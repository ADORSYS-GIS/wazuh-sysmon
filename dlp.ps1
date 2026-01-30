<#
.SYNOPSIS
Wazuh Active Response Script (Windows) - Interactive Blocking
.DESCRIPTION
Extracts destinations from LOLT/Exfiltration alerts and prompts user for action.
Logic: SYSTEM triggers User-Prompt, User-Prompt signals back to SYSTEM.
#>
param(
    [switch]$Test,
    [switch]$Refresh,
    [string]$PromptTarget,
    [string]$PromptRuleId,
    [string]$ResponsePath # Path to write the user's choice
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
$StateFile = Join-Path $BaseDir "test-state.json"

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "$ts wazuh-test: $Message"
    try {
        Add-Content -Path $LogFile -Value $LogEntry -ErrorAction Stop
    } catch {
        try {
            # Fallback for when Program Files is not writable (e.g. running as User)
            Add-Content -Path "C:\Windows\Temp\wazuh-ar-fallback.log" -Value $LogEntry -ErrorAction SilentlyContinue
        } catch {}
    }
}

function Get-State {
    Write-Log "Reading state from $($StateFile)"
    # State structure: { domains: { "example.com": { ips: ["1.2.3.4"], type: "perm"|"temp" } }, ips: { "1.2.3.4": { type: "perm"|"temp" } } }
    $DefaultState = @{ domains = @{}; ips = @{} }
    
    if (-not (Test-Path $StateFile)) {
        Write-Log "State file not found, creating new state file"
        try {
            $Dir = Split-Path $StateFile
            if (-not (Test-Path $Dir)) {
                New-Item -ItemType Directory -Path $Dir -Force | Out-Null
            }
            $DefaultState | ConvertTo-Json -Depth 10 | Set-Content $StateFile -Force -ErrorAction Stop
            Write-Log "Created new state file successfully"
        } catch {
            Write-Log "Failed to create state file: $($_.Exception.Message)"
        }
        return $DefaultState
    }

    try {
        $Content = Get-Content $StateFile -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($Content)) {
            Write-Log "State file empty, reinitializing"
            $DefaultState | ConvertTo-Json -Depth 10 | Set-Content $StateFile -Force -ErrorAction Stop -Encoding UTF8
            return $DefaultState
        }

        $Data = $Content | ConvertFrom-Json
        $DomainHash = @{}
        $IPHash = @{}
        
        if ($Data) {
            # Load domains
            if ($Data.domains) {
                $domainsObj = $Data.domains
                if ($domainsObj -is [System.Collections.IDictionary]) {
                    foreach ($key in $domainsObj.Keys) { $DomainHash[$key] = $domainsObj[$key] }
                } else {
                    foreach ($Prop in $domainsObj.PSObject.Properties) { $DomainHash[$Prop.Name] = $Prop.Value }
                }
            }
            
            # Load ips
            if ($Data.ips) {
                $ipsObj = $Data.ips
                if ($ipsObj -is [System.Collections.IDictionary]) {
                    foreach ($key in $ipsObj.Keys) { $IPHash[$key] = $ipsObj[$key] }
                } else {
                    foreach ($Prop in $ipsObj.PSObject.Properties) { $IPHash[$Prop.Name] = $Prop.Value }
                }
            }
        }
        
        Write-Log "State loaded successfully ($($DomainHash.Count) domains, $($IPHash.Count) ips)"
        return @{ domains = $DomainHash; ips = $IPHash }
    } catch {
        Write-Log "Error reading state: $($_.Exception.Message)"
        return $DefaultState
    }
}

function Save-State {
    param($State)
    try {
        $Dir = Split-Path $StateFile
        if (-not (Test-Path $Dir)) {
            Write-Log "Creating directory: $($Dir)"
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        }
        
        Write-Log "Saving state to $($StateFile)"
        $Json = $State | ConvertTo-Json -Depth 10
        $Json | Set-Content $StateFile -Force -ErrorAction Stop -Encoding UTF8
        Write-Log "State saved successfully"
    } catch {
        Write-Log "CRITICAL: Failed to save state: $($_.Exception.Message)"
    }
}

function Notify-User {
    param([string]$Message)
    try {
        Start-Process "msg.exe" -ArgumentList "*", "/TIME:20", $Message -NoNewWindow
    } catch {
        Write-Log "Failed to notify user via msg.exe"
    }
}

