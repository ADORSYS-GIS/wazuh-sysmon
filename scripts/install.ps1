# Global configuration
$global:Config = @{
    TempDir            = "C:\Temp"
    SysmonZipUrl       = "https://download.sysinternals.com/files/Sysmon.zip"
    SysmonZipPath      = "C:\Temp\Sysmon.zip"
    SysmonExtractPath  = "C:\Temp\Sysmon"
    SysmonInstallPath  = "C:\Program Files\Sysmon"
    SysmonExePath      = "C:\Program Files\Sysmon\sysmon64.exe"
    SysmonConfigPath   = "C:\Program Files\Sysmon\sysmonconfig.xml"
}

# Function to handle logging
function Log {
    param (
        [string]$Level,
        [string]$Message,
        [string]$Color = "White"  # Default color
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "$Timestamp $Level $Message" -ForegroundColor $Color
}

# Logging helpers with colors
function InfoMessage {
    param ([string]$Message)
    Log "[INFO]" $Message "White"
}
function WarnMessage {
    param ([string]$Message)
    Log "[WARNING]" $Message "Yellow"
}
function ErrorMessage {
    param ([string]$Message)
    Log "[ERROR]" $Message "Red"
}
function SuccessMessage {
    param ([string]$Message)
    Log "[SUCCESS]" $Message "Green"
}
function PrintStep {
    param (
        [int]$StepNumber,
        [string]$Message
    )
    Log "[STEP]" "Step ${StepNumber}: $Message" "White"
}

# Helper: Create a directory if it doesn't exist.
function Ensure-Directory {
    param (
        [Parameter(Mandatory)]
        [string]$Path
    )
    if (-Not (Test-Path -Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        InfoMessage "Created directory: $Path"
    }
}

# Helper: Download a file from a URL.
function Download-File {
    param (
        [Parameter(Mandatory)]
        [string]$Url,
        [Parameter(Mandatory)]
        [string]$OutputPath
    )
    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutputPath -Headers @{"User-Agent"="Mozilla/5.0"} -ErrorAction Stop
        InfoMessage "Downloaded file from $Url to $OutputPath"
    }
    catch {
        ErrorMessage "Failed to download file from $Url. $_"
    }
}

# Check if running as administrator
function Test-AdminPrivileges {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    return $isAdmin
}

function Test-SysmonInstalled {
    $service = Get-Service -Name "Sysmon64" -ErrorAction SilentlyContinue
    if ($service) {
        return $true
    }

    return $false
}


# Download and extract Sysmon
function Install-SysmonSoftware {
    PrintStep 1 "Downloading and installing Sysmon"
    
    # Check if Sysmon is already installed
    if (Test-SysmonInstalled) {
        WarnMessage "Sysmon is already installed. Uninstalling to reconfigure."
        return
    }
    
    # Ensure temp directory exists
    Ensure-Directory -Path $global:Config.TempDir
    
    # Download Sysmon zip file
    if (-Not (Test-Path $global:Config.SysmonZipPath)) {
        InfoMessage "Downloading Sysmon from Microsoft..."
        Download-File -Url $global:Config.SysmonZipUrl -OutputPath $global:Config.SysmonZipPath
    }
    
    # Extract Sysmon
    if (Test-Path $global:Config.SysmonZipPath) {
        InfoMessage "Extracting Sysmon..."
        Ensure-Directory -Path $global:Config.SysmonExtractPath
        Expand-Archive -Path $global:Config.SysmonZipPath -DestinationPath $global:Config.SysmonExtractPath -Force
        
        # Create Sysmon installation directory
        Ensure-Directory -Path $global:Config.SysmonInstallPath
        
        # Find the actual extracted files (they might be in a subdirectory)
        $extractedFilesPath = $global:Config.SysmonExtractPath
        $sysmonExePath = Get-ChildItem -Path $global:Config.SysmonExtractPath -Recurse -Filter "sysmon*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        
        if ($sysmonExePath) {
            # Get the directory containing the sysmon executable
            $extractedFilesPath = $sysmonExePath.Directory.FullName
        }
        
        # Copy Sysmon files to installation directory
        Copy-Item -Path "$extractedFilesPath\*" -Destination $global:Config.SysmonInstallPath -Force
        InfoMessage "Sysmon copied to installation directory: $($global:Config.SysmonInstallPath)"
    } else {
        ErrorMessage "Failed to download Sysmon. Cannot proceed with installation."
        exit 1
    }
}

# Install Sysmon service with configuration
function Configure-Sysmon {
    PrintStep 2 "Configuring Sysmon service"
    
    # Check if sysmon executable exists
    if (-Not (Test-Path $global:Config.SysmonExePath)) {
        ErrorMessage "Sysmon executable not found at $($global:Config.SysmonExePath)"
        exit 1
    }
    
    # Copy configuration file to Sysmon directory
    $scriptDir = $PSScriptRoot
    if ([string]::IsNullOrEmpty($scriptDir)) {
        $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
    }
    if ([string]::IsNullOrEmpty($scriptDir)) {
        $scriptDir = Get-Location
    }
    $localConfigPath = Join-Path $scriptDir "sysmonconfig.xml"
    
    # If local config not found, try to download it
    if (-Not (Test-Path $localConfigPath)) {
        InfoMessage "Local sysmonconfig.xml not found. Attempting to download from repository..."
        try {
            $repoConfigUrl = "https://raw.githubusercontent.com/ADORSYS-GIS/wazuh-sysmon/install-configure/scripts/sysmonconfig.xml"
            Download-File -Url $repoConfigUrl -OutputPath $localConfigPath
            InfoMessage "Downloaded sysmonconfig.xml from repository"
        } catch {
            ErrorMessage "Failed to download sysmonconfig.xml from repository: $_"
            ErrorMessage "Please ensure sysmonconfig.xml is in the same directory as this script"
            exit 1
        }
    }
    
    if (Test-Path $localConfigPath) {
        Copy-Item -Path $localConfigPath -Destination $global:Config.SysmonConfigPath -Force
        InfoMessage "Copied Sysmon configuration to $($global:Config.SysmonConfigPath)"
    } else {
        ErrorMessage "Sysmon configuration file not found at $localConfigPath"
        exit 1
    }
    
    # Uninstall Sysmon first if service exists
    if (Test-SysmonInstalled) {
        InfoMessage "Sysmon service already installed. Uninstalling before reinstall..."
        try {
            Start-Process -FilePath $global:Config.SysmonExePath `
                -ArgumentList "-u", "-accepteula" `
                -NoNewWindow `
                -RedirectStandardOutput "$env:TEMP\sysmon_uninstall.log" `
                -RedirectStandardError "$env:TEMP\sysmon_uninstall_error.log" `
                -Wait
            InfoMessage "Existing Sysmon service uninstalled successfully."
        } catch {
            ErrorMessage "Failed to uninstall existing Sysmon service: $_"
            exit 1
        }
    }
    
    # Install Sysmon service silently
    InfoMessage "Installing Sysmon service..."
    try {
        Start-Process -FilePath $global:Config.SysmonExePath `
            -ArgumentList "-accepteula", "-i", "`"$($global:Config.SysmonConfigPath)`"" `
            -WorkingDirectory $global:Config.SysmonInstallPath `
            -NoNewWindow `
            -RedirectStandardOutput "$env:TEMP\sysmon_install.log" `
            -RedirectStandardError "$env:TEMP\sysmon_install_error.log" `
            -Wait
        InfoMessage "Sysmon service installed successfully!"
    } catch {
        ErrorMessage "Sysmon installation failed: $_"
        exit 1
    }
}

# Clean up temporary files
function Cleanup-TempFiles {
    PrintStep 3 "Cleaning up temporary files"
    
    try {
        if (Test-Path $global:Config.SysmonZipPath) {
            Remove-Item -Path $global:Config.SysmonZipPath -Force
            InfoMessage "Removed temporary file: $($global:Config.SysmonZipPath)"
        }
        
        if (Test-Path $global:Config.SysmonExtractPath) {
            Remove-Item -Path $global:Config.SysmonExtractPath -Recurse -Force
            InfoMessage "Removed temporary directory: $($global:Config.SysmonExtractPath)"
        }
    } catch {
        WarnMessage "Could not clean up temporary files: $_"
    }
}

# Main function that runs the installation and configuration steps
function Install-Sysmon {
    try {
        # Check for admin privileges
        if (-Not (Test-AdminPrivileges)) {
            ErrorMessage "This script must be run as Administrator"
            exit 1
        }
        
        InfoMessage "Starting Sysmon installation and configuration..."
        
        Install-SysmonSoftware
        Configure-Sysmon
        Cleanup-TempFiles
        
        SuccessMessage "Sysmon installation and configuration completed!"
        InfoMessage "Sysmon is now monitoring Process Creation events for curl, wget, powershell, and pwsh."
    } catch {
        ErrorMessage "Installation failed: $_"
        exit 1
    }
}
# If the EXE exists but Sysmon service is NOT installed → Clean up the bad install
if ((Test-Path $global:Config.SysmonExePath) -and -not (Test-SysmonInstalled)) {
    WarnMessage "Sysmon files exist but service is not installed. Cleaning up partial installation..."
    Remove-Item -Path $global:Config.SysmonInstallPath -Recurse -Force -ErrorAction SilentlyContinue
}

# Execute the main installation function
Install-Sysmon