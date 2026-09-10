# Synthetic behavioral tests for verify_windows_cloud_bundle.ps1 (read-only except own scratch).
param(
    [string] $RealArchivePath = '',
    [string] $RealProvenancePath = '',
    [string] $RealArchiveSha256 = '',
    [string] $RealSourceSha = '',
    [string] $RealPilotSha = '',
    [string] $RealVariant = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$WorktreeRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$Verifier = Join-Path $PSScriptRoot 'verify_windows_cloud_bundle.ps1'
. $Verifier -FunctionsOnlyForTest

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function New-PeHeaderBytes {
    param([Parameter(Mandatory)][uint16] $Machine)
    $b = New-Object byte[] 160
    $b[0] = 0x4D; $b[1] = 0x5A
    $lfanew = 128
    [Array]::Copy([BitConverter]::GetBytes($lfanew), 0, $b, 0x3C, 4)
    $b[$lfanew] = 0x50; $b[$lfanew+1] = 0x45
    [Array]::Copy([BitConverter]::GetBytes($Machine), 0, $b, $lfanew + 4, 2)
    return $b
}

# Unique run directory, created without overwrite; canonical path must stay under the worktree.
$RunTag = 'verify-bundle-tests-run-' + [Guid]::NewGuid().ToString('N')
$Scratch = [IO.Path]::GetFullPath((Join-Path $WorktreeRoot ('build/' + $RunTag)))
$wsRoot = [IO.Path]::GetFullPath($WorktreeRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
if (-not $Scratch.StartsWith($wsRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'scratch escapes worktree' }
if (Test-Path -LiteralPath $Scratch) { throw "scratch already exists: $Scratch" }
New-Item -ItemType Directory -Path $Scratch | Out-Null
$script:TrackedFiles = @()
$script:TrackedDirs = @($Scratch)
$script:Pass = 0; $script:FailCount = 0

function Assert-UnderScratch {
    param([Parameter(Mandatory)][string] $Path)
    $full = [IO.Path]::GetFullPath($Path)
    if (($full -ne $Scratch) -and (-not $full.StartsWith($Scratch + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase))) { throw "path escapes scratch: $Path" }
}
function Register-RunFile([string] $Path) { Assert-UnderScratch -Path $Path; $script:TrackedFiles += $Path }
function Remove-RunTree {
    $removedF = @(); $removedD = @(); $kept = @()
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
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $kept += ($dp + ' (reparse point)') ; continue }
            if (($item.Attributes -band [IO.FileAttributes]::Directory) -eq 0) { $kept += ($dp + ' (not a dir)') ; continue }
            $kids = @(Get-ChildItem -LiteralPath $dp -Force -ErrorAction SilentlyContinue)
            if ($kids.Count -eq 0) { Remove-Item -LiteralPath $dp -Force; $removedD += $dp }
            else { $kept += ($dp + ' (non-empty, ' + $kids.Count + ' entries)') }
        } catch { $kept += ($dp + ' (skip)') }
    }
    Write-Host ("CLEANUP removed-files={0} removed-dirs={1} kept={2}" -f $removedF.Count, $removedD.Count, $kept.Count)
    foreach ($k in $kept) { Write-Host "CLEANUP-KEEP $k" }
}