function Show-ChoicePrompt {
    param([string]$Target)
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        [System.Windows.Forms.Application]::EnableVisualStyles()
        
        $Form = New-Object System.Windows.Forms.Form
        $Form.Text = "Wazuh Security Alert"
        $Form.Size = New-Object System.Drawing.Size(420,220)
        $Form.StartPosition = "CenterScreen"
        $Form.Topmost = $true
        $Form.FormBorderStyle = "FixedDialog"
        $Form.MaximizeBox = $false
        $Form.MinimizeBox = $false

        $Label = New-Object System.Windows.Forms.Label
        $Label.Text = "Potential data exfiltration detected to:`n$($Target)`n`nChoose an action to take:"
        $Label.Size = New-Object System.Drawing.Size(380,60)
        $Label.Location = New-Object System.Drawing.Point(20,20)
        $Label.Font = New-Object System.Drawing.Font("Segoe UI", 10)
        $Form.Controls.Add($Label)

        $Global:UserChoice = "dismiss"

        $BtnTemp = New-Object System.Windows.Forms.Button
        $BtnTemp.Text = "Block Temporarily"
        $BtnTemp.Location = New-Object System.Drawing.Point(20,100)
        $BtnTemp.Size = New-Object System.Drawing.Size(110,40)
        $BtnTemp.Add_Click({ $Global:UserChoice = "temp"; $Form.Close() })
        $Form.Controls.Add($BtnTemp)

        $BtnPerm = New-Object System.Windows.Forms.Button
        $BtnPerm.Text = "Block Permanently"
        $BtnPerm.Location = New-Object System.Drawing.Point(145,100)
        $BtnPerm.Size = New-Object System.Drawing.Size(120,40)
        $BtnPerm.Add_Click({ $Global:UserChoice = "perm"; $Form.Close() })
        $Form.Controls.Add($BtnPerm)

        $BtnDismiss = New-Object System.Windows.Forms.Button
        $BtnDismiss.Text = "Dismiss"
        $BtnDismiss.Location = New-Object System.Drawing.Point(280,100)
        $BtnDismiss.Size = New-Object System.Drawing.Size(110,40)
        $BtnDismiss.Add_Click({ $Global:UserChoice = "dismiss"; $Form.Close() })
        $Form.Controls.Add($BtnDismiss)

        $Form.Add_Shown({ $Form.Activate() })
        $Form.ShowDialog() | Out-Null
        return $Global:UserChoice
    } catch {
        Write-Log "Error in GUI: $($_.Exception.Message)"
        return "dismiss"
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
    param([string]$IP, [string]$Source, [string]$UnblockTime)
    # Support both IPv4 dots and IPv6 colons in rule names
    $SanitizedIP = $IP -replace '[\.:]', '-'
    $RuleName = "Wazuh-Block-IP-$($SanitizedIP)"
    
    Write-Log "Attempting to block IP: $($IP) (Source: $($Source), Unblock: $($UnblockTime))"
    
    # Check if rule already exists
    $ExistingRule = $null
    try {
        $ExistingRule = Get-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue
    } catch {
        Write-Log "Error checking for existing rule: $($_.Exception.Message)"
    }
    
    if ($ExistingRule) {
        Write-Log "Firewall rule already exists for IP: $($IP). Updating description."
        try {
            Set-NetFirewallRule -Name $RuleName -Description "Wazuh blocked $($Source). Unblock time: $($UnblockTime)" -ErrorAction SilentlyContinue
        } catch {}
        return
    }
    
    try {
        $Description = "Wazuh blocked $($Source). Unblock time: $($UnblockTime)"
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
        Write-Log "Exception details: $($_.Exception.GetType().FullName)"
        if ($_.Exception.InnerException) {
            Write-Log "Inner exception: $($_.Exception.InnerException.Message)"
        }
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
        [string]$Domain,
        [string]$BlockType,
        [string]$UnblockTime,
        $StateObj = $null
    )
    # Remove brackets from IPv6 literal if present
    $CleanDomain = $Domain -replace '\[|\]', ''
    Write-Log "Updating IPs for target: $($CleanDomain) (Type: $($BlockType), Unblock: $($UnblockTime))"
    
    $LocalState = if ($StateObj) { $StateObj } else { Get-State }
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
        # Continue with empty IP list
    }

    $OldIPs = if ($LocalState.domains[$Domain] -and $LocalState.domains[$Domain].ips) { 
        @($LocalState.domains[$Domain].ips) 
    } else { 
        @() 
    }
    
    Write-Log "Old IPs for $($Domain): $($OldIPs.Count) IP(s): $($OldIPs -join ', ')"
    
    # Block new IPs
    $IPsToBlock = @($NewIPs | Where-Object { $_ -notin $OldIPs })
    if ($IPsToBlock.Count -gt 0) {
        Write-Log "IPs to block: $($IPsToBlock.Count) - $($IPsToBlock -join ', ')"
        foreach ($IP in $IPsToBlock) { 
            Block-IP -IP $IP -Source $Domain -UnblockTime $UnblockTime
        }
    }
    
    # Unblock removed IPs
    $IPsToUnblock = @($OldIPs | Where-Object { $_ -notin $NewIPs })
    if ($IPsToUnblock.Count -gt 0) {
        Write-Log "IPs to unblock: $($IPsToUnblock.Count) - $($IPsToUnblock -join ', ')"
        foreach ($IP in $IPsToUnblock) { 
            Unblock-IP -IP $IP
        }
    }
    
    Write-Log "Updating state with new IP list for domain: $($Domain)"
    $LocalState.domains[$Domain] = @{
        ips = $NewIPs
        type = $BlockType
        unblockTime = $UnblockTime
    }
    
    if (-not $StateObj) {
        Save-State $LocalState
    }
    Write-Log "Domain update completed for: $($Domain)"
}

