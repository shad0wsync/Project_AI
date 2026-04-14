<#
.SYNOPSIS
    Assigns Microsoft Teams Voice security baseline policies to users and groups.

.DESCRIPTION
    Applies the organization-wide Teams Voice security policies created by Set-TeamsVoiceSecurityBaseline.ps1
    to specified user groups. Supports targeting by Security Groups, Distribution Lists, or individual users.

.NOTES
    Official Documentation Reference:
    - Grant Teams Policies: https://learn.microsoft.com/en-us/microsoftteams/assign-policies-users-and-groups
    - Batch Policy Assignment: https://learn.microsoft.com/en-us/powershell/module/teams/new-csbatchpolicyassignmentoperation
    
    Author: Jay Smith
    Version: 1.0.0
    Prerequisites: Set-TeamsVoiceSecurityBaseline.ps1 must be executed first

.PARAMETER GroupIdentity
    AAD Group Identity (DisplayName, GUID, or Email). Accepts pipeline input. Mandatory.

.PARAMETER PolicyScope
    Policy assignment scope: 'Users', 'Groups', or 'Organization'. Default: 'Users'

.PARAMETER LogPath
    Output directory for audit logs. Default: C:\Logs\TeamsVoiceBaseline

.PARAMETER Credential
    Azure AD credential for Teams PowerShell authentication.

.EXAMPLE
    .\Apply-TeamsVoiceSecurityPolicy.ps1 -GroupIdentity "Sales-Department" -PolicyScope Users

.EXAMPLE
    Get-MgGroup -Filter "displayName eq 'IT-Devices'" | .\Apply-TeamsVoiceSecurityPolicy.ps1 -PolicyScope Users

#>

[CmdletBinding(
    SupportsShouldProcess = $true,
    ConfirmImpact = 'High'
)]
param(
    [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
    [ValidateNotNullOrEmpty()]
    [Alias('Group', 'SAMAccountName')]
    [string]$GroupIdentity,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Users', 'Groups', 'Organization')]
    [string]$PolicyScope = 'Users',

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$LogPath = 'C:\Logs\TeamsVoiceBaseline',

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential]$Credential = $null
)

