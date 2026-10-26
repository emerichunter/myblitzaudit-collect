#!/usr/bin/env bash
# =============================================================================
#  MY Audit Collector v1.0  (bash)
#  Zero Knowledge MySQL/MariaDB snapshot bundle — multi-database aware
#
# =============================================================================
#  PREREQUISITES
# =============================================================================
#
#  Required:
#    * MySQL 5.7+ or MariaDB 10.2+
#    * mysql client + mysqldump in PATH
#    * User with: SELECT on information_schema, SELECT on mysql.user,
#                 SELECT on performance_schema, PROCESS privilege
#    * performance_schema = ON  (strongly recommended)
#
# =============================================================================
#
#  Mirrors my_collect.ps1 — same output format, same bundle structure.
#
#  Usage:
#    ./my_collect.sh [OPTIONS]
#
#  Options:
#    --host HOST              MySQL/MariaDB server hostname (default: localhost)
#    --port PORT              MySQL port (default: 3306)
#    --database DATABASE      Collect one database only (default: all)
#    --user USER              MySQL user (default: root)
#    --password PASSWORD      MySQL password (or export MYSQL_PWD)
#    --socket SOCKET          Unix socket path (alternative to host/port)
#    --output-dir DIR         Output directory (default: my_audit_<VER>_YYYYMMDD_HHMMSS)
#    --docker-container NAME  Run mysql/mysqldump inside this Docker container
#    --no-schema-dump         Skip mysqldump --no-data schema export
#    -h, --help               Show this help
#
#  Examples:
#    # All databases
#    ./my_collect.sh --host localhost --port 3306 --user root --password secret
#
#    # Single database
#    ./my_collect.sh --database mydb --user root --password secret
#
#    # Docker container — all databases
#    ./my_collect.sh --docker-container my-mysql --user root --password secret
#
#    # Unix socket
#    ./my_collect.sh --socket /var/run/mysqld/mysqld.sock --user root
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
MY_HOST="localhost"
MY_PORT=3306
DATABASE=""
MY_USER="root"
MY_PASSWORD=""
MY_SOCKET=""
OUTPUT_DIR=""
DOCKER_CONTAINER=""
NO_SCHEMA_DUMP=0

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
_step() { printf "  \033[36m%s\033[0m\n"       "$*"; }
_ok()   { printf "  \033[32mOK  %s\033[0m\n"   "$*"; }
_warn() { printf "  \033[33mWARN  %s\033[0m\n" "$*"; }
_err()  { printf "  \033[31mERR  %s\033[0m\n"  "$*" >&2; exit 1; }
_gray() { printf "  \033[90m%s\033[0m\n"        "$*"; }

usage() {
  sed -n '/^#  Usage:/,/^[^#]/p' "$0" | sed 's/^#  \{0,2\}//'
  exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)              MY_HOST="$2";          shift 2 ;;
    --port)              MY_PORT="$2";          shift 2 ;;
    --database|--databases)  DATABASE="$2";     shift 2 ;;
    --user)              MY_USER="$2";          shift 2 ;;
    --password)          MY_PASSWORD="$2";      shift 2 ;;
    --socket)            MY_SOCKET="$2";        shift 2 ;;
    --output-dir)        OUTPUT_DIR="$2";       shift 2 ;;
    --docker-container)  DOCKER_CONTAINER="$2"; shift 2 ;;
    --no-schema-dump)    NO_SCHEMA_DUMP=1;      shift ;;
    -h|--help)           usage ;;
    *) _err "Unknown argument: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# Docker client detection (MariaDB 11.4+ uses 'mariadb' instead of 'mysql')
# ---------------------------------------------------------------------------
DOCKER_MYSQL="mysql"
DOCKER_MYSQLDUMP="mysqldump"
DOCKER_SSL=""
DOCKER_HOST=""
if [[ -n "$DOCKER_CONTAINER" ]]; then
  if docker exec "$DOCKER_CONTAINER" sh -c "command -v mysql" &>/dev/null; then
    DOCKER_MYSQL="mysql"
    DOCKER_MYSQLDUMP="mysqldump"
    DOCKER_SSL=""          # MySQL 8.0+ removed --skip-ssl
    DOCKER_HOST=""
  elif docker exec "$DOCKER_CONTAINER" sh -c "command -v mariadb" &>/dev/null; then
    DOCKER_MYSQL="mariadb"
    DOCKER_MYSQLDUMP="mariadb-dump"
    DOCKER_SSL="--skip-ssl"   # MariaDB needs --skip-ssl + -h for TCP
    DOCKER_HOST="-h 127.0.0.1"
  else
    _err "No MySQL/MariaDB client found in container ${DOCKER_CONTAINER}"
  fi
