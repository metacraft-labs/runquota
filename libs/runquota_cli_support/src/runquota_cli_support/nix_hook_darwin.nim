## The darwin kernel queries of `runquota nix-build-hook` (see the module
## header of `nix_hook` and Build-Engine § Nix daemon builds under leases,
## "Darwin"). Linux answers the same questions from `sock_diag` and `/proc`;
## darwin has neither, and answers them through `libproc` and `sysctl(3)`:
##
## * a process's open descriptors, and what each one is
##   (`proc_pidinfo(PROC_PIDLISTFDS)`, `proc_pidfdinfo`), which is how `lsof`
##   works. A caller sees only processes of its own effective uid unless it is
##   root (`proc_security_policy`, `CHECK_SAME_USER`, in XNU's
##   `bsd/kern/proc_info.c`,
##   https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/proc_info.c);
## * the uid that created an AF_UNIX socket, from the kernel's list of local
##   stream sockets (`net.local.stream.pcblist64`, filled by `unp_pcblist64`
##   in `bsd/kern/uipc_usrreq.c`; `so_uid` is `kauth_cred_getuid(so->so_cred)`,
##   `sotoxsocket64` in `bsd/kern/uipc_socket2.c`, and `so_cred` is the
##   creating process's credential, `socreate_internal` in
##   `bsd/kern/uipc_socket.c`). Its records are not in the public SDK headers
##   (`sys/unpcb.h` keeps `struct xunpcb64` under `PRIVATE`), so the layout is
##   declared below from the XNU sources and CHECKED at run time against the
##   record lengths the kernel writes (`xu_len`, `xso_len`, `xug_len`); a
##   kernel whose records differ is reported as an unknown owner, never read;
## * a process's identity over time: its real and effective ids and its start
##   time (`PROC_PIDTBSDINFO`); a pid and a start time to the microsecond name
##   one process, which is what stands in for Linux's pinned `/proc/<pid>`;
## * a process's environment as it was exec'd (`sysctl` `KERN_PROCARGS2`,
##   `sysctl_procargsx` in `bsd/kern/kern_sysctl.c`: root, or the same
##   effective uid);
## * this process's own credential as the kernel holds it (`KERN_PROC_PID`,
##   `fill_user64_eproc`: real, effective and saved ids and the group list).
##
## Every call here is a read; nothing is opened, locked or signalled.

