#Requires -Version 5.1

<#
.SYNOPSIS
    CLIProxyAPI Tray - Windows System Tray Application
.DESCRIPTION
    A system tray application for managing CLIProxyAPI (Main/Plus channels).
    Features:
    - Single instance enforcement via mutex
    - Channel switching (Main/Plus), mutually exclusive
    - Automatic version download/update from GitHub
    - Shared config.yaml management
    - Password prompt for remote management
    - System tray menu interface
.NOTES
    Version: 1.0
    Author: CLIProxyAPI Team
    Requirements: Windows 10+, PowerShell 5.1+
#>

#region Configuration Constants
$script:Config = @{
    # Application
    AppName = "CLIProxyAPI Tray"
    MutexName = "Global\CLIProxyAPI_Tray_SingleInstance"

    # GitHub Repositories
    MainRepo = "router-for-me/CLIProxyAPI"
    PlusRepo = "router-for-me/CLIProxyAPIPlus"

    # Process Names (without .exe)
    MainProcess = "cli-proxy-api"
    PlusProcess = "cli-proxy-api-plus"

    # Default Values
    DefaultPort = 8317
    DefaultShowProgress = $true
    PortCheckTimeout = 500
    StartupTimeout = 12000

    # UI Settings
    BalloonTipDuration = 1500
    TimerInterval = 1000
}
#endregion

#region Windows API Declarations
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class Win32API {
    // DPI Awareness
    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr dpiContext);

    public static readonly IntPtr DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = new IntPtr(-4);

    // Console Window Management
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    public const int SW_HIDE = 0;
    public const int SW_SHOW = 5;
}
"@
#endregion

#region Assembly Loading
Add-Type -AssemblyName System.Threading
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
#endregion

#region Initialization
function Initialize-Application {
    <#
    .SYNOPSIS
        Initialize application environment
    #>

    # Hide console window
    $consolePtr = [Win32API]::GetConsoleWindow()
    if ($consolePtr -ne [IntPtr]::Zero) {
        [Win32API]::ShowWindow($consolePtr, [Win32API]::SW_HIDE) | Out-Null
    }

    # Enable DPI awareness (Per-Monitor V2)
    try {
        [Win32API]::SetProcessDpiAwarenessContext(
            [Win32API]::DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
        ) | Out-Null
    }
    catch {
        Write-Verbose "DPI awareness not supported on this Windows version"
    }

    # Enforce single instance via mutex
    $createdNew = $false
    $script:AppMutex = New-Object System.Threading.Mutex($true, $script:Config.MutexName, [ref]$createdNew)

    if (-not $createdNew) {
        Write-Warning "Another instance is already running"
        exit 0
    }

    # Ensure STA mode for WinForms
    if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        Start-Process -FilePath "powershell.exe" -ArgumentList @(
            "-STA", "-NoProfile", "-WindowStyle", "Hidden",
            "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`""
        )
        exit 0
    }
}

Initialize-Application
#endregion

#region Path Definitions
$script:LocalDataRoot = if ($env:LOCALAPPDATA) {
    $env:LOCALAPPDATA
}
elseif ($env:APPDATA) {
    $env:APPDATA
}
else {
    $PSScriptRoot
}

$script:Paths = @{
    BaseDir       = $PSScriptRoot
    DataDir       = Join-Path $script:LocalDataRoot "CLIProxyAPI_Tray"
    Config        = Join-Path $PSScriptRoot "config.yaml"
    ConfigExample = Join-Path $PSScriptRoot "config.example.yaml"
    VersionsDir   = Join-Path $PSScriptRoot "versions"
    StateFile     = Join-Path $PSScriptRoot "state.json"
    StateFileFallback = Join-Path (Join-Path $script:LocalDataRoot "CLIProxyAPI_Tray") "state.json"
    LogDir        = Join-Path $PSScriptRoot "logs"
}
#endregion

#region State Management
$script:State = @{
    lastChannel = "main"   # main | plus
    version     = $null    # main tag e.g. v6.7.37
    plusTag     = $null    # plus tag e.g. v6.7.37-0
    arch        = $null    # amd64 | arm64
    autoOpenWebUI = $true  # start/restart auto-open behavior
}

function Get-SystemArchitecture {
    <#
    .SYNOPSIS
        Detect system architecture
    .OUTPUTS
        String - "amd64" or "arm64"
    #>
    $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    return $(if ($arch -eq "Arm64") { "arm64" } else { "amd64" })
}

function Test-DirectoryWritable {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            return $false
        }

        $testFile = Join-Path $Path (".write_test_" + [Guid]::NewGuid().ToString("N") + ".tmp")
        try {
            Set-Content -LiteralPath $testFile -Value "1" -Encoding ASCII -ErrorAction Stop
        }
        finally {
            Remove-Item -LiteralPath $testFile -Force -ErrorAction SilentlyContinue
        }
        return $true
    }
    catch {
        return $false
    }
}

