# Exports only opaque, protected Chat1 correlation inputs from the isolated
# Windows profile. The raw child output is held in memory and never persisted.
[CmdletBinding()]
param(
    [switch] $EnableLive,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')]
    [string] $ExpectedSourceHead,
    [Parameter(Mandatory)][string] $TargetHashFile,
    [string] $Repository = '',
    [string] $FlutterRoot = 'C:\Codex\Toolchains\flutter-3.44.8-arm64',
    [string] $TrustedLegacyRunner = 'C:\Codex\OpenBubblesReview\worktrees\chat1-live-a93671\build\windows\arm64\runner\Debug',
    [ValidateRange(30, 600)][int] $TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($PSVersionTable.PSVersion.Major -lt 7 -or -not $EnableLive -or
    $env:OPENBUBBLES_RUN_CHAT1_STANDALONE_EXPORT -cne '1') {
    throw 'chat1_export_explicit_live_enable_required'
}
foreach ($name in @(
    'OPENBUBBLES_CLOUD_SYNC_V2_OUTBOUND_CANARY',
    'OPENBUBBLES_CLOUDKIT_WRITER_OWNER',
    'OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_REPLAY_EXCLUDED_CHATS',
    'OPENBUBBLES_VERIFY_EDIT_CLAIM',
    'OPENBUBBLES_VERIFY_CHAIN_UNSEND'
)) {
    if (-not [string]::IsNullOrEmpty(
        [Environment]::GetEnvironmentVariable($name, 'Process')
    )) {
        throw 'chat1_export_writer_environment_rejected'
    }
}

if ([string]::IsNullOrWhiteSpace($Repository)) {
    $Repository = Join-Path $PSScriptRoot '../..'
}
$repository = [IO.Path]::GetFullPath($Repository)
$head = (& git -C $repository rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $head -cne $ExpectedSourceHead) {
    throw 'chat1_export_source_head_rejected'
}
if (@(Get-Process bluebubbles_app -ErrorAction SilentlyContinue).Count -ne 0) {
    throw 'chat1_export_profile_in_use'
}

$profile = Join-Path $env:APPDATA 'OpenBubbles\cloudkit-v2-dev'
$profileMarker = Join-Path $profile '.openbubbles-cloud-sync-v2-windows-dev'
if (-not (Test-Path -LiteralPath $profileMarker -PathType Leaf) -or
    (Get-Content -LiteralPath $profileMarker -Raw) -cne
        'openbubbles-cloud-sync-v2-windows-dev-profile:v1') {
    throw 'chat1_export_profile_marker_rejected'
}

$legacyLibrary = Join-Path $TrustedLegacyRunner 'rust_lib_bluebubbles.dll'
$expectedLegacyLibrarySha256 =
    '91a5000a7751d3bef2a9fc16654e8d1e11c297d84647e50b5fa05eee918a0495'
$expectedSigningThumbprint = '8240557965890665F3B49E5FEC83D511CA4F2C9D'
if (-not (Test-Path -LiteralPath $legacyLibrary -PathType Leaf) -or
    (Get-FileHash -LiteralPath $legacyLibrary -Algorithm SHA256).Hash.ToLowerInvariant() -cne
        $expectedLegacyLibrarySha256) {
    throw 'chat1_export_legacy_library_rejected'
}
$signature = Get-AuthenticodeSignature -LiteralPath $legacyLibrary
if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
    $signature.SignerCertificate.Thumbprint -cne $expectedSigningThumbprint) {
    throw 'chat1_export_legacy_signature_rejected'
}

if (-not (Test-Path -LiteralPath $TargetHashFile -PathType Leaf)) {
    throw 'chat1_export_target_file_required'
}
$targets = (Get-Content -LiteralPath $TargetHashFile -Raw).Trim()
$targetValues = @(
    $targets.Split(',') |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }
)
if ($targetValues.Count -ne 8 -or
    @($targetValues | Sort-Object -Unique -CaseSensitive).Count -ne 8 -or
    @($targetValues | Where-Object { $_ -cnotmatch '^[A-Za-z0-9_-]{43}$' }).Count -ne 0) {
    throw 'chat1_export_targets_rejected'
}

$dart = Join-Path $FlutterRoot 'bin\cache\dart-sdk\bin\dart.exe'
$snapshot = Join-Path $FlutterRoot 'bin\cache\flutter_tools.snapshot'
$harnessTest = Join-Path $repository 'test\live\cloud_sync_v2_windows_live_harness_test.dart'
foreach ($required in @($dart, $snapshot, $harnessTest)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw 'chat1_export_runtime_required'
    }
}

