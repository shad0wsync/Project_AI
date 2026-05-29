#Requires -Modules ActiveDirectory

<#
.SYNOPSIS
    Finds Active Directory user and computer accounts that have not signed in for 30 days or more.

.DESCRIPTION
    Queries Active Directory for user and computer accounts and exports stale account details to timestamped CSV and JSON files.
    Export files are saved to: c:\temp\Get-ADInactiveAccounts\Get-ADInactiveAccounts[yyyyMMdd-HHmmss].[filetype]

.PARAMETER DaysInactive
    Number of days since the last logon to consider an account inactive. Default is 30.

.PARAMETER IncludeDisabled
    Include disabled user and computer accounts in the report. Default is $true.

.PARAMETER ExportRoot
    Root export directory. Default is c:\temp\Get-ADInactiveAccounts.

.EXAMPLE
    .\Get-ADInactiveAccounts.ps1
    Runs the report with the default 30-day threshold and exports CSV and JSON files.

.EXAMPLE
    .\Get-ADInactiveAccounts.ps1 -DaysInactive 60 -IncludeDisabled:$false
    Reports accounts inactive for 60 days and excludes disabled accounts.

.NOTES
    Author: Jay Smith
    Requires the ActiveDirectory PowerShell module and domain-connectivity privileges.
#>

param(
    [Parameter(Mandatory = $false)]
    [int]$DaysInactive = 30,

    [Parameter(Mandatory = $false)]
    [bool]$IncludeDisabled = $true,

    [Parameter(Mandatory = $false)]
    [string]$ExportRoot = 'c:\temp'
)

$ScriptName = 'Get-ADInactiveAccounts'
$OutputFolder = Join-Path -Path $ExportRoot -ChildPath $ScriptName
$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$CsvFile      = "$ScriptName$Timestamp.csv"
$JsonFile     = "$ScriptName$Timestamp.json"
$CsvPath      = Join-Path -Path $OutputFolder -ChildPath $CsvFile
$JsonPath     = Join-Path -Path $OutputFolder -ChildPath $JsonFile
$CutoffDate   = (Get-Date).AddDays(-$DaysInactive)

function Write-Header {
    Write-Host "[INFO] $($MyInvocation.MyCommand.Name) - $([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Cyan
}

function Import-ActiveDirectoryModule {
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        Write-Error 'The ActiveDirectory module is not installed or available on this system. Install RSAT or enable the feature and rerun the script.'
        exit 1
    }

    Import-Module ActiveDirectory -ErrorAction Stop
}

function New-ReportItem {
    param(
        [Parameter(Mandatory = $true)] [Microsoft.ActiveDirectory.Management.ADObject]$Object,
        [Parameter(Mandatory = $true)] [string]$ObjectType,
        [Parameter(Mandatory = $true)] [DateTime]$Cutoff
    )

    $lastLogonDate = $Object.LastLogonDate
    $lastLogonText = if ($lastLogonDate) { $lastLogonDate.ToString('yyyy-MM-dd HH:mm:ss') } else { 'Never' }
    $inactiveReason = if (-not $lastLogonDate) { 'Never signed in' } elseif ($lastLogonDate -lt $Cutoff) { 'Last sign-in older than threshold' } else { 'Within threshold' }

    [PSCustomObject]@{
        ObjectType         = $ObjectType
        Name               = $Object.Name
        SamAccountName     = $Object.SamAccountName
        DistinguishedName  = $Object.DistinguishedName
        Enabled            = $Object.Enabled
        LastLogonDate      = $lastLogonText
        LastLogonTimestamp = if ($lastLogonDate) { $lastLogonDate.ToUniversalTime().ToString('o') } else { '' }
        InactiveThreshold  = $Cutoff.ToString('yyyy-MM-dd')
        InactiveReason     = $inactiveReason
        WhenCreated        = if ($Object.whenCreated) { $Object.whenCreated.ToString('yyyy-MM-dd') } else { '' }
        WhenChanged        = if ($Object.whenChanged) { $Object.whenChanged.ToString('yyyy-MM-dd') } else { '' }
        AdditionalInfo     = if ($ObjectType -eq 'Computer') { $Object.OperatingSystem } else { $Object.UserPrincipalName }
    }
}

Write-Header
Import-ActiveDirectoryModule

if (-not (Test-Path -Path $OutputFolder)) {
    New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
}

Write-Host "Querying Active Directory for accounts inactive since $($CutoffDate.ToString('yyyy-MM-dd'))..." -ForegroundColor Yellow

$filteredUserProperties = @('Name','SamAccountName','UserPrincipalName','Enabled','LastLogonDate','DistinguishedName','whenCreated','whenChanged')
$filteredComputerProperties = @('Name','SamAccountName','Enabled','LastLogonDate','DistinguishedName','OperatingSystem','OperatingSystemVersion','whenCreated','whenChanged')

$users = Get-ADUser -Filter * -Properties $filteredUserProperties
$computers = Get-ADComputer -Filter * -Properties $filteredComputerProperties

$inactiveUsers = $users | Where-Object {
    $include = $true
    if (-not $IncludeDisabled) { $include = $include -and $_.Enabled }
    $lastLogon = $_.LastLogonDate
    $include -and ( -not $lastLogon -or $lastLogon -lt $CutoffDate )
} | ForEach-Object { New-ReportItem -Object $_ -ObjectType 'User' -Cutoff $CutoffDate }

$inactiveComputers = $computers | Where-Object {
    $include = $true
    if (-not $IncludeDisabled) { $include = $include -and $_.Enabled }
    $lastLogon = $_.LastLogonDate
    $include -and ( -not $lastLogon -or $lastLogon -lt $CutoffDate )
} | ForEach-Object { New-ReportItem -Object $_ -ObjectType 'Computer' -Cutoff $CutoffDate }

$reportRows = $inactiveUsers + $inactiveComputers

$reportMetadata = [PSCustomObject]@{
    GeneratedDate   = (Get-Date).ToString('o')
    ExportFolder    = $OutputFolder
    DaysInactive    = $DaysInactive
    CutoffDate      = $CutoffDate.ToString('yyyy-MM-dd')
    IncludeDisabled = $IncludeDisabled
    UserCount       = $inactiveUsers.Count
    ComputerCount   = $inactiveComputers.Count
    TotalCount      = $reportRows.Count
    FileNameCsv     = $CsvFile
    FileNameJson    = $JsonFile
}

$reportRows | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8 -Force
$reportMetadata | Add-Member -NotePropertyName Results -NotePropertyValue $reportRows -Force
$reportMetadata | ConvertTo-Json -Depth 5 | Set-Content -Path $JsonPath -Encoding UTF8

Write-Host "Export complete." -ForegroundColor Green
Write-Host "CSV:  $CsvPath" -ForegroundColor Cyan
Write-Host "JSON: $JsonPath" -ForegroundColor Cyan
Write-Host "Inactive user accounts: $($inactiveUsers.Count)" -ForegroundColor Cyan
Write-Host "Inactive computer accounts: $($inactiveComputers.Count)" -ForegroundColor Cyan

if ($reportRows.Count -eq 0) {
    Write-Host 'No inactive accounts were found using the current threshold and filter settings.' -ForegroundColor Yellow
}
else {
    Write-Host 'Review the exported report files for the full stale account details.' -ForegroundColor Green
}
