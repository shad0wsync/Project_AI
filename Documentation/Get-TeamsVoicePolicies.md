---
name: Get-TeamsVoicePolicies
version: 1.0.0
title: 'Teams Voice Policies Audit Script - Technical Documentation'
last_updated: 2026-04-20
---

# Get-TeamsVoicePolicies - Technical Documentation

## Overview

**Get-TeamsVoicePolicies.ps1** is a comprehensive PowerShell auditing script that gathers and reports on all Microsoft Teams voice policies within a tenant. The script automatically generates interactive HTML and JSON exports for policy review, comparison, and compliance documentation.

### Purpose
Organizations need visibility into Teams voice policy configurations to ensure:
- Compliance with internal security policies
- Consistent policy application across the tenant
- Billing and licensing alignment with policy assignments
- Audit trail for regulatory requirements
- Easy identification of non-standard policies

### Quick Facts
- **Language**: PowerShell 5.0+
- **Required Modules**: MicrosoftTeams, Microsoft.Graph.Identity.DirectoryManagement
- **Execution Time**: 30-90 seconds (depending on policy count)
- **Output Format**: Interactive HTML (browser-viewable) + JSON (programmatic)
- **Export Location**: `c:\temp\Get-TeamsVoicePolicies\[OrganizationName]__MM_DD_YY_HH_MM_SS.[filetype]`

---

## Features & Capabilities

### Policy Data Collection

The script retrieves and reports on four primary policy categories:

#### 1. **Teams Calling Policies**
- Private calling enablement
- Voicemail integration
- Call groups availability
- Delegation settings
- Busy-on-busy configuration
- Music on hold settings

#### 2. **Teams Voicemail Policies**
- Transcription enablement
- Profanity masking settings
- Transcription translation options
- Maximum voicemail duration
- Voicemail format preferences

#### 3. **Calling Line Identity Policies**
- Calling ID substitution settings
- User override permissions
- Resource account associations
- Compliance recording status

#### 4. **Teams Voice Routing Policies**
- PSTN gateway configuration
- Route type definitions
- Policy-to-gateway associations

### Interactive HTML Report Features

#### Sorting Capabilities
- Click any column header to sort ascending/descending
- Numeric and text sorting supported
- Sort state persists within session

#### Filtering Options
- **Search Box**: Real-time search across all fields
- **Policy Type Filters**: Quick-filter by:
  - All Policies
  - Calling Policies
  - Voicemail Policies
  - Identity Policies
  - Routing Policies
- **Reset Function**: Clear all filters in one click

#### Export Functionality
- **CSV Export**: Download filtered/sorted results as CSV
- **Color-Coded Badges**: Visual policy type identification
- **Hover Effects**: Interactive row highlighting

#### Visual Design
- Professional gradient header (Teams-branded colors)
- Responsive table layout (horizontal scroll on small screens)
- Color-coded policy type badges for quick identification
- Accessibility-friendly contrast ratios

### JSON Report Features

#### Structured Format
```json
{
  "GeneratedDate": "ISO 8601 timestamp",
  "TotalPolicies": <number>,
  "Policies": [
    {
      "PolicyType": "Policy category",
      "PolicyName": "Unique policy identifier",
      "Description": "Policy description",
      "KeySetting1": "Value",
      "KeySetting2": "Value"
    }
  ]
}
```

#### Benefits
- Machine-readable for programmatic analysis
- Integration-ready for automation frameworks
- Full policy metadata preservation
- Timestamped for version control

---

## Prerequisites & Permissions

### System Requirements
- **OS**: Windows 10/11 or Windows Server 2019+
- **PowerShell**: Version 5.0 or later
- **Internet**: Active connection to Microsoft Teams and Microsoft Graph
- **Disk Space**: ~1GB for module dependencies

### User Permissions

**Teams Administrator Role** (minimum required):
- Global Administrator (recommended for initial setup)
- Teams Administrator
- Skype for Business Administrator

**Microsoft Graph Scopes** (required):
- `Organization.Read.All` - Read organization information
- `Directory.Read.All` - Read directory data

### Required PowerShell Modules

