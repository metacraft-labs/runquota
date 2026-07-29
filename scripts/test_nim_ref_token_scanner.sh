#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 6 ]; then
  echo \
    "usage: test_nim_ref_token_scanner.sh <scanner> <immutable-source-root> <nim-root> <bootstrap-root> <pinned-nim> <gate-wrapper>" \
    >&2
  exit 2
fi

scanner_dir="$(cd "$(dirname "$1")" && pwd -P)"
scanner="${scanner_dir}/$(basename "$1")"
source_root="$2"
nim_root="$3"
nim_lib_root="${nim_root}/lib"
bootstrap_root="$4"
pinned_nim_argument="$5"
pinned_nim="$(realpath -e -- "${pinned_nim_argument}")"
gate_wrapper="$(realpath -e -- "$6")"
fixtures="${source_root}/tests/fixtures/static-helper-ref-scanner"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/runquota-ref-scanner.XXXXXX")"
work_dir="$(realpath -e -- "${work_dir}")"
trap 'chmod -R u+rwX "${work_dir}" 2>/dev/null || true; rm -rf "${work_dir}"' EXIT
bootstrap_script="${source_root}/scripts/bootstrap_nim_ref_token_scanner.sh"
manifest_validator="${source_root}/scripts/validate_nim_scanner_deps.sh"
scanner_source="${source_root}/scripts/nim_ref_token_scanner.nim"
trusted_path="${PATH}"
compiler_home="${work_dir}/compiler-home"
compiler_tmp="${work_dir}/compiler-tmp"
compiler_xdg="${work_dir}/compiler-xdg"
mkdir "${compiler_home}" "${compiler_tmp}" "${compiler_xdg}"
chmod 700 "${compiler_home}" "${compiler_tmp}" "${compiler_xdg}"

test_index=0
last_log=""
last_deps=""

fail() {
  echo "Nim ref token scanner regression failure: $*" >&2
  if [ -n "${last_log}" ] && [ -f "${last_log}" ]; then
    sed -n '1,120p' "${last_log}" >&2
  fi
  exit 1
}

run_pinned_nim() {
  env -i \
    HOME="${compiler_home}" \
    TMPDIR="${compiler_tmp}" \
    XDG_CONFIG_HOME="${compiler_xdg}" \
    PATH="${trusted_path}" \
    LC_ALL=C \
    LANG=C \
    "${pinned_nim}" "$@"
}

expect_success() {
  local description="$1"
  shift
  test_index=$((test_index + 1))
  last_log="${work_dir}/${test_index}-success.log"
  if ! "$@" >"${last_log}" 2>&1; then
    fail "${description} unexpectedly failed"
  fi
}

expect_failure() {
  local description="$1"
  shift
  test_index=$((test_index + 1))
  last_log="${work_dir}/${test_index}-failure.log"
  if "$@" >"${last_log}" 2>&1; then
    fail "${description} unexpectedly succeeded"
  fi
}

assert_findings() {
  local expected_count="$1"
  local source_path="$2"
  shift 2
  local actual_count
  actual_count="$(grep -Fc "Nim ref type token found" "${last_log}" || true)"
  [ "${actual_count}" -eq "${expected_count}" ] ||
    fail "expected ${expected_count} ref findings, found ${actual_count}"
  for line in "$@"; do
    grep -Fq "${source_path}:${line}:" "${last_log}" ||
      fail "missing exact ref finding ${source_path}:${line}"
  done
}

compile_fixture() {
  local source_path="$1"
  local fixture_name
  fixture_name="$(basename "${source_path}" .nim)"
  expect_success \
    "Nim compilation of ${fixture_name}" \
    run_pinned_nim c \
    --skipCfg:on \
    --skipUserCfg:on \
    --skipParentCfg:on \
    --skipProjCfg:on \
    --cc:clang \
    --mm:arc \
    --hints:off \
    --warnings:off \
    --nimcache:"${work_dir}/fixture-cache-${fixture_name}" \
    --out:"${work_dir}/fixture-${fixture_name}" \
    "${source_path}"
}

