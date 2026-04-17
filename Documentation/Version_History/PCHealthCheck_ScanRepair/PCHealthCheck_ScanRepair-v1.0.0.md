---
name: PCHealthCheck_ScanRepair
version: 1.0.0
last_updated: 2026-04-16
focus: 'System health scanning and repair using DISM, SFC, and CHKDSK'
---

# PCHealthCheck_ScanRepair - System Health Scan and Repair Script

## Overview

PCHealthCheck_ScanRepair is a PowerShell script that performs comprehensive system health checks using built-in Windows tools: DISM (Deployment Image Servicing and Management), SFC (System File Checker), and CHKDSK (Check Disk). The script provides options for scan-only mode or scan-and-repair mode, allowing users to diagnose issues without automatically applying fixes.

**Key Capabilities:**
- DISM component store health scanning and repair
- System File Integrity verification and repair via SFC
- Disk health scanning and repair scheduling via CHKDSK
- User choice between scan-only or scan-and-repair operations
- Automated report generation in HTML and JSON formats
- Administrator privilege checking and warnings

## Table of Contents

1. [Version Header](#version-header)
2. [Overview](#overview)
3. [Version History Table](#version-history-table)
4. [Requirements](#requirements)
5. [Quick Start](#quick-start)
6. [Parameters Reference](#parameters-reference)
7. [Common Use Cases](#common-use-cases)
8. [Exit Codes/Error Handling](#exit-codeserror-handling)
9. [Troubleshooting](#troubleshooting)

## Version History Table

| Version | Date       | Change Summary |
|---------|------------|----------------|
| 1.0.0   | 2026-04-16 | Initial release with DISM, SFC, and CHKDSK scan/repair functionality |

## Requirements

- **Operating System:** Windows 10, Windows 11, Windows Server 2016 or later
- **PowerShell Version:** 5.1 or higher
- **Permissions:** Administrator privileges required for full functionality
- **Disk Space:** Sufficient space for DISM operations (typically 10GB+ free space recommended)

## Quick Start

1. Open PowerShell as Administrator
2. Navigate to the script directory
3. Run the script: `.\PCHealthCheck_ScanRepair.ps1`
4. Choose scan mode when prompted (S for scan-only, R for scan and repair)
5. Wait for operations to complete (may take 30-60 minutes for full repair)
6. Review generated HTML and JSON reports in C:\temp\

## Parameters Reference

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| -Repair | Switch | No | Enables repair mode. If not specified, script prompts user for choice |

## Common Use Cases

### Routine Health Check
```powershell
.\PCHealthCheck_ScanRepair.ps1
```
Choose 'S' for scan-only to check system health without making changes.

### Full System Repair
```powershell
.\PCHealthCheck_ScanRepair.ps1 -Repair
```
Automatically runs all scans and applies repairs without user prompts.

### Automated Maintenance
Schedule the script with repair mode enabled for regular system maintenance:
```powershell
# In Task Scheduler
Program: powershell.exe
Arguments: -ExecutionPolicy Bypass -File "C:\Path\To\PCHealthCheck_ScanRepair.ps1" -Repair
```

## Exit Codes/Error Handling

| Exit Code | Meaning | Description |
|-----------|---------|-------------|
| 0 | Success | All operations completed successfully |
| 1 | Error | One or more operations failed |
| 2 | Admin Required | Script requires administrator privileges |

The script handles errors gracefully:
- Continues execution if individual tools fail
- Logs all output to console and report files
- Provides clear error messages for troubleshooting

## Troubleshooting

### Common Issues

**"Access Denied" or "Requires Administrator"**
- Solution: Run PowerShell as Administrator
- Prevention: Always use elevated privileges for system maintenance

**DISM RestoreHealth fails with 0x800f0906**
- Cause: Windows Update connectivity issues
- Solution: Ensure internet connection and Windows Update service is running
- Alternative: Use local repair source: `DISM /Online /Cleanup-Image /RestoreHealth /Source:C:\RepairSource`

**SFC finds corrupt files but cannot repair**
- Cause: Corrupt component store
- Solution: Run DISM RestoreHealth first, then SFC again

**CHKDSK repair scheduling fails**
- Cause: Drive in use or locked
- Solution: Schedule for next boot (normal behavior) or run from Recovery Environment

**Long execution times**
- Normal: DISM and SFC can take 20-60 minutes on slow systems
- Solution: Run during maintenance windows, monitor progress in console

### Log Files
- Check Windows Event Logs for additional error details
- DISM logs: `C:\Windows\Logs\DISM\dism.log`
- SFC logs: `C:\Windows\Logs\CBS\CBS.log`
- CHKDSK logs: Event Viewer > Windows Logs > Application