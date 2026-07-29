#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo \
    "usage: bootstrap_nim_ref_token_scanner.sh <pinned-nim> <scanner-source> <output> <empty-private-root>" \
    >&2
  exit 2
fi

fail() {
  echo "Nim scanner bootstrap failed: $*" >&2
  exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
trusted_path="${PATH}"

pinned_nim="$1"
case "${pinned_nim}" in
/nix/store/*/bin/nim) ;;
*)
  fail "pinned Nim is not an immutable Nix store wrapper: ${pinned_nim}"
  ;;
esac
[ -L "${pinned_nim}" ] || [ -f "${pinned_nim}" ] ||
  fail "pinned Nim wrapper does not exist: ${pinned_nim}"
[ -x "${pinned_nim}" ] ||
  fail "pinned Nim wrapper is not executable: ${pinned_nim}"
nim_wrapper="$(realpath -e -- "${pinned_nim}")" ||
  fail "could not canonicalize pinned Nim wrapper"
[ -f "${nim_wrapper}" ] && [ ! -L "${nim_wrapper}" ] ||
  fail "canonical Nim wrapper is not a regular non-symlink file: ${nim_wrapper}"
case "${nim_wrapper}" in
/nix/store/*/bin/*nim) ;;
*) fail "canonical Nim wrapper escaped its immutable Nix store package: ${nim_wrapper}" ;;
esac

scanner_source="$(realpath -e -- "$2" 2>/dev/null)" ||
  fail "scanner source does not exist: $2"
[ -f "${scanner_source}" ] && [ ! -L "${scanner_source}" ] ||
  fail "scanner source is not a regular non-symlink file: ${scanner_source}"

output_argument="$3"
[ -n "${output_argument}" ] || fail "scanner output must not be empty"
output_parent="$(dirname "${output_argument}")"
mkdir -p "${output_parent}"
output_parent="$(realpath -e -- "${output_parent}")" ||
  fail "could not canonicalize scanner output directory"
scanner_output="${output_parent}/$(basename "${output_argument}")"

bootstrap_root="$4"
[ -n "${bootstrap_root}" ] || fail "private bootstrap root must not be empty"
bootstrap_root="$(realpath -e -- "${bootstrap_root}" 2>/dev/null)" ||
  fail "private bootstrap root does not exist: $4"
[ -d "${bootstrap_root}" ] && [ ! -L "${bootstrap_root}" ] ||
  fail "private bootstrap root is not a non-symlink directory: ${bootstrap_root}"
[ -z "$(find "${bootstrap_root}" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
  fail "private bootstrap root is not empty: ${bootstrap_root}"
permissions="$(stat -c '%a' "${bootstrap_root}" 2>/dev/null ||
  stat -f '%Lp' "${bootstrap_root}")"
[ "${permissions}" = "700" ] ||
  fail "private bootstrap root must have mode 0700, found ${permissions}"

private_home="${bootstrap_root}/home"
private_tmp="${bootstrap_root}/tmp"
private_xdg="${bootstrap_root}/xdg"
nimcache="${bootstrap_root}/nimcache"
mkdir "${private_home}" "${private_tmp}" "${private_xdg}" "${nimcache}"
chmod 700 "${private_home}" "${private_tmp}" "${private_xdg}" "${nimcache}"
copied_source="${bootstrap_root}/nim_ref_token_scanner.nim"
cp "${scanner_source}" "${copied_source}"
chmod 600 "${copied_source}"
candidate="${bootstrap_root}/nim_ref_token_scanner"
deps="${nimcache}/nim_ref_token_scanner.deps"
dump="${bootstrap_root}/nim-dump.json"

run_pinned_nim() {
  (
    cd "${bootstrap_root}"
    env -i \
      HOME="${private_home}" \
      TMPDIR="${private_tmp}" \
      XDG_CONFIG_HOME="${private_xdg}" \
      PATH="${trusted_path}" \
      "${nim_wrapper}" "$@"
  )
}

run_pinned_nim \
  dump \
  --dump.format:json \
  --skipCfg:on \
  --skipUserCfg:on \
  --skipParentCfg:on \
  --skipProjCfg:on \
  "${copied_source}" \
  >"${dump}"

nim_root="$(
  sed -n 's/.*"prefixdir":"\([^"]*\)".*/\1/p' "${dump}"
)"
[ -n "${nim_root}" ] ||
  fail "pinned Nim wrapper did not report its unwrapped prefix"
[ "$(grep -o '"prefixdir":"' "${dump}" | wc -l | tr -d ' ')" = "1" ] ||
  fail "pinned Nim wrapper reported an ambiguous unwrapped prefix"
canonical_nim_root="$(realpath -e -- "${nim_root}" 2>/dev/null)" ||
  fail "reported Nim compiler root does not exist: ${nim_root}"
[ "${nim_root}" = "${canonical_nim_root}" ] ||
  fail \
    "reported Nim compiler root is not canonical: ${nim_root} (canonical: ${canonical_nim_root})"
nim_root="${canonical_nim_root}"
case "${nim_root}" in
/nix/store/*-nim-unwrapped-*/nim) ;;
*) fail "reported Nim compiler root is not an immutable unwrapped Nix Nim root: ${nim_root}" ;;
esac
[ -d "${nim_root}/compiler" ] && [ ! -L "${nim_root}/compiler" ] &&
  [ -f "${nim_root}/compiler/lexer.nim" ] &&
  [ -d "${nim_root}/lib" ] && [ ! -L "${nim_root}/lib" ] ||
  fail "reported Nim compiler root lacks exact compiler and library sources: ${nim_root}"

compiler_arguments=(
  c
  --skipCfg:on
  --skipUserCfg:on
  --skipParentCfg:on
  --skipProjCfg:on
  --cc:clang
  --mm:arc
  --hints:off
  --warnings:off
  --path:"${nim_root}"
  --nimcache:"${nimcache}"
  --out:"${candidate}"
)

run_pinned_nim \
  "${compiler_arguments[@]}" \
  --genScript:on \
  "${copied_source}"
[ -f "${deps}" ] ||
  fail "pinned Nim compiler did not emit scanner dependency manifest: ${deps}"

bash "${script_dir}/validate_nim_scanner_deps.sh" \
  "${deps}" "${copied_source}" "${nim_root}" >&2

run_pinned_nim "${compiler_arguments[@]}" "${copied_source}"
[ -s "${candidate}" ] && [ -x "${candidate}" ] ||
  fail "pinned Nim compiler did not build an executable scanner"
install -m 0755 "${candidate}" "${scanner_output}"

printf '%s\n' "${nim_root}"
