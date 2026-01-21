#Requires -Version 5.1

[CmdletBinding()]
param()

# ============================================================================
# OS Detection & Platform-Specific Configuration
# ============================================================================

function Get-OSPlatform {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        # PowerShell Core 6+
        if ($IsWindows) { return 'Windows' }
        if ($IsLinux) { return 'Linux' }
        if ($IsMacOS) { return 'macOS' }
    }
    else {
        # Windows PowerShell 5.1
        return 'Windows'
    }
    return 'Unknown'
}

function Initialize-PlatformConfig {
    $platform = Get-OSPlatform
    
    $config = @{
        Platform = $platform
    }
    
    switch ($platform) {
        'Windows' {
            $config.DataDir = Join-Path $env:APPDATA "FastDL"
            $config.TempDir = Join-Path $env:TEMP "fastdl_session"
            $config.Aria2Path = Join-Path (Join-Path $env:APPDATA "FastDL") "aria2c.exe"
            $config.Aria2Version = "1.37.0"
            $config.Aria2Url = "https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0-win-64bit-build1.zip"
            $config.Aria2ExeName = "aria2c.exe"
            $config.DefaultDownloadDir = Join-Path ([Environment]::GetFolderPath("UserProfile")) "Downloads"
            $config.ArchiveFormat = "zip"
        }
        'Linux' {
            $homeDir = $env:HOME
            $config.DataDir = Join-Path $homeDir ".local/share/fastdl"
            $config.TempDir = Join-Path $homeDir ".cache/fastdl_session"
            $config.Aria2Path = Join-Path (Join-Path $homeDir ".local/share/fastdl") "aria2c"
            $config.Aria2Version = "1.37.0"
            $config.Aria2Url = "https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0-linux-gnu-64bit-build1.tar.bz2"
            $config.Aria2ExeName = "aria2c"
            $config.DefaultDownloadDir = Join-Path $homeDir "Downloads"
            $config.ArchiveFormat = "tar.bz2"
        }
        'macOS' {
            $homeDir = $env:HOME
            $config.DataDir = Join-Path $homeDir "Library/Application Support/FastDL"
            $config.TempDir = Join-Path $homeDir ".cache/fastdl_session"
            $config.Aria2Path = Join-Path (Join-Path $homeDir "Library/Application Support/FastDL") "aria2c"
            $config.Aria2Version = "1.37.0"
            $config.Aria2Url = "https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0-osx-darwin.tar.bz2"
            $config.Aria2ExeName = "aria2c"
            $config.DefaultDownloadDir = Join-Path $homeDir "Downloads"
            $config.ArchiveFormat = "tar.bz2"
        }
        default {
            throw "Unsupported operating system: $platform"
        }
    }
    
    $config.MaxConnections = 16
    $config.MinConnections = 1
    
    return $config
}

$script:Config = Initialize-PlatformConfig

# ============================================================================
# Configuration & Constants
# ============================================================================

$script:Presets = @{
    Balanced = @{
        Name = "Balanced"
        Connections = 16
        ChunkSize = "1M"
        Turbo = $false
        Description = "Stable, works with most servers"
    }
    Turbo = @{
        Name = "Turbo"
        Connections = 16
        ChunkSize = "512K"
        Turbo = $true
        Description = "Maximum speed, aggressive retry"
    }
    Conservative = @{
        Name = "Conservative"
        Connections = 8
        ChunkSize = "2M"
        Turbo = $false
        Description = "Fewer connections, for slow servers"
    }
}

# ============================================================================
# Utility Functions
# ============================================================================

function Write-Status {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        
        [ValidateSet('Info','Success','Warning','Error','Running')]
        [string]$Type = 'Info'
    )
    
    $config = @{
        Info    = @{ Color = 'Gray';   Prefix = '[i]' }
        Success = @{ Color = 'Green';  Prefix = '[✓]' }
        Warning = @{ Color = 'Yellow'; Prefix = '[!]' }
        Error   = @{ Color = 'Red';    Prefix = '[✗]' }
        Running = @{ Color = 'Cyan';   Prefix = '[→]' }
    }
    
    $c = $config[$Type]
    Write-Host "$($c.Prefix) $Message" -ForegroundColor $c.Color
}

