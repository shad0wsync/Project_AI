#Requires -Version 7.0

<#
.SYNOPSIS
    Exports SharePoint calendar items to a Microsoft 365 group calendar and preserves rollback state.

.DESCRIPTION
    This script supports three modes:
      - SaveState: inventories SharePoint calendar items and writes a JSON state file.
      - Migrate: reads the saved state and creates matching events in the target Microsoft 365 group calendar.
      - Restore: reads the saved state file and removes the previously created events from the target group calendar.

    The save-state file is intentionally designed to support a controlled migration workflow with rollback capability.

.PARAMETER Mode
    The operation to perform: SaveState, Migrate, or Restore.

.PARAMETER SourceSiteUrl
    The SharePoint site URL that contains the calendar list.

.PARAMETER SourceListName
    The SharePoint calendar list name.

.PARAMETER GroupId
    The Microsoft 365 group object ID that owns the destination calendar.

.PARAMETER StatePath
    Path to the JSON state file that will be created or consumed.

.PARAMETER TenantId
    Optional tenant ID used when connecting to Graph. Leave empty when using the default tenant context.

.EXAMPLE
    .\Convert-SharePointCalendarToM365GroupCalendar.ps1 -Mode SaveState -SourceSiteUrl https://contoso.sharepoint.com/sites/HR -SourceListName "Company Calendar" -GroupId "11111111-2222-3333-4444-555555555555"

.EXAMPLE
    .\Convert-SharePointCalendarToM365GroupCalendar.ps1 -Mode Migrate -SourceSiteUrl https://contoso.sharepoint.com/sites/HR -SourceListName "Company Calendar" -GroupId "11111111-2222-3333-4444-555555555555" -StatePath C:\temp\calendar-migration-state.json

.EXAMPLE
    .\Convert-SharePointCalendarToM365GroupCalendar.ps1 -Mode Restore -SourceSiteUrl https://contoso.sharepoint.com/sites/HR -SourceListName "Company Calendar" -GroupId "11111111-2222-3333-4444-555555555555" -StatePath C:\temp\calendar-migration-state.json

.NOTES
    Author: Jay Smith
    Version: 1.0.0
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('SaveState', 'Migrate', 'Restore')]
    [string]$Mode,

    [Parameter(Mandatory = $true)]
    [string]$SourceSiteUrl,

    [Parameter(Mandatory = $true)]
    [string]$SourceListName,

    [Parameter(Mandatory = $true)]
    [string]$GroupId,

    [Parameter(Mandatory = $false)]
    [string]$StatePath = (Join-Path -Path $PSScriptRoot -ChildPath 'sharepoint-calendar-migration-state.json'),

    [Parameter(Mandatory = $false)]
    [string]$TenantId,

    [Parameter(Mandatory = $false)]
    [switch]$UseGraphBeta
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.0.0'
$ScriptName = Split-Path -Leaf $MyInvocation.MyCommand.Path
$GraphVersion = if ($UseGraphBeta) { 'beta' } else { 'v1.0' }

function Assert-RequiredModule {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ModuleName,

        [Parameter(Mandatory = $true)]
        [string]$InstallHint
    )

    if (-not (Get-Module -ListAvailable -Name $ModuleName)) {
        throw "Required module '$ModuleName' is not installed. $InstallHint"
    }

    Import-Module -Name $ModuleName -ErrorAction Stop
}

function Connect-RequiredModules {
    if (-not (Get-Command Connect-PnPOnline -ErrorAction SilentlyContinue)) {
        throw 'PnP PowerShell is required. Install it with Install-Module PnP.PowerShell -Scope CurrentUser.'
    }

    if (-not (Get-Command Connect-MgGraph -ErrorAction SilentlyContinue)) {
        throw 'Microsoft Graph PowerShell is required. Install it with Install-Module Microsoft.Graph -Scope CurrentUser.'
    }

    Assert-RequiredModule -ModuleName 'PnP.PowerShell' -InstallHint 'Install-Module PnP.PowerShell -Scope CurrentUser'
    Assert-RequiredModule -ModuleName 'Microsoft.Graph' -InstallHint 'Install-Module Microsoft.Graph -Scope CurrentUser'

    if ($TenantId) {
        Connect-MgGraph -TenantId $TenantId -Scopes 'Group.Read.All', 'Group.ReadWrite.All', 'Calendars.ReadWrite' -NoWelcome
    }
    else {
        Connect-MgGraph -Scopes 'Group.Read.All', 'Group.ReadWrite.All', 'Calendars.ReadWrite' -NoWelcome
    }

    Connect-PnPOnline -Url $SourceSiteUrl -Interactive
}

