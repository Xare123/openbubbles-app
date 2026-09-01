[CmdletBinding()]
param(
    [string] $FlutterRoot = "C:\Codex\Toolchains\flutter-3.44.8-arm64",
    [string] $NuGetRoot = "C:\Codex\Toolchains\nuget",
    [string] $CargoHome = "C:\Codex\Toolchains\cargo",
    [string] $RustupHome = "C:\Codex\Toolchains\rustup",
    [string] $LlvmRoot = "C:\Codex\Toolchains\LLVM-22.1.8-woa64-portable",
    [string] $PerlBin = "C:\Strawberry\perl\bin",
    [string] $SignTool = (
        "C:\Program Files (x86)\Windows Kits\10\bin\" +
        "10.0.26100.0\arm64\signtool.exe"
    ),
    [string] $SigningThumbprint = "8240557965890665F3B49E5FEC83D511CA4F2C9D",
    [string] $CargoKitCacheRoot = (
        "C:\Codex\OpenBubblesReview\build-cache\ck2-win-arm64"
    ),
    [ValidateRange(30, 600)]
    [int] $TimeoutSeconds = 180,
    [switch] $PromoteCredentialToDevProfile,
    [switch] $FunctionsOnlyForTest
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$authProbeParameterSnapshot = @{
    FlutterRoot = $FlutterRoot
    NuGetRoot = $NuGetRoot
    CargoHome = $CargoHome
    RustupHome = $RustupHome
    LlvmRoot = $LlvmRoot
    PerlBin = $PerlBin
    SignTool = $SignTool
    SigningThumbprint = $SigningThumbprint
    CargoKitCacheRoot = $CargoKitCacheRoot
    TimeoutSeconds = $TimeoutSeconds
    PromoteCredentialToDevProfile = $PromoteCredentialToDevProfile
    FunctionsOnlyForTest = $FunctionsOnlyForTest
}
. (Join-Path $PSScriptRoot "run_cloud_sync_v2_dev.ps1") -FunctionsOnlyForTest
foreach ($parameterName in $authProbeParameterSnapshot.Keys) {
    Set-Variable `
        -Name $parameterName `
        -Value $authProbeParameterSnapshot[$parameterName] `
        -Scope Local
}
$authProbeFunctionsOnlyForTest = [bool] $FunctionsOnlyForTest

function Get-ExactFileHash {
    param([Parameter(Mandatory)][string] $Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-AuthProbeSafeNativeBuildPath {
    param([Parameter(Mandatory)][string] $PathValue)

    return (($PathValue -split ';') | Where-Object {
        $_ -and $_ -notmatch '(?i)\\Strawberry\\(c|perl)\\'
    }) -join ';'
}

function Assert-NoReparsePointTree {
    param([Parameter(Mandatory)][string] $Root)

    $rootItem = Get-Item -LiteralPath $Root -Force
    $items = @($rootItem) + @(Get-ChildItem -LiteralPath $Root -Recurse -Force)
    if (@($items | Where-Object {
        $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint
    }).Count -ne 0) {
        throw "Authentication probe source contains a reparse point."
    }
}

function Assert-PlainPathKind {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)]
        [ValidateSet("Leaf", "Container")]
        [string] $Kind
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($Kind -eq "Leaf" -and $item.PSIsContainer) -or
        ($Kind -eq "Container" -and -not $item.PSIsContainer)) {
        throw "Authentication probe input has an unexpected path kind."
    }
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "Authentication probe input is a reparse point."
    }
}

function Assert-NoReparsePointAncestorChain {
    param([Parameter(Mandatory)][string] $Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    $current = $root
    $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop
    if ($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "Authentication probe path contains a reparse-point ancestor."
    }
    $relative = $fullPath.Substring($root.Length)
    foreach ($segment in @($relative -split '[\\/]' | Where-Object { $_ })) {
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) {
            break
        }
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "Authentication probe path contains a reparse-point ancestor."
        }
    }
}

function Resolve-ExactNonReparsePath {
    param([Parameter(Mandatory)][string] $Path)

    Assert-NoReparsePointAncestorChain -Path $Path
    $lexical = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $canonical = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\')
    if (-not [System.String]::Equals(
        $lexical,
        $canonical,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Authentication probe path changed under canonical resolution."
    }
    return $canonical
}

function Assert-ExactFileCopy {
    param(
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Destination
    )

    Assert-PlainPathKind -Path $Source -Kind Leaf
    Assert-PlainPathKind -Path $Destination -Kind Leaf
    if ((Get-ExactFileHash -Path $Source) -ne
        (Get-ExactFileHash -Path $Destination)) {
        throw "Authentication probe file copy did not preserve exact bytes."
    }
}

function Assert-ExactTreeCopy {
    param(
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Destination
    )

    Assert-NoReparsePointTree -Root $Source
    Assert-NoReparsePointTree -Root $Destination
    if ((Get-TreeFingerprint -Root $Source) -ne
        (Get-TreeFingerprint -Root $Destination)) {
        throw "Authentication probe tree copy did not preserve exact bytes."
    }
}

function Get-ExpectedAuthProbeFailureSafeCode {
    param([Parameter(Mandatory)][string] $Stage)

    $failureCodes = [System.Collections.Generic.Dictionary[string, string]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($name in @(
        "process-entry",
        "binding-ready",
        "profile-compile-gate",
        "profile-directory-check",
        "profile-canonical-check",
        "profile-marker-check",
        "profile-preflight-ready",
        "filesystem-service-configure",
        "profile-configured",
        "rust-ready",
        "probe-profile-prepared"
    )) {
        $failureCodes.Add($name, "cloud_sync_windows_auth_probe_profile_failed")
    }
    foreach ($name in @("hardware-restore", "hardware-restored")) {
        $failureCodes.Add($name, "cloud_sync_windows_auth_probe_hardware_failed")
    }
    foreach ($name in @("aps-setup", "aps-ready")) {
        $failureCodes.Add($name, "cloud_sync_windows_auth_probe_aps_failed")
    }
    foreach ($name in @("anisette-setup", "anisette-ready")) {
        $failureCodes.Add($name, "cloud_sync_windows_auth_probe_anisette_failed")
    }
    $failureCodes.Add("auth-login", "cloud_sync_windows_auth_probe_login_failed")
    foreach ($name in @("auth-admitted", "auth-two-factor-required", "auth-rejected")) {
        $failureCodes.Add($name, "cloud_sync_windows_auth_probe_status_failed")
    }
    $safeCode = $null
    if (-not $failureCodes.TryGetValue($Stage, [ref] $safeCode)) {
        throw "Authentication probe terminal stage is invalid."
    }
    return $safeCode
}

function Get-AuthProbeTerminalResult {
    param(
        [Parameter(Mandatory)][string] $State,
        [Parameter(Mandatory)][string] $Stage,
        [Parameter(Mandatory)][string] $SafeCode,
        [int] $ProcessExitCode
    )

    $terminal = switch -CaseSensitive ("$State|$Stage|$SafeCode") {
        "finished|auth-admitted|none" {
            [pscustomobject]@{
                Result = "admitted"
                ExitCode = 0
                ExpectedProcessExitCode = 0
            }
        }
        (
            "challenge-required|auth-two-factor-required|" +
            "cloud_sync_windows_auth_probe_two_factor_required"
        ) {
            [pscustomobject]@{
                Result = "challenge-required"
                ExitCode = 2
                ExpectedProcessExitCode = 3
            }
        }
        "failed|auth-rejected|cloud_sync_windows_auth_probe_state_rejected" {
            [pscustomobject]@{
                Result = "rejected"
                ExitCode = 2
                ExpectedProcessExitCode = 2
            }
        }
        default {
            $expectedFailureSafeCode = Get-ExpectedAuthProbeFailureSafeCode -Stage $Stage
            if (-not [System.String]::Equals(
                    $State,
                    "failed",
                    [System.StringComparison]::Ordinal
                ) -or
                -not [System.String]::Equals(
                    $SafeCode,
                    $expectedFailureSafeCode,
                    [System.StringComparison]::Ordinal
                )) {
                throw "Authentication probe terminal status is inconsistent."
            }
            [pscustomobject]@{
                Result = "failed"
                ExitCode = 1
                ExpectedProcessExitCode = 1
            }
        }
    }
    if ($PSBoundParameters.ContainsKey("ProcessExitCode") -and
        $ProcessExitCode -ne $terminal.ExpectedProcessExitCode) {
        throw "Authentication probe process exit code does not match terminal status."
    }
    return $terminal
}

function Read-AuthProbeTerminalStatus {
    param(
        [Parameter(Mandatory)][string] $StatusPath,
        [Parameter(Mandatory)][string] $LaunchId,
        [Parameter(Mandatory)][int] $ProcessId,
        [Parameter(Mandatory)][DateTimeOffset] $NotBeforeUtc,
        [DateTimeOffset] $NotAfterUtc = [DateTimeOffset]::MaxValue
    )

    $allowedFields = @(
        "version", "launch_id", "process_id", "state", "stage", "safe_code", "updated_utc"
    )
    $allowedFieldSet = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($fieldName in $allowedFields) {
        $null = $allowedFieldSet.Add($fieldName)
    }
    $statusItem = Get-Item -LiteralPath $StatusPath -Force -ErrorAction Stop
    if ($statusItem.PSIsContainer -or $statusItem.Length -le 0 -or $statusItem.Length -gt 4096) {
        throw "Windows authentication probe status shape is invalid."
    }
    $statusJson = Get-Content -LiteralPath $StatusPath -Raw -ErrorAction Stop
    $document = $null
    try {
        try {
            $document = [System.Text.Json.JsonDocument]::Parse($statusJson)
        }
        catch {
            throw "Windows authentication probe status JSON is invalid."
        }
        $root = $document.RootElement
        if ($root.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
            throw "Windows authentication probe status shape is invalid."
        }
        $seen = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::Ordinal
        )
        $values = @{}
        foreach ($property in $root.EnumerateObject()) {
            if (-not $seen.Add($property.Name) -or
                -not $allowedFieldSet.Contains($property.Name)) {
                throw "Windows authentication probe emitted a non-allowlisted status field."
            }
            if ($property.Name -eq "process_id") {
                $parsedProcessId = 0
                if ($property.Value.ValueKind -ne [System.Text.Json.JsonValueKind]::Number -or
                    -not $property.Value.TryGetInt32([ref] $parsedProcessId)) {
                    throw "Windows authentication probe status field types are invalid."
                }
                $values[$property.Name] = $parsedProcessId
            }
            else {
                if ($property.Value.ValueKind -ne [System.Text.Json.JsonValueKind]::String) {
                    throw "Windows authentication probe status field types are invalid."
                }
                $values[$property.Name] = $property.Value.GetString()
            }
        }
        if ($seen.Count -ne $allowedFields.Count) {
            throw "Windows authentication probe emitted a non-allowlisted status field."
        }
    }
    finally {
        if ($null -ne $document) {
            $document.Dispose()
        }
    }

    if (-not [System.String]::Equals(
            [string] $values.version,
            "cloud-sync-v2-windows-auth-probe-status-v1",
            [System.StringComparison]::Ordinal
        ) -or
        -not [System.String]::Equals(
            [string] $values.launch_id,
            $LaunchId,
            [System.StringComparison]::Ordinal
        ) -or
        [int] $values.process_id -ne $ProcessId) {
        throw "Windows authentication probe status identity is invalid."
    }
    $timestampText = [string] $values.updated_utc
    $updatedUtc = [DateTimeOffset]::MinValue
    $timestampStyles = (
        [System.Globalization.DateTimeStyles]::AssumeUniversal -bor
        [System.Globalization.DateTimeStyles]::AdjustToUniversal
    )
    if ($timestampText -notmatch
        '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?Z$' -or
        -not [DateTimeOffset]::TryParseExact(
            $timestampText,
            "yyyy-MM-dd'T'HH:mm:ss.FFFFFFFK",
            [System.Globalization.CultureInfo]::InvariantCulture,
            $timestampStyles,
            [ref] $updatedUtc
        )) {
        throw "Windows authentication probe status timestamp is invalid."
    }
    if ($updatedUtc -lt $NotBeforeUtc.ToUniversalTime().AddSeconds(-5) -or
        $updatedUtc -gt $NotAfterUtc.ToUniversalTime() -or
        $updatedUtc -gt [DateTimeOffset]::UtcNow.AddSeconds(5)) {
        throw "Windows authentication probe status timestamp is outside the launch window."
    }
    $candidate = [pscustomobject]@{
        version = [string] $values.version
        launch_id = [string] $values.launch_id
        process_id = [int] $values.process_id
        state = [string] $values.state
        stage = [string] $values.stage
        safe_code = [string] $values.safe_code
        updated_utc = $timestampText
    }
    $terminalStates = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($name in @("finished", "challenge-required", "failed")) {
        $null = $terminalStates.Add($name)
    }
    $initializingStages = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($name in @(
        "process-entry",
        "binding-ready",
        "profile-compile-gate",
        "profile-directory-check",
        "profile-canonical-check",
        "profile-marker-check",
        "profile-preflight-ready",
        "filesystem-service-configure",
        "profile-configured",
        "rust-ready",
        "probe-profile-prepared",
        "hardware-restore",
        "hardware-restored"
    )) {
        $null = $initializingStages.Add($name)
    }
    $runningStages = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($name in @(
        "aps-setup",
        "aps-ready",
        "anisette-setup",
        "anisette-ready",
        "auth-login"
    )) {
        $null = $runningStages.Add($name)
    }
    $terminal = $null
    if ($terminalStates.Contains($candidate.state)) {
        $terminal = Get-AuthProbeTerminalResult `
            -State ([string] $candidate.state) `
            -Stage ([string] $candidate.stage) `
            -SafeCode ([string] $candidate.safe_code)
    }
    elseif ([System.String]::Equals(
            $candidate.state,
            "initializing",
            [System.StringComparison]::Ordinal
        )) {
        if (-not $initializingStages.Contains($candidate.stage) -or
            -not [System.String]::Equals(
                $candidate.safe_code,
                "none",
                [System.StringComparison]::Ordinal
            )) {
            throw "Authentication probe progress status is inconsistent."
        }
    }
    elseif ([System.String]::Equals(
            $candidate.state,
            "running",
            [System.StringComparison]::Ordinal
        )) {
        if (-not $runningStages.Contains($candidate.stage) -or
            -not [System.String]::Equals(
                $candidate.safe_code,
                "none",
                [System.StringComparison]::Ordinal
            )) {
            throw "Authentication probe progress status is inconsistent."
        }
    }
    else {
        throw "Authentication probe status state is invalid."
    }
    return [pscustomobject]@{
        Payload = $candidate
        Terminal = $terminal
    }
}

