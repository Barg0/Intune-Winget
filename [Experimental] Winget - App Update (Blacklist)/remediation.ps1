# =========================[ Winget - App Update (Blacklist) - REMEDIATION ]=========================

# ---------------------------[ Script Start Timestamp ]---------------------------
$scriptStartTime = Get-Date

# ---------------------------[ Script name ]---------------------------
$scriptName   = "Winget - App Update (Blacklist)"
$logFileName  = "remediation.log"

# ---------------------------[ Config ]---------------------------
$WingetSource         = 'winget'
$SkipUnknownInstalled = $true
$AllowReboot          = $false

# Blacklist (Winget IDs; wildcards OK)
$ExcludeIds = @(
    'Microsoft.Edge','Microsoft.Edge.Beta','Microsoft.Edge.Dev','Microsoft.EdgeWebView2Runtime',
    'Microsoft.Office','Microsoft.OneDrive',
    'Microsoft.Teams','Microsoft.Teams.Classic',
    'Microsoft.RemoteDesktopClient',
    'Microsoft.VCLibs.*',
    'BraveSoftware.BraveBrowser*'
)

# ---------------------------[ Logging Setup (append; consistent encoding) ]---------------------------
$log           = $true
$enableLogFile = $true
$logFileDirectory = "$env:ProgramData\IntuneLogs\Scripts\$scriptName"
$logFile          = "$logFileDirectory\$logFileName"

function Get-LogEncoding {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        if ($PSVersionTable.PSVersion.Major -ge 7) { return 'utf8BOM' } else { return 'utf8' }
    }
    try {
        $bytes = Get-Content -LiteralPath $Path -Encoding Byte -TotalCount 3 -ErrorAction Stop
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { return 'utf8' }
        if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { return 'unicode' }
        return 'utf8'
    } catch { return 'utf8' }
}

if ($enableLogFile -and -not (Test-Path $logFileDirectory)) { New-Item -ItemType Directory -Path $logFileDirectory -Force | Out-Null }
$Script:LogEncoding = if ($enableLogFile) { Get-LogEncoding -Path $logFile } else { 'utf8' }

# Function to write structured logs to file and console  (your style)
function Write-Log {
    param ([string]$Message, [string]$Tag = "Info")

    if (-not $log) { return }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $tagList = @("Start", "Check", "Info", "Success", "Error", "Debug", "End")
    $rawTag = $Tag.Trim()

    if ($tagList -contains $rawTag) { $rawTag = $rawTag.PadRight(7) } else { $rawTag = "Error  " }

    $color = switch ($rawTag.Trim()) {
        "Start"{"Cyan"};"Check"{"Blue"};"Info"{"Yellow"};"Success"{"Green"};"Error"{"Red"};"Debug"{"DarkYellow"};"End"{"Cyan"} default{"White"}
    }

    $logMessage = "$timestamp [  $rawTag ] $Message"

    if ($enableLogFile) { Add-Content -Path $logFile -Value $logMessage -Encoding $Script:LogEncoding }

    Write-Host "$timestamp " -NoNewline
    Write-Host "[  " -NoNewline -ForegroundColor White
    Write-Host "$rawTag" -NoNewline -ForegroundColor $color
    Write-Host " ] " -NoNewline -ForegroundColor White
    Write-Host "$Message"
}

# ---------------------------[ Exit Function ]---------------------------
function Complete-Script {
    param([int]$ExitCode)
    $duration = (Get-Date) - $scriptStartTime
    Write-Log "Script execution time: $($duration.ToString('hh\:mm\:ss\.ff'))" -Tag "Info"
    Write-Log "Exit Code: $ExitCode" -Tag "Info"
    Write-Log "======== Remediation Script Completed ========" -Tag "End"
    exit $ExitCode
}

