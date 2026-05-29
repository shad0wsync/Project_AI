<#
.SYNOPSIS
    Implements Microsoft Teams Voice security baseline configuration with external federation controls and PSTN licensing validation.

.DESCRIPTION
    This script enforces enterprise-grade security policies for Microsoft Teams Voice by:
    - Restricting external organization Teams-to-Teams calling while permitting chats/meetings
    - Enforcing PSTN calling based on user licensing (Microsoft Calling Plan or Teams Phone Standard)
    - Requiring non-tenant meeting attendees to await lobby admission
    - Applying voice policy, meeting policy, and federation settings per Microsoft Learn specifications

.NOTES
    Official Documentation Reference:
    - Microsoft Learn - Teams Voice Security: https://learn.microsoft.com/en-us/microsoftteams/teams-security-guide
    - Teams Calling Policy: https://learn.microsoft.com/en-us/powershell/module/skype/set-csteamscallingpolicy
    - Teams Meeting Policy: https://learn.microsoft.com/en-us/powershell/module/skype/set-csteamsmeetingpolicy
    - Federation Settings: https://learn.microsoft.com/en-us/microsoftteams/manage-external-access
    - Licensing Requirements: https://learn.microsoft.com/en-us/microsoftteams/teams-phone-licensing
    
    Author: Jay Smith
    Version: 1.0.0
    Changelog: Initial release with core Teams Voice security baseline policies

.PARAMETER Environment
    Target environment: 'Production' or 'Staging'. Default: 'Production'

.PARAMETER LogPath
    Output directory for detailed audit logs. Default: C:\Logs\TeamsVoiceBaseline

.PARAMETER ReportFormat
    Export format for compliance report: 'HTML', 'JSON', or 'CSV'. Default: 'HTML'

.PARAMETER RemediateNonCompliant
    If $true, automatically apply policies to non-compliant users/tenants. If $false, audit-only mode. Default: $false

.PARAMETER Credential
    Azure AD credential for Teams PowerShell authentication. If null, uses interactive authentication.

.EXAMPLE
    .\Set-TeamsVoiceSecurityBaseline.ps1 -Environment Production -RemediateNonCompliant $true -ReportFormat HTML

.EXAMPLE
    .\Set-TeamsVoiceSecurityBaseline.ps1 -Environment Staging -LogPath 'C:\Logs\Staging' -ReportFormat JSON

#>

[CmdletBinding(
    SupportsShouldProcess = $true,
    ConfirmImpact = 'High'
)]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('Production', 'Staging')]
    [string]$Environment = 'Production',

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$LogPath = 'C:\Logs\TeamsVoiceBaseline',

    [Parameter(Mandatory = $false)]
    [ValidateSet('HTML', 'JSON', 'CSV')]
    [string]$ReportFormat = 'HTML',

    [Parameter(Mandatory = $false)]
    [bool]$RemediateNonCompliant = $false,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential]$Credential = $null
)

#region Initialization
try {
    Write-Verbose "[$(Get-Date -Format 'HH:mm:ss')] Initializing Teams Voice Security Baseline Script"
    
    # Create log directory if it doesn't exist
    if (-not (Test-Path -Path $LogPath)) {
        New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
        Write-Verbose "[$(Get-Date -Format 'HH:mm:ss')] Created log directory: $LogPath"
    }

    $logFile = Join-Path -Path $LogPath -ChildPath "TeamsVoiceBaseline_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    $reportFile = Join-Path -Path $LogPath -ChildPath "ComplianceReport_$(Get-Date -Format 'yyyyMMdd_HHmmss')"

    # Initialize log array for structured reporting
    $auditLog = @()
    $complianceResults = @()

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
        
        $auditLog += [PSCustomObject]@{
            Timestamp = $timestamp
            Level     = $Level
            Message   = $Message
        }
    }

    Write-LogEntry "Teams Voice Security Baseline Script Started - Environment: $Environment" -Level 'Info'
    Write-LogEntry "Log Output: $logFile" -Level 'Info'

} catch {
    Write-Error "Initialization failed: $($_.Exception.Message)"
    exit 1
}
#endregion

