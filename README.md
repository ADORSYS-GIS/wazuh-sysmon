# Wazuh Sysmon Integration

This repository contains scripts to install and configure Sysmon for integration with Wazuh endpoint security platform. Sysmon (System Monitor) is a Windows system service and device driver that, once installed on a system, remains resident across system reboots to monitor and log system activity to the Windows event log.

## Prerequisites

1. PowerShell 5.0 or higher
2. Internet connectivity to download Sysmon from Microsoft's servers

## Installation

1. Run PowerShell as Administrator.
2. Navigate to the `scripts` directory.
3. Execute the installation script:
   ```powershell
   Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/ADORSYS-GIS/wazuh-sysmon/main/scripts/install.ps1' `
   -UseBasicParsing -OutFile "$env:TEMP\install.ps1"; `
   & "$env:TEMP\install.ps1"
   ```

This will:
- Automatically download Sysmon from Microsoft's official site
- Extract and install Sysmon to "C:\Program Files\Sysmon"
- Configure Sysmon with the provided configuration file
- Clean up temporary files

## Uninstallation

To uninstall Sysmon:

1. Run PowerShell as Administrator.
2. Navigate to the `scripts` directory.
3. Execute the uninstallation script:
   ```powershell
   Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/ADORSYS-GIS/wazuh-sysmon/main/scripts/uninstall.ps1' `
   -UseBasicParsing -OutFile "$env:TEMP\uninstall.ps1"; `
   & "$env:TEMP\uninstall.ps1" 
   ```

This will:
- Uninstall the Sysmon service
- Remove the Sysmon installation directory

## Configuration

The `sysmonconfig.xml` file is configured to monitor Process Creation (Event ID 1) for the following executables:
- `curl.exe`
- `wget.exe`
- `powershell.exe`
- `pwsh.exe`

This allows Sysmon to detect when these tools are used and what arguments are passed to them, which is useful for security monitoring.

## Verification

After installation, you can verify that Sysmon is running by checking the Windows Services or by running:

```cmd
"C:\Program Files\Sysmon\sysmon64.exe" -c
```

You can also check the Event Viewer under "Applications and Services Logs" > "Microsoft" > "Windows" > "Sysmon" > "Operational" to see Sysmon events.

## Troubleshooting

1. **Scripts must be run as Administrator**: Both installation and uninstallation scripts require administrative privileges.

2. **Execution Policy**: If you encounter execution policy errors, run:
   ```powershell
   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
   ```

## Contributing
Contributions are welcome! Please open an issue or submit a pull request for any improvements or bug fixes.