function Format-FileSize {
    [CmdletBinding()]
    param([Parameter(Mandatory)][long]$Bytes)
    
    if ($Bytes -ge 1TB) { return "{0:N2} TB" -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Format-Duration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][TimeSpan]$TimeSpan)
    
    if ($TimeSpan.TotalHours -ge 1) {
        return "{0:D2}:{1:D2}:{2:D2}" -f $TimeSpan.Hours, $TimeSpan.Minutes, $TimeSpan.Seconds
    }
    return "{0:D2}:{1:D2}" -f $TimeSpan.Minutes, $TimeSpan.Seconds
}

function Test-Url {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Url)
    
    return $Url -match '^https?://.+\..+'
}

function Initialize-Environment {
    [CmdletBinding()]
    param()
    
    try {
        foreach ($dir in @($script:Config.DataDir, $script:Config.TempDir)) {
            if (-not (Test-Path $dir)) {
                New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
            }
        }
        return $true
    }
    catch {
        Write-Status "Failed to create directories: $_" -Type Error
        return $false
    }
}

# ============================================================================
# Archive Extraction Functions
# ============================================================================

function Expand-TarBz2 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        
        [Parameter(Mandatory)]
        [string]$DestinationPath
    )
    
    try {
        if (-not (Test-Path $DestinationPath)) {
            New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
        }
        
        # Try using tar command (available on modern systems)
        if (Get-Command tar -ErrorAction SilentlyContinue) {
            $result = tar -xjf "$Path" -C "$DestinationPath" 2>&1
            if ($LASTEXITCODE -eq 0) {
                return $true
            }
        }
        
        # Fallback: manual extraction (requires bzip2 and tar separately)
        Write-Status "Attempting manual extraction..." -Type Info
        
        # Check for bzip2
        if (-not (Get-Command bunzip2 -ErrorAction SilentlyContinue)) {
            throw "tar or bunzip2 not found. Please install: sudo apt install tar bzip2 (Linux) or brew install bzip2 (macOS)"
        }
        
        $tarFile = $Path -replace '\.bz2$', ''
        
        # Decompress bz2
        bunzip2 -k "$Path" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to decompress bz2 file"
        }
        
        # Extract tar
        tar -xf "$tarFile" -C "$DestinationPath" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Remove-Item $tarFile -Force -ErrorAction SilentlyContinue
            return $true
        }
        
        throw "Failed to extract tar file"
    }
    catch {
        Write-Status "Extraction failed: $_" -Type Error
        return $false
    }
}

# ============================================================================
# Aria2 Management
# ============================================================================

function Test-Aria2Installed {
    # Check if aria2c is in PATH (system-wide installation)
    if (Get-Command aria2c -ErrorAction SilentlyContinue) {
        $script:Config.Aria2Path = "aria2c"
        return $true
    }
    
    # Check local installation
    return (Test-Path $script:Config.Aria2Path)
}

