#!/usr/bin/env bash
# THE STATIC-HELPER GATE UNDER THE TOOL-STORE AUTHORITY: the same checks as
# `check_static_helpers.sh`, for a reprobuild dev shell (`repro exec -- just
# test`) rather than `nix develop`.
#
# WHAT THE GATE CHECKS does not change with the authority: every library in
# `libs/static_helpers.txt` compiles with `--mm:arc --app:staticlib`, and no
# module in its compiler-reported dependency closure contains a Nim `ref`
# token, as judged by a scanner built from the compiler's own lexer. What
# changes is how the gate knows WHICH compiler and WHICH source it ran:
#
#   Nix arm (flake.nix `staticHelperGate`)   tool-store arm (this script)
#   --------------------------------------   ---------------------------------
#   Nim: a /nix/store path baked into the    Nim: the dev shell's `nim`, whose
#     generated wrapper                        tool-store receipt must carry the
#                                              identity pinned in
#                                              `static_helper_gate_toolstore.pins`;
#                                              the release archive is hashed
#                                              against the pin and the compiler
#                                              actually run is a FRESH
#                                              extraction of those bytes
#   C compiler and shell tools: store paths  gcc, and the Git-for-Windows
#     on a pinned PATH                         bash and coreutils this script
#                                              runs under: receipts pinned the
#                                              same way
#   Source: the flake's /nix/store copy,     Source: `git archive` of the
#     checked for writable paths               tracked tree (the index plus
#                                              work-tree edits -- what the flake
#                                              copies), whose tree ids are
#                                              re-verified with git BEFORE and
#                                              AFTER every check
#   Environment: `env -i` + store PATH       Environment: `env -i` + the
#                                              verified toolchain's PATH
#
# So identity is established by CONTENT -- a SHA-256 in a committed file, a
# git tree id -- where the Nix arm establishes it by store path. A hostile
# environment can make this script REFUSE (put a toolchain with another
# identity first on PATH) but cannot make it USE one: the only thing taken
# from the caller's PATH is where the dev shell's `nim`, `gcc` and `git` are,
# and each is then verified; every tool this script itself runs comes from
# the verified Git-for-Windows root or is a Windows system component named by
# its absolute `%SystemRoot%` path.
#
# Everything after the authority is established runs in
# `static_helper_gate_toolstore.nim`, compiled here from the SNAPSHOT by the
# freshly extracted compiler: the scanner bootstrap and its dependency-
# manifest validation, the gate's own regression suite, and the per-library
# loop. Nothing is skipped on any path through it; a check this arm cannot
# perform is a refusal.
#
# usage: static_helper_gate_toolstore.sh [--print-authority]
#   --print-authority  establish and print the authority, then stop. The
#                      regression suite re-runs this under hostile
#                      environments to show the answer cannot be redirected.
set -euo pipefail

fail() {
  echo "RunQuota static-helper gate (tool-store authority) refusal: $*" >&2
  exit 1
}

print_authority=0
case "$#:${1:-}" in
0:) ;;
1:--print-authority) print_authority=1 ;;
*)
  echo "usage: static_helper_gate_toolstore.sh [--print-authority]" >&2
  exit 2
  ;;
esac

# ---------------------------------------------------------------------------
# Until the shell's own root is verified, NOTHING outside bash builtins runs.
# ---------------------------------------------------------------------------

case "${OSTYPE:-}" in
msys* | cygwin*) host_os=windows ;;
linux*) host_os=linux ;;
darwin*) host_os=macos ;;
*) fail "unrecognised host: OSTYPE=${OSTYPE:-}" ;;
esac
case "${HOSTTYPE:-}" in
x86_64 | amd64) host_arch=x86_64 ;;
aarch64 | arm64) host_arch=aarch64 ;;
*) fail "unrecognised host architecture: HOSTTYPE=${HOSTTYPE:-}" ;;
esac
host="${host_os}-${host_arch}"

if [ "${host_os}" != windows ]; then
  # Stated, not assumed: the arm exists for the host whose dev shell
  # provisions from tool-store archives. On Linux and macOS the repro dev
  # shell IS the flake's, and the flake's gate is the authority there.
  fail "no tool-store authority on ${host}: the repro dev shell here is the" \
    "flake's (repro.nim useFlakeDevShell), whose runquota-static-helper-gate" \
    "runs this gate under the Nix authority -- run it there"
