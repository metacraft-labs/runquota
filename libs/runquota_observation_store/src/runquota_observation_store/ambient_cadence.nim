## Fixed-interval waits for host observations. macOS background scheduling
## coalesces ordinary sleeps enough to lose most short sampling intervals.
## A critical kqueue timer requests timely wakeups without raising CPU priority.
import std/os

when defined(macosx):
  import std/posix
  import posix/kqueue

  let noteCritical {.importc: "NOTE_CRITICAL", header: "<sys/event.h>", nodecl.}: cuint

type AmbientCadence* = object
  millis: int
  when defined(macosx):
    descriptor: cint

proc openAmbientCadence*(millis: int): AmbientCadence =
  result.millis = max(1, millis)
  when defined(macosx):
    result.descriptor = kqueue()
    if result.descriptor < 0:
      return
    var event: KEvent
    # Darwin's default unit is milliseconds. Nim's cross-BSD NOTE_MSECONDS
    # constant has a different meaning on Darwin; use the SDK's critical flag.
    EV_SET(addr event, 1, EVFILT_TIMER, EV_ADD or EV_ENABLE,
      noteCritical, result.millis, nil)
    if fcntl(result.descriptor, F_SETFD, FD_CLOEXEC) < 0 or
        kevent(result.descriptor, addr event, 1, nil, 0, nil) < 0:
      discard posix.close(result.descriptor)
      result.descriptor = -1

proc closeAmbientCadence*(timer: var AmbientCadence) =
  when defined(macosx):
    if timer.descriptor >= 0:
      discard posix.close(timer.descriptor)
      timer.descriptor = -1

proc waitAmbientCadence*(timer: var AmbientCadence): bool =
  ## False reports a macOS timer failure and a bounded ordinary-sleep fallback.
  ## One event permits one actual reading, regardless of missed period count.
  when defined(macosx):
    if timer.descriptor >= 0:
      var event: KEvent
      while true:
        let count = kevent(timer.descriptor, nil, 0, addr event, 1, nil)
        if count == 1 and (event.flags and EV_ERROR) == 0:
          return true
        if count < 0 and errno == EINTR:
          continue
        closeAmbientCadence(timer)
        break
    sleep(timer.millis)
    false
  else:
    sleep(timer.millis)
    true
