---
title: 'Get-M365MonthToMonthSubscriptions - Technical Documentation'
version: 1.0.0
last_updated: 2026-04-20
author: AI Coder
status: Production
---

# Get-M365MonthToMonthSubscriptions - Technical Documentation

## Overview

**Get-M365MonthToMonthSubscriptions** is a PowerShell automation script designed to audit Microsoft 365 subscription licensing across your organization. The script connects to Microsoft Graph, retrieves all active subscriptions, and generates interactive HTML and JSON reports for analysis and compliance tracking.

This tool is essential for organizations needing to monitor subscription inventory, identify licensing gaps, and maintain accurate M365 licensing records.

## Purpose

### Primary Goals

- Retrieve complete inventory of Microsoft 365 subscriptions from your tenant
- Display subscription status, license allocation, and consumption metrics
- Generate exportable reports in both interactive HTML and structured JSON formats
- Provide SKU-to-friendly-name mapping for easier identification
- Maintain audit trail with timestamped exports organized by tenant

### Target Users

- Microsoft 365 administrators
- Licensing compliance officers
- IT operations teams
- Billing and procurement departments

## Features

### Core Capabilities

| Feature | Description |
|---------|-------------|
| **Microsoft Graph Integration** | Direct connection to Microsoft 365 tenant via Microsoft Graph API |
| **SKU Aliasing** | Automatic mapping of technical SKU names to friendly product names (e.g., MICROSOFT_TEAMS_PHONE_STANDARD → Teams Phone Standard) |
| **License Metrics** | Tracks total licenses, active licenses, suspended, warnings, and consumed units |
| **Interactive HTML Reports** | Sortable, filterable, searchable HTML reports with real-time filtering |
| **JSON Export** | Structured JSON output for programmatic analysis and integration |
| **Tenant Auto-Detection** | Automatically identifies and names reports by organization display name |
| **Timestamped Exports** | MM_DD_YY_HH_MM_SS naming convention for chronological organization |
| **Console Output** | Real-time status and summary information during execution |
| **Error Handling** | Graceful error handling with fallback tenant naming |

### HTML Report Features

- **Sortable Columns** - Click any column header to sort ascending/descending
- **Live Search** - Filter results in real-time by SKU, alias, status, or any field
- **Color-Coded Status** - Visual indicators for service availability vs. warnings
- **CSV Export** - Download filtered results as CSV directly from the report
- **Professional Design** - Modern gradient UI with responsive layout
- **Sticky Headers** - Column headers remain visible when scrolling

### JSON Report Features

- **Machine-Readable Format** - Standard JSON structure for parsing and automation
- **Metadata** - Includes generation date and total subscription count
- **Numeric Typing** - License counts properly typed as integers for calculations
- **Complete Data** - All subscription attributes included for analysis

## Prerequisites

### Required Software

- **PowerShell 5.0 or higher** (PowerShell 7+ recommended)
- **Windows 10/11 or Windows Server 2016+**
- **Microsoft.Graph.Identity.DirectoryManagement module** (PowerShell module)

### Required Permissions

Your user account must have one of the following roles in Microsoft Entra ID:

- **Global Administrator**
- **Security Administrator**
- **Directory Readers** (minimum for read-only operations)

### Required API Permissions

The script requires the following Microsoft Graph scopes:

```
Organization.Read.All
Directory.Read.All
```

### Network Requirements

- Outbound HTTPS (port 443) access to Microsoft Graph endpoints
- Access to `graph.microsoft.com` domain
- No corporate proxy blocking or VPN restrictions on authentication endpoints

## Installation

### Step 1: Install Microsoft.Graph Module

```powershell
Install-Module -Name Microsoft.Graph.Identity.DirectoryManagement -Scope CurrentUser -Force
```

### Step 2: Download the Script

Place the script in your preferred location:

```
C:\Scripts\Get-M365MonthToMonthSubscriptions.ps1
```

### Step 3: Set Execution Policy

If needed, allow script execution:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### Step 4: Verify Installation

Test the module import:

```powershell
Import-Module Microsoft.Graph.Identity.DirectoryManagement -PassThru
```

## Usage

### Basic Syntax

```powershell
.\Get-M365MonthToMonthSubscriptions.ps1
```

### With Tenant ID

```powershell
.\Get-M365MonthToMonthSubscriptions.ps1 -TenantId "00000000-0000-0000-0000-000000000000"
```

### Parameter Reference

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| **-TenantId** | String | No | Azure AD tenant ID. If omitted, uses default/current tenant context. |

### Copy-Paste Usage