compile_closure_entry() {
  local case_name="$1"
  local entry="$2"
  shift 2
  local cache="${work_dir}/closure-cache-${case_name}"
  rm -rf "${cache}"
  expect_success \
    "Nim dependency-manifest compilation for ${case_name}" \
    run_pinned_nim c \
    --skipCfg:on \
    --skipUserCfg:on \
    --skipParentCfg:on \
    --skipProjCfg:on \
    --cc:clang \
    --mm:arc \
    --app:staticlib \
    --genScript:on \
    --hints:off \
    --warnings:off \
    --nimcache:"${cache}" \
    --out:"${work_dir}/${case_name}.a" \
    "$@" \
    "${entry}"
  last_deps="${cache}/$(basename "${entry}" .nim).deps"
  [ -f "${last_deps}" ] ||
    fail "Nim did not emit dependency manifest for ${case_name}"
  expect_success \
    "full ARC static-library compilation for ${case_name}" \
    run_pinned_nim c \
    --skipCfg:on \
    --skipUserCfg:on \
    --skipParentCfg:on \
    --skipProjCfg:on \
    --cc:clang \
    --mm:arc \
    --app:staticlib \
    --hints:off \
    --warnings:off \
    --nimcache:"${cache}" \
    --out:"${work_dir}/${case_name}.a" \
    "$@" \
    "${entry}"
  [ -s "${work_dir}/${case_name}.a" ] ||
    fail "Nim did not build the static archive for ${case_name}"
}

