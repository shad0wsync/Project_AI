<#
.SYNOPSIS
    Audits Teams Voice security baseline compliance across the tenant.

.DESCRIPTION
    Validates that all Teams Voice security policies are properly configured and assigned.
    Identifies non-compliant users, groups, and policy gaps. Generates detailed compliance reports.

.NOTES
    Official Documentation Reference:
    - Teams Admin Center Reporting: https://learn.microsoft.com/en-us/microsoftteams/teams-analytics-and-reports
    - Policy Assignment Verification: https://learn.microsoft.com/en-us/powershell/module/teams/get-csuser
    
    Author: Senior Windows Systems Architect & Automation Engineer
    Version: 1.0.0

.PARAMETER LogPath
    Output directory for audit logs and reports. Default: C:\Logs\TeamsVoiceBaseline

.PARAMETER ReportFormat
    Export format: 'HTML', 'JSON', or 'CSV'. Default: 'HTML'

.PARAMETER IncludeNonCompliantDetails
    If $true, detailed user-level non-compliance data. Default: $true

.PARAMETER Credential
    Azure AD credential for Teams PowerShell authentication.

.EXAMPLE
    .\Audit-TeamsVoiceSecurityCompliance.ps1 -ReportFormat HTML -IncludeNonCompliantDetails $true

#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$LogPath = 'C:\Logs\TeamsVoiceBaseline',

    [Parameter(Mandatory = $false)]
    [ValidateSet('HTML', 'JSON', 'CSV')]
    [string]$ReportFormat = 'HTML',

    [Parameter(Mandatory = $false)]
    [bool]$IncludeNonCompliantDetails = $true,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential]$Credential = $null
)

#region Initialization
try {
    Write-Verbose "[$(Get-Date -Format 'HH:mm:ss')] Initializing Teams Voice Security Compliance Audit"
    
    if (-not (Test-Path -Path $LogPath)) {
        New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
    }

    $logFile = Join-Path -Path $LogPath -ChildPath "ComplianceAudit_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    $reportFile = Join-Path -Path $LogPath -ChildPath "ComplianceReport_$(Get-Date -Format 'yyyyMMdd_HHmmss')"

    $auditLog = @()
    $complianceFindings = @()

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

    Write-LogEntry "Teams Voice Security Compliance Audit Started" -Level 'Info'

} catch {
    Write-Error "Initialization failed: $($_.Exception.Message)"
    exit 1
}
#endregion

#region Service Connection
try {
    Import-Module -Name MicrosoftTeams -Force
    
    if ($null -eq $Credential) {
        Connect-MicrosoftTeams | Out-Null
    } else {
        Connect-MicrosoftTeams -Credential $Credential | Out-Null
    }
    
    Write-LogEntry "Connected to Teams service" -Level 'Success'

} catch {
    Write-LogEntry "Teams service connection failed: $($_.Exception.Message)" -Level 'Error'
    throw
}
#endregion

#region Policy Existence Validation
try {
    Write-Verbose "[$(Get-Date -Format 'HH:mm:ss')] Validating baseline policies exist"
    
    $expectedPolicies = @{
        CallingPolicy     = 'RestrictedTeamsVoicePolicy'
        MeetingPolicy     = 'RestrictedTeamsMeetingPolicy'
        MessagingPolicy   = 'RestrictedTeamsMessagingPolicy'
        AppSetupPolicy    = 'RestrictedTeamsDevicePolicy'
    }

    $policyStatus = @()

    foreach ($policyType in $expectedPolicies.Keys) {
        try {
            $policy = & "Get-CsTeams$($policyType.Replace('Policy', ''))" -Identity $expectedPolicies[$policyType] -ErrorAction Stop
            
            if ($null -ne $policy) {
                Write-LogEntry "Policy validated: $($expectedPolicies[$policyType])" -Level 'Success'
                
                $policyStatus += [PSCustomObject]@{
                    PolicyType = $policyType
                    PolicyName = $expectedPolicies[$policyType]
                    Status     = 'Exists'
                    Details    = "Policy is properly configured"
                }
            }
        } catch {
            Write-LogEntry "Policy NOT found: $($expectedPolicies[$policyType])" -Level 'Warning'
            
            $policyStatus += [PSCustomObject]@{
                PolicyType = $policyType
                PolicyName = $expectedPolicies[$policyType]
                Status     = 'Missing'
                Details    = "Policy requires creation"
            }
        }
    }

    $complianceFindings += [PSCustomObject]@{
        Category = 'PolicyExistence'
        Items    = $policyStatus
    }

} catch {
    Write-LogEntry "Policy validation failed: $($_.Exception.Message)" -Level 'Error'
}
#endregion

