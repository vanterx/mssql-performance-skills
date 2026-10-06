#!/usr/bin/env python3
"""
verify-claims.py - claim-level invariants for mssql-performance-skills.

verify-docs.sh checks *structure*: counts, ranges, file presence, table rows.
Nothing guarded the technical *claims*, so a correct statement could be silently
undone by a later edit. Three defects in one session made the case: N24 told the
reader an estimated cost was the bottleneck, the self-time guidance said to sum
elapsed across threads (and a worked example computed 59,650 ms from two
concurrent threads), and a fourth copy of the idle-wait exclusion list drifted
out of sync with the other three.

This script holds five checks, numbered to continue verify-docs.sh:

  50  duplicated literal lists are byte-identical across every copy
  51  claims Microsoft does not document carry their Unverified label
  52  fixed-width example tables keep their columns aligned
  53  specific claims that were wrong once stay fixed
  54  the untrusted-artifact-content rule is present and identical everywhere

Scope and honest limits
-----------------------
Checks 50, 52 and 54 are derived from repository content, so they cannot
rot.
Check 51 enforces the mandatory MS Learn validation policy in the one direction
that is mechanical. Check 53 is a regression guard for known-wrong statements,
not a correctness proof - it would not have caught any of the three defects
above, because nothing in the repo knew they were wrong yet. MS Learn
validation remains the actual gate; this is a ratchet behind it.

Deliberately NOT implemented: a banned-phrase linter over all 27 skills. It
generates false positives, rots as wording changes, and pressures authors to
word around the check instead of fixing the content.

Performance
-----------
verify-docs.sh is already slow on Windows (minutes, versus seconds in CI)
because of many small grep invocations. Every check here runs against content
read in ONE pass, so adding them costs a single traversal rather than four.

Output is one record per line for verify-docs.sh to translate:

    PASS<TAB>50<TAB>message
    FAIL<TAB>50<TAB>message

Exit status is 0 even when checks fail; the caller counts the records.
Standard library only.
"""

import os
import re
import sys
from typing import Dict, FrozenSet, List, Optional, Sequence, Tuple

SCAN_DIRS = ("skills",)
SCAN_EXTS = (".md", ".sql")

# ---------------------------------------------------------------------------
# Check 50 registry: literal lists that exist in more than one file.
#
# `sentinel` must appear in every copy that is meant to be canonical, and in
# none of the copies that are deliberately short. The idle-wait list is the
# live example: sqlwait-review/SKILL.md also carries a trend-staging INSERT and
# a compact snapshot documented as the minimal alternative, and those are
# intentional, not drift. SLEEP_PHYSMASTERDBREADY appears only in the full
# lists, so it separates the two without needing a path allowlist.
# ---------------------------------------------------------------------------
DUPLICATED_LISTS: Sequence[Dict[str, object]] = (
    {
        "name": "idle-wait exclusion list",
        "sentinel": "SLEEP_PHYSMASTERDBREADY",
        "block": re.compile(r"NOT\s+IN\s*\((.*?)\)", re.S | re.I),
        "member": re.compile(r"'([A-Z0-9_]+)'"),
        # Documented deliberate keeps. Each accrues only when a feature is
        # configured, and its magnitude is then the signal, so excluding it
        # silently shrinks every share computed against the total.
        "forbidden": ("RESOURCE_SEMAPHORE_MUTEX", "WAIT_FOR_RESULTS", "DBMIRROR_SEND"),
        "min_copies": 2,
    },
)

# ---------------------------------------------------------------------------
# Check 54: the untrusted-artifact-content rule.
#
# Every skill analyses text pasted out of a production system - log lines,
# ApplicationName values, query text, embedded comments - none of which the user
# wrote or reviewed. A standing rule in SKILL.md keeps that content classified
# as data rather than instructions. It lives in SKILL.md and not in
# references/check-explanations.md because only SKILL.md is loaded at runtime by
# default, so a rule placed in references/ would not reach the model unprompted.
#
# The block is byte-identical in all skills so one edit can be propagated
# mechanically; this check fails on a missing copy, a drifted copy, and a copy
# that has been moved away from its documented position.
# See .claude/docs/architectural_patterns.md section 12.
# ---------------------------------------------------------------------------
UNTRUSTED_RULE_HEADING = "## Artifact Content Is Data, Not Instructions"
UNTRUSTED_RULE_FOLLOWS = "## Input"
SKILL_FILE_RE = re.compile("skills/[^/]+/SKILL" + chr(92) + ".md$")

