$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$Platform = "windows-x64"
. (Join-Path $PSScriptRoot "portable-env.ps1") -Root $Root -Platform $Platform

$NodeVersion = "v24.15.0"
$NodeZip = "node-$NodeVersion-win-x64.zip"
$NodeUrl = "https://nodejs.org/dist/$NodeVersion/$NodeZip"
$DownloadPath = Join-Path $Root "packages\downloads\$NodeZip"
$NodeFinal = Join-Path $Root "runtime\$Platform"
$NodeExe = Join-Path $NodeFinal "node.exe"
$NpmCmd = Join-Path $NodeFinal "npm.cmd"
$OpenClawPackageRoot = Join-Path $Root "packages\$Platform\openclaw"
$OpenClawEntry = Join-Path $OpenClawPackageRoot "node_modules\openclaw\openclaw.mjs"
$GatewayLog = Join-Path $Root "logs\gateway-windows.log"
$GatewayErrLog = Join-Path $Root "logs\gateway-windows.err.log"

function Write-Step([string]$Text) {
  Write-Host "[portable-openclaw] $Text" -ForegroundColor Cyan
}

function Format-Bytes([double]$Bytes) {
  if ($Bytes -ge 1GB) { return ("{0:N2} GB" -f ($Bytes / 1GB)) }
  if ($Bytes -ge 1MB) { return ("{0:N1} MB" -f ($Bytes / 1MB)) }
  if ($Bytes -ge 1KB) { return ("{0:N1} KB" -f ($Bytes / 1KB)) }
  return ("{0:N0} B" -f $Bytes)
}

function Format-Duration([double]$Seconds) {
  if ($Seconds -lt 0 -or [double]::IsInfinity($Seconds) -or [double]::IsNaN($Seconds)) {
    return "--:--"
  }
  $span = [TimeSpan]::FromSeconds([Math]::Max(0, $Seconds))
  if ($span.TotalHours -ge 1) {
    return "{0:00}:{1:00}:{2:00}" -f [Math]::Floor($span.TotalHours), $span.Minutes, $span.Seconds
  }
  return "{0:00}:{1:00}" -f $span.Minutes, $span.Seconds
}

function Write-LiveStatus([string]$Text) {
  $width = 100
  try {
    if ([Console]::WindowWidth -gt 20) {
      $width = [Console]::WindowWidth - 1
    }
  } catch {
    $width = 100
  }

  if ($Text.Length -gt $width) {
    $Text = $Text.Substring(0, [Math]::Max(0, $width - 3)) + "..."
  }

  [Console]::Write("`r" + $Text.PadRight($width))
}

function Complete-LiveStatus {
  [Console]::WriteLine()
}

