-- =============================================================================
--  MY Stat Dump  v1.0
--  Zero Knowledge MySQL/MariaDB statistics/activity snapshot — no user data
--
-- =============================================================================
--  PREREQUISITES
-- =============================================================================
--
--  Required:
--    * MySQL 5.7+ or MariaDB 10.2+
--    * performance_schema = ON  (strongly recommended; checks @@performance_schema)
--    * PROCESS privilege or SELECT on performance_schema tables
--
--  Strongly recommended:
--    * performance_schema consumers enabled (especially events_statements_*)
--    * slow_query_log = ON  (independently captured by global dump)
--
--  Usage (called automatically by my_collect.sh):
--    mysql -u <user> -p... -D <db> --default-character-set=utf8mb4 -s -N \
--      < my_stat_dump.sql > stat_db_<db>.json
--
--  Output: single JSON document to stdout
--  Compatibility: MySQL 5.7+, MySQL 8.x, MariaDB 10.2+
-- =============================================================================

SET SESSION group_concat_max_len = 1073741824;
SET SESSION net_write_timeout     = 3600;

SELECT CONCAT(
  -- -----------------------------------------------------------------------
  -- _meta
  -- -----------------------------------------------------------------------
  '{"_meta":',
  JSON_OBJECT(
    'type',              'my_stat_dump',
    'version',           '1.0',
    'generated_at',      DATE_FORMAT(UTC_TIMESTAMP(), '%Y-%m-%dT%H:%i:%SZ'),
    'mysql_version',     VERSION(),
    'is_mariadb',        IF(VERSION() LIKE '%MariaDB%', TRUE, FALSE),
    'database',          DATABASE(),
    'ps_available',      IF(@@performance_schema = 1, TRUE, FALSE),
    'uptime_sec',        (SELECT CAST(VARIABLE_VALUE AS UNSIGNED) FROM performance_schema.global_status WHERE VARIABLE_NAME = 'Uptime'),
    'ps_statements_available', IF(
      (SELECT COUNT(*) FROM performance_schema.events_statements_summary_by_digest
       WHERE DIGEST IS NOT NULL LIMIT 1) > 0, TRUE, FALSE)
  ),

  -- -----------------------------------------------------------------------
  -- stat_tables: table I/O counters per database
  -- -----------------------------------------------------------------------
  ',"stat_tables":[',
  (SELECT COALESCE(GROUP_CONCAT(
    JSON_OBJECT(
      'TABLE_NAME',    OBJECT_NAME,
      'COUNT_READ',    CAST(COUNT_READ  AS SIGNED),
      'COUNT_WRITE',   CAST(COUNT_WRITE AS SIGNED),
      'COUNT_FETCH',   CAST(COUNT_FETCH AS SIGNED),
      'COUNT_INSERT',  CAST(COUNT_INSERT AS SIGNED),
      'COUNT_UPDATE',  CAST(COUNT_UPDATE AS SIGNED),
      'COUNT_DELETE',  CAST(COUNT_DELETE AS SIGNED),
      'SUM_TIMER_WAIT_PS', CAST(SUM_TIMER_WAIT AS SIGNED),
      'total_wait_sec', ROUND(SUM_TIMER_WAIT / 1e12, 4)
    )
    ORDER BY SUM_TIMER_WAIT DESC SEPARATOR ','
  ), '')
  FROM performance_schema.table_io_waits_summary_by_table
  WHERE OBJECT_SCHEMA = DATABASE()
    AND OBJECT_SCHEMA NOT IN ('mysql','sys','information_schema','performance_schema')),

  -- -----------------------------------------------------------------------
  -- stat_indexes: per-index I/O, zero reads = unused index candidate
  -- -----------------------------------------------------------------------
  '],"stat_indexes":[',
  (SELECT COALESCE(GROUP_CONCAT(
    JSON_OBJECT(
      'TABLE_NAME',        OBJECT_NAME,
      'INDEX_NAME',        INDEX_NAME,
      'COUNT_READ',        CAST(COUNT_READ  AS SIGNED),
      'COUNT_FETCH',       CAST(COUNT_FETCH AS SIGNED),
      'SUM_TIMER_WAIT_PS', CAST(SUM_TIMER_WAIT AS SIGNED),
      'total_wait_sec',    ROUND(SUM_TIMER_WAIT / 1e12, 4),
      'is_unused',         IF(COUNT_READ = 0, TRUE, FALSE)
    )
    ORDER BY OBJECT_NAME, INDEX_NAME SEPARATOR ','
  ), '')
  FROM performance_schema.table_io_waits_summary_by_index_usage
  WHERE OBJECT_SCHEMA = DATABASE()
    AND OBJECT_SCHEMA NOT IN ('mysql','sys','information_schema','performance_schema')
    AND INDEX_NAME IS NOT NULL),

  -- -----------------------------------------------------------------------
  -- unused_indexes: pre-computed — zero COUNT_READ, non-PRIMARY
  -- -----------------------------------------------------------------------
  '],"unused_indexes":[',
  (SELECT COALESCE(GROUP_CONCAT(
    JSON_OBJECT(
      'TABLE_NAME',  idx.OBJECT_NAME,
      'INDEX_NAME',  idx.INDEX_NAME,
      'COUNT_READ',  CAST(idx.COUNT_READ AS SIGNED),
      'is_unique',   IF(s.NON_UNIQUE = 0, TRUE, FALSE)
    )
    ORDER BY idx.OBJECT_NAME, idx.INDEX_NAME SEPARATOR ','
  ), '')
  FROM performance_schema.table_io_waits_summary_by_index_usage idx
  LEFT JOIN (
    SELECT TABLE_NAME, INDEX_NAME, MIN(NON_UNIQUE) AS NON_UNIQUE
    FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE()
    GROUP BY TABLE_NAME, INDEX_NAME
  ) s ON s.TABLE_NAME = idx.OBJECT_NAME AND s.INDEX_NAME = idx.INDEX_NAME
  WHERE idx.OBJECT_SCHEMA = DATABASE()
    AND idx.OBJECT_SCHEMA NOT IN ('mysql','sys','information_schema','performance_schema')
    AND idx.INDEX_NAME IS NOT NULL
    AND idx.INDEX_NAME != 'PRIMARY'
    AND idx.COUNT_READ = 0),

  -- -----------------------------------------------------------------------
  -- missing_index_candidates: tables with high full-scan count
  -- (COUNT_READ where INDEX_NAME IS NULL = full table scans via performance_schema)
  -- -----------------------------------------------------------------------
  '],"missing_index_candidates":[',
  (SELECT COALESCE(GROUP_CONCAT(
    JSON_OBJECT(
      'TABLE_NAME',      ts.OBJECT_NAME,
      'full_scan_reads', CAST(ts_null.COUNT_READ AS SIGNED),
      'total_reads',     CAST(ts.COUNT_READ AS SIGNED),
      'TABLE_ROWS',      CAST(COALESCE(t.TABLE_ROWS, 0) AS SIGNED),
      'DATA_LENGTH',     CAST(COALESCE(t.DATA_LENGTH, 0) AS SIGNED)
    )
    ORDER BY ts_null.COUNT_READ DESC SEPARATOR ','
  ), '')
  FROM performance_schema.table_io_waits_summary_by_table ts
  JOIN (
    SELECT OBJECT_SCHEMA, OBJECT_NAME, SUM(COUNT_READ) AS COUNT_READ
    FROM performance_schema.table_io_waits_summary_by_index_usage
    WHERE OBJECT_SCHEMA = DATABASE()
      AND INDEX_NAME IS NULL
    GROUP BY OBJECT_SCHEMA, OBJECT_NAME
  ) ts_null ON ts_null.OBJECT_SCHEMA = ts.OBJECT_SCHEMA AND ts_null.OBJECT_NAME = ts.OBJECT_NAME
  LEFT JOIN information_schema.TABLES t
    ON t.TABLE_SCHEMA = ts.OBJECT_SCHEMA AND t.TABLE_NAME = ts.OBJECT_NAME
  WHERE ts.OBJECT_SCHEMA = DATABASE()
    AND ts.OBJECT_SCHEMA NOT IN ('mysql','sys','information_schema','performance_schema')
    AND ts_null.COUNT_READ > 100
    AND COALESCE(t.TABLE_ROWS, 0) > 1000),

  -- -----------------------------------------------------------------------
  -- stat_statements: top queries by total wait time (timer in picoseconds)
  -- -----------------------------------------------------------------------
  '],"stat_statements":[',
  (SELECT COALESCE(GROUP_CONCAT(
    JSON_OBJECT(
      'DIGEST',                    DIGEST,
      'DIGEST_TEXT',               LEFT(DIGEST_TEXT, 2000),
      'SCHEMA_NAME',               SCHEMA_NAME,
      'COUNT_STAR',                CAST(COUNT_STAR AS SIGNED),
      'total_exec_sec',            ROUND(SUM_TIMER_WAIT   / 1e12, 4),
      'avg_exec_ms',               ROUND(AVG_TIMER_WAIT   / 1e9,  3),
      'min_exec_ms',               ROUND(MIN_TIMER_WAIT   / 1e9,  3),
      'max_exec_ms',               ROUND(MAX_TIMER_WAIT   / 1e9,  3),
      'SUM_ROWS_SENT',             CAST(SUM_ROWS_SENT      AS SIGNED),
      'SUM_ROWS_EXAMINED',         CAST(SUM_ROWS_EXAMINED  AS SIGNED),
      'SUM_ROWS_AFFECTED',         CAST(SUM_ROWS_AFFECTED  AS SIGNED),
      'SUM_CREATED_TMP_TABLES',    CAST(SUM_CREATED_TMP_TABLES       AS SIGNED),
      'SUM_CREATED_TMP_DISK_TABLES',CAST(SUM_CREATED_TMP_DISK_TABLES AS SIGNED),
      'SUM_SELECT_FULL_JOIN',      CAST(SUM_SELECT_FULL_JOIN         AS SIGNED),
      'SUM_NO_INDEX_USED',         CAST(SUM_NO_INDEX_USED            AS SIGNED),
      'SUM_NO_GOOD_INDEX_USED',    CAST(SUM_NO_GOOD_INDEX_USED       AS SIGNED),
      'SUM_SORT_ROWS',             CAST(SUM_SORT_ROWS                AS SIGNED),
      'SUM_LOCK_TIME',             CAST(SUM_LOCK_TIME                AS SIGNED),
      'SUM_ERRORS',                CAST(SUM_ERRORS                   AS SIGNED),
      'SUM_WARNINGS',              CAST(SUM_WARNINGS                 AS SIGNED),
      'SUM_SORT_SCAN',             CAST(SUM_SORT_SCAN                AS SIGNED),
      'SUM_SORT_RANGE',            CAST(SUM_SORT_RANGE               AS SIGNED),
      'SUM_SELECT_SCAN',           CAST(SUM_SELECT_SCAN              AS SIGNED),
      'rows_examined_per_sent',    CASE WHEN SUM_ROWS_SENT > 0
                                     THEN ROUND(SUM_ROWS_EXAMINED / SUM_ROWS_SENT, 1)
                                   END,
      'FIRST_SEEN',                DATE_FORMAT(FIRST_SEEN, '%Y-%m-%dT%H:%i:%SZ'),
      'LAST_SEEN',                 DATE_FORMAT(LAST_SEEN,  '%Y-%m-%dT%H:%i:%SZ')
    )
    ORDER BY SUM_TIMER_WAIT DESC SEPARATOR ','
  ), '')
  FROM performance_schema.events_statements_summary_by_digest
  WHERE (SCHEMA_NAME = DATABASE() OR SCHEMA_NAME IS NULL)
    AND DIGEST IS NOT NULL
  ORDER BY SUM_TIMER_WAIT DESC
  LIMIT 200),

  -- -----------------------------------------------------------------------
  -- bloat_estimate: InnoDB DATA_FREE fragmentation per table
  -- -----------------------------------------------------------------------
  '],"bloat_estimate":[',
  (SELECT COALESCE(GROUP_CONCAT(
    JSON_OBJECT(
      'TABLE_NAME',     TABLE_NAME,
      'ENGINE',         ENGINE,
      'DATA_LENGTH',    CAST(COALESCE(DATA_LENGTH, 0) AS SIGNED),
      'DATA_FREE',      CAST(COALESCE(DATA_FREE, 0) AS SIGNED),
      'data_free_pct',  ROUND(
                          COALESCE(DATA_FREE, 0) /
                          NULLIF(COALESCE(DATA_LENGTH, 0) + COALESCE(DATA_FREE, 0), 0) * 100,
                        1),
      'TABLE_ROWS',     CAST(COALESCE(TABLE_ROWS, 0) AS SIGNED)
    )
    ORDER BY DATA_FREE DESC SEPARATOR ','
  ), '')
  FROM information_schema.TABLES
  WHERE TABLE_SCHEMA = DATABASE()
    AND TABLE_SCHEMA NOT IN ('mysql','sys','information_schema','performance_schema')
    AND ENGINE = 'InnoDB'
    AND COALESCE(DATA_FREE, 0) > 0),

  -- -----------------------------------------------------------------------
  -- activity_summary: connection counts by state — NO query text captured
  -- -----------------------------------------------------------------------
  '],"activity_summary":',
  (SELECT JSON_OBJECT(
    'total',        CAST(COUNT(*) AS SIGNED),
    'active',       CAST(SUM(IF(COMMAND NOT IN ('Sleep','Daemon','Binlog Dump','Binlog Dump GTID'), 1, 0)) AS SIGNED),
    'sleeping',     CAST(SUM(IF(COMMAND = 'Sleep', 1, 0)) AS SIGNED),
    'by_command',   (SELECT CONCAT('{',
                      COALESCE(GROUP_CONCAT(
                        CONCAT('"', REPLACE(COMMAND, '"', '\\"'), '":', cnt)
                        SEPARATOR ','
                      ), ''),
                    '}')
                    FROM (SELECT COMMAND, CAST(COUNT(*) AS SIGNED) AS cnt
                          FROM performance_schema.processlist GROUP BY COMMAND) cmd_sub)
  )
  FROM performance_schema.processlist),

  -- -----------------------------------------------------------------------
  -- locks_summary: MySQL 8 uses performance_schema.data_locks;
  --                MySQL 5.7 falls back to information_schema.INNODB_TRX counts
  -- -----------------------------------------------------------------------
  ',"locks_summary":',
  JSON_OBJECT(
    'note', IF(
      VERSION() LIKE '%MariaDB%' OR CAST(SUBSTRING_INDEX(VERSION(), '.', 1) AS UNSIGNED) < 8,
      'data_locks table requires MySQL 8.0+; use information_schema.INNODB_TRX for 5.7',
      'available'
    )
  ),

  '}'
) AS stat_json;
