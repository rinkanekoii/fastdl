#!/usr/bin/env pwsh
#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$Url,
    [string]$Proxy,
    [switch]$Fast
)

# ============================================================================
# Cross-Platform Configuration
# ============================================================================

$script:OS = if ($IsWindows -or $env:OS -match 'Windows') { 'Windows' }
             elseif ($IsLinux) { 'Linux' }
             elseif ($IsMacOS) { 'macOS' }
             else { 'Windows' }

$script:TempDir = Join-Path ([System.IO.Path]::GetTempPath()) "fastdl_$PID"
$script:Aria2 = $null
$script:DefaultProxy = 'http://115.75.184.174:8080'
$script:Proxy = ''

$script:DownloadDir = if ($script:OS -eq 'Windows') {
    Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads'
} else {
    Join-Path $env:HOME 'Downloads'
}

$script:Presets = @{
    Stable = @{ 
        Label = 'Stable (16 connections, 1M chunks)'
        Desc  = 'Works with most servers, reliable'
        Connections = 16
        Chunk = '1M'
    }
    Speed = @{ 
        Label = 'Max Speed (16 conn x max split)'
        Desc  = 'Fastest, aggressive settings'
        Connections = 16
        Chunk = '1M'
    }
}

$script:Aria2Urls = @{
    Windows = 'https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0-win-64bit-build1.zip'
    Linux   = 'https://github.com/q3aql/aria2-static-builds/releases/download/v1.37.0/aria2-1.37.0-linux-gnu-64bit-build1.tar.bz2'
    macOS   = 'https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0-osx-darwin.tar.bz2'
}

# ============================================================================
# Helpers
# ============================================================================

function Write-Status {
    param([string]$Msg, [string]$Type = 'Info')
    $map = @{
        Info    = @{ C = 'Gray';   P = '[i]' }
        Success = @{ C = 'Green';  P = '[+]' }
        Warning = @{ C = 'Yellow'; P = '[!]' }
        Error   = @{ C = 'Red';    P = '[x]' }
        Action  = @{ C = 'Cyan';   P = '[>]' }
    }
    $e = $map[$Type]
    Write-Host "$($e.P) $Msg" -ForegroundColor $e.C
}

function Test-Url {
    param([string]$U)
    return $U -match '^https?://.+'
}

function Test-ProxyAvailable {
    param([string]$ProxyUrl)
    try {
        $ProgressPreference = 'SilentlyContinue'
        $null = Invoke-WebRequest -Uri 'http://www.gstatic.com/generate_204' -Proxy $ProxyUrl -TimeoutSec 5 -UseBasicParsing
        return $true
    }
    catch { return $false }
}

function Initialize-Proxy {
    if ($script:Proxy) { return }
    
    Write-Host ''
    Write-Status "VN proxy available: $($script:DefaultProxy)" -Type Info
    $useProxy = Read-Choice -Prompt 'Use this proxy?' -Options @('Yes', 'No')
    
    if ($useProxy -eq 1) {
        Write-Status "Testing VN proxy ($($script:DefaultProxy))..." -Type Action
        if (Test-ProxyAvailable -ProxyUrl $script:DefaultProxy) {
            $script:Proxy = $script:DefaultProxy
            Write-Status 'VN proxy OK!' -Type Success
        }
        else {
            Write-Status 'VN proxy unavailable, using direct connection' -Type Warning
        }
    }
    else {
        Write-Status 'Using direct connection' -Type Info
    }
}

function Get-FileName {
    param([string]$U)
    try {
        $uri = [System.Uri]::new($U)
        $path = $uri.AbsolutePath
        
        # Get filename from path
        $n = [System.IO.Path]::GetFileName($path)
        
        # URL decode the filename
        if (-not [string]::IsNullOrWhiteSpace($n)) {
            $n = [System.Uri]::UnescapeDataString($n)
        }
        
        # Validate filename
        if ([string]::IsNullOrWhiteSpace($n) -or $n -eq '/' -or $n -notmatch '\.\w+$') {
            # Try to get from query string or content-disposition later
            return "download_$(Get-Date -Format 'HHmmss')"
        }
        
        # Clean invalid characters
        $invalid = [System.IO.Path]::GetInvalidFileNameChars()
        foreach ($c in $invalid) { $n = $n.Replace($c, '_') }
        
        return $n
    }
    catch { return "download_$(Get-Date -Format 'HHmmss')" }
}