$launchId = [Guid]::NewGuid().ToString('N')
$start = [Diagnostics.ProcessStartInfo]::new($dart)
$start.WorkingDirectory = $repository
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
foreach ($key in @($start.Environment.Keys)) {
    if ($key -like 'OPENBUBBLES_*' -or $key -eq 'RUST_LOG') {
        $null = $start.Environment.Remove($key)
    }
}
$start.Environment['OPENBUBBLES_RUN_LIVE_WINDOWS_HARNESS'] = '1'
$start.Environment['OPENBUBBLES_LIVE_HARNESS_OPERATION'] = 'inspect-chat1-discovery'
$start.Environment['OPENBUBBLES_LIVE_HARNESS_LAUNCH_ID'] = $launchId
$start.Environment['OPENBUBBLES_TEST_NATIVE_LIBRARY'] = $legacyLibrary
$start.Environment['OPENBUBBLES_INSPECT_CHAT1_DISCOVERY'] = '1'
$start.Environment['OPENBUBBLES_INSPECT_CHAT1_CORRELATION'] = '1'
$start.Environment['OPENBUBBLES_EXPORT_CHAT1_INPUT_MANIFEST'] = '1'
$start.Environment['OPENBUBBLES_CHAT1_TARGET_MESSAGE_HASHES'] = $targets
$start.Environment['OPENBUBBLES_CLOUD_SYNC_V2_TEST_HOST'] = '1'
$start.Environment['RUST_LOG'] = 'off'
$start.Environment['PATH'] = "$TrustedLegacyRunner;$($start.Environment['PATH'])"
foreach ($argument in @(
    $snapshot,
    'test',
    '--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_DEV_PROFILE=true',
    '--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_SEMANTIC_PULL=true',
    '--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_SAMPLER=true',
    "--dart-define=OPENBUBBLES_BUILD_COMMIT=$($head.Substring(0, 12))",
    '--no-pub',
    '--concurrency=1',
    '--reporter=expanded',
    'test/live/cloud_sync_v2_windows_live_harness_test.dart'
)) {
    $start.ArgumentList.Add($argument)
}

$process = [Diagnostics.Process]::Start($start)
$stdout = $process.StandardOutput.ReadToEndAsync()
$stderr = $process.StandardError.ReadToEndAsync()
if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
    try { $process.Kill($true) } catch {}
    throw 'chat1_export_process_deadline'
}
[Threading.Tasks.Task]::WaitAll(@($stdout, $stderr))
$combined = $stdout.Result + "`n" + $stderr.Result
if ($combined.Length -gt 32MB) {
    throw 'chat1_export_output_overflow'
}
if ($process.ExitCode -ne 0) {
    throw 'chat1_export_test_failed'
}

$prefix = 'windows_chat1_discovery='
$aggregateLine = @(
    $combined -split "`r?`n" | Where-Object { $_.Contains($prefix) }
) | Select-Object -Last 1
$combined = $null
if ($null -eq $aggregateLine) {
    throw 'chat1_export_aggregate_missing'
}
$offset = $aggregateLine.IndexOf($prefix) + $prefix.Length
$aggregate = $aggregateLine.Substring($offset) | ConvertFrom-Json
$aggregateLine = $null
if ($aggregate.manifest_exported -ne $true -or
    $aggregate.content_exposed -ne $false -or
    $aggregate.durable_state_unchanged -ne $true -or
    [int]$aggregate.message_sources -ne 8 -or
    [int]$aggregate.chat1_sources -ne 50) {
    throw 'chat1_export_aggregate_rejected'
}

$manifestPath = Join-Path $profile 'cloud-sync-v2\diagnostics\chat1-correlation-input-v1.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw 'chat1_export_manifest_missing'
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$anchorCount = @($manifest.anchor_message_sources).Count
if ([int]$manifest.schema -ne 1 -or
    $manifest.content_exposed -ne $false -or
    @($manifest.message_sources).Count -ne 8 -or
    $anchorCount -lt 8 -or $anchorCount -gt 2048 -or
    @($manifest.chat1_sources).Count -ne 50) {
    throw 'chat1_export_manifest_shape_rejected'
}
$expectedFields = @(
    'change_id_hash',
    'record_id_hash',
    'etag_hash',
    'payload_sha256',
    'payload_length',
    'server_modified_at_millis',
    'protected_raw_envelope_reference'
)
foreach ($source in @($manifest.message_sources) +
    @($manifest.anchor_message_sources) + @($manifest.chat1_sources)) {
    if (Compare-Object ($source.PSObject.Properties.Name | Sort-Object) ($expectedFields | Sort-Object)) {
        throw 'chat1_export_manifest_field_rejected'
    }
    if ($source.change_id_hash -cnotmatch '^[A-Za-z0-9_-]{43}$' -or
        $source.record_id_hash -cnotmatch '^[A-Za-z0-9_-]{43}$' -or
        $source.payload_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $source.protected_raw_envelope_reference -cnotmatch
            '^obcs2\.ref\.[A-Za-z0-9_-]{43}$') {
        throw 'chat1_export_manifest_value_rejected'
    }
}

$manifestFile = Get-Item -LiteralPath $manifestPath -Force
[pscustomobject]@{
    Exported = $true
    ContentExposed = $false
    DurableStateUnchanged = $true
    MessageSources = @($manifest.message_sources).Count
    AnchorSources = $anchorCount
    Chat1Sources = @($manifest.chat1_sources).Count
    ManifestBytes = $manifestFile.Length
    ManifestSha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    ManifestPath = $manifestPath
}
