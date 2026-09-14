[CmdletBinding()]
param(
    [string] $ArchivePath,
    [string] $ProvenancePath,
    [string] $ExpectedArchiveSha256,
    [string] $ExpectedSourceSha,
    [string] $ExpectedPilotSha,
    [string] $Repository = '',
    [string] $ProfileRoot = '',
    [string] $RunnerDirectory = '',
    [string] $ReceiptPath = '',
    [string] $SignTool = 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\arm64\signtool.exe',
    [string] $SigningThumbprint = '8240557965890665F3B49E5FEC83D511CA4F2C9D',
    [ValidateRange(1, 10000)]
    [int] $ExpectedNativeEncoderTestCount = 51,
    [switch] $FunctionsOnlyForTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Bounded, fail-closed importer for cloud-built Windows harness bundles.
# Scope: verify a read-only harness archive, stage it under the target build
# parent, install it into the runner Debug directory, preserve the vendor
# ObjectBox runtime, locally sign unsigned binaries, and issue a receipt that
# stays compatible with Test-HarnessBuildReceipt while binding origin hashes.
# Hard prohibitions: no Apple or profile database reads, no app launch, no
# network access, and no message-content inspection. Only the archive,
# provenance, staging area, runner directory, signtool, and receipt move.
#
# Both dependency scripts have top-level param blocks. Dot-sourcing them is
# intentional so their helper functions enter this script scope, but it also
# overwrites same-named importer parameters. Preserve and restore the complete
# invocation state so direct `-File` execution cannot silently become a
# functions-only no-op.
$importerInvocationState = @{
    ArchivePath = $ArchivePath
    ProvenancePath = $ProvenancePath
    ExpectedArchiveSha256 = $ExpectedArchiveSha256
    ExpectedSourceSha = $ExpectedSourceSha
    ExpectedPilotSha = $ExpectedPilotSha
    Repository = $Repository
    ProfileRoot = $ProfileRoot
    RunnerDirectory = $RunnerDirectory
    ReceiptPath = $ReceiptPath
    SignTool = $SignTool
    SigningThumbprint = $SigningThumbprint
    ExpectedNativeEncoderTestCount = $ExpectedNativeEncoderTestCount
    FunctionsOnlyForTest = [bool]$FunctionsOnlyForTest
}
try {
    . (Join-Path $PSScriptRoot 'verify_windows_cloud_bundle.ps1') -FunctionsOnlyForTest
    . (Join-Path $PSScriptRoot 'run_cloud_sync_v2_dev.ps1') -FunctionsOnlyForTest
}
finally {
    $ArchivePath = $importerInvocationState.ArchivePath
    $ProvenancePath = $importerInvocationState.ProvenancePath
    $ExpectedArchiveSha256 = $importerInvocationState.ExpectedArchiveSha256
    $ExpectedSourceSha = $importerInvocationState.ExpectedSourceSha
    $ExpectedPilotSha = $importerInvocationState.ExpectedPilotSha
    $Repository = $importerInvocationState.Repository
    $ProfileRoot = $importerInvocationState.ProfileRoot
    $RunnerDirectory = $importerInvocationState.RunnerDirectory
    $ReceiptPath = $importerInvocationState.ReceiptPath
    $SignTool = $importerInvocationState.SignTool
    $SigningThumbprint = $importerInvocationState.SigningThumbprint
    $ExpectedNativeEncoderTestCount = $importerInvocationState.ExpectedNativeEncoderTestCount
    $FunctionsOnlyForTest = $importerInvocationState.FunctionsOnlyForTest
}

function Fail-Import {
    param([Parameter(Mandatory)][string] $Message)
    throw "IMPORT-FAIL: $Message"
}

function Get-ImportFullPath {
    param([Parameter(Mandatory)][string] $Path)
    return [System.IO.Path]::GetFullPath($Path)
}

function Assert-ImportPhysicalDirectory {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Label)
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if (-not $item.PSIsContainer) { Fail-Import "$Label is not a directory: $Path" }
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { Fail-Import "$Label is a reparse point: $Path" }
    return $item.FullName
}