try {

function Assert-Fails {
    param([Parameter(Mandatory)][scriptblock] $Body, [Parameter(Mandatory)][string] $Name)
    try { & $Body; Write-Host "FAIL $Name (no throw)"; $script:FailCount++ }
    catch { if ("$_" -like '*VERIFY-FAIL*') { Write-Host "PASS $Name"; $script:Pass++ } else { Write-Host "FAIL $Name (wrong error: $_)"; $script:FailCount++ } }
}

function New-MiniFixture {
    param([string] $Tag, [uint16] $DllMachine = 0xAA64, [string] $Variant = 'local-write', [string] $ExtraProvenance = '')
    $dir = Join-Path $Scratch $Tag
    Assert-UnderScratch -Path $dir
    if (Test-Path -LiteralPath $dir) { throw "fixture dir exists: $dir" }
    New-Item -ItemType Directory -Path $dir | Out-Null
    $script:TrackedDirs += $dir
    $zipPath = Join-Path $dir 'mini.zip'
    $dllBytes = New-PeHeaderBytes -Machine $DllMachine
    $txtBytes = [Text.Encoding]::UTF8.GetBytes('hello-mini')
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $fs = [IO.File]::Create($zipPath)
    try {
        $zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $en1 = $zip.CreateEntry('hello.txt'); $s1 = $en1.Open(); try { $s1.Write($txtBytes, 0, $txtBytes.Length) } finally { $s1.Dispose() }
            $en2 = $zip.CreateEntry('rust_lib_bluebubbles.dll'); $s2 = $en2.Open(); try { $s2.Write($dllBytes, 0, $dllBytes.Length) } finally { $s2.Dispose() }
        } finally { $zip.Dispose() }
    } finally { $fs.Dispose() }
    $h1 = (Get-FileHash -InputStream ([IO.MemoryStream]::new($txtBytes)) -Algorithm SHA256).Hash.ToLowerInvariant()
    $h2 = (Get-FileHash -InputStream ([IO.MemoryStream]::new($dllBytes)) -Algorithm SHA256).Hash.ToLowerInvariant()
    $src = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; $pilot = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    $bid = $src.Substring(0, 12)
    if ($Variant -cne 'read-only') { $bid += '-' + $Variant }
    $writer = ($Variant -ceq 'local-write')
    $provPath = Join-Path $dir 'provenance.json'
    $prov = [ordered]@{
        schema_version = 1; purpose = 'windows-cloudkit-fast-loop-engineering-bundle'
        source_commit = $src; sidecar_commit = $pilot
        build = [ordered]@{ variant = $Variant; build_identifier = $bid; writer_defines_present = $writer; automatic_send_runtime_present = $false }
        verification = [ordered]@{
            powershell_contract_tests = 'passed'; focused_dart_tests = 'passed'
            all_pe_files_arm64 = $true; rust_bridge_load_unload = 'passed'
            native_local_write_encoder_tests = [ordered]@{ result = 'passed'; native_library = 'bundle/rust_lib_bluebubbles.dll'; expected_test_count = 48; full_file_run = $true }
            invalid_launch_diagnostic = [ordered]@{ expected_dart_marker = 'cloud_sync_windows_dev_launch_id_invalid'; expected_dart_marker_seen = $true; proof_status = 'observed'; network_or_auth_requested = $false; profile_state_written = $false }
            account_profile_or_database_in_bundle = $false
        }
        files = @(
            [ordered]@{ relative_path = 'hello.txt'; size_bytes = $txtBytes.Length; sha256 = $h1; pe_machine = $null },
            [ordered]@{ relative_path = 'rust_lib_bluebubbles.dll'; size_bytes = $dllBytes.Length; sha256 = $h2; pe_machine = 'ARM64' }
        )
    }
    ($prov | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $provPath -Encoding utf8
    $zhash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Register-RunFile $zipPath; Register-RunFile $provPath
    return @{ Zip = $zipPath; Prov = $provPath; ZipHash = $zhash; Src = $src; Pilot = $pilot }
}

function New-EditedProv {
    param([Parameter(Mandatory)][string] $Tag, [Parameter(Mandatory)][string] $SourceProv, [Parameter(Mandatory)][scriptblock] $Edit)
    $d = Join-Path $Scratch $Tag
    Assert-UnderScratch -Path $d
    if (Test-Path -LiteralPath $d) { throw "fixture dir exists: $d" }
    New-Item -ItemType Directory -Path $d | Out-Null
    $script:TrackedDirs += $d
    $p = Join-Path $d 'provenance.json'
    $o = Get-Content -LiteralPath $SourceProv -Raw | ConvertFrom-Json
    & $Edit $o
    ($o | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $p -Encoding utf8
    Register-RunFile $p
    return $p
}

function New-CollisionFixture {
    param([Parameter(Mandatory)][string] $Tag, [Parameter(Mandatory)] $Base)
    $d = Join-Path $Scratch $Tag
    Assert-UnderScratch -Path $d
    if (Test-Path -LiteralPath $d) { throw "fixture dir exists: $d" }
    New-Item -ItemType Directory -Path $d | Out-Null
    $script:TrackedDirs += $d
    $zipPath = Join-Path $d 'mini.zip'
    $b1 = [Text.Encoding]::UTF8.GetBytes('parent-file')
    $b2 = [Text.Encoding]::UTF8.GetBytes('child-file')
    $b3 = [Text.Encoding]::UTF8.GetBytes('dir-clash')
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $fs = [IO.File]::Create($zipPath)
    try {
        $zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $e1 = $zip.CreateEntry('nod'); $w1 = $e1.Open(); try { $w1.Write($b1, 0, $b1.Length) } finally { $w1.Dispose() }
            $e2 = $zip.CreateEntry('nod/child.txt'); $w2 = $e2.Open(); try { $w2.Write($b2, 0, $b2.Length) } finally { $w2.Dispose() }
            $e3 = $zip.CreateEntry('clash'); $w3 = $e3.Open(); try { $w3.Write($b3, 0, $b3.Length) } finally { $w3.Dispose() }
            $zip.CreateEntry('clash/') | Out-Null
        } finally { $zip.Dispose() }
    } finally { $fs.Dispose() }
    $h1 = (Get-FileHash -InputStream ([IO.MemoryStream]::new($b1)) -Algorithm SHA256).Hash.ToLowerInvariant()
    $h2 = (Get-FileHash -InputStream ([IO.MemoryStream]::new($b2)) -Algorithm SHA256).Hash.ToLowerInvariant()
    $h3 = (Get-FileHash -InputStream ([IO.MemoryStream]::new($b3)) -Algorithm SHA256).Hash.ToLowerInvariant()
    $o = Get-Content -LiteralPath $Base.Prov -Raw | ConvertFrom-Json
    $o.files = @(
        [PSCustomObject]@{ relative_path = 'nod'; size_bytes = $b1.Length; sha256 = $h1; pe_machine = $null },
        [PSCustomObject]@{ relative_path = 'nod/child.txt'; size_bytes = $b2.Length; sha256 = $h2; pe_machine = $null },
        [PSCustomObject]@{ relative_path = 'clash'; size_bytes = $b3.Length; sha256 = $h3; pe_machine = $null }
    )
    $provPath = Join-Path $d 'provenance.json'
    ($o | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $provPath -Encoding utf8
    Register-RunFile $zipPath; Register-RunFile $provPath
    $zhash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    return @{ Zip = $zipPath; Prov = $provPath; ZipHash = $zhash; Src = $Base.Src; Pilot = $Base.Pilot }
}

# 1. Real-bundle positive is opt-in (parent runs it); otherwise explicit skip.
if ($RealArchivePath -and $RealProvenancePath -and $RealArchiveSha256 -and $RealSourceSha -and $RealPilotSha -and $RealVariant) {
    try {
        $s = Invoke-VerifyWindowsCloudBundle -ArchivePath $RealArchivePath -ProvenancePath $RealProvenancePath -ExpectedArchiveSha256 $RealArchiveSha256 -ExpectedSourceSha $RealSourceSha -ExpectedPilotSha $RealPilotSha -ExpectedVariant $RealVariant
        Write-Host ("PASS positive-real-bundle (files={0})" -f $s.Files); $script:Pass++
    } catch { Write-Host "FAIL positive-real-bundle ($_)" ; $script:FailCount++ }
} else {
    Write-Host 'SKIP positive-real-bundle (opt-in params absent; parent runs real positive)'
}

# 2. Path-safety helper cases.
$cases = @(
    @{ N = '../evil.dll'; Ok = $false }, @{ N = 'a\..\b'; Ok = $false },
    @{ N = '/abs/path'; Ok = $false }, @{ N = 'C:/win'; Ok = $false },
    @{ N = 'dir/stream:ads'; Ok = $false }, @{ N = 'CON.txt'; Ok = $false },
    @{ N = 'sub/NUL'; Ok = $false }, @{ N = 'dir/name.'; Ok = $false },
    @{ N = 'dir/trailing '; Ok = $false },
    @{ N = 'q/bad?.txt'; Ok = $false }, @{ N = 'a*b'; Ok = $false },
    @{ N = 'x<y'; Ok = $false }, @{ N = 'z|q'; Ok = $false },
    @{ N = 'quoXte.txt'; Ok = $true }, @{ N = ('ctrl' + [char]1 + '.txt'); Ok = $false },
    @{ N = 'ok/sub/file.txt'; Ok = $true }
)
$helperOk = $true
foreach ($c in $cases) {
    $r = Test-ZipEntryPathSafety -Name $c.N
    if (($null -eq $r) -ne $c.Ok) { Write-Host "FAIL path-helper '$($c.N)'"; $helperOk = $false }
}
if ($helperOk) { Write-Host 'PASS path-helper-matrix'; $script:Pass++ } else { $script:FailCount++ }

# 3. Case-collision helper.
$d = Test-NameCaseCollision -Names @('a/B.txt', 'A/b.TXT', 'c.txt')
if ($d) { Write-Host 'PASS case-collision-helper'; $script:Pass++ } else { Write-Host 'FAIL case-collision-helper'; $script:FailCount++ }

# 4-8. Mini-fixture end-to-end negatives.
$f = New-MiniFixture -Tag 'base'
try {
    Invoke-VerifyWindowsCloudBundle -ArchivePath $f.Zip -ProvenancePath $f.Prov -ExpectedArchiveSha256 $f.ZipHash -ExpectedSourceSha $f.Src -ExpectedPilotSha $f.Pilot -ExpectedVariant 'local-write' | Out-Null
    Write-Host 'PASS mini-positive'; $script:Pass++
} catch { Write-Host "FAIL mini-positive ($_)" ; $script:FailCount++ }

Assert-Fails -Name 'source-mismatch' -Body { Invoke-VerifyWindowsCloudBundle -ArchivePath $f.Zip -ProvenancePath $f.Prov -ExpectedArchiveSha256 $f.ZipHash -ExpectedSourceSha 'cccccccccccccccccccccccccccccccccccccccc' -ExpectedPilotSha $f.Pilot -ExpectedVariant 'local-write' }
Assert-Fails -Name 'archive-sha-mismatch' -Body { Invoke-VerifyWindowsCloudBundle -ArchivePath $f.Zip -ProvenancePath $f.Prov -ExpectedArchiveSha256 '0000000000000000000000000000000000000000000000000000000000000000' -ExpectedSourceSha $f.Src -ExpectedPilotSha $f.Pilot -ExpectedVariant 'local-write' }

# Flags mismatch (48 -> 47).
$tamperProv = New-EditedProv -Tag 'flags-tamper' -SourceProv $f.Prov -Edit { param($o) $o.verification.native_local_write_encoder_tests.expected_test_count = 47 }
Assert-Fails -Name 'flags-48-required' -Body { Invoke-VerifyWindowsCloudBundle -ArchivePath $f.Zip -ProvenancePath $tamperProv -ExpectedArchiveSha256 $f.ZipHash -ExpectedSourceSha $f.Src -ExpectedPilotSha $f.Pilot -ExpectedVariant 'local-write' }

# Per-file hash mismatch: tamper manifest sha.
$hashProv = New-EditedProv -Tag 'hash-tamper' -SourceProv $f.Prov -Edit { param($o) $o.files[0].sha256 = 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff' }
Assert-Fails -Name 'per-file-hash-mismatch' -Body { Invoke-VerifyWindowsCloudBundle -ArchivePath $f.Zip -ProvenancePath $hashProv -ExpectedArchiveSha256 $f.ZipHash -ExpectedSourceSha $f.Src -ExpectedPilotSha $f.Pilot -ExpectedVariant 'local-write' }

# Mismatched native library: x64 PE bytes must fail the ARM64 stream check.
$fx = New-MiniFixture -Tag 'x64dll' -DllMachine 0x8664
Assert-Fails -Name 'non-arm64-dll-rejected' -Body { Invoke-VerifyWindowsCloudBundle -ArchivePath $fx.Zip -ProvenancePath $fx.Prov -ExpectedArchiveSha256 $fx.ZipHash -ExpectedSourceSha $fx.Src -ExpectedPilotSha $fx.Pilot -ExpectedVariant 'local-write' }

# String-typed boolean flag must be rejected (no string coercion).
$boolProv = New-EditedProv -Tag 'bool-string' -SourceProv $f.Prov -Edit { param($o) $o.verification.all_pe_files_arm64 = 'true' }
Assert-Fails -Name 'bool-string-flag-rejected' -Body { Invoke-VerifyWindowsCloudBundle -ArchivePath $f.Zip -ProvenancePath $boolProv -ExpectedArchiveSha256 $f.ZipHash -ExpectedSourceSha $f.Src -ExpectedPilotSha $f.Pilot -ExpectedVariant 'local-write' }

# Inexact native library name must be rejected (exact bundle path required).
$natProv = New-EditedProv -Tag 'native-name' -SourceProv $f.Prov -Edit { param($o) $o.verification.native_local_write_encoder_tests.native_library = 'rust_lib_bluebubbles.dll' }
Assert-Fails -Name 'inexact-native-library-rejected' -Body { Invoke-VerifyWindowsCloudBundle -ArchivePath $f.Zip -ProvenancePath $natProv -ExpectedArchiveSha256 $f.ZipHash -ExpectedSourceSha $f.Src -ExpectedPilotSha $f.Pilot -ExpectedVariant 'local-write' }

# File/directory ancestor collision must be rejected.
$cf = New-CollisionFixture -Tag 'collide' -Base $f
Assert-Fails -Name 'file-dir-ancestor-collision' -Body { Invoke-VerifyWindowsCloudBundle -ArchivePath $cf.Zip -ProvenancePath $cf.Prov -ExpectedArchiveSha256 $cf.ZipHash -ExpectedSourceSha $cf.Src -ExpectedPilotSha $cf.Pilot -ExpectedVariant 'local-write' }

try {
    $fr = New-MiniFixture -Tag 'readonly' -Variant 'read-only'
    Invoke-VerifyWindowsCloudBundle -ArchivePath $fr.Zip -ProvenancePath $fr.Prov -ExpectedArchiveSha256 $fr.ZipHash -ExpectedSourceSha $fr.Src -ExpectedPilotSha $fr.Pilot -ExpectedVariant 'read-only' | Out-Null
    Write-Host 'PASS readonly-positive (bare source12 id, writer/auto-send false)'; $script:Pass++
} catch { Write-Host "FAIL readonly-positive ($_)" ; $script:FailCount++ }
Assert-Fails -Name 'unbuilt-replay-variant-rejected' -Body {
    Invoke-VerifyWindowsCloudBundle -ArchivePath $f.Zip -ProvenancePath $f.Prov -ExpectedArchiveSha256 $f.ZipHash -ExpectedSourceSha $f.Src -ExpectedPilotSha $f.Pilot -ExpectedVariant 'replay-excluded-chats'
}
$wsProv = New-EditedProv -Tag 'writer-string' -SourceProv $f.Prov -Edit { param($o) $o.build.writer_defines_present = 'true' }
Assert-Fails -Name 'writer-string-flag-rejected' -Body { Invoke-VerifyWindowsCloudBundle -ArchivePath $f.Zip -ProvenancePath $wsProv -ExpectedArchiveSha256 $f.ZipHash -ExpectedSourceSha $f.Src -ExpectedPilotSha $f.Pilot -ExpectedVariant 'local-write' }
Assert-Fails -Name 'variant-allowlist' -Body { Invoke-VerifyWindowsCloudBundle -ArchivePath $f.Zip -ProvenancePath $f.Prov -ExpectedArchiveSha256 $f.ZipHash -ExpectedSourceSha $f.Src -ExpectedPilotSha $f.Pilot -ExpectedVariant 'bogus-variant' }

Write-Host ("RESULT pass={0} fail={1}" -f $script:Pass, $script:FailCount)
} finally {
    Remove-RunTree
}
if ($script:FailCount -gt 0) { exit 1 }
