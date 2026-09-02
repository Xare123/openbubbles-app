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
    [switch] $SkipBuild,
    [switch] $RunOnce,
    [switch] $Drain,
    [switch] $AttachmentProbe,
    [switch] $AttachmentProbeReuse,
    [switch] $ProjectionViewer,
    [switch] $ProjectionDetailViewer,
    [ValidateRange(30, 3600)]
    [int] $RunOnceTimeoutSeconds = 600,
    [ValidateRange(60, 7200)]
    [int] $DrainTimeoutSeconds = 3600,
    [ValidateRange(60, 1800)]
    [int] $AttachmentProbeTimeoutSeconds = 900,
    [switch] $FunctionsOnlyForTest
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$selectedOperations = @(
    @(
        $RunOnce,
        $Drain,
        $AttachmentProbe,
        $AttachmentProbeReuse,
        $ProjectionViewer,
        $ProjectionDetailViewer
    ) | Where-Object { $_ }
)
if ($selectedOperations.Count -gt 1) {
    throw "Choose only one harness operation."
}

function Get-Sha256Hex {
    param([Parameter(Mandatory)][string] $Value)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString(
            $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value))
        )).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function New-CryptographicLaunchId {
    $bytes = New-Object byte[] 16
    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $generator.GetBytes($bytes)
        return ([System.BitConverter]::ToString($bytes)).Replace(
            '-',
            ''
        ).ToLowerInvariant()
    }
    finally {
        $generator.Dispose()
    }
}

function Write-HarnessBuildReceipt {
    param(
        [Parameter(Mandatory)][string] $ReceiptPath,
        [Parameter(Mandatory)][string] $BuildIdentifier,
        [Parameter(Mandatory)][string] $Runner,
        [Parameter(Mandatory)][string] $RustLibrary
    )

    $receiptDirectory = Split-Path -Parent $ReceiptPath
    New-Item -ItemType Directory -Path $receiptDirectory -Force | Out-Null
    $temporaryReceipt = Join-Path $receiptDirectory (
        '.windows-harness-build-' + [guid]::NewGuid().ToString('N') + '.tmp'
    )
    try {
        [ordered]@{
            version = 'cloud-sync-v2-windows-harness-build-v1'
            build_identifier = $BuildIdentifier
            runner_sha256 = (
                Get-FileHash -LiteralPath $Runner -Algorithm SHA256
            ).Hash.ToLowerInvariant()
            rust_library_sha256 = (
                Get-FileHash -LiteralPath $RustLibrary -Algorithm SHA256
            ).Hash.ToLowerInvariant()
            created_utc = [datetime]::UtcNow.ToString('o')
        } | ConvertTo-Json -Compress |
            Set-Content -LiteralPath $temporaryReceipt -Encoding UTF8
        Move-Item `
            -LiteralPath $temporaryReceipt `
            -Destination $ReceiptPath `
            -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryReceipt -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryReceipt -Force
        }
    }
}

function Test-HarnessBuildReceipt {
    param(
        [Parameter(Mandatory)][string] $ReceiptPath,
        [Parameter(Mandatory)][string] $BuildIdentifier,
        [Parameter(Mandatory)][string] $Runner,
        [Parameter(Mandatory)][string] $RustLibrary
    )

    if (-not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) {
        return $false
    }
    try {
        $receipt = Get-Content -LiteralPath $ReceiptPath -Raw |
            ConvertFrom-Json
        if ($receipt.version -ne
                'cloud-sync-v2-windows-harness-build-v1' -or
            $receipt.build_identifier -ne $BuildIdentifier) {
            return $false
        }
        $runnerHash = (
            Get-FileHash -LiteralPath $Runner -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        $rustLibraryHash = (
            Get-FileHash -LiteralPath $RustLibrary -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        return (
            $receipt.runner_sha256 -eq $runnerHash -and
            $receipt.rust_library_sha256 -eq $rustLibraryHash
        )
    }
    catch {
        return $false
    }
}

function Enter-ProfileScopedLauncherLock {
    param([Parameter(Mandatory)][string] $ProfilePath)

    $canonicalProfile = (
        [System.IO.Path]::GetFullPath($ProfilePath).TrimEnd('\')
    ).ToUpperInvariant()
    $profileHash = Get-Sha256Hex -Value $canonicalProfile
    $mutexName = "Local\OpenBubblesCloudSyncV2Launcher-$profileHash"
    $mutex = [System.Threading.Mutex]::new($false, $mutexName)
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne(0)
        }
        catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            throw "Another Cloud Sync V2 launcher already owns this profile."
        }
        return $mutex
    }
    catch {
        if (-not $acquired) {
            $mutex.Dispose()
        }
        throw
    }
}

function Resolve-HarnessBuildIdentifier {
    param([Parameter(Mandatory)][string] $Repository)

    $commit = (& git -C $Repository rev-parse --short=12 HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[0-9a-f]{7,40}$') {
        throw "Could not resolve the harness build commit."
    }

    $sourcePaths = @(
        'lib',
        'rust',
        'rustpush',
        'rust_builder',
        'windows',
        'pubspec.yaml',
        'pubspec.lock'
    )
    $status = @(& git -C $Repository status --porcelain=v1 -- @sourcePaths)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect the harness source state."
    }
    if ($status.Count -eq 0) {
        return $commit
    }

    $diff = @(
        & git -C $Repository -c core.safecrlf=false diff `
            --submodule=diff --binary --no-ext-diff HEAD -- @sourcePaths 2>$null
    )
    if ($LASTEXITCODE -ne 0) {
        throw "Could not fingerprint the modified harness source."
    }
    $untracked = @(
        & git -C $Repository ls-files --others --exclude-standard -- @sourcePaths
    ) | Sort-Object
    if ($LASTEXITCODE -ne 0) {
        throw "Could not fingerprint untracked harness source."
    }
    $untrackedBlobs = foreach ($relativePath in $untracked) {
        $blob = (& git -C $Repository hash-object -- $relativePath).Trim()
        if ($LASTEXITCODE -ne 0 -or $blob -notmatch '^[0-9a-f]{40,64}$') {
            throw "Could not fingerprint an untracked harness source file."
        }
        "$relativePath=$blob"
    }
    $material = ($diff -join "`n") + "`n" + ($untrackedBlobs -join "`n")
    $fingerprint = Get-Sha256Hex -Value $material
    return "$commit-dirty-$($fingerprint.Substring(0, 12))"
}

