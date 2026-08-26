# Shared build-mode resolution. Source, do not execute.
#
# WHY THIS EXISTS. `scripts/build_apps.sh` and `scripts/run_tests.sh` each
# resolved `RUNQUOTA_BUILD_MODE` with their own copy of the same case
# statement, and the two benchmark scripts resolved it not at all -- they
# compiled with a bare `--threads:on`, so every benchmark this repository has
# ever published came out of a Nim DEBUG build (`opt: none`).
#
# THAT IS NOT A SLOW NUMBER, IT IS A WRONG COMPARISON. The shm arm of the M8
# preemption study is built `-d:release` on all three of its arms
# (`nim-shm-lease`'s `just preemption-study`). Measuring RunQuota's socket arm
# debug and comparing the two would bias the result toward shared memory by
# whatever debug costs on this code -- and M8's verdict decides whether M23
# and M24 get built at all. A benchmark that answers a design question has to
# be built the way the thing it is deciding about was built.
#
# SO BENCHMARKS DEFAULT TO RELEASE and everything else defaults to debug.
# The default belongs to the caller because the correct answer differs: a test
# run wants debug's checks, a measurement wants the code that will ship.

# Resolve the build mode from the environment, honouring a caller-supplied
# default. Sets RUNQUOTA_RESOLVED_BUILD_MODE and nim_mode_flags.
resolve_build_mode() {
  local fallback="${1:-debug}"
  local requested="${RUNQUOTA_BUILD_MODE:-${REPROBUILD_BUILD_MODE:-${fallback}}}"
  case "${requested}" in
    ""|debug)
      RUNQUOTA_RESOLVED_BUILD_MODE=debug
      nim_mode_flags=()
      ;;
    release)
      RUNQUOTA_RESOLVED_BUILD_MODE=release
      nim_mode_flags=(-d:release)
      ;;
    *)
      echo "unknown RUNQUOTA_BUILD_MODE: ${requested}" >&2
      exit 2
      ;;
  esac
}

# The mode `build/bin` was last built with, or the empty string when nothing
# recorded one. `build_apps.sh` is what writes it.
build_apps_mode_stamp() { echo "build/bin/.build-mode"; }

recorded_apps_mode() {
  local stamp
  stamp="$(build_apps_mode_stamp)"
  if [ -f "${stamp}" ]; then
    cat "${stamp}"
  else
    echo ""
  fi
}

# True when any `.nim` under `libs/` or `apps/` is newer than `build/bin`.
apps_are_stale() {
  [ -x build/bin/runquotad ] || return 0
  [ -n "$(find libs apps -name '*.nim' -newer build/bin/runquotad -print -quit \
      2>/dev/null)" ]
}

# Rebuild `build/bin` unless it already exists, was built in the mode we need,
# AND is newer than the sources it was built from.
#
# EXISTENCE IS THE WRONG QUESTION, which is the bug this replaces. The
# benchmark scripts asked `[ ! -x build/bin/runquotad ]` and reused whatever
# was there -- so a daemon left behind by a debug `just test` silently became
# the subject of a release benchmark, and the published number described a
# pair of binaries built two different ways. Same class as a stale binary
# reading green: the input was never checked, only counted.
#
# THE MODE STAMP ALONE WAS ALSO THE WRONG QUESTION, and that was this
# function's own bug rather than the one it was written to fix. Matching the
# mode says how `build/bin` was compiled and nothing about WHEN, so an
# experiment that edited the daemon and re-ran a benchmark measured the
# PREVIOUS daemon and reported a difference of zero. That cost real time: two
# consecutive "decisive experiments" measured nothing and were only caught
# because their numbers made no sense. `tests/support/daemon_binary.nim`
# already refuses a stale binary for the same reason on the test path; a
# benchmark deserves the check at least as much, because it publishes.
ensure_apps_built_in_mode() {
  local want="$1"
  if [ -x build/bin/runquotad ] && [ -x build/bin/runquota ] &&
      [ "$(recorded_apps_mode)" = "${want}" ] && ! apps_are_stale; then
    return 0
  fi
  local why="mode '$(recorded_apps_mode)'"
  if apps_are_stale; then
    why="${why}, sources newer than the binary"
  fi
  echo "building apps in ${want} mode (${why})" >&2
  RUNQUOTA_BUILD_MODE="${want}" ./scripts/build_apps.sh
}
