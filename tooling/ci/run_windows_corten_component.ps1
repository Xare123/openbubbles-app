# The existing provider's exact locked Rust call boundary on native Windows x64.
# No Apple framework, hardware transfer, account, app profile or live HTTP tests.
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
if ($env:OUTBOUND_WRITER -ne 'false' -or $env:AUTOMATIC_UPLOADS -ne 'false' -or
    $env:SOURCE_REF -ne '2eef443e0d2d6349df94d1ff1deaf4d0bc64c4b0' -or
    $env:TRUSTED_SOURCE_BRANCH -ne 'agent/cloudkit-v2-received-origin-20260916') {
    throw 'Only the reviewed source and disabled account/application operations are admitted'
}
$runnerRoot = (Resolve-Path -LiteralPath $env:RUNNER_TEMP).Path
$workspace = (Resolve-Path -LiteralPath $env:GITHUB_WORKSPACE).Path
$out = [IO.Path]::GetFullPath($OutRoot)
if (-not $out.StartsWith($workspace.TrimEnd('\')+'\', [StringComparison]::OrdinalIgnoreCase) -or
    (Test-Path -LiteralPath $out)) { throw 'Receipt directory must be new and inside this checkout' }
$work = Join-Path $runnerRoot ('ob-corten-component-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work, $out | Out-Null
$child = $null
$report = [ordered]@{ result='UNRUN'; account_access=$false; apple_framework=$false;
    hardware_input=$false; application_sha=$env:SOURCE_REF; tooling_sha=$env:GITHUB_SHA;
    native_sha='338cbf0c17c765bbbde07fae1fab18732c6ae5d0'; cleanup=$false; inputs=@() }
try {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    $vsPath = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or -not $vsPath) { throw 'MSVC x64 tools unavailable' }
    Import-Module (Join-Path $vsPath 'Common7/Tools/Microsoft.VisualStudio.DevShell.dll')
    Enter-VsDevShell -VsInstallPath $vsPath -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64' | Out-Null
    $env:CARGO_TARGET_DIR = Join-Path $work 'target'
    $env:CARGO_HOME = Join-Path $work 'cargo'
    $env:CARGO_BUILD_TARGET = 'x86_64-pc-windows-msvc'
    $env:CARGO_BUILD_JOBS = '4'
    $env:CMAKE_BUILD_PARALLEL_LEVEL = '4'
    $env:CARGO_INCREMENTAL = '0'
    $env:RUSTFLAGS = ''
    $env:CARGO_ENCODED_RUSTFLAGS = $null
    $env:RUSTC_WRAPPER = $null
    $env:RUSTC_WORKSPACE_WRAPPER = $null
    $source = Join-Path $work 'source'
    $prototype = Join-Path $source 'tooling/cloud_sync/corten_mac_validation_probe'
    New-Item -ItemType Directory -Path (Split-Path $prototype -Parent) | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../corten_mac_validation_probe') -Destination $prototype -Recurse
    $initialLock = (Get-FileHash -LiteralPath (Join-Path $prototype 'Cargo.lock') -Algorithm SHA256).Hash
    $report.lock_sha256 = $initialLock.ToLowerInvariant()
    $inputs = @(
        @('https://raw.githubusercontent.com/Xare123/openbubbles-app/2eef443e0d2d6349df94d1ff1deaf4d0bc64c4b0/rust/src/mac_hw_info.proto',
          'rust/src/mac_hw_info.proto', '621eedbc97207d504c107b27eb074253f75729414ef9447e7c5c8d1b553223c0'),
        @('https://raw.githubusercontent.com/Xare123/rustpush/338cbf0c17c765bbbde07fae1fab18732c6ae5d0/certs/root/profileidentity.ess.apple.com.cert',
          'rustpush/certs/root/profileidentity.ess.apple.com.cert', '0c0daaff3aaf1be8d257a1948c98aa469b476ab26fd9a51b597d38004cfbd63e'),
        @('https://raw.githubusercontent.com/Xare123/rustpush/338cbf0c17c765bbbde07fae1fab18732c6ae5d0/certs/root/init.ess.apple.com.cert',
          'rustpush/certs/root/init.ess.apple.com.cert', 'f83c5c9357eebba5d70331640b4b9f15790a251f1f7424914840ccc51db16046')
    )
    foreach ($inputFile in $inputs) {
        $path = Join-Path $source $inputFile[1]
        New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
        Invoke-WebRequest -Uri $inputFile[0] -OutFile $path -TimeoutSec 45 -MaximumRedirection 0
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        $report.inputs += [ordered]@{path=$inputFile[1];sha256=$hash}
        if ($hash -ne $inputFile[2]) { throw ('Pinned source input mismatch: '+$inputFile[1]) }
    }
    # Pinned upstream compiler. Extract only its executable and public schemas.
    $archive = Join-Path $work 'protoc.zip'
    Invoke-WebRequest -Uri 'https://github.com/protocolbuffers/protobuf/releases/download/v31.1/protoc-31.1-win64.zip' -OutFile $archive -TimeoutSec 90
    $report.protoc_archive_sha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($report.protoc_archive_sha256 -ne '70381b116ab0d71cb6a5177d9b17c7c13415866603a0fd40d513dafe32d56c35') {
        throw 'Pinned protoc archive mismatch'
    }
    $protocRoot = Join-Path $work 'protoc'
    New-Item -ItemType Directory -Path $protocRoot | Out-Null
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        foreach ($entry in $zip.Entries) {
            if ($entry.FullName -ne 'bin/protoc.exe' -and $entry.FullName -notlike 'include/*') { continue }
            $path = [IO.Path]::GetFullPath((Join-Path $protocRoot $entry.FullName))
            if (-not $path.StartsWith($protocRoot+'\', [StringComparison]::OrdinalIgnoreCase) -or
                (($entry.ExternalAttributes -shr 16) -band 0xf000) -eq 0xa000) {
                throw 'Unexpected protoc archive path or link'
            }
            if ($entry.FullName.EndsWith('/')) { New-Item -ItemType Directory -Path $path -Force | Out-Null; continue }
            New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $path, $false)
        }
    } finally { $zip.Dispose() }
    $env:PROTOC = Join-Path $protocRoot 'bin/protoc.exe'
    $report.protoc = (& $env:PROTOC --version)
    if ($LASTEXITCODE -ne 0 -or $report.protoc -ne 'libprotoc 31.1') { throw 'Compiler version mismatch' }
    $report.rust = (& rustc --version)
    if ($LASTEXITCODE -ne 0 -or $report.rust -notlike 'rustc 1.98.1 *') { throw 'Rust version mismatch' }
    $manifest = Join-Path $prototype 'Cargo.toml'
    $began = [DateTime]::UtcNow
    $child = Start-Process -FilePath (Get-Command cargo.exe).Source -WorkingDirectory $source `
        -ArgumentList @('test','--manifest-path',('"'+$manifest+'"'),'--locked','--lib','--no-run','--message-format=json','--jobs','4') `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $out 'compile.jsonl') `
        -RedirectStandardError (Join-Path $out 'compile.log')
    if (-not $child.WaitForExit(480000)) { $child.Kill($true); $child.WaitForExit(); throw 'Component compile deadline' }
    $report.compile_seconds = ([DateTime]::UtcNow-$began).TotalSeconds
    $report.compile_exit = $child.ExitCode
    if ($child.ExitCode -ne 0) { throw 'Component compilation failed; inspect retained compiler log' }
    $artifacts = @(Get-Content -LiteralPath (Join-Path $out 'compile.jsonl') | Where-Object { $_.StartsWith('{') } |
        ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.reason -eq 'compiler-artifact' -and
            $_.profile.test -and $_.target.name -eq 'corten_mac_validation_probe' -and $_.executable })
    if ($artifacts.Count -ne 1) { throw 'Expected one compiler-reported native library-test binary' }
    $test = [IO.Path]::GetFullPath($artifacts[0].executable)
    if (-not $test.StartsWith($env:CARGO_TARGET_DIR+'\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Unexpected test artifact path'
    }
    $report.test_binary_sha256 = (Get-FileHash -LiteralPath $test -Algorithm SHA256).Hash.ToLowerInvariant()
    $began = [DateTime]::UtcNow
    $child = Start-Process -FilePath $test -ArgumentList @('nac::tests::','--test-threads=1','--nocapture') `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $out 'tests.log') `
        -RedirectStandardError (Join-Path $out 'tests-error.log')
    if (-not $child.WaitForExit(60000)) { $child.Kill($true); $child.WaitForExit(); throw 'Native-test deadline' }
    $report.test_seconds = ([DateTime]::UtcNow-$began).TotalSeconds
    $report.test_exit = $child.ExitCode
    $summary = Get-Content -LiteralPath (Join-Path $out 'tests.log') -Raw
    if ($child.ExitCode -ne 0 -or $summary -notmatch 'test result: ok\. 14 passed; 0 failed; 0 ignored;') {
        throw 'Required native call-boundary cases did not pass'
    }
    if ((Get-FileHash -LiteralPath (Join-Path $prototype 'Cargo.lock') -Algorithm SHA256).Hash -ne $initialLock) {
        throw 'Locked dependency graph changed'
    }
    $report.passed = 14
    $report.result = 'PASS_real_component_boundary_not_hardware_validation_or_login'
    $summary
} catch {
    $report.result = 'FAIL'
    $report.failure = $_.Exception.Message
    throw
} finally {
    $stopped = ($null -eq $child -or $child.HasExited)
    if (-not $stopped) { $child.Kill($true); $child.WaitForExit(5000) | Out-Null; $stopped=$child.HasExited }
    $resolved = [IO.Path]::GetFullPath($work)
    if ($stopped -and $resolved.StartsWith($runnerRoot.TrimEnd('\')+'\', [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved) -match '^ob-corten-component-[0-9a-f]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
        $report.cleanup = -not (Test-Path -LiteralPath $resolved)
    }
    $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $out 'receipt.json')
    if (-not $report.cleanup) { throw 'Owned component/cache cleanup not proven' }
}