#region User Policy Assignment Audit
try {
    Write-Verbose "[$(Get-Date -Format 'HH:mm:ss')] Auditing user policy assignments"
    
    $teams_users = Get-CsOnlineUser -Filter 'InterpretationLanguage -eq "*"' -ResultSize 1000
    
    Write-LogEntry "Retrieved $($teams_users.Count) Teams users for audit" -Level 'Info'

    $userComplianceStatus = @()
    $nonCompliantUsers = @()

    foreach ($user in $teams_users) {
        try {
            $userPolicies = @{
                CallingPolicy     = Get-CsUserPolicyAssignment -Identity $user.ObjectId -PolicyType TeamsCallingPolicy -ErrorAction SilentlyContinue | Select-Object -ExpandProperty PolicyName
                MeetingPolicy     = Get-CsUserPolicyAssignment -Identity $user.ObjectId -PolicyType TeamsMeetingPolicy -ErrorAction SilentlyContinue | Select-Object -ExpandProperty PolicyName
                MessagingPolicy   = Get-CsUserPolicyAssignment -Identity $user.ObjectId -PolicyType TeamsMessagingPolicy -ErrorAction SilentlyContinue | Select-Object -ExpandProperty PolicyName
                AppSetupPolicy    = Get-CsUserPolicyAssignment -Identity $user.ObjectId -PolicyType TeamsAppSetupPolicy -ErrorAction SilentlyContinue | Select-Object -ExpandProperty PolicyName
            }

            $isCompliant = (
                $userPolicies['CallingPolicy'] -eq 'RestrictedTeamsVoicePolicy' -and
                $userPolicies['MeetingPolicy'] -eq 'RestrictedTeamsMeetingPolicy' -and
                $userPolicies['MessagingPolicy'] -eq 'RestrictedTeamsMessagingPolicy' -and
                $userPolicies['AppSetupPolicy'] -eq 'RestrictedTeamsDevicePolicy'
            )

            if ($isCompliant) {
                $userComplianceStatus += [PSCustomObject]@{
                    UserId           = $user.ObjectId
                    UserPrincipalName = $user.UserPrincipalName
                    ComplianceStatus = 'Compliant'
                    CallingPolicy    = $userPolicies['CallingPolicy'] ?? 'Global Default'
                    MeetingPolicy    = $userPolicies['MeetingPolicy'] ?? 'Global Default'
                    MessagingPolicy  = $userPolicies['MessagingPolicy'] ?? 'Global Default'
                    AppSetupPolicy   = $userPolicies['AppSetupPolicy'] ?? 'Global Default'
                }
            } else {
                $userComplianceStatus += [PSCustomObject]@{
                    UserId           = $user.ObjectId
                    UserPrincipalName = $user.UserPrincipalName
                    ComplianceStatus = 'Non-Compliant'
                    CallingPolicy    = $userPolicies['CallingPolicy'] ?? 'Not Assigned'
                    MeetingPolicy    = $userPolicies['MeetingPolicy'] ?? 'Not Assigned'
                    MessagingPolicy  = $userPolicies['MessagingPolicy'] ?? 'Not Assigned'
                    AppSetupPolicy   = $userPolicies['AppSetupPolicy'] ?? 'Not Assigned'
                }
                
                $nonCompliantUsers += $user.UserPrincipalName
            }

        } catch {
            Write-LogEntry "Error auditing user $($user.UserPrincipalName): $($_.Exception.Message)" -Level 'Error'
        }
    }

    $compliantCount = ($userComplianceStatus | Where-Object { $_.ComplianceStatus -eq 'Compliant' }).Count
    $nonCompliantCount = ($userComplianceStatus | Where-Object { $_.ComplianceStatus -eq 'Non-Compliant' }).Count

    Write-LogEntry "User audit complete: $compliantCount compliant, $nonCompliantCount non-compliant" -Level 'Info'

    $complianceFindings += [PSCustomObject]@{
        Category                = 'UserPolicyAssignments'
        TotalUsers              = $userComplianceStatus.Count
        CompliantUsers          = $compliantCount
        NonCompliantUsers       = $nonCompliantCount
        CompliancePercentage    = if ($userComplianceStatus.Count -gt 0) { [math]::Round(($compliantCount / $userComplianceStatus.Count) * 100, 2) } else { 0 }
        Details                 = $userComplianceStatus
    }

} catch {
    Write-LogEntry "User policy audit failed: $($_.Exception.Message)" -Level 'Error'
}
#endregion

