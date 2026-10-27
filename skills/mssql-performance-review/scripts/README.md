# mssql-performance-review — Scripts

| File | Runtime | Purpose |
|------|---------|---------|
| [redact_artifact.py](redact_artifact.py) | Python 3.8+, standard library only | Replace identifying values in an artifact with consistent tokens before sharing it |

The orchestrator never runs this script. You run it on the machine that holds
the artifacts, read the output, and paste or attach the redacted copy.

## redact_artifact.py

```bash
python redact_artifact.py errorlog.txt > errorlog.redacted.txt
python redact_artifact.py deadlock.xdl -o deadlock.redacted.xdl --map run.map.json
python redact_artifact.py trace.txt --map run.map.json --report
some-command | python redact_artifact.py - > out.txt
python redact_artifact.py --self-test
```

| Option | Effect |
|--------|--------|
| `path` or `-` | Artifact file, or standard input. UTF-16 files with a byte-order mark are read correctly |
| `-o FILE` | Write the redacted copy here instead of standard output |
| `--map FILE` | JSON file of value-to-token mappings. Read if present, updated afterwards |
| `--report` | Print replacement counts per category to standard error |
| `--self-test` | Run the built-in fixtures and exit non-zero on any failure |

### Why consistent tokens

A diagnostic artifact is valuable for its correlations: the host in the ERRORLOG
that is also the blocker in the DMV output, the login that appears in both the
deadlock graph and the trace. A redactor that turns every host into `<HOST>`
destroys those joins. This one turns `SQLPROD01` into `HOST_01` everywhere it
appears, and in every file processed with the same `--map`, so the analysis
keeps its joins and loses the names.

Run every artifact for one review through the same `--map` file. Without it,
each file numbers its tokens from `_01` and the same token can name two
different hosts.

### What it replaces

| Category | Matches |
|----------|---------|
| `GUID` | 8-4-4-4-12 hexadecimal GUIDs |
| `EMAIL` | Email addresses |
| `HOST` | UNC server names, fully qualified host names, values of host-like labels (`hostname=`, `client_hostname:`), identity columns in tables, the host part of `HOST\INSTANCE` |
| `USER` | `DOMAIN\user` tokens, user-profile path segments, values of login-like labels, identity columns in tables |
| `SID` | Windows security identifiers |
| `IP` | IPv4 and IPv6 addresses, validated with the `ipaddress` module |
| `MAC` | Hardware addresses |
| `CARD` | Card-like numbers in 4-digit groups that pass the Luhn check |

Kept unchanged on purpose:

- Built-in principals: `NT SERVICE\`, `NT AUTHORITY\`, `BUILTIN\` and similar.
- Perfmon counter paths (`Buffer Manager\Page life expectancy`) and drive paths.
- Public schema hosts such as `schemas.microsoft.com`, because rewriting the
  showplan namespace makes a `.sqlplan` unparseable. A redacted plan still
  loads in `extract_plan.py`.
- Object names, query text, application names and the instance part of a named
  instance. These are usually what the analysis is about.
- Bare digit runs, because DMV counters are long numbers.

### Limits

- It is pattern matching. A host name that appears bare in free text, with no
  label, UNC prefix, domain suffix or identity column, is not recognised.
  Read the output before sharing it.
- The `--map` file holds the original values. Keep it on the machine where the
  artifacts came from.
- Literal values inside query text (a customer name in a `WHERE` clause) are not
  touched. Review query text by hand, or share a parameterised form of it.

Requires: Python 3.8+ on the machine holding the artifact. No server access.

Adapted from the PII scrubber in `microsoft/SqlNexus` (`SqlNexus.McpServer/PiiScrubber.cs`,
MIT). That scrubber replaces values with fixed placeholders; this version keeps them
distinguishable.
