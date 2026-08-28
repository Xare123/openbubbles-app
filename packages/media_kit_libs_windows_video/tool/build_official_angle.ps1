[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("x64", "arm64")]
    [string] $Architecture,

    [Parameter(Mandatory)]
    [string] $WorkRoot,

    [Parameter(Mandatory)]
    [string] $OutputRoot,

    [string] $ProvenancePath = (
        Join-Path $PSScriptRoot "..\provenance\native-dependencies.json"
    ),

    [switch] $Force,

    [switch] $ValidateOnly
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot "NativeMediaVerification.psm1") -Force

function Get-SafeFullPath {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Label
    )

    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $root = [System.IO.Path]::GetPathRoot($full).TrimEnd('\', '/')
    if ([string]::IsNullOrWhiteSpace($full) -or $full -eq $root) {
        throw "$Label cannot be a filesystem root: $full"
    }
    if ($full.Length -lt ($root.Length + 8)) {
        throw "$Label is too broad for build output: $full"
    }
    return $full
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory)]
        [string] $FilePath,

        [Parameter(Mandatory)]
        [string[]] $ArgumentList,

        [Parameter(Mandatory)]
        [string] $WorkingDirectory
    )

    Push-Location $WorkingDirectory
    try {
        & $FilePath @ArgumentList
        if ($LASTEXITCODE -ne 0) {
            throw "Command failed with exit code ${LASTEXITCODE}: $FilePath $($ArgumentList -join ' ')"
        }
    }
    finally {
        Pop-Location
    }
}

function Get-CommandText {
    param(
        [Parameter(Mandatory)]
        [string] $FilePath,

        [string[]] $ArgumentList = @(),

        [string] $WorkingDirectory
    )

    if ($WorkingDirectory) {
        Push-Location $WorkingDirectory
    }
    try {
        $value = & $FilePath @ArgumentList 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to query command output: $FilePath $($ArgumentList -join ' ')"
        }
        return (($value | Out-String).Trim())
    }
    finally {
        if ($WorkingDirectory) {
            Pop-Location
        }
    }
}

