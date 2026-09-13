[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $SourceRoot,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $ExpectedSourceCommit,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $SidecarCommit,

    [Parameter(Mandatory)]
    [ValidateSet('local-write', 'read-only')]
    [string] $BuildVariant,

    [ValidateSet('harness', 'native-test-host')]
    [string] $ArtifactMode = 'harness',

    [Parameter(Mandatory)]
    [string] $OutputRoot,

    [string] $FlutterRoot,

    [ValidateRange(10, 120)]
    [int] $SmokeTimeoutSeconds = 30,

    [switch] $ValidateOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Checked {
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [string[]] $ArgumentList = @()
    )

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE`: $FilePath"
    }
}

function Get-PEMachine {
    param([Parameter(Mandatory)][string] $Path)

    $stream = [System.IO.File]::Open(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    try {
        $reader = [System.IO.BinaryReader]::new($stream)
        try {
            if ($reader.ReadUInt16() -ne 0x5A4D) { return 'NotPE' }
            $stream.Position = 0x3C
            $peOffset = $reader.ReadUInt32()
            if ($peOffset -gt ($stream.Length - 6)) { return 'NotPE' }
            $stream.Position = $peOffset
            if ($reader.ReadUInt32() -ne 0x00004550) { return 'NotPE' }
            switch ($reader.ReadUInt16()) {
                0x8664 { return 'X64' }
                0xAA64 { return 'ARM64' }
                0x014C { return 'X86' }
                default { return 'Unknown' }
            }
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Get-CommandText {
    param([Parameter(Mandatory)][string] $FilePath, [string[]] $Arguments)
    return ((& $FilePath @Arguments 2>&1 | Out-String).Trim())
}

function Assert-NativeTestResults {
    param([string] $OutputText, [string[]] $ExpectedNames)
    foreach ($case in $ExpectedNames) {
        if ($OutputText -notmatch ("(?m)^test " + [regex]::Escape($case) + ' \.\.\. ok\r?$')) {
            throw "Required native regression test did not pass: $case"
        }
    }
    if ($ExpectedNames.Count -eq 0 -or $OutputText -notmatch (
        'test result: ok\. ' + $ExpectedNames.Count + ' passed; 0 failed; 0 ignored;'
    )) {
        throw 'Native test selection was empty, incomplete, skipped, or unsuccessful.'
    }
}

function Assert-NativeScopeResults {
    param([string] $OutputText, [string[]] $ExpectedNames, [int] $MinimumPassed)
    foreach ($case in $ExpectedNames) {
        if ($OutputText -notmatch ("(?m)^test " + [regex]::Escape($case) + ' \.\.\. ok\r?$')) {
            throw "Required native regression test did not pass: $case"
        }
    }
    $scopeMatch = [regex]::Match($OutputText, '(?m)^test result: ok\. (\d+) passed; 0 failed; 0 ignored;')
    if (-not $scopeMatch.Success) {
        throw 'Native test scope did not report zero failures.'
    }
    $scopePassed = [int]$scopeMatch.Groups[1].Value
    if ($scopePassed -le 0 -or $scopePassed -lt $MinimumPassed) {
        throw "Native test scope passed count $scopePassed is below minimum $MinimumPassed."
    }
}

$nativeDiagnosticCases = @(
    'cloud_sync_transient_bridge::tests::message_required_masks_distinguish_absent_and_without_value',
    'cloud_sync_transient_bridge::tests::message_extension_diagnostics_never_return_provider_values',
    'cloud_sync_transient_bridge::tests::retained_reply_diagnostics_are_bounded_and_value_free',
    'tests::native_logger_handle_outlives_initialization',
    'desktop_native_logging::tests::findmy_probe_cannot_enable_broad_native_debug'
)

# Extension-metadata qualification: full helper/converter/DTO scopes plus the
# repair-digest and system-event regressions wired by the parent. Minimums allow
# growth when the parent adds cases; actual execution must still report >0
# passed with zero failures. Spot names prove the real scope ran.
$nativeExtensionScope = 'cloud_sync_extension_payload::tests::'
$nativeConverterScope = 'cloud_sync_canonical_converter::tests::'
$nativeDtoScope = 'cloud_sync_canonical_dto::tests::'
$nativeExtensionMinimum = 28
$nativeConverterMinimum = 79
$nativeDtoMinimum = 24
$nativeExtensionSpotCases = @(
    'cloud_sync_extension_payload::tests::generated_json_has_exact_version_one_wire_contract_and_roundtrips',
    'cloud_sync_extension_payload::tests::minimum_balloon_is_metadata_not_base_only_success'
    'cloud_sync_extension_payload::tests::session_metadata_has_closed_versions_and_separate_wire_identity'
    'cloud_sync_extension_payload::tests::decode_diagnostic_stages_preserve_result_and_never_contain_content'
    'cloud_sync_extension_payload::tests::live_layout_shape_does_not_expose_archive_values'
    'cloud_sync_extension_payload::tests::direct_live_layout_data_matches_wrapper_and_keeps_the_same_limit'
    'cloud_sync_extension_payload::tests::direct_icon_data_still_requires_valid_bounded_gzip'
)
$nativeConverterSpotCases = @(
    'cloud_sync_canonical_converter::tests::extension_archive_projects_renderer_metadata_with_base_message',
    'cloud_sync_canonical_converter::tests::group_routing_digest_matches_dart_framed_sha256_vector'
    'cloud_sync_canonical_converter::tests::multipart_numeric_reply_keeps_its_exact_parent_dependency'
)
$nativeDtoSpotCases = @(
    'cloud_sync_canonical_dto::tests::every_payload_and_metadata_debug_path_is_redacted',
    'cloud_sync_canonical_dto::tests::aggregate_transient_payload_bytes_are_bounded'
    'cloud_sync_canonical_dto::tests::multipart_reply_preserves_numeric_path_and_exact_final_uuid'
)
$nativeRepairDigestCases = @(
    'api::api::cloudkit_repair_digest_tests::cloudkit_repair_digest_binds_exact_extension_metadata_bytes',
    'api::api::cloudkit_repair_digest_tests::cloudkit_repair_digest_matches_every_pinned_neutral_vector'
)
$nativeSystemEventCases = @(
    'cloud_sync_transient_bridge::tests::system_events_without_normal_error_and_flags_remain_unsupported',
    'cloud_sync_transient_bridge::tests::system_event_quarantine_still_requires_each_common_envelope_field',
    'cloud_sync_transient_bridge::tests::system_events_without_normal_fields_still_reject_malformed_payloads',
    'cloud_sync_transient_bridge::tests::normal_message_conversion_still_requires_error_and_flags',
    'cloud_sync_transient_bridge::tests::system_event_classification_stays_after_preflight_before_normal_conversion'
)

$source = (Resolve-Path -LiteralPath $SourceRoot -ErrorAction Stop).Path
$sourceItem = Get-Item -LiteralPath $source -Force
if (-not $sourceItem.PSIsContainer -or
    ($sourceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
    throw 'SourceRoot must be a physical directory.'
}

$actualCommit = (& git -C $source rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $actualCommit -cne $ExpectedSourceCommit) {
    throw "Checked-out source does not match ExpectedSourceCommit: $actualCommit"
}
$status = @(& git -C $source status --porcelain=v1)
if ($LASTEXITCODE -ne 0 -or $status.Count -ne 0) {
    throw 'Reviewed source checkout must be clean before build preparation.'
}
$submodules = @(& git -C $source submodule status --recursive)
if ($LASTEXITCODE -ne 0 -or @($submodules | Where-Object { $_ -match '^[+\-U]' }).Count -ne 0) {
    throw 'Source submodules must be initialized at their recorded commits.'
}
$sourceTree = Get-CommandText -FilePath git -Arguments @('-C', $source, 'rev-parse', 'HEAD^{tree}')

$requiredFiles = @(
    'lib/cloud_sync_v2_windows_harness.dart',
    'windows/CMakeLists.txt',
    'windows/runner/cloud_sync_v2_plugin_registrant.cc',
    'tooling/windows/run_cloud_sync_v2_dev.ps1',
    'tooling/windows/run_cloud_sync_v2_auth_probe.ps1',
    'tooling/windows/test_run_cloud_sync_v2_dev.ps1',
    'tooling/windows/test_run_cloud_sync_v2_auth_probe.ps1',
    'test/services/cloud_sync/cloud_sync_v2_windows_harness_test.dart',
    'test/services/cloud_sync/cloud_sync_windows_dev_profile_test.dart',
    'test/services/cloud_sync/cloud_sync_windows_local_write_test.dart',
    'test/services/cloud_sync/cloud_sync_local_send_encoder_test.dart',
    'test/services/cloud_sync/objectbox_own_writer_precision_recovery_test.dart',
    'test/services/cloud_sync/cloud_sync_prepared_extension_test.dart',
    'test/services/cloud_sync/cloud_sync_extension_integration_test.dart',
    'test/services/cloud_sync/cloud_sync_extension_test_fixture.dart',
    'lib/services/rustpush/cloud_sync/cloud_sync_prepared_extension.dart',
    'lib/services/rustpush/cloud_sync/cloud_inbox_applier.dart',
    'lib/services/rustpush/cloud_sync/cloudkit_repair_content_digest.dart',
    'lib/services/rustpush/cloud_sync/rust_cloud_semantic_decoder.dart',
    'lib/services/rustpush/cloud_sync/objectbox_canonical_semantic_entity_adapter.dart',
    'test/services/cloud_sync/objectbox_canonical_semantic_entity_adapter_test.dart',
    'test/services/cloud_sync/rust_cloud_semantic_decoder_test.dart',
    'rust/src/cloud_sync_message_update_compose.rs',
    'rust/src/cloud_sync_transient_bridge.rs',
    'rust/src/cloud_sync_canonical_converter.rs',
    'rust/src/cloud_sync_canonical_dto.rs',
    'rust/src/cloud_sync_extension_payload.rs',
    'rust/src/api/api.rs',
    'test/fixtures/cloud_sync/cloudkit_repair_digest_golden_v1.tsv',
    'test/fixtures/cloud_sync/extension_metadata_digest_v1.json',
    'test/fixtures/cloud_sync/extension_session_digest_v2.json',
    'test/fixtures/cloud_sync/.gitattributes',
    'rust/src/frb_generated.rs',
    'lib/src/rust/frb_generated.dart',
    'lib/src/rust/frb_generated.io.dart'
)
foreach ($relative in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $source $relative) -PathType Leaf)) {
        throw "Reviewed source is missing required fast-loop input: $relative"
    }
}
if ($ArtifactMode -eq 'native-test-host') {
    foreach ($case in $nativeDiagnosticCases) {
        $relativeSource = if ($case.StartsWith('tests::')) { 'rust/src/lib.rs' }
            elseif ($case.StartsWith('desktop_native_logging::')) { 'rust/src/desktop_native_logging.rs' }
            else { 'rust/src/cloud_sync_transient_bridge.rs' }
        $diagnosticSource = Get-Content -LiteralPath (Join-Path $source $relativeSource) -Raw
        if (-not $diagnosticSource.Contains('fn ' + ($case -split '::')[-1] + '(')) {
            throw "Reviewed source lacks the pending diagnostic regression: $case. Commit it before dispatch."
        }
    }
    foreach ($case in @($nativeExtensionSpotCases + $nativeConverterSpotCases + $nativeDtoSpotCases + $nativeRepairDigestCases + $nativeSystemEventCases)) {
        $extensionSource = if ($case.StartsWith('cloud_sync_extension_payload::')) { 'rust/src/cloud_sync_extension_payload.rs' }
            elseif ($case.StartsWith('cloud_sync_canonical_converter::')) { 'rust/src/cloud_sync_canonical_converter.rs' }
            elseif ($case.StartsWith('cloud_sync_canonical_dto::')) { 'rust/src/cloud_sync_canonical_dto.rs' }
            elseif ($case.StartsWith('api::api::')) { 'rust/src/api/api.rs' }
            else { 'rust/src/cloud_sync_transient_bridge.rs' }
        $extensionText = Get-Content -LiteralPath (Join-Path $source $extensionSource) -Raw
        if (-not $extensionText.Contains('fn ' + ($case -split '::')[-1] + '(')) {
            throw "Reviewed source lacks the pending extension regression: $case. Commit it before dispatch."
        }
    }
}

$cmakeSource = Get-Content -LiteralPath (Join-Path $source 'windows/CMakeLists.txt') -Raw
foreach ($requiredText in @(
    'OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_HARNESS',
    'set(FLUTTER_PLUGIN_LIST',
    'objectbox_flutter_libs',
    'set(FLUTTER_FFI_PLUGIN_LIST',
    'rust_lib_bluebubbles',
    'if(NOT OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_HARNESS)'
)) {
    if (-not $cmakeSource.Contains($requiredText)) {
        throw "Windows harness CMake contract is missing: $requiredText"
    }
}
$harnessBranch = $cmakeSource.IndexOf(
    'if(OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_HARNESS)',
    [System.StringComparison]::Ordinal
)
$normalPluginInclude = $cmakeSource.IndexOf(
    'include(flutter/generated_plugins.cmake)',
    [System.StringComparison]::Ordinal
)
if ($harnessBranch -lt 0 -or $normalPluginInclude -le $harnessBranch) {
    throw 'CloudKit harness no longer bypasses the full generated plugin graph.'
}

$harnessSource = Get-Content -LiteralPath (
    Join-Path $source 'lib/cloud_sync_v2_windows_harness.dart'
) -Raw
$launchParse = $harnessSource.IndexOf(
    'CloudSyncV2WindowsHarnessLaunch.parse(arguments)',
    [System.StringComparison]::Ordinal
)
$profileConfiguration = $harnessSource.IndexOf(
    'fs.configureCloudSyncV2WindowsDevProfile()',
    [System.StringComparison]::Ordinal
)
$nativeInit = $harnessSource.IndexOf('await RustLib.init()', [System.StringComparison]::Ordinal)
if ($launchParse -lt 0 -or $profileConfiguration -le $launchParse -or
    $nativeInit -le $profileConfiguration -or
    -not $harnessSource.Contains('cloud_sync_windows_dev_launch_id_invalid')) {
    throw 'Invalid-launch rejection no longer precedes profile and native initialization.'
}

$launcherSource = Get-Content -LiteralPath (
    Join-Path $source 'tooling/windows/run_cloud_sync_v2_dev.ps1'
) -Raw
$buildIdentifier = & {
    param($TaskRepository, $TaskVariant)
    # Use the launcher's identity rules before pub/build generate files.
    # Keep its local-machine defaults out of this builder's scope.
    . (Join-Path $TaskRepository 'tooling/windows/run_cloud_sync_v2_dev.ps1') -FunctionsOnlyForTest
    $sourceIdentifier = Resolve-HarnessBuildIdentifier -Repository $TaskRepository
    Get-HarnessConfigurationIdentifier -SourceIdentifier $sourceIdentifier -WriterBuild:($TaskVariant -eq 'local-write')
} $source $BuildVariant
$flagAssignment = $launcherSource.IndexOf(
    '$env:OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_HARNESS = "1"',
    [System.StringComparison]::Ordinal
)
$flutterBuild = $launcherSource.IndexOf('& $flutter @arguments', [System.StringComparison]::Ordinal)
if ($flagAssignment -lt 0 -or $flutterBuild -le $flagAssignment) {
    throw 'The reviewed launcher no longer selects the dedicated harness before building.'
}
foreach ($writerContract in @(
    'return "$SourceIdentifier-local-write"',
    '--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_OUTBOUND_CANARY=true',
    '--dart-define=OPENBUBBLES_CLOUDKIT_WRITER_OWNER=v2'
)) {
    if (-not $launcherSource.Contains($writerContract)) {
        throw "The reviewed launcher is missing its local-write build contract: $writerContract"
    }
}

foreach ($name in @(
    'OPENBUBBLES_CLOUD_SYNC_V2_OUTBOUND_CANARY',
    'OPENBUBBLES_CLOUDKIT_WRITER_OWNER',
    'OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_REPLAY_EXCLUDED_CHATS',
    'OPENBUBBLES_CLOUD_SYNC_V2_LOCAL_SEND_RUNTIME',
    'OPENBUBBLES_RUN_LIVE_WINDOWS_HARNESS'
)) {
    if (-not [string]::IsNullOrWhiteSpace(
        [Environment]::GetEnvironmentVariable($name, 'Process')
    )) {
        throw "Writer-capable environment variable must be absent: $name"
    }
}

$sourceInputPaths = @(
    'lib/cloud_sync_v2_windows_local_write.dart',
    'lib/services/rustpush/cloud_sync/cloud_sync_local_mutation_journal.dart',
    'test/services/cloud_sync/cloud_sync_local_mutation_journal_test.dart',
    'test/services/cloud_sync/cloud_sync_local_mutation_projection_test.dart',
    'test/services/cloud_sync/cloud_sync_windows_mutation_target_test.dart',
    'test/services/cloud_sync/native_protected_message_update_transport_test.dart',
    'rust/src/lib.rs', 'rust/src/desktop_native_logging.rs',
    'rust/Cargo.toml', 'rust/Cargo.lock', 'pubspec.lock',
    'rust/src/frb_generated.rs', 'rust/src/frb_generated.io.rs',
    'lib/src/rust/api/api.dart', 'lib/src/rust/frb_generated.dart', 'lib/src/rust/frb_generated.io.dart',
    'rust/src/api/api.rs', 'rust/src/cloud_sync_message_update_compose.rs',
    'rust/src/cloud_sync_message_update_stage.rs',
    'rust/src/cloud_sync_transient_bridge.rs',
    'rust/src/cloud_sync_canonical_converter.rs',
    'rust/src/cloud_sync_canonical_dto.rs',
    'rust/src/cloud_sync_extension_payload.rs',
    'lib/services/rustpush/cloud_sync/cloud_sync_prepared_extension.dart',
    'lib/services/rustpush/cloud_sync/cloud_inbox_applier.dart',
    'lib/services/rustpush/cloud_sync/cloudkit_repair_content_digest.dart',
    'lib/services/rustpush/cloud_sync/rust_cloud_semantic_decoder.dart',
    'lib/services/rustpush/cloud_sync/objectbox_canonical_semantic_entity_adapter.dart',
    'lib/services/rustpush/cloud_sync/objectbox_cloud_semantic_store_gateway.dart',
    'lib/services/rustpush/cloud_sync/transient_cloud_canonical_identity_registry.dart',
    'lib/services/rustpush/cloud_sync/cloudkit_quarantine_repair.dart',
    'lib/services/ui/extension_service.dart',
    'test/services/ui/extension_service_cache_test.dart',
    'test/services/cloud_sync/objectbox_canonical_semantic_entity_adapter_test.dart',
    'test/services/cloud_sync/rust_cloud_semantic_decoder_test.dart',
    'test/services/cloud_sync/cloud_sync_local_send_encoder_test.dart',
    'test/services/cloud_sync/objectbox_own_writer_precision_recovery_test.dart',
    'test/services/cloud_sync/cloud_sync_prepared_extension_test.dart',
    'test/services/cloud_sync/cloud_sync_extension_integration_test.dart',
    'test/services/cloud_sync/cloud_sync_extension_test_fixture.dart',
    'test/fixtures/cloud_sync/cloudkit_repair_digest_golden_v1.tsv',
    'test/fixtures/cloud_sync/extension_metadata_digest_v1.json',
    'test/fixtures/cloud_sync/extension_session_digest_v2.json',
    'test/fixtures/cloud_sync/.gitattributes',
    'test/services/cloud_sync/cloudkit_repair_content_digest_golden_test.dart'
)
$sourceInputs = @(foreach ($relative in $sourceInputPaths) {
    [ordered]@{ path = $relative; sha256 = (Get-FileHash -LiteralPath (Join-Path $source $relative) -Algorithm SHA256).Hash.ToLowerInvariant() }
})

if ($ValidateOnly) {
    [pscustomobject]@{
        result = 'validated'
        source_commit = $actualCommit
        build_variant = $BuildVariant
        artifact_mode = $ArtifactMode
        harness_media_graph_excluded = $true
        invalid_launch_precedes_profile_and_native_init = $true
        automatic_send_runtime_absent = $true
    } | ConvertTo-Json -Depth 4
    return
}

if (-not $IsWindows -or
    [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne
        [System.Runtime.InteropServices.Architecture]::Arm64) {
    throw 'This build must run on native Windows ARM64.'
}

if ($FlutterRoot) {
    $flutter = Join-Path ([System.IO.Path]::GetFullPath($FlutterRoot)) 'bin/flutter.bat'
}
else {
    $flutterCommand = Get-Command flutter.bat -ErrorAction SilentlyContinue
    if (-not $flutterCommand) { $flutterCommand = Get-Command flutter -ErrorAction Stop }
    $flutter = $flutterCommand.Source
}
foreach ($tool in @('git', 'cmake', 'perl', 'rustc', 'cargo', 'protoc')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Required Windows build tool is unavailable: $tool"
    }
}
if (-not (Test-Path -LiteralPath $flutter -PathType Leaf)) {
    throw "Flutter executable is unavailable: $flutter"
}

$output = [System.IO.Path]::GetFullPath($OutputRoot).TrimEnd('\', '/')
$outputVolume = [System.IO.Path]::GetPathRoot($output).TrimEnd('\', '/')
if ($output -eq $outputVolume -or $output.Length -lt ($outputVolume.Length + 12)) {
    throw "OutputRoot is too broad: $output"
}
if (Test-Path -LiteralPath $output) {
    if (@(Get-ChildItem -LiteralPath $output -Force).Count -ne 0) {
        throw "OutputRoot must be absent or empty: $output"
    }
}
else {
    New-Item -ItemType Directory -Path $output | Out-Null
}

$fairPlaySource = Join-Path $source 'rustpush/certs/legacy-fairplay'
$fairPlayDestination = Join-Path $source 'rustpush/certs/fairplay'
foreach ($file in @('fairplay.pem', 'fairplay.crt')) {
    if (-not (Test-Path -LiteralPath (Join-Path $fairPlaySource $file) -PathType Leaf)) {
        throw "Repository-provided compile fixture is unavailable: $file"
    }
}
New-Item -ItemType Directory -Path $fairPlayDestination -Force | Out-Null
$certificateNames = @(
    '4056631661436364584235346952193',
    '4056631661436364584235346952194',
    '4056631661436364584235346952195',
    '4056631661436364584235346952196',
    '4056631661436364584235346952197',
    '4056631661436364584235346952198',
    '4056631661436364584235346952199',
    '4056631661436364584235346952200',
    '4056631661436364584235346952201',
    '4056631661436364584235346952208'
)
foreach ($name in $certificateNames) {
    Copy-Item -LiteralPath (Join-Path $fairPlaySource 'fairplay.pem') `
        -Destination (Join-Path $fairPlayDestination "$name.pem")
    Copy-Item -LiteralPath (Join-Path $fairPlaySource 'fairplay.crt') `
        -Destination (Join-Path $fairPlayDestination "$name.crt")
}

$previousEnvironment = @{}
$buildEnvironment = @{
    OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_HARNESS = '1'
    CARGO_BUILD_JOBS = '4'
    CARGO_PROFILE_DEV_DEBUG = '0'
    CARGO_PROFILE_DEV_INCREMENTAL = 'false'
    CARGOKIT_TARGET_TEMP_DIR_OVERRIDE = (Join-Path $env:RUNNER_TEMP 'cloudkit-cargokit-arm64')
}
if ($ArtifactMode -eq 'native-test-host') {
    # One fresh job-local target directory shared by the DLL and Rust tests.
    # Never borrow a retained binary/cache or invoke the local signing wrapper.
    $buildEnvironment['CARGO_TARGET_DIR'] = Join-Path $env:RUNNER_TEMP 'cloudkit-native-arm64'
    $buildEnvironment['OPENBUBBLES_FINDMY_VERBOSE_DIAGNOSTICS'] = 'true'
    $buildEnvironment['RUSTFLAGS'] = ' '
    $buildEnvironment['CARGO_PROFILE_TEST_DEBUG'] = '0'
    $buildEnvironment['CARGO_PROFILE_TEST_INCREMENTAL'] = 'false'
    foreach ($name in @('CARGO_ENCODED_RUSTFLAGS', 'RUSTC_WRAPPER', 'RUSTC_WORKSPACE_WRAPPER',
        'CC', 'CXX', 'AR', 'LD', 'RANLIB', 'CFLAGS', 'CXXFLAGS')) {
        $buildEnvironment[$name] = $null
    }
}
foreach ($name in $buildEnvironment.Keys) {
    $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

$buildLog = Join-Path $output 'flutter-build.log'
$testLog = Join-Path $output 'contract-tests.log'
$dartTestLog = Join-Path $output 'dart-windows-tests.log'
$nativeCodecTestLog = Join-Path $output 'native-codec-tests.log'
$nativeComposeBuildLog = Join-Path $output 'native-compose-build.log'
$nativeComposeTestLog = Join-Path $output 'native-compose-tests.log'
$nativeDiagnosticTestLog = Join-Path $output 'native-diagnostic-tests.log'
$nativeExtensionTestLog = Join-Path $output 'native-extension-tests.log'
$nativeConverterTestLog = Join-Path $output 'native-converter-tests.log'
$nativeDtoTestLog = Join-Path $output 'native-dto-tests.log'
$nativeRepairDigestTestLog = Join-Path $output 'native-repair-digest-tests.log'
$nativeSystemEventTestLog = Join-Path $output 'native-system-event-tests.log'
$nativeTestExecutable = $null
$nativeComposeResult = 'not-run'
$nativeExtensionResult = 'not-run'
# Current source adds three attachment-header cases to the original 48:
# 50 mock-capable tests plus the one native-only legacy encoder comparison.
# Keep the full-file native gate exact, including the newly integrated path.
$expectedNativeCodecTests = 51
Push-Location $source
try {
    foreach ($name in $buildEnvironment.Keys) {
        if ($null -eq $buildEnvironment[$name]) {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        } else {
            [Environment]::SetEnvironmentVariable($name, $buildEnvironment[$name], 'Process')
        }
    }

    Invoke-Checked -FilePath $flutter -ArgumentList @('config', '--enable-windows-desktop')
    Invoke-Checked -FilePath $flutter -ArgumentList @('pub', 'get')
    Invoke-Checked -FilePath 'git' -ArgumentList @('diff', '--exit-code', '--', 'pubspec.lock', 'rust/Cargo.lock')

    $contractScripts = @(
        'tooling/windows/test_run_cloud_sync_v2_dev.ps1',
        'tooling/windows/test_run_cloud_sync_v2_auth_probe.ps1'
    )
    foreach ($script in $contractScripts) {
        & pwsh -NoLogo -NoProfile -File $script 2>&1 |
            Tee-Object -FilePath $testLog -Append
        if ($LASTEXITCODE -ne 0) { throw "Contract test failed: $script" }
    }

    $dartTests = @(
        'test/services/cloud_sync/cloud_sync_local_mutation_journal_test.dart',
        'test/services/cloud_sync/cloud_sync_local_mutation_projection_test.dart',
        'test/services/cloud_sync/cloud_sync_windows_mutation_target_test.dart',
        'test/services/cloud_sync/native_protected_message_update_transport_test.dart',
        'test/services/cloud_sync/cloud_sync_v2_windows_harness_test.dart',
        'test/services/cloud_sync/cloud_sync_windows_dev_profile_test.dart',
        'test/services/cloud_sync/cloud_sync_windows_local_write_test.dart',
        'test/services/cloud_sync/objectbox_own_writer_precision_recovery_test.dart',
        'test/services/cloud_sync/cloud_sync_prepared_extension_test.dart',
        'test/services/cloud_sync/cloud_sync_extension_integration_test.dart',
        'test/services/cloud_sync/cloudkit_repair_content_digest_golden_test.dart',
        'test/services/cloud_sync/cloud_inbox_applier_test.dart',
        'test/services/cloud_sync/objectbox_cloud_semantic_store_gateway_test.dart',
        'test/services/cloud_sync/cloudkit_quarantine_repair_test.dart',
        'test/services/cloud_sync/transient_cloud_canonical_identity_registry_test.dart',
        'test/services/ui/extension_service_cache_test.dart',
        'test/services/cloud_sync/objectbox_canonical_semantic_entity_adapter_test.dart',
        'test/services/cloud_sync/rust_cloud_semantic_decoder_test.dart'
    )
    & $flutter test --no-pub @dartTests 2>&1 |
        Tee-Object -FilePath $dartTestLog
    if ($LASTEXITCODE -ne 0) { throw 'Focused Windows CloudKit Dart tests failed.' }

    if ($ArtifactMode -eq 'native-test-host') {
        $cargoArguments = @('--manifest-path', 'rust/Cargo.toml', '--locked',
            '--target', 'aarch64-pc-windows-msvc', '--lib')
        & cargo build @cargoArguments 2>&1 | Tee-Object -FilePath $buildLog
        if ($LASTEXITCODE -ne 0) { throw 'Native ARM64 DLL build failed.' }
        # Keep the test executable and its hash separate from the cdylib proof.
        & cargo test @cargoArguments --no-run --message-format=json 2>&1 |
            Tee-Object -FilePath $nativeComposeBuildLog
        if ($LASTEXITCODE -ne 0) { throw 'Native compose test compilation failed.' }
        $testExecutables = @(Get-Content -LiteralPath $nativeComposeBuildLog | ForEach-Object {
            try { $event = $_ | ConvertFrom-Json -ErrorAction Stop } catch { return }
            if ($event.reason -eq 'compiler-artifact' -and $event.target.name -eq 'rust_lib_bluebubbles' -and
                $event.profile.test -and $event.executable) { $event.executable }
        })
        if ($testExecutables.Count -ne 1) { throw 'Expected exactly one native test executable.' }
        $nativeTestExecutable = $testExecutables[0]
        $expectedTestParent = Join-Path $env:CARGO_TARGET_DIR 'aarch64-pc-windows-msvc/debug/deps'
        if ([IO.Path]::GetDirectoryName($nativeTestExecutable) -ne [IO.Path]::GetFullPath($expectedTestParent) -or
            (Get-PEMachine $nativeTestExecutable) -ne 'ARM64') {
            throw 'Native test executable does not belong to this ARM64 build.'
        }
        $builtBundle = Join-Path $env:CARGO_TARGET_DIR 'aarch64-pc-windows-msvc/debug'
    } else {
    $buildArguments = @(
        'build', 'windows', '--debug', '--no-pub',
        '--target', 'lib/cloud_sync_v2_windows_harness.dart',
        '--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_DEV_PROFILE=true',
        '--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_SEMANTIC_PULL=true',
        '--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_SAMPLER=true',
        "--dart-define=OPENBUBBLES_BUILD_COMMIT=$buildIdentifier"
    )
    if ($BuildVariant -eq 'local-write') {
        $buildArguments += '--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_OUTBOUND_CANARY=true'
        $buildArguments += '--dart-define=OPENBUBBLES_CLOUDKIT_WRITER_OWNER=v2'
    }
    & $flutter @buildArguments 2>&1 | Tee-Object -FilePath $buildLog
    if ($LASTEXITCODE -ne 0) { throw 'Windows CloudKit harness build failed.' }
    $builtBundle = Join-Path $source 'build/windows/arm64/runner/Debug'
    }
    Invoke-Checked -FilePath 'git' -ArgumentList @('diff', '--exit-code', '--', 'pubspec.lock', 'rust/Cargo.lock')
}
finally {
    Pop-Location
    foreach ($name in $previousEnvironment.Keys) {
        if ($null -eq $previousEnvironment[$name]) {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        }
        else {
            [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
        }
    }
}

$runner = Join-Path $builtBundle 'bluebubbles_app.exe'
$rustLibrary = Join-Path $builtBundle 'rust_lib_bluebubbles.dll'
$requiredBinaries = @($rustLibrary)
if ($ArtifactMode -eq 'harness') { $requiredBinaries += $runner }
foreach ($required in $requiredBinaries) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Build did not produce required executable content: $required"
    }
}

$bundle = Join-Path $output 'bundle'
New-Item -ItemType Directory -Path $bundle | Out-Null
if ($ArtifactMode -eq 'native-test-host') {
    Copy-Item -LiteralPath $rustLibrary -Destination $bundle
    Copy-Item -LiteralPath $nativeTestExecutable -Destination (Join-Path $bundle 'native-compose-tests.exe')
    $objectBox = $env:OPENBUBBLES_BUILD_OBJECTBOX_DLL
    if (-not $objectBox -or -not (Test-Path -LiteralPath $objectBox -PathType Leaf)) {
        throw 'The workflow-pinned ObjectBox runtime is unavailable.'
    }
    Copy-Item -LiteralPath $objectBox -Destination (Join-Path $bundle 'objectbox.dll')
} else {
    Copy-Item -Path (Join-Path $builtBundle '*') -Destination $bundle -Recurse
}
$runner = Join-Path $bundle 'bluebubbles_app.exe'
$rustLibrary = Join-Path $bundle 'rust_lib_bluebubbles.dll'
# Keep the vendor DLL byte-for-byte identical in both artifact modes.
& {
    . (Join-Path $source 'tooling/windows/run_cloud_sync_v2_dev.ps1') -FunctionsOnlyForTest
    Assert-HarnessObjectBoxRuntime -RunnerDirectory $bundle
}

$peFiles = @(Get-ChildItem -LiteralPath $bundle -File -Recurse |
    Where-Object { $_.Extension.ToLowerInvariant() -in @('.exe', '.dll') })
$minimumPEFiles = if ($ArtifactMode -eq 'harness') { 4 } else { 3 }
if ($peFiles.Count -lt $minimumPEFiles) { throw 'Packaged output contains too few PE runtime files.' }
foreach ($file in $peFiles) {
    $machine = Get-PEMachine -Path $file.FullName
    if ($machine -ne 'ARM64') {
        throw "Packaged harness has a non-ARM64 PE file: $($file.Name) ($machine)"
    }
}

if ($ArtifactMode -eq 'native-test-host') {
    & (Join-Path $bundle 'native-compose-tests.exe') 'cloud_sync_message_update_compose::tests::' --test-threads=4 --format=pretty 2>&1 |
        Tee-Object -FilePath $nativeComposeTestLog
    if ($LASTEXITCODE -ne 0) { throw 'Native timestamp/compose tests failed.' }
    $composeResults = Get-Content -LiteralPath $nativeComposeTestLog -Raw
    $composeCases = @(
        'authored_edit_milliseconds_survive_apple_seconds_roundtrip',
        'original_timestamp_keeps_its_containing_millisecond',
        'edit_updates_text_body_and_summary_while_preserving_unknown_proto_fields',
        'edit_reconstructs_unstyled_body_for_plain_text_v2_create_predecessor',
        'edit_does_not_replace_present_empty_attributed_body',
        'unsend_retains_text_and_body_and_adds_retracted_part',
        'edit_rejects_nonzero_part_and_timestamp_that_does_not_follow_predecessor'
    ) | ForEach-Object { "cloud_sync_message_update_compose::tests::$_" }
    Assert-NativeTestResults -OutputText $composeResults -ExpectedNames $composeCases
    foreach ($case in $nativeDiagnosticCases) {
        # --exact prevents a renamed/missing filter from silently passing zero tests.
        $caseOutput = & (Join-Path $bundle 'native-compose-tests.exe') $case --exact --test-threads=1 --format=pretty 2>&1
        $caseExit = $LASTEXITCODE
        $caseOutput | Tee-Object -FilePath $nativeDiagnosticTestLog -Append
        if ($caseExit -ne 0) { throw "Native diagnostic test failed: $case" }
        Assert-NativeTestResults -OutputText ($caseOutput -join "`n") -ExpectedNames @($case)
    }
    & (Join-Path $bundle 'native-compose-tests.exe') $nativeExtensionScope --test-threads=4 --format=pretty 2>&1 |
        Tee-Object -FilePath $nativeExtensionTestLog
    if ($LASTEXITCODE -ne 0) { throw 'Native extension-payload tests failed.' }
    Assert-NativeScopeResults -OutputText (Get-Content -LiteralPath $nativeExtensionTestLog -Raw) -ExpectedNames $nativeExtensionSpotCases -MinimumPassed $nativeExtensionMinimum
    & (Join-Path $bundle 'native-compose-tests.exe') $nativeConverterScope --test-threads=4 --format=pretty 2>&1 |
        Tee-Object -FilePath $nativeConverterTestLog
    if ($LASTEXITCODE -ne 0) { throw 'Native canonical-converter tests failed.' }
    Assert-NativeScopeResults -OutputText (Get-Content -LiteralPath $nativeConverterTestLog -Raw) -ExpectedNames $nativeConverterSpotCases -MinimumPassed $nativeConverterMinimum
    & (Join-Path $bundle 'native-compose-tests.exe') $nativeDtoScope --test-threads=4 --format=pretty 2>&1 |
        Tee-Object -FilePath $nativeDtoTestLog
    if ($LASTEXITCODE -ne 0) { throw 'Native canonical-DTO tests failed.' }
    Assert-NativeScopeResults -OutputText (Get-Content -LiteralPath $nativeDtoTestLog -Raw) -ExpectedNames $nativeDtoSpotCases -MinimumPassed $nativeDtoMinimum
    foreach ($case in $nativeRepairDigestCases) {
        $repairOutput = & (Join-Path $bundle 'native-compose-tests.exe') $case --exact --test-threads=1 --format=pretty 2>&1
        $repairExit = $LASTEXITCODE
        $repairOutput | Tee-Object -FilePath $nativeRepairDigestTestLog -Append
        if ($repairExit -ne 0) { throw "Native repair-digest test failed: $case" }
        Assert-NativeTestResults -OutputText ($repairOutput -join "`n") -ExpectedNames @($case)
    }
    foreach ($case in $nativeSystemEventCases) {
        $systemOutput = & (Join-Path $bundle 'native-compose-tests.exe') $case --exact --test-threads=1 --format=pretty 2>&1
        $systemExit = $LASTEXITCODE
        $systemOutput | Tee-Object -FilePath $nativeSystemEventTestLog -Append
        if ($systemExit -ne 0) { throw "Native system-event test failed: $case" }
        Assert-NativeTestResults -OutputText ($systemOutput -join "`n") -ExpectedNames @($case)
    }
    $nativeComposeResult = 'passed'
    $nativeExtensionResult = 'passed'
}

