[CmdletBinding()]
param(
    [switch] $Refresh,
    [string] $SourceProfileRoot,
    [switch] $SharedSourceProfile
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$running = @(Get-Process -Name "bluebubbles_app" -ErrorAction SilentlyContinue)
if ($running.Count -ne 0) {
    throw "Close every OpenBubbles window before bootstrapping the private profile."
}
if ($SourceProfileRoot -and $SharedSourceProfile) {
    throw "SourceProfileRoot and SharedSourceProfile are mutually exclusive."
}

$sharedRoot = Join-Path $env:APPDATA "OpenBubbles\openbubbles"
$targetParent = Join-Path $env:APPDATA "OpenBubbles"
$target = Join-Path $targetParent "cloudkit-v2-dev"
$markerName = ".openbubbles-cloud-sync-v2-windows-dev"
$markerContents = "openbubbles-cloud-sync-v2-windows-dev-profile:v1"
$marker = Join-Path $target $markerName
$refreshed = $false
$package = $null
$storeRoot = $null
if (-not $SharedSourceProfile) {
    $package = Get-AppxPackage `
        -Name "OpenBubbles.OpenBubbles" `
        -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if ($null -ne $package) {
        $storeRoot = Join-Path $env:LOCALAPPDATA (
            "Packages\{0}\LocalCache\Roaming\OpenBubbles\openbubbles" -f
            $package.PackageFamilyName
        )
    }
}
$packageVersion = if ($null -eq $package) {
    $null
}
else {
    [string]$package.Version
}

$required = @(
    "hw_info.plist",
    "anisette_test",
    "gsa.plist",
    "cloudkit.plist",
    "keychain.plist",
    "keystore.plist"
)
function Assert-ApprovedSourceRoot {
    param([Parameter(Mandatory)][string]$Root)

    $resolved = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $approvedRoamingParent = [System.IO.Path]::GetFullPath($targetParent).TrimEnd('\')
    $approvedStoreRoot = if ([string]::IsNullOrWhiteSpace($storeRoot)) {
        $null
    }
    else {
        [System.IO.Path]::GetFullPath($storeRoot).TrimEnd('\')
    }
    $insideRoaming = $resolved.StartsWith(
        "$approvedRoamingParent\",
        [System.StringComparison]::OrdinalIgnoreCase
    )
    $isStoreRoot = $null -ne $approvedStoreRoot -and
        $resolved.Equals(
            $approvedStoreRoot,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    if (-not $insideRoaming -and -not $isStoreRoot) {
        throw "Source profile is outside the approved OpenBubbles roots: $resolved"
    }
    if ($resolved.Equals(
        [System.IO.Path]::GetFullPath($target).TrimEnd('\'),
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "The disposable target cannot be its own bootstrap source."
    }
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
        throw "Source profile does not exist: $resolved"
    }
    $sourceItem = Get-Item -LiteralPath $resolved -Force
    if ($sourceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "Reparse-point source profiles are not accepted: $resolved"
    }
    return $resolved
}

$candidateRoots = [System.Collections.Generic.List[string]]::new()
$candidateDiagnostics = [System.Collections.Generic.List[string]]::new()

function Add-DefaultSourceCandidate {
    param(
        [AllowNull()][string] $Root,
        [Parameter(Mandatory)][string] $Label
    )

    if ([string]::IsNullOrWhiteSpace($Root)) {
        [void]$candidateDiagnostics.Add("${Label}: unavailable")
        return
    }
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        [void]$candidateDiagnostics.Add("${Label}: not found")
        return
    }
    try {
        [void]$candidateRoots.Add((Assert-ApprovedSourceRoot -Root $Root))
    }
    catch {
        [void]$candidateDiagnostics.Add("${Label}: rejected")
    }
}

if ($SourceProfileRoot) {
    [void]$candidateRoots.Add(
        (Assert-ApprovedSourceRoot -Root $SourceProfileRoot)
    )
}
elseif ($SharedSourceProfile) {
    [void]$candidateRoots.Add((Assert-ApprovedSourceRoot -Root $sharedRoot))
}
else {
    Add-DefaultSourceCandidate -Root $storeRoot -Label "Store profile"
    Add-DefaultSourceCandidate -Root $sharedRoot -Label "Shared profile"
}

$sourceRoot = $null
foreach ($candidateRoot in $candidateRoots) {
    $missing = @($required | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $candidateRoot $_))
    })
    if ($missing.Count -eq 0) {
        $sourceRoot = $candidateRoot
        break
    }
    [void]$candidateDiagnostics.Add(
        "Candidate profile is missing: $($missing -join ', ')"
    )
}
if (-not $sourceRoot) {
    $summary = if ($candidateDiagnostics.Count -eq 0) {
        "No approved candidate profile was found."
    }
    else {
        $candidateDiagnostics -join '; '
    }
    throw "No single coherent authenticated profile is complete. $summary"
}

$sources = @{}
foreach ($name in $required) {
    $sources[$name] = Join-Path $sourceRoot $name
}
if (Test-Path -LiteralPath $target) {
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf) -or
        (Get-Content -LiteralPath $marker -Raw) -ne $markerContents) {
        throw "The private profile path exists without a valid commit marker: $target"
    }
    if (-not $Refresh) {
        [pscustomobject]@{
            result = "already_bootstrapped"
            target = $target
            source_root = $sourceRoot
            package_version = $packageVersion
        } | ConvertTo-Json
        exit 0
    }
}

