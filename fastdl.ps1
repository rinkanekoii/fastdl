$script:DataDir = Join-Path $env:APPDATA "FastDL"
$script:TempDir = Join-Path $env:TEMP "fastdl_session"
$script:Aria2Path = Join-Path $script:DataDir "aria2c.exe"
$script:Aria2Url = "https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0-win-64bit-build1.zip"

function Write-Status {
    param([string]$Msg, [ValidateSet('Info','OK','Warn','Err','Run')]$Type = 'Info')
    $c = @{ Info='Gray'; OK='Green'; Warn='Yellow'; Err='Red'; Run='Cyan' }
    $p = @{ Info='[i]'; OK='[+]'; Warn='[!]'; Err='[x]'; Run='[>]' }
    Write-Host "$($p[$Type]) $Msg" -ForegroundColor $c[$Type]
}

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Ensure-Dirs {
    @($script:DataDir, $script:TempDir) | ForEach-Object {
        if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
    }
}

function Initialize-Aria2 {
    if (Test-Path $script:Aria2Path) { return $true }
    Ensure-Dirs
    Write-Status "Downloading aria2c (one-time setup)..." Run
    $zipPath = Join-Path $script:TempDir "aria2.zip"
    $extractPath = Join-Path $script:TempDir "aria2-extract"
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $script:Aria2Url -OutFile $zipPath -UseBasicParsing -TimeoutSec 120
        if (Test-Path $extractPath) { Remove-Item $extractPath -Recurse -Force }
        Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
        $exe = Get-ChildItem -Path $extractPath -Recurse -Filter "aria2c.exe" | Select-Object -First 1
        if ($exe) { 
            Copy-Item $exe.FullName -Destination $script:Aria2Path -Force
            Write-Status "aria2c ready" OK 
        } else { 
            Write-Status "aria2c.exe not found in archive" Err
            return $false 
        }
        Remove-Item $zipPath,$extractPath -Recurse -Force -EA SilentlyContinue
        return $true
    } catch { 
        Write-Status "Failed to download aria2: $_" Err
        return $false 
    }
}