# ---------------------------[ Winget health / path ]---------------------------
function Get-WingetPath {
    try {
        $root = "$env:ProgramW6432\WindowsApps"
        $folder = Get-ChildItem -Path $root -Directory |
            Where-Object { $_.Name -like 'Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe' } |
            Sort-Object CreationTime -Descending | Select-Object -First 1
        $path = Join-Path $folder.FullName 'winget.exe'
        if (-not (Test-Path $path)) { throw "winget.exe not found." }
        return $path
    } catch {
        Write-Log "Failed to locate Winget: $_" -Tag "Error"
        Complete-Script -ExitCode 1
    }
}

function Register-WingetDependencyPaths {
    Write-Log "Registering Winget dependency DLL directories into SYSTEM PATH..." -Tag "Info"
    try {
        $windowsApps = "$env:ProgramW6432\WindowsApps"
        if (-not (Test-Path $windowsApps)) { Write-Log "WindowsApps folder not found: $windowsApps" -Tag "Error"; return }
        $dllPackages = @('Microsoft.VCLibs.140.00.UWPDesktop','Microsoft.UI.Xaml.2.8')

        $paths = New-Object System.Collections.Generic.List[string]
        foreach ($pkg in $dllPackages) {
            $folder = Get-ChildItem -Path $windowsApps -Directory |
                Where-Object { $_.Name -like "$pkg*_x64__*" } |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1
            if ($folder) { [void]$paths.Add($folder.FullName); Write-Log "Found $pkg at: $($folder.FullName)" -Tag "Info" }
            else { Write-Log "Could not find folder for $pkg" -Tag "Error" }
        }
        $uniquePaths = $paths | Select-Object -Unique

        $currentPath = [Environment]::GetEnvironmentVariable("Path","Machine")
        $updated = $false
        foreach ($p in $uniquePaths) {
            if ($currentPath -notlike "*$p*") { $currentPath += ";$p"; $updated = $true; Write-Log "Adding path to SYSTEM PATH: $p" -Tag "Info" }
            else { Write-Log "Path already present: $p" -Tag "Debug" }
        }
        if ($updated) { [Environment]::SetEnvironmentVariable("Path",$currentPath,"Machine"); Write-Log "SYSTEM PATH updated." -Tag "Success" }
        else { Write-Log "No changes made to SYSTEM PATH." -Tag "Info" }
    } catch { Write-Log "Dependency PATH registration failed: $_" -Tag "Error" }
}

function Invoke-WingetRepair {
    Write-Log "Attempting Winget repair..." -Tag "Info"
    Register-WingetDependencyPaths
    Write-Log "Repair complete (restart may be required)." -Tag "Info"
    Complete-Script -ExitCode 0
}

function Test-Winget {
    $wg = Get-WingetPath
    $v = & $wg -v 2>$null
    if ($LASTEXITCODE -eq 0 -and $v) { Write-Log "Winget version: $v" -Tag "Info"; return $true }
    Write-Log "Winget not healthy (exit $LASTEXITCODE)." -Tag "Error"
    return $false
}

# ---------------------------[ WAU-style parsing + helpers ]---------------------------
# [WAU-derived] parse the table from `winget upgrade --source <src>`; only drop indented chatter
class Software { [string]$Name; [string]$Id; [string]$Version; [string]$AvailableVersion }

