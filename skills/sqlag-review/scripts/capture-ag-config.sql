-- sqlag-review capture script
-- Run on the PRIMARY replica to collect all data needed for /sqlag-review
-- Output: paste results into chat or save to a text file

PRINT '--- Query 1: Instance and AG Overview ---';
SELECT
    SERVERPROPERTY('IsHadrEnabled')                    AS hadr_enabled,
    SERVERPROPERTY('ProductVersion')                   AS product_version,
    SERVERPROPERTY('ProductLevel')                     AS product_level,
    SERVERPROPERTY('Edition')                          AS edition,
    ag.name                                            AS ag_name,
    ag.group_id,
    ag.failure_condition_level,
    ag.health_check_timeout,
    ag.automated_backup_preference_desc,
    ag.db_failover,
    ag.basic_features,
    ag.is_contained,
    ag.required_synchronized_secondaries_to_commit
FROM sys.availability_groups ag;

PRINT '--- Query 2: Replica Configuration ---';
SELECT
    ag.name                                             AS ag_name,
    ar.replica_server_name,
    ar.availability_mode_desc,
    ar.failover_mode_desc,
    ar.session_timeout,
    ar.primary_role_allow_connections_desc,
    ar.secondary_role_allow_connections_desc,
    ar.backup_priority,
    ar.seeding_mode_desc,
    ar.endpoint_url,
    ar.read_only_routing_url
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
ORDER BY ag.name, ar.replica_server_name;

PRINT '--- Query 2b: Replica Join State (F11) ---';
-- join_state_desc is in the cluster-states DMV, not sys.availability_replicas
-- Valid values: NOT_JOINED | JOINED_STANDALONE | JOINED_FCI
SELECT
    replica_server_name,
    group_id,
    join_state,
    join_state_desc
FROM sys.dm_hadr_availability_replica_cluster_states
ORDER BY replica_server_name;

PRINT '--- Query 3: Listener and IP Configuration ---';
SELECT
    ag.name                                             AS ag_name,
    agl.dns_name,
    agl.port,
    agl.is_conformant,      -- F35: on sys.availability_group_listeners, not IP addresses view
    aglip.ip_address,
    aglip.ip_subnet_mask,
    aglip.state_desc        AS ip_state  -- ONLINE | OFFLINE | ONLINE_PENDING | FAILED
FROM sys.availability_groups ag
JOIN sys.availability_group_listeners agl
    ON ag.group_id = agl.group_id
JOIN sys.availability_group_listener_ip_addresses aglip
    ON agl.listener_id = aglip.listener_id;

PRINT '--- Query 4: Mirroring Endpoint ---';
SELECT
    name,
    state_desc,
    role_desc,
    connection_auth_desc,
    encryption_algorithm_desc,
    encryption_desc,
    port
FROM sys.database_mirroring_endpoints;

PRINT '--- Query 5: AG Database Recovery Models ---';
SELECT
    adc.ag_database_id,
    db.name                                             AS database_name,
    db.recovery_model_desc,
    db.is_read_committed_snapshot_on,
    db.state_desc
FROM sys.availability_databases_cluster adc
JOIN sys.databases db ON adc.database_id = db.database_id
ORDER BY db.name;

PRINT '--- Query 6: Endpoint Certificates (certificate auth only) ---';
SELECT
    name,
    subject,
    expiry_date,
    pvt_key_encryption_type_desc,
    thumbprint
FROM sys.certificates
WHERE pvt_key_encryption_type_desc IS NOT NULL
ORDER BY expiry_date;

PRINT '--- Query 7: Automatic Seeding Status (if applicable) ---';
SELECT
    local_physical_seeding_id,
    ag_id,
    local_database_id,
    remote_machine_name,
    seeding_id,
    start_time,
    completion_time,
    failure_message,
    number_of_attempts
FROM sys.dm_hadr_automatic_seeding;

PRINT '--- Query 8: XE Sessions for AG Diagnostics ---';
SELECT
    name,
    event_session_address,
    create_time,
    total_dispatched_count
FROM sys.dm_xe_sessions
WHERE name LIKE '%hadr%'
   OR name LIKE '%ag%'
   OR name LIKE '%alwayson%';
