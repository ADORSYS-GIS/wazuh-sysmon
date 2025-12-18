# Global configuration
$global:Config = @{
    TempDir            = "C:\Temp"
    SysmonInstallPath  = "C:\Program Files\Sysmon"
    SysmonExePath      = "C:\Program Files\Sysmon\sysmon64.exe"
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

# Check if Sysmon is installed
function Test-SysmonInstalled {
    $service = Get-Service -Name "Sysmon64" -ErrorAction SilentlyContinue
    if ($service) {
        return $true
    }

    return $false
}

# Uninstall Sysmon service
function Uninstall-SysmonService {
    PrintStep 1 "Uninstalling Sysmon service"
    
    # Try to uninstall using sysmon from installation path
    if (Test-Path $global:Config.SysmonExePath) {
        InfoMessage "Uninstalling Sysmon using installed executable..."
        try {
            $process = Start-Process -FilePath $global:Config.SysmonExePath -ArgumentList "-u" -Wait -NoNewWindow -PassThru
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
            $process = Start-Process -FilePath "sysmon64.exe" -ArgumentList "-u" -Wait -NoNewWindow -PassThru
            if ($process.ExitCode -eq 0) {
                InfoMessage "Sysmon uninstalled successfully!"
            } else {
                InfoMessage "Sysmon uninstallation returned exit code: $($process.ExitCode). This might be expected if Sysmon wasn't installed."
            }
        } catch {
            try {
                $process = Start-Process -FilePath "sysmon.exe" -ArgumentList "-u" -Wait -NoNewWindow -PassThru
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

# Disable Script Block Logging and Module Logging
function Disable-PowerShellLogging {
    PrintStep 3 "Disabling PowerShell Script Block and Module Logging"
    
    try {
        # Disable Script Block Logging
        InfoMessage "Disabling Script Block Logging..."
        if (Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging") {
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging" -Name "EnableScriptBlockLogging" -Value 0
            InfoMessage "Script Block Logging disabled successfully!"
        } else {
            InfoMessage "Script Block Logging was not configured."
        }
        
        # Disable Module Logging
        InfoMessage "Disabling Module Logging..."
        if (Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging") {
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging" -Name "EnableModuleLogging" -Value 0
            InfoMessage "Module Logging disabled successfully!"
        } else {
            InfoMessage "Module Logging was not configured."
        }
    } catch {
        ErrorMessage "Failed to disable PowerShell logging: $_"
        WarnMessage "Continuing with Sysmon uninstallation..."
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
        
        # Check if Sysmon is installed
        if (-Not (Test-SysmonInstalled)) {
            WarnMessage "Sysmon is not installed. Nothing to uninstall."
            exit 0
        }
        
        InfoMessage "Starting Sysmon uninstallation..."
        
        Uninstall-SysmonService
        Remove-SysmonInstallation
        Disable-PowerShellLogging
        
        SuccessMessage "Sysmon uninstallation completed!"
        InfoMessage "PowerShell Script Block and Module Logging have been disabled."
    } catch {
        ErrorMessage "Uninstallation failed: $_"
        exit 1
    }
}

# Execute the main uninstallation function
Uninstall-Sysmon