New-Item -ItemType Directory -Path $targetParent -Force | Out-Null
$stage = Join-Path $targetParent (
    ".cloudkit-v2-dev-bootstrap-{0}" -f [guid]::NewGuid().ToString("N")
)
try {
    New-Item -ItemType Directory -Path $stage | Out-Null
    foreach ($name in ($sources.Keys | Sort-Object)) {
        $source = Get-Item -LiteralPath $sources[$name] -Force
        if ($source.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "Reparse points are not accepted in authenticated state: $name"
        }
        Copy-Item -LiteralPath $source.FullName -Destination (Join-Path $stage $name) -Recurse
    }

    $acl = [System.Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    foreach ($sid in @(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().User,
        [System.Security.Principal.SecurityIdentifier]::new("S-1-5-18"),
        [System.Security.Principal.SecurityIdentifier]::new("S-1-5-32-544")
    )) {
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $sid,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            $propagation,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        [void]$acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $stage -AclObject $acl
    Set-Content -LiteralPath (Join-Path $stage $markerName) -Value $markerContents -NoNewline

    if (Test-Path -LiteralPath $target) {
        $resolvedParent = [System.IO.Path]::GetFullPath($targetParent).TrimEnd('\')
        $resolvedTarget = [System.IO.Path]::GetFullPath($target).TrimEnd('\')
        if ([System.IO.Path]::GetDirectoryName($resolvedTarget) -ne $resolvedParent -or
            [System.IO.Path]::GetFileName($resolvedTarget) -ne "cloudkit-v2-dev") {
            throw "Refusing to refresh an unexpected private profile path: $resolvedTarget"
        }

        $retired = Join-Path $targetParent (
            ".cloudkit-v2-dev-retired-{0}" -f [guid]::NewGuid().ToString("N")
        )
        Move-Item -LiteralPath $resolvedTarget -Destination $retired
        try {
            Move-Item -LiteralPath $stage -Destination $target
            Remove-Item -LiteralPath $retired -Recurse -Force
            $refreshed = $true
        }
        catch {
            if (-not (Test-Path -LiteralPath $target) -and
                (Test-Path -LiteralPath $retired)) {
                Move-Item -LiteralPath $retired -Destination $target
            }
            throw
        }
    }
    else {
        Move-Item -LiteralPath $stage -Destination $target
    }
}
catch {
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
    throw
}

[pscustomobject]@{
    result = if ($refreshed) { "refreshed" } else { "bootstrapped" }
    target = $target
    source_root = $sourceRoot
    package_version = $packageVersion
    copied_items = @($sources.Keys | Sort-Object)
    copied_private_keystore = $true
    windows_protected_keystore_migration_required = $true
    copied_objectbox = $false
    copied_messages = $false
    copied_attachments = $false
} | ConvertTo-Json -Depth 4
