# Credential-free dependency readiness on an owned, disposable GitHub runner.
# No OTP, provisioning, account login, security change or Apple binary artifact.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or
    $env:RUNNER_OS -ne 'Windows' -or -not [Environment]::Is64BitProcess) {
    throw 'Only a disposable GitHub-hosted Windows x64 process is admitted'
}
$runnerRoot = (Resolve-Path -LiteralPath $env:RUNNER_TEMP).Path
$work = Join-Path $runnerRoot ('ob-adi-readiness-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$out = [IO.Path]::GetFullPath($OutRoot)
if (Test-Path -LiteralPath $out) { throw 'Refuse an existing receipt directory' }
New-Item -ItemType Directory -Path $out | Out-Null
$child = $null
$report = [ordered]@{ account_access=$false; provisioning=$false; otp_requested=$false;
    result='UNRUN'; cleanup=$false; source_sha=$env:GITHUB_SHA }
try {
    # Apple website's win64 link resolves here. Hash independently agrees with
    # Microsoft's Apple.iTunes/12.13.11.1 winget installer manifest.
    $url = 'https://secure-appldnld.apple.com/itunes12/140-75773-20260908-6e5e0165-99cb-4b30-b541-1b615fccfc1a/iTunes64Setup.exe'
    $expected = '25b28905a81406a5edbf482f7f3ee4831a8641d32d29dceda5d1eb3e8d534c08'
    $installer = Join-Path $work 'iTunes64Setup.exe'
    Invoke-WebRequest -Uri $url -OutFile $installer -MaximumRedirection 0 -TimeoutSec 120
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $installer).Hash.ToLowerInvariant()
    if ($hash -ne $expected) { throw 'Official installer hash differs from pinned manifest' }
    $signature = Get-AuthenticodeSignature -LiteralPath $installer
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Apple Inc\.') {
        throw 'Installer does not have a valid Apple signature'
    }
    $report.installer_sha256 = $hash
    $report.installer_signature = 'Valid Apple Inc.'
    $packageRoot = Join-Path $work 'package'
    & 7z.exe e $installer 'iTunes64.msi' ('-o' + $packageRoot) -y | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not extract the named MSI' }
    $msi = Join-Path $packageRoot 'iTunes64.msi'
    if (-not (Test-Path -LiteralPath $msi -PathType Leaf)) { throw 'Named MSI not found' }
    $imageRoot = Join-Path $work 'image'
    # Administrative extraction only. No local or cloud iTunes account/session.
    $child = Start-Process -FilePath msiexec.exe -ArgumentList @('/a', ('"'+$msi+'"'),
        '/qn', '/norestart', ('TARGETDIR="'+$imageRoot+'"')) -PassThru -WindowStyle Hidden
    if (-not $child.WaitForExit(90000)) { $child.Kill($true); $child.WaitForExit(); throw 'MSI extraction deadline' }
    if ($child.ExitCode -ne 0) { throw ('MSI extraction exit ' + $child.ExitCode) }
    $libraries = @(Get-ChildItem -LiteralPath $imageRoot -Recurse -File -Filter CoreADI64.dll)
    if ($libraries.Count -ne 1) { throw 'Expected exactly one CoreADI64.dll in the extracted image' }
    $library = $libraries[0]
    $signature = Get-AuthenticodeSignature -LiteralPath $library.FullName
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Apple Inc\.') {
        throw 'Library does not have a valid Apple signature'
    }
    $report.library_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $library.FullName).Hash.ToLowerInvariant()
    $report.library_version = $library.VersionInfo.FileVersion
    $source = Join-Path $PSScriptRoot 'windows_adi_readiness.rs'
    $report.probe_source_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash.ToLowerInvariant()
    $tests = Join-Path $work 'readiness-tests.exe'
    & rustc --edition=2021 --test $source -o $tests
    if ($LASTEXITCODE -ne 0) { throw 'Readiness test compilation failed' }
    & $tests --test-threads=1
    if ($LASTEXITCODE -ne 0) { throw 'Readiness framing tests failed' }
    $probe = Join-Path $work 'readiness.exe'
    & rustc --edition=2021 $source -o $probe
    if ($LASTEXITCODE -ne 0) { throw 'Readiness compilation failed' }
    $child = Start-Process -FilePath $probe -ArgumentList ('"'+$library.FullName+'"') -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $out 'readiness.log') -RedirectStandardError (Join-Path $out 'error.log')
    if (-not $child.WaitForExit(15000)) { $child.Kill($true); $child.WaitForExit(); throw 'Readiness deadline' }
    $report.exit = $child.ExitCode
    Get-Content -LiteralPath (Join-Path $out 'readiness.log')
    Get-Content -LiteralPath (Join-Path $out 'error.log')
    if ($child.ExitCode -ne 0) { throw 'Native library readiness failed; do not relax loading or security' }
    $report.result = 'native_readiness_only_not_account_or_sms'
} catch {
    $report.result = 'FAIL'
    $report.failure = $_.Exception.Message
    throw
} finally {
    $stopped = ($null -eq $child -or $child.HasExited)
    if (-not $stopped) { $child.Kill($true); $child.WaitForExit(5000) | Out-Null; $stopped=$child.HasExited }
    $resolved = [IO.Path]::GetFullPath($work)
    if ($stopped -and $resolved.StartsWith($runnerRoot.TrimEnd('\')+'\', [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved) -match '^ob-adi-readiness-[0-9a-f]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
        $report.cleanup = -not (Test-Path -LiteralPath $resolved)
    }
    $report | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $out 'receipt.json')
    if (-not $report.cleanup) { throw 'Owned temporary dependency cleanup not proven' }
}
