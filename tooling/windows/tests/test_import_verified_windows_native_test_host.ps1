$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Synthetic contract for the provenance-safe native-test-host import seam.
# Temporary directories plus function mocks only. The only real host touches
# are a redirected per-process APPDATA profile, the profile-scoped launcher
# mutex name, and read-only git/process snapshots. Never uses real
# credentials, real archives, or network access.
$Importer = Join-Path $PSScriptRoot '../import_verified_windows_native_test_host.ps1'
. $Importer -FunctionsOnlyForTest

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$RealAppData = $env:APPDATA
$TempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$Scratch = Join-Path $TempRoot ('native-test-host-contract-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Scratch | Out-Null
$script:TrackedFiles = New-Object System.Collections.Generic.List[string]
$script:TrackedDirs = New-Object System.Collections.Generic.List[string]
$script:TrackedDirs.Add($Scratch)
$script:Pass = 0
$script:FailCount = 0

function Assert-UnderScratch {
    param([Parameter(Mandatory)][string] $Path)
    $full = [IO.Path]::GetFullPath($Path)
    $sep = [IO.Path]::DirectorySeparatorChar
    $prefix = $Scratch + $sep
    if (($full -ne $Scratch) -and (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase))) { throw "path escapes scratch: $Path" }
}

function Register-RunFile {
    param([Parameter(Mandatory)][string] $Path)
    Assert-UnderScratch -Path $Path
    $script:TrackedFiles.Add($Path)
}

function Register-RunDir {
    param([Parameter(Mandatory)][string] $Path)
    Assert-UnderScratch -Path $Path
    $script:TrackedDirs.Add($Path)
}

function Remove-RunTree {
    $removedF = 0
    $removedD = 0
    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($fp in @($script:TrackedFiles)) {
        try {
            Assert-UnderScratch -Path $fp
            if (Test-Path -LiteralPath $fp -PathType Leaf) { Remove-Item -LiteralPath $fp -Force; $removedF++ }
        } catch { $kept.Add($fp + ' (skip)') }
    }
    $ordered = @($script:TrackedDirs | Sort-Object { $_.Length } -Descending)
    foreach ($dp in $ordered) {
        try {
            Assert-UnderScratch -Path $dp
            $item = Get-Item -LiteralPath $dp -ErrorAction SilentlyContinue
            if ($null -eq $item) { continue }
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { $kept.Add($dp + ' (reparse point)'); continue }
            if (($item.Attributes -band [System.IO.FileAttributes]::Directory) -eq 0) { $kept.Add($dp + ' (not a dir)'); continue }
            $kids = @(Get-ChildItem -LiteralPath $dp -Force -ErrorAction SilentlyContinue)
            if ($kids.Count -eq 0) { Remove-Item -LiteralPath $dp -Force; $removedD++ }
            else { $kept.Add($dp + ' (non-empty, ' + $kids.Count + ' entries)') }
        } catch { $kept.Add($dp + ' (skip)') }
    }
    Write-Host ("CLEANUP removed-files={0} removed-dirs={1} kept={2}" -f $removedF, $removedD, $kept.Count)
    foreach ($k in $kept) { Write-Host "CLEANUP-KEEP $k" }
}

$script:MockHead = ''
$script:MockClean = $true
$script:BlockHits = @()
$script:SigStore = @{}
$script:SignCalls = New-Object System.Collections.Generic.List[string]
$script:SignShouldThrow = $false
$script:MockThumbprint = ''
$script:ObjectBoxPinCalls = New-Object System.Collections.Generic.List[string]
$script:MockObjectBoxPin = ''
$script:HarnessObjectBoxCalls = New-Object System.Collections.Generic.List[string]

$script:RealCheckoutState = (Get-Item Function:/Get-NativeTestHostCheckoutState).ScriptBlock
$script:RealObjectBoxPin = (Get-Item Function:/Get-NativeTestHostObjectBoxPin).ScriptBlock
$script:RealObjectBoxPinCheck = (Get-Item Function:/Assert-NativeTestHostObjectBoxPin).ScriptBlock
$script:RealHarnessObjectBoxCheck = (Get-Item Function:/Assert-HarnessObjectBoxRuntime).ScriptBlock
$script:RealProfileResolver = (Get-Item Function:/Resolve-NativeTestHostProfileRoot).ScriptBlock
$script:RealBlockingList = (Get-Item Function:/Get-NativeTestHostBlockingProcess).ScriptBlock

function Get-NativeTestHostCheckoutState {
    param([Parameter(Mandatory)][string] $Repository)
    return [pscustomobject]@{ Head = $script:MockHead; Clean = $script:MockClean; DirtyLines = @() }
}

function Get-NativeTestHostBlockingProcess {
    return @($script:BlockHits)
}

function Get-NativeTestHostSignatureState {
    param([Parameter(Mandatory)][string] $Path)
    $mode = 'Valid'
    if ($script:SigStore.ContainsKey($Path)) { $mode = $script:SigStore[$Path] }
    $status = [System.Management.Automation.SignatureStatus]::Valid
    if ($mode -cne 'Valid') { $status = [System.Management.Automation.SignatureStatus]::NotSigned }
    return [pscustomobject]@{ Status = $status; SignerCertificate = [pscustomobject]@{ Thumbprint = $script:MockThumbprint } }
}

function Invoke-NativeTestHostSignBinary {
    param([Parameter(Mandatory)][string] $Binary, [Parameter(Mandatory)][string] $SignToolPath, [Parameter(Mandatory)][string] $Thumbprint)
    $script:SignCalls.Add($Binary)
    if ($script:SignShouldThrow) { throw 'IMPORT-FAIL: mock signtool failed' }
    $script:SigStore[$Binary] = 'Valid'
}

function Assert-NativeTestHostObjectBoxPin {
    param([Parameter(Mandatory)][string] $Path)
    $script:ObjectBoxPinCalls.Add($Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'IMPORT-FAIL: mock objectbox missing' }
}

function Get-NativeTestHostObjectBoxPin {
    return $script:MockObjectBoxPin
}

function Assert-HarnessObjectBoxRuntime {
    param([Parameter(Mandatory)][string] $RunnerDirectory)
    $script:HarnessObjectBoxCalls.Add($RunnerDirectory)
}

function Reset-Mocks {
    $script:MockClean = $true
    $script:BlockHits = @()
    $script:SigStore = @{}
    $script:SignCalls = New-Object System.Collections.Generic.List[string]
    $script:SignShouldThrow = $false
    $script:ObjectBoxPinCalls = New-Object System.Collections.Generic.List[string]
    $script:HarnessObjectBoxCalls = New-Object System.Collections.Generic.List[string]
}

