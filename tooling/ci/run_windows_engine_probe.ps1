# Isolated, offline engine comparison. No Apple code, identity or account.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or
    $env:RUNNER_OS -ne 'Windows' -or
    [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64' -or
    [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne 'X64') {
    throw 'Only a disposable native x64 GitHub-hosted Windows runner is admitted'
}
if ($env:OUTBOUND_WRITER -ne 'false' -or $env:AUTOMATIC_UPLOADS -ne 'false') {
    throw 'Account and application operations must be disabled'
}
$runnerRoot = (Resolve-Path -LiteralPath $env:RUNNER_TEMP).Path
$workspace = (Resolve-Path -LiteralPath $env:GITHUB_WORKSPACE).Path
$out = [IO.Path]::GetFullPath($OutRoot)
if (-not $out.StartsWith($workspace.TrimEnd('\')+'\', [StringComparison]::OrdinalIgnoreCase) -or
    (Test-Path -LiteralPath $out)) { throw 'Receipt directory must be new and inside this checkout' }
$work = Join-Path $runnerRoot ('ob-engine-probe-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work, $out | Out-Null
$child = $null
$report = [ordered]@{ result='UNRUN'; account_access=$false; apple_code=$false;
    source_sha=$env:GITHUB_SHA; host='native-windows-x64'; cleanup=$false; packages=@() }
try {
    # Official package metadata: https://packages.msys2.org/packages/
    # mingw-w64-clang-x86_64-unicorn and mingw-w64-clang-x86_64-libwinpthread.
    # Only the runtime's non-system imported DLL is needed, not a full toolchain.
    $packages = @(
        @('mingw-w64-clang-x86_64-unicorn-2.1.4-5-any.pkg.tar.zst',
          'ca052d04cddb36ae2a01db9a6e2a5f45c3cc08b64ec90c76ea3eff7e26da6a89'),
        @('mingw-w64-clang-x86_64-libwinpthread-14.0.0.r426.g4564ee4b5-2-any.pkg.tar.zst',
          'bc934ff154f4e3d8a7c4468e3d3d68fe7690fc61d9707da0662575042a38fff0')
    )
    foreach ($package in $packages) {
        $archive = Join-Path $work $package[0]
        Invoke-WebRequest -Uri ('https://repo.msys2.org/mingw/clang64/'+$package[0]) `
            -OutFile $archive -MaximumRedirection 0 -TimeoutSec 90
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
        if ($hash -ne $package[1]) { throw 'Official package hash mismatch' }
        $entries = @(& tar.exe -tf $archive)
        if ($LASTEXITCODE -ne 0 -or $entries.Count -eq 0) { throw 'Cannot list verified archive' }
        foreach ($entry in $entries) {
            if ($entry -match '(^[/\\]|^[A-Za-z]:|(^|[/\\])\.\.([/\\]|$))') {
                throw 'Archive path escapes the private directory'
            }
        }
        # The static-link archive includes an unused symlink. Extract only the
        # exact dynamic runtime/header members and retain the no-links guard.
        $members = if ($package[0] -like '*-unicorn-*') {
            @('clang64/bin/libunicorn.dll', 'clang64/include/unicorn')
        } else { @('clang64/bin/libwinpthread-1.dll') }
        $types = @(& tar.exe -tvf $archive @members)
        if ($LASTEXITCODE -ne 0 -or @($types | Where-Object { $_ -notmatch '^[-d]' }).Count -gt 0) {
            throw 'Unexpected archive entry type; only regular files and directories allowed'
        }
        & tar.exe -xf $archive -C $work @members
        if ($LASTEXITCODE -ne 0) { throw 'Verified package extraction failed' }
        $report.packages += [ordered]@{ name=$package[0]; sha256=$hash; bytes=(Get-Item $archive).Length }
    }
    $library = Join-Path $work 'clang64/bin/libunicorn.dll'
    $report.library_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $library).Hash.ToLowerInvariant()
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    $vsPath = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or -not $vsPath) { throw 'MSVC x64 tools unavailable' }
    Import-Module (Join-Path $vsPath 'Common7/Tools/Microsoft.VisualStudio.DevShell.dll')
    Enter-VsDevShell -VsInstallPath $vsPath -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64' | Out-Null
    $source = Join-Path $PSScriptRoot 'windows_engine_probe.cpp'
    $report.probe_source_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash.ToLowerInvariant()
    $probe = Join-Path $work 'engine-probe.exe'
    $child = Start-Process -FilePath (Get-Command cl.exe).Source -WorkingDirectory $work `
        -ArgumentList @('/nologo','/std:c++17','/EHsc','/W4','/O2','/MT',
            ('/I"'+(Join-Path $work 'clang64/include')+'"'), ('"'+$source+'"'), ('/Fe:"'+$probe+'"')) `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $out 'compile.log') `
        -RedirectStandardError (Join-Path $out 'compile-error.log')
    if (-not $child.WaitForExit(60000)) { $child.Kill($true); $child.WaitForExit(); throw 'Compile deadline' }
    if ($child.ExitCode -ne 0) { throw ('Compile exit '+$child.ExitCode) }
    & dumpbin.exe /DEPENDENTS $library | Set-Content -LiteralPath (Join-Path $out 'imports.log')
    if ($LASTEXITCODE -ne 0) { throw 'Dependency inspection failed' }
    $report.probe_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $probe).Hash.ToLowerInvariant()
    $child = Start-Process -FilePath $probe -ArgumentList ('"'+$library+'"') `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $out 'probe.log') `
        -RedirectStandardError (Join-Path $out 'probe-error.log')
    if (-not $child.WaitForExit(15000)) { $child.Kill($true); $child.WaitForExit(); throw 'Offline engine deadline' }
    $report.exit = $child.ExitCode
    $output = Get-Content -LiteralPath (Join-Path $out 'probe.log')
    $output
    if ($child.ExitCode -ne 0 -or $output -notcontains 'passed=3 failed=0 account_access=false') {
        throw 'Engine assertions did not pass; do not promote this runtime'
    }
    $report.result = 'PASS_offline_engine_only_not_mac_validation_or_login'
} catch {
    $report.result = 'FAIL'
    $report.failure = $_.Exception.Message
    throw
} finally {
    $stopped = ($null -eq $child -or $child.HasExited)
    if (-not $stopped) { $child.Kill($true); $child.WaitForExit(5000) | Out-Null; $stopped=$child.HasExited }
    $resolved = [IO.Path]::GetFullPath($work)
    if ($stopped -and $resolved.StartsWith($runnerRoot.TrimEnd('\')+'\', [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved) -match '^ob-engine-probe-[0-9a-f]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
        $report.cleanup = -not (Test-Path -LiteralPath $resolved)
    }
    $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $out 'receipt.json')
    if (-not $report.cleanup) { throw 'Owned temporary runtime cleanup not proven' }
}
