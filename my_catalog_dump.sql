-- =============================================================================
--  MY Catalog Dump  v1.0
--  Zero Knowledge MySQL/MariaDB schema/structure snapshot — no user data
--
-- =============================================================================
--  PREREQUISITES
-- =============================================================================
--
--  Required:
--    * MySQL 5.7+ or MariaDB 10.2+
--    * A user with SELECT on information_schema (default for all users)
--      Plus SELECT on mysql.user for global dump (my_global_dump.sql)
--
--  Usage (called automatically by my_collect.sh):
--    mysql -u <user> -p... -D <db> --default-character-set=utf8mb4 -s -N \
--      < my_catalog_dump.sql > catalog_db_<db>.json
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
    'type',             'my_catalog_dump',
    'version',          '1.0',
    'generated_at',     DATE_FORMAT(UTC_TIMESTAMP(), '%Y-%m-%dT%H:%i:%SZ'),
    'mysql_version',    VERSION(),
    'is_mariadb',       IF(VERSION() LIKE '%MariaDB%', TRUE, FALSE),
    'database',         DATABASE(),
    'hostname',         @@hostname,
    'charset_server',   @@character_set_server,
    'collation_server', @@collation_server,
    'lower_case_table_names', @@lower_case_table_names,
    'performance_schema_enabled', IF(@@performance_schema = 1, TRUE, FALSE)
  ),

  -- -----------------------------------------------------------------------
  -- schemata
  -- -----------------------------------------------------------------------
  ',"schemata":[',
  (SELECT COALESCE(GROUP_CONCAT(
    JSON_OBJECT(
      'SCHEMA_NAME',                  SCHEMA_NAME,
      'DEFAULT_CHARACTER_SET_NAME',   DEFAULT_CHARACTER_SET_NAME,
      'DEFAULT_COLLATION_NAME',       DEFAULT_COLLATION_NAME
    )
    ORDER BY SCHEMA_NAME SEPARATOR ','
  ), '')
  FROM information_schema.SCHEMATA
  WHERE SCHEMA_NAME = DATABASE()),

  -- -----------------------------------------------------------------------
  -- tables
  -- -----------------------------------------------------------------------
  '],"tables":[',
  (SELECT COALESCE(GROUP_CONCAT(
    JSON_OBJECT(
      'TABLE_NAME',       t.TABLE_NAME,
      'TABLE_TYPE',       t.TABLE_TYPE,
      'ENGINE',           t.ENGINE,
      'ROW_FORMAT',       t.ROW_FORMAT,
      'TABLE_ROWS',       CAST(COALESCE(t.TABLE_ROWS, 0) AS SIGNED),
      'AVG_ROW_LENGTH',   CAST(COALESCE(t.AVG_ROW_LENGTH, 0) AS SIGNED),
      'DATA_LENGTH',      CAST(COALESCE(t.DATA_LENGTH, 0) AS SIGNED),
      'INDEX_LENGTH',     CAST(COALESCE(t.INDEX_LENGTH, 0) AS SIGNED),
      'DATA_FREE',        CAST(COALESCE(t.DATA_FREE, 0) AS SIGNED),
      'AUTO_INCREMENT',   CAST(t.AUTO_INCREMENT AS SIGNED),
      'TABLE_COLLATION',  t.TABLE_COLLATION,
      'TABLE_COMMENT',    t.TABLE_COMMENT,
      'total_bytes',      CAST(COALESCE(t.DATA_LENGTH, 0) + COALESCE(t.INDEX_LENGTH, 0) AS SIGNED),
      'data_free_ratio',  ROUND(
                            COALESCE(t.DATA_FREE, 0) /
                            NULLIF(COALESCE(t.DATA_LENGTH, 0) + COALESCE(t.DATA_FREE, 0), 0) * 100,
                          2),
      'has_pk',           IF(pk.TABLE_NAME IS NOT NULL, TRUE, FALSE),
      'charset_ok',       IF(t.TABLE_COLLATION LIKE 'utf8mb4%' OR t.TABLE_COLLATION IS NULL, TRUE, FALSE)
    )
    ORDER BY t.TABLE_NAME SEPARATOR ','
  ), '')
  FROM information_schema.TABLES t
  LEFT JOIN (
    SELECT TABLE_NAME FROM information_schema.TABLE_CONSTRAINTS
    WHERE TABLE_SCHEMA = DATABASE() AND CONSTRAINT_TYPE = 'PRIMARY KEY'
  ) pk ON pk.TABLE_NAME = t.TABLE_NAME
  WHERE t.TABLE_SCHEMA = DATABASE()
    AND t.TABLE_SCHEMA NOT IN ('mysql','sys','information_schema','performance_schema')),

  -- -----------------------------------------------------------------------
  -- columns
  -- -----------------------------------------------------------------------
  '],"columns":[',
  (SELECT COALESCE(GROUP_CONCAT(
    JSON_OBJECT(
      'TABLE_NAME',              TABLE_NAME,
      'COLUMN_NAME',             COLUMN_NAME,
      'ORDINAL_POSITION',        ORDINAL_POSITION,
      'COLUMN_DEFAULT',          COLUMN_DEFAULT,
      'IS_NULLABLE',             IS_NULLABLE,
      'DATA_TYPE',               DATA_TYPE,
      'CHARACTER_MAXIMUM_LENGTH',CAST(CHARACTER_MAXIMUM_LENGTH AS SIGNED),
      'NUMERIC_PRECISION',       CAST(NUMERIC_PRECISION AS SIGNED),
      'NUMERIC_SCALE',           CAST(NUMERIC_SCALE AS SIGNED),
      'CHARACTER_SET_NAME',      CHARACTER_SET_NAME,
      'COLLATION_NAME',          COLLATION_NAME,
      'COLUMN_TYPE',             COLUMN_TYPE,
      'COLUMN_KEY',              COLUMN_KEY,
      'EXTRA',                   EXTRA,
      'COLUMN_COMMENT',          COLUMN_COMMENT,
      'charset_ok',              IF(CHARACTER_SET_NAME IS NULL OR CHARACTER_SET_NAME LIKE 'utf8mb4%', TRUE, FALSE)
    )
    ORDER BY TABLE_NAME, ORDINAL_POSITION SEPARATOR ','
  ), '')
  FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = DATABASE()
    AND TABLE_SCHEMA NOT IN ('mysql','sys','information_schema','performance_schema')),

  -- -----------------------------------------------------------------------
  -- indexes (one row per index, column list aggregated)
  -- -----------------------------------------------------------------------
  '],"indexes":[',
  (SELECT COALESCE(GROUP_CONCAT(
    JSON_OBJECT(
      'TABLE_NAME',   TABLE_NAME,
      'INDEX_NAME',   INDEX_NAME,
      'NON_UNIQUE',   IF(is_non_unique = 0, FALSE, TRUE),
      'INDEX_TYPE',   idx_type,
      'CARDINALITY',  CAST(cardinality_max AS SIGNED),
      'num_cols',     CAST(num_cols AS SIGNED),
      'col_seq',      col_seq,
      'is_primary',   IF(INDEX_NAME = 'PRIMARY', TRUE, FALSE),
      'is_unique',    IF(is_non_unique = 0 AND INDEX_NAME != 'PRIMARY', TRUE, FALSE),
      'INDEX_COMMENT',idx_comment
    )
    ORDER BY TABLE_NAME, INDEX_NAME SEPARATOR ','
  ), '')
  FROM (
    SELECT
      TABLE_NAME, INDEX_NAME,
      MIN(NON_UNIQUE) AS is_non_unique,
      MIN(INDEX_TYPE) AS idx_type,
      MAX(CARDINALITY) AS cardinality_max,
      COUNT(*) AS num_cols,
      GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ',') AS col_seq,
      MIN(INDEX_COMMENT) AS idx_comment
    FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_SCHEMA NOT IN ('mysql','sys','information_schema','performance_schema')
    GROUP BY TABLE_SCHEMA, TABLE_NAME, INDEX_NAME
  ) idx_agg),

  -- -----------------------------------------------------------------------
  -- constraints
  -- -----------------------------------------------------------------------
  '],"constraints":[',
  (SELECT COALESCE(GROUP_CONCAT(
    JSON_OBJECT(
      'CONSTRAINT_NAME',      tc.CONSTRAINT_NAME,
      'TABLE_NAME',           tc.TABLE_NAME,
      'CONSTRAINT_TYPE',      tc.CONSTRAINT_TYPE,
      'REFERENCED_TABLE_NAME',rc.REFERENCED_TABLE_NAME,
      'UPDATE_RULE',          rc.UPDATE_RULE,
      'DELETE_RULE',          rc.DELETE_RULE
    )
    ORDER BY tc.TABLE_NAME, tc.CONSTRAINT_NAME SEPARATOR ','
  ), '')
  FROM information_schema.TABLE_CONSTRAINTS tc
  LEFT JOIN information_schema.REFERENTIAL_CONSTRAINTS rc
    ON  rc.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA
    AND rc.CONSTRAINT_NAME   = tc.CONSTRAINT_NAME
  WHERE tc.TABLE_SCHEMA = DATABASE()
    AND tc.TABLE_SCHEMA NOT IN ('mysql','sys','information_schema','performance_schema')),

  -- -----------------------------------------------------------------------
  -- key_column_usage (FK column details)
  -- -----------------------------------------------------------------------
  '],"key_column_usage":[',
  (SELECT COALESCE(GROUP_CONCAT(
    JSON_OBJECT(
      'CONSTRAINT_NAME',        CONSTRAINT_NAME,
      'TABLE_NAME',             TABLE_NAME,
      'COLUMN_NAME',            COLUMN_NAME,
      'ORDINAL_POSITION',       ORDINAL_POSITION,
      'REFERENCED_TABLE_SCHEMA',REFERENCED_TABLE_SCHEMA,
      'REFERENCED_TABLE_NAME',  REFERENCED_TABLE_NAME,
      'REFERENCED_COLUMN_NAME', REFERENCED_COLUMN_NAME
    )
    ORDER BY TABLE_NAME, CONSTRAINT_NAME, ORDINAL_POSITION SEPARATOR ','
  ), '')
  FROM information_schema.KEY_COLUMN_USAGE
  WHERE TABLE_SCHEMA = DATABASE()
    AND TABLE_SCHEMA NOT IN ('mysql','sys','information_schema','performance_schema')
    AND REFERENCED_TABLE_NAME IS NOT NULL),

  -- -----------------------------------------------------------------------
  -- unindexed_fks: FK columns that are NOT the leftmost column of any index
  -- -----------------------------------------------------------------------
  '],"unindexed_fks":[',
  (SELECT COALESCE(GROUP_CONCAT(
    JSON_OBJECT(
      'TABLE_NAME',       kcu.TABLE_NAME,
      'COLUMN_NAME',      kcu.COLUMN_NAME,
      'CONSTRAINT_NAME',  kcu.CONSTRAINT_NAME,
      'REFERENCED_TABLE', kcu.REFERENCED_TABLE_NAME
    )
    ORDER BY kcu.TABLE_NAME, kcu.COLUMN_NAME SEPARATOR ','
  ), '')
  FROM information_schema.KEY_COLUMN_USAGE kcu
  WHERE kcu.TABLE_SCHEMA = DATABASE()
    AND kcu.REFERENCED_TABLE_NAME IS NOT NULL
    AND kcu.ORDINAL_POSITION = 1
    AND NOT EXISTS (
      SELECT 1 FROM information_schema.STATISTICS s
      WHERE s.TABLE_SCHEMA = kcu.TABLE_SCHEMA
        AND s.TABLE_NAME   = kcu.TABLE_NAME
        AND s.COLUMN_NAME  = kcu.COLUMN_NAME
        AND s.SEQ_IN_INDEX = 1
    )),

  -- -----------------------------------------------------------------------
  -- duplicate_indexes: same column sequence on same table
  -- -----------------------------------------------------------------------
  '],"duplicate_indexes":[',
  (SELECT COALESCE(GROUP_CONCAT(
    JSON_OBJECT(
      'TABLE_NAME',   TABLE_NAME,
      'col_seq',      col_seq,
      'index_names',  index_names,
      'index_count',  CAST(index_count AS SIGNED)
    )
    ORDER BY TABLE_NAME SEPARATOR ','
  ), '')
  FROM (
    SELECT
      TABLE_NAME,
      col_seq,
      GROUP_CONCAT(DISTINCT INDEX_NAME ORDER BY INDEX_NAME SEPARATOR ', ') AS index_names,
      COUNT(DISTINCT INDEX_NAME) AS index_count
    FROM (
      SELECT TABLE_NAME, INDEX_NAME,
        GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ',') AS col_seq
      FROM information_schema.STATISTICS
      WHERE TABLE_SCHEMA = DATABASE()
        AND TABLE_SCHEMA NOT IN ('mysql','sys','information_schema','performance_schema')
      GROUP BY TABLE_SCHEMA, TABLE_NAME, INDEX_NAME
    ) idx_seqs
    GROUP BY TABLE_NAME, col_seq
    HAVING COUNT(DISTINCT INDEX_NAME) > 1
  ) dup_sub),

  -- -----------------------------------------------------------------------
  -- redundant_indexes: index A is redundant when index B covers A's columns
  --                    as a prefix (same order, B has more columns)
  -- -----------------------------------------------------------------------
  '],"redundant_indexes":[',
  (SELECT COALESCE(GROUP_CONCAT(
    JSON_OBJECT(
      'TABLE_NAME',     a_tbl,
      'redundant_index',a_idx,
      'redundant_cols', a_cols,
      'covered_by',     b_idx,
      'covering_cols',  b_cols
    )
    SEPARATOR ','
  ), '')
  FROM (
    SELECT
      a.TABLE_NAME AS a_tbl, a.INDEX_NAME AS a_idx, a.col_seq AS a_cols,
      b.INDEX_NAME AS b_idx, b.col_seq AS b_cols
    FROM (
      SELECT TABLE_SCHEMA, TABLE_NAME, INDEX_NAME,
        GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ',') AS col_seq,
        COUNT(*) AS num_cols
      FROM information_schema.STATISTICS
      WHERE TABLE_SCHEMA = DATABASE()
        AND TABLE_SCHEMA NOT IN ('mysql','sys','information_schema','performance_schema')
      GROUP BY TABLE_SCHEMA, TABLE_NAME, INDEX_NAME
    ) a
    JOIN (
      SELECT TABLE_SCHEMA, TABLE_NAME, INDEX_NAME,
        GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ',') AS col_seq,
        COUNT(*) AS num_cols
      FROM information_schema.STATISTICS
      WHERE TABLE_SCHEMA = DATABASE()
        AND TABLE_SCHEMA NOT IN ('mysql','sys','information_schema','performance_schema')
      GROUP BY TABLE_SCHEMA, TABLE_NAME, INDEX_NAME
    ) b ON  b.TABLE_SCHEMA = a.TABLE_SCHEMA
        AND b.TABLE_NAME   = a.TABLE_NAME
        AND b.INDEX_NAME  != a.INDEX_NAME
        AND b.col_seq LIKE CONCAT(a.col_seq, ',%')
        AND a.num_cols < b.num_cols
    WHERE a.INDEX_NAME != 'PRIMARY'
  ) red_sub),

  -- -----------------------------------------------------------------------
  -- views
  -- -----------------------------------------------------------------------
  '],"views":[',
  (SELECT COALESCE(GROUP_CONCAT(
    JSON_OBJECT(
      'TABLE_NAME',    TABLE_NAME,
      'IS_UPDATABLE',  IS_UPDATABLE,
      'SECURITY_TYPE', SECURITY_TYPE,
      'DEFINER',       DEFINER,
      'VIEW_DEF_SNIPPET', LEFT(VIEW_DEFINITION, 500)
    )
    ORDER BY TABLE_NAME SEPARATOR ','
  ), '')
  FROM information_schema.VIEWS
  WHERE TABLE_SCHEMA = DATABASE()
    AND TABLE_SCHEMA NOT IN ('mysql','sys','information_schema','performance_schema')),

  -- -----------------------------------------------------------------------
  -- routines (no ROUTINE_DEFINITION — may contain sensitive logic)
  -- -----------------------------------------------------------------------
  '],"routines":[',
  (SELECT COALESCE(GROUP_CONCAT(
    JSON_OBJECT(
      'ROUTINE_NAME',      ROUTINE_NAME,
      'ROUTINE_TYPE',      ROUTINE_TYPE,
      'DATA_TYPE',         DATA_TYPE,
      'SECURITY_TYPE',     SECURITY_TYPE,
      'DEFINER',           DEFINER,
      'IS_DETERMINISTIC',  IS_DETERMINISTIC,
      'SQL_DATA_ACCESS',   SQL_DATA_ACCESS,
      'CREATED',           DATE_FORMAT(CREATED, '%Y-%m-%dT%H:%i:%SZ'),
      'LAST_ALTERED',      DATE_FORMAT(LAST_ALTERED, '%Y-%m-%dT%H:%i:%SZ')
    )
    ORDER BY ROUTINE_TYPE, ROUTINE_NAME SEPARATOR ','
  ), '')
  FROM information_schema.ROUTINES
  WHERE ROUTINE_SCHEMA = DATABASE()
    AND ROUTINE_SCHEMA NOT IN ('mysql','sys','information_schema','performance_schema')),

  -- -----------------------------------------------------------------------
  -- triggers (action_statement truncated to 200 chars)
  -- -----------------------------------------------------------------------
  '],"triggers":[',
  (SELECT COALESCE(GROUP_CONCAT(
    JSON_OBJECT(
      'TRIGGER_NAME',        TRIGGER_NAME,
      'EVENT_OBJECT_TABLE',  EVENT_OBJECT_TABLE,
      'ACTION_TIMING',       ACTION_TIMING,
      'EVENT_MANIPULATION',  EVENT_MANIPULATION,
      'DEFINER',             DEFINER,
      'ACTION_SNIPPET',      LEFT(ACTION_STATEMENT, 200)
    )
    ORDER BY EVENT_OBJECT_TABLE, TRIGGER_NAME SEPARATOR ','
  ), '')
  FROM information_schema.TRIGGERS
  WHERE TRIGGER_SCHEMA = DATABASE()
    AND TRIGGER_SCHEMA NOT IN ('mysql','sys','information_schema','performance_schema')),

  -- -----------------------------------------------------------------------
  -- events
  -- -----------------------------------------------------------------------
  '],"events":[',
  (SELECT COALESCE(GROUP_CONCAT(
    JSON_OBJECT(
      'EVENT_NAME',    EVENT_NAME,
      'STATUS',        STATUS,
      'EVENT_TYPE',    EVENT_TYPE,
      'INTERVAL_VALUE',INTERVAL_VALUE,
      'INTERVAL_FIELD',INTERVAL_FIELD,
      'EXECUTE_AT',    DATE_FORMAT(EXECUTE_AT, '%Y-%m-%dT%H:%i:%SZ'),
      'STARTS',        DATE_FORMAT(STARTS, '%Y-%m-%dT%H:%i:%SZ'),
      'ENDS',          DATE_FORMAT(ENDS, '%Y-%m-%dT%H:%i:%SZ'),
      'DEFINER',       DEFINER
    )
    ORDER BY EVENT_NAME SEPARATOR ','
  ), '')
  FROM information_schema.EVENTS
  WHERE EVENT_SCHEMA = DATABASE()
    AND EVENT_SCHEMA NOT IN ('mysql','sys','information_schema','performance_schema')),

  -- -----------------------------------------------------------------------
  -- charset_violations: columns not using utf8mb4
  -- -----------------------------------------------------------------------
  '],"charset_violations":[',
  (SELECT COALESCE(GROUP_CONCAT(
    JSON_OBJECT(
      'TABLE_NAME',       TABLE_NAME,
      'COLUMN_NAME',      COLUMN_NAME,
      'CHARACTER_SET_NAME', CHARACTER_SET_NAME,
      'COLLATION_NAME',   COLLATION_NAME,
      'COLUMN_TYPE',      COLUMN_TYPE
    )
    ORDER BY TABLE_NAME, COLUMN_NAME SEPARATOR ','
  ), '')
  FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = DATABASE()
    AND TABLE_SCHEMA NOT IN ('mysql','sys','information_schema','performance_schema')
    AND CHARACTER_SET_NAME IS NOT NULL
    AND CHARACTER_SET_NAME NOT LIKE 'utf8mb4%'),

  -- -----------------------------------------------------------------------
  -- tables_without_pk: BASE TABLEs with no PRIMARY KEY constraint
  -- -----------------------------------------------------------------------
  '],"tables_without_pk":[',
  (SELECT COALESCE(GROUP_CONCAT(
    JSON_OBJECT(
      'TABLE_NAME',  t.TABLE_NAME,
      'ENGINE',      t.ENGINE,
      'TABLE_ROWS',  CAST(COALESCE(t.TABLE_ROWS, 0) AS SIGNED),
      'DATA_LENGTH', CAST(COALESCE(t.DATA_LENGTH, 0) AS SIGNED)
    )
    ORDER BY t.TABLE_NAME SEPARATOR ','
  ), '')
  FROM information_schema.TABLES t
  WHERE t.TABLE_SCHEMA = DATABASE()
    AND t.TABLE_SCHEMA NOT IN ('mysql','sys','information_schema','performance_schema')
    AND t.TABLE_TYPE = 'BASE TABLE'
    AND t.TABLE_NAME NOT IN (
      SELECT TABLE_NAME FROM information_schema.TABLE_CONSTRAINTS
      WHERE TABLE_SCHEMA = DATABASE() AND CONSTRAINT_TYPE = 'PRIMARY KEY'
    )),

  -- -----------------------------------------------------------------------
  -- non_innodb_tables: BASE TABLEs not using InnoDB engine
  -- -----------------------------------------------------------------------
  '],"non_innodb_tables":[',
  (SELECT COALESCE(GROUP_CONCAT(
    JSON_OBJECT(
      'TABLE_NAME',  TABLE_NAME,
      'ENGINE',      ENGINE,
      'TABLE_ROWS',  CAST(COALESCE(TABLE_ROWS, 0) AS SIGNED),
      'DATA_LENGTH', CAST(COALESCE(DATA_LENGTH, 0) AS SIGNED)
    )
    ORDER BY ENGINE, TABLE_NAME SEPARATOR ','
  ), '')
  FROM information_schema.TABLES
  WHERE TABLE_SCHEMA = DATABASE()
    AND TABLE_SCHEMA NOT IN ('mysql','sys','information_schema','performance_schema')
    AND TABLE_TYPE = 'BASE TABLE'
    AND ENGINE != 'InnoDB'),

  -- -----------------------------------------------------------------------
  -- check_constraints: CHECK constraints.
  -- MySQL 8.0.16+ and MariaDB 10.2+ only: MySQL 5.x has no CHECK_CONSTRAINTS.
  -- MySQL's CHECK_CONSTRAINTS has no TABLE_NAME column (MariaDB's does), so
  -- the table name is joined in from TABLE_CONSTRAINTS, which exists on every
  -- supported version. Collectors replace the single FROM line below with a
  -- synthetic empty subquery when the server has no CHECK_CONSTRAINTS table.
  -- -----------------------------------------------------------------------
  '],"check_constraints":[',
  (SELECT COALESCE(GROUP_CONCAT(
    JSON_OBJECT(
      'CONSTRAINT_CATALOG', cc.CONSTRAINT_CATALOG,
      'CONSTRAINT_SCHEMA', cc.CONSTRAINT_SCHEMA,
      'TABLE_NAME', tc.TABLE_NAME,
      'CONSTRAINT_NAME', cc.CONSTRAINT_NAME,
      'CHECK_CLAUSE', LEFT(cc.CHECK_CLAUSE, 500)
    )
    ORDER BY tc.TABLE_NAME, cc.CONSTRAINT_NAME SEPARATOR ','
  ), '')
  FROM information_schema.CHECK_CONSTRAINTS cc
  LEFT JOIN information_schema.TABLE_CONSTRAINTS tc ON tc.CONSTRAINT_SCHEMA = cc.CONSTRAINT_SCHEMA AND tc.CONSTRAINT_NAME = cc.CONSTRAINT_NAME AND tc.CONSTRAINT_TYPE = 'CHECK'
  WHERE cc.CONSTRAINT_SCHEMA = DATABASE()),

  ']}'
) AS catalog_json;