function Ensure-PinnedCheckout {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $RemoteUrl,

        [Parameter(Mandatory)]
        [string] $Commit,

        [Parameter(Mandatory)]
        [string] $Git
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        Invoke-Checked -FilePath $Git -ArgumentList @("init") -WorkingDirectory $Path
        Invoke-Checked -FilePath $Git -ArgumentList @(
            "remote", "add", "origin", $RemoteUrl
        ) -WorkingDirectory $Path
    }
    elseif (-not (Test-Path -LiteralPath (Join-Path $Path ".git"))) {
        throw "Existing checkout path is not a Git repository: $Path"
    }

    $actualRemote = (& $Git -C $Path remote get-url origin).Trim()
    if ($LASTEXITCODE -ne 0 -or $actualRemote -ne $RemoteUrl) {
        throw "Checkout origin mismatch at $Path. Got '$actualRemote', expected '$RemoteUrl'."
    }

    Invoke-Checked -FilePath $Git -ArgumentList @(
        "fetch", "--depth", "1", "origin", $Commit
    ) -WorkingDirectory $Path
    Invoke-Checked -FilePath $Git -ArgumentList @(
        "checkout", "--detach", "--force", $Commit
    ) -WorkingDirectory $Path

    $actualCommit = (& $Git -C $Path rev-parse HEAD).Trim()
    if ($actualCommit -ne $Commit) {
        throw "Checkout commit mismatch at $Path. Got $actualCommit, expected $Commit."
    }
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Content
    )

    [System.IO.File]::WriteAllText(
        $Path,
        $Content,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Ensure-DepotToolsGitShim {
    param(
        [Parameter(Mandatory)]
        [string] $DepotToolsPath,

        [Parameter(Mandatory)]
        [string] $GitPath
    )

    # The pinned depot_tools revision invokes `git.bat` from Python, but a
    # fresh pinned checkout does not contain that bootstrap-generated shim.
    # DEPOT_TOOLS_UPDATE stays disabled so the reviewed source pin cannot
    # move; provide the same minimal forwarding shim to the runner's Git.
    $shim = Join-Path $DepotToolsPath "git.bat"
    if (Test-Path -LiteralPath $shim -PathType Leaf) {
        return
    }
    $escapedGitPath = $GitPath.Replace("%", "%%")
    Write-Utf8NoBom `
        -Path $shim `
        -Content ("@echo off`r`n`"$escapedGitPath`" %*`r`n")
}

function Initialize-PinnedDepotTools {
    param(
        [Parameter(Mandatory)]
        [string] $DepotToolsPath
    )

    # A detached depot_tools checkout contains source only.  Its normal
    # update path writes the Python/CIPD bootstrap state, including
    # python3_bin_reldir.txt, before GN can run.  We deliberately keep
    # DEPOT_TOOLS_UPDATE disabled below so the reviewed Git pin cannot move;
    # bootstrap the pinned checkout explicitly instead.
    $marker = Join-Path $DepotToolsPath "python3_bin_reldir.txt"
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
        $bootstrap = Join-Path $DepotToolsPath "bootstrap\win_tools.bat"
        if (-not (Test-Path -LiteralPath $bootstrap -PathType Leaf)) {
            throw "Pinned depot_tools checkout is missing bootstrap/win_tools.bat."
        }
        Push-Location $DepotToolsPath
        try {
            # The batch bootstrap writes progress lines to stdout.  Keep that
            # chatter out of the function's success value, which must remain
            # the single Python path returned below.
            & $bootstrap *> $null
            if ($LASTEXITCODE -ne 0) {
                throw "Pinned depot_tools bootstrap failed with exit code ${LASTEXITCODE}: $bootstrap"
            }
        }
        finally {
            Pop-Location
        }
    }

    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
        throw "Pinned depot_tools bootstrap did not create python3_bin_reldir.txt."
    }
    $relativePythonDirectory = (Get-Content -LiteralPath $marker -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($relativePythonDirectory) -or
        [System.IO.Path]::IsPathRooted($relativePythonDirectory) -or
        $relativePythonDirectory -match '(^|[\\/])\.\.([\\/]|$)') {
        throw "Pinned depot_tools produced an unsafe Python bootstrap path."
    }
    $python3 = Join-Path $DepotToolsPath (
        Join-Path $relativePythonDirectory "python3.exe"
    )
    if (-not (Test-Path -LiteralPath $python3 -PathType Leaf)) {
        throw "Pinned depot_tools bootstrap is missing its declared Python executable: $python3"
    }
    return ([System.IO.Path]::GetFullPath($python3))
}

function Use-TrustedHostPythonForGeneratedNinja {
    param(
        [Parameter(Mandatory)]
        [string] $BuildRoot,

        [Parameter(Mandatory)]
        [string] $BootstrapPython,

        [Parameter(Mandatory)]
        [string] $HostPython
    )

    $probeOutput = & $BootstrapPython -c "import sys; print(sys.executable)" 2>&1
    $probeExitCode = $LASTEXITCODE
    if ($probeExitCode -eq 0) {
        return [pscustomobject]@{
            python_path = [System.IO.Path]::GetFullPath($BootstrapPython)
            fallback = $false
            reason = "depot_tools bootstrap Python executed successfully"
            replaced_ninja_files = 0
        }
    }

    $probeText = ($probeOutput -join [Environment]::NewLine)
    if ($probeText -notmatch 'WinError 4551|Application Control policy') {
        throw "Pinned depot_tools Python failed its execution probe with exit code ${probeExitCode}: $probeText"
    }

    $hostOutput = & $HostPython -c "import sys; print(sys.executable)" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Smart App Control blocked the pinned depot_tools Python, and the installed host Python failed its execution probe: $($hostOutput -join [Environment]::NewLine)"
    }

    $bootstrapForward = ([System.IO.Path]::GetFullPath($BootstrapPython)).Replace('\', '/')
    $bootstrapNinja = $bootstrapForward.Replace(':', '$:')
    $hostForward = ([System.IO.Path]::GetFullPath($HostPython)).Replace('\', '/')
    $hostNinja = $hostForward.Replace(':', '$:')
    $replacedFiles = 0
    foreach ($ninjaFile in Get-ChildItem -LiteralPath $BuildRoot -Filter '*.ninja' -File -Recurse) {
        $content = Get-Content -LiteralPath $ninjaFile.FullName -Raw
        $updated = $content.Replace($bootstrapForward, $hostForward).Replace($bootstrapNinja, $hostNinja)
        if ($updated -ne $content) {
            Write-Utf8NoBom -Path $ninjaFile.FullName -Content $updated
            $replacedFiles++
        }
    }
    if ($replacedFiles -eq 0) {
        throw "Smart App Control blocked the pinned depot_tools Python, but no generated Ninja command referenced it for replacement."
    }

    return [pscustomobject]@{
        python_path = [System.IO.Path]::GetFullPath($HostPython)
        fallback = $true
        reason = "Smart App Control blocked depot_tools bootstrap Python (WinError 4551); generated Ninja commands use installed host Python"
        replaced_ninja_files = $replacedFiles
    }
}

function Resolve-CompleteWindowsSdk {
    param(
        [Parameter(Mandatory)]
        [string] $VisualStudioVcvarsAll
    )

    $roots = @(
        [Environment]::GetEnvironmentVariable("WindowsSdkDir"),
        (Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10"),
        (Join-Path $env:ProgramFiles "Windows Kits\10")
    ) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.TrimEnd('\', '/') } |
        Select-Object -Unique

    $candidates = @(
        foreach ($root in $roots) {
            $includeRoot = Join-Path $root "Include"
            $libRoot = Join-Path $root "Lib"
            if (-not (Test-Path -LiteralPath $includeRoot -PathType Container) -or
                -not (Test-Path -LiteralPath $libRoot -PathType Container)) {
                continue
            }

            foreach ($includeVersion in @(
                Get-ChildItem -LiteralPath $includeRoot -Directory -ErrorAction SilentlyContinue
            )) {
                if ($includeVersion.Name -notmatch '^10\.0\.\d+\.0$') {
                    continue
                }
                $includeUm = Join-Path $includeVersion.FullName "um"
                $libUm = Join-Path (Join-Path $libRoot $includeVersion.Name) "um"
                if ((Test-Path -LiteralPath $includeUm -PathType Container) -and
                    (Test-Path -LiteralPath $libUm -PathType Container)) {
                    [pscustomobject]@{
                        version = [version] $includeVersion.Name
                        version_text = $includeVersion.Name
                        root = $root
                        include_um = $includeUm
                        lib_um = $libUm
                    }
                }
            }
        }
    )

    $compatible = @(
        $candidates | Where-Object {
            $probe = "call `"$VisualStudioVcvarsAll`" amd64_x86 $($_.version_text) >nul 2>&1"
            & cmd.exe /d /c $probe
            $LASTEXITCODE -eq 0
        }
    )
    $selected = $compatible |
        Sort-Object -Property version, root -Descending |
        Select-Object -First 1
    if (-not $selected) {
        throw "No complete Windows SDK accepted by Visual Studio was found. Each candidate must contain usable Include\\<version>\\um and Lib\\<version>\\um files."
    }
    return $selected
}

