#Requires -Version 5.1
# =============================================================================
#  MY Audit Collector v1.0  (PowerShell)
#  Zero Knowledge MySQL/MariaDB snapshot bundle — multi-database aware
#
#  Mirrors my_collect.sh — same output format, same bundle structure.
#
#  Usage:
#    .\my_collect.ps1 [OPTIONS]
#
#  Options:
#    -Host HOST              MySQL/MariaDB server hostname (default: localhost)
#    -Port PORT              MySQL port (default: 3306)
#    -Database DATABASE      Collect one database only (default: all)
#    -User USER              MySQL user (default: root)
#    -Password PASSWORD      MySQL password
#    -Socket SOCKET          Unix socket path (Linux/macOS only)
#    -OutputDir DIR          Output directory
#    -DockerContainer NAME   Run mysql inside this Docker container
#    -NoSchemaDump           Skip mysqldump --no-data schema export
#
#  Examples:
#    .\my_collect.ps1 -Host localhost -Port 3306 -User root -Password secret
#    .\my_collect.ps1 -Database mydb -User root -Password secret
#    .\my_collect.ps1 -DockerContainer my-mysql -User root -Password secret
# =============================================================================

param(
    [Alias("Host")]
    [string]$HostName        = "localhost",
    [int]   $Port            = 3306,
    [string]$Database        = "",
    [string]$User            = "root",
    [string]$Password        = "",
    [string]$Socket          = "",
    [string]$OutputDir       = "",
    [string]$DockerContainer = "",
    [switch]$NoSchemaDump
)

$ErrorActionPreference = "Continue"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Decode native command output as UTF-8 so utf8mb4 identifiers survive the
# trip through PowerShell.
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

# ---------------------------------------------------------------------------
# Client binary detection
#   MariaDB 11.4+ ships mariadb / mariadb-dump and no longer provides the
#   mysql / mysqldump symlinks. Detect once, use everywhere.
# ---------------------------------------------------------------------------
$script:MySqlBin     = "mysql"
$script:MySqlDumpBin = "mysqldump"

if ($DockerContainer) {
    $probe = ""
    try { $probe = ((& docker exec $DockerContainer sh -c 'command -v mysql 2>/dev/null || command -v mariadb 2>/dev/null' 2>$null) | Out-String).Trim() } catch { $probe = "" }
    if ($probe -match 'mariadb$') {
        $script:MySqlBin = "mariadb"; $script:MySqlDumpBin = "mariadb-dump"
    }
    if (-not $probe) { Write-Warn "Could not detect a MySQL/MariaDB client in container '$DockerContainer'" }
} elseif (-not (Get-Command $script:MySqlBin -ErrorAction SilentlyContinue)) {
    if (Get-Command mariadb -ErrorAction SilentlyContinue) {
        $script:MySqlBin = "mariadb"; $script:MySqlDumpBin = "mariadb-dump"
    }
}

# ---------------------------------------------------------------------------
# UTF-8 writer without BOM
#   Set-Content / Out-File -Encoding UTF8 prepend a BOM on Windows PowerShell
#   5.1. A BOM on manifest.json breaks the JSON ingest, and a BOM on a .sql
#   dump breaks the mysql client. Always write through this.
# ---------------------------------------------------------------------------
function Write-Utf8NoBom {
    param([Parameter(Mandatory=$true)][string]$Path, [AllowNull()][string]$Text = "")
    $enc = New-Object System.Text.UTF8Encoding($false)
    $full = [System.IO.Path]::GetFullPath($Path)
    [System.IO.File]::WriteAllText($full, $Text, $enc)
}