function New-PeHeaderBytes {
    param([Parameter(Mandatory)][uint16] $Machine)
    $b = New-Object byte[] 160
    $b[0] = 0x4D
    $b[1] = 0x5A
    $lfanew = 128
    [Array]::Copy([BitConverter]::GetBytes($lfanew), 0, $b, 0x3C, 4)
    $b[$lfanew] = 0x50
    $b[$lfanew+1] = 0x45
    [Array]::Copy([BitConverter]::GetBytes($Machine), 0, $b, $lfanew + 4, 2)
    return $b
}

function New-NativeTestHostFixture {
    param([Parameter(Mandatory)][string] $Tag, [uint16] $Machine = 0xAA64, [string] $Variant = 'read-only', [switch] $ExtraFile, [string] $Src = '', [string] $Pilot = '')
    $dir = Join-Path $Scratch $Tag
    Assert-UnderScratch -Path $dir
    if (Test-Path -LiteralPath $dir) { throw "fixture dir exists: $dir" }
    New-Item -ItemType Directory -Path $dir | Out-Null
    Register-RunDir $dir
    if ([string]::IsNullOrWhiteSpace($Src)) { $Src = 'dddddddddddddddddddddddddddddddddddddddd' }
    if ([string]::IsNullOrWhiteSpace($Pilot)) { $Pilot = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' }
    $zipPath = Join-Path $dir 'native.zip'
    $exeBytes = (New-PeHeaderBytes -Machine $Machine) + [Text.Encoding]::UTF8.GetBytes('native-compose-tests-' + $Tag)
    $obBytes = (New-PeHeaderBytes -Machine $Machine) + [Text.Encoding]::UTF8.GetBytes('objectbox-' + $Tag)
    $rustBytes = (New-PeHeaderBytes -Machine $Machine) + [Text.Encoding]::UTF8.GetBytes('rust-' + $Tag)
    $fs = [IO.File]::Create($zipPath)
    try {
        $zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($pair in @(@{ N = 'native-compose-tests.exe'; B = $exeBytes }, @{ N = 'objectbox.dll'; B = $obBytes }, @{ N = 'rust_lib_bluebubbles.dll'; B = $rustBytes })) {
                $entry = $zip.CreateEntry($pair.N)
                $stream = $entry.Open()
                try { $stream.Write($pair.B, 0, $pair.B.Length) } finally { $stream.Dispose() }
            }
            if ($ExtraFile) {
                $extra = [Text.Encoding]::UTF8.GetBytes('extra-' + $Tag)
                $entry = $zip.CreateEntry('notes.txt')
                $stream = $entry.Open()
                try { $stream.Write($extra, 0, $extra.Length) } finally { $stream.Dispose() }
            }
        } finally { $zip.Dispose() }
    } finally { $fs.Dispose() }
    $hashOf = { param($bytes) (Get-FileHash -InputStream ([IO.MemoryStream]::new($bytes)) -Algorithm SHA256).Hash.ToLowerInvariant() }
    $manifest = @(
        [ordered]@{ relative_path = 'native-compose-tests.exe'; size_bytes = $exeBytes.Length; sha256 = (& $hashOf $exeBytes); pe_machine = 'ARM64' },
        [ordered]@{ relative_path = 'objectbox.dll'; size_bytes = $obBytes.Length; sha256 = (& $hashOf $obBytes); pe_machine = 'ARM64' },
        [ordered]@{ relative_path = 'rust_lib_bluebubbles.dll'; size_bytes = $rustBytes.Length; sha256 = (& $hashOf $rustBytes); pe_machine = 'ARM64' }
    )
    if ($ExtraFile) {
        $extra = [Text.Encoding]::UTF8.GetBytes('extra-' + $Tag)
        $manifest += [ordered]@{ relative_path = 'notes.txt'; size_bytes = $extra.Length; sha256 = (& $hashOf $extra); pe_machine = $null }
    }
    $bid = $null
    $writer = $false
    if ($Variant -cne 'read-only') { $writer = $true }
    $prov = [ordered]@{
        schema_version = 2
        purpose = 'windows-cloudkit-fast-loop-native-test-host'
        source_commit = $Src
        source_tree = 'ffffffffffffffffffffffffffffffffffffffff'
        submodule_commits = @(' eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee rustpush')
        sidecar_commit = $Pilot
        build = [ordered]@{
            target = 'rust/Cargo.toml --lib; flutter test'; artifact_mode = 'native-test-host'
            configuration = 'debug'; architecture = 'arm64'; variant = $Variant; build_identifier = $bid
            native_media_graph_excluded = $true; signing_applied = $false
            findmy_value_free_diagnostics_compiled = $true; writer_defines_present = $writer
            automatic_send_runtime_present = $false
        }
        verification = [ordered]@{
            powershell_contract_tests = 'passed'; focused_dart_tests = 'passed'
            all_pe_files_arm64 = $true; rust_bridge_load_unload = 'passed'
            native_timestamp_compose_tests = 'passed'; native_timestamp_compose_expected_count = 7
            native_content_free_diagnostic_tests = [ordered]@{ result = 'passed'; expected_names = 1..5 | ForEach-Object { "diagnostic-$_" }; expected_test_count = 5; executable = 'bundle/native-compose-tests.exe' }
            native_read_discovery_tests = [ordered]@{ result = 'passed'; expected_names = @('discovery-1', 'discovery-2'); expected_test_count = 2; executable = 'bundle/native-compose-tests.exe' }
            native_extension_payload_tests = [ordered]@{ result = 'passed'; scope = 'cloud_sync_extension_payload::tests::'; minimum_passed = 29; spot_names = @('extension-spot'); executable = 'bundle/native-compose-tests.exe' }
            native_canonical_converter_tests = [ordered]@{ result = 'passed'; scope = 'cloud_sync_canonical_converter::tests::'; minimum_passed = 81; spot_names = @('converter-spot'); executable = 'bundle/native-compose-tests.exe' }
            native_canonical_dto_tests = [ordered]@{ result = 'passed'; scope = 'cloud_sync_canonical_dto::tests::'; minimum_passed = 24; spot_names = @('dto-spot'); executable = 'bundle/native-compose-tests.exe' }
            native_repair_digest_test = [ordered]@{ result = 'passed'; expected_names = @('repair-1', 'repair-2'); executable = 'bundle/native-compose-tests.exe' }
            native_system_event_tests = [ordered]@{ result = 'passed'; expected_names = 1..5 | ForEach-Object { "system-$_" }; expected_test_count = 5; executable = 'bundle/native-compose-tests.exe' }
            native_local_write_encoder_tests = [ordered]@{ result = 'passed'; native_library = 'bundle/rust_lib_bluebubbles.dll'; expected_test_count = 51; full_file_run = $true }
            invalid_launch_diagnostic = [ordered]@{ proof_status = 'not-run-no-gui-assembly' }
            account_profile_or_database_in_bundle = $false
        }
        qualification = [ordered]@{
            cloud_artifact_signing = 'not-applied'; local_policy_load = 'not-tested'; gui_assembly_receipt = 'not-issued'
            retained_native_base_reused = $false; live_cloudkit_tested = $false
        }
        source_inputs = @([ordered]@{ path = 'rust/src/lib.rs'; sha256 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' })
        files = $manifest
    }
    $provPath = Join-Path $dir 'provenance.json'
    ($prov | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $provPath -Encoding utf8
    Register-RunFile $zipPath
    Register-RunFile $provPath
    return @{ Zip = $zipPath; Prov = $provPath; ZipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant(); Src = $Src; Pilot = $Pilot; ExeBytes = $exeBytes; ObBytes = $obBytes; RustBytes = $rustBytes }
}
function New-TestAppDataProfile {
    param([Parameter(Mandatory)][string] $Tag)
    $root = Join-Path $Scratch $Tag
    Register-RunDir $root
    $profile = Join-Path $root 'OpenBubbles/cloudkit-v2-dev'
    New-Item -ItemType Directory -Path $profile -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $profile '.openbubbles-cloud-sync-v2-windows-dev') -Value 'openbubbles-cloud-sync-v2-windows-dev-profile:v1' -NoNewline
    return @{ AppData = $root; Profile = $profile }
}

function New-FakeSignTool {
    param([Parameter(Mandatory)][string] $Tag)
    $tool = Join-Path $Scratch $Tag
    Assert-UnderScratch -Path $tool
    Set-Content -LiteralPath $tool -Value 'fake-signtool' -Encoding ASCII
    Register-RunFile $tool
    return $tool
}

function New-TestRepo {
    param([Parameter(Mandatory)][string] $Tag)
    $repo = Join-Path $Scratch $Tag
    Assert-UnderScratch -Path $repo
    if (Test-Path -LiteralPath $repo) { throw "test repo exists: $repo" }
    New-Item -ItemType Directory -Path $repo | Out-Null
    Register-RunDir $repo
    return $repo
}

function Assert-ImportFails {
    param([Parameter(Mandatory)][scriptblock] $Body, [Parameter(Mandatory)][string] $Name)
    try {
        & $Body | Out-Null
        Write-Host "FAIL $Name (no throw)"
        $script:FailCount++
    }
    catch {
        if ("$_" -like '*IMPORT-FAIL*') { Write-Host "PASS $Name"; $script:Pass++ }
        else { Write-Host "FAIL $Name (wrong error: $_)"; $script:FailCount++ }
    }
}

function Get-TestHostLeafHashes {
    param([Parameter(Mandatory)][string] $Dir)
    $out = @{}
    foreach ($leaf in @('native-compose-tests.exe', 'rust_lib_bluebubbles.dll', 'objectbox.dll')) {
        $p = Join-Path $Dir $leaf
        if (Test-Path -LiteralPath $p -PathType Leaf) { $out[$leaf] = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    return $out
}

try {
$Thumb = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
$realMarkerBaselinePath = Join-Path $RealAppData 'OpenBubbles/cloudkit-v2-dev/.openbubbles-cloud-sync-v2-windows-dev'
$realMarkerBaselineHash = ''
if (Test-Path -LiteralPath $realMarkerBaselinePath -PathType Leaf) { $realMarkerBaselineHash = (Get-FileHash -LiteralPath $realMarkerBaselinePath -Algorithm SHA256).Hash }
$fakeSignTool = New-FakeSignTool -Tag 'fake-signtool.exe'

# 0. Direct entrypoint executes (guards dot-sourced param overwrite no-op).
$epDir = Join-Path $Scratch 'entrypoint'
New-Item -ItemType Directory -Path $epDir | Out-Null
Register-RunDir $epDir
$entrypointOutput = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File $Importer -ArchivePath (Join-Path $epDir 'missing.zip') -ProvenancePath (Join-Path $epDir 'missing.json') -ExpectedArchiveSha256 ('0' * 64) -ExpectedSourceSha ('0' * 40) -ExpectedPilotSha ('0' * 40) -ExpectedSignerThumbprint $Thumb -Repository $Scratch -ReceiptPath (Join-Path $epDir 'receipt.json') -SignTool $fakeSignTool 2>&1 | Out-String
$entrypointExitCode = $LASTEXITCODE
if (($entrypointExitCode -ne 0) -and ($entrypointOutput -like '*IMPORT-FAIL*')) { Write-Host 'PASS direct-entrypoint-executes'; $script:Pass++ }
else { Write-Host ("FAIL direct-entrypoint-executes (exit={0}, output={1})" -f $entrypointExitCode, $entrypointOutput.Trim()); $script:FailCount++ }

# 1. Success-positive: fresh install, unsigned exe gets signed, objectbox untouched.
$f = New-NativeTestHostFixture -Tag 'success'
$script:MockObjectBoxPin = (Get-FileHash -InputStream ([IO.MemoryStream]::new($f.ObBytes)) -Algorithm SHA256).Hash.ToLowerInvariant()
Reset-Mocks
$script:MockHead = $f.Src
$script:MockThumbprint = $Thumb
$app = New-TestAppDataProfile -Tag 'appdata-success'
$env:APPDATA = $app.AppData
$repo = New-TestRepo -Tag 't-success-repo'
$runner = Join-Path $app.Profile 'cloud-sync-v2/native-test-host'
$receipt = Join-Path $runner 'native-test-host-receipt.json'
$exeInstalled = Join-Path $runner 'native-compose-tests.exe'
$rustInstalled = Join-Path $runner 'rust_lib_bluebubbles.dll'
$obInstalled = Join-Path $runner 'objectbox.dll'
$script:SigStore[$exeInstalled] = 'NotSigned'
$script:SigStore[$rustInstalled] = 'Valid'
try {
    $archiveBefore = Get-FileHash -LiteralPath $f.Zip -Algorithm SHA256
    $provBefore = Get-FileHash -LiteralPath $f.Prov -Algorithm SHA256
    Assert-ImportFails -Name 'explicit-diagnostic-count-forwarded' -Body {
        Import-VerifiedWindowsNativeTestHost -ArchivePath $f.Zip -ProvenancePath $f.Prov -ExpectedArchiveSha256 $f.ZipHash -ExpectedSourceSha $f.Src -ExpectedPilotSha $f.Pilot -ExpectedSignerThumbprint $Thumb -Repository $repo -SignTool $fakeSignTool -ExpectedNativeDiagnosticTestCount 13
    }
    $result = Import-VerifiedWindowsNativeTestHost -ArchivePath $f.Zip -ProvenancePath $f.Prov -ExpectedArchiveSha256 $f.ZipHash -ExpectedSourceSha $f.Src -ExpectedPilotSha $f.Pilot -ExpectedSignerThumbprint $Thumb -Repository $repo -SignTool $fakeSignTool
    $ok = $true
    if ($result.TestHostDirectory -cne $runner) { Write-Host 'FAIL success-positive (test-host dir)'; $ok = $false }
    $exeHash = (Get-FileHash -LiteralPath $exeInstalled -Algorithm SHA256).Hash.ToLowerInvariant()
    $rustHash = (Get-FileHash -LiteralPath $rustInstalled -Algorithm SHA256).Hash.ToLowerInvariant()
    $obHash = (Get-FileHash -LiteralPath $obInstalled -Algorithm SHA256).Hash.ToLowerInvariant()
    $wantExe = (Get-FileHash -InputStream ([IO.MemoryStream]::new($f.ExeBytes)) -Algorithm SHA256).Hash.ToLowerInvariant()
    $wantRust = (Get-FileHash -InputStream ([IO.MemoryStream]::new($f.RustBytes)) -Algorithm SHA256).Hash.ToLowerInvariant()
    $wantOb = (Get-FileHash -InputStream ([IO.MemoryStream]::new($f.ObBytes)) -Algorithm SHA256).Hash.ToLowerInvariant()
    if (($exeHash -cne $wantExe) -or ($rustHash -cne $wantRust) -or ($obHash -cne $wantOb)) { Write-Host 'FAIL success-positive (installed bytes)'; $ok = $false }
    if ($script:SignCalls -notcontains $exeInstalled) { Write-Host 'FAIL success-positive (unsigned exe was not signed)'; $ok = $false }
    if ($script:SignCalls -contains $rustInstalled) { Write-Host 'FAIL success-positive (valid rust was re-signed)'; $ok = $false }
    if ($script:SignCalls -contains $obInstalled) { Write-Host 'FAIL success-positive (objectbox was signed)'; $ok = $false }
    if ($script:ObjectBoxPinCalls.Count -lt 2) { Write-Host 'FAIL success-positive (objectbox pin not checked staged and installed)'; $ok = $false }
    if ($script:HarnessObjectBoxCalls.Count -lt 1) { Write-Host 'FAIL success-positive (harness objectbox runtime not checked)'; $ok = $false }
    if (-not (Test-NativeTestHostReceipt -ReceiptPath $receipt -TestHostDirectory $runner -SourceCommit $f.Src -PilotCommit $f.Pilot -ArchiveSha256 $f.ZipHash -ProvenanceSha256 $provBefore.Hash.ToLowerInvariant())) { Write-Host 'FAIL success-positive (receipt self-check)'; $ok = $false }
    $doc = Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json
    if (($doc.version -cne 'cloud-sync-v2-windows-native-test-host-v1') -or ($doc.artifact_mode -cne 'native-test-host') -or ($doc.variant -cne 'read-only')) { Write-Host 'FAIL success-positive (receipt header)'; $ok = $false }
    if (($doc.source_commit -cne $f.Src) -or ($doc.pilot_commit -cne $f.Pilot)) { Write-Host 'FAIL success-positive (receipt source/pilot)'; $ok = $false }
    if ($doc.archive_sha256 -cne $f.ZipHash) { Write-Host 'FAIL success-positive (receipt archive)'; $ok = $false }
    if ($doc.files.'objectbox.dll' -cne $obHash) { Write-Host 'FAIL success-positive (receipt objectbox)'; $ok = $false }
    if ($doc.signing_thumbprint -cne $Thumb) { Write-Host 'FAIL success-positive (receipt thumbprint)'; $ok = $false }
    if ((Get-FileHash -LiteralPath $f.Zip -Algorithm SHA256).Hash -cne $archiveBefore.Hash) { Write-Host 'FAIL success-positive (archive mutated)'; $ok = $false }
    if ((Get-FileHash -LiteralPath $f.Prov -Algorithm SHA256).Hash -cne $provBefore.Hash) { Write-Host 'FAIL success-positive (provenance mutated)'; $ok = $false }
    $leftovers = @(Get-ChildItem -LiteralPath (Split-Path -Parent $runner) -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '.native-test-host-stage-*' -or $_.Name -like '*.rollback-*' })
    if ($leftovers.Count -ne 0) { Write-Host 'FAIL success-positive (staging/rollback residue)'; $ok = $false }
    if ($ok) { Write-Host 'PASS success-positive'; $script:Pass++ } else { $script:FailCount++ }
}
catch { Write-Host "FAIL success-positive ($_)"; $script:FailCount++ }
finally { $env:APPDATA = $RealAppData }

# 2. Local-write variant is rejected before anything is installed.
$fw = New-NativeTestHostFixture -Tag 'writer' -Variant 'local-write'
Reset-Mocks
$script:MockHead = $fw.Src
$script:MockThumbprint = $Thumb
$app2 = New-TestAppDataProfile -Tag 'appdata-writer'
$env:APPDATA = $app2.AppData
try {
    $repo2 = New-TestRepo -Tag 't-writer-repo'
    $runner2 = Join-Path $app2.Profile 'cloud-sync-v2/native-test-host'
    $receipt2 = Join-Path $runner2 'native-test-host-receipt.json'
    Assert-ImportFails -Name 'local-write-variant-rejected' -Body { Import-VerifiedWindowsNativeTestHost -ArchivePath $fw.Zip -ProvenancePath $fw.Prov -ExpectedArchiveSha256 $fw.ZipHash -ExpectedSourceSha $fw.Src -ExpectedPilotSha $fw.Pilot -ExpectedSignerThumbprint $Thumb -Repository $repo2 -SignTool $fakeSignTool }
    if ((-not (Test-Path -LiteralPath $runner2)) -and (-not (Test-Path -LiteralPath $receipt2 -PathType Leaf))) { Write-Host 'PASS local-write-no-side-effects'; $script:Pass++ } else { Write-Host 'FAIL local-write-no-side-effects'; $script:FailCount++ }
}
finally { $env:APPDATA = $RealAppData }

# 3. Wrong source SHA is rejected (provenance binding + checkout gate).
Reset-Mocks
$script:MockHead = $f.Src
$script:MockThumbprint = $Thumb
$app3 = New-TestAppDataProfile -Tag 'appdata-wrongsrc'
$env:APPDATA = $app3.AppData
try {
    $repo3 = New-TestRepo -Tag 't-wrongsrc-repo'
    $runner3 = Join-Path $app3.Profile 'cloud-sync-v2/native-test-host'
    $receipt3 = Join-Path $runner3 'native-test-host-receipt.json'
    Assert-ImportFails -Name 'wrong-source-rejected' -Body { Import-VerifiedWindowsNativeTestHost -ArchivePath $f.Zip -ProvenancePath $f.Prov -ExpectedArchiveSha256 $f.ZipHash -ExpectedSourceSha 'cccccccccccccccccccccccccccccccccccccccc' -ExpectedPilotSha $f.Pilot -ExpectedSignerThumbprint $Thumb -Repository $repo3 -SignTool $fakeSignTool }
    if ((-not (Test-Path -LiteralPath $runner3)) -and (-not (Test-Path -LiteralPath $receipt3 -PathType Leaf))) { Write-Host 'PASS wrong-source-no-side-effects'; $script:Pass++ } else { Write-Host 'FAIL wrong-source-no-side-effects'; $script:FailCount++ }
}
finally { $env:APPDATA = $RealAppData }

# 4. Dirty checkout is rejected even when provenance matches.
Reset-Mocks
$script:MockHead = $f.Src
$script:MockClean = $false
$script:MockThumbprint = $Thumb
$app4 = New-TestAppDataProfile -Tag 'appdata-dirty'
$env:APPDATA = $app4.AppData
try {
    $repo4 = New-TestRepo -Tag 't-dirty-repo'
    $runner4 = Join-Path $app4.Profile 'cloud-sync-v2/native-test-host'
    Assert-ImportFails -Name 'dirty-checkout-rejected' -Body { Import-VerifiedWindowsNativeTestHost -ArchivePath $f.Zip -ProvenancePath $f.Prov -ExpectedArchiveSha256 $f.ZipHash -ExpectedSourceSha $f.Src -ExpectedPilotSha $f.Pilot -ExpectedSignerThumbprint $Thumb -Repository $repo4 -SignTool $fakeSignTool }
    if (-not (Test-Path -LiteralPath $runner4)) { Write-Host 'PASS dirty-no-side-effects'; $script:Pass++ } else { Write-Host 'FAIL dirty-no-side-effects'; $script:FailCount++ }
}
finally { $env:APPDATA = $RealAppData; $script:MockClean = $true }

# 5. Wrong archive hash is rejected before anything is installed.
Reset-Mocks
$script:MockHead = $f.Src
$script:MockThumbprint = $Thumb
$app5 = New-TestAppDataProfile -Tag 'appdata-wronghash'
$env:APPDATA = $app5.AppData
try {
    $repo5 = New-TestRepo -Tag 't-wronghash-repo'
    $runner5 = Join-Path $app5.Profile 'cloud-sync-v2/native-test-host'
    Assert-ImportFails -Name 'wrong-archive-hash-rejected' -Body { Import-VerifiedWindowsNativeTestHost -ArchivePath $f.Zip -ProvenancePath $f.Prov -ExpectedArchiveSha256 '0000000000000000000000000000000000000000000000000000000000000000' -ExpectedSourceSha $f.Src -ExpectedPilotSha $f.Pilot -ExpectedSignerThumbprint $Thumb -Repository $repo5 -SignTool $fakeSignTool }
    if (-not (Test-Path -LiteralPath $runner5)) { Write-Host 'PASS wrong-hash-no-side-effects'; $script:Pass++ } else { Write-Host 'FAIL wrong-hash-no-side-effects'; $script:FailCount++ }
}
finally { $env:APPDATA = $RealAppData }

# 6. Thumbprint mismatch rolls back the previous install and receipt exactly.
Reset-Mocks
$script:MockHead = $f.Src
$script:MockThumbprint = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
$app6 = New-TestAppDataProfile -Tag 'appdata-thumb'
$env:APPDATA = $app6.AppData
try {
    $repo6 = New-TestRepo -Tag 't-thumb-repo'
    $runner6 = Join-Path $app6.Profile 'cloud-sync-v2/native-test-host'
    New-Item -ItemType Directory -Path $runner6 -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $runner6 'native-compose-tests.exe') -Value 'old-exe' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $runner6 'rust_lib_bluebubbles.dll') -Value 'old-rust' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $runner6 'objectbox.dll') -Value 'old-objectbox' -Encoding ASCII
    $receipt6 = Join-Path $runner6 'native-test-host-receipt.json'
    Set-Content -LiteralPath $receipt6 -Value 'old-receipt' -Encoding ASCII
    Register-RunFile (Join-Path $runner6 'native-compose-tests.exe')
    Register-RunFile (Join-Path $runner6 'rust_lib_bluebubbles.dll')
    Register-RunFile (Join-Path $runner6 'objectbox.dll')
    Register-RunFile $receipt6
    Assert-ImportFails -Name 'thumbprint-mismatch-rolls-back' -Body { Import-VerifiedWindowsNativeTestHost -ArchivePath $f.Zip -ProvenancePath $f.Prov -ExpectedArchiveSha256 $f.ZipHash -ExpectedSourceSha $f.Src -ExpectedPilotSha $f.Pilot -ExpectedSignerThumbprint $Thumb -Repository $repo6 -SignTool $fakeSignTool }
    $restored = @((Get-Content -LiteralPath (Join-Path $runner6 'native-compose-tests.exe') -Raw), (Get-Content -LiteralPath (Join-Path $runner6 'rust_lib_bluebubbles.dll') -Raw), (Get-Content -LiteralPath (Join-Path $runner6 'objectbox.dll') -Raw), (Get-Content -LiteralPath $receipt6 -Raw)) -join '|'
    $residue = @(Get-ChildItem -LiteralPath (Split-Path -Parent $runner6) -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '.native-test-host-stage-*' -or $_.Name -like '*.rollback-*' })
    if (($restored -like '*old-exe*') -and ($restored -like '*old-rust*') -and ($restored -like '*old-objectbox*') -and ($restored -like '*old-receipt*') -and ($residue.Count -eq 0)) { Write-Host 'PASS thumbprint-rollback-exact'; $script:Pass++ } else { Write-Host 'FAIL thumbprint-rollback-exact'; $script:FailCount++ }
}
finally { $env:APPDATA = $RealAppData; $script:MockThumbprint = $Thumb }

