# A verified Store release uses the ordinary application-support directory,
# not the fixed cloudkit-v2-dev profile selected only by the engineering entry
# points. Do not require the user to close that unrelated app. Every unknown
# executable and every engineering Dart/Flutter/native host remains blocking.
# This is process classification only: no process is stopped and the existing
# profile mutex, file locks, source checks and relay rules remain unchanged.

function Test-CloudSyncUnrelatedStoreProcess {
    param($Process, $Package, [string] $WindowsAppsRoot)
    try {
        if ($Process.ProcessName -cne 'bluebubbles_app' -or
            $Package.Name -cne 'OpenBubbles.OpenBubbles' -or
            $Package.PackageFamilyName -cne 'OpenBubbles.OpenBubbles_qrjz7esdc5g9p' -or
            [string]$Package.Status -cne 'Ok' -or
            [string]$Package.SignatureKind -cne 'Store') { return $false }
        foreach ($candidate in @($Process.Path, $Package.InstallLocation, $WindowsAppsRoot)) {
            if ([string]::IsNullOrWhiteSpace($candidate) -or
                -not [IO.Path]::IsPathFullyQualified($candidate) -or
                $candidate -match '(^|[\\/])\.{1,2}([\\/]|$)') { return $false }
        }
        $root = [IO.Path]::GetFullPath($WindowsAppsRoot).TrimEnd(
            [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $install = [IO.Path]::GetFullPath($Package.InstallLocation).TrimEnd(
            [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        if (-not $install.StartsWith($root + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase)) { return $false }
        $expected = [IO.Path]::GetFullPath((Join-Path $install 'bluebubbles_app.exe'))
        return [IO.Path]::GetFullPath($Process.Path).Equals($expected,
            [StringComparison]::OrdinalIgnoreCase)
    }
    catch { return $false }
}

function Get-CloudSyncPotentialProfileOwners {
    param([Parameter(Mandatory)][string[]] $Names)
    $processes = @(Get-Process -Name $Names -ErrorAction SilentlyContinue)
    if (@($processes | Where-Object { $_.ProcessName -ceq 'bluebubbles_app' }).Count -eq 0) {
        return $processes
    }
    # Only OS package metadata can establish the exception. Missing permission,
    # unsupported cmdlet, ambiguous packages or unreadable process paths fail
    # closed to the previous conservative blocking behavior.
    $packages = @()
    try { $packages = @(Get-AppxPackage -Name 'OpenBubbles.OpenBubbles' -ErrorAction Stop) }
    catch { return $processes }
    if ($packages.Count -ne 1) { return $processes }
    $windowsApps = Join-Path $env:ProgramFiles 'WindowsApps'
    return @($processes | Where-Object {
        -not (Test-CloudSyncUnrelatedStoreProcess -Process $_ -Package $packages[0] `
            -WindowsAppsRoot $windowsApps)
    })
}
