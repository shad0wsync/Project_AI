# Get-TeamsUsersWithDIDs.md

Version: 1.0.0  
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
- Retrieves Microsoft Teams users and their assigned Direct Inward Dial (DID) phone numbers.
- Uses Get-CsPhoneNumberAssignment as the primary source of truth for phone assignments.
- Falls back to Get-CsOnlineUser if the primary method fails.
- Enriches data with user display names, UPNs, DIDs, and Caller ID policies.
- Supports optional inclusion of resource accounts (Auto Attendants / Call Queues).
- Outputs results to CSV file or console display.
- Automatically connects to and disconnects from Microsoft Teams.

## Version History
| Version | Date | Author | Change Summary |
|---------|------|--------|----------------|
| 1.0.0 | 2026-04-13 | Scribe | Initial documentation release. |

## Requirements
| Component | Version/Details | Notes |
|-----------|-----------------|-------|
| Operating System | Windows 10/11 or Windows Server 2016+ | Required for PowerShell and module compatibility |
| PowerShell | 5.1 or higher | PowerShell 7+ recommended for optimal performance |
| Permissions | Teams Administrator | Required for accessing phone number assignments and user data |
| Modules | MicrosoftTeams | Automatically installed and imported if not present |
| Network | Internet access | Required for connecting to Microsoft Teams services |

## Quick Start
Retrieve Teams users with DIDs and export to default CSV:
```powershell
.\Get-TeamsUsersWithDIDs.ps1
```

Display results in console without exporting:
```powershell
.\Get-TeamsUsersWithDIDs.ps1 -NoExport
```

Include resource accounts in the output:
```powershell
.\Get-TeamsUsersWithDIDs.ps1 -IncludeResourceAccounts
```

## Parameters Reference
| Parameter | Type | Default | Mandatory | Description |
|-----------|------|---------|-----------|-------------|
| CsvPath | String | .\TeamsUsersWithDIDs.csv | No | Path to export the CSV file |
| NoExport | Switch | False | No | Output results to console only, skip CSV export |
| IncludeResourceAccounts | Switch | False | No | Include resource accounts (Auto Attendants / Call Queues) in results |

## Common Use Cases
### Phone Number Inventory
Generate a complete list of Teams users with assigned phone numbers for billing or compliance audits.

### Caller ID Policy Review
Review which users have specific Caller ID policies configured for troubleshooting calling issues.

### Resource Account Management
Include Auto Attendants and Call Queues to get a full view of phone number assignments in the organization.

### Migration Planning
Export user phone assignments before migrating to a new phone system or Teams setup.

## Exit Codes/Error Handling
- **Successful Execution**: Script completes without errors, exports CSV or displays results.
- **Connection Failure**: Throws error if unable to connect to Microsoft Teams; script terminates.
- **Module Installation Failure**: Throws error if MicrosoftTeams module cannot be installed or imported.
- **CSV Export Failure**: Displays error message if unable to write to specified CSV path.
- **Fallback Method**: Automatically switches to Get-CsOnlineUser if Get-CsPhoneNumberAssignment fails.
- **Caller ID Policy Handling**: Gracefully handles unsupported Caller ID policy properties in older module versions.

## Troubleshooting
| Issue | Symptom | Solution |
|-------|---------|----------|
| Connection Failed | Error connecting to Microsoft Teams | Verify Teams admin credentials and network connectivity |
| Module Not Found | MicrosoftTeams module installation fails | Ensure internet access and sufficient permissions for module installation |
| No Results | Empty output despite having users with DIDs | Check Teams admin permissions; try running with -Verbose for detailed logging |
| CSV Write Error | Unable to export to specified path | Verify write permissions on the target directory and path validity |
| Resource Accounts Missing | Expected resource accounts not included | Use -IncludeResourceAccounts switch if needed |
| Caller ID Policy Blank | All Caller ID policies show as null | This is normal if the property is not supported in your Teams module version |