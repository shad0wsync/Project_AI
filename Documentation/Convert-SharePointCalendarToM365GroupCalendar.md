# Convert SharePoint calendars to Microsoft 365 group calendars

## Overview

This runbook documents a PowerShell workflow for capturing SharePoint calendar items, migrating them into a Microsoft 365 group calendar, and preserving enough rollback state to remove the imported items later.

## Prerequisites

- PowerShell 7+
- PnP PowerShell
- Microsoft Graph PowerShell
- Permissions to read the source SharePoint calendar and write to the target Microsoft 365 group calendar

## Workflow

1. Run the script in SaveState mode to inventory the SharePoint calendar.
2. Review the JSON state file and then run Migrate to create matching events in the group calendar.
3. If rollback is needed, run Restore to remove the generated events using the saved identifiers.

## Example usage

```powershell
./Scripts/Powershell/SharePoint/Convert-SharePointCalendarToM365GroupCalendar.ps1 -Mode SaveState -SourceSiteUrl https://contoso.sharepoint.com/sites/HR -SourceListName "Company Calendar" -GroupId "11111111-2222-3333-4444-555555555555"

./Scripts/Powershell/SharePoint/Convert-SharePointCalendarToM365GroupCalendar.ps1 -Mode Migrate -SourceSiteUrl https://contoso.sharepoint.com/sites/HR -SourceListName "Company Calendar" -GroupId "11111111-2222-3333-4444-555555555555" -StatePath C:\temp\calendar-migration-state.json

./Scripts/Powershell/SharePoint/Convert-SharePointCalendarToM365GroupCalendar.ps1 -Mode Restore -SourceSiteUrl https://contoso.sharepoint.com/sites/HR -SourceListName "Company Calendar" -GroupId "11111111-2222-3333-4444-555555555555" -StatePath C:\temp\calendar-migration-state.json
```
