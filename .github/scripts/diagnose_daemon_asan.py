"""Compare the real daemon's worker storage before and after preallocation.

No mocks. Real passing and use-after-free C programs verify AddressSanitizer.
Nim's malloc allocator exposes sequence lifetimes to the sanitizer. This is a
separate diagnostic build, not a claim about ordinary allocator instrumentation.
The existing real shutdown fixture and every assertion remain unchanged.
"""

import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path.cwd()
OUT = ROOT / "build/diagnostics/daemon-asan"
DAEMON = ROOT / "libs/runquota_daemon/src/runquota_daemon.nim"
OLD = """  var threads: seq[Thread[void]] = @[]
  for _ in 0 ..< connectionWorkerCount():
    threads.add(default(Thread[void]))
    createThread(threads[^1], connectionWorker)
"""
FIXED = """  # Nim's thread wrapper borrows the Thread object's address through its exit
  # cleanup. Allocate every slot before starting workers so sequence growth
  # cannot move a live worker's storage.
  var threads = newSeq[Thread[void]](connectionWorkerCount())
  for i in 0 ..< threads.len:
    createThread(threads[i], connectionWorker)
"""


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
        assert (result == 0) == (name == "positive")
        if name == "negative":
            assert "heap-use-after-free" in (OUT / "negative.log").read_text()

    entries = []
    for line in (ROOT / "apps/entrypoints.txt").read_text().splitlines():
        if line.strip() and not line.lstrip().startswith("#"):
            name, source, *_ = line.split()
            entries.append((name, source, "build/bin/" + name))
    entries.append(("shutdown", "tests/integration/t_sigterm_exits_with_the_socket_gone.nim",
                    "build/test-bin/t_sigterm_exits_with_the_socket_gone"))
    original = DAEMON.read_text()
    assert original.count(OLD) == 1
    results = {}
    try:
        for variant in ["original", "preallocated"]:
            DAEMON.write_text(original if variant == "original" else original.replace(OLD, FIXED))
            (OUT / (variant + "-source-hash.json")).write_text(json.dumps({
                "daemon_source_sha256": hashlib.sha256(DAEMON.read_bytes()).hexdigest(),
                "allocator": "useMalloc",
            }, indent=2))
            for name, source, binary in entries:
                Path(binary).parent.mkdir(parents=True, exist_ok=True)
                command = ["nim", "c", "--cc:gcc", "--threads:on", "-d:useMalloc",
                           "--debugger:native", "--passC:-fsanitize=address",
                           "--passC:-fno-omit-frame-pointer", "--passL:-fsanitize=address",
                           "--nimcache:build/nimcache/asan-" + variant + "-" + name,
                           "--out:" + binary, source]
                assert run(variant + "-compile-" + name, command, environment) == 0
            def hashes():
                return {binary: hashlib.sha256(Path(binary).read_bytes()).hexdigest()
                        for _, _, binary in entries}
            baseline = hashes()
            (OUT / (variant + "-binary-hashes.json")).write_text(json.dumps(baseline, indent=2))
            results[variant] = []
            for iteration in range(3 if variant == "original" else 30):
                label = variant + "-shutdown-" + str(iteration + 1)
                result = run(label, [str(ROOT / entries[-1][2])], environment, timeout=120)
                results[variant].append(result)
                (OUT / "results.json").write_text(json.dumps(results, indent=2))
                assert hashes() == baseline, "An instrumented binary changed between runs"
                if variant == "original" and result:
                    log = (OUT / (label + ".log")).read_text()
                    assert "heap-use-after-free" in log, "The original must expose the lifetime fault"
                    assert "threadProc" in log, "The failure must involve the real thread wrapper"
                    break
                if variant == "preallocated":
                    assert result == 0, "Preallocated worker storage must pass every real case"
            if variant == "original":
                assert any(results[variant]), "The original-source negative control did not reproduce"
        print("Original worker storage fails; preallocated storage passes all 30 real fixtures.",
              flush=True)
    finally:
        DAEMON.write_text(original)


if __name__ == "__main__":
    main()
