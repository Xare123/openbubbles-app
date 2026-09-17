$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$launcher = Join-Path $PSScriptRoot '../run_imported_cloud_sync_v2_dart_live.ps1'
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

function New-TestZone([string] $Name) {
    return [pscustomobject][ordered]@{
        zone = $Name
        status = 'completed'
        fetched = [long]0
        applied = [long]0
        deferred = [long]0
        quarantined = [long]0
        preflightQuarantined = [long]0
        preflightReasons = [pscustomobject][ordered]@{
            unsupportedRecordType = [long]0
            malformedMetadata = [long]0
            oversizedRecord = [long]0
            invalidChangeShape = [long]0
            unknown = [long]0
        }
        quarantinePhases = [pscustomobject][ordered]@{
            startup = [long]0
            postFetch = [long]0
        }
        tombstoneQuarantined = [long]0
        tombstoneReadOnlyAcknowledged = [long]0
        retainedUnprojected = [long]8
        semanticUnsupportedServiceQuarantined = [long]0
        semanticStageQuarantined = [long]0
        retried = [long]0
        elapsedMilliseconds = [long]10
        observedEmptyTerminalRead = $true
        projectionExamined = [long]0
        projectionRetained = [long]0
        projectionBatches = [long]0
        semanticDiagnostics = [pscustomobject][ordered]@{
            retained_backlog_summary_ready = [long]1
        }
        failureCategory = $null
        failureSafeCode = $null
        skipReason = $null
    }
}

function New-TestReport {
    return [pscustomobject][ordered]@{
        schemaVersion = [long]7
        timestampUtc = [datetime]::UtcNow.ToString('o')
        platform = 'windows'
        architecture = 'windowsArm64'
        buildCommit = 'a' * 12
        mode = 'manual-semantic-read-only-cloudkit'
        automaticTriggersEnabled = $false
        remoteSavesEnabled = $false
        remoteDeletesEnabled = $false
        tombstoneSemanticDeletesEnabled = $false
        tombstoneReadOnlyAcknowledgementsEnabled = $true
        retainedUnprojectedEvidencePreserved = $true
        pageLimit = [long]4
        changeLimit = [long]50
        outboxCountBefore = [long]3
        outboxCountAfter = [long]3
        settledOutboxUnchanged = $true
        zones = @(
            (New-TestZone 'attachments'),
            (New-TestZone 'chats'),
            (New-TestZone 'messages')
        )
    }
}

$report = New-TestReport
$summary = Assert-DartApplierReport -Report $report `
    -ExpectedBuildIdentifier ('a' * 12) -NotBeforeUtc ([datetime]::UtcNow.AddMinutes(-1))
Assert-Check 'accepted-report-summary' (
    $summary.fetched -eq 0 -and $summary.applied -eq 0 -and
    $summary.retained_total -eq 24 -and $summary.all_zones_empty_terminal)

$degraded = New-TestReport
$degraded.zones[2].status = 'degraded'
$degraded.zones[2].failureCategory = 'dependency'
$degraded.zones[2].failureSafeCode = 'retained_projection_incomplete'
$degradedAccepted = $true
try {
    $null = Assert-DartApplierReport -Report $degraded `
        -ExpectedBuildIdentifier ('a' * 12) -NotBeforeUtc ([datetime]::UtcNow.AddMinutes(-1))
}
catch { $degradedAccepted = $false }
Assert-Check 'retained-degraded-accepted' $degradedAccepted

$projectionSweep = New-TestReport
$projectionSweep.mode = 'manual-semantic-local-projection-sweep'
$projectionAccepted = $true
try {
    $null = Assert-DartApplierReport -Report $projectionSweep `
        -ExpectedBuildIdentifier ('a' * 12) -NotBeforeUtc ([datetime]::UtcNow.AddMinutes(-1))
}
catch { $projectionAccepted = $false }
Assert-Check 'projection-sweep-report-accepted' $projectionAccepted

$badOutbox = New-TestReport
$badOutbox.outboxCountAfter = [long]2
Assert-Fails 'outbox-change-rejected' {
    Assert-DartApplierReport -Report $badOutbox `
        -ExpectedBuildIdentifier ('a' * 12) -NotBeforeUtc ([datetime]::UtcNow.AddMinutes(-1))
} 'dart_applier_outbox_tripwire_rejected'

$missingZone = New-TestReport
$missingZone.zones = @($missingZone.zones | Select-Object -First 2)
Assert-Fails 'missing-zone-rejected' {
    Assert-DartApplierReport -Report $missingZone `
        -ExpectedBuildIdentifier ('a' * 12) -NotBeforeUtc ([datetime]::UtcNow.AddMinutes(-1))
} 'dart_applier_zone_shape_rejected'

$badStatus = New-TestReport
$badStatus.zones[0].status = 'degraded'
$badStatus.zones[0].failureCategory = 'transport'
$badStatus.zones[0].failureSafeCode = 'cloud_transport_failed'
Assert-Fails 'unapproved-degraded-rejected' {
    Assert-DartApplierReport -Report $badStatus `
        -ExpectedBuildIdentifier ('a' * 12) -NotBeforeUtc ([datetime]::UtcNow.AddMinutes(-1))
} 'dart_applier_zone_status_rejected'

