# Install progress in the desktop: a completed stage must stay completed when its event is no longer among the
# newest events the dashboard polls (long or parallel runs produce more events than one refresh reads).
BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'PASeasyInstall.UI/Presentation.ps1')
    function New-Evt([int]$Second, [string]$Component, [string]$Stage, [string]$Status, [string]$Message = '') {
        [pscustomobject]@{ TimestampUtc = ([datetime]'2026-11-18T10:00:00Z').AddSeconds($Second).ToString('o')
            Component = $Component; Stage = $Stage; Event = 'Step'; Level = 'Information'; Status = $Status; Message = $Message }
    }
    $script:plan = @([pscustomobject]@{ Id = 'pas-pvwa'; Type = 'PVWA'; Host = 'pas-pvwa'; Address = '192.0.2.33'; Name = 'PVWA01' })
    $script:catalog = @{ PVWA = @('management', 'install') }
}

Describe 'Install progress history' {
    It 'keeps a completed stage completed after its event leaves the polled window' {
        $history = @{}
        $first = @((New-Evt 1 'pas-pvwa' 'management' 'Running'), (New-Evt 2 'pas-pvwa' 'management' 'Complete'))
        $null = Merge-PASUIEventHistory -History $history -Events $first
        # A later refresh only sees the newest 200 events: 300 install lines, none for 'management'.
        $later = @(1..300 | ForEach-Object { New-Evt (10 + $_) 'pas-pvwa' 'install' 'Running' "line $_" } | Select-Object -Last 200)
        $all = Merge-PASUIEventHistory -History $history -Events $later
        $all.Count | Should -Be 202
        $snap = [pscustomobject]@{ RunId = ('a' * 32); Status = 'Running'; CurrentComponent = 'pas-pvwa'; LastStep = 'install'; ErrorEvents = 0; Events = $all }
        $html = ConvertTo-PASUIDashboardHtml -Snapshot $snap -PlanItems $script:plan -Catalog $script:catalog
        $html | Should -Match 'pas-chip complete">management<'
        $html | Should -Match '1 / 2 stages'
    }

    It 'does not duplicate events seen in overlapping refreshes and keeps them in time order' {
        $history = @{}
        $a = @((New-Evt 5 'x' 's' 'Running' 'b'), (New-Evt 1 'x' 's' 'Running' 'a'))
        $null = Merge-PASUIEventHistory -History $history -Events $a
        $all = Merge-PASUIEventHistory -History $history -Events @($a + (New-Evt 9 'x' 's' 'Complete' 'c'))
        @($all | ForEach-Object Message) -join ',' | Should -Be 'a,b,c'
    }

    It 'keeps arrival order for events with the same timestamp' {
        $history = @{}
        $all = Merge-PASUIEventHistory -History $history -Events @((New-Evt 3 'x' 's' 'Running' 'first'), (New-Evt 3 'x' 's' 'Complete' 'second'))
        @($all | ForEach-Object Message) -join ',' | Should -Be 'first,second'
    }
}
