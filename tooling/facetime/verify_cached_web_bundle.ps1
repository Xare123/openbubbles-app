param(
    [string]$Serial,
    [string]$PackageName = "com.bluebubbles.messaging.alpha"
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Serial)) {
    $devices = @(
        & adb devices |
            Select-Object -Skip 1 |
            ForEach-Object { ($_ -split "\s+")[0] } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($devices.Count -ne 1) {
        throw "Pass -Serial when zero or multiple ADB devices are connected."
    }
    $Serial = $devices[0]
}

$cacheFiles = @(
    & adb -s $Serial shell run-as $PackageName ls -t cache/http_cache 2>$null |
        Where-Object { $_ -match "^[a-f0-9]+\.1$" }
)
if ($LASTEXITCODE -ne 0 -or $cacheFiles.Count -eq 0) {
    throw "No cached FaceTime JavaScript bodies are available in $PackageName."
}

$selected = $null
$checks = $null
foreach ($cacheFile in $cacheFiles) {
    $script = (& adb -s $Serial shell "run-as $PackageName gzip -dc cache/http_cache/$cacheFile" 2>$null) -join "`n"
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($script)) {
        continue
    }

    $candidate = [ordered]@{
        bytes = $script.Length
        waiting = [regex]::Matches(
            $script,
            '"GenericToast\.Waiting": *"Waiting to be let in…",'
        ).Count
        banner = [regex]::Matches(
            $script,
            '"SessionBanner\.FaceTime": *"FaceTime Call",'
        ).Count
        submitName = [regex]::Matches(
            $script,
            '(submitName: *([a-zA-Z]+?)[ a-zA-Z,}=:]*?;)'
        ).Count
    }
    if ($candidate.waiting -gt 0 -or $candidate.banner -gt 0 -or $candidate.submitName -gt 0) {
        $selected = $cacheFile
        $checks = $candidate
        break
    }
}

if ($null -eq $checks) {
    throw "No cached body matched the FaceTime web bundle signature."
}

$compatible = $checks.waiting -gt 0 -and $checks.banner -gt 0 -and $checks.submitName -gt 0
[pscustomobject]@{
    compatible = $compatible
    cacheBody = $selected
    bytes = $checks.bytes
    waitingMatches = $checks.waiting
    bannerMatches = $checks.banner
    submitNameMatches = $checks.submitName
}

if (-not $compatible) {
    throw "Apple's cached FaceTime web bundle no longer matches every required compatibility patch."
}