function Register-PeriodicTask {
    $TaskName = "Wazuh-Periodic-Dlp-Refresh"
    if (-not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) {
        $Action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Refresh"
        $Trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)
        try {
            Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -User "SYSTEM" -Force -ErrorAction Stop
            Write-Log "Registered periodic domain refresh task"
        } catch { Write-Log "Failed to register scheduled task: $($_.Exception.Message)" }
    }
}

function Unregister-PeriodicTask {
    $TaskName = "Wazuh-Periodic-Dlp-Refresh"
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        try {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
            Write-Log "Removed periodic domain refresh task (no domains to monitor)"
        } catch { Write-Log "Failed to remove periodic task: $($_.Exception.Message)" }
    }
}

# ---- Periodic Refresh Mode ----
if ($Refresh) {
    Write-Log "Running periodic domain refresh and timeout check"
    try {
        $State = Get-State
        $Now = Get-Date
        $Changed = $false

        # Check IP timeouts
        if ($State.ips) {
            $IPKeys = @($State.ips.Keys)
            Write-Log "Checking timeouts for $($IPKeys.Count) IP(s)"
            $IPsToDelete = @()
            foreach ($IP in $IPKeys) {
                $IPData = $State.ips[$IP]
                if ($IPData.type -eq "temp" -and $IPData.unblockTime -and $IPData.unblockTime -ne "Never") {
                    try {
                        $UnblockTime = [DateTime]$IPData.unblockTime
                        if ($Now -ge $UnblockTime) {
                            Write-Log "IP Timeout reached for $($IP) (Scheduled: $($IPData.unblockTime))"
                            Unblock-IP -IP $IP
                            $IPsToDelete += $IP
                            $Changed = $true
                        } else {
                            Write-Log "IP $($IP) still blocked until $($IPData.unblockTime)"
                        }
                    } catch { Write-Log "Error parsing unblockTime for IP $($IP): $($_.Exception.Message)" }
                }
            }
            foreach ($IP in $IPsToDelete) { $State.ips.Remove($IP) }
        }

        # Refresh domains and check domain timeouts
        if ($State.domains) {
            $DomainKeys = @($State.domains.Keys)
            Write-Log "Checking/Refreshing $($DomainKeys.Count) domain(s)"
            $DomainsToDelete = @()
            foreach ($Domain in $DomainKeys) {
                $DomainData = $State.domains[$Domain]
                if ($DomainData.type -eq "temp" -and $DomainData.unblockTime -and $DomainData.unblockTime -ne "Never") {
                    try {
                        $UnblockTime = [DateTime]$DomainData.unblockTime
                        if ($Now -ge $UnblockTime) {
                            Write-Log "Domain Timeout reached for $($Domain) (Scheduled: $($DomainData.unblockTime))"
                            if ($DomainData.ips) {
                                foreach ($IP in $DomainData.ips) { Unblock-IP -IP $IP }
                            }
                            $DomainsToDelete += $Domain
                            $Changed = $true
                            continue
                        } else {
                            Write-Log "Domain $($Domain) still blocked until $($DomainData.unblockTime)"
                        }
                    } catch { Write-Log "Error parsing unblockTime for Domain $($Domain): $($_.Exception.Message)" }
                }
                # If not timed out, update/refresh IPs
                $BlockType = if ($DomainData.type) { $DomainData.type } else { "perm" }
                Update-Domain -Domain $Domain -BlockType $BlockType -UnblockTime $DomainData.unblockTime -StateObj $State
                $Changed = $true # Update-Domain modifies state
            }
            foreach ($Domain in $DomainsToDelete) { $State.domains.Remove($Domain) }
        }

        if ($Changed) { Save-State $State }
        
        $HasActiveDomains = $State.domains -and $State.domains.Count -gt 0
        $HasActiveIPs = $State.ips -and $State.ips.Count -gt 0
        
        if (-not $HasActiveDomains -and -not $HasActiveIPs) {
            Write-Log "No more active blocks, removing periodic task"
            Unregister-PeriodicTask
        }
    } catch {
        Write-Log "CRITICAL error in periodic refresh: $($_.Exception.Message)"
        Write-Log "Stack trace: $($_.ScriptStackTrace)"
    }
    Write-Log "Periodic refresh cycle completed"
    exit 0
}

