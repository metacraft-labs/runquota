import std/[osproc, strutils]

import runquota_core
import runquota_core/child_process
import runquota_host
import runquota_host_macos/types as macosTypes
import runquota_host_macos/process_telemetry

export macosTypes

const libraryName* = "runquota_host_macos"

proc libraryInfo*(): macosTypes.LibraryInfo =
  macosTypes.LibraryInfo(name: libraryName)

proc sampleMacosMemoryPressure*(required = false): HostMemoryPressureSample =
  ## Ask macOS what its memory pressure is.
  ##
  ## This was `execProcess(..., options = {poUsePath})`. The explicit
  ## `options` replaces `execProcess`'s default of
  ## `{poStdErrToStdOut, poUsePath, poEvalCommand}` wholesale, and
  ## `execProcess`'s body reads `outputStream` and no other stream -- so with
  ## the default gone, stderr had a pipe here that nobody would ever read, and
  ## stdin was never closed. `memory_pressure -Q` is not a tool that says
  ## 65_536 bytes' worth on stderr, so the deadlock was latent rather than
  ## live; the live hazard was the unguarded `startProcess`. The admission
  ## path calls this from whichever thread is deciding, alongside the
  ## observation store's writer and the ambient sampler, and osproc's pipes
  ## are inheritable for the length of the call -- a spawn from any of those
  ## threads at that instant takes them.
  ##
  ## `runCapturedProcess` takes the spawn guard and services every stream, so
  ## this is no longer either kind of hazard. A tool that will not run is
  ## reported through the sample's own "unavailable" shape, exactly as a
  ## raised `OSError` was before.
  when defined(macosx):
    try:
      let captured = runCapturedProcess(
        "/usr/bin/memory_pressure", args = ["-Q"], options = {poUsePath})
      if captured.failure.len > 0:
        return unavailablePressureSample(
          "macos-memory_pressure", required, captured.failure)
      let output = captured.output
      let lower = output.toLowerAscii()
      if lower.contains("critical"):
        return HostMemoryPressureSample(
          level: pressureCritical,
          available: true,
          required: required,
          source: "macos-memory_pressure",
          diagnostic: diagnostic(diagDenied, "host memory pressure is critical", output.strip())
        )
      if lower.contains("warn"):
        return HostMemoryPressureSample(
          level: pressureWarning,
          available: true,
          required: required,
          source: "macos-memory_pressure",
          diagnostic: diagnostic(diagDenied, "host memory pressure is warning", output.strip())
        )
      lowPressureSample("macos-memory_pressure", required)
    except CatchableError as error:
      unavailablePressureSample("macos-memory_pressure", required, error.msg)
  else:
    unavailablePressureSample("macos-memory_pressure", required, "backend is only active on macOS")

proc sampleMacosProcessTreeTelemetry*(rootProcessId: uint64): HostProcessTreeTelemetrySample =
  sampleMacosProcessTreeTelemetryNative(rootProcessId)