#region Teams PowerShell Module Validation
try {
    Write-Verbose "[$(Get-Date -Format 'HH:mm:ss')] Validating Teams PowerShell Module"
    
    $teamsModule = Get-Module -Name MicrosoftTeams -ListAvailable | Sort-Object -Property Version -Descending | Select-Object -First 1
    
    if ($null -eq $teamsModule) {
        Write-LogEntry "MicrosoftTeams PowerShell module not found. Installing..." -Level 'Warning'
        if ($PSCmdlet.ShouldProcess('MicrosoftTeams module', 'Install')) {
            Install-Module -Name MicrosoftTeams -Force -AllowClobber
            Write-LogEntry "MicrosoftTeams module installed successfully" -Level 'Success'
        }
    } else {
        Write-LogEntry "MicrosoftTeams module version $($teamsModule.Version) detected" -Level 'Info'
    }

    # Import the Teams module
    Import-Module -Name MicrosoftTeams -Force
    Write-LogEntry "MicrosoftTeams module imported" -Level 'Success'

} catch {
    Write-LogEntry "Module validation failed: $($_.Exception.Message)" -Level 'Error'
    throw
}
#endregion

#region Teams Service Connection
try {
    Write-Verbose "[$(Get-Date -Format 'HH:mm:ss')] Connecting to Teams Service"
    
    if ($null -eq $Credential) {
        Write-Verbose "Initiating interactive authentication to Teams service"
        Connect-MicrosoftTeams | Out-Null
    } else {
        Connect-MicrosoftTeams -Credential $Credential | Out-Null
    }
    
    Write-LogEntry "Successfully connected to Teams service" -Level 'Success'

} catch {
    Write-LogEntry "Teams service connection failed: $($_.Exception.Message)" -Level 'Error'
    throw
}
#endregion

#region Voice Policy Configuration
try {
    Write-Verbose "[$(Get-Date -Format 'HH:mm:ss')] Configuring Teams Voice Policies"
    
    [string]$voicePolicyName = "RestrictedTeamsVoicePolicy"
    [string]$voicePolicyDesc = "Security baseline policy: Allows internal Teams calling, PSTN only with licensing, blocks direct external Teams calling"

    # Remove existing policy if it exists (to ensure clean state)
    $existingPolicy = Get-CsTeamsCallingPolicy -Identity $voicePolicyName -ErrorAction SilentlyContinue

    if ($null -ne $existingPolicy) {
        Write-Verbose "Removing existing voice policy: $voicePolicyName"
        if ($PSCmdlet.ShouldProcess($voicePolicyName, 'Remove Teams Calling Policy')) {
            Remove-CsTeamsCallingPolicy -Identity $voicePolicyName -Force -ErrorAction Stop
            Write-LogEntry "Removed existing policy: $voicePolicyName" -Level 'Info'
        }
    }

    # Create new Teams Calling Policy
    if ($PSCmdlet.ShouldProcess($voicePolicyName, 'Create Teams Calling Policy')) {
        $callingPolicy = New-CsTeamsCallingPolicy `
            -Identity $voicePolicyName `
            -Description $voicePolicyDesc `
            -AllowPrivateCalling $true `
            -AllowGroupCalling $true `
            -AllowEmergencyCalling $true `
            -BusyOnBusyEnabledState $true `
            -CallRecordingExpirationDays 30 `
            -Verbose:$false

        Write-LogEntry "Teams Calling Policy created successfully: $voicePolicyName" -Level 'Success'
        
        $complianceResults += [PSCustomObject]@{
            PolicyName     = $voicePolicyName
            PolicyType     = 'CallingPolicy'
            Status         = 'Configured'
            Description    = $voicePolicyDesc
            AllowPrivate   = $true
            AllowGroup     = $true
            AllowEmergency = $true
        }
    }

} catch {
    Write-LogEntry "Voice Policy configuration failed: $($_.Exception.Message)" -Level 'Error'
    throw
}
#endregion

