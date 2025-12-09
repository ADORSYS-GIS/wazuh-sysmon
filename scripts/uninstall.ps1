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
            Start-Process -FilePath $global:Config.SysmonExePath -ArgumentList "-u" -Wait -NoNewWindow
            InfoMessage "Sysmon uninstalled successfully!"
        } catch {
            ErrorMessage "Failed to uninstall Sysmon using installed executable: $_"
        }
    } else {
        # Try to uninstall using sysmon from PATH
        InfoMessage "Sysmon executable not found in installation path. Trying to uninstall using sysmon from PATH..."
        try {
            Start-Process -FilePath "sysmon64.exe" -ArgumentList "-u" -Wait -NoNewWindow
            InfoMessage "Sysmon uninstalled successfully!"
        } catch {
            try {
                Start-Process -FilePath "sysmon.exe" -ArgumentList "-u" -Wait -NoNewWindow
                InfoMessage "Sysmon uninstalled successfully!"
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
            Remove-Item -Path $global:Config.SysmonInstallPath -Recurse -Force
            InfoMessage "Removed Sysmon installation directory: $($global:Config.SysmonInstallPath)"
        } catch {
            ErrorMessage "Failed to remove Sysmon installation directory: $_"
        }
    } else {
        WarnMessage "Sysmon installation directory not found: $($global:Config.SysmonInstallPath)"
    }
}

# Remove Sysmon configuration from Wazuh
function Remove-WazuhSysmonConfig {
    PrintStep 3 "Removing Sysmon configuration from Wazuh"
    
    if (Test-Path $global:Config.WazuhConfigPath) {
        # Read the current config
        $configContent = Get-Content $global:Config.WazuhConfigPath -Raw
        
        # Check if Sysmon configuration exists
        if ($configContent -match "Microsoft-Windows-Sysmon/Operational") {
            InfoMessage "Removing Sysmon configuration from Wazuh..."
            
            # Remove the Sysmon configuration block
            $lines = Get-Content $global:Config.WazuhConfigPath
            $newLines = @()
            $skipLines = $false
            
            foreach ($line in $lines) {
                if ($line -match ".*Sysmon log collection.*") {
                    $skipLines = $true
                    continue
                }
                
                if ($skipLines -and $line -match ".*</localfile>.*") {
                    $skipLines = $false
                    continue
                }
                
                if (-not $skipLines) {
                    $newLines += $line
                }
            }
            
            # Write the updated config back to file
            $newLines | Out-File $global:Config.WazuhConfigPath -Encoding UTF8
            
            InfoMessage "Sysmon configuration removed from Wazuh successfully!"
        } else {
            WarnMessage "No Sysmon configuration found in Wazuh config file."
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