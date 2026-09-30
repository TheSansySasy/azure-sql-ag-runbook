// Two SQL Server VMs for a single-subnet Always On availability group, with the
// internal load balancer the listener needs and a storage account for the
// cloud witness. Domain join, failover clustering and the availability group
// itself are configured afterwards: see docs/build.md.
//
// A clean-room template. Nothing here comes from a client environment.

@description('Region for every resource.')
param location string = resourceGroup().location

@description('Short prefix for resource names, for example "sqlag".')
@maxLength(8)
param prefix string = 'sqlag'

@description('Local administrator on both VMs. Replace with domain accounts after joining.')
param adminUsername string

@secure()
@description('Local administrator password.')
param adminPassword string

@description('VM size for both replicas.')
param vmSize string = 'Standard_E4ds_v5'

@description('SQL Server marketplace image SKU: "sqldev-gen2" for Developer edition, "enterprise-gen2" for Enterprise.')
param sqlImageSku string = 'sqldev-gen2'

@description('Availability zones for the two replicas. Use different zones so one zone outage leaves a replica.')
param zones array = ['1', '2']

@description('Private address the availability group listener will answer on.')
param listenerIp string = '10.40.1.100'

@description('Port the cluster answers the load balancer probe on. It must match the cluster IP resource\'s ProbePort.')
param probePort int = 59999

var vnetName = '${prefix}-vnet'
var subnetName = 'sql'
var replicaIps = ['10.40.1.10', '10.40.1.11']
var witnessName = toLower('${prefix}wit${uniqueString(resourceGroup().id)}')

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${prefix}-sql-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'sql-from-vnet'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: ['1433', '5022', string(probePort)]
        }
      }
      {
        // No public RDP. Administer through Azure Bastion or a VPN.
        name: 'deny-rdp-from-internet'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Deny'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: { addressPrefixes: ['10.40.0.0/16'] }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.40.1.0/24'
          networkSecurityGroup: { id: nsg.id }
        }
      }
    ]
  }
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' existing = {
  parent: vnet
  name: subnetName
}

resource lb 'Microsoft.Network/loadBalancers@2023-09-01' = {
  name: '${prefix}-listener-lb'
  location: location
  sku: { name: 'Standard' }
  properties: {
    frontendIPConfigurations: [
      {
        name: 'listener'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: listenerIp
          subnet: { id: subnet.id }
        }
      }
    ]
    backendAddressPools: [{ name: 'replicas' }]
    probes: [
      {
        name: 'ag-probe'
        properties: {
          protocol: 'Tcp'
          port: probePort
          intervalInSeconds: 5
          numberOfProbes: 2
        }
      }
    ]
    loadBalancingRules: [
      {
        name: 'sql'
        properties: {
          frontendIPConfiguration: { id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', '${prefix}-listener-lb', 'listener') }
          backendAddressPool: { id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', '${prefix}-listener-lb', 'replicas') }
          probe: { id: resourceId('Microsoft.Network/loadBalancers/probes', '${prefix}-listener-lb', 'ag-probe') }
          protocol: 'Tcp'
          frontendPort: 1433
          backendPort: 1433
          // Floating IP: the listener address is configured on the cluster itself,
          // and only the node that answers the probe (the primary) receives traffic.
          enableFloatingIP: true
          idleTimeoutInMinutes: 4
        }
      }
    ]
  }
}

resource nics 'Microsoft.Network/networkInterfaces@2023-09-01' = [for (ip, i) in replicaIps: {
  name: '${prefix}-sql${i + 1}-nic'
  location: location
  properties: {
    enableAcceleratedNetworking: true
    ipConfigurations: [
      {
        name: 'primary'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: ip
          subnet: { id: subnet.id }
          loadBalancerBackendAddressPools: [{ id: lb.properties.backendAddressPools[0].id }]
        }
      }
    ]
  }
}]

resource vms 'Microsoft.Compute/virtualMachines@2023-09-01' = [for (ip, i) in replicaIps: {
  name: '${prefix}-sql${i + 1}'
  location: location
  zones: [zones[i]]
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: '${prefix}-sql${i + 1}'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: false // patching is coordinated, one replica at a time
        patchSettings: { patchMode: 'Manual' }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftSQLServer'
        offer: 'sql2022-ws2022'
        sku: sqlImageSku
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Premium_LRS' }
      }
      dataDisks: [
        {
          lun: 0
          name: '${prefix}-sql${i + 1}-data'
          createOption: 'Empty'
          diskSizeGB: 256
          caching: 'ReadOnly'
          managedDisk: { storageAccountType: 'Premium_LRS' }
        }
        {
          lun: 1
          name: '${prefix}-sql${i + 1}-log'
          createOption: 'Empty'
          diskSizeGB: 128
          caching: 'None'
          managedDisk: { storageAccountType: 'Premium_LRS' }
        }
      ]
    }
    networkProfile: {
      networkInterfaces: [{ id: nics[i].id }]
    }
    diagnosticsProfile: { bootDiagnostics: { enabled: true } }
  }
}]

resource witness 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: take(witnessName, 24)
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
  }
}

output listenerAddress string = listenerIp
output probePort int = probePort
output replicaNames array = [for (ip, i) in replicaIps: vms[i].name]
output witnessStorageAccount string = witness.name
