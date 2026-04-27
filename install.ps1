#Requires -Version 5.1

param(
    [string]$InstallDir,

    [ValidateSet("Auto", "WindowsPowerShell", "PowerShell7")]
    [string]$ShortcutShell = "Auto",

    [switch]$NoShortcut,

    [string]$Branch = "main"
)

$ErrorActionPreference = "Stop"

$script:RepositoryUrl = "https://github.com/kitephp/CLIProxyAPI-Tray"
$script:ProjectFiles = @(
    "cli-proxy-api.ps1",
    "config.example.yaml",
    "create-shortcut.bat",
    "cli-proxy-api.vbs",
    "install.ps1",
    "README.md",
    "LICENSE",
    "cli-proxy-api.ico"
)
$script:RequiredFiles = @(
    "cli-proxy-api.ps1",
    "cli-proxy-api.vbs",
    "config.example.yaml",
    "cli-proxy-api.ico"
)

function Enable-Tls12 {
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    catch {
        Write-Verbose "TLS 1.2 configuration was not applied"
    }
}

function Resolve-FullPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Get-LocalSourceRoot {
    $scriptPath = $PSCommandPath
    if (-not $scriptPath) {
        $scriptPath = $MyInvocation.MyCommand.Path
    }

    if ($scriptPath -and (Test-Path -LiteralPath $scriptPath)) {
        return (Split-Path -Parent (Resolve-FullPath -Path $scriptPath))
    }

    return $null
}

function Test-SamePath {
    param(
        [string]$Left,
        [string]$Right
    )

    if (-not $Left -or -not $Right) {
        return $false
    }

    $leftFull = [IO.Path]::GetFullPath($Left).TrimEnd('\', '/')
    $rightFull = [IO.Path]::GetFullPath($Right).TrimEnd('\', '/')
    return ($leftFull -ieq $rightFull)
}

function Get-DefaultInstallDir {
    $homeDir = if ($HOME) { $HOME } else { $env:USERPROFILE }
    if (-not $homeDir) {
        throw "Cannot resolve user home directory."
    }

    return (Join-Path $homeDir ".cli-proxy-api-tray")
}

function Get-RemoteSourceRoot {
    param(
        [Parameter(Mandatory)]
        [string]$BranchName
    )

    Enable-Tls12

    $tempRoot = Join-Path $env:TEMP ("cliproxy_tray_install_" + [Guid]::NewGuid().ToString("N"))
    $zipPath = Join-Path $tempRoot "source.zip"
    $extractDir = Join-Path $tempRoot "source"
    $archiveUrl = "$script:RepositoryUrl/archive/refs/heads/$BranchName.zip"

    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    Invoke-WebRequest -Uri $archiveUrl -OutFile $zipPath -UseBasicParsing
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force

    $sourceRoot = Get-ChildItem -LiteralPath $extractDir -Directory |
                  Select-Object -First 1

    if (-not $sourceRoot) {
        throw "Downloaded archive did not contain a source directory."
    }

    return [PSCustomObject]@{
        Root = $sourceRoot.FullName
        Temp = $tempRoot
    }
}

function Assert-SourceFiles {
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot
    )

    foreach ($file in $script:RequiredFiles) {
        $path = Join-Path $SourceRoot $file
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Required file missing from source: $file"
        }
    }
}

function Copy-ProjectFiles {
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$DestinationRoot
    )

    Assert-SourceFiles -SourceRoot $SourceRoot
    New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null

    foreach ($file in $script:ProjectFiles) {
        $source = Join-Path $SourceRoot $file
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $DestinationRoot $file) -Force
        }
    }
}

function Get-DesktopPath {
    $desktop = [Environment]::GetFolderPath("DesktopDirectory")
    if (-not $desktop) {
        $desktop = Join-Path $env:USERPROFILE "Desktop"
    }

    if (-not (Test-Path -LiteralPath $desktop)) {
        New-Item -ItemType Directory -Path $desktop -Force | Out-Null
    }

    return $desktop
}

function Get-WindowsPowerShellPath {
    $path = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (Test-Path -LiteralPath $path) {
        return $path
    }

    return "powershell.exe"
}

function Get-PowerShell7Path {
    $command = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if (-not $command) {
        $command = Get-Command pwsh -ErrorAction SilentlyContinue
    }

    if ($command -and $command.Source) {
        return $command.Source
    }

    return $null
}

