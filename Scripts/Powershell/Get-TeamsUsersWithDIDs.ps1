<#
.SYNOPSIS
    Retrieves Microsoft Teams users and their assigned DIDs (phone numbers).
.DESCRIPTION
    Connects to Microsoft Teams and exports users with direct inward dial numbers.
    It prefers Get-CsPhoneNumberAssignment and falls back to Get-CsOnlineUser when needed.
.PARAMETER CsvPath
    Path to export the results as CSV. Defaults to .\TeamsUsersWithDIDs.csv.
.PARAMETER NoExport
    If supplied, outputs results to the console instead of exporting a CSV.
.EXAMPLE
    .\Get-TeamsUsersWithDIDs.ps1
.EXAMPLE
    .\Get-TeamsUsersWithDIDs.ps1 -CsvPath .\UsersWithDIDs.csv
.EXAMPLE
    .\Get-TeamsUsersWithDIDs.ps1 -NoExport
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]
    $CsvPath = ".\TeamsUsersWithDIDs.csv",

    [Parameter(Mandatory = $false)]
    [switch]
    $NoExport
)

function Ensure-Module {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not (Get-Module -ListAvailable -Name $Name)) {
        Write-Host "Installing PowerShell module '$Name'..." -ForegroundColor Yellow
        Install-Module -Name $Name -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module $Name -ErrorAction Stop
}

Write-Host "Preparing to connect to Microsoft Teams..." -ForegroundColor Cyan
Ensure-Module -Name MicrosoftTeams

if (-not (Get-Module -Name MicrosoftTeams)) {
    Write-Host "Failed to load MicrosoftTeams module." -ForegroundColor Red
    return
}

Write-Host "Signing in to Microsoft Teams..." -ForegroundColor Cyan
Connect-MicrosoftTeams -ErrorAction Stop

$results = @()

try {
    Write-Host "Fetching phone number assignments with Get-CsPhoneNumberAssignment..." -ForegroundColor Cyan
    $assignments = Get-CsPhoneNumberAssignment -ResultSize Unlimited -ErrorAction Stop
    $results = $assignments | Select-Object @{Name = 'DisplayName'; Expression = { $_.Identity -replace '^.*?/(.*)$', '$1' } },
    @{Name = 'UserPrincipalName'; Expression = { $_.Identity -replace '^.*?/(.*)$', '$1' } },
    @{Name = 'DID'; Expression = { $_.AssignedTelephoneNumber } }
} catch {
    Write-Host "Get-CsPhoneNumberAssignment is unavailable or returned an error. Falling back to Get-CsOnlineUser..." -ForegroundColor Yellow
    try {
        $onlineUsers = Get-CsOnlineUser -ResultSize Unlimited -ErrorAction Stop
        $results = $onlineUsers | Select-Object DisplayName, UserPrincipalName,
        @{Name = 'DID'; Expression = { if ($_.LineURI) { $_.LineURI -replace '^tel:' , '' } else { $null } } }
    } catch {
        Write-Host "Failed to retrieve Teams voice assignments. Ensure you have the required permissions and that Teams PowerShell is available." -ForegroundColor Red
        throw
    }
}

if ($NoExport) {
    $results | Format-Table -AutoSize
} else {
    Write-Host "Exporting results to $CsvPath..." -ForegroundColor Cyan
    $results | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "Export complete." -ForegroundColor Green
}