function Get-WingetOutdatedApps {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Source
    )

    $wg = Get-WingetPath
    try {
        $raw = & $wg upgrade --source $Source 2>&1
    } catch {
        Write-Log "Error while receiving winget upgrade list: $_" -Tag "Error"
        return @()
    }
    if (-not $raw) { return @() }

    $lines = $raw | Where-Object { $_ } | Where-Object { $_ -notmatch '^\s{3,}' }

    $sepIndex = 0
    while ($sepIndex -lt $lines.Count -and -not $lines[$sepIndex].StartsWith('-----')) { $sepIndex++ }
    if ($sepIndex -eq 0 -or $sepIndex -ge $lines.Count) { return @() }

    $headerLine = $lines[$sepIndex - 1]
    $index = $headerLine -split '(?<=\s)(?!\s)'

    $idStart        = ($index[0] -replace '[\u4e00-\u9fa5]', '**').Length
    $versionStart   = $idStart +    (($index[1] -replace '[\u4e00-\u9fa5]', '**').Length)
    $availableStart = $versionStart +(($index[2] -replace '[\u4e00-\u9fa5]', '**').Length)

    $upgradeList = @()
    for ($i = $sepIndex + 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i] -replace "[\u2026]", " "
        if ($line.StartsWith("-----")) {
            $headerLine = $lines[$i - 1]
            $index = $headerLine -split '(?<=\s)(?!\s)'
            $idStart        = ($index[0] -replace '[\u4e00-\u9fa5]', '**').Length
            $versionStart   = $idStart +    (($index[1] -replace '[\u4e00-\u9fa5]', '**').Length)
            $availableStart = $versionStart +(($index[2] -replace '[\u4e00-\u9fa5]', '**').Length)
            continue
        }
        if ($line -match "\w\.\w") {
            $soft = [Software]::new()
            $nameDecl = (($line.Substring(0, $idStart) -replace '[\u4e00-\u9fa5]', '**').Length) - ($line.Substring(0, $idStart).Length)
            $soft.Name             = $line.Substring(0, $idStart - $nameDecl).TrimEnd()
            $soft.Id               = $line.Substring($idStart - $nameDecl, $versionStart - $idStart).TrimEnd()
            $soft.Version          = $line.Substring($versionStart - $nameDecl, $availableStart - $versionStart).TrimEnd()
            $soft.AvailableVersion = $line.Substring($availableStart - $nameDecl).TrimEnd()
            $upgradeList += $soft
        }
    }

    return $upgradeList | Sort-Object { Get-Random }
}

function Test-IdInList { param([string]$Id,[string[]]$List) foreach ($pat in $List) { if ([string]::IsNullOrWhiteSpace($pat)) { continue } if ($Id -like $pat) { return $true } } return $false }

# --- Confirm/reboot helpers ---
function Get-InstalledVersion {
    param([string]$Id, [string]$Source)
    $wg = Get-WingetPath
    $out = & $wg list -e --id $Id -s $Source 2>&1 | Out-String
    if (-not ($out -match "-----")) { return $null }
    $lines = $out -split "(`r`n|`n|`r)" | Where-Object { $_ }
    $sep = ($lines | Select-String -Pattern '^-{3,}' -SimpleMatch).LineNumber | Select-Object -First 1
    if (-not $sep) { return $null }
    for ($i = $sep; $i -lt $lines.Count; $i++) {
        $line = $lines[$i].TrimEnd()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = ($line -split '\s{2,}') | Where-Object { $_ -ne '' }
        if ($parts.Count -ge 3) {
            if ($parts[1].Trim() -eq $Id) { return $parts[2].Trim() }
        }
    }
    return $null
}

function Test-StillOutdated {
    param([string]$Id, [string]$Source)
    $list = Get-WingetOutdatedApps -Source $Source
    if ($list -is [array]) {
        $match = $list | Where-Object { $_.Id -eq $Id }
        return $null -ne $match  # PSUseCorrectNullComparison
    }
    return $false
}

function Confirm-Installation {
    param([string]$Id, [string]$ExpectedVersion, [string]$Source)
    $installed = Get-InstalledVersion -Id $Id -Source $Source
    if ($installed -and $ExpectedVersion -and ($installed -eq $ExpectedVersion)) { return $true }
    if (-not (Test-StillOutdated -Id $Id -Source $Source)) { return $true }
    return $false
}

function Test-PendingReboot {
    try {
        $reboot = $false
        $paths = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        )
        foreach ($p in $paths) { if (Test-Path $p) { $reboot = $true } }
        $pn = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
        if ($pn -and $pn.PendingFileRenameOperations) { $reboot = $true }
        try { $CCM = New-Object -ComObject 'CCM_ClientUtilities' -ErrorAction Stop; $s = $CCM.DetermineIfRebootPending(); if ($s -and $s.RebootPending) { $reboot = $true } } catch {}
        return $reboot
    } catch { return $false }
}

