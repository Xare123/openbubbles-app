[CmdletBinding()]
param(
    [ValidateRange(1, 200)]
    [int] $MaximumRuns = 50,
    [ValidateRange(30, 3600)]
    [int] $RunOnceTimeoutSeconds = 600,
    [switch] $BuildFirst
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-LatestSemanticReport {
    param([Parameter(Mandatory)][string] $ReportDirectory)

    return Get-ChildItem `
        -LiteralPath $ReportDirectory `
        -Filter "obcs2-semantic-*.json" `
        -File `
        -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
}

function Get-RequiredPropertyValue {
    param(
        [Parameter(Mandatory)][object] $InputObject,
        [Parameter(Mandatory)][string] $Name
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        throw "The semantic report is missing required property '$Name'."
    }
    return $property.Value
}

function Read-VerifiedCatchUpReport {
    param([Parameter(Mandatory)][System.IO.FileInfo] $Report)

    try {
        $payload = Get-Content -LiteralPath $Report.FullName -Raw |
            ConvertFrom-Json
    }
    catch {
        throw "The new semantic report is not valid JSON."
    }

    $requiredFalse = @(
        'automaticTriggersEnabled',
        'remoteSavesEnabled',
        'remoteDeletesEnabled',
        'tombstoneSemanticDeletesEnabled'
    )
    foreach ($name in $requiredFalse) {
        if ((Get-RequiredPropertyValue -InputObject $payload -Name $name) -ne
            $false) {
            throw "Read-only invariant '$name' is not false."
        }
    }
    if ((Get-RequiredPropertyValue `
            -InputObject $payload `
            -Name 'retainedUnprojectedEvidencePreserved') -ne $true) {
        throw "Retained CloudKit evidence is not declared preserved."
    }
    if ((Get-RequiredPropertyValue -InputObject $payload -Name 'schemaVersion') `
            -ne 4 -or
        (Get-RequiredPropertyValue -InputObject $payload -Name 'mode') -ne
            'manual-semantic-read-only-cloudkit' -or
        (Get-RequiredPropertyValue -InputObject $payload -Name 'pageLimit') -ne
            4 -or
        (Get-RequiredPropertyValue -InputObject $payload -Name 'changeLimit') `
            -ne 50) {
        throw "The semantic report contract does not match the catch-up harness."
    }
    if ((Get-RequiredPropertyValue `
            -InputObject $payload `
            -Name 'outboxCountBefore') -ne 0 -or
        (Get-RequiredPropertyValue `
            -InputObject $payload `
            -Name 'outboxCountAfter') -ne 0) {
        throw "The semantic report violated the zero-outbox tripwire."
    }

    $zones = @(Get-RequiredPropertyValue -InputObject $payload -Name 'zones')
    $expectedZones = @('attachments', 'chats', 'messages')
    $actualZones = @($zones | ForEach-Object {
        [string](Get-RequiredPropertyValue -InputObject $_ -Name 'zone')
    } | Sort-Object -Unique)
    if ($zones.Count -ne $expectedZones.Count -or
        @(Compare-Object $expectedZones $actualZones).Count -ne 0) {
        throw "The semantic report does not contain exactly the three zones."
    }

    $zoneSummary = foreach ($zone in $zones) {
        $fetched = [int](Get-RequiredPropertyValue `
            -InputObject $zone `
            -Name 'fetched')
        $applied = [int](Get-RequiredPropertyValue `
            -InputObject $zone `
            -Name 'applied')
        $retained = [int](Get-RequiredPropertyValue `
            -InputObject $zone `
            -Name 'retainedUnprojected')
        if ($fetched -lt 0 -or $fetched -gt 200 -or
            $applied -lt 0 -or $applied -gt 200 -or
            $retained -lt 0 -or $retained -gt 10000) {
            throw "A semantic zone counter is outside its safe bounds."
        }
        [pscustomobject]@{
            Zone = [string]$zone.zone
            Fetched = $fetched
            Applied = $applied
            Retained = $retained
        }
    }

    return [pscustomobject]@{
        Path = $Report.FullName
        BuildCommit = [string](Get-RequiredPropertyValue `
            -InputObject $payload `
            -Name 'buildCommit')
        Zones = @($zoneSummary)
        Fetched = [int](@($zoneSummary |
            Measure-Object -Property Fetched -Sum).Sum)
        Applied = [int](@($zoneSummary |
            Measure-Object -Property Applied -Sum).Sum)
        Retained = [int](@($zoneSummary |
            Measure-Object -Property Retained -Sum).Sum)
    }
}

if ($MyInvocation.InvocationName -eq '.') {
    return
}

$runner = Join-Path $PSScriptRoot 'run_cloud_sync_v2_dev.ps1'
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
    throw "The Windows CloudKit fast-loop runner was not found."
}
$profile = Join-Path $env:APPDATA 'OpenBubbles\cloudkit-v2-dev'
$reportDirectory = Join-Path $profile 'cloud-sync-v2\reports'
if (-not (Test-Path -LiteralPath $reportDirectory -PathType Container)) {
    throw "The isolated Windows CloudKit report directory was not found."
}

$totalFetched = 0
$totalApplied = 0
for ($run = 1; $run -le $MaximumRuns; $run++) {
    $before = Get-LatestSemanticReport -ReportDirectory $reportDirectory
    $parameters = @{
        RunOnce = $true
        RunOnceTimeoutSeconds = $RunOnceTimeoutSeconds
    }
    if (-not ($BuildFirst -and $run -eq 1)) {
        $parameters.SkipBuild = $true
    }

    & $runner @parameters
    if ($LASTEXITCODE -ne 0) {
        throw "The Windows CloudKit fast-loop run failed."
    }

    $after = Get-LatestSemanticReport -ReportDirectory $reportDirectory
    if ($null -eq $after -or
        ($null -ne $before -and $after.FullName -eq $before.FullName)) {
        throw "The Windows CloudKit fast loop did not create a new report."
    }
    $summary = Read-VerifiedCatchUpReport -Report $after
    $totalFetched += $summary.Fetched
    $totalApplied += $summary.Applied

    $zoneText = ($summary.Zones | Sort-Object Zone | ForEach-Object {
        '{0}:fetched={1},applied={2},retained={3}' -f
            $_.Zone,
            $_.Fetched,
            $_.Applied,
            $_.Retained
    }) -join '; '
    Write-Host (
        'CloudKit catch-up run {0}/{1}: {2}' -f
        $run,
        $MaximumRuns,
        $zoneText
    )

    if ($summary.Fetched -eq 0) {
        Write-Host (
            'CloudKit catch-up reached the current server head after {0} ' +
            'run(s): fetched={1}, applied={2}, retained={3}, build={4}.' -f
            $run,
            $totalFetched,
            $totalApplied,
            $summary.Retained,
            $summary.BuildCommit
        )
        exit 0
    }
}

throw (
    'CloudKit catch-up reached its {0}-run safety limit after fetching {1} ' +
    'record(s). Durable tokens were preserved; rerun to continue.' -f
    $MaximumRuns,
    $totalFetched
)