function Get-AuthProbeStatusReadFailureCode {
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord] $Failure)

    $codes = [System.Collections.Generic.Dictionary[string, string]]::new(
        [System.StringComparer]::Ordinal
    )
    $codes.Add(
        "Windows authentication probe status shape is invalid.",
        "status-invalid-shape"
    )
    $codes.Add(
        "Windows authentication probe status JSON is invalid.",
        "status-invalid-json"
    )
    $codes.Add(
        "Windows authentication probe emitted a non-allowlisted status field.",
        "status-invalid-fields"
    )
    $codes.Add(
        "Windows authentication probe status field types are invalid.",
        "status-invalid-types"
    )
    $codes.Add(
        "Windows authentication probe status identity is invalid.",
        "status-invalid-identity"
    )
    $codes.Add(
        "Windows authentication probe status timestamp is invalid.",
        "status-invalid-timestamp"
    )
    $codes.Add(
        "Windows authentication probe status timestamp is outside the launch window.",
        "status-invalid-timestamp-window"
    )
    $codes.Add(
        "Authentication probe terminal status is inconsistent.",
        "status-invalid-terminal"
    )
    $codes.Add(
        "Authentication probe terminal stage is invalid.",
        "status-invalid-terminal-stage"
    )
    $codes.Add(
        "Authentication probe progress status is inconsistent.",
        "status-invalid-progress"
    )
    $codes.Add(
        "Authentication probe status state is invalid.",
        "status-invalid-state"
    )
    $code = $null
    if ($codes.TryGetValue($Failure.Exception.Message, [ref] $code)) {
        return $code
    }
    return "status-read-transient"
}

