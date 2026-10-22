$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../cloud_sync_profile_process_guard.ps1')

$script:Checked = 0
function Assert-OwnerCheck([bool] $Condition, [string] $Name) {
    if (-not $Condition) { throw "Process guard regression: $Name" }
    $script:Checked++
}
function New-StoreFixture {
    return [pscustomobject]@{
        Name = 'OpenBubbles.OpenBubbles'
        PackageFamilyName = 'OpenBubbles.OpenBubbles_qrjz7esdc5g9p'
        Status = 'Ok'
        SignatureKind = 'Store'
        InstallLocation = 'C:\Program Files\WindowsApps\OpenBubbles.OpenBubbles_1.0_x64__qrjz7esdc5g9p'
    }
}
$root = 'C:\Program Files\WindowsApps'
$package = New-StoreFixture
$process = [pscustomobject]@{
    ProcessName = 'bluebubbles_app'
    Path = Join-Path $package.InstallLocation 'bluebubbles_app.exe'
}
Assert-OwnerCheck (Test-CloudSyncUnrelatedStoreProcess $process $package $root) 'exact Store release'
$caseProcess = [pscustomobject]@{ ProcessName = 'bluebubbles_app'; Path = $process.Path.ToUpperInvariant() }
Assert-OwnerCheck (Test-CloudSyncUnrelatedStoreProcess $caseProcess $package $root) 'Windows path casing'
foreach ($name in @('dart', 'flutter', 'native-compose-tests')) {
    $other = [pscustomobject]@{ ProcessName = $name; Path = $process.Path }
    Assert-OwnerCheck (-not (Test-CloudSyncUnrelatedStoreProcess $other $package $root)) $name
}
foreach ($path in @($null, '', 'bluebubbles_app.exe',
    'C:\tests\bluebubbles_app.exe',
    ($package.InstallLocation + '-other\bluebubbles_app.exe'),
    ($package.InstallLocation + '\child\bluebubbles_app.exe'),
    ($package.InstallLocation + '\child\..\bluebubbles_app.exe'))) {
    $other = [pscustomobject]@{ ProcessName = 'bluebubbles_app'; Path = $path }
    Assert-OwnerCheck (-not (Test-CloudSyncUnrelatedStoreProcess $other $package $root)) 'unknown process path'
}
foreach ($field in @('Name', 'PackageFamilyName', 'Status', 'SignatureKind')) {
    $otherPackage = New-StoreFixture
    $otherPackage.$field = 'Unverified'
    Assert-OwnerCheck (-not (Test-CloudSyncUnrelatedStoreProcess $process $otherPackage $root)) $field
}
foreach ($install in @('', 'relative', 'C:\Program Files\WindowsApps-other\fake',
    'C:\scratch\fake', 'C:\Program Files\WindowsApps\..\fake')) {
    $otherPackage = New-StoreFixture
    $otherPackage.InstallLocation = $install
    Assert-OwnerCheck (-not (Test-CloudSyncUnrelatedStoreProcess $process $otherPackage $root)) 'unknown package root'
}
Assert-OwnerCheck (-not (Test-CloudSyncUnrelatedStoreProcess $process $null $root)) 'missing package'
Assert-OwnerCheck (-not (Test-CloudSyncUnrelatedStoreProcess $null $package $root)) 'missing process'

# Exercise the production enumeration wrapper with fixtures. No real app,
# profile, package, relay or credential is opened by these cases.
$script:Processes = @($process)
$script:Packages = @($package)
$script:PackageReadFails = $false
function Get-Process { param($Name, $ErrorAction) return $script:Processes }
function Get-AppxPackage {
    param($Name, $ErrorAction)
    if ($script:PackageReadFails) { throw 'package-read-unavailable' }
    return $script:Packages
}
$expectedRoot = Join-Path $env:ProgramFiles 'WindowsApps'
$package.InstallLocation = Join-Path $expectedRoot 'OpenBubbles.OpenBubbles_1.0_x64__qrjz7esdc5g9p'
$process.Path = Join-Path $package.InstallLocation 'bluebubbles_app.exe'
Assert-OwnerCheck (@(Get-CloudSyncPotentialProfileOwners @('bluebubbles_app')).Count -eq 0) 'verified Store is unrelated'
$unknown = [pscustomobject]@{ ProcessName = 'bluebubbles_app'; Path = 'C:\test\bluebubbles_app.exe' }
$script:Processes = @($process, $unknown)
Assert-OwnerCheck (@(Get-CloudSyncPotentialProfileOwners @('bluebubbles_app')).Count -eq 1) 'unknown app still blocks'
$script:Processes = @($process)
$script:PackageReadFails = $true
Assert-OwnerCheck (@(Get-CloudSyncPotentialProfileOwners @('bluebubbles_app')).Count -eq 1) 'package lookup fails closed'
$script:PackageReadFails = $false
$script:Packages = @($package, $package)
Assert-OwnerCheck (@(Get-CloudSyncPotentialProfileOwners @('bluebubbles_app')).Count -eq 1) 'ambiguous packages block'
$script:Processes = @([pscustomobject]@{ ProcessName = 'dart'; Path = 'C:\tools\dart.exe' })
Assert-OwnerCheck (@(Get-CloudSyncPotentialProfileOwners @('dart')).Count -eq 1) 'Dart ownership unchanged'
Write-Host "PASS $script:Checked process-owner checks; no application was controlled."