fi

# ---------------------------------------------------------------------------
# Password security: write temp options file (avoid -p on CLI process list)
# ---------------------------------------------------------------------------
MY_OPTS_FILE=""

_write_opts_file() {
  MY_OPTS_FILE="$(mktemp /tmp/blitz_mysql_XXXXXX.cnf 2>/dev/null || mktemp)"
  chmod 600 "$MY_OPTS_FILE"
  printf '[client]\npassword=%s\n' "${MY_PASSWORD}" > "$MY_OPTS_FILE"
}

_cleanup_opts() {
  [[ -n "$MY_OPTS_FILE" ]] && rm -f "$MY_OPTS_FILE" 2>/dev/null || true
  [[ -n "$_MARIADB_TMP_DIR" ]] && rm -rf "$_MARIADB_TMP_DIR" 2>/dev/null || true
  [[ -n "$_VERSION_TMP_DIR" ]] && rm -rf "$_VERSION_TMP_DIR" 2>/dev/null || true
}
trap _cleanup_opts EXIT

# Write options file now if password is set (non-Docker mode needs it later)
[[ -n "$MY_PASSWORD" && -z "$DOCKER_CONTAINER" ]] && _write_opts_file

# ---------------------------------------------------------------------------
# Connection argument builder (non-Docker)
# ---------------------------------------------------------------------------
_conn_args() {
  # Outputs an array of mysql connection flags (no -D flag — caller adds it)
  local args=()
  [[ -n "$MY_OPTS_FILE" ]] && args+=("--defaults-extra-file=${MY_OPTS_FILE}")
  if [[ -n "$MY_SOCKET" ]]; then
    args+=("-S" "$MY_SOCKET")
  else
    args+=("-h" "$MY_HOST" "-P" "$MY_PORT")
  fi
  args+=("-u" "$MY_USER" "--default-character-set=utf8mb4")
  printf '%s\0' "${args[@]}"
}

# ---------------------------------------------------------------------------
# Helpers: _mysql (SQL file → file), _mysql_cmd (inline SQL → stdout)
# ---------------------------------------------------------------------------

# _mysql SQL_FILE OUT_FILE DATABASE
_mysql() {
  local sql_file="$1"
  local out_file="$2"
  local db="$3"

  if [[ -n "$DOCKER_CONTAINER" ]]; then
    local leaf
    leaf="$(basename "$sql_file")-$$"
    local tmp_in="/tmp/blitz_in_${leaf}"
    local tmp_out="/tmp/blitz_out_${leaf}"

    docker cp "$sql_file" "${DOCKER_CONTAINER}:${tmp_in}" > /dev/null

    if [[ -n "$MY_PASSWORD" ]]; then
      docker exec -e "MYSQL_PWD=${MY_PASSWORD}" "$DOCKER_CONTAINER" \
        sh -c "${DOCKER_MYSQL} -u '${MY_USER}' -D '${db}' ${DOCKER_SSL} ${DOCKER_HOST} --default-character-set=utf8mb4 -B -N --raw \
               < '${tmp_in}' > '${tmp_out}' 2>/dev/null" || true
    else
      docker exec "$DOCKER_CONTAINER" \
        sh -c "${DOCKER_MYSQL} -u '${MY_USER}' -D '${db}' ${DOCKER_SSL} ${DOCKER_HOST} --default-character-set=utf8mb4 -B -N --raw \
               < '${tmp_in}' > '${tmp_out}' 2>/dev/null" || true
    fi

    docker cp "${DOCKER_CONTAINER}:${tmp_out}" "$out_file" > /dev/null
    docker exec "$DOCKER_CONTAINER" rm -f "$tmp_in" "$tmp_out" > /dev/null
  else
    local conn_args=()
    while IFS= read -r -d '' arg; do
      conn_args+=("$arg")
    done < <(_conn_args)
    mysql "${conn_args[@]}" -D "$db" -B -N --raw < "$sql_file" > "$out_file" 2>&1 || true
  fi
}