function Convert-ToGraphDateTime {
    param(
        [Parameter(Mandatory = $false)]
        [datetime]$Value
    )

    if (-not $Value) {
        return $null
    }

    return ([datetime]$Value).ToUniversalTime().ToString('o')
}

function Get-SharePointCalendarItems {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SiteUrl,

        [Parameter(Mandatory = $true)]
        [string]$ListName
    )

    $list = Get-PnPList -Identity $ListName -ErrorAction Stop
    if (-not $list) {
        throw "SharePoint list '$ListName' was not found."
    }

    $items = Get-PnPListItem -List $list -PageSize 100
    $results = foreach ($item in $items) {
        $values = $item.FieldValues
        [PSCustomObject]@{
            Id = [string]$item.Id
            Title = [string]$values.Title
            StartTime = if ($values.EventDate) { [datetime]$values.EventDate } elseif ($values.StartDate) { [datetime]$values.StartDate } else { $null }
            EndTime = if ($values.EndDate) { [datetime]$values.EndDate } elseif ($values.EndDateTime) { [datetime]$values.EndDateTime } else { $null }
            Location = [string]$values.Location
            Description = [string]$values.Description
            EventType = [string]$values.EventType
            Created = if ($values.Created) { [datetime]$values.Created } else { $null }
            Modified = if ($values.Modified) { [datetime]$values.Modified } else { $null }
        }
    }

    return @($results)
}

function Invoke-GraphRequest {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('GET', 'POST', 'DELETE', 'PATCH')]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [object]$Body
    )

    $params = @{
        Method = $Method
        Uri = "https://graph.microsoft.com/$GraphVersion/$Path"
        ContentType = 'application/json'
    }

    if ($Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 8)
    }

    return Invoke-MgGraphRequest @params
}

function New-M365GroupCalendarEvent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GroupIdentifier,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$CalendarItem
    )

    $body = [ordered]@{
        subject = if ($CalendarItem.Title) { $CalendarItem.Title } else { 'Imported SharePoint Calendar Item' }
        body = [ordered]@{
            contentType = 'HTML'
            content = if ($CalendarItem.Description) { $CalendarItem.Description } else { 'Imported from SharePoint calendar.' }
        }
        start = [ordered]@{
            dateTime = Convert-ToGraphDateTime -Value $CalendarItem.StartTime
            timeZone = 'UTC'
        }
        end = [ordered]@{
            dateTime = Convert-ToGraphDateTime -Value $CalendarItem.EndTime
            timeZone = 'UTC'
        }
        location = [ordered]@{
            displayName = if ($CalendarItem.Location) { $CalendarItem.Location } else { 'Imported from SharePoint' }
        }
        showAs = 'busy'
    }

    return Invoke-GraphRequest -Method POST -Path "groups/$GroupIdentifier/events" -Body $body
}

function Remove-M365GroupCalendarEvent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GroupIdentifier,

        [Parameter(Mandatory = $true)]
        [string]$EventId
    )

    if ([string]::IsNullOrWhiteSpace($EventId)) {
        return $null
    }

    return Invoke-GraphRequest -Method DELETE -Path "groups/$GroupIdentifier/events/$EventId"
}

function Save-StateFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [object]$State
    )

    $parentPath = Split-Path -Path $Path -Parent
    if ($parentPath) {
        New-Item -ItemType Directory -Path $parentPath -Force | Out-Null
    }

    $State | ConvertTo-Json -Depth 8 | Set-Content -Path $Path -Encoding UTF8
    return $Path
}

