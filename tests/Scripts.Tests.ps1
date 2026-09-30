# Pester 5. Dot-sources each script, which loads its functions without running it.

BeforeAll {
    . "$PSScriptRoot/../scripts/Watch-DiskThreshold.ps1"
    . "$PSScriptRoot/../scripts/Invoke-CpuFailover.ps1" -Primary p -Secondary s -AvailabilityGroup ag
    . "$PSScriptRoot/../scripts/Test-KerberosHealth.ps1" -SqlServiceAccount svc -ListenerFqdn listener
}

Describe 'Get-DiskVerdict' {
    It 'is <expected> at <free>% free' -ForEach @(
        @{ free = 45; expected = 'ok' }
        @{ free = 20; expected = 'warning' }
        @{ free = 12.5; expected = 'warning' }
        @{ free = 10; expected = 'critical' }
        @{ free = 0; expected = 'critical' }
    ) {
        Get-DiskVerdict -FreePercent $free -Warn 20 -Critical 10 | Should -Be $expected
    }

    It 'exits with the worst verdict' {
        Get-ExitCode -Verdicts @('ok', 'warning', 'ok') | Should -Be 1
        Get-ExitCode -Verdicts @('ok', 'critical', 'warning') | Should -Be 2
        Get-ExitCode -Verdicts @('ok') | Should -Be 0
    }
}

Describe 'Get-FailoverDecision' {
    BeforeAll { $now = [datetime]'2026-10-01T12:00:00' }

    It 'does nothing below the threshold' {
        $d = Get-FailoverDecision -AverageCpu 70 -Threshold 90 -LaggingDatabases 0 -CooldownMinutes 30 -Now $now
        $d.FailOver | Should -BeFalse
        $d.Alert | Should -BeFalse
    }

    It 'never fails over to a secondary that is behind' {
        $d = Get-FailoverDecision -AverageCpu 97 -Threshold 90 -LaggingDatabases 2 -CooldownMinutes 30 -Now $now
        $d.FailOver | Should -BeFalse
        $d.Alert | Should -BeTrue
        $d.Reason | Should -Match 'not synchronized'
    }

    It 'waits out the cooldown so the group cannot flap' {
        $d = Get-FailoverDecision -AverageCpu 97 -Threshold 90 -LaggingDatabases 0 `
            -LastFailover $now.AddMinutes(-10) -CooldownMinutes 30 -Now $now
        $d.FailOver | Should -BeFalse
        $d.Reason | Should -Match 'under 30 minutes'
    }

    It 'fails over when the load is sustained and the secondary is synchronized' {
        $d = Get-FailoverDecision -AverageCpu 97 -Threshold 90 -LaggingDatabases 0 `
            -LastFailover $now.AddHours(-3) -CooldownMinutes 30 -Now $now
        $d.FailOver | Should -BeTrue
    }
}

Describe 'setspn parsing' {
    It 'reads the duplicate count from setspn -X' {
        $output = @('Checking domain DC=contoso,DC=local', 'Processing entry 0', '', 'found 0 group of duplicate SPNs.')
        Get-DuplicateSpnGroupCount -SetspnOutput $output | Should -Be 0
        Get-DuplicateSpnGroupCount -SetspnOutput @('found 2 group of duplicate SPNs.') | Should -Be 2
    }

    It 'fails loudly when the summary is missing' {
        { Get-DuplicateSpnGroupCount -SetspnOutput @('Access is denied.') } | Should -Throw
    }

    It 'finds an SPN in a setspn -L listing regardless of case and indentation' {
        $listing = @('Registered ServicePrincipalNames for CN=svc-sql:', "`tMSSQLSvc/AGListen.contoso.local:1433")
        Test-SpnPresent -SetspnListing $listing -Spn 'MSSQLSvc/aglisten.contoso.local:1433' | Should -BeTrue
        Test-SpnPresent -SetspnListing $listing -Spn 'MSSQLSvc/other:1433' | Should -BeFalse
    }
}
