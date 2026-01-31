# CLIProxyAPI Tray - Windows built-in only
# - Single instance tray
# - Channel switch (Main/Plus), mutually exclusive
# - Version download/update into versions/<mainTag>/
# - Shared config.yaml (auto created from config.example.yaml)
# - Password prompt if remote-management.secret-key is empty
# - Menu: Channel/Main|Plus, Open/WebUI|Folder, Reset Password, Update, Restart, Stop, Exit

# ---- Enable DPI Awareness (Per-Monitor V2) & Window Control ----
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class Win32API {
    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr dpiContext);

    public static readonly IntPtr DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = new IntPtr(-4);

    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@

# Hide Console Window
$consolePtr = [Win32API]::GetConsoleWindow()
if ($consolePtr -ne [IntPtr]::Zero) {
    [Win32API]::ShowWindow($consolePtr, 0) # 0 = SW_HIDE
}

try {
    [Win32API]::SetProcessDpiAwarenessContext(
        [Win32API]::DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
    ) | Out-Null
} catch {
    # ignore (older Windows)
}

# ---------------- Single instance (Mutex) ----------------
Add-Type -AssemblyName System.Threading
$mutexName = "Global\CLIProxyAPI_Tray_SingleInstance"
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) { exit }

# ---------------- Ensure STA (WinForms NotifyIcon needs STA) ----------------
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    Start-Process -FilePath "powershell.exe" -ArgumentList @(
        "-STA","-NoProfile","-WindowStyle","Hidden","-ExecutionPolicy","Bypass",
        "-File", "`"$PSCommandPath`""
    ) | Out-Null
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

# ---------------- Paths ----------------
$BaseDir       = $PSScriptRoot
$Config        = Join-Path $BaseDir "config.yaml"
$ConfigExample = Join-Path $BaseDir "config.example.yaml"
$VersionsDir   = Join-Path $BaseDir "versions"
$StateFile     = Join-Path $BaseDir "state.json"

# Process names (without .exe)
$ProcMain = "cli-proxy-api"
$ProcPlus = "cli-proxy-api-plus"

# ---------------- State ----------------
$script:State = @{
    lastChannel = "main"   # main | plus
    version     = $null    # main tag e.g. v6.7.37
    plusTag     = $null    # plus tag e.g. v6.7.37-0
    arch        = $null    # amd64 | arm64
}
$script:ProgressForm = $null

function Get-Arch {
    $a = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    if ($a -eq "Arm64") { return "arm64" }
    return "amd64"
}

function Load-State {
    if (-not (Test-Path $StateFile)) { return }
    try {
        $obj = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
        if ($obj.lastChannel -in @("main","plus")) { $script:State.lastChannel = [string]$obj.lastChannel }
        if ($obj.version)  { $script:State.version = [string]$obj.version }
        if ($obj.plusTag)  { $script:State.plusTag = [string]$obj.plusTag }
        if ($obj.arch)     { $script:State.arch = [string]$obj.arch }
    } catch { }
}

function Save-State {
    try {
        $o = [pscustomobject]@{
            lastChannel = $script:State.lastChannel
            version     = $script:State.version
            plusTag     = $script:State.plusTag
            arch        = $script:State.arch
            updatedAt   = (Get-Date).ToString("s")
        }
        ($o | ConvertTo-Json -Compress) | Set-Content -LiteralPath $StateFile -Encoding UTF8
    } catch { }
}

# ---------------- Tray icon (create early so we can show balloon tips) ----------------
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = [System.Drawing.SystemIcons]::Application
$notify.Visible = $true
$notify.Text = "CLIProxyAPI Tray"

# ---------------- Config helpers ----------------
function Ensure-ConfigExists {
    if (Test-Path $Config) { return $true }
    if (-not (Test-Path $ConfigExample)) {
        [System.Windows.Forms.MessageBox]::Show(
            "config.yaml is missing, and config.example.yaml was not found. Cannot continue.",
            "CLIProxyAPI Tray", "OK", "Error"
        ) | Out-Null
        return $false
    }

    try {
        Copy-Item -LiteralPath $ConfigExample -Destination $Config -Force
        $notify.ShowBalloonTip(1500, "CLIProxyAPI Tray", "Created config.yaml from config.example.yaml.", "Info")
        return $true
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            ("Failed to create config.yaml: {0}" -f $_.Exception.Message),
            "CLIProxyAPI Tray", "OK", "Error"
        ) | Out-Null
        return $false
    }
}

function Prompt-ForPassword([string]$title, [string]$prompt) {
    $pwd = ""
    while ([string]::IsNullOrWhiteSpace($pwd)) {
        $pwd = [Microsoft.VisualBasic.Interaction]::InputBox($prompt, $title, "")
        if ($pwd -eq "") { return "" }  # cancel
        $pwd = $pwd.Trim()
    }
    return $pwd
}

function Get-SecretKeyFromConfig {
    if (-not (Test-Path $Config)) { return "" }
    try {
        $lines = Get-Content -LiteralPath $Config -ErrorAction Stop
        foreach ($line in $lines) {
            if ($line -match '^\s*secret-key\s*:\s*(.*)\s*$') {
                $v = $Matches[1].Trim()
                if ($v -match '^"(.*)"$') { $v = $Matches[1] }
                elseif ($v -match "^'(.*)'$") { $v = $Matches[1] }
                return $v.Trim()
            }
        }
    } catch { }
    return ""
}

function Set-SecretKeyInConfig([string]$newKey) {
    if ([string]::IsNullOrWhiteSpace($newKey)) { return $false }
    if (-not (Test-Path $Config)) { return $false }

    $lines = Get-Content -LiteralPath $Config
    $updated = $false

    # Replace existing secret-key
    for ($i=0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*secret-key\s*:') {
            $indent = ($lines[$i] -replace '^(\s*).*$','$1')
            $lines[$i] = ('{0}secret-key: "{1}"' -f $indent, $newKey)
            $updated = $true
            break
        }
    }

    if (-not $updated) {
        # Insert under remote-management: if present; else append a new block
        $rmIndex = -1
        for ($i=0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*remote-management\s*:\s*$') { $rmIndex = $i; break }
        }

        if ($rmIndex -ge 0) {
            # Find end of remote-management block (next top-level key)
            $insertAt = $rmIndex + 1
            for ($j=$rmIndex+1; $j -lt $lines.Count; $j++) {
                if ($lines[$j] -match '^\S') { $insertAt = $j; break }
                $insertAt = $j + 1
            }

            # If allow-remote missing, add it too (safe default)
            $hasAllow = $false
            for ($k=$rmIndex+1; $k -lt $lines.Count; $k++) {
                if ($lines[$k] -match '^\S') { break }
                if ($lines[$k] -match '^\s*allow-remote\s*:') { $hasAllow = $true; break }
            }

            $block = @()
            if (-not $hasAllow) { $block += '  allow-remote: false' }
            $block += ('  secret-key: "{0}"' -f $newKey)

            if ($insertAt -le 0) {
                $lines = @($lines + $block)
            } else {
                $lines = @($lines[0..($insertAt-1)] + $block + $lines[$insertAt..($lines.Count-1)])
            }
        } else {
            $lines = @($lines + "" + "remote-management:" + "  allow-remote: false" + ('  secret-key: "{0}"' -f $newKey))
        }
    }

    $lines | Set-Content -LiteralPath $Config -Encoding UTF8
    return $true
}

function Ensure-Password {
    if (-not (Ensure-ConfigExists)) { return $false }
    $key = Get-SecretKeyFromConfig
    if (-not [string]::IsNullOrWhiteSpace($key)) { return $true }

    $pwd = Prompt-ForPassword "Set Password" "config.yaml secret-key is empty. Please enter a password:"
    if ([string]::IsNullOrWhiteSpace($pwd)) { return $false }

    if (Set-SecretKeyInConfig $pwd) {
        $notify.ShowBalloonTip(1200, "CLIProxyAPI Tray", "Password saved to config.yaml.", "Info")
        return $true
    }

    $notify.ShowBalloonTip(2000, "CLIProxyAPI Tray", "Failed to write password to config.yaml.", "Error")
    return $false
}

# ---------------- Runtime helpers ----------------
function Get-PortFromConfig {
    param([int]$DefaultPort = 8317)
    if (-not (Test-Path $Config)) { return $DefaultPort }
    try {
        $line = Get-Content -LiteralPath $Config -ErrorAction Stop |
            Where-Object { $_ -match '^\s*port\s*:\s*\d+\s*(#.*)?$' } |
            Select-Object -First 1
        if ($line -and ($line -match '^\s*port\s*:\s*(\d+)')) { return [int]$Matches[1] }
    } catch { }
    return $DefaultPort
}

function Get-ShowUpdateProgressFromConfig {
    param([boolean]$Default = $true)
    if (-not (Test-Path $Config)) { return $Default }
    try {
        $line = Get-Content -LiteralPath $Config -ErrorAction Stop |
            Where-Object { $_ -match '^\s*show-update-progress\s*:\s*(true|false)\s*(#.*)?$' } |
            Select-Object -First 1
        if ($line -and ($line -match '^\s*show-update-progress\s*:\s*(true|false)')) { return $Matches[1] -eq 'true' }
    } catch { }
    return $Default
}

function Test-PortOpen {
    param([int]$Port, [int]$TimeoutMs = 500, [string]$HostAddr = "127.0.0.1")
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($HostAddr, $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($ok) { $client.EndConnect($iar); $client.Close(); return $true }
        $client.Close()
    } catch { }
    return $false
}

function Wait-PortOpen {
    param([int]$Port, [int]$TimeoutMs = 12000)
    $start = Get-Date
    while (((Get-Date) - $start).TotalMilliseconds -lt $TimeoutMs) {
        if (Test-PortOpen -Port $Port -TimeoutMs 350) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Get-RunningChannel {
    if (Get-Process -Name $ProcPlus -ErrorAction SilentlyContinue) { return "plus" }
    if (Get-Process -Name $ProcMain -ErrorAction SilentlyContinue) { return "main" }
    return ""
}

function Stop-All {
    try { Get-Process -Name $ProcMain -ErrorAction SilentlyContinue | Stop-Process -Force } catch {}
    try { Get-Process -Name $ProcPlus -ErrorAction SilentlyContinue | Stop-Process -Force } catch {}
    Start-Sleep -Milliseconds 200
}

function Open-WebUI {
    $port = Get-PortFromConfig
    if (-not (Test-PortOpen -Port $port -TimeoutMs 500)) {
        $notify.ShowBalloonTip(1500, "CLIProxyAPI Tray", "Not running (port not listening).", "Info")
        return
    }
    Start-Process ("http://127.0.0.1:{0}/management.html" -f $port) | Out-Null
}

function Open-Folder {
    Start-Process -FilePath "explorer.exe" -ArgumentList "`"$BaseDir`"" | Out-Null
}