function Resolve-VisualStudioInstallation {
    $vswhere = $null
    try {
        $vswhere = (Get-Command vswhere.exe -ErrorAction Stop).Source
    }
    catch {
        $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    }

    $candidatePaths = @()
    if (Test-Path -LiteralPath $vswhere -PathType Leaf) {
        $candidatePaths += @(
            & $vswhere -latest -products * -property installationPath 2>$null |
                ForEach-Object { ([string] $_).Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
    }
    $candidatePaths += @(
        (Join-Path ${env:ProgramFiles} "Microsoft Visual Studio"),
        (Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio")
    ) |
        Where-Object { Test-Path -LiteralPath $_ -PathType Container } |
        ForEach-Object {
            Get-ChildItem -LiteralPath $_ -Directory -ErrorAction SilentlyContinue |
                ForEach-Object {
                    Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue |
                        ForEach-Object { $_.FullName }
                }
        }

    foreach ($candidate in ($candidatePaths | Select-Object -Unique)) {
        $vcvarsall = Join-Path $candidate "VC\Auxiliary\Build\vcvarsall.bat"
        if (Test-Path -LiteralPath $vcvarsall -PathType Leaf) {
            return [pscustomobject]@{
                root = ([System.IO.Path]::GetFullPath($candidate)).TrimEnd('\', '/')
                vcvarsall = $vcvarsall
            }
        }
    }
    throw "No Visual Studio installation with VC\\Auxiliary\\Build\\vcvarsall.bat was found."
}

function Resolve-MsvcAtlInclude {
    param(
        [Parameter(Mandatory)]
        [string] $VisualStudioRoot
    )

    $toolsetRoot = Join-Path $VisualStudioRoot "VC\Tools\MSVC"
    if (-not (Test-Path -LiteralPath $toolsetRoot -PathType Container)) {
        throw "Resolved Visual Studio installation is missing MSVC toolsets: $toolsetRoot"
    }
    $candidates = @(
        Get-ChildItem -LiteralPath $toolsetRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName "atlmfc\include" }
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate "atlbase.h") -PathType Leaf) {
            return ([System.IO.Path]::GetFullPath($candidate)).TrimEnd('\', '/')
        }
    }
    throw "MSVC ATL headers were not found below $toolsetRoot. Expected atlmfc\\include\\atlbase.h."
}

function Initialize-SdkCompatibilityEnvironment {
    param(
        [Parameter(Mandatory)]
        [string] $SdkVersion,

        [Parameter(Mandatory)]
        [string] $VisualStudioRoot,

        [Parameter(Mandatory)]
        [string] $AtlInclude
    )

    if (-not (Test-Path -LiteralPath (Join-Path $VisualStudioRoot "VC\Auxiliary\Build\vcvarsall.bat") -PathType Leaf)) {
        throw "Resolved Visual Studio root is missing vcvarsall.bat: $VisualStudioRoot"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $AtlInclude "atlbase.h") -PathType Leaf)) {
        throw "Resolved MSVC ATL include directory is missing atlbase.h: $AtlInclude"
    }
    # Use the real installation root. A wrapper directory breaks ANGLE's
    # runtime-DLL discovery because it also resolves VC\Redist from this path.
    # The pinned checkout's SDK constants were adapted immediately above, so
    # vcvarsall can be called directly with the selected, validated SDK.
    $env:GYP_MSVS_OVERRIDE_PATH = $VisualStudioRoot
    # Chromium's Windows config supplies the normal MSVC and Windows SDK
    # include roots, but ATL lives in the optional atlmfc tree and is not
    # emitted by that config. Pass the validated directory explicitly so both
    # the ARM64 target and the x64 host tools use the same installed headers.
    $env:OPENBUBBLES_ATL_INCLUDE = $AtlInclude
    $existingInclude = [Environment]::GetEnvironmentVariable("INCLUDE")
    if ([string]::IsNullOrWhiteSpace($existingInclude)) {
        $env:INCLUDE = $AtlInclude
    }
    elseif ($existingInclude -notlike "*$AtlInclude*") {
        $env:INCLUDE = "$AtlInclude;$existingInclude"
    }
    return [pscustomobject]@{
        sdk_version = $SdkVersion
        visual_studio_root = $VisualStudioRoot
        atl_include = $AtlInclude
    }
}

