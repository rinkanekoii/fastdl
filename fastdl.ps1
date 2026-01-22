#Requires -Version 5.1

& {
param(
    [string]$Url,
    [switch]$Fast,
    [switch]$NoProxy
)

$script:OS = if ($IsWindows -or $env:OS -match 'Windows') { 'Windows' }
             elseif ($IsLinux) { 'Linux' }
             elseif ($IsMacOS) { 'macOS' }
             else { 'Windows' }

$script:TempDir = Join-Path ([System.IO.Path]::GetTempPath()) "fastdl_$PID"
$script:Aria2 = $null
$script:ProxyListUrl = 'https://raw.githubusercontent.com/rinkanekoii/fastdl/main/proxies.json'
$script:ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path $MyInvocation.MyCommand.Path } else { $PWD.Path }
$script:LocalProxyFile = Join-Path $script:ScriptRoot 'proxies.json'
$script:Proxy = ''
$script:ProxyTestConfig = @{
    Urls = @('http://www.gstatic.com/generate_204', 'https://www.msftconnecttest.com/connecttest.txt')
    TimeoutSec = 15
    Retries = 2
    RetryDelaySec = 1
}

$script:DownloadDir = if ($script:OS -eq 'Windows') {
    Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads'
} else {
    Join-Path $env:HOME 'Downloads'
}

$script:Presets = @{
    Normal = @{ 
        Label = 'Normal (16 conn, stable)'
        Desc  = 'Reliable for all servers'
        Connections = 16
        Chunk = '1M'
        ConnectTimeout = 15
        Timeout = 600
        MaxTries = 10
        RetryWait = 2
        DiskCache = '64M'
        SocketBuffer = '8M'
    }
    Fast = @{ 
        Label = 'Fast (16 conn, optimized cache)'
        Desc  = 'Better performance, safe timeouts'
        Connections = 16
        Chunk = '1M'
        ConnectTimeout = 15
        Timeout = 600
        MaxTries = 10
        RetryWait = 2
        DiskCache = '256M'
        SocketBuffer = '16M'
    }
    Turbo = @{
        Label = 'Turbo (16 conn, max cache)'
        Desc  = 'Maximum speed optimization'
        Connections = 16
        Chunk = '1M'
        ConnectTimeout = 15
        Timeout = 600
        MaxTries = 10
        RetryWait = 2
        DiskCache = '512M'
        SocketBuffer = '32M'
    }
}

$script:Aria2Urls = @{
    Windows = 'https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0-win-64bit-build1.zip'
    Linux   = 'https://github.com/q3aql/aria2-static-builds/releases/download/v1.37.0/aria2-1.37.0-linux-gnu-64bit-build1.tar.bz2'
    macOS   = 'https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0-osx-darwin.tar.bz2'
}

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

function Test-TcpConnection {
    param([string]$TargetHost, [int]$Port, [int]$TimeoutMs = 5000)
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $connect = $tcp.BeginConnect($TargetHost, $Port, $null, $null)
        $wait = $connect.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($wait -and $tcp.Connected) {
            $tcp.EndConnect($connect)
            $tcp.Close()
            return $true
        }
        $tcp.Close()
        return $false
    }
    catch { return $false }
}

