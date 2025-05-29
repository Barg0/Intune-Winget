# Script version: 2025-05-29 11:00
# Script author: Barg0

# ---------------------------[ Script Start Timestamp ]---------------------------

# Capture start time to log script duration
$scriptStartTime = Get-Date

# ---------------------------[ Winget App ID ]---------------------------

# Define the Winget App ID
$applicationName = "7-Zip"
$wingetAppID = "7zip.7zip"

# ---------------------------[ Logging Setup ]---------------------------

# Logging control switches
$log = $true                     # Set to $false to disable logging in shell
$enableLogFile = $true           # Set to $false to disable file output

# Define the log output location
$logFileDirectory = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\$applicationName"
$logFile = "$logFileDirectory\detection.log"

# Ensure the log directory exists
if ($enableLogFile -and -not (Test-Path $logFileDirectory)) {
    New-Item -ItemType Directory -Path $logFileDirectory -Force | Out-Null
}

# Function to write structured logs to file and console
function Write-Log {
    param ([string]$Message, [string]$Tag = "Info")

    if (-not $log) { return } # Exit if logging is disabled

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $tagList = @("Start", "Check", "Info", "Success", "Error", "Debug", "End")
    $rawTag = $Tag.Trim()

    if ($tagList -contains $rawTag) {
        $rawTag = $rawTag.PadRight(7)
    } else {
        $rawTag = "Error  "  # Fallback if an unrecognized tag is used
    }

    # Set tag colors
    $color = switch ($rawTag.Trim()) {
        "Start"   { "Cyan" }
        "Check"   { "Blue" }
        "Info"    { "Yellow" }
        "Success" { "Green" }
        "Error"   { "Red" }
        "Debug"   { "DarkYellow"}
        "End"     { "Cyan" }
        default   { "White" }
    }

    $logMessage = "$timestamp [  $rawTag ] $Message"

    # Write to file if enabled
    if ($enableLogFile) {
        "$logMessage" | Out-File -FilePath $logFile -Append
    }

    # Write to console with color formatting
    Write-Host "$timestamp " -NoNewline
    Write-Host "[  " -NoNewline -ForegroundColor White
    Write-Host "$rawTag" -NoNewline -ForegroundColor $color
    Write-Host " ] " -NoNewline -ForegroundColor White
    Write-Host "$Message"
}

# ---------------------------[ Exit Function ]---------------------------

function Complete-Script {
    param([int]$ExitCode)
    $scriptEndTime = Get-Date
    $duration = $scriptEndTime - $scriptStartTime
    Write-Log "Script execution time: $($duration.ToString("hh\:mm\:ss\.ff"))" -Tag "Info"
    Write-Log "Exit Code: $ExitCode" -Tag "Info"
    Write-Log "======== Detection Script Completed ========" -Tag "End"
    exit $ExitCode
}

# ---------------------------[ Script Start ]---------------------------

Write-Log "======== Detection Script Started ========" -Tag "Start"
Write-Log "ComputerName: $env:COMPUTERNAME | User: $env:USERNAME | Application: $applicationName" -Tag "Info"
Write-Log "Starting detection for $applicationName" -Tag "Info"
Write-Log "Winget App ID: $wingetAppID" -Tag "Info"

# ---------------------------[ Winget folder Detection ]---------------------------

# Change to the correct path so winget.exe can run in SYSTEM context
$wingetBase = "$env:ProgramW6432\WindowsApps"

try {
    # Find all matching x64 Winget folders
    $wingetFolders = Get-ChildItem -Path $wingetBase -Directory |
        Where-Object { $_.Name -like 'Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe' }
        Write-Log "Winget folder count: $($wingetFolders.Count)" -Tag "Info"
    if ($null -eq $wingetFolders -or $wingetFolders.Count -eq 0) {
        throw "No matching Winget installation folders found."
    }

    # Sort by CreationTime (latest first)
    $latestWingetFolder = $wingetFolders |
        Sort-Object CreationTime -Descending |
        Select-Object -First 1

    # Log selected folder path and creation date
    Write-Log "Winget folder path: $($latestWingetFolder.FullName)" -Tag "Info"
    Write-Log "Winget folder creation date: $($latestWingetFolder.CreationTime.ToString('yyyy-MM-dd HH:mm:ss'))" -Tag "Info"

    # Change to the most recent folder
    Set-Location -Path $latestWingetFolder.FullName
    Write-Log "Navigated to Winget directory successfully." -Tag "Success"

} catch {
    Write-Log "Failed to access Winget directory. Exception: $_" -Tag "Error"
    Complete-Script -ExitCode 1
}