function Apply-SdkCompatibilityPatch {
    param(
        [Parameter(Mandatory)]
        [string] $AngleSource,

        [Parameter(Mandatory)]
        [string] $SdkVersion,

        [Parameter(Mandatory)]
        [bool] $SkipArm64HostDebugger
    )

    # The reviewed ANGLE pin currently names a newer SDK than is installed on
    # Windows 11 ARM64 and on the hosted Windows runners. Keep the official
    # source commit intact, but adapt only its two build-tool version constants
    # in the disposable checkout to the SDK that vcvarsall accepted above.
    # Refuse unexpected source text so this cannot silently patch a new layout.
    $files = @(
        [pscustomobject]@{
            relative_path = "build\vs_toolchain.py"
            expected = "SDK_VERSION = '10.0.28000.0'"
            replacement = "SDK_VERSION = '$SdkVersion'"
        },
        [pscustomobject]@{
            relative_path = "build\toolchain\win\setup_toolchain.py"
            expected = "SDK_VERSION = '10.0.28000.0'"
            replacement = "SDK_VERSION = '$SdkVersion'"
        }
    )

    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($file in $files) {
        $path = Join-Path $AngleSource $file.relative_path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Pinned ANGLE checkout is missing required SDK compatibility file: $($file.relative_path)"
        }
        $content = Get-Content -LiteralPath $path -Raw
        $matches = [regex]::Matches($content, [regex]::Escape($file.expected))
        if ($matches.Count -ne 1) {
            throw "Expected exactly one reviewed SDK constant in $($file.relative_path), found $($matches.Count)."
        }
        Write-Utf8NoBom `
            -Path $path `
            -Content $content.Replace($file.expected, $file.replacement)
        $records.Add([pscustomobject]@{
            relative_path = $file.relative_path.Replace('\', '/')
            operation = "replace SDK_VERSION constant"
            requested_sdk_version = '10.0.28000.0'
            selected_sdk_version = $SdkVersion
        })
    }

    if ($SkipArm64HostDebugger) {
        $path = Join-Path $AngleSource "build\vs_toolchain.py"
        $content = Get-Content -LiteralPath $path -Raw
        $callPattern = "(?m)^[ ]+_CopyDebugger\(target_dir, target_cpu\)"
        $callMatches = [regex]::Matches($content, $callPattern)
        if ($callMatches.Count -ne 2) {
            throw "Expected exactly two ANGLE debugger-copy calls, found $($callMatches.Count)."
        }
        $lastCall = $callMatches[$callMatches.Count - 1]
        $guardedCall = @"
    if os.environ.get('OPENBUBBLES_ARM64_NATIVE_BUILD') != '1':
      _CopyDebugger(target_dir, target_cpu)
"@
        $updated = $content.Substring(0, $lastCall.Index) +
            $guardedCall.TrimEnd("`r", "`n") +
            $content.Substring($lastCall.Index + $lastCall.Length)
        Write-Utf8NoBom -Path $path -Content $updated
        $records.Add([pscustomobject]@{
            relative_path = "build/vs_toolchain.py"
            operation = "guard x64 host debugger copy for ARM64 build"
            requested_sdk_version = '10.0.28000.0'
            selected_sdk_version = $SdkVersion
        })
    }

    if ($SdkVersion -eq '10.0.26100.0') {
        $path = Join-Path $AngleSource "build\config\win\BUILD.gn"
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Pinned ANGLE checkout is missing Windows target-version configuration."
        }
        $content = Get-Content -LiteralPath $path -Raw
        $expected = '"NTDDI_VERSION=NTDDI_WIN11_BR",'
        $replacement = '"NTDDI_VERSION=NTDDI_WIN11_GA",'
        $matches = [regex]::Matches($content, [regex]::Escape($expected))
        if ($matches.Count -ne 1) {
            throw "Expected exactly one ANGLE Windows target-version constant, found $($matches.Count)."
        }
        Write-Utf8NoBom -Path $path -Content $content.Replace($expected, $replacement)
        $records.Add([pscustomobject]@{
            relative_path = "build/config/win/BUILD.gn"
            operation = "map Windows 11 Beta target macro to SDK 26100 GA macro"
            requested_sdk_version = '10.0.28000.0'
            selected_sdk_version = $SdkVersion
        })
    }

    $path = Join-Path $AngleSource "build\config\win\BUILD.gn"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Pinned ANGLE checkout is missing Windows compiler configuration."
    }
    $content = Get-Content -LiteralPath $path -Raw
    $expected = 'config\("compiler"\)\s*\{'
    $replacement = @"
