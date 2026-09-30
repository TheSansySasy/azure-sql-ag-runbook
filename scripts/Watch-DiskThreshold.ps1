<#
.SYNOPSIS
    Warns before a volume fills, not after the database stops writing.

.DESCRIPTION
    Checks every fixed volume on this machine against a warning and a critical
    free-space threshold, prints one line per volume, optionally posts a
    message to a chat webhook, and exits 0 (ok), 1 (warning) or 2 (critical)
    so Task Scheduler, Zabbix or any monitoring agent can act on the result.

.EXAMPLE
    .\Watch-DiskThreshold.ps1 -WarnPercent 20 -CriticalPercent 10 -WebhookUrl $env:ALERT_WEBHOOK
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 99)]
    [int] $WarnPercent = 20,

    [ValidateRange(1, 99)]
    [int] $CriticalPercent = 10,

    # A Teams or Slack incoming webhook. Both accept {"text": "..."}.
    [string] $WebhookUrl
)

function Get-DiskVerdict {
    param(
        [Parameter(Mandatory)] [double] $FreePercent,
        [Parameter(Mandatory)] [int] $Warn,
        [Parameter(Mandatory)] [int] $Critical
    )
    if ($FreePercent -le $Critical) { return 'critical' }
    if ($FreePercent -le $Warn) { return 'warning' }
    return 'ok'
}

function Get-ExitCode {
    param([string[]] $Verdicts)
    if ($Verdicts -contains 'critical') { return 2 }
    if ($Verdicts -contains 'warning') { return 1 }
    return 0
}

function Invoke-DiskCheck {
    if ($CriticalPercent -ge $WarnPercent) {
        throw 'CriticalPercent must be lower than WarnPercent.'
    }

    $results = Get-Volume |
        Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter -and $_.Size -gt 0 } |
        ForEach-Object {
            $free = [math]::Round(100 * $_.SizeRemaining / $_.Size, 1)
            [pscustomobject]@{
                Volume      = "$($_.DriveLetter):"
                Label       = $_.FileSystemLabel
                FreePercent = $free
                FreeGB      = [math]::Round($_.SizeRemaining / 1GB, 1)
                Verdict     = Get-DiskVerdict -FreePercent $free -Warn $WarnPercent -Critical $CriticalPercent
            }
        }

    $results | Format-Table -AutoSize | Out-String | Write-Host

    $problems = @($results | Where-Object Verdict -ne 'ok')
    if ($problems.Count -gt 0 -and $WebhookUrl) {
        $lines = $problems | ForEach-Object { "$($_.Verdict.ToUpper()) $($_.Volume) $($_.Label): $($_.FreePercent)% free ($($_.FreeGB) GB)" }
        $body = @{ text = "Disk space on $env:COMPUTERNAME`n$($lines -join "`n")" } | ConvertTo-Json
        Invoke-RestMethod -Method Post -Uri $WebhookUrl -ContentType 'application/json' -Body $body | Out-Null
    }

    return Get-ExitCode -Verdicts @($results.Verdict)
}

# Dot-sourcing (as the tests do) loads the functions without running the check.
if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-DiskCheck)
}
