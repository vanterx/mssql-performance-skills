#!/usr/bin/env python3
"""
redact_artifact.py - replace identifying values in a SQL Server diagnostic
artifact with consistent tokens before it is pasted anywhere.

Why consistent tokens rather than a fixed placeholder:

  The value of a diagnostic artifact is in its correlations - the host in the
  ERRORLOG that is also the blocker in the DMV output, the login that appears
  in both the deadlock graph and the trace. A redactor that turns every host
  into "<HOST>" destroys exactly that. This one turns SQLPROD01 into HOST_01
  everywhere it appears, in every file processed with the same --map, so the
  analysis keeps its joins and loses the names.

What it replaces (categories, in the order applied):

  GUID          8-4-4-4-12 hex GUIDs
  EMAIL         addresses
  HOST          UNC server names (\\\\HOST\\share), fully qualified host names
                ending in a common internal or public suffix, and values of
                host-like labels (hostname=, host_name, MachineName, ...)
  USER          DOMAIN\\user tokens (NT SERVICE\\, NT AUTHORITY\\, BUILTIN\\ and
                other built-in principals are kept), user-profile path
                segments (C:\\Users\\<name>), and values of login-like labels
  SID           Windows security identifiers (S-1-5-21-...)
  IP            IPv4 and IPv6 addresses, validated with the ipaddress module
  MAC           hardware addresses
  CARD          card-like numbers in 4-digit groups that pass the Luhn check
                (bare digit runs are left alone: DMV counters are long numbers)

  Tab-, comma- and fixed-width tables whose header names an identity column
  (host_name, login_name, client_hostname, ...) have that column redacted
  row by row until the table ends. A fixed-width row whose cell count differs
  from its header's is left to the pattern rules rather than guessed at.

  A named instance (NODE1\\SQL2022) keeps its instance part and loses its host
  part: HOST_01\\SQL2022.

What it does not do:

  * It is pattern matching. A host name that appears bare in free text, with
    no label, UNC prefix or domain suffix, is not recognised. Read the output
    before sharing it.
  * It does not touch object names, query text, application names or the
    instance part of a named instance. Those are usually what the analysis
    is about.
  * The --map file holds the original values. Keep it local.

Standard library only. Python 3.8+.

    python redact_artifact.py errorlog.txt > errorlog.redacted.txt
    python redact_artifact.py deadlock.xdl -o deadlock.redacted.xdl --map run.map.json
    python redact_artifact.py trace.txt --map run.map.json --report
    some-command | python redact_artifact.py - > out.txt
    python redact_artifact.py --self-test

Requires: Python 3.8+ on the machine holding the artifact. No server access.
Adapted from the PII scrubber in microsoft/SqlNexus SqlNexus.McpServer/PiiScrubber.cs
(MIT), which replaces values with fixed placeholders; this version keeps them
distinguishable.
"""

import argparse
import ipaddress
import json
import os
import re
import sys
from typing import Callable, Dict, List, Match, Optional, Tuple

MAX_BYTES = 256 * 1024 * 1024

BUILTIN_PRINCIPAL_PREFIXES = (
    "NT SERVICE", "NT AUTHORITY", "BUILTIN", "NT VIRTUAL MACHINE",
    "WINDOW MANAGER", "FONT DRIVER HOST", "IIS APPPOOL",
)

HOST_LABELS = (
    "hostname", "host_name", "client_hostname", "clienthostname", "machinename",
    "machine_name", "computername", "computer_name", "servername", "server_name",
    "replica_server_name", "replicaservername", "workstation", "wkstn",
)
USER_LABELS = (
    "loginname", "login_name", "original_login_name", "nt_user_name", "ntusername",
    "nt_domain", "username", "user_name", "server_principal_name", "session_nt_username",
    "owner_login", "login",
)

FQDN_SUFFIXES = (
    r"database\.windows\.net", r"core\.windows\.net", r"cloudapp\.net",
    r"local", r"corp", r"internal", r"intranet", r"lan", r"ad",
    r"com", r"net", r"org", r"gov", r"edu", r"mil", r"io",
)