config("compiler") {
  # ANGLE's Chromium toolchain does not add the optional MSVC ATL include
  # tree. The build wrapper validates and supplies this path at generation.
  if (getenv("OPENBUBBLES_ATL_INCLUDE") != "") {
    include_dirs = [ getenv("OPENBUBBLES_ATL_INCLUDE") ]
  }
"@
    $matches = [regex]::Matches($content, $expected)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one ANGLE clang compiler configuration block, found $($matches.Count)."
    }
    $updated = $content.Substring(0, $matches[0].Index) +
        $replacement.TrimEnd("`r", "`n") +
        $content.Substring($matches[0].Index + $matches[0].Length)
    Write-Utf8NoBom -Path $path -Content $updated
    $records.Add([pscustomobject]@{
        relative_path = "build/config/win/BUILD.gn"
        operation = "add validated MSVC ATL include directory"
        requested_sdk_version = '10.0.28000.0'
        selected_sdk_version = $SdkVersion
    })

    return @($records)
}

$work = Get-SafeFullPath -Path $WorkRoot -Label "WorkRoot"
$output = Get-SafeFullPath -Path $OutputRoot -Label "OutputRoot"
$provenanceFile = (Resolve-Path -LiteralPath $ProvenancePath -ErrorAction Stop).Path
$provenance = Get-Content -LiteralPath $provenanceFile -Raw |
    ConvertFrom-Json -ErrorAction Stop

if ($provenance.schema_version -ne 1) {
    throw "Unsupported native dependency provenance schema."
}
if ($provenance.angle.source_url -ne
    "https://chromium.googlesource.com/angle/angle.git") {
    throw "Refusing non-official ANGLE source URL."
}
if ($provenance.angle.depot_tools_url -ne
    "https://chromium.googlesource.com/chromium/tools/depot_tools.git") {
    throw "Refusing non-official depot_tools source URL."
}
foreach ($pin in @(
    [string] $provenance.angle.source_commit,
    [string] $provenance.angle.depot_tools_commit
)) {
    if ($pin -notmatch '^[0-9a-f]{40}$') {
        throw "Official source pins must be full lowercase Git commit hashes."
    }
}

$visualStudio = Resolve-VisualStudioInstallation
$atlInclude = Resolve-MsvcAtlInclude -VisualStudioRoot $visualStudio.root
$selectedSdk = Resolve-CompleteWindowsSdk -VisualStudioVcvarsAll $visualStudio.vcvarsall

# Chromium's pinned vs_toolchain.py prefers the conventional Program Files
# location when it detects VS 2022. Windows-on-ARM may install the complete
# Build Tools workload under Program Files (x86), even when the host process
# is ARM64. Pass the already-validated installation path explicitly so GN and
# the subsequent compiler invocations use the same VS instance that accepted
# the selected SDK.
$env:vs2022_install = $visualStudio.root

$requiredRuntimeFiles = @($provenance.angle.runtime_files.$Architecture)
$expectedMachine = if ($Architecture -eq "arm64") { "ARM64" } else { "X64" }

if (Test-Path -LiteralPath $output -PathType Container) {
    $existingManifest = Join-Path $output "native-manifest.json"
    if (-not $Force) {
        $result = Test-NativeMediaBundle `
            -BundleRoot $output `
            -ManifestPath $existingManifest `
            -Architecture $Architecture `
            -ExpectedAngleSourceUrl $provenance.angle.source_url `
            -ExpectedAngleCommit $provenance.angle.source_commit `
            -ExpectedDepotToolsUrl $provenance.angle.depot_tools_url `
            -ExpectedDepotToolsCommit $provenance.angle.depot_tools_commit `
            -RequiredRuntimeFiles $requiredRuntimeFiles
        $result | ConvertTo-Json -Depth 7
        exit 0
    }
}

