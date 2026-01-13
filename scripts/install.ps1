# Global configuration
$Script:Config = @{
    TempDir            = "C:\Temp"
    SysmonZipUrl       = "https://download.sysinternals.com/files/Sysmon.zip"
    SysmonZipPath      = "C:\Temp\Sysmon.zip"
    SysmonExtractPath  = "C:\Temp\Sysmon"
    SysmonInstallPath  = "C:\Program Files\Sysmon"
    SysmonExePath      = "C:\Program Files\Sysmon\sysmon64.exe"
    SysmonConfigPath   = "C:\Program Files\Sysmon\sysmonconfig.xml"
    SysmonConfigUrl    = "https://raw.githubusercontent.com/ADORSYS-GIS/wazuh-sysmon/refs/heads/install-configure/config/sysmonconfig.xml"
    SysmonUninstallUrl = "https://raw.githubusercontent.com/ADORSYS-GIS/wazuh-sysmon/refs/heads/install-configure/scripts/uninstall.ps1"
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

    # Ensure temp directory exists
    Ensure-Directory -Path $Script:Config.TempDir
    
    # Download Sysmon zip file
    if (-Not (Test-Path $Script:Config.SysmonZipPath)) {
        InfoMessage "Downloading Sysmon from Microsoft..."
        Download-File -Url $Script:Config.SysmonZipUrl -OutputPath $Script:Config.SysmonZipPath
    }
    
    # Extract Sysmon
    if (Test-Path $Script:Config.SysmonZipPath) {
        InfoMessage "Extracting Sysmon..."
        Ensure-Directory -Path $Script:Config.SysmonExtractPath
        Expand-Archive -Path $Script:Config.SysmonZipPath -DestinationPath $Script:Config.SysmonExtractPath -Force
        
        # Create Sysmon installation directory
        Ensure-Directory -Path $Script:Config.SysmonInstallPath
        
        # Find the actual extracted files (they might be in a subdirectory)
        $extractedFilesPath = $Script:Config.SysmonExtractPath
        $sysmonExePath = Get-ChildItem -Path $Script:Config.SysmonExtractPath -Recurse -Filter "sysmon*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        
        if ($sysmonExePath) {
            # Get the directory containing the sysmon executable
            $extractedFilesPath = $sysmonExePath.Directory.FullName
        }
        
        # Copy Sysmon files to installation directory
        Copy-Item -Path "$extractedFilesPath\*" -Destination $Script:Config.SysmonInstallPath -Force
        InfoMessage "Sysmon copied to installation directory: $($Script:Config.SysmonInstallPath)"
    } else {
        ErrorMessage "Failed to download Sysmon. Cannot proceed with installation."
        exit 1
    }
}


function Uninstall-ExistingSysmon {
    PrintStep 0 "Uninstalling any existing Sysmon installation"
    
    $uninstallScriptPath = "$env:TEMP\uninstall.ps1"
    
    try {
        InfoMessage "Downloading uninstall script from $($Script:Config.SysmonUninstallUrl)..."
        Invoke-WebRequest -Uri $Script:Config.SysmonUninstallUrl -OutFile $uninstallScriptPath -Headers @{"User-Agent"="Mozilla/5.0"} -ErrorAction Stop
        InfoMessage "Downloaded uninstall script."
        
        InfoMessage "Executing uninstall script with -KeepLogging..."
        & $uninstallScriptPath -KeepLogging
        
        InfoMessage "Existing Sysmon uninstalled (logging settings preserved)."
    } catch {
        WarnMessage "Failed to download or run uninstall script: $_"
        InfoMessage "Continuing with installation (assuming clean state or overwrite)..."
    }
}

function Verify-Installation {
    PrintStep 5 "Verifying Sysmon Installation"
    $verificationFailed = $false

    # 1. Check Service
    $service = Get-Service -Name "Sysmon64" -ErrorAction SilentlyContinue
    if ($service -and $service.Status -eq 'Running') {
        SuccessMessage "Verification: Sysmon64 service is running."
    } else {
        ErrorMessage "Verification: Sysmon64 service is NOT running."
        $verificationFailed = $true
    }

    # 2. Check Configuration File
    if (Test-Path $Script:Config.SysmonConfigPath) {
        SuccessMessage "Verification: Configuration file exists at $($Script:Config.SysmonConfigPath)."
    } else {
        ErrorMessage "Verification: Configuration file missing at $($Script:Config.SysmonConfigPath)."
        $verificationFailed = $true
    }

    # 3. Check Registry
    if (Test-Path "HKLM:\SYSTEM\CurrentControlSet\Services\Sysmon64") {
        SuccessMessage "Verification: Sysmon64 registry key exists."
    } else {
        ErrorMessage "Verification: Sysmon64 registry key missing."
        $verificationFailed = $true
    }
    
    if ($verificationFailed) {
        throw "Sysmon verification failed. Please check the logs."
    } else {
        SuccessMessage "All verification checks passed!"
    }
}

