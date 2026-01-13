# Global configuration
param (
    [switch]$KeepLogging
)

$Script:Config = @{
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

# Remove Sysmon Registry Keys (Fallback)
function Remove-SysmonRegistry {
    PrintStep "1b" "Removing Sysmon Registry Keys manually"
    
    $registryKeys = @(
        "HKLM:\SYSTEM\CurrentControlSet\Services\Sysmon64",
        "HKLM:\SYSTEM\CurrentControlSet\Services\SysmonDrv"
    )

    foreach ($key in $registryKeys) {
        if (Test-Path $key) {
            try {
                Remove-Item -Path $key -Recurse -Force -ErrorAction Stop
                InfoMessage "Removed registry key: $key"
            } catch {
                ErrorMessage "Failed to remove registry key $key : $_"
            }
        }
    }
}

# Uninstall Sysmon service
function Uninstall-SysmonService {
    PrintStep 1 "Uninstalling Sysmon service"
    $uninstallSuccess = $false
    
    # Try to uninstall using sysmon from installation path
    if (Test-Path $Script:Config.SysmonExePath) {
        InfoMessage "Uninstalling Sysmon using installed executable..."
        try {
            $process = Start-Process -FilePath $Script:Config.SysmonExePath -ArgumentList "-u" -Wait -NoNewWindow -PassThru
            if ($process.ExitCode -eq 0) {
                InfoMessage "Sysmon uninstalled successfully!"
                $uninstallSuccess = $true
            } else {
                WarnMessage "Sysmon uninstallation returned exit code: $($process.ExitCode)."
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
                $uninstallSuccess = $true
            } else {
                WarnMessage "Sysmon uninstallation returned exit code: $($process.ExitCode)."
            }
        } catch {
            try {
                $process = Start-Process -FilePath "sysmon.exe" -ArgumentList "-u" -Wait -NoNewWindow -PassThru
                if ($process.ExitCode -eq 0) {
                    InfoMessage "Sysmon uninstalled successfully!"
                    $uninstallSuccess = $true
                } else {
                    WarnMessage "Sysmon uninstallation returned exit code: $($process.ExitCode)."
                }
            } catch {
                WarnMessage "Failed to uninstall Sysmon via command line."
            }
        }
    }

    # Fallback to registry cleanup if uninstall failed or if service still exists
    if (-not $uninstallSuccess -or (Test-SysmonInstalled)) {
        WarnMessage "Standard uninstallation failed or service still detected. Attempting manual registry cleanup..."
        Remove-SysmonRegistry
    }
}

# Remove Sysmon installation directory
function Remove-SysmonInstallation {
    PrintStep 2 "Removing Sysmon installation directory"
    
    if (Test-Path $Script:Config.SysmonInstallPath) {
        try {
            # Check if the directory is accessible
            $acl = Get-Acl -Path $Script:Config.SysmonInstallPath -ErrorAction SilentlyContinue
            if ($acl) {
                Remove-Item -Path $Script:Config.SysmonInstallPath -Recurse -Force
                InfoMessage "Removed Sysmon installation directory: $($Script:Config.SysmonInstallPath)"
            } else {
                WarnMessage "Cannot access Sysmon installation directory. It might be in use or protected."
            }
        } catch {
            ErrorMessage "Failed to remove Sysmon installation directory: $_"
            WarnMessage "You may need to manually remove the directory: $($Script:Config.SysmonInstallPath)"
        }
    } else {
        WarnMessage "Sysmon installation directory not found: $($Script:Config.SysmonInstallPath)"
    }
}

# Disable Script Block Logging and Module Logging
function Disable-PowerShellLogging {
    if ($KeepLogging) {
        InfoMessage "Skipping Disable-PowerShellLogging as -KeepLogging was specified."
        return
    }

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
        
        InfoMessage "Starting Sysmon uninstallation..."
        
        Uninstall-SysmonService
        Remove-SysmonInstallation
        Disable-PowerShellLogging
        
        SuccessMessage "Sysmon uninstallation completed!"
        if (-not $KeepLogging) {
            InfoMessage "PowerShell Script Block and Module Logging have been disabled."
        }
    } catch {
        ErrorMessage "Uninstallation failed: $_"
        exit 1
    }
}

# Execute the main uninstallation function
Uninstall-Sysmon