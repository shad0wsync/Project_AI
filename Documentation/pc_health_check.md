# pc_health_check.md

Version: 1.1.0  
Last Updated: 2026-04-13

## Table of Contents
- [Overview](#overview)
- [Version History](#version-history)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Parameters Reference](#parameters-reference)
- [Common Use Cases](#common-use-cases)
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

## Version History
| Version | Date | Author | Change Summary |
|---------|------|--------|----------------|
| 1.1.0 | 2026-04-13 | Scribe | Documentation structure updated to include version tracking and history. No changes to script logic. |
| 1.0.0 | 2026-04-13 | Scribe | Initial documentation release. |

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