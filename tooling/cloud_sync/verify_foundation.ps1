[CmdletBinding()]
param(
    [string]$FlutterCommand = "flutter",
    [string]$ObjectBoxDllDirectory = "",
    [string]$CargoCommand = "cargo",
    [string]$CargoHome = "",
    [string]$RustupHome = "",
    [string]$CargoTargetDirectory = "",
    [switch]$SkipAnalyze,
    [switch]$SkipRust
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$cloudSyncSource = Join-Path $repoRoot "lib\services\rustpush\cloud_sync"
$cloudSyncTests = Join-Path $repoRoot "test\services\cloud_sync"
$harnessManifest = Join-Path $repoRoot "rust\cloud_sync_protector_harness\Cargo.toml"
$sensitiveRustLogScan = Join-Path $PSScriptRoot "check_sensitive_rust_logs.ps1"
$originalPath = $env:PATH
$hadCargoHome = Test-Path Env:CARGO_HOME
$originalCargoHome = $env:CARGO_HOME
$hadRustupHome = Test-Path Env:RUSTUP_HOME
$originalRustupHome = $env:RUSTUP_HOME
$hadCargoTargetDirectory = Test-Path Env:CARGO_TARGET_DIR
$originalCargoTargetDirectory = $env:CARGO_TARGET_DIR
$completedChecks = [System.Collections.Generic.List[string]]::new()
$skippedChecks = [System.Collections.Generic.List[string]]::new()

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action
    )

    Write-Host ""
    Write-Host "== $Label =="
    & $Action
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE"
    }
}

function Resolve-CommandPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command
    )

    if (Test-Path -LiteralPath $Command -PathType Leaf) {
        return (Resolve-Path -LiteralPath $Command).Path
    }
    $resolved = Get-Command $Command -ErrorAction Stop
    return $resolved.Source
}

function Get-PEMachineArchitecture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $reader = New-Object System.IO.BinaryReader($stream)
        $stream.Position = 0x3C
        $stream.Position = $reader.ReadInt32()
        if ($reader.ReadUInt32() -ne 0x00004550) {
            throw "Not a PE image: $Path"
        }
        switch ($reader.ReadUInt16()) {
            0x8664 { return "x64" }
            0xAA64 { return "arm64" }
            default { return "unsupported" }
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Get-ObjectBoxLibraryVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    # The ObjectBox C library embeds its own "<semver>-<date>" banner. Reading it
    # here lets this script reject a stale library before Dart fails 60+ tests
    # with an unrelated LateInitializationError.
    $ascii = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($Path))
    $match = [regex]::Match($ascii, '(\d+)\.(\d+)\.(\d+)-\d{4}-\d{2}-\d{2}')
    if (-not $match.Success) {
        return $null
    }
    return [version]::new([int]$match.Groups[1].Value, [int]$match.Groups[2].Value, [int]$match.Groups[3].Value)
}

function Get-RequiredObjectBoxVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PubspecPath
    )

    $match = Select-String -LiteralPath $PubspecPath -Pattern '^\s{2}objectbox:\s*(\d+\.\d+\.\d+)\s*$' |
        Select-Object -First 1
    if (-not $match) {
        throw "Could not read the pinned objectbox version from $PubspecPath"
    }
    return [version]$match.Matches[0].Groups[1].Value
}

