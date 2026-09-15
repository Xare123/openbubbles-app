[CmdletBinding()]
param(
    [string] $ArchivePath,
    [string] $ProvenancePath,
    [string] $ExpectedArchiveSha256,
    [string] $ExpectedSourceSha,
    [string] $ExpectedPilotSha,
    [string] $ExpectedSignerThumbprint,
    [string] $Repository = '',
    [string] $ProfileRoot = '',
    [string] $TestHostDirectory = '',
    [string] $ReceiptPath = '',
    [string] $SignTool = 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\arm64\signtool.exe',
    [ValidateRange(1, 10000)]
    [int] $ExpectedNativeEncoderTestCount = 51,
    [switch] $FunctionsOnlyForTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Bounded, fail-closed importer for cloud-built Windows native-test-host bundles.
# Verifies a read-only native-test-host archive (exactly native-compose-tests.exe,
# rust_lib_bluebubbles.dll, objectbox.dll), stages it under the isolated
# cloudkit-v2-dev profile, signs the two signable binaries with the expected
# signer, never signs objectbox.dll, and atomically installs the three binaries
# plus a source-bound receipt. This helper imports only. A separately reviewed
# launcher must own any later replay so execution failure cannot roll back a
# valid import transaction.
# Hard prohibitions: no local-write variant, no other profile, no profile-data
# reads or writes, no app launch, no network access, no Git state mutation.
# Only the archive, provenance, staging area, test-host directory, signtool,
# and receipt move.
#
# Both dependency scripts have top-level param blocks. Dot-sourcing them is
# intentional so their helper functions enter this script scope, but it also
# overwrites same-named importer parameters. Preserve and restore the complete
# invocation state so direct -File execution cannot silently become a
# functions-only no-op.
$nativeTestHostInvocationState = @{
    ArchivePath = $ArchivePath
    ProvenancePath = $ProvenancePath
    ExpectedArchiveSha256 = $ExpectedArchiveSha256
    ExpectedSourceSha = $ExpectedSourceSha
    ExpectedPilotSha = $ExpectedPilotSha
    ExpectedSignerThumbprint = $ExpectedSignerThumbprint
    Repository = $Repository
    ProfileRoot = $ProfileRoot
    TestHostDirectory = $TestHostDirectory
    ReceiptPath = $ReceiptPath
    SignTool = $SignTool
    ExpectedNativeEncoderTestCount = $ExpectedNativeEncoderTestCount
    FunctionsOnlyForTest = [bool]$FunctionsOnlyForTest
}
try {
    . (Join-Path $PSScriptRoot 'verify_windows_cloud_bundle.ps1') -FunctionsOnlyForTest
    . (Join-Path $PSScriptRoot 'run_cloud_sync_v2_dev.ps1') -FunctionsOnlyForTest
}
finally {
    $ArchivePath = $nativeTestHostInvocationState.ArchivePath
    $ProvenancePath = $nativeTestHostInvocationState.ProvenancePath
    $ExpectedArchiveSha256 = $nativeTestHostInvocationState.ExpectedArchiveSha256
    $ExpectedSourceSha = $nativeTestHostInvocationState.ExpectedSourceSha
    $ExpectedPilotSha = $nativeTestHostInvocationState.ExpectedPilotSha
    $ExpectedSignerThumbprint = $nativeTestHostInvocationState.ExpectedSignerThumbprint
    $Repository = $nativeTestHostInvocationState.Repository
    $ProfileRoot = $nativeTestHostInvocationState.ProfileRoot
    $TestHostDirectory = $nativeTestHostInvocationState.TestHostDirectory
    $ReceiptPath = $nativeTestHostInvocationState.ReceiptPath
    $SignTool = $nativeTestHostInvocationState.SignTool
    $ExpectedNativeEncoderTestCount = $nativeTestHostInvocationState.ExpectedNativeEncoderTestCount
    $FunctionsOnlyForTest = $nativeTestHostInvocationState.FunctionsOnlyForTest
}

function Fail-NativeTestHostImport {
    param([Parameter(Mandatory)][string] $Message)
    throw "IMPORT-FAIL: $Message"
}

function Get-NativeTestHostObjectBoxPin {
    # ObjectBox 5.3.2 Windows ARM64, the same vendor pin enforced by
    # Assert-HarnessObjectBoxRuntime. Review this pin on upgrades.
    return '9c8583c4015ab9e4ce2ed3d2d581811fa059e03bb528cb8c8387adcdfda8d8a5'
}

function Get-NativeTestHostRuntimeNames {
    return @('native-compose-tests.exe', 'rust_lib_bluebubbles.dll', 'objectbox.dll')
}

function Get-NativeTestHostReceiptLeaf {
    return 'native-test-host-receipt.json'
}

function Get-NativeTestHostBlockedProcessNames {
    return @('bluebubbles_app', 'flutter', 'dart', 'native-compose-tests')
}

function Get-NativeTestHostWriterBlockedEnvNames {
    return @(
        'OPENBUBBLES_CLOUD_SYNC_V2_OUTBOUND_CANARY',
        'OPENBUBBLES_CLOUDKIT_WRITER_OWNER',
        'OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_REPLAY_EXCLUDED_CHATS',
        'OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_FINDMY_PROBE',
        'OPENBUBBLES_RUN_FINDMY_WINDOWS_LIVE',
        'OPENBUBBLES_VERIFY_EDIT_CLAIM',
        'OPENBUBBLES_VERIFY_CHAIN_UNSEND'
    )
}

function Get-NativeTestHostSeparator {
    return [string][IO.Path]::DirectorySeparatorChar
}

function Get-NativeTestHostFullPath {
    param([Parameter(Mandatory)][string] $Path)
    return [System.IO.Path]::GetFullPath($Path)
}

function Get-NativeTestHostTrimmedPath {
    param([Parameter(Mandatory)][string] $Path)
    return $Path.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Assert-NativeTestHostPhysicalDirectory {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Label)
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if (-not $item.PSIsContainer) { Fail-NativeTestHostImport "$Label is not a directory: $Path" }
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { Fail-NativeTestHostImport "$Label is a reparse point: $Path" }
    return $item.FullName
}

function Assert-NativeTestHostUnderParent {
    param([Parameter(Mandatory)][string] $Child, [Parameter(Mandatory)][string] $Parent, [Parameter(Mandatory)][string] $Label)
    $childFull = Get-NativeTestHostFullPath -Path $Child
    $parentFull = Get-NativeTestHostTrimmedPath -Path (Get-NativeTestHostFullPath -Path $Parent)
    $prefix = $parentFull + (Get-NativeTestHostSeparator)
    if (($childFull -ne $parentFull) -and (-not $childFull.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase))) { Fail-NativeTestHostImport "$Label escapes its parent: $Child" }
    return $childFull
}

