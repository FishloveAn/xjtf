[CmdletBinding()]
param(
    [int] $TimeoutSeconds = 120,
    [string] $GodotBin = $env:GODOT_BIN,
    [switch] $ProtocolSelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$playerCount = 8
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($GodotBin)) {
    $GodotBin = 'C:\Users\668\AppData\Local\CodexTools\Godot\4.7.1\Godot_v4.7.1-stable_win64_console.exe'
}
$GodotBin = [System.IO.Path]::GetFullPath($GodotBin)

function New-IsolatedUdpPort {
    $udp = [System.Net.Sockets.UdpClient]::new(0)
    try { return ([System.Net.IPEndPoint] $udp.Client.LocalEndPoint).Port }
    finally { $udp.Dispose() }
}

function Get-MatchingFileCount {
    param([string] $Directory, [string] $Pattern, [string] $RunId)
    $count = 0
    foreach ($file in @(Get-ChildItem -LiteralPath $Directory -Filter $Pattern -File -ErrorAction SilentlyContinue)) {
        try { $value = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8 | ConvertFrom-Json }
        catch { continue }
        if ($value.run_id -eq $RunId) { $count++ }
    }
    return $count
}

function Test-HordeArtifacts {
    param(
        [string] $Directory,
        [string] $RunId,
        [object[]] $ProcessRows,
        [bool] $TimedOut
    )
    if ($TimedOut -or $ProcessRows.Count -ne $playerCount) { return $false }
    if (@($ProcessRows | Where-Object { $_.ExitCode -ne 0 -or -not $_.Exited -or $_.EngineErrorCount -gt 0 }).Count -gt 0) {
        return $false
    }
    $results = @(Get-ChildItem -LiteralPath $Directory -Filter 'result_*.json' -File -ErrorAction SilentlyContinue)
    if ($results.Count -ne $playerCount) { return $false }
    foreach ($file in $results) {
        try { $result = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8 | ConvertFrom-Json }
        catch { return $false }
        if ($result.run_id -ne $RunId -or $result.pass_count -le 0 -or $result.fail_count -ne 0) { return $false }
        if (@($result.snapshot.psobject.Properties).Count -ne $playerCount) { return $false }
    }
    if ((Get-MatchingFileCount $Directory 'horde_seen_*.json' $RunId) -ne $playerCount) { return $false }
    if ((Get-MatchingFileCount $Directory 'kill_seen_*.json' $RunId) -ne $playerCount) { return $false }
    if ((Get-MatchingFileCount $Directory 'cleanup_seen_*.json' $RunId) -ne $playerCount) { return $false }
    return $true
}

