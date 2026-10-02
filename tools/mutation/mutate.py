#!/usr/bin/env python3
"""MacReplica mutation testing.

Swift has no mutation-testing tool that works with plain SwiftPM and the
Command Line Tools, so this small, dependency-free runner does the job:

1. For every critical source file listed in config.json it generates mutants
   with classic operators (relational and logical operator replacement,
   boolean literal flips, negation removal, return-value flips, arithmetic
   off-by-one and early-exit removal).
2. Each mutant is compiled; mutants that do not compile are "invalid" and
   do not count.
3. The tests that cover the file run against the mutant. A failing test
   "kills" the mutant; a passing test means it "survived".
4. The original file is always restored, even on Ctrl-C or errors.

Usage:
  tools/mutation/mutate.py [--files Restore/RestorePlanner.swift ...]
                           [--max-per-file N] [--report DIR] [--check]

With --check the exit code is non-zero if a module falls below its
threshold (used in CI).
"""

import argparse
import json
import os
import re
import random
import signal
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / "Sources" / "MacReplicaCore"
CONFIG = Path(__file__).with_name("config.json")

# (name, regex, replacement). Applied one occurrence at a time.
OPERATORS = [
    ("== → !=", r"(?<![=!<>])==(?!=)", "!="),
    ("!= → ==", r"!=(?!=)", "=="),
    ("< → <=", r"(?<![<\-])\s<\s(?!=)", " <= "),
    ("<= → <", r"\s<=\s", " < "),
    ("> → >=", r"(?<![\->])\s>\s(?!=)", " >= "),
    (">= → >", r"\s>=\s", " > "),
    ("&& → ||", r"&&", "||"),
    ("|| → &&", r"\|\|", "&&"),
    ("true → false", r"\btrue\b", "false"),
    ("false → true", r"\bfalse\b", "true"),
    ("remove !", r"(?<![\w)\]!])!(?=[\w(.$])", ""),
    ("+ 1 → - 1", r"\+ 1\b", "- 1"),
    ("- 1 → + 1", r"(?<=\s)- 1\b", "+ 1"),
    ("+= → -=", r"\+=", "-="),
    ("isEmpty → !isEmpty", r"(?<=[\w)\]])\.isEmpty\b", ".isEmpty == false"),
    ("contains → !contains", r"(?<![!\w])(\w[\w.?]*)\.contains\(", r"!\1.contains("),
    ("remove continue", r"\bcontinue\b", "_ = 0"),
    ("first → last", r"\.first\b", ".last"),
    ("min → max", r"\bmin\(", "max("),
    ("max → min", r"\bmax\(", "min("),
]


def strip_strings_and_comments(line):
    """Returns a mask of positions that are code (not inside strings or comments)."""
    mask = [True] * len(line)
    in_string = False
    i = 0
    while i < len(line):
        ch = line[i]
        if not in_string and line.startswith("//", i):
            for j in range(i, len(line)):
                mask[j] = False
            break
        if ch == '"' and (i == 0 or line[i - 1] != "\\"):
            in_string = not in_string
            mask[i] = False
        elif in_string:
            mask[i] = False
        i += 1
    return mask


def generate_mutants(path):
    lines = path.read_text().splitlines(keepends=True)
    mutants = []
    in_block_comment = False
    for number, line in enumerate(lines):
        stripped = line.strip()
        if "/*" in stripped:
            in_block_comment = True
        if in_block_comment:
            if "*/" in stripped:
                in_block_comment = False
            continue
        if (not stripped or stripped.startswith("//") or stripped.startswith("import ") or stripped.startswith("///")
                or stripped.startswith("case ") and "=" in stripped and "\"" in stripped
                or "#expect" in stripped or stripped.startswith("@")):
            continue
        mask = strip_strings_and_comments(line)
        for name, pattern, replacement in OPERATORS:
            for match in re.finditer(pattern, line):
                if not all(mask[match.start():match.end()]) or not mask[match.start()]:
                    continue
                mutated = line[:match.start()] + match.expand(replacement) + line[match.end():]
                if mutated != line:
                    mutants.append({"line": number + 1, "operator": name, "original": line.rstrip("\n"),
                                    "mutated": mutated.rstrip("\n"), "start": match.start(), "end": match.end(),
                                    "replacement": match.expand(replacement)})
    return lines, mutants


