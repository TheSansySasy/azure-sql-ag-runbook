<#
.SYNOPSIS
    The checks for KRB_AP_ERR_MODIFIED, in the order they rule causes out.

.DESCRIPTION
    KRB_AP_ERR_MODIFIED means the server could not decrypt the service ticket
    it was handed: the key the domain sealed it with does not match the key
    the service holds. This script checks the usual causes first and the one
    that is easy to miss last:
      1. duplicate service principal names anywhere in the domain;
      2. the SQL service account's SPNs, including the listener's;
      3. this node's machine account password against the domain;
      4. cluster groups and resources that are not online. A cluster role such
         as Cluster-Aware Updating owns a computer object of its own, and an
         offline role is not a harmless one.
    Prints a table and exits 1 if anything failed.

.EXAMPLE
    .\Test-KerberosHealth.ps1 -SqlServiceAccount 'CONTOSO\svc-sql' -ListenerFqdn 'aglisten.contoso.local'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SqlServiceAccount,
    [Parameter(Mandatory)] [string] $ListenerFqdn,
    [int] $Port = 1433,
    [string] $Cluster = '.'
)

function Get-DuplicateSpnGroupCount {
    <# Reads the summary line of `setspn -X`: "found N group of duplicate SPNs." #>
    param([Parameter(Mandatory)] [AllowEmptyString()] [string[]] $SetspnOutput)
    $summary = $SetspnOutput | Select-String -Pattern 'found (\d+) group' | Select-Object -Last 1
    if (-not $summary) { throw 'Could not read the setspn -X summary line.' }
    return [int]$summary.Matches[0].Groups[1].Value
}

function Test-SpnPresent {
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string[]] $SetspnListing,
        [Parameter(Mandatory)] [string] $Spn
    )
    return [bool]($SetspnListing | Where-Object { $_.Trim() -ieq $Spn })
}

function New-Check {
    param([string] $Name, [bool] $Passed, [string] $Detail)
    [pscustomobject]@{ Check = $Name; Result = $(if ($Passed) { 'pass' } else { 'FAIL' }); Detail = $Detail }
}

function Invoke-KerberosChecks {
    $checks = @()

    $duplicates = Get-DuplicateSpnGroupCount -SetspnOutput (setspn -X 2>&1 | ForEach-Object { "$_" })
    $checks += New-Check 'Duplicate SPNs in the domain' ($duplicates -eq 0) "$duplicates duplicate group(s)"

    $listing = setspn -L $SqlServiceAccount 2>&1 | ForEach-Object { "$_" }
    $expected = "MSSQLSvc/$ListenerFqdn`:$Port"
    $checks += New-Check "Listener SPN on $SqlServiceAccount" (Test-SpnPresent -SetspnListing $listing -Spn $expected) $expected

    $secure = Test-ComputerSecureChannel -ErrorAction SilentlyContinue
    $checks += New-Check "Machine account of $env:COMPUTERNAME" $secure $(if ($secure) { 'in step with the domain' } else { 'secure channel broken' })

    $groups = @(Get-ClusterGroup -Cluster $Cluster | Where-Object State -ne 'Online')
    $checks += New-Check 'Cluster groups online' ($groups.Count -eq 0) (($groups | ForEach-Object { "$($_.Name) is $($_.State)" }) -join '; ')

    $resources = @(Get-ClusterResource -Cluster $Cluster | Where-Object State -ne 'Online')
    $checks += New-Check 'Cluster resources online' ($resources.Count -eq 0) (($resources | ForEach-Object { "$($_.Name) ($($_.ResourceType)) is $($_.State)" }) -join '; ')

    $checks | Format-Table -AutoSize -Wrap | Out-String | Write-Host
    if ($checks.Result -contains 'FAIL') { return 1 }
    return 0
}

if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-KerberosChecks)
}
