# Monitoring

What to watch on a two-node availability group, and why. The thresholds here are starting points; tune them to the workload.

| Watch | Why | How |
|---|---|---|
| Free space on data, log and system volumes | A full log volume stops every write. Warn early enough to act in working hours | `scripts/Watch-DiskThreshold.ps1` on a schedule; exit code 1 warns, 2 is critical |
| Sustained CPU on the primary | A primary that is too busy to answer is worse than one that failed cleanly | `scripts/Invoke-CpuFailover.ps1`, which alerts or fails over |
| Replica synchronization state | A secondary that is not `SYNCHRONIZED` is not a safe failover target | `sys.dm_hadr_database_replica_states`, alert on anything else for more than a few minutes |
| Log send and redo queues | Growing queues mean the secondary is falling behind before it says so | Same view, `log_send_queue_size` and `redo_queue_size` |
| **Every cluster group and resource state** | An offline role is invisible from SQL Server and can break authentication | `Get-ClusterResource \| Where-Object State -ne 'Online'` on a schedule |
| The listener answering | The end-to-end check: what clients actually use | A connection through the listener name every minute |
| Kerberos health after changes | SPN and machine-account problems appear after patching, restores and renames | `scripts/Test-KerberosHealth.ps1` after every change window |

Any agent can run the scripts: Task Scheduler with a webhook, a Zabbix user parameter reading the exit code, or a Prometheus exporter's textfile collector. Use more than one source for the listener check, so a monitoring outage is not mistaken for a database one.
