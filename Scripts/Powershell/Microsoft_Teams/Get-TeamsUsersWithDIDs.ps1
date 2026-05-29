<#
.SYNOPSIS
    Retrieves Microsoft Teams users and their assigned DIDs. 

.DESCRIPTION
    Uses Get-CsPhoneNumberAssignment as the primary source of truth.
    Falls back to Get-CsOnlineUser if needed.
    Outputs enriched user data with DisplayName, UPN, DID, and CallerIdPolicy.

.PARAMETER CsvPath
    Path to export CSV.

.PARAMETER NoExport
    Output to console only.

.PARAMETER IncludeResourceAccounts
    Include resource accounts (Auto Attendants / Call Queues).

.EXAMPLE
    .\Get-TeamsUsersWithDIDs.ps1 -Verbose
#>

[CmdletBinding()]
param(
    [string]$CsvPath = ".\TeamsUsersWithDIDs.csv",
    [switch]$NoExport,
    [switch]$IncludeResourceAccounts
)

$script:CallerIdPolicySupportChecked = $false
$script:CallerIdPolicySupported = $false

#------------------------------------------------------------
# MODULE CHECK
#------------------------------------------------------------
function Install-AndImport-Module {
    param([string]$Name)

    if (-not (Get-Module -ListAvailable -Name $Name)) {
        Write-Verbose "Installing module: $Name"
        Install-Module -Name $Name -Scope CurrentUser -Force -AllowClobber
    }

    Import-Module $Name -ErrorAction Stop
}

#------------------------------------------------------------
# CONNECT TO TEAMS
#------------------------------------------------------------
function Connect-TeamsSession {
    try {
        Write-Verbose "Connecting to Microsoft Teams..."
        Connect-MicrosoftTeams -ErrorAction Stop
    } catch {
        Write-Error "Failed to connect to Microsoft Teams. $_"
        throw
    }
}

#------------------------------------------------------------
# GET PHONE NUMBER ASSIGNMENTS (PRIMARY)
#------------------------------------------------------------
function Get-PhoneAssignments {
    try {
        Write-Verbose "Retrieving phone number assignments..."
        
        return Get-CsPhoneNumberAssignment -AssignedPstnTargetIdType User -ErrorAction Stop
    } catch {
        Write-Warning "Primary method failed. Falling back to Get-CsOnlineUser."
        return $null
    }
}

#------------------------------------------------------------
# FALLBACK METHOD
#------------------------------------------------------------
function Get-FallbackUsers {
    Write-Verbose "Using fallback method (Get-CsOnlineUser)..."

    return Get-CsOnlineUser -ResultSize 100000 |
    Where-Object { $_.LineURI } |
    ForEach-Object {
        $userPrincipalName = $_.UserPrincipalName

        [PSCustomObject]@{
            DisplayName       = $_.DisplayName
            UserPrincipalName = $userPrincipalName
            DID               = ($_.LineURI -replace '^tel:', '')
            CallerIdPolicy    = Get-UserCallerIdPolicy -UserPrincipalName $userPrincipalName
        }
    }
}

function Get-UserCallerIdPolicy {
    param(
        [Parameter(Mandatory)]
        [string]$UserPrincipalName
    )

    if (-not $script:CallerIdPolicySupportChecked) {
        try {
            $testUser = Get-CsOnlineUser -Identity $UserPrincipalName -Properties CallerIdPolicy -ErrorAction Stop
            $script:CallerIdPolicySupported = $true
            $script:CallerIdPolicySupportChecked = $true
            return $testUser.CallerIdPolicy
        } catch {
            if ($_.Exception.Message -match 'Unrecognized properties' -or $_.Exception.Message -match 'calleridpolicy') {
                Write-Verbose "CallerIdPolicy is not supported in this Teams module version. Returning null."
                $script:CallerIdPolicySupported = $false
                $script:CallerIdPolicySupportChecked = $true
                return $null
            }
            throw
        }
    }

    if (-not $script:CallerIdPolicySupported) {
        return $null
    }

    try {
        $user = Get-CsOnlineUser -Identity $UserPrincipalName -Properties CallerIdPolicy -ErrorAction Stop
        return $user.CallerIdPolicy
    } catch {
        if ($_.Exception.Message -match 'Unrecognized properties' -or $_.Exception.Message -match 'calleridpolicy') {
            $script:CallerIdPolicySupported = $false
            return $null
        }
        throw
    }
}

#------------------------------------------------------------
# MAIN EXECUTION
#------------------------------------------------------------
Install-AndImport-Module -Name MicrosoftTeams
Connect-TeamsSession

$results = @()

$assignments = Get-PhoneAssignments

if ($assignments) {

    Write-Verbose "Joining assignment data with user metadata..."

    $users = Get-CsOnlineUser -ResultSize 100000 |
    Select-Object UserPrincipalName, DisplayName

    $userHash = @{}
    foreach ($u in $users) {
        $userHash[$u.UserPrincipalName.ToLower()] = $u.DisplayName
    }

    $callerIdPolicyCache = @{}

    foreach ($a in $assignments) {

        if (-not $IncludeResourceAccounts -and $a.AssignedPstnTargetId -match "resourceaccount") {
            continue
        }

        $upn = $a.AssignedPstnTargetId.ToLower()

        $displayName = if ($userHash.ContainsKey($upn)) { $userHash[$upn] } else { "Unknown" }

        if (-not $callerIdPolicyCache.ContainsKey($upn)) {
            $callerIdPolicyCache[$upn] = Get-UserCallerIdPolicy -UserPrincipalName $a.AssignedPstnTargetId
        }

        $results += [PSCustomObject]@{
            DisplayName       = $displayName
            UserPrincipalName = $a.AssignedPstnTargetId
            DID               = $a.PhoneNumber
            CallerIdPolicy    = $callerIdPolicyCache[$upn]
        }
    }

} else {
    $results = Get-FallbackUsers
}

#------------------------------------------------------------
# OUTPUT
#------------------------------------------------------------
if ($NoExport) {
    $results | Format-Table -AutoSize
} else {
    try {
        Write-Verbose "Exporting to CSV: $CsvPath"

        $results |
        Sort-Object DisplayName |
        Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8 -Force

        Write-Host "Export complete: $CsvPath" -ForegroundColor Green
    } catch {
        Write-Error "Failed to export CSV. $_"
    }
}

#------------------------------------------------------------
# CLEANUP
#------------------------------------------------------------
Disconnect-MicrosoftTeams