function Import-State {
    <#
    .SYNOPSIS
        Load state from JSON file
    #>
    $primaryPath = $script:Paths.StateFile
    $fallbackPath = $script:Paths.StateFileFallback

    $primaryExists = $primaryPath -and (Test-Path -LiteralPath $primaryPath)
    $fallbackExists = $fallbackPath -and (Test-Path -LiteralPath $fallbackPath)

    $statePath = $null
    if ($primaryExists -and $fallbackExists) {
        $primaryDir = Split-Path -Parent $primaryPath

        if ($primaryDir -and (-not (Test-DirectoryWritable -Path $primaryDir))) {
            $statePath = $fallbackPath
        }
        else {
            # 两份文件都存在时优先使用最近更新的那份。
            $primaryTime = (Get-Item -LiteralPath $primaryPath).LastWriteTimeUtc
            $fallbackTime = (Get-Item -LiteralPath $fallbackPath).LastWriteTimeUtc
            $statePath = if ($fallbackTime -gt $primaryTime) { $fallbackPath } else { $primaryPath }
        }
    }
    elseif ($primaryExists) {
        $statePath = $primaryPath
    }
    elseif ($fallbackExists) {
        $statePath = $fallbackPath
    }
    else {
        return
    }

    # 后续保存沿用加载到的路径，避免反复写失败或写回旧文件。
    $script:Paths.StateFile = $statePath

    try {
        $obj = Get-Content -LiteralPath $statePath -Raw -ErrorAction Stop |
               ConvertFrom-Json

        if ($obj.lastChannel -in @("main", "plus")) {
            $script:State.lastChannel = [string]$obj.lastChannel
        }
        if ($obj.version) { $script:State.version = [string]$obj.version }
        if ($obj.plusTag) { $script:State.plusTag = [string]$obj.plusTag }
        if ($obj.arch)    { $script:State.arch = [string]$obj.arch }
        if ($null -ne $obj.autoOpenWebUI) {
            $script:State.autoOpenWebUI = [bool]$obj.autoOpenWebUI
        }
    }
    catch {
        Write-Warning "Failed to load state: $($_.Exception.Message)"
    }
}

function Export-State {
    <#
    .SYNOPSIS
        Save current state to JSON file
    #>
    try {
        $stateObject = [PSCustomObject]@{
            lastChannel = $script:State.lastChannel
            version     = $script:State.version
            plusTag     = $script:State.plusTag
            arch        = $script:State.arch
            autoOpenWebUI = [bool]$script:State.autoOpenWebUI
            updatedAt   = (Get-Date).ToString("o")
        }

        $json = $stateObject | ConvertTo-Json -Compress

        try {
            $json | Set-Content -LiteralPath $script:Paths.StateFile -Encoding UTF8 -ErrorAction Stop
            return $true
        }
        catch {
            # 脚本目录可能不可写（例如放在 Program Files），则降级写到用户目录。
            $primaryErr = $_.Exception.Message

            try {
                $fallbackPath = $script:Paths.StateFileFallback
                $fallbackDir = Split-Path -Parent $fallbackPath
                if ($fallbackDir) {
                    New-Item -ItemType Directory -Path $fallbackDir -Force | Out-Null
                }

                $json | Set-Content -LiteralPath $fallbackPath -Encoding UTF8 -ErrorAction Stop

                # 后续统一用可写路径，避免每次保存都失败。
                $script:Paths.StateFile = $fallbackPath

                if (-not $script:StateFileWriteFallbackNotified) {
                    $script:StateFileWriteFallbackNotified = $true
                    Show-BalloonTip "state.json 保存失败（$primaryErr），已改为写入：$fallbackPath" -Icon Warning -Duration 2500
                }
                return $true
            }
            catch {
                if (-not $script:StateFileWriteFailedNotified) {
                    $script:StateFileWriteFailedNotified = $true
                    Show-BalloonTip "state.json 保存失败：$primaryErr" -Icon Error -Duration 2500
                }
                Write-Warning "Failed to save state: $primaryErr"
                return $false
            }
        }
    }
    catch {
        Write-Warning "Failed to save state: $($_.Exception.Message)"
        return $false
    }
}
#endregion

#region Tray Icon Initialization
$script:TrayIcon = New-Object System.Windows.Forms.NotifyIcon
$script:TrayIcon.Icon = [System.Drawing.SystemIcons]::Application
$script:TrayIcon.Visible = $true
$script:TrayIcon.Text = $script:Config.AppName
#endregion

