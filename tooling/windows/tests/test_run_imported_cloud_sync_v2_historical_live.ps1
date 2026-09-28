$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Pure contract tests for the imported historical-import launcher. Synthetic
# fixtures only: no bundle, profile, device, account, or network is touched.

$launcher = Join-Path $PSScriptRoot '../run_imported_cloud_sync_v2_historical_live.ps1'
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

Assert-Check 'hex40-accepted' (Test-HistoricalLiveHex -Value ('a' * 40) -Length 40)
Assert-Check 'hex64-accepted' (Test-HistoricalLiveHex -Value ('b' * 64) -Length 64)
Assert-Check 'hex-uppercase-rejected' (-not (Test-HistoricalLiveHex -Value ('A' * 40) -Length 40))
Assert-Check 'hex-short-rejected' (-not (Test-HistoricalLiveHex -Value ('a' * 39) -Length 40))
Assert-Check 'hex-long-rejected' (-not (Test-HistoricalLiveHex -Value ('a' * 41) -Length 40))
Assert-Check 'hex-nonnhex-rejected' (-not (Test-HistoricalLiveHex -Value ('z' * 40) -Length 40))
Assert-Check 'hex-empty-rejected' (-not (Test-HistoricalLiveHex -Value '' -Length 40))
Assert-Check 'hex-zero-length-rejected' (-not (Test-HistoricalLiveHex -Value 'a' -Length 0))