function Install-Aria2 {
    [CmdletBinding()]
    param()
    
    if (Test-Aria2Installed) {
        return $true
    }
    
    if (-not (Initialize-Environment)) {
        return $false
    }
    
    Write-Status "Downloading aria2c for $($script:Config.Platform) (one-time setup)..." -Type Running
    
    $archiveName = if ($script:Config.ArchiveFormat -eq "zip") { "aria2.zip" } else { "aria2.tar.bz2" }
    $archivePath = Join-Path $script:Config.TempDir $archiveName
    $extractPath = Join-Path $script:Config.TempDir "aria2-extract"
    
    try {
        # Download with progress
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $script:Config.Aria2Url -OutFile $archivePath `
            -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
        
        Write-Status "Extracting aria2c..." -Type Running
        
        # Extract based on format
        if (Test-Path $extractPath) {
            Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        
        if ($script:Config.ArchiveFormat -eq "zip") {
            Expand-Archive -Path $archivePath -DestinationPath $extractPath -Force -ErrorAction Stop
        }
        else {
            if (-not (Expand-TarBz2 -Path $archivePath -DestinationPath $extractPath)) {
                throw "Failed to extract tar.bz2 archive"
            }
        }
        
        # Find and copy executable
        $exe = Get-ChildItem -Path $extractPath -Recurse -Filter $script:Config.Aria2ExeName -ErrorAction Stop | 
               Select-Object -First 1
        
        if (-not $exe) {
            throw "$($script:Config.Aria2ExeName) not found in archive"
        }
        
        Copy-Item $exe.FullName -Destination $script:Config.Aria2Path -Force -ErrorAction Stop
        
        # Make executable on Unix-like systems
        if ($script:Config.Platform -in @('Linux', 'macOS')) {
            chmod +x $script:Config.Aria2Path 2>&1 | Out-Null
        }
        
        Write-Status "aria2c is ready" -Type Success
        
        # Cleanup
        Remove-Item $archivePath, $extractPath -Recurse -Force -ErrorAction SilentlyContinue
        
        return $true
    }
    catch {
        Write-Status "Failed to download aria2: $_" -Type Error
        
        # Suggest package manager installation
        $suggestion = switch ($script:Config.Platform) {
            'Linux' { "sudo apt install aria2 (Debian/Ubuntu) or sudo yum install aria2 (RHEL/CentOS)" }
            'macOS' { "brew install aria2" }
            default { "" }
        }
        
        if ($suggestion) {
            Write-Status "Alternatively, install via package manager: $suggestion" -Type Info
        }
        
        return $false
    }
}

function Get-Aria2Arguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutputDir,
        [int]$Connections = 16,
        [switch]$Turbo,
        [string]$FileName
    )
    
    $args = New-Object System.Collections.ArrayList
    
    # Core arguments
    [void]$args.AddRange(@(
        "`"$Url`""
        "-d", "`"$OutputDir`""
        "-x", $Connections
        "-s", $Connections
        "-j", "10"
        "-c"
        "--file-allocation=none"
        "--console-log-level=notice"
        "--summary-interval=1"
        "--auto-file-renaming=false"
        "--allow-overwrite=true"
        "--check-certificate=false"
        "--remote-time=true"
        "--enable-http-keep-alive=true"
        "--http-accept-gzip=true"
        "--always-resume=true"
        "--continue=true"
    ))
    
    if ($Turbo) {
        # Turbo mode: Aggressive settings
        [void]$args.AddRange(@(
            "-k", "512K"
            "--min-split-size=512K"
            "--piece-length=512K"
            "--max-connection-per-server=16"
            "--split=16"
            "--max-concurrent-downloads=16"
            "--connect-timeout=30"
            "--timeout=300"
            "--max-tries=0"
            "--retry-wait=1"
            "--max-file-not-found=5"
            "--uri-selector=feedback"
            "--max-resume-failure-tries=0"
            "--reuse-uri=true"
            "--max-download-limit=0"
            "--disk-cache=64M"
            "--optimize-concurrent-downloads=true"
            "--stream-piece-selector=inorder"
        ))
    }
    else {
        # Balanced mode: Stable settings
        [void]$args.AddRange(@(
            "-k", "1M"
            "--min-split-size=1M"
            "--piece-length=1M"
            "--max-connection-per-server=16"
            "--connect-timeout=20"
            "--timeout=180"
            "--max-tries=10"
            "--retry-wait=5"
            "--max-file-not-found=5"
            "--uri-selector=adaptive"
            "--max-resume-failure-tries=10"
            "--disk-cache=32M"
            "--lowest-speed-limit=0"
        ))
    }
    
    if ($FileName) {
        [void]$args.AddRange(@("-o", "`"$FileName`""))
    }
    
    return $args -join " "
}

# ============================================================================
# Download Functions
# ============================================================================