#region Configuration Management
function Test-ConfigExists {
    <#
    .SYNOPSIS
        Ensure config.yaml exists, create from example if missing
    .OUTPUTS
        Boolean - $true if config exists or was created successfully
    #>
    if (Test-Path $script:Paths.Config) {
        return $true
    }

    if (-not (Test-Path $script:Paths.ConfigExample)) {
        [System.Windows.Forms.MessageBox]::Show(
            "config.yaml is missing and config.example.yaml was not found.`nCannot continue.",
            $script:Config.AppName,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return $false
    }

    try {
        Copy-Item -LiteralPath $script:Paths.ConfigExample -Destination $script:Paths.Config -Force
        Show-BalloonTip "Created config.yaml from config.example.yaml" -Icon Info
        return $true
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Failed to create config.yaml:`n$($_.Exception.Message)",
            $script:Config.AppName,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return $false
    }
}

function Get-ConfigValue {
    <#
    .SYNOPSIS
        Extract a value from config.yaml
    .PARAMETER Key
        The YAML key to search for
    .PARAMETER Pattern
        Regex pattern to match the value
    .PARAMETER Default
        Default value if not found
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Key,

        [Parameter(Mandatory)]
        [string]$Pattern,

        [object]$Default = $null
    )

    if (-not (Test-Path $script:Paths.Config)) {
        return $Default
    }

    try {
        $line = Get-Content -LiteralPath $script:Paths.Config -ErrorAction Stop |
                Where-Object { $_ -match "^\s*$Key\s*:\s*$Pattern" } |
                Select-Object -First 1

        if ($line -and ($line -match "^\s*$Key\s*:\s*(.+)")) {
            return $Matches[1].Trim()
        }
    }
    catch {
        Write-Warning "Failed to read config value '$Key': $($_.Exception.Message)"
    }

    return $Default
}

function Get-PortFromConfig {
    <#
    .SYNOPSIS
        Get port number from config.yaml
    #>
    param([int]$DefaultPort = $script:Config.DefaultPort)

    $portValue = Get-ConfigValue -Key "port" -Pattern "\d+" -Default $DefaultPort

    if ($portValue -match '^\d+$') {
        return [int]$portValue
    }

    return $DefaultPort
}

function Get-ShowUpdateProgressFromConfig {
    <#
    .SYNOPSIS
        Get show-update-progress setting from config.yaml
    #>
    param([bool]$Default = $script:Config.DefaultShowProgress)

    $value = Get-ConfigValue -Key "show-update-progress" -Pattern "(true|false)" -Default $Default.ToString().ToLower()

    return ($value -eq 'true')
}

function Get-SecretKeyFromConfig {
    <#
    .SYNOPSIS
        Extract secret-key from config.yaml
    .OUTPUTS
        String - The secret key value, or empty string if not found
    #>
    if (-not (Test-Path $script:Paths.Config)) {
        return ""
    }

    try {
        $lines = Get-Content -LiteralPath $script:Paths.Config -ErrorAction Stop

        foreach ($line in $lines) {
            if ($line -match '^\s*secret-key\s*:\s*(.+)\s*$') {
                $value = $Matches[1].Trim()

                # Remove quotes if present
                if ($value -match '^"(.*)"$' -or $value -match "^'(.*)'$") {
                    $value = $Matches[1]
                }

                return $value.Trim()
            }
        }
    }
    catch {
        Write-Warning "Failed to read secret-key: $($_.Exception.Message)"
    }

    return ""
}

function Set-SecretKeyInConfig {
    <#
    .SYNOPSIS
        Update secret-key in config.yaml
    .PARAMETER NewKey
        The new secret key value
    .OUTPUTS
        Boolean - $true if successful
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$NewKey
    )

    if (-not (Test-Path $script:Paths.Config)) {
        return $false
    }

    try {
        $lines = Get-Content -LiteralPath $script:Paths.Config -ErrorAction Stop
        $updated = $false

        # Replace existing secret-key
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*secret-key\s*:') {
                $indent = ($lines[$i] -replace '^(\s*).*$', '$1')
                $lines[$i] = "${indent}secret-key: `"$NewKey`""
                $updated = $true
                break
            }
        }

        # If not found, insert into remote-management section
        if (-not $updated) {
            $rmIndex = -1
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^\s*remote-management\s*:\s*$') {
                    $rmIndex = $i
                    break
                }
            }

            if ($rmIndex -ge 0) {
                # Find insertion point (end of remote-management block)
                $insertAt = $rmIndex + 1
                for ($j = $rmIndex + 1; $j -lt $lines.Count; $j++) {
                    if ($lines[$j] -match '^\S') {
                        $insertAt = $j
                        break
                    }
                    $insertAt = $j + 1
                }

                # Check if allow-remote exists
                $hasAllow = $false
                for ($k = $rmIndex + 1; $k -lt $lines.Count; $k++) {
                    if ($lines[$k] -match '^\S') { break }
                    if ($lines[$k] -match '^\s*allow-remote\s*:') {
                        $hasAllow = $true
                        break
                    }
                }

                # Build insertion block
                $block = @()
                if (-not $hasAllow) {
                    $block += '  allow-remote: false'
                }
                $block += "  secret-key: `"$NewKey`""

                # Insert block
                if ($insertAt -le 0) {
                    $lines = @($lines + $block)
                }
                else {
                    $lines = @($lines[0..($insertAt - 1)] + $block + $lines[$insertAt..($lines.Count - 1)])
                }
            }
            else {
                # Add new remote-management section
                $lines = @(
                    $lines +
                    "" +
                    "remote-management:" +
                    "  allow-remote: false" +
                    "  secret-key: `"$NewKey`""
                )
            }
        }

        $lines | Set-Content -LiteralPath $script:Paths.Config -Encoding UTF8 -ErrorAction Stop
        return $true
    }
    catch {
        Write-Warning "Failed to update secret-key: $($_.Exception.Message)"
        return $false
    }
}

function Request-Password {
    <#
    .SYNOPSIS
        Prompt user for password input
    .OUTPUTS
        String - The password, or empty string if cancelled
    #>
    param(
        [string]$Title = "Password Required",
        [string]$Prompt = "Please enter password:"
    )

    $password = ""
    while ([string]::IsNullOrWhiteSpace($password)) {
        $password = [Microsoft.VisualBasic.Interaction]::InputBox($Prompt, $Title, "")

        if ($password -eq "") {
            return ""  # User cancelled
        }

        $password = $password.Trim()
    }

    return $password
}

