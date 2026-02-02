<#
.SYNOPSIS
Wazuh Active Response Script (Windows) - Immediate Blocking
.DESCRIPTION
Extracts destinations from LOLT/Exfiltration alerts and blocks them immediately.
Logic: SYSTEM triggers immediate block and creates a state file for unblocking by SOC.
#>
param(
    [switch]$Test,
    [string]$UnblockStatePath
)

$ScriptDir = Split-Path -Parent $PSCommandPath
if (-not $ScriptDir) { $ScriptDir = $PSScriptRoot }
if (-not $ScriptDir) { $ScriptDir = "." }

# Determine Base AR directory (one level up if in 'bin')
$BaseDir = $ScriptDir
if ($BaseDir -match '\\bin$|/bin$') {
    $BaseDir = Split-Path -Parent $BaseDir
}

$LogFile = Join-Path $BaseDir "active-responses-test.log"
$StatesDir = Join-Path $BaseDir "states"

if (-not (Test-Path $StatesDir)) {
    try {
        New-Item -ItemType Directory -Path $StatesDir -Force | Out-Null
    } catch {
        # Fallback to Temp if ProgramData is not writable
        $StatesDir = "C:\Windows\Temp\wazuh-states"
        if (-not (Test-Path $StatesDir)) { New-Item -ItemType Directory -Path $StatesDir -Force | Out-Null }
    }
}

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "$ts wazuh-dlp: $Message"
    try {
        Add-Content -Path $LogFile -Value $LogEntry -ErrorAction Stop
    } catch {
        try {
            # Fallback for when Program Files is not writable (e.g. running as User)
            Add-Content -Path "C:\Windows\Temp\wazuh-ar-fallback.log" -Value $LogEntry -ErrorAction SilentlyContinue
        } catch {}
    }
}




function Extract-Destination {
    param($RuleId, $Data)
    $Target = $null
    try {
        if ($RuleId -eq "100533") {
            $CommandLine = $Data.win.eventdata.commandLine
            # Capture domain or IPv6 in brackets
            if ($CommandLine -match 'https?://(?:\[([a-fA-F0-9:]+)\]|([a-zA-Z0-9.-]+))') { 
                $Target = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
            }
        } elseif ($RuleId -match '100532|100534') {
            if ($RuleId -eq "100532") {
                $Payload = $Data.win.eventdata.payload
                if ($Payload -match 'https?://(?:\[([a-fA-F0-9:]+)\]|([a-zA-Z0-9.-]+))') { 
                    $Target = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
                }
            } elseif ($RuleId -eq "100534") {
                $CommandLine = $Data.win.eventdata.commandLine
                if ($CommandLine -match '(?i)(?:[a-z0-9._%+-]+@|(?<=\s)(?![a-z]:))(?:\[([a-fA-F0-9:]+)\]|([a-z0-9.-]+)):') { 
                    $Target = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
                }
            }
        }
    } catch { Write-Log "Error extracting destination: $_" }
    return $Target
}