$nativeHandle = [System.Runtime.InteropServices.NativeLibrary]::Load($rustLibrary)
try {
    if ($nativeHandle -eq [IntPtr]::Zero) { throw 'Rust bridge returned a null native handle.' }
}
finally {
    if ($nativeHandle -ne [IntPtr]::Zero) {
        [System.Runtime.InteropServices.NativeLibrary]::Free($nativeHandle)
    }
}

$priorNativeTestLibrary = $env:OPENBUBBLES_TEST_NATIVE_LIBRARY
$priorNativeTestPath = $env:Path
try {
    $env:OPENBUBBLES_TEST_NATIVE_LIBRARY = $rustLibrary
    $env:Path = "$bundle;$priorNativeTestPath"
    Push-Location $source
    try {
        & $flutter test --no-pub `
            'test/services/cloud_sync/cloud_sync_local_send_encoder_test.dart' `
            --reporter json `
            2>&1 | Tee-Object -FilePath $nativeCodecTestLog
        if ($LASTEXITCODE -ne 0) {
            throw 'Native local-write encoder suite failed.'
        }
        $nativeTestEvents = @(Get-Content -LiteralPath $nativeCodecTestLog |
            ForEach-Object {
                try { $_ | ConvertFrom-Json -ErrorAction Stop } catch { $null }
            })
        $nativeTestDone = @($nativeTestEvents | Where-Object {
            if ($null -eq $_ -or $null -eq $_.PSObject.Properties['type'] -or $_.type -ne 'testDone') { return $false }
            $hiddenProperty = $_.PSObject.Properties['hidden']
            return $null -eq $hiddenProperty -or -not [bool]$hiddenProperty.Value
        })
        if ($nativeTestDone.Count -ne $expectedNativeCodecTests) {
            throw "Expected $expectedNativeCodecTests native codec tests, observed $($nativeTestDone.Count)."
        }
        if (@($nativeTestDone | Where-Object { $_.result -ne 'success' -or $_.skipped }).Count -ne 0) {
            throw 'Native codec results include a skipped or unsuccessful test.'
        }
    }
    finally {
        Pop-Location
    }
}
finally {
    $env:Path = $priorNativeTestPath
    if ($null -eq $priorNativeTestLibrary) {
        Remove-Item -LiteralPath 'Env:OPENBUBBLES_TEST_NATIVE_LIBRARY' `
            -ErrorAction SilentlyContinue
    }
    else {
        $env:OPENBUBBLES_TEST_NATIVE_LIBRARY = $priorNativeTestLibrary
    }
}

