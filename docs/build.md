# Building the availability group

`infra/main.bicep` creates the machines, the network, the listener's load balancer and the witness storage. Everything below happens inside Windows and SQL Server, in this order. Names in angle brackets are yours to choose.

## 1. Deploy the infrastructure

```bash
az group create --name <rg> --location <region>
az deployment group create --resource-group <rg> --template-file infra/main.bicep \
  --parameters adminUsername=<admin> adminPassword=<password> prefix=sqlag
```

The outputs give the listener address, the probe port and the witness storage account name.

## 2. Join both VMs to the domain

Both replicas, the cluster and the listener live in Active Directory. If there is no domain yet, promote a separate Windows Server VM in the same network to a domain controller first with [`scripts/New-AdForest.ps1`](../scripts/New-AdForest.ps1):

```powershell
Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
.\New-AdForest.ps1 -DomainName corp.example.local -NetbiosName CORP
```

Point the VNet's DNS at your domain controllers, then join each SQL VM and restart it. From here on, sign in with a domain account that can create computer objects, or have the cluster and listener objects prestaged.

## 3. Create the cluster

On both nodes:

```powershell
Install-WindowsFeature Failover-Clustering -IncludeManagementTools
```

Then, on one node:

```powershell
Test-Cluster -Node sqlag-sql1, sqlag-sql2
New-Cluster -Name <cluster> -Node sqlag-sql1, sqlag-sql2 -StaticAddress <unused-ip> -NoStorage
Set-ClusterQuorum -Cluster <cluster> -CloudWitness -AccountName <witness-account> -AccessKey <key>
```

Two nodes and a witness make three votes. Either node can then fail and the survivor still holds a majority with the witness.

## 4. Enable Always On and create the group

```powershell
Enable-SqlAlwaysOn -ServerInstance sqlag-sql1 -Force
Enable-SqlAlwaysOn -ServerInstance sqlag-sql2 -Force
```

Create a database mirroring endpoint on each replica (TCP 5022), take a full and a log backup of each database, then create the availability group with synchronous commit and automatic failover on both replicas. SQL Server Management Studio's wizard or `New-SqlAvailabilityGroup` both work. Synchronous commit is what makes "nothing already committed was lost" true after a failover.

## 5. Create the listener and wire it to the load balancer

Create the listener on `listenerAddress` from the deployment output, port 1433. On Azure the load balancer only sends traffic to the node answering its probe, so the listener's cluster IP resource has to answer on the probe port and use a host mask:

```powershell
$ListenerIp  = '10.40.1.100'           # listenerAddress
$ProbePort   = 59999                   # probePort
$IpResource  = '<ag>_10.40.1.100'      # Get-ClusterResource | Where ResourceType -eq 'IP Address'
$Network     = (Get-ClusterNetwork).Name

Get-ClusterResource $IpResource | Set-ClusterParameter -Multiple @{
    Address    = $ListenerIp
    ProbePort  = $ProbePort
    SubnetMask = '255.255.255.255'
    Network    = $Network
    EnableDhcp = 0
}
```

Take the listener resource offline and online again for the change to apply, then connect to the listener name from another machine.

## 6. Register the listener's SPN

If SQL Server runs under a domain service account, register the listener's SPN on that account so clients can use Kerberos:

```powershell
setspn -S MSSQLSvc/<listener-fqdn>:1433 <DOMAIN>\<sql-service-account>
setspn -S MSSQLSvc/<listener-fqdn> <DOMAIN>\<sql-service-account>
```

`scripts/Test-KerberosHealth.ps1` checks that it is there.

## 7. Monitoring

See [monitoring.md](monitoring.md): disk thresholds, sustained CPU, replica synchronization, and the state of every cluster resource.
