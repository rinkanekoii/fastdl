#Requires -Version 5.1

<#
.SYNOPSIS
    FastDL - High-Speed Download Manager powered by aria2c
.DESCRIPTION
    Multi-threaded download manager with turbo mode and batch support
.NOTES
    Version: 2.0
#>

[CmdletBinding()]
param()

# ============================================================================
# Configuration & Constants
# ============================================================================

$script:Config = @{
    DataDir = Join-Path $env:APPDATA "FastDL"
    TempDir = Join-Path $env:TEMP "fastdl_session"
    Aria2Path = Join-Path (Join-Path $env:APPDATA "FastDL") "aria2c.exe"
    Aria2Version = "1.37.0"
    Aria2Url = "https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0-win-64bit-build1.zip"
    MaxConnections = 16
    MinConnections = 1
    DefaultDownloadDir = Join-Path ([Environment]::GetFolderPath("UserProfile")) "Downloads"
}

$script:Presets = @{
    Balanced = @{
        Name = "Balanced"
        Connections = 16
        ChunkSize = "1M"
        Turbo = $false
        Description = "Ổn định, phù hợp hầu hết các server"
    }
    Turbo = @{
        Name = "Turbo"
        Connections = 16
        ChunkSize = "512K"
        Turbo = $true
        Description = "Tốc độ tối đa, retry tích cực"
    }
    Conservative = @{
        Name = "Conservative"
        Connections = 8
        ChunkSize = "2M"
        Turbo = $false
        Description = "Ít kết nối, phù hợp server chậm"
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
    
    $sizes = @(
        @{ Threshold = 1TB; Format = "{0:N2} TB"; Divisor = 1TB }
        @{ Threshold = 1GB; Format = "{0:N2} GB"; Divisor = 1GB }
        @{ Threshold = 1MB; Format = "{0:N2} MB"; Divisor = 1MB }
        @{ Threshold = 1KB; Format = "{0:N2} KB"; Divisor = 1KB }
    )
    
    foreach ($size in $sizes) {
        if ($Bytes -ge $size.Threshold) {
            return $size.Format -f ($Bytes / $size.Divisor)
        }
    }
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
        Write-Status "Không thể tạo thư mục: $_" -Type Error
        return $false
    }
}

# ============================================================================
# Aria2 Management
# ============================================================================

function Install-Aria2 {
    [CmdletBinding()]
    param()
    
    if (Test-Path $script:Config.Aria2Path) {
        return $true
    }
    
    if (-not (Initialize-Environment)) {
        return $false
    }
    
    Write-Status "Đang tải aria2c (chỉ một lần)..." -Type Running
    
    $zipPath = Join-Path $script:Config.TempDir "aria2.zip"
    $extractPath = Join-Path $script:Config.TempDir "aria2-extract"
    
    try {
        # Download with progress
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $script:Config.Aria2Url -OutFile $zipPath `
            -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
        
        # Extract
        if (Test-Path $extractPath) {
            Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force -ErrorAction Stop
        
        # Find and copy executable
        $exe = Get-ChildItem -Path $extractPath -Recurse -Filter "aria2c.exe" -ErrorAction Stop | 
               Select-Object -First 1
        
        if (-not $exe) {
            throw "Không tìm thấy aria2c.exe trong archive"
        }
        
        Copy-Item $exe.FullName -Destination $script:Config.Aria2Path -Force -ErrorAction Stop
        Write-Status "aria2c đã sẵn sàng" -Type Success
        
        # Cleanup
        Remove-Item $zipPath, $extractPath -Recurse -Force -ErrorAction SilentlyContinue
        
        return $true
    }
    catch {
        Write-Status "Lỗi tải aria2: $_" -Type Error
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
    
    $args = [System.Collections.Generic.List[string]]::new()
    
    # Core arguments
    $args.AddRange(@(
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
        $args.AddRange(@(
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
        $args.AddRange(@(
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
        $args.AddRange(@("-o", "`"$FileName`""))
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
        Write-Status "URL không hợp lệ: $Url" -Type Error
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
            Write-Status "Không thể tạo thư mục đích: $_" -Type Error
            return $false
        }
    }
    
    # Normalize connections
    $Connections = [Math]::Max($script:Config.MinConnections, 
                              [Math]::Min($script:Config.MaxConnections, $Connections))
    
    # Display info
    if (-not $Quiet) {
        Write-Host ""
        Write-Status "Engine: aria2c $($Turbo ? 'TURBO' : 'BALANCED')" -Type Running
        Write-Status "Kết nối: $Connections | Chunk: $($Turbo ? '512K' : '1M')" -Type Info
        Write-Status "Đích: $OutputDir" -Type Info
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
                Write-Status "Hoàn thành! Thời gian: $(Format-Duration $elapsed)" -Type Success
            }
            return $true
        }
        else {
            Write-Status "Tải thất bại (exit code: $($process.ExitCode))" -Type Error
            return $false
        }
    }
    catch {
        Write-Status "Lỗi: $_" -Type Error
        return $false
    }
}

# ============================================================================
# UI Functions
# ============================================================================

