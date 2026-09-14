# Parent-invoked only. Read-only Chat1 live diagnostic. It makes no CloudKit or
# profile-database writes. Per-launch aggregate JSON sidecars are retained.
# No build, profile bootstrap, receipt relabel, or policy change.
# PowerShell 7 is required for ArgumentList and asynchronous stream draining.
[CmdletBinding()]
param(
    [switch] $EnableLive,
    [switch] $FunctionsOnlyForTest,
    [ValidateSet('cache-only', 'discovery', 'correlation')]
    [string] $Mode = 'cache-only',
    [string] $TargetHashFile = '',
    [string] $Repository = '',
    [string] $FlutterRoot = 'C:\Codex\Toolchains\flutter-3.44.8-arm64',
    [string] $SigningThumbprint = '8240557965890665F3B49E5FEC83D511CA4F2C9D',
    [ValidateRange(30, 600)][int] $TimeoutSeconds = 300
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$functionsOnly = $FunctionsOnlyForTest
# Reuse the exact mutex, launch-id, build-identifier, receipt, ObjectBox,
# foreign-process, and exact-process stop checks. This mode returns before
# the parent launcher's profile, build, receipt, or operation code.
. "$PSScriptRoot/run_cloud_sync_v2_dev.ps1" -FunctionsOnlyForTest -FlutterRoot $FlutterRoot

# Exact source pinned for this read-only diagnostic. Any other checkout is
# rejected before any child process starts.
$chat1LiveSourceHead = '908ccc0040ed4bb60d2611db945e0b304eff639c'
# Writer configuration is never inherited and never set on the child. Any
# of these in the parent environment aborts the diagnostic.
$chat1LiveWriterBlockedEnv = @(
    'OPENBUBBLES_CLOUD_SYNC_V2_OUTBOUND_CANARY',
    'OPENBUBBLES_CLOUDKIT_WRITER_OWNER',
    'OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_REPLAY_EXCLUDED_CHATS',
    'OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_FINDMY_PROBE',
    'OPENBUBBLES_RUN_FINDMY_WINDOWS_LIVE',
    'OPENBUBBLES_VERIFY_EDIT_CLAIM',
    'OPENBUBBLES_VERIFY_CHAIN_UNSEND'
)
# Only bounded scalar diagnostics are retained. Everything else the child
# prints is deleted with the raw log.
$chat1LiveAggregateAllowlist = @(
    'account_bound', 'scope', 'page_limit', 'change_limit',
    'checkpoint_was_fresh', 'status', 'fetched', 'journaled',
    'journal_rejected', 'journal_estimated_bytes', 'failure_safe_code',
    'skip_reason', 'journal_block_reason', 'empty_terminal_read',
    'zero_mutation_counters', 'canonical_counts_unchanged',
    'outbox_count_unchanged', 'network_read_performed', 'content_exposed',
    'durable_state_unchanged', 'completed', 'message_sources',
    'decoded_message_routes', 'chat1_sources', 'verified_chat1_records',
    'route_field_failure_matrix_schema', 'route_field_failure_matrix',
    'paged_route_field_failure_matrix', 'route_field_decode_failures',
    'paged_route_field_decode_failures', 'paged_pages_scanned',
    'paged_changes_scanned', 'paged_chat_records', 'paged_tombstones',
    'paged_record_decode_failures', 'paged_terminal_reached',
    'paged_budget_exhausted',
    'failure_code'
)
$chat1LiveCorrelationBooleanKeys = @(
    'semantic_correlation_requested', 'pcs_lookup_attempted',
    'paged_correlation_requested', 'anchor_source_budget_exhausted'
)
$chat1LiveCorrelationCountKeys = @(
    'distinct_message_routes', 'message_group_id_sources',
    'message_sender_sources', 'anchor_message_sources',
    'decoded_anchor_messages', 'skipped_anchor_messages',
    'distinct_anchor_message_guids', 'conflicting_anchor_message_guids',
    'exact_match_pairs',
    'matched_message_routes', 'matched_chat1_records',
    'chat_record_type_records', 'other_record_type_records',
    'decoded_route_records', 'record_decode_failures',
    'chat_identifier_match_pairs', 'group_id_match_pairs',
    'original_group_id_match_pairs', 'guid_match_pairs',
    'semantic_match_pairs', 'matched_semantic_message_routes',
    'matched_semantic_chat1_records', 'route_participant_match_pairs',
    'route_legacy_match_pairs', 'route_lah_match_pairs',
    'msgproto_chat_identifier_match_pairs', 'msgproto_group_id_match_pairs',
    'msgproto_original_group_id_match_pairs', 'msgproto_guid_match_pairs',
    'msgproto_legacy_match_pairs', 'sender_participant_match_pairs',
    'sender_lah_match_pairs', 'matched_route_extra_message_routes',
    'matched_route_extra_chat1_records', 'matched_msgproto_targets',
    'matched_msgproto_chat1_records', 'matched_sender_targets',
    'matched_sender_chat1_records', 'participant_present_records',
    'legacy_present_records', 'lah_present_records',
    'service_present_records', 'imessage_service_records',
    'other_service_records', 'style_group_records',
    'style_direct_records', 'style_other_records', 'paged_other_records',
    'paged_semantic_match_pairs', 'paged_matched_message_routes',
    'paged_matched_chat1_records',
    'paged_normalized_chat_identifier_match_pairs',
    'paged_normalized_group_id_match_pairs',
    'paged_normalized_original_group_id_match_pairs',
    'paged_normalized_guid_match_pairs',
    'paged_normalized_semantic_match_pairs',
    'paged_normalized_matched_message_routes',
    'paged_normalized_matched_chat1_records',
    'paged_route_participant_match_pairs',
    'paged_route_legacy_match_pairs', 'paged_route_lah_match_pairs',
    'paged_msgproto_chat_identifier_match_pairs',
    'paged_msgproto_group_id_match_pairs',
    'paged_msgproto_original_group_id_match_pairs',
    'paged_msgproto_guid_match_pairs', 'paged_msgproto_legacy_match_pairs',
    'paged_sender_participant_match_pairs', 'paged_sender_lah_match_pairs',
    'paged_matched_route_extra_message_routes',
    'paged_matched_route_extra_chat1_records',
    'paged_matched_msgproto_targets', 'paged_matched_msgproto_chat1_records',
    'paged_matched_sender_targets', 'paged_matched_sender_chat1_records',
    'paged_participant_present_records', 'paged_legacy_present_records',
    'paged_lah_present_records', 'paged_service_present_records',
    'paged_imessage_service_records', 'paged_other_service_records',
    'paged_style_direct_records', 'paged_style_group_records',
    'paged_style_other_records',
    'paged_normalized_route_participant_match_pairs',
    'paged_normalized_route_legacy_match_pairs',
    'paged_normalized_route_lah_match_pairs',
    'paged_normalized_msgproto_chat_identifier_match_pairs',
    'paged_normalized_msgproto_group_id_match_pairs',
    'paged_normalized_msgproto_original_group_id_match_pairs',
    'paged_normalized_msgproto_guid_match_pairs',
    'paged_normalized_msgproto_legacy_match_pairs',
    'paged_normalized_sender_participant_match_pairs',
    'paged_normalized_sender_lah_match_pairs',
    'paged_normalized_matched_route_extra_message_routes',
    'paged_normalized_matched_route_extra_chat1_records',
    'paged_normalized_matched_msgproto_targets',
    'paged_normalized_matched_msgproto_chat1_records',
    'paged_normalized_matched_sender_targets',
    'paged_normalized_matched_sender_chat1_records',
    'paged_last_seen_message_guid_present_records',
    'paged_last_seen_target_message_match_pairs',
    'paged_matched_last_seen_target_messages',
    'paged_matched_last_seen_target_chat1_records',
    'paged_last_seen_anchor_exact_match_pairs',
    'paged_matched_anchor_exact_targets',
    'paged_matched_anchor_exact_chat1_records',
    'paged_last_seen_anchor_normalized_match_pairs',
    'paged_matched_anchor_normalized_targets',
    'paged_matched_anchor_normalized_chat1_records',
    'paged_sender_service_style_match_pairs',
    'paged_matched_sender_service_style_targets',
    'paged_matched_sender_service_style_chat1_records',
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
    'paged_anchor_normalized_multiple_candidate_targets'
)
$chat1LiveAggregateAllowlist += $chat1LiveCorrelationBooleanKeys
$chat1LiveAggregateAllowlist += $chat1LiveCorrelationCountKeys
$chat1LiveFailureMatrixSchema = 2
$chat1LiveFailureMatrixBaseLen = 88
$chat1LiveFailureMatrixDetailLen = 17
$chat1LiveFailureMatrixTotalLen = $chat1LiveFailureMatrixBaseLen +
    $chat1LiveFailureMatrixDetailLen
$chat1LiveLahValidationBaseIndex = 46
$chat1LivePtcptsWireShapeBaseIndex = 65

function Assert-Chat1PlainPath([string] $Path) {
    $item = Get-Item -LiteralPath $Path -Force
    while ($null -ne $item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'chat1_live_reparse_path_rejected'
        }
        $parent = [IO.Path]::GetDirectoryName($item.FullName.TrimEnd('\'))
        if (-not $parent -or $parent -eq $item.FullName) { break }
        $item = Get-Item -LiteralPath $parent -Force
    }
}

function Assert-Chat1NoWriterEnv {
    foreach ($name in $chat1LiveWriterBlockedEnv) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if (-not [string]::IsNullOrEmpty($value)) {
            throw 'chat1_live_writer_env_blocked'
        }
    }
}

function Add-Chat1TestHostIdentity {
    param(
        [Parameter(Mandatory)][Diagnostics.ProcessStartInfo] $Start,
        [Parameter(Mandatory)][string] $BuildIdentifier
    )
    if ($BuildIdentifier -cnotmatch '^[0-9a-f]{12}$') {
        throw 'chat1_live_build_identifier_rejected'
    }
    $Start.Environment['OPENBUBBLES_CLOUD_SYNC_V2_TEST_HOST'] = '1'
    foreach ($define in @(
        'OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_DEV_PROFILE=true',
        'OPENBUBBLES_CLOUD_SYNC_V2_SEMANTIC_PULL=true',
        'OPENBUBBLES_CLOUD_SYNC_V2_SAMPLER=true',
        "OPENBUBBLES_BUILD_COMMIT=$BuildIdentifier"
    )) {
        $Start.ArgumentList.Add("--dart-define=$define")
    }
}

function Assert-Chat1TargetHashes([string] $File) {
    Assert-Chat1PlainPath $File
    $leaf = Get-Item -LiteralPath $File -Force
    if ($leaf.PSIsContainer) { throw 'chat1_live_target_hash_file_rejected' }
    $raw = Get-Content -LiteralPath $File -Raw
    if ($null -eq $raw) { throw 'chat1_live_target_hash_file_rejected' }
    $encoded = $raw.Trim()
    $values = @($encoded.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($values.Count -ne 8 -or
        @($values | Sort-Object -Unique -CaseSensitive).Count -ne 8) {
        throw 'chat1_live_target_hash_file_rejected'
    }
    foreach ($value in $values) {
        if ($value.Length -ne 43 -or $value -cnotmatch '^[A-Za-z0-9_-]{43}$') {
            throw 'chat1_live_target_hash_file_rejected'
        }
    }
    return ($values -join ',')
}

function Assert-Chat1NoForeignProfileProcess([string] $StoreExecutable) {
    # Read-only means read-only: refuse when any profile process exists
    # instead of stopping the user's app.
    $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop |
        Where-Object { $_.Name -eq 'bluebubbles_app.exe' })
    $foreign = @($processes | Where-Object {
        [string]::IsNullOrWhiteSpace($_.ExecutablePath) -or
        -not [System.String]::Equals(
            $_.ExecutablePath,
            $StoreExecutable,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    })
    if ($foreign.Count -ne 0) {
        throw 'chat1_live_foreign_profile_process_rejected'
    }
    if ($processes.Count -ne 0) {
        throw 'chat1_live_close_store_app_first'
    }
}

function Add-Chat1OwnedChildren($Owned, [string[]] $AllowedExecutables) {
    # Only direct descendants of recorded process instances are admitted.
    do {
        $added = $false
        foreach ($parent in @($Owned.Values)) {
            $parent.Process.Refresh()
            if ($parent.Process.HasExited) { continue }
            foreach ($child in @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $($parent.Process.Id)")) {
                if ($Owned.ContainsKey([int]$child.ProcessId)) { continue }
                if ([string]::IsNullOrWhiteSpace($child.ExecutablePath)) { continue }
                $childPath = [IO.Path]::GetFullPath($child.ExecutablePath)
                if ($childPath -notin $AllowedExecutables) { continue }
                $process = Get-Process -Id $child.ProcessId -ErrorAction SilentlyContinue
                if ($null -eq $process) { continue }
                $null = $process.Handle
                if ($process.StartTime.ToUniversalTime() -lt $parent.Started) {
                    $process.Dispose()
                    continue
                }
                if ([math]::Abs(
                    ($process.StartTime.ToUniversalTime() -
                        $child.CreationDate.ToUniversalTime()).TotalMilliseconds
                ) -gt 2000) {
                    $process.Dispose()
                    continue
                }
                $Owned[[int]$process.Id] = @{
                    Process = $process
                    Path = $childPath
                    Started = $process.StartTime.ToUniversalTime()
                }
                $added = $true
            }
        }
    } while ($added)
}

function Stop-Chat1OwnedProcesses($Owned) {
    foreach ($entry in @($Owned.Values | Sort-Object Started -Descending)) {
        Stop-ExactLaunchedHarness -Process $entry.Process -ExpectedExecutable $entry.Path
        if (-not $entry.Process.WaitForExit(5000)) { throw 'chat1_live_cleanup_unconfirmed' }
    }
}

function Get-Chat1ReportProperty($Report, [string] $Key) {
    if ($null -eq $Report -or $Report -isnot [pscustomobject]) {
        throw 'chat1_live_aggregate_unreadable'
    }
    return $Report.PSObject.Properties[$Key]
}

function Assert-Chat1Aggregate($Report, [string] $DiagnosticMode) {
    if ($Report.account_bound -ne $true -or $Report.scope -cne 'chat1ManateeZone') {
        throw 'chat1_live_aggregate_binding_rejected'
    }
    if ($DiagnosticMode -eq 'cache-only') {
        if ($Report.network_read_performed -ne $false) {
            throw 'chat1_live_aggregate_binding_rejected'
        }
        if ($Report.content_exposed -ne $false -or
            $Report.durable_state_unchanged -ne $true -or
            $null -ne $Report.failure_code) {
            throw 'chat1_live_write_tripwire_rejected'
        }
        return
    }
    if ($DiagnosticMode -eq 'discovery') {
        if ($Report.zero_mutation_counters -ne $true -or
            $Report.canonical_counts_unchanged -ne $true -or
            $Report.outbox_count_unchanged -ne $true -or
            $Report.durable_state_unchanged -ne $true -or
            $Report.content_exposed -ne $false) {
            throw 'chat1_live_write_tripwire_rejected'
        }
        return
    }
    # Correlation deliberately performs bounded, lookup-only PCS reads. The
    # durable-state and content tripwires below are what make this lane safe;
    # claiming no network read here would reject every real correlation run.
    if ($Report.network_read_performed -ne $true -or
        ($Report.content_exposed -ne $true -and
            $Report.content_exposed -ne $false)) {
        throw 'chat1_live_aggregate_binding_rejected'
    }
    if ($Report.content_exposed -ne $false -or
        $Report.durable_state_unchanged -ne $true -or
        $Report.completed -ne $true -or
        $Report.message_sources -ne 8 -or
        $Report.anchor_message_sources -lt 8 -or
        $Report.anchor_message_sources -gt 2048 -or
        $Report.chat1_sources -ne 50 -or
        $Report.verified_chat1_records -ne 50 -or
        $null -ne $Report.failure_code) { throw 'chat1_live_write_tripwire_rejected' }
    foreach ($key in @('status', 'failure_safe_code', 'skip_reason', 'journal_block_reason')) {
        $property = Get-Chat1ReportProperty $Report $key
        if ($null -ne $property -and $null -ne $property.Value) {
            throw 'chat1_live_aggregate_string_rejected'
        }
    }
    foreach ($key in $chat1LiveCorrelationBooleanKeys) {
        $property = Get-Chat1ReportProperty $Report $key
        if ($null -eq $property -or $property.Value -isnot [bool]) {
            throw 'chat1_live_correlation_boolean_rejected'
        }
    }
    foreach ($key in $chat1LiveCorrelationCountKeys) {
        $property = Get-Chat1ReportProperty $Report $key
        if ($null -eq $property -or
            ($property.Value -isnot [int] -and $property.Value -isnot [long]) -or
            $property.Value -lt 0 -or $property.Value -gt 8000) {
            throw 'chat1_live_correlation_counter_rejected'
        }
    }
    if ($Report.decoded_anchor_messages + $Report.skipped_anchor_messages -ne
            $Report.anchor_message_sources -or
        $Report.distinct_anchor_message_guids + $Report.conflicting_anchor_message_guids -gt
            $Report.decoded_anchor_messages) {
        throw 'chat1_live_anchor_accounting_rejected'
    }
    foreach ($prefix in @(
        'paged_sender_service_style',
        'paged_last_seen_target',
        'paged_anchor_exact',
        'paged_anchor_normalized'
    )) {
        $zero = Get-Chat1ReportProperty $Report ($prefix + '_zero_candidate_targets')
        $unique = Get-Chat1ReportProperty $Report ($prefix + '_unique_candidate_targets')
        $multiple = Get-Chat1ReportProperty $Report ($prefix + '_multiple_candidate_targets')
        if ($null -eq $zero -or $null -eq $unique -or $null -eq $multiple -or
            $zero.Value + $unique.Value + $multiple.Value -ne 8) {
            throw 'chat1_live_candidate_cardinality_rejected'
        }
    }
    if ($Report.route_field_failure_matrix_schema -ne $chat1LiveFailureMatrixSchema) {
        throw 'chat1_live_failure_matrix_schema_rejected'
    }
    foreach ($pair in @(
        @($Report.route_field_failure_matrix, $Report.route_field_decode_failures),
        @($Report.paged_route_field_failure_matrix, $Report.paged_route_field_decode_failures)
    )) {
        $matrix = @($pair[0])
        $base = @($matrix | Select-Object -First $chat1LiveFailureMatrixBaseLen)
        $detail = @($matrix | Select-Object -Skip $chat1LiveFailureMatrixBaseLen)
        $baseSum = ($base | Measure-Object -Sum).Sum
        $detailSum = ($detail | Measure-Object -Sum).Sum
        $expectedDetailSum = if ($matrix.Count -eq $chat1LiveFailureMatrixTotalLen) {
            [long]$matrix[$chat1LiveLahValidationBaseIndex] +
                [long]$matrix[$chat1LivePtcptsWireShapeBaseIndex]
        } else { -1 }
        if ($matrix.Count -ne $chat1LiveFailureMatrixTotalLen -or
            $base.Count -ne $chat1LiveFailureMatrixBaseLen -or
            $detail.Count -ne $chat1LiveFailureMatrixDetailLen -or
            @($matrix | Where-Object {
                    ($_ -isnot [int] -and $_ -isnot [long]) -or $_ -lt 0
                }).Count -ne 0 -or
            $baseSum -ne $pair[1] -or $detailSum -ne $expectedDetailSum) {
            throw 'chat1_live_failure_matrix_rejected'
        }
    }
    if ($Report.paged_pages_scanned -lt 1 -or $Report.paged_pages_scanned -gt 20 -or
        $Report.paged_changes_scanned -lt 1 -or $Report.paged_changes_scanned -gt 1000 -or
        (-not $Report.paged_terminal_reached -and -not $Report.paged_budget_exhausted)) {
        throw 'chat1_live_paged_bounds_rejected'
    }
}

function Copy-Chat1Aggregate($Report) {
    $aggregate = [ordered]@{}
    foreach ($key in $chat1LiveAggregateAllowlist) {
        $property = Get-Chat1ReportProperty $Report $key
        if ($null -eq $property) { continue }
        $value = $property.Value
        $isMatrix = $key -in @('route_field_failure_matrix', 'paged_route_field_failure_matrix')
        if ($isMatrix -and ($value -isnot [array] -or
                $value.Count -ne $chat1LiveFailureMatrixTotalLen -or
                @($value | Where-Object { $_ -isnot [int] -and $_ -isnot [long] }).Count -ne 0)) {
            throw 'chat1_live_failure_matrix_rejected'
        }
        if ($null -eq $value -or
            ($value -is [string] -and $value.Length -le 64 -and $value -cmatch '^[A-Za-z0-9_\-]*$') -or
            $value -is [bool] -or $value -is [int] -or $value -is [long] -or $value -is [double] -or
            ($value -is [array] -and $value.Count -eq $chat1LiveFailureMatrixTotalLen -and
                @($value | Where-Object { $_ -isnot [int] -and $_ -isnot [long] }).Count -eq 0)) {
            $aggregate[$key] = $value
        }
    }
    return $aggregate
}

function Assert-Chat1AggregateLaunch($Report, [string] $ExpectedLaunch) {
    $property = Get-Chat1ReportProperty $Report 'launch_id'
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace(
        [string]$property.Value
    )) {
        return
    }
    if ([string]$property.Value -cne $ExpectedLaunch) {
        throw 'chat1_live_aggregate_binding_rejected'
    }
}

if ($functionsOnly) { return }
if ($PSVersionTable.PSVersion.Major -lt 7 -or -not $EnableLive -or
    $env:OPENBUBBLES_RUN_CHAT1_LIVE_DIAGNOSTIC -cne '1') {
    throw 'chat1_live_explicit_live_enable_required'
}
Assert-Chat1NoWriterEnv
if ([string]::IsNullOrWhiteSpace($Repository)) {
    $Repository = Join-Path $PSScriptRoot '../..'
}
$repository = [IO.Path]::GetFullPath($Repository)
$profile = Join-Path $env:APPDATA 'OpenBubbles/cloudkit-v2-dev'
$marker = Join-Path $profile '.openbubbles-cloud-sync-v2-windows-dev'
if (-not (Test-Path -LiteralPath $marker -PathType Leaf) -or
    (Get-Content -LiteralPath $marker -Raw) -ne
        'openbubbles-cloud-sync-v2-windows-dev-profile:v1') {
    throw 'chat1_live_profile_marker_rejected'
}
Assert-Chat1PlainPath $profile
$dart = Join-Path $FlutterRoot 'bin/cache/dart-sdk/bin/dart.exe'
$tester = Join-Path $FlutterRoot 'bin/cache/artifacts/engine/windows-arm64/flutter_tester.exe'
$snapshot = Join-Path $FlutterRoot 'bin/cache/flutter_tools.snapshot'
$harnessTest = Join-Path $repository 'test/live/cloud_sync_v2_windows_live_harness_test.dart'
foreach ($item in @($dart, $tester, $snapshot, $harnessTest)) { Assert-Chat1PlainPath $item }
$head = (& git -C $repository rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $head -cne $chat1LiveSourceHead) { throw 'chat1_live_source_head_rejected' }
$buildIdentifier = Resolve-HarnessBuildIdentifier -Repository $repository
if ($buildIdentifier -cne $chat1LiveSourceHead.Substring(0, 12)) { throw 'chat1_live_build_identifier_rejected' }
$runnerDirectory = [IO.Path]::GetFullPath((Join-Path $repository 'build/windows/arm64/runner/Debug')).TrimEnd('\')
$rustLibrary = [IO.Path]::GetFullPath((Join-Path $runnerDirectory 'rust_lib_bluebubbles.dll'))
$runner = [IO.Path]::GetFullPath((Join-Path $runnerDirectory 'bluebubbles_app.exe'))
$trustedPrefix = "$runnerDirectory\"
foreach ($artifact in @($rustLibrary, $runner)) {
    if (-not $artifact.StartsWith($trustedPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $artifact -PathType Leaf)) {
        throw 'chat1_live_harness_artifact_rejected'
    }
    Assert-Chat1PlainPath $artifact
}
Assert-HarnessObjectBoxRuntime -RunnerDirectory $runnerDirectory
$signature = Get-AuthenticodeSignature -LiteralPath $rustLibrary
if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
    $signature.SignerCertificate.Thumbprint -cne $SigningThumbprint) {
    throw 'chat1_live_native_signature_rejected'
}
$buildReceiptPath = Join-Path (Join-Path $profile 'cloud-sync-v2') 'windows-harness-build-receipt.json'
if (-not (Test-HarnessBuildReceipt `
    -ReceiptPath $buildReceiptPath `
    -BuildIdentifier $buildIdentifier `
    -Runner $runner `
    -RustLibrary $rustLibrary)) {
    throw 'chat1_live_build_receipt_rejected'
}
$storeExecutable = Resolve-StoreOpenBubblesExecutable
Assert-Chat1NoForeignProfileProcess -StoreExecutable $storeExecutable
$targetHashes = $null
if ($Mode -eq 'correlation') {
    if ([string]::IsNullOrWhiteSpace($TargetHashFile)) { throw 'chat1_live_target_hash_file_required' }
    $targetHashes = Assert-Chat1TargetHashes $TargetHashFile
} elseif (-not [string]::IsNullOrWhiteSpace($TargetHashFile)) {
    throw 'chat1_live_target_hash_file_unexpected'
}
$sdkExecutables = @($dart, (Join-Path $FlutterRoot 'bin/cache/dart-sdk/bin/dartvm.exe'), (Join-Path $FlutterRoot 'bin/cache/dart-sdk/bin/dartaotruntime.exe'), $tester)
foreach ($executable in $sdkExecutables) { Assert-Chat1PlainPath $executable }
$launch = New-CryptographicLaunchId
if ($launch -cnotmatch '^[a-f0-9]{32}$') {
    throw 'chat1_live_launch_id_rejected'
}
$owned = @{}
$mutex = Enter-ProfileScopedLauncherLock -ProfilePath $profile
$cleaned = $false
$directory = $null
$rawPath = $null
try {
    $directory = $profile
    foreach ($part in @('cloud-sync-v2', 'chat1-live', $launch)) {
        $directory = Join-Path $directory $part
        if (-not (Test-Path -LiteralPath $directory)) { $null = New-Item -ItemType Directory -Path $directory }
        Assert-Chat1PlainPath $directory
    }
    $rawPath = Join-Path $directory 'raw-stdout.log'
    $libraryHash = (Get-FileHash -LiteralPath $rustLibrary -Algorithm SHA256).Hash.ToLowerInvariant()
    @{
        version = 1; launch_id = $launch; mode = $Mode
        source_head = $head; build_identifier = $buildIdentifier
        native_library = $rustLibrary; native_sha256 = $libraryHash
        signature_thumbprint = $SigningThumbprint
        harness_test_sha256 = (Get-FileHash -LiteralPath $harnessTest -Algorithm SHA256).Hash.ToLowerInvariant()
        launcher_sha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
        flutter_root = [IO.Path]::GetFullPath($FlutterRoot)
        dart_sha256 = (Get-FileHash -LiteralPath $dart -Algorithm SHA256).Hash.ToLowerInvariant()
        tester_sha256 = (Get-FileHash -LiteralPath $tester -Algorithm SHA256).Hash.ToLowerInvariant()
        flutter_tools_sha256 = (Get-FileHash -LiteralPath $snapshot -Algorithm SHA256).Hash.ToLowerInvariant()
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$directory/qualification.json" -Encoding utf8
    $statusPath = Join-Path $profile 'cloud-sync-v2/windows-harness-status.json'
    $statusBaselineWriteUtc = [datetime]::MinValue
    if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
        $statusBaselineWriteUtc = (Get-Item -LiteralPath $statusPath -Force).LastWriteTimeUtc
    }
    $start = [Diagnostics.ProcessStartInfo]::new($dart)
    $start.WorkingDirectory = $repository
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($key in @($start.Environment.Keys)) {
        if ($key -like 'OPENBUBBLES_*' -or $key -eq 'RUST_LOG') { $null = $start.Environment.Remove($key) }
    }
    $start.Environment['OPENBUBBLES_RUN_LIVE_WINDOWS_HARNESS'] = '1'
    $start.Environment['OPENBUBBLES_LIVE_HARNESS_OPERATION'] = 'inspect-chat1-discovery'
    $start.Environment['OPENBUBBLES_LIVE_HARNESS_LAUNCH_ID'] = $launch
    $start.Environment['OPENBUBBLES_TEST_NATIVE_LIBRARY'] = $rustLibrary
    $start.Environment['OPENBUBBLES_INSPECT_CHAT1_DISCOVERY'] = '1'
    if ($Mode -eq 'cache-only') { $start.Environment['OPENBUBBLES_INSPECT_CHAT1_CACHE_ONLY'] = '1' }
    if ($Mode -eq 'correlation') {
        $start.Environment['OPENBUBBLES_INSPECT_CHAT1_CORRELATION'] = '1'
        $start.Environment['OPENBUBBLES_INSPECT_CHAT1_SEMANTIC_CORRELATION'] = '1'
        $start.Environment['OPENBUBBLES_INSPECT_CHAT1_PAGED_CORRELATION'] = '1'
        $start.Environment['OPENBUBBLES_CHAT1_TARGET_MESSAGE_HASHES'] = $targetHashes
    }
    $start.Environment['PATH'] = "$runnerDirectory;$($start.Environment['PATH'])"
    foreach ($arg in @($snapshot, 'test')) { $start.ArgumentList.Add($arg) }
    Add-Chat1TestHostIdentity -Start $start -BuildIdentifier $buildIdentifier
    foreach ($arg in @('--no-pub', '--concurrency=1', '--reporter=expanded',
        'test/live/cloud_sync_v2_windows_live_harness_test.dart')) { $start.ArgumentList.Add($arg) }
    $process = [Diagnostics.Process]::Start($start)
    $null = $process.Handle
    $owned[[int]$process.Id] = @{ Process = $process; Path = $dart; Started = $process.StartTime.ToUniversalTime() }
    # Raw child output lands in the per-launch file only. The retained log
    # keeps aggregates; the raw file is deleted below even on failure.
    $rawStream = [IO.File]::Open($rawPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        $stdoutCopy = $process.StandardOutput.BaseStream.CopyToAsync($rawStream)
        $stderrDrain = $process.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
        $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
        while (-not $process.HasExited -and [datetime]::UtcNow -lt $deadline) {
            Add-Chat1OwnedChildren $owned $sdkExecutables
            if ((Get-Item -LiteralPath $rawPath -Force).Length -gt 32MB) {
                throw 'chat1_live_raw_overflow'
            }
            Start-Sleep -Milliseconds 100
            $process.Refresh()
        }
        if (-not $process.HasExited) { throw 'chat1_live_process_deadline' }
        if (-not $stdoutCopy.Wait(10000) -or -not $stderrDrain.Wait(10000)) {
            throw 'chat1_live_log_drain_timeout'
        }
    } finally {
        $rawStream.Dispose()
    }
    $admitted = @($owned.Values | Where-Object { $_.Path -ieq $tester }).Count -gt 0
    @{ launch_id = $launch; root_process_id = $process.Id
        root_exit_code = $process.ExitCode; admitted = $admitted
        owned_process_count = $owned.Count
        expected_tester_seen = $admitted
    } | ConvertTo-Json | Set-Content -LiteralPath "$directory/admission-status.json" -Encoding utf8
    if (-not $admitted) { throw 'chat1_live_process_not_admitted' }
    # Launch-id correlation through the harness status file.
    $statusBound = $false
    $statusDeadline = [datetime]::UtcNow.AddSeconds(10)
    do {
        try {
            $statusFile = Get-Item -LiteralPath $statusPath -Force
            if ($statusFile.LastWriteTimeUtc -gt $statusBaselineWriteUtc) {
                $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
                $statusBound = $status.launch_id -ceq $launch
            }
        } catch { $statusBound = $false }
        if (-not $statusBound) { Start-Sleep -Milliseconds 100 }
    } while (-not $statusBound -and [datetime]::UtcNow -lt $statusDeadline)
    if (-not $statusBound) { throw 'chat1_live_status_binding_rejected' }
    $marker = 'windows_chat1_discovery='
    $lines = @(Get-Content -LiteralPath $rawPath | Where-Object { $_.StartsWith($marker) })
    if ($lines.Count -ne 1) { throw 'chat1_live_aggregate_unreadable' }
    $report = $lines[0].Substring($marker.Length) | ConvertFrom-Json
    Assert-Chat1AggregateLaunch $report $launch
    if ($process.ExitCode -ne 0) {
        $failureAggregate = Copy-Chat1Aggregate $report
        $failureAggregate['launch_id'] = $launch
        $failureAggregate['mode'] = $Mode
        $failureAggregate['build_identifier'] = $buildIdentifier
        $failureAggregate | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath "$directory/failure-aggregate.json" -Encoding utf8
        throw 'chat1_live_read_failed'
    }
    Assert-Chat1Aggregate $report $Mode
    $aggregate = Copy-Chat1Aggregate $report
    $aggregate['launch_id'] = $launch
    $aggregate['mode'] = $Mode
    $aggregate['build_identifier'] = $buildIdentifier
    $aggregate | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$directory/diagnosis-aggregate.json" -Encoding utf8
    # Aggregate-only retention: the raw child log is deleted on success.
    Remove-Item -LiteralPath $rawPath -Force
    $rawPath = $null
    Stop-Chat1OwnedProcesses $owned
    $cleaned = $true
    $aggregate | ConvertTo-Json -Depth 5
} finally {
    if (-not $cleaned) {
        try {
            Stop-Chat1OwnedProcesses $owned
            $cleaned = $true
        } catch {
            $cleaned = $false
        }
    }
    if ($cleaned) {
        foreach ($entry in $owned.Values) {
            try {
                if (-not $entry.Process.HasExited) { $cleaned = $false }
            } catch {
                $cleaned = $false
            }
        }
    }
    if ($null -ne $rawPath -and (Test-Path -LiteralPath $rawPath -PathType Leaf)) {
        Remove-Item -LiteralPath $rawPath -Force
    }
    try {
        if ($null -ne $directory) {
            @{ confirmed = $cleaned
                processes = @($owned.Values | ForEach-Object {
                    @{ process_id = $_.Process.Id; started_utc = $_.Started.ToString('o'); executable = $_.Path }
                })
            } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$directory/cleanup.json" -Encoding utf8
        }
    } finally {
        foreach ($entry in $owned.Values) { $entry.Process.Dispose() }
        if ($null -ne $mutex) {
            $mutex.ReleaseMutex()
            $mutex.Dispose()
        }
    }
}