function Invoke-PortableDownload([string]$Uri, [string]$OutFile, [string]$Label) {
  Add-Type -AssemblyName System.Net.Http

  $tempFile = "$OutFile.partial"
  Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue

  $client = [System.Net.Http.HttpClient]::new()
  $client.Timeout = [TimeSpan]::FromMinutes(45)
  $response = $client.GetAsync($Uri, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
  $response.EnsureSuccessStatusCode() | Out-Null

  $total = $response.Content.Headers.ContentLength
  $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
  $file = [System.IO.File]::Open($tempFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
  $buffer = New-Object byte[] (1024 * 256)
  $downloaded = [int64]0
  $lastDraw = Get-Date
  $timer = [Diagnostics.Stopwatch]::StartNew()

  try {
    while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
      $file.Write($buffer, 0, $read)
      $downloaded += $read

      $now = Get-Date
      if (($now - $lastDraw).TotalMilliseconds -lt 200 -and $total -and $downloaded -lt $total) {
        continue
      }

      $speed = if ($timer.Elapsed.TotalSeconds -gt 0) { $downloaded / $timer.Elapsed.TotalSeconds } else { 0 }
      if ($total) {
        $percent = [Math]::Min(100, [Math]::Floor(($downloaded / $total) * 100))
        $remaining = [Math]::Max(0, $total - $downloaded)
        $eta = if ($speed -gt 0) { $remaining / $speed } else { -1 }
        $status = "{0}% | {1}/{2} | {3}/s | ETA {4}" -f $percent, (Format-Bytes $downloaded), (Format-Bytes $total), (Format-Bytes $speed), (Format-Duration $eta)
      } else {
        $status = "{0} downloaded | {1}/s" -f (Format-Bytes $downloaded), (Format-Bytes $speed)
      }

      Write-LiveStatus ("[portable-openclaw] {0}  {1}" -f $Label, $status)
      $lastDraw = $now
    }
  } finally {
    $file.Dispose()
    $stream.Dispose()
    $client.Dispose()
    Complete-LiveStatus
  }

  Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
  Move-Item -LiteralPath $tempFile -Destination $OutFile
}

function Format-ProcessArgument([string]$Argument) {
  if ($Argument -notmatch '[\s"]') {
    return $Argument
  }

  return '"' + ($Argument -replace '\\(?=\\*")', '$0$0' -replace '"', '\"') + '"'
}

function Join-ProcessArguments([string[]]$Arguments) {
  return (($Arguments | ForEach-Object { Format-ProcessArgument $_ }) -join " ")
}

function Get-RelativePathText([string]$Path) {
  $relative = Resolve-Path -LiteralPath $Path -Relative -ErrorAction SilentlyContinue
  if ($relative) {
    return $relative
  }
  return $Path
}

function Get-LatestNpmDebugLog {
  $npmDebugRoot = Join-Path $env:npm_config_cache "_logs"
  if (-not (Test-Path -LiteralPath $npmDebugRoot)) {
    return $null
  }

  return Get-ChildItem -LiteralPath $npmDebugRoot -Filter "*-debug-*.log" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
}

function Show-NewLogLines([string]$Path, [ref]$NextLine, [string]$Title) {
  if (-not (Test-Path -LiteralPath $Path)) {
    return $false
  }

  $lines = Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue
  if (-not $lines) {
    return $false
  }

  if ($NextLine.Value -lt 1) {
    $NextLine.Value = 1
  }

  if ($lines.Count -lt $NextLine.Value) {
    $NextLine.Value = 1
  }

  if ($lines.Count -ge $NextLine.Value) {
    Write-Host
    Write-Host "--- ${Title}: $(Get-RelativePathText $Path) ---" -ForegroundColor DarkGray
    for ($i = $NextLine.Value - 1; $i -lt $lines.Count; $i++) {
      Write-Host $lines[$i]
    }
    $NextLine.Value = $lines.Count + 1
    return $true
  }

  return $false
}

function Invoke-PortableProcess([string]$FilePath, [string[]]$Arguments, [string]$StdoutLog, [string]$StderrLog, [string]$Label) {
  Remove-Item -LiteralPath $StdoutLog, $StderrLog -Force -ErrorAction SilentlyContinue

  $timer = [Diagnostics.Stopwatch]::StartNew()
  $process = Start-Process `
    -FilePath $FilePath `
    -ArgumentList (Join-ProcessArguments $Arguments) `
    -WorkingDirectory $Root `
    -RedirectStandardOutput $StdoutLog `
    -RedirectStandardError $StderrLog `
    -WindowStyle Hidden `
    -PassThru

  $showLogs = $false
  $printedWaitingForLogs = $false
  $stdoutNextLine = 1
  $stderrNextLine = 1

  while (-not $process.HasExited) {
    $elapsed = [Math]::Floor($timer.Elapsed.TotalSeconds)
    $relativeLog = Get-RelativePathText $StdoutLog

    try {
      if ([Console]::KeyAvailable) {
        $key = [Console]::ReadKey($true)
        if ($key.KeyChar -eq 'l' -or $key.KeyChar -eq 'L') {
          if (-not $showLogs) {
            $showLogs = $true
            $printedWaitingForLogs = $false
            Complete-LiveStatus
            Write-Host "--- install logs, H to hide ---" -ForegroundColor DarkGray
            Write-Host "Showing npm output/errors. Full npm debug log is shown only if install fails." -ForegroundColor DarkGray
          }
        } elseif ($key.KeyChar -eq 'h' -or $key.KeyChar -eq 'H') {
          if ($showLogs) {
            $showLogs = $false
            Complete-LiveStatus
            Write-Host "--- logs hidden ---" -ForegroundColor DarkGray
          }
        }
      }
    } catch {
      $showLogs = $false
    }

    if ($showLogs) {
      $printedAnyLine = $false

      if (Show-NewLogLines -Path $StdoutLog -NextLine ([ref]$stdoutNextLine) -Title "npm output") {
        $printedAnyLine = $true
      }
      if (Show-NewLogLines -Path $StderrLog -NextLine ([ref]$stderrNextLine) -Title "npm errors") {
        $printedAnyLine = $true
      }

      if (-not $printedAnyLine -and -not $printedWaitingForLogs) {
        Write-Host "Waiting for npm output..."
        $printedWaitingForLogs = $true
      }
      Write-LiveStatus ("[portable-openclaw] {0} | {1} | H hide" -f $Label, (Format-Duration $elapsed))
    } else {
      $status = "{0} | L logs | {1}" -f (Format-Duration $elapsed), $relativeLog
      Write-LiveStatus ("[portable-openclaw] {0} | {1}" -f $Label, $status)
    }

    Start-Sleep -Milliseconds 500
    $process.Refresh()
  }

  $process.WaitForExit()
  $process.Refresh()
  Complete-LiveStatus

  $exitCode = $process.ExitCode
  if ($null -eq $exitCode -and $Label -eq "Installing OpenClaw" -and (Test-Path -LiteralPath $OpenClawEntry)) {
    $exitCode = 0
  }

  if ($exitCode -ne 0) {
    Write-Host "$Label failed. Last log lines:" -ForegroundColor Red
    foreach ($log in @($StderrLog, $StdoutLog)) {
      if (Test-Path -LiteralPath $log) {
        Write-Host "--- $log ---" -ForegroundColor DarkGray
        Get-Content -LiteralPath $log -Tail 25
      }
    }
    $npmDebugRoot = Join-Path $env:npm_config_cache "_logs"
    if (Test-Path -LiteralPath $npmDebugRoot) {
      $latestDebugLog = Get-ChildItem -LiteralPath $npmDebugRoot -Filter "*-debug-*.log" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
      if ($latestDebugLog) {
        Write-Host "--- npm debug log: $($latestDebugLog.FullName) ---" -ForegroundColor DarkGray
        Get-Content -LiteralPath $latestDebugLog.FullName -Tail 60
      }
    }
    throw "$Label failed with exit code $exitCode"
  }
}

function Install-NodeIfNeeded {
  if (Test-Path -LiteralPath $NodeExe) {
    Write-Step "Portable Node already exists for $Platform"
    return
  }

  Write-Step "Downloading portable Node $NodeVersion for $Platform"
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $DownloadPath), (Join-Path $Root "runtime") | Out-Null
  Invoke-PortableDownload -Uri $NodeUrl -OutFile $DownloadPath -Label "Downloading Node"

  Write-Step "Extracting portable Node"
  $extractParent = Join-Path $Root "runtime"
  Expand-Archive -LiteralPath $DownloadPath -DestinationPath $extractParent -Force
  $extracted = Join-Path $extractParent "node-$NodeVersion-win-x64"
  Remove-Item -LiteralPath $NodeFinal -Recurse -Force -ErrorAction SilentlyContinue
  Move-Item -LiteralPath $extracted -Destination $NodeFinal
}

function Install-OpenClawIfNeeded {
  if (Test-Path -LiteralPath $OpenClawEntry) {
    Write-Step "Portable OpenClaw already exists for $Platform"
    return
  }

  if (-not (Test-Path -LiteralPath $NpmCmd)) {
    throw "Portable npm not found at $NpmCmd"
  }

  Write-Step "Installing OpenClaw into USB package folder for $Platform"
  Invoke-PortableProcess `
    -FilePath $NpmCmd `
    -Arguments @("install", "--prefix", $OpenClawPackageRoot, "openclaw@latest", "--ignore-scripts", "--loglevel=info", "--progress=false") `
    -StdoutLog (Join-Path $Root "logs\npm-install-$Platform.out.log") `
    -StderrLog (Join-Path $Root "logs\npm-install-$Platform.err.log") `
    -Label "Installing OpenClaw"
}

function Invoke-OpenClaw([string[]]$Arguments) {
  if (-not (Test-Path -LiteralPath $OpenClawEntry)) {
    throw "Portable OpenClaw is not installed at $OpenClawEntry"
  }
  & $NodeExe $OpenClawEntry @Arguments
}

function Get-PortableGatewaySettings {
  $settings = [ordered]@{
    Port = "18789"
    Bind = "loopback"
    AuthMode = "none"
    Token = $null
    Password = $null
  }

  try {
    if (Test-Path -LiteralPath $env:OPENCLAW_CONFIG_PATH) {
      $config = Get-Content -LiteralPath $env:OPENCLAW_CONFIG_PATH -Raw | ConvertFrom-Json
      if ($config.gateway.port) { $settings.Port = [string]$config.gateway.port }
      if ($config.gateway.bind) { $settings.Bind = [string]$config.gateway.bind }
      if ($config.gateway.auth.mode) { $settings.AuthMode = [string]$config.gateway.auth.mode }
      if ($config.gateway.auth.token) { $settings.Token = [string]$config.gateway.auth.token }
      if ($config.gateway.auth.password) { $settings.Password = [string]$config.gateway.auth.password }
    }
  } catch {
    Write-Host "Could not read gateway config; using portable defaults." -ForegroundColor Yellow
  }

  return [pscustomobject]$settings
}

function Get-GatewayRunArguments {
  $settings = Get-PortableGatewaySettings
  $arguments = @("gateway", "run", "--port", $settings.Port, "--bind", $settings.Bind, "--auth", $settings.AuthMode, "--verbose")

  if ($settings.AuthMode -eq "token" -and $settings.Token) {
    $arguments += @("--token", $settings.Token)
  } elseif ($settings.AuthMode -eq "password" -and $settings.Password) {
    $arguments += @("--password", $settings.Password)
  }

  return $arguments
}

function Get-GatewayHealthArguments {
  $settings = Get-PortableGatewaySettings
  $arguments = @("gateway", "health", "--timeout", "2500")

  if ($settings.AuthMode -eq "token" -and $settings.Token) {
    $arguments += @("--token", $settings.Token)
  } elseif ($settings.AuthMode -eq "password" -and $settings.Password) {
    $arguments += @("--password", $settings.Password)
  }

  return $arguments
}

function Add-GatewayClientAuthArguments([string[]]$Arguments) {
  $settings = Get-PortableGatewaySettings
  $out = @($Arguments)

  if ($settings.AuthMode -eq "token" -and $settings.Token -and -not ($out -contains "--token")) {
    $out += @("--token", $settings.Token)
  } elseif ($settings.AuthMode -eq "password" -and $settings.Password -and -not ($out -contains "--password")) {
    $out += @("--password", $settings.Password)
  }

  return $out
}

function Split-CommandLine([string]$CommandLine) {
  $tokens = New-Object System.Collections.Generic.List[string]
  $current = New-Object System.Text.StringBuilder
  $quote = [char]0

  foreach ($char in $CommandLine.ToCharArray()) {
    if ($quote -ne [char]0) {
      if ($char -eq $quote) {
        $quote = [char]0
      } else {
        [void]$current.Append($char)
      }
      continue
    }
    if ($char -eq '"' -or $char -eq "'") {
      $quote = $char
      continue
    }
    if ([char]::IsWhiteSpace($char)) {
      if ($current.Length -gt 0) {
        $tokens.Add($current.ToString())
        [void]$current.Clear()
      }
      continue
    }
    [void]$current.Append($char)
  }

  if ($current.Length -gt 0) {
    $tokens.Add($current.ToString())
  }

  return [string[]]$tokens.ToArray()
}

function Invoke-OpenClawCommandPrompt {
  Write-Host
  Write-Host "Paste OpenClaw command, for example:" -ForegroundColor DarkGray
  Write-Host "openclaw pairing approve telegram R2F8ZL5S" -ForegroundColor DarkGray
  $commandText = (Read-Host "Command").Trim()
  if (-not $commandText) {
    return
  }

  $arguments = @(Split-CommandLine $commandText)
  if ($arguments.Count -gt 0 -and $arguments[0].ToLowerInvariant() -eq "openclaw") {
    if ($arguments.Count -eq 1) {
      $arguments = @()
    } else {
      $arguments = $arguments[1..($arguments.Count - 1)]
    }
  }
  if ($arguments.Count -eq 0) {
    return
  }

  Write-Host
  Write-Host "[portable-openclaw] Running OpenClaw command live. Press Ctrl+C to stop it." -ForegroundColor Cyan
  & $NodeExe $OpenClawEntry @arguments
  $exitCode = $LASTEXITCODE
  if ($exitCode -ne 0) {
    Write-Host "OpenClaw command exited with code $exitCode." -ForegroundColor Yellow
  }
}

function Test-GatewayPort {
  $settings = Get-PortableGatewaySettings
  try {
    $client = New-Object Net.Sockets.TcpClient
    $iar = $client.BeginConnect("127.0.0.1", ([int]$settings.Port), $null, $null)
    $ok = $iar.AsyncWaitHandle.WaitOne(500, $false)
    if ($ok) { $client.EndConnect($iar) }
    $client.Close()
    return $ok
  } catch {
    return $false
  }
}

function Test-GatewayHealthy {
  if (-not (Test-GatewayPort)) { return $false }
  try {
    Invoke-OpenClaw (Get-GatewayHealthArguments) *> $null
    return ($LASTEXITCODE -eq 0)
  } catch {
    return $false
  }
}

function Test-GatewayReadyFromLog {
  if (-not (Test-GatewayPort)) { return $false }
  if (-not (Test-Path -LiteralPath $GatewayLog)) { return $false }

  $tail = Get-Content -LiteralPath $GatewayLog -Tail 80 -ErrorAction SilentlyContinue
  return [bool]($tail | Where-Object { $_ -match "\[gateway\].*ready" } | Select-Object -Last 1)
}

function Stop-Gateway {
  $processes = @(Get-Process node -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -like "*runtime\$Platform*" })

  if ($processes.Count -eq 0) {
    Write-Host "Gateway is not running." -ForegroundColor Yellow
    return
  }

  Write-Step "Stopping Gateway process(es): $($processes.Id -join ', ')"
  $processes | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 500

  if (Test-GatewayPort) {
    Write-Host "Gateway port is still open after stop attempt." -ForegroundColor Yellow
  } else {
    Write-Host "Gateway stopped." -ForegroundColor Green
  }
}