#region Federation Configuration Audit
try {
    Write-Verbose "[$(Get-Date -Format 'HH:mm:ss')] Auditing federation configuration"
    
    $federationSettings = Get-CsTenantFederationConfiguration
    
    $federationCompliance = @{
        AllowFederatedUsersCheck = $federationSettings.AllowFederatedUsers -eq $true
        BlockPublicUsersCheck    = $federationSettings.AllowPublicUsers -eq $false
        BlockTeamsConsumerCheck  = $federationSettings.AllowTeamsConsumer -eq $false
        SharedSipAddressCheck    = $federationSettings.SharedSipAddressSpace -eq $false
    }

    $federationCompliant = $federationCompliance.Values -contains $false ? 'Non-Compliant' : 'Compliant'

    Write-LogEntry "Federation configuration status: $federationCompliant" -Level 'Info'

    $complianceFindings += [PSCustomObject]@{
        Category                          = 'FederationConfiguration'
        AllowFederatedUsers              = $federationSettings.AllowFederatedUsers
        AllowPublicUsers                 = $federationSettings.AllowPublicUsers
        AllowTeamsConsumer               = $federationSettings.AllowTeamsConsumer
        AllowTeamsConsumerInbound        = $federationSettings.AllowTeamsConsumerInbound
        SharedSipAddressSpace            = $federationSettings.SharedSipAddressSpace
        OverallComplianceStatus          = $federationCompliant
        Details                          = $federationCompliance
    }

} catch {
    Write-LogEntry "Federation audit failed: $($_.Exception.Message)" -Level 'Error'
}
#endregion