#### Microsoft Teams Module
```powershell
# Check if installed
Get-Module -ListAvailable MicrosoftTeams

# Install if needed
Install-Module -Name MicrosoftTeams -Force -AllowClobber
```

**Version Requirements**: v4.9.0 or higher

#### Microsoft Graph PowerShell SDK
```powershell
# Install Microsoft Graph module
Install-Module -Name Microsoft.Graph -Force -AllowClobber

# Or install specific component
Install-Module -Name Microsoft.Graph.Identity.DirectoryManagement -Force
```

### Execution Policy

```powershell
# Check current execution policy
Get-ExecutionPolicy

# If restricted, set to RemoteSigned for user scope
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
```

### Network Requirements
- Access to `teams.microsoft.com`
- Access to `graph.microsoft.com`
- Outbound HTTPS (port 443) connectivity
- No proxy authentication requirements (or configure proxy settings)

---

## Installation Guide

### Step 1: Install Required Modules

```powershell
# Install Teams PowerShell Module
Install-Module -Name MicrosoftTeams -Force -AllowClobber

# Install Microsoft Graph Module
Install-Module -Name Microsoft.Graph -Force -AllowClobber
```

Expected output:
```
Installing module 'MicrosoftTeams' ...
Publishing module 'MicrosoftTeams' 4.9.x ...
Module installation succeeded.
```

### Step 2: Download Script

Place `Get-TeamsVoicePolicies.ps1` in one of:
- Current working directory
- `C:\Scripts\` (create if needed)
- Any location in PowerShell `$PROFILE` path

### Step 3: Configure Execution Policy (if needed)

```powershell
# Set for current user only
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
```

### Step 4: Verify Connectivity

Test Teams connection:
```powershell
Connect-MicrosoftTeams
# When prompted, sign in with admin credentials
Get-CsTeamsCallingPolicy
Disconnect-MicrosoftTeams
```

### Step 5: Create Export Directory

The script auto-creates the export directory, but you can pre-create it:
```powershell
New-Item -ItemType Directory -Path "c:\temp\Get-TeamsVoicePolicies" -Force
```

---

## Usage Examples

### Example 1: Basic Execution (Default Tenant)

```powershell
# Navigate to script directory
cd C:\Scripts

# Run script with default tenant
.\Get-TeamsVoicePolicies.ps1
```

**Console Output:**
```
Connecting to Microsoft Teams Admin...
Connected to Teams successfully.
Connecting to Microsoft Graph...
Connected to Microsoft Graph successfully.
Retrieving organization information...
Organization: Contoso Inc
==========================================

Retrieving Teams voice policies...
  - Retrieving Teams Call Policies...
  - Retrieving Teams Voicemail Policies...
  - Retrieving Teams Calling Line Identity Policies...
  - Retrieving Teams Voice Routing Policies...
Found 27 total voice policies

==========================================

Generating HTML report...
HTML report exported to: c:\temp\Get-TeamsVoicePolicies\Contoso_Inc__04_20_26_14_30_45.html
Generating JSON report...
JSON report exported to: c:\temp\Get-TeamsVoicePolicies\Contoso_Inc__04_20_26_14_30_45.json

==========================================

Export Summary:
  Output Directory: c:\temp\Get-TeamsVoicePolicies
  Organization Name: Contoso_Inc
  Total Voice Policies: 27
  HTML File: Contoso_Inc__04_20_26_14_30_45.html
  JSON File: Contoso_Inc__04_20_26_14_30_45.json

Disconnecting from Teams and Microsoft Graph...
Disconnected successfully.
```

### Example 2: Specify Tenant ID

```powershell
$tenantId = "a1234567-b890-c123-d456-e78901234567"
.\Get-TeamsVoicePolicies.ps1 -TenantId $tenantId
```

Use this when:
- Managing multiple tenants
- Service principal authentication
- Connecting to specific Azure AD tenant

### Example 3: Scheduled Audit (Weekly)

Create scheduled task in Task Scheduler:

```powershell
# PowerShell script to schedule (schedule-audit.ps1)
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At 2:00AM
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
  -Argument "-NoProfile -WindowStyle Hidden -File 'C:\Scripts\Get-TeamsVoicePolicies.ps1'"
