[CmdletBinding()]
param(
    [string] $ArchivePath,
    [string] $ProvenancePath,
    [string] $ExpectedArchiveSha256,
    [string] $ExpectedSourceSha,
    [string] $ExpectedPilotSha,
    [string] $ExpectedVariant,
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
        [Parameter(Mandatory)][string] $ExpectedVariant
    )
    foreach ($p in @($ArchivePath, $ProvenancePath)) { if (-not (Test-Path -LiteralPath $p)) { Fail "missing input $p" } }
    $actualArchiveHash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualArchiveHash -ne $ExpectedArchiveSha256.ToLowerInvariant()) { Fail 'archive SHA256 mismatch' }
    $prov = Get-Content -LiteralPath $ProvenancePath -Raw | ConvertFrom-Json
    # Unknown non-security provenance keys are preserved (ignored); only required fields assert.
    if ($prov.schema_version -ne 1) { Fail 'provenance schema_version must be 1' }
    if ($prov.source_commit -ne $ExpectedSourceSha) { Fail 'provenance source_commit mismatch' }
    if ($prov.sidecar_commit -ne $ExpectedPilotSha) { Fail 'provenance sidecar (pilot) commit mismatch' }
    $allowedVariants = @('local-write', 'read-only')
    if ($allowedVariants -cnotcontains $ExpectedVariant) { Fail "variant '$ExpectedVariant' not allowed" }
    if ($prov.build.variant -cne $ExpectedVariant) { Fail 'provenance build.variant mismatch' }
    # Exact per-variant mapping mirrors Get-HarnessConfigurationIdentifier: writer/replay take a
    # suffix, the read-only default is the bare 12-char source identifier.
    $wantId = $ExpectedSourceSha.Substring(0, 12)
    if ($ExpectedVariant -cne 'read-only') { $wantId += '-' + $ExpectedVariant }
    if ($prov.build.build_identifier -cne $wantId) { Fail "build_identifier must be '$wantId'" }
    $wantWriter = ($ExpectedVariant -ceq 'local-write')
    if (($prov.build.writer_defines_present -isnot [bool]) -or ($prov.build.writer_defines_present -ne $wantWriter)) { Fail 'build.writer_defines_present must be boolean matching variant' }
    if (($prov.build.automatic_send_runtime_present -isnot [bool]) -or ($prov.build.automatic_send_runtime_present -ne $false)) { Fail 'build.automatic_send_runtime_present must be boolean false' }
    $v = $prov.verification
    if ($v.powershell_contract_tests -ne 'passed') { Fail 'powershell_contract_tests not passed' }
    if ($v.focused_dart_tests -ne 'passed') { Fail 'focused_dart_tests not passed' }
    if (($v.all_pe_files_arm64 -isnot [bool]) -or ($v.all_pe_files_arm64 -ne $true)) { Fail 'all_pe_files_arm64 must be boolean true' }
    if ($v.rust_bridge_load_unload -ne 'passed') { Fail 'rust_bridge_load_unload not passed' }
    $enc = $v.native_local_write_encoder_tests
    if ($enc.result -ne 'passed') { Fail 'native encoder tests not passed' }
    if ($enc.expected_test_count -ne 48) { Fail 'native encoder expected_test_count must be 48' }
    if (($enc.full_file_run -isnot [bool]) -or ($enc.full_file_run -ne $true)) { Fail 'native encoder full_file_run must be boolean true' }
    if ($enc.native_library -cne 'bundle/rust_lib_bluebubbles.dll') { Fail 'native_library must be exactly bundle/rust_lib_bluebubbles.dll' }
    $inv = $v.invalid_launch_diagnostic
    if ($inv.expected_dart_marker -ne 'cloud_sync_windows_dev_launch_id_invalid') { Fail 'invalid-launch marker mismatch' }
    if ((($inv.expected_dart_marker_seen -isnot [bool]) -or ($inv.expected_dart_marker_seen -ne $true)) -or ($inv.proof_status -ne 'observed')) { Fail 'invalid-launch not observed' }
    if ((($inv.network_or_auth_requested -isnot [bool]) -or ($inv.network_or_auth_requested -ne $false)) -or ((($inv.profile_state_written -isnot [bool]) -or ($inv.profile_state_written -ne $false)))) { Fail 'invalid-launch side-effect flags unexpected' }
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
        Write-Host ("OK files={0} dirs={1} bytes={2} src={3} variant={4} build={5} native48 invalid-launch=observed" -f $manifest.Count, $dirEntries.Count, $totalBytes, $ExpectedSourceSha.Substring(0, 12), $ExpectedVariant, $wantId)
        return [PSCustomObject]@{
            Files = $manifest.Count; DirEntries = $dirEntries.Count; TotalExpandedBytes = $totalBytes
            Source = $ExpectedSourceSha; Variant = $ExpectedVariant; BuildId = $wantId
        }
    } finally { $zf.Dispose() }
}

if (-not $FunctionsOnlyForTest) {
    if (-not $ArchivePath -or -not $ProvenancePath -or -not $ExpectedArchiveSha256 -or -not $ExpectedSourceSha -or -not $ExpectedPilotSha -or -not $ExpectedVariant) {
        throw 'ArchivePath, ProvenancePath, ExpectedArchiveSha256, ExpectedSourceSha, ExpectedPilotSha, ExpectedVariant are all required.'
    }
    Invoke-VerifyWindowsCloudBundle -ArchivePath $ArchivePath -ProvenancePath $ProvenancePath -ExpectedArchiveSha256 $ExpectedArchiveSha256 -ExpectedSourceSha $ExpectedSourceSha -ExpectedPilotSha $ExpectedPilotSha -ExpectedVariant $ExpectedVariant | Out-Null
}