# --- WAU-style update (upgrade -> confirm -> install fallback) ---
function Update-App {
    param([Software]$App, [string]$Source, [switch]$AllowReboot)

    $wg = Get-WingetPath

    # UPGRADE  # [WAU-derived]
    $upgradeParams = @('upgrade','--id',$App.Id,'-e',
        '--accept-package-agreements','--accept-source-agreements',
        '--disable-interactivity','-h','-s',$Source)
    if ($AllowReboot) { $upgradeParams += '--allow-reboot' }

    Write-Log "Upgrading $($App.Name) [$($App.Id)] $($App.Version) -> $($App.AvailableVersion) ..." -Tag "Info"
    $out = & $wg @upgradeParams 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Log ("winget upgrade output (exit $LASTEXITCODE): " + ($out -join " ")) -Tag "Debug" }

    $confirmed = Confirm-Installation -Id $App.Id -ExpectedVersion $App.AvailableVersion -Source $Source

    # INSTALL fallback (max 2; limit to 1 if pending reboot)  # [WAU-derived]
    if (-not $confirmed) {
        $retryMax = 2
        if (Test-PendingReboot) { Write-Log "Pending reboot detected; limiting to 1 install attempt." -Tag "Info"; $retryMax = 1 }
        for ($retry = 1; (-not $confirmed) -and ($retry -le $retryMax); $retry++) {
            Write-Log "Upgrade not confirmed; trying install instead... ($retry/$retryMax)" -Tag "Check"
            $installParams = @('install','--id',$App.Id,'-e',
                '--accept-package-agreements','--accept-source-agreements',
                '--disable-interactivity','-h','-s',$Source,'--force')
            if ($AllowReboot) { $installParams += '--allow-reboot' }
            $out2 = & $wg @installParams 2>&1
            if ($LASTEXITCODE -ne 0) { Write-Log ("winget install output (exit $LASTEXITCODE): " + ($out2 -join " ")) -Tag "Debug" }
            $confirmed = Confirm-Installation -Id $App.Id -ExpectedVersion $App.AvailableVersion -Source $Source
        }
    }

    if ($confirmed) { Write-Log "$($App.Name) updated to $($App.AvailableVersion)." -Tag "Success"; return $true }
    else { Write-Log "$($App.Name) update failed." -Tag "Error"; return $false }
}

# ---------------------------[ Script Start ]---------------------------
Write-Log "======== Remediation Script Started ========" -Tag "Start"
Write-Log "ComputerName: $env:COMPUTERNAME | User: $env:USERNAME | Script: $scriptName" -Tag "Info"

if (-not (Test-Winget)) { Write-Log "Winget unhealthy; attempting repair." -Tag "Info"; Invoke-WingetRepair; if (-not (Test-Winget)) { Write-Log "Winget still unhealthy after repair." -Tag "Error"; Complete-Script -ExitCode 1 } }

$outdated = Get-WingetOutdatedApps -Source $WingetSource
if (-not $outdated -or $outdated.Count -eq 0) { Write-Log "No upgradable packages detected on source '$WingetSource'." -Tag "Success"; Complete-Script -ExitCode 0 }

$eligible = foreach ($app in $outdated) {
    if ($SkipUnknownInstalled -and $app.Version -eq 'Unknown') { continue }
    if (Test-IdInList -Id $app.Id -List $ExcludeIds) { continue }
    $app
}

if (-not $eligible -or $eligible.Count -eq 0) { Write-Log "All available upgrades are excluded or none eligible." -Tag "Success"; Complete-Script -ExitCode 0 }

$hadFailures = $false
foreach ($app in $eligible) {
    if (-not (Update-App -App $app -Source $WingetSource -AllowReboot:$AllowReboot)) { $hadFailures = $true }
}

if ($hadFailures) { Complete-Script -ExitCode 1 } else { Complete-Script -ExitCode 0 }