# 7. A signtool failure after the atomic move restores the previous install.
Reset-Mocks
$script:MockHead = $f.Src
$script:MockThumbprint = $Thumb
$script:SignShouldThrow = $true
$app6b = New-TestAppDataProfile -Tag 'appdata-signfail'
$env:APPDATA = $app6b.AppData
try {
    $repo6b = New-TestRepo -Tag 't-signfail-repo'
    $runner6b = Join-Path $app6b.Profile 'cloud-sync-v2/native-test-host'
    New-Item -ItemType Directory -Path $runner6b -Force | Out-Null
    Register-RunDir $runner6b
    $old6b = [ordered]@{
        'native-compose-tests.exe' = 'old-signfail-exe'
        'rust_lib_bluebubbles.dll' = 'old-signfail-rust'
        'objectbox.dll' = 'old-signfail-objectbox'
        'native-test-host-receipt.json' = 'old-signfail-receipt'
    }
    foreach ($entry in $old6b.GetEnumerator()) {
        $path = Join-Path $runner6b $entry.Key
        Set-Content -LiteralPath $path -Value $entry.Value -Encoding ASCII
        Register-RunFile $path
    }
    $script:SigStore[(Join-Path $runner6b 'native-compose-tests.exe')] = 'NotSigned'
    $script:SigStore[(Join-Path $runner6b 'rust_lib_bluebubbles.dll')] = 'Valid'
    Assert-ImportFails -Name 'signtool-failure-rolls-back' -Body { Import-VerifiedWindowsNativeTestHost -ArchivePath $f.Zip -ProvenancePath $f.Prov -ExpectedArchiveSha256 $f.ZipHash -ExpectedSourceSha $f.Src -ExpectedPilotSha $f.Pilot -ExpectedSignerThumbprint $Thumb -Repository $repo6b -SignTool $fakeSignTool }
    $restored = $true
    foreach ($entry in $old6b.GetEnumerator()) {
        $path = Join-Path $runner6b $entry.Key
        if ((-not (Test-Path -LiteralPath $path -PathType Leaf)) -or ((Get-Content -LiteralPath $path -Raw) -notlike "*$($entry.Value)*")) { $restored = $false }
    }
    $residue = @(Get-ChildItem -LiteralPath (Split-Path -Parent $runner6b) -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '.native-test-host-stage-*' -or $_.Name -like '*.rollback-*' })
    if ($restored -and $residue.Count -eq 0) { Write-Host 'PASS signtool-rollback-exact'; $script:Pass++ } else { Write-Host 'FAIL signtool-rollback-exact'; $script:FailCount++ }
}
finally { $env:APPDATA = $RealAppData; $script:SignShouldThrow = $false }

