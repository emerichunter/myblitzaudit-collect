-- =============================================================================
--  MY Global Dump  v1.0
--  Zero Knowledge MySQL/MariaDB server-level snapshot (once per server)
--  Covers: users, global variables, global status, replication, binary logs
--
-- =============================================================================
--  PREREQUISITES
-- =============================================================================
--
--  Required:
--    * MySQL 5.7+ or MariaDB 10.2+
--    * SELECT on mysql.user  (or PROCESS privilege)
--    * SELECT on performance_schema (for replication tables on MySQL 8)
--    * REPLICATION CLIENT privilege (for SHOW BINARY LOGS)
--
--  Usage (called automatically by my_collect.sh):
--    mysql -u <user> -p... -D mysql --default-character-set=utf8mb4 -s -N \
--      < my_global_dump.sql > global_snapshot.json
--
--  Output: single JSON document to stdout
--  IMPORTANT: Never captures password hashes (authentication_string / Password)
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
    'type',           'my_global_dump',
    'version',        '1.0',
    'generated_at',   DATE_FORMAT(UTC_TIMESTAMP(), '%Y-%m-%dT%H:%i:%SZ'),
    'mysql_version',  VERSION(),
    'is_mariadb',     IF(VERSION() LIKE '%MariaDB%', TRUE, FALSE),
    'hostname',       @@hostname,
    'server_uuid',    IF(VERSION() LIKE '%MariaDB%', NULL, @@global.server_uuid),
    'port',           CAST(@@port AS SIGNED),
    'datadir',        @@datadir,
    'basedir',        @@basedir,
    'charset_server', @@character_set_server,
    'collation_server',@@collation_server,
    'version_compile_os', @@version_compile_os,
    'version_compile_machine', @@version_compile_machine
  ),

  -- -----------------------------------------------------------------------
  -- global_variables: key configuration parameters
  -- -----------------------------------------------------------------------
  ',"global_variables":[',
  (SELECT COALESCE(GROUP_CONCAT(
    JSON_OBJECT('Variable_name', VARIABLE_NAME, 'Value', VARIABLE_VALUE)
    ORDER BY Variable_name SEPARATOR ','
  ), '')
  FROM performance_schema.global_variables
  WHERE Variable_name IN (
    -- Connection and threading
    'max_connections','max_user_connections','thread_cache_size',
    'wait_timeout','interactive_timeout','net_read_timeout','net_write_timeout',
    'connect_timeout','lock_wait_timeout','thread_stack','binlog_cache_size',
    -- Network / TLS
    'bind_address','skip_networking','tls_version','ssl_cipher','have_ssl','have_openssl','socket',
    -- Memory
    'innodb_buffer_pool_size','innodb_buffer_pool_instances',
    'innodb_buffer_pool_chunk_size',
    'key_buffer_size','sort_buffer_size','join_buffer_size','read_buffer_size',
    'read_rnd_buffer_size','tmp_table_size','max_heap_table_size',
    'max_allowed_packet','group_concat_max_len',
    -- InnoDB I/O
    'innodb_log_file_size','innodb_log_buffer_size','innodb_log_files_in_group',
    'innodb_flush_log_at_trx_commit','innodb_flush_method','innodb_autoinc_lock_mode',
    'innodb_io_capacity','innodb_io_capacity_max',
    'innodb_file_per_table','innodb_page_size',
    'innodb_read_io_threads','innodb_write_io_threads',
    'innodb_doublewrite',
    -- Replication / Binlog
    'log_bin','binlog_format','sync_binlog','binlog_row_image',
    'binlog_expire_logs_seconds','expire_logs_days',
    'gtid_mode','enforce_gtid_consistency',
    'replica_parallel_workers','slave_parallel_workers',
    'log_replica_updates','log_slave_updates',
    'master_info_repository','relay_log_info_repository',
    -- Slow query log
    'slow_query_log','slow_query_log_file','long_query_time',
    'log_queries_not_using_indexes','min_examined_row_limit',
    -- General log
    'general_log','general_log_file',
    -- Error log
    'log_error',
    -- Password policy
    'default_password_lifetime','password_history','password_reuse_interval',
    'password_require_current',
    -- Brute force / Audit
    'connection_control_failed_connections_threshold','connection_control_min_connection_delay',
    'audit_log','audit_log_file','max_password_errors',
    -- P_S sizing
    'performance_schema_events_statements_history_size',
    'performance_schema_events_statements_history_long_size',
    'performance_schema_max_digest_storage','performance_schema_max_metadata_locks',
    'performance_schema_max_prepared_statements_instances',
    'performance_schema_max_table_handles',
    'performance_schema_accounts_size','performance_schema_hosts_size',
    -- Security / Auth
    'validate_password_policy','validate_password.policy',
    'validate_password_length','validate_password.length',
    'default_authentication_plugin','authentication_policy',
    'require_secure_transport',
    'ssl_ca','ssl_cert','ssl_key',
    'local_infile',
    -- Query cache (5.7 only, deprecated in 8.0)
    'query_cache_type','query_cache_size',
    -- Other
    'default_storage_engine','lower_case_table_names',
    'explicit_defaults_for_timestamp','sql_mode','time_zone',
    'character_set_server','collation_server',
    'performance_schema',
    'table_open_cache','table_definition_cache',
    'open_files_limit',
    'max_prepared_stmt_count',
    -- MyISAM
    'myisam_recover_options',
    -- Audit
    'audit_log_policy','audit_log_format'
  )),

  -- -----------------------------------------------------------------------
  -- global_status: runtime counters snapshot
  -- -----------------------------------------------------------------------
  '],"global_status":[',
  (SELECT COALESCE(GROUP_CONCAT(
    JSON_OBJECT('Variable_name', VARIABLE_NAME, 'Value', VARIABLE_VALUE)
    ORDER BY Variable_name SEPARATOR ','
  ), '')
  FROM performance_schema.global_status
  WHERE Variable_name IN (
    -- Connections
    'Threads_connected','Threads_running','Max_used_connections',
    'Connections','Aborted_connects','Aborted_clients','Threads_created',
    -- Queries
    'Queries','Questions','Slow_queries',
    'Com_select','Com_insert','Com_update','Com_delete',
    'Com_replace','Com_commit','Com_rollback',
    -- InnoDB buffer pool
    'Innodb_buffer_pool_reads','Innodb_buffer_pool_read_requests',
    'Innodb_buffer_pool_pages_data','Innodb_buffer_pool_pages_free',
    'Innodb_buffer_pool_pages_dirty','Innodb_buffer_pool_pages_total',
    'Innodb_buffer_pool_bytes_data','Innodb_buffer_pool_bytes_dirty',
    -- InnoDB I/O
    'Innodb_pages_read','Innodb_pages_written','Innodb_pages_created',
    'Innodb_os_log_written','Innodb_data_reads','Innodb_data_writes',
    -- InnoDB row operations
    'Innodb_rows_read','Innodb_rows_inserted','Innodb_rows_updated','Innodb_rows_deleted',
    -- InnoDB locks
    'Innodb_row_lock_waits','Innodb_row_lock_time','Innodb_row_lock_time_avg',
    'Innodb_row_lock_time_max','Innodb_deadlocks',
    -- MyISAM
    'Key_reads','Key_read_requests','Key_writes','Key_write_requests',
    'Key_blocks_unused','Key_blocks_used',
    -- Temp tables
    'Created_tmp_disk_tables','Created_tmp_tables','Created_tmp_files',
    'Sort_merge_passes','Sort_rows',
    -- Full table scan indicators
    'Handler_read_rnd','Handler_read_rnd_next',
    'Select_full_join','Select_scan','Select_range',
    -- Table lock waits
    'Table_locks_waited','Table_locks_immediate',
    -- Open tables
    'Open_tables','Opened_tables','Table_open_cache_hits','Table_open_cache_misses',
    -- Network
    'Bytes_received','Bytes_sent',
    -- Uptime
    'Uptime','Uptime_since_flush_status',
    -- SSL
    'Ssl_cipher','Ssl_version',
    -- Query cache (5.7 only, removed in 8.0+)
    'Qcache_hits','Qcache_inserts','Qcache_lowmem_prunes',
    'Qcache_not_cached','Qcache_queries_in_cache','Qcache_free_memory'
  )),

  -- -----------------------------------------------------------------------
  -- users: from mysql.user — NEVER capture authentication_string or Password
  -- -----------------------------------------------------------------------
  '],"users":[',
  (SELECT COALESCE(GROUP_CONCAT(
    JSON_OBJECT(
      'User',              User,
      'Host',              Host,
      'plugin',            plugin,
      'account_locked',    account_locked,
      'password_expired',  password_expired,
      -- Privilege flags
      'Select_priv',       Select_priv,
      'Insert_priv',       Insert_priv,
      'Update_priv',       Update_priv,
      'Delete_priv',       Delete_priv,
      'Create_priv',       Create_priv,
      'Drop_priv',         Drop_priv,
      'Grant_priv',        Grant_priv,
      'Super_priv',        Super_priv,
      'Repl_slave_priv',   Repl_slave_priv,
      'Repl_client_priv',  Repl_client_priv,
      'Execute_priv',      Execute_priv,
      'Create_user_priv',  Create_user_priv,
      -- Computed risk fields
      'is_superuser',      IF(Super_priv = 'Y', TRUE, FALSE),
      'has_password',      IF(
        plugin NOT IN ('', 'mysql_no_password', 'mysql_old_password') AND
        plugin NOT LIKE 'auth_socket%' AND
        plugin NOT LIKE 'unix_socket%', TRUE, FALSE),
      'auth_type',         plugin,
      'wild_host',         IF(Host = '%', TRUE, FALSE),
      'risk_level',        CASE
        WHEN Super_priv = 'Y' AND (Host = '%' OR Host = '')          THEN 'CRITICAL'
        WHEN plugin IN ('', 'mysql_no_password', 'mysql_old_password') THEN 'CRITICAL'
        WHEN Super_priv = 'Y'                                          THEN 'HIGH'
        WHEN Grant_priv = 'Y'                                          THEN 'HIGH'
        WHEN Host = '%'                                                THEN 'MEDIUM'
        WHEN plugin = 'mysql_native_password'                          THEN 'LOW'
        ELSE 'OK'
      END
    )
    ORDER BY User, Host SEPARATOR ','
  ), '')
  -- Explicitly exclude authentication_string/Password columns:
  FROM (SELECT User, Host, plugin,
               account_locked, password_expired,
               Select_priv, Insert_priv, Update_priv, Delete_priv,
               Create_priv, Drop_priv, Grant_priv, Super_priv,
               Repl_slave_priv, Repl_client_priv, Execute_priv, Create_user_priv
        FROM mysql.user) u),

  -- -----------------------------------------------------------------------
  -- storage_engine_summary: count and size per engine
  -- -----------------------------------------------------------------------
  '],"storage_engine_summary":[',
  (SELECT COALESCE(GROUP_CONCAT(
    JSON_OBJECT(
      'ENGINE',           ENGINE,
      'table_count',      CAST(table_count AS SIGNED),
      'total_data_bytes', CAST(total_data_bytes AS SIGNED),
      'total_index_bytes',CAST(total_index_bytes AS SIGNED),
      'total_free_bytes', CAST(total_free_bytes AS SIGNED),
      'total_rows',       CAST(total_rows AS SIGNED)
    )
    ORDER BY table_count DESC SEPARATOR ','
  ), '')
  FROM (
    SELECT ENGINE,
      COUNT(*) AS table_count,
      SUM(COALESCE(DATA_LENGTH, 0)) AS total_data_bytes,
      SUM(COALESCE(INDEX_LENGTH, 0)) AS total_index_bytes,
      SUM(COALESCE(DATA_FREE, 0)) AS total_free_bytes,
      SUM(COALESCE(TABLE_ROWS, 0)) AS total_rows
    FROM information_schema.TABLES
    WHERE TABLE_SCHEMA NOT IN ('mysql','sys','information_schema','performance_schema')
      AND TABLE_TYPE = 'BASE TABLE'
      AND ENGINE IS NOT NULL
    GROUP BY ENGINE
  ) eng_summary),

  -- -----------------------------------------------------------------------
  -- innodb_buffer_ratio: buffer pool size vs total InnoDB data
  -- -----------------------------------------------------------------------
  '],"innodb_buffer_ratio":',
  (SELECT JSON_OBJECT(
    'buffer_pool_bytes',  CAST(@@innodb_buffer_pool_size AS SIGNED),
    'total_innodb_bytes', CAST(COALESCE(SUM(COALESCE(DATA_LENGTH,0) + COALESCE(INDEX_LENGTH,0)), 0) AS SIGNED),
    'buffer_pool_pct',    ROUND(
      @@innodb_buffer_pool_size * 100.0 /
      NULLIF(SUM(COALESCE(DATA_LENGTH,0) + COALESCE(INDEX_LENGTH,0)), 0), 1)
  )
  FROM information_schema.TABLES
  WHERE TABLE_SCHEMA NOT IN ('mysql','sys','information_schema','performance_schema')
    AND ENGINE = 'InnoDB'),

  -- -----------------------------------------------------------------------
  -- replication_status: version-branched
  --   MySQL 8.0+: performance_schema.replication_connection_status
  --   MySQL 5.7 / MariaDB: SHOW SLAVE STATUS captured by shell script
  --   This SQL section captures MySQL 8 replica status;
  --   my_collect.sh also captures SHOW SLAVE/REPLICA STATUS output.
  -- -----------------------------------------------------------------------
  ',"replication_status":',
  JSON_OBJECT(
    'note', 'Replication details captured separately by my_collect.sh (SHOW REPLICA STATUS)',
    'is_replica', IF(
      (SELECT COUNT(*) FROM performance_schema.global_status
       WHERE VARIABLE_NAME = 'Slave_running' AND VARIABLE_VALUE = 'ON') > 0,
      TRUE, FALSE),
    'read_master_log_pos', (SELECT VARIABLE_VALUE FROM performance_schema.global_status
                             WHERE VARIABLE_NAME = 'Read_Master_Log_Pos'),
    'slave_running', (SELECT VARIABLE_VALUE FROM performance_schema.global_status
                       WHERE VARIABLE_NAME IN ('Slave_running','Replica_running') LIMIT 1)
  ),

  -- -----------------------------------------------------------------------
  -- binary_logs: captured when log_bin = ON
  -- -----------------------------------------------------------------------
  ',"binary_logs_note":',
  JSON_OBJECT(
    'log_bin', CAST(@@log_bin AS CHAR),
    'binlog_format', CAST(@@binlog_format AS CHAR),
    'note', 'Binary log file list captured separately by my_collect.sh (SHOW BINARY LOGS)'
  ),

  -- -----------------------------------------------------------------------
  -- global_grants: dynamic privileges (MySQL 8.0+)
  -- -----------------------------------------------------------------------
  ',"global_grants":[',
  (SELECT COALESCE(GROUP_CONCAT(
    JSON_OBJECT(
      'USER', USER, 'HOST', HOST, 'PRIV', PRIV, 'WITH_GRANT_OPTION', WITH_GRANT_OPTION
    )
    ORDER BY USER, HOST, PRIV SEPARATOR ','
  ), '')
  FROM mysql.global_grants)
  , '],\n',

  -- -----------------------------------------------------------------------
  -- role_edges: role grants (MySQL 8.0+)
  -- -----------------------------------------------------------------------
  '"role_edges":[',
  (SELECT COALESCE(GROUP_CONCAT(
    JSON_OBJECT(
      'FROM_USER', FROM_USER, 'FROM_HOST', FROM_HOST,
      'TO_USER', TO_USER, 'TO_HOST', TO_HOST,
      'WITH_ADMIN_OPTION', WITH_ADMIN_OPTION
    )
    ORDER BY TO_USER, TO_HOST, FROM_USER SEPARATOR ','
  ), '')
  FROM mysql.role_edges)
  , '],\n',

  -- -----------------------------------------------------------------------
  -- setup_consumers: P_S consumer state
  -- -----------------------------------------------------------------------
  '"setup_consumers":[',
  (SELECT COALESCE(GROUP_CONCAT(
    JSON_OBJECT('NAME', NAME, 'ENABLED', IF(ENABLED = 'YES', TRUE, FALSE))
    ORDER BY NAME SEPARATOR ','
  ), '')
  FROM performance_schema.setup_consumers)
  , '],\n',

  -- -----------------------------------------------------------------------
  -- setup_instruments: P_S instrument state (filtered categories)
  -- -----------------------------------------------------------------------
  '"setup_instruments":[',
  (SELECT COALESCE(GROUP_CONCAT(
    JSON_OBJECT('NAME', NAME, 'ENABLED', IF(ENABLED = 'YES', TRUE, FALSE),
                'TIMED', IF(TIMED = 'YES', TRUE, FALSE))
    ORDER BY NAME SEPARATOR ','
  ), '')
  FROM performance_schema.setup_instruments
  WHERE NAME LIKE 'wait/io/%'
     OR NAME LIKE 'wait/synch/%'
     OR NAME LIKE 'memory/%'
     OR NAME LIKE 'statement/%'
     OR NAME LIKE 'transaction/%'
     OR NAME LIKE 'error/%')
  , '],\n',

  -- -----------------------------------------------------------------------
  -- host_cache: connection errors and blocked hosts
  -- -----------------------------------------------------------------------
  '"host_cache":[',
  (SELECT COALESCE(GROUP_CONCAT(
    JSON_OBJECT(
      'IP', IP, 'HOST', HOST,
      'HOST_VALIDATED', IF(HOST_VALIDATED = 'YES', TRUE, FALSE),
      'SUM_CONNECT_ERRORS', CAST(SUM_CONNECT_ERRORS AS SIGNED),
      'COUNT_HOST_BLOCKED_ERRORS', CAST(COUNT_HOST_BLOCKED_ERRORS AS SIGNED)
    )
    ORDER BY SUM_CONNECT_ERRORS DESC SEPARATOR ','
  ), '')
  FROM performance_schema.host_cache)
  , '],\n',

  -- -----------------------------------------------------------------------
  -- memory_summary: top P_S memory consumers
  -- -----------------------------------------------------------------------
  '"memory_summary":[',
  (SELECT COALESCE(GROUP_CONCAT(
    JSON_OBJECT(
      'EVENT_NAME', EVENT_NAME,
      'CURRENT_NUMBER_OF_BYTES_USED', CAST(CURRENT_NUMBER_OF_BYTES_USED AS SIGNED),
      'HIGH_NUMBER_OF_BYTES_USED', CAST(HIGH_NUMBER_OF_BYTES_USED AS SIGNED),
      'CURRENT_COUNT_USED', CAST(CURRENT_COUNT_USED AS SIGNED)
    )
    ORDER BY CURRENT_NUMBER_OF_BYTES_USED DESC SEPARATOR ','
  ), '')
  FROM performance_schema.memory_summary_global_by_event_name
  WHERE CURRENT_NUMBER_OF_BYTES_USED > 0
  LIMIT 50)
  , '],\n',

  -- -----------------------------------------------------------------------
  -- file_summary: top P_S file I/O
  -- -----------------------------------------------------------------------
  '"file_summary":[',
  (SELECT COALESCE(GROUP_CONCAT(
    JSON_OBJECT(
      'FILE_NAME', FILE_NAME, 'EVENT_NAME', EVENT_NAME,
      'COUNT_READ', CAST(COUNT_READ AS SIGNED),
      'COUNT_WRITE', CAST(COUNT_WRITE AS SIGNED),
      'SUM_NUMBER_OF_BYTES_READ', CAST(SUM_NUMBER_OF_BYTES_READ AS SIGNED),
      'SUM_NUMBER_OF_BYTES_WRITE', CAST(SUM_NUMBER_OF_BYTES_WRITE AS SIGNED)
    )
    ORDER BY SUM_NUMBER_OF_BYTES_READ + SUM_NUMBER_OF_BYTES_WRITE DESC SEPARATOR ','
  ), '')
  FROM performance_schema.file_summary_by_instance
  LIMIT 50),

  ']}'
) AS global_json;