function Test-PasswordConfigured {
    <#
    .SYNOPSIS
        Ensure password is set in config, prompt if missing
    .OUTPUTS
        Boolean - $true if password is configured
    #>
    if (-not (Test-ConfigExists)) {
        return $false
    }

    $key = Get-SecretKeyFromConfig
    if (-not [string]::IsNullOrWhiteSpace($key)) {
        return $true
    }

    $password = Request-Password -Title "Set Password" -Prompt "config.yaml secret-key is empty.`nPlease enter a password:"

    if ([string]::IsNullOrWhiteSpace($password)) {
        return $false
    }

    if (Set-SecretKeyInConfig $password) {
        Show-BalloonTip "Password saved to config.yaml" -Icon Info
        return $true
    }

    Show-BalloonTip "Failed to write password to config.yaml" -Icon Error -Duration 2000
    return $false
}
#endregion

#region Network Utilities
function Test-PortListening {
    <#
    .SYNOPSIS
        Check if a TCP port is listening
    .OUTPUTS
        Boolean - $true if port is open
    #>
    param(
        [Parameter(Mandatory)]
        [int]$Port,

        [int]$TimeoutMs = $script:Config.PortCheckTimeout,
        [string]$HostAddress = "127.0.0.1"
    )

    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $asyncResult = $client.BeginConnect($HostAddress, $Port, $null, $null)
        $success = $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMs, $false)

        if ($success) {
            $client.EndConnect($asyncResult)
            $client.Close()
            return $true
        }

        $client.Close()
    }
    catch {
        # Connection failed
    }

    return $false
}

function Wait-PortListening {
    <#
    .SYNOPSIS
        Wait for a port to become available
    .OUTPUTS
        Boolean - $true if port became available within timeout
    #>
    param(
        [Parameter(Mandatory)]
        [int]$Port,

        [int]$TimeoutMs = $script:Config.StartupTimeout
    )

    $startTime = Get-Date

    while (((Get-Date) - $startTime).TotalMilliseconds -lt $TimeoutMs) {
        if (Test-PortListening -Port $Port -TimeoutMs 350) {
            return $true
        }
        Start-Sleep -Milliseconds 200
    }

    return $false
}
#endregion

#region Process Management
function Get-ActiveChannel {
    <#
    .SYNOPSIS
        Detect which channel is currently running
    .OUTPUTS
        String - "main", "plus", or "" if neither
    #>
    if (Get-Process -Name $script:Config.PlusProcess -ErrorAction SilentlyContinue) {
        return "plus"
    }

    if (Get-Process -Name $script:Config.MainProcess -ErrorAction SilentlyContinue) {
        return "main"
    }

    return ""
}

function Stop-AllChannels {
    <#
    .SYNOPSIS
        Stop all running channel processes
    #>
    try {
        Get-Process -Name $script:Config.MainProcess -ErrorAction SilentlyContinue |
            Stop-Process -Force
    }
    catch {
        Write-Verbose "No main process to stop"
    }

    try {
        Get-Process -Name $script:Config.PlusProcess -ErrorAction SilentlyContinue |
            Stop-Process -Force
    }
    catch {
        Write-Verbose "No plus process to stop"
    }

    Start-Sleep -Milliseconds 200
}
#endregion

#region GitHub Integration
function Get-LatestGitHubTag {
    <#
    .SYNOPSIS
        Get the latest release tag from a GitHub repository
    .PARAMETER Repository
        Repository in format "owner/repo"
    .OUTPUTS
        String - The latest tag name
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Repository
    )

    $headers = @{ "User-Agent" = $script:Config.AppName }
    $url = "https://api.github.com/repos/$Repository/releases/latest"

    try {
        $response = Invoke-RestMethod -Uri $url -Headers $headers -Method Get -ErrorAction Stop
        return $response.tag_name
    }
    catch {
        throw "Failed to get latest tag from $Repository : $($_.Exception.Message)"
    }
}

function Get-GitHubAssetUrl {
    <#
    .SYNOPSIS
        Find download URL for a specific asset in latest release
    .OUTPUTS
        String - The browser download URL
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Repository,

        [Parameter(Mandatory)]
        [string]$AssetName
    )

    $headers = @{ "User-Agent" = $script:Config.AppName }
    $url = "https://api.github.com/repos/$Repository/releases/latest"

    try {
        $release = Invoke-RestMethod -Uri $url -Headers $headers -Method Get -ErrorAction Stop
        $asset = $release.assets | Where-Object { $_.name -eq $AssetName } | Select-Object -First 1

        if (-not $asset) {
            throw "Asset not found: $AssetName"
        }

        return $asset.browser_download_url
    }
    catch {
        throw "Failed to get asset URL for $AssetName : $($_.Exception.Message)"
    }
}