def run(command, timeout):
    env = dict(os.environ, MACREPLICA_CLT_TESTING=os.environ.get("MACREPLICA_CLT_TESTING", "1"))
    try:
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=timeout, env=env)
        return result.returncode, result.stdout + result.stderr
    except subprocess.TimeoutExpired:
        return None, "timeout"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--files", nargs="*", help="limit to these files (relative to Sources/MacReplicaCore)")
    parser.add_argument("--max-per-file", type=int, default=0, help="sample at most N mutants per file (0 = all)")
    parser.add_argument("--report", default=str(ROOT / ".build" / "mutation"), help="report folder")
    parser.add_argument("--check", action="store_true", help="fail if a module is below its threshold")
    parser.add_argument("--seed", type=int, default=20261002)
    args = parser.parse_args()

    config = json.loads(CONFIG.read_text())
    modules = config["modules"]
    if args.files:
        modules = [m for m in modules if m["file"] in args.files]

    report_dir = Path(args.report)
    report_dir.mkdir(parents=True, exist_ok=True)

    code, output = run(["swift", "build", "--build-tests"], 1800)
    if code != 0:
        print(output)
        sys.exit("baseline build failed")

    results = []
    current = {"path": None, "content": None}

    def restore(*_):
        if current["path"] is not None:
            current["path"].write_text(current["content"])
            current["path"] = None
        if _:
            sys.exit(130)

    signal.signal(signal.SIGINT, restore)
    signal.signal(signal.SIGTERM, restore)

    rng = random.Random(args.seed)
    try:
        for module in modules:
            path = CORE / module["file"]
            original = path.read_text()
            lines, mutants = generate_mutants(path)
            if args.max_per_file and len(mutants) > args.max_per_file:
                mutants = sorted(rng.sample(mutants, args.max_per_file), key=lambda m: (m["line"], m["start"]))
            excluded = [re.compile(e["pattern"]) for e in config.get("exclusions", []) if e["file"] == module["file"]]
            filter_args = []
            for suite in module["tests"]:
                filter_args += ["--filter", suite]
            # Baseline: the covering tests must pass on the original code.
            code, output = run(["swift", "test", "--skip-build"] + filter_args, 600)
            if code != 0:
                print(output[-3000:])
                sys.exit(f"tests for {module['file']} fail without mutations")
            print(f"== {module['file']}: {len(mutants)} mutants", flush=True)
            for index, mutant in enumerate(mutants, 1):
                if any(rx.search(mutant["original"]) for rx in excluded):
                    mutant["status"] = "excluded"
                    results.append({**mutant, "file": module["file"]})
                    continue
                mutated_lines = list(lines)
                line = mutated_lines[mutant["line"] - 1]
                mutated_lines[mutant["line"] - 1] = line[:mutant["start"]] + mutant["replacement"] + line[mutant["end"]:]
                current["path"], current["content"] = path, original
                path.write_text("".join(mutated_lines))
                started = time.time()
                code, output = run(["swift", "build", "--build-tests"], 900)
                if code != 0:
                    status = "invalid"
                else:
                    code, output = run(["swift", "test", "--skip-build"] + filter_args, 300)
                    status = "survived" if code == 0 else "killed"
                restore()
                mutant.update(status=status, seconds=round(time.time() - started, 1), file=module["file"])
                results.append(mutant)
                print(f"  [{index}/{len(mutants)}] {status:8} L{mutant['line']} {mutant['operator']}", flush=True)
    finally:
        restore()
        run(["swift", "build", "--build-tests"], 1800)

    summary = []
    failed = False
    for module in modules:
        rows = [r for r in results if r["file"] == module["file"]]
        killed = sum(r["status"] == "killed" for r in rows)
        survived = sum(r["status"] == "survived" for r in rows)
        invalid = sum(r["status"] == "invalid" for r in rows)
        excluded = sum(r["status"] == "excluded" for r in rows)
        valid = killed + survived
        score = 100.0 * killed / valid if valid else 100.0
        threshold = module.get("threshold", config["default_threshold"])
        ok = score >= threshold
        failed |= not ok
        summary.append({"file": module["file"], "killed": killed, "survived": survived, "invalid": invalid,
                        "excluded": excluded, "score": round(score, 1), "threshold": threshold, "passed": ok})

    total_killed = sum(s["killed"] for s in summary)
    total_valid = sum(s["killed"] + s["survived"] for s in summary)
    overall = round(100.0 * total_killed / total_valid, 1) if total_valid else 100.0
    (report_dir / "mutation-results.json").write_text(json.dumps({"overall": overall, "modules": summary, "mutants": results}, indent=2))

    md = ["# Mutation testing report", "",
          f"Overall mutation score: **{overall} %** ({total_killed} of {total_valid} valid mutants killed)", "",
          "| Module | Killed | Survived | Invalid | Excluded | Score | Threshold | Result |",
          "|---|---:|---:|---:|---:|---:|---:|---|"]
    for s in summary:
        md.append(f"| `{s['file']}` | {s['killed']} | {s['survived']} | {s['invalid']} | {s['excluded']} | {s['score']} % | "
                  f"{s['threshold']} % | {'✅' if s['passed'] else '❌'} |")
    survivors = [r for r in results if r["status"] == "survived"]
    if survivors:
        md += ["", "## Surviving mutants", ""]
        for r in survivors:
            md.append(f"- `{r['file']}:{r['line']}` {r['operator']}: `{r['original'].strip()}` → `{r['mutated'].strip()}`")
    (report_dir / "mutation-report.md").write_text("\n".join(md) + "\n")
    print("\n".join(md))
    if args.check and failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