# 8. Extra-file inventory is rejected with no side effects.
$fx = New-NativeTestHostFixture -Tag 'extra' -ExtraFile
Reset-Mocks
$script:MockHead = $fx.Src
$script:MockThumbprint = $Thumb
$app7 = New-TestAppDataProfile -Tag 'appdata-extra'
$env:APPDATA = $app7.AppData
try {
    $repo7 = New-TestRepo -Tag 't-extra-repo'
    $runner7 = Join-Path $app7.Profile 'cloud-sync-v2/native-test-host'
    Assert-ImportFails -Name 'extra-file-inventory-rejected' -Body { Import-VerifiedWindowsNativeTestHost -ArchivePath $fx.Zip -ProvenancePath $fx.Prov -ExpectedArchiveSha256 $fx.ZipHash -ExpectedSourceSha $fx.Src -ExpectedPilotSha $fx.Pilot -ExpectedSignerThumbprint $Thumb -Repository $repo7 -SignTool $fakeSignTool }
    if (-not (Test-Path -LiteralPath $runner7)) { Write-Host 'PASS extra-file-no-side-effects'; $script:Pass++ } else { Write-Host 'FAIL extra-file-no-side-effects'; $script:FailCount++ }
}
finally { $env:APPDATA = $RealAppData }

# 9. Non-ARM64 binaries are rejected.
$fx64 = New-NativeTestHostFixture -Tag 'x64' -Machine 0x8664
Reset-Mocks
$script:MockHead = $fx64.Src
$script:MockThumbprint = $Thumb
$app8 = New-TestAppDataProfile -Tag 'appdata-x64'
$env:APPDATA = $app8.AppData
try {
    $repo8 = New-TestRepo -Tag 't-x64-repo'
    $runner8 = Join-Path $app8.Profile 'cloud-sync-v2/native-test-host'
    Assert-ImportFails -Name 'non-arm64-rejected' -Body { Import-VerifiedWindowsNativeTestHost -ArchivePath $fx64.Zip -ProvenancePath $fx64.Prov -ExpectedArchiveSha256 $fx64.ZipHash -ExpectedSourceSha $fx64.Src -ExpectedPilotSha $fx64.Pilot -ExpectedSignerThumbprint $Thumb -Repository $repo8 -SignTool $fakeSignTool }
    if (-not (Test-Path -LiteralPath $runner8)) { Write-Host 'PASS x64-no-side-effects'; $script:Pass++ } else { Write-Host 'FAIL x64-no-side-effects'; $script:FailCount++ }
}
finally { $env:APPDATA = $RealAppData }
# 10. A blocking process aborts before any mutation.
Reset-Mocks
$script:MockHead = $f.Src
$script:MockThumbprint = $Thumb
$script:BlockHits = @('dart')
$app9 = New-TestAppDataProfile -Tag 'appdata-blocked'
$env:APPDATA = $app9.AppData
try {
    $repo9 = New-TestRepo -Tag 't-blocked-repo'
    $runner9 = Join-Path $app9.Profile 'cloud-sync-v2/native-test-host'
    Assert-ImportFails -Name 'blocking-process-rejected' -Body { Import-VerifiedWindowsNativeTestHost -ArchivePath $f.Zip -ProvenancePath $f.Prov -ExpectedArchiveSha256 $f.ZipHash -ExpectedSourceSha $f.Src -ExpectedPilotSha $f.Pilot -ExpectedSignerThumbprint $Thumb -Repository $repo9 -SignTool $fakeSignTool }
    if (-not (Test-Path -LiteralPath $runner9)) { Write-Host 'PASS blocked-no-side-effects'; $script:Pass++ } else { Write-Host 'FAIL blocked-no-side-effects'; $script:FailCount++ }
}
finally { $env:APPDATA = $RealAppData; $script:BlockHits = @() }

