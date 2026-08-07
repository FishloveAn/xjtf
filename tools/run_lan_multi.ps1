[CmdletBinding()]
param(
    [ValidateSet(4, 8)]
    [int[]] $PlayerCount = @(4, 8),
    [int] $TimeoutSeconds = 90,
    [string] $GodotBin = $env:GODOT_BIN,
    [switch] $ProtocolSelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$defaultGodot = 'C:\Users\668\AppData\Local\CodexTools\Godot\4.7.1\Godot_v4.7.1-stable_win64_console.exe'
if ([string]::IsNullOrWhiteSpace($GodotBin)) {
    $GodotBin = $defaultGodot
}
$GodotBin = [System.IO.Path]::GetFullPath($GodotBin)

function New-IsolatedUdpPort {
    $udp = [System.Net.Sockets.UdpClient]::new(0)
    try {
        return ([System.Net.IPEndPoint] $udp.Client.LocalEndPoint).Port
    }
    finally {
        $udp.Dispose()
    }
}

function Test-RunArtifacts {
    param(
        [Parameter(Mandatory)] [string] $RunDirectory,
        [Parameter(Mandatory)] [string] $RunId,
        [Parameter(Mandatory)] [int] $ExpectedCount,
        [Parameter(Mandatory)] [object[]] $ProcessRows,
        [Parameter(Mandatory)] [bool] $TimedOut
    )

    if ($TimedOut -or $ProcessRows.Count -ne $ExpectedCount) {
        return $false
    }
    if (@($ProcessRows | Where-Object {
        $_.ExitCode -ne 0 -or -not $_.Exited -or
        ($_.PSObject.Properties['EngineErrorCount'] -and $_.EngineErrorCount -gt 0)
    }).Count -gt 0) {
        return $false
    }
    $files = @(Get-ChildItem -LiteralPath $RunDirectory -Filter 'result_*.json' -File -ErrorAction SilentlyContinue)
    if ($files.Count -ne $ExpectedCount) {
        return $false
    }
    $results = @()
    foreach ($file in $files) {
        try {
            $result = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8 | ConvertFrom-Json
        }
        catch {
            return $false
        }
        if ($result.run_id -ne $RunId -or $result.pass_count -le 0 -or $result.fail_count -ne 0) {
            return $false
        }
        $results += $result
    }
    $server = @($results | Where-Object { $_.role -eq 'server' })
    if ($server.Count -ne 1) {
        return $false
    }
    $serverSnapshot = $server[0].snapshot | ConvertTo-Json -Compress
    foreach ($result in $results) {
        if (@($result.snapshot.psobject.Properties).Count -ne $ExpectedCount) {
            return $false
        }
        if (($result.snapshot | ConvertTo-Json -Compress) -ne $serverSnapshot) {
            return $false
        }
    }
    return $true
}

function Invoke-ProtocolSelfTest {
    $base = Join-Path ([System.IO.Path]::GetTempPath()) ('xjtf_lan_multi_protocol_' + [guid]::NewGuid().ToString('N'))
    [System.IO.Directory]::CreateDirectory($base) | Out-Null
    try {
        $goodRows = 1..4 | ForEach-Object { [pscustomobject]@{ ExitCode = 0; Exited = $true; EngineErrorCount = 0 } }
        $checks = [ordered]@{}
        $checks['空结果必须失败'] = -not (Test-RunArtifacts $base 'new' 4 $goodRows $false)
        '{"run_id":"old","role":"server","pass_count":1,"fail_count":0}' |
            Set-Content -LiteralPath (Join-Path $base 'result_server_0.json') -Encoding utf8
        $checks['旧 run_id 必须失败'] = -not (Test-RunArtifacts $base 'new' 4 $goodRows $false)
        $badRows = @($goodRows)
        $badRows[2] = [pscustomobject]@{ ExitCode = 3; Exited = $true; EngineErrorCount = 0 }
        $checks['任一进程异常必须失败'] = -not (Test-RunArtifacts $base 'new' 4 $badRows $false)
        $checks['超时必须失败'] = -not (Test-RunArtifacts $base 'new' 4 $goodRows $true)
        foreach ($entry in $checks.GetEnumerator()) {
            $status = if ($entry.Value) { 'PASS' } else { 'FAIL' }
            Write-Host "[PROTOCOL][$status] $($entry.Key)"
        }
        return @($checks.Values | Where-Object { -not $_ }).Count -eq 0
    }
    finally {
        Remove-Item -LiteralPath $base -Recurse -Force
    }
}

function Start-GodotPeer {
    param(
        [string] $Role,
        [int] $Index,
        [int] $Count,
        [int] $Port,
        [string] $RunId,
        [string] $RunDirectory
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $GodotBin
    $psi.WorkingDirectory = $projectRoot
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($argument in @(
        '--headless', '--path', $projectRoot, '--script', 'tools/debug_lan_multi.gd', '--',
        "--$Role", "--index=$Index", "--count=$Count", "--port=$Port",
        "--run-id=$RunId", "--run-dir=$RunDirectory"
    )) {
        $psi.ArgumentList.Add($argument)
    }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    if (-not $process.Start()) {
        throw "无法启动 $Role/$Index"
    }
    return [pscustomobject]@{
        Role = $Role
        Index = $Index
        Process = $process
        StdoutTask = $process.StandardOutput.ReadToEndAsync()
        StderrTask = $process.StandardError.ReadToEndAsync()
        MaxWorkingSet = [int64] 0
        CpuSeconds = 0.0
    }
}

function Update-PeerMetrics {
    param(
        [Parameter(Mandatory)] [object[]] $Peers,
        [Parameter(Mandatory)] [string] $RunId
    )

    # Godot 的 console.exe 是轻量包装器；资源数据应读取它启动的非 console 引擎进程。
    $engines = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -like 'Godot*.exe' -and $_.Name -notlike '*console*' -and
        $_.CommandLine -and $_.CommandLine.Contains("--run-id=$RunId")
    })
    foreach ($engine in $engines) {
        if ($engine.CommandLine -notmatch '--index=(\d+)') {
            continue
        }
        $index = [int] $Matches[1]
        $peer = $Peers | Where-Object { $_.Index -eq $index } | Select-Object -First 1
        if (-not $peer) {
            continue
        }
        $process = Get-Process -Id $engine.ProcessId -ErrorAction SilentlyContinue
        if ($process) {
            $peer.MaxWorkingSet = [math]::Max($peer.MaxWorkingSet, $process.WorkingSet64)
            $peer.CpuSeconds = [math]::Max($peer.CpuSeconds, $process.TotalProcessorTime.TotalSeconds)
        }
    }
}

