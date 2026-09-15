[CmdletBinding()]
param(
    [switch] $EnableLive,
    [switch] $EnablePseudonymousGraph,
    [string] $ExpectedSourceSha,
    [string] $ExpectedPilotSha,
    [string] $ExpectedArchiveSha256,
    [string] $ExpectedProvenanceSha256,
    [string] $SigningThumbprint = '8240557965890665F3B49E5FEC83D511CA4F2C9D',
    [ValidateRange(30, 900)]
    [int] $TimeoutSeconds = 600,
    [switch] $FunctionsOnlyForTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Runs exactly one ignored, read-only Rust integration test from a previously
# verified and locally signed native-test-host bundle. This launcher never
# builds, imports, relabels, repairs, logs in, or enables a CloudKit writer.
# It is hard-bound to the isolated Windows dev profile and retains only a
# bounded aggregate plus an optional pseudonymous relationship graph.

$script:StandaloneTestName = 'api::cloud_sync_chat1_correlation::windows_standalone_live_tests::current_rust_correlates_exported_chat1_inputs_read_only'
$script:StandaloneAggregateMarker = 'OPENBUBBLES_CHAT1_STANDALONE_AGGREGATE='
$script:StandaloneGraphMarker = 'OPENBUBBLES_CHAT1_PSEUDONYMOUS_GRAPH='
$script:StandaloneObjectBoxSha256 = '9c8583c4015ab9e4ce2ed3d2d581811fa059e03bb528cb8c8387adcdfda8d8a5'
$script:StandaloneWriterEnvironment = @(
    'OPENBUBBLES_CLOUD_SYNC_V2_OUTBOUND_CANARY',
    'OPENBUBBLES_CLOUDKIT_WRITER_OWNER',
    'OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_REPLAY_EXCLUDED_CHATS',
    'OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_FINDMY_PROBE',
    'OPENBUBBLES_RUN_FINDMY_WINDOWS_LIVE',
    'OPENBUBBLES_VERIFY_EDIT_CLAIM',
    'OPENBUBBLES_VERIFY_CHAIN_UNSEND'
)
$script:StandaloneRuntimeFiles = @(
    'native-compose-tests.exe',
    'rust_lib_bluebubbles.dll',
    'objectbox.dll'
)
$script:StandaloneReceiptFields = @(
    'version', 'artifact_mode', 'variant', 'source_commit', 'pilot_commit',
    'archive_sha256', 'provenance_sha256', 'files', 'signing_thumbprint',
    'created_utc'
)
$script:StandaloneManifestFields = @(
    'schema', 'server_modified_at_format', 'content_exposed',
    'account_fingerprint', 'protected_store_identity', 'message_generation',
    'message_sources', 'anchor_message_sources', 'chat1_generation',
    'chat1_sources'
)
$script:StandaloneSourceFields = @(
    'change_id_hash', 'record_id_hash', 'etag_hash', 'payload_sha256',
    'payload_length', 'server_modified_at_millis',
    'protected_raw_envelope_reference'
)
$script:StandaloneAggregateFields = @(
    'completed', 'failure_code', 'message_sources', 'decoded_message_routes',
    'anchor_message_sources', 'decoded_anchor_messages',
    'skipped_anchor_messages', 'distinct_anchor_message_guids',
    'conflicting_anchor_message_guids', 'paged_pages_scanned',
    'paged_changes_scanned', 'paged_chat_records',
    'paged_record_decode_failures', 'paged_route_field_decode_failures',
    'paged_route_field_failure_matrix', 'paged_semantic_match_pairs',
    'paged_normalized_semantic_match_pairs',
    'paged_matched_message_routes',
    'paged_normalized_matched_message_routes',
    'paged_last_seen_target_message_match_pairs',
    'paged_last_seen_anchor_exact_match_pairs',
    'paged_last_seen_anchor_normalized_match_pairs',
    'paged_sender_service_style_match_pairs',
    'paged_sender_service_style_zero_candidate_targets',
    'paged_sender_service_style_unique_candidate_targets',
    'paged_sender_service_style_multiple_candidate_targets',
    'paged_last_seen_target_zero_candidate_targets',
    'paged_last_seen_target_unique_candidate_targets',
    'paged_last_seen_target_multiple_candidate_targets',
    'paged_anchor_exact_zero_candidate_targets',
    'paged_anchor_exact_unique_candidate_targets',
    'paged_anchor_exact_multiple_candidate_targets',
    'paged_anchor_normalized_zero_candidate_targets',
    'paged_anchor_normalized_unique_candidate_targets',
    'paged_anchor_normalized_multiple_candidate_targets',
    'paged_terminal_reached', 'paged_budget_exhausted'
)
$script:StandaloneGraphFields = @(
    'schema', 'content_exposed', 'raw_identifiers_exposed', 'anchor_sources',
    'decoded_anchor_sources', 'skipped_anchor_sources', 'pages_scanned',
    'changes_scanned', 'chat_records', 'tombstones', 'other_records',
    'terminal_reached', 'symbol_count', 'chat1_field_shape_counts',
    'messages', 'chats'
)

function Fail-StandaloneNativeLive {
    param([Parameter(Mandatory)][string] $Code)
    throw "NATIVE-LIVE-FAIL: $Code"
}

function Test-StandaloneExactProperties {
    param($Value, [Parameter(Mandatory)][string[]] $Expected)
    if ($null -eq $Value) { return $false }
    $actual = @($Value.PSObject.Properties.Name | Sort-Object)
    $wanted = @($Expected | Sort-Object)
    return -not [bool](Compare-Object -ReferenceObject $wanted -DifferenceObject $actual)
}

function Test-StandaloneInteger {
    param($Value)
    return ($Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64])
}