function Test-ProxyAvailable {
    param([string]$ProxyUrl, [int]$TimeoutSec, [int]$Retries, [string[]]$TestUrls, [int]$RetryDelaySec, [switch]$Verbose)
    
    if (-not $ProxyUrl) { return $false }
    
    try {
        $uri = [System.Uri]$ProxyUrl
        $proxyHost = $uri.Host
        $proxyPort = $uri.Port
    }
    catch {
        if ($Verbose) { Write-Status "Invalid proxy URL: $ProxyUrl" -Type Error }
        return $false
    }
    
    if (-not (Test-TcpConnection -TargetHost $proxyHost -Port $proxyPort -TimeoutMs 5000)) {
        if ($Verbose) { Write-Status "TCP connection failed to ${proxyHost}:${proxyPort}" -Type Warning }
        return $false
    }
    
    $config = $script:ProxyTestConfig
    $timeout = if ($TimeoutSec) { $TimeoutSec } else { $config.TimeoutSec }
    $retries = if ($Retries) { $Retries } else { $config.Retries }
    if ($retries -lt 1) { $retries = 1 }
    $retryDelay = if ($RetryDelaySec -ge 0) { $RetryDelaySec } else { $config.RetryDelaySec }
    $targets = if ($TestUrls -and $TestUrls.Count -gt 0) { $TestUrls } else { $config.Urls }
    if (-not $targets -or $targets.Count -eq 0) { $targets = @('http://www.gstatic.com/generate_204') }

    $lastError = $null
    for ($attempt = 1; $attempt -le $retries; $attempt++) {
        foreach ($target in $targets) {
            try {
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest -Uri $target -Proxy $ProxyUrl -TimeoutSec $timeout -UseBasicParsing -Method Get -ErrorAction Stop | Out-Null
                return $true
            }
            catch { $lastError = $_ }
        }
        if ($attempt -lt $retries -and $retryDelay -gt 0) {
            Start-Sleep -Seconds $retryDelay
        }
    }

    if ($Verbose -and $lastError) {
        Write-Status "HTTP via proxy failed: $($lastError.Exception.Message)" -Type Warning
    }
    return $false
}

function Get-ProxyList {
    if (Test-Path $script:LocalProxyFile) {
        try {
            $content = Get-Content $script:LocalProxyFile -Raw -Encoding UTF8
            $data = $content | ConvertFrom-Json
            if ($data.proxies -and $data.proxies.Count -gt 0) {
                Write-Status "Loaded proxies from local file" -Type Success
                return $data.proxies
            }
        }
        catch { Write-Status "Failed to parse local proxies.json: $_" -Type Warning }
    }
    
    try {
        $ProgressPreference = 'SilentlyContinue'
        $response = Invoke-RestMethod -Uri $script:ProxyListUrl -TimeoutSec 10
        return $response.proxies
    }
    catch { return @() }
}

