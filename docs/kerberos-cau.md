# KRB_AP_ERR_MODIFIED on an availability group

A production login fails with a Kerberos error, `KRB_AP_ERR_MODIFIED`, while the availability group itself looks healthy. This guide is the order I would search in, and the cause that is easy to miss.

## What the error means

The client asked a domain controller for a ticket to the SQL Server service. The domain sealed that ticket with the key of the account it believes owns the service's SPN. The server that received the ticket could not open it. So the key the domain used and the key the server holds do not match.

Every cause is a version of that mismatch.

## The search, in order

`scripts/Test-KerberosHealth.ps1` runs all of these and prints a table.

### 1. Duplicate SPNs

```powershell
setspn -X
```

The same `MSSQLSvc/...` SPN on two accounts means the domain may seal the ticket for the wrong one. This is the classic cause. Remove the duplicate from the account that should not have it.

### 2. The SQL service account's SPNs

```powershell
setspn -L <DOMAIN>\<sql-service-account>
```

The listener's SPN (`MSSQLSvc/<listener-fqdn>:1433`) should be on the account SQL Server runs as, on every replica. If SQL Server runs as a machine account on one node and a domain account on the other, tickets will fail on one of them.

### 3. The node's machine password

```powershell
Test-ComputerSecureChannel -Verbose
```

If a machine's password changed in the domain but not on the machine (a restored VM, a snapshot rollback), anything sealed with the machine account's key fails. `Test-ComputerSecureChannel -Repair -Credential <domain-admin>` resets it.

### 4. Cluster roles and their computer objects

```powershell
Get-ClusterGroup | Where-Object State -ne 'Online'
Get-ClusterResource | Where-Object State -ne 'Online'
```

The one that is easy to miss. A failover cluster keeps computer objects in Active Directory for its network names: the cluster itself, the listener, and roles such as **Cluster-Aware Updating**, which runs as a clustered role with its own name. An offline role is not a harmless one. Its computer object's state can drift away from what the domain expects, and nothing about the availability group dashboard says so.

If a role or network name resource is offline:

1. Find out why it went offline (`Get-ClusterLog`), so it does not go offline again.
2. Bring it back online.
3. Correct the computer object's state. In Failover Cluster Manager, the network name resource's **More Actions → Repair Active Directory Object** resets the password the cluster and the domain share. Check that the object is enabled in Active Directory and that the cluster name object still has rights over it.
4. Have the client purge its tickets (`klist purge`) and try again.

## Afterwards

Alert on the state of every cluster resource, not only on disk and CPU (see [monitoring.md](monitoring.md)). An offline role that nothing watches is a failure waiting for a login to find it.
