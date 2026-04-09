# Script: Export-TeamsUsersWithCallerId.ps1
# Description: Exports Teams users with a specific Caller ID policy name to CSV.

<#
.SYNOPSIS
Exports Teams users with a specific caller ID display name to a CSV file.

.DESCRIPTION
Connects to Microsoft Teams, retrieves users with the specified caller ID display name,
and exports the results to CSV.

.PARAMETER CallerIdName
The caller ID display name to filter by (e.g., "Anonymous", "Block").

.PARAMETER IncludeGuests
Include guest accounts in the export.

.PARAMETER ExportCsvPath
Path to the CSV file for export.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$CallerIdName,
    [switch]$IncludeGuests,
    [ValidateNotNullOrEmpty()]
    [string]$ExportCsvPath = "TeamsUsersWithCallerId_$CallerIdName.csv"
)

try {
    $module = Get-Module -ListAvailable -Name MicrosoftTeams | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $module) {
        throw "MicrosoftTeams module not found."
    }
    Import-Module $module -ErrorAction Stop
    Write-Verbose "Imported MicrosoftTeams module version $($module.Version)."
}
catch {
    Write-Error "The MicrosoftTeams module is not installed or failed to import. Install it with Install-Module MicrosoftTeams -Scope CurrentUser."
    return
}

try {
    Write-Verbose "Connecting to Microsoft Teams..."
    Connect-MicrosoftTeams -ErrorAction Stop
    Write-Verbose "Successfully connected to Microsoft Teams."
}
catch {
    Write-Error "Failed to connect to Microsoft Teams. Verify your credentials and network connectivity."
    return
}

$filter = if ($IncludeGuests) { $null } else { "AccountType -eq 'User'" }

Write-Verbose "Retrieving users with filter: $filter"
$users = Get-CsOnlineUser -ResultSize 2147483647 -Filter $filter -ErrorAction Stop |
    Where-Object { $_.CallingLineIdentity -eq $CallerIdName } |
    Select-Object DisplayName, UserPrincipalName, AccountType, EnterpriseVoiceEnabled, CallingLineIdentity

if ($users.Count -eq 0) {
    Write-Host "No users found with caller ID display name set to '$CallerIdName'."
    return
}

$exportDir = Split-Path $ExportCsvPath
if (-not (Test-Path $exportDir)) {
    Write-Error "Export directory does not exist: $exportDir"
    return
}

Write-Verbose "Exporting $($users.Count) users to $ExportCsvPath"
$users | Export-Csv -Path $ExportCsvPath -NoTypeInformation -Force
Write-Host "Exported $($users.Count) users with caller ID display name '$CallerIdName' to '$ExportCsvPath'."
