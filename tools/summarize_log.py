"""Summarize Food Trade self-check logs without inventing passes for missing steps."""
from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--require-spikes", action="store_true", help="also fail if any of S1-S5 has no evidence")
    args = parser.parse_args()
    lines = args.log.read_text(encoding="utf-8-sig", errors="replace").splitlines()
    passed = failed = pending = summaries = notes = 0
    summary_failures = summary_pending = 0
    spikes: set[str] = set()
    for line in lines:
        match = re.search(r"\[(?:CHECK(?: [^\]]*)?|SPIKE(?: [^\]]*)?|SETUP(?: [^\]]*)?|SET GOLD(?: [^\]]*)?|PILLAGE(?: [^\]]*)?|DEV ERROR(?: [^\]]*)?|SUMMARY|FDT)\]", line)
        if not match:
            continue
        result = line[match.start():]
        if result.startswith("[FDT]") and not re.search(r"\bFAIL\b", result):
            continue
        print(result)
        if "[SUMMARY]" in result:
            summaries += 1
            summary = re.search(r"(\d+) PASS,\s*(\d+) FAIL(?:,\s*(\d+) PENDING)?", result)
            if summary:
                summary_failures = max(summary_failures, int(summary.group(2)))
                summary_pending = max(summary_pending, int(summary.group(3) or 0))
            else:
                pending += 1
            continue
        if re.search(r"\bFAIL\b", result):
            failed += 1
        elif re.search(r"\bPASS\b", result):
            passed += 1
        elif re.search(r"\bPENDING\b", result):
            pending += 1
        else:
            notes += 1
        spike = re.search(r"\[SPIKE (S[1-5])(?: |\])", result)
        if spike:
            spikes.add(spike.group(1))
    print(f"Parsed {passed} PASS, {failed} FAIL, {pending} PENDING; {notes} context lines; {summaries} session summaries.")
    missing = sorted({f"S{i}" for i in range(1, 6)} - spikes)
    if missing:
        print("Missing spike evidence: " + ", ".join(missing))
    if not summaries:
        print("FAIL no completed [SUMMARY] session found; quit Civilization VI before collecting Lua.log.")
    return 1 if failed or pending or summary_failures or summary_pending or not summaries or not passed or (args.require_spikes and missing) else 0


if __name__ == "__main__":
    sys.exit(main())