# Public hosts whose names carry no identity and whose rewriting would break the artifact:
# the showplan XML namespace is http://schemas.microsoft.com/..., and a changed namespace
# makes the plan unparseable.
PUBLIC_HOST_SUFFIXES = ("microsoft.com", "w3.org", "xmlsoap.org", "github.com", "windowsupdate.com")

# DOMAIN\name where the right-hand side looks like a SQL Server instance name is a server and
# instance (NODE1\SQL2022), not a domain account: tokenise the server, keep the instance.
# Case-sensitive on purpose: service accounts such as sqlsvc also contain "sql", and are
# usually lower or mixed case, while instance names in @@SERVERNAME output are upper case.
INSTANCE_NAME = re.compile(r"^(?:MSSQLSERVER|SQLEXPRESS|(?!.*(?:SVC|SERVICE|ACCT|ACCOUNT|ADMIN))[A-Z0-9_]*SQL[A-Z0-9_]*)$")

Token = Callable[[str, str], str]


class Mapper:
    """Consistent value -> token assignment per category, persisted with --map."""

    def __init__(self, data: Optional[Dict[str, Dict[str, str]]] = None) -> None:
        self.data: Dict[str, Dict[str, str]] = data or {}
        self.counts: Dict[str, int] = {}

    def token(self, category: str, value: str) -> str:
        key = value.lower() if category in ("HOST", "USER", "EMAIL", "GUID", "MAC") else value
        table = self.data.setdefault(category, {})
        if key not in table:
            table[key] = "{}_{:02d}".format(category, len(table) + 1)
        self.counts[category] = self.counts.get(category, 0) + 1
        return table[key]


def _luhn_ok(digits: str) -> bool:
    total, double = 0, False
    for ch in reversed(digits):
        d = ord(ch) - 48
        if double:
            d *= 2
            if d > 9:
                d -= 9
        total += d
        double = not double
    return total % 10 == 0