$smokeMarkerSeen = $false
$expectedSmokeMarker = 'cloud_sync_windows_dev_launch_id_invalid'
if ($ArtifactMode -eq 'harness') {
$smokeRoot = Join-Path $env:RUNNER_TEMP (
    'cloudkit-executable-smoke-' + [guid]::NewGuid().ToString('N')
)
$smokeAppData = Join-Path $smokeRoot 'AppData/Roaming'
$smokeLocalAppData = Join-Path $smokeRoot 'AppData/Local'
New-Item -ItemType Directory -Path $smokeAppData -Force | Out-Null
New-Item -ItemType Directory -Path $smokeLocalAppData -Force | Out-Null
$priorAppData = $env:APPDATA
$priorLocalAppData = $env:LOCALAPPDATA
$smokeStdout = Join-Path $smokeRoot 'stdout.txt'
$smokeStderr = Join-Path $smokeRoot 'stderr.txt'
$expectedSmokeMarker = 'cloud_sync_windows_dev_launch_id_invalid'
$smokeMarkerSeen = $false
$process = $null
try {
    $env:APPDATA = $smokeAppData
    $env:LOCALAPPDATA = $smokeLocalAppData
    $process = Start-Process -FilePath $runner -WorkingDirectory $bundle `
        -ArgumentList @('--launch-id=invalid') `
        -RedirectStandardOutput $smokeStdout `
        -RedirectStandardError $smokeStderr `
        -WindowStyle Hidden -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds($SmokeTimeoutSeconds)
    do {
        $captured = @($smokeStdout, $smokeStderr | ForEach-Object {
            if (Test-Path -LiteralPath $_ -PathType Leaf) {
                Get-Content -LiteralPath $_ -Raw -ErrorAction SilentlyContinue
            }
        }) -join "`n"
        $smokeMarkerSeen = $captured.Contains($expectedSmokeMarker)
        if ($smokeMarkerSeen -or $process.HasExited) { break }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $process.HasExited) {
        $process.Kill($true)
        $process.WaitForExit()
    }
    $captured = @($smokeStdout, $smokeStderr | ForEach-Object {
        if (Test-Path -LiteralPath $_ -PathType Leaf) {
            Get-Content -LiteralPath $_ -Raw -ErrorAction SilentlyContinue
        }
    }) -join "`n"
    $smokeMarkerSeen = $captured.Contains($expectedSmokeMarker)
}
finally {
    $env:APPDATA = $priorAppData
    $env:LOCALAPPDATA = $priorLocalAppData
    if ($null -ne $process -and -not $process.HasExited) {
        $process.Kill($true)
        $process.WaitForExit()
    }
}
$smokeFiles = @(Get-ChildItem -LiteralPath $smokeRoot -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notin @($smokeStdout, $smokeStderr) })
if ($smokeFiles.Count -ne 0) {
    throw 'Invalid-launch smoke wrote application or profile state.'
}
}