function Invoke-PackageDownload {
    <#
    .SYNOPSIS
        Download both Main and Plus packages with optional progress UI
    #>
    param(
        [Parameter(Mandatory)]
        [string]$MainUrl,

        [Parameter(Mandatory)]
        [string]$MainOutputPath,

        [Parameter(Mandatory)]
        [string]$PlusUrl,

        [Parameter(Mandatory)]
        [string]$PlusOutputPath,

        [bool]$ShowProgress = $true
    )

    if (-not $ShowProgress) {
        # Simple synchronous download without UI
        $webClient = New-Object System.Net.WebClient
        $webClient.Headers.Add("User-Agent", $script:Config.AppName)

        try {
            Show-BalloonTip "Downloading Main..." -Icon Info -Duration 1200
            $webClient.DownloadFile($MainUrl, $MainOutputPath)

            Show-BalloonTip "Downloading Plus..." -Icon Info -Duration 1200
            $webClient.DownloadFile($PlusUrl, $PlusOutputPath)
        }
        finally {
            $webClient.Dispose()
        }

        return
    }

    # Create progress form
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Downloading Updates"
    $form.Size = New-Object System.Drawing.Size(400, 150)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true
    $form.ShowInTaskbar = $true

    $label = New-Object System.Windows.Forms.Label
    $label.Text = "Initializing..."
    $label.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $label.AutoSize = $false
    $label.Location = New-Object System.Drawing.Point(20, 40)
    $label.Size = New-Object System.Drawing.Size(340, 30)
    $label.TextAlign = "MiddleCenter"
    $form.Controls.Add($label)

    $webClient = New-Object System.Net.WebClient
    $webClient.Headers.Add("User-Agent", $script:Config.AppName)

    # Download state
    $script:CurrentDownload = "main"
    $script:DownloadError = $null

    # Progress event
    $webClient.add_DownloadProgressChanged({
        param($sender, $e)
        $channelName = if ($script:CurrentDownload -eq "main") { "Main" } else { "Plus" }
        $label.Text = "Downloading ${channelName}: $($e.ProgressPercentage)%  ($([math]::Round($e.BytesReceived / 1MB, 1)) MB / $([math]::Round($e.TotalBytesToReceive / 1MB, 1)) MB)"
    })

    # Completion event
    $webClient.add_DownloadFileCompleted({
        param($sender, $e)

        if ($e.Error) {
            $script:DownloadError = $e.Error
            $form.Close()
            return
        }

        if ($script:CurrentDownload -eq "main") {
            # Start Plus download
            $script:CurrentDownload = "plus"
            $label.Text = "Starting Plus download..."

            try {
                $webClient.DownloadFileAsync($PlusUrl, $PlusOutputPath)
            }
            catch {
                $script:DownloadError = $_.Exception
                $form.Close()
            }
        }
        else {
            # Both downloads complete
            $form.Close()
        }
    })

    # Start Main download when form is shown
    $form.add_Shown({
        try {
            $webClient.DownloadFileAsync($MainUrl, $MainOutputPath)
        }
        catch {
            $script:DownloadError = $_.Exception
            $form.Close()
        }
    })

    # Show modal dialog (blocks but pumps messages)
    $form.ShowDialog() | Out-Null

    # Cleanup
    $form.Dispose()
    $webClient.Dispose()

    if ($script:DownloadError) {
        throw $script:DownloadError
    }
}
#endregion