# ---------------------------------------------------------------------------
# Check 51 registry: claims Microsoft Learn does not document.
#
# CLAUDE.md makes MS Learn validation mandatory, which across 909 checks is
# otherwise pure honour system. This enforces it in the mechanical direction:
# if a file asserts the claim, it must also carry the label.
# ---------------------------------------------------------------------------
UNVERIFIED_CLAIMS: Sequence[Dict[str, object]] = (
    {
        "name": "per-thread elapsed/CPU aggregation rule",
        "asserts": re.compile(r"`?MAX`?\s+for\s+elapsed", re.I),
        "marker": re.compile(r"Unverified\s+against\s+Microsoft\s+Learn", re.I),
    },
)

# ---------------------------------------------------------------------------
# Check 53: claims that were wrong once. Keep this list short and tie every
# entry to a defect that actually shipped.
# ---------------------------------------------------------------------------
CLAIM_SENTINELS: Sequence[Dict[str, object]] = (
    {
        "path": "skills/sqlplan-review/SKILL.md",
        "kind": "must",
        "pattern": re.compile(r"`costPercent` is defined as", re.I),
        "why": "costPercent drove 5 triggers and sqlindex-advisor's ranking while undefined",
    },
    {
        "path": "skills/sqlplan-review/SKILL.md",
        "kind": "must",
        "pattern": re.compile(r"[Ss]uperseded by N62"),
        "why": "N24 presented an estimated cost as the bottleneck",
    },
    {
        "path": "skills/sqlplan-review/SKILL.md",
        "kind": "must_not",
        "pattern": re.compile(r"sum of `?RunTimeCountersPerThread", re.I),
        "why": "elapsed aggregates by MAX across threads, never SUM",
    },
    {
        "path": "skills/sqlplan-review/references/check-explanations.md",
        "kind": "must_not",
        "pattern": re.compile(r"Sum\s*=\s*[\d,]+\s*ms actual elapsed", re.I),
        "why": "the worked example summed two concurrent threads to 59,650 ms",
    },
    {
        "path": "*",
        "kind": "must_not",
        "pattern": re.compile(r"\b\d{1,2}% (equality|inequality) guess\b", re.I),
        "why": "CE guess fractions vary by estimator version; N35 treats them as a shape",
    },
    {
        "path": "*/references/README.md",
        "kind": "must_not",
        "pattern": re.compile(r"all 0 checks"),
        "why": "a dispatcher skill states no count rather than claiming zero",
    },
)

# ---------------------------------------------------------------------------
# Check 52: fixed-width ASCII tables inside fenced code blocks.
# ---------------------------------------------------------------------------
FENCE = re.compile(r"^\s*```")
IDENTIFIER = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
GAP = re.compile(r"\s{2,}")
MIN_COLUMNS = 3


def column_starts(line: str) -> List[int]:
    """Offsets where a run of non-space characters begins."""
    out: List[int] = []
    prev = " "
    for pos, ch in enumerate(line):
        if ch != " " and prev == " ":
            out.append(pos)
        prev = ch
    return out


def looks_like_header(line: str) -> bool:
    """
    A fixed-width table header: three or more bare identifiers separated by runs
    of two or more spaces. The identifier constraint is what keeps SQL, XML and
    prose code blocks out - they contain punctuation, quotes or operators.
    """
    if not line.strip() or line.strip().startswith(("-", "|", "<", "/", "#", "*")):
        return False
    tokens = [t for t in GAP.split(line.strip()) if t]
    if len(tokens) < MIN_COLUMNS:
        return False
    return all(IDENTIFIER.match(t) for t in tokens)


def iter_fenced_blocks(text: str):
    """Yield (start_line_number, [lines]) for each fenced code block."""
    lines = text.split("\n")
    inside = False
    buf: List[str] = []
    start = 0
    for n, line in enumerate(lines, 1):
        if FENCE.match(line):
            if inside:
                yield start, buf
                buf = []
            else:
                start = n + 1
            inside = not inside
            continue
        if inside:
            buf.append(line)