function Assert-NativeTestHostPlainPath {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Label)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $current = $item
    while ($null -ne $current) {
        if (($current.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { Fail-NativeTestHostImport "$Label traverses a reparse point: $($current.FullName)" }
        $parent = [System.IO.Path]::GetDirectoryName((Get-NativeTestHostTrimmedPath -Path $current.FullName))
        if ([string]::IsNullOrWhiteSpace($parent) -or ($parent -eq $current.FullName)) { break }
        $current = Get-Item -LiteralPath $parent -Force -ErrorAction Stop
    }
    return $item.FullName
}

function Get-NativeTestHostCheckoutState {
    param([Parameter(Mandatory)][string] $Repository)
    # Read-only Git inspection only: rev-parse and status never mutate state.
    $head = (& git -C $Repository rev-parse HEAD).Trim()
    if (($LASTEXITCODE -ne 0) -or ($head -cnotmatch '^[0-9a-f]{40}$')) { Fail-NativeTestHostImport 'could not resolve the checkout head commit' }
    $statusLines = @(& git -C $Repository status --porcelain=v1 --untracked-files=all --ignore-submodules=dirty)
    if ($LASTEXITCODE -ne 0) { Fail-NativeTestHostImport 'could not inspect the checkout state' }
    $dirty = New-Object System.Collections.Generic.List[string]
    foreach ($line in $statusLines) {
        if ([string]::IsNullOrWhiteSpace($line) -or ($line.Length -lt 4)) { continue }
        $path = $line.Substring(3).Trim().Trim('"')
        if ($path -match '^(.*) -> (.*)$') { $path = $Matches[2].Trim().Trim('"') }
        $path = $path.TrimEnd('/')
        $top = ($path -split '/')[0]
        if (($top -cin @('lib', 'rust', 'rustpush', 'rust_builder', 'windows')) -or ($path -cin @('pubspec.yaml', 'pubspec.lock'))) { $dirty.Add($line.Trim()) }
    }
    return [pscustomobject]@{ Head = $head; Clean = ($dirty.Count -eq 0); DirtyLines = @($dirty) }
}

function Assert-NativeTestHostSourceTree {
    param([Parameter(Mandatory)][string] $Repository, [Parameter(Mandatory)][string] $ExpectedSourceSha)
    $state = Get-NativeTestHostCheckoutState -Repository $Repository
    if ($state.Head -cne $ExpectedSourceSha) { Fail-NativeTestHostImport "source tree is not the expected revision (checkout $($state.Head), expected $ExpectedSourceSha)" }
    if (-not $state.Clean) {
        $shown = (($state.DirtyLines | Select-Object -First 5) -join '; ')
        Fail-NativeTestHostImport "source tree is dirty; commit or stash tracked source changes and retry ($shown)"
    }
}

function Get-NativeTestHostCanonicalProfile {
    if ([string]::IsNullOrWhiteSpace($env:APPDATA)) { Fail-NativeTestHostImport 'APPDATA is unavailable' }
    return Get-NativeTestHostTrimmedPath -Path (Get-NativeTestHostFullPath -Path (Join-Path $env:APPDATA 'OpenBubbles/cloudkit-v2-dev'))
}

function Resolve-NativeTestHostProfileRoot {
    param([string] $ProfileRoot = '', [string] $ApprovedBaseForTest = '')
    $approvedBase = $ApprovedBaseForTest
    if ([string]::IsNullOrWhiteSpace($approvedBase)) { $approvedBase = Get-NativeTestHostCanonicalProfile }
    else { $approvedBase = Get-NativeTestHostTrimmedPath -Path (Get-NativeTestHostFullPath -Path $approvedBase) }
    $candidate = $ProfileRoot
    if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = $approvedBase }
    $candidateFull = Get-NativeTestHostTrimmedPath -Path (Get-NativeTestHostFullPath -Path $candidate)
    $separators = @([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    foreach ($segment in @($candidateFull.Split($separators, [System.StringSplitOptions]::RemoveEmptyEntries))) {
        if (($segment -ieq 'alpha') -or ($segment -ieq 'beta') -or ($segment -ieq 'canary')) { Fail-NativeTestHostImport "refusing protected profile segment '$segment': $candidateFull" }
    }
    if ($candidateFull -cne $approvedBase) { Fail-NativeTestHostImport "profile must resolve exactly to the isolated dev profile ($approvedBase); refusing $candidateFull" }
    if (-not (Test-Path -LiteralPath $candidateFull -PathType Container)) { Fail-NativeTestHostImport "isolated profile does not exist: $candidateFull" }
    $null = Assert-NativeTestHostPlainPath -Path $candidateFull -Label 'isolated profile'
    $marker = Join-Path $candidateFull '.openbubbles-cloud-sync-v2-windows-dev'
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { Fail-NativeTestHostImport "isolated profile marker is missing: $marker" }
    if ((Get-Content -LiteralPath $marker -Raw) -cne 'openbubbles-cloud-sync-v2-windows-dev-profile:v1') { Fail-NativeTestHostImport 'isolated profile marker contents are invalid' }
    return $candidateFull
}

function Get-NativeTestHostBlockingProcess {
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($name in @(Get-NativeTestHostBlockedProcessNames)) {
        $hits = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
        if ($hits.Count -gt 0) { $found.Add($name) }
    }
    return @($found)
}

function Assert-NativeTestHostNoBlockingProcess {
    $found = @(Get-NativeTestHostBlockingProcess)
    if ($found.Count -ne 0) { Fail-NativeTestHostImport "a profile-owning process is running ($($found -join ', ')); close it and retry" }
}

function Get-NativeTestHostSignatureState {
    param([Parameter(Mandatory)][string] $Path)
    return Get-AuthenticodeSignature -LiteralPath $Path
}

function Invoke-NativeTestHostSignBinary {
    param([Parameter(Mandatory)][string] $Binary, [Parameter(Mandatory)][string] $SignToolPath, [Parameter(Mandatory)][string] $Thumbprint)
    & $SignToolPath sign /sha1 $Thumbprint /fd SHA256 $Binary
    if ($LASTEXITCODE -ne 0) { Fail-NativeTestHostImport "signtool failed for $Binary" }
}

function Assert-NativeTestHostObjectBoxPin {
    param([Parameter(Mandatory)][string] $Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) { Fail-NativeTestHostImport 'the ObjectBox runtime must be a physical file' }
    $actual = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -cne (Get-NativeTestHostObjectBoxPin)) { Fail-NativeTestHostImport 'objectbox.dll does not match the pinned vendor runtime; refusing to install' }
}

function Assert-NativeTestHostAuthenticode {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $ExpectedThumbprint)
    $state = Get-NativeTestHostSignatureState -Path $Path
    if ($state.Status -ne [System.Management.Automation.SignatureStatus]::Valid) { Fail-NativeTestHostImport "binary signature is not valid: $Path" }
    if ([string]$state.SignerCertificate.Thumbprint -ne $ExpectedThumbprint) { Fail-NativeTestHostImport "binary signer thumbprint mismatch: $Path" }
}