process {
    try {
        #region Initialization
        if (-not (Test-Path -Path $LogPath)) {
            New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
        }

        $logFile = Join-Path -Path $LogPath -ChildPath "PolicyAssignment_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
        
        function Write-LogEntry {
            param(
                [Parameter(Mandatory = $true)]
                [string]$Message,
                
                [Parameter(Mandatory = $false)]
                [ValidateSet('Info', 'Warning', 'Error', 'Success')]
                [string]$Level = 'Info'
            )
            
            $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            $logEntry = "$timestamp [$Level] $Message"
            Add-Content -Path $logFile -Value $logEntry
            Write-Verbose $logEntry
        }

        Write-LogEntry "Policy assignment initiated for group: $GroupIdentity" -Level 'Info'

        #endregion

        #region Module and Connection Validation
        
        # Import required modules
        Import-Module -Name MicrosoftTeams -Force
        Import-Module -Name Microsoft.Graph.Groups -Force
        Import-Module -Name Microsoft.Graph.Users -Force
        
        # Connect to Teams service
        if ($null -eq $Credential) {
            Connect-MicrosoftTeams | Out-Null
        } else {
            Connect-MicrosoftTeams -Credential $Credential | Out-Null
        }
        
        # Connect to Microsoft Graph service
        if ($null -eq $Credential) {
            Connect-MgGraph | Out-Null
        } else {
            Connect-MgGraph -Credential $Credential | Out-Null
        }

        Write-LogEntry "Connected to Teams and Microsoft Graph services" -Level 'Success'

        #endregion

        #region Policy Assignment

        # Define baseline policies
        $policies = @{
            CallingPolicy   = 'RestrictedTeamsVoicePolicy'
            MeetingPolicy   = 'RestrictedTeamsMeetingPolicy'
            MessagingPolicy = 'RestrictedTeamsMessagingPolicy'
            AppSetupPolicy  = 'RestrictedTeamsDevicePolicy'
        }

        # Validate policies exist
        foreach ($policyType in $policies.Keys) {
            $policy = & "Get-CsTeams$policyType" -Identity $policies[$policyType] -ErrorAction SilentlyContinue
            if ($null -eq $policy) {
                throw "Policy not found: $($policies[$policyType]). Run Set-TeamsVoiceSecurityBaseline.ps1 first."
            }
        }

        Write-LogEntry "All baseline policies validated and present" -Level 'Success'

        # Get group or user identity
        $targetIdentity = $GroupIdentity
        $assignmentCount = 0

        if ($PolicyScope -eq 'Users' -or $PolicyScope -eq 'Groups') {
            # Resolve group and get members
            try {
                $group = Get-MgGroup -Filter "displayName eq '$GroupIdentity' or mail eq '$GroupIdentity'" -ErrorAction Stop | Select-Object -First 1
                
                if ($null -eq $group) {
                    $group = Get-MgGroup -Filter "id eq '$GroupIdentity'" -ErrorAction Stop
                }

                if ($null -eq $group) {
                    throw "Group not found: $GroupIdentity"
                }

                Write-LogEntry "Group resolved: $($group.DisplayName) (ID: $($group.Id))" -Level 'Info'

                # Get group members
                $members = Get-MgGroupMember -GroupId $group.Id -All | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.user' }
                Write-LogEntry "Retrieved $($members.Count) user members from group" -Level 'Info'

                # Assign policies to each user
                foreach ($member in $members) {
                    try {
                        $user = Get-MgUser -UserId $member.Id -ErrorAction Stop
                        
                        # Assign calling policy
                        Grant-CsTeamsCallingPolicy -Identity $user.Id -PolicyName $policies['CallingPolicy'] -ErrorAction Continue
                        
                        # Assign meeting policy
                        Grant-CsTeamsMeetingPolicy -Identity $user.Id -PolicyName $policies['MeetingPolicy'] -ErrorAction Continue
                        
                        # Assign messaging policy
                        Grant-CsTeamsMessagingPolicy -Identity $user.Id -PolicyName $policies['MessagingPolicy'] -ErrorAction Continue
                        
                        # Assign app setup policy
                        Grant-CsTeamsAppSetupPolicy -Identity $user.Id -PolicyName $policies['AppSetupPolicy'] -ErrorAction Continue

                        $assignmentCount++
                        Write-LogEntry "Policies assigned to user: $($user.UserPrincipalName)" -Level 'Success'

                    } catch {
                        Write-LogEntry "Failed to assign policies to user $($member.Id): $($_.Exception.Message)" -Level 'Error'
                    }
                }

            } catch {
                Write-LogEntry "Group resolution or assignment failed: $($_.Exception.Message)" -Level 'Error'
                throw
            }

        } elseif ($PolicyScope -eq 'Organization') {
            # Apply as organization-wide defaults
            if ($PSCmdlet.ShouldProcess('Organization', 'Set as default policies')) {
                try {
                    Set-CsTeamsCallingPolicy -Identity Global -PolicyName $policies['CallingPolicy'] -ErrorAction Continue
                    Set-CsTeamsMeetingPolicy -Identity Global -PolicyName $policies['MeetingPolicy'] -ErrorAction Continue
                    Set-CsTeamsMessagingPolicy -Identity Global -PolicyName $policies['MessagingPolicy'] -ErrorAction Continue
                    Set-CsTeamsAppSetupPolicy -Identity Global -PolicyName $policies['AppSetupPolicy'] -ErrorAction Continue

                    Write-LogEntry "Policies set as organization-wide defaults" -Level 'Success'
                    $assignmentCount = 1
                } catch {
                    Write-LogEntry "Failed to set organization-wide policies: $($_.Exception.Message)" -Level 'Error'
                    throw
                }
            }
        }

        Write-LogEntry "Policy assignment completed. Users/Groups updated: $assignmentCount" -Level 'Success'

        #endregion

        #region Cleanup
        Disconnect-MicrosoftTeams -Confirm:$false | Out-Null
        Disconnect-MgGraph -Confirm:$false | Out-Null
        Write-LogEntry "Disconnected from Teams and Microsoft Graph services" -Level 'Info'
        Write-Host "✓ Policy assignment complete for $assignmentCount user(s)/group(s)" -ForegroundColor Green

        #endregion

    } catch {
        Write-Error "Policy assignment failed: $($_.Exception.Message)"
        exit 1
    }
}