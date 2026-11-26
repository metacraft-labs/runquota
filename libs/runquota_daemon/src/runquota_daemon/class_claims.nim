## Who may put a session in a reservation class: the socket it connected on.
##
## Each `[reservation.<class>]` table of the host file has its own daemon
## socket (`runquota_ipc.classEndpoint`), and the operating system's access
## check on that socket -- `connect(2)` needs write permission on a Unix
## socket, `CreateFile` needs the pipe's DACL to allow it -- is what decides
## the claim. By the time a `RegisterSession` arrives, the kernel has
## decided; the daemon only has to remember which socket the connection came
## in on and hold every registration on it to that class. This module is
## that rule, kept pure (no sockets, no daemon state) so it is the same on
## every platform and testable on any of them:
##
## * on a CLASS SOCKET, a registration with no class block, or with the
##   socket's class, is in the class; one naming another class is refused
##   (its client reached the wrong socket); joining an existing group of
##   another class, or of no class, is refused;
## * on the SHARED SOCKET, a registration with a class block is refused,
##   naming the class's socket (or saying the host declares no such class),
##   and joining an existing group that has a class is refused. A
##   registration with no class is served as before.
##
## Nothing is silently dropped: a CI job served outside its reservation
## should fail loudly, which is why the client already refuses a malformed
## class.
##
## A daemon that does not serve class sockets on this platform
## (`runquota_protocol.ClassSocketsServed`) keeps the earlier rule, the class
## block accepted on its one socket, and never calls this.

import std/options

import runquota_ipc

type
  ClassClaim* = object
    ## The verdict on one `RegisterSession`.
    refusal*: string
      ## Empty when the registration may proceed; otherwise the
      ## `invalid argument` message to answer it with.
    className*: string
      ## The class the session's group gets if this session creates it: the
      ## socket's class on a class socket, none on the shared one.

proc classSocketText(endpoint: Endpoint; className: string): string =
  ## The path (or pipe) of `className`'s socket, for a message.
  classSocketPathFor(endpoint.path, className, endpoint.kind,
    endpoint.rendezvousPath)

proc classClaim*(socketClass, requestedClass: string;
                 existingGroupClass: Option[string];
                 declared: openArray[string];
                 sharedEndpoint: Endpoint): ClassClaim =
  ## The verdict for a `RegisterSession` arriving on the socket of
  ## `socketClass` ("" for the shared socket) that names `requestedClass`
  ## ("" for none) and would join a group that already exists with
  ## `existingGroupClass` (none when the session creates the group).
  ## `declared` is every class the host file in force declares, and
  ## `sharedEndpoint` the daemon's shared endpoint, from which the class
  ## sockets' paths are named in the refusals.
  if socketClass.len == 0:
    if requestedClass.len > 0:
      if requestedClass in declared:
        return ClassClaim(refusal: "class " & requestedClass &
          " is claimed only on its own socket, " &
          classSocketText(sharedEndpoint, requestedClass) &
          ", not on the shared socket; a client with RUNQUOTA_CLASS=" &
          requestedClass & " connects there, and the host file's " &
          "[reservation." & requestedClass & "] decides who may")
      return ClassClaim(refusal: "this host declares no class " &
        requestedClass & ": declare [reservation." & requestedClass &
        "] in the host file to give it a socket, or unset RUNQUOTA_CLASS " &
        "to run without a class")
    if existingGroupClass.isSome and existingGroupClass.get.len > 0:
      let groupClass = existingGroupClass.get
      return ClassClaim(refusal: "the session group is in class " &
        groupClass & ", and a group of a class is joined only on that " &
        "class's socket, " & classSocketText(sharedEndpoint, groupClass))
    return ClassClaim(className: "")
  if requestedClass.len > 0 and requestedClass != socketClass:
    return ClassClaim(refusal: "the registration names class " &
      requestedClass & " on the socket of class " & socketClass & " (" &
      classSocketText(sharedEndpoint, socketClass) & "); a connection " &
      "claims only the class of the socket it connected on")
  if existingGroupClass.isSome and existingGroupClass.get != socketClass:
    let groupClass = existingGroupClass.get
    return ClassClaim(refusal:
      if groupClass.len == 0:
        "the session group has no class, and a group without a class is " &
          "joined only on the shared socket, not on the socket of class " &
          socketClass
      else:
        "the session group is in class " & groupClass & ", and it is " &
          "joined only on that class's socket, " &
          classSocketText(sharedEndpoint, groupClass) &
          ", not on the socket of class " & socketClass)
  ClassClaim(className: socketClass)
