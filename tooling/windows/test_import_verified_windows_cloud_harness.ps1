# Synthetic behavioral tests for import_verified_windows_cloud_harness.ps1 (read-only except own scratch).
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Importer = Join-Path $PSScriptRoot 'import_verified_windows_cloud_harness.ps1'
. $Importer -FunctionsOnlyForTest

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$WorktreeRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$RunTag = 'import-harness-tests-run-' + [Guid]::NewGuid().ToString('N')
$Scratch = [IO.Path]::GetFullPath((Join-Path $WorktreeRoot ('build/' + $RunTag)))
$wsRoot = [IO.Path]::GetFullPath($WorktreeRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
if (-not $Scratch.StartsWith($wsRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'scratch escapes worktree' }
if (Test-Path -LiteralPath $Scratch) { throw "scratch already exists: $Scratch" }
New-Item -ItemType Directory -Path $Scratch | Out-Null
$script:TrackedFiles = @()
$script:TrackedDirs = @($Scratch)
$script:Pass = 0
$script:FailCount = 0

function Assert-UnderScratch {
    param([Parameter(Mandatory)][string] $Path)
    $full = [IO.Path]::GetFullPath($Path)
    if (($full -ne $Scratch) -and (-not $full.StartsWith($Scratch + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase))) { throw "path escapes scratch: $Path" }
}
function Register-RunFile([string] $Path) { Assert-UnderScratch -Path $Path; $script:TrackedFiles += $Path }
function Remove-RunTree {
    $removedF = @()
    $removedD = @()
    $kept = @()
    foreach ($fp in $script:TrackedFiles) {
        try {
            Assert-UnderScratch -Path $fp
            if (Test-Path -LiteralPath $fp -PathType Leaf) { Remove-Item -LiteralPath $fp -Force; $removedF += $fp }
        } catch { $kept += ($fp + ' (skip)') }
    }
    $ordered = @($script:TrackedDirs | Sort-Object { $_.Length } -Descending)
    foreach ($dp in $ordered) {
        try {
            Assert-UnderScratch -Path $dp
            $item = Get-Item -LiteralPath $dp -ErrorAction SilentlyContinue
            if ($null -eq $item) { continue }
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $kept += ($dp + ' (reparse point)'); continue }
            if (($item.Attributes -band [IO.FileAttributes]::Directory) -eq 0) { $kept += ($dp + ' (not a dir)'); continue }
            $kids = @(Get-ChildItem -LiteralPath $dp -Force -ErrorAction SilentlyContinue)
            if ($kids.Count -eq 0) { Remove-Item -LiteralPath $dp -Force; $removedD += $dp }
            else { $kept += ($dp + ' (non-empty, ' + $kids.Count + ' entries)') }
        } catch { $kept += ($dp + ' (skip)') }
    }
    Write-Host ("CLEANUP removed-files={0} removed-dirs={1} kept={2}" -f $removedF.Count, $removedD.Count, $kept.Count)
    foreach ($k in $kept) { Write-Host "CLEANUP-KEEP $k" }
}

$script:MockBuildId = ''
$script:SigStore = @{}
$script:SignCalls = @()
$script:SignShouldThrow = $false
$script:RustThumbprint = ''
$script:ObjectBoxChecks = @()
$script:ObjectBoxShouldThrow = $false

function Resolve-HarnessBuildIdentifier {
    param([Parameter(Mandatory)][string] $Repository)
    return $script:MockBuildId
}
function Get-ImportSignatureState {
    param([Parameter(Mandatory)][string] $Path)
    $mode = 'Valid'
    if ($script:SigStore.ContainsKey($Path)) { $mode = $script:SigStore[$Path] }
    $status = [System.Management.Automation.SignatureStatus]::Valid
    if ($mode -cne 'Valid') { $status = [System.Management.Automation.SignatureStatus]::NotSigned }
    return [pscustomobject]@{ Status = $status; SignerCertificate = [pscustomobject]@{ Thumbprint = $script:RustThumbprint } }
}
function Invoke-ImportSignBinary {
    param([Parameter(Mandatory)][string] $Binary, [Parameter(Mandatory)][string] $SignToolPath, [Parameter(Mandatory)][string] $Thumbprint)
    $script:SignCalls += $Binary
    if ($script:SignShouldThrow) { throw 'IMPORT-FAIL: mock signtool failed' }
    $script:SigStore[$Binary] = 'Valid'
}
function Assert-ImportObjectBoxRuntime {
    param([Parameter(Mandatory)][string] $RunnerDirectory)
    $script:ObjectBoxChecks += $RunnerDirectory
    if (-not (Test-Path -LiteralPath (Join-Path $RunnerDirectory 'objectbox.dll') -PathType Leaf)) { throw 'IMPORT-FAIL: mock objectbox missing' }
    if ($script:ObjectBoxShouldThrow) { throw 'IMPORT-FAIL: mock objectbox mismatch' }
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

function New-ReadOnlyHarnessFixture {
    param([Parameter(Mandatory)][string] $Tag, [string] $Variant = 'read-only')
    $dir = Join-Path $Scratch $Tag
    Assert-UnderScratch -Path $dir
    if (Test-Path -LiteralPath $dir) { throw "fixture dir exists: $dir" }
    New-Item -ItemType Directory -Path $dir | Out-Null
    $script:TrackedDirs += $dir
    $zipPath = Join-Path $dir 'harness.zip'
    $appBytes = (New-PeHeaderBytes -Machine 0xAA64) + [Text.Encoding]::UTF8.GetBytes('app-' + $Tag)
    $rustBytes = (New-PeHeaderBytes -Machine 0xAA64) + [Text.Encoding]::UTF8.GetBytes('rust-' + $Tag)
    $obBytes = (New-PeHeaderBytes -Machine 0xAA64) + [Text.Encoding]::UTF8.GetBytes('objectbox-' + $Tag)
    $txtBytes = [Text.Encoding]::UTF8.GetBytes('harness-notes')
    $fs = [IO.File]::Create($zipPath)
    try {
        $zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($pair in @(@{ N = 'bluebubbles_app.exe'; B = $appBytes }, @{ N = 'rust_lib_bluebubbles.dll'; B = $rustBytes }, @{ N = 'objectbox.dll'; B = $obBytes }, @{ N = 'notes.txt'; B = $txtBytes })) {
                $entry = $zip.CreateEntry($pair.N)
                $stream = $entry.Open()
                try { $stream.Write($pair.B, 0, $pair.B.Length) } finally { $stream.Dispose() }
            }
        } finally { $zip.Dispose() }
    } finally { $fs.Dispose() }
    $hashOf = { param($bytes) (Get-FileHash -InputStream ([IO.MemoryStream]::new($bytes)) -Algorithm SHA256).Hash.ToLowerInvariant() }
    $src = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $pilot = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    $bid = $src.Substring(0, 12)
    if ($Variant -cne 'read-only') { $bid += '-' + $Variant }
    $writer = ($Variant -ceq 'local-write')
    $prov = [ordered]@{
        schema_version = 1
        purpose = 'windows-cloudkit-fast-loop-engineering-bundle'
        source_commit = $src
        sidecar_commit = $pilot
        build = [ordered]@{ variant = $Variant; build_identifier = $bid; writer_defines_present = $writer; automatic_send_runtime_present = $false }
        verification = [ordered]@{
            powershell_contract_tests = 'passed'
            focused_dart_tests = 'passed'
            all_pe_files_arm64 = $true
            rust_bridge_load_unload = 'passed'
            native_local_write_encoder_tests = [ordered]@{ result = 'passed'; native_library = 'bundle/rust_lib_bluebubbles.dll'; expected_test_count = 51; full_file_run = $true }
            invalid_launch_diagnostic = [ordered]@{ expected_dart_marker = 'cloud_sync_windows_dev_launch_id_invalid'; expected_dart_marker_seen = $true; proof_status = 'observed'; network_or_auth_requested = $false; profile_state_written = $false }
            account_profile_or_database_in_bundle = $false
        }
        files = @(
            [ordered]@{ relative_path = 'bluebubbles_app.exe'; size_bytes = $appBytes.Length; sha256 = (& $hashOf $appBytes); pe_machine = 'ARM64' },
            [ordered]@{ relative_path = 'rust_lib_bluebubbles.dll'; size_bytes = $rustBytes.Length; sha256 = (& $hashOf $rustBytes); pe_machine = 'ARM64' },
            [ordered]@{ relative_path = 'objectbox.dll'; size_bytes = $obBytes.Length; sha256 = (& $hashOf $obBytes); pe_machine = 'ARM64' },
            [ordered]@{ relative_path = 'notes.txt'; size_bytes = $txtBytes.Length; sha256 = (& $hashOf $txtBytes); pe_machine = $null }
        )
    }
    $provPath = Join-Path $dir 'provenance.json'
    ($prov | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $provPath -Encoding utf8
    Register-RunFile $zipPath
    Register-RunFile $provPath
    return @{ Zip = $zipPath; Prov = $provPath; ZipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant(); Src = $src; Pilot = $pilot; BuildId = $bid; AppBytes = $appBytes; RustBytes = $rustBytes; ObBytes = $obBytes }
}

function Reset-Mocks {
    $script:SigStore = @{}
    $script:SignCalls = @()
    $script:SignShouldThrow = $false
    $script:ObjectBoxChecks = @()
    $script:ObjectBoxShouldThrow = $false
}

function New-TestRepo {
    param([Parameter(Mandatory)][string] $Tag)
    $repo = Join-Path $Scratch $Tag
    Assert-UnderScratch -Path $repo
    if (Test-Path -LiteralPath $repo) { throw "test repo exists: $repo" }
    New-Item -ItemType Directory -Path $repo | Out-Null
    $script:TrackedDirs += $repo
    return $repo
}

function Get-TestRunnerDir {
    param([Parameter(Mandatory)][string] $Repo)
    return (Join-Path $Repo 'build/windows/arm64/runner/Debug')
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

function New-FakeSignTool {
    param([Parameter(Mandatory)][string] $Tag)
    $tool = Join-Path $Scratch $Tag
    Assert-UnderScratch -Path $tool
    Set-Content -LiteralPath $tool -Value 'fake-signtool' -Encoding ASCII
    Register-RunFile $tool
    return $tool
}

try {
$Thumb = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
$realReceiptDefault = Join-Path $env:APPDATA 'OpenBubbles/cloudkit-v2-dev/cloud-sync-v2/windows-harness-build-receipt.json'
$realReceiptExisted = Test-Path -LiteralPath $realReceiptDefault -PathType Leaf
$realReceiptHash = ''
if ($realReceiptExisted) { $realReceiptHash = (Get-FileHash -LiteralPath $realReceiptDefault -Algorithm SHA256).Hash }
$fakeSignTool = New-FakeSignTool -Tag 'fake-signtool.exe'

# A fresh process exercises the script's real entrypoint. This guards against
# dependency dot-sourcing overwriting the importer's parameters and turning a
# requested import into a successful functions-only no-op.
$entrypointOutput = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File $Importer `
    -ArchivePath (Join-Path $Scratch 'entrypoint-missing.zip') `
    -ProvenancePath (Join-Path $Scratch 'entrypoint-missing-provenance.json') `
    -ExpectedArchiveSha256 ('0' * 64) `
    -ExpectedSourceSha ('0' * 40) `
    -ExpectedPilotSha ('0' * 40) `
    -Repository $WorktreeRoot `
    -ReceiptPath (Join-Path $Scratch 'entrypoint-receipt.json') `
    -SignTool $fakeSignTool `
    -SigningThumbprint $Thumb 2>&1 | Out-String
$entrypointExitCode = $LASTEXITCODE
if ($entrypointExitCode -ne 0 -and $entrypointOutput -like '*IMPORT-FAIL:*archive not found*') {
    Write-Host 'PASS direct-entrypoint-executes'
    $script:Pass++
}
else {
    Write-Host ("FAIL direct-entrypoint-executes (exit={0}, output={1})" -f $entrypointExitCode, $entrypointOutput.Trim())
    $script:FailCount++
}

# 1. Success: fresh install, unsigned app gets signed, objectbox untouched, receipt bound.
$f = New-ReadOnlyHarnessFixture -Tag 'success'
Reset-Mocks
$script:MockBuildId = $f.BuildId
$script:RustThumbprint = $Thumb
$repo = New-TestRepo -Tag 't-success-repo'
$runner = Get-TestRunnerDir -Repo $repo
$receipt = Join-Path $Scratch 't-success-receipt.json'
$appInstalled = Join-Path $runner 'bluebubbles_app.exe'
$rustInstalled = Join-Path $runner 'rust_lib_bluebubbles.dll'
$obInstalled = Join-Path $runner 'objectbox.dll'
$script:SigStore[$appInstalled] = 'NotSigned'
$script:SigStore[$rustInstalled] = 'Valid'
$script:SigStore[$obInstalled] = 'Valid'
try {
    $result = Import-VerifiedWindowsCloudHarness -ArchivePath $f.Zip -ProvenancePath $f.Prov -ExpectedArchiveSha256 $f.ZipHash -ExpectedSourceSha $f.Src -ExpectedPilotSha $f.Pilot -Repository $repo -ReceiptPath $receipt -SignTool $fakeSignTool -SigningThumbprint $Thumb
    $ok = $true
    if ($result.BuildIdentifier -cne $f.BuildId) { Write-Host 'FAIL success-positive (build id)'; $ok = $false }
    $appHash = (Get-FileHash -LiteralPath $appInstalled -Algorithm SHA256).Hash.ToLowerInvariant()
    $rustHash = (Get-FileHash -LiteralPath $rustInstalled -Algorithm SHA256).Hash.ToLowerInvariant()
    $obHash = (Get-FileHash -LiteralPath $obInstalled -Algorithm SHA256).Hash.ToLowerInvariant()
    $wantApp = (Get-FileHash -InputStream ([IO.MemoryStream]::new($f.AppBytes)) -Algorithm SHA256).Hash.ToLowerInvariant()
    $wantRust = (Get-FileHash -InputStream ([IO.MemoryStream]::new($f.RustBytes)) -Algorithm SHA256).Hash.ToLowerInvariant()
    $wantOb = (Get-FileHash -InputStream ([IO.MemoryStream]::new($f.ObBytes)) -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($appHash -cne $wantApp -or $rustHash -cne $wantRust -or $obHash -cne $wantOb) { Write-Host 'FAIL success-positive (installed bytes)'; $ok = $false }
    if ($script:SignCalls -notcontains $appInstalled) { Write-Host 'FAIL success-positive (unsigned app was not signed)'; $ok = $false }
    if ($script:SignCalls -contains $rustInstalled) { Write-Host 'FAIL success-positive (valid rust was re-signed)'; $ok = $false }
    if ($script:SignCalls -contains $obInstalled) { Write-Host 'FAIL success-positive (objectbox was signed)'; $ok = $false }
    $signables = @(Get-HarnessSignableArtifacts -RunnerDirectory $runner)
    if ($signables -contains $obInstalled) { Write-Host 'FAIL success-positive (objectbox in signable set)'; $ok = $false }
    if ($script:ObjectBoxChecks.Count -lt 2) { Write-Host 'FAIL success-positive (objectbox not checked staged and installed)'; $ok = $false }
    if (-not (Test-HarnessBuildReceipt -ReceiptPath $receipt -BuildIdentifier $f.BuildId -Runner $appInstalled -RustLibrary $rustInstalled)) { Write-Host 'FAIL success-positive (receipt compat)'; $ok = $false }
    $doc = Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json
    if ($doc.origin.source_commit -cne $f.Src -or $doc.origin.pilot_commit -cne $f.Pilot) { Write-Host 'FAIL success-positive (origin source/pilot)'; $ok = $false }
    if ($doc.origin.archive_sha256 -cne $f.ZipHash) { Write-Host 'FAIL success-positive (origin archive)'; $ok = $false }
    $provHash = (Get-FileHash -LiteralPath $f.Prov -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($doc.origin.provenance_sha256 -cne $provHash) { Write-Host 'FAIL success-positive (origin provenance)'; $ok = $false }
    if ($doc.origin.runner_post_sign_sha256 -cne $appHash -or $doc.origin.rust_library_post_sign_sha256 -cne $rustHash) { Write-Host 'FAIL success-positive (origin post-sign)'; $ok = $false }
    $leftovers = @(Get-ChildItem -LiteralPath (Split-Path -Parent $runner) -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '.harness-import-stage-*' -or $_.Name -like '*.rollback-*' })
    if ($leftovers.Count -ne 0) { Write-Host 'FAIL success-positive (staging/rollback residue)'; $ok = $false }
    if ($ok) { Write-Host 'PASS success-positive'; $script:Pass++ } else { $script:FailCount++ }
}
catch { Write-Host "FAIL success-positive ($_)"; $script:FailCount++ }

# 2. Wrong source SHA is rejected before anything is installed.
Reset-Mocks
$script:MockBuildId = $f.BuildId
$script:RustThumbprint = $Thumb
$repo2 = New-TestRepo -Tag 't-wrongsrc-repo'
$runner2 = Get-TestRunnerDir -Repo $repo2
$receipt2 = Join-Path $Scratch 't-wrongsrc-receipt.json'
Assert-ImportFails -Name 'wrong-source-rejected' -Body { Import-VerifiedWindowsCloudHarness -ArchivePath $f.Zip -ProvenancePath $f.Prov -ExpectedArchiveSha256 $f.ZipHash -ExpectedSourceSha 'cccccccccccccccccccccccccccccccccccccccc' -ExpectedPilotSha $f.Pilot -Repository $repo2 -ReceiptPath $receipt2 -SignTool $fakeSignTool -SigningThumbprint $Thumb }
if (-not (Test-Path -LiteralPath $runner2) -and -not (Test-Path -LiteralPath $receipt2 -PathType Leaf)) { Write-Host 'PASS wrong-source-no-side-effects'; $script:Pass++ } else { Write-Host 'FAIL wrong-source-no-side-effects'; $script:FailCount++ }

# 3. Wrong archive hash is rejected before anything is installed.
Reset-Mocks
$script:MockBuildId = $f.BuildId
$script:RustThumbprint = $Thumb
$repo3 = New-TestRepo -Tag 't-wronghash-repo'
$runner3 = Get-TestRunnerDir -Repo $repo3
$receipt3 = Join-Path $Scratch 't-wronghash-receipt.json'
Assert-ImportFails -Name 'wrong-archive-hash-rejected' -Body { Import-VerifiedWindowsCloudHarness -ArchivePath $f.Zip -ProvenancePath $f.Prov -ExpectedArchiveSha256 '0000000000000000000000000000000000000000000000000000000000000000' -ExpectedSourceSha $f.Src -ExpectedPilotSha $f.Pilot -Repository $repo3 -ReceiptPath $receipt3 -SignTool $fakeSignTool -SigningThumbprint $Thumb }
if (-not (Test-Path -LiteralPath $runner3) -and -not (Test-Path -LiteralPath $receipt3 -PathType Leaf)) { Write-Host 'PASS wrong-hash-no-side-effects'; $script:Pass++ } else { Write-Host 'FAIL wrong-hash-no-side-effects'; $script:FailCount++ }

# 4. Wrong mode (writer bundle offered as read-only) is rejected.
$fw = New-ReadOnlyHarnessFixture -Tag 'writer' -Variant 'local-write'
Reset-Mocks
$script:MockBuildId = $f.BuildId
$script:RustThumbprint = $Thumb
$repo4 = New-TestRepo -Tag 't-wrongmode-repo'
$runner4 = Get-TestRunnerDir -Repo $repo4
$receipt4 = Join-Path $Scratch 't-wrongmode-receipt.json'
Assert-ImportFails -Name 'wrong-mode-rejected' -Body { Import-VerifiedWindowsCloudHarness -ArchivePath $fw.Zip -ProvenancePath $fw.Prov -ExpectedArchiveSha256 $fw.ZipHash -ExpectedSourceSha $fw.Src -ExpectedPilotSha $fw.Pilot -Repository $repo4 -ReceiptPath $receipt4 -SignTool $fakeSignTool -SigningThumbprint $Thumb }
if (-not (Test-Path -LiteralPath $runner4) -and -not (Test-Path -LiteralPath $receipt4 -PathType Leaf)) { Write-Host 'PASS wrong-mode-no-side-effects'; $script:Pass++ } else { Write-Host 'FAIL wrong-mode-no-side-effects'; $script:FailCount++ }

# 5. Reparse point at the runner directory is rejected without side effects.
Reset-Mocks
$script:MockBuildId = $f.BuildId
$script:RustThumbprint = $Thumb
$repo5 = New-TestRepo -Tag 't-reparse-repo'
$runner5 = Get-TestRunnerDir -Repo $repo5
$receipt5 = Join-Path $Scratch 't-reparse-receipt.json'
$junctionTarget = Join-Path $Scratch 't-reparse-target'
New-Item -ItemType Directory -Path $junctionTarget | Out-Null
$script:TrackedDirs += $junctionTarget
$junctionParent = Split-Path -Parent $runner5
New-Item -ItemType Directory -Path $junctionParent -Force | Out-Null
$junctionOk = $true
try { New-Item -ItemType Junction -Path $runner5 -Target $junctionTarget | Out-Null } catch { $junctionOk = $false }
if (-not $junctionOk) { Write-Host 'SKIP reparse-rejected (junction creation unavailable)' }
else {
    Assert-ImportFails -Name 'reparse-rejected' -Body { Import-VerifiedWindowsCloudHarness -ArchivePath $f.Zip -ProvenancePath $f.Prov -ExpectedArchiveSha256 $f.ZipHash -ExpectedSourceSha $f.Src -ExpectedPilotSha $f.Pilot -Repository $repo5 -ReceiptPath $receipt5 -SignTool $fakeSignTool -SigningThumbprint $Thumb }
    $link = Get-Item -LiteralPath $runner5 -Force
    if ((($link.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) -and (-not (Test-Path -LiteralPath $receipt5 -PathType Leaf))) { Write-Host 'PASS reparse-no-side-effects'; $script:Pass++ } else { Write-Host 'FAIL reparse-no-side-effects'; $script:FailCount++ }
    Remove-Item -LiteralPath $runner5 -Force
}

# 6. Signing failure rolls back the previous build and receipt exactly.
Reset-Mocks
$script:MockBuildId = $f.BuildId
$script:RustThumbprint = $Thumb
$script:SignShouldThrow = $true
$repo6 = New-TestRepo -Tag 't-signfail-repo'
$runner6 = Get-TestRunnerDir -Repo $repo6
New-Item -ItemType Directory -Path $runner6 -Force | Out-Null
Set-Content -LiteralPath (Join-Path $runner6 'old.exe') -Value 'old-build' -Encoding ASCII
$receipt6 = Join-Path $Scratch 't-signfail-receipt.json'
Set-Content -LiteralPath $receipt6 -Value 'old-receipt' -Encoding ASCII
Register-RunFile (Join-Path $runner6 'old.exe')
Register-RunFile $receipt6
$script:SigStore[(Join-Path $runner6 'bluebubbles_app.exe')] = 'NotSigned'
Assert-ImportFails -Name 'sign-failure-rolls-back' -Body { Import-VerifiedWindowsCloudHarness -ArchivePath $f.Zip -ProvenancePath $f.Prov -ExpectedArchiveSha256 $f.ZipHash -ExpectedSourceSha $f.Src -ExpectedPilotSha $f.Pilot -Repository $repo6 -ReceiptPath $receipt6 -SignTool $fakeSignTool -SigningThumbprint $Thumb }
$restoredExe = Get-Content -LiteralPath (Join-Path $runner6 'old.exe') -Raw
$restoredReceipt = Get-Content -LiteralPath $receipt6 -Raw
$residue6 = @(Get-ChildItem -LiteralPath (Split-Path -Parent $runner6) -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '.harness-import-stage-*' -or $_.Name -like '*.rollback-*' })
$receiptResidue6 = @(Get-ChildItem -LiteralPath $Scratch -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*.rollback-*' })
if (($restoredExe -like '*old-build*') -and ($restoredReceipt -like '*old-receipt*') -and ($residue6.Count -eq 0) -and ($receiptResidue6.Count -eq 0)) { Write-Host 'PASS sign-failure-rollback-exact'; $script:Pass++ } else { Write-Host 'FAIL sign-failure-rollback-exact'; $script:FailCount++ }
$script:SignShouldThrow = $false

# 7. Rust signer thumbprint mismatch rolls back.
Reset-Mocks
$script:MockBuildId = $f.BuildId
$script:RustThumbprint = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
$repo7 = New-TestRepo -Tag 't-thumb-repo'
$runner7 = Get-TestRunnerDir -Repo $repo7
New-Item -ItemType Directory -Path $runner7 -Force | Out-Null
Set-Content -LiteralPath (Join-Path $runner7 'old.exe') -Value 'old-build' -Encoding ASCII
$receipt7 = Join-Path $Scratch 't-thumb-receipt.json'
Set-Content -LiteralPath $receipt7 -Value 'old-receipt' -Encoding ASCII
Register-RunFile (Join-Path $runner7 'old.exe')
Register-RunFile $receipt7
Assert-ImportFails -Name 'signer-thumbprint-mismatch-rolls-back' -Body { Import-VerifiedWindowsCloudHarness -ArchivePath $f.Zip -ProvenancePath $f.Prov -ExpectedArchiveSha256 $f.ZipHash -ExpectedSourceSha $f.Src -ExpectedPilotSha $f.Pilot -Repository $repo7 -ReceiptPath $receipt7 -SignTool $fakeSignTool -SigningThumbprint $Thumb }
$restoredExe7 = Get-Content -LiteralPath (Join-Path $runner7 'old.exe') -Raw
$restoredReceipt7 = Get-Content -LiteralPath $receipt7 -Raw
if (($restoredExe7 -like '*old-build*') -and ($restoredReceipt7 -like '*old-receipt*')) { Write-Host 'PASS thumbprint-rollback-exact'; $script:Pass++ } else { Write-Host 'FAIL thumbprint-rollback-exact'; $script:FailCount++ }
$script:RustThumbprint = $Thumb

# 8. Receipt validation failure rolls back (validation itself is mocked to fail).
$originalReceiptCheck = (Get-Item Function:\Test-HarnessBuildReceipt).ScriptBlock
Set-Item -Path Function:\Test-HarnessBuildReceipt -Value { param($ReceiptPath, $BuildIdentifier, $Runner, $RustLibrary) return $false }
Reset-Mocks
$script:MockBuildId = $f.BuildId
$script:RustThumbprint = $Thumb
$repo8 = New-TestRepo -Tag 't-receiptfail-repo'
$runner8 = Get-TestRunnerDir -Repo $repo8
New-Item -ItemType Directory -Path $runner8 -Force | Out-Null
Set-Content -LiteralPath (Join-Path $runner8 'old.exe') -Value 'old-build' -Encoding ASCII
$receipt8 = Join-Path $Scratch 't-receiptfail-receipt.json'
Set-Content -LiteralPath $receipt8 -Value 'old-receipt' -Encoding ASCII
Register-RunFile (Join-Path $runner8 'old.exe')
Register-RunFile $receipt8
Assert-ImportFails -Name 'receipt-mismatch-rolls-back' -Body { Import-VerifiedWindowsCloudHarness -ArchivePath $f.Zip -ProvenancePath $f.Prov -ExpectedArchiveSha256 $f.ZipHash -ExpectedSourceSha $f.Src -ExpectedPilotSha $f.Pilot -Repository $repo8 -ReceiptPath $receipt8 -SignTool $fakeSignTool -SigningThumbprint $Thumb }
Set-Item -Path Function:\Test-HarnessBuildReceipt -Value $originalReceiptCheck
$restoredExe8 = Get-Content -LiteralPath (Join-Path $runner8 'old.exe') -Raw
$restoredReceipt8 = Get-Content -LiteralPath $receipt8 -Raw
if (($restoredExe8 -like '*old-build*') -and ($restoredReceipt8 -like '*old-receipt*')) { Write-Host 'PASS receipt-rollback-exact'; $script:Pass++ } else { Write-Host 'FAIL receipt-rollback-exact'; $script:FailCount++ }

# 9. Tampering the installed harness breaks the receipt (binding is truthful).
Reset-Mocks
$script:MockBuildId = $f.BuildId
$script:RustThumbprint = $Thumb
$repo9 = New-TestRepo -Tag 't-tamper-repo'
$runner9 = Get-TestRunnerDir -Repo $repo9
$receipt9 = Join-Path $Scratch 't-tamper-receipt.json'
try {
    Import-VerifiedWindowsCloudHarness -ArchivePath $f.Zip -ProvenancePath $f.Prov -ExpectedArchiveSha256 $f.ZipHash -ExpectedSourceSha $f.Src -ExpectedPilotSha $f.Pilot -Repository $repo9 -ReceiptPath $receipt9 -SignTool $fakeSignTool -SigningThumbprint $Thumb | Out-Null
    $rustInstalled9 = Join-Path $runner9 'rust_lib_bluebubbles.dll'
    $appInstalled9 = Join-Path $runner9 'bluebubbles_app.exe'
    $beforeTamper = Test-HarnessBuildReceipt -ReceiptPath $receipt9 -BuildIdentifier $f.BuildId -Runner $appInstalled9 -RustLibrary $rustInstalled9
    Add-Content -LiteralPath $rustInstalled9 -Value 'tamper' -Encoding ASCII
    $afterTamper = Test-HarnessBuildReceipt -ReceiptPath $receipt9 -BuildIdentifier $f.BuildId -Runner $appInstalled9 -RustLibrary $rustInstalled9
    if ($beforeTamper -and (-not $afterTamper)) { Write-Host 'PASS receipt-binding-truthful'; $script:Pass++ } else { Write-Host 'FAIL receipt-binding-truthful'; $script:FailCount++ }
}
catch { Write-Host "FAIL receipt-binding-truthful ($_)"; $script:FailCount++ }

# 9b. Default read-only preservation: the issued receipt pins harness/read-only binding.
try {
    $bindDoc = Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json
    $bindOk = $true
    if ($bindDoc.origin.variant -cne 'read-only') { Write-Host 'FAIL receipt-default-variant (expected read-only)'; $bindOk = $false }
    if ($bindDoc.origin.artifact_mode -cne 'harness') { Write-Host 'FAIL receipt-default-mode (expected harness)'; $bindOk = $false }
    if ($bindDoc.build_identifier -cne $f.BuildId) { Write-Host 'FAIL receipt-default-build-id'; $bindOk = $false }
    if ($bindDoc.build_identifier -like '*-*') { Write-Host 'FAIL receipt-default-build-id (read-only must be bare 12-char, no suffix)'; $bindOk = $false }
    if ($bindOk) { Write-Host 'PASS receipt-default-read-only-preserved'; $script:Pass++ } else { $script:FailCount++ }
}
catch { Write-Host "FAIL receipt-default-read-only-preserved ($_ )"; $script:FailCount++ }

# 9c. Configuration/build-id binding mirrors Get-HarnessConfigurationIdentifier.
try {
    $cfgOk = $true
    $bare = $f.Src.Substring(0, 12)
    if ((Get-HarnessConfigurationIdentifier -SourceIdentifier $bare) -cne $bare) { Write-Host 'FAIL config-binding-default'; $cfgOk = $false }
    if ((Get-HarnessConfigurationIdentifier -SourceIdentifier $bare -WriterBuild) -cne ($bare + '-local-write')) { Write-Host 'FAIL config-binding-writer'; $cfgOk = $false }
    if ($fw.BuildId -cne ($bare + '-local-write')) { Write-Host 'FAIL config-binding-fixture (local-write build id must carry suffix)'; $cfgOk = $false }
    if ($f.BuildId -cne $bare) { Write-Host 'FAIL config-binding-fixture (read-only build id must be bare)'; $cfgOk = $false }
    try { Get-HarnessConfigurationIdentifier -SourceIdentifier $bare -WriterBuild -ReplayBuild | Out-Null; Write-Host 'FAIL config-binding-conflict (no throw)'; $cfgOk = $false } catch { if ("$_" -notlike '*Conflicting harness configurations*') { Write-Host "FAIL config-binding-conflict (wrong error: $_)"; $cfgOk = $false } }
    if ($cfgOk) { Write-Host 'PASS config-build-id-binding'; $script:Pass++ } else { $script:FailCount++ }
}
catch { Write-Host "FAIL config-build-id-binding ($_ )"; $script:FailCount++ }

# 9d. Explicit local-write acceptance at the verifier layer
# (artifact_mode=harness, build_variant=local-write).
try {
    $lwResult = Invoke-VerifyWindowsCloudBundle -ArchivePath $fw.Zip -ProvenancePath $fw.Prov -ExpectedArchiveSha256 $fw.ZipHash -ExpectedSourceSha $fw.Src -ExpectedPilotSha $fw.Pilot -ExpectedVariant 'local-write' -ExpectedArtifactMode 'harness'
    $lwOk = $true
    if ($lwResult.BuildId -cne $fw.BuildId) { Write-Host 'FAIL verifier-local-write-accept (build id)'; $lwOk = $false }
    if ($lwResult.Variant -cne 'local-write') { Write-Host 'FAIL verifier-local-write-accept (variant)'; $lwOk = $false }
    if ($lwResult.ArtifactMode -cne 'harness') { Write-Host 'FAIL verifier-local-write-accept (mode)'; $lwOk = $false }
    if ($lwOk) { Write-Host 'PASS verifier-local-write-accept'; $script:Pass++ } else { $script:FailCount++ }
}
catch { Write-Host "FAIL verifier-local-write-accept ($_ )"; $script:FailCount++ }

# 9e. Provenance variant enforcement + wrong-variant rejection (both directions, verifier layer).
try { Invoke-VerifyWindowsCloudBundle -ArchivePath $fw.Zip -ProvenancePath $fw.Prov -ExpectedArchiveSha256 $fw.ZipHash -ExpectedSourceSha $fw.Src -ExpectedPilotSha $fw.Pilot -ExpectedVariant 'read-only' -ExpectedArtifactMode 'harness' | Out-Null; Write-Host 'FAIL verifier-rejects-writer-as-readonly (no throw)'; $script:FailCount++ } catch { if ("$_" -like '*VERIFY-FAIL*') { Write-Host 'PASS verifier-rejects-writer-as-readonly'; $script:Pass++ } else { Write-Host "FAIL verifier-rejects-writer-as-readonly (wrong error: $_)"; $script:FailCount++ } }
try { Invoke-VerifyWindowsCloudBundle -ArchivePath $f.Zip -ProvenancePath $f.Prov -ExpectedArchiveSha256 $f.ZipHash -ExpectedSourceSha $f.Src -ExpectedPilotSha $f.Pilot -ExpectedVariant 'local-write' -ExpectedArtifactMode 'harness' | Out-Null; Write-Host 'FAIL verifier-rejects-readonly-as-writer (no throw)'; $script:FailCount++ } catch { if ("$_" -like '*VERIFY-FAIL*') { Write-Host 'PASS verifier-rejects-readonly-as-writer'; $script:Pass++ } else { Write-Host "FAIL verifier-rejects-readonly-as-writer (wrong error: $_)"; $script:FailCount++ } }

# 9f. Importer-layer wrong-variant rejection: a local-write bundle cannot enter
# through the default read-only path.
Reset-Mocks
$script:MockBuildId = $f.BuildId
$script:RustThumbprint = $Thumb
$lwRepo = New-TestRepo -Tag 't-lw-explicit-repo'
$lwReceipt = Join-Path $Scratch 't-lw-explicit-receipt.json'
try { Import-VerifiedWindowsCloudHarness -ArchivePath $fw.Zip -ProvenancePath $fw.Prov -ExpectedArchiveSha256 $fw.ZipHash -ExpectedSourceSha $fw.Src -ExpectedPilotSha $fw.Pilot -Repository $lwRepo -ReceiptPath $lwReceipt -SignTool $fakeSignTool -SigningThumbprint $Thumb | Out-Null; Write-Host 'FAIL importer-rejects-local-write (no throw)'; $script:FailCount++ } catch { if ("$_" -like '*IMPORT-FAIL*') { Write-Host 'PASS importer-rejects-local-write'; $script:Pass++ } else { Write-Host "FAIL importer-rejects-local-write (wrong error: $_)"; $script:FailCount++ } }
if ((-not (Test-Path -LiteralPath (Get-TestRunnerDir -Repo $lwRepo))) -and (-not (Test-Path -LiteralPath $lwReceipt -PathType Leaf))) { Write-Host 'PASS importer-rejects-local-write-no-side-effects'; $script:Pass++ } else { Write-Host 'FAIL importer-rejects-local-write-no-side-effects'; $script:FailCount++ }

# 9g. An explicitly selected local-write harness imports with the suffixed
# configuration identifier and stamps the same variant into its receipt.
Reset-Mocks
$script:MockBuildId = $f.BuildId
$script:RustThumbprint = $Thumb
$lwPositiveRepo = New-TestRepo -Tag 't-lw-positive-repo'
$lwPositiveRunner = Get-TestRunnerDir -Repo $lwPositiveRepo
$lwPositiveReceipt = Join-Path $Scratch 't-lw-positive-receipt.json'
$lwPositiveApp = Join-Path $lwPositiveRunner 'bluebubbles_app.exe'
$lwPositiveRust = Join-Path $lwPositiveRunner 'rust_lib_bluebubbles.dll'
$lwPositiveObjectBox = Join-Path $lwPositiveRunner 'objectbox.dll'
$script:SigStore[$lwPositiveApp] = 'NotSigned'
$script:SigStore[$lwPositiveRust] = 'Valid'
$script:SigStore[$lwPositiveObjectBox] = 'Valid'
try {
    $lwImport = Import-VerifiedWindowsCloudHarness -ArchivePath $fw.Zip -ProvenancePath $fw.Prov -ExpectedArchiveSha256 $fw.ZipHash -ExpectedSourceSha $fw.Src -ExpectedPilotSha $fw.Pilot -ExpectedVariant 'local-write' -Repository $lwPositiveRepo -ReceiptPath $lwPositiveReceipt -SignTool $fakeSignTool -SigningThumbprint $Thumb
    $lwImportOk = $true
    if ($lwImport.BuildIdentifier -cne $fw.BuildId) { Write-Host 'FAIL importer-local-write-positive (build id)'; $lwImportOk = $false }
    $lwReceiptDoc = Get-Content -LiteralPath $lwPositiveReceipt -Raw | ConvertFrom-Json
    if ($lwReceiptDoc.origin.variant -cne 'local-write') { Write-Host 'FAIL importer-local-write-positive (receipt variant)'; $lwImportOk = $false }
    if ($lwReceiptDoc.build_identifier -cne $fw.BuildId) { Write-Host 'FAIL importer-local-write-positive (receipt build id)'; $lwImportOk = $false }
    if (-not (Test-HarnessBuildReceipt -ReceiptPath $lwPositiveReceipt -BuildIdentifier $fw.BuildId -Runner $lwPositiveApp -RustLibrary $lwPositiveRust)) { Write-Host 'FAIL importer-local-write-positive (receipt compatibility)'; $lwImportOk = $false }
    if ($script:SignCalls -notcontains $lwPositiveApp -or $script:SignCalls -contains $lwPositiveObjectBox) { Write-Host 'FAIL importer-local-write-positive (signing boundary)'; $lwImportOk = $false }
    if ($lwImportOk) { Write-Host 'PASS importer-local-write-positive'; $script:Pass++ } else { $script:FailCount++ }
}
catch { Write-Host "FAIL importer-local-write-positive ($_ )"; $script:FailCount++ }

# 9h. The explicit writer path rejects a read-only bundle without installing it.
Reset-Mocks
$script:MockBuildId = $f.BuildId
$script:RustThumbprint = $Thumb
$roAsWriterRepo = New-TestRepo -Tag 't-ro-as-writer-repo'
$roAsWriterReceipt = Join-Path $Scratch 't-ro-as-writer-receipt.json'
Assert-ImportFails -Name 'importer-rejects-readonly-as-writer' -Body { Import-VerifiedWindowsCloudHarness -ArchivePath $f.Zip -ProvenancePath $f.Prov -ExpectedArchiveSha256 $f.ZipHash -ExpectedSourceSha $f.Src -ExpectedPilotSha $f.Pilot -ExpectedVariant 'local-write' -Repository $roAsWriterRepo -ReceiptPath $roAsWriterReceipt -SignTool $fakeSignTool -SigningThumbprint $Thumb }
if ((-not (Test-Path -LiteralPath (Get-TestRunnerDir -Repo $roAsWriterRepo))) -and (-not (Test-Path -LiteralPath $roAsWriterReceipt -PathType Leaf))) { Write-Host 'PASS importer-rejects-readonly-as-writer-no-side-effects'; $script:Pass++ } else { Write-Host 'FAIL importer-rejects-readonly-as-writer-no-side-effects'; $script:FailCount++ }

# 10. The real profile receipt is never touched.
$realAfter = Test-Path -LiteralPath $realReceiptDefault -PathType Leaf
$realHashAfter = ''
if ($realAfter) { $realHashAfter = (Get-FileHash -LiteralPath $realReceiptDefault -Algorithm SHA256).Hash }
if (($realAfter -eq $realReceiptExisted) -and ($realHashAfter -eq $realReceiptHash)) { Write-Host 'PASS real-profile-untouched'; $script:Pass++ } else { Write-Host 'FAIL real-profile-untouched'; $script:FailCount++ }

Write-Host ("RESULT pass={0} fail={1}" -f $script:Pass, $script:FailCount)
} finally {
    Remove-RunTree
}
if ($script:FailCount -gt 0) { exit 1 }