function Read-NativeTestHostPeMachine {
    param([Parameter(Mandatory)][string] $Path)
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $buffer = New-Object byte[] 512
        $read = 0
        while ($read -lt 512) {
            $taken = $stream.Read($buffer, $read, 512 - $read)
            if ($taken -le 0) { break }
            $read += $taken
        }
        if ($read -lt 64) { return $null }
        $head = New-Object byte[] $read
        [System.Array]::Copy($buffer, $head, $read)
        return Get-PeMachineFromHeader -Bytes $head
    }
    finally { $stream.Dispose() }
}

function Write-NativeTestHostReceipt {
    param(
        [Parameter(Mandatory)][string] $ReceiptPath,
        [Parameter(Mandatory)][string] $SourceCommit,
        [Parameter(Mandatory)][string] $PilotCommit,
        [Parameter(Mandatory)][string] $ArchiveSha256,
        [Parameter(Mandatory)][string] $ProvenanceSha256,
        [Parameter(Mandatory)][string] $TestHostSha256,
        [Parameter(Mandatory)][string] $RustLibrarySha256,
        [Parameter(Mandatory)][string] $ObjectBoxSha256,
        [Parameter(Mandatory)][string] $SigningThumbprint
    )
    $receiptDirectory = Split-Path -Parent $ReceiptPath
    if (-not (Test-Path -LiteralPath $receiptDirectory -PathType Container)) { New-Item -ItemType Directory -Path $receiptDirectory -Force | Out-Null }
    $temporaryReceipt = Join-Path $receiptDirectory ('.windows-native-test-host-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [ordered]@{
            version = 'cloud-sync-v2-windows-native-test-host-v1'
            artifact_mode = 'native-test-host'
            variant = 'read-only'
            source_commit = $SourceCommit
            pilot_commit = $PilotCommit
            archive_sha256 = $ArchiveSha256
            provenance_sha256 = $ProvenanceSha256
            files = [ordered]@{
                'native-compose-tests.exe' = $TestHostSha256
                'rust_lib_bluebubbles.dll' = $RustLibrarySha256
                'objectbox.dll' = $ObjectBoxSha256
            }
            signing_thumbprint = $SigningThumbprint
            created_utc = [datetime]::UtcNow.ToString('o')
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $temporaryReceipt -Encoding UTF8
        Move-Item -LiteralPath $temporaryReceipt -Destination $ReceiptPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryReceipt -PathType Leaf) { Remove-Item -LiteralPath $temporaryReceipt -Force }
    }
}

