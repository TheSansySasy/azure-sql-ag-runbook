<#
.SYNOPSIS
    Promotes a Windows Server to the first domain controller of a new forest.

.DESCRIPTION
    An availability group needs Active Directory: both replicas, the cluster
    and the listener are all domain objects. If no domain exists yet, run this
    on the server that will be the domain controller, after installing the
    role:

        Install-WindowsFeature AD-Domain-Services -IncludeManagementTools

    It is the script the Active Directory Domain Services wizard generates,
    with the domain names as parameters. The server restarts when it finishes,
    and prompts for the Directory Services Restore Mode password.

.EXAMPLE
    .\New-AdForest.ps1 -DomainName corp.example.local -NetbiosName CORP
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [string] $DomainName,
    [Parameter(Mandatory)] [ValidateLength(1, 15)] [string] $NetbiosName
)

Import-Module ADDSDeployment

if ($PSCmdlet.ShouldProcess($DomainName, 'Create a new Active Directory forest and restart')) {
    Install-ADDSForest `
        -CreateDnsDelegation:$false `
        -DatabasePath 'C:\Windows\NTDS' `
        -DomainMode 'WinThreshold' `
        -DomainName $DomainName `
        -DomainNetbiosName $NetbiosName `
        -ForestMode 'WinThreshold' `
        -InstallDns:$true `
        -LogPath 'C:\Windows\NTDS' `
        -NoRebootOnCompletion:$false `
        -SysvolPath 'C:\Windows\SYSVOL' `
        -Force:$true
}
