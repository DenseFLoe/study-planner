#!/usr/bin/env python3
"""Check the production repair against the committed synthetic baseline table."""
import argparse
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def compare(a, b):
    for x, y in zip(a, b):
        if abs(x-y) > 1e-6:
            return -1 if x < y else 1
    return 0


def baseline():
    fixture = "Experiments/Scheduling/main.swift"
    expected = subprocess.check_output(["git", "show", "88444e9:"+fixture], cwd=ROOT)
    assert (ROOT/fixture).read_bytes() == expected, "Synthetic inputs changed; baseline comparison needs a new fixture audit"
    text = subprocess.check_output(["git", "show", "88444e9:Experiments/Scheduling/reference-results.md"], cwd=ROOT, text=True)
    result, name = {}, None
    for line in text.splitlines():
        if line.startswith("### "):
            name = line[4:]
            result[name] = {}
        elif name and line.startswith(("| 现算法 |", "| CP-SAT |")):
            cells = [x.strip() for x in line.split("|")[1:-1]]
            result[name][cells[0]] = [json.loads(x) for x in cells[1:4]]
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results", type=Path)
    args = parser.parse_args()
    original = baseline()
    rows = json.loads(args.results.read_text())["cases"]
    assert len(rows) == len(original) == 32
    changed, equal, proven = [], 0, 0
    for row in rows:
        name = row["input"]["name"]
        old = original[name]
        current = row["baseline"]["metrics"]
        assert len(old["现算法"][0]) == len(current["score"])
        assert old["现算法"][1] == current["courseMinutes"], (name, "booked work changed")
        order = compare(current["score"], old["现算法"][0])
        assert order <= 0, (name, "whole-plan preference regression")
        if order < 0:
            changed.append(name)
        else:
            equal += 1
        if "CP-SAT" in old:
            assert compare(current["score"], old["CP-SAT"][0]) == 0, (name, "does not reach recorded proven optimum")
            proven += 1
    print(json.dumps({"cases": len(rows), "improved": changed, "equal": equal,
                      "matchesRecordedProvenOptimum": proven, "workLossOrScoreRegressions": 0}, ensure_ascii=False))
