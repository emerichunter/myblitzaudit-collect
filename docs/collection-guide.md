# myblitzaudit — Collection Guide

**Audience:** the DBA or system administrator running this on a client server.
**Time:** 10 to 20 minutes, most of it waiting.
**What it does:** reads schema metadata and aggregate statistics from a MySQL or
MariaDB server and writes them to a folder. It does not read your data, does not
install anything, and does not need internet access.

You will end up with a folder to zip and send back. Reports are produced
off-site from that folder.

---

## 1. What you need before you start

| Requirement | Detail |
|---|---|
| Server access | A MySQL/MariaDB account that can read metadata (see step 2) |
| Client tools | `mysql` and `mysqldump` on the machine where you run this. On Windows: the MySQL client, usually in `C:\Program Files\MySQL\MySQL Server X.Y\bin` |
| Shell | Bash (Linux/macOS) or PowerShell 5.1+ (Windows) |
| Disk | A few hundred MB free where the bundle is written |
| Network | Nothing outbound. Only a connection to the database |
| Downtime | None. Every statement is a read |

If the database is only reachable from a specific host, run the collection from
that host. If it runs in Docker, see the Docker variant in step 3.

---

## 2. Create a read-only account

Run this as an administrator on the server. Replace the password.

```sql
CREATE USER 'blitz_ro'@'%' IDENTIFIED BY 'choose-a-password';
GRANT SELECT, PROCESS, REPLICATION CLIENT ON *.* TO 'blitz_ro'@'%';
GRANT SELECT ON performance_schema.* TO 'blitz_ro'@'%';
```

That is the whole privilege set:

- `SELECT` — schema metadata and the schema dump.
- `PROCESS` — the process list and `mysql.user` inventory.
- `REPLICATION CLIENT` — replica status and the binlog file list.
- `SELECT` on `performance_schema` — statement digests and wait statistics.

If your security policy forbids `SELECT ON *.*`, grant per schema instead and
accept that the global snapshot will be partial.

Drop the account when the collection is finished:

```sql
DROP USER 'blitz_ro'@'%';
```

---

## 3. Run the collection

Unzip the kit, open a shell in that folder, and run one command.

**Windows (PowerShell):**

```powershell
$env:MYSQL_PWD = "choose-a-password"
.\my_collect.ps1 -HostName db.example.com -User blitz_ro
```

**Linux / macOS:**

```bash
MYSQL_PWD='choose-a-password' ./my_collect.sh --host db.example.com --user blitz_ro
```

**Database inside Docker on this machine:**

```bash
./my_collect.sh --docker-container mysql-prod --user root
```

**One database only:**

```bash
./my_collect.sh --host db.example.com --user blitz_ro --database appdb
```

Keep the password out of your shell history where possible — `MYSQL_PWD` and
`$env:MYSQL_PWD` above are read by the client and never written to disk by the
collector.

Every connectable non-system schema is collected by default. Add `--database`
(or `-Database` on Windows) as many times as needed to restrict the run.

### What you should see

```text
  MY Audit Collector v1.0

  Detected: MySQL 8.0.46 (MySQL)
  Output:   my_audit_MY80_20261024_143022

  Discovering databases...
  OK  Found 3 database(s): appdb, reporting, shopdb

  --- Database: appdb ---
    Collecting catalog snapshot...      OK  catalog_db_appdb.json  (21 KB)
    Collecting statistics snapshot...   OK  stat_db_appdb.json     (35 KB)
  ...
  Bundle ready: my_audit_MY80_20261024_143022
```

If a line says `WARN` instead of `OK`, the step failed. Note which one and see
section 6. Do not send a bundle that has warnings until you have read them.

---

## 4. Verify the bundle before sending

A collection that "looked fine" can still be unusable. The kit includes a
checker; run it:

**Windows:**

```powershell
.\tests\battle-test.ps1 -Bundle .\my_audit_MY80_20261024_143022
```

**Linux (needs python3, which is standard):**

```bash
bash tests/battle-test.sh my_audit_MY80_20261024_143022
```

Both print one line per check and finish with either `RESULT: PASSED` or
`RESULT: FAILED` plus the reason. If it fails, re-run the collection once; if it
fails again, send us the output — that is exactly the information needed to fix
it.

---

## 5. Package and return

**Windows:**

```powershell
Compress-Archive -Path .\my_audit_MY80_20261024_143022 -DestinationPath .\bundle.zip
Get-FileHash .\bundle.zip -Algorithm SHA256
```

**Linux:**

```bash
zip -r bundle.zip my_audit_MY80_20261024_143022
sha256sum bundle.zip
```

Send `bundle.zip` and the hash. If your security policy blocks the hash in the
same channel, send it in a second message.

The bundle contains no row data, so it usually passes DLP review without
discussion. Section 7 is there for the reviewer who asks.

---

## 6. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `ERROR 1045 Access denied` | Wrong password, or the account is restricted to a different host | `SELECT user, host FROM mysql.user WHERE user='blitz_ro';` |
| `ERROR 1227 Access denied; you need the PROCESS privilege` | Grants incomplete | Re-run the `GRANT` statements in step 2 |
| `catalog_db_*.json is suspiciously small` | The server denied a metadata query | Check the file — it will contain the SQL error verbatim |
| `global_snapshot.json` is 0 KB | The global query failed, usually a privilege | Verify `SELECT` on `mysql.user` or the `PROCESS` privilege |
| `mysql: command not found` | Client tools not on `PATH` | Add the MySQL `bin` directory to `PATH`, or use `--docker-container` |
| `Cannot overwrite variable Host` | You are running an old collector | Use the kit as provided; the parameter is `-HostName` |
| `performance_schema` sections empty | `performance_schema` is off | Normal on MariaDB. The report still works; note it for us |
| Collection takes minutes | Large schemas, many tables | Expected. Let it finish |

---

## 7. What leaves your server

For the security reviewer.

| Collected | Never collected |
|---|---|
| Schema, table, column, index and foreign-key definitions | Any table row |
| Object sizes, row counts, engine, collation | Any column value |
| Users, hosts, grants, authentication plugin, account flags | Password hashes |
| Global variables and status counters | Connection strings or credentials |
| Replication status, binlog configuration and file list | Binlog contents |
| Normalised statement digests (`?` in place of literals) | Raw SQL text, query samples |
| Views, routines, triggers, events and their definers | Data files |
| Server version, uptime, OS counters (optional sys script) | Environment variables holding secrets |

Everything is plain UTF-8 JSON and SQL. You can grep it, diff it, or review it
line by line before sending. Please do — that is the reason the collector is
published as source.

---

## 8. Questions people ask

**Does this read my data?** No. Every query reads catalogue tables
(`information_schema`, `performance_schema`, `mysql.user`) or aggregate counters.
The schema dump is `mysqldump --no-data`.

**Can I run it on a replica?** Yes, and it is the better choice. Statistics will
describe the replica, which is usually close enough; the configuration section
will describe the replica's settings.

**Can I run it twice?** Yes. Each run writes a new timestamped folder.

**Does it need internet?** No. Nothing is uploaded; the folder is yours until you
send it.

**What if it fails halfway?** Delete the folder and run it again. There is no
state to clean up on the server.

**Can I see the code first?** Yes, that is expected.
`https://github.com/emerichunter/myblitzaudit-collect`

---

## 9. What happens next

Send the zip. We replay it into a throwaway database on our side and produce the
HTML reports. The source server is never contacted again — the bundle is the
complete input.

If you want the OS-level section (CPU, memory, disk, I/O, kernel parameters),
also run:

```bash
./sys_collect.sh            # Linux
```

and include its output folder in the zip.