# ---- Internal Prompt Mode (Runs as User) ----
if ($PromptTarget -and $ResponsePath) {
    $Choice = Show-ChoicePrompt -Target $PromptTarget
    try {
        # Ensure clean choice string
        $Choice.Trim() | Set-Content $ResponsePath -ErrorAction Stop
    } catch {
        Write-Log "Prompt process failed to write choice to $($ResponsePath): $($_.Exception.Message)"
    }
    exit 0
}

# ---- Manual test mode ----
if ($Test) {
    Write-Log "Manual test invoked"
    Notify-User "Wazuh Active Response TEST successful (manual run)"
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
        Write-Log "Requesting user choice for $($Target)"
        $RequestId = [guid]::NewGuid().ToString().Split('-')[0]
        $ResponseFile = "C:\Windows\Temp\wazuh-ar-$($RequestId).choice"
        $LoggedInUser = (Get-CimInstance Win32_ComputerSystem).UserName
        
        if ($LoggedInUser) {
            $TaskName = "Wazuh-Security-Prompt-$($RequestId)"
            Write-Log "Registering task $($TaskName) for user $($LoggedInUser)"
            $Action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -PromptTarget `"$Target`" -ResponsePath `"$ResponseFile`""
            
            try {
                Register-ScheduledTask -TaskName $TaskName -Action $Action -User $LoggedInUser -Force -ErrorAction Stop
                Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
                
                # Wait for response (up to 45 seconds)
                $WaitCount = 0
                while (-not (Test-Path $ResponseFile) -and $WaitCount -lt 45) {
                    Start-Sleep -Seconds 1
                    $WaitCount++
                }
                
                if (Test-Path $ResponseFile) {
                    $Choice = (Get-Content $ResponseFile -Raw).Trim()
                    Write-Log "User choice received: [$($Choice)]"
                    Remove-Item $ResponseFile -ErrorAction SilentlyContinue
                    
                    if ($Choice -eq "temp" -or $Choice -eq "perm") {
                        $UnblockTime = if ($Choice -eq "temp") { (Get-Date).AddMinutes(30).ToString("yyyy-MM-dd HH:mm:ss") } else { "Never" }
                        Write-Log "Applying $($Choice) block for $($Target) (Unblock: $($UnblockTime))"
                        
                        if ([System.Net.IPAddress]::TryParse($Target, [ref]$null)) {
                            # Direct IP block
                            Write-Log "Target is direct IP: $($Target)"
                            Block-IP -IP $Target -Source "IP-User-$($Choice)" -UnblockTime $UnblockTime
                            $State = Get-State
                            $State.ips[$Target] = @{
                                type = $Choice
                                unblockTime = $UnblockTime
                            }
                            Save-State $State
                            Register-PeriodicTask
                        } else {
                            # Domain block - save to state with block type
                            Write-Log "Target is domain: $($Target)"
                            Update-Domain -Domain $Target -BlockType $Choice -UnblockTime $UnblockTime
                            Register-PeriodicTask
                        }
                        
                        Write-Log "Block applied successfully (Self-unblocking scheduled for temp blocks)"
                    } else {
                        Write-Log "User dismissed alert for $($Target)"
                    }
                } else {
                    Write-Log "No user response received within timeout for $($Target)"
                }
            } catch {
                Write-Log "Failed to manage interactive task: $($_.Exception.Message)"
            } finally {
                # Clean up the temporary task
                if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
                    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
                    Write-Log "Cleaned up task $($TaskName)"
                }
            }
        } else {
            Write-Log "No logged in user found to show prompt"
        }
    }
} catch { 
    Write-Log "Script error: $($_.Exception.Message)"
    Write-Log "Stack trace: $($_.ScriptStackTrace)"
}