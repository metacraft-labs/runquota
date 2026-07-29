#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo \
    "usage: check_static_helpers.sh <pinned-nim> <immutable-source-root> <gate-wrapper>" \
    >&2
  exit 2
fi

fail() {
  echo "RunQuota static-helper gate authority failure: $*" >&2
  exit 1
}

pinned_nim_argument="$1"
source_root_argument="$2"
gate_wrapper_argument="$3"

case "${pinned_nim_argument}" in
/nix/store/*/bin/nim) ;;
*) fail "pinned Nim argument is not an immutable Nix store wrapper" ;;
esac
[ -L "${pinned_nim_argument}" ] || [ -f "${pinned_nim_argument}" ] ||
  fail "pinned Nim argument does not exist: ${pinned_nim_argument}"
[ -x "${pinned_nim_argument}" ] ||
  fail "pinned Nim argument is not executable: ${pinned_nim_argument}"
pinned_nim="$(realpath -e -- "${pinned_nim_argument}")" ||
  fail "could not canonicalize pinned Nim argument"
[ -f "${pinned_nim}" ] && [ ! -L "${pinned_nim}" ] ||
  fail "canonical pinned Nim is not a regular non-symlink file: ${pinned_nim}"
case "${pinned_nim}" in
/nix/store/*/bin/*nim) ;;
*) fail "canonical pinned Nim escaped its immutable Nix store package" ;;
esac

source_root="$(realpath -e -- "${source_root_argument}" 2>/dev/null)" ||
  fail "source root does not exist: ${source_root_argument}"
[ "${source_root_argument}" = "${source_root}" ] ||
  fail \
    "source root is not canonical: ${source_root_argument} (canonical: ${source_root})"
[ -d "${source_root}" ] && [ ! -L "${source_root}" ] ||
  fail "source root is not a non-symlink directory: ${source_root}"
case "${source_root}" in
/nix/store/*) ;;
*) fail "source root is mutable; the authoritative gate requires a Nix store snapshot" ;;
esac
if find "${source_root}" -perm -0222 -print -quit | grep -q .; then
  fail "immutable source snapshot contains a writable path: ${source_root}"
fi

gate_wrapper="$(realpath -e -- "${gate_wrapper_argument}" 2>/dev/null)" ||
  fail "gate wrapper does not exist: ${gate_wrapper_argument}"
[ "${gate_wrapper_argument}" = "${gate_wrapper}" ] ||
  fail \
    "gate wrapper is not canonical: ${gate_wrapper_argument} (canonical: ${gate_wrapper})"
[ -f "${gate_wrapper}" ] && [ ! -L "${gate_wrapper}" ] &&
  [ -x "${gate_wrapper}" ] ||
  fail "gate wrapper is not an executable regular non-symlink file: ${gate_wrapper}"
case "${gate_wrapper}" in
/nix/store/*/bin/runquota-static-helper-gate) ;;
*) fail "gate wrapper is not the immutable generated RunQuota gate" ;;
esac

authority="$("${gate_wrapper}" --print-authority)"
expected_authority="$(
  printf 'nim=%s\nsource=%s\npath=%s\ngate=%s\n' \
    "${pinned_nim_argument}" "${source_root}" "${PATH}" "${gate_wrapper}"
)"
[ "${authority}" = "${expected_authority}" ] ||
  fail \
    "generated wrapper authority does not match its positional compiler, source, PATH, and identity"

[ -z "${RUNQUOTA_PINNED_NIM+x}" ] ||
  fail "generated wrapper leaked RUNQUOTA_PINNED_NIM into the gate"
[ -z "${RUNQUOTA_SOURCE_ROOT+x}" ] ||
  fail "generated wrapper leaked RUNQUOTA_SOURCE_ROOT into the gate"
[ -z "${HOME+x}" ] ||
  fail "generated wrapper leaked HOME into the gate"
[ -z "${XDG_CONFIG_HOME+x}" ] ||
  fail "generated wrapper leaked XDG_CONFIG_HOME into the gate"
[ -z "${XDG_CONFIG_DIRS+x}" ] ||
  fail "generated wrapper leaked XDG_CONFIG_DIRS into the gate"
[ -z "${NIMBLE_DIR+x}" ] ||
  fail "generated wrapper leaked NIMBLE_DIR into the gate"
[ -z "${NIM_LIB_PREFIX+x}" ] ||
  fail "generated wrapper leaked NIM_LIB_PREFIX into the gate"
[ -z "${NIM_CONFIG_DIR+x}" ] ||
  fail "generated wrapper leaked NIM_CONFIG_DIR into the gate"
[ -z "${REPROBUILD_SRC+x}" ] ||
  fail "generated wrapper leaked REPROBUILD_SRC into the gate"
[ -z "${CC+x}" ] ||
  fail "generated wrapper leaked CC into the gate"
[ -z "${CXX+x}" ] ||
  fail "generated wrapper leaked CXX into the gate"