function Merge-AuthProbeStatusObservation {
    param(
        [AllowNull()] $LatestStatus,
        [AllowNull()][string] $LatestStatusReadFailure,
        [AllowNull()] $ValidatedStatus,
        [AllowNull()][string] $ReadFailure
    )

    $hasValidatedStatus = $PSBoundParameters.ContainsKey("ValidatedStatus")
    $hasReadFailure = $PSBoundParameters.ContainsKey("ReadFailure")
    if ($hasValidatedStatus -eq $hasReadFailure -or
        ($hasValidatedStatus -and $null -eq $ValidatedStatus) -or
        ($hasReadFailure -and [string]::IsNullOrWhiteSpace($ReadFailure))) {
        throw "Authentication probe status observation is invalid."
    }
    if ($hasValidatedStatus) {
        return [pscustomobject]@{
            LatestStatus = $ValidatedStatus
            LatestStatusReadFailure = $null
        }
    }
    return [pscustomobject]@{
        LatestStatus = $LatestStatus
        LatestStatusReadFailure = $ReadFailure
    }
}

function Get-AuthProbeTimeoutStage {
    param(
        [AllowNull()] $LatestStatus,
        [Parameter(Mandatory)][bool] $StatusObserved,
        [AllowNull()][string] $LatestStatusReadFailure
    )

    if ($null -ne $LatestStatus) {
        return [string] $LatestStatus.Payload.stage
    }
    if ($StatusObserved -and -not [string]::IsNullOrWhiteSpace($LatestStatusReadFailure)) {
        return $LatestStatusReadFailure
    }
    return "status-not-observed"
}

function Wait-AuthProbeTerminalProcess {
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process] $Process,
        [Parameter(Mandatory)][string] $StatusPath,
        [Parameter(Mandatory)][string] $LaunchId,
        [Parameter(Mandatory)][string] $ExpectedExecutable,
        [Parameter(Mandatory)][ValidateRange(1, 600)][int] $TimeoutSeconds
    )

    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    $statusNotBeforeUtc = [DateTimeOffset] $Process.StartTime.ToUniversalTime()
    $terminalStatus = $null
    $latestStatus = $null
    $statusObserved = $false
    $latestStatusReadFailure = $null
    while ([datetime]::UtcNow -lt $deadline) {
        # Observe child exit before reading status. If the child exits while a
        # read is in progress, the next iteration performs one final exact read
        # after exit instead of misclassifying a completed terminal write.
        $Process.Refresh()
        $processExitedAtIterationStart = $Process.HasExited
        if (Test-Path -LiteralPath $StatusPath -PathType Leaf) {
            $statusObserved = $true
            try {
                $candidateStatus = Read-AuthProbeTerminalStatus `
                    -StatusPath $StatusPath `
                    -LaunchId $LaunchId `
                    -ProcessId $Process.Id `
                    -NotBeforeUtc $statusNotBeforeUtc `
                    -NotAfterUtc ([DateTimeOffset] $deadline)
                $observation = Merge-AuthProbeStatusObservation `
                    -LatestStatus $latestStatus `
                    -LatestStatusReadFailure $latestStatusReadFailure `
                    -ValidatedStatus $candidateStatus
                $latestStatus = $observation.LatestStatus
                $latestStatusReadFailure = $observation.LatestStatusReadFailure
                if ($null -ne $candidateStatus.Terminal) {
                    $terminalStatus = $candidateStatus
                    break
                }
            }
            catch {
                $candidateStatus = $null
                $readFailure = Get-AuthProbeStatusReadFailureCode -Failure $_
                $observation = Merge-AuthProbeStatusObservation `
                    -LatestStatus $latestStatus `
                    -LatestStatusReadFailure $latestStatusReadFailure `
                    -ReadFailure $readFailure
                $latestStatus = $observation.LatestStatus
                $latestStatusReadFailure = $observation.LatestStatusReadFailure
            }
        }
        if ($processExitedAtIterationStart -and $null -eq $terminalStatus) {
            throw "Windows authentication probe exited without a terminal status."
        }
        Start-Sleep -Milliseconds 250
    }
    if ($null -eq $terminalStatus) {
        # A child can finish its terminal write during the final polling sleep.
        # Re-read once only when the exact child is already exited, before the
        # timeout path terminates or classifies it.
        $Process.Refresh()
        if ($Process.HasExited) {
            if (Test-Path -LiteralPath $StatusPath -PathType Leaf) {
                $statusObserved = $true
                try {
                    $candidateStatus = Read-AuthProbeTerminalStatus `
                        -StatusPath $StatusPath `
                        -LaunchId $LaunchId `
                        -ProcessId $Process.Id `
                        -NotBeforeUtc $statusNotBeforeUtc `
                        -NotAfterUtc ([DateTimeOffset] $deadline)
                    $observation = Merge-AuthProbeStatusObservation `
                        -LatestStatus $latestStatus `
                        -LatestStatusReadFailure $latestStatusReadFailure `
                        -ValidatedStatus $candidateStatus
                    $latestStatus = $observation.LatestStatus
                    $latestStatusReadFailure = $observation.LatestStatusReadFailure
                    if ($null -ne $candidateStatus.Terminal) {
                        $terminalStatus = $candidateStatus
                    }
                }
                catch {
                    $readFailure = Get-AuthProbeStatusReadFailureCode -Failure $_
                    $observation = Merge-AuthProbeStatusObservation `
                        -LatestStatus $latestStatus `
                        -LatestStatusReadFailure $latestStatusReadFailure `
                        -ReadFailure $readFailure
                    $latestStatus = $observation.LatestStatus
                    $latestStatusReadFailure = $observation.LatestStatusReadFailure
                }
            }
            if ($null -eq $terminalStatus) {
                throw "Windows authentication probe exited without a terminal status."
            }
        }
    }
    if ($null -eq $terminalStatus) {
        Stop-ExactLaunchedHarness `
            -Process $Process `
            -ExpectedExecutable $ExpectedExecutable
        $lastStage = Get-AuthProbeTimeoutStage `
            -LatestStatus $latestStatus `
            -StatusObserved $statusObserved `
            -LatestStatusReadFailure $latestStatusReadFailure
        throw "Windows authentication probe timed out at allowlisted stage: $lastStage"
    }
    if (-not $Process.WaitForExit(5000)) {
        Stop-ExactLaunchedHarness `
            -Process $Process `
            -ExpectedExecutable $ExpectedExecutable
        throw "Windows authentication probe did not exit after terminal status."
    }
    $Process.Refresh()
    $terminal = Get-AuthProbeTerminalResult `
        -State ([string] $terminalStatus.Payload.state) `
        -Stage ([string] $terminalStatus.Payload.stage) `
        -SafeCode ([string] $terminalStatus.Payload.safe_code) `
        -ProcessExitCode $Process.ExitCode
    return [pscustomobject]@{
        Payload = $terminalStatus.Payload
        Terminal = $terminal
    }
}

function Remove-ExactAuthProbeRoot {
    param(
        [Parameter(Mandatory)][string] $ProbeRoot,
        [Parameter(Mandatory)][string] $ProbeParent,
        [Parameter(Mandatory)][string] $ProbeIdentifier
    )

    if (-not (Test-Path -LiteralPath $ProbeRoot)) {
        return
    }
    if ($ProbeIdentifier -notmatch '^[a-f0-9]{32}$') {
        throw "Authentication probe cleanup identifier is invalid."
    }
    $canonicalParent = Resolve-ExactNonReparsePath -Path $ProbeParent
    $expectedRoot = [System.IO.Path]::GetFullPath(
        (Join-Path $canonicalParent $ProbeIdentifier)
    ).TrimEnd('\')
    $canonicalRoot = Resolve-ExactNonReparsePath -Path $ProbeRoot
    if (-not [System.String]::Equals(
        $expectedRoot,
        $canonicalRoot,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Authentication probe cleanup target escaped its dedicated root."
    }
    Assert-NoReparsePointTree -Root $canonicalRoot
    Remove-Item -LiteralPath $canonicalRoot -Recurse -Force
    if (Test-Path -LiteralPath $canonicalRoot) {
        throw "Authentication probe cleanup did not remove its exact target."
    }
}

function Assert-RestrictedProbeAcl {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)]
        [System.Security.Principal.SecurityIdentifier[]] $AllowedSids
    )

    $security = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $rules = @($security.GetAccessRules(
        $true,
        $true,
        [System.Security.Principal.SecurityIdentifier]
    ))
    $allowedValues = @($AllowedSids | ForEach-Object { $_.Value })
    foreach ($rule in $rules) {
        if ($rule.AccessControlType -ne
                [System.Security.AccessControl.AccessControlType]::Allow -or
            $rule.IdentityReference.Value -notin $allowedValues -or
            ($rule.FileSystemRights -band
                [System.Security.AccessControl.FileSystemRights]::FullControl) -ne
                [System.Security.AccessControl.FileSystemRights]::FullControl) {
            throw "Authentication probe ACL is not restricted to the approved principals."
        }
    }
    foreach ($sid in $AllowedSids) {
        if (-not @($rules | Where-Object {
            $_.IdentityReference.Value -eq $sid.Value
        })) {
            throw "Authentication probe ACL is missing an approved principal."
        }
    }
}

function Set-RestrictedProbeAcl {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)]
        [System.Security.Principal.SecurityIdentifier[]] $AllowedSids
    )

    $security = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $security.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($security.Access)) {
        [void] $security.RemoveAccessRuleSpecific($rule)
    }
    $inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    foreach ($sid in $AllowedSids) {
        [void] $security.AddAccessRule(
            [System.Security.AccessControl.FileSystemAccessRule]::new(
                $sid,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                $inheritance,
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow
            )
        )
    }
    Set-Acl -LiteralPath $Path -AclObject $security
}

function Get-TreeFingerprint {
    param([Parameter(Mandatory)][string] $Root)

    $canonicalRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $rows = foreach ($item in Get-ChildItem -LiteralPath $canonicalRoot -Recurse -Force) {
        $relative = [System.IO.Path]::GetRelativePath($canonicalRoot, $item.FullName)
        if ($item.PSIsContainer) {
            "D:{0}" -f $relative
        }
        else {
            "F:{0}={1}" -f $relative, (Get-ExactFileHash -Path $item.FullName)
        }
    }
    return Get-Sha256Hex -Value (($rows | Sort-Object) -join "`n")
}

