[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$launcher = Join-Path $PSScriptRoot "run_cloud_sync_v2_auth_probe.ps1"
. $launcher -FunctionsOnlyForTest

function Assert-True {
    param(
        [Parameter(Mandatory)][bool] $Condition,
        [Parameter(Mandatory)][string] $Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Invoke-ExpectedFailure {
    param([Parameter(Mandatory)][scriptblock] $Action)

    try {
        & $Action
    }
    catch {
        return $_.Exception.Message
    }
    throw "Expected the operation to fail."
}

function Write-SyntheticGsa {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][int] $DigestLength,
        [byte] $DigestByte = 0,
        [switch] $IncludeEncryptedDigest
    )

    $digest = New-Object byte[] $DigestLength
    for ($index = 0; $index -lt $DigestLength; $index++) {
        $digest[$index] = $DigestByte
    }
    $legacy = [Convert]::ToBase64String($digest)
    $encrypted = if ($IncludeEncryptedDigest) {
        "<key>encrypted_password</key><data>AA==</data>"
    }
    else {
        ""
    }
    $xml = (
        "<?xml version=`"1.0`" encoding=`"UTF-8`"?>" +
        "<plist version=`"1.0`"><dict>" +
        "<key>username</key><string>person@example.com</string>" +
        "<key>password</key><data>$legacy</data>" +
        $encrypted +
        "<key>postdata_done</key><true/>" +
        "</dict></plist>"
    )
    Set-Content -LiteralPath $Path -Value $xml -NoNewline
}

function Write-SyntheticEncryptedGsa {
    param(
        [Parameter(Mandatory)][string] $Path,
        [byte] $EncryptedByte = 0
    )

    $encryptedBytes = [byte[]] @(
        [byte] $EncryptedByte
        [byte] (([int] $EncryptedByte + 1) % 256)
        [byte] (([int] $EncryptedByte + 2) % 256)
    )
    $encrypted = [Convert]::ToBase64String($encryptedBytes)
    $xml = (
        "<?xml version=`"1.0`" encoding=`"UTF-8`"?>" +
        "<plist version=`"1.0`"><dict>" +
        "<key>username</key><string>person@example.com</string>" +
        "<key>encrypted_password</key><data>$encrypted</data>" +
        "<key>postdata_done</key><true/>" +
        "</dict></plist>"
    )
    Set-Content -LiteralPath $Path -Value $xml -NoNewline
}

function Test-AuthProbeParameterPreservation {
    param([Parameter(Mandatory)][string] $Launcher)

    $expected = @{
        FlutterRoot = "X:\custom-flutter"
        NuGetRoot = "X:\custom-nuget"
        CargoHome = "X:\custom-cargo"
        RustupHome = "X:\custom-rustup"
        LlvmRoot = "X:\custom-llvm"
        PerlBin = "X:\custom-perl"
        SignTool = "X:\custom-signtool.exe"
        SigningThumbprint = "custom-thumbprint"
        CargoKitCacheRoot = "X:\custom-cache"
        TimeoutSeconds = 77
        PromoteCredentialToDevProfile = $true
    }
    . $Launcher `
        -FlutterRoot $expected.FlutterRoot `
        -NuGetRoot $expected.NuGetRoot `
        -CargoHome $expected.CargoHome `
        -RustupHome $expected.RustupHome `
        -LlvmRoot $expected.LlvmRoot `
        -PerlBin $expected.PerlBin `
        -SignTool $expected.SignTool `
        -SigningThumbprint $expected.SigningThumbprint `
        -CargoKitCacheRoot $expected.CargoKitCacheRoot `
        -TimeoutSeconds $expected.TimeoutSeconds `
        -PromoteCredentialToDevProfile `
        -FunctionsOnlyForTest
    return (
        $FlutterRoot -eq $expected.FlutterRoot -and
        $NuGetRoot -eq $expected.NuGetRoot -and
        $CargoHome -eq $expected.CargoHome -and
        $RustupHome -eq $expected.RustupHome -and
        $LlvmRoot -eq $expected.LlvmRoot -and
        $PerlBin -eq $expected.PerlBin -and
        $SignTool -eq $expected.SignTool -and
        $SigningThumbprint -eq $expected.SigningThumbprint -and
        $CargoKitCacheRoot -eq $expected.CargoKitCacheRoot -and
        $TimeoutSeconds -eq $expected.TimeoutSeconds -and
        [bool] $PromoteCredentialToDevProfile -and
        [bool] $FunctionsOnlyForTest
    )
}

$tempRoot = [System.IO.Path]::GetFullPath(
    [System.IO.Path]::GetTempPath()
).TrimEnd('\')
$testDirectory = [System.IO.Path]::GetFullPath(
    (Join-Path $tempRoot (
        "openbubbles-auth-probe-launcher-test-" +
        [guid]::NewGuid().ToString("N")
    ))
)
if (-not $testDirectory.StartsWith(
    "$tempRoot\",
    [System.StringComparison]::OrdinalIgnoreCase
)) {
    throw "The authentication probe test directory escaped the temporary root."
}
New-Item -ItemType Directory -Path $testDirectory | Out-Null

try {
    Assert-True `
        -Condition (Test-AuthProbeParameterPreservation -Launcher $launcher) `
        -Message "The shared launcher import overwrote an auth-only caller parameter."
    $safeNativePath = Get-AuthProbeSafeNativeBuildPath -PathValue (
        "C:\Keep;C:\Strawberry\c\bin;" +
        "C:\Strawberry\perl\bin;C:\AlsoKeep"
    )
    Assert-True `
        -Condition ($safeNativePath -eq "C:\Keep;C:\AlsoKeep") `
        -Message "The native build PATH filter did not remove only Strawberry tool directories."

    $launchId = New-CryptographicLaunchId
    Assert-True `
        -Condition ($launchId -match "^[a-f0-9]{32}$") `
        -Message "The authentication probe launch ID contract changed."

    Assert-NoReparsePointAncestorChain -Path $testDirectory
    $resolvedTestDirectory = Resolve-ExactNonReparsePath -Path $testDirectory
    Assert-True `
        -Condition ([System.String]::Equals(
            $testDirectory,
            $resolvedTestDirectory,
            [System.StringComparison]::OrdinalIgnoreCase
        )) `
        -Message "The authentication probe test path did not resolve exactly."

    $fileCopySource = Join-Path $testDirectory "copy-source.bin"
    $fileCopyDestination = Join-Path $testDirectory "copy-destination.bin"
    [System.IO.File]::WriteAllBytes($fileCopySource, [byte[]](0, 1, 2, 127, 255))
    Copy-Item -LiteralPath $fileCopySource -Destination $fileCopyDestination
    Assert-ExactFileCopy `
        -Source $fileCopySource `
        -Destination $fileCopyDestination
    [System.IO.File]::WriteAllBytes($fileCopyDestination, [byte[]](0, 1, 2, 127, 254))
    $fileCopyFailure = Invoke-ExpectedFailure {
        Assert-ExactFileCopy `
            -Source $fileCopySource `
            -Destination $fileCopyDestination
    }
    Assert-True `
        -Condition ($fileCopyFailure -eq
            "Authentication probe file copy did not preserve exact bytes.") `
        -Message "A modified authentication probe file copy was accepted."

    $treeCopySource = Join-Path $testDirectory "tree-source"
    $treeCopyDestination = Join-Path $testDirectory "tree-destination"
    foreach ($root in @($treeCopySource, $treeCopyDestination)) {
        New-Item -ItemType Directory -Path (Join-Path $root "nested") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root "empty") -Force | Out-Null
    }
    Set-Content -LiteralPath (Join-Path $treeCopySource "root.txt") -Value "root" -NoNewline
    Set-Content -LiteralPath (Join-Path $treeCopySource "nested\child.txt") -Value "child" -NoNewline
    Copy-Item `
        -LiteralPath (Join-Path $treeCopySource "root.txt") `
        -Destination (Join-Path $treeCopyDestination "root.txt")
    Copy-Item `
        -LiteralPath (Join-Path $treeCopySource "nested\child.txt") `
        -Destination (Join-Path $treeCopyDestination "nested\child.txt")
    Assert-ExactTreeCopy `
        -Source $treeCopySource `
        -Destination $treeCopyDestination
    Set-Content `
        -LiteralPath (Join-Path $treeCopyDestination "nested\child.txt") `
        -Value "changed" `
        -NoNewline
    $treeCopyFailure = Invoke-ExpectedFailure {
        Assert-ExactTreeCopy `
            -Source $treeCopySource `
            -Destination $treeCopyDestination
    }
    Assert-True `
        -Condition ($treeCopyFailure -eq
            "Authentication probe tree copy did not preserve exact bytes.") `
        -Message "A modified authentication probe tree copy was accepted."
    Copy-Item `
        -LiteralPath (Join-Path $treeCopySource "nested\child.txt") `
        -Destination (Join-Path $treeCopyDestination "nested\child.txt") `
        -Force
    New-Item `
        -ItemType Directory `
        -Path (Join-Path $treeCopyDestination "unexpected-empty") | Out-Null
    $treeShapeFailure = Invoke-ExpectedFailure {
        Assert-ExactTreeCopy `
            -Source $treeCopySource `
            -Destination $treeCopyDestination
    }
    Assert-True `
        -Condition ($treeShapeFailure -eq
            "Authentication probe tree copy did not preserve exact bytes.") `
        -Message "An unexpected authentication probe directory was accepted."

    $validGsa = Join-Path $testDirectory "valid-gsa.plist"
    Write-SyntheticGsa -Path $validGsa -DigestLength 32
    $validShape = Read-GsaShape -Path $validGsa
    Assert-True `
        -Condition ($validShape.HasLegacyDigest -and
            -not $validShape.HasEncryptedDigest -and
            $validShape.DigestLength -eq 32 -and
            $validShape.PostdataDone) `
        -Message "A valid synthetic legacy GSA record was not recognized."
    $prettyGsa = Join-Path $testDirectory "pretty-gsa.plist"
    $prettyXml = (Get-Content -LiteralPath $validGsa -Raw) -replace '><', ">`n<"
    Set-Content -LiteralPath $prettyGsa -Value $prettyXml -NoNewline
    $prettyShape = Read-GsaShape -Path $prettyGsa
    Assert-True `
        -Condition ($prettyShape.HasLegacyDigest -and
            -not $prettyShape.HasEncryptedDigest -and
            $prettyShape.DigestLength -eq 32) `
        -Message "A whitespace-formatted legacy GSA record was not recognized."

    $ambiguousGsa = Join-Path $testDirectory "ambiguous-gsa.plist"
    Write-SyntheticGsa `
        -Path $ambiguousGsa `
        -DigestLength 31 `
        -IncludeEncryptedDigest
    $ambiguousShape = Read-GsaShape -Path $ambiguousGsa
    Assert-True `
        -Condition ($ambiguousShape.HasEncryptedDigest -and
            $ambiguousShape.DigestLength -eq 31 -and
            $ambiguousShape.EncryptedLength -eq 1) `
        -Message "An ambiguous synthetic GSA record was not exposed to validation."

    $allowedSids = @(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().User,
        [System.Security.Principal.SecurityIdentifier]::new("S-1-5-18"),
        [System.Security.Principal.SecurityIdentifier]::new("S-1-5-32-544")
    )
    Set-RestrictedProbeAcl -Path $testDirectory -AllowedSids $allowedSids
    Assert-RestrictedProbeAcl `
        -Path $testDirectory `
        -AllowedSids $allowedSids
    $aclChildDirectory = Join-Path $testDirectory "acl-child"
    $aclChildFile = Join-Path $aclChildDirectory "child.txt"
    New-Item -ItemType Directory -Path $aclChildDirectory | Out-Null
    Set-Content -LiteralPath $aclChildFile -Value "acl" -NoNewline
    foreach ($aclPath in @($aclChildDirectory, $aclChildFile)) {
        Assert-RestrictedProbeAcl `
            -Path $aclPath `
            -AllowedSids $allowedSids
    }

    $incompleteAllowedSids = @($allowedSids[0], $allowedSids[1])
    $aclFailure = Invoke-ExpectedFailure {
        Assert-RestrictedProbeAcl `
            -Path $testDirectory `
            -AllowedSids $incompleteAllowedSids
    }
    Assert-True `
        -Condition ($aclFailure -eq
            "Authentication probe ACL is not restricted to the approved principals.") `
        -Message "A non-allowlisted probe ACL principal was accepted."

    $finished = Get-AuthProbeTerminalResult `
        -State "finished" `
        -Stage "auth-admitted" `
        -SafeCode "none" `
        -ProcessExitCode 0
    $challenge = Get-AuthProbeTerminalResult `
        -State "challenge-required" `
        -Stage "auth-two-factor-required" `
        -SafeCode "cloud_sync_windows_auth_probe_two_factor_required" `
        -ProcessExitCode 3
    $rejected = Get-AuthProbeTerminalResult `
        -State "failed" `
        -Stage "auth-rejected" `
        -SafeCode "cloud_sync_windows_auth_probe_state_rejected" `
        -ProcessExitCode 2
    $localFailure = Get-AuthProbeTerminalResult `
        -State "failed" `
        -Stage "auth-login" `
        -SafeCode "cloud_sync_windows_auth_probe_login_failed" `
        -ProcessExitCode 1
    Assert-True `
        -Condition ($finished.Result -eq "admitted" -and $finished.ExitCode -eq 0) `
        -Message "The admitted authentication probe result changed."
    Assert-True `
        -Condition ($challenge.Result -eq "challenge-required" -and
            $challenge.ExitCode -eq 2) `
        -Message "The challenge-required authentication probe result is not fail-closed."
    Assert-True `
        -Condition ($rejected.Result -eq "rejected" -and $rejected.ExitCode -eq 2) `
        -Message "The rejected authentication probe result is not fail-closed."
    Assert-True `
        -Condition ($localFailure.Result -eq "failed" -and $localFailure.ExitCode -eq 1) `
        -Message "The local authentication probe failure classification changed."

    $promotionDirectory = Join-Path $testDirectory "credential-promotion"
    New-Item -ItemType Directory -Path $promotionDirectory | Out-Null
    $promotionSource = Join-Path $promotionDirectory "gsa.plist"
    $promotionAdmitted = Join-Path $promotionDirectory "admitted-gsa.plist"
    Write-SyntheticGsa -Path $promotionSource -DigestLength 32 -DigestByte 17
    Write-SyntheticEncryptedGsa -Path $promotionAdmitted -EncryptedByte 29
    $originalPromotionHash = Get-ExactFileHash -Path $promotionSource
    $admittedPromotionHash = Get-ExactFileHash -Path $promotionAdmitted
    $promotionLaunchId = New-CryptographicLaunchId
    $promotion = Install-AdmittedProbeGsaCredential `
        -SourceGsa $promotionSource `
        -AdmittedGsa $promotionAdmitted `
        -LaunchId $promotionLaunchId `
        -TerminalResult $finished
    Assert-True `
        -Condition ($promotion.Promoted -and
            $promotion.RollbackAvailable -and
            (Test-Path -LiteralPath $promotion.BackupPath -PathType Leaf)) `
        -Message "An admitted credential was not promoted with rollback state."
    Assert-True `
        -Condition ((Get-ExactFileHash -Path $promotionSource) -eq $admittedPromotionHash -and
            (Get-ExactFileHash -Path $promotion.BackupPath) -eq $originalPromotionHash) `
        -Message "Credential promotion did not preserve exact source and rollback bytes."
    Assert-True `
        -Condition (@(Get-ChildItem -LiteralPath $promotionDirectory -Force |
            Where-Object { $_.Name -like '*-stage-*' -or $_.Name -like '*-rollback-*' }).Count -eq 0) `
        -Message "Credential promotion retained transaction scratch files."
    Restore-AdmittedGsaCredential `
        -SourceGsa $promotionSource `
        -BackupPath $promotion.BackupPath `
        -LaunchId $promotionLaunchId
    Assert-True `
        -Condition ((Get-ExactFileHash -Path $promotionSource) -eq $originalPromotionHash -and
            (Get-ExactFileHash -Path $promotion.BackupPath) -eq $originalPromotionHash) `
        -Message "Credential rollback did not restore the exact original bytes."

    $rejectedPromotionSource = Join-Path $promotionDirectory "rejected-gsa.plist"
    $rejectedPromotionAdmitted = Join-Path $promotionDirectory "rejected-admitted-gsa.plist"
    Write-SyntheticGsa -Path $rejectedPromotionSource -DigestLength 32 -DigestByte 41
    Write-SyntheticEncryptedGsa -Path $rejectedPromotionAdmitted -EncryptedByte 43
    $rejectedPromotionHash = Get-ExactFileHash -Path $rejectedPromotionSource
    $rejectedPromotionFailure = Invoke-ExpectedFailure {
        Install-AdmittedProbeGsaCredential `
            -SourceGsa $rejectedPromotionSource `
            -AdmittedGsa $rejectedPromotionAdmitted `
            -LaunchId (New-CryptographicLaunchId) `
            -TerminalResult $rejected
    }
    Assert-True `
        -Condition ($rejectedPromotionFailure -eq
            "Credential promotion requires an admitted authentication probe." -and
            (Get-ExactFileHash -Path $rejectedPromotionSource) -eq $rejectedPromotionHash) `
        -Message "A rejected authentication result changed source credentials."

    $sameCredentialSource = Join-Path $promotionDirectory "same-gsa.plist"
    $sameCredentialAdmitted = Join-Path $promotionDirectory "same-admitted-gsa.plist"
    Write-SyntheticEncryptedGsa -Path $sameCredentialSource -EncryptedByte 53
    Copy-Item -LiteralPath $sameCredentialSource -Destination $sameCredentialAdmitted
    $sameCredential = Install-AdmittedProbeGsaCredential `
        -SourceGsa $sameCredentialSource `
        -AdmittedGsa $sameCredentialAdmitted `
        -LaunchId (New-CryptographicLaunchId) `
        -TerminalResult $finished
    Assert-True `
        -Condition (-not $sameCredential.Promoted -and
            -not $sameCredential.RollbackAvailable -and
            $null -eq $sameCredential.BackupPath) `
        -Message "An already-current credential created an unnecessary backup."

    $admittedStatusPayload = [pscustomobject]@{
        state = "finished"
        stage = "auth-admitted"
        safe_code = "none"
    }
    $stagingSource = Join-Path $promotionDirectory "staging-source-gsa.plist"
    $stagingProbe = Join-Path $promotionDirectory "staging-probe-gsa.plist"
    Write-SyntheticGsa -Path $stagingSource -DigestLength 32 -DigestByte 79
    Write-SyntheticEncryptedGsa -Path $stagingProbe -EncryptedByte 83
    $stagingSourceHash = Get-ExactFileHash -Path $stagingSource
    $stagingProbeHash = Get-ExactFileHash -Path $stagingProbe
    $stagingLaunchId = New-CryptographicLaunchId
    $stagedCredential = Stage-AdmittedProbeGsaCredential `
        -SourceGsa $stagingSource `
        -ProbeGsa $stagingProbe `
        -LaunchId $stagingLaunchId `
        -TerminalResult $finished
    Assert-True `
        -Condition ((Get-ExactFileHash -Path $stagedCredential) -eq $stagingProbeHash) `
        -Message "The admitted probe credential was not staged exactly."
    $stagingResultJson = Publish-AdmittedCredentialPromotionResult `
        -SourceGsa $stagingSource `
        -AdmittedGsa $stagedCredential `
        -LaunchId $stagingLaunchId `
        -ProcessId $PID `
        -TerminalResult $finished `
        -StatusPayload $admittedStatusPayload `
        -PromotionRequested $true `
        -ProbeRootRemoved $true `
        -RemoveAdmittedGsaAfterInstall $true
    $stagingResult = $stagingResultJson | ConvertFrom-Json
    $stagingBackup = Join-Path $promotionDirectory (
        ".openbubbles-cloud-sync-v2-gsa-backup-$stagingLaunchId.plist"
    )
    Assert-True `
        -Condition ($stagingResult.credential_promoted -and
            -not (Test-Path -LiteralPath $stagedCredential) -and
            (Get-ExactFileHash -Path $stagingSource) -eq $stagingProbeHash -and
            (Get-ExactFileHash -Path $stagingBackup) -eq $stagingSourceHash) `
        -Message "The staged admitted credential lifecycle is not transactional."
    Restore-AdmittedGsaCredential `
        -SourceGsa $stagingSource `
        -BackupPath $stagingBackup `
        -LaunchId $stagingLaunchId
    Assert-True `
        -Condition ((Get-ExactFileHash -Path $stagingSource) -eq $stagingSourceHash) `
        -Message "The staged credential rollback did not restore exact source bytes."

    $legacyStageLaunchId = New-CryptographicLaunchId
    $legacyStageFailure = Invoke-ExpectedFailure {
        Stage-AdmittedProbeGsaCredential `
            -SourceGsa $stagingSource `
            -ProbeGsa $validGsa `
            -LaunchId $legacyStageLaunchId `
            -TerminalResult $finished
    }
    Assert-True `
        -Condition ($legacyStageFailure -eq
            "Credential staging requires the admitted encrypted probe credential.") `
        -Message "A legacy Store credential was accepted as admitted probe output."

    $postReportSource = Join-Path $promotionDirectory "post-report-gsa.plist"
    $postReportAdmitted = Join-Path $promotionDirectory "post-report-admitted-gsa.plist"
    Write-SyntheticGsa -Path $postReportSource -DigestLength 32 -DigestByte 61
    Write-SyntheticEncryptedGsa -Path $postReportAdmitted -EncryptedByte 67
    $postReportOriginalHash = Get-ExactFileHash -Path $postReportSource
    $postReportLaunchId = New-CryptographicLaunchId
    $postReportFailure = Invoke-ExpectedFailure {
        Publish-AdmittedCredentialPromotionResult `
            -SourceGsa $postReportSource `
            -AdmittedGsa $postReportAdmitted `
            -LaunchId $postReportLaunchId `
            -ProcessId $PID `
            -TerminalResult $finished `
            -StatusPayload $admittedStatusPayload `
            -PromotionRequested $true `
            -ProbeRootRemoved $true `
            -BeforeReport { throw "synthetic post-promotion report failure" }
    }
    $postReportBackup = Join-Path $promotionDirectory (
        ".openbubbles-cloud-sync-v2-gsa-backup-$postReportLaunchId.plist"
    )
    Assert-True `
        -Condition ($postReportFailure -eq "synthetic post-promotion report failure" -and
            (Get-ExactFileHash -Path $postReportSource) -eq $postReportOriginalHash -and
            (Test-Path -LiteralPath $postReportBackup -PathType Leaf)) `
        -Message "A post-promotion pre-report failure was not rolled back."

    $missingBackupSource = Join-Path $promotionDirectory "missing-backup-gsa.plist"
    $missingBackupAdmitted = Join-Path $promotionDirectory "missing-backup-admitted-gsa.plist"
    Write-SyntheticGsa -Path $missingBackupSource -DigestLength 32 -DigestByte 71
    Write-SyntheticEncryptedGsa -Path $missingBackupAdmitted -EncryptedByte 73
    $missingBackupAdmittedHash = Get-ExactFileHash -Path $missingBackupAdmitted
    $missingBackupFailure = Invoke-ExpectedFailure {
        Publish-AdmittedCredentialPromotionResult `
            -SourceGsa $missingBackupSource `
            -AdmittedGsa $missingBackupAdmitted `
            -LaunchId (New-CryptographicLaunchId) `
            -ProcessId $PID `
            -TerminalResult $finished `
            -StatusPayload $admittedStatusPayload `
            -PromotionRequested $true `
            -ProbeRootRemoved $true `
            -BeforeReport {
                param($appliedPromotion)
                Remove-Item -LiteralPath $appliedPromotion.BackupPath -Force
                throw "synthetic missing rollback state"
            }
    }
    Assert-True `
        -Condition ($missingBackupFailure -eq
            "Authentication probe failed after promotion and rollback failed." -and
            (Get-ExactFileHash -Path $missingBackupSource) -eq $missingBackupAdmittedHash) `
        -Message "A missing rollback backup was reported as preserved state."

    foreach ($profileStage in @(
        "process-entry",
        "binding-ready",
        "profile-compile-gate",
        "profile-directory-check",
        "profile-canonical-check",
        "profile-marker-check",
        "profile-preflight-ready",
        "filesystem-service-configure",
        "profile-configured"
    )) {
        Assert-True `
            -Condition ((Get-ExpectedAuthProbeFailureSafeCode -Stage $profileStage) -eq
                "cloud_sync_windows_auth_probe_profile_failed") `
            -Message "An authentication probe profile stage is not fail-closed."
    }
    $inconsistentTerminalFailure = Invoke-ExpectedFailure {
        Get-AuthProbeTerminalResult `
            -State "finished" `
            -Stage "auth-rejected" `
            -SafeCode "cloud_sync_windows_auth_probe_state_rejected"
    }
    Assert-True `
        -Condition ($inconsistentTerminalFailure -eq
            "Authentication probe terminal status is inconsistent.") `
        -Message "An inconsistent authentication probe terminal tuple was accepted."
    $exitMismatchFailure = Invoke-ExpectedFailure {
        Get-AuthProbeTerminalResult `
            -State "finished" `
            -Stage "auth-admitted" `
            -SafeCode "none" `
            -ProcessExitCode 1
    }
    Assert-True `
        -Condition ($exitMismatchFailure -eq
            "Authentication probe process exit code does not match terminal status.") `
        -Message "A mismatched authentication probe process exit was accepted."

    $statusPath = Join-Path $testDirectory "terminal-status.json"
    $statusNotBeforeUtc = [DateTimeOffset]::UtcNow.AddMinutes(-1)
    $statusUpdatedUtc = [DateTimeOffset]::UtcNow.ToString(
        "yyyy-MM-dd'T'HH:mm:ss.ffffff'Z'",
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    @{
        version = "cloud-sync-v2-windows-auth-probe-status-v1"
        launch_id = $launchId
        process_id = $PID
        state = "finished"
        stage = "auth-admitted"
        safe_code = "none"
        updated_utc = $statusUpdatedUtc
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $statusPath -NoNewline
    $parsedStatus = Read-AuthProbeTerminalStatus `
        -StatusPath $statusPath `
        -LaunchId $launchId `
        -ProcessId $PID `
        -NotBeforeUtc $statusNotBeforeUtc
    Assert-True `
        -Condition ($parsedStatus.Terminal.Result -eq "admitted") `
        -Message "The exact terminal status parser rejected a valid admitted result."
    $postDeadlineFailure = Invoke-ExpectedFailure {
        Read-AuthProbeTerminalStatus `
            -StatusPath $statusPath `
            -LaunchId $launchId `
            -ProcessId $PID `
            -NotBeforeUtc $statusNotBeforeUtc `
            -NotAfterUtc ([DateTimeOffset]::UtcNow.AddMinutes(-1))
    }
    Assert-True `
        -Condition ($postDeadlineFailure -eq
            "Windows authentication probe status timestamp is outside the launch window.") `
        -Message "The exact terminal status parser accepted a post-deadline status."
    @{
        version = "cloud-sync-v2-windows-auth-probe-status-v1"
        launch_id = $launchId
        process_id = $PID
        state = "finished"
        stage = "auth-rejected"
        safe_code = "cloud_sync_windows_auth_probe_state_rejected"
        updated_utc = $statusUpdatedUtc
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $statusPath -NoNewline
    $parsedTupleFailure = Invoke-ExpectedFailure {
        Read-AuthProbeTerminalStatus `
            -StatusPath $statusPath `
            -LaunchId $launchId `
            -ProcessId $PID `
            -NotBeforeUtc $statusNotBeforeUtc
    }
    Assert-True `
        -Condition ($parsedTupleFailure -eq
            "Authentication probe terminal status is inconsistent.") `
        -Message "The terminal status parser accepted an inconsistent tuple."

    $exactClassifierCode = try {
        throw "Windows authentication probe status identity is invalid."
    }
    catch {
        Get-AuthProbeStatusReadFailureCode -Failure $_
    }
    Assert-True `
        -Condition ($exactClassifierCode -eq "status-invalid-identity") `
        -Message "The exact authentication probe status failure was not classified."
    $caseVariantClassifierCode = try {
        throw "Windows authentication probe status Identity is invalid."
    }
    catch {
        Get-AuthProbeStatusReadFailureCode -Failure $_
    }
    Assert-True `
        -Condition ($caseVariantClassifierCode -eq "status-read-transient") `
        -Message "The authentication probe status classifier was not ordinal."
    $unknownClassifierCode = try {
        throw "synthetic unknown status read failure"
    }
    catch {
        Get-AuthProbeStatusReadFailureCode -Failure $_
    }
    Assert-True `
        -Condition ($unknownClassifierCode -eq "status-read-transient") `
        -Message "An unknown authentication probe status failure did not fail closed."

    $profileLock = Enter-ProfileScopedLauncherLock -ProfilePath $testDirectory
    try {
        Assert-True `
            -Condition ($null -ne $profileLock) `
            -Message "The source-profile launcher lock was not acquired."
    }
    finally {
        $profileLock.ReleaseMutex()
        $profileLock.Dispose()
    }

    $syntheticChild = Join-Path $testDirectory "synthetic-auth-probe-child.ps1"
    @'
param(
    [Parameter(Mandatory)][string] $StatusPath,
    [Parameter(Mandatory)][string] $LaunchId,
    [Parameter(Mandatory)][int] $ExitCode,
    [string] $State = "finished",
    [string] $Stage = "auth-admitted",
    [string] $SafeCode = "none",
    [int] $HoldSeconds = 0,
    [string] $StatusLaunchId = "",
    [string] $UpdatedUtc = ""
)
$effectiveLaunchId = if ($StatusLaunchId) { $StatusLaunchId } else { $LaunchId }
$effectiveUpdatedUtc = if ($UpdatedUtc) {
    $UpdatedUtc
}
else {
    [DateTimeOffset]::UtcNow.ToString(
        "yyyy-MM-dd'T'HH:mm:ss.ffffff'Z'",
        [System.Globalization.CultureInfo]::InvariantCulture
    )
}
$payload = @{
    version = "cloud-sync-v2-windows-auth-probe-status-v1"
    launch_id = $effectiveLaunchId
    process_id = $PID
    state = $State
    stage = $Stage
    safe_code = $SafeCode
    updated_utc = $effectiveUpdatedUtc
}
$payload | ConvertTo-Json -Compress | Set-Content -LiteralPath $StatusPath -NoNewline
if ($HoldSeconds -gt 0) {
    Start-Sleep -Seconds $HoldSeconds
}
exit $ExitCode
'@ | Set-Content -LiteralPath $syntheticChild -NoNewline
    $pwshExecutable = (Get-Command pwsh -ErrorAction Stop).Source
    $syntheticStatus = Join-Path $testDirectory "synthetic-terminal-status.json"
    $terminalLifecycleCases = @(
        @{
            Name = "admitted"
            ProcessExitCode = 0
            State = "finished"
            Stage = "auth-admitted"
            SafeCode = "none"
            ExpectedResult = "admitted"
            ExpectedExitCode = 0
        },
        @{
            Name = "challenge"
            ProcessExitCode = 3
            State = "challenge-required"
            Stage = "auth-two-factor-required"
            SafeCode = "cloud_sync_windows_auth_probe_two_factor_required"
            ExpectedResult = "challenge-required"
            ExpectedExitCode = 2
        },
        @{
            Name = "rejected"
            ProcessExitCode = 2
            State = "failed"
            Stage = "auth-rejected"
            SafeCode = "cloud_sync_windows_auth_probe_state_rejected"
            ExpectedResult = "rejected"
            ExpectedExitCode = 2
        },
        @{
            Name = "profile-failure"
            ProcessExitCode = 1
            State = "failed"
            Stage = "profile-marker-check"
            SafeCode = "cloud_sync_windows_auth_probe_profile_failed"
            ExpectedResult = "failed"
            ExpectedExitCode = 1
        }
    )
    foreach ($terminalCase in $terminalLifecycleCases) {
        if (Test-Path -LiteralPath $syntheticStatus) {
            Remove-Item -LiteralPath $syntheticStatus -Force
        }
        $syntheticLaunchId = New-CryptographicLaunchId
        $syntheticProcess = Start-Process `
            -FilePath $pwshExecutable `
            -ArgumentList @(
                "-NoProfile", "-File", $syntheticChild,
                "-StatusPath", $syntheticStatus,
                "-LaunchId", $syntheticLaunchId,
                "-ExitCode", ([string] $terminalCase.ProcessExitCode),
                "-State", ([string] $terminalCase.State),
                "-Stage", ([string] $terminalCase.Stage),
                "-SafeCode", ([string] $terminalCase.SafeCode)
            ) `
            -PassThru
        $syntheticResult = Wait-AuthProbeTerminalProcess `
            -Process $syntheticProcess `
            -StatusPath $syntheticStatus `
            -LaunchId $syntheticLaunchId `
            -ExpectedExecutable $pwshExecutable `
            -TimeoutSeconds 10
        Assert-True `
            -Condition ($syntheticResult.Terminal.Result -eq $terminalCase.ExpectedResult -and
                $syntheticResult.Terminal.ExitCode -eq $terminalCase.ExpectedExitCode) `
            -Message ("The controlled authentication probe lifecycle rejected the " +
                $terminalCase.Name + " terminal tuple.")
    }

    Remove-Item -LiteralPath $syntheticStatus -Force
    $terminalHangLaunchId = New-CryptographicLaunchId
    $terminalHangProcess = Start-Process `
        -FilePath $pwshExecutable `
        -ArgumentList @(
            "-NoProfile", "-File", $syntheticChild,
            "-StatusPath", $syntheticStatus,
            "-LaunchId", $terminalHangLaunchId,
            "-ExitCode", "0",
            "-HoldSeconds", "10"
        ) `
        -PassThru
    $terminalHangFailure = Invoke-ExpectedFailure {
        Wait-AuthProbeTerminalProcess `
            -Process $terminalHangProcess `
            -StatusPath $syntheticStatus `
            -LaunchId $terminalHangLaunchId `
            -ExpectedExecutable $pwshExecutable `
            -TimeoutSeconds 10
    }
    Assert-True `
        -Condition ($terminalHangFailure -eq
            "Windows authentication probe did not exit after terminal status.") `
        -Message "A terminal authentication probe child that remained active was accepted."
    $terminalHangProcess.Refresh()
    Assert-True `
        -Condition $terminalHangProcess.HasExited `
        -Message "The terminal authentication probe child remained active after forced termination."

    Remove-Item -LiteralPath $syntheticStatus -Force
    $mismatchLaunchId = New-CryptographicLaunchId
    $mismatchProcess = Start-Process `
        -FilePath $pwshExecutable `
        -ArgumentList @(
            "-NoProfile", "-File", $syntheticChild,
            "-StatusPath", $syntheticStatus,
            "-LaunchId", $mismatchLaunchId,
            "-ExitCode", "1"
        ) `
        -PassThru
    $controlledMismatchFailure = Invoke-ExpectedFailure {
        Wait-AuthProbeTerminalProcess `
            -Process $mismatchProcess `
            -StatusPath $syntheticStatus `
            -LaunchId $mismatchLaunchId `
            -ExpectedExecutable $pwshExecutable `
            -TimeoutSeconds 10
    }
    Assert-True `
        -Condition ($controlledMismatchFailure -eq
            "Authentication probe process exit code does not match terminal status.") `
        -Message "The controlled lifecycle accepted a mismatched child exit code."

    Remove-Item -LiteralPath $syntheticStatus -Force
    $progressLaunchId = New-CryptographicLaunchId
    $progressProcess = Start-Process `
        -FilePath $pwshExecutable `
        -ArgumentList @(
            "-NoProfile", "-File", $syntheticChild,
            "-StatusPath", $syntheticStatus,
            "-LaunchId", $progressLaunchId,
            "-ExitCode", "0",
            "-State", "running",
            "-Stage", "aps-setup",
            "-SafeCode", "none",
            "-HoldSeconds", "5"
        ) `
        -PassThru
    $progressTimeoutFailure = Invoke-ExpectedFailure {
        Wait-AuthProbeTerminalProcess `
            -Process $progressProcess `
            -StatusPath $syntheticStatus `
            -LaunchId $progressLaunchId `
            -ExpectedExecutable $pwshExecutable `
            -TimeoutSeconds 1
    }
    Assert-True `
        -Condition ($progressTimeoutFailure -eq
            "Windows authentication probe timed out at allowlisted stage: aps-setup") `
        -Message "The controlled lifecycle did not report its last allowlisted progress stage."
    $progressProcess.Refresh()
    Assert-True `
        -Condition $progressProcess.HasExited `
        -Message "The timed-out authentication probe child remained active."

    Remove-Item -LiteralPath $syntheticStatus -Force
    $staleTimeoutLaunchId = New-CryptographicLaunchId
    $staleTimeoutUpdatedUtc = [DateTimeOffset]::UtcNow.AddHours(-1).ToString(
        "yyyy-MM-dd'T'HH:mm:ss.ffffff'Z'",
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    $staleTimeoutProcess = Start-Process `
        -FilePath $pwshExecutable `
        -ArgumentList @(
            "-NoProfile", "-File", $syntheticChild,
            "-StatusPath", $syntheticStatus,
            "-LaunchId", $staleTimeoutLaunchId,
            "-ExitCode", "0",
            "-State", "running",
            "-Stage", "aps-setup",
            "-SafeCode", "none",
            "-HoldSeconds", "5",
            "-UpdatedUtc", $staleTimeoutUpdatedUtc
        ) `
        -PassThru
    $staleTimeoutFailure = Invoke-ExpectedFailure {
        Wait-AuthProbeTerminalProcess `
            -Process $staleTimeoutProcess `
            -StatusPath $syntheticStatus `
            -LaunchId $staleTimeoutLaunchId `
            -ExpectedExecutable $pwshExecutable `
            -TimeoutSeconds 1
    }
    Assert-True `
        -Condition ($staleTimeoutFailure -eq
            "Windows authentication probe timed out at allowlisted stage: status-invalid-timestamp-window") `
        -Message "A stale status influenced authentication probe timeout reporting."

    Remove-Item -LiteralPath $syntheticStatus -Force
    $mismatchedTimeoutLaunchId = New-CryptographicLaunchId
    $mismatchedTimeoutProcess = Start-Process `
        -FilePath $pwshExecutable `
        -ArgumentList @(
            "-NoProfile", "-File", $syntheticChild,
            "-StatusPath", $syntheticStatus,
            "-LaunchId", $mismatchedTimeoutLaunchId,
            "-ExitCode", "0",
            "-State", "running",
            "-Stage", "aps-setup",
            "-SafeCode", "none",
            "-HoldSeconds", "5",
            "-StatusLaunchId", (New-CryptographicLaunchId)
        ) `
        -PassThru
    $mismatchedTimeoutFailure = Invoke-ExpectedFailure {
        Wait-AuthProbeTerminalProcess `
            -Process $mismatchedTimeoutProcess `
            -StatusPath $syntheticStatus `
            -LaunchId $mismatchedTimeoutLaunchId `
            -ExpectedExecutable $pwshExecutable `
            -TimeoutSeconds 1
    }
    Assert-True `
        -Condition ($mismatchedTimeoutFailure -eq
            "Windows authentication probe timed out at allowlisted stage: status-invalid-identity") `
        -Message "A mismatched status influenced authentication probe timeout reporting."

    @{
        version = "cloud-sync-v2-windows-auth-probe-status-v1"
        launch_id = $launchId
        process_id = $PID
        state = "running"
        stage = "aps-setup"
        safe_code = "none"
        updated_utc = $statusUpdatedUtc
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $statusPath -NoNewline
    $parsedProgress = Read-AuthProbeTerminalStatus `
        -StatusPath $statusPath `
        -LaunchId $launchId `
        -ProcessId $PID `
        -NotBeforeUtc $statusNotBeforeUtc
    Assert-True `
        -Condition ($parsedProgress.Payload.stage -eq "aps-setup" -and
            $null -eq $parsedProgress.Terminal) `
        -Message "A valid nonterminal authentication probe status was not preserved."

    $acceptedObservation = Merge-AuthProbeStatusObservation `
        -LatestStatus $null `
        -LatestStatusReadFailure $null `
        -ValidatedStatus $parsedProgress
    $laterInvalidObservation = Merge-AuthProbeStatusObservation `
        -LatestStatus $acceptedObservation.LatestStatus `
        -LatestStatusReadFailure $acceptedObservation.LatestStatusReadFailure `
        -ReadFailure "status-invalid-identity"
    $retainedTimeoutStage = Get-AuthProbeTimeoutStage `
        -LatestStatus $laterInvalidObservation.LatestStatus `
        -StatusObserved $true `
        -LatestStatusReadFailure $laterInvalidObservation.LatestStatusReadFailure
    Assert-True `
        -Condition ($retainedTimeoutStage -eq "aps-setup" -and
            $laterInvalidObservation.LatestStatusReadFailure -eq "status-invalid-identity") `
        -Message "A later invalid status displaced an already accepted progress stage."

    $invalidOnlyObservation = Merge-AuthProbeStatusObservation `
        -LatestStatus $null `
        -LatestStatusReadFailure $null `
        -ReadFailure "status-invalid-identity"
    $invalidOnlyTimeoutStage = Get-AuthProbeTimeoutStage `
        -LatestStatus $invalidOnlyObservation.LatestStatus `
        -StatusObserved $true `
        -LatestStatusReadFailure $invalidOnlyObservation.LatestStatusReadFailure
    Assert-True `
        -Condition ($invalidOnlyTimeoutStage -eq "status-invalid-identity") `
        -Message "An invalid-only authentication probe status was misclassified."
    $unobservedTimeoutStage = Get-AuthProbeTimeoutStage `
        -LatestStatus $null `
        -StatusObserved $false `
        -LatestStatusReadFailure $null
    Assert-True `
        -Condition ($unobservedTimeoutStage -eq "status-not-observed") `
        -Message "A missing authentication probe status was misclassified."

    $invalidProgressFailure = Invoke-ExpectedFailure {
        @{
            version = "cloud-sync-v2-windows-auth-probe-status-v1"
            launch_id = $launchId
            process_id = $PID
            state = "running"
            stage = "auth-admitted"
            safe_code = "none"
            updated_utc = $statusUpdatedUtc
        } | ConvertTo-Json -Compress | Set-Content -LiteralPath $statusPath -NoNewline
        Read-AuthProbeTerminalStatus `
            -StatusPath $statusPath `
            -LaunchId $launchId `
            -ProcessId $PID `
            -NotBeforeUtc $statusNotBeforeUtc
    }
    Assert-True `
        -Condition ($invalidProgressFailure -eq
            "Authentication probe progress status is inconsistent.") `
        -Message "An inconsistent nonterminal authentication probe tuple was accepted."

    @{
        version = "cloud-sync-v2-windows-auth-probe-status-v1"
        launch_id = $launchId
        process_id = $PID
        state = "Running"
        stage = "aps-setup"
        safe_code = "none"
        updated_utc = $statusUpdatedUtc
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $statusPath -NoNewline
    $caseVariantStateFailure = Invoke-ExpectedFailure {
        Read-AuthProbeTerminalStatus `
            -StatusPath $statusPath `
            -LaunchId $launchId `
            -ProcessId $PID `
            -NotBeforeUtc $statusNotBeforeUtc
    }
    Assert-True `
        -Condition ($caseVariantStateFailure -eq
            "Authentication probe status state is invalid.") `
        -Message "A case-variant authentication probe state was accepted."

    @{
        Version = "cloud-sync-v2-windows-auth-probe-status-v1"
        launch_id = $launchId
        process_id = $PID
        state = "running"
        stage = "aps-setup"
        safe_code = "none"
        updated_utc = $statusUpdatedUtc
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $statusPath -NoNewline
    $caseVariantFieldFailure = Invoke-ExpectedFailure {
        Read-AuthProbeTerminalStatus `
            -StatusPath $statusPath `
            -LaunchId $launchId `
            -ProcessId $PID `
            -NotBeforeUtc $statusNotBeforeUtc
    }
    Assert-True `
        -Condition ($caseVariantFieldFailure -eq
            "Windows authentication probe emitted a non-allowlisted status field.") `
        -Message "A case-variant authentication probe field name was accepted."

    $duplicateStatusJson = (
        '{"version":"cloud-sync-v2-windows-auth-probe-status-v1",' +
        '"version":"cloud-sync-v2-windows-auth-probe-status-v1",' +
        '"launch_id":"' + $launchId + '",' +
        '"process_id":' + $PID + ',' +
        '"state":"running","stage":"aps-setup","safe_code":"none",' +
        '"updated_utc":"' + $statusUpdatedUtc + '"}'
    )
    Set-Content -LiteralPath $statusPath -Value $duplicateStatusJson -NoNewline
    $duplicateFieldFailure = Invoke-ExpectedFailure {
        Read-AuthProbeTerminalStatus `
            -StatusPath $statusPath `
            -LaunchId $launchId `
            -ProcessId $PID `
            -NotBeforeUtc $statusNotBeforeUtc
    }
    Assert-True `
        -Condition ($duplicateFieldFailure -eq
            "Windows authentication probe emitted a non-allowlisted status field.") `
        -Message "Duplicate authentication probe status fields were accepted."

    @{
        version = "cloud-sync-v2-windows-auth-probe-status-v1"
        launch_id = $launchId
        process_id = $PID
        state = "running"
        stage = "aps-setup"
        safe_code = "none"
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $statusPath -NoNewline
    $missingFieldFailure = Invoke-ExpectedFailure {
        Read-AuthProbeTerminalStatus `
            -StatusPath $statusPath `
            -LaunchId $launchId `
            -ProcessId $PID `
            -NotBeforeUtc $statusNotBeforeUtc
    }
    Assert-True `
        -Condition ($missingFieldFailure -eq
            "Windows authentication probe emitted a non-allowlisted status field.") `
        -Message "An authentication probe status with a missing field was accepted."

    @{
        version = "cloud-sync-v2-windows-auth-probe-status-v1"
        launch_id = $launchId
        process_id = $PID
        state = "running"
        stage = "aps-setup"
        safe_code = "none"
        updated_utc = $statusUpdatedUtc
        extra = "not-allowlisted"
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $statusPath -NoNewline
    $extraFieldFailure = Invoke-ExpectedFailure {
        Read-AuthProbeTerminalStatus `
            -StatusPath $statusPath `
            -LaunchId $launchId `
            -ProcessId $PID `
            -NotBeforeUtc $statusNotBeforeUtc
    }
    Assert-True `
        -Condition ($extraFieldFailure -eq
            "Windows authentication probe emitted a non-allowlisted status field.") `
        -Message "An authentication probe status with an extra field was accepted."

    @{
        version = "cloud-sync-v2-windows-auth-probe-status-v1"
        launch_id = $launchId
        process_id = $PID
        state = "running"
        stage = "aps-setup"
        safe_code = "none"
        updated_utc = "2026-08-31 00:00:00Z"
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $statusPath -NoNewline
    $malformedTimestampFailure = Invoke-ExpectedFailure {
        Read-AuthProbeTerminalStatus `
            -StatusPath $statusPath `
            -LaunchId $launchId `
            -ProcessId $PID `
            -NotBeforeUtc $statusNotBeforeUtc
    }
    Assert-True `
        -Condition ($malformedTimestampFailure -eq
            "Windows authentication probe status timestamp is invalid.") `
        -Message "A malformed authentication probe status timestamp was accepted."

    Set-Content -LiteralPath $statusPath -Value '{' -NoNewline
    $malformedJsonFailure = Invoke-ExpectedFailure {
        Read-AuthProbeTerminalStatus `
            -StatusPath $statusPath `
            -LaunchId $launchId `
            -ProcessId $PID `
            -NotBeforeUtc $statusNotBeforeUtc
    }
    Assert-True `
        -Condition ($malformedJsonFailure -eq
            "Windows authentication probe status JSON is invalid.") `
        -Message "Malformed authentication probe status JSON was accepted."

    @{
        version = "cloud-sync-v2-windows-auth-probe-status-v1"
        launch_id = $launchId
        process_id = [string] $PID
        state = "running"
        stage = "aps-setup"
        safe_code = "none"
        updated_utc = $statusUpdatedUtc
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $statusPath -NoNewline
    $malformedTypeFailure = Invoke-ExpectedFailure {
        Read-AuthProbeTerminalStatus `
            -StatusPath $statusPath `
            -LaunchId $launchId `
            -ProcessId $PID `
            -NotBeforeUtc $statusNotBeforeUtc
    }
    Assert-True `
        -Condition ($malformedTypeFailure -eq
            "Windows authentication probe status field types are invalid.") `
        -Message "A string-shaped authentication probe process ID was accepted."

    $staleUpdatedUtc = [DateTimeOffset]::UtcNow.AddHours(-1).ToString(
        "yyyy-MM-dd'T'HH:mm:ss.ffffff'Z'",
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    @{
        version = "cloud-sync-v2-windows-auth-probe-status-v1"
        launch_id = $launchId
        process_id = $PID
        state = "running"
        stage = "aps-setup"
        safe_code = "none"
        updated_utc = $staleUpdatedUtc
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $statusPath -NoNewline
    $staleTimestampFailure = Invoke-ExpectedFailure {
        Read-AuthProbeTerminalStatus `
            -StatusPath $statusPath `
            -LaunchId $launchId `
            -ProcessId $PID `
            -NotBeforeUtc $statusNotBeforeUtc
    }
    Assert-True `
        -Condition ($staleTimestampFailure -eq
            "Windows authentication probe status timestamp is outside the launch window.") `
        -Message "A stale authentication probe progress timestamp was accepted."

    @{
        version = "cloud-sync-v2-windows-auth-probe-status-v1"
        launch_id = (New-CryptographicLaunchId)
        process_id = $PID
        state = "running"
        stage = "aps-setup"
        safe_code = "none"
        updated_utc = $statusUpdatedUtc
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $statusPath -NoNewline
    $mismatchedLaunchFailure = Invoke-ExpectedFailure {
        Read-AuthProbeTerminalStatus `
            -StatusPath $statusPath `
            -LaunchId $launchId `
            -ProcessId $PID `
            -NotBeforeUtc $statusNotBeforeUtc
    }
    Assert-True `
        -Condition ($mismatchedLaunchFailure -eq
            "Windows authentication probe status identity is invalid.") `
        -Message "A mismatched authentication probe progress launch ID was accepted."

    @{
        version = "cloud-sync-v2-windows-auth-probe-status-v1"
        launch_id = $launchId
        process_id = ($PID + 1)
        state = "running"
        stage = "aps-setup"
        safe_code = "none"
        updated_utc = $statusUpdatedUtc
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $statusPath -NoNewline
    $mismatchedProcessFailure = Invoke-ExpectedFailure {
        Read-AuthProbeTerminalStatus `
            -StatusPath $statusPath `
            -LaunchId $launchId `
            -ProcessId $PID `
            -NotBeforeUtc $statusNotBeforeUtc
    }
    Assert-True `
        -Condition ($mismatchedProcessFailure -eq
            "Windows authentication probe status identity is invalid.") `
        -Message "A mismatched authentication probe progress process ID was accepted."

    Remove-Item -LiteralPath $syntheticStatus -Force
    $nonterminalExitLaunchId = New-CryptographicLaunchId
    $nonterminalExitProcess = Start-Process `
        -FilePath $pwshExecutable `
        -ArgumentList @(
            "-NoProfile", "-File", $syntheticChild,
            "-StatusPath", $syntheticStatus,
            "-LaunchId", $nonterminalExitLaunchId,
            "-ExitCode", "0",
            "-State", "running",
            "-Stage", "aps-ready",
            "-SafeCode", "none"
        ) `
        -PassThru
    $nonterminalExitFailure = Invoke-ExpectedFailure {
        Wait-AuthProbeTerminalProcess `
            -Process $nonterminalExitProcess `
            -StatusPath $syntheticStatus `
            -LaunchId $nonterminalExitLaunchId `
            -ExpectedExecutable $pwshExecutable `
            -TimeoutSeconds 10
    }
    Assert-True `
        -Condition ($nonterminalExitFailure -eq
            "Windows authentication probe exited without a terminal status.") `
        -Message "An exited authentication probe child with only progress status was accepted."

    $cleanupParent = Join-Path $testDirectory "cleanup-parent"
    $cleanupId = New-CryptographicLaunchId
    $cleanupRoot = Join-Path $cleanupParent $cleanupId
    New-Item -ItemType Directory -Path $cleanupRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $cleanupRoot "credential-clone.bin") -Value "x"
    Remove-ExactAuthProbeRoot `
        -ProbeRoot $cleanupRoot `
        -ProbeParent $cleanupParent `
        -ProbeIdentifier $cleanupId
    Assert-True `
        -Condition (-not (Test-Path -LiteralPath $cleanupRoot)) `
        -Message "The disposable authentication probe clone was not removed."

    $reparseCleanupParent = Join-Path $testDirectory "reparse-cleanup-parent"
    $reparseCleanupId = New-CryptographicLaunchId
    $reparseCleanupRoot = Join-Path $reparseCleanupParent $reparseCleanupId
    $reparseTarget = Join-Path $testDirectory "reparse-target"
    New-Item -ItemType Directory -Path $reparseCleanupRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $reparseTarget -Force | Out-Null
    $reparseChild = Join-Path $reparseCleanupRoot "unsafe-junction"
    New-Item -ItemType Junction -Path $reparseChild -Target $reparseTarget | Out-Null
    $reparseCleanupFailure = Invoke-ExpectedFailure {
        Remove-ExactAuthProbeRoot `
            -ProbeRoot $reparseCleanupRoot `
            -ProbeParent $reparseCleanupParent `
            -ProbeIdentifier $reparseCleanupId
    }
    Assert-True `
        -Condition ($reparseCleanupFailure -eq
            "Authentication probe source contains a reparse point.") `
        -Message "Recursive probe cleanup accepted a descendant reparse point."
    Remove-Item -LiteralPath $reparseChild -Force
    Remove-ExactAuthProbeRoot `
        -ProbeRoot $reparseCleanupRoot `
        -ProbeParent $reparseCleanupParent `
        -ProbeIdentifier $reparseCleanupId

    $source = Get-Content -LiteralPath $launcher -Raw
    $parameterSnapshot = $source.IndexOf(
        '$authProbeParameterSnapshot = @{',
        [System.StringComparison]::Ordinal
    )
    $sharedLauncherImport = $source.IndexOf(
        '. (Join-Path $PSScriptRoot "run_cloud_sync_v2_dev.ps1") -FunctionsOnlyForTest',
        [System.StringComparison]::Ordinal
    )
    $parameterRestore = $source.IndexOf(
        'foreach ($parameterName in $authProbeParameterSnapshot.Keys)',
        [System.StringComparison]::Ordinal
    )
    $switchGate = $source.IndexOf(
        'if ($authProbeFunctionsOnlyForTest)',
        [System.StringComparison]::Ordinal
    )
    Assert-True `
        -Condition ($parameterSnapshot -ge 0 -and
            $parameterSnapshot -lt $sharedLauncherImport -and
            $sharedLauncherImport -lt $parameterRestore -and
            $parameterRestore -lt $switchGate) `
        -Message "The auth-only launcher test switch is vulnerable to dot-source scope mutation."
    $firstStoreStop = $source.IndexOf(
        "Stop-StoreOpenBubbles -StoreExecutable `$storeExecutable",
        [System.StringComparison]::Ordinal
    )
    $firstSourceRead = $source.IndexOf(
        "`$isolatedShape = Read-GsaShape",
        [System.StringComparison]::Ordinal
    )
    Assert-True `
        -Condition ($firstStoreStop -ge 0 -and
            $firstStoreStop -lt $firstSourceRead) `
        -Message "The Store process is not stopped before authentication input capture."
    Assert-True `
        -Condition ($source.Contains(
            '"--target", "lib/cloud_sync_v2_windows_auth_probe.dart"'
        )) `
        -Message "The launcher no longer builds the dedicated auth-only target."
    Assert-True `
        -Condition ($source.Contains(
            'Read-AuthProbeTerminalStatus `'
        )) `
        -Message "The launcher no longer uses the exact terminal status parser."
    Assert-True `
        -Condition ($source.Contains(
            '-ProcessExitCode $Process.ExitCode'
        )) `
        -Message "The launcher no longer binds terminal status to child exit code."
    Assert-True `
        -Condition ($source.Contains(
            'Remove-ExactAuthProbeRoot `'
        )) `
        -Message "The launcher no longer removes its disposable credential clone."
    Assert-True `
        -Condition ($source.Contains(
            "source_inputs_unchanged = -not [bool] `$credentialPromotion.Promoted"
        ) -and $source.Contains(
            'if ($PromotionRequested -and $TerminalResult.Result -eq ''admitted'')'
        ) -and $source.Contains(
            'Install-AdmittedProbeGsaCredential `'
        )) `
        -Message "The explicit admitted-only credential promotion gate changed."
    $verifiedCloneRemoval = $source.IndexOf(
        '$probeRootRemoved = -not (Test-Path -LiteralPath $probeAppData)',
        [System.StringComparison]::Ordinal
    )
    $credentialPromotionPublish = $source.LastIndexOf(
        'Publish-AdmittedCredentialPromotionResult `',
        [System.StringComparison]::Ordinal
    )
    Assert-True `
        -Condition ($verifiedCloneRemoval -ge 0 -and
            $credentialPromotionPublish -gt $verifiedCloneRemoval -and
            $source.Contains(
                'Restore-AdmittedGsaCredential `'
            )) `
        -Message "Credential promotion can occur before probe cleanup or lacks rollback."
    Assert-True `
        -Condition ($source.Contains(
            '$sourceLauncherLock = Enter-ProfileScopedLauncherLock'
        )) `
        -Message "The launcher no longer locks the complete isolated source profile."
    Assert-True `
        -Condition ($source.Contains(
            '$sourceFingerprints.profile -eq (Get-TreeFingerprint -Root $sourceProfile)'
        )) `
        -Message "The launcher no longer verifies the complete isolated source profile."
    Assert-True `
        -Condition (-not $source.Contains(
            'Copy-Item -LiteralPath $sourceCloudKit'
        )) `
        -Message "The auth-only profile unexpectedly copies CloudKit state."

    Write-Host "Cloud Sync V2 Windows authentication probe launcher tests passed."
}
finally {
    if (Test-Path -LiteralPath $testDirectory -PathType Container) {
        $resolved = (Resolve-Path -LiteralPath $testDirectory).Path
        if (-not $resolved.StartsWith(
            "$tempRoot\",
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            throw "The authentication probe test cleanup escaped the temporary root."
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
        if (Test-Path -LiteralPath $resolved) {
            throw "The authentication probe test cleanup did not remove its exact target."
        }
    }
}