function Download-Version-Package($mainUrl, $mainOut, $plusUrl, $plusOut, $showProgress) {
    # If progress not shown, use simple synchronous downloads
    if (-not $showProgress) {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "CLIProxyAPI-Tray")
        try { 
            $notify.ShowBalloonTip(1200, "CLIProxyAPI Tray", "Downloading Main...", "Info")
            $wc.DownloadFile($mainUrl, $mainOut)
            $notify.ShowBalloonTip(1200, "CLIProxyAPI Tray", "Downloading Plus...", "Info")
            $wc.DownloadFile($plusUrl, $plusOut)
        }
        finally { $wc.Dispose() }
        return
    }

    # Create a standard form (with border and title) for progress
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
    $webClient.Headers.Add("User-Agent", "CLIProxyAPI-Tray")
    
    # State tracking
    $script:DownloadStep = "main" # main -> plus
    $script:DownloadError = $null

    # Events
    $webClient.add_DownloadProgressChanged({
        param($s, $e)
        $name = if ($script:DownloadStep -eq "main") { "Main" } else { "Plus" }
        $label.Text = "Downloading {0}: {1}%  ({2:N1} MB / {3:N1} MB)" -f $name, $e.ProgressPercentage, ($e.BytesReceived / 1MB), ($e.TotalBytesToReceive / 1MB)
    })

    $webClient.add_DownloadFileCompleted({
        param($s, $e)
        if ($e.Error) { 
            $script:DownloadError = $e.Error
            $form.Close()
            return
        }

        if ($script:DownloadStep -eq "main") {
            # Main finished, start Plus
            $script:DownloadStep = "plus"
            $label.Text = "Starting Plus download..."
            try {
                $webClient.DownloadFileAsync($plusUrl, $plusOut)
            } catch {
                $script:DownloadError = $_.Exception
                $form.Close()
            }
        } else {
            # Plus finished, all done
            $form.Close()
        }
    })

    $form.add_Shown({
        try {
            $webClient.DownloadFileAsync($mainUrl, $mainOut)
        } catch {
            $script:DownloadError = $_.Exception
            $form.Close()
        }
    })

    # ShowDialog blocks script execution but pumps messages (prevents freeze)
    $form.ShowDialog() | Out-Null
    
    $form.Dispose()
    $webClient.Dispose()

    if ($script:DownloadError) {
        throw $script:DownloadError
    }
}