function Show-GatewayLogTail {
  $shown = $false
  if (Test-Path -LiteralPath $GatewayLog) {
    Write-Host
    Write-Host "--- OpenClaw Gateway log: logs\gateway-windows.log ---" -ForegroundColor DarkGray
    Get-Content -LiteralPath $GatewayLog -Tail 40
    Write-Host "--- end gateway log ---" -ForegroundColor DarkGray
    $shown = $true
  }
  if (Test-Path -LiteralPath $GatewayErrLog) {
    Write-Host
    Write-Host "--- OpenClaw Gateway errors: logs\gateway-windows.err.log ---" -ForegroundColor DarkGray
    Get-Content -LiteralPath $GatewayErrLog -Tail 40
    Write-Host "--- end gateway errors ---" -ForegroundColor DarkGray
    $shown = $true
  }
  $nativeLog = Get-ChildItem -LiteralPath (Join-Path $Root "data\temp\openclaw") -Filter "openclaw-*.log" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  if ($nativeLog) {
    Write-Host
    Write-Host "--- OpenClaw native log: $($nativeLog.FullName) ---" -ForegroundColor DarkGray
    Get-Content -LiteralPath $nativeLog.FullName -Tail 40
    Write-Host "--- end native log ---" -ForegroundColor DarkGray
    $shown = $true
  }
  if (-not $shown) {
    Write-Host
    Write-Host "No Gateway log files were created." -ForegroundColor Yellow
  }
}