function Get-StateFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path)) {
        throw "State file '$Path' was not found."
    }

    return Get-Content -Path $Path -Raw | ConvertFrom-Json -AsHashtable
}

try {
    Connect-RequiredModules

    switch ($Mode) {
        'SaveState' {
            $state = [ordered]@{
                scriptName = $ScriptName
                version = $ScriptVersion
                timestamp = (Get-Date).ToUniversalTime().ToString('o')
                sourceSiteUrl = $SourceSiteUrl
                sourceListName = $SourceListName
                groupId = $GroupId
                tenantId = $TenantId
                mode = 'SaveState'
                events = @()
            }

            $items = Get-SharePointCalendarItems -SiteUrl $SourceSiteUrl -ListName $SourceListName
            foreach ($item in $items) {
                $state.events += [ordered]@{
                    sourceId = $item.Id
                    title = $item.Title
                    startTime = Convert-ToGraphDateTime -Value $item.StartTime
                    endTime = Convert-ToGraphDateTime -Value $item.EndTime
                    location = $item.Location
                    description = $item.Description
                    eventType = $item.EventType
                    created = Convert-ToGraphDateTime -Value $item.Created
                    modified = Convert-ToGraphDateTime -Value $item.Modified
                    destinationEventId = $null
                    migrated = $false
                }
            }

            Save-StateFile -Path $StatePath -State $state | Out-Null
            Write-Host "State file saved: $StatePath" -ForegroundColor Green
            Write-Host "Captured $($state.events.Count) calendar item(s)." -ForegroundColor Green
        }

        'Migrate' {
            $state = Get-StateFile -Path $StatePath
            if ($state.mode -ne 'SaveState') {
                throw "State file '$StatePath' does not contain a SaveState snapshot."
            }

            foreach ($entry in @($state.events)) {
                if ($entry.migrated) {
                    continue
                }

                $calendarItem = [PSCustomObject]@{
                    Id = $entry.sourceId
                    Title = $entry.title
                    StartTime = if ($entry.startTime) { [datetime]$entry.startTime } else { $null }
                    EndTime = if ($entry.endTime) { [datetime]$entry.endTime } else { $null }
                    Location = $entry.location
                    Description = $entry.description
                }

                if ($PSCmdlet.ShouldProcess($entry.title, 'Create group calendar event')) {
                    $response = New-M365GroupCalendarEvent -GroupIdentifier $GroupId -CalendarItem $calendarItem
                    $entry.destinationEventId = $response.id
                    $entry.migrated = $true
                    $entry.lastMigrated = (Get-Date).ToUniversalTime().ToString('o')
                }
            }

            $state.mode = 'Migrate'
            $state.timestamp = (Get-Date).ToUniversalTime().ToString('o')
            Save-StateFile -Path $StatePath -State $state | Out-Null
            Write-Host "Migration complete. State file updated: $StatePath" -ForegroundColor Green
        }

        'Restore' {
            $state = Get-StateFile -Path $StatePath
            if ($state.mode -eq 'Restore') {
                Write-Host 'State file already reflects a restore operation.' -ForegroundColor Yellow
                return
            }

            foreach ($entry in @($state.events)) {
                if (-not $entry.migrated -or [string]::IsNullOrWhiteSpace($entry.destinationEventId)) {
                    continue
                }

                if ($PSCmdlet.ShouldProcess($entry.title, 'Delete group calendar event')) {
                    Remove-M365GroupCalendarEvent -GroupIdentifier $GroupId -EventId $entry.destinationEventId | Out-Null
                    $entry.migrated = $false
                    $entry.destinationEventId = $null
                    $entry.lastRestored = (Get-Date).ToUniversalTime().ToString('o')
                }
            }

            $state.mode = 'Restore'
            $state.timestamp = (Get-Date).ToUniversalTime().ToString('o')
            Save-StateFile -Path $StatePath -State $state | Out-Null
            Write-Host "Restore complete. State file updated: $StatePath" -ForegroundColor Green
        }
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