$plan = [pscustomobject]@{
    architecture = $Architecture
    work_root = $work
    output_root = $output
    angle_source = $provenance.angle.source_url
    angle_commit = $provenance.angle.source_commit
    depot_tools_source = $provenance.angle.depot_tools_url
    depot_tools_commit = $provenance.angle.depot_tools_commit
    windows_sdk_version = $selectedSdk.version_text
    windows_sdk_root = $selectedSdk.root
    atl_include = $atlInclude
    required_runtime_files = $requiredRuntimeFiles
}

if ($ValidateOnly) {
    $plan | ConvertTo-Json -Depth 6
    exit 0
}

New-Item -ItemType Directory -Path $work -Force | Out-Null

$git = (Get-Command git -ErrorAction Stop).Source
$python = (Get-Command python -ErrorAction Stop).Source
$depotTools = Join-Path $work "depot_tools"
$angleSource = Join-Path $work "angle"

Ensure-PinnedCheckout `
    -Path $depotTools `
    -RemoteUrl $provenance.angle.depot_tools_url `
    -Commit $provenance.angle.depot_tools_commit `
    -Git $git

$depotToolsPython = Initialize-PinnedDepotTools -DepotToolsPath $depotTools

Ensure-DepotToolsGitShim -DepotToolsPath $depotTools -GitPath $git

$env:PATH = "$depotTools;$env:PATH"
$env:DEPOT_TOOLS_WIN_TOOLCHAIN = "0"
$env:DEPOT_TOOLS_UPDATE = "0"

Ensure-PinnedCheckout `
    -Path $angleSource `
    -RemoteUrl $provenance.angle.source_url `
    -Commit $provenance.angle.source_commit `
    -Git $git

Invoke-Checked `
    -FilePath $python `
    -ArgumentList @("scripts/bootstrap.py") `
    -WorkingDirectory $angleSource
Invoke-Checked `
    -FilePath (Join-Path $depotTools "gclient.bat") `
    -ArgumentList @("sync", "--force", "--reset", "--no-history") `
    -WorkingDirectory $angleSource

$actualAngleCommit = (& $git -C $angleSource rev-parse HEAD).Trim()
if ($actualAngleCommit -ne $provenance.angle.source_commit) {
    throw "gclient changed the pinned ANGLE checkout to $actualAngleCommit."
}
$actualDepotToolsCommit = (& $git -C $depotTools rev-parse HEAD).Trim()
if ($actualDepotToolsCommit -ne $provenance.angle.depot_tools_commit) {
    throw "depot_tools moved away from its reviewed pin to $actualDepotToolsCommit."
}

$toolchainEnvironment = Initialize-SdkCompatibilityEnvironment `
    -SdkVersion $selectedSdk.version_text `
    -VisualStudioRoot $visualStudio.root `
    -AtlInclude $atlInclude
$sdkCompatibilityFiles = Apply-SdkCompatibilityPatch `
    -AngleSource $angleSource `
    -SdkVersion $selectedSdk.version_text `
    -SkipArm64HostDebugger ($Architecture -eq "arm64")
$env:OPENBUBBLES_ARM64_NATIVE_BUILD = if ($Architecture -eq "arm64") { "1" } else { "0" }

$gn = (Get-Command gn -ErrorAction Stop).Source
$autoninja = (Get-Command autoninja -ErrorAction Stop).Source
$ninja = Join-Path $angleSource "third_party\ninja\ninja.exe"
if (-not (Test-Path -LiteralPath $ninja -PathType Leaf)) {
    throw "Pinned ANGLE checkout is missing its Ninja executable: $ninja"
}
$targetCpu = if ($Architecture -eq "arm64") { "arm64" } else { "x64" }
# gn.bat forwards through cmd.exe, which removes unescaped embedded quotes from
# the --args value. Preserve GN's string literal for target_cpu at that boundary.
$gnArgs = @($provenance.angle.gn_args_common) + @("target_cpu=\`"$targetCpu\`"")
$gnArgsText = $gnArgs -join " "
$buildRoot = Join-Path $angleSource "out\openbubbles-$Architecture-release"

Invoke-Checked `
    -FilePath $gn `
    -ArgumentList @("gen", $buildRoot, "--args=$gnArgsText") `
    -WorkingDirectory $angleSource
$pythonExecution = Use-TrustedHostPythonForGeneratedNinja `
    -BuildRoot $buildRoot `
    -BootstrapPython $depotToolsPython `
    -HostPython $python
Invoke-Checked `
    -FilePath $autoninja `
    -ArgumentList @("-C", $buildRoot, "libEGL", "libGLESv2") `
    -WorkingDirectory $angleSource

$stage = "$output.stage-$([guid]::NewGuid().ToString('N'))"
$bin = Join-Path $stage "bin"
$include = Join-Path $stage "include"
$lib = Join-Path $stage "lib"
$licenses = Join-Path $stage "licenses"
$sourceLicenses = Join-Path $licenses "source-tree"
$evidence = Join-Path $stage "provenance"
New-Item -ItemType Directory -Path $bin -Force | Out-Null
New-Item -ItemType Directory -Path $lib -Force | Out-Null
New-Item -ItemType Directory -Path $sourceLicenses -Force | Out-Null
New-Item -ItemType Directory -Path $evidence -Force | Out-Null

foreach ($relative in $requiredRuntimeFiles) {
    $name = Split-Path $relative -Leaf
    $source = Join-Path $buildRoot $name
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Official ANGLE build did not produce required runtime: $source"
    }
    Copy-Item -LiteralPath $source -Destination (Join-Path $bin $name)
}