#region Version Management
function Test-VersionInstalled {
    <#
    .SYNOPSIS
        Check if current version is installed, download if not
    .OUTPUTS
        Boolean - $true if version is ready to use
    #>

    # Check if current version binaries exist
    if ($script:State.version) {
        $versionDir = Join-Path $script:Paths.VersionsDir $script:State.version
        $mainExe = Join-Path $versionDir "cli-proxy-api.exe"
        $plusExe = Join-Path $versionDir "cli-proxy-api-plus.exe"

        if ((Test-Path $mainExe) -and (Test-Path $plusExe)) {
            return $true
        }
    }

    # Need to download
    $arch = Get-SystemArchitecture

    try {
        $mainTag = Get-LatestGitHubTag -Repository $script:Config.MainRepo
        $plusTag = Get-LatestGitHubTag -Repository $script:Config.PlusRepo
        $mainVersion = $mainTag.TrimStart("v")

        $script:State.arch = $arch

        $message = @"
No version installed.

Latest:
Main: $mainTag
Plus: $plusTag
Architecture: $arch

Download now?
"@

        $result = [System.Windows.Forms.MessageBox]::Show(
            $message,
            $script:Config.AppName,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )

        if ($result -ne [System.Windows.Forms.DialogResult]::Yes) {
            # User declined download, check if any old version exists
            if (Test-Path $script:Paths.VersionsDir) {
                $existingVersions = Get-ChildItem -Path $script:Paths.VersionsDir -Directory |
                                    Where-Object {
                                        (Test-Path (Join-Path $_.FullName "cli-proxy-api.exe")) -and
                                        (Test-Path (Join-Path $_.FullName "cli-proxy-api-plus.exe"))
                                    } |
                                    Sort-Object Name -Descending |
                                    Select-Object -First 1

                if ($existingVersions) {
                    # Use the latest existing version
                    $script:State.version = $existingVersions.Name
                    $script:State.plusTag = $existingVersions.Name
                    Export-State | Out-Null
                    Show-BalloonTip "Using existing version: $($existingVersions.Name)" -Icon Info -Duration 1500
                    return $true
                }
            }
            return $false
        }

        # Create directories
        New-Item -ItemType Directory -Path $script:Paths.VersionsDir -Force | Out-Null
        $versionDir = Join-Path $script:Paths.VersionsDir $mainTag
        New-Item -ItemType Directory -Path $versionDir -Force | Out-Null

        # Build asset names
        $plusVersion = $plusTag.TrimStart("v")
        $mainZipName = "CLIProxyAPI_${mainVersion}_windows_${arch}.zip"
        $plusZipName = "CLIProxyAPIPlus_${plusVersion}_windows_${arch}.zip"

        # Create temp directory
        $tempDir = Join-Path $env:TEMP ("cliproxy_update_" + [Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $tempDir | Out-Null

        $showProgress = Get-ShowUpdateProgressFromConfig

        try {
            # Get download URLs
            $mainUrl = Get-GitHubAssetUrl -Repository $script:Config.MainRepo -AssetName $mainZipName
            $plusUrl = Get-GitHubAssetUrl -Repository $script:Config.PlusRepo -AssetName $plusZipName

            $mainZipPath = Join-Path $tempDir $mainZipName
            $plusZipPath = Join-Path $tempDir $plusZipName

            # Download
            Invoke-PackageDownload -MainUrl $mainUrl -MainOutputPath $mainZipPath `
                                   -PlusUrl $plusUrl -PlusOutputPath $plusZipPath `
                                   -ShowProgress $showProgress

            # Extract
            $mainExtractDir = Join-Path $tempDir "main"
            $plusExtractDir = Join-Path $tempDir "plus"

            Show-BalloonTip "Extracting files..." -Icon Info -Duration 1200
            Expand-Archive -LiteralPath $mainZipPath -DestinationPath $mainExtractDir -Force
            Expand-Archive -LiteralPath $plusZipPath -DestinationPath $plusExtractDir -Force

            # Find executables
            $mainExeFile = Get-ChildItem -Path $mainExtractDir -Recurse -Filter "*.exe" |
                           Select-Object -First 1
            $plusExeFile = Get-ChildItem -Path $plusExtractDir -Recurse -Filter "*.exe" |
                           Select-Object -First 1

            if (-not $mainExeFile) {
                throw "Main executable not found in downloaded package"
            }
            if (-not $plusExeFile) {
                throw "Plus executable not found in downloaded package"
            }

            # Stop running processes
            Stop-AllChannels

            # Copy to version directory
            Copy-Item -LiteralPath $mainExeFile.FullName -Destination (Join-Path $versionDir "cli-proxy-api.exe") -Force
            Copy-Item -LiteralPath $plusExeFile.FullName -Destination (Join-Path $versionDir "cli-proxy-api-plus.exe") -Force

            # Update state
            $script:State.version = $mainTag
            $script:State.plusTag = $plusTag
            Export-State | Out-Null

            Show-BalloonTip "Installed $mainTag" -Icon Info -Duration 1500
            return $true
        }
        catch {
            Show-BalloonTip "Update failed: $($_.Exception.Message)" -Icon Error -Duration 2500
            return $false
        }
        finally {
            try {
                Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
            }
            catch {
                # Ignore cleanup errors
            }
        }
    }
    catch {
        Show-BalloonTip "Failed to check for updates: $($_.Exception.Message)" -Icon Error -Duration 2500
        return $false
    }
}

function Get-ChannelExecutablePath {
    <#
    .SYNOPSIS
        Get executable path for specified channel
    .OUTPUTS
        String - Full path to executable, or $null if not found
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet("main", "plus")]
        [string]$Channel
    )

    if (-not $script:State.version) {
        return $null
    }

    $versionDir = Join-Path $script:Paths.VersionsDir $script:State.version

    if ($Channel -eq "plus") {
        return (Join-Path $versionDir "cli-proxy-api-plus.exe")
    }

    return (Join-Path $versionDir "cli-proxy-api.exe")
}
#endregion

