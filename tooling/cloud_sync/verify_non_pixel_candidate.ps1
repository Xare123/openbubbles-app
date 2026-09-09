[CmdletBinding()]
param(
    [string]$FlutterCommand = "flutter",
    [Parameter(Mandatory = $true)]
    [string]$ObjectBoxDllDirectory,
    [string]$CargoCommand = "cargo",
    [string]$CargoHome = "",
    [string]$RustupHome = "",
    [string]$CargoTargetDirectory = "",
    [switch]$SkipAnalyze,
    [switch]$SkipRust,
    [switch]$SkipFaceTimeHost
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$foundation = Join-Path $PSScriptRoot "verify_foundation.ps1"
$faceTimeHostTests = Join-Path $repoRoot "test\services\facetime\run_face_time_host_tests.ps1"
$objectBoxDirectory = (Resolve-Path -LiteralPath $ObjectBoxDllDirectory).Path
$objectBoxDll = Join-Path $objectBoxDirectory "objectbox.dll"
$originalPath = $env:PATH
$completedChecks = [System.Collections.Generic.List[string]]::new()
$skippedChecks = [System.Collections.Generic.List[string]]::new()

function Resolve-CommandPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command
    )

    if (Test-Path -LiteralPath $Command -PathType Leaf) {
        return (Resolve-Path -LiteralPath $Command).Path
    }
    return (Get-Command $Command -ErrorAction Stop).Source
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action
    )

    Write-Host ""
    Write-Host "== $Label =="
    & $Action
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE"
    }
}

if (-not (Test-Path -LiteralPath $objectBoxDll -PathType Leaf)) {
    throw "ObjectBox library not found: $objectBoxDll"
}
if (-not (Test-Path -LiteralPath $foundation -PathType Leaf)) {
    throw "Cloud Sync foundation verifier not found: $foundation"
}

$adjacentTests = @(
    "test\utils\attachment_mime_utils_test.dart",
    "test\database\chat_attachment_overview_test.dart",
    "test\layouts\conversation_details\media_gallery_card_auto_download_test.dart",
    "test\services\facetime\face_time_outgoing_start_test.dart",
    "test\services\facetime\face_time_diagnostics_contract_test.dart"
)
$analysisTargets = @(
    "lib\utils\attachment_mime_utils.dart",
    "lib\database\io\chat.dart",
    "lib\app\layouts\conversation_details\widgets\media_gallery_card.dart",
    "lib\app\layouts\conversation_view\widgets\message\attachment\other_file.dart",
    "test\utils\attachment_mime_utils_test.dart",
    "test\database\chat_attachment_overview_test.dart",
    "test\layouts\conversation_details\media_gallery_card_auto_download_test.dart",
    "test\services\facetime\face_time_outgoing_start_test.dart",
    "test\services\facetime\face_time_diagnostics_contract_test.dart"
)

Push-Location $repoRoot
try {
    $flutter = Resolve-CommandPath $FlutterCommand
    $env:PATH = "$objectBoxDirectory;$env:PATH"

    $foundationArguments = @{
        FlutterCommand = $flutter
        ObjectBoxDllDirectory = $objectBoxDirectory
        CargoCommand = $CargoCommand
        CargoHome = $CargoHome
        RustupHome = $RustupHome
        CargoTargetDirectory = $CargoTargetDirectory
        SkipAnalyze = $SkipAnalyze
        SkipRust = $SkipRust
    }
    Invoke-Checked "Cloud Sync V2 foundation" {
        & $foundation @foundationArguments
    }
    $completedChecks.Add("Cloud Sync V2 foundation")

    Invoke-Checked "Attachment and FaceTime adjacent regressions" {
        & $flutter test --no-pub @adjacentTests
    }
    $completedChecks.Add("attachment and FaceTime adjacent regressions")

    if (-not $SkipAnalyze) {
        Invoke-Checked "Adjacent Flutter analyzer" {
            & $flutter analyze --no-pub @analysisTargets
        }
        $completedChecks.Add("adjacent Flutter analyzer")
    }
    else {
        $skippedChecks.Add("adjacent Flutter analyzer")
    }

    if (-not $SkipFaceTimeHost) {
        Invoke-Checked "FaceTime Kotlin host policy suite" {
            & $faceTimeHostTests
        }
        $completedChecks.Add("FaceTime Kotlin host policy suite")
    }
    else {
        $skippedChecks.Add("FaceTime Kotlin host policy suite")
    }

    Write-Host ""
    Write-Host "Passed checks: $($completedChecks -join '; ')."
    if ($skippedChecks.Count -gt 0) {
        Write-Warning "Partial non-Pixel qualification only. Skipped: $($skippedChecks -join '; ')."
    }
    else {
        Write-Host "Non-Pixel candidate qualification passed."
    }
    Write-Host "No live CloudKit access, Apple account mutation, app installation, or message send was performed."
    Write-Host "Pixel lifecycle, UI, remote readback, and independent Apple-device display remain separate release gates."
}
finally {
    $env:PATH = $originalPath
    Pop-Location
}
