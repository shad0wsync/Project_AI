---
name: Get-ADInactiveAccounts
version: 1.0.0
title: 'Get-ADInactiveAccounts - Active Directory Inactive Account Report'
last_updated: 2026-05-29T12:21:18Z
author: Jay Smith
---

# Get-ADInactiveAccounts

## Overview

`Get-ADInactiveAccounts.ps1` scans Active Directory for user and computer accounts that have not signed in for 30 days or more. It exports the results into timestamped CSV and JSON files located under `c:\temp\Get-ADInactiveAccounts\`.

## Purpose

- Identify stale AD user accounts that have not logged on in the last 30 days
- Identify stale AD computer accounts that have not authenticated in the last 30 days
- Provide audit-ready exports for remediation, cleanup, and compliance review

## Requirements

- Windows PowerShell with the `ActiveDirectory` module available
- Domain-joined workstation or domain controller with AD read permissions
- Permission to query AD user and computer objects

## Usage

Open PowerShell as an administrator and run:

```powershell
.\\Scripts\\Powershell\\Get-ADInactiveAccounts.ps1
```

Optional parameters:

```powershell
.\\Scripts\\Powershell\\Get-ADInactiveAccounts.ps1 -DaysInactive 60
.\\Scripts\\Powershell\\Get-ADInactiveAccounts.ps1 -IncludeDisabled:$false
.\\Scripts\\Powershell\\Get-ADInactiveAccounts.ps1 -ExportRoot 'd:\reports'
```

## Output

- `c:\temp\Get-ADInactiveAccounts\Get-ADInactiveAccounts[yyyyMMdd-HHmmss].csv`
- `c:\temp\Get-ADInactiveAccounts\Get-ADInactiveAccounts[yyyyMMdd-HHmmss].json`

The CSV file contains one row per inactive account. The JSON file includes metadata plus the same account details.

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `DaysInactive` | int | `30` | Number of days since last logon to treat an account as inactive |
| `IncludeDisabled` | switch | `$true` | Include disabled accounts in the report |
| `ExportRoot` | string | `c:\temp` | Root folder for exports |

## Report Fields

- `ObjectType` — `User` or `Computer`
- `Name` — AD object name
- `SamAccountName` — logon name
- `DistinguishedName` — AD path
- `Enabled` — enabled state
- `LastLogonDate` — last sign-in timestamp or `Never`
- `InactiveThreshold` — threshold date used for the report
- `InactiveReason` — why the object was included
- `WhenCreated` — object creation date
- `WhenChanged` — last AD modification date
- `AdditionalInfo` — UPN for users, operating system for computers

## Notes

- The script uses `LastLogonDate`, which is replicated and suitable for reporting.
- Accounts with no recorded sign-in are reported as `Never signed in`.
- If the `ActiveDirectory` module is unavailable, the script will exit with an error.

## Example

```powershell
.\\Scripts\\Powershell\\Get-ADInactiveAccounts.ps1 -DaysInactive 30 -IncludeDisabled:$true
```

This produces timestamped export files in `c:\temp\Get-ADInactiveAccounts\`.