function Invoke-ProtocolSelfTest {
    $directory = Join-Path ([System.IO.Path]::GetTempPath()) ('xjtf_horde_protocol_' + [guid]::NewGuid().ToString('N'))
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    $runId = 'protocol_current'
    $rows = @(1..$playerCount | ForEach-Object {
        [pscustomobject]@{ ExitCode = 0; Exited = $true; EngineErrorCount = 0 }
    })
    try {
        $checks = [ordered]@{}
        $checks['空结果必须失败'] = -not (Test-HordeArtifacts $directory $runId $rows $false)
        $snapshot = [ordered]@{}
        1..$playerCount | ForEach-Object { $snapshot["peer$_"] = "slot$_" }
        0..($playerCount - 1) | ForEach-Object {
            $role = if ($_ -eq 0) { 'server' } else { 'client' }
            @{ run_id = $runId; role = $role; index = $_; pass_count = 1; fail_count = 0; snapshot = $snapshot } |
                ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $directory "result_${role}_$_.json") -Encoding utf8
        }
        $checks['缺少100怪复制证据必须失败'] = -not (Test-HordeArtifacts $directory $runId $rows $false)
        0..($playerCount - 1) | ForEach-Object {
            @{ run_id = $runId; count = 100 } | ConvertTo-Json -Compress |
                Set-Content -LiteralPath (Join-Path $directory "horde_seen_$_.json") -Encoding utf8
        }
        $checks['缺少击杀回落证据必须失败'] = -not (Test-HordeArtifacts $directory $runId $rows $false)
        0..($playerCount - 1) | ForEach-Object {
            @{ run_id = $runId; count = 99 } | ConvertTo-Json -Compress |
                Set-Content -LiteralPath (Join-Path $directory "kill_seen_$_.json") -Encoding utf8
        }
        $checks['缺少资源收尾证据必须失败'] = -not (Test-HordeArtifacts $directory $runId $rows $false)
        0..($playerCount - 1) | ForEach-Object {
            @{ run_id = $runId } | ConvertTo-Json -Compress |
                Set-Content -LiteralPath (Join-Path $directory "cleanup_seen_$_.json") -Encoding utf8
        }
        $checks['完整证据必须通过'] = Test-HordeArtifacts $directory $runId $rows $false
        $badRows = @($rows)
        $badRows[3] = [pscustomobject]@{ ExitCode = 0; Exited = $true; EngineErrorCount = 1 }
        $checks['引擎错误必须失败'] = -not (Test-HordeArtifacts $directory $runId $badRows $false)
        $checks['超时必须失败'] = -not (Test-HordeArtifacts $directory $runId $rows $true)
        foreach ($entry in $checks.GetEnumerator()) {
            $status = if ($entry.Value) { 'PASS' } else { 'FAIL' }
            Write-Host "[HORDE_PROTOCOL][$status] $($entry.Key)"
        }
        return @($checks.Values | Where-Object { -not $_ }).Count -eq 0
    }
    finally {
        Remove-Item -LiteralPath $directory -Recurse -Force
    }
}

function Start-HordePeer {
    param([string] $Role, [int] $Index, [int] $Port, [string] $RunId, [string] $Directory)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $GodotBin
    $psi.WorkingDirectory = $projectRoot
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($argument in @(
        '--headless', '--path', $projectRoot, '--script', 'tools/debug_lan_horde_8.gd', '--',
        "--$Role", "--index=$Index", "--count=$playerCount", "--port=$Port",
        "--run-id=$RunId", "--run-dir=$Directory"
    )) { $psi.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    if (-not $process.Start()) { throw "无法启动 $Role/$Index" }
    return [pscustomobject]@{
        Role = $Role; Index = $Index; Process = $process
        StdoutTask = $process.StandardOutput.ReadToEndAsync()
        StderrTask = $process.StandardError.ReadToEndAsync()
        MaxWorkingSet = [int64] 0; CpuSeconds = 0.0
    }
}

function Update-HordeMetrics {
    param([object[]] $Peers, [string] $RunId)
    $engines = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -like 'Godot*.exe' -and $_.Name -notlike '*console*' -and
        $_.CommandLine -and $_.CommandLine.Contains("--run-id=$RunId")
    })
    foreach ($engine in $engines) {
        if ($engine.CommandLine -notmatch '--index=(\d+)') { continue }
        $peer = $Peers | Where-Object { $_.Index -eq [int] $Matches[1] } | Select-Object -First 1
        $process = Get-Process -Id $engine.ProcessId -ErrorAction SilentlyContinue
        if ($peer -and $process) {
            $peer.MaxWorkingSet = [math]::Max($peer.MaxWorkingSet, $process.WorkingSet64)
            $peer.CpuSeconds = [math]::Max($peer.CpuSeconds, $process.TotalProcessorTime.TotalSeconds)
        }
    }
}

if (-not (Invoke-ProtocolSelfTest)) { exit 2 }
if ($ProtocolSelfTest) { exit 0 }
if (-not (Test-Path -LiteralPath $GodotBin -PathType Leaf)) { throw "Godot 不存在：$GodotBin" }