class Redactor:
    def __init__(self, mapper: Mapper) -> None:
        self.m = mapper
        label_alt = "|".join(re.escape(x) for x in HOST_LABELS + USER_LABELS)
        self.rules: List[Tuple[str, "re.Pattern[str]", Callable[[Match[str]], str]]] = [
            ("GUID", re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"),
             lambda mt: self.m.token("GUID", mt.group(0))),
            ("EMAIL", re.compile(r"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"),
             lambda mt: self.m.token("EMAIL", mt.group(0))),
            # Labelled values: hostname="X", "login_name": "X", host_name = 'X', LoginName X
            ("LABEL", re.compile(
                r"(?P<pre>\b(?P<label>" + label_alt + r")\b\s*(?:=|:)\s*(?P<q>[\"']?))"
                r"(?P<val>[A-Za-z0-9][A-Za-z0-9._@\\\-]{0,127}\$?)(?P=q)",
                re.IGNORECASE), self._label),
            ("UNC", re.compile(r"(?<![\w\\])\\\\(?P<host>[A-Za-z0-9][A-Za-z0-9.\-_]{0,253})(?=\\)"),
             lambda mt: "\\\\" + self.m.token("HOST", mt.group("host"))),
            ("PROFILE", re.compile(r"(?P<pre>[A-Za-z]:\\(?:Users|Documents and Settings)\\)(?P<user>[^\\\s\"'<>|,;]+)", re.IGNORECASE),
             lambda mt: mt.group("pre") + self.m.token("USER", mt.group("user"))),
            ("SID", re.compile(r"\bS-1-\d+(?:-\d+){1,14}\b"),
             lambda mt: self.m.token("SID", mt.group(0))),
            ("MAC", re.compile(r"\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b"),
             lambda mt: self.m.token("MAC", mt.group(0))),
            ("IPV4", re.compile(r"(?<![\d.])\d{1,3}(?:\.\d{1,3}){3}(?![\d.])"), self._ipv4),
            ("IPV6", re.compile(r"(?<![0-9A-Fa-f:])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?![0-9A-Fa-f:])"), self._ipv6),
            ("FQDN", re.compile(
                r"\b(?P<fqdn>[A-Za-z0-9](?:[A-Za-z0-9\-]{0,62})(?:\.[A-Za-z0-9\-]{1,63})*\.(?:" + "|".join(FQDN_SUFFIXES) + r"))\b",
                re.IGNORECASE), self._fqdn),
            ("CARD", re.compile(r"(?<![\d-])\d{4}(?:[ -]\d{4}){2,3}(?:[ -]\d{1,3})?(?![\d-])"), self._card),
        ]
        # DOMAIN\user, applied after drive paths are masked so "Program Files\Microsoft" is safe.
        self.domain_user = re.compile(
            r"(?<![\w\\/:.$])(?P<dom>[A-Za-z][A-Za-z0-9_\-]{0,14})\\"
            r"(?P<user>[A-Za-z0-9._\-]{1,64}\$?)(?![\w\\])")
        self.drive_path = re.compile(r"[A-Za-z]:\\(?:[^\\\r\n\"'<>|*?]+\\)*[^\\\r\n\"'<>|*?\s,;]*")
        # Spans the DOMAIN\user pass must not read: built-in principals (some have a space in
        # the domain part) and Perfmon object paths such as "SQLServer:Buffer Manager\Page life
        # expectancy" (no space after the colon, so "Account: CONTOSO\x" is still read). Path
        # segments after a backslash need no mask: the DOMAIN\user lookbehind already skips them.
        self.protected = re.compile(
            r"(?i)\b(?:" + "|".join(re.escape(p) for p in BUILTIN_PRINCIPAL_PREFIXES) + r")\\[\w.$\-]+"
            r"|[A-Za-z$][\w$]*:[A-Za-z][^\\\r\n\",:]*\\[^\r\n\",]*")

    # --- replacement callbacks -------------------------------------------------
    def _label(self, mt: Match[str]) -> str:
        label = mt.group("label").lower()
        val = mt.group("val")
        category = "HOST" if label in HOST_LABELS else "USER"
        if category == "USER" and "\\" in val:
            dom, _, user = val.partition("\\")
            if dom.upper() in BUILTIN_PRINCIPAL_PREFIXES:
                return mt.group(0)
            val_tok = self.m.token("USER", val)
        elif category == "USER" and val.lower() in ("sa", "public", "dbo", "guest", "sys"):
            return mt.group(0)
        else:
            val_tok = self.m.token(category, val)
        return mt.group("pre") + val_tok + mt.group("q")

    def _ipv4(self, mt: Match[str]) -> str:
        try:
            ipaddress.IPv4Address(mt.group(0))
        except ValueError:
            return mt.group(0)
        return self.m.token("IP", mt.group(0))

    def _ipv6(self, mt: Match[str]) -> str:
        s = mt.group(0)
        if s.count(":") < 2 or not re.search(r"[0-9A-Fa-f]", s):
            return s
        try:
            ipaddress.IPv6Address(s)
        except ValueError:
            return s
        return self.m.token("IP", s)

    def _fqdn(self, mt: Match[str]) -> str:
        name = mt.group("fqdn")
        if name.count(".") < 1 or re.fullmatch(r"[\d.]+", name):
            return name
        if any(name.lower() == sfx or name.lower().endswith("." + sfx) for sfx in PUBLIC_HOST_SUFFIXES):
            return name
        return self.m.token("HOST", name)

    def _card(self, mt: Match[str]) -> str:
        digits = re.sub(r"\D", "", mt.group(0))
        if 13 <= len(digits) <= 19 and _luhn_ok(digits):
            return self.m.token("CARD", mt.group(0))
        return mt.group(0)

    def _domain_user(self, mt: Match[str]) -> str:
        dom = mt.group("dom")
        if dom.upper() in BUILTIN_PRINCIPAL_PREFIXES or dom.upper().startswith("MSSQL"):
            return mt.group(0)
        if INSTANCE_NAME.match(mt.group("user")):
            return self.m.token("HOST", dom) + "\\" + mt.group("user")
        return self.m.token("USER", mt.group(0))

    # --- line and table handling ----------------------------------------------
    def redact_text(self, text: str) -> str:
        masked: List[str] = []

        def mask(mt: Match[str]) -> str:
            masked.append(mt.group(0))
            return "\x00{}\x00".format(len(masked) - 1)

        for _name, pattern, fn in self.rules:
            text = pattern.sub(fn, text)
        text = self.drive_path.sub(mask, text)
        text = self.protected.sub(mask, text)
        text = self.domain_user.sub(self._domain_user, text)
        return re.sub(r"\x00(\d+)\x00", lambda mt: masked[int(mt.group(1))], text)

    def redact_document(self, text: str) -> str:
        """Redact line by line, tracking tables whose header names an identity column."""
        out: List[str] = []
        table: Optional[Tuple[str, List[Tuple[int, int, str]]]] = None
        for line in text.split("\n"):
            body = line.rstrip("\r")
            tail = line[len(body):]
            if not body.strip():
                table = None
            elif table is not None and not re.fullmatch(r"[\s\-=+|]+", body):
                body = self._redact_row(body, table)
            header = self._identity_header(body)
            if header is not None:
                table = header
                out.append(line)
                continue
            out.append(self.redact_text(body) + tail)
        return "\n".join(out)

    def _cell_token(self, raw: str, category: str) -> Optional[str]:
        value = raw.strip().strip('"')
        if not value or value.upper() in ("NULL", "N/A", "-"):
            return None
        if category == "USER" and (value.split("\\")[0].upper() in BUILTIN_PRINCIPAL_PREFIXES
                                   or value.lower() in ("sa", "public", "dbo", "guest", "sys")):
            return None
        return self.m.token(category, value)

    def _redact_row(self, row: str, table: Tuple[str, List[Tuple[int, int, str]]]) -> str:
        kind, cols = table
        if kind in ("\t", ","):
            cells = row.split(kind)
            for idx, _end, category in cols:
                if idx < len(cells):
                    tok = self._cell_token(cells[idx], category)
                    if tok:
                        cells[idx] = cells[idx].replace(cells[idx].strip().strip('"'), tok)
            return kind.join(cells)
        # Fixed-width: split on runs of 2+ spaces and map cells to header columns by index.
        # Slicing by the header's offsets corrupts rows whose values overrun a column, which
        # pasted DMV output often has; a row whose cell count differs from the header is left
        # to the line rules rather than guessed at.
        header_count, = [c for i, c, _cat in cols if i == -1] or [0]
        cells = [(m.start(), m.group(0)) for m in re.finditer(r"\S+(?: \S+)*", row)]
        if len(cells) != header_count:
            return row
        for idx, _unused, category in sorted(cols, reverse=True):
            if idx < 0 or idx >= len(cells):
                continue
            pos, value = cells[idx]
            tok = self._cell_token(value, category)
            if tok:
                row = row[:pos] + tok.ljust(len(value)) + row[pos + len(value):]
        return row

    @staticmethod
    def _identity_header(line: str) -> Optional[Tuple[str, List[Tuple[int, int, str]]]]:
        def category(name: str) -> Optional[str]:
            name = name.lower()
            return "HOST" if name in HOST_LABELS else "USER" if name in USER_LABELS else None

        for delim in ("\t", ","):
            if delim not in line:
                continue
            cols = [c.strip().strip('"') for c in line.split(delim)]
            if not all(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_ ]*", c) for c in cols if c):
                continue
            found = [(i, 0, category(c)) for i, c in enumerate(cols) if category(c)]
            if found:
                return delim, [(i, e, c) for i, e, c in found if c]
        # fixed-width: three or more identifier tokens separated by runs of 2+ spaces
        tokens = [(m.start(), m.group(0)) for m in re.finditer(r"\S+", line)]
        if len(tokens) >= 3 and all(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", t) for _p, t in tokens):
            gaps_ok = all(tokens[i + 1][0] - (tokens[i][0] + len(tokens[i][1])) >= 2 for i in range(len(tokens) - 1))
            found = [(i, 0, category(name)) for i, (_pos, name) in enumerate(tokens) if category(name)]
            if gaps_ok and found:
                # (-1, column count, "") carries the header width for the row matcher
                return "fixed", [(i, e, c) for i, e, c in found if c] + [(-1, len(tokens), "")]
        return None


SELF_TESTS = [
    ("2026-10-06 10:32:16.12 Logon Login failed for user 'CONTOSO\\jsmith'. [CLIENT: 10.20.30.40]",
     ["USER_01", "IP_01"], ["jsmith", "10.20.30.40"]),
    ('<process id="p1" hostname="APPSRV07" loginname="CONTOSO\\svc_app" clientapp="OrderService">',
     ["HOST_01", "USER_01", "OrderService"], ["APPSRV07", "svc_app"]),
    ("BACKUP DATABASE to \\\\BKPSRV01\\sqlbackups\\Sales.bak and C:\\Program Files\\Microsoft SQL Server\\MSSQL16\\DATA",
     ["HOST_01", "C:\\Program Files\\Microsoft SQL Server"], ["BKPSRV01"]),
    ("Service account NT SERVICE\\MSSQLSERVER and NT AUTHORITY\\SYSTEM", ["NT SERVICE\\MSSQLSERVER", "NT AUTHORITY\\SYSTEM"], []),
    ("\\\\SQLHOST01\\Process(sqlservr)\\% Processor Time,\\\\SQLHOST01\\Memory\\Available MBytes",
     ["\\\\HOST_01\\Process(sqlservr)", "\\\\HOST_01\\Memory"], ["SQLHOST01"]),
    ("Connect to sqlprod01.contoso.com and myserver.database.windows.net", ["HOST_01", "HOST_02"], ["contoso", "myserver"]),
    ("total_worker_time 4111111111111111 at 10:32:16.000", ["4111111111111111", "10:32:16.000"], []),
    ("card 4111 1111 1111 1111 SID S-1-5-21-3623811015-3361044348-30300820-1013", ["CARD_01", "SID_01"], ["4111 1111"]),
    ("C:\\Users\\jdoe\\AppData\\Local\\Temp", ["C:\\Users\\USER_01\\AppData"], ["jdoe"]),
    ("--- setspn -L CONTOSO\\sqlsvc ---", ["setspn -L USER_01"], ["sqlsvc"]),
    ("--- Get-ADUser CONTOSO\\sqlsvc -Properties X ---", ["Get-ADUser USER_01 -Properties"], ["sqlsvc"]),
    ('"\\\\SQLHOST01\\SQLServer:Buffer Manager\\Page life expectancy","x"', ["SQLServer:Buffer Manager\\Page life expectancy"], ["SQLHOST01", "USER_"]),
    ("SQLServer:SQL Statistics\\Batch Requests/sec", ["SQLServer:SQL Statistics\\Batch Requests/sec"], ["USER_"]),
    ("Account: CONTOSO\\sqlsvc", ["Account: USER_01"], ["sqlsvc"]),
    ("host_name    program_name    login_name", ["host_name    program_name    login_name"], ["HOST_", "USER_"]),
    ('<ShowPlanXML xmlns="http://schemas.microsoft.com/sqlserver/2004/07/showplan">', ["schemas.microsoft.com"], ["HOST_"]),
    ("Primary: NODE1\\SQL2022 | replica NODE2\\MSSQLSERVER", ["HOST_01\\SQL2022", "HOST_02\\MSSQLSERVER"], ["NODE1", "NODE2"]),
    ("run as CONTOSO\\SQLSVC and CONTOSO\\sqladmin", ["USER_01", "USER_02"], ["SQLSVC", "sqladmin"]),
]

TABLE_TEST = "session_id\thost_name\tlogin_name\tprogram_name\n52\tAPPSRV07\tCONTOSO\\svc_app\tOrderService\n53\tAPPSRV07\tsa\tSSMS\n"
FIXED_TEST = (
    "session_id  host_name    program_name   login_name\n"
    "----------  -----------  -------------  ---------------\n"
    "71          WKS-FIN-14   OrderEntry     CORP\\svc_orders\n"
    "84          APP-NODE-02  OrderService   sa\n"
)


def self_test() -> int:
    failures = 0
    for i, (text, must, must_not) in enumerate(SELF_TESTS, 1):
        out = Redactor(Mapper()).redact_document(text)
        for s in must:
            if s not in out:
                print("FAIL {}: expected {!r} in {!r}".format(i, s, out)); failures += 1
        for s in must_not:
            if s in out:
                print("FAIL {}: {!r} still present in {!r}".format(i, s, out)); failures += 1
    m = Mapper()
    out = Redactor(m).redact_document(TABLE_TEST)
    for s in ("HOST_01\tUSER_01", "OrderService"):
        if s not in out:
            print("FAIL table: expected {!r} in {!r}".format(s, out)); failures += 1
    if out.count("HOST_01") != 2:
        print("FAIL table: host not tokenised consistently: {!r}".format(out)); failures += 1
    out = Redactor(Mapper()).redact_document(FIXED_TEST)
    lines = out.split("\n")
    if "WKS-FIN-14" in out or "APP-NODE-02" in out or "svc_orders" in out:
        print("FAIL fixed: value left in {!r}".format(out)); failures += 1
    if lines[2].index("OrderEntry") != FIXED_TEST.split("\n")[2].index("OrderEntry"):
        print("FAIL fixed: column alignment changed: {!r}".format(lines[2])); failures += 1
    if " sa" not in lines[3]:
        print("FAIL fixed: built-in login sa should be kept: {!r}".format(lines[3])); failures += 1
    # consistency across documents sharing a mapper
    shared = Mapper()
    a = Redactor(shared).redact_document('hostname="APPSRV07"')
    b = Redactor(shared).redact_document("\\\\APPSRV07\\share\\x")
    if "HOST_01" not in a or "HOST_01" not in b:
        print("FAIL consistency: {!r} / {!r}".format(a, b)); failures += 1
    print("self-test: {} failure(s)".format(failures))
    return 1 if failures else 0


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="Redact identifying values in a SQL Server diagnostic artifact.")
    ap.add_argument("path", nargs="?", help="artifact file, or - for stdin")
    ap.add_argument("-o", "--output", help="write here instead of stdout")
    ap.add_argument("--map", help="JSON file of value-to-token mappings; read if present, updated after")
    ap.add_argument("--report", action="store_true", help="print replacement counts per category to stderr")
    ap.add_argument("--self-test", action="store_true", help="run built-in checks and exit")
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()
    if not args.path:
        ap.error("path is required (use - for stdin)")

    if args.path == "-":
        data = sys.stdin.buffer.read(MAX_BYTES + 1)
    else:
        if os.path.getsize(args.path) > MAX_BYTES:
            print("refusing: file larger than {} bytes".format(MAX_BYTES), file=sys.stderr)
            return 2
        with open(args.path, "rb") as fh:
            data = fh.read()
    if len(data) > MAX_BYTES:
        print("refusing: input larger than {} bytes".format(MAX_BYTES), file=sys.stderr)
        return 2

    # SSMS writes .sqlplan and some exports as UTF-16; detect by BOM.
    if data[:2] in (b"\xff\xfe", b"\xfe\xff"):
        text, encoding = data.decode("utf-16"), "utf-16"
    else:
        text, encoding = data.decode("utf-8-sig", errors="replace"), "utf-8"

    mapping: Dict[str, Dict[str, str]] = {}
    if args.map and os.path.exists(args.map):
        with open(args.map, encoding="utf-8") as fh:
            mapping = json.load(fh)
    mapper = Mapper(mapping)
    result = Redactor(mapper).redact_document(text)

    if args.output:
        with open(args.output, "w", encoding=encoding, newline="") as fh:
            fh.write(result)
    else:
        sys.stdout.write(result)

    if args.map:
        with open(args.map, "w", encoding="utf-8") as fh:
            json.dump(mapper.data, fh, indent=2, sort_keys=True)
    if args.report:
        for category in sorted(mapper.counts):
            print("{:6} {}".format(category, mapper.counts[category]), file=sys.stderr)
        print("Read the output before sharing it: bare names in free text are not recognised.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