function Test-NativeTestHostReceipt {
    param(
        [Parameter(Mandatory)][string] $ReceiptPath,
        [Parameter(Mandatory)][string] $TestHostDirectory,
        [Parameter(Mandatory)][string] $SourceCommit,
        [Parameter(Mandatory)][string] $PilotCommit,
        [Parameter(Mandatory)][string] $ArchiveSha256,
        [Parameter(Mandatory)][string] $ProvenanceSha256
    )
    if (-not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) { return $false }
    try {
        $receipt = Get-Content -LiteralPath $ReceiptPath -Raw | ConvertFrom-Json
        if (($receipt.version -cne 'cloud-sync-v2-windows-native-test-host-v1') -or ($receipt.artifact_mode -cne 'native-test-host') -or ($receipt.variant -cne 'read-only')) { return $false }
        if (($receipt.source_commit -cne $SourceCommit) -or ($receipt.pilot_commit -cne $PilotCommit)) { return $false }
        if (($receipt.archive_sha256 -cne $ArchiveSha256) -or ($receipt.provenance_sha256 -cne $ProvenanceSha256)) { return $false }
        foreach ($leaf in @(Get-NativeTestHostRuntimeNames)) {
            $installed = Join-Path $TestHostDirectory $leaf
            if (-not (Test-Path -LiteralPath $installed -PathType Leaf)) { return $false }
            $actual = (Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actual -cne [string]$receipt.files.$leaf) { return $false }
        }
        return $true
    }
    catch { return $false }
}

