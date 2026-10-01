"""Retain complete-suite scheduling while collecting daemon crash evidence.

No mocks or changed assertions. Only test-result caching is disabled so both
full executions really run; the original dependencies and monitor policies stay.
"""

import json
from pathlib import Path
import subprocess
import tempfile

from diagnose_daemon_regressions import (
    EVIDENCE, FIELDS, PROVISIONING, RECIPE, REPRO, collect_cores, hashes,
)


def graph(label, target=None):
    with tempfile.TemporaryDirectory(prefix="runquota-full-diagnostic-") as temporary:
        report = Path(temporary) / "report.json"
        command = [REPRO, "build"]
        if target:
            command.append(target)
        command += ["--tool-provisioning=" + PROVISIONING, "--daemon=off",
                    "--write-report=" + str(report)]
        try:
            with (EVIDENCE / (label + ".log")).open("w") as log:
                result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT,
                                        timeout=1800)
        finally:
            collect_cores(label)
        data = json.loads(report.read_text())
    summary = {"command_exit": result.returncode,
               "actions": [{key: action[key] for key in FIELDS}
                           for action in data["actions"]]}
    (EVIDENCE / (label + ".summary.json")).write_text(json.dumps(summary, indent=2))
    print(label + ": exit=" + str(result.returncode), flush=True)
    if result.returncode:
        raise SystemExit(result.returncode)
    executions = [a for a in summary["actions"]
                  if a["id"].startswith("runquota.test_execute.")]
    if target:
        assert len(executions) > 100, "The complete suite must be selected"
        for action in executions:
            assert action["launched"] and action["status"] == "asSucceeded", action
            assert action["cacheDecision"] == "cdNotCacheable", action
        shutdown = next(a for a in executions if a["id"].endswith(
            ".t_sigterm_exits_with_the_socket_gone"))
        assert shutdown["dependencyPolicyKind"] == "dgAutomaticMonitor", shutdown
    return {a["id"] for a in executions}


def main():
    assert REPRO
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    original = RECIPE.read_text()
    marker = "        cacheable = not isolatesEnvironment,"
    assert original.count(marker) == 1
    try:
        RECIPE.write_text(original.replace(marker, "        cacheable = false,"))
        graph("full-build")
        baseline = hashes()
        (EVIDENCE / "binary-hashes.json").write_text(json.dumps(baseline, indent=2))
        first = graph("full-test-first", ".#test")
        assert hashes() == baseline, "Daemon or shutdown fixture changed"
        repeated = graph("full-test-repeat", ".#test")
        assert repeated == first, "The repeat changed the execution catalog"
        assert hashes() == baseline, "Daemon or shutdown fixture changed"
        print("Two complete uncached test graphs passed with identical binaries.",
              flush=True)
    finally:
        RECIPE.write_text(original)


if __name__ == "__main__":
    main()