$angleInclude = Join-Path $angleSource "include"
if (-not (Test-Path -LiteralPath $angleInclude -PathType Container)) {
    throw "Pinned ANGLE checkout is missing its public include tree: $angleInclude"
}
Copy-Item -LiteralPath $angleInclude -Destination $stage -Recurse

foreach ($importLibraryName in @("libEGL.dll.lib", "libGLESv2.dll.lib")) {
    $importLibrary = Join-Path $buildRoot $importLibraryName
    if (-not (Test-Path -LiteralPath $importLibrary -PathType Leaf)) {
        throw "Official ANGLE build did not produce required import library: $importLibrary"
    }
    Copy-Item -LiteralPath $importLibrary -Destination (
        Join-Path $lib $importLibraryName
    )
}

$angleLicense = Join-Path $angleSource "LICENSE"
if (-not (Test-Path -LiteralPath $angleLicense -PathType Leaf)) {
    throw "Pinned ANGLE checkout is missing its top-level LICENSE."
}
Copy-Item -LiteralPath $angleLicense -Destination (
    Join-Path $licenses "ANGLE-LICENSE.txt"
)

$licenseNames = @(
    "LICENSE",
    "COPYING",
    "NOTICE",
    "README.chromium"
)
$licenseFiles = @(
    Get-ChildItem -LiteralPath (Join-Path $angleSource "third_party") -File -Recurse |
        Where-Object {
            $base = $_.BaseName
            $_.Name -eq "README.chromium" -or
            $licenseNames -contains $base -or
            $_.Name -like "LICENSE.*" -or
            $_.Name -like "COPYING.*" -or
            $_.Name -like "NOTICE.*"
        } |
        Sort-Object FullName
)
if ($licenseFiles.Count -eq 0) {
    throw "No third-party license evidence was found in the pinned ANGLE checkout."
}