function Invoke-LanMultiRun {
    param([int] $Count)

    $runId = "n${Count}_" + [guid]::NewGuid().ToString('N')
    $runRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'xjtf_lan_multi'
    $runDirectory = Join-Path $runRoot $runId
    [System.IO.Directory]::CreateDirectory($runDirectory) | Out-Null
    $port = New-IsolatedUdpPort
    $peers = [System.Collections.Generic.List[object]]::new()
    $timedOut = $false
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    try {
        $peers.Add((Start-GodotPeer 'server' 0 $Count $port $runId $runDirectory))
        Start-Sleep -Milliseconds 800
        for ($index = 1; $index -lt $Count; $index++) {
            $peers.Add((Start-GodotPeer 'client' $index $Count $port $runId $runDirectory))
        }
        while (@($peers | Where-Object { -not $_.Process.HasExited }).Count -gt 0) {
            if ([datetime]::UtcNow -ge $deadline) {
                $timedOut = $true
                break
            }
            Update-PeerMetrics $peers $runId
            Start-Sleep -Milliseconds 500
        }
    }
    finally {
        foreach ($peer in $peers) {
            if (-not $peer.Process.HasExited) {
                $peer.Process.Kill($true)
            }
        }
        foreach ($peer in $peers) {
            $peer.Process.WaitForExit(5000) | Out-Null
            $stdout = $peer.StdoutTask.GetAwaiter().GetResult()
            $stderr = $peer.StderrTask.GetAwaiter().GetResult()
            [System.IO.File]::WriteAllText((Join-Path $runDirectory "$($peer.Role)_$($peer.Index).stdout.log"), $stdout)
            [System.IO.File]::WriteAllText((Join-Path $runDirectory "$($peer.Role)_$($peer.Index).stderr.log"), $stderr)
        }
    }

    $processRows = @($peers | ForEach-Object {
        $stderrPath = Join-Path $runDirectory "$($_.Role)_$($_.Index).stderr.log"
        $stderrText = [string] $(if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { '' })
        [pscustomobject]@{
            Role = $_.Role
            Index = $_.Index
            ExitCode = if ($_.Process.HasExited) { $_.Process.ExitCode } else { -999 }
            Exited = $_.Process.HasExited
            MaxWorkingSetBytes = $_.MaxWorkingSet
            CpuSeconds = [math]::Round($_.CpuSeconds, 3)
            EngineErrorCount = ([regex]::Matches($stderrText, '(?m)^(ERROR|SCRIPT ERROR):')).Count
        }
    })
    $ok = Test-RunArtifacts $runDirectory $runId $Count $processRows $timedOut
    $results = @(Get-ChildItem -LiteralPath $runDirectory -Filter 'result_*.json' -File -ErrorAction SilentlyContinue |
        ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding utf8 | ConvertFrom-Json })
    $summary = [pscustomobject]@{
        RunId = $runId
        PlayerCount = $Count
        Port = $port
        Passed = $ok
        TimedOut = $timedOut
        DurationSeconds = [math]::Round(($TimeoutSeconds - [math]::Max(0, ($deadline - [datetime]::UtcNow).TotalSeconds)), 3)
        TotalMaxWorkingSetBytes = [int64] (($processRows | Measure-Object MaxWorkingSetBytes -Sum).Sum)
        TotalCpuSeconds = [double] (($processRows | Measure-Object CpuSeconds -Sum).Sum)
        EnetSentBytes = [int64] (($results | Measure-Object sent_bytes -Sum).Sum)
        EnetReceivedBytes = [int64] (($results | Measure-Object received_bytes -Sum).Sum)
        Processes = $processRows
        LogDirectory = $runDirectory
    }
    $summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $runDirectory 'summary.json') -Encoding utf8
    $status = if ($ok) { 'PASS' } else { 'FAIL' }
    Write-Host "[LAN_MULTI][$status] ${Count}人 port=$port CPU=$($summary.TotalCpuSeconds)s WorkingSet=$([math]::Round($summary.TotalMaxWorkingSetBytes / 1MB, 1))MiB ENet sent/recv=$($summary.EnetSentBytes)/$($summary.EnetReceivedBytes) bytes"
    Write-Host "  日志：$runDirectory"
    return $summary
}

$protocolOk = Invoke-ProtocolSelfTest
if (-not $protocolOk) {
    exit 2
}
if ($ProtocolSelfTest) {
    exit 0
}
if (-not (Test-Path -LiteralPath $GodotBin -PathType Leaf)) {
    throw "Godot 控制台程序不存在：$GodotBin"
}

$summaries = @($PlayerCount | ForEach-Object { Invoke-LanMultiRun $_ })
if (@($summaries | Where-Object { -not $_.Passed }).Count -gt 0) {
    exit 1
}
exit 0