#region Channel Operations
function Start-Channel {
    <#
    .SYNOPSIS
        Start a specific channel (main or plus)
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet("main", "plus")]
        [string]$Channel
    )

    # Ensure password is configured
    if (-not (Test-PasswordConfigured)) {
        Show-BalloonTip "Password not set. Start cancelled." -Icon Warning -Duration 2000
        return
    }

    # Save last channel preference
    $script:State.lastChannel = $Channel
    Export-State | Out-Null

    # Ensure version is installed
    if (-not (Test-VersionInstalled)) {
        return
    }

    # Get executable path
    $exePath = Get-ChannelExecutablePath -Channel $Channel

    if (-not $exePath -or -not (Test-Path $exePath)) {
        Show-BalloonTip "Executable not found for current version" -Icon Error -Duration 2500
        return
    }

    # Stop any running channels
    Stop-AllChannels

    # Build arguments
    $arguments = "--config `"$($script:Paths.Config)`""

    try {
        # Start process
        Start-Process -FilePath $exePath -ArgumentList $arguments -WindowStyle Hidden | Out-Null

        # Wait for port to become available
        $port = Get-PortFromConfig
        $portReady = Wait-PortListening -Port $port -TimeoutMs $script:Config.StartupTimeout

        # Update UI
        Update-TrayState

        if ($portReady) {
            Show-BalloonTip "Started: $Channel" -Icon Info -Duration 1200

            if ([bool]$script:State.autoOpenWebUI) {
                Start-Sleep -Seconds 1
                Open-WebUI
            }
        }
        else {
            Show-BalloonTip "Started, but port not ready yet" -Icon Warning -Duration 2500
        }
    }
    catch {
        Show-BalloonTip "Start failed: $($_.Exception.Message)" -Icon Error -Duration 2500
    }
}

function Restart-Channel {
    <#
    .SYNOPSIS
        Restart currently active or last used channel
    #>
    $activeChannel = Get-ActiveChannel
    $channelToStart = if ($activeChannel -ne "") { $activeChannel } else { $script:State.lastChannel }

    Start-Channel -Channel $channelToStart
}

function Invoke-Update {
    <#
    .SYNOPSIS
        Check for and install updates
    #>
    try {
        $latestMainTag = Get-LatestGitHubTag -Repository $script:Config.MainRepo
        $latestPlusTag = Get-LatestGitHubTag -Repository $script:Config.PlusRepo

        # Check if already up to date
        if ($script:State.version -and ($script:State.version -eq $latestMainTag)) {
            Show-BalloonTip "Already latest: $latestMainTag" -Icon Info -Duration 1500
            return
        }

        $message = @"
New version found:
Main: $latestMainTag
Plus: $latestPlusTag

Download and install?
"@

        $result = [System.Windows.Forms.MessageBox]::Show(
            $message,
            $script:Config.AppName,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )

        if ($result -ne [System.Windows.Forms.DialogResult]::Yes) {
            Show-BalloonTip "Update cancelled" -Icon Info -Duration 1200
            return
        }

        # Clear version to force new install
        $script:State.version = $null
        $script:State.plusTag = $null
        $script:State.arch = Get-SystemArchitecture
        Export-State | Out-Null

        # Install new version
        if (Test-VersionInstalled) {
            Start-Channel -Channel $script:State.lastChannel
        }
    }
    catch {
        Show-BalloonTip "Update check failed: $($_.Exception.Message)" -Icon Error -Duration 2500
    }
}
#endregion

#region UI Operations
function Show-BalloonTip {
    <#
    .SYNOPSIS
        Show a balloon tip notification
    #>
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,

        [ValidateSet("None", "Info", "Warning", "Error")]
        [string]$Icon = "Info",

        [int]$Duration = $script:Config.BalloonTipDuration
    )

    $script:TrayIcon.ShowBalloonTip($Duration, $script:Config.AppName, $Message, $Icon)
}

function Open-WebUI {
    <#
    .SYNOPSIS
        Open the web management UI in default browser
    #>
    $port = Get-PortFromConfig

    if (-not (Test-PortListening -Port $port -TimeoutMs 500)) {
        Show-BalloonTip "Not running (port not listening)" -Icon Info -Duration 1500
        return
    }

    Start-Process "http://127.0.0.1:$port/management.html"
}

function Open-ApplicationFolder {
    <#
    .SYNOPSIS
        Open the application folder in Explorer
    #>
    Start-Process -FilePath "explorer.exe" -ArgumentList "`"$($script:Paths.BaseDir)`""
}

function Update-TrayState {
    <#
    .SYNOPSIS
        Update tray icon and menu state based on running channel
    #>
    $activeChannel = Get-ActiveChannel

    # Update channel checkmarks
    $script:MenuItems.ChannelMain.Checked = ($script:State.lastChannel -eq "main")
    $script:MenuItems.ChannelPlus.Checked = ($script:State.lastChannel -eq "plus")
    if ($script:MenuItems.AutoOpenWebUI) {
        $script:MenuItems.AutoOpenWebUI.Checked = [bool]$script:State.autoOpenWebUI
    }

    # Update status display
    if ($activeChannel -eq "main") {
        $version = if ($script:State.version) { $script:State.version } else { "v?" }
        $script:MenuItems.CurrentStatus.Text = "Current : Main ($version)"
        $script:TrayIcon.Text = "$($script:Config.AppName) - Main"

        if ($script:State.lastChannel -ne "main") {
            $script:State.lastChannel = "main"
            Export-State | Out-Null
        }

        $script:MenuItems.Restart.Enabled = $true
        $script:MenuItems.Stop.Enabled = $true
    }
    elseif ($activeChannel -eq "plus") {
        $plusVersion = if ($script:State.plusTag) { $script:State.plusTag } else { "v?-0" }
        $script:MenuItems.CurrentStatus.Text = "Current : Plus ($plusVersion)"
        $script:TrayIcon.Text = "$($script:Config.AppName) - Plus"

        if ($script:State.lastChannel -ne "plus") {
            $script:State.lastChannel = "plus"
            Export-State | Out-Null
        }

        $script:MenuItems.Restart.Enabled = $true
        $script:MenuItems.Stop.Enabled = $true
    }
    else {
        $script:MenuItems.CurrentStatus.Text = "Current : Not Running"
        $script:TrayIcon.Text = $script:Config.AppName

        $script:MenuItems.Restart.Enabled = $false
        $script:MenuItems.Stop.Enabled = $false
    }
}
#endregion