$sourcePrefixLength = $angleSource.TrimEnd('\', '/').Length + 1
$licenseInventory = [System.Collections.Generic.List[object]]::new()
foreach ($item in $licenseFiles) {
    if ($item.FullName.StartsWith(
        $buildRoot,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        continue
    }
    $sourceRelative = $item.FullName.Substring($sourcePrefixLength).Replace('\', '/')
    $bundleRelative = "source-tree/$sourceRelative"
    $destination = Join-Path $licenses $bundleRelative
    New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force |
        Out-Null
    Copy-Item -LiteralPath $item.FullName -Destination $destination
    $licenseInventory.Add([pscustomobject]@{
        source_relative_path = $sourceRelative
        bundle_relative_path = "licenses/$bundleRelative"
        sha256 = Get-Sha256Hex -Path $destination
    })
}

$licenseInventoryPath = Join-Path $licenses "license-inventory.json"
Write-Utf8NoBom `
    -Path $licenseInventoryPath `
    -Content (@($licenseInventory) | ConvertTo-Json -Depth 6)

$gclient = Join-Path $depotTools "gclient.bat"
$gclientRevisionsPath = Join-Path $evidence "gclient-revisions.txt"
$gclientRevisions = Get-CommandText `
    -FilePath $gclient `
    -ArgumentList @("revinfo", "-a") `
    -WorkingDirectory $angleSource
Write-Utf8NoBom `
    -Path $gclientRevisionsPath `
    -Content ($gclientRevisions + [Environment]::NewLine)

$gnArgsPath = Join-Path $evidence "gn-args.txt"
Write-Utf8NoBom `
    -Path $gnArgsPath `
    -Content (($gnArgs -join [Environment]::NewLine) + [Environment]::NewLine)

$sdkCompatibilityPath = Join-Path $evidence "sdk-compatibility.txt"
$sdkCompatibilityLines = @(
    "official_angle_commit=$($provenance.angle.source_commit)",
    "requested_sdk_version=10.0.28000.0",
    "selected_sdk_version=$($selectedSdk.version_text)"
) + @(
    $sdkCompatibilityFiles | ForEach-Object {
        "patched_file=$($_.relative_path) operation=$($_.operation)"
    }
)
Write-Utf8NoBom `
    -Path $sdkCompatibilityPath `
    -Content (($sdkCompatibilityLines -join [Environment]::NewLine) + [Environment]::NewLine)

$runtimeEntries = [System.Collections.Generic.List[object]]::new()
foreach ($relative in $requiredRuntimeFiles) {
    $file = Join-Path $stage $relative
    $machine = Get-PEMachine -Path $file
    if ($machine -ne $expectedMachine) {
        throw "Official ANGLE output has PE machine $machine, expected $expectedMachine`: $file"
    }
    $runtimeEntries.Add([pscustomobject]@{
        relative_path = $relative
        sha256 = Get-Sha256Hex -Path $file
        pe_machine = $machine
        origin = "official ANGLE source build"
    })
}

$compileEntries = [System.Collections.Generic.List[object]]::new()
$stagePrefixLength = $stage.TrimEnd('\', '/').Length + 1
foreach ($compileFile in @(
    Get-ChildItem -LiteralPath $include, $lib -File -Recurse |
        Sort-Object FullName
)) {
    $compileEntries.Add([pscustomobject]@{
        relative_path = $compileFile.FullName.Substring(
            $stagePrefixLength
        ).Replace('\', '/')
        sha256 = Get-Sha256Hex -Path $compileFile.FullName
        origin = "official ANGLE source build"
    })
}

$manifest = [ordered]@{
    schema_version = 1
    architecture = $Architecture
    source = [ordered]@{
        angle_url = $provenance.angle.source_url
        angle_commit = $provenance.angle.source_commit
        depot_tools_url = $provenance.angle.depot_tools_url
        depot_tools_commit = $provenance.angle.depot_tools_commit
    }
    build = [ordered]@{
        built_at_utc = [DateTime]::UtcNow.ToString("o")
        gn_args = $gnArgs
        git_version = Get-CommandText -FilePath $git -ArgumentList @("--version")
        python_version = Get-CommandText -FilePath $python -ArgumentList @("--version")
        gn_version = Get-CommandText -FilePath $gn -ArgumentList @("--version") -WorkingDirectory $angleSource
        ninja_version = Get-CommandText -FilePath $ninja -ArgumentList @("--version") -WorkingDirectory $angleSource
        os_version = [System.Environment]::OSVersion.VersionString
        process_architecture = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
        sdk_compatibility = $sdkCompatibilityFiles
    }
    files = @($runtimeEntries)
    compile_files = @($compileEntries)
    angle_license_sha256 = Get-Sha256Hex -Path (
        Join-Path $licenses "ANGLE-LICENSE.txt"
    )
    license_inventory_sha256 = Get-Sha256Hex -Path $licenseInventoryPath
    evidence = [ordered]@{
        gclient_revisions_path = "provenance/gclient-revisions.txt"
        gclient_revisions_sha256 = Get-Sha256Hex -Path $gclientRevisionsPath
        gn_args_path = "provenance/gn-args.txt"
        gn_args_sha256 = Get-Sha256Hex -Path $gnArgsPath
        sdk_compatibility_path = "provenance/sdk-compatibility.txt"
        sdk_compatibility_sha256 = Get-Sha256Hex -Path $sdkCompatibilityPath
    }
}

$manifestPath = Join-Path $stage "native-manifest.json"
Write-Utf8NoBom `
    -Path $manifestPath `
    -Content ($manifest | ConvertTo-Json -Depth 10)

Test-NativeMediaBundle `
    -BundleRoot $stage `
    -ManifestPath $manifestPath `
    -Architecture $Architecture `
    -ExpectedAngleSourceUrl $provenance.angle.source_url `
    -ExpectedAngleCommit $provenance.angle.source_commit `
    -ExpectedDepotToolsUrl $provenance.angle.depot_tools_url `
    -ExpectedDepotToolsCommit $provenance.angle.depot_tools_commit `
    -RequiredRuntimeFiles $requiredRuntimeFiles |
    Out-Null

if (Test-Path -LiteralPath $output) {
    $backup = "$output.previous-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"
    if (Test-Path -LiteralPath $backup) {
        throw "Refusing to overwrite existing native bundle backup: $backup"
    }
    Move-Item -LiteralPath $output -Destination $backup
}
Move-Item -LiteralPath $stage -Destination $output

$result = Test-NativeMediaBundle `
    -BundleRoot $output `
    -ManifestPath (Join-Path $output "native-manifest.json") `
    -Architecture $Architecture `
    -ExpectedAngleSourceUrl $provenance.angle.source_url `
    -ExpectedAngleCommit $provenance.angle.source_commit `
    -ExpectedDepotToolsUrl $provenance.angle.depot_tools_url `
    -ExpectedDepotToolsCommit $provenance.angle.depot_tools_commit `
    -RequiredRuntimeFiles $requiredRuntimeFiles

$result | ConvertTo-Json -Depth 7