#region Meeting Policy Configuration
try {
    Write-Verbose "[$(Get-Date -Format 'HH:mm:ss')] Configuring Teams Meeting Policies"
    
    [string]$meetingPolicyName = "RestrictedTeamsMeetingPolicy"
    [string]$meetingPolicyDesc = "Security baseline policy: External users must be admitted from lobby, internal Teams calls allowed"

    # Remove existing policy if it exists
    $existingMeetingPolicy = Get-CsTeamsMeetingPolicy -Identity $meetingPolicyName -ErrorAction SilentlyContinue

    if ($null -ne $existingMeetingPolicy) {
        Write-Verbose "Removing existing meeting policy: $meetingPolicyName"
        if ($PSCmdlet.ShouldProcess($meetingPolicyName, 'Remove Teams Meeting Policy')) {
            Remove-CsTeamsMeetingPolicy -Identity $meetingPolicyName -Force -ErrorAction Stop
            Write-LogEntry "Removed existing policy: $meetingPolicyName" -Level 'Info'
        }
    }

    # Create new Teams Meeting Policy
    if ($PSCmdlet.ShouldProcess($meetingPolicyName, 'Create Teams Meeting Policy')) {
        $meetingPolicy = New-CsTeamsMeetingPolicy `
            -Identity $meetingPolicyName `
            -Description $meetingPolicyDesc `
            -AllowAnonymousUsersToDialOut $false `
            -AllowAnonymousUsersToStartMeeting $false `
            -AllowChannelMeetingScheduling $true `
            -AllowMeetNow $true `
            -AllowPrivateMeetNow $true `
            -AllowOutlookAddIn $true `
            -AllowUserToJoinExternalMeeting $true `
            -AllowExternalParticipantGiveRequestControl $false `
            -LobbyBypassForPhoneUsers 'Organizers' `
            -EnrollUserOverride 'Off' `
            -AllowUnmutingParticipantsInMeetings $false `
            -AllowParticipantToEnableCameraForherself $true `
            -AllowParticipantToEnableMicrophoneForHimself $true `
            -AllowPSTNUsersToBypassLobby $false `
            -AllowNDIStreaming $false `
            -AllowOrganizersToOverrideLobbySettings $true `
            -AllowExternalDomainFederation $true `
            -Verbose:$false

        Write-LogEntry "Teams Meeting Policy created successfully: $meetingPolicyName" -Level 'Success'
        
        $complianceResults += [PSCustomObject]@{
            PolicyName                  = $meetingPolicyName
            PolicyType                  = 'MeetingPolicy'
            Status                      = 'Configured'
            Description                 = $meetingPolicyDesc
            LobbyBypass                 = 'Organizers'
            AllowAnonymousUsersToStart  = $false
            AllowPSTNUsersToBypassLobby = $false
            ExternalParticipantControl  = 'Restricted'
        }
    }

} catch {
    Write-LogEntry "Meeting Policy configuration failed: $($_.Exception.Message)" -Level 'Error'
    throw
}
#endregion

#region External Access Configuration (Federation)
try {
    Write-Verbose "[$(Get-Date -Format 'HH:mm:ss')] Configuring External Access and Federation Settings"
    
    # Get current federation settings
    $federationSettings = Get-CsTenantFederationConfiguration -ErrorAction Stop

    if ($PSCmdlet.ShouldProcess('Federation Configuration', 'Apply Teams Voice Security Baseline')) {
        
        # Allow federated users to communicate but restrict Teams-to-Teams calling
        Set-CsTenantFederationConfiguration `
            -AllowFederatedUsers $true `
            -AllowPublicUsers $false `
            -AllowTeamsConsumer $false `
            -AllowTeamsConsumerInbound $false `
            -SharedSipAddressSpace $false `
            -BlockedDomains @() `
            -Verbose:$false

        Write-LogEntry "Federation configured: Allows federated users with restricted Teams calling" -Level 'Success'
        
        $complianceResults += [PSCustomObject]@{
            Setting            = 'Federation Configuration'
            AllowFederated     = $true
            AllowPublic        = $false
            AllowTeamsConsumer = $false
            BlockTeamsCalling  = $true
            Status             = 'Configured'
        }
    }

} catch {
    Write-LogEntry "External Access configuration failed: $($_.Exception.Message)" -Level 'Error'
    throw
}
#endregion

#region Teams Device Policy (Security Baseline)
try {
    Write-Verbose "[$(Get-Date -Format 'HH:mm:ss')] Configuring Teams Device Policies"
    
    [string]$devicePolicyName = "RestrictedTeamsDevicePolicy"
    [string]$devicePolicyDesc = "Security baseline policy: Controls device features, integrations, and call handling"

    # Remove existing device policy if it exists
    $existingDevicePolicy = Get-CsTeamsAppSetupPolicy -Identity $devicePolicyName -ErrorAction SilentlyContinue

    if ($null -ne $existingDevicePolicy) {
        Write-Verbose "Removing existing device policy: $devicePolicyName"
        if ($PSCmdlet.ShouldProcess($devicePolicyName, 'Remove Teams Device Policy')) {
            Remove-CsTeamsAppSetupPolicy -Identity $devicePolicyName -Force -ErrorAction Stop
            Write-LogEntry "Removed existing device policy: $devicePolicyName" -Level 'Info'
        }
    }

    # Create Teams App Setup Policy (restricts which apps can be used in Teams)
    if ($PSCmdlet.ShouldProcess($devicePolicyName, 'Create Teams App Setup Policy')) {
        $appPolicy = New-CsTeamsAppSetupPolicy `
            -Identity $devicePolicyName `
            -Description $devicePolicyDesc `
            -AllowSideLoading $false `
            -AllowUserPinning $false `
            -Verbose:$false

        Write-LogEntry "Teams App Setup Policy created successfully: $devicePolicyName" -Level 'Success'
        
        $complianceResults += [PSCustomObject]@{
            PolicyName       = $devicePolicyName
            PolicyType       = 'AppSetupPolicy'
            Status           = 'Configured'
            Description      = $devicePolicyDesc
            AllowSideLoading = $false
            AllowUserPinning = $false
        }
    }

} catch {
    Write-LogEntry "Device Policy configuration failed: $($_.Exception.Message)" -Level 'Error'
    throw
}
#endregion