# 11. Unknown files in the test-host directory are refused, never snapshotted away.
Reset-Mocks
$script:MockHead = $f.Src
$script:MockThumbprint = $Thumb
$app10 = New-TestAppDataProfile -Tag 'appdata-unknown'
$env:APPDATA = $app10.AppData
try {
    $repo10 = New-TestRepo -Tag 't-unknown-repo'
    $runner10 = Join-Path $app10.Profile 'cloud-sync-v2/native-test-host'
    New-Item -ItemType Directory -Path $runner10 -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $runner10 'store.obx') -Value 'pretend-objectbox-store' -Encoding ASCII
    Register-RunFile (Join-Path $runner10 'store.obx')
    Assert-ImportFails -Name 'unknown-content-refused' -Body { Import-VerifiedWindowsNativeTestHost -ArchivePath $f.Zip -ProvenancePath $f.Prov -ExpectedArchiveSha256 $f.ZipHash -ExpectedSourceSha $f.Src -ExpectedPilotSha $f.Pilot -ExpectedSignerThumbprint $Thumb -Repository $repo10 -SignTool $fakeSignTool }
    if ((Get-Content -LiteralPath (Join-Path $runner10 'store.obx') -Raw) -like '*pretend-objectbox-store*') { Write-Host 'PASS unknown-content-preserved'; $script:Pass++ } else { Write-Host 'FAIL unknown-content-preserved'; $script:FailCount++ }
}
finally { $env:APPDATA = $RealAppData }
# __CHUNK_C2_END__
# 12. Protected profile targeting: siblings and other names are refused.
$app11 = New-TestAppDataProfile -Tag 'appdata-targeting'
$alphaDir = Join-Path (Split-Path -Parent $app11.Profile) 'Alpha'
$betaDir = Join-Path (Split-Path -Parent $app11.Profile) 'Beta'
New-Item -ItemType Directory -Path $alphaDir -Force | Out-Null
New-Item -ItemType Directory -Path $betaDir -Force | Out-Null
Register-RunDir $alphaDir
Register-RunDir $betaDir
Set-Content -LiteralPath (Join-Path $alphaDir '.openbubbles-cloud-sync-v2-windows-dev') -Value 'openbubbles-cloud-sync-v2-windows-dev-profile:v1' -NoNewline
Set-Content -LiteralPath (Join-Path $betaDir '.openbubbles-cloud-sync-v2-windows-dev') -Value 'openbubbles-cloud-sync-v2-windows-dev-profile:v1' -NoNewline
Register-RunFile (Join-Path $alphaDir '.openbubbles-cloud-sync-v2-windows-dev')
Register-RunFile (Join-Path $betaDir '.openbubbles-cloud-sync-v2-windows-dev')
try { & $script:RealProfileResolver -ProfileRoot $alphaDir -ApprovedBaseForTest $app11.Profile | Out-Null; Write-Host 'FAIL alpha-rejected (no throw)'; $script:FailCount++ }
catch { if ("$_" -like '*IMPORT-FAIL*') { Write-Host 'PASS alpha-rejected'; $script:Pass++ } else { Write-Host "FAIL alpha-rejected ($_)"; $script:FailCount++ } }
try { & $script:RealProfileResolver -ProfileRoot $betaDir -ApprovedBaseForTest $app11.Profile | Out-Null; Write-Host 'FAIL beta-rejected (no throw)'; $script:FailCount++ }
catch { if ("$_" -like '*IMPORT-FAIL*') { Write-Host 'PASS beta-rejected'; $script:Pass++ } else { Write-Host "FAIL beta-rejected ($_)"; $script:FailCount++ } }
$nestedDir = Join-Path $app11.Profile 'nested-evil'
New-Item -ItemType Directory -Path $nestedDir -Force | Out-Null
Register-RunDir $nestedDir
try { & $script:RealProfileResolver -ProfileRoot $nestedDir -ApprovedBaseForTest $app11.Profile | Out-Null; Write-Host 'FAIL nested-rejected (no throw)'; $script:FailCount++ }
catch { if ("$_" -like '*IMPORT-FAIL*') { Write-Host 'PASS nested-rejected'; $script:Pass++ } else { Write-Host "FAIL nested-rejected ($_)"; $script:FailCount++ } }
$noMarker = Join-Path $Scratch 'nomarker-profile'
New-Item -ItemType Directory -Path $noMarker -Force | Out-Null
Register-RunDir $noMarker
try { & $script:RealProfileResolver -ProfileRoot $noMarker -ApprovedBaseForTest $noMarker | Out-Null; Write-Host 'FAIL marker-required (no throw)'; $script:FailCount++ }
catch { if ("$_" -like '*IMPORT-FAIL*') { Write-Host 'PASS marker-required'; $script:Pass++ } else { Write-Host "FAIL marker-required ($_)"; $script:FailCount++ } }
try { $resolved = & $script:RealProfileResolver -ProfileRoot '' -ApprovedBaseForTest $app11.Profile; if ($resolved -cne $app11.Profile) { throw 'resolved to wrong profile' }; Write-Host 'PASS canonical-profile-resolves'; $script:Pass++ }
catch { Write-Host "FAIL canonical-profile-resolves ($_)"; $script:FailCount++ }
Reset-Mocks
$script:MockHead = $f.Src
$script:MockThumbprint = $Thumb
$env:APPDATA = $app11.AppData
try {
    $repo11 = New-TestRepo -Tag 't-targeting-repo'
    Assert-ImportFails -Name 'import-alpha-profile-rejected' -Body { Import-VerifiedWindowsNativeTestHost -ArchivePath $f.Zip -ProvenancePath $f.Prov -ExpectedArchiveSha256 $f.ZipHash -ExpectedSourceSha $f.Src -ExpectedPilotSha $f.Pilot -ExpectedSignerThumbprint $Thumb -Repository $repo11 -ProfileRoot $alphaDir -SignTool $fakeSignTool }
    if (-not (Test-Path -LiteralPath (Join-Path $alphaDir 'cloud-sync-v2/native-test-host') )) { Write-Host 'PASS alpha-untouched'; $script:Pass++ } else { Write-Host 'FAIL alpha-untouched'; $script:FailCount++ }
}
finally { $env:APPDATA = $RealAppData }