function Start-DownloadTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Url,
        
        [int]$Connections = 16,
        
        [string]$OutputDir,
        
        [string]$FileName,
        
        [switch]$Turbo,
        
        [switch]$Quiet
    )
    
    # Validate
    if (-not (Test-Url $Url)) {
        Write-Status "Invalid URL: $Url" -Type Error
        return $false
    }
    
    if (-not (Install-Aria2)) {
        return $false
    }
    
    # Setup directories
    if (-not $OutputDir) {
        $OutputDir = $script:Config.DefaultDownloadDir
    }
    
    if (-not (Test-Path $OutputDir)) {
        try {
            New-Item -ItemType Directory -Path $OutputDir -Force -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Status "Failed to create output directory: $_" -Type Error
            return $false
        }
    }
    
    # Normalize connections
    $Connections = [Math]::Max($script:Config.MinConnections, 
                              [Math]::Min($script:Config.MaxConnections, $Connections))
    
    # Display info
    if (-not $Quiet) {
        Write-Host ""
        if ($Turbo) {
            Write-Status "Engine: aria2c TURBO on $($script:Config.Platform)" -Type Running
        } else {
            Write-Status "Engine: aria2c BALANCED on $($script:Config.Platform)" -Type Running
        }
        
        $chunkSize = if ($Turbo) { '512K' } else { '1M' }
        Write-Status "Connections: $Connections | Chunk: $chunkSize" -Type Info
        Write-Status "Output: $OutputDir" -Type Info
        Write-Host ""
    }
    
    # Build arguments
    $arguments = Get-Aria2Arguments -Url $Url -OutputDir $OutputDir `
        -Connections $Connections -Turbo:$Turbo -FileName $FileName
    
    # Execute
    $startTime = Get-Date
    
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:Config.Aria2Path
        $psi.Arguments = $arguments
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $false
        
        $process = [System.Diagnostics.Process]::Start($psi)
        $process.WaitForExit()
        
        $elapsed = (Get-Date) - $startTime
        
        if ($process.ExitCode -eq 0) {
            if (-not $Quiet) {
                Write-Host ""
                Write-Status "Complete! Time: $(Format-Duration $elapsed)" -Type Success
            }
            return $true
        }
        else {
            Write-Status "Download failed (exit code: $($process.ExitCode))" -Type Error
            return $false
        }
    }
    catch {
        Write-Status "Error: $_" -Type Error
        return $false
    }
}

# ============================================================================
# UI Functions
# ============================================================================

function Show-Banner {
    Clear-Host
    $platform = $script:Config.Platform
    $banner = @"
╔════════════════════════════════════════╗
║    FastDL - High-Speed Downloader     ║
║         Powered by aria2c v1.37        ║
║         Platform: $platform$(' ' * (18 - $platform.Length))║
╚════════════════════════════════════════╝
"@
    Write-Host $banner -ForegroundColor Cyan
    Write-Host ""
}

function Read-Choice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,
        
        [Parameter(Mandatory)]
        [string[]]$Options,
        
        [switch]$AllowQuit
    )
    
    Write-Host $Prompt -ForegroundColor Yellow
    Write-Host ""
    
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host "  [$($i + 1)] $($Options[$i])"
    }
    
    if ($AllowQuit) {
        Write-Host "  [Q] Quit" -ForegroundColor DarkGray
    }
    
    Write-Host ""
    
    while ($true) {
        $input = Read-Host "Select"
        
        if ($AllowQuit -and $input -match '^[Qq]$') {
            return -1
        }
        
        if ($input -match '^\d+$') {
            $num = [int]$input
            if ($num -ge 1 -and $num -le $Options.Count) {
                return $num
            }
        }
        
        Write-Host "Invalid choice" -ForegroundColor Red
    }
}

function Read-Urls {
    [CmdletBinding()]
    param()
    
    Write-Host "Enter URLs (one per line, empty line to finish):" -ForegroundColor Gray
    Write-Host ""
    
    $urls = New-Object System.Collections.ArrayList
    $lineNum = 1
    
    while ($true) {
        $input = Read-Host "URL $lineNum"
        
        if ([string]::IsNullOrWhiteSpace($input)) {
            break
        }
        
        if (Test-Url $input) {
            [void]$urls.Add($input.Trim())
            $lineNum++
        }
        else {
            Write-Status "Invalid URL, skipping" -Type Warning
        }
    }
    
    return $urls.ToArray()
}

# ============================================================================
# Menu Functions
# ============================================================================

function Show-SingleDownloadMenu {
    Show-Banner
    Write-Host "═══ Single Download ═══" -ForegroundColor Yellow
    Write-Host ""
    
    # Get URL
    $url = Read-Host "URL"
    if ([string]::IsNullOrWhiteSpace($url) -or -not (Test-Url $url)) {
        Write-Status "Invalid URL" -Type Warning
        Read-Host "`nPress Enter to continue"
        return
    }
    
    # Select preset
    $presetOptions = @()
    foreach ($key in $script:Presets.Keys) {
        $p = $script:Presets[$key]
        $presetOptions += "$($p.Name) - $($p.Description)"
    }
    $presetOptions += "Custom"
    
    $choice = Read-Choice -Prompt "Download Mode" -Options $presetOptions -AllowQuit
    if ($choice -eq -1) { return }
    
    $preset = $null
    $connections = 16
    $turbo = $false
    
    if ($choice -le $script:Presets.Count) {
        $presetKeys = @($script:Presets.Keys)
        $presetKey = $presetKeys[$choice - 1]
        $preset = $script:Presets[$presetKey]
        $connections = $preset.Connections
        $turbo = $preset.Turbo
    }
    else {
        # Custom settings
        $customConn = Read-Host "Number of connections (1-16)"
        $connections = [Math]::Max(1, [Math]::Min(16, [int]$customConn))
        
        $turboChoice = Read-Choice -Prompt "Use Turbo mode?" -Options @("No", "Yes")
        $turbo = ($turboChoice -eq 2)
    }
    
    # Download
    Start-DownloadTask -Url $url -Connections $connections -Turbo:$turbo
    
    Read-Host "`nPress Enter to continue"
}