# ---------------- GitHub Update helpers ----------------
function Get-LatestTag($repo) {
    $headers = @{ "User-Agent" = "CLIProxyAPI-Tray" }
    $url = "https://api.github.com/repos/$repo/releases/latest"
    (Invoke-RestMethod -Uri $url -Headers $headers -Method Get).tag_name
}

function Find-AssetUrl($repo, $assetName) {
    $headers = @{ "User-Agent" = "CLIProxyAPI-Tray" }
    $url = "https://api.github.com/repos/$repo/releases/latest"
    $rel = Invoke-RestMethod -Uri $url -Headers $headers -Method Get
    $asset = $rel.assets | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
    if (-not $asset) { throw "Asset not found: $assetName" }
    return $asset.browser_download_url
}

function Ensure-VersionInstalled {
    # If state has version & binaries exist, ok
    if ($script:State.version) {
        $vdir = Join-Path $VersionsDir $script:State.version
        $mexe = Join-Path $vdir "cli-proxy-api.exe"
        $pexe = Join-Path $vdir "cli-proxy-api-plus.exe"
        if ((Test-Path $mexe) -and (Test-Path $pexe)) { return $true }
    }

    $arch = Get-Arch
    $mainTag = Get-LatestTag "router-for-me/CLIProxyAPI"     # e.g. v6.7.37
    $mainVer = $mainTag.TrimStart("v")                      # 6.7.37
    $plusTag = ("v{0}-0" -f $mainVer)                       # v6.7.37-0
    $script:State.arch = $arch

    $msg = "No version installed.`nLatest:`nMain: $mainTag`nPlus: $plusTag`nArch: $arch`n`nDownload now?"
    $res = [System.Windows.Forms.MessageBox]::Show($msg, "CLIProxyAPI Tray", "YesNo", "Question")
    if ($res -ne [System.Windows.Forms.DialogResult]::Yes) { return $false }

    New-Item -ItemType Directory -Path $VersionsDir -Force | Out-Null
    $vdir = Join-Path $VersionsDir $mainTag
    New-Item -ItemType Directory -Path $vdir -Force | Out-Null

    $mainZipName = "CLIProxyAPI_{0}_windows_{1}.zip" -f $mainVer, $arch
    $plusZipName = "CLIProxyAPIPlus_{0}-0_windows_{1}.zip" -f $mainVer, $arch

    $tmp = Join-Path $env:TEMP ("cliproxy_update_" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmp | Out-Null

    $showProgress = Get-ShowUpdateProgressFromConfig

    try {
        $mainUrl = Find-AssetUrl "router-for-me/CLIProxyAPI" $mainZipName
        $plusUrl = Find-AssetUrl "router-for-me/CLIProxyAPIPlus" $plusZipName

        $mainZip = Join-Path $tmp $mainZipName
        $plusZip = Join-Path $tmp $plusZipName

        # Download both files in a single progressive window
        Download-Version-Package $mainUrl $mainZip $plusUrl $plusZip $showProgress

        $mainDir = Join-Path $tmp "main"
        $plusDir = Join-Path $tmp "plus"
        
        $notify.ShowBalloonTip(1200, "CLIProxyAPI Tray", "Extracting files...", "Info")
        Expand-Archive -LiteralPath $mainZip -DestinationPath $mainDir -Force
        Expand-Archive -LiteralPath $plusZip -DestinationPath $plusDir -Force

        $mainExe = Get-ChildItem -Path $mainDir -Recurse -Filter "*.exe" | Select-Object -First 1
        $plusExe = Get-ChildItem -Path $plusDir -Recurse -Filter "*.exe" | Select-Object -First 1
        if (-not $mainExe) { throw "Main exe not found in zip" }
        if (-not $plusExe) { throw "Plus exe not found in zip" }

        Stop-All

        Copy-Item -LiteralPath $mainExe.FullName -Destination (Join-Path $vdir "cli-proxy-api.exe") -Force
        Copy-Item -LiteralPath $plusExe.FullName -Destination (Join-Path $vdir "cli-proxy-api-plus.exe") -Force

        $script:State.version = $mainTag
        $script:State.plusTag = $plusTag
        Save-State

        $notify.ShowBalloonTip(1500, "CLIProxyAPI Tray", ("Installed {0}" -f $mainTag), "Info")
        return $true
    } catch {
        $notify.ShowBalloonTip(2500, "CLIProxyAPI Tray", ("Update failed: {0}" -f $_.Exception.Message), "Error")
        return $false
    } finally {
        try { Remove-Item -Recurse -Force $tmp } catch {}
    }
}

function Get-ExePathForChannel([string]$Channel) {
    if (-not $script:State.version) { return $null }
    $vdir = Join-Path $VersionsDir $script:State.version
    if ($Channel -eq "plus") { return (Join-Path $vdir "cli-proxy-api-plus.exe") }
    return (Join-Path $vdir "cli-proxy-api.exe")
}

function Start-Channel {
    param([ValidateSet("main","plus")] [string]$Channel, [switch]$OpenWebAfter)

    if (-not (Ensure-Password)) {
        $notify.ShowBalloonTip(2000, "CLIProxyAPI Tray", "Password not set. Start cancelled.", "Warning")
        return
    }

    $script:State.lastChannel = $Channel
    Save-State

    if (-not (Ensure-VersionInstalled)) { return }

    $exe = Get-ExePathForChannel $Channel
    if (-not $exe -or -not (Test-Path $exe)) {
        $notify.ShowBalloonTip(2500, "CLIProxyAPI Tray", "Exe not found for current version.", "Error")
        return
    }

    Stop-All

    $argList = "--config `"$Config`""

    try {
        Start-Process -FilePath $exe -ArgumentList $argList -WindowStyle Hidden | Out-Null

        $port = Get-PortFromConfig
        $ok = Wait-PortOpen -Port $port -TimeoutMs 12000

        Update-UiState
        if ($ok) {
            $notify.ShowBalloonTip(1200, "CLIProxyAPI Tray", ("Started: {0}" -f $Channel), "Info")
            if ($OpenWebAfter) { 
                Start-Sleep -Seconds 1
                Open-WebUI 
            }
        } else {
            $notify.ShowBalloonTip(2500, "CLIProxyAPI Tray", "Started, but port not ready yet.", "Warning")
        }
    } catch {
        $notify.ShowBalloonTip(2500, "CLIProxyAPI Tray", ("Start failed: {0}" -f $_.Exception.Message), "Error")
    }
}

function Restart-Current {
    $running = Get-RunningChannel
    $ch = if ($running -ne "") { $running } else { $script:State.lastChannel }
    Start-Channel -Channel $ch -OpenWebAfter
}

function Run-Update {
    # Compare installed main tag to latest main tag
    $latestMainTag = Get-LatestTag "router-for-me/CLIProxyAPI"
    if ($script:State.version -and ($script:State.version -eq $latestMainTag)) {
        $notify.ShowBalloonTip(1500, "CLIProxyAPI Tray", ("Already latest: {0}" -f $latestMainTag), "Info")
        return
    }

    $mainVer = $latestMainTag.TrimStart("v")
    $latestPlusTag = ("v{0}-0" -f $mainVer)

    $res = [System.Windows.Forms.MessageBox]::Show(
        "New version found:`nMain: $latestMainTag`nPlus: $latestPlusTag`n`nDownload and install?",
        "CLIProxyAPI Tray", "YesNo", "Question"
    )
    if ($res -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    # Force new install by clearing state version
    $script:State.version = $null
    $script:State.plusTag = $null
    $script:State.arch = Get-Arch
    Save-State

    if (Ensure-VersionInstalled) {
        Start-Channel -Channel $script:State.lastChannel -OpenWebAfter
    }
}

# ---------------- Tray UI ----------------
$menu = New-Object System.Windows.Forms.ContextMenuStrip

$currentItem = New-Object System.Windows.Forms.ToolStripMenuItem
$currentItem.Enabled = $false
$currentItem.Text = "Current : Not Running"
$menu.Items.Add($currentItem) | Out-Null

$menu.Items.Add("-") | Out-Null

# Channel submenu
$channelMenu = New-Object System.Windows.Forms.ToolStripMenuItem
$channelMenu.Text = "Channel"

$channelMainItem = New-Object System.Windows.Forms.ToolStripMenuItem
$channelMainItem.Text = "Main"
$channelMainItem.Add_Click({ Start-Channel -Channel "main" -OpenWebAfter })

$channelPlusItem = New-Object System.Windows.Forms.ToolStripMenuItem
$channelPlusItem.Text = "Plus"
$channelPlusItem.Add_Click({ Start-Channel -Channel "plus" -OpenWebAfter })

$channelMenu.DropDownItems.Add($channelMainItem) | Out-Null
$channelMenu.DropDownItems.Add($channelPlusItem) | Out-Null
$menu.Items.Add($channelMenu) | Out-Null

# Open submenu
$openMenu = New-Object System.Windows.Forms.ToolStripMenuItem
$openMenu.Text = "Open"

$openWebItem = New-Object System.Windows.Forms.ToolStripMenuItem
$openWebItem.Text = "WebUI"
$openWebItem.Add_Click({ Open-WebUI })

$openFolderItem = New-Object System.Windows.Forms.ToolStripMenuItem
$openFolderItem.Text = "Folder"
$openFolderItem.Add_Click({ Open-Folder })

$openMenu.DropDownItems.Add($openWebItem) | Out-Null
$openMenu.DropDownItems.Add($openFolderItem) | Out-Null
$menu.Items.Add($openMenu) | Out-Null

$menu.Items.Add("-") | Out-Null

$resetPwdItem = New-Object System.Windows.Forms.ToolStripMenuItem
$resetPwdItem.Text = "Reset Password"
$resetPwdItem.Add_Click({
    if (-not (Ensure-ConfigExists)) { return }
    $pwd = Prompt-ForPassword "Reset Password" "Enter new password (secret-key):"
    if ([string]::IsNullOrWhiteSpace($pwd)) { return }
    if (Set-SecretKeyInConfig $pwd) {
        $notify.ShowBalloonTip(1200, "CLIProxyAPI Tray", "Password updated.", "Info")
    } else {
        $notify.ShowBalloonTip(2000, "CLIProxyAPI Tray", "Failed to update password.", "Error")
    }
})
$menu.Items.Add($resetPwdItem) | Out-Null

$updateItem = New-Object System.Windows.Forms.ToolStripMenuItem
$updateItem.Text = "Update"
$updateItem.Add_Click({ Run-Update })
$menu.Items.Add($updateItem) | Out-Null

$restartItem = New-Object System.Windows.Forms.ToolStripMenuItem
$restartItem.Text = "Restart"
$restartItem.Add_Click({ Restart-Current })
$menu.Items.Add($restartItem) | Out-Null

$stopItem = New-Object System.Windows.Forms.ToolStripMenuItem
$stopItem.Text = "Stop"
$stopItem.Add_Click({
    Stop-All
    Update-UiState
    $notify.ShowBalloonTip(1200, "CLIProxyAPI Tray", "Stopped.", "Info")
})
$menu.Items.Add($stopItem) | Out-Null

$menu.Items.Add("-") | Out-Null

$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem
$exitItem.Text = "Exit"
$exitItem.Add_Click({
    Stop-All
    $timer.Stop()
    $notify.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})
$menu.Items.Add($exitItem) | Out-Null

$notify.ContextMenuStrip = $menu

function Update-UiState {
    $running = Get-RunningChannel

    # Checkmarks show last selection
    $channelMainItem.Checked = ($script:State.lastChannel -eq "main")
    $channelPlusItem.Checked = ($script:State.lastChannel -eq "plus")

    if ($running -eq "main") {
        $ver = if ($script:State.version) { $script:State.version } else { "v?" }
        $currentItem.Text = ("Current : Main ({0})" -f $ver)
        $notify.Text = "CLIProxyAPI Tray - Main"
        $script:State.lastChannel = "main"
        Save-State
        $restartItem.Enabled = $true
        $stopItem.Enabled = $true
    } elseif ($running -eq "plus") {
        $pver = if ($script:State.plusTag) { $script:State.plusTag } else { "v?-0" }
        $currentItem.Text = ("Current : Plus ({0})" -f $pver)
        $notify.Text = "CLIProxyAPI Tray - Plus"
        $script:State.lastChannel = "plus"
        Save-State
        $restartItem.Enabled = $true
        $stopItem.Enabled = $true
    } else {
        $currentItem.Text = "Current : Not Running"
        $notify.Text = "CLIProxyAPI Tray"
        $restartItem.Enabled = $false
        $stopItem.Enabled = $false
    }
}

# Double-click tray icon:
# - if running -> open web
# - else -> start last channel + open web
$notify.add_DoubleClick({
    $running = Get-RunningChannel
    if ($running -ne "") { Open-WebUI } else { Start-Channel -Channel $script:State.lastChannel -OpenWebAfter }
})

# Periodic refresh
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({ Update-UiState })
$timer.Start()

# ---------------- Startup behavior ----------------
Load-State
if (-not $script:State.arch) { $script:State.arch = Get-Arch; Save-State }

# Ensure config exists early; if missing example, keep tray but don't crash
Ensure-ConfigExists | Out-Null

# Prompt password if empty (user can cancel; tray remains usable)
Ensure-Password | Out-Null

Update-UiState

# If already running, open WebUI; else ensure version & start last channel
if ((Get-RunningChannel) -ne "") {
    Open-WebUI
} else {
    if (Ensure-VersionInstalled) {
        Start-Channel -Channel $script:State.lastChannel -OpenWebAfter
    } else {
        Update-UiState
    }
}

[System.Windows.Forms.Application]::Run()

$timer.Stop()
$notify.Visible = $false