# _mysql_cmd INLINE_SQL DATABASE → stdout
_mysql_cmd() {
  local sql="$1"
  local db="${2:-mysql}"

  if [[ -n "$DOCKER_CONTAINER" ]]; then
    if [[ -n "$MY_PASSWORD" ]]; then
      docker exec -e "MYSQL_PWD=${MY_PASSWORD}" "$DOCKER_CONTAINER" \
        ${DOCKER_MYSQL} -u "$MY_USER" -D "$db" ${DOCKER_SSL} ${DOCKER_HOST} --default-character-set=utf8mb4 -s -N \
        -e "$sql" 2>/dev/null | tr -d '\r'
    else
      docker exec "$DOCKER_CONTAINER" \
        ${DOCKER_MYSQL} -u "$MY_USER" -D "$db" ${DOCKER_SSL} ${DOCKER_HOST} --default-character-set=utf8mb4 -s -N \
        -e "$sql" 2>/dev/null | tr -d '\r'
    fi
  else
    local conn_args=()
    while IFS= read -r -d '' arg; do
      conn_args+=("$arg")
    done < <(_conn_args)
    mysql "${conn_args[@]}" -D "$db" -s -N -e "$sql" 2>/dev/null | tr -d '\r'
  fi
}

# _mysqldump OUT_FILE DATABASE [EXTRA_ARGS...]
_mysqldump() {
  local out_file="$1"
  local db="$2"
  shift 2
  local extra_args=("$@")

  if [[ -n "$DOCKER_CONTAINER" ]]; then
    local leaf
    leaf="$(basename "$out_file")-$$"
    local tmp_out="/tmp/blitz_dump_${leaf}"
    local arg_str
    arg_str="$(printf ' %q' "${extra_args[@]}")"

    if [[ -n "$MY_PASSWORD" ]]; then
      docker exec -e "MYSQL_PWD=${MY_PASSWORD}" "$DOCKER_CONTAINER" \
        sh -c "${DOCKER_MYSQLDUMP} -u '${MY_USER}' ${arg_str} '${db}' > '${tmp_out}' 2>/dev/null" || true
    else
      docker exec "$DOCKER_CONTAINER" \
        sh -c "${DOCKER_MYSQLDUMP} -u '${MY_USER}' ${arg_str} '${db}' > '${tmp_out}' 2>/dev/null" || true
    fi

    docker cp "${DOCKER_CONTAINER}:${tmp_out}" "$out_file" > /dev/null
    docker exec "$DOCKER_CONTAINER" rm -f "$tmp_out" > /dev/null
  else
    local dump_args=()
    [[ -n "$MY_OPTS_FILE" ]] && dump_args+=("--defaults-extra-file=${MY_OPTS_FILE}")
    if [[ -n "$MY_SOCKET" ]]; then
      dump_args+=("-S" "$MY_SOCKET")
    else
      dump_args+=("-h" "$MY_HOST" "-P" "$MY_PORT")
    fi
    dump_args+=("-u" "$MY_USER" "${extra_args[@]}" "$db")
    mysqldump "${dump_args[@]}" > "$out_file" 2>&1 || true
  fi
}

# Human-readable KB
_kb() {
  local f="$1"
  if [[ -f "$f" ]]; then
    local sz
    sz=$(wc -c < "$f" 2>/dev/null || echo 0)
    echo "$(( (sz + 512) / 1024 ))"
  else
    echo 0
  fi
}

# ---------------------------------------------------------------------------
# Step 0: Detect MySQL/MariaDB version and flavor
# ---------------------------------------------------------------------------
MY_VERSION=""
MY_VERSION=$(_mysql_cmd "SELECT VERSION();" "mysql" 2>/dev/null \
  | tr -d '[:space:]') || MY_VERSION=""
MY_VERSION="${MY_VERSION:-unknown}"

IS_MARIADB=false
[[ "$MY_VERSION" == *"MariaDB"* ]] && IS_MARIADB=true

# Parse major.minor
MY_MAJOR=$(echo "$MY_VERSION" | sed 's/[^0-9].*//' | cut -d. -f1 || echo 0)
MY_MINOR=$(echo "$MY_VERSION" | cut -d. -f2 | sed 's/[^0-9].*//' || echo 0)
MY_MAJOR="${MY_MAJOR:-0}"