function Block-IP {
    param([string]$IP, [string]$Source)
    # Support both IPv4 dots and IPv6 colons in rule names
    $SanitizedIP = $IP -replace '[\.:]', '-'
    $RuleName = "Wazuh-Block-IP-$($SanitizedIP)"
    
    Write-Log "Attempting to block IP: $($IP) (Source: $($Source))"
    
    # Check if rule already exists
    $ExistingRule = $null
    try {
        $ExistingRule = Get-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue
    } catch {
        Write-Log "Error checking for existing rule: $($_.Exception.Message)"
    }
    
    if ($ExistingRule) {
        Write-Log "Firewall rule already exists for IP: $($IP)."
        return
    }
    
    try {
        $Description = "Wazuh blocked $($Source)."
        Write-Log "Creating firewall rule: $($RuleName)"
        New-NetFirewallRule -Name $RuleName `
                           -DisplayName "Wazuh Block $($Source): $($IP)" `
                           -Description $Description `
                           -RemoteAddress $IP `
                           -Action Block `
                           -Direction Outbound `
                           -Enabled True `
                           -ErrorAction Stop `
                           -WarningAction SilentlyContinue `
                           -Confirm:$false | Out-Null
        Write-Log "Successfully blocked IP: $($IP) (Source: $($Source))"
    } catch {
        Write-Log "FAILED to block IP $($IP) : $($_.Exception.Message)"
    }
}

function Unblock-IP {
    param([string]$IP)
    $SanitizedIP = $IP -replace '[\.:]', '-'
    $RuleName = "Wazuh-Block-IP-$($SanitizedIP)"
    
    Write-Log "Attempting to unblock IP: $($IP)"
    
    $ExistingRule = $null
    try {
        $ExistingRule = Get-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue
    } catch {
        Write-Log "Error checking for existing rule during unblock: $($_.Exception.Message)"
    }
    
    if ($ExistingRule) {
        try {
            Remove-NetFirewallRule -Name $RuleName -ErrorAction Stop -Confirm:$false | Out-Null
            Write-Log "Successfully unblocked IP: $($IP)"
        } catch {
            Write-Log "FAILED to unblock IP $($IP) : $($_.Exception.Message)"
        }
    } else {
        Write-Log "No firewall rule found for IP: $($IP) - nothing to unblock"
    }
}

function Update-Domain {
    param(
        [string]$Domain
    )
    # Remove brackets from IPv6 literal if present
    $CleanDomain = $Domain -replace '\[|\]', ''
    Write-Log "Resolving IPs for target: $($CleanDomain)"
    
    $NewIPs = @()
    
    try {
        Write-Log "Resolving DNS for: $($CleanDomain)"
        
        # Try Resolve-DnsName first for better IPv6 support
        $DnsResults = Resolve-DnsName -Name $CleanDomain -Type A_AAAA -ErrorAction SilentlyContinue
        if ($DnsResults) {
            $NewIPs = $DnsResults | Where-Object { $_.Type -in 'A','AAAA' } | Select-Object -ExpandProperty IPAddress -Unique
        }
        
        # Fallback to GetHostAddresses if Resolve-DnsName returned nothing (e.g. not available or literal IP)
        if (-not $NewIPs) {
            $NewIPs = [System.Net.Dns]::GetHostAddresses($CleanDomain) | ForEach-Object { $_.IPAddressToString }
        }
        
        Write-Log "Resolved $($CleanDomain) to $($NewIPs.Count) IP(s): $($NewIPs -join ', ')"
    } catch {
        Write-Log "Failed to resolve target $($CleanDomain): $($_.Exception.Message)"
    }

    foreach ($IP in $NewIPs) { 
        Block-IP -IP $IP -Source $Domain
    }
    
    return $NewIPs
}



# ---- Unblock Mode (Invoked by SOC Agent) ----
if ($UnblockStatePath) {
    Write-Log "Unblock requested via state file: $($UnblockStatePath)"
    if (Test-Path $UnblockStatePath) {
        try {
            $State = Get-Content $UnblockStatePath -Raw | ConvertFrom-Json
            if ($State.ips) {
                Write-Log "Unblocking $($State.ips.Count) IPs for target: $($State.target)"
                foreach ($IP in $State.ips) {
                    Unblock-IP -IP $IP
                }
            }
            Remove-Item $UnblockStatePath -Force
            Write-Log "Successfully processed unblock and removed state file: $($UnblockStatePath)"
        } catch {
            Write-Log "FAILED to process unblock state file: $($_.Exception.Message)"
        }
    } else {
        Write-Log "Unblock state file not found: $($UnblockStatePath)"
    }
    exit 0
}


# ---- Manual test mode ----
if ($Test) {
    Write-Log "Manual test invoked"
    exit 0
}

# ---- Wazuh execution path (Runs as SYSTEM) ----
try {
    $InputLine = [Console]::In.ReadLine()
    if (-not $InputLine) { exit 0 }
    
    $Alert = $InputLine | ConvertFrom-Json
    $Command = $Alert.command
    $RuleId = $Alert.parameters.alert.rule.id
    $Data = $Alert.parameters.alert.data
    
    $Target = Extract-Destination -RuleId $RuleId -Data $Data
    if (-not $Target) { exit 0 }
    
    if ($Command -eq "add") {
        Write-Log "Blocking $($Target) immediately"
        $BlockedIPs = @()
        
        if ([System.Net.IPAddress]::TryParse($Target, [ref]$null)) {
            # Direct IP block
            Write-Log "Target is direct IP: $($Target)"
            Block-IP -IP $Target -Source "Wazuh-AR"
            $BlockedIPs = @($Target)
        } else {
            # Domain block
            Write-Log "Target is domain: $($Target)"
            $BlockedIPs = Update-Domain -Domain $Target
        }

        if ($BlockedIPs.Count -gt 0) {
            $SanitizedTarget = $Target -replace '[^a-zA-Z0-9.-]', '_'
            $Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $StateFileName = "block_$($SanitizedTarget)_$($Timestamp).json"
            $StateFilePath = Join-Path $StatesDir $StateFileName
            
            $StateData = @{
                target = $Target
                ips = $BlockedIPs
                timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            }
            
            try {
                $StateData | ConvertTo-Json | Set-Content $StateFilePath -Force -ErrorAction Stop
                Write-Log "Created immutable state file for unblocking: $($StateFilePath)"
            } catch {
                Write-Log "FAILED to create state file: $($_.Exception.Message)"
            }
        }
        Write-Log "Immediate block applied successfully"
    }
} catch { 
    Write-Log "Script error: $($_.Exception.Message)"
    Write-Log "Stack trace: $($_.ScriptStackTrace)"
}