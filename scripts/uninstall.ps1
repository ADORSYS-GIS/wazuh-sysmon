# Global configuration
$global:Config = @{
    TempDir            = "C:\Temp"
    SysmonInstallPath  = "C:\Program Files\Sysmon"
    SysmonExePath      = "C:\Program Files\Sysmon\sysmon64.exe"
    WazuhConfigPath    = "C:\Program Files (x86)\ossec-agent\ossec.conf"
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

# Check if running as administrator
function Test-AdminPrivileges {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    return $isAdmin
}

# Uninstall Sysmon service
function Uninstall-SysmonService {
    PrintStep 1 "Uninstalling Sysmon service"
    
    # Try to uninstall using sysmon from installation path
    if (Test-Path $global:Config.SysmonExePath) {
        InfoMessage "Uninstalling Sysmon using installed executable..."
        try {
            $process = Start-Process -FilePath $global:Config.SysmonExePath `
             -ArgumentList "-u" `
             -Wait `
             -NoNewWindow `
             -RedirectStandardOutput "$env:TEMP\sysmon_install.log" `
             -RedirectStandardError "$env:TEMP\sysmon_install_error.log" `
             -PassThru
            if ($process.ExitCode -eq 0) {
                InfoMessage "Sysmon uninstalled successfully!"
            } else {
                InfoMessage "Sysmon uninstallation returned exit code: $($process.ExitCode). This might be expected if Sysmon wasn't installed."
            }
        } catch {
            ErrorMessage "Failed to uninstall Sysmon using installed executable: $_"
        }
    } else {
        # Try to uninstall using sysmon from PATH
        InfoMessage "Sysmon executable not found in installation path. Trying to uninstall using sysmon from PATH..."
        try {
            $process = Start-Process -FilePath "sysmon64.exe" `
             -ArgumentList "-u" `
             -Wait `
             -NoNewWindow `
             -PassThru
            if ($process.ExitCode -eq 0) {
                InfoMessage "Sysmon uninstalled successfully!"
            } else {
                InfoMessage "Sysmon uninstallation returned exit code: $($process.ExitCode). This might be expected if Sysmon wasn't installed."
            }
        } catch {
            try {
                $process = Start-Process -FilePath "sysmon.exe" `
                 -ArgumentList "-u" `
                 -Wait `
                 -NoNewWindow `
                 -PassThru
                if ($process.ExitCode -eq 0) {
                    InfoMessage "Sysmon uninstalled successfully!"
                } else {
                    InfoMessage "Sysmon uninstallation returned exit code: $($process.ExitCode). This might be expected if Sysmon wasn't installed."
                }
            } catch {
                WarnMessage "Failed to uninstall Sysmon. This might be expected if Sysmon wasn't installed or was already uninstalled."
            }
        }
    }
}

# Remove Sysmon installation directory
function Remove-SysmonInstallation {
    PrintStep 2 "Removing Sysmon installation directory"
    
    if (Test-Path $global:Config.SysmonInstallPath) {
        try {
            # Check if the directory is accessible
            $acl = Get-Acl -Path $global:Config.SysmonInstallPath -ErrorAction SilentlyContinue
            if ($acl) {
                Remove-Item -Path $global:Config.SysmonInstallPath -Recurse -Force
                InfoMessage "Removed Sysmon installation directory: $($global:Config.SysmonInstallPath)"
            } else {
                WarnMessage "Cannot access Sysmon installation directory. It might be in use or protected."
            }
        } catch {
            ErrorMessage "Failed to remove Sysmon installation directory: $_"
            WarnMessage "You may need to manually remove the directory: $($global:Config.SysmonInstallPath)"
        }
    } else {
        WarnMessage "Sysmon installation directory not found: $($global:Config.SysmonInstallPath)"
    }
}

# Remove Sysmon configuration from Wazuh
function Remove-WazuhSysmonConfig {
    PrintStep 3 "Removing Sysmon configuration from Wazuh"
    
    if (Test-Path $global:Config.WazuhConfigPath) {
        try {
            InfoMessage "Removing Sysmon configuration from Wazuh..."
            
            # Load the XML configuration
            [xml]$configXml = Get-Content -Path $global:Config.WazuhConfigPath
            
            # Find Sysmon configuration
            $sysmonConfig = $configXml.SelectSingleNode("//localfile[contains(location, 'Microsoft-Windows-Sysmon/Operational')]")
            
            if ($sysmonConfig) {
                # Remove the Sysmon configuration
                $sysmonConfig.ParentNode.RemoveChild($sysmonConfig) | Out-Null
                
                # Save the updated configuration
                $configXml.Save($global:Config.WazuhConfigPath)
                
                InfoMessage "Sysmon configuration removed from Wazuh successfully!"
            } else {
                WarnMessage "No Sysmon configuration found in Wazuh config file."
            }
        } catch {
            ErrorMessage "Failed to modify Wazuh configuration: $($_.Exception.Message)"
            WarnMessage "You may need to manually remove the Sysmon configuration from: $($global:Config.WazuhConfigPath)"
        }
    } else {
        ErrorMessage "Wazuh configuration file not found at $($global:Config.WazuhConfigPath)"
    }
}

# Restart Wazuh service
function Restart-WazuhService {
    PrintStep 4 "Restarting Wazuh service"
    
    try {
        Restart-Service WazuhSvc -Force
        InfoMessage "Wazuh service restarted successfully!"
    } catch {
        ErrorMessage "Failed to restart Wazuh service. Please restart it manually."
    }
}

# Main function that runs the uninstallation steps
function Uninstall-Sysmon {
    try {
        # Check for admin privileges
        if (-Not (Test-AdminPrivileges)) {
            ErrorMessage "This script must be run as Administrator"
            exit 1
        }
        
        InfoMessage "Starting Sysmon uninstallation..."
        
        Uninstall-SysmonService
        Remove-SysmonInstallation
        Remove-WazuhSysmonConfig
        Restart-WazuhService
        
        SuccessMessage "Sysmon uninstallation completed!"
    } catch {
        ErrorMessage "Uninstallation failed: $_"
        exit 1
    }
}

# Execute the main uninstallation function
Uninstall-Sysmon