"""Exercise the real daemon and shutdown assertions under AddressSanitizer.

No mocks. Real passing and use-after-free C programs first verify the sanitizer.
The daemon keeps its normal Nim allocator; only compiler instrumentation changes.
Leak reporting is disabled because this experiment targets invalid memory access.
"""

import hashlib
import json
import os
from pathlib import Path
import subprocess


ROOT = Path.cwd()
OUT = ROOT / "build/diagnostics/daemon-asan"


def run(label, command, environment, timeout=600):
    with (OUT / (label + ".log")).open("w") as log:
        result = subprocess.run(command, env=environment, stdout=log,
                                stderr=subprocess.STDOUT, timeout=timeout)
    print(label + ": exit=" + str(result.returncode), flush=True)
    return result.returncode


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    environment = dict(os.environ)
    for key in list(environment):
        if key == "LD_PRELOAD" or key.startswith("REPRO_MONITOR_"):
            del environment[key]
    environment["ASAN_OPTIONS"] = "detect_leaks=0:abort_on_error=1"
    assert run("nim-version", ["nim", "--version"], environment) == 0
    assert run("gcc-version", ["gcc", "--version"], environment) == 0
    # Build and execute real controls with the same compiler instrumentation.
    for name, body in [
        ("positive", "int value = *p; free((void *)p); return value == 7 ? 0 : 1;"),
        ("negative", "free((void *)p); return *p;"),
    ]:
        source = OUT / (name + ".c")
        binary = OUT / name
        source.write_text("#include <stdlib.h>\nint main(void) {\n"
                          "volatile int *p = malloc(sizeof(int)); *p = 7;\n" +
                          body + "\n}\n")
        assert run(name + "-compile", ["gcc", "-O0", "-g", "-fsanitize=address",
                   "-fno-omit-frame-pointer", str(source), "-o", str(binary)],
                   environment) == 0
        result = run(name, [str(binary)], environment)
        if name == "positive":
            assert result == 0
        else:
            assert result != 0
            assert "heap-use-after-free" in (OUT / "negative.log").read_text()

    entries = []
    for line in (ROOT / "apps/entrypoints.txt").read_text().splitlines():
        if line.strip() and not line.lstrip().startswith("#"):
            name, source, *_ = line.split()
            entries.append((name, source, "build/bin/" + name))
    entries.append(("shutdown", "tests/integration/t_sigterm_exits_with_the_socket_gone.nim",
                    "build/test-bin/t_sigterm_exits_with_the_socket_gone"))
    for name, source, binary in entries:
        Path(binary).parent.mkdir(parents=True, exist_ok=True)
        command = ["nim", "c", "--cc:gcc", "--threads:on", "--debugger:native",
                   "--passC:-fsanitize=address", "--passC:-fno-omit-frame-pointer",
                   "--passL:-fsanitize=address", "--nimcache:build/nimcache/asan-" + name,
                   "--out:" + binary, source]
        assert run("compile-" + name, command, environment) == 0
    def hashes():
        return {binary: hashlib.sha256(Path(binary).read_bytes()).hexdigest()
                for _, _, binary in entries}
    baseline = hashes()
    (OUT / "binary-hashes.json").write_text(json.dumps(baseline, indent=2))
    results = []
    for iteration in range(30):
        result = run("shutdown-" + str(iteration + 1),
                     [str(ROOT / entries[-1][2])], environment, timeout=120)
        results.append(result)
        (OUT / "results.json").write_text(json.dumps(results))
        assert hashes() == baseline, "An instrumented binary changed between runs"
        if result:
            raise SystemExit(result)
    print("All 30 real shutdown fixtures passed under AddressSanitizer.", flush=True)


if __name__ == "__main__":
    main()