function Show-MultiDownloadMenu {
    Show-Banner
    Write-Host "═══ Multiple Downloads ═══" -ForegroundColor Yellow
    Write-Host ""
    
    $urls = Read-Urls
    
    if ($urls.Count -eq 0) {
        Write-Status "No URLs entered" -Type Warning
        Read-Host "`nPress Enter to continue"
        return
    }
    
    Write-Host ""
    Write-Status "Entered $($urls.Count) URL(s)" -Type Info
    
    # Select mode
    $choice = Read-Choice -Prompt "Download mode for all files" `
        -Options @("Balanced - Stable", "Turbo - Maximum speed") -AllowQuit
    
    if ($choice -eq -1) { return }
    
    $turbo = ($choice -eq 2)
    
    # Download all
    Write-Host ""
    Write-Status "Starting download of $($urls.Count) file(s)..." -Type Running
    
    $stats = @{ Success = 0; Failed = 0 }
    
    foreach ($url in $urls) {
        Write-Host "`n$('─' * 60)" -ForegroundColor DarkCyan
        Write-Host "Downloading: $url" -ForegroundColor Cyan
        Write-Host "$('─' * 60)" -ForegroundColor DarkCyan
        
        if (Start-DownloadTask -Url $url -Connections 16 -Turbo:$turbo) {
            $stats.Success++
        }
        else {
            $stats.Failed++
        }
    }
    
    # Summary
    Write-Host ""
    Write-Host "╔════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║              SUMMARY                   ║" -ForegroundColor Cyan
    Write-Host "╠════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host ("║  Successful: {0,-25} ║" -f $stats.Success) -ForegroundColor Green
    
    $failColor = if ($stats.Failed -gt 0) { 'Red' } else { 'Gray' }
    Write-Host ("║  Failed:     {0,-25} ║" -f $stats.Failed) -ForegroundColor $failColor
    Write-Host "╚════════════════════════════════════════╝" -ForegroundColor Cyan
    
    Read-Host "`nPress Enter to continue"
}

function Show-MainMenu {
    while ($true) {
        Show-Banner
        
        $choice = Read-Choice -Prompt "Main Menu" `
            -Options @("Single Download", "Multiple Downloads", "Exit") `
            -AllowQuit
        
        switch ($choice) {
            1 { Show-SingleDownloadMenu }
            2 { Show-MultiDownloadMenu }
            { $_ -eq 3 -or $_ -eq -1 } { return }
        }
    }
}

# ============================================================================
# Main Entry Point
# ============================================================================

# Display platform info
Write-Host "Detected OS: $($script:Config.Platform)" -ForegroundColor Cyan

if (-not (Initialize-Environment)) {
    Write-Status "Failed to initialize environment" -Type Error
    exit 1
}

Show-MainMenu

Write-Host ""
Write-Status "Goodbye!" -Type Success
Write-Host ""