function Test-StandaloneNonNegativeInteger {
    param($Value)
    return (Test-StandaloneInteger $Value) -and ([decimal]$Value -ge 0)
}

function Get-StandaloneTextSha256 {
    param([Parameter(Mandatory)][string] $Value)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString(
            $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))
        )).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function New-StandaloneLaunchId {
    $bytes = New-Object byte[] 16
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $generator.GetBytes($bytes)
        return ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
    }
    finally { $generator.Dispose() }
}

function Assert-StandalonePlainPath {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Label)
    $current = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    while ($null -ne $current) {
        if (($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Fail-StandaloneNativeLive ($Label + '_reparse_rejected')
        }
        $parent = [IO.Path]::GetDirectoryName($current.FullName.TrimEnd('\', '/'))
        if ([string]::IsNullOrWhiteSpace($parent) -or
            $parent -ceq $current.FullName.TrimEnd('\', '/')) { break }
        if (-not (Test-Path -LiteralPath $parent)) { break }
        $current = Get-Item -LiteralPath $parent -Force -ErrorAction Stop
    }
}

function Resolve-StandaloneProfile {
    param([string] $Candidate = '', [string] $ExpectedBase = '')
    if ([string]::IsNullOrWhiteSpace($env:APPDATA) -and
        [string]::IsNullOrWhiteSpace($ExpectedBase)) {
        Fail-StandaloneNativeLive 'appdata_required'
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedBase)) {
        $ExpectedBase = Join-Path $env:APPDATA 'OpenBubbles\cloudkit-v2-dev'
    }
    $expected = [IO.Path]::GetFullPath($ExpectedBase).TrimEnd('\', '/')
    if ([string]::IsNullOrWhiteSpace($Candidate)) { $Candidate = $expected }
    $resolved = [IO.Path]::GetFullPath($Candidate).TrimEnd('\', '/')
    foreach ($segment in @($resolved -split '[\\/]')) {
        if ($segment -ieq 'alpha' -or $segment -ieq 'beta' -or
            $segment -ieq 'canary') {
            Fail-StandaloneNativeLive 'protected_profile_segment_rejected'
        }
    }
    if (-not $resolved.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
        Fail-StandaloneNativeLive 'profile_not_exact_isolated_dev'
    }
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
        Fail-StandaloneNativeLive 'profile_missing'
    }
    Assert-StandalonePlainPath -Path $resolved -Label 'profile'
    $marker = Join-Path $resolved '.openbubbles-cloud-sync-v2-windows-dev'
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
        Fail-StandaloneNativeLive 'profile_marker_missing'
    }
    Assert-StandalonePlainPath -Path $marker -Label 'profile_marker'
    if ((Get-Content -LiteralPath $marker -Raw) -cne
        'openbubbles-cloud-sync-v2-windows-dev-profile:v1') {
        Fail-StandaloneNativeLive 'profile_marker_rejected'
    }
    return $resolved
}

function Assert-StandaloneNoWriterEnvironment {
    foreach ($name in $script:StandaloneWriterEnvironment) {
        if ($null -ne [Environment]::GetEnvironmentVariable($name, 'Process')) {
            Fail-StandaloneNativeLive 'writer_environment_rejected'
        }
    }
}

function Enter-StandaloneProfileLock {
    param([Parameter(Mandatory)][string] $Profile)
    $canonical = ([IO.Path]::GetFullPath($Profile).TrimEnd('\')).ToUpperInvariant()
    $profileHash = Get-StandaloneTextSha256 -Value $canonical
    $mutex = [Threading.Mutex]::new($false,
        "Local\OpenBubblesCloudSyncV2Launcher-$profileHash")
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) {
            Fail-StandaloneNativeLive 'profile_owned_by_another_launcher'
        }
        return $mutex
    }
    catch {
        if (-not $acquired) { $mutex.Dispose() }
        throw
    }
}

function Get-StandalonePeMachine {
    param([Parameter(Mandatory)][string] $Path)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open,
        [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($stream.Length -lt 70 -or $reader.ReadUInt16() -ne 0x5A4D) {
            Fail-StandaloneNativeLive 'pe_header_rejected'
        }
        $stream.Position = 0x3c
        $offset = $reader.ReadInt32()
        if ($offset -lt 64 -or ([long]$offset + 6) -gt $stream.Length) {
            Fail-StandaloneNativeLive 'pe_header_rejected'
        }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x00004550) {
            Fail-StandaloneNativeLive 'pe_header_rejected'
        }
        return $reader.ReadUInt16()
    }
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Get-StandaloneObjectBoxPin {
    return $script:StandaloneObjectBoxSha256
}

function Assert-StandaloneTestHost {
    param(
        [Parameter(Mandatory)][string] $Profile,
        [Parameter(Mandatory)][string] $ExpectedSource,
        [Parameter(Mandatory)][string] $ExpectedPilot,
        [Parameter(Mandatory)][string] $ExpectedArchive,
        [Parameter(Mandatory)][string] $ExpectedProvenance,
        [Parameter(Mandatory)][string] $ExpectedSigner
    )
    if ($ExpectedSource -cnotmatch '^[0-9a-f]{40}$' -or
        $ExpectedPilot -cnotmatch '^[0-9a-f]{40}$' -or
        $ExpectedArchive -cnotmatch '^[0-9a-f]{64}$' -or
        $ExpectedProvenance -cnotmatch '^[0-9a-f]{64}$' -or
        $ExpectedSigner -notmatch '^[0-9A-Fa-f]{40}$') {
        Fail-StandaloneNativeLive 'expected_provenance_rejected'
    }
    $directory = [IO.Path]::GetFullPath((Join-Path $Profile 'cloud-sync-v2\native-test-host')).TrimEnd('\', '/')
    $prefix = $Profile.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $directory.StartsWith($prefix,
        [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $directory -PathType Container)) {
        Fail-StandaloneNativeLive 'test_host_directory_rejected'
    }
    Assert-StandalonePlainPath -Path $directory -Label 'test_host'
    $receiptPath = Join-Path $directory 'native-test-host-receipt.json'
    $allowed = @($script:StandaloneRuntimeFiles + 'native-test-host-receipt.json')
    $children = @(Get-ChildItem -LiteralPath $directory -Force)
    if ($children.Count -ne $allowed.Count) {
        Fail-StandaloneNativeLive 'test_host_inventory_rejected'
    }
    foreach ($child in $children) {
        if ($child.PSIsContainer -or
            ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $allowed -cnotcontains $child.Name) {
            Fail-StandaloneNativeLive 'test_host_inventory_rejected'
        }
        Assert-StandalonePlainPath -Path $child.FullName -Label 'test_host_file'
    }
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    if (-not (Test-StandaloneExactProperties $receipt $script:StandaloneReceiptFields) -or
        $receipt.version -cne 'cloud-sync-v2-windows-native-test-host-v1' -or
        $receipt.artifact_mode -cne 'native-test-host' -or
        $receipt.variant -cne 'read-only' -or
        $receipt.source_commit -cne $ExpectedSource -or
        $receipt.pilot_commit -cne $ExpectedPilot -or
        $receipt.archive_sha256 -cne $ExpectedArchive -or
        $receipt.provenance_sha256 -cne $ExpectedProvenance -or
        [string]$receipt.signing_thumbprint -ine $ExpectedSigner) {
        Fail-StandaloneNativeLive 'test_host_receipt_rejected'
    }
    if (-not (Test-StandaloneExactProperties $receipt.files $script:StandaloneRuntimeFiles)) {
        Fail-StandaloneNativeLive 'test_host_receipt_files_rejected'
    }
    $hashes = [ordered]@{}
    foreach ($leaf in $script:StandaloneRuntimeFiles) {
        $path = Join-Path $directory $leaf
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        $receiptHash = [string]$receipt.files.PSObject.Properties[$leaf].Value
        if ($receiptHash -cnotmatch '^[0-9a-f]{64}$' -or
            $hash -cne $receiptHash -or (Get-StandalonePeMachine $path) -ne 0xAA64) {
            Fail-StandaloneNativeLive 'test_host_binary_rejected'
        }
        $hashes[$leaf] = $hash
    }
    if ($hashes['objectbox.dll'] -cne (Get-StandaloneObjectBoxPin)) {
        Fail-StandaloneNativeLive 'objectbox_pin_rejected'
    }
    foreach ($leaf in @('native-compose-tests.exe', 'rust_lib_bluebubbles.dll')) {
        $path = Join-Path $directory $leaf
        $signature = Get-AuthenticodeSignature -LiteralPath $path
        if ([string]$signature.Status -cne 'Valid' -or
            $null -eq $signature.SignerCertificate -or
            [string]$signature.SignerCertificate.Thumbprint -ine $ExpectedSigner) {
            Fail-StandaloneNativeLive 'test_host_signature_rejected'
        }
    }
    return [pscustomobject]@{
        Directory = $directory
        Executable = Join-Path $directory 'native-compose-tests.exe'
        Receipt = $receiptPath
        Hashes = $hashes
    }
}

function Assert-StandaloneManifest {
    param([Parameter(Mandatory)][string] $Profile)
    $path = Join-Path $Profile 'cloud-sync-v2\diagnostics\chat1-correlation-input-v2.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Fail-StandaloneNativeLive 'manifest_missing'
    }
    Assert-StandalonePlainPath -Path $path -Label 'manifest'
    $file = Get-Item -LiteralPath $path -Force
    if ($file.Length -le 0 -or $file.Length -gt 4MB) {
        Fail-StandaloneNativeLive 'manifest_size_rejected'
    }
    $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if (-not (Test-StandaloneExactProperties $manifest $script:StandaloneManifestFields) -or
        -not (Test-StandaloneInteger $manifest.schema) -or
        [int]$manifest.schema -ne 2 -or
        $manifest.server_modified_at_format -cne 'unix_epoch_milliseconds' -or
        $manifest.content_exposed -ne $false -or
        $manifest.account_fingerprint -cnotmatch '^[A-Za-z0-9_-]{43}$' -or
        $manifest.protected_store_identity -cnotmatch
            '^obcs2\.store\.[A-Za-z0-9_-]{43}$' -or
        -not (Test-StandaloneNonNegativeInteger $manifest.message_generation) -or
        [decimal]$manifest.message_generation -le 0 -or
        -not (Test-StandaloneNonNegativeInteger $manifest.chat1_generation) -or
        [decimal]$manifest.chat1_generation -le 0) {
        Fail-StandaloneNativeLive 'manifest_header_rejected'
    }
    $message = @($manifest.message_sources)
    $anchor = @($manifest.anchor_message_sources)
    $chat1 = @($manifest.chat1_sources)
    if ($message.Count -ne 8 -or $anchor.Count -lt 8 -or
        $anchor.Count -gt 2048 -or $chat1.Count -ne 50) {
        Fail-StandaloneNativeLive 'manifest_shape_rejected'
    }
    foreach ($source in @($message + $anchor + $chat1)) {
        if (-not (Test-StandaloneExactProperties $source $script:StandaloneSourceFields) -or
            $source.change_id_hash -cnotmatch '^[A-Za-z0-9_-]{43}$' -or
            $source.record_id_hash -cnotmatch '^[A-Za-z0-9_-]{43}$' -or
            ($null -ne $source.etag_hash -and
                $source.etag_hash -cnotmatch '^[A-Za-z0-9_-]{43}$') -or
            $source.payload_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            ($null -ne $source.payload_length -and
                -not (Test-StandaloneNonNegativeInteger $source.payload_length)) -or
            ($null -ne $source.server_modified_at_millis -and
                -not (Test-StandaloneInteger $source.server_modified_at_millis)) -or
            $source.protected_raw_envelope_reference -cnotmatch
                '^obcs2\.ref\.[A-Za-z0-9_-]{43}$') {
            Fail-StandaloneNativeLive 'manifest_source_rejected'
        }
    }
    return [pscustomobject]@{
        Path = $path
        Sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        MessageSources = $message.Count
        AnchorSources = $anchor.Count
        Chat1Sources = $chat1.Count
    }
}

function Assert-StandaloneNoProfileOwner {
    $names = @('bluebubbles_app', 'flutter', 'dart', 'native-compose-tests')
    $found = @(Get-Process -Name $names -ErrorAction SilentlyContinue)
    if ($found.Count -ne 0) { Fail-StandaloneNativeLive 'profile_process_running' }
}

function Get-StandaloneDurableDigest {
    param([Parameter(Mandatory)][string] $Profile,
        [Parameter(Mandatory)][string] $ExcludedRoot)
    $excluded = [IO.Path]::GetFullPath($ExcludedRoot).TrimEnd('\', '/')
    $excludedPrefix = $excluded + [IO.Path]::DirectorySeparatorChar
    $rows = [Collections.Generic.List[string]]::new()
    foreach ($relativeRoot in @('cloud_sync_v2_native_store', 'cloud-sync-v2')) {
        $root = Join-Path $Profile $relativeRoot
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($item in @(Get-ChildItem -LiteralPath $root -Force -Recurse)) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Fail-StandaloneNativeLive 'durable_state_reparse_rejected'
            }
            $full = [IO.Path]::GetFullPath($item.FullName)
            if ($full.Equals($excluded, [StringComparison]::OrdinalIgnoreCase) -or
                $full.StartsWith($excludedPrefix,
                    [StringComparison]::OrdinalIgnoreCase)) { continue }
            if (-not $item.PSIsContainer) {
                $relative = [IO.Path]::GetRelativePath($Profile, $full).Replace('\', '/')
                $hash = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
                $rows.Add("$relative|$($item.Length)|$hash")
            }
        }
    }
    return Get-StandaloneTextSha256 -Value (@($rows | Sort-Object) -join "`n")
}

function New-StandaloneStartInfo {
    param(
        [Parameter(Mandatory)][string] $Executable,
        [Parameter(Mandatory)][string] $WorkingDirectory,
        [Parameter(Mandatory)][string] $AppData,
        [bool] $GraphEnabled
    )
    $start = [Diagnostics.ProcessStartInfo]::new($Executable)
    $start.WorkingDirectory = $WorkingDirectory
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($key in @($start.Environment.Keys)) {
        if ($key -like 'OPENBUBBLES_*' -or $key -ceq 'RUST_LOG') {
            $null = $start.Environment.Remove($key)
        }
    }
    foreach ($name in @(
        'OPENBUBBLES_RUN_CHAT1_STANDALONE_LIVE',
        'OPENBUBBLES_CLOUD_SYNC_V2_TEST_HOST',
        'OPENBUBBLES_INSPECT_CHAT1_CORRELATION',
        'OPENBUBBLES_INSPECT_CHAT1_SEMANTIC_CORRELATION',
        'OPENBUBBLES_INSPECT_CHAT1_PAGED_CORRELATION'
    )) { $start.Environment[$name] = '1' }
    if ($GraphEnabled) {
        $start.Environment['OPENBUBBLES_INSPECT_CHAT1_PSEUDONYMOUS_GRAPH'] = '1'
        $start.Environment['OPENBUBBLES_ACKNOWLEDGE_LOCAL_PERSONAL_DATA'] = '1'
    }
    $start.Environment['APPDATA'] = $AppData
    $start.Environment['PATH'] = "$WorkingDirectory;$($start.Environment['PATH'])"
    foreach ($argument in @(
        $script:StandaloneTestName, '--ignored', '--exact', '--test-threads=1',
        '--nocapture', '--format=pretty', '--color=never'
    )) { $start.ArgumentList.Add($argument) }
    return $start
}

function Assert-StandaloneAggregate {
    param($Report)
    if (-not (Test-StandaloneExactProperties $Report $script:StandaloneAggregateFields) -or
        $Report.completed -ne $true -or $null -ne $Report.failure_code -or
        $Report.paged_terminal_reached -isnot [bool] -or
        $Report.paged_budget_exhausted -isnot [bool]) {
        Fail-StandaloneNativeLive 'aggregate_header_rejected'
    }
    $countFields = @($script:StandaloneAggregateFields | Where-Object {
        $_ -notin @('completed', 'failure_code', 'paged_terminal_reached',
            'paged_budget_exhausted', 'paged_route_field_failure_matrix')
    })
    foreach ($name in $countFields) {
        if (-not (Test-StandaloneNonNegativeInteger $Report.PSObject.Properties[$name].Value)) {
            Fail-StandaloneNativeLive 'aggregate_counter_rejected'
        }
    }
    $matrix = @($Report.paged_route_field_failure_matrix)
    if ($matrix.Count -ne 105 -or
        @($matrix | Where-Object {
            -not (Test-StandaloneNonNegativeInteger $_)
        }).Count -ne 0) {
        Fail-StandaloneNativeLive 'aggregate_matrix_rejected'
    }
    if ([int]$Report.message_sources -ne 8 -or
        [int]$Report.anchor_message_sources -lt 8 -or
        [int]$Report.anchor_message_sources -gt 2048 -or
        ([int]$Report.decoded_anchor_messages +
            [int]$Report.skipped_anchor_messages) -ne
            [int]$Report.anchor_message_sources -or
        [int]$Report.paged_pages_scanned -gt 20 -or
        [int]$Report.paged_changes_scanned -gt 1000) {
        Fail-StandaloneNativeLive 'aggregate_bounds_rejected'
    }
    return $Report
}

function Assert-StandaloneGraph {
    param($Graph, [Parameter(Mandatory)][int] $EncodedBytes)
    if ($EncodedBytes -le 0 -or $EncodedBytes -gt 512KB -or
        -not (Test-StandaloneExactProperties $Graph $script:StandaloneGraphFields) -or
        -not (Test-StandaloneInteger $Graph.schema) -or
        [int]$Graph.schema -ne 2 -or $Graph.content_exposed -ne $false -or
        $Graph.raw_identifiers_exposed -ne $false -or
        $Graph.terminal_reached -isnot [bool]) {
        Fail-StandaloneNativeLive 'graph_header_rejected'
    }
    foreach ($name in @('anchor_sources', 'decoded_anchor_sources',
        'skipped_anchor_sources', 'pages_scanned', 'changes_scanned',
        'chat_records', 'tombstones', 'other_records', 'symbol_count')) {
        if (-not (Test-StandaloneNonNegativeInteger $Graph.PSObject.Properties[$name].Value)) {
            Fail-StandaloneNativeLive 'graph_counter_rejected'
        }
    }
    if ([int]$Graph.anchor_sources -lt 8 -or
        [int]$Graph.anchor_sources -gt 2048 -or
        ([int]$Graph.decoded_anchor_sources +
            [int]$Graph.skipped_anchor_sources) -ne [int]$Graph.anchor_sources -or
        # `messages` is the fixed target cohort. The decoded/skipped counters
        # describe the separate, larger anchor evidence pool.
        @($Graph.messages).Count -ne 8 -or
        @($Graph.chats).Count -ne [int]$Graph.chat_records) {
        Fail-StandaloneNativeLive 'graph_bounds_rejected'
    }
    return $Graph
}

function Get-StandaloneSafeFailureCode {
    param([string[]] $Paths)
    $known = @(
        'chat1_standalone_read_authentication_refresh_writer_busy',
        'chat1_standalone_read_authentication_refresh_session_missing',
        'chat1_standalone_read_authentication_refresh_relay_unavailable',
        'chat1_standalone_read_authentication_refresh_credentials_rejected',
        'chat1_standalone_read_authentication_refresh_transport_failed',
        'chat1_standalone_read_authentication_refresh_state_failed',
        'chat1_standalone_read_authentication_refresh_timeout',
        'chat1_standalone_read_authentication_refresh_failed',
        'chat1_standalone_read_authentication_account_changed',
        'chat1_standalone_read_authentication_identity_mismatch',
        'chat1_standalone_read_authentication_refresh_unclassified',
        'chat1_standalone_aps_setup_failed',
        'chat1_standalone_account_restore_failed',
        'chat1_standalone_cloudkit_restore_failed',
        'chat1_standalone_keychain_restore_failed',
        'chat1_standalone_writer_pause_failed',
        'chat1_standalone_read_authentication_failed',
        'chat1_standalone_relationship_probe_failed',
        'chat1_standalone_correlation_failed'
    )
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $text = Get-Content -LiteralPath $path -Raw
        foreach ($marker in $known) {
            if ($text.Contains($marker, [StringComparison]::Ordinal)) {
                return $marker
            }
        }
    }
    return 'native_test_failed_unclassified'
}

function Assert-StandaloneExecutionProof {
    param(
        [Parameter(Mandatory)][int] $ExitCode,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Stdout,
        [Parameter(Mandatory)][string] $SafeFailureCode
    )
    # A failed Rust test cannot emit the success footer, so classify its bounded
    # safe marker before checking the positive execution proof. Otherwise every
    # real native failure is incorrectly flattened to exact_test_execution_unproven.
    if ($ExitCode -ne 0) { Fail-StandaloneNativeLive $SafeFailureCode }
    # With --nocapture, libtest may interleave the test's bounded diagnostic
    # output between the anchored status prefix and its trailing `ok`. Bind the
    # exact test by its anchored prefix and prove success independently with the
    # one-test footer instead of assuming both remain on one physical line.
    if ([regex]::Matches($Stdout,
        ('(?m)^test ' + [regex]::Escape($script:StandaloneTestName) +
            '(?:\s|$)')).Count -ne 1 -or
        -not [regex]::IsMatch($Stdout,
            '(?m)^test result: ok\. 1 passed; 0 failed; [0-9]+ ignored;')) {
        Fail-StandaloneNativeLive 'exact_test_execution_unproven'
    }
}

function Get-StandaloneMarkerPayload {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Output,
        [Parameter(Mandatory)][string] $Marker,
        [Parameter(Mandatory)][string] $FailureCode
    )
    $matches = [regex]::Matches($Output, [regex]::Escape($Marker))
    if ($matches.Count -ne 1) { Fail-StandaloneNativeLive $FailureCode }
    $start = $matches[0].Index + $matches[0].Length
    $lineEnd = $Output.IndexOf("`n", $start)
    if ($lineEnd -lt 0) { $lineEnd = $Output.Length }
    $payload = $Output.Substring($start, $lineEnd - $start).TrimEnd("`r")
    if ([string]::IsNullOrWhiteSpace($payload)) {
        Fail-StandaloneNativeLive $FailureCode
    }
    return $payload
}

function Stop-StandaloneOwnedProcess {
    param($Process, [Parameter(Mandatory)][string] $ExpectedExecutable)
    if ($null -eq $Process) { return $true }
    try {
        if ($Process.HasExited) { return $true }
        if (-not ([IO.Path]::GetFullPath($Process.Path)).Equals(
            [IO.Path]::GetFullPath($ExpectedExecutable),
            [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
        $Process.Kill($true)
        return $Process.WaitForExit(10000)
    }
    catch { return $false }
}

if ($FunctionsOnlyForTest) { return }

if ($PSVersionTable.PSVersion.Major -lt 7 -or -not $EnableLive -or
    $env:OPENBUBBLES_RUN_CHAT1_STANDALONE_NATIVE_LIVE -cne '1') {
    Fail-StandaloneNativeLive 'explicit_live_enable_required'
}
if ($EnablePseudonymousGraph -and
    $env:OPENBUBBLES_ACKNOWLEDGE_LOCAL_PERSONAL_DATA -cne '1') {
    Fail-StandaloneNativeLive 'personal_data_acknowledgement_required'
}
Assert-StandaloneNoWriterEnvironment
$profile = Resolve-StandaloneProfile
$mutex = $null
$process = $null
$hostInfo = $null
$directory = $null
$stdoutPath = $null
$stderrPath = $null
$stdoutStream = $null
$stderrStream = $null
$cleaned = $true
$safeFailure = $null
$executionEvidencePath = $null
$graph = $null
try {
    $mutex = Enter-StandaloneProfileLock -Profile $profile
    Assert-StandaloneNoProfileOwner
    $hostArguments = @{
        Profile = $profile
        ExpectedSource = $ExpectedSourceSha
        ExpectedPilot = $ExpectedPilotSha
        ExpectedArchive = $ExpectedArchiveSha256
        ExpectedProvenance = $ExpectedProvenanceSha256
        ExpectedSigner = $SigningThumbprint
    }
    $hostInfo = Assert-StandaloneTestHost @hostArguments
    $manifest = Assert-StandaloneManifest -Profile $profile
    $launch = New-StandaloneLaunchId
    if ($launch -cnotmatch '^[0-9a-f]{32}$') {
        Fail-StandaloneNativeLive 'launch_id_rejected'
    }
    $outputRoot = Join-Path $profile 'cloud-sync-v2\diagnostics\chat1-native-live'
    if (-not (Test-Path -LiteralPath $outputRoot)) {
        $null = New-Item -ItemType Directory -Path $outputRoot
    }
    Assert-StandalonePlainPath -Path $outputRoot -Label 'output_root'
    $directory = Join-Path $outputRoot $launch
    $null = New-Item -ItemType Directory -Path $directory
    Assert-StandalonePlainPath -Path $directory -Label 'output_directory'
    $executionEvidencePath = Join-Path $directory 'execution-proof.json'
    $durableBefore = Get-StandaloneDurableDigest -Profile $profile -ExcludedRoot $outputRoot
    $receiptBefore = (Get-FileHash -LiteralPath $hostInfo.Receipt -Algorithm SHA256).Hash.ToLowerInvariant()
    $stdoutPath = Join-Path $directory 'raw-stdout.log'
    $stderrPath = Join-Path $directory 'raw-stderr.log'
    [ordered]@{
        version = 1
        launch_id = $launch
        source_commit = $ExpectedSourceSha
        pilot_commit = $ExpectedPilotSha
        archive_sha256 = $ExpectedArchiveSha256
        provenance_sha256 = $ExpectedProvenanceSha256
        executable_sha256 = $hostInfo.Hashes['native-compose-tests.exe']
        rust_library_sha256 = $hostInfo.Hashes['rust_lib_bluebubbles.dll']
        objectbox_sha256 = $hostInfo.Hashes['objectbox.dll']
        manifest_sha256 = $manifest.Sha256
        manifest_counts = [ordered]@{
            messages = $manifest.MessageSources
            anchors = $manifest.AnchorSources
            chats = $manifest.Chat1Sources
        }
        pseudonymous_graph_requested = [bool]$EnablePseudonymousGraph
        launcher_sha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $directory 'qualification.json') -Encoding UTF8
    $startArguments = @{
        Executable = $hostInfo.Executable
        WorkingDirectory = $hostInfo.Directory
        AppData = $env:APPDATA
        GraphEnabled = [bool]$EnablePseudonymousGraph
    }
    $start = New-StandaloneStartInfo @startArguments
    $process = [Diagnostics.Process]::Start($start)
    $null = $process.Handle
    $cleaned = $false
    try {
        $stdoutStream = [IO.File]::Open($stdoutPath, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $stderrStream = [IO.File]::Open($stderrPath, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $stdoutCopy = $process.StandardOutput.BaseStream.CopyToAsync($stdoutStream)
        $stderrCopy = $process.StandardError.BaseStream.CopyToAsync($stderrStream)
        $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
        while (-not $process.HasExited -and [datetime]::UtcNow -lt $deadline) {
            if ((Get-Item -LiteralPath $stdoutPath -Force).Length -gt 32MB -or
                (Get-Item -LiteralPath $stderrPath -Force).Length -gt 32MB) {
                Fail-StandaloneNativeLive 'raw_output_overflow'
            }
            Start-Sleep -Milliseconds 100
            $process.Refresh()
        }
        if (-not $process.HasExited) {
            Fail-StandaloneNativeLive 'process_deadline'
        }
        if (-not $stdoutCopy.Wait(10000) -or -not $stderrCopy.Wait(10000)) {
            Fail-StandaloneNativeLive 'output_drain_timeout'
        }
    }
    finally {
        if ($null -ne $stdoutStream) { $stdoutStream.Dispose() }
        if ($null -ne $stderrStream) { $stderrStream.Dispose() }
    }
    $stdout = Get-Content -LiteralPath $stdoutPath -Raw
    $stderr = Get-Content -LiteralPath $stderrPath -Raw
    $safeFailure = Get-StandaloneSafeFailureCode @($stdoutPath, $stderrPath)
    $exactTestPattern = ('(?m)^test ' +
        [regex]::Escape($script:StandaloneTestName) + ' \.\.\. ok\r?$')
    $exactSummaryPattern =
        '(?m)^test result: ok\. 1 passed; 0 failed; [0-9]+ ignored;'
    [ordered]@{
        version = 1
        process_exit_code = [int]$process.ExitCode
        stdout_bytes = [long](Get-Item -LiteralPath $stdoutPath -Force).Length
        stderr_bytes = [long](Get-Item -LiteralPath $stderrPath -Force).Length
        stdout_sha256 = (Get-FileHash -LiteralPath $stdoutPath -Algorithm SHA256).Hash.ToLowerInvariant()
        stderr_sha256 = (Get-FileHash -LiteralPath $stderrPath -Algorithm SHA256).Hash.ToLowerInvariant()
        expected_test_name_mentions = [regex]::Matches(
            $stdout, [regex]::Escape($script:StandaloneTestName)).Count
        exact_test_start_lines = [regex]::Matches(
            $stdout, ('(?m)^test ' +
                [regex]::Escape($script:StandaloneTestName) +
                '(?:\s|$)')).Count
        exact_test_ok_lines = [regex]::Matches($stdout, $exactTestPattern).Count
        generic_test_ok_lines = [regex]::Matches(
            $stdout, '(?m)^test [A-Za-z0-9_:]+ \.\.\. ok\r?$').Count
        exact_success_summaries = [regex]::Matches(
            $stdout, $exactSummaryPattern).Count
        generic_success_summaries = [regex]::Matches(
            $stdout, '(?m)^test result: ok\. [1-9][0-9]* passed; 0 failed;').Count
        aggregate_markers = [regex]::Matches(
            $stdout, [regex]::Escape($script:StandaloneAggregateMarker)).Count
        graph_markers = [regex]::Matches(
            $stdout, [regex]::Escape($script:StandaloneGraphMarker)).Count
        safe_native_failure = $safeFailure
    } | ConvertTo-Json | Set-Content -LiteralPath $executionEvidencePath -Encoding UTF8
    Assert-StandaloneExecutionProof -ExitCode $process.ExitCode -Stdout $stdout `
        -SafeFailureCode $safeFailure
    # libtest's --nocapture status prefix can share a line with the first
    # diagnostic marker. Uniqueness plus strict JSON schema validation is the
    # boundary; physical line-start placement is not semantically meaningful.
    $aggregateJson = Get-StandaloneMarkerPayload -Output $stdout `
        -Marker $script:StandaloneAggregateMarker `
        -FailureCode 'aggregate_marker_rejected'
    $aggregate = Assert-StandaloneAggregate ($aggregateJson | ConvertFrom-Json)
    if ($EnablePseudonymousGraph) {
        $graphJson = Get-StandaloneMarkerPayload -Output $stdout `
            -Marker $script:StandaloneGraphMarker `
            -FailureCode 'graph_marker_rejected'
        $graphBytes = [Text.Encoding]::UTF8.GetByteCount($graphJson)
        $graphCandidate = $graphJson | ConvertFrom-Json
        $graphProperties = @{}
        foreach ($property in @($graphCandidate.PSObject.Properties)) {
            $graphProperties[$property.Name] = $property.Value
        }
        [ordered]@{
            version = 1
            encoded_bytes = $graphBytes
            exact_fields = Test-StandaloneExactProperties `
                $graphCandidate $script:StandaloneGraphFields
            schema = $graphProperties['schema']
            content_exposed = $graphProperties['content_exposed']
            raw_identifiers_exposed = $graphProperties['raw_identifiers_exposed']
            anchor_sources = $graphProperties['anchor_sources']
            decoded_anchor_sources = $graphProperties['decoded_anchor_sources']
            skipped_anchor_sources = $graphProperties['skipped_anchor_sources']
            chat_records = $graphProperties['chat_records']
            message_entries = @($graphProperties['messages']).Count
            chat_entries = @($graphProperties['chats']).Count
        } | ConvertTo-Json | Set-Content `
            -LiteralPath (Join-Path $directory 'graph-shape.json') -Encoding UTF8
        $graph = Assert-StandaloneGraph $graphCandidate $graphBytes
    }
    elseif ([regex]::Matches(
        $stdout, [regex]::Escape($script:StandaloneGraphMarker)).Count -ne 0) {
        Fail-StandaloneNativeLive 'unexpected_graph_output'
    }
    $durableAfter = Get-StandaloneDurableDigest -Profile $profile -ExcludedRoot $outputRoot
    $manifestAfter = (Get-FileHash -LiteralPath $manifest.Path -Algorithm SHA256).Hash.ToLowerInvariant()
    $receiptAfter = (Get-FileHash -LiteralPath $hostInfo.Receipt -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($durableAfter -cne $durableBefore -or
        $manifestAfter -cne $manifest.Sha256 -or
        $receiptAfter -cne $receiptBefore) {
        Fail-StandaloneNativeLive 'durable_state_changed'
    }
    foreach ($leaf in $script:StandaloneRuntimeFiles) {
        $after = (Get-FileHash -LiteralPath (Join-Path $hostInfo.Directory $leaf) -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($after -cne $hostInfo.Hashes[$leaf]) {
            Fail-StandaloneNativeLive 'test_host_changed_during_run'
        }
    }
    $cleaned = Stop-StandaloneOwnedProcess -Process $process -ExpectedExecutable $hostInfo.Executable
    if (-not $cleaned) { Fail-StandaloneNativeLive 'process_cleanup_unconfirmed' }
    $aggregate | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath (Join-Path $directory 'diagnosis-aggregate.json') -Encoding UTF8
    if ($null -ne $graph) {
        $graph | ConvertTo-Json -Depth 16 -Compress | Set-Content -LiteralPath (Join-Path $directory 'pseudonymous-graph.json') -Encoding UTF8
    }
    $aggregate | ConvertTo-Json -Depth 8
}
catch {
    $launcherFailure = $null
    if ($_.Exception.Message -match '^NATIVE-LIVE-FAIL: ([a-z0-9_]+)$') {
        $launcherFailure = $Matches[1]
    }
    if (-not [string]::IsNullOrWhiteSpace($launcherFailure)) {
        $safeFailure = $launcherFailure
    }
    elseif ([string]::IsNullOrWhiteSpace($safeFailure) -and
        $null -ne $stdoutPath -and $null -ne $stderrPath) {
        $safeFailure = Get-StandaloneSafeFailureCode @($stdoutPath, $stderrPath)
    }
    if ($null -ne $directory -and (Test-Path -LiteralPath $directory)) {
        [ordered]@{
            version = 1
            failure_code = if ([string]::IsNullOrWhiteSpace($safeFailure)) {
                'launcher_rejected'
            } else { $safeFailure }
            source_commit = $ExpectedSourceSha
            pilot_commit = $ExpectedPilotSha
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'failure.json') -Encoding UTF8
    }
    throw
}
finally {
    if (-not $cleaned -and $null -ne $process) {
        $cleanupExecutable = if ($null -ne $hostInfo) { $hostInfo.Executable } else { '' }
        $cleaned = Stop-StandaloneOwnedProcess -Process $process -ExpectedExecutable $cleanupExecutable
    }
    foreach ($raw in @($stdoutPath, $stderrPath)) {
        if ($null -ne $raw -and (Test-Path -LiteralPath $raw -PathType Leaf)) {
            Remove-Item -LiteralPath $raw -Force
        }
    }
    $remainingRaw = @(@($stdoutPath, $stderrPath) | Where-Object {
        $null -ne $_ -and (Test-Path -LiteralPath $_)
    })
    if ($null -ne $directory -and (Test-Path -LiteralPath $directory)) {
        [ordered]@{
            process_cleanup_confirmed = $cleaned
            raw_output_removed = $remainingRaw.Count -eq 0
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'cleanup.json') -Encoding UTF8
    }
    if ($null -ne $process) { $process.Dispose() }
    if ($null -ne $mutex) {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}
