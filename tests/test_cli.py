#!/usr/bin/env python3
"""Exercise the built CLI without credentials or external pool connections."""

import json
import math
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
BINARY = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "build/miner/Build/Products/Release/verusmetal"


def run(*arguments, success=True):
    result = subprocess.run([str(BINARY), *arguments], capture_output=True, text=True, timeout=20)
    assert result.returncode == (0 if success else 2), (arguments, result.returncode, result.stderr)
    if success:
        assert not result.stderr, (arguments, result.stderr)
    else:
        assert not result.stdout, (arguments, result.stdout)
        assert "error:" in result.stderr
    return result.stdout


assert run("--version").strip() == "VerusMetal 0.2.0"
for command in ["devices", "verify", "benchmark", "mine"]:
    assert f"verusmetal {command}" in run(command, "--help")
    assert run(command, "--help") == run(command, "-h")
for arguments in [[], ["unknown"], ["--version", "--json"], ["help", "--unknown"],
                  ["mine"], ["mine", "--pool", "stratum+tcp://127.0.0.1:1"],
                  ["devices", "--json", "true"], ["benchmark", "--batch-nonces"],
                  ["benchmark", "--batch", "64", "--batch-nonces", "64"],
                  ["benchmark", "--batch-nonces", "0"], ["benchmark", "--batch", "32769"],
                  ["benchmark", "--duration", "0"], ["mine", "--help", "--unknown"]]:
    run(*arguments, success=False)

devices = json.loads(run("devices", "--json"))
assert devices and all(isinstance(d["name"], str) and isinstance(d["unifiedMemory"], bool)
                       and d["recommendedWorkingSetBytes"] > 0 for d in devices)
for option in ["--batch-nonces", "--batch"]:
    report = json.loads(run("benchmark", "--duration", "1", option, "64", "--json"))
    assert report["schemaVersion"] == 1 and report["batchNonces"] == 64
    assert report["requestedDurationSeconds"] == 1 and report["durationSeconds"] >= 1
    assert report["nonces"] == report["dispatches"] * 64 > 0
    for rate, seconds in [("gpuHashrate", "gpuSeconds"), ("averageHashrate", "commandWallSeconds"),
                          ("effectiveHashrate", "durationSeconds")]:
        assert math.isfinite(report[rate]) and report[rate] > 0
        assert math.isclose(report[rate], report["nonces"] / report[seconds], rel_tol=1e-9)
print("CLI passed: help, version, strict errors, device JSON, batch alias and benchmark rate accounting.")