$principal = New-ScheduledTaskPrincipal -UserID "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName "TeamsVoiceAudit" `
  -Trigger $trigger `
  -Action $action `
  -Principal $principal `
  -Description "Weekly Teams voice policies audit"
```

**Output Location**: Reports automatically saved to `c:\temp\Get-TeamsVoicePolicies\` with timestamped filenames

### Example 4: Programmatic Analysis (PowerShell)

```powershell
# Read JSON export for programmatic analysis
$policyReport = Get-Content "c:\temp\Get-TeamsVoicePolicies\Contoso_Inc__04_20_26_14_30_45.json" | ConvertFrom-Json

# Find all calling policies
$callingPolicies = $policyReport.Policies | Where-Object { $_.PolicyType -eq "Teams Calling Policy" }

# Export to custom format
$callingPolicies | Export-Csv -Path "calling-policies-export.csv" -NoTypeInformation

# Count policies by type
$policyReport.Policies | Group-Object -Property PolicyType | Select-Object Name, Count
```

### Example 5: Compliance Reporting

```powershell
# Generate multiple reports for compliance archive
$dates = @("Monday", "Wednesday", "Friday")
foreach ($day in $dates) {
    if ((Get-Date).DayOfWeek -eq $day) {
        .\Get-TeamsVoicePolicies.ps1
        $files = Get-ChildItem "c:\temp\Get-TeamsVoicePolicies" -Filter "*.json" | 
                 Sort-Object LastWriteTime -Descending | 
                 Select-Object -First 1
        Copy-Item $files.FullName "c:\compliance-archive\$(Get-Date -Format 'yyyy-MM-dd')_teams_voices_policies.json"
    }
}
```

---

## Output Reference

### Export File Naming Convention

```
[ScriptName]__[TenantName]__MM_DD_YY_HH_MM_SS.[filetype]
```

**Examples:**
- `Contoso_Inc__04_20_26_14_30_45.html`
- `Contoso_Inc__04_20_26_14_30_45.json`
- `Unknown_Organization_04_20_26.html` (fallback if org info unavailable)

### Export Directory Structure

```
c:\temp\Get-TeamsVoicePolicies\
├── Contoso_Inc__04_20_26_14_30_45.html
├── Contoso_Inc__04_20_26_14_30_45.json
├── Contoso_Inc__04_21_26_14_30_45.html
├── Contoso_Inc__04_21_26_14_30_45.json
└── [additional reports...]
```

### HTML Report Sections

| Section | Purpose |
|---------|---------|
| **Header** | Report title, generation timestamp, organization name |
| **Controls** | Search box, type filters, reset button, CSV export |
| **Table** | Sortable/filterable policy listing with details |
| **Footer** | Total policy count, report metadata |

### JSON Report Fields

| Field | Type | Description |
|-------|------|-------------|
| `GeneratedDate` | ISO 8601 | Timestamp when report was created |
| `TotalPolicies` | Integer | Count of all voice policies |
| `Policies` | Array | Array of policy objects with all details |
| `PolicyType` | String | Category: Calling, Voicemail, Identity, Routing |
| `PolicyName` | String | Unique policy identifier |
| `Description` | String | Policy description or notes |

---

## Troubleshooting

### Issue 1: "The term 'Connect-MicrosoftTeams' is not recognized"

**Cause**: MicrosoftTeams module not installed

**Solution**:
```powershell
Install-Module -Name MicrosoftTeams -Force -AllowClobber -SkipPublisherCheck
```

### Issue 2: "Access Denied" during connection

**Cause**: Insufficient permissions or wrong account

**Solution**:
1. Verify you have Teams Administrator role:
   ```powershell
   # Check current roles
   Get-MgDirectoryRole -Filter "displayName eq 'Teams Administrator'"
   ```

2. Try with Global Administrator account:
   ```powershell
   .\Get-TeamsVoicePolicies.ps1
   # Sign in with global admin credentials when prompted
   ```

3. Re-authenticate by clearing cached credentials:
   ```powershell
   Disconnect-MicrosoftTeams
   Disconnect-MgGraph
   # Wait 5 seconds then run script again
   ```

### Issue 3: "No voice policies found"

**Cause**: Tenant has no custom policies (only defaults) OR permission issues

**Solution**:
```powershell
# Check if you can query policies manually
Get-CsTeamsCallingPolicy