fi

backslash='\'
script_path="${BASH_SOURCE[0]//"${backslash}"//}"
case "${script_path}" in
*/*) script_dir="${script_path%/*}" ;;
*) script_dir=. ;;
esac
script_dir="$(cd "${script_dir}" && pwd -P)"
repo_root="$(cd "${script_dir}/.." && pwd -P)"
pins="${script_dir}/static_helper_gate_toolstore.pins"
[ -f "${pins}" ] || fail "pin file is missing: ${pins}"

pinned() {
  # The ONE line for this host and tool. Zero or two are both refusals: an
  # ambiguous pin is not a pin.
  local tool="$1" line h t identity rest found="" count=0
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in
    "" | \#*) continue ;;
    esac
    read -r h t identity rest <<<"${line}"
    if [ "${h}" = "${host}" ] && [ "${t}" = "${tool}" ]; then
      found="${identity}"
      count=$((count + 1))
    fi
  done <"${pins}"
  [ "${count}" -eq 1 ] || fail "no single ${tool} pin for ${host} in ${pins}"
  case "${found}" in
  tarball:*:sha256:*) ;;
  *) fail "pinned ${tool} identity is not a sha256 tarball identity: ${found}" ;;
  esac
  printf '%s\n' "${found}"
}

receipt_field() {
  # One string field of a `.reprobuild-tarball-receipt.json`, read with
  # builtins only. The receipt is reprobuild's, one field per line; a field
  # that is absent, or present twice, is a receipt this script cannot vouch
  # for.
  local receipt="$1" field="$2" line value="" count=0
  [ -f "${receipt}" ] || fail "no receipt at ${receipt}"
  while IFS= read -r line || [ -n "${line}" ]; do
    line="${line%$'\r'}"
    if [[ "${line}" =~ ^[[:space:]]*\"${field}\":[[:space:]]*\"([^\"]*)\",?[[:space:]]*$ ]]; then
      value="${BASH_REMATCH[1]}"
      count=$((count + 1))
    elif [[ "${line}" =~ ^[[:space:]]*\"${field}\":[[:space:]]*([0-9]+),?[[:space:]]*$ ]]; then
      value="${BASH_REMATCH[1]}"
      count=$((count + 1))
    fi
  done <"${receipt}"
  [ "${count}" -eq 1 ] || fail "receipt ${receipt} has no single \"${field}\""
  printf '%s\n' "${value}"
}

git_pin="$(pinned git)"

# THE SHELL THIS RUNS UNDER. The dev shell's bash is Git for Windows, whose
# MSYS root `/` is the tool-store prefix it was realised into, receipt and
# all; `/usr/bin` below it is where every coreutil this script uses comes
# from. Verified here, with builtins, before any of them runs.
[ -f /.reprobuild-tarball-receipt.json ] ||
  fail "this script runs under a shell that is not a reprobuild tool-store" \
    "prefix (its MSYS root has no .reprobuild-tarball-receipt.json): run it" \
    "under the repro dev shell's bash (repro exec -- just test)"
shell_lock="$(receipt_field /.reprobuild-tarball-receipt.json lockIdentity)" ||
  exit 1
[ "${shell_lock}" = "${git_pin}" ] ||
  fail "this script runs under a shell whose MSYS root is ${shell_lock}, not" \
    "the pinned ${git_pin}: run it under the repro dev shell's bash" \
    "(repro exec -- just test)"
caller_path="${PATH}"
system_root="${SYSTEMROOT:-${SystemRoot:-}}"
[ -n "${system_root}" ] || fail "SYSTEMROOT is not set; cannot name Windows system tools"
PATH="/usr/bin"
system32="$(cygpath -u "${system_root}")/System32"
export PATH="/usr/bin:${system32}"
system_tar="${system32}/tar.exe"
system_icacls="${system32}/icacls.exe"
system_whoami="${system32}/whoami.exe"
for tool in "${system_tar}" "${system_icacls}" "${system_whoami}"; do
  [ -x "${tool}" ] || fail "no ${tool} (Windows 10 1803 or later ships every one)"
done

resolve_prefix() {
  # The tool-store prefix the dev shell's `$2` comes from, verified to carry
  # the identity pinned for `$1`. Prints the prefix root.
  local tool="$1" program="$2" expected="$3" exe dir prefix="" lock method
  exe="$(PATH="${caller_path}" type -P "${program}")" ||
    fail "${program} is not on PATH; run the gate inside the repro dev shell" \
      "(repro exec -- just test), which provisions it"
  exe="$(realpath -e -- "${exe}")" || fail "cannot canonicalise ${program}"
  dir="${exe%/*}"
  # A prefix's executables sit at most three levels below its root
  # (`bin/`, `cmd/`, `mingw64/bin/`, `usr/bin/`).
  for _ in 1 2 3 4; do
    if [ -f "${dir}/.reprobuild-tarball-receipt.json" ]; then
      prefix="${dir}"
      break
    fi
    dir="${dir%/*}"
  done
  [ -n "${prefix}" ] ||
    fail "${program} on PATH (${exe}) is not in a reprobuild tool-store prefix:" \
      "no .reprobuild-tarball-receipt.json above it"
  method="$(receipt_field "${prefix}/.reprobuild-tarball-receipt.json" installMethod)" ||
    exit 1
  [ "${method}" = tarball ] ||
    fail "${program} on PATH comes from a ${method} prefix, not a tarball one: ${prefix}"
  lock="$(receipt_field "${prefix}/.reprobuild-tarball-receipt.json" lockIdentity)" ||
    exit 1
  [ "${lock}" = "${expected}" ] ||
    fail "${program} on PATH (${exe}) is ${lock}; the gate is pinned to" \
      "${expected} (scripts/static_helper_gate_toolstore.pins, ${tool})." \
      "If the dev shell's toolchain changed on purpose, change that pin"
  printf '%s %s\n' "${prefix}" "${exe}"
}

nim_pin="$(pinned nim)"
gcc_pin="$(pinned gcc)"
nim_sha="${nim_pin##*:sha256:}"

read -r nim_prefix _ <<<"$(resolve_prefix nim nim "${nim_pin}")"
read -r _ gcc_exe <<<"$(resolve_prefix gcc gcc "${gcc_pin}")"
read -r _ git_exe <<<"$(resolve_prefix git git "${git_pin}")"
[ -n "${nim_prefix}" ] && [ -n "${gcc_exe}" ] && [ -n "${git_exe}" ] || exit 1

# THE ARCHIVE, AND ITS HASH. The receipt is a claim a mutable prefix makes
# about itself; the archive's bytes are what the pin is a hash of. A prefix
# lives at <tool-store>/prefixes/<name>/<id>, and reprobuild keeps the archive
# it realised from at <tool-store>/downloads/<sha256>.archive.
tool_store="$(cd "${nim_prefix}/../../.." && pwd -P)"
nim_archive="${tool_store}/downloads/${nim_sha}.archive"
[ -f "${nim_archive}" ] ||
  fail "the pinned Nim archive is not in the tool store's download cache:" \
    "${nim_archive}. Re-provision the dev shell (repro exec -- true) so it is" \
    "fetched and verified again"
archive_sha="$(sha256sum -- "${nim_archive}")"
archive_sha="${archive_sha%% *}"
[ "${archive_sha}" = "${nim_sha}" ] ||
  fail "the Nim archive ${nim_archive} hashes to ${archive_sha}, not the pinned" \
    "${nim_sha}; refusing a toolchain whose bytes are not the pinned ones"
nim_strip="$(receipt_field "${nim_prefix}/.reprobuild-tarball-receipt.json" stripComponents)" ||
  exit 1

# THE SOURCE: the tracked tree, as git holds it. A private COPY of the index
# is refreshed from the work tree for tracked files only (`add -u`), so the
# tree it writes is what the flake's `./.` copies -- every file git tracks,
# staged new ones included, with its work-tree content, and never an
# untracked one -- without touching the real index, the work tree or any ref.
# `core.autocrlf=false` everywhere, so the snapshot's bytes are the blobs'
# bytes and a re-hash of it is comparable.
git_config=(-c core.autocrlf=false -c core.safecrlf=false)
source_index="$(mktemp)"
trap 'rm -f "${source_index}"' EXIT
real_index="$("${git_exe}" -C "${repo_root}" rev-parse --path-format=absolute --git-path index)" ||
  fail "cannot locate the index of ${repo_root}"
cp -- "${real_index}" "${source_index}" || fail "cannot copy the index ${real_index}"
GIT_INDEX_FILE="${source_index}" "${git_exe}" -C "${repo_root}" "${git_config[@]}" \
  add -u -- . || fail "cannot stage tracked changes into a private index"
source_tree="$(GIT_INDEX_FILE="${source_index}" "${git_exe}" -C "${repo_root}" \
  "${git_config[@]}" write-tree)" || fail "cannot write the source tree"
source_paths=(libs scripts tests/fixtures/static-helper-ref-scanner)
source_trees=()
for path in "${source_paths[@]}"; do
  tree="$("${git_exe}" -C "${repo_root}" rev-parse --verify "${source_tree}:${path}")" ||
    fail "the source tree has no ${path}"
  source_trees+=("${path}=${tree}")
done
git_common_dir="$("${git_exe}" -C "${repo_root}" rev-parse --path-format=absolute --git-common-dir)"

authority="$(
  printf 'authority=toolstore\nhost=%s\n' "${host}"
  printf 'shell=%s\n' "${shell_lock}"
  printf 'nim=%s\nnim-archive-sha256=%s\n' "${nim_pin}" "${archive_sha}"
  printf 'gcc=%s\ngit=%s\n' "${gcc_pin}" "${git_pin}"
  printf 'source-tree=%s\n' "${source_tree}"
  for entry in "${source_trees[@]}"; do printf 'source-subtree=%s\n' "${entry}"; done
)"
if [ "${print_authority}" -eq 1 ]; then
  printf '%s\n' "${authority}"
  exit 0
fi

# THE WORK ROOT, private to this account. On Windows a directory under a
# checkout inherits the checkout's ACL, and a drive root's default lets every
# authenticated user modify what is created below it; the Nix arm's `chmod
# 700` becomes an owner-only DACL, which the driver verifies before trusting
# anything placed in it.
work_root="${repo_root}/build/static-helper-gate"
if [ -e "${work_root}" ]; then
  chmod -R u+w "${work_root}" 2>/dev/null || true
  rm -rf "${work_root}"
fi
mkdir -p "${work_root}"
me_sid="$("${system_whoami}" //user //fo csv //nh)"
me_sid="${me_sid//$'\r'/}"
me_sid="${me_sid//\"/}"
me_sid="${me_sid##*,}"
case "${me_sid}" in
S-1-*) ;;
*) fail "cannot read this account's SID from whoami: ${me_sid}" ;;
esac
"${system_icacls}" "$(cygpath -w "${work_root}")" //inheritance:r //grant:r \
  "*${me_sid}:(OI)(CI)F" >/dev/null ||
  fail "cannot make ${work_root} private to ${me_sid}"

nim_root="${work_root}/toolchain/nim"
snapshot="${work_root}/source"
driver_root="${work_root}/driver"
private_home="${work_root}/private/home"
private_tmp="${work_root}/private/tmp"
mkdir -p "${nim_root}" "${snapshot}" "${driver_root}/nimcache" \
  "${private_home}" "${private_tmp}"
win() { cygpath -w "$1"; }

"${system_tar}" -x -f "$(win "${nim_archive}")" \
  --strip-components "${nim_strip}" -C "$(win "${nim_root}")" ||
  fail "extracting ${nim_archive} failed"
[ -f "${nim_root}/bin/nim.exe" ] && [ -f "${nim_root}/compiler/lexer.nim" ] &&
  [ -d "${nim_root}/lib" ] ||
  fail "the extracted Nim root lacks bin/nim.exe, compiler/lexer.nim or lib/"

"${git_exe}" -C "${repo_root}" "${git_config[@]}" archive --format=tar \
  "${source_tree}" -- "${source_paths[@]}" |
  "${system_tar}" -x -f - -C "$(win "${snapshot}")" ||
  fail "materialising the source snapshot failed"
# A guard, not the proof: the proof is the tree-id verification the driver
# repeats before and after every check.
chmod -R a-w "${snapshot}"

# THE DRIVER, compiled from the SNAPSHOT's copy -- never the checkout's -- in
# an otherwise empty directory, so no neighbouring module can shadow an
# import, with the environment rebuilt from nothing.
nim_exe="${nim_root}/bin/nim.exe"
gcc_bin="${gcc_exe%/*}"
git_bin="${git_exe%/*}"
trusted_path="${nim_root}/bin:${gcc_bin}:${git_bin}:${system32}"
cp "${snapshot}/scripts/static_helper_gate_toolstore.nim" "${driver_root}/gate.nim"
chmod u+w "${driver_root}/gate.nim"
run_nim() {
  env -i \
    SYSTEMROOT="${system_root}" \
    TEMP="$(win "${private_tmp}")" \
    TMP="$(win "${private_tmp}")" \
    USERPROFILE="$(win "${private_home}")" \
    HOME="$(win "${private_home}")" \
    APPDATA="$(win "${private_home}")" \
    LOCALAPPDATA="$(win "${private_home}")" \
    PATH="${trusted_path}" \
    LC_ALL=C \
    LANG=C \
    "${nim_exe}" "$@"
}
driver_arguments=(
  c
  --skipCfg:on --skipUserCfg:on --skipParentCfg:on --skipProjCfg:on
  --cc:gcc --mm:arc --threads:on --hints:off --warnings:off
  --path:"$(win "${snapshot}/libs/runquota_host_windows/src")"
  --nimcache:"$(win "${driver_root}/nimcache")"
  --out:"$(win "${driver_root}/gate.exe")"
)
# The compiler's output goes to a log, shown only on failure: gcc's
# diagnostics about Nim's generated C are not the gate's findings.
driver_log="${driver_root}/compile.log"
run_nim "${driver_arguments[@]}" --genScript:on "$(win "${driver_root}/gate.nim")"   >"${driver_log}" 2>&1 || {
  cat "${driver_log}" >&2
  fail "compiling the gate driver's dependency manifest failed"
}
driver_deps="${driver_root}/nimcache/gate.deps"
[ -s "${driver_deps}" ] || fail "the compiler emitted no dependency manifest for the driver"
# EVERY module the driver was built from is the copied driver, the one
# snapshot module it imports, or the fresh Nim root's standard library.
allowed_driver="$(win "${driver_root}/gate.nim")"
allowed_module="$(win "${snapshot}/libs/runquota_host_windows/src/runquota_host_windows/security.nim")"
allowed_lib="$(win "${nim_root}/lib")\\"
while IFS= read -r dependency || [ -n "${dependency}" ]; do
  case "${dependency}" in
  *$'\r'* | "") fail "driver dependency manifest has a blank or CR-terminated line" ;;
  *'\..\'* | *'\.\'* | */*) fail "driver dependency is not canonical: ${dependency}" ;;
  esac
  [ "${dependency}" = "${allowed_driver}" ] && continue
  [ "${dependency}" = "${allowed_module}" ] && continue
  case "${dependency}" in
  "${allowed_lib}"*) continue ;;
  esac
  fail "the gate driver depends on a module outside the snapshot and the" \
    "fresh Nim library: ${dependency}"