# Build version tag for bundle directory name
if $IS_MARIADB; then
  VER_TAG="MA${MY_MAJOR}${MY_MINOR}"
else
  VER_TAG="MY${MY_MAJOR}${MY_MINOR}"
fi

# ---------------------------------------------------------------------------
# Setup output directory
# ---------------------------------------------------------------------------
if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="my_audit_${VER_TAG}_$(date +%Y%m%d_%H%M%S)"
fi
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

printf "\n"
printf "  \033[97mMY Audit Collector v1.0 (bash)\033[0m\n"
_gray "Output:  $OUTPUT_DIR"
_gray "Version: ${MY_VERSION}"
$IS_MARIADB && _gray "Flavor:  MariaDB" || _gray "Flavor:  MySQL"
printf "\n"

# ---------------------------------------------------------------------------
# SQL file paths
# ---------------------------------------------------------------------------
CATALOG_SQL="${SCRIPT_DIR}/my_catalog_dump.sql"
STAT_SQL="${SCRIPT_DIR}/my_stat_dump.sql"
GLOBAL_SQL="${SCRIPT_DIR}/my_global_dump.sql"

[[ -f "$CATALOG_SQL" ]] || _warn "my_catalog_dump.sql not found at: ${CATALOG_SQL}"
[[ -f "$STAT_SQL"    ]] || _warn "my_stat_dump.sql not found at: ${STAT_SQL}"
[[ -f "$GLOBAL_SQL"  ]] || _warn "my_global_dump.sql not found at: ${GLOBAL_SQL}"

# ---------------------------------------------------------------------------
# MariaDB SQL rewriting: some performance_schema tables differ between MySQL
# and MariaDB. When MariaDB is detected, create temporary SQL files with
# compatible table references.
# ---------------------------------------------------------------------------
_MARIADB_TMP_DIR=""

_mariadb_rewrite_sql() {
  local src="$1"
  local suffix="$2"

  if ! $IS_MARIADB; then
    printf '%s' "$src"
    return
  fi

  # Create temp directory on first call
  [[ -z "$_MARIADB_TMP_DIR" ]] && _MARIADB_TMP_DIR="$(mktemp -d /tmp/blitz_mariadb_XXXXXX)"

  local dst="${_MARIADB_TMP_DIR}/${suffix}.sql"

  sed \
    -e 's/performance_schema\.global_variables/information_schema.GLOBAL_VARIABLES/g' \
    -e 's/performance_schema\.global_status/information_schema.GLOBAL_STATUS/g' \
    -e 's/performance_schema\.processlist/information_schema.PROCESSLIST/g' \
    -e 's/account_locked, password_expired,/NULL AS `account_locked`, password_expired,/g' \
    -e 's/@@global\.server_uuid/NULL/g' \
    "$src" > "$dst"

  printf '%s' "$dst"
}

if $IS_MARIADB; then
  # Add MariaDB temp dir cleanup to existing trap
  _cleanup_opts() {
    [[ -n "$MY_OPTS_FILE" ]] && rm -f "$MY_OPTS_FILE" 2>/dev/null || true
    [[ -n "$_MARIADB_TMP_DIR" ]] && rm -rf "$_MARIADB_TMP_DIR" 2>/dev/null || true
    [[ -n "$_VERSION_TMP_DIR" ]] && rm -rf "$_VERSION_TMP_DIR" 2>/dev/null || true
  }

  _step "MariaDB detected — applying SQL compatibility rewrites..."
  CATALOG_SQL="$(_mariadb_rewrite_sql "$CATALOG_SQL" "catalog")"
  STAT_SQL="$(_mariadb_rewrite_sql "$STAT_SQL" "stat")"
  GLOBAL_SQL="$(_mariadb_rewrite_sql "$GLOBAL_SQL" "global")"
  _ok "MariaDB rewrites applied"
fi

