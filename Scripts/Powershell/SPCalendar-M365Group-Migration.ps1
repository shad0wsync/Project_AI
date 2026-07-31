#Requires -Version 7.4

<#
.NOTES
Name: SPCalendar-M365Group-Migration.ps1
Author: Infrastructure Coder
Version: 2.0
Date: 2026-07-30

Modes:
Document
Backup
Migrate
Restore

Required Modules:
PnP.PowerShell
Microsoft.Graph.Authentication
Microsoft.Graph.Groups
Microsoft.Graph.Calendar
#>

[CmdletBinding(SupportsShouldProcess)]
param(

    [Parameter(Mandatory)]
    [ValidateSet(
        "Document",
        "Backup",
        "Migrate",
        "Restore"
    )]
    [string]$Mode,

    [Parameter(Mandatory)]
    [string]$MappingCsv,

    [string]$OutputPath = "C:\Temp\SPCalendarMigration"
)

$ErrorActionPreference = "Stop"

#region Initialization

$null = New-Item `
    -ItemType Directory `
    -Path $OutputPath `
    -Force

$LogFile = Join-Path $OutputPath "Migration.log"
$StateFile = Join-Path $OutputPath "MigrationState.json"

function Write-Log {

    param([string]$Message)

    $entry = "{0} : {1}" -f `
        (Get-Date), `
        $Message

    Write-Host $entry

    Add-Content `
        -Path $LogFile `
        -Value $entry
}

function Save-State {

    param($State)

    $State |
        ConvertTo-Json -Depth 100 |
        Set-Content $StateFile
}

function Load-State {

    if(Test-Path $StateFile)
    {
        return Get-Content $StateFile -Raw |
            ConvertFrom-Json -Depth 100
    }

    return @{
        Migrations = @()
    }
}

#endregion

#region Connections

function Connect-MigrationServices {

    Write-Log "Connecting to Graph"

    Connect-MgGraph `
        -Scopes `
        "Group.ReadWrite.All",
        "Calendars.ReadWrite",
        "Sites.Read.All"

    Write-Log "Graph Connected"
}

#endregion

#region SharePoint

function Get-SPCalendarEvents {

    param(
        [string]$SiteUrl,
        [string]$CalendarName
    )

    Connect-PnPOnline `
        -Url $SiteUrl `
        -Interactive

    $items = Get-PnPListItem `
        -List $CalendarName `
        -PageSize 1000

    foreach($item in $items)
    {
        [PSCustomObject]@{

            ItemId      = $item.Id
            Title       = $item["Title"]

            Start       = $item["EventDate"]
            End         = $item["EndDate"]

            Location    = $item["Location"]
            Description = $item["Description"]

            Created     = $item["Created"]
            Modified    = $item["Modified"]
        }
    }
}

#endregion

#region Documentation

function Invoke-Documentation {

    Import-Csv $MappingCsv | ForEach-Object {

        $events = Get-SPCalendarEvents `
            -SiteUrl $_.SiteUrl `
            -CalendarName $_.CalendarName

        $report = [PSCustomObject]@{

            SiteUrl      = $_.SiteUrl
            CalendarName = $_.CalendarName
            EventCount   = ($events | Measure-Object).Count

            FirstEvent = (
                $events |
                Sort-Object Start |
                Select-Object -First 1
            ).Start

            LastEvent = (
                $events |
                Sort-Object Start |
                Select-Object -Last 1
            ).Start

            Generated = Get-Date
        }

        $report |
            Export-Csv `
            (Join-Path $OutputPath "CalendarInventory.csv") `
            -NoTypeInformation `
            -Append
    }

    Write-Log "Documentation completed"
}

#endregion

#region Backup

function Invoke-Backup {

    Import-Csv $MappingCsv | ForEach-Object {

        $events = Get-SPCalendarEvents `
            -SiteUrl $_.SiteUrl `
            -CalendarName $_.CalendarName

        $safeName = $_.CalendarName `
            -replace '[\\/:*?"<>|]','_'

        $backupFile = Join-Path `
            $OutputPath `
            "$safeName-Backup.csv"

        $events |
            Export-Csv `
            $backupFile `
            -NoTypeInformation

        Write-Log "Backup created $backupFile"
    }
}

#endregion

#region Migration

function Add-GroupEvent {

    param(
        [string]$GroupId,
        [object]$Event
    )

    $body = @{

        Subject = $Event.Title

        Body = @{
            ContentType = "HTML"
            Content     = $Event.Description
        }

        Start = @{
            DateTime = (
                Get-Date $Event.Start
            ).ToString("s")

            TimeZone = "UTC"
        }

        End = @{
            DateTime = (
                Get-Date $Event.End
            ).ToString("s")

            TimeZone = "UTC"
        }

        Location = @{
            DisplayName = $Event.Location
        }
    }

    New-MgGroupCalendarEvent `
        -GroupId $GroupId `
        -BodyParameter $body
}

function Invoke-Migration {

    $State = Load-State

    Import-Csv $MappingCsv | ForEach-Object {

        $siteUrl = $_.SiteUrl
        $calendarName = $_.CalendarName
        $groupEmail = $_.GroupEmail

        Write-Log "Migrating: $calendarName"

        $group = Get-MgGroup `
            -Filter "mail eq '$groupEmail'"

        if(-not $group)
        {
            throw "Group not found $groupEmail"
        }

        $events = Get-SPCalendarEvents `
            -SiteUrl $siteUrl `
            -CalendarName $calendarName

        foreach($event in $events)
        {
            $alreadyMigrated =
                $State.Migrations |
                Where-Object {

                    $_.SiteUrl -eq $siteUrl -and
                    $_.ItemId -eq $event.ItemId
                }

            if($alreadyMigrated)
            {
                continue
            }

            try {

                $newEvent = Add-GroupEvent `
                    -GroupId $group.Id `
                    -Event $event

                $State.Migrations += @{

                    SiteUrl      = $siteUrl
                    CalendarName = $calendarName

                    ItemId       = $event.ItemId

                    EventTitle   = $event.Title

                    GroupId      = $group.Id
                    GroupEmail   = $groupEmail

                    GroupEventId = $newEvent.Id

                    MigratedDate = Get-Date
                }

                Save-State $State

                Write-Log "Migrated item $($event.ItemId)"
            }
            catch {

                Write-Log "ERROR $($_.Exception.Message)"
            }
        }
    }

    Write-Log "Migration completed"
}

#endregion

#region Restore

function Invoke-Restore {

    $State = Load-State

    foreach($entry in $State.Migrations)
    {
        try {

            Remove-MgGroupCalendarEvent `
                -GroupId $entry.GroupId `
                -EventId $entry.GroupEventId

            Write-Log `
                "Removed $($entry.GroupEventId)"
        }
        catch {

            Write-Log `
                "Restore failure: $($_.Exception.Message)"
        }
    }

    Write-Log "Restore completed"
}

#endregion

#region Main

try {

    Connect-MigrationServices

    switch ($Mode)
    {
        "Document" {

            Invoke-Documentation
        }

        "Backup" {

            Invoke-Backup
        }

        "Migrate" {

            Invoke-Backup
            Invoke-Migration
        }

        "Restore" {

            Invoke-Restore
        }
    }
}
catch {

    Write-Error $_
}

#endregion
``