# If empty or error, check Teams PowerShell connection
Get-CsOnlineUser -ResultSize 1
```

### Issue 4: Export files not created

**Cause**: Directory doesn't exist and script lacks creation permissions

**Solution**:
```powershell
# Create directory manually
New-Item -ItemType Directory -Path "c:\temp\Get-TeamsVoicePolicies" -Force

# Or run script with elevated privileges (Run as Administrator)
```

### Issue 5: "Cannot find path 'c:\temp\Get-TeamsVoicePolicies'"

**Cause**: Windows doesn't have write permissions to `c:\temp\`

**Solution**:

Option A - Use alternative location:
```powershell
# Edit script to use different path
$BaseExportPath = "C:\Users\$env:USERNAME\Documents\TeamsAudits"
```

Option B - Create with full permissions:
```powershell
New-Item -ItemType Directory -Path "c:\temp" -Force
New-Item -ItemType Directory -Path "c:\temp\Get-TeamsVoicePolicies" -Force
```

### Issue 6: Script times out during policy retrieval

**Cause**: Large number of policies or slow network connection

**Solution**:
1. Check network connectivity:
   ```powershell
   Test-Connection -ComputerName graph.microsoft.com -Count 1
   ```

2. Increase PowerShell timeout:
   ```powershell
   $PSDefaultParameterValues['*:OperationTimeoutSec'] = 180
   ```

3. Run during off-peak hours

### Issue 7: HTML report shows "JavaScript disabled"

**Cause**: JavaScript disabled in browser or browser security policy

**Solution**:
1. Enable JavaScript in browser settings
2. Try different browser (Chrome, Edge, Firefox)
3. Use JSON export instead for raw data review

### Issue 8: "The specified module could not be loaded" error

**Cause**: Module version conflict or corruption

**Solution**:
```powershell
# Uninstall and reinstall
Uninstall-Module -Name MicrosoftTeams -Force -AllowPrerelease
Install-Module -Name MicrosoftTeams -Force -AllowClobber -SkipPublisherCheck

# Clear module cache
Remove-Item -Path $PROFILE -Force
```

---

## Technical Architecture

### Component Diagram

```
┌─────────────────────────────────────────────────────┐
│     Get-TeamsVoicePolicies.ps1 (Main Script)       │
├─────────────────────────────────────────────────────┤
│                                                     │
│  ┌────────────────────────────────────────────┐   │
│  │  Connection Functions                      │   │
│  │  • Connect-TeamsAdmin()                    │   │
│  │  • Connect-ToMgGraph()                     │   │
│  │  • Get-OrganizationInfo()                  │   │
│  └────────────────────────────────────────────┘   │
│           ↓                                         │
│  ┌────────────────────────────────────────────┐   │
│  │  Data Retrieval Function                   │   │
│  │  • Get-AllTeamsVoicePolicies()             │   │
│  │    - Get-CsTeamsCallingPolicy              │   │
│  │    - Get-CsTeamsVoicemailPolicy            │   │
│  │    - Get-CsCallingLineIdentity             │   │
│  │    - Get-CsTeamsVoiceRoutingPolicy         │   │
│  └────────────────────────────────────────────┘   │
│           ↓                                         │
│  ┌────────────────────────────────────────────┐   │
│  │  Export Functions (Parallel)               │   │
│  │  ┌─────────────────┐  ┌─────────────────┐ │   │
│  │  │ Export-ToHTML() │  │ Export-ToJSON() │ │   │
│  │  └─────────────────┘  └─────────────────┘ │   │
│  └────────────────────────────────────────────┘   │
│           ↓                  ↓                     │
│           ↓                  ↓                     │
│  ┌───────────────────────────────────────────┐   │
│  │  Output Files (Timestamped)               │   │
│  │  • .html (interactive browser report)     │   │
│  │  • .json (structured data export)         │   │
│  └───────────────────────────────────────────┘   │
│                                                     │
└─────────────────────────────────────────────────────┘
```

### Function Call Sequence

1. **Main Execution Block**
   - Calls `Connect-TeamsAdmin()` → Authenticates to Teams
   - Calls `Connect-ToMgGraph()` → Authenticates to Graph
   - Calls `Get-OrganizationInfo()` → Retrieves org metadata

2. **Policy Data Collection**
   - Calls `Get-AllTeamsVoicePolicies()`
   - Internally calls four policy retrieval functions:
     - `Get-CsTeamsCallingPolicy`
     - `Get-CsTeamsVoicemailPolicy`
     - `Get-CsCallingLineIdentity`
     - `Get-CsTeamsVoiceRoutingPolicy`

3. **Export Phase (Parallel)**
   - If policies found, calls both:
     - `Export-ToHTML()` → Generates interactive report
     - `Export-ToJSON()` → Generates structured data
   - Both functions handle directory creation

4. **Cleanup**
   - Disconnects from Teams
   - Disconnects from Microsoft Graph

### Error Handling Strategy

```
Try-Catch Blocks:
├── Connection errors
│   └── Fallback: Display error, exit with code 1
├── Organization info retrieval
│   └── Fallback: Use "Unknown_Organization_" with date
├── Policy retrieval
│   └── Fallback: Display warning, continue or exit
├── Export function errors
│   └── Fallback: Display path errors, suggest solutions
└── Disconnection (non-fatal)
    └── Ignored errors during cleanup phase