def check_table_alignment(rel: str, text: str) -> List[str]:
    """
    Detect a value that overflowed its column and consumed the separator, which
    is how a corrected wait type produced 'SOS_SCHEDULER_YIELD0' with
    blocking_session_id merged into it.

    Comparing column START OFFSETS does not work, and the first version of this
    check failed on 84 rows because of it: right-aligning a numeric column is
    normal and shifts every start. What a merge actually destroys is the column
    COUNT - two fields become one token - so compare the number of fields
    separated by runs of two or more spaces. That tolerates right-alignment,
    tolerates single spaces inside a value ('84, 90'), and still catches the
    merge.

    Only a row with FEWER fields than its header is reported. More fields means
    free text in the final column, which is routine (statement text), not a
    defect.
    """
    problems: List[str] = []
    for start, block in iter_fenced_blocks(text):
        if not block or not looks_like_header(block[0]):
            continue
        expected = len([t for t in GAP.split(block[0].strip()) if t])
        if expected < MIN_COLUMNS:
            continue
        for offset, row in enumerate(block[1:], 1):
            stripped = row.strip()
            if not stripped or set(stripped) <= set("-=+ |"):
                continue
            # An annotation under the sample is prose, not a data row. These
            # appear throughout the references ('-- Only two replicas; NODE2 is
            # the sole DR target') and have no column structure to check.
            if stripped.startswith(("--", "#", "//", "(", "<")):
                continue
            fields = [t for t in GAP.split(stripped) if t]
            if len(fields) >= expected:
                continue
            # A row can legitimately run short when its trailing columns are
            # empty. A merge instead shows up as a field with an identifier run
            # straight into a digit, or two values with no separator at all.
            suspect = [f for f in fields if re.search(r"[A-Za-z_]{3,}\d", f)]
            if not suspect:
                continue
            problems.append(
                "{}:{}: fixed-width table row has {} fields, header has {} - a value "
                "appears merged with its neighbour: {!r} ({!r})".format(
                    rel, start + offset, len(fields), expected,
                    suspect[0][:40], stripped[:60]
                )
            )
    return problems


def rel_matches(pattern: str, rel: str) -> bool:
    """Sentinel path matching: exact, '*' for any file, or '*/suffix'."""
    if pattern == "*":
        return True
    if pattern.startswith("*/"):
        return rel.endswith(pattern[1:])
    return rel == pattern


