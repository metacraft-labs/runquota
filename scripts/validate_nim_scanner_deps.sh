#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo \
    "usage: validate_nim_scanner_deps.sh <compiler-deps> <copied-source> <nim-root>" \
    >&2
  exit 2
fi

fail() {
  echo "Nim scanner dependency validation failed: $*" >&2
  exit 1
}

canonical_existing() {
  local path="$1"
  local description="$2"
  local canonical

  [ -n "${path}" ] || fail "${description} must not be empty"
  [ "${path#/}" != "${path}" ] ||
    fail "${description} is not absolute: ${path}"
  canonical="$(realpath -e -- "${path}" 2>/dev/null)" ||
    fail "${description} does not exist: ${path}"
  [ "${path}" = "${canonical}" ] ||
    fail "${description} is not canonical: ${path} (canonical: ${canonical})"
  printf '%s\n' "${canonical}"
}

is_within() {
  local path="$1"
  local root="$2"
  [ "${path}" = "${root}" ] || [ "${path#"${root}/"}" != "${path}" ]
}

deps="$(canonical_existing "$1" "compiler dependency manifest")"
source="$(canonical_existing "$2" "copied scanner source")"
nim_root="$(canonical_existing "$3" "Nim compiler root")"

[ -f "${deps}" ] && [ ! -L "${deps}" ] ||
  fail "compiler dependency manifest is not a regular non-symlink file: ${deps}"
[ -r "${deps}" ] ||
  fail "compiler dependency manifest is not readable: ${deps}"
[ -s "${deps}" ] ||
  fail "compiler dependency manifest is empty: ${deps}"
[ -f "${source}" ] && [ ! -L "${source}" ] ||
  fail "copied scanner source is not a regular non-symlink file: ${source}"
[ -d "${nim_root}" ] && [ ! -L "${nim_root}" ] ||
  fail "Nim compiler root is not a non-symlink directory: ${nim_root}"

case "${nim_root}" in
/nix/store/*-nim-unwrapped-*/nim) ;;
*) fail "Nim compiler root is not an immutable unwrapped Nix Nim root: ${nim_root}" ;;
esac

compiler_root="${nim_root}/compiler"
lib_root="${nim_root}/lib"
compiler_root="$(canonical_existing "${compiler_root}" "Nim compiler source root")"
lib_root="$(canonical_existing "${lib_root}" "Nim standard-library root")"
[ -d "${compiler_root}" ] && [ ! -L "${compiler_root}" ] ||
  fail "Nim compiler source root is not a non-symlink directory: ${compiler_root}"
[ -d "${lib_root}" ] && [ ! -L "${lib_root}" ] ||
  fail "Nim standard-library root is not a non-symlink directory: ${lib_root}"

if od -An -v -t u1 -- "${deps}" |
  awk '{ for (i = 1; i <= NF; i++) if ($i == 0 || $i == 13) exit 1 }'; then
  :
else
  fail "compiler dependency manifest contains a NUL or carriage-return byte"
fi

required_modules=(
  idents.nim
  lexer.nim
  lineinfos.nim
  llstream.nim
  options.nim
  pathutils.nim
)
declare -A required_seen=()
declare -A dependency_seen=()
source_seen=0
dependency_count=0

while IFS= read -r dependency || [ -n "${dependency}" ]; do
  dependency_count=$((dependency_count + 1))
  [ -n "${dependency}" ] ||
    fail "compiler dependency manifest contains a blank path"
  [ "${dependency#/}" != "${dependency}" ] ||
    fail "compiler dependency path is not absolute: ${dependency}"
  [ -f "${dependency}" ] && [ ! -L "${dependency}" ] ||
    fail "compiler dependency is not a regular non-symlink file: ${dependency}"

  canonical="$(realpath -e -- "${dependency}" 2>/dev/null)" ||
    fail "compiler dependency does not exist: ${dependency}"
  [ "${dependency}" = "${canonical}" ] ||
    fail \
      "compiler dependency path is not canonical: ${dependency} (canonical: ${canonical})"
  [ -z "${dependency_seen["${canonical}"]+present}" ] ||
    fail "compiler dependency manifest contains a duplicate: ${canonical}"
  dependency_seen["${canonical}"]=1

  if [ "${canonical}" = "${source}" ]; then
    source_seen=1
    continue
  fi

  if is_within "${canonical}" "${compiler_root}"; then
    relative="${canonical#"${compiler_root}/"}"
    for module in "${required_modules[@]}"; do
      if [ "${relative}" = "${module}" ]; then
        required_seen["${module}"]=1
      fi
    done
  elif ! is_within "${canonical}" "${lib_root}"; then
    fail \
      "compiler dependency is outside the copied source and exact Nim roots: ${canonical}"
  fi
done <"${deps}"

[ "${dependency_count}" -gt 0 ] ||
  fail "compiler dependency manifest contains no paths"
[ "${source_seen}" -eq 1 ] ||
  fail "compiler dependency manifest does not contain the copied scanner source: ${source}"
for module in "${required_modules[@]}"; do
  expected="${compiler_root}/${module}"
  [ -f "${expected}" ] && [ ! -L "${expected}" ] ||
    fail "required compiler module is not a regular non-symlink file: ${expected}"
  [ -n "${required_seen["${module}"]+present}" ] ||
    fail "compiler dependency manifest is missing required compiler module: ${expected}"
done

echo "Nim scanner dependency manifest authority validated"