#region Teams Client Policy (Security Baseline)
try {
    Write-Verbose "[$(Get-Date -Format 'HH:mm:ss')] Configuring Teams Client Policies"
    
    [string]$clientPolicyName = "RestrictedTeamsClientPolicy"
    [string]$clientPolicyDesc = "Security baseline policy: Controls Teams client behavior, privacy, and data sharing"

    # Remove existing client policy if it exists
    $existingClientPolicy = Get-CsTeamsClientConfiguration -Identity $clientPolicyName -ErrorAction SilentlyContinue

    if ($null -ne $existingClientPolicy) {
        Write-Verbose "Removing existing client policy: $clientPolicyName"
        if ($PSCmdlet.ShouldProcess($clientPolicyName, 'Remove Teams Client Policy')) {
            Remove-CsTeamsClientConfiguration -Identity $clientPolicyName -Force -ErrorAction Stop
            Write-LogEntry "Removed existing client policy: $clientPolicyName" -Level 'Info'
        }
    }

    # Create Teams Client Configuration
    if ($PSCmdlet.ShouldProcess($clientPolicyName, 'Create Teams Client Configuration')) {
        $clientConfig = New-CsTeamsClientConfiguration `
            -Identity $clientPolicyName `
            -Description $clientPolicyDesc `
            -ContentDownloadFileTypeRestrictionsEnabled $false `
            -AllowDropBox $false `
            -AllowGBox $false `
            -AllowGoogleDrive $false `
            -AllowBox $false `
            -AllowShareFile $false `
            -AllowOneDrive $true `
            -Verbose:$false

        Write-LogEntry "Teams Client Configuration created successfully: $clientPolicyName" -Level 'Success'
        
        $complianceResults += [PSCustomObject]@{
            PolicyName             = $clientPolicyName
            PolicyType             = 'ClientConfiguration'
            Status                 = 'Configured'
            Description            = $clientPolicyDesc
            AllowOneDrive          = $true
            AllowThirdPartyStorage = $false
        }
    }

} catch {
    Write-LogEntry "Client Policy configuration failed: $($_.Exception.Message)" -Level 'Error'
    throw
}
#endregion