# 13. Profile data outside the test-host directory is never mutated.
Reset-Mocks
$script:MockHead = $f.Src
$script:MockThumbprint = $Thumb
$app12 = New-TestAppDataProfile -Tag 'appdata-nomut'
$decoys = @(
    @{ P = Join-Path $app12.Profile 'objectbox-data/store.mdb'; V = 'fake-objectbox-store' },
    @{ P = Join-Path $app12.Profile 'keychain.plist'; V = 'fake-keychain' },
    @{ P = Join-Path $app12.Profile 'cloudkit.plist'; V = 'fake-cloudkit' },
    @{ P = Join-Path $app12.Profile 'messages.db'; V = 'fake-messages' },
    @{ P = Join-Path $app12.Profile 'attachments/file.bin'; V = 'fake-attachments' }
)
foreach ($d in $decoys) {
    $parent = Split-Path -Parent $d.P
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Set-Content -LiteralPath $d.P -Value $d.V -Encoding ASCII
    Register-RunFile $d.P
}
$env:APPDATA = $app12.AppData
try {
    $before = @{}
    foreach ($d in $decoys) { $before[$d.P] = (Get-FileHash -LiteralPath $d.P -Algorithm SHA256).Hash }
    $repo12 = New-TestRepo -Tag 't-nomut-repo'
    $null = Import-VerifiedWindowsNativeTestHost -ArchivePath $f.Zip -ProvenancePath $f.Prov -ExpectedArchiveSha256 $f.ZipHash -ExpectedSourceSha $f.Src -ExpectedPilotSha $f.Pilot -ExpectedSignerThumbprint $Thumb -Repository $repo12 -SignTool $fakeSignTool
    $ok = $true
    foreach ($d in $decoys) {
        if ((Get-FileHash -LiteralPath $d.P -Algorithm SHA256).Hash -cne $before[$d.P]) { Write-Host ("FAIL no-mutation (changed: " + $d.P + ')'); $ok = $false }
    }
    $runner12 = Join-Path $app12.Profile 'cloud-sync-v2/native-test-host'
    $names = @(Get-ChildItem -LiteralPath $runner12 -File | ForEach-Object { $_.Name } | Sort-Object)
    $want = @('native-compose-tests.exe', 'native-test-host-receipt.json', 'objectbox.dll', 'rust_lib_bluebubbles.dll')
    if ((Compare-Object $names $want) -ne $null) { Write-Host 'FAIL no-mutation (test-host inventory)'; $ok = $false }
    if ($ok) { Write-Host 'PASS no-profile-data-mutation'; $script:Pass++ } else { $script:FailCount++ }
}
catch { Write-Host "FAIL no-profile-data-mutation ($_)"; $script:FailCount++ }
finally { $env:APPDATA = $RealAppData }
# __CHUNK_C3_END__
# 14. Blocked-process names cover every required family.
$names = @(Get-NativeTestHostBlockedProcessNames)
$missing = @(@('bluebubbles_app', 'flutter', 'dart', 'native-compose-tests') | Where-Object { $names -cnotcontains $_ })
if ($missing.Count -eq 0) { Write-Host 'PASS blocked-names-complete'; $script:Pass++ } else { Write-Host ("FAIL blocked-names-complete (missing: " + ($missing -join ', ') + ')'); $script:FailCount++ }