#region Report Generation
try {
    Write-Verbose "[$(Get-Date -Format 'HH:mm:ss')] Generating compliance report"

    switch ($ReportFormat) {
        'JSON' {
            $complianceFindings | ConvertTo-Json -Depth 10 | Out-File -Path "$($reportFile).json" -Force
            Write-LogEntry "Report exported (JSON): $($reportFile).json" -Level 'Success'
        }
        'CSV' {
            $complianceFindings[1].Details | Export-Csv -Path "$($reportFile)_UserCompliance.csv" -NoTypeInformation -Force
            Write-LogEntry "Report exported (CSV): $($reportFile)_UserCompliance.csv" -Level 'Success'
        }
        'HTML' {
            $htmlReport = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Teams Voice Security Compliance Audit Report</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; margin: 20px; background-color: #f5f5f5; }
        .header { background-color: #0078d4; color: white; padding: 20px; border-radius: 5px; }
        .section { background-color: white; margin: 20px 0; padding: 15px; border-radius: 5px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
        table { width: 100%; border-collapse: collapse; margin-top: 10px; }
        th { background-color: #0078d4; color: white; padding: 10px; text-align: left; }
        td { padding: 10px; border-bottom: 1px solid #ddd; }
        tr:hover { background-color: #f9f9f9; }
        .status-compliant { color: #107c10; font-weight: bold; }
        .status-non-compliant { color: #d83b01; font-weight: bold; }
        .status-missing { color: #ffb900; font-weight: bold; }
        .metric { display: inline-block; margin: 10px 20px 10px 0; }
        .metric-value { font-size: 24px; font-weight: bold; color: #0078d4; }
        .metric-label { color: #666; font-size: 12px; }
        .footer { margin-top: 20px; padding-top: 10px; border-top: 1px solid #ddd; font-size: 0.9em; color: #666; }
    </style>
</head>
<body>
    <div class="header">
        <h1>Teams Voice Security Compliance Audit Report</h1>
        <p>Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
    </div>

    <div class="section">
        <h2>Executive Summary</h2>
        <div class="metric">
            <div class="metric-value">$($complianceFindings[1].CompliantUsers)</div>
            <div class="metric-label">Compliant Users</div>
        </div>
        <div class="metric">
            <div class="metric-value">$($complianceFindings[1].NonCompliantUsers)</div>
            <div class="metric-label">Non-Compliant Users</div>
        </div>
        <div class="metric">
            <div class="metric-value">$($complianceFindings[1].CompliancePercentage)%</div>
            <div class="metric-label">Overall Compliance Rate</div>
        </div>
    </div>

    <div class="section">
        <h2>Policy Existence Status</h2>
        <table>
            <thead>
                <tr>
                    <th>Policy Type</th>
                    <th>Policy Name</th>
                    <th>Status</th>
                    <th>Details</th>
                </tr>
            </thead>
            <tbody>
"@

            foreach ($policy in $complianceFindings[0].Items) {
                $statusClass = $policy.Status -eq 'Exists' ? 'status-compliant' : 'status-missing'
                $htmlReport += @"
                <tr>
                    <td>$($policy.PolicyType)</td>
                    <td>$($policy.PolicyName)</td>
                    <td><span class="$statusClass">$($policy.Status)</span></td>
                    <td>$($policy.Details)</td>
                </tr>
"@
            }

            $htmlReport += @"
            </tbody>
        </table>
    </div>

    <div class="section">
        <h2>Federation Configuration Status</h2>
        <table>
            <thead>
                <tr>
                    <th>Setting</th>
                    <th>Value</th>
                    <th>Expected</th>
                    <th>Status</th>
                </tr>
            </thead>
            <tbody>
"@

            $expectedFederation = @{
                'AllowFederatedUsers'     = $true
                'AllowPublicUsers'        = $false
                'AllowTeamsConsumer'      = $false
                'AllowTeamsConsumerInbound' = $false
                'SharedSipAddressSpace'   = $false
            }

            foreach ($setting in $expectedFederation.Keys) {
                $actualValue = $complianceFindings[2].$setting
                $expectedValue = $expectedFederation[$setting]
                $isCompliant = $actualValue -eq $expectedValue
                $statusClass = $isCompliant ? 'status-compliant' : 'status-non-compliant'
                
                $htmlReport += @"
                <tr>
                    <td>$setting</td>
                    <td>$actualValue</td>
                    <td>$expectedValue</td>
                    <td><span class="$statusClass">$(if ($isCompliant) { 'Compliant' } else { 'Non-Compliant' })</span></td>
                </tr>
"@
            }

            $htmlReport += @"
            </tbody>
        </table>
    </div>
"@

            if ($IncludeNonCompliantDetails -and $nonCompliantCount -gt 0) {
                $htmlReport += @"
    <div class="section">
        <h2>Non-Compliant Users</h2>
        <table>
            <thead>
                <tr>
                    <th>User Principal Name</th>
                    <th>Calling Policy</th>
                    <th>Meeting Policy</th>
                    <th>Messaging Policy</th>
                    <th>App Setup Policy</th>
                </tr>
            </thead>
            <tbody>
"@

                $nonCompliantUserDetails = $complianceFindings[1].Details | Where-Object { $_.ComplianceStatus -eq 'Non-Compliant' }
                foreach ($user in $nonCompliantUserDetails) {
                    $htmlReport += @"
                <tr>
                    <td>$($user.UserPrincipalName)</td>
                    <td>$($user.CallingPolicy)</td>
                    <td>$($user.MeetingPolicy)</td>
                    <td>$($user.MessagingPolicy)</td>
                    <td>$($user.AppSetupPolicy)</td>
                </tr>
"@
                }

                $htmlReport += @"
            </tbody>
        </table>
    </div>
"@
            }

            $htmlReport += @"
    <div class="section">
        <h2>Recommendations</h2>
        <ul>
"@

            if ($compliantCount / $userComplianceStatus.Count -lt 0.95) {
                $htmlReport += "<li><strong>High Priority:</strong> Assign baseline policies to $nonCompliantCount non-compliant users using Apply-TeamsVoiceSecurityPolicy.ps1</li>"
            }

            if (($complianceFindings[0].Items | Where-Object { $_.Status -eq 'Missing' }).Count -gt 0) {
                $htmlReport += "<li><strong>Critical:</strong> Run Set-TeamsVoiceSecurityBaseline.ps1 to create missing policies</li>"
            }

            if (-not ($complianceFindings[2].Details.Values -contains $false)) {
                $htmlReport += "<li><strong>Verified:</strong> Federation configuration complies with security baseline</li>"
            } else {
                $htmlReport += "<li><strong>Action Required:</strong> Review and correct federation settings per baseline requirements</li>"
            }

            $htmlReport += @"
        </ul>
    </div>

    <div class="section">
        <h2>Audit Information</h2>
        <p><strong>Audit Timestamp:</strong> $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
        <p><strong>Total Users Audited:</strong> $($userComplianceStatus.Count)</p>
        <p><strong>Report Format:</strong> HTML</p>
        <p><strong>Log File:</strong> $logFile</p>
    </div>

    <div class="footer">
        <p>This audit report was generated by the Teams Voice Security Compliance audit script.</p>
        <p>Execute this audit monthly to maintain compliance visibility.</p>
    </div>
</body>
</html>
"@

            $htmlReport | Out-File -Path "$($reportFile).html" -Force -Encoding UTF8
            Write-LogEntry "Report exported (HTML): $($reportFile).html" -Level 'Success'
        }
    }

    Write-LogEntry "Report generation completed" -Level 'Success'

} catch {
    Write-LogEntry "Report generation failed: $($_.Exception.Message)" -Level 'Error'
}
#endregion

#region Cleanup
try {
    Disconnect-MicrosoftTeams -Confirm:$false | Out-Null
    Write-LogEntry "Disconnected from Teams service" -Level 'Info'
    Write-LogEntry "========================================" -Level 'Info'
    Write-LogEntry "Teams Voice Security Compliance Audit Completed" -Level 'Success'
    Write-LogEntry "Report: $reportFile.$($ReportFormat.ToLower())" -Level 'Info'
    Write-LogEntry "========================================" -Level 'Info'

} catch {
    Write-LogEntry "Cleanup failed: $($_.Exception.Message)" -Level 'Error'
}
#endregion

Write-Host "`n✓ Compliance audit complete." -ForegroundColor Green
Write-Host "  Report: $reportFile.$($ReportFormat.ToLower())" -ForegroundColor Cyan
Write-Host "  Log: $logFile" -ForegroundColor Cyan