# ---------------------------[ Winget repair functions ]---------------------------

function Test-NuGetProvider {
	[CmdletBinding()]
	param (
		[version]$MinimumVersion = [version]'2.8.5.201'
	)
	$provider = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue |
	Sort-Object Version -Descending |
	Select-Object -First 1

	if (-not $provider) {
		Write-Log 'NuGet Provider Package not detected, installing...' -Tag "Info"
		Install-PackageProvider -Name NuGet -Force | Out-Null
	} elseif ($provider.Version -lt $MinimumVersion) {
		Write-Log "NuGet provider v$($provider.Version) is less than required v$MinimumVersion; updating." -Tag "Info"
		Install-PackageProvider -Name NuGet -Force | Out-Null
        
	} else {
		Write-Log "NuGet provider meets min requirements (v:$($provider.Version))." -Tag "Success"
	}
    
}

function Test-Winget {
    Write-Log "Checking Winget version" -Tag "Check"
    $wingetVersionOutput = & .\winget.exe -v
    $wingetVersionExitCode = $LASTEXITCODE

    if ($null -ne $wingetVersionOutput -and $wingetVersionExitCode -eq 0) {
        Write-Log "Winget version: $wingetVersionOutput" -Tag "Info"
    }
    elseif ($wingetVersionExitCode -ne 0) {
        Write-Log "Winget execution failed with exit code: $wingetVersionExitCode" -Tag "Error"
        Write-Log "Winget output: $wingetVersionOutput" -Tag "Debug"
    }

    return $wingetVersionExitCode -eq 0
}

function Invoke-WingetRepair {
    Write-Log "Attempting Winget repair..." -Tag "Info"

    try {
        Write-Log "Installing Microsoft.WinGet.Client from PSGallery..." -Tag "Info"
        Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery -Scope AllUsers -ErrorAction Stop | Out-Null
        Write-Log "Module installed successfully." -Tag "Success"

        Write-Log "Running Repair-WinGetPackageManager..." -Tag "Info"
        Repair-WinGetPackageManager -AllUsers -Force -Latest -ErrorAction Stop | Out-Null
        Write-Log "Repair completed successfully." -Tag "Success"
    }
    catch {
        Write-Log "Exception during Winget repair attempt: $_" -Tag "Error"
    }
}

# ---------------------------[ Winget version check ]---------------------------

# Run initial check
if (-not (Test-Winget)) {
    Write-Log "Winget not working correctly. Proceeding to repair." -Tag "Info"

    Test-NuGetProvider
    Invoke-WingetRepair

    # Retry after repair
    Write-Log "Retrying Winget version check after repair..." -Tag "Info"
    if (-not (Test-Winget)) {
        Write-Log "Winget is still not working after repair. Exiting script." -Tag "Error"
        Complete-Script -ExitCode 1
    }
    else {
        Write-Log "Winget is now functioning after repair." -Tag "Success"
    }
}
else {
    Write-Log "Winget is functioning correctly." -Tag "Success"
}

# ---------------------------[ App detection ]---------------------------

# Run Winget list to check if app is installed
Write-Log "Running Winget list to check if $applicationName is installed..." -Tag "Check"

$installedOutput = & .\winget.exe list -e --id $wingetAppID --accept-source-agreements
$wingetExitCode = $LASTEXITCODE

if ($wingetExitCode -eq -1978335212 -and $installedOutput -match 'No installed package found matching input criteria.') {
    Write-Log "App NOT detected - $applicationName is NOT installed." -Tag "Error"
    Complete-Script -ExitCode 1
}
elseif ($wingetExitCode -ne 0) {
    Write-Log "Winget execution failed with exit code: $wingetExitCode" -Tag "Error"
    Complete-Script -ExitCode 1
}
else {
    Write-Log "App detected - $applicationName IS installed." -Tag "Success"
    Complete-Script -ExitCode 0
}