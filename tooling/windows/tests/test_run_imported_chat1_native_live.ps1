$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$launcher = Join-Path $PSScriptRoot '../run_imported_chat1_native_live.ps1'
. $launcher -FunctionsOnlyForTest

$script:Pass = 0
$script:Fail = 0
function Assert-Check([string] $Name, [bool] $Condition) {
    if ($Condition) { Write-Host "PASS $Name"; $script:Pass++ }
    else { Write-Host "FAIL $Name"; $script:Fail++ }
}
function Assert-Fails([string] $Name, [scriptblock] $Body, [string] $Code) {
    $matched = $false
    try { & $Body } catch { $matched = $_.Exception.Message.Contains($Code) }
    Assert-Check $Name $matched
}
function New-PeBytes {
    $bytes = New-Object byte[] 512
    $bytes[0] = 0x4d; $bytes[1] = 0x5a
    [BitConverter]::GetBytes([int]128).CopyTo($bytes, 0x3c)
    $bytes[128] = 0x50; $bytes[129] = 0x45
    $bytes[130] = 0; $bytes[131] = 0
    [BitConverter]::GetBytes([uint16]0xAA64).CopyTo($bytes, 132)
    return $bytes
}
function New-SourceRow {
    return [ordered]@{
        change_id_hash = 'A' * 43
        record_id_hash = 'B' * 43
        etag_hash = $null
        payload_sha256 = 'c' * 64
        payload_length = [long]1
        server_modified_at_millis = [long]0
        protected_raw_envelope_reference = 'obcs2.ref.' + ('D' * 43)
    }
}
function New-Aggregate {
    $report = [ordered]@{}
    foreach ($name in $script:StandaloneAggregateFields) { $report[$name] = [long]0 }
    $report.completed = $true
    $report.failure_code = $null
    $report.message_sources = [long]8
    $report.decoded_message_routes = [long]8
    $report.anchor_message_sources = [long]8
    $report.decoded_anchor_messages = [long]7
    $report.skipped_anchor_messages = [long]1
    $report.paged_route_field_failure_matrix = @([long]0) * 105
    $report.paged_terminal_reached = $true
    $report.paged_budget_exhausted = $false
    return [pscustomobject]$report
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('chat1-native-launcher-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $scratch
try {
    $profile = Join-Path $scratch 'OpenBubbles/cloudkit-v2-dev'
    $diagnostics = Join-Path $profile 'cloud-sync-v2/diagnostics'
    $hostDirectory = Join-Path $profile 'cloud-sync-v2/native-test-host'
    $null = New-Item -ItemType Directory -Path $diagnostics -Force
    $null = New-Item -ItemType Directory -Path $hostDirectory -Force
    $profileMarker = Join-Path $profile '.openbubbles-cloud-sync-v2-windows-dev'
    Set-Content -LiteralPath $profileMarker -NoNewline -Encoding ASCII -Value 'openbubbles-cloud-sync-v2-windows-dev-profile:v1'
    $resolved = Resolve-StandaloneProfile -Candidate $profile -ExpectedBase $profile
    Assert-Check 'exact-profile-accepted' ($resolved -ceq
        [IO.Path]::GetFullPath($profile).TrimEnd('\', '/'))
    $alpha = Join-Path $scratch 'alpha/cloudkit-v2-dev'
    $null = New-Item -ItemType Directory -Path $alpha -Force
    Assert-Fails 'alpha-profile-rejected' {
        Resolve-StandaloneProfile -Candidate $alpha -ExpectedBase $alpha
    } 'protected_profile_segment_rejected'

    $manifest = [ordered]@{
        schema = [long]2
        server_modified_at_format = 'unix_epoch_milliseconds'
        content_exposed = $false
        account_fingerprint = 'E' * 43
        protected_store_identity = 'obcs2.store.' + ('F' * 43)
        message_generation = [long]1
        message_sources = @(1..8 | ForEach-Object { New-SourceRow })
        anchor_message_sources = @(1..8 | ForEach-Object { New-SourceRow })
        chat1_generation = [long]2
        chat1_sources = @(1..50 | ForEach-Object { New-SourceRow })
    }
    $manifestPath = Join-Path $diagnostics 'chat1-correlation-input-v2.json'
    $manifest | ConvertTo-Json -Depth 8 -Compress |
        Set-Content -LiteralPath $manifestPath -Encoding UTF8
    $manifestInfo = Assert-StandaloneManifest -Profile $profile
    Assert-Check 'manifest-v2-accepted' ($manifestInfo.MessageSources -eq 8 -and
        $manifestInfo.Chat1Sources -eq 50)
    $manifest['extra'] = 'rejected'
    $manifest | ConvertTo-Json -Depth 8 -Compress |
        Set-Content -LiteralPath $manifestPath -Encoding UTF8
    Assert-Fails 'manifest-unknown-field-rejected' {
        Assert-StandaloneManifest -Profile $profile
    } 'manifest_header_rejected'
    $manifest.Remove('extra')
    $manifest | ConvertTo-Json -Depth 8 -Compress |
        Set-Content -LiteralPath $manifestPath -Encoding UTF8

    foreach ($leaf in $script:StandaloneRuntimeFiles) {
        [IO.File]::WriteAllBytes((Join-Path $hostDirectory $leaf), (New-PeBytes))
    }
    $script:FakeObjectBoxHash = (Get-FileHash -LiteralPath (Join-Path $hostDirectory 'objectbox.dll') -Algorithm SHA256).Hash.ToLowerInvariant()
    function Get-StandaloneObjectBoxPin { return $script:FakeObjectBoxHash }
    $script:FakeThumb = '1' * 40
    function Get-AuthenticodeSignature {
        param([string] $LiteralPath)
        return [pscustomobject]@{
            Status = 'Valid'
            SignerCertificate = [pscustomobject]@{ Thumbprint = $script:FakeThumb }
        }
    }
    $source = '2' * 40
    $pilot = '3' * 40
    $archive = '4' * 64
    $provenance = '5' * 64
    $files = [ordered]@{}
    foreach ($leaf in $script:StandaloneRuntimeFiles) {
        $files[$leaf] = (Get-FileHash -LiteralPath (Join-Path $hostDirectory $leaf) -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    [ordered]@{
        version = 'cloud-sync-v2-windows-native-test-host-v1'
        artifact_mode = 'native-test-host'
        variant = 'read-only'
        source_commit = $source
        pilot_commit = $pilot
        archive_sha256 = $archive
        provenance_sha256 = $provenance
        files = $files
        signing_thumbprint = $script:FakeThumb
        created_utc = [datetime]::UtcNow.ToString('o')
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $hostDirectory 'native-test-host-receipt.json') -Encoding UTF8
    $hostInfo = Assert-StandaloneTestHost -Profile $profile -ExpectedSource $source -ExpectedPilot $pilot -ExpectedArchive $archive -ExpectedProvenance $provenance -ExpectedSigner $script:FakeThumb
    Assert-Check 'receipt-signature-machine-pin-accepted' ($hostInfo.Hashes.Count -eq 3)
    Assert-Fails 'receipt-caller-source-binding' {
        Assert-StandaloneTestHost -Profile $profile -ExpectedSource ('6' * 40) -ExpectedPilot $pilot -ExpectedArchive $archive -ExpectedProvenance $provenance -ExpectedSigner $script:FakeThumb
    } 'test_host_receipt_rejected'

    $env:OPENBUBBLES_CLOUDKIT_WRITER_OWNER = 'v2'
    Assert-Fails 'writer-environment-rejected' {
        Assert-StandaloneNoWriterEnvironment
    } 'writer_environment_rejected'
    Remove-Item Env:OPENBUBBLES_CLOUDKIT_WRITER_OWNER -ErrorAction SilentlyContinue

    $start = New-StandaloneStartInfo -Executable $hostInfo.Executable -WorkingDirectory $hostInfo.Directory -AppData $scratch -GraphEnabled $false
    $args = @($start.ArgumentList)
    Assert-Check 'exact-test-arguments' (
        $args.Count -eq 7 -and $args[0] -ceq $script:StandaloneTestName -and
        $args -ccontains '--ignored' -and $args -ccontains '--exact' -and
        $args -ccontains '--test-threads=1' -and
        $args -ccontains '--nocapture')
    $required = @(
        'OPENBUBBLES_RUN_CHAT1_STANDALONE_LIVE',
        'OPENBUBBLES_CLOUD_SYNC_V2_TEST_HOST',
        'OPENBUBBLES_INSPECT_CHAT1_CORRELATION',
        'OPENBUBBLES_INSPECT_CHAT1_SEMANTIC_CORRELATION',
        'OPENBUBBLES_INSPECT_CHAT1_PAGED_CORRELATION'
    )
    Assert-Check 'five-required-child-environments' (
        @($required | Where-Object { $start.Environment[$_] -cne '1' }).Count -eq 0 -and
        -not $start.Environment.ContainsKey(
            'OPENBUBBLES_INSPECT_CHAT1_PSEUDONYMOUS_GRAPH'))
    $graphStart = New-StandaloneStartInfo -Executable $hostInfo.Executable -WorkingDirectory $hostInfo.Directory -AppData $scratch -GraphEnabled $true
    Assert-Check 'graph-child-environments-explicit' (
        $graphStart.Environment['OPENBUBBLES_INSPECT_CHAT1_PSEUDONYMOUS_GRAPH'] -ceq '1' -and
        $graphStart.Environment['OPENBUBBLES_ACKNOWLEDGE_LOCAL_PERSONAL_DATA'] -ceq '1')

    $knownFailure = 'chat1_standalone_read_authentication_refresh_relay_unavailable'
    Assert-Fails 'native-failure-precedes-success-proof' {
        Assert-StandaloneExecutionProof -ExitCode 101 -Stdout '' `
            -SafeFailureCode $knownFailure
    } $knownFailure
    $successOutput = "test $script:StandaloneTestName ... ok`n" +
        'test result: ok. 1 passed; 0 failed; 696 ignored; 0 measured; 0 filtered out; finished in 0.01s'
    $successAccepted = $true
    try {
        Assert-StandaloneExecutionProof -ExitCode 0 -Stdout $successOutput `
            -SafeFailureCode 'native_test_failed_unclassified'
    } catch { $successAccepted = $false }
    Assert-Check 'exact-success-proof-accepted' $successAccepted
    $interleavedOutput = "test $script:StandaloneTestName ... " +
        "OPENBUBBLES_CONTENT_FREE_DIAGNOSTIC=1`nok`n" +
        'test result: ok. 1 passed; 0 failed; 696 ignored; 0 measured; 0 filtered out; finished in 0.01s'
    $interleavedAccepted = $true
    try {
        Assert-StandaloneExecutionProof -ExitCode 0 -Stdout $interleavedOutput `
            -SafeFailureCode 'native_test_failed_unclassified'
    } catch { $interleavedAccepted = $false }
    Assert-Check 'nocapture-interleaved-success-proof-accepted' $interleavedAccepted
    $marker = 'OPENBUBBLES_TEST_MARKER='
    $interleavedMarker = Get-StandaloneMarkerPayload `
        -Output ("test $script:StandaloneTestName ... ${marker}" +
            '{"ok":true}' + "`nok") `
        -Marker $marker -FailureCode 'marker_rejected'
    Assert-Check 'nocapture-interleaved-marker-accepted' (
        $interleavedMarker -ceq '{"ok":true}')
    Assert-Fails 'duplicate-marker-rejected' {
        Get-StandaloneMarkerPayload -Output "${marker}{}`n${marker}{}" `
            -Marker $marker -FailureCode 'marker_rejected'
    } 'marker_rejected'

    $aggregate = Assert-StandaloneAggregate (New-Aggregate)
    Assert-Check 'aggregate-v2-shape-accepted' ($aggregate.message_sources -eq 8)
    $badAggregate = New-Aggregate
    $badAggregate.PSObject.Properties.Remove('paged_terminal_reached')
    Assert-Fails 'aggregate-missing-field-rejected' {
        Assert-StandaloneAggregate $badAggregate
    } 'aggregate_header_rejected'
    $badMatrix = New-Aggregate
    $badMatrix.paged_route_field_failure_matrix = @(0) * 104
    Assert-Fails 'aggregate-matrix-length-rejected' {
        Assert-StandaloneAggregate $badMatrix
    } 'aggregate_matrix_rejected'

    $graph = [pscustomobject][ordered]@{
        schema = [long]2
        content_exposed = $false
        raw_identifiers_exposed = $false
        anchor_sources = [long]8
        decoded_anchor_sources = [long]0
        skipped_anchor_sources = [long]8
        pages_scanned = [long]1
        changes_scanned = [long]2
        chat_records = [long]0
        tombstones = [long]0
        other_records = [long]0
        terminal_reached = $true
        symbol_count = [long]0
        chat1_field_shape_counts = [pscustomobject]@{}
        messages = @(1..8)
        chats = @()
    }
    $validatedGraph = Assert-StandaloneGraph $graph 100
    Assert-Check 'pseudonymous-graph-v2-accepted' ($validatedGraph.content_exposed -eq $false)
    $graph.raw_identifiers_exposed = $true
    Assert-Fails 'graph-raw-identifiers-rejected' {
        Assert-StandaloneGraph $graph 100
    } 'graph_header_rejected'
    $graph.raw_identifiers_exposed = $false
    $graph.messages = @(1..7)
    Assert-Fails 'graph-target-cohort-count-rejected' {
        Assert-StandaloneGraph $graph 100
    } 'graph_bounds_rejected'
}
finally {
    Remove-Item Env:OPENBUBBLES_CLOUDKIT_WRITER_OWNER -ErrorAction SilentlyContinue
    $resolvedScratch = [IO.Path]::GetFullPath($scratch)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolvedScratch.StartsWith($tempRoot,
        [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedScratch) -like 'chat1-native-launcher-*') {
        Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
    }
}

Write-Host "RESULT pass=$script:Pass fail=$script:Fail"
if ($script:Fail -ne 0) { exit 1 }