For ad-hoc execution, you can copy the entire script content and paste into PowerShell console:

```powershell
# Paste entire script content here
# The script will execute immediately without file permissions issues
```

## Output

### Export Location

All exports are saved to:

```
c:\temp\Get-M365MonthToMonthSubscriptions\
```

### File Naming Convention

```
[TenantName]__MM_DD_YY_HH_MM_SS.[filetype]
```

### Example Output

```
Contoso_Inc__04_20_26_14_30_45.html
Contoso_Inc__04_20_26_14_30_45.json
```

### Console Output

The script provides real-time feedback:

```
Connecting to Microsoft Graph...
Retrieving organization licensing information...
Organization: Contoso Inc
Tenant ID: 00000000-0000-0000-0000-000000000000

==========================================

Retrieving subscriptions from Microsoft 365...
Found 12 total subscriptions

Subscription Summary:
===========================================

SKU                               Alias                         Status              Total Licenses
----                              -----                         ------              ---------------
MICROSOFT_TEAMS_PHONE_STANDARD    Teams Phone Standard          ServiceAvailable    74
M365_BUSINESS_PREMIUM             Microsoft 365 Business Premi… ServiceAvailable    50
...

Generating HTML report...
HTML report exported to: c:\temp\Get-M365MonthToMonthSubscriptions\Contoso_Inc__04_20_26_14_30_45.html

Generating JSON report...
JSON report exported to: c:\temp\Get-M365MonthToMonthSubscriptions\Contoso_Inc__04_20_26_14_30_45.json

==========================================

Export Summary:
  Output Directory: c:\temp\Get-M365MonthToMonthSubscriptions
  Tenant Name: Contoso_Inc
  Total Subscriptions: 12
  HTML File: Contoso_Inc__04_20_26_14_30_45.html
  JSON File: Contoso_Inc__04_20_26_14_30_45.json

Disconnecting from Microsoft Graph...
Disconnected successfully.
```

## Examples

### Example 1: Basic Execution

```powershell
.\Get-M365MonthToMonthSubscriptions.ps1
```

**Output**: Connects to default tenant and exports both HTML and JSON reports.

### Example 2: Specific Tenant

```powershell
.\Get-M365MonthToMonthSubscriptions.ps1 -TenantId "a1b2c3d4-e5f6-g7h8-i9j0-k1l2m3n4o5p6"
```

**Output**: Connects to specified tenant and exports reports.

### Example 3: Scheduled Task

```powershell
# PowerShell scheduled task action
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Get-M365MonthToMonthSubscriptions.ps1"
```

**Usage**: Configure to run weekly for ongoing compliance reporting.

### Example 4: Programmatic Usage

```powershell
# Store results for further processing
$subscriptions = & "C:\Scripts\Get-M365MonthToMonthSubscriptions.ps1"
```

## Troubleshooting

### Error: "Cannot bind argument to parameter 'TenantName' because it is an empty string"

**Cause**: Organization display name could not be retrieved from Microsoft Graph.

**Solution**: 
- Verify your Microsoft Entra ID user account has Global Reader or Directory Reader role
- Ensure proper connectivity to Microsoft Graph
- The script will automatically use fallback naming: `Unknown_Tenant_MM_DD_YY`

### Error: "The 'Microsoft.Graph.Identity.DirectoryManagement' module cannot be found"

**Cause**: Required PowerShell module is not installed.

**Solution**:
```powershell
Install-Module -Name Microsoft.Graph.Identity.DirectoryManagement -Force
```

### Error: "Connect-MgGraph: No MFA token found"

**Cause**: Not authenticated or authentication token expired.

**Solution**:
```powershell
# Clear cached tokens
Disconnect-MgGraph -ErrorAction SilentlyContinue

# Re-run script to trigger fresh authentication
.\Get-M365MonthToMonthSubscriptions.ps1
```

### Error: "Access Denied" or "Insufficient Privileges"

**Cause**: User account lacks required permissions.

**Solution**:
- Ensure user account has Global Administrator or Security Administrator role
- Request elevated permissions from your tenant administrator
- Verify Graph API scopes (Organization.Read.All, Directory.Read.All)

### No Subscriptions Found

**Cause**: Tenant has no subscriptions or query returned no results.

**Solution**:
- Verify tenant has active Microsoft 365 subscriptions
- Check user account permissions in Azure Portal
- Confirm connection to correct tenant (verify Tenant ID in output)

### Export Directory Does Not Exist