Push-Location $repoRoot
try {
    $flutter = Resolve-CommandPath $FlutterCommand

    # The Dart test host loads objectbox.dll by architecture, so the library must
    # match the Flutter SDK's own dart.exe rather than the repository default.
    $dartHost = Join-Path (Split-Path -Parent $flutter) "cache\dart-sdk\bin\dart.exe"
    if (-not (Test-Path -LiteralPath $dartHost -PathType Leaf)) {
        throw "Could not locate the Dart test host for $flutter"
    }
    $hostArchitecture = Get-PEMachineArchitecture $dartHost
    if ($hostArchitecture -eq "unsupported") {
        throw "Unsupported Flutter test host architecture for $dartHost"
    }
    $requiredObjectBox = Get-RequiredObjectBoxVersion (Join-Path $repoRoot "pubspec.yaml")
    Write-Host "Flutter test host: $hostArchitecture ($dartHost)"
    Write-Host "Required objectbox C library: $requiredObjectBox or newer"

    $explicitObjectBoxDirectory = -not [string]::IsNullOrWhiteSpace($ObjectBoxDllDirectory)
    if ($explicitObjectBoxDirectory) {
        $objectBoxCandidates = @($ObjectBoxDllDirectory)
    }
    else {
        $reviewRoot = Split-Path -Parent $repoRoot
        $objectBoxCandidates = @(
            (Join-Path $repoRoot "build\windows\$hostArchitecture\runner\Release"),
            (Join-Path $repoRoot "build-x64-verified3\windows\$hostArchitecture\runner\Release"),
            (Join-Path $reviewRoot "cloudsync_objectbox5_sandbox\build\windows\$hostArchitecture\runner\Release"),
            "C:\Codex\Toolchains\objectbox-windows-$hostArchitecture-v$requiredObjectBox\lib"
        )
    }

    $ObjectBoxDllDirectory = ""
    $rejectedObjectBoxLibraries = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in $objectBoxCandidates) {
        $candidateDll = Join-Path $candidate "objectbox.dll"
        if (-not (Test-Path -LiteralPath $candidateDll -PathType Leaf)) {
            continue
        }
        $candidateArchitecture = Get-PEMachineArchitecture $candidateDll
        $candidateVersion = Get-ObjectBoxLibraryVersion $candidateDll
        if ($candidateArchitecture -ne $hostArchitecture) {
            $rejectedObjectBoxLibraries.Add("$candidateDll (architecture $candidateArchitecture, needs $hostArchitecture)")
            continue
        }
        if ($null -eq $candidateVersion -or $candidateVersion -lt $requiredObjectBox) {
            $reportedVersion = if ($null -eq $candidateVersion) { "unreadable" } else { $candidateVersion }
            $rejectedObjectBoxLibraries.Add("$candidateDll (version $reportedVersion, needs $requiredObjectBox or newer)")
            continue
        }
        $ObjectBoxDllDirectory = $candidate
        Write-Host "Selected objectbox C library: $candidateDll ($candidateArchitecture $candidateVersion)"
        break
    }

    if ($rejectedObjectBoxLibraries.Count -gt 0) {
        Write-Warning ("Rejected objectbox libraries:`n  " + ($rejectedObjectBoxLibraries -join "`n  "))
    }
    if ([string]::IsNullOrWhiteSpace($ObjectBoxDllDirectory)) {
        throw "No $hostArchitecture objectbox.dll at version $requiredObjectBox or newer was found for this Flutter test host. Pass -ObjectBoxDllDirectory explicitly."
    }
    $env:PATH = "$ObjectBoxDllDirectory;$env:PATH"

    $rustApi = Join-Path $repoRoot "rust\src\api\api.rs"
    $dartApi = Join-Path $repoRoot "lib\src\rust\api\api.dart"
    $runtime = Join-Path $cloudSyncSource "cloud_sync_runtime.dart"
    $protectedTransport = Join-Path $cloudSyncSource "native_protected_cloud_sync_transport.dart"
    $protectedLeaseLifecycle = Join-Path $cloudSyncSource "cloud_protected_page_lease_lifecycle.dart"
    $productionPreflight = Join-Path $cloudSyncSource "cloud_sync_production_preflight.dart"
    $productionOwner = Join-Path $cloudSyncSource "cloud_sync_manual_shadow_owner.dart"
    $protectorHealth = Join-Path $cloudSyncSource "cloud_sync_protector_health.dart"
    $reportWriter = Join-Path $cloudSyncSource "cloud_sync_shadow_report_file.dart"
    $rustPushService = Join-Path $repoRoot "lib\services\rustpush\rustpush_service.dart"
    foreach ($requiredFile in @(
        $rustApi,
        $dartApi,
        $runtime,
        $protectedTransport,
        $protectedLeaseLifecycle,
        $productionPreflight,
        $productionOwner,
        $protectorHealth,
        $reportWriter,
        $rustPushService,
        $sensitiveRustLogScan
    )) {
        if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
            throw "Required Cloud Sync source is missing: $requiredFile"
        }
    }

    # V2's reviewed boundary is the protected bridge. The legacy raw bridge may
    # remain for compatibility, but it is not sufficient evidence for V2.
    foreach ($rustProtectedSymbol in @(
        "pub async fn cloud_sync_capture_auth_snapshot",
        "pub async fn cloud_sync_fetch_protected_page",
        "pub fn cloud_sync_commit_protected_page_lease",
        "pub fn cloud_sync_acknowledge_committed_page_lease",
        "pub fn cloud_sync_rollback_protected_page_lease",
        "pub fn cloud_sync_recover_abandoned_page_leases",
        "pub fn cloud_sync_retire_protected_references",
        "pub fn cloud_sync_collect_protected_garbage"
    )) {
        if (-not (Select-String -LiteralPath $rustApi -SimpleMatch $rustProtectedSymbol)) {
            throw "Rust protected-page bridge entry point is missing: $rustProtectedSymbol"
        }
    }
    foreach ($dartProtectedSymbol in @(
        "cloudSyncCaptureAuthSnapshot",
        "cloudSyncFetchProtectedPage",
        "cloudSyncCommitProtectedPageLease",
        "cloudSyncAcknowledgeCommittedPageLease",
        "cloudSyncRollbackProtectedPageLease",
        "cloudSyncRecoverAbandonedPageLeases",
        "cloudSyncRetireProtectedReferences",
        "cloudSyncCollectProtectedGarbage"
    )) {
        if (-not (Select-String -LiteralPath $dartApi -SimpleMatch $dartProtectedSymbol)) {
            throw "Generated Dart protected-page binding is missing: $dartProtectedSymbol"
        }
    }
    foreach ($deadlineSymbol in @(
        "CLOUD_SYNC_RAW_FETCH_DEADLINE",
        "tokio::time::timeout(CLOUD_SYNC_RAW_FETCH_DEADLINE"
    )) {
        if (-not (Select-String -LiteralPath $rustApi -SimpleMatch $deadlineSymbol)) {
            throw "Rust raw-page native cancellation boundary is missing: $deadlineSymbol"
        }
    }
    foreach ($dartProtectionSymbol in @(
        "cloudSyncProtect",
        "cloudSyncUnprotect",
        "cloudSyncFingerprintAccount"
    )) {
        if (-not (Select-String -LiteralPath $dartApi -SimpleMatch $dartProtectionSymbol)) {
            throw "Generated Dart protection binding is missing: $dartProtectionSymbol"
        }
    }
    foreach ($rustProtectionSymbol in @(
        "pub fn cloud_sync_protect",
        "pub fn cloud_sync_unprotect",
        "pub fn cloud_sync_fingerprint_account"
    )) {
        if (-not (Select-String -LiteralPath $rustApi -SimpleMatch $rustProtectionSymbol)) {
            throw "Rust protection bridge entry point is missing: $rustProtectionSymbol"
        }
    }
    if (-not (Select-String -LiteralPath $runtime -SimpleMatch "!flags.readOnlyFetch")) {
        throw "Shadow runtime does not explicitly require read-only fetch."
    }
    foreach ($protectedLifecycleSymbol in @(
        "ensureRecoveredBeforeFetch",
        "commitJournaledPage",
        "rollbackUnjournaledPage",
        "collectOneProtectedGarbagePage",
        "retireProtectedReferences"
    )) {
        if (-not (Select-String -LiteralPath $protectedLeaseLifecycle -SimpleMatch $protectedLifecycleSymbol)) {
            throw "Protected-page Dart lifecycle operation is missing: $protectedLifecycleSymbol"
        }
    }
    if (-not (Select-String -LiteralPath $protectedTransport -SimpleMatch "NativeProtectedCloudSyncTransport")) {
        throw "Protected native Cloud Sync transport is missing."
    }
    foreach ($productionSymbol in @(
        "CloudSyncProductionPreflightProbe",
        "CloudSyncManualShadowOwner",
        "CloudSyncProtectorHealthProbe",
        "CloudSyncShadowReportFileWriter"
    )) {
        if (-not (Select-String -Path @(
            $productionPreflight,
            $productionOwner,
            $protectorHealth,
            $reportWriter
        ) -SimpleMatch $productionSymbol)) {
            throw "Production manual-sampler safety boundary is missing: $productionSymbol"
        }
    }
    foreach ($compositionSymbol in @(
        "runCloudSyncV2ManualShadowConfirmed",
        "quiesceForAccountTransition",
        "resumeAfterAccountTransition",
        "CloudSyncDevGate.manualShadowSamplerEnabled"
    )) {
        if (-not (Select-String -LiteralPath $rustPushService -SimpleMatch $compositionSymbol)) {
            throw "Production manual-sampler composition is missing: $compositionSymbol"
        }
    }
    $completedChecks.Add("protected bridge, recovery, retention, garbage collection, read-only invariant, and gated production lifecycle")

    Invoke-Checked "Sensitive Rust logging regression scan" {
        & $sensitiveRustLogScan -RepositoryRoot $repoRoot
    }
    $completedChecks.Add("sensitive Rust logging regression scan")

    Invoke-Checked "Cloud Sync Dart and ObjectBox tests" {
        & $flutter test --no-pub $cloudSyncTests
    }
    $completedChecks.Add("Dart and ObjectBox tests")

    if (-not $SkipAnalyze) {
        Invoke-Checked "Focused Flutter analyzer" {
            & $flutter analyze --no-pub $cloudSyncSource $cloudSyncTests
        }
        $completedChecks.Add("focused Flutter analyzer")
    }
    else {
        $skippedChecks.Add("focused Flutter analyzer")
    }

    if (-not $SkipRust) {
        if (-not [string]::IsNullOrWhiteSpace($CargoHome)) {
            $env:CARGO_HOME = $CargoHome
        }
        if (-not [string]::IsNullOrWhiteSpace($RustupHome)) {
            $env:RUSTUP_HOME = $RustupHome
        }
        if ([string]::IsNullOrWhiteSpace($CargoTargetDirectory)) {
            $reviewRoot = Split-Path -Parent $repoRoot
            $CargoTargetDirectory = Join-Path $reviewRoot "build-cache\cloud-sync-protector-harness"
        }
        $null = New-Item -ItemType Directory -Path $CargoTargetDirectory -Force
        $env:CARGO_TARGET_DIR = (Resolve-Path -LiteralPath $CargoTargetDirectory).Path
        $cargo = Resolve-CommandPath $CargoCommand
        Invoke-Checked "Native Cloud Sync protector harness" {
            & $cargo test --locked --manifest-path $harnessManifest
        }
        $completedChecks.Add("native protector harness for the current Cargo target")
    }
    else {
        $skippedChecks.Add("native protector harness")
    }

    Write-Host ""
    Write-Host "Passed checks: $($completedChecks -join '; ')."
    if ($skippedChecks.Count -gt 0) {
        Write-Warning "Partial verification only. Skipped: $($skippedChecks -join '; ')."
    }
    else {
        Write-Host "Cloud Sync V2 offline foundation verification passed for the current native Cargo target."
    }
    Write-Host "APK/Windows package ABI inspection and the other Windows Rust architecture remain separate release gates."
    Write-Host "No live CloudKit access, app installation, account mutation, or message send was performed."
}
finally {
    $env:PATH = $originalPath
    if ($hadCargoHome) {
        $env:CARGO_HOME = $originalCargoHome
    }
    else {
        Remove-Item Env:CARGO_HOME -ErrorAction SilentlyContinue
    }
    if ($hadRustupHome) {
        $env:RUSTUP_HOME = $originalRustupHome
    }
    else {
        Remove-Item Env:RUSTUP_HOME -ErrorAction SilentlyContinue
    }
    if ($hadCargoTargetDirectory) {
        $env:CARGO_TARGET_DIR = $originalCargoTargetDirectory
    }
    else {
        Remove-Item Env:CARGO_TARGET_DIR -ErrorAction SilentlyContinue
    }
    Pop-Location
}