$runId = 'horde8_' + [guid]::NewGuid().ToString('N')
$runDirectory = Join-Path (Join-Path ([System.IO.Path]::GetTempPath()) 'xjtf_lan_horde_8') $runId
[System.IO.Directory]::CreateDirectory($runDirectory) | Out-Null
$port = New-IsolatedUdpPort
$peers = [System.Collections.Generic.List[object]]::new()
$timedOut = $false
$started = [datetime]::UtcNow
$deadline = $started.AddSeconds($TimeoutSeconds)
try {
    $peers.Add((Start-HordePeer 'server' 0 $port $runId $runDirectory))
    Start-Sleep -Milliseconds 900
    1..($playerCount - 1) | ForEach-Object { $peers.Add((Start-HordePeer 'client' $_ $port $runId $runDirectory)) }
    while (@($peers | Where-Object { -not $_.Process.HasExited }).Count -gt 0) {
        if ([datetime]::UtcNow -ge $deadline) { $timedOut = $true; break }
        Update-HordeMetrics $peers $runId
        Start-Sleep -Milliseconds 500
    }
}
finally {
    foreach ($peer in $peers) { if (-not $peer.Process.HasExited) { $peer.Process.Kill($true) } }
    foreach ($peer in $peers) {
        $peer.Process.WaitForExit(5000) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $runDirectory "$($peer.Role)_$($peer.Index).stdout.log"), $peer.StdoutTask.GetAwaiter().GetResult())
        [System.IO.File]::WriteAllText((Join-Path $runDirectory "$($peer.Role)_$($peer.Index).stderr.log"), $peer.StderrTask.GetAwaiter().GetResult())
    }
}

$processRows = @($peers | ForEach-Object {
    $stderr = [string] (Get-Content -LiteralPath (Join-Path $runDirectory "$($_.Role)_$($_.Index).stderr.log") -Raw)
    [pscustomobject]@{
        Role = $_.Role; Index = $_.Index; Exited = $_.Process.HasExited
        ExitCode = if ($_.Process.HasExited) { $_.Process.ExitCode } else { -999 }
        MaxWorkingSetBytes = $_.MaxWorkingSet; CpuSeconds = [math]::Round($_.CpuSeconds, 3)
        EngineErrorCount = ([regex]::Matches($stderr, '(?m)^(ERROR|SCRIPT ERROR):')).Count
    }
})
$passed = Test-HordeArtifacts $runDirectory $runId $processRows $timedOut
$results = @(Get-ChildItem -LiteralPath $runDirectory -Filter 'result_*.json' -File -ErrorAction SilentlyContinue |
    ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding utf8 | ConvertFrom-Json })
$summary = [pscustomobject]@{
    RunId = $runId; Passed = $passed; TimedOut = $timedOut; Port = $port
    DurationSeconds = [math]::Round(([datetime]::UtcNow - $started).TotalSeconds, 3)
    PassCount = [int] (($results | Measure-Object pass_count -Sum).Sum)
    FailCount = [int] (($results | Measure-Object fail_count -Sum).Sum)
    EngineErrorCount = [int] (($processRows | Measure-Object EngineErrorCount -Sum).Sum)
    TotalCpuSeconds = [double] (($processRows | Measure-Object CpuSeconds -Sum).Sum)
    TotalMaxWorkingSetBytes = [int64] (($processRows | Measure-Object MaxWorkingSetBytes -Sum).Sum)
    EnetSentBytes = [int64] (($results | Measure-Object sent_bytes -Sum).Sum)
    EnetReceivedBytes = [int64] (($results | Measure-Object received_bytes -Sum).Sum)
    EnetSentBytesPerSecond = [double] (($results | Measure-Object sent_bytes_per_second -Sum).Sum)
    EnetReceivedBytesPerSecond = [double] (($results | Measure-Object received_bytes_per_second -Sum).Sum)
    Processes = $processRows; LogDirectory = $runDirectory
}
$summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $runDirectory 'summary.json') -Encoding utf8
$status = if ($passed) { 'PASS' } else { 'FAIL' }
Write-Host "[LAN_HORDE_8][$status] pass/fail=$($summary.PassCount)/$($summary.FailCount) errors=$($summary.EngineErrorCount) CPU=$($summary.TotalCpuSeconds)s WorkingSet=$([math]::Round($summary.TotalMaxWorkingSetBytes/1MB,1))MiB ENet=$($summary.EnetSentBytes)/$($summary.EnetReceivedBytes)B"
Write-Host "  run_id=$runId port=$port logs=$runDirectory"
exit $(if ($passed) { 0 } else { 1 })