function Import-VerifiedWindowsNativeTestHost {
    param(
        [Parameter(Mandatory)][string] $ArchivePath,
        [Parameter(Mandatory)][string] $ProvenancePath,
        [Parameter(Mandatory)][string] $ExpectedArchiveSha256,
        [Parameter(Mandatory)][string] $ExpectedSourceSha,
        [Parameter(Mandatory)][string] $ExpectedPilotSha,
        [Parameter(Mandatory)][string] $ExpectedSignerThumbprint,
        [Parameter(Mandatory)][string] $Repository,
        [string] $ProfileRoot = '',
        [string] $TestHostDirectory = '',
        [string] $ReceiptPath = '',
        [Parameter(Mandatory)][string] $SignTool,
        [int] $ExpectedNativeEncoderTestCount = 51
    )
    foreach ($field in @('ArchivePath', 'ProvenancePath', 'ExpectedArchiveSha256', 'ExpectedSourceSha', 'ExpectedPilotSha', 'ExpectedSignerThumbprint', 'Repository', 'SignTool')) {
        $value = Get-Variable -Name $field -ValueOnly
        if ([string]::IsNullOrWhiteSpace([string]$value)) { Fail-NativeTestHostImport "$field is required" }
    }
    if ($ExpectedArchiveSha256 -cnotmatch '^[0-9a-f]{64}$') { Fail-NativeTestHostImport 'expected archive SHA must be lowercase 64-hex' }
    if ($ExpectedSourceSha -cnotmatch '^[0-9a-f]{40}$') { Fail-NativeTestHostImport 'expected source SHA must be lowercase 40-hex' }
    if ($ExpectedPilotSha -cnotmatch '^[0-9a-f]{40}$') { Fail-NativeTestHostImport 'expected pilot SHA must be lowercase 40-hex' }
    if ($ExpectedSignerThumbprint -notmatch '^[0-9A-Fa-f]{40}$') { Fail-NativeTestHostImport 'expected signer thumbprint must be 40-hex' }
    foreach ($leaf in @(@{ P = $ArchivePath; L = 'archive' }, @{ P = $ProvenancePath; L = 'provenance' }, @{ P = $SignTool; L = 'signtool' })) {
        if (-not (Test-Path -LiteralPath $leaf.P -PathType Leaf)) { Fail-NativeTestHostImport ($leaf.L + ' not found: ' + $leaf.P) }
        $leafItem = Get-Item -LiteralPath $leaf.P -Force
        if (($leafItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { Fail-NativeTestHostImport ($leaf.L + ' is a reparse point: ' + $leaf.P) }
    }
    $repoFull = Assert-NativeTestHostPhysicalDirectory -Path $Repository -Label 'repository'
    $profileFull = Resolve-NativeTestHostProfileRoot -ProfileRoot $ProfileRoot
    if ([string]::IsNullOrWhiteSpace($TestHostDirectory)) { $TestHostDirectory = Join-Path $profileFull 'cloud-sync-v2/native-test-host' }
    $testHostFull = Assert-NativeTestHostUnderParent -Child $TestHostDirectory -Parent $profileFull -Label 'test-host directory'
    if ((Split-Path -Leaf (Get-NativeTestHostTrimmedPath -Path $testHostFull)) -cne 'native-test-host') { Fail-NativeTestHostImport 'test-host directory leaf must be exactly native-test-host' }
    if ([string]::IsNullOrWhiteSpace($ReceiptPath)) { $ReceiptPath = Join-Path $testHostFull (Get-NativeTestHostReceiptLeaf) }
    $receiptFull = Assert-NativeTestHostUnderParent -Child $ReceiptPath -Parent $profileFull -Label 'receipt path'
    $sep = Get-NativeTestHostSeparator
    $receiptInsideTestHost = $receiptFull.StartsWith((Get-NativeTestHostTrimmedPath -Path $testHostFull) + $sep, [System.StringComparison]::OrdinalIgnoreCase)
    $testHostParent = Split-Path -Parent (Get-NativeTestHostTrimmedPath -Path $testHostFull)
    if (-not (Test-Path -LiteralPath $testHostParent -PathType Container)) { New-Item -ItemType Directory -Path $testHostParent -Force | Out-Null }
    $testHostParent = Assert-NativeTestHostPhysicalDirectory -Path $testHostParent -Label 'test-host parent'
    $runTag = [guid]::NewGuid().ToString('N')
    $staging = Join-Path $testHostParent ('.native-test-host-stage-' + $runTag)
    $rollbackLeaf = (Split-Path -Leaf (Get-NativeTestHostTrimmedPath -Path $testHostFull)) + '.rollback-' + $runTag
    $rollbackSibling = Join-Path $testHostParent $rollbackLeaf
    $receiptBackup = $receiptFull + '.rollback-' + $runTag
    $launcherLock = $null
    $movedTestHost = $false
    $movedReceipt = $false
    $installedNew = $false
    $receiptWritten = $false
    $stagingCreated = $false
    $receiptExisted = Test-Path -LiteralPath $receiptFull -PathType Leaf
    try {
        try { $launcherLock = Enter-ProfileScopedLauncherLock -ProfilePath $profileFull }
        catch { Fail-NativeTestHostImport ("profile ownership is held by another launcher: " + $_.Exception.Message) }
        Assert-NativeTestHostNoBlockingProcess
        Assert-NativeTestHostSourceTree -Repository $repoFull -ExpectedSourceSha $ExpectedSourceSha
        $null = Invoke-VerifyWindowsCloudBundle -ArchivePath $ArchivePath -ProvenancePath $ProvenancePath -ExpectedArchiveSha256 $ExpectedArchiveSha256 -ExpectedSourceSha $ExpectedSourceSha -ExpectedPilotSha $ExpectedPilotSha -ExpectedVariant 'read-only' -ExpectedArtifactMode 'native-test-host' -ExpectedNativeEncoderTestCount $ExpectedNativeEncoderTestCount
        $provenanceHash = (Get-FileHash -LiteralPath $ProvenancePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $provenanceDoc = Get-Content -LiteralPath $ProvenancePath -Raw | ConvertFrom-Json
        $manifest = @{}
        foreach ($entry in @($provenanceDoc.files)) {
            if ($manifest.ContainsKey($entry.relative_path)) { Fail-NativeTestHostImport 'duplicate manifest path' }
            $manifest[$entry.relative_path] = $entry
        }
        $runtimeNames = @(Get-NativeTestHostRuntimeNames)
        if ($manifest.Count -ne $runtimeNames.Count) { Fail-NativeTestHostImport 'provenance manifest must list exactly the three runtime files' }
        foreach ($name in $runtimeNames) {
            if (-not $manifest.ContainsKey($name)) { Fail-NativeTestHostImport "provenance manifest is missing '$name'" }
        }
        if (Test-Path -LiteralPath $testHostFull) {
            $existingItem = Get-Item -LiteralPath $testHostFull -Force
            if (-not $existingItem.PSIsContainer) { Fail-NativeTestHostImport 'existing test-host path is not a directory' }
            if (($existingItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { Fail-NativeTestHostImport 'existing test-host directory is a reparse point' }
            $allowed = @($runtimeNames)
            if ($receiptInsideTestHost) { $allowed = @($allowed + @((Split-Path -Leaf $receiptFull))) }
            foreach ($child in @(Get-ChildItem -LiteralPath $testHostFull -Force)) {
                if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { Fail-NativeTestHostImport "existing test-host content is a reparse point: $($child.Name)" }
                if ($child.PSIsContainer) { Fail-NativeTestHostImport "unexpected directory in test-host directory; refusing to snapshot unknown content: $($child.Name)" }
                if ($allowed -cnotcontains $child.Name) { Fail-NativeTestHostImport "unexpected file in test-host directory; refusing to snapshot unknown content: $($child.Name)" }
            }
        }
        $preMoveHashes = @{}
        foreach ($leafName in $runtimeNames) {
            $prior = Join-Path $testHostFull $leafName
            if (Test-Path -LiteralPath $prior -PathType Leaf) { $preMoveHashes[$leafName] = (Get-FileHash -LiteralPath $prior -Algorithm SHA256).Hash.ToLowerInvariant() }
        }
        $receiptPreHash = ''
        if ($receiptExisted) { $receiptPreHash = (Get-FileHash -LiteralPath $receiptFull -Algorithm SHA256).Hash.ToLowerInvariant() }
        if (Test-Path -LiteralPath $staging) { Fail-NativeTestHostImport "staging path already exists: $staging" }
        New-Item -ItemType Directory -Path $staging | Out-Null
        $stagingCreated = $true
        $stagingFull = Assert-NativeTestHostPhysicalDirectory -Path $staging -Label 'staging'
        $stagingPrefix = (Get-NativeTestHostTrimmedPath -Path $stagingFull) + $sep
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead((Get-NativeTestHostFullPath -Path $ArchivePath))
        try {
            $seenLower = @{}
            foreach ($zipEntry in $zip.Entries) {
                $bad = Test-ZipEntryPathSafety -Name $zipEntry.FullName
                if ($bad) { Fail-NativeTestHostImport 'unsafe zip path rejected' }
                $lowerKey = $zipEntry.FullName.ToLowerInvariant()
                if ($seenLower.ContainsKey($lowerKey)) { Fail-NativeTestHostImport 'zip case-insensitive collision rejected' }
                $seenLower[$lowerKey] = $true
            }
            foreach ($zipEntry in $zip.Entries) {
                $destination = [System.IO.Path]::GetFullPath((Join-Path $stagingFull $zipEntry.FullName))
                if (($destination -ne $stagingFull) -and (-not $destination.StartsWith($stagingPrefix, [System.StringComparison]::OrdinalIgnoreCase))) { Fail-NativeTestHostImport 'extraction escapes staging' }
                if ($zipEntry.FullName.EndsWith('/')) {
                    if (-not (Test-Path -LiteralPath $destination)) { New-Item -ItemType Directory -Path $destination -Force | Out-Null }
                }
                else {
                    if (Test-Path -LiteralPath $destination) { Fail-NativeTestHostImport 'extraction collision rejected' }
                    $destinationParent = Split-Path -Parent $destination
                    if (-not (Test-Path -LiteralPath $destinationParent)) { New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null }
                    $readStream = $zipEntry.Open()
                    try {
                        $writeStream = [System.IO.File]::Create($destination)
                        try { $readStream.CopyTo($writeStream) } finally { $writeStream.Dispose() }
                    } finally { $readStream.Dispose() }
                }
            }
        } finally { $zip.Dispose() }
        $stagedFiles = @(Get-ChildItem -LiteralPath $stagingFull -Recurse -Force -File)
        foreach ($stagedFile in $stagedFiles) {
            if (($stagedFile.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { Fail-NativeTestHostImport 'staged reparse point rejected' }
            if (-not $stagedFile.FullName.StartsWith($stagingPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { Fail-NativeTestHostImport 'staged file escapes staging' }
        }
        $slash = '/'
        $fromSep = [string][IO.Path]::DirectorySeparatorChar
        $stagedNames = @($stagedFiles | ForEach-Object { $_.FullName.Substring($stagingPrefix.Length).Replace($fromSep, $slash) })
        $collision = Test-NameCaseCollision -Names $stagedNames
        if ($collision) { Fail-NativeTestHostImport 'staged case-insensitive collision rejected' }
        if ($stagedNames.Count -ne $runtimeNames.Count) { Fail-NativeTestHostImport 'staged inventory must be exactly the three runtime files' }
        foreach ($name in $stagedNames) { if ($runtimeNames -cnotcontains $name) { Fail-NativeTestHostImport "staged file is not an expected runtime file: $name" } }
        foreach ($key in @($manifest.Keys)) { if ($stagedNames -cnotcontains $key) { Fail-NativeTestHostImport "provenance manifest file missing from staging: $key" } }
        foreach ($stagedFile in $stagedFiles) {
            $name = $stagedFile.FullName.Substring($stagingPrefix.Length).Replace($fromSep, $slash)
            $manifestEntry = $manifest[$name]
            if ($stagedFile.Length -ne [long]$manifestEntry.size_bytes) { Fail-NativeTestHostImport "staged file length mismatch: $name" }
            $hex = (Get-FileHash -LiteralPath $stagedFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($hex -cne $manifestEntry.sha256.ToLowerInvariant()) { Fail-NativeTestHostImport "staged file hash mismatch: $name" }
            $machine = Read-NativeTestHostPeMachine -Path $stagedFile.FullName
            if ($machine -ne 0xAA64) { Fail-NativeTestHostImport "staged binary is not ARM64: $name" }
        }
        $stagedObjectBox = Join-Path $stagingFull 'objectbox.dll'
        Assert-NativeTestHostObjectBoxPin -Path $stagedObjectBox
        Assert-HarnessObjectBoxRuntime -RunnerDirectory $stagingFull
        $stagedObjectBoxHash = (Get-FileHash -LiteralPath $stagedObjectBox -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($stagedObjectBoxHash -cne (Get-NativeTestHostObjectBoxPin)) { Fail-NativeTestHostImport 'staged objectbox.dll does not match the pinned vendor runtime' }
        if (Test-Path -LiteralPath $rollbackSibling) { Fail-NativeTestHostImport 'rollback sibling already exists' }
        if (Test-Path -LiteralPath $testHostFull) {
            Move-Item -LiteralPath $testHostFull -Destination $rollbackSibling
            $movedTestHost = $true
            foreach ($leafName in @($preMoveHashes.Keys)) {
                $moved = Join-Path $rollbackSibling $leafName
                if (-not (Test-Path -LiteralPath $moved -PathType Leaf)) { Fail-NativeTestHostImport "rollback snapshot is missing '$leafName'" }
                $movedHash = (Get-FileHash -LiteralPath $moved -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($movedHash -cne $preMoveHashes[$leafName]) { Fail-NativeTestHostImport "rollback snapshot hash mismatch for '$leafName'" }
            }
        }
        if ((-not $receiptInsideTestHost) -and $receiptExisted) {
            if (Test-Path -LiteralPath $receiptBackup) { Fail-NativeTestHostImport 'receipt backup already exists' }
            Move-Item -LiteralPath $receiptFull -Destination $receiptBackup
            $movedReceipt = $true
            $backupHash = (Get-FileHash -LiteralPath $receiptBackup -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($backupHash -cne $receiptPreHash) { Fail-NativeTestHostImport 'receipt rollback snapshot hash mismatch' }
        }
        Move-Item -LiteralPath $stagingFull -Destination $testHostFull
        $installedNew = $true
        $stagingCreated = $false
        $installedObjectBoxHash = (Get-FileHash -LiteralPath (Join-Path $testHostFull 'objectbox.dll') -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($installedObjectBoxHash -cne $stagedObjectBoxHash) { Fail-NativeTestHostImport 'ObjectBox bytes changed during install' }
        Assert-NativeTestHostObjectBoxPin -Path (Join-Path $testHostFull 'objectbox.dll')
        $testHostExe = Join-Path $testHostFull 'native-compose-tests.exe'
        $rustLib = Join-Path $testHostFull 'rust_lib_bluebubbles.dll'
        $signables = @(Get-HarnessSignableArtifacts -RunnerDirectory $testHostFull)
        foreach ($binary in $signables) {
            if ((Get-NativeTestHostSignatureState -Path $binary).Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
                Invoke-NativeTestHostSignBinary -Binary $binary -SignToolPath (Get-NativeTestHostFullPath -Path $SignTool) -Thumbprint $ExpectedSignerThumbprint
            }
            Assert-NativeTestHostAuthenticode -Path $binary -ExpectedThumbprint $ExpectedSignerThumbprint
            $postMachine = Read-NativeTestHostPeMachine -Path $binary
            if ($postMachine -ne 0xAA64) { Fail-NativeTestHostImport "installed binary is not ARM64: $binary" }
        }
        $exeHash = (Get-FileHash -LiteralPath $testHostExe -Algorithm SHA256).Hash.ToLowerInvariant()
        $rustHash = (Get-FileHash -LiteralPath $rustLib -Algorithm SHA256).Hash.ToLowerInvariant()
        $obHash = (Get-FileHash -LiteralPath (Join-Path $testHostFull 'objectbox.dll') -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($obHash -cne (Get-NativeTestHostObjectBoxPin)) { Fail-NativeTestHostImport 'installed objectbox.dll does not match the pinned vendor runtime' }
        Write-NativeTestHostReceipt -ReceiptPath $receiptFull -SourceCommit $ExpectedSourceSha -PilotCommit $ExpectedPilotSha -ArchiveSha256 $ExpectedArchiveSha256.ToLowerInvariant() -ProvenanceSha256 $provenanceHash -TestHostSha256 $exeHash -RustLibrarySha256 $rustHash -ObjectBoxSha256 $obHash -SigningThumbprint $ExpectedSignerThumbprint
        $receiptWritten = $true
        if (-not (Test-NativeTestHostReceipt -ReceiptPath $receiptFull -TestHostDirectory $testHostFull -SourceCommit $ExpectedSourceSha -PilotCommit $ExpectedPilotSha -ArchiveSha256 $ExpectedArchiveSha256.ToLowerInvariant() -ProvenanceSha256 $provenanceHash)) { Fail-NativeTestHostImport 'issued receipt does not match the installed test host' }
        if ($movedTestHost -and (Test-Path -LiteralPath $rollbackSibling)) {
            $rollbackItem = Get-Item -LiteralPath $rollbackSibling -Force
            if (($rollbackItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) { Remove-Item -LiteralPath $rollbackSibling -Recurse -Force }
            else { Fail-NativeTestHostImport 'rollback sibling became a reparse point' }
        }
        if ($movedReceipt -and (Test-Path -LiteralPath $receiptBackup)) { Remove-Item -LiteralPath $receiptBackup -Force }
        Write-Host ("OK import-native-test-host src={0} files={1} receipt={2}" -f $ExpectedSourceSha.Substring(0, 12), $manifest.Count, $receiptFull)
        $importResult = [pscustomobject]@{ TestHostDirectory = $testHostFull; ReceiptPath = $receiptFull; TestHostSha256 = $exeHash; RustLibrarySha256 = $rustHash; ObjectBoxSha256 = $obHash }
        return $importResult
    }
    catch {
        $originalMessage = $_.Exception.Message
        $rollbackNotes = New-Object System.Collections.Generic.List[string]
        if ($installedNew -and (Test-Path -LiteralPath $testHostFull)) {
            try {
                $installedItem = Get-Item -LiteralPath $testHostFull -Force
                if (($installedItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) { Remove-Item -LiteralPath $testHostFull -Recurse -Force }
                else { $rollbackNotes.Add('partial install is a reparse point; left in place') }
            } catch { $rollbackNotes.Add('remove-partial-install failed') }
        }
        if ($movedTestHost -and (Test-Path -LiteralPath $rollbackSibling)) {
            try {
                if (-not (Test-Path -LiteralPath $testHostFull)) { Move-Item -LiteralPath $rollbackSibling -Destination $testHostFull }
                else { $rollbackNotes.Add('rollback sibling retained') }
            } catch { $rollbackNotes.Add('restore-test-host failed') }
        }
        if ($receiptWritten -and (Test-Path -LiteralPath $receiptFull -PathType Leaf) -and (-not $receiptExisted)) {
            try { Remove-Item -LiteralPath $receiptFull -Force } catch { $rollbackNotes.Add('remove-partial-receipt failed') }
        }
        if ($receiptExisted -and (-not $receiptInsideTestHost)) {
            if (Test-Path -LiteralPath $receiptBackup -PathType Leaf) {
                try {
                    if (-not (Test-Path -LiteralPath $receiptFull -PathType Leaf)) { Move-Item -LiteralPath $receiptBackup -Destination $receiptFull }
                    else { $rollbackNotes.Add('receipt backup retained') }
                } catch { $rollbackNotes.Add('restore-receipt failed') }
            }
        }
        if ($stagingCreated -and (Test-Path -LiteralPath $staging)) {
            try {
                $stagingItem = Get-Item -LiteralPath $staging -Force
                if (($stagingItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) { Remove-Item -LiteralPath $staging -Recurse -Force }
                else { $rollbackNotes.Add('staging reparse retained') }
            } catch { $rollbackNotes.Add('remove-staging failed') }
        }
        $suffix = ''
        if ($rollbackNotes.Count -gt 0) { $suffix = ' [rollback-notes: ' + ($rollbackNotes -join '; ') + ']' }
        throw "IMPORT-FAIL: import aborted; test host and receipt rolled back ($originalMessage)$suffix"
    }
    finally {
        if ($null -ne $launcherLock) {
            try { $launcherLock.ReleaseMutex() } catch { }
            $launcherLock.Dispose()
        }
    }
}

if (-not $FunctionsOnlyForTest) {
    if (-not $ArchivePath -or -not $ProvenancePath -or -not $ExpectedArchiveSha256 -or -not $ExpectedSourceSha -or -not $ExpectedPilotSha -or -not $ExpectedSignerThumbprint) {
        throw 'ArchivePath, ProvenancePath, ExpectedArchiveSha256, ExpectedSourceSha, ExpectedPilotSha, and ExpectedSignerThumbprint are all required.'
    }
    $resolvedRepository = $Repository
    if (-not $resolvedRepository) { $resolvedRepository = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path }
    Import-VerifiedWindowsNativeTestHost -ArchivePath $ArchivePath -ProvenancePath $ProvenancePath -ExpectedArchiveSha256 $ExpectedArchiveSha256 -ExpectedSourceSha $ExpectedSourceSha -ExpectedPilotSha $ExpectedPilotSha -ExpectedSignerThumbprint $ExpectedSignerThumbprint -Repository $resolvedRepository -ProfileRoot $ProfileRoot -TestHostDirectory $TestHostDirectory -ReceiptPath $ReceiptPath -SignTool $SignTool -ExpectedNativeEncoderTestCount $ExpectedNativeEncoderTestCount | Out-Null
}