```

---

## Performance Metrics

### Execution Timeline

| Phase | Duration | Notes |
|-------|----------|-------|
| Authentication | 5-10s | Depends on MFA/cached credentials |
| Organization Info | 2-3s | Graph query |
| Policy Retrieval | 15-30s | Scales with policy count |
| HTML Generation | 3-5s | Template rendering |
| JSON Generation | 2-3s | Serialization |
| Disconnection | 2-3s | Cleanup |
| **Total** | **30-60s** | Typical for 25-50 policies |

### Data Size Estimates

| Metric | Size | Notes |
|--------|------|-------|
| HTML File | 150-300 KB | Includes all styling/JavaScript |
| JSON File | 50-150 KB | Scales with policy count |
| Console Output | ~5 KB | Policy summary table |

### Scalability

- **Tested with**: 50-100 voice policies
- **Max recommended**: 200 policies per run
- **Performance degradation**: Minimal (linear)
- **Recommended execution frequency**: Daily/Weekly

---

## Security Considerations

### Authentication & Authorization

1. **OAuth 2.0 Flow**
   - Modern, secure authentication
   - Token-based (expires in ~1 hour)
   - Supports MFA and Conditional Access

2. **Required Scopes**
   ```
   - Organization.Read.All (read organization)
   - Directory.Read.All (read directory)
   ```

3. **Least Privilege**
   - Teams Administrator role is minimum
   - Global Administrator not required
   - Scopes limited to read-only operations

### Data Protection

1. **In Transit**
   - All API calls use HTTPS/TLS 1.2+
   - No plaintext credentials transmitted
   - OAuth tokens handled by PowerShell SDK

2. **At Rest**
   - Export files stored on local filesystem
   - NTFS permissions apply to export directory
   - No encryption applied by script (implement OS-level encryption)

3. **Recommended Security Hardening**
   ```powershell
   # Encrypt export directory
   cipher /e /s:c:\temp\Get-TeamsVoicePolicies

   # Set restrictive NTFS permissions
   $acl = Get-Acl "c:\temp\Get-TeamsVoicePolicies"
   $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) }
   $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
       "Administrators", "FullControl", "Allow")
   $acl.AddAccessRule($rule)
   Set-Acl "c:\temp\Get-TeamsVoicePolicies" $acl
   ```

### Credential Management

1. **Interactive Authentication**
   - Script uses interactive login flow
   - Credentials not stored in script
   - Browser-based authentication

2. **Cached Tokens**
   - PowerShell SDK caches tokens
   - Location: `$env:USERPROFILE\.graph\token_cache.json`
   - Tokens expire automatically

3. **Service Principal (Advanced)**
   ```powershell
   # Alternative for automation (requires additional setup)
   $credential = New-Object System.Management.Automation.PSCredential(
       "app-id", 
       (ConvertTo-SecureString "secret" -AsPlainText -Force))
   Connect-MicrosoftTeams -Credential $credential
   ```

### Audit Trail

- Script logs actions to PowerShell Event Log
- Each execution is timestamped in output files
- Consider logging to centralized SIEM:
  ```powershell
  # After script execution
  Write-EventLog -LogName Application `
    -Source "TeamsAudit" `
    -EventId 1000 `
    -Message "Teams voice policies audit completed"
  ```