function Initialize-Proxy {
    if ($script:Proxy) { return }
    
    Write-Host ''
    Write-Status 'Loading proxy list...' -Type Action
    $proxies = Get-ProxyList
    
    if ($proxies.Count -eq 0) {
        Write-Status 'No proxies available, using direct connection' -Type Warning
        return
    }
    
    Write-Host ''
    $preChoice = Read-Choice -Prompt "Found $($proxies.Count) proxy(s). What to do?" -Options @(
        'Test and select working proxy',
        'Skip testing, show all proxies',
        'No proxy (direct connection)'
    )
    
    if ($preChoice -eq -1) { exit }
    if ($preChoice -eq 3) {
        Write-Status 'Using direct connection' -Type Info
        return
    }
    
    $allProxies = @()
    $workingProxies = @()
    
    foreach ($p in $proxies) {
        $proxyUrl = "$($p.type)://$($p.ip):$($p.port)"
        $proxyInfo = @{ Url = $proxyUrl; Country = $p.country; Info = $p; Working = $false }
        
        if ($preChoice -eq 1) {
            Write-Host "  Testing $($p.country) ($proxyUrl)... " -NoNewline -ForegroundColor Gray
            
            $tcpOk = Test-TcpConnection -TargetHost $p.ip -Port $p.port -TimeoutMs 5000
            if (-not $tcpOk) {
                Write-Host "FAIL (TCP unreachable)" -ForegroundColor Red
            }
            else {
                Write-Host "TCP OK... " -NoNewline -ForegroundColor DarkGreen
                $httpOk = $false
                foreach ($target in $script:ProxyTestConfig.Urls) {
                    try {
                        $ProgressPreference = 'SilentlyContinue'
                        Invoke-WebRequest -Uri $target -Proxy $proxyUrl -TimeoutSec $script:ProxyTestConfig.TimeoutSec -UseBasicParsing -Method Get -ErrorAction Stop | Out-Null
                        $httpOk = $true
                        break
                    }
                    catch { }
                }
                if ($httpOk) {
                    Write-Host "OK" -ForegroundColor Green
                    $proxyInfo.Working = $true
                    $workingProxies += $proxyInfo
                }
                else {
                    Write-Host "FAIL (HTTP timeout/blocked)" -ForegroundColor Red
                }
            }
        }
        $allProxies += $proxyInfo
    }
    
    $showList = if ($preChoice -eq 1 -and $workingProxies.Count -gt 0) { $workingProxies } else { $allProxies }
    
    if ($preChoice -eq 1 -and $workingProxies.Count -eq 0) {
        Write-Host ''
        Write-Status 'All proxies failed. Show all anyway?' -Type Warning
        $fallback = Read-Choice -Prompt 'Options' -Options @('Show all (try anyway)', 'No proxy (direct)')
        if ($fallback -eq -1) { exit }
        if ($fallback -eq 2) {
            Write-Status 'Using direct connection' -Type Info
            return
        }
        $showList = $allProxies
    }
    
    Write-Host ''
    $listTitle = if ($preChoice -eq 1 -and $workingProxies.Count -gt 0) { 
        "$($workingProxies.Count) working proxy(s):" 
    } else { 
        "$($allProxies.Count) proxy(s) available:" 
    }
    Write-Status $listTitle -Type Info
    
    $options = @()
    foreach ($px in $showList) {
        $status = if ($px.Working) { '[OK]' } elseif ($preChoice -eq 2) { '' } else { '[FAIL]' }
        $options += "$($px.Country) - $($px.Url) $status".Trim()
    }
    $options += 'No proxy (direct connection)'
    
    $choice = Read-Choice -Prompt 'Select proxy' -Options $options
    
    if ($choice -eq -1) { exit }
    if ($choice -le $showList.Count) {
        $selected = $showList[$choice - 1]
        $script:Proxy = $selected.Url
        Write-Status "Proxy enabled: $($script:Proxy)" -Type Success
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
        $n = [System.IO.Path]::GetFileName($path)
        
        if (-not [string]::IsNullOrWhiteSpace($n)) {
            $n = [System.Uri]::UnescapeDataString($n)
        }
        
        if ([string]::IsNullOrWhiteSpace($n) -or $n -eq '/' -or $n -notmatch '\.\w+$') {
            return "download_$(Get-Date -Format 'HHmmss')"
        }
        
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

function Initialize-Aria2 {
    if ($script:Aria2 -and (Test-Path $script:Aria2)) { return $script:Aria2 }

    $cmd = Get-Command aria2c -ErrorAction SilentlyContinue
    if ($cmd) {
        $script:Aria2 = $cmd.Source
        return $script:Aria2
    }

    Write-Status "Downloading aria2 for $($script:OS)..." -Type Action

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
            'Linux'   { 'sudo apt install aria2' }
            'macOS'   { 'brew install aria2' }
        }
        throw "Failed to download aria2. Install manually: $installCmd`nError: $_"
    }
}