$badTripwire = New-TestReport
$badTripwire.zones[0].retried = [long]1
Assert-Fails 'zone-tripwire-rejected' {
    Assert-DartApplierReport -Report $badTripwire `
        -ExpectedBuildIdentifier ('a' * 12) -NotBeforeUtc ([datetime]::UtcNow.AddMinutes(-1))
} 'dart_applier_zone_tripwire_rejected'

$badDiagnostics = New-TestReport
$badDiagnostics.zones[0].semanticDiagnostics = [pscustomobject]@{}
Assert-Fails 'missing-summary-diagnostic-rejected' {
    Assert-DartApplierReport -Report $badDiagnostics `
        -ExpectedBuildIdentifier ('a' * 12) -NotBeforeUtc ([datetime]::UtcNow.AddMinutes(-1))
} 'dart_applier_diagnostics_rejected'

$oldReport = New-TestReport
$oldReport.timestampUtc = [datetime]::UtcNow.AddHours(-1).ToString('o')
Assert-Fails 'stale-report-rejected' {
    Assert-DartApplierReport -Report $oldReport `
        -ExpectedBuildIdentifier ('a' * 12) -NotBeforeUtc ([datetime]::UtcNow
    )
} 'dart_applier_report_timestamp_rejected'

$status = [pscustomobject]@{
    detail = 'fetched=0 applied=0 retained=24 chat_order_cache_repaired=0 report=obcs2-semantic-123.json'
}
Assert-Check 'status-report-name-bound' (
    (Get-DartApplierReportNameFromStatus -Status $status) -ceq
        'obcs2-semantic-123.json')
Assert-Fails 'status-report-path-rejected' {
    Get-DartApplierReportNameFromStatus -Status ([pscustomobject]@{
        detail = 'report=..\private.json'
    })
} 'dart_applier_status_report_binding_rejected'

$nativeDiagnostics = Get-DartApplierContentFreeNativeDiagnostics -Stdout @'
CloudKit V2 transient message retained_shape absent_mask=042 without_value_mask=000 guid_empty=false chat_empty=false sender_empty=false from_me=true body_present=false attributed_present=true extension_class=apple_other reply_present=false account=must-not-escape
CloudKit V2 transient message retained_shape absent_mask=042 without_value_mask=000 guid_empty=false chat_empty=false sender_empty=false from_me=true body_present=false attributed_present=true extension_class=apple_other reply_present=false
CloudKit V2 transient message retained_route_shape outer_type_class=class_1 service_class=imessage chat_empty=true sender_empty=false from_me=false destination_empty=false destination_matches_sender=false proto4_present=true group_id_state=nonempty group_matches_sender=false group_matches_destination=false account=must-not-escape
CloudKit V2 transient message retained_route_shape outer_type_class=class_1 service_class=imessage chat_empty=true sender_empty=false from_me=false destination_empty=false destination_matches_sender=false proto4_present=true group_id_state=nonempty group_matches_sender=false group_matches_destination=false
CloudKit V2 transient message retained_shape outer_type_class=system_4 absent_mask=042 without_value_mask=000
CloudKit V2 retained conversion outcome=CloudCanonicalConversionOutcome::Quarantined(MalformedRequiredIdentity)
CloudKit V2 transient message unsupported_service source=top_level_svc service_class=rcs top_level_service_class=rcs msg_proto_4_service_class=sms message_kind=normal
CloudKit V2 extension name contract name_shape=absent url_shape=ns_url app_id_shape=other_scalar display_shape=string layout_shape=string user_info_shape=ns_dictionary
CloudKit V2 extension name contract name_shape=absent url_shape=ns_url app_id_shape=other_scalar display_shape=string layout_shape=string user_info_shape=ns_dictionary message=must-not-escape
CloudKit V2 extension name contract name_shape=private-name url_shape=ns_url app_id_shape=other_scalar display_shape=string layout_shape=string user_info_shape=ns_dictionary
CloudKit V2 extension name contract name_shape=absent url_shape=ns_url app_id_shape=other_scalar display_shape=string layout_shape=string user_info_shape=ns_dictionary-private-class
'@
Assert-Check 'native-shape-diagnostics-aggregated' (
    $nativeDiagnostics.schema_version -eq 4 -and
    $nativeDiagnostics.retained_message_shapes.Count -eq 1 -and
    $nativeDiagnostics.retained_message_shapes[0].count -eq 2 -and
    $nativeDiagnostics.retained_route_shapes.Count -eq 1 -and
    $nativeDiagnostics.retained_route_shapes[0].count -eq 2 -and
    $nativeDiagnostics.system_event_shapes.Count -eq 1 -and
    $nativeDiagnostics.conversion_outcomes.Count -eq 1 -and
    $nativeDiagnostics.unsupported_services.Count -eq 1)
Assert-Check 'extension-name-shapes-closed-aggregates' (
    $nativeDiagnostics.extension_name_shapes.Count -eq 1 -and
    $nativeDiagnostics.extension_name_shapes[0].count -eq 2 -and
    $nativeDiagnostics.extension_name_shapes[0].shape -ceq
        'name=absent;url=ns_url;app_id=other_scalar;display=string;layout=string;user_info=ns_dictionary')
Assert-Check 'native-shape-diagnostics-redacted' (
    -not (($nativeDiagnostics | ConvertTo-Json -Depth 8) -match 'must-not-escape'))

$first = [pscustomobject]@{
    fetched = 0; applied = 0; all_zones_empty_terminal = $true
    chat_order_cache_repaired = 0; outbox_before = 3; outbox_after = 3
    retained = [pscustomobject]@{ attachments = 8; chats = 8; messages = 8 }
}
$second = [pscustomobject]@{
    fetched = 0; applied = 0; all_zones_empty_terminal = $true
    chat_order_cache_repaired = 0; outbox_before = 3; outbox_after = 3
    retained = [pscustomobject]@{ attachments = 8; chats = 8; messages = 8 }
}
Assert-Check 'stable-pair-accepted' (
    Test-DartApplierStablePair -Previous $first -Current $second)
$second.applied = 1
Assert-Check 'nonzero-repeat-rejected' (-not (
    Test-DartApplierStablePair -Previous $first -Current $second))
$second.applied = 0
$second.retained.messages = 7
Assert-Check 'retained-drift-rejected' (-not (
    Test-DartApplierStablePair -Previous $first -Current $second))

$env:OPENBUBBLES_CLOUDKIT_WRITER_OWNER = 'v2'
try {
    Assert-Fails 'parent-writer-env-rejected' {
        Assert-DartApplierNoBlockedEnvironment
    } 'dart_applier_writer_or_probe_environment_rejected'
    $start = New-DartApplierStartInfo `
        -Dart 'C:\tools\dart.exe' `
        -FlutterToolsSnapshot 'C:\tools\flutter_tools.snapshot' `
        -Repository 'C:\repo' `
        -NativeLibrary 'C:\runtime\rust_lib_bluebubbles.dll' `
        -RuntimeDirectory 'C:\runtime' `
        -LaunchId ('b' * 32) `
        -BuildIdentifier ('a' * 12)
    $arguments = @($start.ArgumentList)
    Assert-Check 'child-writer-env-scrubbed' (
        -not $start.Environment.ContainsKey('OPENBUBBLES_CLOUDKIT_WRITER_OWNER'))
    Assert-Check 'child-native-logging-bounded' (
        $start.Environment['OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_HARNESS'] -ceq '1' -and
        -not $start.Environment.ContainsKey('OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_VERBOSE_NATIVE_LOGS') -and
        -not $start.Environment.ContainsKey('RUST_LOG'))
    Assert-Check 'child-run-once-bound' (
        $start.Environment['OPENBUBBLES_LIVE_HARNESS_OPERATION'] -ceq 'run-once' -and
        $start.Environment['OPENBUBBLES_LIVE_HARNESS_LAUNCH_ID'] -ceq ('b' * 32) -and
        $start.Environment['OPENBUBBLES_TEST_NATIVE_LIBRARY'] -ceq
            'C:\runtime\rust_lib_bluebubbles.dll')
    Assert-Check 'child-build-identity-bound' (
        $arguments -ccontains
             '--dart-define=OPENBUBBLES_BUILD_COMMIT=aaaaaaaaaaaa' -and
        $arguments -ccontains '--no-pub' -and
        $arguments -ccontains '--concurrency=1')
    $drainStart = New-DartApplierStartInfo `
        -Dart 'C:\tools\dart.exe' `
        -FlutterToolsSnapshot 'C:\tools\flutter_tools.snapshot' `
        -Repository 'C:\repo' `
        -NativeLibrary 'C:\runtime\rust_lib_bluebubbles.dll' `
        -RuntimeDirectory 'C:\runtime' `
        -LaunchId ('c' * 32) `
        -BuildIdentifier ('a' * 12) `
        -Operation drain `
        -ReplayExcludedChats
    $drainArguments = @($drainStart.ArgumentList)
    Assert-Check 'drain-native-logging-bounded' (
        $drainStart.Environment['OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_HARNESS'] -ceq '1' -and
        -not $drainStart.Environment.ContainsKey('OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_VERBOSE_NATIVE_LOGS') -and
        -not $drainStart.Environment.ContainsKey('RUST_LOG'))
    Assert-Check 'child-drain-bound' (
        $drainStart.Environment['OPENBUBBLES_LIVE_HARNESS_OPERATION'] -ceq 'drain' -and
        $drainStart.Environment['OPENBUBBLES_LIVE_HARNESS_LAUNCH_ID'] -ceq ('c' * 32) -and
        $drainArguments -ccontains
            '--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_REPLAY_EXCLUDED_CHATS=true')
}
finally {
    Remove-Item Env:OPENBUBBLES_CLOUDKIT_WRITER_OWNER -ErrorAction SilentlyContinue
}

Write-Host "RESULT pass=$script:Pass fail=$script:Fail"
if ($script:Fail -ne 0) { exit 1 }
