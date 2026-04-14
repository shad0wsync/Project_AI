# PC Health Check Script Documentation

**Version:** 1.0.0  
**Last Updated:** 2026-04-13

## Table of Contents
- [Overview](#overview)
- [Version History](#version-history)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Parameters Reference](#parameters-reference)
- [Common Use Cases](#common-use-cases)
- [Error Handling](#error-handling)
- [Troubleshooting](#troubleshooting)

## Overview
The PC Health Check script performs comprehensive diagnostic checks across multiple system categories to assess the health of a Windows PC. Key capabilities include:

- **System File Integrity Checks**: Verifies system files using SFC and DISM tools
- **Disk Health Analysis**: Monitors disk space, SMART status, and fragmentation
- **Event Log Analysis**: Scans for critical errors, crashes, and system issues
- **Windows Update Health**: Checks update service status and pending updates
- **Performance Metrics**: Collects CPU, memory, and boot time data
- **Startup Impact Assessment**: Analyzes startup programs and services
- **Network Health**: Tests adapters, DNS resolution, and connectivity
- **Cleanup Opportunities**: Identifies temporary files and cache for removal
- **Security Posture**: Evaluates antivirus, firewall, and other security settings
- **Driver Health**: Checks for problematic or unsigned drivers
- **HTML Report Generation**: Creates interactive reports with findings and remediation commands
- **Export Options**: Supports CSV and JSON exports for integration with SIEM systems or APIs
- **Non-Destructive**: Provides recommendations without automatically applying fixes

## Version History

| Version | Date       | Change Summary |
|---------|------------|----------------|
| 1.0.0   | 2026-04-13 | Initial release of comprehensive PC health check script with HTML reporting, CSV/JSON export options, and modular diagnostic categories. |

## Requirements
- **Operating System**: Windows 10, Windows 11, Windows Server 2016 or later
- **PowerShell Version**: PowerShell 5.1 or higher (compatible with PowerShell 7.x)
- **Permissions**: Administrator privileges are recommended for full functionality. Some checks (like SFC/DISM) will be skipped or limited without admin rights.
- **Dependencies**: Built-in Windows tools (SFC, DISM, WMI, Event Viewer). No external dependencies required.

## Quick Start
Run these common commands to get started:

1. **Quick Check** (2-5 minutes): `.\PCHealthCheck.ps1 -Mode Quick`
2. **Standard Check** (10-15 minutes): `.\PCHealthCheck.ps1 -Mode Standard -OutputPath "C:\Reports"`
3. **Full Diagnostic** (30-60 minutes): `.\PCHealthCheck.ps1 -Mode Full -ExportCsv`

## Parameters Reference

| Parameter   | Type          | Description | Default Value |
|-------------|---------------|-------------|---------------|
| Mode        | String        | Execution mode: Quick, Standard, Full, or Custom | Standard |
| Categories  | String[]      | Specific categories to run in Custom mode | None |
| Exclude     | String[]      | Categories to exclude from the selected mode | None |
| OutputPath  | String        | Path to save the HTML report | C:\Temp\PCHealthCheck |
| LogPath     | String        | Path for detailed log file output | C:\Temp\PCHealthCheck\Logs |
| Quiet       | Switch        | Suppress console output | False |
| ExportCsv   | Switch        | Export findings to CSV file | False |
| ExportJson  | Switch        | Export findings to JSON file | False |
| DaysBack    | Int           | Number of days to look back for event log analysis | 7 |

**Valid Category Values**: SystemFiles, Disk, EventLog, WindowsUpdate, Performance, Startup, Network, Cleanup, Security, Drivers

## Common Use Cases

### Basic Health Assessment
```powershell
.\PCHealthCheck.ps1 -Mode Quick
```
**Expected Output**: HTML report with basic disk space, recent errors, and update status. Completes in 2-5 minutes.

### Comprehensive Audit with Custom Output
```powershell
.\PCHealthCheck.ps1 -Mode Standard -OutputPath "C:\IT\Reports" -LogPath "C:\IT\Logs"
```
**Expected Output**: Detailed HTML report and log files saved to specified directories. Includes system integrity, performance, and security checks.

### Targeted Troubleshooting
```powershell
.\PCHealthCheck.ps1 -Mode Custom -Categories Disk, EventLog, Drivers
```
**Expected Output**: Focused report on disk health, system events, and driver issues. Useful for specific problem diagnosis.

### SIEM Integration
```powershell
.\PCHealthCheck.ps1 -Mode Standard -ExportCsv -ExportJson -Quiet
```
**Expected Output**: HTML report, CSV file for spreadsheet analysis, and JSON file for API integration. Console output suppressed for automated runs.

### Excluding Resource-Intensive Checks
```powershell
.\PCHealthCheck.ps1 -Mode Full -Exclude SystemFiles
```
**Expected Output**: Full diagnostic excluding SFC and DISM scans, which can take 20-40 minutes. Useful when time is limited.

## Error Handling
The script is designed for robustness and continues execution even when individual checks fail. Error handling includes:

- **Graceful Degradation**: Checks that require admin privileges are skipped with warnings when run without elevation
- **Logging**: All errors are logged to console and optional log file with timestamps
- **Status Reporting**: Findings are categorized as Pass, Warning, Fail, Info, or Skipped
- **No Exit Codes**: The script does not use exit codes for RMM integration; all results are captured in the HTML report
- **Try/Catch Blocks**: Critical operations are wrapped to prevent script termination

Common error messages and their meanings:
- "Running without Administrator privileges": Some checks will be limited
- "Custom mode requires -Categories parameter": Must specify categories when using Custom mode
- "All categories have been excluded": Invalid combination of mode and exclusions

## Troubleshooting

### Script Won't Run
- **Issue**: "Execution Policy" error
- **Solution**: Run `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser` or execute as Administrator
- **Issue**: "File not found" when running
- **Solution**: Ensure you're in the correct directory or use full path to script

### Limited Results Without Admin Rights
- **Issue**: Many checks show "Skipped" status
- **Solution**: Run PowerShell as Administrator for full functionality

### SFC/DISM Taking Too Long
- **Issue**: Full mode hangs on SystemFiles category
- **Solution**: Use `-Exclude SystemFiles` or run SFC/DISM manually: `sfc /scannow`, `dism /online /cleanup-image /restorehealth`

### No HTML Report Generated
- **Issue**: Script completes but no report file
- **Solution**: Check OutputPath permissions and disk space. Default path requires write access to C:\Temp

### Event Log Analysis Shows No Results
- **Issue**: EventLog category shows no findings
- **Solution**: Adjust `-DaysBack` parameter (default 7 days). Very clean systems may have few events.

### Performance Impact During Scan
- **Issue**: System slows down during Full mode
- **Solution**: Run during off-hours or use Standard mode for most scenarios

### CSV/JSON Export Issues
- **Issue**: Export files not created
- **Solution**: Ensure write permissions to OutputPath and sufficient disk space

For additional support, check the generated log file or run with increased verbosity.