current_root="$(pwd -P)"
[ -d "${current_root}" ] && [ -w "${current_root}" ] ||
  fail "current build root is not a writable directory: ${current_root}"
case "${current_root}" in
/nix/store | /nix/store/*)
  fail "build outputs must not be written into the immutable source store"
  ;;
esac

build_root="${current_root}/build"
static_lib_root="${build_root}/static-libs"
test_bin_root="${build_root}/test-bin"
nimcache_root="${build_root}/nimcache"
test_work_root="${build_root}/test-work"
compiler_private_root="${build_root}/compiler-private"
mkdir -p \
  "${static_lib_root}" "${test_bin_root}" "${nimcache_root}" \
  "${test_work_root}" \
  "${compiler_private_root}/home" \
  "${compiler_private_root}/tmp" \
  "${compiler_private_root}/xdg"
chmod 700 \
  "${test_work_root}" \
  "${compiler_private_root}" \
  "${compiler_private_root}/home" \
  "${compiler_private_root}/tmp" \
  "${compiler_private_root}/xdg"

readonly trusted_path="${PATH}"
run_pinned_nim() {
  env -i \
    HOME="${compiler_private_root}/home" \
    TMPDIR="${compiler_private_root}/tmp" \
    XDG_CONFIG_HOME="${compiler_private_root}/xdg" \
    PATH="${trusted_path}" \
    LC_ALL=C \
    LANG=C \
    "${pinned_nim}" "$@"
}

repo_path_arguments=()
while IFS= read -r -d '' source_directory; do
  canonical_source_directory="$(realpath -e -- "${source_directory}")" ||
    fail "could not canonicalize repository source directory: ${source_directory}"
  [ "${canonical_source_directory}" = "${source_directory}" ] ||
    fail "repository source directory is not canonical: ${source_directory}"
  repo_path_arguments+=(--path:"${source_directory}")
done < <(
  find "${source_root}/libs" \
    -mindepth 2 -maxdepth 2 -type d -name src -print0 |
    sort -z
)
[ "${#repo_path_arguments[@]}" -gt 0 ] ||
  fail "immutable source snapshot contains no library source directories"

ref_scanner="${test_bin_root}/nim_ref_token_scanner"
scanner_bootstrap="$(mktemp -d \
  "${build_root}/nim-scanner-bootstrap.XXXXXX")"
chmod 700 "${scanner_bootstrap}"
scanner_bootstrap="$(realpath -e -- "${scanner_bootstrap}")"
cleanup() {
  chmod -R u+rwX "${scanner_bootstrap}" 2>/dev/null || true
  rm -rf "${scanner_bootstrap}"
}
trap cleanup EXIT
nim_root="$(
  bash "${source_root}/scripts/bootstrap_nim_ref_token_scanner.sh" \
    "${pinned_nim_argument}" \
    "${source_root}/scripts/nim_ref_token_scanner.nim" \
    "${ref_scanner}" \
    "${scanner_bootstrap}"
)"
nim_lib_root="${nim_root}/lib"

TMPDIR="${test_work_root}" \
  bash "${source_root}/scripts/test_nim_ref_token_scanner.sh" \
  "${ref_scanner}" \
  "${source_root}" \
  "${nim_root}" \
  "${scanner_bootstrap}" \
  "${pinned_nim_argument}" \
  "${gate_wrapper}"

while read -r lib _; do
  case "${lib}" in
  "" | \#*) continue ;;
  esac

  entry="${source_root}/libs/${lib}/src/${lib}.nim"
  [ -f "${entry}" ] && [ ! -L "${entry}" ] ||
    fail "static-helper entry is not an immutable regular file: ${entry}"
  nimcache="${nimcache_root}/static-${lib}"
  deps="${nimcache}/${lib}.deps"
  archive="${static_lib_root}/lib${lib}.a"
  rm -rf "${nimcache}"
  rm -f "${archive}"

  compiler_arguments=(
    c
    --skipCfg:on
    --skipUserCfg:on
    --skipParentCfg:on
    --skipProjCfg:on
    --cc:clang
    --mm:arc
    --app:staticlib
    --nimcache:"${nimcache}"
    --out:"${archive}"
    "${repo_path_arguments[@]}"
  )
  run_pinned_nim \
    "${compiler_arguments[@]}" \
    --genScript:on \
    "${entry}"
  [ -f "${deps}" ] ||
    fail "Nim compiler did not emit dependency manifest ${deps}"

  if ! "${ref_scanner}" closure \
    "${source_root}" "${nim_lib_root}" "${entry}" "${deps}"; then
    echo "Nim ref type token found in static helper ${lib}" >&2
    exit 1
  fi

  rm -f "${archive}"
  run_pinned_nim "${compiler_arguments[@]}" "${entry}"
  [ -s "${archive}" ] ||
    fail "Nim did not build static helper archive for ${lib}"
done <"${source_root}/libs/static_helpers.txt"

echo "runquota static helper checks passed"