**Cause**: `c:\temp\Get-M365MonthToMonthSubscriptions\` directory cannot be created.

**Solution**:
```powershell
# Manually create directory with proper permissions
New-Item -ItemType Directory -Path "c:\temp\Get-M365MonthToMonthSubscriptions" -Force
```

## Technical Architecture

### Component Overview

```
┌─────────────────────────────────────────┐
│  PowerShell Script Execution            │
├─────────────────────────────────────────┤
│                                         │
│  ┌─────────────────────────────────┐   │
│  │ Connect-ToMgGraph               │   │
│  │ (Microsoft Graph Auth)          │   │
│  └──────────────┬──────────────────┘   │
│                 │                      │
│  ┌──────────────▼──────────────────┐   │
│  │ Get-OrganizationLicensingInfo   │   │
│  │ (Tenant Metadata)               │   │
│  └──────────────┬──────────────────┘   │
│                 │                      │
│  ┌──────────────▼──────────────────┐   │
│  │ Get-MonthToMonthSubscriptions   │   │
│  │ (Get-MgSubscribedSku)           │   │
│  │ (Get-SKUAlias)                  │   │
│  └──────────────┬──────────────────┘   │
│                 │                      │
│        ┌────────┴─────────┐            │
│        │                  │            │
│  ┌─────▼──────────┐  ┌────▼─────────┐ │
│  │ Export-ToHTML  │  │ Export-ToJSON │ │
│  │ (Interactive   │  │ (Machine-     │ │
│  │  Report)       │  │  Readable)    │ │
│  └────────────────┘  └───────────────┘ │
│                                         │
└─────────────────────────────────────────┘
```

### Function Details

#### `Connect-ToMgGraph()`
Establishes authenticated connection to Microsoft Graph API using OAuth 2.0.

#### `Get-SKUAlias()`
Maps technical SKU identifiers to human-readable product names via lookup table.

#### `Get-MonthToMonthSubscriptions()`
Queries Graph API for subscriptions and enriches data with SKU names and metrics.

#### `Get-OrganizationLicensingInfo()`
Retrieves organization metadata for report naming and identification.

#### `Export-ToHTML()`
Generates interactive HTML report with sorting, filtering, and CSV export capabilities.

#### `Export-ToJSON()`
Generates structured JSON export for programmatic analysis.

## Performance Considerations

| Metric | Typical Value | Notes |
|--------|---------------|-------|
| Execution Time | 30-60 seconds | Includes Microsoft Graph API calls |
| Data Size | 50 KB - 2 MB | Depends on subscription count |
| HTML Report Size | 200 KB - 500 KB | Includes embedded CSS/JavaScript |
| JSON Report Size | 50 KB - 150 KB | Compressed structured data |

### Optimization Tips

- Run during off-peak hours to minimize Graph API throttling
- Store reports in SSD for faster write operations
- Use JSON for programmatic processing (faster parsing than HTML)
- Schedule execution weekly to balance monitoring with API quota usage

## Security Considerations

### Authentication

- Script uses modern OAuth 2.0 via Microsoft Graph
- Credentials stored securely in Windows credential manager (no plaintext)
- Multi-factor authentication (MFA) supported and recommended

### Data Protection

- Reports contain sensitive licensing information
- Store exports in secure, access-controlled directories
- Consider encrypting reports at rest if storing long-term
- Implement audit logging for compliance tracking

### API Permissions

- Uses principle of least privilege (Organization.Read.All, Directory.Read.All)
- No write permissions requested
- Read-only access to subscription data

## Maintenance

### Regular Updates

- Review SKU alias table quarterly for new Microsoft products
- Monitor Microsoft Graph API changes and deprecations
- Test monthly with sample tenants to ensure functionality

### Log Rotation

Implement log cleanup for older exports:

```powershell
# Remove exports older than 90 days
Get-ChildItem "c:\temp\Get-M365MonthToMonthSubscriptions" -Filter "*.html" | 
Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-90) } | 
Remove-Item -Force
```

### Version Control

Track script versions using naming convention:
- `Get-M365MonthToMonthSubscriptions_v1.0.0.ps1`
- `Get-M365MonthToMonthSubscriptions_v1.1.0.ps1`

## Support & Feedback

For issues, enhancements, or questions:

1. Review troubleshooting section above
2. Verify all prerequisites are installed
3. Check Microsoft Graph API documentation
4. Contact your IT department or system administrator

## Changelog

### Version 1.0.0 (2026-04-20)

- Initial release
- Full HTML and JSON export support
- Interactive HTML reports with sorting and filtering
- SKU aliasing for 25+ common products
- Error handling and fallback tenant naming
- Timestamped exports organized by tenant
