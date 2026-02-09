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
    WazuhARPath        = "C:\Program Files (x86)\ossec-agent\active-response\bin"
    DlpPs1Url          = "https://raw.githubusercontent.com/ADORSYS-GIS/wazuh-sysmon/refs/heads/feat/dlp-implementation/scripts/dlp.ps1"
    DlpCmdUrl          = "https://raw.githubusercontent.com/ADORSYS-GIS/wazuh-sysmon/refs/heads/feat/dlp-implementation/scripts/dlp.cmd"
    SuricataYamlPath   = "C:\Program Files\Suricata\suricata.yaml"
    SuricataRulesDir   = "C:\Program Files\Suricata\rules"
    SuricataRuleUrl    = "https://raw.githubusercontent.com/ADORSYS-GIS/wazuh-auditd/refs/heads/feat/DLP/config/suricata-exfiltration.rules"
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

# Ensure powershell-yaml module is installed
function Ensure-PowerShellYaml {
    try {
        Import-Module powershell-yaml -ErrorAction Stop
        return $true
    } catch {
        InfoMessage "powershell-yaml module not found. Installing..."
        try {
            Install-Module -Name powershell-yaml -Scope CurrentUser -Force -ErrorAction Stop
            Import-Module powershell-yaml -ErrorAction Stop
            SuccessMessage "powershell-yaml module installed successfully."
            return $true
        } catch {
            WarnMessage "Failed to install powershell-yaml module: $_"
            WarnMessage "Falling back to regex-based YAML parsing (less reliable)."
            return $false
        }
    }
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
    PrintStep 7 "Verifying Installation"
    $verificationFailed = $false

    # 1. Check Sysmon Service
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

    # 4. Check Suricata configuration
    if (Test-Path $Script:Config.SuricataYamlPath) {
        $content = Get-Content $Script:Config.SuricataYamlPath -Raw
        if ($content -match "suricata-exfiltration.rules") {
            SuccessMessage "Verification: Suricata rules for exfiltration are configured."
        } else {
            WarnMessage "Verification: Suricata rules for exfiltration are NOT configured in suricata.yaml."
        }
    }
    
    if ($verificationFailed) {
        throw "Sysmon verification failed. Please check the logs."
    } else {
        SuccessMessage "All verification checks completed!"
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
        $process = Start-Process -FilePath $Script:Config.SysmonExePath `
        -ArgumentList "-accepteula", "-i", "`"$($Script:Config.SysmonConfigPath)`"" `
        -WorkingDirectory $Script:Config.SysmonInstallPath `
        -NoNewWindow `
        -RedirectStandardOutput "$env:TEMP\sysmon_install.log" `
        -RedirectStandardError "$env:TEMP\sysmon_install_error.log" `
        -Wait `
        -PassThru
    if ($process.ExitCode -ne 0) {
        $errorLog = Get-Content "$env:TEMP\sysmon_install_error.log" -Raw
        ErrorMessage "Sysmon installation failed with exit code $($process.ExitCode). Error: $errorLog"
        exit 1
    }
    
        InfoMessage "Sysmon service installed successfully!"
    } catch {
        ErrorMessage "Sysmon installation failed: $_"
        exit 1
    }
}

# Enable Module Logging
function Enable-PowerShellLogging {
    PrintStep 3 "Enabling PowerShell Module Logging"
    
    try {
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

# Download DLP scripts for Active Response
function Install-DlpScripts {
    PrintStep 4 "Installing DLP Active Response scripts"
    
    Ensure-Directory -Path $Script:Config.WazuhARPath
    
    try {
        InfoMessage "Downloading dlp.ps1..."
        Download-File -Url $Script:Config.DlpPs1Url -OutputPath (Join-Path $Script:Config.WazuhARPath "dlp.ps1")
        
        InfoMessage "Downloading dlp.cmd..."
        Download-File -Url $Script:Config.DlpCmdUrl -OutputPath (Join-Path $Script:Config.WazuhARPath "dlp.cmd")
        
        SuccessMessage "DLP scripts installed successfully in $($Script:Config.WazuhARPath)"
    } catch {
        ErrorMessage "Failed to install DLP scripts: $_"
    }
}

# Install Suricata rules for exfiltration detection
function Install-SuricataRules {
    PrintStep 5 "Installing Suricata Rules for Exfiltration Detection"
    
    if (-Not (Test-Path $Script:Config.SuricataYamlPath)) {
        WarnMessage "Suricata configuration file not found at $($Script:Config.SuricataYamlPath). Skipping Suricata configuration."
        return
    }

    # Backup configuration
    try {
        Copy-Item -Path $Script:Config.SuricataYamlPath -Destination "$($Script:Config.SuricataYamlPath).bak" -Force
        InfoMessage "Backed up Suricata configuration to $($Script:Config.SuricataYamlPath).bak"
    } catch {
        WarnMessage "Fairule-filesled to backup Suricata configuration: $_"
    }

    # Download rules
    Ensure-Directory -Path $Script:Config.SuricataRulesDir
    $rulePath = Join-Path $Script:Config.SuricataRulesDir "suricata-exfiltration.rules"
    try {
        Download-File -Url $Script:Config.SuricataRuleUrl -OutputPath $rulePath
        InfoMessage "Downloaded Suricata rules to $rulePath"
    } catch {
        ErrorMessage "Failed to download Suricata rules: $_"
        return
    }

    # Update suricata.yaml using powershell-yaml
    $useYamlModule = Ensure-PowerShellYaml
    
    try {
        $yamlContent = Get-Content $Script:Config.SuricataYamlPath -Raw
        
        if ($yamlContent -match "suricata-exfiltration.rules") {
            InfoMessage "Suricata rules already configured in suricata.yaml"
            return
        }
        
        if ($useYamlModule) {
            # Use powershell-yaml module for robust parsing
            InfoMessage "Using powershell-yaml module for YAML configuration..."
            
            $config = ConvertFrom-Yaml $yamlContent
            $ruleName = "suricata-exfiltration.rules"
            
            # Add rule if not present
            if ($config['rule-files'] -notcontains $ruleName) {
                $config['rule-files'] += $ruleName
                
                # Convert back to YAML and save
                $newYamlContent = ConvertTo-Yaml $config
                $newYamlContent | Set-Content $Script:Config.SuricataYamlPath -NoNewline
                
                SuccessMessage "Updated Suricata configuration with exfiltration rules using YAML parser."
            }
        } else {
            # Fallback to regex-based approach
            InfoMessage "Using regex fallback for YAML configuration..."
            
            if ($yamlContent -match "(?m)^rule-files:") {
                # Detect line ending style
                $lineEnding = if ($yamlContent -match "\r\n") { "`r`n" } else { "`n" }
                
                # Detect indentation from existing entries or use default
                $indent = "  "
                if ($yamlContent -match "(?m)^rule-files:\s*$lineEnding(\s+)-\s") {
                    $indent = $matches[1]
                }
                
                # Add rule after rule-files: line
                $newYamlContent = $yamlContent -replace "(?m)^(rule-files:.*)$", 
                    "`$1$lineEnding$indent- suricata-exfiltration.rules"
                
                $newYamlContent | Set-Content $Script:Config.SuricataYamlPath -NoNewline
                SuccessMessage "Updated Suricata configuration with exfiltration rules."
            } else {
                WarnMessage "Could not find 'rule-files' section in suricata.yaml. Manual configuration may be required."
            }
        }
    } catch {
        ErrorMessage "Failed to update Suricata configuration: $_"
        WarnMessage "You may need to manually add 'suricata-exfiltration.rules' to the rule-files section."
    }

    # Restart Suricata (Scheduled Task)
    try {
        $suricataTask = Get-ScheduledTask -TaskName "SuricataStartup" -ErrorAction SilentlyContinue
        if ($suricataTask) {
            Stop-ScheduledTask -TaskName "SuricataStartup" -ErrorAction SilentlyContinue
            Start-ScheduledTask -TaskName "SuricataStartup"
            SuccessMessage "Restarted Suricata via scheduled task 'SuricataStartup'."
        } else {
            WarnMessage "Suricata scheduled task 'SuricataStartup' not found. Please restart it manually if needed."
        }
    } catch {
        WarnMessage "Failed to restart Suricata scheduled task: $_"
    }
}

# Clean up temporary files
function Cleanup-TempFiles {
    PrintStep 6 "Cleaning up temporary files"
    
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
        Install-DlpScripts
        Install-SuricataRules
        Cleanup-TempFiles
        Verify-Installation
        
        SuccessMessage "Sysmon installation and configuration completed!"
        InfoMessage "Sysmon is now monitoring Process Creation events for curl, wget, powershell, and pwsh."
        InfoMessage "PowerShell Module Logging has been enabled."
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