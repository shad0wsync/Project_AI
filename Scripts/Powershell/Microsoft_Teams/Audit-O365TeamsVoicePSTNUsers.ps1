<#
.SYNOPSIS
    Audits Office 365 users and highlights accounts with Microsoft Teams Voice PSTN calling capability.

.DESCRIPTION
    Connects to the Teams PowerShell module, enumerates all Teams-enabled users,
    and correlates PSTN phone number assignments, voice policies, and related Teams voice settings.
    The output marks accounts that appear to have Teams PSTN calling capability.

.PARAMETER CsvPath
    Path to export the CSV audit output.

.PARAMETER NoExport
    If specified, output is written to the console instead of a CSV file.

.PARAMETER IncludeResourceAccounts
    Include Teams resource accounts (Auto Attendants / Call Queues) in the audit.

.EXAMPLE
    .\Audit-O365TeamsVoicePSTNUsers.ps1 -CsvPath .\TeamsVoicePSTNUsers.csv

.EXAMPLE
    .\Audit-O365TeamsVoicePSTNUsers.ps1 -NoExport -Verbose
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$CsvPath = ".\O365TeamsVoicePSTNUsersAudit.csv",

    [Parameter(Mandatory = $false)]
    [switch]$NoExport,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeResourceAccounts
)

function Install-AndImport-Module {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not (Get-Module -ListAvailable -Name $Name)) {
        Write-Verbose "Installing module: $Name"
        Install-Module -Name $Name -Scope CurrentUser -Force -AllowClobber
    }

    Import-Module $Name -ErrorAction Stop
}

function Connect-TeamsSession {
    try {
        Write-Verbose "Connecting to Microsoft Teams..."
        Connect-MicrosoftTeams -ErrorAction Stop | Out-Null
    } catch {
        Write-Error "Failed to connect to Microsoft Teams. $_"
        throw
    }
}

function Get-PhoneAssignments {
    try {
        Write-Verbose "Retrieving Teams PSTN phone number assignments..."
        return Get-CsPhoneNumberAssignment -AssignedPstnTargetIdType User -ErrorAction Stop
    } catch {
        Write-Warning "Unable to retrieve phone assignments: $_"
        return @()
    }
}

function Get-AllTeamsUsers {
    Write-Verbose "Retrieving Teams users from CsOnlineUser..."

    return Get-CsOnlineUser -ResultSize 100000 |
        Select-Object 
            DisplayName,
            UserPrincipalName,
            LineURI,
            VoicePolicy,
            OnlineVoiceRoutingPolicy,
            TeamsCallingPolicy,
            TeamsMeetingPolicy,
            HostedVoiceMail
}

try {
    Install-AndImport-Module -Name MicrosoftTeams
    Connect-TeamsSession

    $phoneAssignments = Get-PhoneAssignments
    $assignmentHash = @{}

    foreach ($assignment in $phoneAssignments) {
        if (-not $IncludeResourceAccounts -and $assignment.AssignedPstnTargetId -match 'resourceaccount') {
            continue
        }

        $assignmentHash[$assignment.AssignedPstnTargetId.ToLower()] = $assignment
    }

    $teamsUsers = Get-AllTeamsUsers

    $results = @()
    foreach ($user in $teamsUsers) {
        $upn = $user.UserPrincipalName.ToLower()
        $assignedPhone = $null
        if ($assignmentHash.ContainsKey($upn)) {
            $assignedPhone = $assignmentHash[$upn]
        }

        $hasPstnNumber = $assignedPhone -ne $null
        $hasVoicePolicy = -not [string]::IsNullOrWhiteSpace($user.VoicePolicy) -or
                          -not [string]::IsNullOrWhiteSpace($user.TeamsCallingPolicy) -or
                          -not [string]::IsNullOrWhiteSpace($user.OnlineVoiceRoutingPolicy)

        $pstnCapability = if ($hasPstnNumber -or $hasVoicePolicy) { 'Yes' } else { 'No' }

        $results += [PSCustomObject]@{
            DisplayName             = $user.DisplayName
            UserPrincipalName       = $user.UserPrincipalName
            LineURI                 = $user.LineURI
            VoicePolicy             = $user.VoicePolicy
            TeamsCallingPolicy      = $user.TeamsCallingPolicy
            OnlineVoiceRoutingPolicy= $user.OnlineVoiceRoutingPolicy
            HostedVoiceMail         = $user.HostedVoiceMail
            AssignedPstnNumber      = if ($assignedPhone) { $assignedPhone.PhoneNumber } else { '' }
            AssignedPstnTargetId    = if ($assignedPhone) { $assignedPhone.AssignedPstnTargetId } else { '' }
            TeamsVoicePSTNEnabled   = $pstnCapability
            HasPstnNumber           = $hasPstnNumber
            HasVoicePolicy          = $hasVoicePolicy
        }
    }

    $highlighted = $results | Where-Object { $_.TeamsVoicePSTNEnabled -eq 'Yes' }
    $summary = [PSCustomObject]@{
        TotalUsers              = $results.Count
        PSTNEnabledAccounts     = $highlighted.Count
        PSTNEnabledPercentage   = if ($results.Count -gt 0) { [math]::Round(($highlighted.Count / $results.Count) * 100, 2) } else { 0 }
    }

    Write-Verbose "Total users audited: $($summary.TotalUsers)"
    Write-Verbose "PSTN-capable accounts found: $($summary.PSTNEnabledAccounts)"

    if ($NoExport) {
        $summary | Format-List
        $results | Sort-Object -Property TeamsVoicePSTNEnabled, DisplayName | Format-Table -AutoSize
    } else {
        try {
            Write-Verbose "Exporting audit results to CSV: $CsvPath"
            $results | Sort-Object -Property TeamsVoicePSTNEnabled, DisplayName |
                Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8 -Force

            Write-Host "Audit complete: $CsvPath" -ForegroundColor Green
            Write-Host "Total users: $($summary.TotalUsers); PSTN-capable accounts: $($summary.PSTNEnabledAccounts)" -ForegroundColor Cyan
        } catch {
            Write-Error "Failed to export CSV. $_"
        }
    }
} catch {
    Write-Error "Audit failed: $($_.Exception.Message)"
} finally {
    try {
        Disconnect-MicrosoftTeams -Confirm:$false | Out-Null
    } catch {
        # ignore disconnect failures
    }
}