function Out-FileUtf8NoBom {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(ValueFromPipeline=$true)]$InputObject
    )
    begin { $sb = New-Object System.Text.StringBuilder }
    process { if ($null -ne $InputObject) { [void]$sb.AppendLine([string]$InputObject) } }
    end { Write-Utf8NoBom -Path $Path -Text $sb.ToString() }
}

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
function Write-Step  { param([string]$m) Write-Host "  $m" -ForegroundColor Cyan    }
function Write-Ok    { param([string]$m) Write-Host "  OK  $m" -ForegroundColor Green  }
function Write-Warn  { param([string]$m) Write-Host "  WARN  $m" -ForegroundColor Yellow }
function Write-Err   { param([string]$m) Write-Host "  ERR  $m" -ForegroundColor Red; exit 1 }
function Write-Gray  { param([string]$m) Write-Host "  $m" -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# Temp options file for password security
# ---------------------------------------------------------------------------
$script:OptFile = ""

function Write-OptsFile {
    $script:OptFile = [System.IO.Path]::GetTempFileName()
    Write-Utf8NoBom -Path $script:OptFile -Text "[client]`npassword=$Password`n"
}

function Remove-OptsFile {
    if ($script:OptFile -and (Test-Path $script:OptFile)) {
        Remove-Item $script:OptFile -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Connection argument builder
# ---------------------------------------------------------------------------
function Get-ConnArgs {
    param([string]$Db = "mysql")
    $args = @()
    if ($script:OptFile) { $args += "--defaults-extra-file=$($script:OptFile)" }
    if ($Socket) {
        $args += "-S", $Socket
    } else {
        $args += "-h", $HostName, "-P", $Port
    }
    $args += "-u", $User, "--default-character-set=utf8mb4", "--raw"
    $args
}

# ---------------------------------------------------------------------------
# _mysql: execute SQL file, write output to file
# ---------------------------------------------------------------------------
function Invoke-MySql {
    param([string]$SqlFile, [string]$OutFile, [string]$Db)

    if ($DockerContainer) {
        $leaf  = "blitz_in_$([System.IO.Path]::GetFileNameWithoutExtension($SqlFile))_$PID"
        $tmpIn = "/tmp/$leaf.sql"
        $tmpOut= "/tmp/${leaf}_out.json"

        docker cp $SqlFile "${DockerContainer}:${tmpIn}" | Out-Null
        if ($Password) {
            docker exec -e "MYSQL_PWD=$Password" $DockerContainer `
                sh -c "$script:MySqlBin -u '$User' -D '$Db' --default-character-set=utf8mb4 -s -N --raw < '$tmpIn' > '$tmpOut' 2>&1"
        } else {
            docker exec $DockerContainer `
                sh -c "$script:MySqlBin -u '$User' -D '$Db' --default-character-set=utf8mb4 -s -N --raw < '$tmpIn' > '$tmpOut' 2>&1"
        }
        docker cp "${DockerContainer}:${tmpOut}" $OutFile | Out-Null
        docker exec $DockerContainer rm -f $tmpIn $tmpOut | Out-Null
    } else {
        $connArgs = Get-ConnArgs -Db $Db
        $connArgs += "-D", $Db, "-s", "-N"
        $sqlContent = Get-Content $SqlFile -Raw
        $sqlContent | & $script:MySqlBin $connArgs 2>&1 | Out-FileUtf8NoBom -Path $OutFile
    }
}

# ---------------------------------------------------------------------------
# _mysql_cmd: run inline SQL, return stdout
# ---------------------------------------------------------------------------
function Invoke-MySqlCmd {
    param([string]$Sql, [string]$Db = "mysql")

    if ($DockerContainer) {
        if ($Password) {
            docker exec -e "MYSQL_PWD=$Password" $DockerContainer `
                $script:MySqlBin -u $User -D $Db --default-character-set=utf8mb4 -s -N --raw -e $Sql 2>$null
        } else {
            docker exec $DockerContainer `
                $script:MySqlBin -u $User -D $Db --default-character-set=utf8mb4 -s -N --raw -e $Sql 2>$null
        }
    } else {
        $connArgs = Get-ConnArgs -Db $Db
        $connArgs += "-D", $Db, "-s", "-N", "-e", $Sql
        & $script:MySqlBin $connArgs 2>$null
    }
}

# ---------------------------------------------------------------------------
# _mysqldump: dump schema only
# ---------------------------------------------------------------------------
function Invoke-MySqlDump {
    param([string]$OutFile, [string]$Db, [string[]]$ExtraArgs = @())

    if ($DockerContainer) {
        $leaf   = "blitz_dump_${Db}_$PID"
        $tmpOut = "/tmp/$leaf.sql"
        $argStr = ($ExtraArgs | ForEach-Object { "'$_'" }) -join ' '
        if ($Password) {
            docker exec -e "MYSQL_PWD=$Password" $DockerContainer `
                sh -c "$script:MySqlDumpBin -u '$User' $argStr '$Db' > '$tmpOut' 2>&1"
        } else {
            docker exec $DockerContainer `
                sh -c "$script:MySqlDumpBin -u '$User' $argStr '$Db' > '$tmpOut' 2>&1"
        }
        docker cp "${DockerContainer}:${tmpOut}" $OutFile | Out-Null
        docker exec $DockerContainer rm -f $tmpOut | Out-Null
    } else {
        $dumpArgs = @()
        if ($OptFile) { $dumpArgs += "--defaults-extra-file=$OptFile" }
        if ($Socket) {
            $dumpArgs += "-S", $Socket
        } else {
            $dumpArgs += "-h", $HostName, "-P", $Port
        }
        $dumpArgs += "-u", $User
        $dumpArgs += $ExtraArgs
        $dumpArgs += $Db
        & $script:MySqlDumpBin $dumpArgs | Out-FileUtf8NoBom -Path $OutFile
    }
}

function Get-FileSizeKB {
    param([string]$Path)
    if (Test-Path $Path) {
        [int]([System.IO.FileInfo]$Path).Length / 1024
    } else { 0 }
}

# ---------------------------------------------------------------------------
# Step 0: Write options file + detect version
# ---------------------------------------------------------------------------
if ($Password -and -not $DockerContainer) {
    Write-OptsFile
}

try {
    $MyVersion = Invoke-MySqlCmd -Sql "SELECT VERSION();" -Db "mysql"
    $MyVersion = ($MyVersion -join "").Trim()
} catch {
    $MyVersion = "unknown"
}
if (-not $MyVersion) { $MyVersion = "unknown" }

$IsMariaDB = $MyVersion -like "*MariaDB*"
$parts     = $MyVersion -split '\.'
$MyMajor   = [int]($parts[0] -replace '[^0-9]','')
$MyMinor   = [int]($parts[1] -replace '[^0-9]','')

$VerTag = if ($IsMariaDB) { "MA${MyMajor}${MyMinor}" } else { "MY${MyMajor}${MyMinor}" }

if (-not $OutputDir) {
    $ts        = Get-Date -Format "yyyyMMdd_HHmmss"
    $OutputDir = "my_audit_${VerTag}_${ts}"
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$OutputDir = Resolve-Path $OutputDir

Write-Host ""
Write-Host "  MY Audit Collector v1.0 (PowerShell)" -ForegroundColor White
Write-Gray "Output:  $OutputDir"
Write-Gray "Version: $MyVersion"
Write-Gray "Flavor:  $(if ($IsMariaDB) { 'MariaDB' } else { 'MySQL' })"
Write-Host ""

# ---------------------------------------------------------------------------
# SQL file paths
# ---------------------------------------------------------------------------
$CatalogSql = Join-Path $ScriptDir "my_catalog_dump.sql"
$StatSql    = Join-Path $ScriptDir "my_stat_dump.sql"
$GlobalSql  = Join-Path $ScriptDir "my_global_dump.sql"

foreach ($f in @($CatalogSql, $StatSql, $GlobalSql)) {
    if (-not (Test-Path $f)) { Write-Warn "SQL file not found: $f" }
}

# ---------------------------------------------------------------------------
# Version-dependent SQL patching
#   MySQL resolves table names at parse time, so a missing catalogue table is
#   a hard error that IF() cannot guard against. Probe which optional tables
#   exist and rewrite the SQL to use empty stand-ins where they do not.
# ---------------------------------------------------------------------------
$script:SqlTempDir   = $null
$HasCheckConstraints = $false
$HasGlobalGrants     = $false
$HasRoleEdges        = $false

try {
    $probe = Invoke-MySqlCmd -Sql "SELECT CONCAT(TABLE_SCHEMA,'.',TABLE_NAME) FROM information_schema.TABLES WHERE TABLE_NAME IN ('CHECK_CONSTRAINTS','global_grants','role_edges')" -Db "information_schema"
    foreach ($row in ($probe -split "`n")) {
        switch ($row.Trim()) {
            'information_schema.CHECK_CONSTRAINTS' { $HasCheckConstraints = $true }
            'mysql.global_grants'                  { $HasGlobalGrants = $true }
            'mysql.role_edges'                     { $HasRoleEdges = $true }
        }
    }
} catch { Write-Warn "Schema probe failed: $_" }

function Get-PatchedSql {
    param([string]$Path, [string]$Kind)

    $needMissing = $false
    if ($Kind -eq 'catalog' -and -not $HasCheckConstraints) { $needMissing = $true }
    if ($Kind -eq 'global'  -and ((-not $HasGlobalGrants) -or (-not $HasRoleEdges))) { $needMissing = $true }
    if (-not $needMissing -and -not $IsMariaDB) { return $Path }

    if (-not $script:SqlTempDir) {
        $script:SqlTempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("blitz_sql_" + [System.Guid]::NewGuid().ToString("N").Substring(0,8))
        New-Item -ItemType Directory -Path $script:SqlTempDir -Force | Out-Null
    }

    $sql = Get-Content -LiteralPath $Path -Raw

    # MariaDB exposes performance_schema without the MySQL 8 tables; the same
    # rewrites the bash collector applies with sed.
    if ($IsMariaDB) {
        $sql = $sql.Replace('performance_schema.global_variables', 'information_schema.GLOBAL_VARIABLES')
        $sql = $sql.Replace('performance_schema.global_status',    'information_schema.GLOBAL_STATUS')
        $sql = $sql.Replace('performance_schema.processlist',      'information_schema.PROCESSLIST')
        $sql = $sql.Replace('account_locked, password_expired,',   'NULL AS `account_locked`, password_expired,')
        $sql = $sql.Replace('@@global.server_uuid',                'NULL')
    }

    if ($Kind -eq 'catalog') {
        $sql = $sql.Replace(
            'FROM information_schema.CHECK_CONSTRAINTS cc',
            'FROM (SELECT "" AS CONSTRAINT_CATALOG, "" AS CONSTRAINT_SCHEMA, "" AS CONSTRAINT_NAME, "" AS CHECK_CLAUSE WHERE FALSE) cc')
    } else {
        if (-not $HasGlobalGrants) {
            $sql = $sql.Replace('FROM mysql.global_grants)',
                'FROM (SELECT 1 AS USER, "" AS HOST, "" AS PRIV, "" AS WITH_GRANT_OPTION WHERE FALSE) AS mysql_global_grants)')
        }
        if (-not $HasRoleEdges) {
            $sql = $sql.Replace('FROM mysql.role_edges)',
                'FROM (SELECT 1 AS FROM_USER, "" AS FROM_HOST, "" AS TO_USER, "" AS TO_HOST, "" AS WITH_ADMIN_OPTION WHERE FALSE) AS mysql_role_edges)')
        }
    }

    $dst = Join-Path $script:SqlTempDir "$Kind.sql"
    Write-Utf8NoBom -Path $dst -Text $sql
    return $dst
}

$CatalogSql = Get-PatchedSql -Path $CatalogSql -Kind 'catalog'
$GlobalSql  = Get-PatchedSql -Path $GlobalSql  -Kind 'global'
$StatSql    = Get-PatchedSql -Path $StatSql    -Kind 'stat'

# ---------------------------------------------------------------------------
# Step 1: Discover databases
# ---------------------------------------------------------------------------
$DbDiscoverySql = "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA " +
    "WHERE SCHEMA_NAME NOT IN ('mysql','sys','information_schema','performance_schema','_blitz_replay') " +
    "ORDER BY SCHEMA_NAME;"

$DbList = @()

if ($Database) {
    $DbList = @($Database)
    Write-Gray "Single-database mode: $Database"
} else {
    Write-Step "Discovering databases..."
    $DbList = @(Invoke-MySqlCmd -Sql $DbDiscoverySql -Db "information_schema" |
                Where-Object { $_ -match '\S' })
    if ($DbList.Count -eq 0) {
        Write-Err "No user databases found. Use -Database to specify one explicitly."
    }
    Write-Ok "Found $($DbList.Count) database(s): $($DbList -join ', ')"
}

# ---------------------------------------------------------------------------
# Step 2: Global snapshot
# ---------------------------------------------------------------------------
Write-Host ""
Write-Step "Collecting global server snapshot..."
$GlobalOut = Join-Path $OutputDir "global_snapshot.json"
if (Test-Path $GlobalSql) {
    try {
        Invoke-MySql -SqlFile $GlobalSql -OutFile $GlobalOut -Db "mysql"
        Write-Ok "global_snapshot.json  ($(Get-FileSizeKB $GlobalOut) KB)"
    } catch {
        Write-Warn "global_snapshot.json failed — check privileges on mysql.user"
    }
}

# ---------------------------------------------------------------------------
# Step 3: Catalog + statistics per database
# ---------------------------------------------------------------------------
foreach ($db in $DbList) {
    Write-Host ""
    Write-Step "━━━ Database: $db ━━━"

    if (Test-Path $CatalogSql) {
        $CatalogOut = Join-Path $OutputDir "catalog_db_${db}.json"
        Write-Step "  Collecting catalog snapshot..."
        try {
            Invoke-MySql -SqlFile $CatalogSql -OutFile $CatalogOut -Db $db
            Write-Ok "catalog_db_${db}.json  ($(Get-FileSizeKB $CatalogOut) KB)"
        } catch {
            Write-Warn "catalog_db_${db}.json failed"
        }
    }

    if (Test-Path $StatSql) {
        $StatOut = Join-Path $OutputDir "stat_db_${db}.json"
        Write-Step "  Collecting statistics snapshot..."
        try {
            Invoke-MySql -SqlFile $StatSql -OutFile $StatOut -Db $db
            Write-Ok "stat_db_${db}.json  ($(Get-FileSizeKB $StatOut) KB)"
        } catch {
            Write-Warn "stat_db_${db}.json failed"
        }
    }
}

# ---------------------------------------------------------------------------
# Step 4: Schema dump per database
# ---------------------------------------------------------------------------
if (-not $NoSchemaDump) {
    Write-Host ""
    foreach ($db in $DbList) {
        Write-Step "mysqldump --no-data: $db..."
        $SchemaOut  = Join-Path $OutputDir "schema_dump_${db}.sql"
        $DumpArgs   = @("--no-data","--triggers","--routines","--events",
                        "--skip-lock-tables","--set-gtid-purged=OFF")
        try {
            Invoke-MySqlDump -OutFile $SchemaOut -Db $db -ExtraArgs $DumpArgs
            Write-Ok "schema_dump_${db}.sql  ($(Get-FileSizeKB $SchemaOut) KB)"
        } catch {
            Write-Warn "schema_dump_${db}.sql failed"
        }
    }
}

# ---------------------------------------------------------------------------
# Step 5: manifest.json
# ---------------------------------------------------------------------------
Write-Host ""
Write-Step "Writing manifest..."

$HostVal = if ($DockerContainer) { "docker:$DockerContainer" }
           elseif ($Socket)      { "socket:$Socket"           }
           else                  { "${Host}:${Port}"           }

$GeneratedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$VersionEscaped = $MyVersion -replace '\\','\\' -replace '"','\"'

$DbJsonArr = '[' + (($DbList | ForEach-Object { '"' + $_ + '"' }) -join ',') + ']'

$FilesArr = @()
Get-ChildItem -Path $OutputDir -File | Where-Object { $_.Name -ne 'manifest.json' } | ForEach-Object {
    $sz   = $_.Length
    $mtime= $_.LastWriteTimeUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
    $FilesArr += "{`"name`":`"$($_.Name)`",`"size_bytes`":$sz,`"modified`":`"$mtime`"}"
}
$FilesJson = '[' + ($FilesArr -join ',') + ']'

$Manifest = @"
{
  "blitz_version": "1.0",
  "generated_at": "$GeneratedAt",
  "mysql_version": "$VersionEscaped",
  "is_mariadb": $(if ($IsMariaDB) { 'true' } else { 'false' }),
  "major_version": $MyMajor,
  "minor_version": $MyMinor,
  "host": "$HostVal",
  "databases": $DbJsonArr,
  "files": $FilesJson
}
"@
Write-Utf8NoBom -Path (Join-Path $OutputDir "manifest.json") -Text $Manifest
Write-Ok "manifest.json"

if ($script:SqlTempDir -and (Test-Path $script:SqlTempDir)) {
    Remove-Item $script:SqlTempDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Cleanup and summary
# ---------------------------------------------------------------------------
Remove-OptsFile

Write-Host ""
Write-Host "  Bundle ready: $OutputDir" -ForegroundColor White
Write-Gray "Databases collected: $($DbList -join ', ')"
Write-Host ""
Get-ChildItem -Path $OutputDir -File | ForEach-Object {
    $kb = [int]($_.Length / 1024)
    Write-Host ("    {0,-44} {1,8} KB" -f $_.Name, $kb) -ForegroundColor DarkGray
}
Write-Host ""