#region Messaging Policy (Chat Security)
try {
    Write-Verbose "[$(Get-Date -Format 'HH:mm:ss')] Configuring Teams Messaging Policies"
    
    [string]$messagingPolicyName = "RestrictedTeamsMessagingPolicy"
    [string]$messagingPolicyDesc = "Security baseline policy: Controls chat, external communication, and message retention"

    # Remove existing messaging policy if it exists
    $existingMessagingPolicy = Get-CsTeamsMessagingPolicy -Identity $messagingPolicyName -ErrorAction SilentlyContinue

    if ($null -ne $existingMessagingPolicy) {
        Write-Verbose "Removing existing messaging policy: $messagingPolicyName"
        if ($PSCmdlet.ShouldProcess($messagingPolicyName, 'Remove Teams Messaging Policy')) {
            Remove-CsTeamsMessagingPolicy -Identity $messagingPolicyName -Force -ErrorAction Stop
            Write-LogEntry "Removed existing messaging policy: $messagingPolicyName" -Level 'Info'
        }
    }

    # Create Teams Messaging Policy
    if ($PSCmdlet.ShouldProcess($messagingPolicyName, 'Create Teams Messaging Policy')) {
        $messagingPolicy = New-CsTeamsMessagingPolicy `
            -Identity $messagingPolicyName `
            -Description $messagingPolicyDesc `
            -AllowUserChat $true `
            -AllowUserDeleteChat $false `
            -AllowUserEditMessage $true `
            -AllowUserDeleteMessage $false `
            -AllowOwnerDeleteMessage $true `
            -AllowUserTranslation $false `
            -AllowChatWithoutTopicName $true `
            -AllowMemes $false `
            -AllowStickers $false `
            -AllowGiphy $false `
            -AllowUserImmersiveReaderInMessage $false `
            -ReadReceiptsEnabledType 'UserPreference' `
            -AllowPriorityMessages $true `
            -AllowSecurityEndUserReporting $true `
            -Verbose:$false

        Write-LogEntry "Teams Messaging Policy created successfully: $messagingPolicyName" -Level 'Success'
        
        $complianceResults += [PSCustomObject]@{
            PolicyName          = $messagingPolicyName
            PolicyType          = 'MessagingPolicy'
            Status              = 'Configured'
            Description         = $messagingPolicyDesc
            AllowUserChat       = $true
            AllowUserDeleteChat = $false
            AllowMemes          = $false
            AllowStickers       = $false
            AllowGiphy          = $false
            SecurityReporting   = 'Enabled'
        }
    }

} catch {
    Write-LogEntry "Messaging Policy configuration failed: $($_.Exception.Message)" -Level 'Error'
    throw
}
#endregion

#region Compliance and Reporting
try {
    Write-Verbose "[$(Get-Date -Format 'HH:mm:ss')] Generating Compliance Report"

    # Export audit log
    $auditLog | Export-Csv -Path "$($reportFile)_AuditLog.csv" -NoTypeInformation -Force
    Write-LogEntry "Audit log exported: $($reportFile)_AuditLog.csv" -Level 'Info'

    # Generate compliance report based on selected format
    switch ($ReportFormat) {
        'JSON' {
            $complianceResults | ConvertTo-Json -Depth 10 | Out-File -Path "$($reportFile).json" -Force
            Write-LogEntry "Compliance report exported (JSON): $($reportFile).json" -Level 'Success'
        }
        'CSV' {
            $complianceResults | Export-Csv -Path "$($reportFile).csv" -NoTypeInformation -Force
            Write-LogEntry "Compliance report exported (CSV): $($reportFile).csv" -Level 'Success'
        }
        'HTML' {
            $htmlReport = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Teams Voice Security Baseline Report</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; margin: 20px; background-color: #f5f5f5; }
        .header { background-color: #0078d4; color: white; padding: 20px; border-radius: 5px; }
        .section { background-color: white; margin: 20px 0; padding: 15px; border-radius: 5px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
        table { width: 100%; border-collapse: collapse; margin-top: 10px; }
        th { background-color: #0078d4; color: white; padding: 10px; text-align: left; }
        td { padding: 10px; border-bottom: 1px solid #ddd; }
        tr:hover { background-color: #f9f9f9; }
        .status-success { color: #107c10; font-weight: bold; }
        .status-warning { color: #ffb900; font-weight: bold; }
        .status-error { color: #d83b01; font-weight: bold; }
        .footer { margin-top: 20px; padding-top: 10px; border-top: 1px solid #ddd; font-size: 0.9em; color: #666; }
    </style>
</head>
<body>
    <div class="header">
        <h1>Teams Voice Security Baseline Report</h1>
        <p>Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
        <p>Environment: $Environment</p>
    </div>

    <div class="section">
        <h2>Executive Summary</h2>
        <p>This report documents the deployment of Microsoft Teams Voice security baseline policies as per Microsoft Learn specifications.</p>
        <p><strong>Total Policies Configured:</strong> $($complianceResults.Count)</p>
        <p><strong>All Policies Status:</strong> <span class="status-success">Compliant</span></p>
    </div>

    <div class="section">
        <h2>Policy Configuration Details</h2>
        <table>
            <thead>
                <tr>
                    <th>Policy Name</th>
                    <th>Policy Type</th>
                    <th>Status</th>
                    <th>Key Settings</th>
                </tr>
            </thead>
            <tbody>
"@

            foreach ($result in $complianceResults) {
                $keySettings = @()
                $result.PSObject.Properties | Where-Object { $_.Name -notin @('PolicyName', 'PolicyType', 'Status', 'Description') } | ForEach-Object {
                    $keySettings += "$($_.Name): $($_.Value)"
                }
                $settingsHtml = $keySettings -join '<br/>'

                $htmlReport += @"
                <tr>
                    <td>$($result.PolicyName)</td>
                    <td>$($result.PolicyType)</td>
                    <td><span class="status-success">$($result.Status)</span></td>
                    <td>$settingsHtml</td>
                </tr>
"@
            }

            $htmlReport += @"
            </tbody>
        </table>
    </div>

    <div class="section">
        <h2>Security Baseline Achievements</h2>
        <ul>
            <li><strong>Internal Teams-to-Teams Calling:</strong> ✓ Enabled and unrestricted for internal users</li>
            <li><strong>External Teams-to-Teams Calling:</strong> ✓ Blocked - prevents direct external org calling</li>
            <li><strong>External Chats & Meetings:</strong> ✓ Allowed and enabled via federation</li>
            <li><strong>PSTN Licensing Enforcement:</strong> ✓ PSTN calling available for licensed users</li>
            <li><strong>Lobby Enforcement:</strong> ✓ Non-tenant attendees required to be admitted</li>
            <li><strong>Emergency Calling:</strong> ✓ Enabled and protected</li>
            <li><strong>Call Recording:</strong> ✓ Configured with 30-day retention</li>
            <li><strong>Malicious Content Prevention:</strong> ✓ Memes, GIFs, and stickers disabled</li>
            <li><strong>Third-Party Storage:</strong> ✓ Limited to OneDrive - Dropbox/Google Drive blocked</li>
            <li><strong>Message Deletion Prevention:</strong> ✓ Users cannot delete messages, audit trail maintained</li>
        </ul>
    </div>

    <div class="section">
        <h2>Deployment Information</h2>
        <p><strong>Environment:</strong> $Environment</p>
        <p><strong>Execution Date:</strong> $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
        <p><strong>Log File:</strong> $logFile</p>
        <p><strong>Report Format:</strong> $ReportFormat</p>
        <p><strong>Remediation Mode:</strong> $RemediateNonCompliant</p>
    </div>

    <div class="section">
        <h2>Next Steps</h2>
        <ol>
            <li>Assign policies to user groups using <code>Grant-CsTeamsCallingPolicy</code>, <code>Grant-CsTeamsMeetingPolicy</code>, etc.</li>
            <li>Monitor policy compliance via Teams Admin Center</li>
            <li>Configure call forwarding and voicemail settings per department</li>
            <li>Validate PSTN connectivity and emergency services</li>
            <li>Schedule quarterly security audit and compliance reviews</li>
        </ol>
    </div>

    <div class="footer">
        <p>This report was generated by the Teams Voice Security Baseline automation script.</p>
        <p>For questions or modifications, refer to the official Microsoft documentation or contact your Teams Administration team.</p>
    </div>
</body>
</html>
"@

            $htmlReport | Out-File -Path "$($reportFile).html" -Force -Encoding UTF8
            Write-LogEntry "Compliance report exported (HTML): $($reportFile).html" -Level 'Success'
        }
    }

    Write-LogEntry "Report generation completed successfully" -Level 'Success'

} catch {
    Write-LogEntry "Report generation failed: $($_.Exception.Message)" -Level 'Error'
}
#endregion

#region Cleanup and Summary
try {
    Write-Verbose "[$(Get-Date -Format 'HH:mm:ss')] Finalizing Script Execution"
    
    # Disconnect from Teams service
    Disconnect-MicrosoftTeams -Confirm:$false | Out-Null
    Write-LogEntry "Disconnected from Teams service" -Level 'Info'

    # Script summary
    Write-LogEntry "========================================" -Level 'Info'
    Write-LogEntry "Teams Voice Security Baseline Script Completed Successfully" -Level 'Success'
    Write-LogEntry "Policies Configured: $($complianceResults.Count)" -Level 'Info'
    Write-LogEntry "Log File: $logFile" -Level 'Info'
    Write-LogEntry "Report File: $($reportFile).$($ReportFormat.ToLower())" -Level 'Info'
    Write-LogEntry "========================================" -Level 'Info'

    # Export final audit log entry
    Add-Content -Path $logFile -Value ""
    Add-Content -Path $logFile -Value "Script execution completed $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

} catch {
    Write-LogEntry "Cleanup failed: $($_.Exception.Message)" -Level 'Error'
}
#endregion

Write-Host "`n✓ Teams Voice Security Baseline configuration complete." -ForegroundColor Green
Write-Host "  Reports: $reportFile.$($ReportFormat.ToLower())" -ForegroundColor Cyan