# 15. Pinned ObjectBox hash constant is exact, and the real pin check rejects foreign bytes.
$script:MockObjectBoxPin = & $script:RealObjectBoxPin
if ($script:MockObjectBoxPin -cne '9c8583c4015ab9e4ce2ed3d2d581811fa059e03bb528cb8c8387adcdfda8d8a5') { Write-Host 'FAIL pin-constant-exact'; $script:FailCount++ }
else { Write-Host 'PASS pin-constant-exact'; $script:Pass++ }
$pinProbe = Join-Path $Scratch 'pin-probe.dll'
Set-Content -LiteralPath $pinProbe -Value 'not-the-vendor-runtime' -Encoding ASCII
Register-RunFile $pinProbe
try { & $script:RealObjectBoxPinCheck -Path $pinProbe; Write-Host 'FAIL pin-rejects-foreign (no throw)'; $script:FailCount++ }
catch { if ("$_" -like '*IMPORT-FAIL*') { Write-Host 'PASS pin-rejects-foreign'; $script:Pass++ } else { Write-Host "FAIL pin-rejects-foreign ($_)"; $script:FailCount++ } }
$vendorDll = Join-Path (Join-Path (Join-Path $PSScriptRoot '../..') 'build/windows/arm64/runner/Debug') 'objectbox.dll'
if (Test-Path -LiteralPath $vendorDll -PathType Leaf) {
    if ((Get-FileHash -LiteralPath $vendorDll -Algorithm SHA256).Hash.ToLowerInvariant() -ceq (Get-NativeTestHostObjectBoxPin)) {
        try {
            & $script:RealObjectBoxPinCheck -Path $vendorDll
            & $script:RealHarnessObjectBoxCheck -RunnerDirectory (Split-Path -Parent $vendorDll)
            $signables = @(Get-HarnessSignableArtifacts -RunnerDirectory (Split-Path -Parent $vendorDll))
            if ($signables -contains $vendorDll) { Write-Host 'FAIL vendor-objectbox-excluded'; $script:FailCount++ }
            else { Write-Host 'PASS vendor-objectbox-pin-and-excluded'; $script:Pass++ }
        }
        catch { Write-Host "FAIL vendor-objectbox-pin-and-excluded ($_)"; $script:FailCount++ }
    }
    else { Write-Host 'SKIP vendor-objectbox-pin-and-excluded (hash drifted; pin review required)' }
}
else { Write-Host 'SKIP vendor-objectbox-pin-and-excluded (no local runner dll)' }

