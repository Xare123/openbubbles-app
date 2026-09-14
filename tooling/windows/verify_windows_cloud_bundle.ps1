[CmdletBinding()]
param(
    [string] $ArchivePath,
    [string] $ProvenancePath,
    [string] $ExpectedArchiveSha256,
    [string] $ExpectedSourceSha,
    [string] $ExpectedPilotSha,
    [string] $ExpectedVariant,
    [ValidateSet('harness', 'native-test-host')]
    [string] $ExpectedArtifactMode = 'harness',
    [ValidateRange(1, 10000)]
    [int] $ExpectedNativeEncoderTestCount = 51,
    [switch] $FunctionsOnlyForTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Fail([string] $Message) { throw "VERIFY-FAIL: $Message" }

function Test-ZipEntryPathSafety {
    param([Parameter(Mandatory)][string] $Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return 'empty entry name' }
    if ($Name.Contains('\')) { return 'backslash separator' }
    if ($Name.StartsWith('/')) { return 'rooted path' }
    if ($Name.Length -gt 2 -and $Name[1] -eq ':' -and $Name[0] -match '[A-Za-z]') { return 'drive-qualified path' }
    if ($Name.Contains(':')) { return 'ADS or drive colon present' }
    $badChars = [char[]]@([char]63, [char]42, [char]60, [char]62, [char]124, [char]34)
    if ($Name.IndexOfAny($badChars) -ge 0) { return 'windows-invalid character' }
    foreach ($ch in $Name.ToCharArray()) { $code = [int]$ch; if ($code -lt 32 -or $code -eq 127) { return 'control character present' } }
    $segs = $Name.TrimEnd('/').Split('/')
    foreach ($s in $segs) {
        if ($s -eq '' -or $s -eq '.' -or $s -eq '..') { return "unsafe segment '$s'" }
        if ($s.EndsWith(' ') -or $s.EndsWith('.')) { return "trailing dot or space in '$s'" }
        $base = ($s.Split('.')[0]).ToUpperInvariant()
        if ($base -in @('CON','PRN','AUX','NUL') -or $base -match '^(COM[1-9]|LPT[1-9])$') { return "device name '$s'" }
    }
    return $null
}

function Test-NameCaseCollision {
    param([Parameter(Mandatory)][string[]] $Names)
    $seen = @{}
    foreach ($n in $Names) {
        $k = $n.ToLowerInvariant()
        if ($seen.ContainsKey($k)) { return $n }
        $seen[$k] = $true
    }
    return $null
}

function Get-PeMachineFromHeader {
    param([Parameter(Mandatory)][byte[]] $Bytes)
    if ($Bytes.Length -lt 64) { return $null }
    if ($Bytes[0] -ne 0x4D -or $Bytes[1] -ne 0x5A) { return $null }
    $lfanew = [BitConverter]::ToInt32($Bytes, 0x3C)
    if ($lfanew -lt 0 -or ($lfanew + 6) -gt $Bytes.Length) { return $null }
    if ($Bytes[$lfanew] -ne 0x50 -or $Bytes[$lfanew+1] -ne 0x45 -or $Bytes[$lfanew+2] -ne 0 -or $Bytes[$lfanew+3] -ne 0) { return $null }
    return [BitConverter]::ToUInt16($Bytes, $lfanew + 4)
}

function Invoke-VerifyWindowsCloudBundle {
    param(
        [Parameter(Mandatory)][string] $ArchivePath,
        [Parameter(Mandatory)][string] $ProvenancePath,
        [Parameter(Mandatory)][string] $ExpectedArchiveSha256,
        [Parameter(Mandatory)][string] $ExpectedSourceSha,
        [Parameter(Mandatory)][string] $ExpectedPilotSha,
        [Parameter(Mandatory)][string] $ExpectedVariant,
        [ValidateSet('harness', 'native-test-host')][string] $ExpectedArtifactMode = 'harness',
        [ValidateRange(1, 10000)][int] $ExpectedNativeEncoderTestCount = 51
    )
    foreach ($p in @($ArchivePath, $ProvenancePath)) { if (-not (Test-Path -LiteralPath $p)) { Fail "missing input $p" } }
    $actualArchiveHash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualArchiveHash -ne $ExpectedArchiveSha256.ToLowerInvariant()) { Fail 'archive SHA256 mismatch' }
    $prov = Get-Content -LiteralPath $ProvenancePath -Raw | ConvertFrom-Json
    # Unknown non-security provenance keys are preserved (ignored); only required fields assert.
    $isSchemaTwo = ($prov.schema_version -eq 2)
    if ($ExpectedArtifactMode -eq 'native-test-host') {
        if (-not $isSchemaTwo) { Fail 'native-test-host provenance schema_version must be 2' }
    } elseif (($prov.schema_version -ne 1) -and (-not $isSchemaTwo)) {
        Fail 'harness provenance schema_version must be 1 or 2'
    }
    if ($prov.source_commit -ne $ExpectedSourceSha) { Fail 'provenance source_commit mismatch' }
    if ($prov.sidecar_commit -ne $ExpectedPilotSha) { Fail 'provenance sidecar (pilot) commit mismatch' }
    if ($ExpectedSourceSha -cnotmatch '^[0-9a-f]{40}$') { Fail 'expected source SHA must be lowercase 40-hex' }
    if ($ExpectedPilotSha -cnotmatch '^[0-9a-f]{40}$') { Fail 'expected pilot SHA must be lowercase 40-hex' }
    if ($isSchemaTwo) {
        $wantPurpose = "windows-cloudkit-fast-loop-$ExpectedArtifactMode"
        if ($prov.purpose -cne $wantPurpose) { Fail "provenance purpose must be '$wantPurpose'" }
        if (($prov.source_tree -isnot [string]) -or ($prov.source_tree -cnotmatch '^[0-9a-f]{40}$')) { Fail 'source_tree must be lowercase 40-hex' }
        $submodules = @($prov.submodule_commits)
        if ($submodules.Count -eq 0) { Fail 'submodule_commits must not be empty' }
        foreach ($submodule in $submodules) {
            if (($submodule -isnot [string]) -or ($submodule -cnotmatch '^[ +\-U][0-9a-f]{40}\s+\S+(?:\s+\(.+\))?$')) { Fail 'submodule_commits contains an invalid entry' }
        }
        $sourceInputs = @($prov.source_inputs)
        if ($sourceInputs.Count -eq 0) { Fail 'source_inputs must not be empty' }
        $sourceInputPaths = New-Object System.Collections.Generic.List[string]
        foreach ($input in $sourceInputs) {
            if (($input.path -isnot [string]) -or ($input.sha256 -isnot [string])) { Fail 'source_inputs entry must contain string path and sha256' }
            $badInputPath = Test-ZipEntryPathSafety -Name $input.path
            if ($badInputPath) { Fail "unsafe source_inputs path '$($input.path)': $badInputPath" }
            if ($input.sha256 -cnotmatch '^[0-9a-f]{64}$') { Fail "source_inputs sha256 invalid for '$($input.path)'" }
            $sourceInputPaths.Add($input.path)
        }
        $sourceInputCollision = Test-NameCaseCollision -Names $sourceInputPaths.ToArray()
        if ($sourceInputCollision) { Fail "duplicate or case-colliding source_inputs path '$sourceInputCollision'" }
        if ($prov.build.artifact_mode -cne $ExpectedArtifactMode) { Fail 'provenance build.artifact_mode mismatch' }
        if ($prov.build.configuration -cne 'debug') { Fail 'build.configuration must be debug' }
        if ($prov.build.architecture -cne 'arm64') { Fail 'build.architecture must be arm64' }
        if (($prov.build.native_media_graph_excluded -isnot [bool]) -or ($prov.build.native_media_graph_excluded -ne $true)) { Fail 'build.native_media_graph_excluded must be boolean true' }
        if (($prov.build.signing_applied -isnot [bool]) -or ($prov.build.signing_applied -ne $false)) { Fail 'build.signing_applied must be boolean false' }
        $wantFindMyDiagnostics = ($ExpectedArtifactMode -eq 'native-test-host')
        if (($prov.build.findmy_value_free_diagnostics_compiled -isnot [bool]) -or ($prov.build.findmy_value_free_diagnostics_compiled -ne $wantFindMyDiagnostics)) { Fail 'build.findmy_value_free_diagnostics_compiled mismatch' }
        if ($ExpectedArtifactMode -eq 'harness') {
            if ($prov.build.target -cne 'lib/cloud_sync_v2_windows_harness.dart') { Fail 'harness build.target mismatch' }
        } else {
            if ($prov.build.target -cne 'rust/Cargo.toml --lib; flutter test') { Fail 'native-test-host build.target mismatch' }
        }
        $q = $prov.qualification
        if ($q.cloud_artifact_signing -cne 'not-applied' -or $q.local_policy_load -cne 'not-tested' -or $q.gui_assembly_receipt -cne 'not-issued') { Fail 'qualification state mismatch' }
        if (($q.retained_native_base_reused -isnot [bool]) -or $q.retained_native_base_reused -ne $false) { Fail 'qualification retained_native_base_reused must be boolean false' }
        if (($q.live_cloudkit_tested -isnot [bool]) -or $q.live_cloudkit_tested -ne $false) { Fail 'qualification live_cloudkit_tested must be boolean false' }
    } elseif ($prov.purpose -cne 'windows-cloudkit-fast-loop-engineering-bundle') {
        Fail 'legacy harness provenance purpose mismatch'
    }
    $allowedVariants = @('local-write', 'read-only')
    if ($allowedVariants -cnotcontains $ExpectedVariant) { Fail "variant '$ExpectedVariant' not allowed" }
    if (($ExpectedArtifactMode -eq 'native-test-host') -and ($ExpectedVariant -cne 'read-only')) { Fail 'native-test-host verification permits only read-only artifacts' }
    if ($prov.build.variant -cne $ExpectedVariant) { Fail 'provenance build.variant mismatch' }
    # Exact per-variant mapping mirrors Get-HarnessConfigurationIdentifier: writer/replay take a
    # suffix, the read-only default is the bare 12-char source identifier.
    $wantId = $null
    if ($ExpectedArtifactMode -eq 'harness') {
        $wantId = $ExpectedSourceSha.Substring(0, 12)
        if ($ExpectedVariant -cne 'read-only') { $wantId += '-' + $ExpectedVariant }
        if ($prov.build.build_identifier -cne $wantId) { Fail "build_identifier must be '$wantId'" }
    } elseif ($null -ne $prov.build.build_identifier) {
        Fail 'native-test-host build_identifier must be null'
    }
    $wantWriter = (($ExpectedArtifactMode -eq 'harness') -and ($ExpectedVariant -ceq 'local-write'))
    if (($prov.build.writer_defines_present -isnot [bool]) -or ($prov.build.writer_defines_present -ne $wantWriter)) { Fail 'build.writer_defines_present must be boolean matching variant' }
    if (($prov.build.automatic_send_runtime_present -isnot [bool]) -or ($prov.build.automatic_send_runtime_present -ne $false)) { Fail 'build.automatic_send_runtime_present must be boolean false' }
    $v = $prov.verification
    if ($v.powershell_contract_tests -ne 'passed') { Fail 'powershell_contract_tests not passed' }
    if ($v.focused_dart_tests -ne 'passed') { Fail 'focused_dart_tests not passed' }
    if (($v.all_pe_files_arm64 -isnot [bool]) -or ($v.all_pe_files_arm64 -ne $true)) { Fail 'all_pe_files_arm64 must be boolean true' }
    if ($v.rust_bridge_load_unload -ne 'passed') { Fail 'rust_bridge_load_unload not passed' }
    $enc = $v.native_local_write_encoder_tests
    if ($enc.result -ne 'passed') { Fail 'native encoder tests not passed' }
    # Trusted caller expectation, never learn the required count from the bundle.
    # Historical bundles can be explicitly verified against their older suite.
    if ($enc.expected_test_count -ne $ExpectedNativeEncoderTestCount) { Fail "native encoder expected_test_count must be $ExpectedNativeEncoderTestCount" }
    if (($enc.full_file_run -isnot [bool]) -or ($enc.full_file_run -ne $true)) { Fail 'native encoder full_file_run must be boolean true' }
    if ($enc.native_library -cne 'bundle/rust_lib_bluebubbles.dll') { Fail 'native_library must be exactly bundle/rust_lib_bluebubbles.dll' }
    $inv = $v.invalid_launch_diagnostic
    if ($ExpectedArtifactMode -eq 'harness') {
        if ($inv.expected_dart_marker -ne 'cloud_sync_windows_dev_launch_id_invalid') { Fail 'invalid-launch marker mismatch' }
        if ((($inv.expected_dart_marker_seen -isnot [bool]) -or ($inv.expected_dart_marker_seen -ne $true)) -or ($inv.proof_status -ne 'observed')) { Fail 'invalid-launch not observed' }
        if ((($inv.network_or_auth_requested -isnot [bool]) -or ($inv.network_or_auth_requested -ne $false)) -or ((($inv.profile_state_written -isnot [bool]) -or ($inv.profile_state_written -ne $false)))) { Fail 'invalid-launch side-effect flags unexpected' }
    } else {
        if ($inv.proof_status -cne 'not-run-no-gui-assembly') { Fail 'native-test-host invalid-launch status mismatch' }
        if ($v.native_timestamp_compose_tests -cne 'passed' -or $v.native_timestamp_compose_expected_count -ne 7) { Fail 'native timestamp compose suite mismatch' }
        $nativeSuites = @(
            @{ Name = 'native_content_free_diagnostic_tests'; Count = 5 },
            @{ Name = 'native_read_discovery_tests'; Count = 2 },
            @{ Name = 'native_system_event_tests'; Count = 5 }
        )
        foreach ($suiteSpec in $nativeSuites) {
            $suite = $v.($suiteSpec.Name)
            if ($suite.result -cne 'passed' -or $suite.expected_test_count -ne $suiteSpec.Count) { Fail "$($suiteSpec.Name) result or count mismatch" }
            if ($suite.executable -cne 'bundle/native-compose-tests.exe') { Fail "$($suiteSpec.Name) executable mismatch" }
            $names = @($suite.expected_names)
            if ($names.Count -ne $suiteSpec.Count -or @($names | Select-Object -Unique).Count -ne $suiteSpec.Count) { Fail "$($suiteSpec.Name) expected_names mismatch" }
        }
        $scopedSuites = @(
            @{ Name = 'native_extension_payload_tests'; Scope = 'cloud_sync_extension_payload::tests::'; Minimum = 29 },
            @{ Name = 'native_canonical_converter_tests'; Scope = 'cloud_sync_canonical_converter::tests::'; Minimum = 81 },
            @{ Name = 'native_canonical_dto_tests'; Scope = 'cloud_sync_canonical_dto::tests::'; Minimum = 24 }
        )
        foreach ($suiteSpec in $scopedSuites) {
            $suite = $v.($suiteSpec.Name)
            if ($suite.result -cne 'passed' -or $suite.scope -cne $suiteSpec.Scope -or $suite.minimum_passed -lt $suiteSpec.Minimum) { Fail "$($suiteSpec.Name) result, scope, or minimum mismatch" }
            if ($suite.executable -cne 'bundle/native-compose-tests.exe' -or @($suite.spot_names).Count -eq 0) { Fail "$($suiteSpec.Name) evidence mismatch" }
        }
        $repair = $v.native_repair_digest_test
        if ($repair.result -cne 'passed' -or $repair.executable -cne 'bundle/native-compose-tests.exe' -or @($repair.expected_names).Count -ne 2) { Fail 'native_repair_digest_test mismatch' }
    }
    if (($v.account_profile_or_database_in_bundle -isnot [bool]) -or ($v.account_profile_or_database_in_bundle -ne $false)) { Fail 'account data flag must be boolean false' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zf = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        if ($zf.Entries.Count -gt 2048) { Fail 'zip entry count exceeds 2048' }
        $manifest = @{}
        foreach ($f in $prov.files) {
            if ($manifest.ContainsKey($f.relative_path)) { Fail "duplicate manifest path '$($f.relative_path)'" }
            $manifest[$f.relative_path] = $f
        }
        if ($manifest.Count -eq 0) { Fail 'provenance files manifest empty' }
        if ($ExpectedArtifactMode -eq 'native-test-host') {
            $expectedNativeFiles = @('native-compose-tests.exe', 'objectbox.dll', 'rust_lib_bluebubbles.dll')
            if ($manifest.Count -ne $expectedNativeFiles.Count) { Fail 'native-test-host manifest must contain exactly three files' }
            foreach ($expectedNativeFile in $expectedNativeFiles) {
                if (-not $manifest.ContainsKey($expectedNativeFile)) { Fail "native-test-host manifest missing '$expectedNativeFile'" }
            }
        }
        $fileEntries = @($zf.Entries | Where-Object { -not $_.FullName.EndsWith('/') })
        $dirEntries = @($zf.Entries | Where-Object { $_.FullName.EndsWith('/') })
        $totalBytes = 0
        foreach ($e in $fileEntries) { $totalBytes += $e.Length }
        if ($totalBytes -gt 2147483648) { Fail 'total expanded size exceeds 2GiB' }
        $allNames = @($zf.Entries | ForEach-Object { $_.FullName })
        $dup = Test-NameCaseCollision -Names $allNames
        if ($dup) { Fail "case-insensitive collision at '$dup'" }
        foreach ($e in $zf.Entries) {
            $bad = Test-ZipEntryPathSafety -Name $e.FullName
            if ($bad) { Fail "unsafe zip path '$($e.FullName)': $bad" }
            $mode = [int]($e.ExternalAttributes -shr 16)
            if (($mode -band 0xF000) -eq 0xA000) { Fail "unix symlink entry '$($e.FullName)'" }
        }
        foreach ($d in $dirEntries) {
            if ($d.Length -ne 0) { Fail "directory entry with data '$($d.FullName)'" }
            $covered = $false
            foreach ($k in $manifest.Keys) { if ($k.StartsWith($d.FullName)) { $covered = $true; break } }
            if (-not $covered) { Fail "unmanifested directory '$($d.FullName)'" }
        }
        $fileSet = @{}
        foreach ($fn in @($fileEntries | ForEach-Object { $_.FullName })) { $fileSet[$fn] = $true }
        $dirSet = @{}
        foreach ($dd in $dirEntries) { $dirSet[$dd.FullName.TrimEnd('/')] = $true }
        foreach ($kn in @($fileSet.Keys)) {
            if ($dirSet.ContainsKey($kn)) { Fail "file/directory collision '$kn'" }
            $parts = $kn.Split('/')
            for ($pi = 1; $pi -lt $parts.Count; $pi++) {
                $ancestor = ($parts[0..($pi - 1)] -join '/')
                if ($fileSet.ContainsKey($ancestor)) { Fail "file ancestor collision '$ancestor' under '$kn'" }
            }
        }
        $zipNames = @($fileEntries | ForEach-Object { $_.FullName })
        foreach ($n in $zipNames) { if (-not $manifest.ContainsKey($n)) { Fail "unmanifested file '$n'" } }
        foreach ($k in $manifest.Keys) { if ($zipNames -notcontains $k) { Fail "missing manifested file '$k'" } }
        foreach ($e in $fileEntries) {
            $m = $manifest[$e.FullName]
            if ($e.Length -ne [long]$m.size_bytes) { Fail "length mismatch '$($e.FullName)'" }
            $isBin = $e.FullName.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase) -or $e.FullName.EndsWith('.dll', [StringComparison]::OrdinalIgnoreCase)
            if ($isBin -and $m.pe_machine -ne 'ARM64') { Fail "manifest pe_machine must be ARM64 '$($e.FullName)'" }
            if ((-not $isBin) -and ($null -ne $m.pe_machine)) { Fail "non-binary pe_machine must be null '$($e.FullName)'" }
            $hasher = [System.Security.Cryptography.SHA256]::Create()
            $head = New-Object System.Collections.Generic.List[byte]
            try {
                $st = $e.Open()
                try {
                    $buf = New-Object byte[] 131072
                    $count = 0
                    while (($n = $st.Read($buf, 0, $buf.Length)) -gt 0) {
                        $count += $n
                        $hasher.TransformBlock($buf, 0, $n, $null, 0) | Out-Null
                        if ($head.Count -lt 512) {
                            $take = [Math]::Min($n, 512 - $head.Count)
                            for ($i = 0; $i -lt $take; $i++) { $head.Add($buf[$i]) }
                        }
                    }
                    if ($count -ne $e.Length) { Fail "stream length mismatch '$($e.FullName)'" }
                } finally { $st.Dispose() }
                $hasher.TransformFinalBlock([byte[]]@(), 0, 0) | Out-Null
                $hex = ([BitConverter]::ToString($hasher.Hash)).Replace('-', '').ToLowerInvariant()
            } finally { $hasher.Dispose() }
            if ($hex -ne $m.sha256.ToLowerInvariant()) { Fail "sha256 mismatch '$($e.FullName)'" }
            if ($isBin) {
                $machine = Get-PeMachineFromHeader -Bytes $head.ToArray()
                if ($machine -ne 0xAA64) { Fail "PE stream bytes not ARM64 '$($e.FullName)'" }
            }
        }
        $leaf = $enc.native_library.Split('/')[-1]
        if (-not $manifest.ContainsKey($leaf)) { Fail "native library '$leaf' not in manifest" }
        $launchProof = if ($ExpectedArtifactMode -eq 'harness') { 'observed' } else { 'not-applicable' }
        Write-Host ("OK files={0} dirs={1} bytes={2} src={3} variant={4} mode={5} build={6} native{7} invalid-launch={8}" -f $manifest.Count, $dirEntries.Count, $totalBytes, $ExpectedSourceSha.Substring(0, 12), $ExpectedVariant, $ExpectedArtifactMode, $wantId, $ExpectedNativeEncoderTestCount, $launchProof)
        return [PSCustomObject]@{
            Files = $manifest.Count; DirEntries = $dirEntries.Count; TotalExpandedBytes = $totalBytes
            Source = $ExpectedSourceSha; Variant = $ExpectedVariant; ArtifactMode = $ExpectedArtifactMode; BuildId = $wantId
        }
    } finally { $zf.Dispose() }
}

if (-not $FunctionsOnlyForTest) {
    if (-not $ArchivePath -or -not $ProvenancePath -or -not $ExpectedArchiveSha256 -or -not $ExpectedSourceSha -or -not $ExpectedPilotSha -or -not $ExpectedVariant) {
        throw 'ArchivePath, ProvenancePath, ExpectedArchiveSha256, ExpectedSourceSha, ExpectedPilotSha, ExpectedVariant are all required.'
    }
    Invoke-VerifyWindowsCloudBundle -ArchivePath $ArchivePath -ProvenancePath $ProvenancePath -ExpectedArchiveSha256 $ExpectedArchiveSha256 -ExpectedSourceSha $ExpectedSourceSha -ExpectedPilotSha $ExpectedPilotSha -ExpectedVariant $ExpectedVariant -ExpectedArtifactMode $ExpectedArtifactMode -ExpectedNativeEncoderTestCount $ExpectedNativeEncoderTestCount | Out-Null
}