### Compliance Considerations

- **GDPR**: Audit reports may contain organizational data
- **Data Retention**: Implement cleanup policy
  ```powershell
  # Remove reports older than 90 days
  Get-ChildItem "c:\temp\Get-TeamsVoicePolicies" -Filter "*.json" |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-90) } |
    Remove-Item -Force
  ```
- **SOC/HIPAA**: Store reports in compliance-audited location

---

## Maintenance Guidelines

### Regular Maintenance Tasks

#### Weekly
- Monitor export directory size
- Verify latest report generation
- Check for new policy creation

#### Monthly
- Review policy audit history
- Archive compliance copies
- Update module versions
  ```powershell
  Update-Module -Name MicrosoftTeams -Force
  Update-Module -Name Microsoft.Graph -Force
  ```

#### Quarterly
- Full security assessment
- Backup export directory
- Review error logs
- Test disaster recovery

### Module Updates

```powershell
# Check for updates
Get-Module -ListAvailable MicrosoftTeams | 
  Select-Object Name, Version

# Update to latest
Update-Module -Name MicrosoftTeams -Force -AllowClobber

# Verify update
Get-Module -ListAvailable MicrosoftTeams | 
  Select-Object Name, Version
```

### Log Management

Enable PowerShell Script Block Logging for audit trail:

```powershell
# Enable logging (admin PowerShell)
$basePath = "HKLM:\Software\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging"
if (-not (Test-Path $basePath)) {
    New-Item -Path $basePath -Force | Out-Null
}
Set-ItemProperty -Path $basePath -Name "EnableScriptBlockLogging" -Value 1

# View logs
Get-WinEvent -LogName "Windows PowerShell" | 
  Where-Object { $_.Message -match "Get-TeamsVoicePolicies" } |
  Format-List TimeCreated, Message
```

### Backup Strategy

```powershell
# Backup critical exports
$sourceDir = "c:\temp\Get-TeamsVoicePolicies"
$backupDir = "\\backup-server\archive\teams-audits\$(Get-Date -Format 'yyyy-MM')"

New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

Get-ChildItem -Path $sourceDir -Filter "*.json" | 
  Copy-Item -Destination $backupDir -Force

Write-Host "Backup completed to: $backupDir"
```

---

## Changelog

### Version 1.0.0 (2026-04-20)
- Initial release
- Support for 4 policy types (Calling, Voicemail, Identity, Routing)
- Interactive HTML reports with sorting and filtering
- JSON export for programmatic analysis
- Automatic dual export (HTML + JSON)
- Standardized export path naming convention
- Error handling with graceful fallbacks
- Organizations info validation
- Support for multi-tenant scenarios (optional TenantId parameter)

---

## Support & Resources

### Official Documentation
- [Teams PowerShell Module Docs](https://learn.microsoft.com/en-us/powershell/module/teams/)
- [Microsoft Graph PowerShell SDK](https://learn.microsoft.com/en-us/powershell/microsoftgraph/)
- [Teams Voice Policies Overview](https://learn.microsoft.com/en-us/microsoftteams/teams-calling-policy)

### Related Scripts
- `Get-M365MonthToMonthSubscriptions.ps1` - M365 licensing audit
- `Audit-TeamsVoiceSecurityCompliance.ps1` - Security compliance checking
- `Get-TeamsUsersWithDIDs.ps1` - User telephone number audit

### Contact & Feedback
For issues, enhancements, or feedback, document:
- Script version used
- Exact command executed
- Error message (full stack trace)
- Tenant size (approximate policy count)
- PowerShell version (`$PSVersionTable.PSVersion`)
- Module versions (`Get-Module -ListAvailable MicrosoftTeams | Select Version`)