function Resolve-StoreOpenBubblesExecutable {
    $package = Get-AppxPackage -Name "OpenBubbles.OpenBubbles" -ErrorAction Stop |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if ($null -eq $package) {
        throw "The Microsoft Store OpenBubbles package was not found."
    }
    $storeExecutable = [System.IO.Path]::GetFullPath(
        (Join-Path $package.InstallLocation "bluebubbles_app.exe")
    )
    if (-not (Test-Path -LiteralPath $storeExecutable -PathType Leaf)) {
        throw "The Microsoft Store OpenBubbles executable was not found."
    }
    return $storeExecutable
}

function Stop-StoreOpenBubbles {
    param([Parameter(Mandatory)][string] $StoreExecutable)

    $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq "bluebubbles_app.exe" })
    $foreign = @($processes | Where-Object {
        [string]::IsNullOrWhiteSpace($_.ExecutablePath) -or
        -not [System.String]::Equals(
            $_.ExecutablePath,
            $StoreExecutable,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    })
    if ($foreign.Count -ne 0) {
        throw "A non-Store OpenBubbles process is running; refusing to stop it."
    }
    $storeProcesses = @($processes | Where-Object {
        [System.String]::Equals(
            $_.ExecutablePath,
            $StoreExecutable,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    })
    foreach ($process in $storeProcesses) {
        $storeProcess = Get-Process `
            -Id $process.ProcessId `
            -ErrorAction SilentlyContinue
        if ($null -eq $storeProcess) {
            continue
        }
        if (-not $storeProcess.CloseMainWindow()) {
            throw "Close the Microsoft Store OpenBubbles window before launch."
        }
        if (-not $storeProcess.WaitForExit(10000)) {
            throw "Microsoft Store OpenBubbles did not close within 10 seconds."
        }
    }
}

function ConvertTo-SafeHarnessStatusValue {
    param(
        [AllowNull()][object] $Value,
        [Parameter(Mandatory)][string] $Fallback
    )

    $text = [string]$Value
    if ($text -match '^[A-Za-z0-9._-]{1,96}$') {
        return $text
    }
    return $Fallback
}

function Read-HarnessStatusText {
    param([Parameter(Mandatory)][string] $Path)

    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $stream = [System.IO.File]::Open(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        $share
    )
    try {
        $reader = [System.IO.StreamReader]::new(
            $stream,
            [System.Text.Encoding]::UTF8,
            $true
        )
        try {
            return $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Find-LatestReadOnlyHarnessReport {
    param(
        [Parameter(Mandatory)][string] $ReportDirectory,
        [Parameter(Mandatory)][datetime] $NotOlderThanUtc
    )

    $reports = Get-ChildItem `
        -LiteralPath $ReportDirectory `
        -Filter "obcs2-semantic-*.json" `
        -File `
        -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending
    foreach ($report in $reports) {
        if ($report.LastWriteTimeUtc -lt $NotOlderThanUtc) {
            break
        }
        try {
            $payload = Read-HarnessStatusText -Path $report.FullName |
                ConvertFrom-Json
        }
        catch {
            throw "The latest harness report is not readable."
        }
        $modeProperty = $payload.PSObject.Properties['mode']
        if ($null -eq $modeProperty) {
            throw "The latest harness report mode is missing."
        }
        $mode = [string]$modeProperty.Value
        if ($mode -eq 'manual-semantic-read-only-cloudkit') {
            return [pscustomobject]@{
                File = $report
                Payload = $payload
            }
        }
        if ($mode -ne 'manual-semantic-local-projection-sweep') {
            throw "The latest harness report mode is not recognized."
        }
    }
    return $null
}

function Read-FreshHarnessStatus {
    param(
        [Parameter(Mandatory)][string] $StatusPath,
        [Parameter(Mandatory)][datetime] $LaunchStartedUtc,
        [Parameter(Mandatory)][datetime] $BaselineWriteUtc,
        [Parameter(Mandatory)][string] $ExpectedLaunchId,
        [Parameter(Mandatory)][int] $ExpectedProcessId
    )

    try {
        if (-not (Test-Path -LiteralPath $StatusPath -PathType Leaf)) {
            return $null
        }
        $statusFile = Get-Item -LiteralPath $StatusPath -Force
        if ($statusFile.LastWriteTimeUtc -le $BaselineWriteUtc) {
            return $null
        }
        $payload = Read-HarnessStatusText -Path $StatusPath | ConvertFrom-Json
        $updatedProperty = $payload.PSObject.Properties['updated_utc']
        $versionProperty = $payload.PSObject.Properties['version']
        $launchIdProperty = $payload.PSObject.Properties['launch_id']
        $processIdProperty = $payload.PSObject.Properties['process_id']
        $stateProperty = $payload.PSObject.Properties['state']
        $stageProperty = $payload.PSObject.Properties['stage']
        if ($null -eq $versionProperty -or
            $null -eq $launchIdProperty -or
            $null -eq $processIdProperty -or
            $null -eq $updatedProperty -or
            $null -eq $stateProperty -or
            $null -eq $stageProperty) {
            return $null
        }
        if ([string]$versionProperty.Value -ne
                'cloud-sync-v2-windows-harness-status-v2' -or
            -not [System.String]::Equals(
                [string]$launchIdProperty.Value,
                $ExpectedLaunchId,
                [System.StringComparison]::Ordinal
            )) {
            return $null
        }
        try {
            $statusProcessId = [System.Convert]::ToInt32(
                $processIdProperty.Value,
                [System.Globalization.CultureInfo]::InvariantCulture
            )
        }
        catch {
            return $null
        }
        if ($statusProcessId -ne $ExpectedProcessId) {
            return $null
        }
        $updatedUtc = [DateTimeOffset]::Parse(
            [string]$updatedProperty.Value,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal -bor
                [System.Globalization.DateTimeStyles]::AdjustToUniversal
        ).UtcDateTime
        if ($updatedUtc -lt $LaunchStartedUtc.AddSeconds(-2)) {
            return $null
        }
        $safeCodeProperty = $payload.PSObject.Properties['safe_code']
        return [pscustomobject]@{
            state = ConvertTo-SafeHarnessStatusValue `
                -Value $stateProperty.Value -Fallback 'unknown'
            stage = ConvertTo-SafeHarnessStatusValue `
                -Value $stageProperty.Value -Fallback 'unknown'
            safe_code = ConvertTo-SafeHarnessStatusValue `
                -Value $(if ($null -eq $safeCodeProperty) {
                    $null
                } else {
                    $safeCodeProperty.Value
                }) `
                -Fallback 'cloud_sync_windows_harness_failed'
        }
    }
    catch {
        # The harness replaces this file atomically. Retry transient reads and
        # malformed partial observations until the outer deadline expires.
        return $null
    }
}

function Stop-ExactLaunchedHarness {
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process] $Process,
        [Parameter(Mandatory)][string] $ExpectedExecutable
    )

    $Process.Refresh()
    if ($Process.HasExited) {
        return
    }
    $processInfo = Get-CimInstance Win32_Process -Filter (
        "ProcessId = {0}" -f $Process.Id
    ) -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $processInfo) {
        return
    }
    if ([string]::IsNullOrWhiteSpace($processInfo.ExecutablePath) -or
        -not [System.String]::Equals(
            [System.IO.Path]::GetFullPath($processInfo.ExecutablePath),
            $ExpectedExecutable,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        throw "Refusing to stop a process that is not the launched harness."
    }
    if ($Process.CloseMainWindow() -and $Process.WaitForExit(5000)) {
        return
    }
    $Process.Refresh()
    if ($Process.HasExited) {
        return
    }
    $processInfo = Get-CimInstance Win32_Process -Filter (
        "ProcessId = {0}" -f $Process.Id
    ) -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $processInfo -or
        [string]::IsNullOrWhiteSpace($processInfo.ExecutablePath) -or
        -not [System.String]::Equals(
            [System.IO.Path]::GetFullPath($processInfo.ExecutablePath),
            $ExpectedExecutable,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        throw "Refusing to force-stop a process that is not the launched harness."
    }
    Stop-Process -Id $Process.Id -Force -ErrorAction Stop
    Wait-Process -Id $Process.Id -Timeout 5 -ErrorAction SilentlyContinue
}

function Wait-HarnessOperation {
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process] $Process,
        [Parameter(Mandatory)][string] $ExpectedExecutable,
        [Parameter(Mandatory)][string] $StatusPath,
        [Parameter(Mandatory)][datetime] $LaunchStartedUtc,
        [Parameter(Mandatory)][datetime] $BaselineWriteUtc,
        [Parameter(Mandatory)][string] $ExpectedLaunchId,
        [Parameter(Mandatory)][ValidateSet(
            'run-once',
            'drain',
            'attachment-probe',
            'attachment-reuse-probe'
        )]
        [string] $ExpectedOperation,
        [Parameter(Mandatory)][int] $TimeoutSeconds
    )

    $deadlineUtc = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([datetime]::UtcNow -lt $deadlineUtc) {
        $status = Read-FreshHarnessStatus `
            -StatusPath $StatusPath `
            -LaunchStartedUtc $LaunchStartedUtc `
            -BaselineWriteUtc $BaselineWriteUtc `
            -ExpectedLaunchId $ExpectedLaunchId `
            -ExpectedProcessId $Process.Id
        if ($null -ne $status) {
            if ($status.state -eq 'finished') {
                $acceptedFinishedStage = if ($ExpectedOperation -eq 'drain') {
                    $status.stage -in @(
                        'semantic-drain-complete',
                        'semantic-drain-remote-complete-projection-partial'
                    )
                }
                elseif ($ExpectedOperation -eq 'attachment-probe') {
                    $status.stage -eq 'attachment-probe-complete'
                }
                elseif ($ExpectedOperation -eq 'attachment-reuse-probe') {
                    $status.stage -eq 'attachment-reuse-probe-complete'
                }
                else {
                    $status.stage -eq 'semantic-pull'
                }
                Stop-ExactLaunchedHarness `
                    -Process $Process `
                    -ExpectedExecutable $ExpectedExecutable
                if (-not $acceptedFinishedStage) {
                    throw "Cloud Sync V2 Windows harness reported an invalid terminal stage."
                }
                Write-Host (
                    "Cloud Sync V2 Windows harness finished at stage {0}." -f
                    $status.stage
                )
                return
            }
            if ($status.state -eq 'resumable') {
                Stop-ExactLaunchedHarness `
                    -Process $Process `
                    -ExpectedExecutable $ExpectedExecutable
                if ($ExpectedOperation -ne 'drain' -or
                    $status.stage -ne 'semantic-drain-pass-limit') {
                    throw "Cloud Sync V2 Windows harness reported an invalid resumable stage."
                }
                throw (
                    "Cloud Sync V2 Windows drain reached its safe pass limit " +
                    "and remains resumable."
                )
            }
            if ($status.state -eq 'failed') {
                Stop-ExactLaunchedHarness `
                    -Process $Process `
                    -ExpectedExecutable $ExpectedExecutable
                throw (
                    "Cloud Sync V2 Windows harness failed at stage {0} ({1})." -f
                    $status.stage,
                    $status.safe_code
                )
            }
            if ($status.state -eq 'waiting-user') {
                Write-Host (
                    "Cloud Sync V2 Windows harness is waiting for user input at " +
                    "stage $($status.stage) (PID $($Process.Id)); leaving it running."
                )
                return
            }
        }

        $Process.Refresh()
        if ($Process.HasExited) {
            throw "The Windows harness exited before recording a terminal status."
        }
        Start-Sleep -Milliseconds 500
    }

    $Process.Refresh()
    if ($Process.HasExited) {
        throw "The Windows harness exited before recording a terminal status."
    }
    throw (
        "Timed out waiting for the Windows harness terminal status; " +
        "the harness remains running."
    )
}

if ($FunctionsOnlyForTest) {
    return
}

$profile = Join-Path $env:APPDATA "OpenBubbles\cloudkit-v2-dev"
$marker = Join-Path $profile ".openbubbles-cloud-sync-v2-windows-dev"
if (-not (Test-Path -LiteralPath $marker -PathType Leaf) -or
    (Get-Content -LiteralPath $marker -Raw) -ne
        "openbubbles-cloud-sync-v2-windows-dev-profile:v1") {
    throw "Run bootstrap_cloud_sync_v2_dev_profile.ps1 first."
}
$attachmentProbeMarker = Join-Path `
    $profile `
    ".openbubbles-cloud-sync-v2-attachment-probe-copy"
if (($AttachmentProbe -or $AttachmentProbeReuse) -and
    (-not (Test-Path -LiteralPath $attachmentProbeMarker -PathType Leaf) -or
        (Get-Content -LiteralPath $attachmentProbeMarker -Raw) -ne
            "openbubbles-cloud-sync-v2-attachment-probe-copy:v1")) {
    throw "Attachment probing requires an explicitly marked disposable profile copy."
}

$flutter = Join-Path $FlutterRoot "bin\flutter.bat"
if (-not (Test-Path -LiteralPath $flutter -PathType Leaf)) {
    throw "Flutter 3.44.8 was not found at $FlutterRoot"
}
$nuget = Join-Path $NuGetRoot "nuget.exe"
if (-not (Test-Path -LiteralPath $nuget -PathType Leaf)) {
    throw "NuGet was not found at $NuGetRoot"
}
$rustup = Join-Path $CargoHome "bin\rustup.exe"
if (-not (Test-Path -LiteralPath $rustup -PathType Leaf)) {
    throw "Rustup was not found under $CargoHome"
}
if (-not (Test-Path -LiteralPath $RustupHome -PathType Container)) {
    throw "The Rust toolchain root was not found at $RustupHome"
}
$clang = Join-Path $LlvmRoot "bin\clang.exe"
if (-not (Test-Path -LiteralPath $clang -PathType Leaf)) {
    throw "The native ARM64 clang toolchain was not found at $LlvmRoot"
}
$perl = Join-Path $PerlBin "perl.exe"
if (-not (Test-Path -LiteralPath $perl -PathType Leaf)) {
    throw "Perl was not found at $PerlBin"
}
if (-not (Test-Path -LiteralPath $SignTool -PathType Leaf)) {
    throw "The ARM64 Windows signing tool was not found at $SignTool"
}
$signingCertificate = Get-Item (
    "Cert:\CurrentUser\My\$SigningThumbprint"
) -ErrorAction SilentlyContinue
if ($null -eq $signingCertificate -or
    -not $signingCertificate.HasPrivateKey -or
    $signingCertificate.NotAfter -le (Get-Date)) {
    throw "The private Windows harness signing certificate is unavailable."
}
$cargoKitCache = [System.IO.Path]::GetFullPath($CargoKitCacheRoot).TrimEnd('\')
$cargoKitCacheVolume = [System.IO.Path]::GetPathRoot($cargoKitCache).TrimEnd('\')
if ($cargoKitCache -eq $cargoKitCacheVolume -or
    $cargoKitCache.Length -lt ($cargoKitCacheVolume.Length + 12)) {
    throw "CargoKitCacheRoot is too broad: $cargoKitCache"
}
New-Item -ItemType Directory -Path $cargoKitCache -Force | Out-Null

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$harnessSource = Join-Path $repo "lib\cloud_sync_v2_windows_harness.dart"
if (-not (Test-Path -LiteralPath $harnessSource -PathType Leaf)) {
    throw "The Windows Cloud Sync V2 harness source file was not found."
}
$buildIdentifier = Resolve-HarnessBuildIdentifier -Repository $repo
$storeExecutable = Resolve-StoreOpenBubblesExecutable
$runnerDirectory = Join-Path $repo "build\windows\arm64\runner\Debug"
$runnerDirectory = [System.IO.Path]::GetFullPath($runnerDirectory).TrimEnd('\')
$rustLibrary = [System.IO.Path]::GetFullPath(
    (Join-Path $runnerDirectory "rust_lib_bluebubbles.dll")
)
$runner = [System.IO.Path]::GetFullPath(
    (Join-Path $runnerDirectory "bluebubbles_app.exe")
)
$buildReceiptPath = Join-Path (
    Join-Path $profile 'cloud-sync-v2'
) 'windows-harness-build-receipt.json'
$trustedPrefix = "$runnerDirectory\"

$arguments = @(
    "build", "windows",
    "--debug",
    "--target", "lib/cloud_sync_v2_windows_harness.dart",
    "--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_DEV_PROFILE=true",
    "--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_SEMANTIC_PULL=true",
    "--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_SAMPLER=true",
    "--dart-define=OPENBUBBLES_BUILD_COMMIT=$buildIdentifier"
)

$launcherLock = Enter-ProfileScopedLauncherLock -ProfilePath $profile
$launcherLockOwned = $true
$repositoryLocationPushed = $false
try {
Push-Location $repo
$repositoryLocationPushed = $true
$previousHarnessMode = $env:OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_HARNESS
$previousProcessPath = $env:Path
$previousFlutterRoot = $env:FLUTTER_ROOT
$previousCargoHome = $env:CARGO_HOME
$previousRustupHome = $env:RUSTUP_HOME
$previousCargoKitCache = $env:CARGOKIT_TARGET_TEMP_DIR_OVERRIDE
$previousLang = $env:LANG
$previousLcAll = $env:LC_ALL
$gnuOverrides = @("CC", "CXX", "AR", "LD", "RANLIB", "CFLAGS", "CXXFLAGS")
$previousGnuOverrides = @{}
foreach ($gnuOverride in $gnuOverrides) {
    $previousGnuOverrides[$gnuOverride] = [Environment]::GetEnvironmentVariable(
        $gnuOverride,
        "Process"
    )
}
try {
    $env:OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_HARNESS = "1"
    $env:FLUTTER_ROOT = $FlutterRoot
    $env:CARGO_HOME = $CargoHome
    $env:RUSTUP_HOME = $RustupHome
    $env:CARGOKIT_TARGET_TEMP_DIR_OVERRIDE = $cargoKitCache
    $env:LANG = "C"
    $env:LC_ALL = "C"
    foreach ($gnuOverride in $gnuOverrides) {
        Remove-Item "Env:$gnuOverride" -ErrorAction SilentlyContinue
    }
    $safeExistingPath = (($previousProcessPath -split ';') | Where-Object {
        $_ -and $_ -notmatch '(?i)\\Strawberry\\(c|perl)\\'
    }) -join ';'
    $llvmBin = Join-Path $LlvmRoot "bin"
    $env:Path = (
        "$NuGetRoot;$(Join-Path $CargoHome 'bin');" +
        "$safeExistingPath;$PerlBin;$llvmBin"
    )
    # A timeout or waiting-user return deliberately leaves the exact harness
    # alive. Reject that process before touching its build artifacts, then
    # repeat the same check immediately before this invocation launches.
    Stop-StoreOpenBubbles -StoreExecutable $storeExecutable
    if (-not $SkipBuild) {
        & $flutter @arguments
        if ($LASTEXITCODE -ne 0) {
            throw (
                "Windows Cloud Sync V2 harness build exited with code " +
                $LASTEXITCODE
            )
        }
    }
    foreach ($artifact in @($rustLibrary, $runner)) {
        if (-not $artifact.StartsWith(
            $trustedPrefix,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or -not (Test-Path -LiteralPath $artifact -PathType Leaf)) {
            throw "The harness build did not produce its expected artifact."
        }
    }

    if (-not $SkipBuild) {
        & $SignTool sign /sha1 $SigningThumbprint /fd SHA256 $rustLibrary
        if ($LASTEXITCODE -ne 0) {
            throw "Signing the Windows harness Rust library failed."
        }
        Write-HarnessBuildReceipt `
            -ReceiptPath $buildReceiptPath `
            -BuildIdentifier $buildIdentifier `
            -Runner $runner `
            -RustLibrary $rustLibrary
    }
    elseif ($ProjectionViewer -or $ProjectionDetailViewer) {
        if (-not (Test-HarnessBuildReceipt `
            -ReceiptPath $buildReceiptPath `
            -BuildIdentifier $buildIdentifier `
            -Runner $runner `
            -RustLibrary $rustLibrary
        )) {
            throw "No matching receipt proves the existing viewer build."
        }
    }
    else {
        $reportDirectory = Join-Path $profile "cloud-sync-v2\reports"
        $minimumReportWriteUtc = @(
            (Get-Item -LiteralPath $runner).LastWriteTimeUtc,
            (Get-Item -LiteralPath $rustLibrary).LastWriteTimeUtc
        ) | Sort-Object -Descending | Select-Object -First 1
        $latestReport = Find-LatestReadOnlyHarnessReport `
            -ReportDirectory $reportDirectory `
            -NotOlderThanUtc $minimumReportWriteUtc
        if ($null -eq $latestReport) {
            throw "No fresh report proves the existing harness build."
        }
        $latestReportPayload = $latestReport.Payload
        if ($latestReportPayload.mode -ne
                "manual-semantic-read-only-cloudkit" -or
            $latestReportPayload.buildCommit -ne $buildIdentifier) {
            throw (
                "The existing harness does not match the current source; " +
                "rerun without -SkipBuild."
            )
        }
        Write-Host "Reusing the verified Windows harness build."
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $rustLibrary
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
        $signature.SignerCertificate.Thumbprint -ne $SigningThumbprint) {
        throw "The Windows harness Rust library signature is not valid."
    }

    $launchId = New-CryptographicLaunchId
    $harnessArguments = @("--launch-id=$launchId")
    if ($RunOnce) {
        $harnessArguments = @("run-once") + $harnessArguments
    }
    elseif ($Drain) {
        $harnessArguments = @("drain") + $harnessArguments
    }
    elseif ($AttachmentProbe) {
        $harnessArguments = @("probe-attachment") + $harnessArguments
    }
    elseif ($AttachmentProbeReuse) {
        $harnessArguments = @("probe-attachment-reuse") + $harnessArguments
    }
    elseif ($ProjectionViewer) {
        $harnessArguments = @("view-projection") + $harnessArguments
    }
    elseif ($ProjectionDetailViewer) {
        $harnessArguments = @("view-projection-detail") + $harnessArguments
    }
    $startParameters = @{
        FilePath = $runner
        WorkingDirectory = $runnerDirectory
        PassThru = $true
        ArgumentList = $harnessArguments
    }
    $statusPath = Join-Path $profile "cloud-sync-v2\windows-harness-status.json"
    $statusBaselineWriteUtc = [datetime]::MinValue
    if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
        $statusBaselineWriteUtc = (
            Get-Item -LiteralPath $statusPath -Force
        ).LastWriteTimeUtc
    }
    Stop-StoreOpenBubbles -StoreExecutable $storeExecutable
    $launchStartedUtc = [datetime]::UtcNow
    $process = Start-Process @startParameters
    try {
        $null = $process.WaitForInputIdle(10000)
    }
    catch {
        # Flutter may initialize before Win32 exposes an input-idle signal.
    }
    if ($process.HasExited) {
        throw "The Windows Cloud Sync V2 harness exited during startup."
    }
    Write-Host "Cloud Sync V2 Windows harness started (PID $($process.Id))."
    if ($RunOnce -or $Drain -or $AttachmentProbe -or $AttachmentProbeReuse) {
        $operationTimeoutSeconds = if ($Drain) {
            $DrainTimeoutSeconds
        }
        elseif ($AttachmentProbe -or $AttachmentProbeReuse) {
            $AttachmentProbeTimeoutSeconds
        }
        else {
            $RunOnceTimeoutSeconds
        }
        Wait-HarnessOperation `
            -Process $process `
            -ExpectedExecutable $runner `
            -StatusPath $statusPath `
            -LaunchStartedUtc $launchStartedUtc `
            -BaselineWriteUtc $statusBaselineWriteUtc `
            -ExpectedLaunchId $launchId `
            -ExpectedOperation $(if ($Drain) {
                'drain'
            } elseif ($AttachmentProbe) {
                'attachment-probe'
            } elseif ($AttachmentProbeReuse) {
                'attachment-reuse-probe'
            } else {
                'run-once'
            }) `
            -TimeoutSeconds $operationTimeoutSeconds
    }
}
finally {
    if ($null -eq $previousHarnessMode) {
        Remove-Item Env:OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_HARNESS `
            -ErrorAction SilentlyContinue
    }
    else {
        $env:OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_HARNESS = $previousHarnessMode
    }
    $env:Path = $previousProcessPath
    foreach ($gnuOverride in $gnuOverrides) {
        $previousValue = $previousGnuOverrides[$gnuOverride]
        if ($null -eq $previousValue) {
            Remove-Item "Env:$gnuOverride" -ErrorAction SilentlyContinue
        }
        else {
            Set-Item "Env:$gnuOverride" $previousValue
        }
    }
    foreach ($entry in @(
        @{ Name = "FLUTTER_ROOT"; Value = $previousFlutterRoot },
        @{ Name = "CARGO_HOME"; Value = $previousCargoHome },
        @{ Name = "RUSTUP_HOME"; Value = $previousRustupHome },
        @{
            Name = "CARGOKIT_TARGET_TEMP_DIR_OVERRIDE"
            Value = $previousCargoKitCache
        },
        @{ Name = "LANG"; Value = $previousLang },
        @{ Name = "LC_ALL"; Value = $previousLcAll }
    )) {
        if ($null -eq $entry.Value) {
            Remove-Item "Env:$($entry.Name)" -ErrorAction SilentlyContinue
        }
        else {
            Set-Item "Env:$($entry.Name)" $entry.Value
        }
    }
    Pop-Location
    $repositoryLocationPushed = $false
}
}
finally {
    if ($repositoryLocationPushed) {
        Pop-Location
    }
    if ($launcherLockOwned) {
        try {
            $launcherLock.ReleaseMutex()
        }
        finally {
            $launcherLock.Dispose()
            $launcherLockOwned = $false
        }
    }
}
