# release_metadata.nim calls reprobuild's package renderers
# (`repro_dsl_stdlib/packaging`), which need the full project DSL. Since
# reprobuild 41d3232396 the DSL compiles in its thin mode -- the form names
# only -- unless the compilation's main file is a DSL file or a mode is
# defined, and this module is neither. Nim reads this file only when
# release_metadata.nim is the main module, which is how the DSL's own
# documentation (`repro_project_dsl/mode.nim`) asks a helper that uses the
# full DSL to select it. Both release recipes (scripts/release/build.sh and
# build.ps1) compile this module as the main file, so both get the mode.
switch("define", "reproEvalMode")