when defined(macosx):
  import std/[algorithm, posix]

  {.emit: """
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>

/* The pcblist64 records (XNU bsd/sys/unpcb.h and bsd/sys/socketvar.h,
   both under PRIVATE and #pragma pack(4)). Only the lengths, the pcb
   handles and so_uid are read, after the lengths are checked. */
#pragma pack(4)
struct rq_xsockbuf { u_int32_t sb_cc, sb_hiwat, sb_mbcnt, sb_mbmax;
  int32_t sb_lowat; short sb_flags, sb_timeo; };
struct rq_xsocket64 { u_int32_t xso_len; u_int64_t xso_so;
  short so_type, so_options, so_linger, so_state; u_int64_t so_pcb;
  int xso_protocol, xso_family; short so_qlen, so_incqlen, so_qlimit, so_timeo;
  u_short so_error; pid_t so_pgid; u_int32_t so_oobmark;
  struct rq_xsockbuf so_rcv, so_snd; uid_t so_uid; };
struct rq_list_entry { u_int64_t le_next, le_prev; };
struct rq_xunpcb64 { u_int32_t xu_len; u_int64_t xu_unpp;
  struct rq_list_entry xunp_link; u_int64_t xunp_socket, xunp_vnode, xunp_ino,
  xunp_conn, xunp_refs; struct rq_list_entry xunp_reflink; int xunp_cc, xunp_mbcnt;
  u_int64_t xunp_gencnt; int xunp_flags; char xu_au[256]; char xu_cau[256];
  struct rq_xsocket64 xu_socket; };
#pragma pack()
struct rq_xunpgen { u_int32_t xug_len; u_int xug_count; u_int64_t xug_gen;
  u_int64_t xug_sogen; };

/* The fds of `pid`: their numbers and PROX_FDTYPE_* types. Returns the
   count (at most `cap`), or -errno. */
static int rq_darwin_list_fds(int pid, int *fds, unsigned *types, int cap) {
  int bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
  if (bytes <= 0) return -(errno ? errno : ESRCH);
  /* Room for descriptors opened between the two calls. */
  int room = bytes / (int)sizeof(struct proc_fdinfo) + 32;
  struct proc_fdinfo *list = calloc((size_t)room, sizeof(struct proc_fdinfo));
  if (list == NULL) return -ENOMEM;
  bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, list,
                       room * (int)sizeof(struct proc_fdinfo));
  if (bytes <= 0) { int e = errno ? errno : ESRCH; free(list); return -e; }
  int n = bytes / (int)sizeof(struct proc_fdinfo);
  if (n > cap) n = cap;
  for (int i = 0; i < n; i++) {
    fds[i] = list[i].proc_fd;
    types[i] = list[i].proc_fdtype;
  }
  free(list);
  return n;
}

/* An AF_UNIX socket fd of `pid`: 1 with its own pcb handle, its peer's
   pcb handle (0 when unconnected) and its bound path; 0 when it is
   another kind of socket; -1 when it cannot be read. */
static int rq_darwin_unix_socket(int pid, int fd, unsigned long long *pcb,
    unsigned long long *conn, char *path, int pathcap) {
  struct socket_fdinfo si;
  memset(&si, 0, sizeof si);
  if (proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &si, sizeof si) != sizeof si)
    return -1;
  if (si.psi.soi_family != AF_UNIX || si.psi.soi_kind != SOCKINFO_UN) return 0;
  *pcb = si.psi.soi_pcb;
  *conn = si.psi.soi_proto.pri_un.unsi_conn_pcb;
  const struct sockaddr_un *sun = &si.psi.soi_proto.pri_un.unsi_addr.ua_sun;
  size_t len = strnlen(sun->sun_path, sizeof sun->sun_path);
  if ((int)len >= pathcap) len = (size_t)pathcap - 1;
  memcpy(path, sun->sun_path, len);
  path[len] = 0;
  return 1;
}

/* A vnode fd of `pid`: 1 with the file's device, inode and the fd's open
   flags (FWASLOCKED among them); -1 when it cannot be read. */
static int rq_darwin_vnode(int pid, int fd, unsigned long long *dev,
    unsigned long long *ino, unsigned *openflags) {
  struct vnode_fdinfo vi;
  memset(&vi, 0, sizeof vi);
  if (proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEINFO, &vi, sizeof vi) != sizeof vi)
    return -1;
  *dev = (unsigned long long)(unsigned)vi.pvi.vi_stat.vst_dev;
  *ino = vi.pvi.vi_stat.vst_ino;
  *openflags = vi.pfi.fi_openflags;
  return 1;
}

/* `pid`'s identity: 0 on success, -errno otherwise. */
static int rq_darwin_bsdinfo(int pid, unsigned *ruid, unsigned *uid,
    unsigned *rgid, unsigned *ppid, unsigned long long *start_sec,
    unsigned long long *start_usec) {
  struct proc_bsdinfo bi;
  memset(&bi, 0, sizeof bi);
  if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, sizeof bi) != sizeof bi)
    return -(errno ? errno : ESRCH);
  *ruid = bi.pbi_ruid; *uid = bi.pbi_uid; *rgid = bi.pbi_rgid;
  *ppid = bi.pbi_ppid;
  *start_sec = bi.pbi_start_tvsec; *start_usec = bi.pbi_start_tvusec;
  return 0;
}

/* How many descriptor entries to allocate for `pid` (its count now, plus
   room for ones opened before the listing), or -errno. */
static int rq_darwin_fd_room(int pid) {
  int bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
  if (bytes <= 0) return -(errno ? errno : ESRCH);
  return bytes / (int)sizeof(struct proc_fdinfo) + 32;
}

static int rq_darwin_pid_room(void) {
  int n = proc_listallpids(NULL, 0);
  return n < 0 ? -(errno ? errno : EPERM) : n + 256;
}

/* Every pid. Returns the count (at most `cap`), or -errno. */
static int rq_darwin_list_pids(int *pids, int cap) {
  int n = proc_listallpids(pids, cap * (int)sizeof(int));
  if (n < 0) return -(errno ? errno : EPERM);
  return n > cap ? cap : n;
}

/* The uid that created the local stream socket whose pcb handle is
   `pcb`: 1 found (in *uid), 0 not found, -1 the list cannot be read or
   its records are not the layout above. */
static int rq_darwin_socket_owner(unsigned long long pcb,
    unsigned long long peer, unsigned *uid) {
  /* The kernel sizes its answer for the sockets that exist now plus an
     eighth (`unp_pcblist64`); sockets created between the two calls can
     outgrow that (ENOMEM), so the read is retried with twice the room. */
  size_t len = 0;
  char *buf = NULL;
  int attempt;
  for (attempt = 0; attempt < 4; attempt++) {
    size_t want = 0;
    if (sysctlbyname("net.local.stream.pcblist64", NULL, &want, NULL, 0) != 0)
      return -1;
    want = want << attempt;
    if (want < sizeof(struct rq_xunpgen) || want > (256u << 20)) return -1;
    buf = malloc(want);
    if (buf == NULL) return -1;
    len = want;
    if (sysctlbyname("net.local.stream.pcblist64", buf, &len, NULL, 0) == 0)
      break;
    free(buf);
    buf = NULL;
    if (errno != ENOMEM) return -1;
  }
  if (buf == NULL) return -1;
  int result = -1;
  struct rq_xunpgen gen;
  memcpy(&gen, buf, sizeof gen);
  if (len >= sizeof gen && gen.xug_len == sizeof(struct rq_xunpgen)) {
    result = 0;
    size_t off = sizeof gen;
    while (off + sizeof(struct rq_xunpcb64) <= len) {
      struct rq_xunpcb64 rec;
      memcpy(&rec, buf + off, sizeof rec);
      if (rec.xu_len != sizeof(struct rq_xunpcb64) ||
          rec.xu_socket.xso_len != sizeof(struct rq_xsocket64)) {
        result = -1;   /* not the layout declared above: read nothing */
        break;
      }
      /* The record must be the client end AND be connected to the
         worker's own socket: a pcb handle is derived from an address, and
         a socket created at a freed address would otherwise match. */
      if (rec.xu_unpp == pcb && pcb != 0 && rec.xunp_conn == peer) {
        *uid = rec.xu_socket.so_uid;
        result = 1;
        break;
      }
      off += sizeof rec;
    }
  }
  free(buf);
  return result;
}

/* This process's credential as the kernel holds it: 0 on success. */
static int rq_darwin_self_cred(unsigned *ruid, unsigned *euid, unsigned *svuid,
    unsigned *rgid, unsigned *egid, unsigned *svgid, int *ngroups,
    unsigned *groups) {
  struct kinfo_proc kp;
  size_t len = sizeof kp;
  int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, (int)getpid() };
  memset(&kp, 0, sizeof kp);
  if (sysctl(mib, 4, &kp, &len, NULL, 0) != 0 || len != sizeof kp) return -1;
  *ruid = kp.kp_eproc.e_pcred.p_ruid;
  *svuid = kp.kp_eproc.e_pcred.p_svuid;
  *rgid = kp.kp_eproc.e_pcred.p_rgid;
  *svgid = kp.kp_eproc.e_pcred.p_svgid;
  *euid = kp.kp_eproc.e_ucred.cr_uid;
  int n = kp.kp_eproc.e_ucred.cr_ngroups;
  if (n < 0) n = 0;
  if (n > NGROUPS) n = NGROUPS;
  *ngroups = n;
  for (int i = 0; i < n; i++) groups[i] = kp.kp_eproc.e_ucred.cr_groups[i];
  /* BSD keeps the effective gid as the first entry of the group list. */
  *egid = n > 0 ? kp.kp_eproc.e_ucred.cr_groups[0] : (unsigned)-1;
  return 0;
}

/* `pid`'s KERN_PROCARGS2 block into `buf` (at most `cap` bytes): the
   length, or -errno. */
static long rq_darwin_procargs(int pid, char *buf, size_t cap) {
  int mib[3] = { CTL_KERN, KERN_PROCARGS2, pid };
  size_t len = cap;
  if (sysctl(mib, 3, buf, &len, NULL, 0) != 0) return -(long)(errno ? errno : EPERM);
  return (long)len;
}

static int rq_darwin_argmax(void) {
  int mib[2] = { CTL_KERN, KERN_ARGMAX };
  int value = 0;
  size_t len = sizeof value;
  if (sysctl(mib, 2, &value, &len, NULL, 0) != 0) return -1;
  return value;
}
""".}

  proc rqListFds(pid: cint; fds: ptr cint; types: ptr cuint; cap: cint): cint {.
    importc: "rq_darwin_list_fds", nodecl.}
  proc rqUnixSocket(pid, fd: cint; pcb, conn: var culonglong; path: cstring;
                    cap: cint): cint {.importc: "rq_darwin_unix_socket", nodecl.}
  proc rqVnode(pid, fd: cint; dev, ino: var culonglong; flags: var cuint): cint {.
    importc: "rq_darwin_vnode", nodecl.}
  proc rqBsdInfo(pid: cint; ruid, uid, rgid, ppid: var cuint;
                 startSec, startUsec: var culonglong): cint {.
    importc: "rq_darwin_bsdinfo", nodecl.}
  proc rqListPids(pids: ptr cint; cap: cint): cint {.
    importc: "rq_darwin_list_pids", nodecl.}
  proc rqFdRoom(pid: cint): cint {.importc: "rq_darwin_fd_room", nodecl.}
  proc rqPidRoom(): cint {.importc: "rq_darwin_pid_room", nodecl.}
  proc rqSocketOwner(pcb, peer: culonglong; uid: var cuint): cint {.
    importc: "rq_darwin_socket_owner", nodecl.}
  proc rqSelfCred(ruid, euid, svuid, rgid, egid, svgid: var cuint;
                  ngroups: var cint; groups: ptr cuint): cint {.
    importc: "rq_darwin_self_cred", nodecl.}
  proc rqProcArgs(pid: cint; buf: cstring; cap: csize_t): clong {.
    importc: "rq_darwin_procargs", nodecl.}
  proc rqArgMax(): cint {.importc: "rq_darwin_argmax", nodecl.}

  const
    ProxFdTypeVnode* = 1'u32
    ProxFdTypeSocket* = 2'u32
    FWasLocked* = 0x4000'u32
      ## `fg_flag` bit set by a successful `flock(2)` and never cleared
      ## while the open file lives (`sys_flock`, `bsd/kern/kern_descrip.c`;
      ## `FWASLOCKED`/`FHASLOCK` in `bsd/sys/fcntl.h`).
    FdListLimit = 1 shl 16
      ## Descriptors read per process (a process with more is read up to
      ## this many).
    PidListLimit = 1 shl 17

  type
    DarwinFd* = object
      fd*: int
      kind*: uint32     ## `PROX_FDTYPE_*`.

    UnixSocketEnd* = object
      fd*: int
      pcb*: uint64      ## This socket's pcb handle.
      conn*: uint64     ## Its peer's pcb handle; 0 when unconnected.
      path*: string     ## The bound path ("" when unbound).

    ProcessIdentity* = object
      ## Who a process is and when it started: a pid and a start time name
      ## one process (a pid is reused only after its process is gone, and
      ## the next one starts later).
      ruid*, uid*, rgid*, ppid*: int
      startSec*, startUsec*: uint64

    SelfCredential* = object
      ruid*, euid*, svuid*: int
      rgid*, egid*, svgid*: int
      groups*: seq[int]

  proc listFds*(pid: int; ok: var bool): seq[DarwinFd] =
    ## The open descriptors of `pid`; `ok` false when they could not be
    ## read (it is gone, or not ours to read).
    ok = false
    let room = min(int(rqFdRoom(cint(pid))), FdListLimit)
    if room <= 0: return
    var fds = newSeq[cint](room)
    var types = newSeq[cuint](room)
    let n = rqListFds(cint(pid), addr fds[0], addr types[0], cint(room))
    if n < 0: return
    ok = true
    for i in 0 ..< int(n):
      result.add(DarwinFd(fd: int(fds[i]), kind: uint32(types[i])))

  proc listFds*(pid: int): seq[DarwinFd] =
    ## The open descriptors of `pid`; empty when they cannot be read.
    var ok = false
    listFds(pid, ok)

  proc unixSocketsOf*(pid: int): seq[UnixSocketEnd] =
    ## The AF_UNIX sockets `pid` holds.
    var path = newString(256)
    for entry in listFds(pid):
      if entry.kind != ProxFdTypeSocket: continue
      var pcb, conn: culonglong
      if rqUnixSocket(cint(pid), cint(entry.fd), pcb, conn, path.cstring,
          cint(path.len)) == 1:
        result.add(UnixSocketEnd(fd: entry.fd, pcb: uint64(pcb),
          conn: uint64(conn), path: $path.cstring))

  proc holdsSocket*(pid: int; pcb: uint64): bool =
    ## Whether `pid` has a descriptor on the socket whose pcb is `pcb`.
    for socket in unixSocketsOf(pid):
      if socket.pcb == pcb: return true
    false

  proc socketOwner*(pcb, peer: uint64; uid: var int): int =
    ## The uid that created the local stream socket `pcb`, which must be
    ## connected to the socket `peer`: 1 found, 0 no such socket, -1
    ## unreadable (see the module header).
    var owner: cuint
    result = int(rqSocketOwner(culonglong(pcb), culonglong(peer), owner))
    if result == 1: uid = int(owner)

  proc processIdentity*(pid: int; identity: var ProcessIdentity): bool =
    var ruid, uid, rgid, ppid: cuint
    var sec, usec: culonglong
    if rqBsdInfo(cint(pid), ruid, uid, rgid, ppid, sec, usec) != 0:
      return false
    identity = ProcessIdentity(ruid: int(ruid), uid: int(uid),
      rgid: int(rgid), ppid: int(ppid), startSec: uint64(sec),
      startUsec: uint64(usec))
    true

  proc sameProcess*(a, b: ProcessIdentity): bool =
    a.startSec == b.startSec and a.startUsec == b.startUsec

  proc allPids*(): seq[int] =
    ## Every pid, ascending.
    let room = min(int(rqPidRoom()), PidListLimit)
    if room <= 0: return
    var pids = newSeq[cint](room)
    let n = rqListPids(addr pids[0], cint(room))
    for i in 0 ..< max(0, int(n)):
      if pids[i] > 0: result.add(int(pids[i]))
    result.sort()

  proc fileLockProbe*(pid: int; files: openArray[(uint64, uint64)]): int =
    ## Whether `pid` has a descriptor that took a `flock(2)` on one of
    ## `files` (device, inode): 1 held, 0 free, -1 the descriptors could not
    ## all be read (a caller must not take that for free). Nix holds an
    ## output lock exactly as long as it keeps that descriptor (`PathLocks`,
    ## `src/libstore/unix/pathlocks.cc`: a descriptor is kept only once its
    ## `flock` succeeded, and closing it is the release; Nix never unlocks
    ## an output lock with `LOCK_UN`, which would leave `FWASLOCKED` set),
    ## so an open descriptor marked `FWASLOCKED` is a held lock. Reads only:
    ## the lock file is never opened.
    if files.len == 0: return 0
    var ok = false
    let entries = listFds(pid, ok)
    if not ok: return -1
    result = 0
    for entry in entries:
      if entry.kind != ProxFdTypeVnode: continue
      var dev, ino: culonglong
      var flags: cuint
      if rqVnode(cint(pid), cint(entry.fd), dev, ino, flags) != 1:
        # Closed since the listing, or unreadable: not proof of either.
        result = -1
        continue
      if (uint32(flags) and FWasLocked) == 0: continue
      for (fileDev, fileIno) in files:
        if uint64(dev) == fileDev and uint64(ino) == fileIno:
          return 1

  proc selfCredential*(credential: var SelfCredential): bool =
    var ruid, euid, svuid, rgid, egid, svgid: cuint
    var ngroups: cint
    var groups: array[16, cuint]
    if rqSelfCred(ruid, euid, svuid, rgid, egid, svgid, ngroups,
        addr groups[0]) != 0:
      return false
    credential = SelfCredential(ruid: int(ruid), euid: int(euid),
      svuid: int(svuid), rgid: int(rgid), egid: int(egid), svgid: int(svgid))
    for i in 0 ..< int(ngroups): credential.groups.add(int(groups[i]))
    true

  proc procArgs*(pid: int; limit: int): string =
    ## `pid`'s `KERN_PROCARGS2` block, at most `limit` bytes (and at most
    ## `kern.argmax`, the most `execve` accepts). Raises `IOError` when it
    ## cannot be read (the process is gone, or is not ours to read).
    # The kernel refuses a buffer larger than `ARG_MAX` (`EINVAL`,
    # `sysctl_procargsx`), and `kern.argmax` is `ARG_MAX`.
    let argMax = int(rqArgMax())
    let cap = max(64, min(limit, (if argMax > 0: argMax else: limit)))
    result = newString(cap)
    let n = rqProcArgs(cint(pid), result.cstring, csize_t(cap))
    if n < 0:
      raise newException(IOError, "cannot read the arguments of pid " &
        $pid & ": " & $strerror(cint(-n)))
    result.setLen(int(n))