# Install Sysmon service with configuration
function Configure-Sysmon {
    PrintStep 2 "Configuring Sysmon service"
    
    # Check if sysmon executable exists
    if (-Not (Test-Path $Script:Config.SysmonExePath)) {
        ErrorMessage "Sysmon executable not found at $($Script:Config.SysmonExePath)"
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
    
    
    InfoMessage "Downloading sysmonconfig.xml..."
    try {
        Download-File -Url $Script:Config.SysmonConfigUrl -OutputPath $localConfigPath
        InfoMessage "Downloaded sysmonconfig.xml from repository"
    } catch {
        ErrorMessage "Failed to download sysmonconfig.xml from repository: $_"
        exit 1
    }
    
    if (Test-Path $localConfigPath) {
        Copy-Item -Path $localConfigPath -Destination $Script:Config.SysmonConfigPath -Force
        InfoMessage "Copied Sysmon configuration to $($Script:Config.SysmonConfigPath)"
    } else {
        ErrorMessage "Sysmon configuration file not found at $localConfigPath"
        exit 1
    }
    

    # Install Sysmon service silently
    InfoMessage "Installing Sysmon service..."
    try {
        Start-Process -FilePath $Script:Config.SysmonExePath `
            -ArgumentList "-accepteula", "-i", "`"$($Script:Config.SysmonConfigPath)`"" `
            -WorkingDirectory $Script:Config.SysmonInstallPath `
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

# Enable Script Block Logging and Module Logging
function Enable-PowerShellLogging {
    PrintStep 3 "Enabling PowerShell Script Block and Module Logging"
    
    try {
        # Enable Script Block Logging
        InfoMessage "Enabling Script Block Logging..."
        New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging" -Force | Out-Null
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging" -Name "EnableScriptBlockLogging" -Value 1
        InfoMessage "Script Block Logging enabled successfully!"
        
        # Enable Module Logging (optional, more verbose)
        InfoMessage "Enabling Module Logging..."
        New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging" -Force | Out-Null
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging" -Name "EnableModuleLogging" -Value 1
        New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging\ModuleNames" -Force | Out-Null
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging\ModuleNames" -Name "*" -Value "*"
        InfoMessage "Module Logging enabled successfully!"
    } catch {
        ErrorMessage "Failed to enable PowerShell logging: $_"
        WarnMessage "Continuing with Sysmon installation..."
    }
}

# Clean up temporary files
function Cleanup-TempFiles {
    PrintStep 4 "Cleaning up temporary files"
    
    try {
        if (Test-Path $Script:Config.SysmonZipPath) {
            Remove-Item -Path $Script:Config.SysmonZipPath -Force
            InfoMessage "Removed temporary file: $($Script:Config.SysmonZipPath)"
        }
        
        if (Test-Path $Script:Config.SysmonExtractPath) {
            Remove-Item -Path $Script:Config.SysmonExtractPath -Recurse -Force
            InfoMessage "Removed temporary directory: $($Script:Config.SysmonExtractPath)"
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
        

        Uninstall-ExistingSysmon
        Install-SysmonSoftware
        Configure-Sysmon
        Enable-PowerShellLogging
        Cleanup-TempFiles
        Verify-Installation
        
        SuccessMessage "Sysmon installation and configuration completed!"
        InfoMessage "Sysmon is now monitoring Process Creation events for curl, wget, powershell, and pwsh."
        InfoMessage "PowerShell Script Block and Module Logging have been enabled."
    } catch {
        ErrorMessage "Installation failed: $_"
        exit 1
    }
}
# If the EXE exists but Sysmon service is NOT installed → Clean up the bad install
if ((Test-Path $Script:Config.SysmonExePath) -and -not (Test-SysmonInstalled)) {
    WarnMessage "Sysmon files exist but service is not installed. Cleaning up partial installation..."
    Remove-Item -Path $Script:Config.SysmonInstallPath -Recurse -Force -ErrorAction SilentlyContinue
}

# Execute the main installation function
Install-Sysmon