"""Repeat real daemon fixtures without unrelated compile or execution load.

No mocks or modified assertions. Both modes use identical compiled binaries.
Temporary recipe edits select the existing graph edges and prevent result caching.
Linux cores stay local; only backtraces without argument values are retained.
"""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path.cwd()
RECIPE = ROOT / "repro.nim"
EVIDENCE = ROOT / "build/diagnostics/daemon-regressions"
WINDOWS = os.name == "nt"
SUFFIX = ".exe" if WINDOWS else ""
NAMES = (["t_endpoint_serves_before_store_verification",
          "t_e2e_runquota_client_exit_releases_lease"] if WINDOWS else
         ["t_sigterm_exits_with_the_socket_gone"])
REPRO = shutil.which("repro") or shutil.which("repro.exe")
PROVISIONING = "tarball" if WINDOWS else "nix"
FIELDS = ["id", "status", "exitCode", "launched", "cacheDecision",
          "dependencyPolicyKind", "stdout", "stderr"]


def hashes():
    paths = [ROOT / "build/bin" / (name + SUFFIX)
             for name in ["runquota", "runquotad"]]
    paths += [ROOT / "build/test-bin" / (name + SUFFIX) for name in NAMES]
    return {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in paths}


def collect_cores(label):
    directory = os.environ.get("DIAGNOSTIC_CORE_DIR")
    if not directory:
        return
    for core in Path(directory).glob("core.*"):
        try:
            with (EVIDENCE / (label + "-" + core.name + ".backtrace.log")).open("w") as log:
                subprocess.run([
                    "/usr/bin/gdb", "--batch", "-nx", "-ex", "set pagination off",
                    "-ex", "set print frame-arguments none", "-ex", "thread apply all bt",
                    str(ROOT / "build/bin/runquotad"), str(core),
                ], stdout=log, stderr=subprocess.STDOUT, timeout=90)
        finally:
            core.unlink()


def monitored(label, target, expected):
    with tempfile.TemporaryDirectory(prefix="runquota-diagnostic-") as temporary:
        report = Path(temporary) / "report.json"
        with (EVIDENCE / (label + ".log")).open("w") as log:
            result = subprocess.run([
                REPRO, "build", target, "--tool-provisioning=" + PROVISIONING,
                "--daemon=off", "--write-report=" + str(report),
            ], stdout=log, stderr=subprocess.STDOUT, timeout=1800)
        data = json.loads(report.read_text())
    executions = [action for action in data["actions"]
                  if action["id"].startswith("runquota.test_execute.")]
    summary = {"command_exit": result.returncode,
               "actions": [{key: action[key] for key in FIELDS} for action in executions]}
    (EVIDENCE / (label + ".summary.json")).write_text(json.dumps(summary, indent=2))
    assert {a["id"] for a in executions} == set(expected), summary
    for action in executions:
        assert action["launched"], summary
        assert action["cacheDecision"] == "cdNotCacheable", summary
        assert action["dependencyPolicyKind"] == "dgAutomaticMonitor", summary
    print(label + ": exit=" + str(result.returncode), flush=True)
    collect_cores(label)
    return result.returncode


def native(label, name, activated):
    environment = dict(activated)
    for key in list(environment):
        if key == "LD_PRELOAD" or key.startswith("REPRO_MONITOR_"):
            del environment[key]
    with (EVIDENCE / (label + ".log")).open("w") as log:
        result = subprocess.run([str(ROOT / "build/test-bin" / (name + SUFFIX))],
                                env=environment, stdout=log, stderr=subprocess.STDOUT,
                                timeout=600, stdin=subprocess.DEVNULL)
    print(label + ": exit=" + str(result.returncode), flush=True)
    collect_cores(label)
    return result.returncode


def main():
    assert REPRO, "Reprobuild must come from the source bootstrap"
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    original = RECIPE.read_text()
    selector = "    for program in testPrograms:\n"
    assert original.count(selector) == 1
    names = "[" + ", ".join(json.dumps(name) for name in NAMES) + "]"
    selected = original.replace(selector,
        "    var diagnosticBuilds = runquotaAppsActions\n" +
        "    for program in testPrograms:\n" +
        "      if program.name in " + names + ":\n" +
        "        diagnosticBuilds.add(program.compiled)\n" +
        '    discard collect("daemon-diagnostic-builds", diagnosticBuilds)\n' + selector)
    dependency = ("      var executeAfter = runquotaAppsActions & @[compiled] &\n"
                  "        (if name in measurementTests: testBuilds & testRuns else: @[])")
    assert selected.count(dependency) == 1
    selected = selected.replace(dependency,
                                "      var executeAfter = runquotaAppsActions & @[compiled]")
    assert selected.count("        cacheable = not isolatesEnvironment,") == 1
    selected = selected.replace("        cacheable = not isolatesEnvironment,",
        "        cacheable = not isolatesEnvironment and name notin " + names + ",")
    results = []
    try:
        RECIPE.write_text(selected)
        assert monitored("compile", ".#daemon-diagnostic-builds", []) == 0
        # Activate only native controls. Repro graph commands keep the exact
        # bootstrap environment used by CI instead of nesting repro exec.
        with (EVIDENCE / "native-activation.log").open("w") as log:
            activation = subprocess.run([
                REPRO, "exec", "--", sys.executable, "-c",
                "import json,os; print(json.dumps(dict(os.environ)))",
            ], stdout=subprocess.PIPE, stderr=log, text=True, timeout=1200)
        assert activation.returncode == 0, "Native environment activation failed"
        # This may contain credentials. Keep it in memory; never write or print it.
        activated = json.loads(activation.stdout)
        baseline = hashes()
        (EVIDENCE / "binary-hashes.json").write_text(json.dumps(baseline, indent=2))
        for iteration in range(2 if WINDOWS else 30):
            for name in NAMES:
                prefix = str(iteration + 1) + "-" + name
                direct = native(prefix + "-native", name, activated)
                observed = monitored(prefix + "-monitored", ".#test-" + name,
                                     ["runquota.test_execute." + name])
                assert hashes() == baseline, "Binary changed between control modes"
                results.append({"iteration": iteration + 1, "name": name,
                                "native": direct, "monitored": observed})
                (EVIDENCE / "results.json").write_text(json.dumps(results, indent=2))
                if not WINDOWS and (direct != 0 or observed != 0):
                    return
        print("All paired executions completed with identical binaries.", flush=True)
    finally:
        RECIPE.write_text(original)


if __name__ == "__main__":
    main()