function Show-Banner {
    Clear-Host
    $banner = @"
╔════════════════════════════════════════╗
║     FastDL - Trình tải tốc độ cao     ║
║         Powered by aria2c v1.37        ║
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
        Write-Host "  [Q] Thoát" -ForegroundColor DarkGray
    }
    
    Write-Host ""
    
    while ($true) {
        $input = Read-Host "Chọn"
        
        if ($AllowQuit -and $input -match '^[Qq]$') {
            return -1
        }
        
        if ($input -match '^\d+$') {
            $num = [int]$input
            if ($num -ge 1 -and $num -le $Options.Count) {
                return $num
            }
        }
        
        Write-Host "Lựa chọn không hợp lệ" -ForegroundColor Red
    }
}

function Read-Urls {
    [CmdletBinding()]
    param()
    
    Write-Host "Nhập URL (từng dòng, Enter 2 lần để kết thúc):" -ForegroundColor Gray
    Write-Host ""
    
    $urls = [System.Collections.Generic.List[string]]::new()
    $lineNum = 1
    
    while ($true) {
        $input = Read-Host "URL $lineNum"
        
        if ([string]::IsNullOrWhiteSpace($input)) {
            break
        }
        
        if (Test-Url $input) {
            $urls.Add($input.Trim())
            $lineNum++
        }
        else {
            Write-Status "URL không hợp lệ, bỏ qua" -Type Warning
        }
    }
    
    return $urls.ToArray()
}

# ============================================================================
# Menu Functions
# ============================================================================

function Show-SingleDownloadMenu {
    Show-Banner
    Write-Host "═══ Tải đơn ═══" -ForegroundColor Yellow
    Write-Host ""
    
    # Get URL
    $url = Read-Host "URL"
    if ([string]::IsNullOrWhiteSpace($url) -or -not (Test-Url $url)) {
        Write-Status "URL không hợp lệ" -Type Warning
        Read-Host "`nEnter để tiếp tục"
        return
    }
    
    # Select preset
    $presetOptions = $script:Presets.Keys | ForEach-Object {
        $p = $script:Presets[$_]
        "$($p.Name) - $($p.Description)"
    }
    $presetOptions += "Tùy chỉnh"
    
    $choice = Read-Choice -Prompt "Chế độ tải" -Options $presetOptions -AllowQuit
    if ($choice -eq -1) { return }
    
    $preset = $null
    $connections = 16
    $turbo = $false
    
    if ($choice -le $script:Presets.Count) {
        $presetKey = $script:Presets.Keys[$choice - 1]
        $preset = $script:Presets[$presetKey]
        $connections = $preset.Connections
        $turbo = $preset.Turbo
    }
    else {
        # Custom settings
        $customConn = Read-Host "Số kết nối (1-16)"
        $connections = [Math]::Max(1, [Math]::Min(16, [int]$customConn))
        
        $turboChoice = Read-Choice -Prompt "Dùng Turbo?" -Options @("Không", "Có")
        $turbo = ($turboChoice -eq 2)
    }
    
    # Download
    Start-DownloadTask -Url $url -Connections $connections -Turbo:$turbo
    
    Read-Host "`nEnter để tiếp tục"
}

function Show-MultiDownloadMenu {
    Show-Banner
    Write-Host "═══ Tải nhiều file ═══" -ForegroundColor Yellow
    Write-Host ""
    
    $urls = Read-Urls
    
    if ($urls.Count -eq 0) {
        Write-Status "Không có URL nào" -Type Warning
        Read-Host "`nEnter để tiếp tục"
        return
    }
    
    Write-Host ""
    Write-Status "Đã nhập $($urls.Count) URL" -Type Info
    
    # Select mode
    $choice = Read-Choice -Prompt "Chế độ cho tất cả" `
        -Options @("Balanced - Ổn định", "Turbo - Tốc độ tối đa") -AllowQuit
    
    if ($choice -eq -1) { return }
    
    $turbo = ($choice -eq 2)
    
    # Download all
    Write-Host ""
    Write-Status "Bắt đầu tải $($urls.Count) file..." -Type Running
    
    $stats = @{ Success = 0; Failed = 0 }
    
    foreach ($url in $urls) {
        Write-Host "`n$('─' * 60)" -ForegroundColor DarkCyan
        Write-Host "Đang tải: $url" -ForegroundColor Cyan
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
    Write-Host "║            KẾT QUẢ TỔNG QUAN           ║" -ForegroundColor Cyan
    Write-Host "╠════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host ("║  Thành công: {0,-25} ║" -f $stats.Success) -ForegroundColor Green
    Write-Host ("║  Thất bại:   {0,-25} ║" -f $stats.Failed) -ForegroundColor $(if ($stats.Failed -gt 0) { 'Red' } else { 'Gray' })
    Write-Host "╚════════════════════════════════════════╝" -ForegroundColor Cyan
    
    Read-Host "`nEnter để tiếp tục"
}

function Show-MainMenu {
    while ($true) {
        Show-Banner
        
        $choice = Read-Choice -Prompt "Menu chính" `
            -Options @("Tải đơn", "Tải nhiều file", "Thoát") `
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

if (-not (Initialize-Environment)) {
    Write-Status "Không thể khởi tạo môi trường" -Type Error
    exit 1
}

Show-MainMenu

Write-Host ""
Write-Status "Tạm biệt!" -Type Success
Write-Host ""
