# Failing over

Three situations, three procedures. In every case, clients keep connecting to the listener name and follow the primary. No connection string changes.

## Before any planned failover

Run on the current primary:

```sql
SELECT ag.name AS availability_group,
       ar.replica_server_name,
       drs.database_id,
       drs.synchronization_state_desc,
       drs.log_send_queue_size,
       drs.redo_queue_size
FROM sys.dm_hadr_database_replica_states AS drs
JOIN sys.availability_replicas AS ar ON ar.replica_id = drs.replica_id
JOIN sys.availability_groups   AS ag ON ag.group_id  = drs.group_id;
```

Every database on the target should be `SYNCHRONIZED`, with queues near zero.

## Planned failover (no data loss)

For patching, resizing or moving load. Connect to the **target secondary**, not the primary:

```sql
ALTER AVAILABILITY GROUP [<ag>] FAILOVER;
```

or from PowerShell, also against the target:

```powershell
Switch-SqlAvailabilityReplica -Path 'SQLSERVER:\SQL\<target>\DEFAULT\AvailabilityGroups\<ag>'
```

Then check that the old primary is now a synchronized secondary, patch it, and fail back the same way if you want the original layout.

## Automatic failover

With synchronous commit and automatic failover on both replicas, the cluster fails over by itself when the primary stops answering its health checks, after waiting out the heartbeat so a short network blip does not move it. Nothing to run; check afterwards what happened and why (the cluster log: `Get-ClusterLog -Destination C:\Temp -TimeSpan 30`).

`scripts/Invoke-CpuFailover.ps1` adds one more trigger: sustained CPU on the primary, and only when the secondary is synchronized and no failover happened within the cooldown.

## Forced failover (possible data loss)

Only when the primary is gone and is not coming back soon, and only after deciding that losing the transactions it had not sent is acceptable. On the secondary:

```sql
ALTER AVAILABILITY GROUP [<ag>] FORCE_FAILOVER_ALLOW_DATA_LOSS;
```

If the cluster itself lost quorum, it has to be forced to start on the surviving node first (`Start-ClusterNode -FixQuorum`). When the old primary returns, it comes back as a secondary with data movement suspended. Compare, recover anything needed, then resume each database:

```sql
ALTER DATABASE [<database>] SET HADR RESUME;
```

## After any failover

- Clients reconnect through the listener. Check the application logs for connection errors that did not retry.
- Check that the SPN checks still pass: `scripts/Test-KerberosHealth.ps1`.
- Write down what happened, when, and why, while it is fresh.