function Read-GsaShape {
    param([Parameter(Mandatory)][string] $Path)

    [xml] $document = Get-Content -LiteralPath $Path -Raw
    $dictionary = $document.SelectSingleNode('/plist/dict')
    if ($null -eq $dictionary) {
        throw "Authentication probe GSA dictionary is unavailable."
    }
    $elements = @($dictionary.ChildNodes | Where-Object {
        $_.NodeType -eq [System.Xml.XmlNodeType]::Element
    })
    if ($elements.Count % 2 -ne 0) {
        throw "Authentication probe GSA dictionary is malformed."
    }
    $values = @{}
    for ($index = 0; $index -lt $elements.Count; $index += 2) {
        if ($elements[$index].Name -ne 'key' -or
            $values.ContainsKey($elements[$index].InnerText)) {
            throw "Authentication probe GSA dictionary is malformed."
        }
        $values[$elements[$index].InnerText] = $elements[$index + 1]
    }
    $usernameNode = $values['username']
    if ($null -eq $usernameNode -or $usernameNode.Name -ne 'string') {
        throw "Authentication probe account identifier is unavailable."
    }
    $username = $usernameNode.InnerText.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($username) -or $username.Length -gt 320) {
        throw "Authentication probe account identifier is malformed."
    }
    $passwordNode = $values['password']
    $encryptedNode = $values['encrypted_password']
    $digestLength = $null
    $encryptedLength = $null
    if ($null -ne $passwordNode) {
        if ($passwordNode.Name -ne 'data') {
            throw "Authentication probe password digest is malformed."
        }
        $digestLength = [Convert]::FromBase64String(
            ($passwordNode.InnerText -replace '\s', '')
        ).Length
    }
    if ($null -ne $encryptedNode) {
        if ($encryptedNode.Name -ne 'data') {
            throw "Authentication probe encrypted password is malformed."
        }
        $encryptedLength = [Convert]::FromBase64String(
            ($encryptedNode.InnerText -replace '\s', '')
        ).Length
    }
    return [pscustomobject]@{
        Username = $username
        HasLegacyDigest = $null -ne $passwordNode
        HasEncryptedDigest = $null -ne $encryptedNode
        DigestLength = $digestLength
        EncryptedLength = $encryptedLength
        PostdataDone = $null -ne $values['postdata_done'] -and
            $values['postdata_done'].Name -eq 'true'
    }
}