# ---------------------------------------------------------------------------
# Version-dependent SQL patching: replace references to tables that don't
# exist on older MySQL versions with synthetic subqueries returning empty
# results. MySQL resolves table names at parse time, so IF() guards can't
# protect against missing tables.
#
# Pure bash — the collector must run on a server with nothing but bash and a
# mysql client installed.
# ---------------------------------------------------------------------------
_VERSION_TMP_DIR=""
_version_patch_sql() {
  local src="$1" suffix="$2"
  local dst

  # Decide from the catalogue, not from version arithmetic: a parsed version
  # number cannot tell 8.0.46 (has CHECK_CONSTRAINTS) from 8.0.13 (has not).
  local need_patch=false
  if [[ "$suffix" == "global" ]]; then
    if [[ "$HAS_GLOBAL_GRANTS" == "false" || "$HAS_ROLE_EDGES" == "false" ]]; then need_patch=true; fi
  elif [[ "$suffix" == "catalog" ]]; then
    if [[ "$HAS_CHECK_CONSTRAINTS" == "false" ]]; then need_patch=true; fi
  fi

  if ! $need_patch; then
    printf '%s' "$src"
    return
  fi

  [[ -z "$_VERSION_TMP_DIR" ]] && _VERSION_TMP_DIR="$(mktemp -d /tmp/blitz_version_XXXXXX)"
  dst="${_VERSION_TMP_DIR}/${suffix}.sql"

  local sql
  sql="$(cat "$src" 2>/dev/null)" || { printf '%s' "$src"; return; }

  if [[ "$suffix" == "global" ]]; then
    if [[ "$HAS_GLOBAL_GRANTS" == "false" ]]; then
      sql="${sql//FROM mysql.global_grants)/FROM (SELECT 1 AS USER, \"\" AS HOST, \"\" AS PRIV, \"\" AS WITH_GRANT_OPTION WHERE FALSE) AS mysql_global_grants)}"
    fi
    if [[ "$HAS_ROLE_EDGES" == "false" ]]; then
      sql="${sql//FROM mysql.role_edges)/FROM (SELECT 1 AS FROM_USER, \"\" AS FROM_HOST, \"\" AS TO_USER, \"\" AS TO_HOST, \"\" AS WITH_ADMIN_OPTION WHERE FALSE) AS mysql_role_edges)}"
    fi
  elif [[ "$suffix" == "catalog" ]]; then
    sql="${sql//FROM information_schema.CHECK_CONSTRAINTS cc/FROM (SELECT \"\" AS CONSTRAINT_CATALOG, \"\" AS CONSTRAINT_SCHEMA, \"\" AS CONSTRAINT_NAME, \"\" AS CHECK_CLAUSE WHERE FALSE) cc}"
  fi

  printf '%s\n' "$sql" > "$dst" || { printf '%s' "$src"; return; }
  printf '%s' "$dst"
}

# Apply version patching (only when needed)
_step "Checking version-dependent SQL compatibility..."

# Probe which optional catalogue tables this server actually has. MySQL
# resolves table names at parse time, so a missing table is a hard error and
# IF() cannot guard against it. Probing beats parsing version numbers.
_SCHEMA_PROBE="$(_mysql_cmd "SELECT CONCAT(TABLE_SCHEMA,'.',TABLE_NAME) FROM information_schema.TABLES WHERE TABLE_NAME IN ('CHECK_CONSTRAINTS','global_grants','role_edges');" "information_schema" 2>/dev/null || true)"
HAS_CHECK_CONSTRAINTS=false
HAS_GLOBAL_GRANTS=false
HAS_ROLE_EDGES=false
if grep -qx 'information_schema.CHECK_CONSTRAINTS' <<< "$_SCHEMA_PROBE"; then HAS_CHECK_CONSTRAINTS=true; fi
if grep -qx 'mysql.global_grants' <<< "$_SCHEMA_PROBE"; then HAS_GLOBAL_GRANTS=true; fi
if grep -qx 'mysql.role_edges' <<< "$_SCHEMA_PROBE"; then HAS_ROLE_EDGES=true; fi

CATALOG_SQL="$(_version_patch_sql "$CATALOG_SQL" "catalog")"
GLOBAL_SQL="$(_version_patch_sql "$GLOBAL_SQL" "global")"
_ok "Version compatibility applied"

# ---------------------------------------------------------------------------
# Step 1: Discover databases
# ---------------------------------------------------------------------------
DB_DISCOVERY_SQL="SELECT SCHEMA_NAME FROM information_schema.SCHEMATA \
  WHERE SCHEMA_NAME NOT IN ('mysql','sys','information_schema','performance_schema','_blitz_replay') \
  ORDER BY SCHEMA_NAME;"

