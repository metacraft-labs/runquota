## The namespaces a client runs in, as the `Hello` reports them.
##
## WHY THE DAEMON NEEDS TO KNOW. A client in a container reaches the host's
## daemon through a socket forwarded into the container, and everything it
## learns about itself from its own kernel view is in the CONTAINER's
## namespaces: `getuid()` is a container uid and `getpid()` a container pid.
## The daemon reads the connection's peer credentials in ITS OWN namespaces.
## Two consequences follow, and both are about not misreading a value, never
## about trusting one more:
##
## * The `Hello`'s declared uid cannot equal the peer uid the daemon reads
##   (a container's root is an unprivileged host uid, or the uid of the proxy
##   that forwards the socket), so the refusal of a client "declaring
##   somebody else" would refuse every container. The owner was never taken
##   from the declaration, so a client in another USER namespace is excused
##   only from that comparison; its owner is still the peer credential.
## * The pids a client reports (`Hello.processId`, `LeaseRunning`'s child)
##   name processes in ITS pid namespace. Probed in the daemon's, they name
##   unrelated processes -- a container's pid 40 is likely a host kernel
##   thread that never exits -- so a client in another PID namespace has its
##   child watched through the connection's peer process instead
##   (`runquota_daemon`, LeaseRunning).
##
## THE WIRE FORM is two tokens in `Hello.desiredCapabilities`, which is a
## space-separated token list that daemons ignore token by token:
## `pidns=<inode>` and `userns=<inode>`, the inode numbers of
## `/proc/self/ns/pid` and `/proc/self/ns/user`. A daemon that predates them
## ignores them, so the `Hello` stays readable by every daemon of this major.
## A token is written only for a namespace that is NOT the kernel's initial
## one, so a client on the host sends exactly the `Hello` bytes it sent
## before the tokens existed; a daemon reads a missing token as "the same
## namespace as mine", which for a daemon on the host is exactly right.
## The inode identifies a namespace within one running kernel (they share the
## one `nsfs` device), and the daemon and its clients share a kernel.
##
## A REPORT IS A CLAIM, and nothing here turns a claim into authority. The
## daemon checks it against what the kernel shows of the connection's peer
## and refuses a client whose claim the kernel contradicts
## (`runquota_daemon/peer_namespaces`); where the kernel cannot see behind
## the peer (a forwarder), a client that says it is in another user
## namespace skips a consistency check whose only effect is to refuse it, and
## one that says it is in another pid namespace has the daemon watch a host
## process the KERNEL named (the peer) instead of one the client named.
## Neither widens what the client may do.

import std/strutils

when defined(linux):
  import std/posix

type
  ClientNamespaces* = object
    ## Namespace identities; 0 means "not reported" (a client that predates
    ## the tokens, or a platform without namespaces).
    pidNamespace*: uint64
    userNamespace*: uint64

  NamespaceDifference* = object
    ## Which of the client's namespaces are not the daemon's. False whenever
    ## either side did not report the namespace: the daemon then reads the
    ## client's values exactly as it did before namespaces were reported.
    pid*: bool
    user*: bool

const
  PidNamespaceToken* = "pidns="
  UserNamespaceToken* = "userns="
  InitialPidNamespace* = 0xEFFF_FFFC'u64
    ## The inode of the kernel's initial pid namespace (`PROC_PID_INIT_INO`
    ## in `include/linux/proc_ns.h`), fixed since Linux 3.8.
    ## https://github.com/torvalds/linux/blob/master/include/linux/proc_ns.h
  InitialUserNamespace* = 0xEFFF_FFFD'u64
    ## The inode of the initial user namespace (`PROC_USER_INIT_INO`).

proc namespaceInode(path: string): uint64 =
  ## The inode of a `/proc/self/ns/*` link's target, or 0 when it cannot be
  ## read (no procfs, a sandbox that hides it).
  when defined(linux):
    var info: Stat
    if stat(path.cstring, info) == 0:
      uint64(info.st_ino)
    else:
      0'u64
  else:
    discard path
    0'u64

proc currentNamespaces*(): ClientNamespaces =
  ## This process's pid and user namespaces (Linux), or zeros elsewhere.
  ClientNamespaces(
    pidNamespace: namespaceInode("/proc/self/ns/pid"),
    userNamespace: namespaceInode("/proc/self/ns/user"))

proc namespaceTokens*(namespaces: ClientNamespaces): string =
  ## The tokens for the namespaces that are known and are not the kernel's
  ## initial ones, space separated; empty when there is none, which is the
  ## case for every client on the host.
  var tokens: seq[string] = @[]
  if namespaces.pidNamespace notin [0'u64, InitialPidNamespace]:
    tokens.add(PidNamespaceToken & $namespaces.pidNamespace)
  if namespaces.userNamespace notin [0'u64, InitialUserNamespace]:
    tokens.add(UserNamespaceToken & $namespaces.userNamespace)
  tokens.join(" ")

proc withNamespaceTokens*(capabilities: string;
                          namespaces: ClientNamespaces): string =
  ## `capabilities` with the namespace tokens appended.
  let tokens = namespaceTokens(namespaces)
  if tokens.len == 0: capabilities
  elif capabilities.len == 0: tokens
  else: capabilities & " " & tokens

proc parseTokenValue(token, prefix: string; value: var uint64): bool =
  if not token.startsWith(prefix) or token.len == prefix.len:
    return false
  let digits = token[prefix.len .. ^1]
  for c in digits:
    if c notin Digits:
      return false
  try:
    value = parseBiggestUInt(digits).uint64
    true
  except ValueError:
    false

proc parseClientNamespaces*(capabilities: string): ClientNamespaces =
  ## The namespaces a `Hello`'s capability tokens report. A malformed token
  ## reports nothing (0), and the FIRST well-formed token of each kind wins:
  ## either way the result can only be what some token said, never a value
  ## assembled from several.
  for token in capabilities.splitWhitespace():
    var value: uint64
    if result.pidNamespace == 0'u64 and
        parseTokenValue(token, PidNamespaceToken, value) and value != 0'u64:
      result.pidNamespace = value
    elif result.userNamespace == 0'u64 and
        parseTokenValue(token, UserNamespaceToken, value) and value != 0'u64:
      result.userNamespace = value

proc differenceFrom*(client, daemon: ClientNamespaces): NamespaceDifference =
  ## Which of the client's namespaces differ from the daemon's own.
  NamespaceDifference(
    pid: client.pidNamespace != 0'u64 and daemon.pidNamespace != 0'u64 and
      client.pidNamespace != daemon.pidNamespace,
    user: client.userNamespace != 0'u64 and daemon.userNamespace != 0'u64 and
      client.userNamespace != daemon.userNamespace)