function Stage-AdmittedProbeGsaCredential {
    param(
        [Parameter(Mandatory)][string] $SourceGsa,
        [Parameter(Mandatory)][string] $ProbeGsa,
        [Parameter(Mandatory)][string] $LaunchId,
        [Parameter(Mandatory)][psobject] $TerminalResult
    )

    if ($LaunchId -notmatch '^[a-f0-9]{32}$') {
        throw "Credential staging launch identity is invalid."
    }
    if ($TerminalResult.Result -ne 'admitted' -or
        $TerminalResult.ExitCode -ne 0) {
        throw "Credential staging requires an admitted authentication probe."
    }
    foreach ($candidate in @($SourceGsa, $ProbeGsa)) {
        Assert-NoReparsePointAncestorChain -Path $candidate
        Assert-PlainPathKind -Path $candidate -Kind Leaf
    }
    $sourceDirectory = [System.IO.Path]::GetDirectoryName(
        [System.IO.Path]::GetFullPath($SourceGsa)
    )
    Assert-NoReparsePointAncestorChain -Path $sourceDirectory
    Assert-PlainPathKind -Path $sourceDirectory -Kind Container

    $sourceShape = Read-GsaShape -Path $SourceGsa
    $probeShape = Read-GsaShape -Path $ProbeGsa
    if (-not [System.String]::Equals(
        $sourceShape.Username,
        $probeShape.Username,
        [System.StringComparison]::Ordinal
    )) {
        throw "Credential staging account identifiers do not match."
    }
    if ($probeShape.HasLegacyDigest -or
        -not $probeShape.HasEncryptedDigest -or
        $probeShape.EncryptedLength -le 0 -or
        -not $probeShape.PostdataDone) {
        throw "Credential staging requires the admitted encrypted probe credential."
    }

    $stagePath = Join-Path $sourceDirectory (
        ".openbubbles-cloud-sync-v2-gsa-admitted-$LaunchId.plist"
    )
    if (Test-Path -LiteralPath $stagePath) {
        throw "Credential staging path already exists."
    }
    Assert-NoReparsePointAncestorChain -Path $stagePath
    try {
        Copy-Item -LiteralPath $ProbeGsa -Destination $stagePath
        Set-Acl -LiteralPath $stagePath -AclObject (Get-Acl -LiteralPath $SourceGsa)
        Assert-ExactFileCopy -Source $ProbeGsa -Destination $stagePath
        Assert-PlainPathKind -Path $stagePath -Kind Leaf
        $stageStream = [System.IO.File]::Open(
            $stagePath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        try {
            $stageStream.Flush($true)
        }
        finally {
            $stageStream.Dispose()
        }
        return $stagePath
    }
    catch {
        if (Test-Path -LiteralPath $stagePath -PathType Leaf) {
            Remove-Item -LiteralPath $stagePath -Force
        }
        throw
    }
}

function Remove-AdmittedProbeGsaCredentialStage {
    param(
        [Parameter(Mandatory)][string] $SourceGsa,
        [Parameter(Mandatory)][string] $StagePath,
        [Parameter(Mandatory)][string] $LaunchId
    )

    if ($LaunchId -notmatch '^[a-f0-9]{32}$') {
        throw "Credential stage cleanup launch identity is invalid."
    }
    $sourceDirectory = [System.IO.Path]::GetDirectoryName(
        [System.IO.Path]::GetFullPath($SourceGsa)
    )
    $expectedStage = Join-Path $sourceDirectory (
        ".openbubbles-cloud-sync-v2-gsa-admitted-$LaunchId.plist"
    )
    if (-not [System.String]::Equals(
        [System.IO.Path]::GetFullPath($StagePath),
        [System.IO.Path]::GetFullPath($expectedStage),
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Credential stage cleanup path is invalid."
    }
    if (-not (Test-Path -LiteralPath $StagePath)) {
        return
    }
    Assert-NoReparsePointAncestorChain -Path $StagePath
    Assert-PlainPathKind -Path $StagePath -Kind Leaf
    Remove-Item -LiteralPath $StagePath -Force
    if (Test-Path -LiteralPath $StagePath) {
        throw "Credential stage cleanup failed."
    }
}

function Restore-AdmittedGsaCredential {
    param(
        [Parameter(Mandatory)][string] $SourceGsa,
        [Parameter(Mandatory)][string] $BackupPath,
        [Parameter(Mandatory)][string] $LaunchId
    )

    if ($LaunchId -notmatch '^[a-f0-9]{32}$') {
        throw "Credential rollback launch identity is invalid."
    }
    Assert-NoReparsePointAncestorChain -Path $SourceGsa
    Assert-PlainPathKind -Path $SourceGsa -Kind Leaf
    $sourceDirectory = [System.IO.Path]::GetDirectoryName(
        [System.IO.Path]::GetFullPath($SourceGsa)
    )
    $expectedBackup = Join-Path $sourceDirectory (
        ".openbubbles-cloud-sync-v2-gsa-backup-$LaunchId.plist"
    )
    if (-not [System.String]::Equals(
        [System.IO.Path]::GetFullPath($BackupPath),
        [System.IO.Path]::GetFullPath($expectedBackup),
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Credential rollback path is invalid."
    }
    if (-not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
        throw "Credential rollback state is unavailable."
    }
    Assert-NoReparsePointAncestorChain -Path $BackupPath
    Assert-PlainPathKind -Path $BackupPath -Kind Leaf

    $backupHash = Get-ExactFileHash -Path $BackupPath
    if ((Get-ExactFileHash -Path $SourceGsa) -eq $backupHash) {
        return
    }
    $rollbackPath = Join-Path $sourceDirectory (
        ".openbubbles-cloud-sync-v2-gsa-rollback-$LaunchId.plist"
    )
    if (Test-Path -LiteralPath $rollbackPath) {
        throw "Credential rollback transaction path already exists."
    }
    try {
        Copy-Item -LiteralPath $BackupPath -Destination $rollbackPath
        Set-Acl -LiteralPath $rollbackPath -AclObject (Get-Acl -LiteralPath $SourceGsa)
        Assert-ExactFileCopy -Source $BackupPath -Destination $rollbackPath
        $rollbackStream = [System.IO.File]::Open(
            $rollbackPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        try {
            $rollbackStream.Flush($true)
        }
        finally {
            $rollbackStream.Dispose()
        }
        [System.IO.File]::Move($rollbackPath, $SourceGsa, $true)
        if ((Get-ExactFileHash -Path $SourceGsa) -ne $backupHash) {
            throw "Credential rollback verification failed."
        }
    }
    finally {
        if (Test-Path -LiteralPath $rollbackPath -PathType Leaf) {
            Remove-Item -LiteralPath $rollbackPath -Force
        }
    }
}

function Install-AdmittedProbeGsaCredential {
    param(
        [Parameter(Mandatory)][string] $SourceGsa,
        [Parameter(Mandatory)][string] $AdmittedGsa,
        [Parameter(Mandatory)][string] $LaunchId,
        [Parameter(Mandatory)][psobject] $TerminalResult
    )

    if ($LaunchId -notmatch '^[a-f0-9]{32}$') {
        throw "Credential promotion launch identity is invalid."
    }
    if ($TerminalResult.Result -ne 'admitted' -or
        $TerminalResult.ExitCode -ne 0) {
        throw "Credential promotion requires an admitted authentication probe."
    }

    foreach ($candidate in @($SourceGsa, $AdmittedGsa)) {
        Assert-NoReparsePointAncestorChain -Path $candidate
        Assert-PlainPathKind -Path $candidate -Kind Leaf
    }
    $sourceDirectory = [System.IO.Path]::GetDirectoryName(
        [System.IO.Path]::GetFullPath($SourceGsa)
    )
    Assert-NoReparsePointAncestorChain -Path $sourceDirectory
    Assert-PlainPathKind -Path $sourceDirectory -Kind Container

    $sourceShape = Read-GsaShape -Path $SourceGsa
    $admittedShape = Read-GsaShape -Path $AdmittedGsa
    if (-not [System.String]::Equals(
        $sourceShape.Username,
        $admittedShape.Username,
        [System.StringComparison]::Ordinal
    )) {
        throw "Credential promotion account identifiers do not match."
    }
    if ($admittedShape.HasLegacyDigest -or
        -not $admittedShape.HasEncryptedDigest -or
        $admittedShape.EncryptedLength -le 0 -or
        -not $admittedShape.PostdataDone) {
        throw "Credential promotion requires the admitted encrypted probe credential."
    }

    $sourceHash = Get-ExactFileHash -Path $SourceGsa
    $admittedHash = Get-ExactFileHash -Path $AdmittedGsa
    if ($sourceHash -eq $admittedHash) {
        return [pscustomobject]@{
            Promoted = $false
            RollbackAvailable = $false
            BackupPath = $null
        }
    }

    $backupPath = Join-Path $sourceDirectory (
        ".openbubbles-cloud-sync-v2-gsa-backup-$LaunchId.plist"
    )
    $stagePath = Join-Path $sourceDirectory (
        ".openbubbles-cloud-sync-v2-gsa-stage-$LaunchId.plist"
    )
    foreach ($candidate in @($backupPath, $stagePath)) {
        if (Test-Path -LiteralPath $candidate) {
            throw "Credential promotion transaction path already exists."
        }
        Assert-NoReparsePointAncestorChain -Path $candidate
    }

    $replaceCompleted = $false
    try {
        Copy-Item -LiteralPath $AdmittedGsa -Destination $stagePath
        Set-Acl -LiteralPath $stagePath -AclObject (Get-Acl -LiteralPath $SourceGsa)
        Assert-ExactFileCopy -Source $AdmittedGsa -Destination $stagePath
        $stageStream = [System.IO.File]::Open(
            $stagePath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        try {
            $stageStream.Flush($true)
        }
        finally {
            $stageStream.Dispose()
        }

        [System.IO.File]::Replace($stagePath, $SourceGsa, $backupPath, $true)
        $replaceCompleted = $true
        Assert-PlainPathKind -Path $SourceGsa -Kind Leaf
        Assert-PlainPathKind -Path $backupPath -Kind Leaf
        if ((Get-ExactFileHash -Path $SourceGsa) -ne $admittedHash -or
            (Get-ExactFileHash -Path $backupPath) -ne $sourceHash) {
            throw "Credential promotion verification failed."
        }
        $sourceStream = [System.IO.File]::Open(
            $SourceGsa,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        try {
            $sourceStream.Flush($true)
        }
        finally {
            $sourceStream.Dispose()
        }

        return [pscustomobject]@{
            Promoted = $true
            RollbackAvailable = $true
            BackupPath = $backupPath
        }
    }
    catch {
        if ($replaceCompleted) {
            if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
                throw "Credential promotion failed after replacement; rollback state is unavailable."
            }
            try {
                Restore-AdmittedGsaCredential `
                    -SourceGsa $SourceGsa `
                    -BackupPath $backupPath `
                    -LaunchId $LaunchId
            }
            catch {
                throw "Credential promotion and automatic rollback both failed."
            }
            throw "Credential promotion failed and was rolled back."
        }
        throw "Credential promotion failed before source replacement."
    }
    finally {
        foreach ($candidate in @($stagePath)) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                Remove-Item -LiteralPath $candidate -Force
            }
        }
    }
}

function Publish-AdmittedCredentialPromotionResult {
    param(
        [Parameter(Mandatory)][string] $SourceGsa,
        [AllowNull()][string] $AdmittedGsa,
        [Parameter(Mandatory)][string] $LaunchId,
        [Parameter(Mandatory)][int] $ProcessId,
        [Parameter(Mandatory)][psobject] $TerminalResult,
        [Parameter(Mandatory)][psobject] $StatusPayload,
        [Parameter(Mandatory)][bool] $PromotionRequested,
        [Parameter(Mandatory)][bool] $ProbeRootRemoved,
        [bool] $RemoveAdmittedGsaAfterInstall = $false,
        [scriptblock] $BeforeReport
    )

    if (-not $ProbeRootRemoved) {
        throw "Windows authentication probe cleanup was not verified."
    }
    $credentialPromotion = [pscustomobject]@{
        Promoted = $false
        RollbackAvailable = $false
        BackupPath = $null
    }
    $promotionReported = $false
    try {
        if ($PromotionRequested -and $TerminalResult.Result -eq 'admitted') {
            if ([string]::IsNullOrWhiteSpace($AdmittedGsa)) {
                throw "Credential promotion is missing the admitted probe state."
            }
            $credentialPromotion = Install-AdmittedProbeGsaCredential `
                -SourceGsa $SourceGsa `
                -AdmittedGsa $AdmittedGsa `
                -LaunchId $LaunchId `
                -TerminalResult $TerminalResult
        }
        if ($RemoveAdmittedGsaAfterInstall -and
            -not [string]::IsNullOrWhiteSpace($AdmittedGsa)) {
            Remove-AdmittedProbeGsaCredentialStage `
                -SourceGsa $SourceGsa `
                -StagePath $AdmittedGsa `
                -LaunchId $LaunchId
        }
        if ($null -ne $BeforeReport) {
            $validationOutput = @(& $BeforeReport $credentialPromotion)
            if ($validationOutput.Count -ne 0) {
                throw "Credential promotion pre-report validation emitted output."
            }
        }
        $resultPayload = [pscustomobject]@{
            result = $TerminalResult.Result
            state = [string] $StatusPayload.state
            stage = [string] $StatusPayload.stage
            safe_code = [string] $StatusPayload.safe_code
            launch_id = $LaunchId
            process_id = $ProcessId
            source_inputs_unchanged = -not [bool] $credentialPromotion.Promoted
            credential_promotion_requested = $PromotionRequested
            credential_promoted = [bool] $credentialPromotion.Promoted
            rollback_available = [bool] $credentialPromotion.RollbackAvailable
            cloudkit_initialized = $false
            objectbox_initialized = $false
            probe_profile_removed = $true
        }
        $serializedResult = $resultPayload | ConvertTo-Json
        Write-Output $serializedResult
        $promotionReported = $true
    }
    catch {
        if ($credentialPromotion.Promoted -and -not $promotionReported) {
            try {
                Restore-AdmittedGsaCredential `
                    -SourceGsa $SourceGsa `
                    -BackupPath $credentialPromotion.BackupPath `
                    -LaunchId $LaunchId
            }
            catch {
                throw "Authentication probe failed after promotion and rollback failed."
            }
        }
        throw
    }
}

if ($authProbeFunctionsOnlyForTest) {
    return
}

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$sourceProfile = Join-Path $env:APPDATA "OpenBubbles\cloudkit-v2-dev"
$sourceLauncherLock = Enter-ProfileScopedLauncherLock -ProfilePath $sourceProfile
$sourceLauncherLockOwned = $true
$probeId = $null
$probeParent = $null
$probeAppData = $null
$process = $null
$runner = $null
$resultPayload = $null
$launcherExitCode = $null
$probeRootRemoved = $false
$processSettled = $true
$admittedGsaStage = $null
try {
$sourceMarker = Join-Path $sourceProfile ".openbubbles-cloud-sync-v2-windows-dev"
if (-not (Test-Path -LiteralPath $sourceMarker -PathType Leaf) -or
    (Get-Content -LiteralPath $sourceMarker -Raw) -ne
        "openbubbles-cloud-sync-v2-windows-dev-profile:v1") {
    throw "The isolated Cloud Sync V2 development profile is unavailable."
}

$package = Get-AppxPackage -Name "OpenBubbles.OpenBubbles" -ErrorAction Stop |
    Sort-Object Version -Descending |
    Select-Object -First 1
if ($null -eq $package) {
    throw "The Microsoft Store OpenBubbles package is unavailable."
}
$storeProfile = Join-Path $env:LOCALAPPDATA (
    "Packages\{0}\LocalCache\Roaming\OpenBubbles\openbubbles" -f
    $package.PackageFamilyName
)
$storeExecutable = Resolve-StoreOpenBubblesExecutable
Stop-StoreOpenBubbles -StoreExecutable $storeExecutable
$sourceGsa = Join-Path $sourceProfile "gsa.plist"
$storeGsa = Join-Path $storeProfile "gsa.plist"
$sourceCloudKit = Join-Path $sourceProfile "cloudkit.plist"
$storeCloudKit = Join-Path $storeProfile "cloudkit.plist"
$sourceKeystore = Join-Path $sourceProfile "keystore.plist"
$sourceHardware = Join-Path $sourceProfile "hw_info.plist"
$sourceAnisette = Join-Path $sourceProfile "anisette_test"
Assert-NoReparsePointAncestorChain -Path $sourceProfile
Assert-NoReparsePointAncestorChain -Path $storeProfile
Assert-PlainPathKind -Path $sourceProfile -Kind Container
Assert-PlainPathKind -Path $storeProfile -Kind Container
Assert-NoReparsePointTree -Root $sourceProfile
Assert-PlainPathKind -Path $sourceMarker -Kind Leaf
foreach ($required in @(
    $sourceGsa,
    $storeGsa,
    $sourceCloudKit,
    $storeCloudKit,
    $sourceKeystore,
    $sourceHardware
)) {
    Assert-PlainPathKind -Path $required -Kind Leaf
}
Assert-PlainPathKind -Path $sourceAnisette -Kind Container
Assert-NoReparsePointTree -Root $sourceAnisette

$isolatedShape = Read-GsaShape -Path $sourceGsa
$storeShape = Read-GsaShape -Path $storeGsa
if (-not [System.String]::Equals(
    $isolatedShape.Username,
    $storeShape.Username,
    [System.StringComparison]::Ordinal
)) {
    throw "Authentication probe account identifiers do not match."
}
if (-not $storeShape.HasLegacyDigest -or
    $storeShape.HasEncryptedDigest -or
    $storeShape.DigestLength -ne 32) {
    throw "The Store authentication digest is not an exact legacy SHA-256 value."
}
if ((Get-ExactFileHash -Path $sourceCloudKit) -ne
    (Get-ExactFileHash -Path $storeCloudKit)) {
    throw "The isolated and Store CloudKit account state does not match."
}
if ((Get-Item -LiteralPath $storeGsa).LastWriteTimeUtc -le
    (Get-Item -LiteralPath $sourceGsa).LastWriteTimeUtc) {
    throw "The Store authentication state is not newer than the isolated state."
}

$sourceFingerprints = @{
    profile = Get-TreeFingerprint -Root $sourceProfile
    gsa = Get-ExactFileHash -Path $sourceGsa
    keystore = Get-ExactFileHash -Path $sourceKeystore
    hardware = Get-ExactFileHash -Path $sourceHardware
    anisette = Get-TreeFingerprint -Root $sourceAnisette
    store_gsa = Get-ExactFileHash -Path $storeGsa
    cloudkit = Get-ExactFileHash -Path $sourceCloudKit
    store_cloudkit = Get-ExactFileHash -Path $storeCloudKit
    source_marker = Get-ExactFileHash -Path $sourceMarker
}

$probeId = New-CryptographicLaunchId
$localAppData = [System.IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\')
$localAppData = Resolve-ExactNonReparsePath -Path $localAppData
$probeParent = Join-Path $localAppData "OpenBubbles\CloudSyncV2AuthProbes"
Assert-NoReparsePointAncestorChain -Path $probeParent
if (-not (Test-Path -LiteralPath $probeParent)) {
    New-Item -ItemType Directory -Path $probeParent -Force | Out-Null
}
Assert-PlainPathKind -Path $probeParent -Kind Container
$probeParent = Resolve-ExactNonReparsePath -Path $probeParent
$probeAppData = Join-Path $probeParent $probeId
$probeProfile = Join-Path $probeAppData "OpenBubbles\cloudkit-v2-dev"
if (Test-Path -LiteralPath $probeAppData) {
    throw "Authentication probe target already exists."
}
New-Item -ItemType Directory -Path $probeAppData | Out-Null
$probeAppData = Resolve-ExactNonReparsePath -Path $probeAppData

$probeAllowedSids = @(
    [System.Security.Principal.WindowsIdentity]::GetCurrent().User,
    [System.Security.Principal.SecurityIdentifier]::new("S-1-5-18"),
    [System.Security.Principal.SecurityIdentifier]::new("S-1-5-32-544")
)
Set-RestrictedProbeAcl -Path $probeAppData -AllowedSids $probeAllowedSids
New-Item -ItemType Directory -Path $probeProfile | Out-Null
Assert-RestrictedProbeAcl -Path $probeAppData -AllowedSids $probeAllowedSids
Assert-RestrictedProbeAcl -Path $probeProfile -AllowedSids $probeAllowedSids

Copy-Item -LiteralPath $sourceHardware -Destination (Join-Path $probeProfile "hw_info.plist")
Copy-Item -LiteralPath $sourceKeystore -Destination (Join-Path $probeProfile "keystore.plist")
Copy-Item -LiteralPath $sourceAnisette -Destination (Join-Path $probeProfile "anisette_test") -Recurse
Copy-Item -LiteralPath $storeGsa -Destination (Join-Path $probeProfile "gsa.plist")
$probeHardware = Join-Path $probeProfile "hw_info.plist"
$probeKeystore = Join-Path $probeProfile "keystore.plist"
$probeAnisette = Join-Path $probeProfile "anisette_test"
$probeGsa = Join-Path $probeProfile "gsa.plist"
Assert-ExactFileCopy -Source $sourceHardware -Destination $probeHardware
Assert-ExactFileCopy -Source $sourceKeystore -Destination $probeKeystore
Assert-ExactTreeCopy -Source $sourceAnisette -Destination $probeAnisette
Assert-ExactFileCopy -Source $storeGsa -Destination $probeGsa
Set-Content `
    -LiteralPath (Join-Path $probeProfile ".openbubbles-cloud-sync-v2-windows-dev") `
    -Value "openbubbles-cloud-sync-v2-windows-dev-profile:v1" `
    -NoNewline
Set-Content `
    -LiteralPath (Join-Path $probeProfile ".openbubbles-cloud-sync-v2-windows-auth-probe") `
    -Value "openbubbles-cloud-sync-v2-windows-auth-probe:v1" `
    -NoNewline
Assert-NoReparsePointTree -Root $probeProfile

$flutter = Join-Path $FlutterRoot "bin\flutter.bat"
$nuget = Join-Path $NuGetRoot "nuget.exe"
$rustup = Join-Path $CargoHome "bin\rustup.exe"
$clang = Join-Path $LlvmRoot "bin\clang.exe"
$perl = Join-Path $PerlBin "perl.exe"
foreach ($tool in @($flutter, $nuget, $rustup, $clang, $perl, $SignTool)) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {
        throw "Authentication probe build tool is unavailable."
    }
}
$certificate = Get-Item "Cert:\CurrentUser\My\$SigningThumbprint" -ErrorAction SilentlyContinue
if ($null -eq $certificate -or
    -not $certificate.HasPrivateKey -or
    $certificate.NotAfter -le (Get-Date)) {
    throw "The private Windows probe signing certificate is unavailable."
}

$runnerDirectory = [System.IO.Path]::GetFullPath(
    (Join-Path $repo "build\windows\arm64\runner\Debug")
).TrimEnd('\')
$runner = Join-Path $runnerDirectory "bluebubbles_app.exe"
$rustLibrary = Join-Path $runnerDirectory "rust_lib_bluebubbles.dll"
$buildArguments = @(
    "build", "windows",
    "--debug",
    "--target", "lib/cloud_sync_v2_windows_auth_probe.dart",
    "--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_DEV_PROFILE=true"
)

$previousEnvironment = @{
    harness = $env:OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_HARNESS
    flutter = $env:FLUTTER_ROOT
    cargo = $env:CARGO_HOME
    rustup = $env:RUSTUP_HOME
    cache = $env:CARGOKIT_TARGET_TEMP_DIR_OVERRIDE
    path = $env:Path
    appdata = $env:APPDATA
    lang = $env:LANG
    lc_all = $env:LC_ALL
}
$gnuOverrides = @("CC", "CXX", "AR", "LD", "RANLIB", "CFLAGS", "CXXFLAGS")
$previousGnuOverrides = @{}
foreach ($name in $gnuOverrides) {
    $previousGnuOverrides[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
}
try {
    $env:OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_HARNESS = "1"
    $env:FLUTTER_ROOT = $FlutterRoot
    $env:CARGO_HOME = $CargoHome
    $env:RUSTUP_HOME = $RustupHome
    $env:CARGOKIT_TARGET_TEMP_DIR_OVERRIDE = $CargoKitCacheRoot
    $env:LANG = "C"
    $env:LC_ALL = "C"
    foreach ($name in $gnuOverrides) {
        Remove-Item "Env:$name" -ErrorAction SilentlyContinue
    }
    $safePath = Get-AuthProbeSafeNativeBuildPath `
        -PathValue $previousEnvironment.path
    $env:Path = (
        "$NuGetRoot;$(Join-Path $CargoHome 'bin');$safePath;" +
        "$PerlBin;$(Join-Path $LlvmRoot 'bin')"
    )
    New-Item -ItemType Directory -Path $CargoKitCacheRoot -Force | Out-Null

    Push-Location $repo
    try {
        & $flutter @buildArguments
        if ($LASTEXITCODE -ne 0) {
            throw "Windows authentication probe build failed."
        }
    }
    finally {
        Pop-Location
    }
    foreach ($artifact in @($runner, $rustLibrary)) {
        if (-not (Test-Path -LiteralPath $artifact -PathType Leaf)) {
            throw "Windows authentication probe artifact is unavailable."
        }
    }
    & $SignTool sign /sha1 $SigningThumbprint /fd SHA256 $rustLibrary
    if ($LASTEXITCODE -ne 0) {
        throw "Windows authentication probe library signing failed."
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $rustLibrary
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
        $signature.SignerCertificate.Thumbprint -ne $SigningThumbprint) {
        throw "Windows authentication probe library signature is invalid."
    }

    Stop-StoreOpenBubbles -StoreExecutable $storeExecutable
    $statusPath = Join-Path $probeProfile "cloud-sync-v2-windows-auth-probe-status.json"
    $env:APPDATA = $probeAppData
    try {
        $process = Start-Process `
            -FilePath $runner `
            -WorkingDirectory $runnerDirectory `
            -ArgumentList @("--launch-id=$probeId") `
            -PassThru
        $processSettled = $false
    }
    finally {
        $env:APPDATA = $previousEnvironment.appdata
    }

    $terminalStatus = Wait-AuthProbeTerminalProcess `
        -Process $process `
        -StatusPath $statusPath `
        -LaunchId $probeId `
        -ExpectedExecutable $runner `
        -TimeoutSeconds $TimeoutSeconds
    $processSettled = $true
    $payload = $terminalStatus.Payload
    $terminal = $terminalStatus.Terminal

    foreach ($probeItem in @(
        Get-Item -LiteralPath $probeAppData -Force
    ) + @(
        Get-ChildItem -LiteralPath $probeAppData -Recurse -Force
    )) {
        Assert-RestrictedProbeAcl `
            -Path $probeItem.FullName `
            -AllowedSids $probeAllowedSids
    }

    foreach ($forbidden in @(
        "cloudkit.plist",
        "keychain.plist",
        "objectbox",
        "cloud-sync-v2",
        "attachments",
        "messages"
    )) {
        if (Test-Path -LiteralPath (Join-Path $probeProfile $forbidden)) {
            throw "Windows authentication probe initialized forbidden application state."
        }
    }

    $unchanged =
        $sourceFingerprints.profile -eq (Get-TreeFingerprint -Root $sourceProfile) -and
        $sourceFingerprints.gsa -eq (Get-ExactFileHash -Path $sourceGsa) -and
        $sourceFingerprints.keystore -eq (Get-ExactFileHash -Path $sourceKeystore) -and
        $sourceFingerprints.hardware -eq (Get-ExactFileHash -Path $sourceHardware) -and
        $sourceFingerprints.anisette -eq (Get-TreeFingerprint -Root $sourceAnisette) -and
        $sourceFingerprints.store_gsa -eq (Get-ExactFileHash -Path $storeGsa) -and
        $sourceFingerprints.cloudkit -eq (Get-ExactFileHash -Path $sourceCloudKit) -and
        $sourceFingerprints.store_cloudkit -eq (Get-ExactFileHash -Path $storeCloudKit) -and
        $sourceFingerprints.source_marker -eq (Get-ExactFileHash -Path $sourceMarker)
    if (-not $unchanged) {
        throw "A source authentication profile changed during the probe."
    }

    if ($PromoteCredentialToDevProfile -and $terminal.Result -eq 'admitted') {
        Assert-ExactFileCopy -Source $sourceKeystore -Destination $probeKeystore
        $admittedGsaStage = Stage-AdmittedProbeGsaCredential `
            -SourceGsa $sourceGsa `
            -ProbeGsa $probeGsa `
            -LaunchId $probeId `
            -TerminalResult $terminal
    }

    $launcherExitCode = $terminal.ExitCode
}
finally {
    try {
        if ($null -ne $process) {
            $process.Refresh()
            if (-not $process.HasExited) {
                Stop-ExactLaunchedHarness -Process $process -ExpectedExecutable $runner
            }
            $process.Refresh()
            if (-not $process.HasExited) {
                throw "Windows authentication probe process did not terminate."
            }
            $processSettled = $true
        }
        foreach ($entry in @(
            @{ Name = "OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_HARNESS"; Value = $previousEnvironment.harness },
            @{ Name = "FLUTTER_ROOT"; Value = $previousEnvironment.flutter },
            @{ Name = "CARGO_HOME"; Value = $previousEnvironment.cargo },
            @{ Name = "RUSTUP_HOME"; Value = $previousEnvironment.rustup },
            @{ Name = "CARGOKIT_TARGET_TEMP_DIR_OVERRIDE"; Value = $previousEnvironment.cache },
            @{ Name = "APPDATA"; Value = $previousEnvironment.appdata },
            @{ Name = "LANG"; Value = $previousEnvironment.lang },
            @{ Name = "LC_ALL"; Value = $previousEnvironment.lc_all },
            @{ Name = "Path"; Value = $previousEnvironment.path }
        )) {
            if ($null -eq $entry.Value) {
                Remove-Item "Env:$($entry.Name)" -ErrorAction SilentlyContinue
            }
            else {
                Set-Item "Env:$($entry.Name)" $entry.Value
            }
        }
        foreach ($name in $gnuOverrides) {
            $value = $previousGnuOverrides[$name]
            if ($null -eq $value) {
                Remove-Item "Env:$name" -ErrorAction SilentlyContinue
            }
            else {
                Set-Item "Env:$name" $value
            }
        }
    }
    finally {
        if (-not $processSettled) {
            throw "Authentication probe cleanup refused an active process root."
        }
        Remove-ExactAuthProbeRoot `
            -ProbeRoot $probeAppData `
            -ProbeParent $probeParent `
            -ProbeIdentifier $probeId
        $probeRootRemoved = -not (Test-Path -LiteralPath $probeAppData)
    }
}

if ($null -eq $launcherExitCode) {
    throw "Windows authentication probe completed without a classified result."
}
Publish-AdmittedCredentialPromotionResult `
    -SourceGsa $sourceGsa `
    -AdmittedGsa $admittedGsaStage `
    -LaunchId $probeId `
    -ProcessId $process.Id `
    -TerminalResult $terminal `
    -StatusPayload $payload `
    -PromotionRequested ([bool] $PromoteCredentialToDevProfile) `
    -ProbeRootRemoved $probeRootRemoved `
    -RemoveAdmittedGsaAfterInstall ([bool] $PromoteCredentialToDevProfile)
if ($launcherExitCode -ne 0) {
    exit $launcherExitCode
}
}
finally {
    try {
        if ($null -ne $process) {
            $process.Refresh()
            if (-not $process.HasExited) {
                Stop-ExactLaunchedHarness -Process $process -ExpectedExecutable $runner
            }
            $process.Refresh()
            if (-not $process.HasExited) {
                throw "Windows authentication probe process did not terminate."
            }
            $processSettled = $true
        }
        if ($null -ne $probeAppData -and
            (Test-Path -LiteralPath $probeAppData)) {
            if (-not $processSettled) {
                throw "Authentication probe cleanup refused an active process root."
            }
            Remove-ExactAuthProbeRoot `
                -ProbeRoot $probeAppData `
                -ProbeParent $probeParent `
                -ProbeIdentifier $probeId
            $probeRootRemoved = -not (Test-Path -LiteralPath $probeAppData)
        }
    }
    finally {
        if ($null -ne $admittedGsaStage -and
            (Test-Path -LiteralPath $admittedGsaStage)) {
            Remove-AdmittedProbeGsaCredentialStage `
                -SourceGsa $sourceGsa `
                -StagePath $admittedGsaStage `
                -LaunchId $probeId
        }
        if ($sourceLauncherLockOwned) {
            try {
                $sourceLauncherLock.ReleaseMutex()
            }
            finally {
                $sourceLauncherLock.Dispose()
                $sourceLauncherLockOwned = $false
            }
        }
    }
}
