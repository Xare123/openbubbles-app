param(
    [string] $GradleCache = (Join-Path $env:USERPROFILE '.gradle/caches/modules-2/files-2.1')
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

# Reuse cached compiler/test jars. Never invoke Gradle, Android tools, or downloads.
function Find-CachedJar([string] $relative) {
    $matches = @(Get-ChildItem -LiteralPath (Join-Path $GradleCache $relative) -Recurse -Filter '*.jar' -File)
    if ($matches.Count -ne 1) { throw "Expected one cached jar for $relative" }
    return $matches[0].FullName
}
$compiler = @(
    Find-CachedJar 'org.jetbrains.kotlin/kotlin-compiler-embeddable/2.2.20'
    Find-CachedJar 'org.jetbrains.kotlin/kotlin-stdlib/2.2.20'
    Find-CachedJar 'org.jetbrains.kotlin/kotlin-script-runtime/2.2.20'
    Find-CachedJar 'org.jetbrains.kotlin/kotlin-reflect/1.6.10'
    Find-CachedJar 'org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm/1.8.0'
    Find-CachedJar 'org.jetbrains/annotations/13.0'
)
$tests = @(
    Find-CachedJar 'junit/junit/4.13.2'
    Find-CachedJar 'org.hamcrest/hamcrest-core/1.3'
    Find-CachedJar 'org.json/json/20180813'
)
$production = Join-Path $repo 'android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime'
$testSource = Join-Path $repo 'android/app/src/test/kotlin/com/bluebubbles/messaging/services/facetime'
$sources = @(
    Join-Path $production 'FaceTimeMediaProbe.kt'
    Join-Path $production 'FaceTimeMediaEvidenceParser.kt'
    Join-Path $production 'FaceTimeJoinPolicy.kt'
    Join-Path $production 'FaceTimePermissionPolicy.kt'
)
$testNames = @(
    'FaceTimeMediaProbeTest'
    'FaceTimeMediaEvidenceParserTest'
    'FaceTimeJoinPolicyTest'
    'FaceTimeMediaAdmissionReplayTest'
    'FaceTimePermissionPolicyTest'
)
$sources += $testNames | ForEach-Object { Join-Path $testSource ($_ + '.kt') }
$output = Join-Path $repo 'build/facetime-host-tests'
New-Item -ItemType Directory -Path $output -Force | Out-Null
$jar = Join-Path $output 'tests.jar'
$classpath = ($compiler + $tests) -join [IO.Path]::PathSeparator
& java -cp ($compiler -join [IO.Path]::PathSeparator) org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -no-stdlib -no-reflect -jvm-target 17 -classpath $classpath -d $jar @sources
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$qualifiedTests = $testNames | ForEach-Object { 'com.bluebubbles.messaging.services.facetime.' + $_ }
& java -cp ($jar + [IO.Path]::PathSeparator + $classpath) org.junit.runner.JUnitCore @qualifiedTests
exit $LASTEXITCODE