done <"${driver_deps}"
run_nim "${driver_arguments[@]}" "$(win "${driver_root}/gate.nim")"   >"${driver_log}" 2>&1 || {
  cat "${driver_log}" >&2
  fail "compiling the gate driver failed"
}

authority_file="${work_root}/authority.txt"
printf '%s\n' "${authority}" >"${authority_file}"

driver_args=(
  gate
  --host "${host}"
  --nim-root "$(win "${nim_root}")"
  --gcc-bin "$(win "${gcc_bin}")"
  --git "$(win "${git_exe}")"
  --repo "$(win "${repo_root}")"
  --git-common-dir "$(win "${git_common_dir}")"
  --source-tree "${source_tree}"
  --snapshot "$(win "${snapshot}")"
  --work "$(win "${work_root}")"
  --owner-sid "${me_sid}"
  --front "$(cygpath -m "${script_dir}/static_helper_gate_toolstore.sh")"
  --bash "$(win "$(realpath -e -- "${BASH}")")"
  --caller-path "$(cygpath -w -p "${caller_path}")"
  --authority-file "$(win "${authority_file}")"
)
for entry in "${source_trees[@]}"; do
  driver_args+=(--subtree "${entry}")
done
rm -f "${source_index}"
trap - EXIT
exec env -i \
  SYSTEMROOT="${system_root}" \
  TEMP="$(win "${private_tmp}")" \
  TMP="$(win "${private_tmp}")" \
  PATH="${trusted_path}" \
  LC_ALL=C \
  LANG=C \
  "${driver_root}/gate.exe" "${driver_args[@]}"
