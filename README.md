# myblitzaudit-collect

Zero-knowledge MySQL and MariaDB snapshot collector. One shell script (or one
PowerShell script) turns a server into a portable bundle of schema metadata and
aggregate statistics — and leaves every row behind.

No agent. No cloud. No Python. Just bash or PowerShell plus the `mysql` client
you already have.

This repository is the **collector only**. It produces a bundle; it does not
render reports. Sample reports and a real bundle are published in
[myblitzaudit-examples](https://github.com/emerichunter/myblitzaudit-examples).

---

## Handing this to a client

`make-client-kit.sh` builds a zip containing only what the client needs: the two
collectors, the dump SQL, both acceptance tests, the collection guide and a
checksum file. No engine, no report SQL.

```bash
./make-client-kit.sh --version 1.0
# dist/myblitzaudit-kit-1.0.zip  + SHA-256
```

The guide inside the kit, [docs/collection-guide.md](docs/collection-guide.md),
is written for the client's DBA: grants, one command per platform, verification,
packaging, and a table of exactly what leaves their server for their security
reviewer.

## Quick start

Linux / macOS:

```bash
./my_collect.sh --host db.example.com --user audit_reader
```

Windows (PowerShell 5.1 or 7):

```powershell
$env:MYSQL_PWD = "..."
.\my_collect.ps1 -HostName db.example.com -User audit_reader
```

Docker (client tools run inside the container, so versions always match):

```bash
./my_collect.sh --docker-container mysql-prod --user root
```

One schema only, custom destination:

```bash
./my_collect.sh --host localhost --user root --database appdb --output-dir /tmp/audit
```

Every connectable non-system schema is collected by default. The replay
engine's own `_blitz_replay` shadow schema is skipped, so replaying a bundle on
the same server never contaminates the next collection. Use `--database`
one or more times to restrict the run. `bash my_collect.sh --help` lists
everything.

---

## What leaves your server

| Collected | Not collected |
|---|---|
| Schema, table, column, index and foreign-key definitions | Any table row |
| Table sizes, row counts, `DATA_FREE`, engine, collation | Any column value |
| Users, hosts, grants, auth plugins, account flags | Password hashes (`authentication_string` / `Password` are never selected) |
| Global variables and status counters | Query literals — only `DIGEST_TEXT` from `performance_schema`, which is normalised to `?` placeholders |
| Replication status, binlog configuration, binlog file list | Binlog contents |
| `performance_schema` statement digests, waits, locks, temp-table spills | `SQL_TEXT`, `QUERY_SAMPLE_TEXT`, or any raw statement text |
| Views, routines, triggers, events (definitions and definers) | Definer passwords, credentials, connection strings |
| Server version, uptime, OS-level metrics when `sys_collect.sh` is used | Files from the data directory |

The schema dump is `mysqldump --no-data`: structure only, never `--data`.

Bundles are plain UTF-8 JSON and SQL. You can open them, diff them, or grep
them before sending anything anywhere. That is the point.

---

## Privileges

The collector only reads. A working grant set:

```sql
CREATE USER 'audit_reader'@'%' IDENTIFIED BY '...';
GRANT SELECT, PROCESS, REPLICATION CLIENT ON *.* TO 'audit_reader'@'%';
GRANT SELECT ON performance_schema.* TO 'audit_reader'@'%';
```

- `SELECT` on each audited schema — schema dump and `information_schema`.
- `SELECT` on `mysql.user` (or the `PROCESS` privilege) — user and grant inventory.
- `SELECT` on `performance_schema.*` — statement digests and waits.
- `REPLICATION CLIENT` — binlog listing and replica status.

`GRANT SELECT ON mysql.*` also exposes `authentication_string` at the grant
layer even though the collector never selects it. If that matters to you, grant
column by column on `mysql.user` instead.

---

## What you get

```text
my_audit_MY80_20260510_143022/
  global_snapshot.json           server-wide: users, variables, status, replication
  catalog_db_appdb.json          schema metadata for one database
  stat_db_appdb.json             performance counters for one database
  schema_dump_appdb.sql          DDL only (mysqldump --no-data)
  manifest.json                  what was collected, when, from where
```

`manifest.json`:

```json
{
  "blitz_version": "1.0",
  "generated_at": "2026-05-10T14:30:22Z",
  "mysql_version": "8.0.46",
  "is_mariadb": false,
  "major_version": 8,
  "minor_version": 0,
  "host": "db.example.com:3306",
  "databases": ["appdb", "reporting"],
  "files": [
    { "name": "catalog_db_appdb.json", "size_bytes": 6813, "modified": "2026-05-10T14:30:19Z" }
  ]
}
```

---

## Verify a bundle

A bundle that "ran fine" is not a bundle that is usable. `tests/battle-test.ps1`
checks the failure modes that matter, on any machine, before you send anything:

```powershell
.\tests\battle-test.ps1 -Bundle .\my_audit_MY80_20260510_143022
```

Or collect and verify in one step:

```powershell
.\tests\battle-test.ps1 -Collect -Bundle .\evidence `
    -Target "-HostName db.example.com -User audit_reader"
```

It asserts that every JSON file parses as strict UTF-8, that no file carries a
byte-order mark, that no SQL error text was written where a snapshot should be,
that every file listed in the manifest exists at the recorded size, that the
per-database catalog and statistics files are present and not truncated, that
the global snapshot carries no password hashes, and — with `-ReportsDir` — that
the rendered reports reference no external URL.

Exit code 0 means every check passed. The run writes
`battle-test-evidence.json` into the bundle with the PowerShell version, the OS,
the file inventory and the findings, so a result can be sent back as evidence
rather than as an opinion.

## Supported versions

MySQL 5.7, 8.0, 8.4 and MariaDB 10.6, 10.11, 11.4. The collector probes the
server's own catalogue for optional tables (`CHECK_CONSTRAINTS`,
`mysql.global_grants`, `mysql.role_edges`) and rewrites its SQL to empty
stand-ins when they are absent, so one SQL file works across the range.

MariaDB differences (`performance_schema` exposes different tables, no
`@@server_uuid`, no `account_locked`) are handled by both collectors. The test
matrix in the engine repository runs all six images.

---

## Requirements

- `bash` 4+ and a `mysql` client on the machine running the collection, or
  `--docker-container` to use the one inside a container.
- PowerShell 5.1+ on Windows. MariaDB 11.4+ ships `mariadb` and `mariadb-dump`
  instead of `mysql` and `mysqldump`; the collector detects which pair exists.
- No Python, no jq, no agents, no network access beyond the database port.

---

## What this does not do

It does not generate reports. Report SQL, the replay engine and the HTML/JSON
renderers are proprietary and live in a separate private repository. That is
deliberate: the collector is the part you must be able to audit, and the
analysis is the part you are paying for.

To see what a finished report looks like, open the samples in
[myblitzaudit-examples](https://github.com/emerichunter/myblitzaudit-examples).

---

## License

MIT. See [LICENSE](LICENSE).
