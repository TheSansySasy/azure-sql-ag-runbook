<#
.SYNOPSIS
    Moves the availability group to the secondary when the primary's CPU stays
    high, so the listener moves before the primary becomes unusable.

.DESCRIPTION
    Samples the primary's processor load over a window, and fails over only if
    all of these hold:
      - the average stayed above the threshold for the whole window, so a spike
        never moves the cluster;
      - every database on the target secondary is SYNCHRONIZED, so no committed
        transaction can be lost;
      - no failover happened within the cooldown, so the group cannot flap.
    Otherwise it alerts and leaves the decision to a person.

    Runs from a management host or the secondary, with the SqlServer and
    FailoverClusters modules. Supports -WhatIf.

.EXAMPLE
    .\Invoke-CpuFailover.ps1 -Primary sql1 -Secondary sql2 -AvailabilityGroup ag1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $Primary,
    [Parameter(Mandatory)] [string] $Secondary,
    [Parameter(Mandatory)] [string] $AvailabilityGroup,
    [string] $Instance = 'DEFAULT',

    [ValidateRange(50, 100)]
    [int] $ThresholdPercent = 90,

    [ValidateRange(15, 900)]
    [int] $WindowSeconds = 120,

    [ValidateRange(5, 1440)]
    [int] $CooldownMinutes = 30,

    # Where the time of the last failover is kept. Defaults under ProgramData.
    [string] $StateFile,
    [string] $WebhookUrl
)

function Get-FailoverDecision {
    <# The whole policy, as a pure function the tests can exercise. #>
    param(
        [Parameter(Mandatory)] [double] $AverageCpu,
        [Parameter(Mandatory)] [int] $Threshold,
        [Parameter(Mandatory)] [int] $LaggingDatabases,
        [Nullable[datetime]] $LastFailover,
        [Parameter(Mandatory)] [int] $CooldownMinutes,
        [datetime] $Now = (Get-Date)
    )
    if ($AverageCpu -lt $Threshold) {
        return [pscustomobject]@{ FailOver = $false; Alert = $false; Reason = "CPU $AverageCpu% is below $Threshold%" }
    }
    if ($LaggingDatabases -gt 0) {
        return [pscustomobject]@{ FailOver = $false; Alert = $true; Reason = "CPU $AverageCpu%, but $LaggingDatabases database(s) on the secondary are not synchronized" }
    }
    if ($LastFailover -and ($Now - $LastFailover).TotalMinutes -lt $CooldownMinutes) {
        return [pscustomobject]@{ FailOver = $false; Alert = $true; Reason = "CPU $AverageCpu%, but the last failover was under $CooldownMinutes minutes ago" }
    }
    return [pscustomobject]@{ FailOver = $true; Alert = $true; Reason = "CPU $AverageCpu% sustained above $Threshold%, secondary synchronized" }
}

function Send-Alert {
    param([string] $Message)
    Write-Warning $Message
    if ($WebhookUrl) {
        $body = @{ text = "[$AvailabilityGroup] $Message" } | ConvertTo-Json
        Invoke-RestMethod -Method Post -Uri $WebhookUrl -ContentType 'application/json' -Body $body | Out-Null
    }
}

function Invoke-CpuCheck {
    if (-not $StateFile) { $StateFile = Join-Path $env:ProgramData 'AgOps\last-failover.txt' }
    $samples = [math]::Max(1, [int]($WindowSeconds / 15))
    $load = (Get-Counter -ComputerName $Primary -Counter '\Processor(_Total)\% Processor Time' `
            -SampleInterval 15 -MaxSamples $samples).CounterSamples |
        Measure-Object -Property CookedValue -Average
    $average = [math]::Round($load.Average, 1)

    $lagging = (Invoke-Sqlcmd -ServerInstance $Secondary -TrustServerCertificate -Query @"
SELECT COUNT(*) AS n
FROM sys.dm_hadr_database_replica_states
WHERE is_local = 1 AND synchronization_state_desc <> 'SYNCHRONIZED';
"@).n

    $last = if (Test-Path $StateFile) { [datetime](Get-Content $StateFile -Raw) } else { $null }
    $decision = Get-FailoverDecision -AverageCpu $average -Threshold $ThresholdPercent `
        -LaggingDatabases $lagging -LastFailover $last -CooldownMinutes $CooldownMinutes
    Write-Verbose $decision.Reason

    if (-not $decision.FailOver) {
        if ($decision.Alert) { Send-Alert $decision.Reason }
        return
    }

    $path = "SQLSERVER:\SQL\$Secondary\$Instance\AvailabilityGroups\$AvailabilityGroup"
    if ($PSCmdlet.ShouldProcess($Secondary, "Fail over availability group $AvailabilityGroup")) {
        # Run against the target secondary; the listener follows the new primary.
        Switch-SqlAvailabilityReplica -Path $path
        New-Item -ItemType Directory -Force -Path (Split-Path $StateFile) | Out-Null
        (Get-Date).ToString('o') | Set-Content -Path $StateFile
        Send-Alert "Failed over to $Secondary. $($decision.Reason)."
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-CpuCheck
}