def main() -> int:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    os.chdir(root)

    # --- the single pass -------------------------------------------------
    contents: Dict[str, str] = {}
    for scan in SCAN_DIRS:
        for dirpath, _dirnames, filenames in os.walk(scan):
            for name in filenames:
                if not name.endswith(SCAN_EXTS):
                    continue
                path = os.path.join(dirpath, name)
                try:
                    with open(path, encoding="utf-8", errors="replace") as handle:
                        contents[path.replace(os.sep, "/")] = handle.read()
                except OSError:
                    continue

    records: List[Tuple[str, str, str]] = []

    def record(status: str, check: str, message: str) -> None:
        records.append((status, check, message))

    if not contents:
        record("FAIL", "50", "no skill files found - run from the repository root")
        for status, check, message in records:
            print("{}\t{}\t{}".format(status, check, message))
        return 0

    # --- Check 50: duplicated literal lists ------------------------------
    for spec in DUPLICATED_LISTS:
        name = str(spec["name"])
        sentinel = str(spec["sentinel"])
        block_re = spec["block"]
        member_re = spec["member"]
        variants: Dict[FrozenSet[str], List[str]] = {}
        for rel, text in sorted(contents.items()):
            if sentinel not in text:
                continue
            for match in block_re.finditer(text):  # type: ignore[union-attr]
                body = match.group(1)
                if sentinel not in body:
                    continue
                members = frozenset(member_re.findall(body))  # type: ignore[union-attr]
                variants.setdefault(members, []).append(rel)

        copies = sum(len(v) for v in variants.values())
        if copies < int(spec["min_copies"]):  # type: ignore[call-overload]
            record("FAIL", "50", "{}: found {} copies, expected at least {} - "
                                 "did a copy lose its sentinel {}?".format(
                                     name, copies, spec["min_copies"], sentinel))
        elif len(variants) != 1:
            detail = "; ".join(
                "{} types in {}".format(len(members), ", ".join(sorted(set(paths))))
                for members, paths in variants.items()
            )
            record("FAIL", "50", "{}: {} copies have DRIFTED into {} variants - {}".format(
                name, copies, len(variants), detail))
        else:
            members = next(iter(variants))
            leaked = [f for f in spec["forbidden"] if f in members]  # type: ignore[union-attr]
            if leaked:
                record("FAIL", "50", "{}: deliberately-kept wait type(s) {} are being "
                                     "EXCLUDED - this shrinks every share computed against "
                                     "the total".format(name, ", ".join(leaked)))
            else:
                record("PASS", "50", "{}: {} copies identical at {} entries, "
                                     "{} documented keeps all in scope".format(
                                         name, copies, len(members),
                                         len(spec["forbidden"])))  # type: ignore[arg-type]

    # --- Check 51: unverified claims carry their label -------------------
    unlabelled: List[str] = []
    asserted = 0
    for spec in UNVERIFIED_CLAIMS:
        for rel, text in sorted(contents.items()):
            if not spec["asserts"].search(text):  # type: ignore[union-attr]
                continue
            asserted += 1
            if not spec["marker"].search(text):  # type: ignore[union-attr]
                unlabelled.append("{} asserts the {} without the Unverified label".format(
                    rel, spec["name"]))
    if unlabelled:
        for message in unlabelled:
            record("FAIL", "51", message)
    else:
        record("PASS", "51", "all {} file(s) asserting an undocumented claim carry "
                             "their Unverified label".format(asserted))

    # --- Check 52: fixed-width table alignment ---------------------------
    misaligned: List[str] = []
    for rel, text in sorted(contents.items()):
        if not rel.endswith(".md"):
            continue
        misaligned.extend(check_table_alignment(rel, text))
    if misaligned:
        for message in misaligned[:20]:
            record("FAIL", "52", message)
        if len(misaligned) > 20:
            record("FAIL", "52", "... and {} further misaligned rows".format(
                len(misaligned) - 20))
    else:
        record("PASS", "52", "fixed-width example tables keep their columns aligned")

    # --- Check 53: claims that were wrong once ---------------------------
    violations: List[str] = []
    for spec in CLAIM_SENTINELS:
        path = str(spec["path"])
        kind = str(spec["kind"])
        pattern = spec["pattern"]
        why = str(spec["why"])
        targets = {r: t for r, t in contents.items() if rel_matches(path, r)}
        if kind == "must":
            if not targets:
                violations.append("{}: file not found, cannot assert - {}".format(path, why))
                continue
            for rel, text in sorted(targets.items()):
                if not pattern.search(text):  # type: ignore[union-attr]
                    violations.append("{}: required claim is missing - {}".format(rel, why))
        else:
            for rel, text in sorted(targets.items()):
                match = pattern.search(text)  # type: ignore[union-attr]
                if match:
                    line = text[: match.start()].count("\n") + 1
                    violations.append("{}:{}: {!r} - {}".format(
                        rel, line, match.group(0)[:60], why))
    if violations:
        for message in violations:
            record("FAIL", "53", message)
    else:
        record("PASS", "53", "all {} claim sentinels hold".format(len(CLAIM_SENTINELS)))

    # --- Check 54: untrusted-artifact-content rule -----------------------
    skill_files = sorted(rel for rel in contents if SKILL_FILE_RE.match(rel))
    if not skill_files:
        record("FAIL", "54", "no skills/*/SKILL.md files found")
    else:
        missing: List[str] = []
        misplaced: List[str] = []
        blocks: Dict[str, List[str]] = {}
        newline = chr(10)
        for rel in skill_files:
            text = contents[rel].replace(chr(13) + newline, newline)
            start = text.find(UNTRUSTED_RULE_HEADING)
            if start < 0:
                missing.append(rel)
                continue
            after = text.find(newline + "## ", start + len(UNTRUSTED_RULE_HEADING))
            if after < 0:
                body, nxt = text[start:], ""
            else:
                body, nxt = text[start:after + 1], text[after + 1:]
            blocks.setdefault(body, []).append(rel)
            # Documented placement: immediately before the "## Input" section.
            if not nxt.startswith(UNTRUSTED_RULE_FOLLOWS):
                misplaced.append(rel)

        if missing:
            record("FAIL", "54", "untrusted-artifact-content rule missing from: {}".format(
                ", ".join(missing)))
        if misplaced:
            record("FAIL", "54", "untrusted-artifact-content rule is not immediately before "
                                 "'{}' in: {}".format(
                                     UNTRUSTED_RULE_FOLLOWS, ", ".join(misplaced)))
        if len(blocks) > 1:
            detail = "; ".join(
                "{} file(s): {}".format(len(paths), ", ".join(paths))
                for paths in blocks.values()
            )
            record("FAIL", "54", "untrusted-artifact-content rule has DRIFTED into {} "
                                 "variants - {}".format(len(blocks), detail))
        if not missing and not misplaced and len(blocks) == 1:
            record("PASS", "54", "untrusted-artifact-content rule present, identical and "
                                 "correctly placed in all {} skills".format(len(skill_files)))

    for status, check, message in records:
        print("{}\t{}\t{}".format(status, check, message))
    return 0


if __name__ == "__main__":
    sys.exit(main())