# 16. Real checkout-state reader is read-only and returns a full head.
try {
    $worktree = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $beforeHead = (& git -C $worktree rev-parse HEAD).Trim()
    $state = & $script:RealCheckoutState -Repository $worktree
    $afterHead = (& git -C $worktree rev-parse HEAD).Trim()
    if (($state.Head -cnotmatch '^[0-9a-f]{40}$') -or ($state.Head -cne $beforeHead) -or ($afterHead -cne $beforeHead)) { Write-Host 'FAIL git-read-only-state'; $script:FailCount++ }
    else { Write-Host 'PASS git-read-only-state'; $script:Pass++ }
}
catch { Write-Host "FAIL git-read-only-state ($_)"; $script:FailCount++ }

# 17. Real canonical profile marker is untouched by the whole run.
if ($realMarkerBaselineHash -ne '') {
    $realMarkerNow = ''
    if (Test-Path -LiteralPath $realMarkerBaselinePath -PathType Leaf) { $realMarkerNow = (Get-FileHash -LiteralPath $realMarkerBaselinePath -Algorithm SHA256).Hash }
    if ($realMarkerNow -ceq $realMarkerBaselineHash) { Write-Host 'PASS real-profile-untouched'; $script:Pass++ } else { Write-Host 'FAIL real-profile-untouched'; $script:FailCount++ }
}
else { Write-Host 'SKIP real-profile-untouched (no real marker)' }

Write-Host ("RESULT pass={0} fail={1}" -f $script:Pass, $script:FailCount)
}
finally {
    $env:APPDATA = $RealAppData
    Remove-Item Env:/OPENBUBBLES_CLOUDKIT_WRITER_OWNER -ErrorAction SilentlyContinue
    Remove-RunTree
}
if ($script:FailCount -gt 0) { exit 1 }