#region Menu Construction
function New-TrayMenu {
    <#
    .SYNOPSIS
        Build the tray icon context menu
    #>
    $menu = New-Object System.Windows.Forms.ContextMenuStrip

    # Store menu items for later reference
    $script:MenuItems = @{}

    # Current status (disabled label)
    $script:MenuItems.CurrentStatus = New-Object System.Windows.Forms.ToolStripMenuItem
    $script:MenuItems.CurrentStatus.Enabled = $false
    $script:MenuItems.CurrentStatus.Text = "Current : Not Running"
    $menu.Items.Add($script:MenuItems.CurrentStatus) | Out-Null

    $menu.Items.Add("-") | Out-Null

    # Channel submenu
    $channelMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $channelMenu.Text = "Channel"

    $script:MenuItems.ChannelMain = New-Object System.Windows.Forms.ToolStripMenuItem
    $script:MenuItems.ChannelMain.Text = "Main"
    $script:MenuItems.ChannelMain.Add_Click({
        Start-Channel -Channel "main"
    })

    $script:MenuItems.ChannelPlus = New-Object System.Windows.Forms.ToolStripMenuItem
    $script:MenuItems.ChannelPlus.Text = "Plus"
    $script:MenuItems.ChannelPlus.Add_Click({
        Start-Channel -Channel "plus"
    })

    $channelMenu.DropDownItems.Add($script:MenuItems.ChannelMain) | Out-Null
    $channelMenu.DropDownItems.Add($script:MenuItems.ChannelPlus) | Out-Null
    $menu.Items.Add($channelMenu) | Out-Null

    # Open submenu
    $openMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $openMenu.Text = "Open"

    $openWebItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $openWebItem.Text = "WebUI"
    $openWebItem.Add_Click({ Open-WebUI })

    $openFolderItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $openFolderItem.Text = "Folder"
    $openFolderItem.Add_Click({ Open-ApplicationFolder })

    $openMenu.DropDownItems.Add($openWebItem) | Out-Null
    $openMenu.DropDownItems.Add($openFolderItem) | Out-Null
    $menu.Items.Add($openMenu) | Out-Null

    $menu.Items.Add("-") | Out-Null

    # Reset Password
    $resetPasswordItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $resetPasswordItem.Text = "Reset Password"
    $resetPasswordItem.Add_Click({
        if (-not (Test-ConfigExists)) {
            return
        }

        $newPassword = Request-Password -Title "Reset Password" -Prompt "Enter new password (secret-key):"

        if ([string]::IsNullOrWhiteSpace($newPassword)) {
            return
        }

        if (Set-SecretKeyInConfig $newPassword) {
            Show-BalloonTip "Password updated" -Icon Info -Duration 1200
        }
        else {
            Show-BalloonTip "Failed to update password" -Icon Error -Duration 2000
        }
    })
    $menu.Items.Add($resetPasswordItem) | Out-Null

    $script:MenuItems.AutoOpenWebUI = New-Object System.Windows.Forms.ToolStripMenuItem
    $script:MenuItems.AutoOpenWebUI.Text = "Auto Open WebUI"
    $script:MenuItems.AutoOpenWebUI.Add_Click({
        $script:State.autoOpenWebUI = -not [bool]$script:State.autoOpenWebUI
        Export-State | Out-Null
        Update-TrayState
    })
    $menu.Items.Add($script:MenuItems.AutoOpenWebUI) | Out-Null

    # Update
    $script:MenuItems.Update = New-Object System.Windows.Forms.ToolStripMenuItem
    $script:MenuItems.Update.Text = "Update"
    $script:MenuItems.Update.Add_Click({ Invoke-Update })
    $menu.Items.Add($script:MenuItems.Update) | Out-Null

    # Restart
    $script:MenuItems.Restart = New-Object System.Windows.Forms.ToolStripMenuItem
    $script:MenuItems.Restart.Text = "Restart"
    $script:MenuItems.Restart.Add_Click({ Restart-Channel })
    $menu.Items.Add($script:MenuItems.Restart) | Out-Null

    # Stop
    $script:MenuItems.Stop = New-Object System.Windows.Forms.ToolStripMenuItem
    $script:MenuItems.Stop.Text = "Stop"
    $script:MenuItems.Stop.Add_Click({
        Stop-AllChannels
        Update-TrayState
        Show-BalloonTip "Stopped" -Icon Info -Duration 1200
    })
    $menu.Items.Add($script:MenuItems.Stop) | Out-Null

    $menu.Items.Add("-") | Out-Null

    # Exit
    $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $exitItem.Text = "Exit"
    $exitItem.Add_Click({
        Stop-AllChannels
        $script:UpdateTimer.Stop()
        $script:TrayIcon.Visible = $false
        [System.Windows.Forms.Application]::Exit()
    })
    $menu.Items.Add($exitItem) | Out-Null

    return $menu
}
#endregion

#region Main Execution
# Build and attach menu
$script:TrayIcon.ContextMenuStrip = New-TrayMenu

# Double-click tray icon handler
$script:TrayIcon.add_DoubleClick({
    $activeChannel = Get-ActiveChannel

    if ($activeChannel -ne "") {
        Open-WebUI
    }
    else {
        Start-Channel -Channel $script:State.lastChannel
    }
})

# Create periodic update timer
$script:UpdateTimer = New-Object System.Windows.Forms.Timer
$script:UpdateTimer.Interval = $script:Config.TimerInterval
$script:UpdateTimer.Add_Tick({ Update-TrayState })
$script:UpdateTimer.Start()

# Load saved state
Import-State

if (-not $script:State.arch) {
    $script:State.arch = Get-SystemArchitecture
    Export-State | Out-Null
}

# Ensure config exists
Test-ConfigExists | Out-Null

# Prompt for password if not set
Test-PasswordConfigured | Out-Null

# Update initial UI state
Update-TrayState

# Auto-start behavior
if ((Get-ActiveChannel) -ne "") {
    # Already running, just open WebUI
    if ($script:State.autoOpenWebUI) {
        Open-WebUI
    }
}
else {
    # Not running, ensure version and start
    if (Test-VersionInstalled) {
        Start-Channel -Channel $script:State.lastChannel
    }
    else {
        Update-TrayState
    }
}

# Run message loop
[System.Windows.Forms.Application]::Run()

# Cleanup
$script:UpdateTimer.Stop()
$script:TrayIcon.Visible = $false
#endregion