$forbiddenBundleFiles = @(Get-ChildItem -LiteralPath $bundle -File -Recurse |
    Where-Object {
        $_.Extension.ToLowerInvariant() -in @('.pfx', '.p12', '.pem', '.crt', '.key', '.plist', '.db')
    })
if ($forbiddenBundleFiles.Count -ne 0) {
    throw 'Engineering bundle contains a credential, certificate, profile, or database file.'
}

$bundlePrefixLength = $bundle.TrimEnd('\', '/').Length + 1
foreach ($inputFile in $sourceInputs) {
    $hash = (Get-FileHash -LiteralPath (Join-Path $source $inputFile.path) -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -cne $inputFile.sha256) { throw "Build/test source input changed: $($inputFile.path)" }
}
Invoke-Checked -FilePath git -ArgumentList @('-C', $source, 'diff', '--exit-code', '--', 'rust', 'lib', 'test', 'pubspec.lock')
$fileInventory = @(Get-ChildItem -LiteralPath $bundle -File -Recurse |
    Sort-Object FullName |
    ForEach-Object {
        [ordered]@{
            relative_path = $_.FullName.Substring($bundlePrefixLength).Replace('\', '/')
            size_bytes = $_.Length
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            pe_machine = if ($_.Extension.ToLowerInvariant() -in @('.exe', '.dll')) {
                Get-PEMachine -Path $_.FullName
            } else { $null }
            authenticode_status = if ($_.Extension.ToLowerInvariant() -in @('.exe', '.dll')) {
                (Get-AuthenticodeSignature -LiteralPath $_.FullName).Status.ToString()
            } else { $null }
        }
    })

$manifestPath = Join-Path $output 'provenance.json'
$provenance = [ordered]@{
    schema_version = 2
    purpose = "windows-cloudkit-fast-loop-$ArtifactMode"
    source_commit = $actualCommit
    source_tree = $sourceTree
    submodule_commits = $submodules
    sidecar_commit = $SidecarCommit
    github_run_id = $env:GITHUB_RUN_ID
    github_run_attempt = $env:GITHUB_RUN_ATTEMPT
    created_utc = [DateTime]::UtcNow.ToString('o')
    runner = [ordered]@{
        image_os = $env:ImageOS
        image_version = $env:ImageVersion
        os_architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    }
    toolchain = [ordered]@{
        flutter = Get-CommandText -FilePath $flutter -Arguments @('--version')
        rustc = Get-CommandText -FilePath 'rustc' -Arguments @('--version')
        protoc = Get-CommandText -FilePath 'protoc' -Arguments @('--version')
        cmake = Get-CommandText -FilePath 'cmake' -Arguments @('--version')
    }
    build = [ordered]@{
        target = if ($ArtifactMode -eq 'harness') { 'lib/cloud_sync_v2_windows_harness.dart' } else { 'rust/Cargo.toml --lib; flutter test' }
        artifact_mode = $ArtifactMode
        configuration = 'debug'
        architecture = 'arm64'
        variant = $BuildVariant
        build_identifier = if ($ArtifactMode -eq 'harness') { $buildIdentifier } else { $null }
        native_media_graph_excluded = $true
        signing_applied = $false
        findmy_value_free_diagnostics_compiled = ($ArtifactMode -eq 'native-test-host')
        writer_defines_present = ($ArtifactMode -eq 'harness' -and $BuildVariant -eq 'local-write')
        automatic_send_runtime_present = $false
    }
    verification = [ordered]@{
        powershell_contract_tests = 'passed'
        focused_dart_tests = 'passed'
        all_pe_files_arm64 = $true
        rust_bridge_load_unload = 'passed'
        native_timestamp_compose_tests = $nativeComposeResult
        native_timestamp_compose_expected_count = 7
        native_content_free_diagnostic_tests = [ordered]@{
            result = $nativeComposeResult
            expected_names = $nativeDiagnosticCases
            expected_test_count = $nativeDiagnosticCases.Count
            executable = if ($ArtifactMode -eq 'native-test-host') { 'bundle/native-compose-tests.exe' } else { $null }
        }
        native_extension_payload_tests = [ordered]@{
            result = $nativeExtensionResult
            scope = $nativeExtensionScope
            minimum_passed = $nativeExtensionMinimum
            spot_names = $nativeExtensionSpotCases
            executable = if ($ArtifactMode -eq 'native-test-host') { 'bundle/native-compose-tests.exe' } else { $null }
        }
        native_canonical_converter_tests = [ordered]@{
            result = $nativeExtensionResult
            scope = $nativeConverterScope
            minimum_passed = $nativeConverterMinimum
            spot_names = $nativeConverterSpotCases
            executable = if ($ArtifactMode -eq 'native-test-host') { 'bundle/native-compose-tests.exe' } else { $null }
        }
        native_canonical_dto_tests = [ordered]@{
            result = $nativeExtensionResult
            scope = $nativeDtoScope
            minimum_passed = $nativeDtoMinimum
            spot_names = $nativeDtoSpotCases
            executable = if ($ArtifactMode -eq 'native-test-host') { 'bundle/native-compose-tests.exe' } else { $null }
        }
        native_repair_digest_test = [ordered]@{
            result = $nativeExtensionResult
            expected_names = $nativeRepairDigestCases
            executable = if ($ArtifactMode -eq 'native-test-host') { 'bundle/native-compose-tests.exe' } else { $null }
        }
        native_system_event_tests = [ordered]@{
            result = $nativeExtensionResult
            expected_names = $nativeSystemEventCases
            expected_test_count = $nativeSystemEventCases.Count
            executable = if ($ArtifactMode -eq 'native-test-host') { 'bundle/native-compose-tests.exe' } else { $null }
        }
        native_local_write_encoder_tests = [ordered]@{
            result = 'passed'
            native_library = 'bundle/rust_lib_bluebubbles.dll'
            test_file = 'test/services/cloud_sync/cloud_sync_local_send_encoder_test.dart'
            expected_test_count = $expectedNativeCodecTests
            full_file_run = $true
        }
        invalid_launch_diagnostic = if ($ArtifactMode -eq 'harness') { [ordered]@{
            operation = 'invalid-launch-id'
            network_or_auth_requested = $false
            expected_dart_marker = $expectedSmokeMarker
            expected_dart_marker_seen = $smokeMarkerSeen
            process_terminated_if_still_running = $true
            profile_state_written = $false
            proof_status = if ($smokeMarkerSeen) { 'observed' } else { 'not-captured' }
        } } else { [ordered]@{ proof_status = 'not-run-no-gui-assembly' } }
        account_profile_or_database_in_bundle = $false
    }
    qualification = [ordered]@{
        cloud_artifact_signing = 'not-applied'
        local_policy_load = 'not-tested'
        gui_assembly_receipt = 'not-issued'
        retained_native_base_reused = $false
        live_cloudkit_tested = $false
    }
    source_inputs = $sourceInputs
    test_logs = @(Get-ChildItem -LiteralPath $output -Filter '*.log' -File | ForEach-Object {
        [ordered]@{ path = $_.Name; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
    files = $fileInventory
}
[System.IO.File]::WriteAllText(
    $manifestPath,
    ($provenance | ConvertTo-Json -Depth 10),
    [System.Text.UTF8Encoding]::new($false)
)

$archive = Join-Path $output "windows-cloudkit-fast-loop-arm64-$ArtifactMode-$BuildVariant-$actualCommit.zip"
Compress-Archive -Path (Join-Path $bundle '*') -DestinationPath $archive
$archiveHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
$hashPath = "$archive.sha256"
[System.IO.File]::WriteAllText(
    $hashPath,
    "$archiveHash  $([System.IO.Path]::GetFileName($archive))`n",
    [System.Text.Encoding]::ASCII
)

[pscustomobject]@{
    result = 'passed'
    source_commit = $actualCommit
    build_variant = $BuildVariant
    artifact_mode = $ArtifactMode
    build_identifier = if ($ArtifactMode -eq 'harness') { $buildIdentifier } else { $null }
    bundle = $archive
    bundle_sha256 = $archiveHash
    provenance = $manifestPath
    pe_files = $peFiles.Count
    native_codec_smoke = "${expectedNativeCodecTests}_tests_passed_against_packaged_rust_dll"
    invalid_launch_marker_seen = $smokeMarkerSeen
    live_cloudkit_tested = $false
} | ConvertTo-Json -Depth 5