case "${source_root}" in
/nix/store/*) ;;
*) fail "authoritative source root is not an immutable Nix store snapshot" ;;
esac
if find "${source_root}" -perm -0222 -print -quit | grep -q .; then
  fail "authoritative source snapshot contains a writable path"
fi

expected_authority="$(
  printf 'nim=%s\nsource=%s\npath=%s\ngate=%s\n' \
    "${pinned_nim_argument}" "${source_root}" "${trusted_path}" "${gate_wrapper}"
)"
authority_report="$("${gate_wrapper}" --print-authority)" ||
  fail "generated gate authority introspection failed"
[ "${authority_report}" = "${expected_authority}" ] ||
  fail "generated gate authority introspection returned unexpected authority"

hostile_bin="${work_dir}/hostile-bin"
hostile_config="${work_dir}/hostile-config"
mkdir "${hostile_bin}" "${hostile_config}"
hostile_authority_report="$(
  env -i \
    RUNQUOTA_PINNED_NIM=/usr/bin/false \
    RUNQUOTA_SOURCE_ROOT="${work_dir}/mutable-source" \
    PATH="${hostile_bin}" \
    HOME="${hostile_config}" \
    XDG_CONFIG_HOME="${hostile_config}" \
    XDG_CONFIG_DIRS="${hostile_config}" \
    NIMBLE_DIR="${hostile_config}" \
    NIM_LIB_PREFIX="${hostile_config}" \
    NIM_CONFIG_DIR="${hostile_config}" \
    REPROBUILD_SRC="${hostile_config}" \
    CC=/usr/bin/false \
    CXX=/usr/bin/false \
    "${gate_wrapper}" --print-authority
)" || fail "generated gate authority introspection failed under hostile environment"
[ "${hostile_authority_report}" = "${expected_authority}" ] ||
  fail "hostile environment redirected generated gate authority"

mutable_source="${work_dir}/mutable-source"
mkdir "${mutable_source}"
expect_failure \
  "authoritative gate refusal of a mutable source root" \
  env -i \
  PATH="${trusted_path}" \
  LC_ALL=C \
  LANG=C \
  bash "${source_root}/scripts/check_static_helpers.sh" \
  "${pinned_nim_argument}" "${mutable_source}" "${gate_wrapper}"
grep -Fq \
  "source root is mutable; the authoritative gate requires a Nix store snapshot" \
  "${last_log}" ||
  fail "mutable source root refusal did not report the authority boundary"

accepted="${fixtures}/accepted.nim"
rejected="${fixtures}/rejected.nim"
style_ref="${fixtures}/style_ref.nim"
mixed_case_ref="${fixtures}/mixed_case_ref.nim"
raw_ref="${fixtures}/raw_trailing_backslash_ref.nim"
generalized_ref="${fixtures}/generalized_trailing_backslash_ref.nim"
numeric_ref="${fixtures}/numeric_suffix_ref.nim"
malformed_string="${work_dir}/malformed_string.nim"
malformed_comment="${work_dir}/malformed_comment.nim"
cp "${fixtures}/malformed_string.nim.fixture" "${malformed_string}"
cp "${fixtures}/malformed_comment.nim.fixture" "${malformed_comment}"

bootstrap_source="${bootstrap_root}/nim_ref_token_scanner.nim"
bootstrap_deps="${bootstrap_root}/nimcache/nim_ref_token_scanner.deps"
expect_success \
  "primary scanner bootstrap dependency authority" \
  bash "${manifest_validator}" \
  "${bootstrap_deps}" "${bootstrap_source}" "${nim_root}"
for expected_authority in \
  "${bootstrap_source}" \
  "${nim_root}/compiler/idents.nim" \
  "${nim_root}/compiler/lexer.nim" \
  "${nim_root}/compiler/lineinfos.nim" \
  "${nim_root}/compiler/llstream.nim" \
  "${nim_root}/compiler/options.nim" \
  "${nim_root}/compiler/pathutils.nim"; do
  grep -Fxq "${expected_authority}" "${bootstrap_deps}" ||
    fail "primary scanner manifest lacks exact authority ${expected_authority}"
done
if grep -Fq "${source_root}/" "${bootstrap_deps}"; then
  fail "primary scanner manifest contains a repository dependency"
fi

expect_failure \
  "missing scanner bootstrap dependency manifest" \
  bash "${manifest_validator}" \
  "${work_dir}/missing-bootstrap.deps" "${bootstrap_source}" "${nim_root}"
: >"${work_dir}/empty-bootstrap.deps"
expect_failure \
  "empty scanner bootstrap dependency manifest" \
  bash "${manifest_validator}" \
  "${work_dir}/empty-bootstrap.deps" "${bootstrap_source}" "${nim_root}"
cp "${bootstrap_deps}" "${work_dir}/unreadable-bootstrap.deps"
chmod 000 "${work_dir}/unreadable-bootstrap.deps"
expect_failure \
  "unreadable scanner bootstrap dependency manifest" \
  bash "${manifest_validator}" \
  "${work_dir}/unreadable-bootstrap.deps" \
  "${bootstrap_source}" "${nim_root}"
chmod 600 "${work_dir}/unreadable-bootstrap.deps"

cp "${bootstrap_deps}" "${work_dir}/duplicate-bootstrap.deps"
printf '%s\n' "${bootstrap_source}" \
  >>"${work_dir}/duplicate-bootstrap.deps"
expect_failure \
  "duplicate scanner bootstrap dependency" \
  bash "${manifest_validator}" \
  "${work_dir}/duplicate-bootstrap.deps" \
  "${bootstrap_source}" "${nim_root}"
awk -v source="${bootstrap_source}" \
  '$0 != source { print }' \
  "${bootstrap_deps}" \
  >"${work_dir}/missing-source-bootstrap.deps"
expect_failure \
  "scanner bootstrap manifest missing copied source" \
  bash "${manifest_validator}" \
  "${work_dir}/missing-source-bootstrap.deps" \
  "${bootstrap_source}" "${nim_root}"
awk -v lexer="${nim_root}/compiler/lexer.nim" \
  '$0 != lexer { print }' \
  "${bootstrap_deps}" \
  >"${work_dir}/missing-lexer-bootstrap.deps"
expect_failure \
  "scanner bootstrap manifest missing exact compiler lexer" \
  bash "${manifest_validator}" \
  "${work_dir}/missing-lexer-bootstrap.deps" \
  "${bootstrap_source}" "${nim_root}"

cp "${bootstrap_deps}" "${work_dir}/blank-bootstrap.deps"
printf '\n' >>"${work_dir}/blank-bootstrap.deps"
expect_failure \
  "blank scanner bootstrap dependency path" \
  bash "${manifest_validator}" \
  "${work_dir}/blank-bootstrap.deps" "${bootstrap_source}" "${nim_root}"
cp "${bootstrap_deps}" "${work_dir}/nul-bootstrap.deps"
printf '\0' >>"${work_dir}/nul-bootstrap.deps"
expect_failure \
  "NUL scanner bootstrap dependency manifest" \
  bash "${manifest_validator}" \
  "${work_dir}/nul-bootstrap.deps" "${bootstrap_source}" "${nim_root}"
awk '{ printf "%s\r\n", $0 }' \
  "${bootstrap_deps}" \
  >"${work_dir}/crlf-bootstrap.deps"
expect_failure \
  "CRLF scanner bootstrap dependency manifest" \
  bash "${manifest_validator}" \
  "${work_dir}/crlf-bootstrap.deps" "${bootstrap_source}" "${nim_root}"

cp "${bootstrap_deps}" "${work_dir}/local-bootstrap.deps"
printf '%s\n' "${scanner_source}" >>"${work_dir}/local-bootstrap.deps"
expect_failure \
  "repository-local scanner bootstrap dependency" \
  bash "${manifest_validator}" \
  "${work_dir}/local-bootstrap.deps" "${bootstrap_source}" "${nim_root}"
other_store_dependency="${pinned_nim}"
cp "${bootstrap_deps}" "${work_dir}/other-store-bootstrap.deps"
printf '%s\n' "${other_store_dependency}" \
  >>"${work_dir}/other-store-bootstrap.deps"
expect_failure \
  "other-store scanner bootstrap dependency" \
  bash "${manifest_validator}" \
  "${work_dir}/other-store-bootstrap.deps" \
  "${bootstrap_source}" "${nim_root}"
cp "${bootstrap_deps}" "${work_dir}/relative-bootstrap.deps"
printf '%s\n' 'compiler/lexer.nim' \
  >>"${work_dir}/relative-bootstrap.deps"
expect_failure \
  "relative scanner bootstrap dependency" \
  bash "${manifest_validator}" \
  "${work_dir}/relative-bootstrap.deps" "${bootstrap_source}" "${nim_root}"
cp "${bootstrap_deps}" "${work_dir}/noncanonical-bootstrap.deps"
printf '%s\n' "${bootstrap_root}/nimcache/../nim_ref_token_scanner.nim" \
  >>"${work_dir}/noncanonical-bootstrap.deps"
expect_failure \
  "noncanonical scanner bootstrap dependency" \
  bash "${manifest_validator}" \
  "${work_dir}/noncanonical-bootstrap.deps" \
  "${bootstrap_source}" "${nim_root}"
ln -s "${bootstrap_source}" "${work_dir}/bootstrap-source-link.nim"
cp "${bootstrap_deps}" "${work_dir}/symlink-bootstrap.deps"
printf '%s\n' "${work_dir}/bootstrap-source-link.nim" \
  >>"${work_dir}/symlink-bootstrap.deps"
expect_failure \
  "symlink scanner bootstrap dependency" \
  bash "${manifest_validator}" \
  "${work_dir}/symlink-bootstrap.deps" "${bootstrap_source}" "${nim_root}"
cp "${bootstrap_deps}" "${work_dir}/missing-dependency-bootstrap.deps"
printf '%s\n' "${work_dir}/missing-bootstrap-source.nim" \
  >>"${work_dir}/missing-dependency-bootstrap.deps"
expect_failure \
  "missing scanner bootstrap dependency" \
  bash "${manifest_validator}" \
  "${work_dir}/missing-dependency-bootstrap.deps" \
  "${bootstrap_source}" "${nim_root}"

missing_pinned_root="${work_dir}/missing-pinned-bootstrap"
wrong_wrapper_root="${work_dir}/wrong-wrapper-bootstrap"
mkdir "${missing_pinned_root}" "${wrong_wrapper_root}"
chmod 700 "${missing_pinned_root}" "${wrong_wrapper_root}"
expect_failure \
  "scanner bootstrap without positional pinned Nim wrapper" \
  bash "${bootstrap_script}" \
  "${scanner_source}" "${work_dir}/unset-wrapper-scanner" \
  "${missing_pinned_root}"
expect_failure \
  "scanner bootstrap with non-store positional Nim wrapper" \
  bash "${bootstrap_script}" \
  /usr/bin/false \
  "${scanner_source}" "${work_dir}/wrong-wrapper-scanner" \
  "${wrong_wrapper_root}"

compile_fixture "${accepted}"
expect_success \
  "comments, literals, ordinary identifiers, and backticked ref" \
  "${scanner}" scan -- "${accepted}"

for specification in \
  "${rejected}:4:10" \
  "${style_ref}:2" \
  "${mixed_case_ref}:2" \
  "${raw_ref}:3" \
  "${generalized_ref}:6" \
  "${numeric_ref}:3"; do
  source_path="${specification%%:*}"
  line_specification="${specification#"${source_path}":}"
  compile_fixture "${source_path}"
  expect_failure \
    "compiler-valid ref syntax in $(basename "${source_path}")" \
    "${scanner}" scan -- "${source_path}"
  IFS=: read -r -a expected_lines <<<"${line_specification}"
  assert_findings "${#expected_lines[@]}" "${source_path}" "${expected_lines[@]}"
done

hostile_project="${work_dir}/hostile-project"
hostile_scripts="${hostile_project}/scripts"
hostile_compiler="${hostile_scripts}/compiler"
hostile_cache="${work_dir}/hostile-unisolated-cache"
hostile_home="${work_dir}/hostile-home"
hostile_tmp="${work_dir}/hostile-tmp"
hostile_xdg="${work_dir}/hostile-xdg"
mkdir -p \
  "${hostile_compiler}" "${hostile_cache}" \
  "${hostile_home}" "${hostile_tmp}" "${hostile_xdg}"
cp "${scanner_source}" "${hostile_scripts}/nim_ref_token_scanner.nim"
cp -R "${nim_root}/compiler/." "${hostile_compiler}/"
awk '
  /^    result\.getIdent\(\$s, hashIgnoreStyle\(\$s\)\)\.id = ord\(s\)$/ {
    print "    if s != wRef:"
    print "      result.getIdent($s, hashIgnoreStyle($s)).id = ord(s)"
    replacements++
    next
  }
  { print }
  END {
    if (replacements != 1) {
      exit 42
    }
  }
' "${nim_root}/compiler/idents.nim" \
  >"${hostile_compiler}/idents.nim.tmp"
mv "${hostile_compiler}/idents.nim.tmp" "${hostile_compiler}/idents.nim"

hostile_unisolated_scanner="${work_dir}/hostile-unisolated-scanner"
expect_success \
  "unisolated scanner compilation under reviewer compiler shadow" \
  env -i \
  HOME="${hostile_home}" \
  TMPDIR="${hostile_tmp}" \
  XDG_CONFIG_HOME="${hostile_xdg}" \
  PATH="${trusted_path}" \
  "${pinned_nim}" c \
  --skipCfg:on \
  --skipUserCfg:on \
  --skipParentCfg:on \
  --skipProjCfg:on \
  --cc:clang \
  --mm:arc \
  --hints:off \
  --warnings:off \
  --path:"${nim_root}" \
  --nimcache:"${hostile_cache}" \
  --out:"${hostile_unisolated_scanner}" \
  "${hostile_scripts}/nim_ref_token_scanner.nim"
expect_success \
  "reviewer compiler shadow evasion reproduction" \
  "${hostile_unisolated_scanner}" scan -- "${style_ref}"

hostile_bootstrap="${work_dir}/hostile-bootstrap"
mkdir "${hostile_bootstrap}"
chmod 700 "${hostile_bootstrap}"
hostile_hardened_scanner="${work_dir}/hostile-hardened-scanner"
test_index=$((test_index + 1))
last_log="${work_dir}/${test_index}-hostile-bootstrap.log"
if ! hostile_report="$(
  RUNQUOTA_PINNED_NIM=/usr/bin/false \
    RUNQUOTA_SOURCE_ROOT="${hostile_project}" \
    HOME="${hostile_project}" \
    XDG_CONFIG_HOME="${hostile_project}/xdg" \
    XDG_CONFIG_DIRS="${hostile_project}/xdg" \
    NIMBLE_DIR="${hostile_project}/nimble" \
    NIM_LIB_PREFIX="${hostile_compiler}" \
    NIM_CONFIG_DIR="${hostile_project}/nim-config" \
    CC=/usr/bin/false \
    CXX=/usr/bin/false \
    bash "${bootstrap_script}" \
    "${pinned_nim_argument}" \
    "${hostile_scripts}/nim_ref_token_scanner.nim" \
    "${hostile_hardened_scanner}" \
    "${hostile_bootstrap}" \
    2>"${last_log}"
)"; then
  fail "isolated scanner bootstrap under reviewer compiler shadow failed"
fi
[ "${hostile_report}" = "${nim_root}" ] ||
  fail "hostile bootstrap reported an unexpected Nim root: ${hostile_report}"
expect_failure \
  "isolated scanner rejects compile-proven ref despite reviewer compiler shadow" \
  "${hostile_hardened_scanner}" scan -- "${style_ref}"
assert_findings 1 "${style_ref}" 2
expect_success \
  "hostile bootstrap dependency authority" \
  bash "${manifest_validator}" \
  "${hostile_bootstrap}/nimcache/nim_ref_token_scanner.deps" \
  "${hostile_bootstrap}/nim_ref_token_scanner.nim" \
  "${nim_root}"
grep -Fxq \
  "${nim_root}/compiler/idents.nim" \
  "${hostile_bootstrap}/nimcache/nim_ref_token_scanner.deps" ||
  fail "hostile bootstrap did not bind exact immutable compiler idents"
if grep -Fq \
  "${hostile_compiler}/" \
  "${hostile_bootstrap}/nimcache/nim_ref_token_scanner.deps"; then
  fail "hostile bootstrap manifest contains reviewer-controlled compiler sources"
fi

expect_failure \
  "multi-file aggregation with compiler-valid ref types" \
  "${scanner}" scan -- \
  "${accepted}" "${style_ref}" "${mixed_case_ref}" "${raw_ref}" \
  "${generalized_ref}" "${numeric_ref}" "${rejected}"
aggregate_count="$(grep -Fc "Nim ref type token found" "${last_log}" || true)"
[ "${aggregate_count}" -eq 7 ] ||
  fail "multi-file scan must report all seven ref tokens"
for exact_finding in \
  "${style_ref}:2:" \
  "${mixed_case_ref}:2:" \
  "${raw_ref}:3:" \
  "${generalized_ref}:6:" \
  "${numeric_ref}:3:" \
  "${rejected}:4:" \
  "${rejected}:10:"; do
  grep -Fq "${exact_finding}" "${last_log}" ||
    fail "multi-file scan missed ${exact_finding}"
done

for malformed in "${malformed_string}" "${malformed_comment}"; do
  expect_failure \
    "Nim compiler rejection of malformed $(basename "${malformed}")" \
    run_pinned_nim check \
    --skipCfg:on \
    --skipUserCfg:on \
    --skipParentCfg:on \
    --skipProjCfg:on \
    --cc:clang \
    --hints:off \
    --warnings:off \
    "${malformed}"
  expect_failure \
    "fail-closed lexical scan of malformed $(basename "${malformed}")" \
    "${scanner}" scan -- "${malformed}"
  grep -Fq "Nim source has lexical errors" "${last_log}" ||
    fail "malformed source did not report a lexical error"
done

cp "${accepted}" "${work_dir}/-leading.nim"
cp "${accepted}" "${work_dir}/source with spaces.nim"
: >"${work_dir}/empty.nim"
test_index=$((test_index + 1))
last_log="${work_dir}/${test_index}-path-boundaries.log"
if ! (
  cd "${work_dir}"
  "${scanner}" scan -- "-leading.nim" "source with spaces.nim" "empty.nim"
) >"${last_log}" 2>&1; then
  fail "leading-dash, whitespace, or empty valid source path failed"
fi

expect_failure "empty scan input" "${scanner}" scan --
expect_failure \
  "missing scan delimiter" \
  "${scanner}" scan "${accepted}"
expect_failure \
  "missing source read error" \
  "${scanner}" scan -- "${work_dir}/missing.nim"
cp "${accepted}" "${work_dir}/unreadable.nim"
chmod 000 "${work_dir}/unreadable.nim"
expect_failure \
  "unreadable source error" \
  "${scanner}" scan -- "${work_dir}/unreadable.nim"
chmod 600 "${work_dir}/unreadable.nim"

fake_repo="${work_dir}/repo with spaces"
helper_src="${fake_repo}/libs/helper/src"
shared_src="${fake_repo}/shared"
external_src="${work_dir}/external"
mkdir -p \
  "${helper_src}" "${shared_src}/linked_dir" "${external_src}" \
  "${work_dir}/empty-root"

printf '%s\n' \
  'import std/os' \
  'const acceptedClosure = DirSep' \
  >"${helper_src}/accepted_entry.nim"
compile_closure_entry \
  "accepted-closure" "${helper_src}/accepted_entry.nim"
accepted_deps="${last_deps}"
expect_success \
  "repository sources plus exact trusted Nim standard library" \
  "${scanner}" closure \
  "${fake_repo}" "${nim_lib_root}" \
  "${helper_src}/accepted_entry.nim" "${accepted_deps}"

printf '%s\n' \
  'type' \
  '  OutsideSourceReference = r_e_f object' \
  '    value: int' \
  >"${shared_src}/outside_module.nim"
printf '%s\n' \
  'import outside_module' \
  'const importsOutsideSource = true' \
  >"${helper_src}/outside_entry.nim"
compile_closure_entry \
  "outside-src" "${helper_src}/outside_entry.nim" \
  --path:"${shared_src}"
expect_failure \
  "ordinary compiler-followed module outside src" \
  "${scanner}" closure \
  "${fake_repo}" "${nim_lib_root}" \
  "${helper_src}/outside_entry.nim" "${last_deps}"
grep -Fq "${shared_src}/outside_module.nim:2:" "${last_log}" ||
  fail "outside-src dependency was not scanned"

printf '%s\n' \
  'type' \
  '  SymlinkedFileReference = ref object' \
  '    value: int' \
  >"${shared_src}/file_target.nim"
ln -s "../../../shared/file_target.nim" "${helper_src}/file_link.nim"
printf '%s\n' \
  'import file_link' \
  'const importsSymlinkedFile = true' \
  >"${helper_src}/file_link_entry.nim"
compile_closure_entry \
  "symlink-file" "${helper_src}/file_link_entry.nim"
expect_failure \
  "compiler-followed symlinked Nim file" \
  "${scanner}" closure \
  "${fake_repo}" "${nim_lib_root}" \
  "${helper_src}/file_link_entry.nim" "${last_deps}"
grep -Fq "${shared_src}/file_target.nim:2:" "${last_log}" ||
  fail "symlinked file target was not scanned canonically"

printf '%s\n' \
  'type' \
  '  SymlinkedDirectoryReference = ref object' \
  '    value: int' \
  >"${shared_src}/linked_dir/dir_module.nim"
ln -s "../../../shared/linked_dir" "${helper_src}/linked_dir"
printf '%s\n' \
  'import linked_dir/dir_module' \
  'const importsSymlinkedDirectory = true' \
  >"${helper_src}/dir_link_entry.nim"
compile_closure_entry \
  "symlink-directory" "${helper_src}/dir_link_entry.nim"
expect_failure \
  "compiler-followed symlinked Nim directory" \
  "${scanner}" closure \
  "${fake_repo}" "${nim_lib_root}" \
  "${helper_src}/dir_link_entry.nim" "${last_deps}"
grep -Fq "${shared_src}/linked_dir/dir_module.nim:2:" "${last_log}" ||
  fail "symlinked directory target was not scanned canonically"

printf '%s\n' \
  'type ExternalButClean = object' \
  >"${external_src}/escape_module.nim"
ln -s "${external_src}/escape_module.nim" "${helper_src}/escape_module.nim"
printf '%s\n' \
  'import escape_module' \
  'const importsEscapedModule = true' \
  >"${helper_src}/escape_entry.nim"
compile_closure_entry \
  "symlink-escape" "${helper_src}/escape_entry.nim"
expect_failure \
  "symlink escape outside repository and trusted roots" \
  "${scanner}" closure \
  "${fake_repo}" "${nim_lib_root}" \
  "${helper_src}/escape_entry.nim" "${last_deps}"
grep -Fq "outside repository and trusted Nim roots" "${last_log}" ||
  fail "symlink escape did not fail the root policy"

expect_failure \
  "missing compiler dependency manifest" \
  "${scanner}" closure \
  "${fake_repo}" "${nim_lib_root}" \
  "${helper_src}/accepted_entry.nim" "${work_dir}/missing.deps"
: >"${work_dir}/empty.deps"
expect_failure \
  "empty compiler dependency manifest" \
  "${scanner}" closure \
  "${fake_repo}" "${nim_lib_root}" \
  "${helper_src}/accepted_entry.nim" "${work_dir}/empty.deps"
cp "${accepted_deps}" "${work_dir}/unreadable.deps"
chmod 000 "${work_dir}/unreadable.deps"
expect_failure \
  "unreadable compiler dependency manifest" \
  "${scanner}" closure \
  "${fake_repo}" "${nim_lib_root}" \
  "${helper_src}/accepted_entry.nim" "${work_dir}/unreadable.deps"
chmod 600 "${work_dir}/unreadable.deps"

cp "${accepted_deps}" "${work_dir}/duplicate.deps"
printf '%s\n' "${helper_src}/accepted_entry.nim" \
  >>"${work_dir}/duplicate.deps"
expect_failure \
  "duplicate compiler dependency" \
  "${scanner}" closure \
  "${fake_repo}" "${nim_lib_root}" \
  "${helper_src}/accepted_entry.nim" "${work_dir}/duplicate.deps"

awk -v entry="${helper_src}/accepted_entry.nim" \
  '$0 != entry { print }' \
  "${accepted_deps}" \
  >"${work_dir}/missing-entry.deps"
expect_failure \
  "compiler dependency manifest missing its entry" \
  "${scanner}" closure \
  "${fake_repo}" "${nim_lib_root}" \
  "${helper_src}/accepted_entry.nim" "${work_dir}/missing-entry.deps"

printf '\n' >"${work_dir}/blank.deps"
expect_failure \
  "blank compiler dependency manifest" \
  "${scanner}" closure \
  "${fake_repo}" "${nim_lib_root}" \
  "${helper_src}/accepted_entry.nim" "${work_dir}/blank.deps"
printf '%s\n\0%s\n' \
  "${helper_src}/accepted_entry.nim" \
  "${nim_lib_root}/system.nim" \
  >"${work_dir}/nul.deps"
expect_failure \
  "NUL-containing compiler dependency manifest" \
  "${scanner}" closure \
  "${fake_repo}" "${nim_lib_root}" \
  "${helper_src}/accepted_entry.nim" "${work_dir}/nul.deps"
awk '{ printf "%s\r\n", $0 }' \
  "${accepted_deps}" \
  >"${work_dir}/crlf.deps"
expect_failure \
  "CRLF compiler dependency manifest" \
  "${scanner}" closure \
  "${fake_repo}" "${nim_lib_root}" \
  "${helper_src}/accepted_entry.nim" "${work_dir}/crlf.deps"

printf '%s\n%s\n' \
  "${helper_src}/accepted_entry.nim" \
  "${external_src}/escape_module.nim" \
  >"${work_dir}/untrusted-local.deps"
expect_failure \
  "untrusted local compiler dependency" \
  "${scanner}" closure \
  "${fake_repo}" "${nim_lib_root}" \
  "${helper_src}/accepted_entry.nim" "${work_dir}/untrusted-local.deps"

other_store_dependency="${pinned_nim}"
printf '%s\n%s\n' \
  "${helper_src}/accepted_entry.nim" \
  "${other_store_dependency}" \
  >"${work_dir}/other-store.deps"
expect_failure \
  "dependency from another Nix store compiler package" \
  "${scanner}" closure \
  "${fake_repo}" "${nim_lib_root}" \
  "${helper_src}/accepted_entry.nim" "${work_dir}/other-store.deps"

repo_sibling="${fake_repo}-sibling"
trusted_root="${work_dir}/trusted-root"
trusted_sibling="${trusted_root}-sibling"
mkdir -p "${repo_sibling}" "${trusted_root}" "${trusted_sibling}"
printf '%s\n' 'type RepoPrefixEscape = object' \
  >"${repo_sibling}/prefix_escape.nim"
printf '%s\n' 'type TrustedPrefixEscape = object' \
  >"${trusted_sibling}/prefix_escape.nim"
printf '%s\n%s\n' \
  "${helper_src}/accepted_entry.nim" \
  "${repo_sibling}/prefix_escape.nim" \
  >"${work_dir}/repo-prefix-boundary.deps"
expect_failure \
  "repository prefix-boundary sibling dependency" \
  "${scanner}" closure \
  "${fake_repo}" "${nim_lib_root}" \
  "${helper_src}/accepted_entry.nim" \
  "${work_dir}/repo-prefix-boundary.deps"
printf '%s\n%s\n' \
  "${helper_src}/accepted_entry.nim" \
  "${trusted_sibling}/prefix_escape.nim" \
  >"${work_dir}/trusted-prefix-boundary.deps"
expect_failure \
  "trusted-root prefix-boundary sibling dependency" \
  "${scanner}" closure \
  "${fake_repo}" "${trusted_root}" \
  "${helper_src}/accepted_entry.nim" \
  "${work_dir}/trusted-prefix-boundary.deps"

printf '%s\n%s\n' \
  "${helper_src}/accepted_entry.nim" \
  "${work_dir}/missing-dependency.nim" \
  >"${work_dir}/missing-dependency.deps"
expect_failure \
  "manifest containing a missing compiler dependency" \
  "${scanner}" closure \
  "${fake_repo}" "${nim_lib_root}" \
  "${helper_src}/accepted_entry.nim" \
  "${work_dir}/missing-dependency.deps"

expect_failure \
  "empty repository root argument" \
  "${scanner}" closure \
  "" "${nim_lib_root}" \
  "${helper_src}/accepted_entry.nim" "${accepted_deps}"
expect_failure \
  "empty trusted root argument" \
  "${scanner}" closure \
  "${fake_repo}" "" \
  "${helper_src}/accepted_entry.nim" "${accepted_deps}"
expect_failure \
  "empty repository root directory" \
  "${scanner}" closure \
  "${work_dir}/empty-root" "${nim_lib_root}" \
  "${helper_src}/accepted_entry.nim" "${accepted_deps}"

printf '%s\n' \
  "${helper_src}/../src/accepted_entry.nim" \
  >"${work_dir}/noncanonical.deps"
expect_failure \
  "noncanonical compiler dependency path" \
  "${scanner}" closure \
  "${fake_repo}" "${nim_lib_root}" \
  "${helper_src}/accepted_entry.nim" "${work_dir}/noncanonical.deps"
printf '%s\n' \
  "libs/helper/src/accepted_entry.nim" \
  >"${work_dir}/relative.deps"
expect_failure \
  "relative compiler dependency path" \
  "${scanner}" closure \
  "${fake_repo}" "${nim_lib_root}" \
  "${helper_src}/accepted_entry.nim" "${work_dir}/relative.deps"

echo "Nim compiler lexer and dependency-closure regression tests passed"