function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Format-Speed {
    param([double]$BytesPerSec)
    if ($BytesPerSec -ge 1GB) { return "{0:N2} GB/s" -f ($BytesPerSec / 1GB) }
    if ($BytesPerSec -ge 1MB) { return "{0:N2} MB/s" -f ($BytesPerSec / 1MB) }
    if ($BytesPerSec -ge 1KB) { return "{0:N2} KB/s" -f ($BytesPerSec / 1KB) }
    return "{0:N0} B/s" -f $BytesPerSec
}

function Format-Duration {
    param([TimeSpan]$Duration)
    if ($Duration.TotalHours -ge 1) {
        return "{0:D2}:{1:D2}:{2:D2}" -f [int]$Duration.TotalHours, $Duration.Minutes, $Duration.Seconds
    }
    return "{0:D2}:{1:D2}" -f $Duration.Minutes, $Duration.Seconds
}

function Get-FileInfo {
    param([string]$Url)
    try {
        $ProgressPreference = 'SilentlyContinue'
        $proxyParam = @{}
        if ($script:Proxy) { $proxyParam['Proxy'] = $script:Proxy }
        
        $resp = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -TimeoutSec 15 @proxyParam -ErrorAction Stop
        $size = [long]$resp.Headers['Content-Length']
        
        # Try to get filename from Content-Disposition header
        $fileName = $null
        $cd = $resp.Headers['Content-Disposition']
        if ($cd -and $cd -match 'filename[*]?=(?:UTF-8'''')?["\s]*([^";\r\n]+)') {
            $fileName = $Matches[1].Trim('"', ' ')
            $fileName = [System.Uri]::UnescapeDataString($fileName)
        }
        
        return @{ Size = $size; Success = $true; FileName = $fileName }
    }
    catch {
        return @{ Size = 0; Success = $false; Error = $_.Exception.Message; FileName = $null }
    }
}

# ============================================================================
# Aria2 Setup (Temporary, No Install)
# ============================================================================

function Initialize-Aria2 {
    if ($script:Aria2 -and (Test-Path $script:Aria2)) { return $script:Aria2 }

    # Check PATH first
    $cmd = Get-Command aria2c -ErrorAction SilentlyContinue
    if ($cmd) {
        $script:Aria2 = $cmd.Source
        return $script:Aria2
    }

    Write-Status "Downloading aria2 for $($script:OS) (temp, no install)..." -Type Action

    if (-not (Test-Path $script:TempDir)) {
        New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null
    }

    $url = $script:Aria2Urls[$script:OS]
    $ext = if ($script:OS -eq 'Windows') { 'zip' } else { 'tar.bz2' }
    $archive = Join-Path $script:TempDir "aria2.$ext"

    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $url -OutFile $archive -UseBasicParsing -TimeoutSec 120

        if ($script:OS -eq 'Windows') {
            Expand-Archive -Path $archive -DestinationPath $script:TempDir -Force
            $exe = Get-ChildItem -Path $script:TempDir -Recurse -Filter 'aria2c.exe' | Select-Object -First 1
            $script:Aria2 = $exe.FullName
        }
        else {
            # Linux/macOS: extract tar.bz2
            Push-Location $script:TempDir
            tar -xjf $archive 2>$null
            Pop-Location
            
            $exeName = 'aria2c'
            $exe = Get-ChildItem -Path $script:TempDir -Recurse -Filter $exeName | Select-Object -First 1
            if ($exe) {
                chmod +x $exe.FullName 2>$null
                $script:Aria2 = $exe.FullName
            }
        }

        Remove-Item $archive -Force -ErrorAction SilentlyContinue

        if (-not $script:Aria2 -or -not (Test-Path $script:Aria2)) {
            throw 'aria2c not found after extraction'
        }

        Write-Status 'aria2 ready!' -Type Success
        return $script:Aria2
    }
    catch {
        $installCmd = switch ($script:OS) {
            'Windows' { 'winget install aria2' }
            'Linux'   { 'sudo apt install aria2  # or: sudo yum install aria2' }
            'macOS'   { 'brew install aria2' }
        }
        throw "Failed to download aria2. Install manually: $installCmd`nError: $_"
    }
}

# ============================================================================
# Download Engine
# ============================================================================

function Start-Download {
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$Connections = 16,
        [string]$Chunk = '1M',
        [switch]$MaxSpeed
    )

    if (-not (Test-Url $Url)) {
        Write-Status 'Invalid URL' -Type Error
        return $false
    }

    $aria2 = Initialize-Aria2

    if (-not (Test-Path $script:DownloadDir)) {
        New-Item -ItemType Directory -Path $script:DownloadDir -Force | Out-Null
    }

    # Get file info first (size and filename from headers)
    Write-Status "Getting file info..." -Type Action
    $fileInfo = Get-FileInfo -Url $Url
    $totalSize = $fileInfo.Size
    
    # Get filename: prefer Content-Disposition, then URL, then fallback
    $fileName = if ($fileInfo.FileName) { 
        $fileInfo.FileName 
    } else { 
        Get-FileName -U $Url 
    }
    
    if (-not $fileInfo.Success) {
        Write-Status "Cannot get file info: $($fileInfo.Error)" -Type Warning
        Write-Status "Continuing without size info..." -Type Info
    }
    else {
        if ($totalSize -gt 0) {
            Write-Status "File size: $(Format-FileSize $totalSize)" -Type Info
        }
        Write-Status "File name: $fileName" -Type Info
    }

    # aria2 limit: max 16 connections per server
    $conn = [Math]::Min(16, $Connections)

    $args = @(
        $Url
        '-d', $script:DownloadDir
        '-o', $fileName
        '-x', $conn
        '-s', $conn
        '-j', $conn
        '-k', $Chunk
        "--min-split-size=$Chunk"
        "--max-connection-per-server=$conn"
        "--split=$conn"
        '-c'
        '--file-allocation=none'
        '--summary-interval=1'
        '--auto-file-renaming=false'
        '--allow-overwrite=true'
        '--check-certificate=false'
        '--remote-time=true'
        '--enable-http-keep-alive=true'
        '--http-accept-gzip=true'
        '--console-log-level=notice'
        '--download-result=full'
    )

    if ($MaxSpeed) {
        # Aggressive settings for max speed
        $args += @(
            '--max-tries=0'
            '--retry-wait=1'
            '--connect-timeout=5'
            '--timeout=300'
            '--max-file-not-found=5'
            '--stream-piece-selector=geom'
            '--uri-selector=adaptive'
            '--disk-cache=512M'
            '--piece-length=1M'
            '--optimize-concurrent-downloads=true'
            '--async-dns=true'
            '--max-download-limit=0'
            '--lowest-speed-limit=0'
            '--socket-recv-buffer-size=16M'
            '--no-netrc=true'
            '--always-resume=true'
            '--max-resume-failure-tries=0'
            '--http-no-cache=true'
        )
    }
    else {
        $args += @(
            '--max-tries=10'
            '--retry-wait=2'
            '--connect-timeout=15'
            '--timeout=600'
        )
    }

    if ($script:Proxy) {
        $args += "--all-proxy=$($script:Proxy)"
    }

    Write-Host ''
    $mode = if ($MaxSpeed) { 'MAX SPEED' } else { 'Stable' }
    Write-Status "$conn connections | Chunk: $Chunk | Mode: $mode" -Type Action
    if ($script:Proxy) { Write-Status "Proxy: $($script:Proxy)" -Type Info }
    Write-Status "Save to: $script:DownloadDir\$fileName" -Type Info
    Write-Host ''

    # Track download with progress
    $startTime = Get-Date
    
    $destFile = Join-Path $script:DownloadDir $fileName
    $ariaControl = "$destFile.aria2"
    
    # Start aria2 process
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $aria2
    $psi.Arguments = ($args | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    
    # Capture output asynchronously
    $outputBuilder = [System.Text.StringBuilder]::new()
    $errorBuilder = [System.Text.StringBuilder]::new()
    
    $outputHandler = {
        if ($EventArgs.Data) {
            $outputBuilder.AppendLine($EventArgs.Data)
        }
    }
    $errorHandler = {
        if ($EventArgs.Data) {
            $errorBuilder.AppendLine($EventArgs.Data)
        }
    }
    
    $process.EnableRaisingEvents = $true
    Register-ObjectEvent -InputObject $process -EventName OutputDataReceived -Action $outputHandler -SourceIdentifier "aria2out_$PID" | Out-Null
    Register-ObjectEvent -InputObject $process -EventName ErrorDataReceived -Action $errorHandler -SourceIdentifier "aria2err_$PID" | Out-Null
    
    try {
        $null = $process.Start()
        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()
        
        # Monitor progress
        while (-not $process.HasExited) {
            Start-Sleep -Milliseconds 500
            
            $now = Get-Date
            $elapsed = $now - $startTime
            
            # Get current downloaded size
            $currentBytes = 0
            if (Test-Path $destFile) {
                $currentBytes = (Get-Item $destFile -ErrorAction SilentlyContinue).Length
            }
            
            # Calculate overall speed (total downloaded / elapsed time) - more stable
            $overallSpeed = if ($elapsed.TotalSeconds -gt 1) { 
                $currentBytes / $elapsed.TotalSeconds 
            } else { 0 }
            
            # Progress display
            if ($totalSize -gt 0 -and $currentBytes -gt 0) {
                $percent = [Math]::Min(100, [Math]::Round(($currentBytes / $totalSize) * 100, 1))
                
                # ETA based on overall speed
                $remaining = $totalSize - $currentBytes
                $eta = if ($overallSpeed -gt 0) { 
                    [TimeSpan]::FromSeconds($remaining / $overallSpeed) 
                } else { 
                    [TimeSpan]::Zero 
                }
                $etaStr = if ($eta.TotalSeconds -gt 0) { Format-Duration $eta } else { "--:--" }
                
                $speedStr = Format-Speed $overallSpeed
                $dlStr = Format-FileSize $currentBytes
                $totalStr = Format-FileSize $totalSize
                
                $status = "`r  [{0,5:N1}%]  {1,10} / {2,-10}  Speed: {3,12}  ETA: {4}   " -f $percent, $dlStr, $totalStr, $speedStr, $etaStr
                Write-Host $status -NoNewline
            }
            elseif ($currentBytes -gt 0) {
                # Unknown total size
                $speedStr = Format-Speed $overallSpeed
                $dlStr = Format-FileSize $currentBytes
                $elapsedStr = Format-Duration $elapsed
                
                $status = "`r  Downloaded: {0,10}  Speed: {1,12}  Elapsed: {2}   " -f $dlStr, $speedStr, $elapsedStr
                Write-Host $status -NoNewline
            }
        }
        
        $process.WaitForExit()
        $code = $process.ExitCode
        
        Write-Host ""
    }
    finally {
        Unregister-Event -SourceIdentifier "aria2out_$PID" -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier "aria2err_$PID" -ErrorAction SilentlyContinue
        Get-Job -Name "aria2out_$PID" -ErrorAction SilentlyContinue | Remove-Job -Force
        Get-Job -Name "aria2err_$PID" -ErrorAction SilentlyContinue | Remove-Job -Force
    }
    
    $endTime = Get-Date
    $totalDuration = $endTime - $startTime
    
    # Get final file size
    $finalSize = 0
    if (Test-Path $destFile) {
        $finalSize = (Get-Item $destFile).Length
    }
    
    # Calculate average speed
    $avgSpeedTotal = if ($totalDuration.TotalSeconds -gt 0) { 
        $finalSize / $totalDuration.TotalSeconds 
    } else { 0 }

    Write-Host ''
    if ($code -eq 0) {
        Write-Host '╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Green
        Write-Host '║                    DOWNLOAD COMPLETE                         ║' -ForegroundColor Green
        Write-Host '╠══════════════════════════════════════════════════════════════╣' -ForegroundColor Green
        Write-Host ("║  File: {0,-53}║" -f ($fileName.Substring(0, [Math]::Min(53, $fileName.Length)))) -ForegroundColor Green
        Write-Host ("║  Size: {0,-53}║" -f (Format-FileSize $finalSize)) -ForegroundColor Green
        Write-Host ("║  Time: {0,-53}║" -f (Format-Duration $totalDuration)) -ForegroundColor Green
        Write-Host ("║  Avg Speed: {0,-48}║" -f (Format-Speed $avgSpeedTotal)) -ForegroundColor Green
        Write-Host '╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Green
        return $true
    }
    else {
        Write-Host '╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Red
        Write-Host '║                    DOWNLOAD FAILED                           ║' -ForegroundColor Red
        Write-Host '╠══════════════════════════════════════════════════════════════╣' -ForegroundColor Red
        Write-Host ("║  Exit Code: {0,-48}║" -f $code) -ForegroundColor Red
        Write-Host ("║  Time Elapsed: {0,-45}║" -f (Format-Duration $totalDuration)) -ForegroundColor Red
        if ($finalSize -gt 0) {
            Write-Host ("║  Downloaded: {0,-47}║" -f (Format-FileSize $finalSize)) -ForegroundColor Red
        }
        Write-Host '╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Red
        
        # Show error output if any
        $errOut = $errorBuilder.ToString()
        if ($errOut) {
            Write-Status "Error details:" -Type Error
            $errOut -split "`n" | Where-Object { $_ -match '\S' } | Select-Object -Last 5 | ForEach-Object {
                Write-Host "  $_" -ForegroundColor DarkRed
            }
        }
        return $false
    }
}

# ============================================================================
# UI
# ============================================================================

function Show-Banner {
    Clear-Host
    Write-Host '=====================================' -ForegroundColor Cyan
    Write-Host '  FastDL - High Speed Downloader    ' -ForegroundColor Cyan
    Write-Host "  OS: $($script:OS) | No install required" -ForegroundColor DarkGray
    Write-Host '=====================================' -ForegroundColor Cyan
    if ($script:Proxy) {
        Write-Host "  Proxy: $($script:Proxy)" -ForegroundColor Green
    }
    Write-Host ''
}

function Read-Choice {
    param([string]$Prompt, [string[]]$Options)
    Write-Host $Prompt -ForegroundColor Yellow
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host "  [$($i + 1)] $($Options[$i])"
    }
    Write-Host '  [Q] Quit' -ForegroundColor DarkGray
    Write-Host ''

    while ($true) {
        $sel = Read-Host 'Select'
        if ($sel -match '^[Qq]$') { return -1 }
        if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $Options.Count) {
            return [int]$sel
        }
        Write-Host 'Invalid' -ForegroundColor Red
    }
}

function Menu-Download {
    param([switch]$Multi)

    Show-Banner
    $title = if ($Multi) { '=== Multiple Downloads ===' } else { '=== Single Download ===' }
    Write-Host $title -ForegroundColor Yellow
    Write-Host ''

    $urls = @()
    if ($Multi) {
        Write-Host 'Enter URLs (blank line to finish):' -ForegroundColor Gray
        $i = 1
        while ($true) {
            $line = Read-Host "URL $i"
            if ([string]::IsNullOrWhiteSpace($line)) { break }
            if (Test-Url $line) { $urls += $line.Trim(); $i++ }
            else { Write-Status 'Invalid URL, skip' -Type Warning }
        }
        if ($urls.Count -eq 0) {
            Write-Status 'No URLs entered' -Type Warning
            Read-Host 'Press Enter'
            return
        }
    }
    else {
        $url = Read-Host 'URL'
        if (-not (Test-Url $url)) {
            Write-Status 'Invalid URL' -Type Warning
            Read-Host 'Press Enter'
            return
        }
        $urls = @($url)
    }

    # Select preset
    Write-Host ''
    $choice = Read-Choice -Prompt 'Download Mode' -Options @(
        "$($script:Presets.Stable.Label) - $($script:Presets.Stable.Desc)",
        "$($script:Presets.Speed.Label) - $($script:Presets.Speed.Desc)"
    )
    if ($choice -eq -1) { return }

    $preset = if ($choice -eq 1) { $script:Presets.Stable } else { $script:Presets.Speed }
    $maxSpeed = ($choice -eq 2)

    # Download
    $ok = 0; $fail = 0
    foreach ($u in $urls) {
        if ($Multi -and $urls.Count -gt 1) {
            Write-Host "`n$('-' * 50)" -ForegroundColor DarkCyan
            Write-Host $u -ForegroundColor Cyan
        }
        if (Start-Download -Url $u -Connections $preset.Connections -Chunk $preset.Chunk -MaxSpeed:$maxSpeed) { $ok++ }
        else { $fail++ }
    }

    if ($Multi -and $urls.Count -gt 1) {
        Write-Host "`n=== Summary ===" -ForegroundColor Cyan
        Write-Status "Success: $ok | Failed: $fail" -Type $(if ($fail -gt 0) { 'Warning' } else { 'Success' })
    }
    Read-Host "`nPress Enter"
}

function Menu-Proxy {
    Show-Banner
    Write-Host '=== Proxy Settings ===' -ForegroundColor Yellow
    Write-Host ''
    
    $current = if ($script:Proxy) { $script:Proxy } else { '(none)' }
    Write-Status "Current: $current" -Type Info
    Write-Host ''

    $choice = Read-Choice -Prompt 'Options' -Options @('Set HTTP/SOCKS proxy', 'Clear proxy', 'Back')
    
    switch ($choice) {
        1 {
            Write-Host ''
            Write-Host 'Examples:' -ForegroundColor Gray
            Write-Host '  http://proxy-server:8080' -ForegroundColor DarkGray
            Write-Host '  socks5://127.0.0.1:1080' -ForegroundColor DarkGray
            Write-Host ''
            $p = Read-Host 'Proxy URL'
            if (-not [string]::IsNullOrWhiteSpace($p)) {
                $newProxy = $p.Trim()
                Write-Status "Testing proxy ($newProxy)..." -Type Action
                if (Test-ProxyAvailable -ProxyUrl $newProxy) {
                    $script:Proxy = $newProxy
                    Write-Status "Proxy set: $($script:Proxy)" -Type Success
                }
                else {
                    Write-Status 'Proxy unavailable, keeping current settings' -Type Warning
                }
            }
        }
        2 {
            $script:Proxy = ''
            Write-Status 'Proxy cleared' -Type Success
        }
    }
    if ($choice -ne 3 -and $choice -ne -1) { Read-Host 'Press Enter' }
}

function Main-Menu {
    while ($true) {
        Show-Banner
        $choice = Read-Choice -Prompt 'Main Menu' -Options @(
            'Single Download',
            'Multiple Downloads',
            'Proxy Settings',
            'Exit'
        )
        
        switch ($choice) {
            1 { Menu-Download }
            2 { Menu-Download -Multi }
            3 { Menu-Proxy }
            { $_ -eq 4 -or $_ -eq -1 } { return }
        }
    }
}

# ============================================================================
# Entry Point
# ============================================================================

# Command-line mode
if ($Url) {
    try {
        Write-Status "OS: $($script:OS)" -Type Info
        Write-Status "Output: $script:DownloadDir" -Type Info
        Initialize-Proxy
        $preset = if ($Fast) { $script:Presets.Speed } else { $script:Presets.Stable }
        Start-Download -Url $Url -Connections $preset.Connections -Chunk $preset.Chunk -MaxSpeed:$Fast | Out-Null
    }
    catch {
        Write-Status "Error: $_" -Type Error
    }
    finally {
        if (Test-Path $script:TempDir) {
            Remove-Item $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    exit
}

# Interactive mode
try {
    Write-Status "OS: $($script:OS)" -Type Info
    Write-Status "Output: $script:DownloadDir" -Type Info
    $null = Initialize-Aria2
    Initialize-Proxy
    Main-Menu
}
catch {
    Write-Status "Error: $_" -Type Error
}
finally {
    if (Test-Path $script:TempDir) {
        Remove-Item $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Status 'Temp files cleaned' -Type Info
    }
}

Write-Host ''
Write-Status 'Goodbye!' -Type Success