function Start-Download {
    param(
        [string]$Url,
        [int]$Connections = 16,
        [string]$OutputDir,
        [string]$FileName,
        [switch]$Turbo
    )
    
    if (-not (Initialize-Aria2)) { return $false }
    
    $Connections = [Math]::Max(1, [Math]::Min(16, $Connections))
    if (-not $OutputDir) { 
        $OutputDir = Join-Path ([Environment]::GetFolderPath("UserProfile")) "Downloads" 
    }
    if (-not (Test-Path $OutputDir)) { 
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null 
    }
    
    Write-Host ""
    if ($Turbo) {
        Write-Status "Engine: aria2c TURBO MODE" Run
        Write-Status "Connections: $Connections | Chunk: 512K | Aggressive retry" Info
    } else {
        Write-Status "Engine: aria2c" Info
        Write-Status "Connections: $Connections | Chunk: 1M" Info
    }
    Write-Status "Output: $OutputDir" Info
    Write-Host ""
    
    # Base arguments - optimized for large files and slow servers
    $aria2Args = @(
        "`"$Url`"",
        "-d", "`"$OutputDir`"",
        "-x", $Connections,
        "-s", $Connections,
        "-j", "10",
        "-k", "1M",
        "--min-split-size=1M",
        "--piece-length=1M",
        "--file-allocation=none",
        "--console-log-level=notice",
        "--summary-interval=2",
        "-c",
        "--auto-file-renaming=false",
        "--allow-overwrite=true",
        "--check-certificate=false",
        "--remote-time=true"
    )
    
    if ($Turbo) {
        # TURBO MODE: Aggressive settings for maximum speed
        $aria2Args += @(
            "--max-connection-per-server=16",
            "--split=16",
            "--min-split-size=512K",
            "--piece-length=512K",
            "--max-concurrent-downloads=16",
            "--connect-timeout=30",
            "--timeout=300",
            "--max-tries=0",
            "--retry-wait=1",
            "--max-file-not-found=5",
            "--uri-selector=feedback",
            "--max-resume-failure-tries=0",
            "--always-resume=true",
            "--continue=true",
            "--enable-http-keep-alive=true",
            "--http-accept-gzip=true",
            "--reuse-uri=true",
            "--max-download-limit=0",
            "--disk-cache=64M",
            "--optimize-concurrent-downloads=true",
            "--stream-piece-selector=inorder",
            "--bt-max-peers=0",
            "--follow-metalink=mem",
            "--metalink-servers=16"
        )
    } else {
        # BALANCED MODE: Stable settings for reliability
        $aria2Args += @(
            "--max-connection-per-server=16",
            "--connect-timeout=20",
            "--timeout=180",
            "--max-tries=10",
            "--retry-wait=5",
            "--max-file-not-found=5",
            "--uri-selector=adaptive",
            "--max-resume-failure-tries=10",
            "--always-resume=true",
            "--continue=true",
            "--enable-http-keep-alive=true",
            "--http-accept-gzip=true",
            "--disk-cache=32M",
            "--lowest-speed-limit=0"
        )
    }
    
    if ($FileName) { 
        $aria2Args += @("-o", "`"$FileName`"") 
    }
    
    $startTime = Get-Date
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:Aria2Path
    $psi.Arguments = $aria2Args -join " "
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $false
    
    $process = [System.Diagnostics.Process]::Start($psi)
    $process.WaitForExit()
    $elapsed = (Get-Date) - $startTime
    
    if ($process.ExitCode -eq 0) {
        Write-Host ""
        Write-Status "Download complete! Time: $([Math]::Round($elapsed.TotalSeconds,1))s" OK
        return $true
    } else {
        Write-Status "Download failed (exit code: $($process.ExitCode))" Err
        return $false
    }
}

function Show-Banner {
    Clear-Host
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  FastDL - High-Speed Downloader" -ForegroundColor Cyan
    Write-Host "  Powered by aria2c" -ForegroundColor DarkGray
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
}

function Read-Choice {
    param([string]$Prompt, [string[]]$Options)
    Write-Host "$Prompt" -ForegroundColor Yellow
    for ($i = 0; $i -lt $Options.Count; $i++) { 
        Write-Host "  [$($i+1)] $($Options[$i])" 
    }
    Write-Host "  [Q] Quit" -ForegroundColor DarkGray
    while ($true) {
        $r = Read-Host ">"
        if ($r -match '^[Qq]$') { return -1 }
        if ($r -match '^\d+$' -and [int]$r -ge 1 -and [int]$r -le $Options.Count) { 
            return [int]$r 
        }
        Write-Host "Invalid choice" -ForegroundColor Red
    }
}

function Menu-SingleDownload {
    Show-Banner
    Write-Host "=== Single Download ===" -ForegroundColor Yellow
    Write-Host ""
    
    $url = Read-Host "URL"
    if (-not $url) { 
        Write-Status "URL is required" Warn
        Read-Host "`nPress Enter to continue"
        return 
    }
    
    $modeChoice = Read-Choice "Download Mode" @(
        "Balanced (16 conn, stable)",
        "Turbo (16 conn, max speed, aggressive retry)",
        "Custom"
    )
    if ($modeChoice -eq -1) { return }
    
    $turbo = $false
    $conns = 16
    
    switch ($modeChoice) {
        1 { $conns = 16; $turbo = $false }
        2 { $conns = 16; $turbo = $true }
        3 { 
            $custom = Read-Host "Enter connections (1-16)"
            $conns = [Math]::Max(1, [Math]::Min(16, [int]$custom))
            $turboChoice = Read-Choice "Use Turbo settings?" @("No (stable)","Yes (aggressive)")
            $turbo = ($turboChoice -eq 2)
        }
    }
    
    Start-Download -Url $url -Connections $conns -Turbo:$turbo
    Read-Host "`nPress Enter to continue"
}

function Menu-MultiDownload {
    Show-Banner
    Write-Host "=== Multiple Downloads ===" -ForegroundColor Yellow
    Write-Host "Enter URLs one per line (empty line to finish):" -ForegroundColor Gray
    Write-Host ""
    
    $urls = @()
    $i = 1
    while ($true) {
        $u = Read-Host "URL $i"
        if (-not $u) { break }
        $urls += $u
        $i++
    }
    
    if ($urls.Count -eq 0) { 
        Write-Status "No URLs entered" Warn
        Read-Host "`nPress Enter to continue"
        return 
    }
    
    $modeChoice = Read-Choice "Download Mode for all files" @(
        "Balanced (16 conn, stable)",
        "Turbo (16 conn, max speed)"
    )
    if ($modeChoice -eq -1) { return }
    
    $turbo = ($modeChoice -eq 2)
    $conns = 16
    
    Write-Host ""
    Write-Status "Starting download of $($urls.Count) file(s)..." Run
    
    $success = 0
    $failed = 0
    
    foreach ($url in $urls) {
        Write-Host "`n--- Downloading: $url ---" -ForegroundColor DarkCyan
        if (Start-Download -Url $url -Connections $conns -Turbo:$turbo) {
            $success++
        } else {
            $failed++
        }
    }
    
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Status "Summary: $success succeeded, $failed failed" Info
    Write-Host "========================================" -ForegroundColor Cyan
    
    Read-Host "`nPress Enter to continue"
}

function Show-MainMenu {
    while ($true) {
        Show-Banner
        $choice = Read-Choice "Main Menu" @(
            "Single Download",
            "Multiple Downloads",
            "Exit"
        )
        
        switch ($choice) {
            1 { Menu-SingleDownload }
            2 { Menu-MultiDownload }
            3 { return }
            -1 { return }
        }
    }
}

# Main execution
Ensure-Dirs
Show-MainMenu
Write-Host ""
Write-Status "Goodbye!" OK