function Assert-ImportUnderParent {
    param([Parameter(Mandatory)][string] $Child, [Parameter(Mandatory)][string] $Parent, [Parameter(Mandatory)][string] $Label)
    $childFull = Get-ImportFullPath -Path $Child
    $parentFull = (Get-ImportFullPath -Path $Parent).TrimEnd('\')
    if (($childFull -ne $parentFull) -and (-not $childFull.StartsWith($parentFull + '\', [System.StringComparison]::OrdinalIgnoreCase))) { Fail-Import "$Label escapes its parent: $Child" }
    return $childFull
}

function Get-ImportSignatureState {
    param([Parameter(Mandatory)][string] $Path)
    return Get-AuthenticodeSignature -LiteralPath $Path
}

function Invoke-ImportSignBinary {
    param(
        [Parameter(Mandatory)][string] $Binary,
        [Parameter(Mandatory)][string] $SignToolPath,
        [Parameter(Mandatory)][string] $Thumbprint
    )
    & $SignToolPath sign /sha1 $Thumbprint /fd SHA256 $Binary
    if ($LASTEXITCODE -ne 0) { Fail-Import "signtool failed for $Binary" }
}

function Assert-ImportObjectBoxRuntime {
    param([Parameter(Mandatory)][string] $RunnerDirectory)
    Assert-HarnessObjectBoxRuntime -RunnerDirectory $RunnerDirectory
}

function Write-ImportHarnessReceipt {
    param(
        [Parameter(Mandatory)][string] $ReceiptPath,
        [Parameter(Mandatory)][string] $BuildIdentifier,
        [Parameter(Mandatory)][string] $Runner,
        [Parameter(Mandatory)][string] $RustLibrary,
        [Parameter(Mandatory)][string] $SourceCommit,
        [Parameter(Mandatory)][string] $PilotCommit,
        [Parameter(Mandatory)][string] $ArchiveSha256,
        [Parameter(Mandatory)][string] $ProvenanceSha256
    )
    $runnerHash = (Get-FileHash -LiteralPath $Runner -Algorithm SHA256).Hash.ToLowerInvariant()
    $rustHash = (Get-FileHash -LiteralPath $RustLibrary -Algorithm SHA256).Hash.ToLowerInvariant()
    $receiptDirectory = Split-Path -Parent $ReceiptPath
    New-Item -ItemType Directory -Path $receiptDirectory -Force | Out-Null
    $temporaryReceipt = Join-Path $receiptDirectory ('.windows-harness-import-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [ordered]@{
            version = 'cloud-sync-v2-windows-harness-build-v1'
            build_identifier = $BuildIdentifier
            runner_sha256 = $runnerHash
            rust_library_sha256 = $rustHash
            created_utc = [datetime]::UtcNow.ToString('o')
            origin = [ordered]@{
                source_commit = $SourceCommit
                pilot_commit = $PilotCommit
                archive_sha256 = $ArchiveSha256
                provenance_sha256 = $ProvenanceSha256
                artifact_mode = 'harness'
                variant = 'read-only'
                runner_post_sign_sha256 = $runnerHash
                rust_library_post_sign_sha256 = $rustHash
            }
        } | ConvertTo-Json -Depth 6 -Compress | Set-Content -LiteralPath $temporaryReceipt -Encoding UTF8
        Move-Item -LiteralPath $temporaryReceipt -Destination $ReceiptPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryReceipt -PathType Leaf) { Remove-Item -LiteralPath $temporaryReceipt -Force }
    }
    return [pscustomobject]@{ RunnerSha256 = $runnerHash; RustLibrarySha256 = $rustHash }
}

function Import-VerifiedWindowsCloudHarness {
    param(
        [Parameter(Mandatory)][string] $ArchivePath,
        [Parameter(Mandatory)][string] $ProvenancePath,
        [Parameter(Mandatory)][string] $ExpectedArchiveSha256,
        [Parameter(Mandatory)][string] $ExpectedSourceSha,
        [Parameter(Mandatory)][string] $ExpectedPilotSha,
        [Parameter(Mandatory)][string] $Repository,
        [string] $RunnerDirectory = '',
        [Parameter(Mandatory)][string] $ReceiptPath,
        [Parameter(Mandatory)][string] $SignTool,
        [Parameter(Mandatory)][string] $SigningThumbprint,
        [int] $ExpectedNativeEncoderTestCount = 51
    )
    foreach ($field in @('ArchivePath', 'ProvenancePath', 'ExpectedArchiveSha256', 'ExpectedSourceSha', 'ExpectedPilotSha', 'Repository', 'ReceiptPath', 'SignTool', 'SigningThumbprint')) {
        $value = Get-Variable -Name $field -ValueOnly
        if ([string]::IsNullOrWhiteSpace([string]$value)) { Fail-Import "$field is required" }
    }
    if ($ExpectedArchiveSha256 -cnotmatch '^[0-9a-f]{64}$') { Fail-Import 'expected archive SHA must be lowercase 64-hex' }
    if ($ExpectedSourceSha -cnotmatch '^[0-9a-f]{40}$') { Fail-Import 'expected source SHA must be lowercase 40-hex' }
    if ($ExpectedPilotSha -cnotmatch '^[0-9a-f]{40}$') { Fail-Import 'expected pilot SHA must be lowercase 40-hex' }
    if ($SigningThumbprint -notmatch '^[0-9A-Fa-f]{40}$') { Fail-Import 'signing thumbprint must be 40-hex' }
    foreach ($leaf in @(@{ P = $ArchivePath; L = 'archive' }, @{ P = $ProvenancePath; L = 'provenance' }, @{ P = $SignTool; L = 'signtool' })) {
        if (-not (Test-Path -LiteralPath $leaf.P -PathType Leaf)) { Fail-Import ($leaf.L + ' not found: ' + $leaf.P) }
        $leafItem = Get-Item -LiteralPath $leaf.P -Force
        if (($leafItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { Fail-Import ($leaf.L + ' is a reparse point: ' + $leaf.P) }
    }
    $repoFull = Assert-ImportPhysicalDirectory -Path $Repository -Label 'repository'
    if ([string]::IsNullOrWhiteSpace($RunnerDirectory)) { $RunnerDirectory = Join-Path $repoFull 'build\windows\arm64\runner\Debug' }
    $runnerFull = Get-ImportFullPath -Path $RunnerDirectory
    $runnerFull = Assert-ImportUnderParent -Child $runnerFull -Parent $repoFull -Label 'runner directory'
    $buildParent = Split-Path -Parent $runnerFull
    if (-not (Test-Path -LiteralPath $buildParent -PathType Container)) { New-Item -ItemType Directory -Path $buildParent -Force | Out-Null }
    $buildParent = Assert-ImportPhysicalDirectory -Path $buildParent -Label 'build parent'
    $receiptFull = Get-ImportFullPath -Path $ReceiptPath
    $receiptParent = Split-Path -Parent $receiptFull
    if (-not (Test-Path -LiteralPath $receiptParent -PathType Container)) { New-Item -ItemType Directory -Path $receiptParent -Force | Out-Null }
    $expectedBuildId = $ExpectedSourceSha.Substring(0, 12)
    $runTag = [guid]::NewGuid().ToString('N')
    $staging = Join-Path $buildParent ('.harness-import-stage-' + $runTag)
    $rollbackSibling = Join-Path $buildParent ((Split-Path -Leaf $runnerFull) + '.rollback-' + $runTag)
    $receiptBackup = $receiptFull + '.rollback-' + $runTag
    $movedBuild = $false
    $movedReceipt = $false
    $installedNew = $false
    $receiptWritten = $false
    $stagingCreated = $false
    $hadReceipt = Test-Path -LiteralPath $receiptFull -PathType Leaf
    try {
        $resolvedId = Resolve-HarnessBuildIdentifier -Repository $repoFull
        if ($resolvedId -cne $expectedBuildId) { Fail-Import "source tree is not the exact clean read-only revision (resolved '$resolvedId', expected '$expectedBuildId')" }
        $configId = Get-HarnessConfigurationIdentifier -SourceIdentifier $resolvedId
        if ($configId -cne $expectedBuildId) { Fail-Import "harness configuration is not read-only (got '$configId')" }
        $verifyResult = Invoke-VerifyWindowsCloudBundle -ArchivePath $ArchivePath -ProvenancePath $ProvenancePath -ExpectedArchiveSha256 $ExpectedArchiveSha256 -ExpectedSourceSha $ExpectedSourceSha -ExpectedPilotSha $ExpectedPilotSha -ExpectedVariant 'read-only' -ExpectedArtifactMode 'harness' -ExpectedNativeEncoderTestCount $ExpectedNativeEncoderTestCount
        if ($verifyResult.BuildId -cne $expectedBuildId) { Fail-Import "verified build identifier mismatch (got '$($verifyResult.BuildId)')" }
        $provenanceHash = (Get-FileHash -LiteralPath $ProvenancePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $provenanceDoc = Get-Content -LiteralPath $ProvenancePath -Raw | ConvertFrom-Json
        $manifest = @{}
        foreach ($entry in @($provenanceDoc.files)) {
            if ($manifest.ContainsKey($entry.relative_path)) { Fail-Import "duplicate manifest path" }
            $manifest[$entry.relative_path] = $entry
        }
        if ($manifest.Count -eq 0) { Fail-Import 'provenance files manifest is empty' }
        if (Test-Path -LiteralPath $staging) { Fail-Import "staging path already exists: $staging" }
        New-Item -ItemType Directory -Path $staging | Out-Null
        $stagingCreated = $true
        $stagingFull = Assert-ImportPhysicalDirectory -Path $staging -Label 'staging'
        $stagingPrefix = $stagingFull.TrimEnd('\') + '\'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead((Get-ImportFullPath -Path $ArchivePath))
        try {
            $seenLower = @{}
            foreach ($zipEntry in $zip.Entries) {
                $bad = Test-ZipEntryPathSafety -Name $zipEntry.FullName
                if ($bad) { Fail-Import "unsafe zip path rejected" }
                $lowerKey = $zipEntry.FullName.ToLowerInvariant()
                if ($seenLower.ContainsKey($lowerKey)) { Fail-Import 'zip case-insensitive collision rejected' }
                $seenLower[$lowerKey] = $true
            }
            foreach ($zipEntry in $zip.Entries) {
                $relative = $zipEntry.FullName.Replace('/', '\')
                $destination = [System.IO.Path]::GetFullPath((Join-Path $stagingFull $relative))
                if (($destination -ne $stagingFull) -and (-not $destination.StartsWith($stagingPrefix, [System.StringComparison]::OrdinalIgnoreCase))) { Fail-Import 'extraction escapes staging' }
                if ($zipEntry.FullName.EndsWith('/')) {
                    if (-not (Test-Path -LiteralPath $destination)) { New-Item -ItemType Directory -Path $destination -Force | Out-Null }
                }
                else {
                    if (Test-Path -LiteralPath $destination) { Fail-Import 'extraction collision rejected' }
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
            if (($stagedFile.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { Fail-Import 'staged reparse point rejected' }
            $full = $stagedFile.FullName
            if (-not $full.StartsWith($stagingPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { Fail-Import 'staged file escapes staging' }
        }
        $stagedDirs = @(Get-ChildItem -LiteralPath $stagingFull -Recurse -Force -Directory)
        foreach ($stagedDir in $stagedDirs) {
            if (($stagedDir.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { Fail-Import 'staged reparse point rejected' }
        }
        $stagedNames = @($stagedFiles | ForEach-Object { $_.FullName.Substring($stagingPrefix.Length).Replace('\', '/') })
        $collision = Test-NameCaseCollision -Names $stagedNames
        if ($collision) { Fail-Import 'staged case-insensitive collision rejected' }
        foreach ($name in $stagedNames) { if (-not $manifest.ContainsKey($name)) { Fail-Import 'staged file is not in the provenance manifest (wrong inventory)' } }
        foreach ($key in $manifest.Keys) { if ($stagedNames -notcontains $key) { Fail-Import 'provenance manifest file missing from staging (wrong inventory)' } }
        foreach ($stagedFile in $stagedFiles) {
            $name = $stagedFile.FullName.Substring($stagingPrefix.Length).Replace('\', '/')
            $manifestEntry = $manifest[$name]
            if ($stagedFile.Length -ne [long]$manifestEntry.size_bytes) { Fail-Import 'staged file length mismatch' }
            $hex = (Get-FileHash -LiteralPath $stagedFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($hex -ne $manifestEntry.sha256.ToLowerInvariant()) { Fail-Import 'staged file hash mismatch' }
        }
        $stagedRunner = Join-Path $stagingFull 'bluebubbles_app.exe'
        $stagedRust = Join-Path $stagingFull 'rust_lib_bluebubbles.dll'
        $stagedObjectBox = Join-Path $stagingFull 'objectbox.dll'
        foreach ($required in @($stagedRunner, $stagedRust, $stagedObjectBox)) {
            if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { Fail-Import 'staged bundle is missing a required harness binary (wrong inventory)' }
        }
        Assert-ImportObjectBoxRuntime -RunnerDirectory $stagingFull
        $stagedObjectBoxHash = (Get-FileHash -LiteralPath $stagedObjectBox -Algorithm SHA256).Hash.ToLowerInvariant()
        if (Test-Path -LiteralPath $runnerFull) {
            $runnerItem = Get-Item -LiteralPath $runnerFull -Force
            if (-not $runnerItem.PSIsContainer) { Fail-Import 'existing runner path is not a directory' }
            if (($runnerItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { Fail-Import 'existing runner directory is a reparse point' }
            if (Test-Path -LiteralPath $rollbackSibling) { Fail-Import 'rollback sibling already exists' }
            Move-Item -LiteralPath $runnerFull -Destination $rollbackSibling
            $movedBuild = $true
        }
        if ($hadReceipt) {
            if (Test-Path -LiteralPath $receiptBackup) { Fail-Import 'receipt backup already exists' }
            Move-Item -LiteralPath $receiptFull -Destination $receiptBackup
            $movedReceipt = $true
        }
        Move-Item -LiteralPath $stagingFull -Destination $runnerFull
        $installedNew = $true
        $stagingCreated = $false
        Assert-ImportObjectBoxRuntime -RunnerDirectory $runnerFull
        $installedObjectBoxHash = (Get-FileHash -LiteralPath (Join-Path $runnerFull 'objectbox.dll') -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($installedObjectBoxHash -cne $stagedObjectBoxHash) { Fail-Import 'ObjectBox bytes changed during install' }
        $runnerExe = Join-Path $runnerFull 'bluebubbles_app.exe'
        $rustLib = Join-Path $runnerFull 'rust_lib_bluebubbles.dll'
        $signables = @(Get-HarnessSignableArtifacts -RunnerDirectory $runnerFull)
        foreach ($binary in $signables) {
            if ((Get-ImportSignatureState -Path $binary).Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
                Invoke-ImportSignBinary -Binary $binary -SignToolPath (Get-ImportFullPath -Path $SignTool) -Thumbprint $SigningThumbprint
            }
            if ((Get-ImportSignatureState -Path $binary).Status -ne [System.Management.Automation.SignatureStatus]::Valid) { Fail-Import "harness binary signature is invalid: $binary" }
        }
        $rustState = Get-ImportSignatureState -Path $rustLib
        if ($rustState.Status -ne [System.Management.Automation.SignatureStatus]::Valid) { Fail-Import 'rust library signature is invalid' }
        $actualThumbprint = [string]$rustState.SignerCertificate.Thumbprint
        if ($actualThumbprint -ne $SigningThumbprint) { Fail-Import 'rust library signer thumbprint mismatch' }
        $hashes = Write-ImportHarnessReceipt -ReceiptPath $receiptFull -BuildIdentifier $expectedBuildId -Runner $runnerExe -RustLibrary $rustLib -SourceCommit $ExpectedSourceSha -PilotCommit $ExpectedPilotSha -ArchiveSha256 $ExpectedArchiveSha256.ToLowerInvariant() -ProvenanceSha256 $provenanceHash
        $receiptWritten = $true
        if (-not (Test-HarnessBuildReceipt -ReceiptPath $receiptFull -BuildIdentifier $expectedBuildId -Runner $runnerExe -RustLibrary $rustLib)) { Fail-Import 'issued receipt does not match the installed harness (receipt mismatch)' }
        $receiptDoc = Get-Content -LiteralPath $receiptFull -Raw | ConvertFrom-Json
        if ($receiptDoc.version -cne 'cloud-sync-v2-windows-harness-build-v1') { Fail-Import 'issued receipt version mismatch' }
        if ($receiptDoc.build_identifier -cne $expectedBuildId) { Fail-Import 'issued receipt build identifier mismatch' }
        if ($receiptDoc.runner_sha256 -cne $hashes.RunnerSha256) { Fail-Import 'issued receipt runner hash mismatch' }
        if ($receiptDoc.rust_library_sha256 -cne $hashes.RustLibrarySha256) { Fail-Import 'issued receipt rust library hash mismatch' }
        if ($receiptDoc.origin.source_commit -cne $ExpectedSourceSha) { Fail-Import 'issued receipt source binding mismatch' }
        if ($receiptDoc.origin.pilot_commit -cne $ExpectedPilotSha) { Fail-Import 'issued receipt pilot binding mismatch' }
        if ($receiptDoc.origin.archive_sha256 -cne $ExpectedArchiveSha256.ToLowerInvariant()) { Fail-Import 'issued receipt archive binding mismatch' }
        if ($receiptDoc.origin.provenance_sha256 -cne $provenanceHash) { Fail-Import 'issued receipt provenance binding mismatch' }
        if ($receiptDoc.origin.runner_post_sign_sha256 -cne $hashes.RunnerSha256) { Fail-Import 'issued receipt post-sign runner binding mismatch' }
        if ($receiptDoc.origin.rust_library_post_sign_sha256 -cne $hashes.RustLibrarySha256) { Fail-Import 'issued receipt post-sign rust binding mismatch' }
        if ($movedBuild -and (Test-Path -LiteralPath $rollbackSibling)) { Remove-Item -LiteralPath $rollbackSibling -Recurse -Force }
        if ($movedReceipt -and (Test-Path -LiteralPath $receiptBackup)) { Remove-Item -LiteralPath $receiptBackup -Force }
        Write-Host ("OK import build={0} src={1} files={2} receipt={3}" -f $expectedBuildId, $ExpectedSourceSha.Substring(0, 12), $manifest.Count, $receiptFull)
        return [pscustomobject]@{ BuildIdentifier = $expectedBuildId; ReceiptPath = $receiptFull; RunnerSha256 = $hashes.RunnerSha256; RustLibrarySha256 = $hashes.RustLibrarySha256 }
    }
    catch {
        $originalMessage = $_.Exception.Message
        $rollbackNotes = New-Object System.Collections.Generic.List[string]
        if ($installedNew -and (Test-Path -LiteralPath $runnerFull)) {
            try { Remove-Item -LiteralPath $runnerFull -Recurse -Force } catch { $rollbackNotes.Add('remove-partial-build failed') }
        }
        if ($movedBuild -and (Test-Path -LiteralPath $rollbackSibling)) {
            try {
                if (-not (Test-Path -LiteralPath $runnerFull)) { Move-Item -LiteralPath $rollbackSibling -Destination $runnerFull }
                else { $rollbackNotes.Add('rollback sibling retained') }
            } catch { $rollbackNotes.Add('restore-build failed') }
        }
        if ($receiptWritten -and (Test-Path -LiteralPath $receiptFull -PathType Leaf)) {
            try { Remove-Item -LiteralPath $receiptFull -Force } catch { $rollbackNotes.Add('remove-partial-receipt failed') }
        }
        if ($movedReceipt -and (Test-Path -LiteralPath $receiptBackup -PathType Leaf)) {
            try {
                if (-not (Test-Path -LiteralPath $receiptFull -PathType Leaf)) { Move-Item -LiteralPath $receiptBackup -Destination $receiptFull }
                else { $rollbackNotes.Add('receipt backup retained') }
            } catch { $rollbackNotes.Add('restore-receipt failed') }
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
        throw "IMPORT-FAIL: import aborted; build and receipt rolled back ($originalMessage)$suffix"
    }
}

if (-not $FunctionsOnlyForTest) {
    if (-not $ArchivePath -or -not $ProvenancePath -or -not $ExpectedArchiveSha256 -or -not $ExpectedSourceSha -or -not $ExpectedPilotSha) {
        throw 'ArchivePath, ProvenancePath, ExpectedArchiveSha256, ExpectedSourceSha, and ExpectedPilotSha are all required.'
    }
    $resolvedRepository = $Repository
    if (-not $resolvedRepository) { $resolvedRepository = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path }
    $resolvedRunner = $RunnerDirectory
    if (-not $resolvedRunner) { $resolvedRunner = Join-Path $resolvedRepository 'build\windows\arm64\runner\Debug' }
    $resolvedReceipt = $ReceiptPath
    if (-not $resolvedReceipt) {
        if ($ProfileRoot) { $resolvedReceipt = Join-Path $ProfileRoot 'cloud-sync-v2\windows-harness-build-receipt.json' }
        else { $resolvedReceipt = Join-Path $env:APPDATA 'OpenBubbles\cloudkit-v2-dev\cloud-sync-v2\windows-harness-build-receipt.json' }
    }
    Import-VerifiedWindowsCloudHarness -ArchivePath $ArchivePath -ProvenancePath $ProvenancePath -ExpectedArchiveSha256 $ExpectedArchiveSha256 -ExpectedSourceSha $ExpectedSourceSha -ExpectedPilotSha $ExpectedPilotSha -Repository $resolvedRepository -RunnerDirectory $resolvedRunner -ReceiptPath $resolvedReceipt -SignTool $SignTool -SigningThumbprint $SigningThumbprint -ExpectedNativeEncoderTestCount $ExpectedNativeEncoderTestCount | Out-Null
}