function Get-WScriptPath {
    $path = Join-Path $env:SystemRoot "System32\wscript.exe"
    if (Test-Path -LiteralPath $path) {
        return $path
    }

    $command = Get-Command wscript.exe -ErrorAction SilentlyContinue
    if ($command -and $command.Source) {
        return $command.Source
    }

    return $null
}

function Resolve-ShortcutShellPath {
    param(
        [Parameter(Mandatory)]
        [ValidateSet("Auto", "WindowsPowerShell", "PowerShell7")]
        [string]$Shell
    )

    if ($Shell -eq "WindowsPowerShell") {
        return (Get-WindowsPowerShellPath)
    }

    if ($Shell -eq "PowerShell7") {
        $pwsh = Get-PowerShell7Path
        if ($pwsh) {
            return $pwsh
        }

        Write-Warning "PowerShell 7 was not found. Falling back to Windows PowerShell."
        return (Get-WindowsPowerShellPath)
    }

    $pwsh = Get-PowerShell7Path
    if ($pwsh) {
        return $pwsh
    }

    return (Get-WindowsPowerShellPath)
}

function New-DesktopShortcut {
    param(
        [Parameter(Mandatory)]
        [string]$ApplicationRoot,

        [Parameter(Mandatory)]
        [ValidateSet("Auto", "WindowsPowerShell", "PowerShell7")]
        [string]$Shell
    )

    $scriptPath = Join-Path $ApplicationRoot "cli-proxy-api.ps1"
    $launcherPath = Join-Path $ApplicationRoot "cli-proxy-api.vbs"
    $iconPath = Join-Path $ApplicationRoot "cli-proxy-api.ico"

    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "Application script not found: $scriptPath"
    }
    if (-not (Test-Path -LiteralPath $launcherPath)) {
        throw "Application launcher not found: $launcherPath"
    }
    if (-not (Test-Path -LiteralPath $iconPath)) {
        throw "Application icon not found: $iconPath"
    }

    $desktop = Get-DesktopPath
    $shortcutPath = Join-Path $desktop "CLIProxyAPI Tray.lnk"
    $shellPath = Resolve-ShortcutShellPath -Shell $Shell
    $wscriptPath = Get-WScriptPath
    $wsType = [type]::GetTypeFromCLSID([guid]"72C24DD5-D70A-438B-8A42-98424B88AFB8")

    if (-not $wsType) {
        throw "Failed to load Windows shortcut COM type."
    }

    $ws = [Activator]::CreateInstance($wsType)
    $shortcut = $ws.CreateShortcut($shortcutPath)
    if ($wscriptPath) {
        $shortcut.TargetPath = $wscriptPath
        $shortcut.Arguments = '"' + $launcherPath + '" "' + $shellPath + '"'
    }
    else {
        $shortcut.TargetPath = $shellPath
        $shortcut.Arguments = '-STA -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $scriptPath + '"'
    }
    $shortcut.WorkingDirectory = $ApplicationRoot
    $shortcut.IconLocation = $iconPath + ",0"
    $shortcut.WindowStyle = 7
    $shortcut.Save()

    return $shortcutPath
}

$localSourceRoot = Get-LocalSourceRoot
$applicationRoot = if ($InstallDir) {
    Resolve-FullPath -Path $InstallDir
}
elseif ($localSourceRoot) {
    $localSourceRoot
}
else {
    Get-DefaultInstallDir
}

$remoteSource = $null
try {
    if ($localSourceRoot) {
        if (-not (Test-SamePath -Left $localSourceRoot -Right $applicationRoot)) {
            Copy-ProjectFiles -SourceRoot $localSourceRoot -DestinationRoot $applicationRoot
        }
        else {
            Assert-SourceFiles -SourceRoot $applicationRoot
        }
    }
    else {
        $remoteSource = Get-RemoteSourceRoot -BranchName $Branch
        Copy-ProjectFiles -SourceRoot $remoteSource.Root -DestinationRoot $applicationRoot
    }

    $shortcutPath = $null
    if (-not $NoShortcut) {
        $shortcutPath = New-DesktopShortcut -ApplicationRoot $applicationRoot -Shell $ShortcutShell
    }

    Write-Host "Installed CLIProxyAPI Tray to: $applicationRoot"
    if ($shortcutPath) {
        Write-Host "Desktop shortcut: $shortcutPath"
    }
}
finally {
    if ($remoteSource -and $remoteSource.Temp -and (Test-Path -LiteralPath $remoteSource.Temp)) {
        Remove-Item -LiteralPath $remoteSource.Temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