function Get-GatewayStartupMilestone {
  if (-not (Test-Path -LiteralPath $GatewayLog)) {
    return $null
  }

  $tail = Get-Content -LiteralPath $GatewayLog -Tail 25 -ErrorAction SilentlyContinue
  foreach ($pattern in @(
    "ready",
    "http server listening",
    "starting channels and sidecars",
    "loaded .* plugin",
    "starting HTTP server",
    "starting..."
  )) {
    $match = $tail | Where-Object { $_ -match $pattern } | Select-Object -Last 1
    if ($match) { return ($match -replace "`e\[[0-9;]*m", "") }
  }

  return $null
}

function Start-Gateway([switch]$Force) {
  if ($Force) {
    Stop-Gateway
    Start-Sleep -Milliseconds 500
  } elseif (Test-GatewayHealthy) {
    Write-Step "Gateway already running and healthy"
    return $true
  } elseif (Test-GatewayPort) {
    Write-Host "Gateway is running but not healthy. Restarting portable Gateway." -ForegroundColor Yellow
    Stop-Gateway
    Start-Sleep -Milliseconds 500
  }

  Write-Step "Starting Gateway"
  Remove-Item -LiteralPath $GatewayLog, $GatewayErrLog -Force -ErrorAction SilentlyContinue
  Start-Process `
    -FilePath $NodeExe `
    -ArgumentList (Join-ProcessArguments (@($OpenClawEntry) + (Get-GatewayRunArguments))) `
    -WorkingDirectory $Root `
    -RedirectStandardOutput $GatewayLog `
    -RedirectStandardError $GatewayErrLog `
    -WindowStyle Hidden `
    -PassThru | Out-Null

  $deadline = (Get-Date).AddSeconds(120)
  $lastStatus = -1
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    if (Test-GatewayReadyFromLog) {
      Show-GatewayLogTail
      return $true
    }

    $elapsed = [Math]::Floor(120 - ($deadline - (Get-Date)).TotalSeconds)
    if ($elapsed -ge 0 -and ($elapsed % 10) -eq 0 -and $elapsed -ne $lastStatus) {
      $lastStatus = $elapsed
      $milestone = Get-GatewayStartupMilestone
      if ($milestone) {
        Write-Host ("Waiting for Gateway startup... {0}s/120s | {1}" -f $elapsed, $milestone) -ForegroundColor DarkGray
      } else {
        Write-Host ("Waiting for Gateway startup... {0}s/120s" -f $elapsed) -ForegroundColor DarkGray
      }
    }
  }

  Write-Host "Gateway did not become healthy within 120s. Check logs\gateway-windows.log and logs\gateway-windows.err.log" -ForegroundColor Yellow
  Show-GatewayLogTail
  return $false
}

function Show-Header {
  Clear-Host
  Write-Host "Portable OpenClaw" -ForegroundColor Cyan
  Write-Host ("-" * 72) -ForegroundColor DarkGray
  Write-Host "Root      $Root"
  Write-Host "Platform  $Platform"
  Write-Host "Data      $env:OPENCLAW_STATE_DIR"
  Write-Host "Workspace $env:OPENCLAW_PORTABLE_WORKSPACE"
  $gateway = if (Test-GatewayPort) { "RUNNING" } else { "STOPPED" }
  Write-Host "Gateway   $gateway"
  Write-Host ("-" * 72) -ForegroundColor DarkGray
}

function Pause-Menu {
  Write-Host
  Read-Host "Press Enter to continue" | Out-Null
}

function Show-ToolsMenu {
  while ($true) {
    Show-Header
    Write-Host "Tools"
    Write-Host
    Write-Host "1. Full Setup"
    Write-Host "2. Health Check / Repair"
    Write-Host "3. Status"
    Write-Host "4. Sessions"
    Write-Host "5. Channels"
    Write-Host "6. Logs"
    Write-Host "7. Update"
    Write-Host "8. Stop Gateway"
    Write-Host "9. Run OpenClaw Command"
    Write-Host "0. Back"
    Write-Host

    $choice = Read-Host "Select"
    switch ($choice) {
      "1" { Invoke-OpenClaw @("configure"); Start-Gateway -Force; Pause-Menu }
      "2" { Invoke-OpenClaw @("doctor"); Pause-Menu }
      "3" { Invoke-OpenClaw @("status"); Pause-Menu }
      "4" { Invoke-OpenClaw @("sessions"); Pause-Menu }
      "5" { Invoke-OpenClaw @("channels", "status"); Pause-Menu }
      "6" { Show-GatewayLogTail; Pause-Menu }
      "7" { & $NpmCmd install --prefix $OpenClawPackageRoot openclaw@latest --ignore-scripts --loglevel=info --progress=false; Pause-Menu }
      "8" { Stop-Gateway; Pause-Menu }
      "9" { Invoke-OpenClawCommandPrompt; Pause-Menu }
      "0" { return }
      default { Write-Host "Invalid option" -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
    }
  }
}

Install-NodeIfNeeded
. (Join-Path $PSScriptRoot "portable-env.ps1") -Root $Root -Platform $Platform
Install-OpenClawIfNeeded

Write-Step "Portable runtime ready"
& $NodeExe --version
& $NpmCmd --version
Invoke-OpenClaw @("--version")
Start-Sleep -Seconds 1

while ($true) {
  Show-Header
  Write-Host "1. Setup / Change AI"
  Write-Host "2. Chat"
  Write-Host "3. Dashboard"
  Write-Host "4. Tools"
  Write-Host "5. Stop Gateway"
  Write-Host "0. Exit"
  Write-Host

  $choice = Read-Host "Select"
  switch ($choice) {
    "1" { Invoke-OpenClaw @("configure", "--section", "model"); [void](Start-Gateway -Force); Pause-Menu }
    "2" { if (Start-Gateway) { Invoke-OpenClaw (Add-GatewayClientAuthArguments @("tui")) }; Pause-Menu }
    "3" { if (Start-Gateway) { Invoke-OpenClaw @("dashboard") }; Pause-Menu }
    "4" { Show-ToolsMenu }
    "5" { Stop-Gateway; Pause-Menu }
    "0" { exit 0 }
    default { Write-Host "Invalid option" -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
  }
}