declare -a DB_LIST

if [[ -n "$DATABASE" ]]; then
  IFS=',' read -ra DB_LIST <<< "$DATABASE"
  _gray "Selected database(s): ${DATABASE}"
else
  _step "Discovering databases..."
  mapfile -t DB_LIST < <(_mysql_cmd "$DB_DISCOVERY_SQL" "information_schema" 2>/dev/null \
    | grep -v '^[[:space:]]*$' || true)

  if [[ ${#DB_LIST[@]} -eq 0 ]]; then
    _warn "No user databases found. Specify --database explicitly."
    exit 1
  fi
  _ok "Found ${#DB_LIST[@]} database(s): ${DB_LIST[*]}"
fi

# ---------------------------------------------------------------------------
# Step 2: Global snapshot (once per server)
# ---------------------------------------------------------------------------
printf "\n"
_step "Collecting global server snapshot..."
GLOBAL_OUT="${OUTPUT_DIR}/global_snapshot.json"

# Capture SHOW SLAVE/REPLICA STATUS and SHOW BINARY LOGS via shell
# (these SHOW commands can't be easily read from SQL in the dump file)
REPL_STATUS_FILE="${OUTPUT_DIR}/_repl_status_tmp.txt"
BINLOG_FILE="${OUTPUT_DIR}/_binlogs_tmp.txt"

if [[ -n "$DOCKER_CONTAINER" ]]; then
  if [[ -n "$MY_PASSWORD" ]]; then
    docker exec -e "MYSQL_PWD=${MY_PASSWORD}" "$DOCKER_CONTAINER" \
      ${DOCKER_MYSQL} -u "$MY_USER" -s -N \
      -e "SHOW SLAVE STATUS\G; SHOW REPLICA STATUS\G;" \
      > "$REPL_STATUS_FILE" 2>/dev/null || true
    docker exec -e "MYSQL_PWD=${MY_PASSWORD}" "$DOCKER_CONTAINER" \
      ${DOCKER_MYSQL} -u "$MY_USER" -s -N \
      -e "SHOW BINARY LOGS;" \
      > "$BINLOG_FILE" 2>/dev/null || true
  else
    docker exec "$DOCKER_CONTAINER" \
      ${DOCKER_MYSQL} -u "$MY_USER" -s -N \
      -e "SHOW SLAVE STATUS\G; SHOW REPLICA STATUS\G;" \
      > "$REPL_STATUS_FILE" 2>/dev/null || true
    docker exec "$DOCKER_CONTAINER" \
      ${DOCKER_MYSQL} -u "$MY_USER" -s -N \
      -e "SHOW BINARY LOGS;" \
      > "$BINLOG_FILE" 2>/dev/null || true
  fi
fi

if [[ -f "$GLOBAL_SQL" ]]; then
  if _mysql "$GLOBAL_SQL" "$GLOBAL_OUT" "mysql"; then
    _ok "global_snapshot.json  ($(_kb "$GLOBAL_OUT") KB)"
  else
    _warn "global_snapshot.json failed — check user privileges on mysql.user"
  fi
fi

# Clean up temp files
rm -f "$REPL_STATUS_FILE" "$BINLOG_FILE" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Step 3: Catalog + statistics per database
# ---------------------------------------------------------------------------
for db in "${DB_LIST[@]}"; do
  printf "\n"
  _step "━━━ Database: ${db} ━━━"

  if [[ -f "$CATALOG_SQL" ]]; then
    CATALOG_OUT="${OUTPUT_DIR}/catalog_db_${db}.json"
    _step "  Collecting catalog snapshot..."
    if _mysql "$CATALOG_SQL" "$CATALOG_OUT" "$db"; then
      _ok "catalog_db_${db}.json  ($(_kb "$CATALOG_OUT") KB)"
    else
      _warn "catalog_db_${db}.json failed"
    fi
  fi

  if [[ -f "$STAT_SQL" ]]; then
    STAT_OUT="${OUTPUT_DIR}/stat_db_${db}.json"
    _step "  Collecting statistics snapshot..."
    if _mysql "$STAT_SQL" "$STAT_OUT" "$db"; then
      _ok "stat_db_${db}.json  ($(_kb "$STAT_OUT") KB)"
    else
      _warn "stat_db_${db}.json failed"
    fi
  fi
done

# ---------------------------------------------------------------------------
# Step 4: mysqldump --no-data schema export per database
# ---------------------------------------------------------------------------
if [[ "$NO_SCHEMA_DUMP" -eq 0 ]]; then
  printf "\n"
  for db in "${DB_LIST[@]}"; do
    _step "mysqldump --no-data: ${db}..."
    SCHEMA_OUT="${OUTPUT_DIR}/schema_dump_${db}.sql"
    DUMP_ARGS=(
      "--no-data"
      "--triggers"
      "--routines"
      "--events"
      "--skip-lock-tables"
    )
    if [[ "$MY_VERSION" != *"MariaDB"* ]]; then
      DUMP_ARGS+=("--set-gtid-purged=OFF")
    fi
    if _mysqldump "$SCHEMA_OUT" "$db" "${DUMP_ARGS[@]}"; then
      _ok "schema_dump_${db}.sql  ($(_kb "$SCHEMA_OUT") KB)"
    else
      _warn "schema_dump_${db}.sql failed"
    fi
  done
fi

# ---------------------------------------------------------------------------
# Step 5: manifest.json
# ---------------------------------------------------------------------------
printf "\n"
_step "Writing manifest..."

if [[ -n "$DOCKER_CONTAINER" ]]; then
  HOST_VAL="docker:${DOCKER_CONTAINER}"
elif [[ -n "$MY_SOCKET" ]]; then
  HOST_VAL="socket:${MY_SOCKET}"
else
  HOST_VAL="${MY_HOST}:${MY_PORT}"
fi

GENERATED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Escape version string for JSON
MY_VERSION_JSON="${MY_VERSION//\\/\\\\}"
MY_VERSION_JSON="${MY_VERSION_JSON//\"/\\\"}"

# Build databases JSON array
DB_JSON_ARR="["
FIRST=1
for db in "${DB_LIST[@]}"; do
  [[ "$FIRST" -eq 0 ]] && DB_JSON_ARR+=","
  DB_JSON_ARR+="\"${db}\""
  FIRST=0
done
DB_JSON_ARR+="]"

# Build files array
FILES_JSON="["
FIRST=1
for f in "$OUTPUT_DIR"/*.json "$OUTPUT_DIR"/*.sql; do
  [[ -f "$f" ]] || continue
  [[ "$(basename "$f")" == "manifest.json" ]] && continue
  NAME="$(basename "$f")"
  SZ=$(wc -c < "$f" 2>/dev/null || echo 0)
  if date -r "$f" -u +"%Y-%m-%dT%H:%M:%SZ" &>/dev/null; then
    MTIME="$(date -r "$f" -u +"%Y-%m-%dT%H:%M:%SZ")"
  else
    MTIME="$GENERATED_AT"
  fi
  [[ "$FIRST" -eq 0 ]] && FILES_JSON+=","
  FILES_JSON+="{\"name\":\"${NAME}\",\"size_bytes\":${SZ},\"modified\":\"${MTIME}\"}"
  FIRST=0
done
FILES_JSON+="]"

cat > "${OUTPUT_DIR}/manifest.json" <<EOF
{
  "blitz_version": "1.0",
  "generated_at": "${GENERATED_AT}",
  "mysql_version": "${MY_VERSION_JSON}",
  "is_mariadb": ${IS_MARIADB},
  "major_version": ${MY_MAJOR},
  "minor_version": ${MY_MINOR},
  "host": "${HOST_VAL}",
  "databases": ${DB_JSON_ARR},
  "files": ${FILES_JSON}
}
EOF
_ok "manifest.json"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf "\n"
printf "  \033[97mBundle ready: %s\033[0m\n" "$OUTPUT_DIR"
printf "  \033[90mDatabases collected: %s\033[0m\n" "${DB_LIST[*]}"
printf "\n"
for f in "$OUTPUT_DIR"/*; do
  [[ -f "$f" ]] || continue
  NAME="$(basename "$f")"
  SZ=$(wc -c < "$f" 2>/dev/null || echo 0)
  printf "  \033[90m    %-44s %8d KB\033[0m\n" "$NAME" "$(( (SZ + 512) / 1024 ))"
done
printf "\n"