$zone = Join-Path ([IO.Path]::GetTempPath()) ('ob-historical-live-test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $zone -Force
try {
    $requestPath = Join-Path $zone 'windows-historical-import-request.json'
    Set-Content -LiteralPath $requestPath -Value '{"version":1,"action":"preview","maximumAssessed":1,"maximumCreates":1}' -Encoding UTF8
    Assert-Check 'request-file-parses' (
        (Assert-HistoricalLiveRequestFile -Profile $zone) -ne $null)
    Assert-Fails 'request-file-missing-rejected' {
        Assert-HistoricalLiveRequestFile -Profile (Join-Path $zone 'absent-profile')
    } 'historical_live_request_missing'
    $dirRequest = Join-Path $zone 'dir-as-request';
    $null = New-Item -ItemType Directory -Path $dirRequest -Force
    Remove-Item -LiteralPath (Join-Path $zone 'windows-historical-import-request.json') -Force
    Rename-Item -LiteralPath $dirRequest -NewName 'windows-historical-import-request.json'
    Assert-Fails 'request-directory-rejected' {
        Assert-HistoricalLiveRequestFile -Profile $zone
    } 'historical_live_request_missing'
    Remove-Item -LiteralPath (Join-Path $zone 'windows-historical-import-request.json') -Recurse -Force
    Set-Content -LiteralPath (Join-Path $zone 'windows-historical-import-request.json') `
        -Value '{not json' -Encoding UTF8
    Assert-Fails 'request-unparseable-rejected' {
        Assert-HistoricalLiveRequestFile -Profile $zone
    } 'historical_live_request_unparseable'
    foreach ($invalid in @('{}', '[]', '{"version":1,"action":"archive","maximumAssessed":201,"maximumCreates":1}')) {
        Set-Content -LiteralPath $requestPath -Value $invalid -Encoding UTF8
        Assert-Fails 'request-bounds-rejected' {
            Assert-HistoricalLiveRequestFile -Profile $zone
        } 'historical_live_request_bounds_rejected'
    }
 }
finally {
    Remove-Item -LiteralPath $zone -Recurse -Force
}

$start = New-HistoricalLiveStartInfo `
    -Dart 'C:\dart.exe' `
    -FlutterToolsSnapshot 'C:\snapshot' `
    -Repository 'C:\repo' `
    -NativeLibrary 'C:\native\rust_lib_bluebubbles.dll' `
    -RuntimeDirectory 'C:\native' `
    -LaunchId 'abcdef0123456789abcdef0123456789' `
    -BuildIdentifier '94d5fd07c2b7' `
    -RequestSha256 ('c' * 64) `
    -TimeoutSeconds 600
Assert-Check 'startinfo-operation-historical' (
    $start.Environment['OPENBUBBLES_LIVE_HARNESS_OPERATION'] -ceq 'historical-import')
Assert-Check 'startinfo-test-file-historical' (
    ($start.ArgumentList -join ' ').Contains('cloud_sync_v2_windows_historical_live_test.dart'))
Assert-Check 'startinfo-no-applier-test' (
    -not (($start.ArgumentList -join ' ').Contains('cloud_sync_v2_windows_live_harness_test.dart')))
Assert-Check 'startinfo-writer-owner-define' (
    ($start.ArgumentList -join ' ').Contains('OPENBUBBLES_CLOUDKIT_WRITER_OWNER=v2'))
Assert-Check 'startinfo-outbound-canary-define' (
    ($start.ArgumentList -join ' ').Contains('OPENBUBBLES_CLOUD_SYNC_V2_OUTBOUND_CANARY=true'))
Assert-Check 'startinfo-native-library-bound' (
    $start.Environment['OPENBUBBLES_TEST_NATIVE_LIBRARY'] -ceq 'C:\native\rust_lib_bluebubbles.dll')
Assert-Check 'startinfo-launch-id-bound' (
    $start.Environment['OPENBUBBLES_LIVE_HARNESS_LAUNCH_ID'] -ceq 'abcdef0123456789abcdef0123456789')
Assert-Check 'startinfo-timeout-bound' (
    $start.Environment['OPENBUBBLES_HISTORICAL_IMPORT_TIMEOUT_SECONDS'] -ceq '600')
Assert-Check 'startinfo-request-digest-bound' (
    $start.Environment['OPENBUBBLES_HISTORICAL_IMPORT_REQUEST_SHA256'] -ceq ('c' * 64))
$savedConsent = $env:OPENBUBBLES_RUN_IMPORTED_HISTORICAL_LIVE
$savedRustLog = $env:RUST_LOG
try {
    $env:OPENBUBBLES_RUN_IMPORTED_HISTORICAL_LIVE = '1'
    $env:RUST_LOG = 'debug'
    $dirty = New-HistoricalLiveStartInfo `
        -Dart 'C:\dart.exe' `
        -FlutterToolsSnapshot 'C:\snapshot' `
        -Repository 'C:\repo' `
        -NativeLibrary 'C:\native\rust_lib_bluebubbles.dll' `
        -RuntimeDirectory 'C:\native' `
        -LaunchId 'abcdef0123456789abcdef0123456789' `
        -BuildIdentifier '94d5fd07c2b7' `
        -RequestSha256 ('c' * 64) `
        -TimeoutSeconds 600
    Assert-Check 'startinfo-cleans-ambient-openbubbles-env' (
        -not ($dirty.Environment.ContainsKey('OPENBUBBLES_RUN_IMPORTED_HISTORICAL_LIVE')) -and
        -not ($dirty.Environment.ContainsKey('RUST_LOG')))
 }
finally {
    $env:OPENBUBBLES_RUN_IMPORTED_HISTORICAL_LIVE = $savedConsent
    $env:RUST_LOG = $savedRustLog
}

Write-Host "historical-live-contract pass=$script:Pass fail=$script:Fail"
if ($script:Fail -ne 0) { exit 1 }


# End-to-end behavioral pins through a child process: the default
# invocation must print the inert banner and exit 0 (this catches the
# dot-sourced param-overwrite pitfall that once made it exit silent),
# while -EnableLive without consent must fail closed with its code.
$launcherPath = Join-Path $PSScriptRoot '../run_imported_cloud_sync_v2_historical_live.ps1'
$inertOut = & pwsh -NoProfile -ExecutionPolicy Bypass -File $launcherPath 2>&1 | Out-String
$inertCode = $LASTEXITCODE
Assert-Check 'default-invocation-inert-banner' (
    $inertCode -eq 0 -and $inertOut.Contains('HISTORICAL-LIVE-INERT'))
$gatedOut = & pwsh -NoProfile -ExecutionPolicy Bypass -File $launcherPath -EnableLive 2>&1 | Out-String
$gatedCode = $LASTEXITCODE
Assert-Check 'live-without-consent-fails-closed' (
    $gatedCode -ne 0 -and $gatedOut.Contains('historical_live_explicit_enable_required'))

Write-Host "historical-live-behavioral pass=$script:Pass fail=$script:Fail"
if ($script:Fail -ne 0) { exit 1 }

# Verify the actual receipt contract with synthetic files. Only PE/signature
# probes are stubbed; the receipt, hashes and variant checks execute unchanged.
& {
    $fixture = [IO.Directory]::CreateTempSubdirectory('ob-historical-runtime-').FullName
    try {
        foreach ($name in @('bluebubbles_app.exe', 'rust_lib_bluebubbles.dll', 'objectbox.dll')) {
            Set-Content -LiteralPath (Join-Path $fixture $name) -Value ('synthetic-' + $name)
        }
        $vendorPin = (Get-FileHash -LiteralPath (Join-Path $fixture 'objectbox.dll')).Hash.ToLowerInvariant()
        $runnerHash = (Get-FileHash -LiteralPath (Join-Path $fixture 'bluebubbles_app.exe')).Hash.ToLowerInvariant()
        $nativeHash = (Get-FileHash -LiteralPath (Join-Path $fixture 'rust_lib_bluebubbles.dll')).Hash.ToLowerInvariant()
        $signatureValid = $true
        $peMachine = 0xAA64
        function Get-StandaloneObjectBoxPin { return $vendorPin }
        function Get-StandalonePeMachine { return $peMachine }
        function Get-AuthenticodeSignature {
            [pscustomobject]@{
                Status = $(if ($signatureValid) { 'Valid' } else { 'NotSigned' })
                SignerCertificate = [pscustomobject]@{ Thumbprint = 'd' * 40 }
            }
        }
        $receiptPath = Join-Path $fixture 'receipt.json'
        $receipt = [ordered]@{
            version = 'cloud-sync-v2-windows-harness-build-v1'
            build_identifier = ('a' * 12) + '-local-write'
            runner_sha256 = $runnerHash
            rust_library_sha256 = $nativeHash
            origin = [ordered]@{
                source_commit = 'a' * 40
                pilot_commit = 'b' * 40
                archive_sha256 = 'c' * 64
                provenance_sha256 = 'e' * 64
                artifact_mode = 'harness'
                variant = 'local-write'
                runner_post_sign_sha256 = $runnerHash
                rust_library_post_sign_sha256 = $nativeHash
            }
        }
        $original = $receipt | ConvertTo-Json -Depth 5
        Set-Content -LiteralPath $receiptPath -Value $original
        $arguments = @{
            Directory = $fixture; ReceiptPath = $receiptPath
            NativeSource = 'a' * 40; Pilot = 'b' * 40; Archive = 'c' * 64
            Provenance = 'e' * 64; Signer = 'd' * 40
        }
        $qualified = Assert-HistoricalLocalWriteRuntime @arguments
        Assert-Check 'local-write-receipt-executes-full-verification' ($qualified.NativeSha256 -ceq $nativeHash)
        foreach ($field in @('source_commit', 'pilot_commit', 'archive_sha256',
                'provenance_sha256', 'artifact_mode', 'variant',
                'runner_post_sign_sha256', 'rust_library_post_sign_sha256')) {
            $changed = $original | ConvertFrom-Json
            $changed.origin.$field = 'wrong'
            $changed | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $receiptPath
            Assert-Fails "receipt-$field-mismatch-blocked" {
                Assert-HistoricalLocalWriteRuntime @arguments
            } 'historical_live_receipt_rejected'
        }
        Set-Content -LiteralPath $receiptPath -Value $original
        $signatureValid = $false
        Assert-Fails 'unsigned-native-blocked' {
            Assert-HistoricalLocalWriteRuntime @arguments
        } 'historical_live_runtime_signature_rejected'
        $signatureValid = $true
        $peMachine = 0x8664
        Assert-Fails 'wrong-architecture-blocked' {
            Assert-HistoricalLocalWriteRuntime @arguments
        } 'historical_live_runtime_architecture_rejected'
        $peMachine = 0xAA64
        Add-Content -LiteralPath (Join-Path $fixture 'objectbox.dll') -Value 'changed'
        Assert-Fails 'vendor-dll-change-blocked' {
            Assert-HistoricalLocalWriteRuntime @arguments
        } 'historical_live_objectbox_pin_rejected'
        Add-Content -LiteralPath (Join-Path $fixture 'rust_lib_bluebubbles.dll') -Value 'changed'
        Assert-Fails 'native-dll-change-blocked' {
            Assert-HistoricalLocalWriteRuntime @arguments
        } 'historical_live_receipt_rejected'
    }
    finally {
        if ([IO.Path]::GetFullPath($fixture).StartsWith(
                [IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $fixture -Recurse -Force
        } else { throw 'synthetic_fixture_cleanup_target_rejected' }
    }
}

# Compose the live branch with synthetic profile/tool files and a stub process
# boundary. No Apple initialization occurs. This catches unreachable live bodies,
# incorrect native-vs-Dart source binding, request replacement and false evidence.
& {
    $fixture = [IO.Directory]::CreateTempSubdirectory('ob-historical-workflow-').FullName
    $previousConsent = $env:OPENBUBBLES_RUN_IMPORTED_HISTORICAL_LIVE
    $previousAcknowledgement = $env:OPENBUBBLES_ACKNOWLEDGE_LOCAL_PERSONAL_DATA
    try {
        $env:OPENBUBBLES_RUN_IMPORTED_HISTORICAL_LIVE = '1'
        $env:OPENBUBBLES_ACKNOWLEDGE_LOCAL_PERSONAL_DATA = '1'
        foreach ($leaf in @('bin/cache/dart-sdk/bin/dart.exe',
                'bin/cache/artifacts/engine/windows-arm64/flutter_tester.exe',
                'bin/cache/flutter_tools.snapshot')) {
            $file = Join-Path $fixture $leaf
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force
            Set-Content -LiteralPath $file -Value 'synthetic'
        }
        $requestPath = Join-Path $fixture 'windows-historical-import-request.json'
        $request = @{version=1; action='preview'; maximumAssessed=1; maximumCreates=1}
        $request | ConvertTo-Json | Set-Content -LiteralPath $requestPath
        $invocation = @{}
        foreach ($key in $script:HistoricalLiveInvocation.Keys) {
            $invocation[$key] = $script:HistoricalLiveInvocation[$key]
        }
        $invocation.EnableLive = $true
        $invocation.Repository = $fixture
        $invocation.ProfileRoot = $fixture
        $invocation.FlutterRoot = $fixture
        $invocation.RunnerDirectory = $fixture
        $invocation.ExpectedSourceSha = 'f' * 40
        $invocation.ExpectedNativeSourceSha = 'a' * 40
        $seen = @{calls=0; locked=$false; release=0; disposed=0; mismatch=$false; fail=$false}
        function Assert-DartApplierRepository { param($Path, $ExpectedSource) return $Path }
        function Assert-DartApplierNativeCompatibility {
            param($Path, $DartSource, $NativeSource)
            $seen.mismatch = $DartSource -ceq ('f' * 40) -and $NativeSource -ceq ('a' * 40)
        }
        function Resolve-StandaloneProfile { param($Candidate) return $Candidate }
        function Enter-StandaloneProfileLock {
            $lock = [pscustomobject]@{ counters = $seen }
            $lock | Add-Member ScriptMethod ReleaseMutex { $this.counters.release++ }
            $lock | Add-Member ScriptMethod Dispose { $this.counters.disposed++ }
            return $lock
        }
        function Assert-StandaloneNoProfileOwner {}
        function Import-VerifiedWindowsCloudHarness { throw 'must-not-import-during-live-loop' }
        function Assert-HistoricalLocalWriteRuntime {
            param($Directory, $ReceiptPath, $NativeSource, $Pilot, $Archive, $Provenance, $Signer)
            if ($NativeSource -cne ('a' * 40)) { throw 'native-source-substituted' }
            [pscustomobject]@{
                Directory=$fixture; NativeLibrary=(Join-Path $fixture 'native.dll')
                NativeSha256='a' * 64; ObjectBoxSha256='b' * 64; ReceiptSha256='c' * 64
            }
        }
        function Invoke-HistoricalLivePass {
            param($Repository, $Profile, $Dart, $Tester, $FlutterToolsSnapshot,
                $NativeLibrary, $RuntimeDirectory, $LaunchId, $BuildIdentifier,
                $RequestSha256, $ExpectedAction, $EvidenceDirectory,
                $TimeoutSeconds, $AllowedExecutables)
            $seen.calls++
            Assert-Check 'live-call-bound-to-request-bytes' ($RequestSha256 -ceq
                (Get-FileHash -LiteralPath $requestPath).Hash.ToLowerInvariant())
            $writer = $null
            try { $writer = [IO.File]::Open($requestPath, 'Open', 'Write', 'ReadWrite') }
            catch [IO.IOException] { $seen.locked = $true }
            finally { if ($null -ne $writer) { $writer.Dispose() } }
            if ($seen.fail) { throw 'synthetic-process-failure' }
            return [pscustomobject]@{
                state='finished'; stage='historical-import-pass-complete'; launch_id=$LaunchId
                detail=(@{ action=$ExpectedAction; scan_complete=$false;
                    confirmed_creates_this_session=0 } | ConvertTo-Json -Compress)
            }
        }
        Invoke-HistoricalLiveWorkflow -Invocation $invocation
        Assert-Check 'matching-runtime-reaches-exactly-one-pass' ($seen.calls -eq 1)
        Assert-Check 'later-dart-uses-qualified-native-source' $seen.mismatch
        Assert-Check 'request-locked-through-process' $seen.locked
        Assert-Check 'profile-lock-released' ($seen.release -eq 1 -and $seen.disposed -eq 1)
        $previewEvidence = Get-ChildItem -LiteralPath (Join-Path $fixture 'cloud-sync-v2/diagnostics/historical-live') -Filter qualification.json -Recurse |
            ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json }
        Assert-Check 'preview-evidence-read-only' (-not $previewEvidence.remote_writes_enabled)
        $request.action = 'archive'
        $request | ConvertTo-Json | Set-Content -LiteralPath $requestPath
        Invoke-HistoricalLiveWorkflow -Invocation $invocation
        $archiveEvidence = @(Get-ChildItem -LiteralPath (Join-Path $fixture 'cloud-sync-v2/diagnostics/historical-live') -Filter qualification.json -Recurse |
            ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } |
            Where-Object request_action -CEQ 'archive')
        Assert-Check 'archive-evidence-honest-about-writes' ($archiveEvidence.Count -eq 1 -and
            $archiveEvidence[0].remote_writes_enabled -and -not $archiveEvidence[0].automatic_uploads_enabled)
        $seen.fail = $true
        Assert-Fails 'process-failure-retained' {
            Invoke-HistoricalLiveWorkflow -Invocation $invocation
        } 'synthetic-process-failure'
        Assert-Check 'profile-lock-released-after-failure' ($seen.release -eq 3 -and $seen.disposed -eq 3)
        $writer = [IO.File]::Open($requestPath, 'Open', 'Write', 'ReadWrite')
        $writer.Dispose()
        Assert-Check 'request-preserved-and-unlocked-after-failure' (Test-Path -LiteralPath $requestPath -PathType Leaf)
    }
    finally {
        $env:OPENBUBBLES_RUN_IMPORTED_HISTORICAL_LIVE = $previousConsent
        $env:OPENBUBBLES_ACKNOWLEDGE_LOCAL_PERSONAL_DATA = $previousAcknowledgement
        if ([IO.Path]::GetFullPath($fixture).StartsWith(
                [IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $fixture -Recurse -Force
        } else { throw 'synthetic_fixture_cleanup_target_rejected' }
    }
}
Write-Host "historical-live-integrated pass=$script:Pass fail=$script:Fail"
if ($script:Fail -ne 0) { exit 1 }
