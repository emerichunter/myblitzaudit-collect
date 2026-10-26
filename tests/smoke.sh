#!/usr/bin/env bash
# =============================================================================
#  Smoke test for myblitzaudit-collect
#
#  Starts a throwaway MySQL/MariaDB container, seeds two schemas, runs the
#  collector and asserts the bundle shape, the manifest and the JSON validity.
#
#  Usage:
#    bash tests/smoke.sh                  # default image mysql:8.0
#    bash tests/smoke.sh mariadb:11.4
#
#  Requires: docker, python3 (for JSON assertions only — the collector itself
#  needs neither).
# =============================================================================
set -euo pipefail

IMAGE="${1:-mysql:8.0}"
CTR="blitz-smoke-$$"
ROOT_PW="smoketest123"
WORK="$(mktemp -d /tmp/blitz_smoke_XXXXXX)"

PASS=0
FAIL=0

_ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
_bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
_info() { printf '  \033[90m%s\033[0m\n' "$1"; }
_step() { printf '\n\033[36m== %s\033[0m\n' "$1"; }

cleanup() {
  docker rm -f "$CTR" > /dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
_step "Prerequisites"
command -v docker > /dev/null || { echo "docker is required"; exit 1; }
_ok "docker"

if [[ "$IMAGE" == *"mariadb"* ]]; then
  CLIENT="mariadb"; DUMP="mariadb-dump"
else
  CLIENT="mysql"; DUMP="mysqldump"
fi
_info "image: $IMAGE (client: $CLIENT)"

# ---------------------------------------------------------------------------
# Container
# ---------------------------------------------------------------------------
_step "Starting $IMAGE"
if [[ "$IMAGE" == *"mariadb"* ]]; then
  docker run -d --name "$CTR" -e MARIADB_ROOT_PASSWORD="$ROOT_PW" "$IMAGE" > /dev/null
else
  docker run -d --name "$CTR" -e MYSQL_ROOT_PASSWORD="$ROOT_PW" "$IMAGE" > /dev/null
fi

READY=false
for _ in $(seq 1 60); do
  if docker exec "$CTR" "$CLIENT" -uroot -p"$ROOT_PW" -e "SELECT 1" > /dev/null 2>&1; then
    READY=true; break
  fi
  sleep 2
done
if $READY; then _ok "container ready"; else _bad "container did not become ready"; exit 1; fi

docker exec -i "$CTR" "$CLIENT" -uroot -p"$ROOT_PW" > /dev/null 2>&1 <<'SQL'
CREATE DATABASE alpha;
CREATE TABLE alpha.t1 (id INT PRIMARY KEY, v VARCHAR(20)) ENGINE=InnoDB;
INSERT INTO alpha.t1 VALUES (1,'a'),(2,'b');
CREATE DATABASE beta;
CREATE TABLE beta.t2 (id INT PRIMARY KEY, n BIGINT, CONSTRAINT chk_n CHECK (n >= 0)) ENGINE=InnoDB;
SQL
_ok "seeded alpha and beta"

# ---------------------------------------------------------------------------
# Collect: whole server
# ---------------------------------------------------------------------------
_step "Collect all databases"
BUNDLE="$WORK/bundle_all"
if bash "$(dirname "$0")/../my_collect.sh" --docker-container "$CTR" --user root \
      --password "$ROOT_PW" --output-dir "$BUNDLE" > "$WORK/collect.log" 2>&1; then
  _ok "collector exited 0"
else
  _bad "collector failed (see below)"; tail -20 "$WORK/collect.log"; exit 1
fi

for f in manifest.json global_snapshot.json catalog_db_alpha.json stat_db_alpha.json \
         catalog_db_beta.json stat_db_beta.json schema_dump_alpha.sql schema_dump_beta.sql; do
  if [[ -s "$BUNDLE/$f" ]]; then _ok "$f"; else _bad "$f missing or empty"; fi
done

if ! head -c 3 "$BUNDLE/manifest.json" | grep -q $'\xef\xbb\xbf'; then
  _ok "manifest.json has no BOM"
else
  _bad "manifest.json starts with a BOM"
fi

_step "Manifest and JSON validity"
python3 - "$BUNDLE" <<'PY'
import json, sys, os, glob
bundle = sys.argv[1]
fails = 0

def check(cond, msg):
    global fails
    print(("  \033[32mPASS\033[0m  " if cond else "  \033[31mFAIL\033[0m  ") + msg)
    if not cond:
        fails += 1

m = json.load(open(os.path.join(bundle, "manifest.json"), encoding="utf-8-sig"))
check(m.get("blitz_version") == "1.0", "manifest blitz_version is 1.0")
check(set(m.get("databases", [])) == {"alpha", "beta"}, "manifest lists alpha and beta")
check(m.get("host", "").startswith("docker:"), "manifest host records the container")
check(len(m.get("files", [])) >= 7, "manifest enumerates the files")
check(all("size_bytes" in f and f["size_bytes"] > 0 for f in m["files"]), "every file has a size")

for f in glob.glob(os.path.join(bundle, "*.json")):
    try:
        json.load(open(f, encoding="utf-8-sig"))
        check(True, os.path.basename(f) + " parses as JSON")
    except Exception as exc:
        check(False, os.path.basename(f) + " is not valid JSON: " + str(exc)[:60])

cat = json.load(open(os.path.join(bundle, "catalog_db_alpha.json"), encoding="utf-8-sig"))
check("tables" in cat or "table_inventory" in cat, "catalog has a table section")
sys.exit(1 if fails else 0)
PY
if [[ $? -eq 0 ]]; then _ok "manifest and JSON assertions"; else _bad "manifest or JSON assertions"; fi

# ---------------------------------------------------------------------------
# Collect: single database
# ---------------------------------------------------------------------------
_step "Collect one database"
ONE="$WORK/bundle_one"
bash "$(dirname "$0")/../my_collect.sh" --docker-container "$CTR" --user root \
     --password "$ROOT_PW" --database alpha --output-dir "$ONE" > "$WORK/collect_one.log" 2>&1 || true

if python3 -c "
import json,sys
m=json.load(open('$ONE/manifest.json',encoding='utf-8-sig'))
sys.exit(0 if m['databases']==['alpha'] else 1)
" 2>/dev/null; then
  _ok "--database alpha collects only alpha"
else
  _bad "--database alpha did not restrict the run"
fi

if [[ -f "$ONE/catalog_db_beta.json" ]]; then
  _bad "beta leaked into a single-database run"
else
  _ok "no files for databases outside the selection"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
_step "Summary"
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ $FAIL -gt 0 ]]; then
  printf '\n\033[31mFAILED\033[0m\n'; exit 1
fi
printf '\n\033[32mAll smoke checks passed (%s)\033[0m\n' "$IMAGE"