function Start-Download {
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$Connections = 16,
        [string]$Chunk = '1M',
        [int]$ConnectTimeout = 15,
        [int]$Timeout = 600,
        [int]$MaxTries = 10,
        [int]$RetryWait = 2,
        [string]$DiskCache = '64M',
        [string]$SocketBuffer = '8M'
    )

    if (-not (Test-Url $Url)) {
        Write-Status 'Invalid URL' -Type Error
        return $false
    }

    $aria2 = Initialize-Aria2

    if (-not (Test-Path $script:DownloadDir)) {
        New-Item -ItemType Directory -Path $script:DownloadDir -Force | Out-Null
    }

    Write-Status "Getting file info..." -Type Action
    $fileInfo = Get-FileInfo -Url $Url
    $totalSize = $fileInfo.Size
    
    $fileName = if ($fileInfo.FileName) { $fileInfo.FileName } else { Get-FileName -U $Url }
    
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

    $conn = [Math]::Min(16, $Connections)

    $aria2Args = @(
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
        '--user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
        "--max-tries=$MaxTries"
        "--retry-wait=$RetryWait"
        "--connect-timeout=$ConnectTimeout"
        "--timeout=$Timeout"
        "--disk-cache=$DiskCache"
        "--socket-recv-buffer-size=$SocketBuffer"
    )

    if ($script:Proxy) {
        $aria2Args += "--all-proxy=$($script:Proxy)"
    }

    Write-Host ''
    Write-Status "$conn connections | Chunk: $Chunk | Cache: $DiskCache | Buffer: $SocketBuffer" -Type Action
    if ($script:Proxy) { Write-Status "Proxy: $($script:Proxy)" -Type Info }
    Write-Status "Save to: $script:DownloadDir\$fileName" -Type Info
    Write-Host ''

    $startTime = Get-Date
    $destFile = Join-Path $script:DownloadDir $fileName
    $ariaControl = "$destFile.aria2"
    
    $initialSize = 0
    if (Test-Path $destFile) {
        $initialSize = (Get-Item $destFile).Length
        if ($initialSize -gt 0) {
            Write-Status "Resuming from $(Format-FileSize $initialSize)..." -Type Info
        }
    }
    
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $aria2
    $psi.Arguments = ($aria2Args | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    
    $outputBuilder = [System.Text.StringBuilder]::new()
    $errorBuilder = [System.Text.StringBuilder]::new()
    
    $outputHandler = { if ($EventArgs.Data) { $outputBuilder.AppendLine($EventArgs.Data) } }
    $errorHandler = { if ($EventArgs.Data) { $errorBuilder.AppendLine($EventArgs.Data) } }
    
    $process.EnableRaisingEvents = $true
    Register-ObjectEvent -InputObject $process -EventName OutputDataReceived -Action $outputHandler -SourceIdentifier "aria2out_$PID" | Out-Null
    Register-ObjectEvent -InputObject $process -EventName ErrorDataReceived -Action $errorHandler -SourceIdentifier "aria2err_$PID" | Out-Null
    
    $code = 0
    try {
        $null = $process.Start()
        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()
        
        $lastBytes = $initialSize
        $lastTime = $startTime
        $currentSpeed = 0
        
        while (-not $process.HasExited) {
            Start-Sleep -Milliseconds 500
            
            $now = Get-Date
            $elapsed = $now - $startTime
            
            $currentBytes = 0
            if (Test-Path $destFile) {
                $currentBytes = (Get-Item $destFile -ErrorAction SilentlyContinue).Length
            }
            
            $intervalSeconds = ($now - $lastTime).TotalSeconds
            if ($intervalSeconds -ge 0.5) {
                $bytesInInterval = $currentBytes - $lastBytes
                $currentSpeed = if ($bytesInInterval -gt 0) { $bytesInInterval / $intervalSeconds } else { $currentSpeed * 0.9 }
                $lastBytes = $currentBytes
                $lastTime = $now
            }
            
            if ($totalSize -gt 0 -and $currentBytes -gt 0) {
                $percent = [Math]::Min(100, [Math]::Round(($currentBytes / $totalSize) * 100, 1))
                
                $remaining = $totalSize - $currentBytes
                $eta = if ($currentSpeed -gt 0) { [TimeSpan]::FromSeconds($remaining / $currentSpeed) } else { [TimeSpan]::Zero }
                $etaStr = if ($eta.TotalSeconds -gt 0) { Format-Duration $eta } else { "--:--" }
                
                $speedStr = Format-Speed $currentSpeed
                $dlStr = Format-FileSize $currentBytes
                $totalStr = Format-FileSize $totalSize
                
                $status = "`r  [{0,5:N1}%]  {1,10} / {2,-10}  Speed: {3,12}  ETA: {4}   " -f $percent, $dlStr, $totalStr, $speedStr, $etaStr
                Write-Host $status -NoNewline
            }
            elseif ($currentBytes -gt 0) {
                $speedStr = Format-Speed $currentSpeed
                $dlStr = Format-FileSize $currentBytes
                $elapsedStr = Format-Duration $elapsed
                
                $status = "`r  Downloaded: {0,10}  Speed: {1,12}  Elapsed: {2}   " -f $dlStr, $speedStr, $elapsedStr
                Write-Host $status -NoNewline
            }
            elseif ($elapsed.TotalSeconds -gt 1) {
                $status = "`r  Connecting... Elapsed: {0}   " -f (Format-Duration $elapsed)
                Write-Host $status -NoNewline
            }
        }
        
        $process.WaitForExit()
        $code = $process.ExitCode
        Write-Host ""
    }
    finally {
        if ($process -and -not $process.HasExited) {
            try {
                $process.Kill()
                $process.WaitForExit(1000)
            }
            catch { }
        }
        if ($process) { $process.Dispose() }
        
        Unregister-Event -SourceIdentifier "aria2out_$PID" -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier "aria2err_$PID" -ErrorAction SilentlyContinue
        Get-Job -Name "aria2out_$PID" -ErrorAction SilentlyContinue | Remove-Job -Force
        Get-Job -Name "aria2err_$PID" -ErrorAction SilentlyContinue | Remove-Job -Force
    }
    
    $endTime = Get-Date
    $totalDuration = $endTime - $startTime
    
    $finalSize = 0
    if (Test-Path $destFile) {
        $finalSize = (Get-Item $destFile).Length
    }
    
    $controlFileExists = Test-Path $ariaControl
    $isSuccess = ($code -eq 0) -or (($totalSize -gt 0) -and ($finalSize -ge $totalSize) -and (-not $controlFileExists))
    
    $downloadedThisSession = $finalSize - $initialSize
    $avgSpeedTotal = if ($totalDuration.TotalSeconds -gt 0 -and $downloadedThisSession -gt 0) { 
        $downloadedThisSession / $totalDuration.TotalSeconds 
    } else { 0 }

    Write-Host ''
    if ($isSuccess) {
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

function Show-Banner {
    Clear-Host
    Write-Host '=====================================' -ForegroundColor Cyan
    Write-Host '  FastDL - High Speed Downloader    ' -ForegroundColor Cyan
    Write-Host "  OS: $($script:OS)" -ForegroundColor DarkGray
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

    Write-Host ''
    $choice = Read-Choice -Prompt 'Download Mode' -Options @(
        "$($script:Presets.Normal.Label) - $($script:Presets.Normal.Desc)",
        "$($script:Presets.Fast.Label) - $($script:Presets.Fast.Desc)",
        "$($script:Presets.Turbo.Label) - $($script:Presets.Turbo.Desc)"
    )
    if ($choice -eq -1) { return }

    $preset = switch ($choice) {
        1 { $script:Presets.Normal }
        2 { $script:Presets.Fast }
        3 { $script:Presets.Turbo }
    }

    $ok = 0; $fail = 0
    foreach ($u in $urls) {
        if ($Multi -and $urls.Count -gt 1) {
            Write-Host "`n$('-' * 50)" -ForegroundColor DarkCyan
            Write-Host $u -ForegroundColor Cyan
        }
        if (Start-Download -Url $u -Connections $preset.Connections -Chunk $preset.Chunk -ConnectTimeout $preset.ConnectTimeout -Timeout $preset.Timeout -MaxTries $preset.MaxTries -RetryWait $preset.RetryWait -DiskCache $preset.DiskCache -SocketBuffer $preset.SocketBuffer) { $ok++ }
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

if ($Url) {
    try {
        Write-Status "OS: $($script:OS)" -Type Info
        Write-Status "Output: $script:DownloadDir" -Type Info
        if (-not $NoProxy) { Initialize-Proxy }
        $preset = if ($Fast) { $script:Presets.Fast } else { $script:Presets.Normal }
        Start-Download -Url $Url -Connections $preset.Connections -Chunk $preset.Chunk -ConnectTimeout $preset.ConnectTimeout -Timeout $preset.Timeout -MaxTries $preset.MaxTries -RetryWait $preset.RetryWait -DiskCache $preset.DiskCache -SocketBuffer $preset.SocketBuffer | Out-Null
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

try {
    Write-Status "OS: $($script:OS)" -Type Info
    Write-Status "Output: $script:DownloadDir" -Type Info
    $null = Initialize-Aria2
    if (-not $NoProxy) {
        Initialize-Proxy
    } else {
        Write-Status 'Direct connection (no proxy)' -Type Info
    }
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
}
