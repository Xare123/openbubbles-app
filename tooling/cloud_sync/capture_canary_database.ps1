# Private read-only capture. Does not stop Canary or open its database locally.
# A failed/unstable transfer is retained as unqualified evidence, never inspected.
param(
    [Parameter(Mandatory)][string]$Serial,
    [Parameter(Mandatory)][string]$EvidenceDirectory,
    [ValidateRange(10, 300)][int]$TimeoutSeconds = 180,
    [switch]$Compress
)
$ErrorActionPreference = 'Stop'
$adbPath = 'C:\Codex\Toolchains\AndroidSdk\platform-tools\adb.exe'
$package = 'com.bluebubbles.messaging.cloudkitcanary'
$remotePath = 'app_flutter/objectbox/data.mdb'
$root = [IO.Path]::GetFullPath('C:\Codex\OpenBubblesReview\device-evidence\')
$destination = [IO.Path]::GetFullPath($EvidenceDirectory)
if (!$destination.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Evidence directory must be inside the private device-evidence root'
}
$null = New-Item -ItemType Directory -Path $destination -Force
$outputPath = Join-Path $destination 'data.mdb'
$qualificationPath = Join-Path $destination 'capture-qualification.json'
if ((Test-Path -LiteralPath $outputPath) -or (Test-Path -LiteralPath $qualificationPath)) {
    throw 'Capture destination already contains evidence; choose a new directory'
}
[IO.File]::WriteAllText($qualificationPath, '{"stable":false,"reason":"capture_not_qualified"}')
function Read-DeviceHash {
    $result = & $adbPath -s $Serial shell run-as $package sha256sum $remotePath
    if ($LASTEXITCODE -ne 0 -or $result -notmatch '^([a-fA-F0-9]{64})\s') {
        throw 'Canary database hash unavailable'
    }
    return $Matches[1].ToLowerInvariant()
}
$before = Read-DeviceHash
$start = [Diagnostics.ProcessStartInfo]::new($adbPath)
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$remoteCommand = if ($Compress) { @('gzip', '-c', $remotePath) } else { @('cat', $remotePath) }
foreach ($arg in (@('-s', $Serial, 'exec-out', 'run-as', $package) + $remoteCommand)) {
    $start.ArgumentList.Add($arg)
}
$stream = [IO.File]::Open($outputPath, [IO.FileMode]::CreateNew)
$process = [Diagnostics.Process]::new()
$process.StartInfo = $start
$decompressor = $null
try {
    if (!$process.Start()) { throw 'Capture failed to start' }
    $errors = $process.StandardError.ReadToEndAsync()
    $sourceStream = $process.StandardOutput.BaseStream
    if ($Compress) {
        $decompressor = [IO.Compression.GZipStream]::new(
            $sourceStream, [IO.Compression.CompressionMode]::Decompress, $true)
        $sourceStream = $decompressor
    }
    $copy = $sourceStream.CopyToAsync($stream)
    if (!$process.WaitForExit($TimeoutSeconds * 1000)) {
        $process.Kill()
        $process.WaitForExit()
        throw 'Capture timed out; partial evidence retained, do not inspect'
    }
    $null = $copy.GetAwaiter().GetResult()
    $null = $errors.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) { throw 'Capture failed; partial evidence retained' }
} finally {
    if ($null -ne $decompressor) { $decompressor.Dispose() }
    $stream.Dispose()
    $process.Dispose()
}
$after = Read-DeviceHash
$local = (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($before -ne $after -or $local -ne $after) {
    throw 'Database changed during capture; retained unqualified copy, do not inspect'
}
[IO.File]::WriteAllText($qualificationPath, ([ordered]@{
    stable = $true
    package = $package
    databaseSha256 = $local
    remoteBeforeSha256 = $before
    remoteAfterSha256 = $after
    bytes = (Get-Item -LiteralPath $outputPath).Length
    compressedTransfer = [bool]$Compress
    capturedAtUtc = [DateTime]::UtcNow.ToString('o')
} | ConvertTo-Json))
[pscustomobject]@{path=$outputPath; bytes=(Get-Item -LiteralPath $outputPath).Length; stable=$true}
