# DOC-pc_health_check.md

## Table of Contents
- [Overview](#overview)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Technical Logic](#technical-logic)
- [Parameters Reference](#parameters-reference)
- [Common Use Cases](#common-use-cases)
- [Security & Safety](#security--safety)
- [Exit Codes/Error Handling](#exit-codeserror-handling)
- [Troubleshooting](#troubleshooting)

## Overview
- Performs DISM image health check to detect Windows component store corruption.
- Collects disk space utilization data for all fixed volumes.
- Executes read-only disk error scanning using Repair-Volume cmdlet.
- Validates network connectivity through ICMP, TCP, and DNS tests.
- Queries Windows Event Viewer for the 10 most recent error events from System and Application logs.
- Generates a detailed, sortable HTML report with remediation suggestions.
- Requires administrator privileges to run.

## Requirements
| Component | Version/Details | Notes |
|-----------|-----------------|-------|
| Operating System | Windows 10/11 or Windows Server 2016+ | Required for DISM and Event Viewer access |
| PowerShell | 5.1 or higher | PowerShell 7+ recommended for optimal cmdlet availability |
| Permissions | Local Administrator | Required for DISM, disk scans, and Event Viewer queries |
| Modules | Storage (optional) | Falls back to WMI if unavailable |
| Network | Outbound ICMP/TCP access | To 8.8.8.8 and google.com for connectivity tests |

## Quick Start
Run the health check on the local machine:
```powershell
.\pc_health_check.ps1
```

Enable verbose output for detailed progress:
```powershell
.\pc_health_check.ps1 -Verbose
```

## Technical Logic
The script follows a modular function-based architecture:

1. **Initialization**: Validates admin rights and creates output directory.
2. **Health Checks**: Executes DISM, disk space, disk error, network, and Event Viewer checks sequentially.
3. **Analysis**: Processes results to generate remediation suggestions.
4. **Report Generation**: Compiles all data into a formatted HTML document with sortable tables.
5. **Output**: Saves report to `C:\Temp\pc_health_check\<computername>_MM-DD-YY_HH-MM-SS.html`.

Primary functions include New-OutputFile, Invoke-DismCheck, Get-DiskSpaceReport, Invoke-DiskErrorChecks, Invoke-NetworkConnectivityCheck, Get-RecentEventErrors, Get-HealthSuggestions, and Convert-ReportToHtml.

## Parameters Reference
The script currently uses CmdletBinding but accepts no parameters.

| Parameter | Type | Default | Mandatory | Description |
|-----------|------|---------|-----------|-------------|
| None | N/A | N/A | N/A | Script runs with default behavior |

## Common Use Cases
### Routine System Maintenance
Run weekly health checks on workstations to identify potential issues before they impact users.

### Post-Update Verification
Execute after Windows updates to ensure system integrity and disk health.

### Troubleshooting Network Issues
Use the network connectivity section to isolate connectivity problems.

### Event Log Analysis
Review recent errors in the HTML report to identify recurring system or application issues.

## Security & Safety
- **Privilege Validation**: Checks for administrator rights before execution.
- **Read-Only Operations**: Disk scans and DISM checks are non-destructive.
- **Error Handling**: Try/Catch blocks prevent script failure and provide graceful degradation.
- **Data Sanitization**: HTML output escapes special characters to prevent injection.
- **No WhatIf Mode**: Script performs actual checks; no dry-run capability implemented.

## Exit Codes/Error Handling
- **Exit Code 0**: Successful completion.
- **Exit Code 1**: Administrator privileges not detected.
- **Error Messages**: Displayed for cmdlet failures, with fallback methods where available.
- **Graceful Degradation**: Script continues with available checks if some cmdlets fail.

## Troubleshooting
| Issue | Symptom | Solution |
|-------|---------|----------|
| Access Denied | Script exits with error | Run PowerShell as Administrator |
| Cmdlet Not Found | Repair-Volume or Test-NetConnection unavailable | Install required Windows features or use fallback methods |
| Network Failures | Offline status in report | Verify firewall rules, DNS configuration, and gateway settings |
| Event Log Access | Failed to query Event Viewer | Check Event Viewer permissions; may require Domain Admin for remote logs |
| HTML Report Not Generated | Script completes but no file | Verify write permissions to C:\Temp\pc_health_check\ |