<#
.SYNOPSIS
    Teams CIS Hardening - Interactive Menu-Driven Assessment & Remediation

.DESCRIPTION
    Connects to Microsoft Teams, then presents an interactive menu for:
    - Assessment & Report
    - Guided Remediation with detailed impact analysis
    - Snapshot current state
    - Rollback from previous snapshot

.PARAMETER ExcludeControls
    Array of CIS control IDs to skip (e.g., "8.5.1","8.5.9").

.PARAMETER ReportPath
    Output directory for reports and logs. Default: C:\Temp\Set-TeamsHardening

.EXAMPLE
    .\Set-TeamsHardening.ps1

.NOTES
    Script:   Set-TeamsHardening.ps1
    Author:   Jeff Davidson/Chase Tuter
    Version:  1.3.1
#>
#Requires -Version 5.1

[CmdletBinding()]
param(
    [string[]]$ExcludeControls = @(),
    [string]$ReportPath = 'C:\Temp\Set-TeamsHardening'
)

$script:Version = '1.3.1'
$script:LogFile = $null
$script:TenantName = $null

# ===============================================================================
# CIS CONTROLS DEFINITION
# ===============================================================================

$CISControls = @(
    @{
        CisId           = '8.2.2'
        Tier            = 'Mandatory'
        Title           = 'Block unmanaged Teams users'
        Description     = 'Prevents users from communicating with personal Microsoft Teams accounts not managed by any organization.'
        Setting         = 'AllowTeamsConsumer'
        TargetValue     = $false
        Cmdlet          = 'Set-CsTenantFederationConfiguration'
        GetCmdlet       = 'Get-CsTenantFederationConfiguration'
        PolicyIdentity  = $null
        Severity        = 'High'
        SecurityBenefit = 'Blocks phishing/social engineering via personal Teams accounts'
        BusinessImpact  = 'Users cannot chat with personal @outlook.com accounts. B2B unaffected.'
        RiskIfIgnored   = 'Vulnerable to external phishing campaigns through Teams'
    }
    @{
        CisId           = '8.2.3'
        Tier            = 'Mandatory'
        Title           = 'Block inbound from unmanaged Teams'
        Description     = 'Prevents external unmanaged Teams users from initiating conversations with your users.'
        Setting         = 'AllowTeamsConsumerInbound'
        TargetValue     = $false
        Cmdlet          = 'Set-CsTenantFederationConfiguration'
        GetCmdlet       = 'Get-CsTenantFederationConfiguration'
        PolicyIdentity  = $null
        Severity        = 'High'
        SecurityBenefit = 'Prevents unsolicited contact from personal accounts'
        BusinessImpact  = 'Minimal - legitimate contacts use organizational accounts'
        RiskIfIgnored   = 'Attackers can cold-contact employees with phishing messages'
    }
    @{
        CisId           = '8.2.4'
        Tier            = 'Mandatory'
        Title           = 'Disable Skype consumer interop'
        Description     = 'Blocks communication between Teams and legacy Skype consumer accounts.'
        Setting         = 'AllowFederatedUsers'  # CHANGED from AllowPublicUsers
        TargetValue     = $false
        Cmdlet          = 'Set-CsTenantFederationConfiguration'
        GetCmdlet       = 'Get-CsTenantFederationConfiguration'
        PolicyIdentity  = $null
        Severity        = 'Medium'
        SecurityBenefit = 'Eliminates attack surface from deprecated platform'
        BusinessImpact  = 'None - Skype consumer rarely used for business'
        RiskIfIgnored   = 'Unnecessary open communication channel for attackers'
    }
    @{
        CisId           = '8.1.2'
        Tier            = 'Recommended'
        Title           = 'Disable email-to-channel'
        Description     = 'Prevents posting messages to Teams channels via email addresses.'
        Setting         = 'AllowEmailIntoChannel'
        TargetValue     = $false
        Cmdlet          = 'Set-CsTeamsClientConfiguration'
        GetCmdlet       = 'Get-CsTeamsClientConfiguration'
        PolicyIdentity  = $null
        Severity        = 'Medium'
        SecurityBenefit = 'Prevents injection of phishing content into channels'
        BusinessImpact  = 'MODERATE - verify no ticketing/alert workflows use this'
        RiskIfIgnored   = 'Attackers can inject content directly into Teams channels'
    }
    @{
        CisId           = '8.2.1'
        Tier            = 'Recommended'
        Title           = 'Block trial tenant federation'
        Description     = 'Prevents communication with Microsoft 365 trial tenant accounts.'
        Setting         = 'ExternalAccessWithTrialTenants'
        TargetValue     = 'Blocked'
        Cmdlet          = 'Set-CsTenantFederationConfiguration'
        GetCmdlet       = 'Get-CsTenantFederationConfiguration'
        PolicyIdentity  = $null
        Severity        = 'High'
        SecurityBenefit = 'Blocks free/anonymous trial tenants used by attackers'
        BusinessImpact  = 'Minimal - legitimate partners have paid subscriptions'
        RiskIfIgnored   = 'Can receive messages from attackers using free trials'
    }
    @{
        CisId           = '8.5.2'
        Tier            = 'Recommended'
        Title           = 'Anonymous cannot start meetings'
        Description     = 'Prevents anonymous users from starting a scheduled meeting before the organizer joins.'
        Setting         = 'AllowAnonymousUsersToStartMeeting'
        TargetValue     = $false
        Cmdlet          = 'Set-CsTeamsMeetingPolicy'
        GetCmdlet       = 'Get-CsTeamsMeetingPolicy'
        PolicyIdentity  = 'Global'
        Severity        = 'Medium'
        SecurityBenefit = 'Prevents meeting hijacking before organizer arrives'
        BusinessImpact  = 'None - organizer simply joins first'
        RiskIfIgnored   = 'Attackers could join early and present malicious content'
    }
    @{
        CisId           = '8.5.3'
        Tier            = 'Recommended'
        Title           = 'Restrict lobby bypass'
        Description     = 'Only organization members (excluding guests) bypass the meeting lobby automatically.'
        Setting         = 'AutoAdmittedUsers'
        TargetValue     = 'EveryoneInCompanyExcludingGuests'
        Cmdlet          = 'Set-CsTeamsMeetingPolicy'
        GetCmdlet       = 'Get-CsTeamsMeetingPolicy'
        PolicyIdentity  = 'Global'
        Severity        = 'Medium'
        SecurityBenefit = 'Organizer controls who joins meetings'
        BusinessImpact  = 'MODERATE - external attendees wait in lobby'
        RiskIfIgnored   = 'Anyone with meeting link can join without awareness'
    }
    @{
        CisId           = '8.5.4'
        Tier            = 'Recommended'
        Title           = 'Dial-in users wait in lobby'
        Description     = 'Requires PSTN dial-in participants to wait in the lobby for admission.'
        Setting         = 'AllowPSTNUsersToBypassLobby'
        TargetValue     = $false
        Cmdlet          = 'Set-CsTeamsMeetingPolicy'
        GetCmdlet       = 'Get-CsTeamsMeetingPolicy'
        PolicyIdentity  = 'Global'
        Severity        = 'Medium'
        SecurityBenefit = 'Phone callers must be verified before admission'
        BusinessImpact  = 'MODERATE - phone callers wait in lobby'
        RiskIfIgnored   = 'Anyone with dial-in number can join anonymously'
    }
    @{
        CisId           = '8.5.5'
        Tier            = 'Recommended'
        Title           = 'No anonymous meeting chat'
        Description     = 'Prevents anonymous meeting participants from using the meeting chat.'
        Setting         = 'MeetingChatEnabledType'
        TargetValue     = 'EnabledExceptAnonymous'
        Cmdlet          = 'Set-CsTeamsMeetingPolicy'
        GetCmdlet       = 'Get-CsTeamsMeetingPolicy'
        PolicyIdentity  = 'Global'
        Severity        = 'Low'
        SecurityBenefit = 'Prevents anonymous users sharing malicious links via chat'
        BusinessImpact  = 'Low - anonymous can still speak, just not text chat'
        RiskIfIgnored   = 'Anonymous attendees could share phishing links'
    }
    @{
        CisId           = '8.5.7'
        Tier            = 'Recommended'
        Title           = 'External cannot control screen'
        Description     = 'Prevents external participants from requesting or being given screen control.'
        Setting         = 'AllowExternalParticipantGiveRequestControl'
        TargetValue     = $false
        Cmdlet          = 'Set-CsTeamsMeetingPolicy'
        GetCmdlet       = 'Get-CsTeamsMeetingPolicy'
        PolicyIdentity  = 'Global'
        Severity        = 'Medium'
        SecurityBenefit = 'Prevents external users taking control of screens'
        BusinessImpact  = 'Low - external users can still view shared screens'
        RiskIfIgnored   = 'Attacker could request control and run malicious actions'
    }
    @{
        CisId           = '8.6.1'
        Tier            = 'Recommended'
        Title           = 'Enable security reporting'
        Description     = 'Allows users to report suspicious messages directly from Teams.'
        Setting         = 'AllowSecurityEndUserReporting'
        TargetValue     = $true
        Cmdlet          = 'Set-CsTeamsMessagingPolicy'
        GetCmdlet       = 'Get-CsTeamsMessagingPolicy'
        PolicyIdentity  = 'Global'
        Severity        = 'Low'
        SecurityBenefit = 'Users can report phishing - improves threat detection'
        BusinessImpact  = 'None negative - adds helpful Report option'
        RiskIfIgnored   = 'No easy way for users to report Teams threats'
    }
    @{
        CisId           = '8.1.1a'
        Tier            = 'Optional'
        Title           = 'Disable DropBox integration'
        Description     = 'Removes DropBox as a cloud storage option within Teams.'
        Setting         = 'AllowDropBox'
        TargetValue     = $false
        Cmdlet          = 'Set-CsTeamsClientConfiguration'
        GetCmdlet       = 'Get-CsTeamsClientConfiguration'
        PolicyIdentity  = $null
        Severity        = 'Medium'
        SecurityBenefit = 'Consolidates storage to approved platforms'
        BusinessImpact  = 'HIGH if DropBox actively used - verify first'
        RiskIfIgnored   = 'Data stored outside compliance boundary'
    }
    @{
        CisId           = '8.1.1b'
        Tier            = 'Optional'
        Title           = 'Disable Google Drive integration'
        Description     = 'Removes Google Drive as a cloud storage option within Teams.'
        Setting         = 'AllowGoogleDrive'
        TargetValue     = $false
        Cmdlet          = 'Set-CsTeamsClientConfiguration'
        GetCmdlet       = 'Get-CsTeamsClientConfiguration'
        PolicyIdentity  = $null
        Severity        = 'Medium'
        SecurityBenefit = 'Consolidates storage to approved platforms'
        BusinessImpact  = 'HIGH if Google Drive actively used'
        RiskIfIgnored   = 'Data outside compliance boundary'
    }
    @{
        CisId           = '8.1.1c'
        Tier            = 'Optional'
        Title           = 'Disable Box integration'
        Description     = 'Removes Box as a cloud storage option within Teams.'
        Setting         = 'AllowBox'
        TargetValue     = $false
        Cmdlet          = 'Set-CsTeamsClientConfiguration'
        GetCmdlet       = 'Get-CsTeamsClientConfiguration'
        PolicyIdentity  = $null
        Severity        = 'Medium'
        SecurityBenefit = 'Consolidates storage to approved platforms'
        BusinessImpact  = 'HIGH if Box actively used'
        RiskIfIgnored   = 'Data outside compliance boundary'
    }
    @{
        CisId           = '8.1.1d'
        Tier            = 'Optional'
        Title           = 'Disable ShareFile integration'
        Description     = 'Removes Citrix ShareFile as a cloud storage option within Teams.'
        Setting         = 'AllowShareFile'
        TargetValue     = $false
        Cmdlet          = 'Set-CsTeamsClientConfiguration'
        GetCmdlet       = 'Get-CsTeamsClientConfiguration'
        PolicyIdentity  = $null
        Severity        = 'Medium'
        SecurityBenefit = 'Consolidates storage to approved platforms'
        BusinessImpact  = 'HIGH if ShareFile actively used'
        RiskIfIgnored   = 'Data outside compliance boundary'
    }
    @{
        CisId           = '8.1.1e'
        Tier            = 'Optional'
        Title           = 'Disable Egnyte integration'
        Description     = 'Removes Egnyte as a cloud storage option within Teams.'
        Setting         = 'AllowEgnyte'
        TargetValue     = $false
        Cmdlet          = 'Set-CsTeamsClientConfiguration'
        GetCmdlet       = 'Get-CsTeamsClientConfiguration'
        PolicyIdentity  = $null
        Severity        = 'Medium'
        SecurityBenefit = 'Consolidates storage to approved platforms'
        BusinessImpact  = 'HIGH if Egnyte actively used'
        RiskIfIgnored   = 'Data outside compliance boundary'
    }
    @{
        CisId           = '8.5.1'
        Tier            = 'Optional'
        Title           = 'Block anonymous meeting join'
        Description     = 'Completely prevents anonymous users from joining meetings.'
        Setting         = 'AllowAnonymousUsersToJoinMeeting'
        TargetValue     = $false
        Cmdlet          = 'Set-CsTeamsMeetingPolicy'
        GetCmdlet       = 'Get-CsTeamsMeetingPolicy'
        PolicyIdentity  = 'Global'
        Severity        = 'CRITICAL'
        SecurityBenefit = 'Maximum meeting security - only authenticated users'
        BusinessImpact  = '*** BREAKS external meetings without M365! ***'
        RiskIfIgnored   = 'Anonymous can join with link - other controls mitigate'
    }
    @{
        CisId           = '8.5.6'
        Tier            = 'Optional'
        Title           = 'Only organizer can present'
        Description     = 'Sets default presenter role to organizer only.'
        Setting         = 'DesignatedPresenterRoleMode'
        TargetValue     = 'OrganizerOnlyUserOverride'
        Cmdlet          = 'Set-CsTeamsMeetingPolicy'
        GetCmdlet       = 'Get-CsTeamsMeetingPolicy'
        PolicyIdentity  = 'Global'
        Severity        = 'Low'
        SecurityBenefit = 'Prevents attendees from sharing screen by default'
        BusinessImpact  = 'MODERATE - organizers must promote presenters'
        RiskIfIgnored   = 'Any attendee can share screen by default'
    }
    @{
        CisId           = '8.5.8'
        Tier            = 'Optional'
        Title           = 'Disable external meeting chat'
        Description     = 'Blocks chat with external non-trusted meeting participants.'
        Setting         = 'AllowExternalNonTrustedMeetingChat'
        TargetValue     = $false
        Cmdlet          = 'Set-CsTeamsMeetingPolicy'
        GetCmdlet       = 'Get-CsTeamsMeetingPolicy'
        PolicyIdentity  = 'Global'
        Severity        = 'Medium'
        SecurityBenefit = 'Prevents external sharing malicious content via chat'
        BusinessImpact  = 'MODERATE - external cannot use meeting chat'
        RiskIfIgnored   = 'External participants can share content via chat'
    }
    @{
        CisId           = '8.5.9'
        Tier            = 'Optional'
        Title           = 'Disable cloud recording'
        Description     = 'Disables the ability to record Teams meetings to the cloud.'
        Setting         = 'AllowCloudRecording'
        TargetValue     = $false
        Cmdlet          = 'Set-CsTeamsMeetingPolicy'
        GetCmdlet       = 'Get-CsTeamsMeetingPolicy'
        PolicyIdentity  = 'Global'
        Severity        = 'Medium'
        SecurityBenefit = 'Prevents sensitive meeting content from being recorded'
        BusinessImpact  = '*** DISABLES all meeting recording! ***'
        RiskIfIgnored   = 'Recordings may be accessed inappropriately'
    }
)

# ===============================================================================
# FUNCTIONS
# ===============================================================================

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    if ($script:LogFile) { 
        $entry = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] [' + $Level + '] ' + $Message
        Add-Content -Path $script:LogFile -Value $entry -ErrorAction SilentlyContinue 
    }
}

function Write-Banner {
    param([string]$Text, [string]$Color = 'Cyan')
    Write-Host ''
    Write-Host ('=' * 80) -ForegroundColor $Color
    Write-Host (' ' + $Text) -ForegroundColor $Color
    Write-Host ('=' * 80) -ForegroundColor $Color
}

function Get-CurrentConfig {
    Write-Host ''
    Write-Host '  Retrieving current Teams configuration...' -ForegroundColor Cyan
    Write-Host ''
    $config = @{ TenantFederation = $null; ClientConfig = $null; MeetingPolicy = $null; MessagingPolicy = $null }
    Write-Host '    [1/4] Tenant Federation...' -NoNewline
    try { $config.TenantFederation = Get-CsTenantFederationConfiguration -ErrorAction Stop; Write-Host ' OK' -ForegroundColor Green } catch { Write-Host ' FAILED' -ForegroundColor Red }
    Write-Host '    [2/4] Client Configuration...' -NoNewline
    try { $config.ClientConfig = Get-CsTeamsClientConfiguration -ErrorAction Stop; Write-Host ' OK' -ForegroundColor Green } catch { Write-Host ' FAILED' -ForegroundColor Red }
    Write-Host '    [3/4] Meeting Policy...' -NoNewline
    try { $config.MeetingPolicy = Get-CsTeamsMeetingPolicy -Identity Global -ErrorAction Stop; Write-Host ' OK' -ForegroundColor Green } catch { Write-Host ' FAILED' -ForegroundColor Red }
    Write-Host '    [4/4] Messaging Policy...' -NoNewline
    try { $config.MessagingPolicy = Get-CsTeamsMessagingPolicy -Identity Global -ErrorAction Stop; Write-Host ' OK' -ForegroundColor Green } catch { Write-Host ' FAILED' -ForegroundColor Red }
    Write-Host ''
    return $config
}

function Test-TeamsCompliance {
    param($Control, $Config)
    $currentValue = $null
    switch ($Control.GetCmdlet) {
        'Get-CsTenantFederationConfiguration' { $currentValue = $Config.TenantFederation.($Control.Setting) }
        'Get-CsTeamsClientConfiguration'      { $currentValue = $Config.ClientConfig.($Control.Setting) }
        'Get-CsTeamsMeetingPolicy'            { $currentValue = $Config.MeetingPolicy.($Control.Setting) }
        'Get-CsTeamsMessagingPolicy'          { $currentValue = $Config.MessagingPolicy.($Control.Setting) }
    }
    $currentStr = if ($null -eq $currentValue) { '' } else { "$currentValue" }
    $targetStr  = if ($null -eq $Control.TargetValue) { '' } else { "$($Control.TargetValue)" }
    return @{ CurrentValue = $currentValue; TargetValue = $Control.TargetValue; IsCompliant = ($currentStr -eq $targetStr) }
}

function Set-ControlValue {
    param(
        [string]$Cmdlet, 
        [string]$Setting, 
        $Value, 
        [string]$PolicyIdentity
    )
    
    $params = @{ $Setting = $Value }
    
    # Determine which cmdlets need Identity and what value
    switch ($Cmdlet) {
        # These always need -Identity Global
        'Set-CsTenantFederationConfiguration' { 
            $params['Identity'] = 'Global'
        }
        'Set-CsTeamsClientConfiguration' { 
            $params['Identity'] = 'Global'
        }
        # These use the PolicyIdentity value (should be 'Global')
        'Set-CsTeamsMeetingPolicy' { 
            if ($PolicyIdentity) {
                $params['Identity'] = $PolicyIdentity
            } else {
                $params['Identity'] = 'Global'  # Fallback
            }
        }
        'Set-CsTeamsMessagingPolicy' { 
            if ($PolicyIdentity) {
                $params['Identity'] = $PolicyIdentity
            } else {
                $params['Identity'] = 'Global'  # Fallback
            }
        }
        default {
            # If PolicyIdentity is set, use it; otherwise don't add Identity
            if ($PolicyIdentity) {
                $params['Identity'] = $PolicyIdentity
            }
        }
    }
    
    try { 
        Write-Host "    [DEBUG] Calling: $Cmdlet -$Setting `"$Value`"" -NoNewline -ForegroundColor Gray
        if ($params.ContainsKey('Identity')) {
            Write-Host " -Identity $($params['Identity'])" -ForegroundColor Gray
        } else {
            Write-Host "" -ForegroundColor Gray
        }
        
        & $Cmdlet @params -ErrorAction Stop
        return @{ Success = $true; Error = $null } 
    }
    catch { 
        return @{ Success = $false; Error = $_.Exception.Message } 
    }
}

function Show-DetailedControlList {
    param($Items, $InsufficientPermissionCisIds = @())
    
    Write-Host ''
    Write-Host '  #   CIS     Tier          Severity   Setting' -ForegroundColor White
    Write-Host '  =============================================================================' -ForegroundColor Gray
    
    $i = 1
    foreach ($item in $Items) {
        $tierColor = switch ($item.Tier) { 'Mandatory' { 'Red' } 'Recommended' { 'Yellow' } default { 'Gray' } }
        $sevColor = switch ($item.Severity) { 'CRITICAL' { 'Magenta' } 'High' { 'Red' } 'Medium' { 'Yellow' } default { 'Green' } }
        
        Write-Host ''
        Write-Host "  $($i.ToString().PadLeft(2))  " -NoNewline -ForegroundColor Cyan
        Write-Host "$($item.CisId.PadRight(7))" -NoNewline -ForegroundColor White
        Write-Host "$($item.Tier.PadRight(13))" -NoNewline -ForegroundColor $tierColor
        Write-Host "$($item.Severity.PadRight(10))" -NoNewline -ForegroundColor $sevColor
        Write-Host $item.Setting
        
        $curVal = if ($null -eq $item.CurrentValue) { '<not set>' } else { "$($item.CurrentValue)" }
        Write-Host '      ' -NoNewline
        Write-Host 'Current: ' -NoNewline -ForegroundColor Gray
        Write-Host $curVal.PadRight(15) -NoNewline -ForegroundColor Red
        Write-Host ' -> ' -NoNewline -ForegroundColor Gray
        Write-Host 'Target: ' -NoNewline -ForegroundColor Gray
        Write-Host "$($item.TargetValue)" -ForegroundColor Green
        
        if ($InsufficientPermissionCisIds -contains $item.CisId) {
            Write-Host '      ' -NoNewline
            Write-Host '[!] Insufficient Permissions - Teams Service Administrator role required' -ForegroundColor Yellow
        }
        
        Write-Host '      ' -NoNewline
        Write-Host '[+] ' -NoNewline -ForegroundColor Green
        Write-Host $item.SecurityBenefit -ForegroundColor Gray
        
        Write-Host '      ' -NoNewline
        Write-Host '[!] ' -NoNewline -ForegroundColor Yellow
        Write-Host $item.BusinessImpact -ForegroundColor Gray
        
        Write-Host '      ' -NoNewline
        Write-Host '[-] ' -NoNewline -ForegroundColor Red
        Write-Host $item.RiskIfIgnored -ForegroundColor Gray
        
        $i++
    }
    
    Write-Host ''
    Write-Host '  =============================================================================' -ForegroundColor Gray
}

function Show-SelectionMenu {
    param($Items, $InsufficientPermissionCisIds = @())
    
    $mCount = @($Items | Where-Object { $_.Tier -eq 'Mandatory' }).Count
    $rCount = @($Items | Where-Object { $_.Tier -eq 'Recommended' }).Count
    $oCount = @($Items | Where-Object { $_.Tier -eq 'Optional' }).Count
    
    # Count how many in each tier require additional permissions
    $mInsufficient = @($Items | Where-Object { $_.Tier -eq 'Mandatory' -and $InsufficientPermissionCisIds -contains $_.CisId }).Count
    $rInsufficient = @($Items | Where-Object { $_.Tier -eq 'Recommended' -and $InsufficientPermissionCisIds -contains $_.CisId }).Count
    $oInsufficient = @($Items | Where-Object { $_.Tier -eq 'Optional' -and $InsufficientPermissionCisIds -contains $_.CisId }).Count
    $safeInsufficient = @($Items | Where-Object { $_.Tier -in @('Mandatory','Recommended') -and $InsufficientPermissionCisIds -contains $_.CisId }).Count
    
    Write-Host ''
    Write-Host '  SELECTION OPTIONS:' -ForegroundColor Yellow
    Write-Host '  -------------------------------------------------------------------------------' -ForegroundColor Gray
    Write-Host ''
    Write-Host '    Quick Select:' -ForegroundColor Cyan
    
    if ($mInsufficient -gt 0) {
        Write-Host "      all         - Apply all $($Items.Count) controls ($mInsufficient require additional permissions)" -ForegroundColor Gray
    } else {
        Write-Host "      all         - Apply all $($Items.Count) controls"
    }
    
    if ($mInsufficient -gt 0) {
        Write-Host "      mandatory   - Apply $mCount Mandatory tier controls only ($mInsufficient require additional permissions)" -ForegroundColor Red
    } else {
        Write-Host "      mandatory   - Apply $mCount Mandatory tier controls only" -ForegroundColor Red
    }
    
    if ($rInsufficient -gt 0) {
        Write-Host "      recommended - Apply $rCount Recommended tier controls only ($rInsufficient require additional permissions)" -ForegroundColor Yellow
    } else {
        Write-Host "      recommended - Apply $rCount Recommended tier controls only" -ForegroundColor Yellow
    }
    
    if ($oInsufficient -gt 0) {
        Write-Host "      optional    - Apply $oCount Optional tier controls only ($oInsufficient require additional permissions)" -ForegroundColor Gray
    } else {
        Write-Host "      optional    - Apply $oCount Optional tier controls only" -ForegroundColor Gray
    }
    
    if ($safeInsufficient -gt 0) {
        Write-Host "      safe        - Apply Mandatory + Recommended ($($mCount + $rCount) controls / $safeInsufficient require additional permissions)" -ForegroundColor Green
    } else {
        Write-Host "      safe        - Apply Mandatory + Recommended ($($mCount + $rCount) controls)" -ForegroundColor Green
    }
    
    Write-Host '      none        - Cancel and return to menu'
    Write-Host ''
    Write-Host '    Custom Select:' -ForegroundColor Cyan
    Write-Host '      Enter numbers: 1,2,5 or 1-3,7 or 1-5,8,10-12'
    Write-Host ''
    
    return (Read-Host '  Enter selection').Trim().ToLower()
}

function Resolve-Selection {
    param([string]$Selection, $Items)
    
    $selection = $selection.Trim().ToLower()
    $indices = @()
    
    # Quick select keywords - return immediately
    switch ($selection) {
        'all' { return (1..$Items.Count) }
        'none' { return $null }
        'mandatory' { 
            for ($i = 0; $i -lt $Items.Count; $i++) {
                if ($Items[$i].Tier -eq 'Mandatory') { $indices += $i + 1 }
            }
            return $indices
        }
        'recommended' { 
            for ($i = 0; $i -lt $Items.Count; $i++) {
                if ($Items[$i].Tier -eq 'Recommended') { $indices += $i + 1 }
            }
            return $indices
        }
        'optional' { 
            for ($i = 0; $i -lt $Items.Count; $i++) {
                if ($Items[$i].Tier -eq 'Optional') { $indices += $i + 1 }
            }
            return $indices
        }
        'safe' { 
            for ($i = 0; $i -lt $Items.Count; $i++) {
                if ($Items[$i].Tier -in @('Mandatory','Recommended')) { $indices += $i + 1 }
            }
            return $indices
        }
    }
    
    # Custom numeric selection
    $parts = $selection -split ','
    foreach ($part in $parts) {
        $part = $part.Trim()
        if ([string]::IsNullOrWhiteSpace($part)) { continue }
        
        if ($part.Contains('-')) {
            $dashPos = $part.IndexOf('-')
            $startStr = $part.Substring(0, $dashPos).Trim()
            $endStr = $part.Substring($dashPos + 1).Trim()
            
            $start = $null
            $end = $null
            if ([int]::TryParse($startStr, [ref]$start) -and [int]::TryParse($endStr, [ref]$end)) {
                for ($j = $start; $j -le $end; $j++) {
                    if ($j -ge 1 -and $j -le $Items.Count) { $indices += $j }
                }
            }
        }
        else {
            $num = $null
            if ([int]::TryParse($part, [ref]$num)) {
                if ($num -ge 1 -and $num -le $Items.Count) { $indices += $num }
            }
        }
    }
    
    if ($indices.Count -gt 0) {
        return @($indices | Sort-Object -Unique)
    } else {
        return @()
    }
}

function Export-RollbackConfig {
    param(
        $RollbackData, 
        [string]$TenantName, 
        [string]$OutputPath,
        [string]$FileType = 'Remediation'  # 'Remediation' or 'Snapshot'
    )
    
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $filename = "Teams_$($FileType)_$timestamp.json"
    $file = Join-Path $OutputPath $filename
    
    @{ 
        SchemaVersion = '1.0'
        GeneratedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        FileType = $FileType
        TenantName = $TenantName
        ScriptVersion = $script:Version
        Changes = $RollbackData
    } | ConvertTo-Json -Depth 10 | Out-File -FilePath $file -Encoding UTF8
    
    Write-Log "$FileType saved: $file"
    return $file
}

function Export-HtmlReport {
    param($Results, [string]$TenantName, [string]$OutputPath, [string]$RollbackFile)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $compliant = @($Results | Where-Object { $_.IsCompliant -and -not $_.Excluded }).Count
    $nonCompliant = @($Results | Where-Object { -not $_.IsCompliant -and -not $_.Excluded -and -not $_.Remediated }).Count
    $remediated = @($Results | Where-Object { $_.Remediated }).Count
    $total = $Results.Count
    $pct = if ($total -gt 0) { [math]::Round((($compliant + $remediated) / $total) * 100, 1) } else { 0 }
    $scriptVer = $script:Version
    $rollbackHtml = ''
    if ($RollbackFile) { $rollbackHtml = '<div style="background:#fff3cd;padding:12px 30px;border-bottom:1px solid #dee2e6"><strong>Rollback:</strong> <code>' + $RollbackFile + '</code></div>' }
    $rowsHtml = ''
    $lastTier = ''
    foreach ($r in ($Results | Sort-Object { switch ($_.Tier) { 'Mandatory' { 0 } 'Recommended' { 1 } 'Optional' { 2 } default { 3 } } })) {
        if ($r.Tier -ne $lastTier) {
            if ($lastTier -ne '') { $rowsHtml += '</tbody></table></div>' }
            $lastTier = $r.Tier
            $tierClass = $lastTier.ToLower()
            $rowsHtml += '<div class="tier-header tier-' + $tierClass + '">' + $lastTier + ' Tier</div><div class="section"><table><thead><tr><th>CIS</th><th>Control</th><th>Setting</th><th>Current</th><th>Target</th><th>Severity</th><th>Status</th></tr></thead><tbody>'
        }
        $rowClass = 'noncompliant'; $badge = '<span class="badge badge-noncompliant">Non-Compliant</span>'
        if ($r.Excluded) { $rowClass = 'excluded'; $badge = '<span class="badge badge-excluded">Excluded</span>' }
        elseif ($r.Remediated) { $rowClass = 'remediated'; $badge = '<span class="badge badge-remediated">Remediated</span>' }
        elseif ($r.IsCompliant) { $rowClass = 'compliant'; $badge = '<span class="badge badge-compliant">Compliant</span>' }
        $curHtml = if ($null -ne $r.CurrentValue -and "$($r.CurrentValue)" -ne '') { '<code>' + $r.CurrentValue + '</code>' } else { '<em style="color:#999">null</em>' }
        $sevClass = 'severity-' + $r.Severity.ToLower()
        $rowsHtml += '<tr class="' + $rowClass + '"><td><strong>' + $r.CisId + '</strong></td><td>' + $r.Title + '</td><td><code>' + $r.Setting + '</code></td><td>' + $curHtml + '</td><td><code>' + $r.TargetValue + '</code></td><td class="' + $sevClass + '">' + $r.Severity + '</td><td>' + $badge + '</td></tr>'
    }
    if ($lastTier -ne '') { $rowsHtml += '</tbody></table></div>' }
    $css = '*{box-sizing:border-box;margin:0;padding:0}body{font-family:Segoe UI,sans-serif;background:#f5f5f5;padding:20px}.container{max-width:1200px;margin:0 auto;background:#fff;border-radius:8px;overflow:hidden}.header{background:#0078d4;color:#fff;padding:25px}.summary{display:flex;gap:15px;padding:20px;background:#f8f9fa}.stat{flex:1;text-align:center;padding:15px;background:#fff;border-radius:8px}.stat-value{font-size:2em;font-weight:bold}.stat-compliant .stat-value{color:#28a745}.stat-noncompliant .stat-value{color:#dc3545}.stat-remediated .stat-value{color:#0078d4}.tier-header{padding:12px 20px;color:#fff;font-weight:bold}.tier-mandatory{background:#dc3545}.tier-recommended{background:#fd7e14}.tier-optional{background:#6c757d}.section{padding:0 20px 20px}table{width:100%;border-collapse:collapse;margin-top:12px}th,td{padding:8px;border:1px solid #dee2e6;text-align:left}th{background:#f8f9fa}.compliant{background:#d4edda}.noncompliant{background:#f8d7da}.remediated{background:#cce5ff}.excluded{background:#fff3cd}.severity-critical{color:#dc3545;font-weight:bold}.severity-high{color:#e85600}.severity-medium{color:#b38600}.severity-low{color:#28a745}.badge{display:inline-block;padding:3px 8px;border-radius:4px;font-size:.8em}.badge-compliant{background:#28a745;color:#fff}.badge-noncompliant{background:#dc3545;color:#fff}.badge-remediated{background:#0078d4;color:#fff}.badge-excluded{background:#ffc107}code{background:#e9ecef;padding:2px 5px;border-radius:3px}.footer{padding:15px;background:#f8f9fa;text-align:center;color:#666}'
    $html = '<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Teams CIS Report - ' + $TenantName + '</title><style>' + $css + '</style></head><body><div class="container"><div class="header"><h1>Teams CIS Hardening Report</h1><p>Tenant: ' + $TenantName + ' | Generated: ' + $timestamp + ' | Script: v' + $scriptVer + '</p></div>' + $rollbackHtml + '<div class="summary"><div class="stat stat-compliant"><div class="stat-value">' + $compliant + '</div><div>Compliant</div></div><div class="stat stat-noncompliant"><div class="stat-value">' + $nonCompliant + '</div><div>Non-Compliant</div></div><div class="stat stat-remediated"><div class="stat-value">' + $remediated + '</div><div>Remediated</div></div><div class="stat"><div class="stat-value">' + $pct + '%</div><div>Compliance</div></div></div>' + $rowsHtml + '<div class="footer">CIS Microsoft 365 Foundations Benchmark | v' + $scriptVer + '</div></div></body></html>'
    $file = Join-Path $OutputPath ('Teams_CIS_Report_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.html')
    $html | Out-File -FilePath $file -Encoding UTF8
    Write-Log "Report saved: $file"
    return $file
}

function Show-MainMenu {
    Clear-Host
    Write-Host ''
    Write-Host '  +========================================================================+' -ForegroundColor Cyan
    Write-Host '  |           TEAMS CIS HARDENING - INTERACTIVE SECURITY TOOL             |' -ForegroundColor Cyan
    Write-Host '  +========================================================================+' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Connected Tenant: ' -NoNewline
    Write-Host $script:TenantName -ForegroundColor Green
    Write-Host "  Script Version:   v$($script:Version)"
    Write-Host "  Report Location:  $ReportPath" -ForegroundColor Gray
    Write-Host ''
    Write-Host '  ------------------------------------------------------------------------' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  [1] ' -NoNewline -ForegroundColor Cyan
    Write-Host 'Assessment & Report'
    Write-Host '      Scan current settings and generate compliance report. No changes made.'
    Write-Host ''
    Write-Host '  [2] ' -NoNewline -ForegroundColor Green
    Write-Host 'Guided Remediation'
    Write-Host '      Review all non-compliant controls with impact details, then select.'
    Write-Host ''
    Write-Host '  [3] ' -NoNewline -ForegroundColor Yellow
    Write-Host 'Create Snapshot'
    Write-Host '      Save current state as a restore point before making changes.'
    Write-Host ''
    Write-Host '  [4] ' -NoNewline -ForegroundColor Magenta
    Write-Host 'Rollback Changes'
    Write-Host '      Restore settings from a previous snapshot file.'
    Write-Host ''
    Write-Host '  [?] ' -NoNewline -ForegroundColor White
    Write-Host 'FAQ & Information'
    Write-Host '      Learn about snapshots, remediation files, and best practices.'
    Write-Host ''
    Write-Host '  [Q] ' -NoNewline -ForegroundColor Red
    Write-Host 'Quit'
    Write-Host ''
    Write-Host '  ------------------------------------------------------------------------' -ForegroundColor Gray
    Write-Host ''
    $choice = Read-Host '  Enter selection'
    return $choice.Trim().ToUpper()
}

function Show-FAQ {
    Clear-Host
    Write-Host ''
    Write-Host '  +========================================================================+' -ForegroundColor Cyan
    Write-Host '  |                    TEAMS CIS HARDENING - FAQ & INFO                   |' -ForegroundColor Cyan
    Write-Host '  +========================================================================+' -ForegroundColor Cyan
    Write-Host ''
    
    $selection = $null
    do {
        Write-Host '  Select a topic:' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '    [1] What are Snapshots vs Remediation files?' -ForegroundColor Cyan
        Write-Host '    [2] Where are files saved?' -ForegroundColor Cyan
        Write-Host '    [3] How do I attach files to ConnectWise?' -ForegroundColor Cyan
        Write-Host '    [4] What if remediation fails or I need to undo changes?' -ForegroundColor Cyan
        Write-Host '    [5] Understanding permission errors' -ForegroundColor Cyan
        Write-Host '    [6] Best practices for CIS hardening' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '    [B] Back to main menu' -ForegroundColor Gray
        Write-Host ''
        $selection = Read-Host '  Enter selection'
        
        Clear-Host
        Write-Host ''
        
        switch ($selection.ToUpper()) {
            '1' {
                Write-Host '  SNAPSHOTS vs REMEDIATION FILES' -ForegroundColor Yellow
                Write-Host '  =========================================================================' -ForegroundColor Gray
                Write-Host ''
                Write-Host '  SNAPSHOT (Full System State):' -ForegroundColor Green
                Write-Host '    - Filename: Teams_Snapshot_[timestamp].json' -ForegroundColor Cyan
                Write-Host '    - Contains: ALL 20 CIS control settings (current state at time of creation)' -ForegroundColor Cyan
                Write-Host '    - Use Case: Create BEFORE making any changes as a complete restore point' -ForegroundColor Cyan
                Write-Host '    - Size: Large (all settings captured)' -ForegroundColor Cyan
                Write-Host '    - Rollback Effect: Restores system to exact state when snapshot was created' -ForegroundColor Cyan
                Write-Host ''
                Write-Host '  REMEDIATION (Targeted Changes):' -ForegroundColor Cyan
                Write-Host '    - Filename: Teams_Remediation_[timestamp].json' -ForegroundColor White
                Write-Host '    - Contains: ONLY the settings that were changed during remediation' -ForegroundColor White
                Write-Host '    - Use Case: Auto-created during Guided Remediation to track changes' -ForegroundColor White
                Write-Host '    - Size: Small (only changed settings)' -ForegroundColor White
                Write-Host '    - Rollback Effect: Reverts only the changes made, leaves other settings intact' -ForegroundColor White
                Write-Host ''
                Write-Host '  EXAMPLE WORKFLOW:' -ForegroundColor Yellow
                Write-Host '    1. Create Snapshot (menu option 3)' -ForegroundColor Cyan
                Write-Host '       -> Teams_Snapshot_20260601_120000.json' -ForegroundColor Gray
                Write-Host ''
                Write-Host '    2. Run Guided Remediation (menu option 2)' -ForegroundColor Cyan
                Write-Host '       -> Auto-creates Teams_Remediation_20260601_120500.json' -ForegroundColor Gray
                Write-Host '       -> Applies 5 changes' -ForegroundColor Gray
                Write-Host ''
                Write-Host '    3. If something goes wrong, use Rollback (menu option 4)' -ForegroundColor Cyan
                Write-Host '       -> Option A: Restore Teams_Remediation_... to revert just the changes' -ForegroundColor Gray
                Write-Host '       -> Option B: Restore Teams_Snapshot_... to go back to original state' -ForegroundColor Gray
                Write-Host ''
                Write-Host '  RECOMMENDATION:' -ForegroundColor Yellow
                Write-Host '    Always create a Snapshot BEFORE running remediation!' -ForegroundColor Yellow
                Write-Host ''
            }
            '2' {
                Write-Host '  FILE LOCATIONS & STORAGE' -ForegroundColor Yellow
                Write-Host '  =========================================================================' -ForegroundColor Gray
                Write-Host ''
                Write-Host "  All files are saved to: $ReportPath" -ForegroundColor Cyan
                Write-Host ''
                Write-Host '  File Types:' -ForegroundColor White
                Write-Host '    - Teams_Snapshot_[timestamp].json       (Full state backups)' -ForegroundColor Green
                Write-Host '    - Teams_Remediation_[timestamp].json    (Change rollback files)' -ForegroundColor Cyan
                Write-Host '    - Teams_CIS_Report_[timestamp].html     (Compliance reports)' -ForegroundColor Blue
                Write-Host '    - Set-TeamsHardening_[timestamp].log    (Execution logs)' -ForegroundColor Gray
                Write-Host ''
                Write-Host '  File Retention:' -ForegroundColor White
                Write-Host '    - Keep snapshots and remediation files for at least 30 days' -ForegroundColor Yellow
                Write-Host '    - Store files securely (they contain configuration details)' -ForegroundColor Yellow
                Write-Host '    - Archive to ticket records as documentation' -ForegroundColor Yellow
                Write-Host ''
                Write-Host '  To Access Files:' -ForegroundColor White
                Write-Host "    1. Open File Explorer" -ForegroundColor Cyan
                Write-Host "    2. Navigate to: $ReportPath" -ForegroundColor Cyan
                Write-Host '    3. All script-generated files will be there' -ForegroundColor Cyan
                Write-Host ''
            }
            '3' {
                Write-Host '  ATTACHING FILES TO CONNECTWISE TICKETS' -ForegroundColor Yellow
                Write-Host '  =========================================================================' -ForegroundColor Gray
                Write-Host ''
                Write-Host '  WHY ATTACH FILES:' -ForegroundColor Cyan
                Write-Host '    - Document what changes were made' -ForegroundColor White
                Write-Host '    - Provide rollback capability if needed' -ForegroundColor White
                Write-Host '    - Maintain audit trail for compliance' -ForegroundColor White
                Write-Host '    - Help support team troubleshoot issues' -ForegroundColor White
                Write-Host ''
                Write-Host '  WHICH FILES TO ATTACH:' -ForegroundColor Yellow
                Write-Host '    ALWAYS attach:' -ForegroundColor White
                Write-Host '      1. Teams_CIS_Report_[timestamp].html' -ForegroundColor Green
                Write-Host '         (Shows compliance status - pre and post remediation)' -ForegroundColor Gray
                Write-Host ''
                Write-Host '    ALSO attach when making changes:' -ForegroundColor White
                Write-Host '      2. Teams_Remediation_[timestamp].json' -ForegroundColor Cyan
                Write-Host '         (Allows reverting changes if needed)' -ForegroundColor Gray
                Write-Host ''
                Write-Host '    OPTIONAL (for reference):' -ForegroundColor White
                Write-Host '      3. Set-TeamsHardening_[timestamp].log' -ForegroundColor Gray
                Write-Host '         (Execution log for troubleshooting)' -ForegroundColor Gray
                Write-Host ''
                Write-Host '  CONNECTWISE ATTACHMENT STEPS:' -ForegroundColor Cyan
                Write-Host '    1. Open the ConnectWise ticket' -ForegroundColor White
                Write-Host '    2. Go to the Documents/Attachments section' -ForegroundColor White
                Write-Host '    3. Click "Add Document" or "Attach File"' -ForegroundColor White
                Write-Host '    4. Browse to: ' -NoNewline -ForegroundColor White
                Write-Host $ReportPath -ForegroundColor Cyan
                Write-Host '    5. Select the report and remediation files' -ForegroundColor White
                Write-Host '    6. Add a note: "CIS Hardening Assessment/Remediation - see attached"' -ForegroundColor White
                Write-Host ''
                Write-Host '  NAMING CONVENTION:' -ForegroundColor Yellow
                Write-Host '    - Keep original filenames (they include timestamp)' -ForegroundColor White
                Write-Host '    - Timestamp helps identify which run generated the file' -ForegroundColor White
                Write-Host '    - Multiple runs create multiple files for version control' -ForegroundColor White
                Write-Host ''
            }
            '4' {
                Write-Host '  FAILURE & ROLLBACK PROCEDURES' -ForegroundColor Yellow
                Write-Host '  =========================================================================' -ForegroundColor Gray
                Write-Host ''
                Write-Host '  REMEDIATION FAILED OR PARTIALLY APPLIED:' -ForegroundColor Red
                Write-Host ''
                Write-Host '    Steps:' -ForegroundColor Cyan
                Write-Host '    1. Run this script again' -ForegroundColor White
                Write-Host '    2. Go to Menu Option [4] - Rollback Changes' -ForegroundColor White
                Write-Host '    3. Select the most recent Teams_Remediation_[timestamp].json file' -ForegroundColor White
                Write-Host '    4. Confirm rollback - this will revert ALL changes from that session' -ForegroundColor White
                Write-Host ''
                Write-Host '  NEED TO RESTORE FULL SYSTEM STATE:' -ForegroundColor Yellow
                Write-Host ''
                Write-Host '    Steps:' -ForegroundColor Cyan
                Write-Host '    1. Run this script again' -ForegroundColor White
                Write-Host '    2. Go to Menu Option [4] - Rollback Changes' -ForegroundColor White
                Write-Host '    3. Look for Teams_Snapshot_[timestamp].json (shows [Snapshot] label)' -ForegroundColor White
                Write-Host '    4. Select the snapshot file to restore ALL settings to that point in time' -ForegroundColor White
                Write-Host ''
                Write-Host '  IF ROLLBACK ALSO FAILS:' -ForegroundColor Red
                Write-Host ''
                Write-Host '    This indicates possible permission issues:' -ForegroundColor Yellow
                Write-Host '    1. Check your Teams Administrator role is active' -ForegroundColor Cyan
                Write-Host '    2. Try signing out and back in (role cache refresh)' -ForegroundColor Cyan
                Write-Host '    3. Contact Global Admin if you have Teams Service Administrator role' -ForegroundColor Cyan
                Write-Host '    4. Attach the rollback file to the ConnectWise ticket' -ForegroundColor Cyan
                Write-Host '    5. Request manual rollback by support team' -ForegroundColor Cyan
                Write-Host ''
            }
            '5' {
                Write-Host '  UNDERSTANDING PERMISSION ERRORS' -ForegroundColor Yellow
                Write-Host '  =========================================================================' -ForegroundColor Gray
                Write-Host ''
                Write-Host '  ERROR: "You are not authorized to perform this action" (code 40301)' -ForegroundColor Red
                Write-Host ''
                Write-Host '  Cause:' -ForegroundColor White
                Write-Host '    You do not have the required Azure AD role for this operation.' -ForegroundColor Cyan
                Write-Host ''
                Write-Host '  Common Scenarios:' -ForegroundColor Yellow
                Write-Host ''
                Write-Host '    Scenario 1: Cannot modify Meeting Policies' -ForegroundColor Red
                Write-Host '      - Error: Forbidden when trying to set AutoAdmittedUsers, etc.' -ForegroundColor Gray
                Write-Host '      - Required Role: Teams Service Administrator' -ForegroundColor Cyan
                Write-Host '      - Current Role: Likely Teams Administrator only' -ForegroundColor Yellow
                Write-Host '      - Solution: Contact Global Admin, request Teams Service Administrator' -ForegroundColor Green
                Write-Host ''
                Write-Host '    Scenario 2: Cannot modify Federation/Client Config' -ForegroundColor Red
                Write-Host '      - Error: Forbidden when changing AllowTeamsConsumer, etc.' -ForegroundColor Gray
                Write-Host '      - Required Role: Teams Service Administrator' -ForegroundColor Cyan
                Write-Host '      - Current Role: Need to verify with admin' -ForegroundColor Yellow
                Write-Host '      - Solution: Contact Global Admin' -ForegroundColor Green
                Write-Host ''
                Write-Host '  WHAT TO DO:' -ForegroundColor Green
                Write-Host '    1. Note which controls show permission errors' -ForegroundColor White
                Write-Host '    2. Attach the Teams_CIS_Report_*.html to ticket' -ForegroundColor White
                Write-Host '    3. Contact your Global Administrator' -ForegroundColor White
                Write-Host '    4. Request: "Teams Service Administrator role"' -ForegroundColor White
                Write-Host '    5. Wait 15-30 minutes for role to propagate' -ForegroundColor White
                Write-Host '    6. Sign out and back in' -ForegroundColor White
                Write-Host '    7. Run script again' -ForegroundColor White
                Write-Host ''
            }
            '6' {
                Write-Host '  BEST PRACTICES FOR CIS HARDENING' -ForegroundColor Yellow
                Write-Host '  =========================================================================' -ForegroundColor Gray
                Write-Host ''
                Write-Host '  BEFORE YOU START:' -ForegroundColor Green
                Write-Host '    1. Read all control descriptions in the Guided Remediation' -ForegroundColor Cyan
                Write-Host '    2. Understand Business Impact for each control' -ForegroundColor Cyan
                Write-Host '    3. Consider which controls affect your organization' -ForegroundColor Cyan
                Write-Host ''
                Write-Host '  STEP 1: ASSESSMENT' -ForegroundColor Green
                Write-Host '    - Run Assessment & Report (menu option 1)' -ForegroundColor Cyan
                Write-Host '    - Review the HTML report to see current compliance' -ForegroundColor Cyan
                Write-Host '    - Share report with stakeholders' -ForegroundColor Cyan
                Write-Host ''
                Write-Host '  STEP 2: PLAN' -ForegroundColor Green
                Write-Host '    - Decide which controls to implement' -ForegroundColor Cyan
                Write-Host '    - Consider: mandatory vs optional vs safe selection' -ForegroundColor Cyan
                Write-Host '    - Identify business process impacts' -ForegroundColor Cyan
                Write-Host ''
                Write-Host '  STEP 3: SNAPSHOT' -ForegroundColor Green
                Write-Host '    - Create a Snapshot BEFORE any changes (menu option 3)' -ForegroundColor Cyan
                Write-Host '    - Store snapshot file in ConnectWise ticket' -ForegroundColor Cyan
                Write-Host ''
                Write-Host '  STEP 4: REMEDIATE' -ForegroundColor Green
                Write-Host '    - Use Guided Remediation (menu option 2)' -ForegroundColor Cyan
                Write-Host '    - Review before/after impacts' -ForegroundColor Cyan
                Write-Host '    - Apply changes incrementally if possible' -ForegroundColor Cyan
                Write-Host ''
                Write-Host '  STEP 5: VALIDATE' -ForegroundColor Green
                Write-Host '    - Test affected Teams functionality' -ForegroundColor Cyan
                Write-Host '    - Verify no unintended side effects' -ForegroundColor Cyan
                Write-Host '    - Communicate changes to users if needed' -ForegroundColor Cyan
                Write-Host ''
                Write-Host '  STEP 6: DOCUMENT' -ForegroundColor Green
                Write-Host '    - Attach report to ConnectWise ticket' -ForegroundColor Cyan
                Write-Host '    - Attach remediation file (for rollback capability)' -ForegroundColor Cyan
                Write-Host '    - Document any manual follow-ups needed' -ForegroundColor Cyan
                Write-Host ''
                Write-Host '  TROUBLESHOOTING TIPS:' -ForegroundColor Yellow
                Write-Host '    - Keep multiple snapshots for different compliance levels' -ForegroundColor Cyan
                Write-Host '    - If one control fails, others may still succeed' -ForegroundColor Cyan
                Write-Host '    - Permission errors can be retried after role propagation' -ForegroundColor Cyan
                Write-Host '    - Always test in lower environment first if available' -ForegroundColor Cyan
                Write-Host ''
            }
            'B' {
                return
            }
            default {
                Write-Host '  Invalid selection. Please try again.' -ForegroundColor Yellow
                Write-Host ''
                Read-Host '  Press Enter'
                Clear-Host
                Write-Host ''
            }
        }
        
        if ($selection -ne 'B') {
            Write-Host ''
            Read-Host '  Press Enter to continue'
            Clear-Host
            Write-Host ''
        }
    } while ($selection -ne 'B')
}

function Invoke-Assessment {
    Write-Banner 'Assessment & Report' 'Cyan'
    $config = Get-CurrentConfig
    Write-Host '  Evaluating CIS compliance...' -ForegroundColor Cyan
    Write-Host ''
    $results = @()
    foreach ($control in $CISControls) {
        $isExcluded = $ExcludeControls -contains $control.CisId
        $compliance = Test-TeamsCompliance -Control $control -Config $config
        $results += [PSCustomObject]@{ CisId = $control.CisId; Tier = $control.Tier; Title = $control.Title; Severity = $control.Severity; Setting = $control.Setting; Cmdlet = $control.Cmdlet; PolicyIdentity = $control.PolicyIdentity; CurrentValue = $compliance.CurrentValue; TargetValue = $compliance.TargetValue; IsCompliant = $compliance.IsCompliant; Excluded = $isExcluded; Remediated = $false }
        $icon = if ($isExcluded) { '[SKIP]' } elseif ($compliance.IsCompliant) { '[ OK ]' } else { '[ X  ]' }
        $color = if ($isExcluded) { 'Yellow' } elseif ($compliance.IsCompliant) { 'Green' } else { 'Red' }
        Write-Host "    $icon $($control.CisId) $($control.Title)" -ForegroundColor $color
    }
    $compliant = @($results | Where-Object { $_.IsCompliant -and -not $_.Excluded }).Count
    $nonCompliant = @($results | Where-Object { -not $_.IsCompliant -and -not $_.Excluded }).Count
    $pct = if ($results.Count -gt 0) { [math]::Round(($compliant / $results.Count) * 100, 1) } else { 0 }
    Write-Host ''
    Write-Host "  Summary: $compliant compliant, $nonCompliant non-compliant ($pct%)" -ForegroundColor Cyan
    $reportFile = Export-HtmlReport -Results $results -TenantName $script:TenantName -OutputPath $ReportPath -RollbackFile $null
    Write-Host ''
    Write-Host "  Report saved: $reportFile" -ForegroundColor Green
    Write-Host ''
    $open = Read-Host '  Open report in browser? (Y/N)'
    if ($open -match '^[Yy]') { Start-Process $reportFile }
    Write-Host ''
    Read-Host '  Press Enter to return to menu'
}

function Invoke-GuidedRemediation {
    Write-Banner 'Guided Remediation' 'Green'
    $config = Get-CurrentConfig
    $results = @()
    $nonCompliantItems = @()
    
    # Identify which cmdlets have insufficient permissions
    $insufficientCmdlets = @()
    if (-not $script:HasMeetingPolicyPermission) {
        $insufficientCmdlets += 'Set-CsTeamsMeetingPolicy'
    }
    
    foreach ($control in $CISControls) {
        $isExcluded = $ExcludeControls -contains $control.CisId
        $compliance = Test-TeamsCompliance -Control $control -Config $config
        $result = [PSCustomObject]@{ 
            CisId = $control.CisId
            Tier = $control.Tier
            Title = $control.Title
            Severity = $control.Severity
            Setting = $control.Setting
            Cmdlet = $control.Cmdlet
            PolicyIdentity = $control.PolicyIdentity
            CurrentValue = $compliance.CurrentValue
            TargetValue = $compliance.TargetValue
            IsCompliant = $compliance.IsCompliant
            Excluded = $isExcluded
            Remediated = $false
            SecurityBenefit = $control.SecurityBenefit
            BusinessImpact = $control.BusinessImpact
            RiskIfIgnored = $control.RiskIfIgnored
            RequiresElevatedPermission = $insufficientCmdlets -contains $control.Cmdlet
        }
        if (-not $compliance.IsCompliant -and -not $isExcluded) { $nonCompliantItems += $result }
        $results += $result
    }
    
    if ($nonCompliantItems.Count -eq 0) {
        Write-Host ''
        Write-Host '  All controls are compliant! No remediation needed.' -ForegroundColor Green
        Write-Host ''
        Read-Host '  Press Enter to return to menu'
        return
    }
    
    # Identify which controls have insufficient permissions
    $insufficientPermissionCisIds = @($nonCompliantItems | Where-Object { $_.RequiresElevatedPermission } | ForEach-Object { $_.CisId })
    
    Write-Host ''
    Write-Host "  Found $($nonCompliantItems.Count) NON-COMPLIANT control(s):" -ForegroundColor Yellow
    if ($insufficientPermissionCisIds.Count -gt 0) {
        Write-Host "  ($($insufficientPermissionCisIds.Count) require additional permissions for Teams Service Administrator)" -ForegroundColor Yellow
    }
    
    Show-DetailedControlList -Items $nonCompliantItems -InsufficientPermissionCisIds $insufficientPermissionCisIds
    
    $selectedItems = @()
    do {
        $selInput = Show-SelectionMenu -Items $nonCompliantItems -InsufficientPermissionCisIds $insufficientPermissionCisIds
        
        if ($selInput -eq 'none') {
            Write-Host ''
            Write-Host '  No controls selected. Returning to menu.' -ForegroundColor Yellow
            Write-Host ''
            Read-Host '  Press Enter'
            return
        }
        
        [array]$selIndices = Resolve-Selection -Selection $selInput -Items $nonCompliantItems
        [int]$count = if ($null -eq $selIndices) { 0 } else { @($selIndices).Count }
        
        if ($count -eq 0) {
            Write-Host ''
            Write-Host '  Invalid selection or no controls matched. Please try again.' -ForegroundColor Yellow
            Write-Host ''
            continue
        }
        
        $selectedItems = @()
        foreach ($idx in $selIndices) { 
            $selectedItems += $nonCompliantItems[$idx - 1] 
        }
        
        break
    } while ($true)
    
    Write-Host ''
    Write-Banner "Remediation Preview - $($selectedItems.Count) Changes" 'Yellow'
    Write-Host ''
    
    # Separate items that can be applied vs need permissions
    $canApply = @($selectedItems | Where-Object { -not $_.RequiresElevatedPermission })
    $needPermissions = @($selectedItems | Where-Object { $_.RequiresElevatedPermission })
    
    if ($needPermissions.Count -gt 0) {
        Write-Host '  INSUFFICIENT PERMISSIONS - Cannot Apply:' -ForegroundColor Red
        Write-Host '  ===================================================================================' -ForegroundColor Red
        Write-Host ''
        $i = 1
        foreach ($item in $needPermissions) {
            $tierColor = switch ($item.Tier) { 'Mandatory' { 'Red' } 'Recommended' { 'Yellow' } default { 'Gray' } }
            $sevColor = switch ($item.Severity) { 'CRITICAL' { 'Magenta' } 'High' { 'Red' } 'Medium' { 'Yellow' } default { 'Green' } }
            
            Write-Host ''
            Write-Host "  $($i.ToString().PadLeft(2))  " -NoNewline -ForegroundColor Cyan
            Write-Host "$($item.CisId.PadRight(7))" -NoNewline -ForegroundColor White
            Write-Host "$($item.Tier.PadRight(13))" -NoNewline -ForegroundColor $tierColor
            Write-Host "$($item.Severity.PadRight(10))" -NoNewline -ForegroundColor $sevColor
            Write-Host $item.Setting
            
            $curVal = if ($null -eq $item.CurrentValue) { '<not set>' } else { "$($item.CurrentValue)" }
            $tgtVal = "$($item.TargetValue)"
            $curDisplay = if ($curVal.Length -gt 30) { $curVal.Substring(0, 27) + '...' } else { $curVal }
            $tgtDisplay = if ($tgtVal.Length -gt 30) { $tgtVal.Substring(0, 27) + '...' } else { $tgtVal }
            
            Write-Host "      $($curDisplay.PadRight(35)) -> " -NoNewline -ForegroundColor Red
            Write-Host $tgtDisplay -ForegroundColor Green
            
            Write-Host '      [!] Requires: Teams Service Administrator role' -ForegroundColor Yellow
            $i++
        }
        Write-Host ''
        Write-Host '  ===================================================================================' -ForegroundColor Red
    }
    
    if ($canApply.Count -gt 0) {
        if ($needPermissions.Count -gt 0) {
            Write-Host ''
            Write-Host '  CAN APPLY - Sufficient Permissions:' -ForegroundColor Green
            Write-Host '  ===================================================================================' -ForegroundColor Green
        }
        
        Write-Host ''
        Write-Host '  BEFORE                              AFTER' -ForegroundColor White
        Write-Host '  ===================================================================================' -ForegroundColor Gray
        
        foreach ($item in $canApply) {
            $curVal = if ($null -eq $item.CurrentValue) { '<not set>' } else { "$($item.CurrentValue)" }
            $tgtVal = "$($item.TargetValue)"
            $curDisplay = if ($curVal.Length -gt 30) { $curVal.Substring(0, 27) + '...' } else { $curVal }
            $tgtDisplay = if ($tgtVal.Length -gt 30) { $tgtVal.Substring(0, 27) + '...' } else { $tgtVal }
            
            Write-Host "  [$($item.CisId)] " -NoNewline -ForegroundColor Cyan
            Write-Host "$($item.Setting)" -ForegroundColor White
            Write-Host "    $($curDisplay.PadRight(35)) -> " -NoNewline -ForegroundColor Red
            Write-Host $tgtDisplay -ForegroundColor Green
        }
        
        Write-Host ''
        Write-Host '  ===================================================================================' -ForegroundColor Gray
    }
    
    Write-Host ''
    if ($canApply.Count -gt 0) {
        Write-Host '  Summary (Can Apply):' -ForegroundColor Cyan
        foreach ($item in $canApply) {
            $tierColor = switch ($item.Tier) { 'Mandatory' { 'Red' } 'Recommended' { 'Yellow' } default { 'Gray' } }
            Write-Host "    [$($item.CisId)] " -NoNewline -ForegroundColor $tierColor
            Write-Host "$($item.Title)"
        }
    }
    
    if ($needPermissions.Count -gt 0) {
        Write-Host ''
        Write-Host '  Summary (Need Permissions):' -ForegroundColor Yellow
        foreach ($item in $needPermissions) {
            $tierColor = switch ($item.Tier) { 'Mandatory' { 'Red' } 'Recommended' { 'Yellow' } default { 'Gray' } }
            Write-Host "    [$($item.CisId)] " -NoNewline -ForegroundColor $tierColor
            Write-Host "$($item.Title) [Teams Service Administrator]" -ForegroundColor Yellow
        }
    }
    
    Write-Host ''
    
    if ($canApply.Count -eq 0) {
        Write-Host '  Cannot proceed - all selected controls require additional permissions.' -ForegroundColor Yellow
        Write-Host '  Contact your administrator to request Teams Service Administrator role.' -ForegroundColor Yellow
        Write-Host ''
        Read-Host '  Press Enter to return to menu'
        return
    }
    
    Write-Host '  A rollback file will be saved before applying changes.' -ForegroundColor Cyan
    Write-Host ''
    
    $confirm = Read-Host '  Apply these changes? (yes/no)'
    if ($confirm -notmatch '^(yes|y)$') {
        Write-Host ''
        Write-Host '  Cancelled.' -ForegroundColor Yellow
        Read-Host '  Press Enter to return to menu'
        return
    }
    
    Write-Host ''
    Write-Host '  Saving rollback...' -NoNewline
    $rollbackData = @()
    foreach ($item in $canApply) { 
        $rollbackData += @{ 
            CisId = $item.CisId
            Tier = $item.Tier
            Setting = $item.Setting
            Cmdlet = $item.Cmdlet
            PolicyIdentity = $item.PolicyIdentity
            PreviousValue = if ($null -eq $item.CurrentValue) { '' } else { "$($item.CurrentValue)" }
            NewValue = "$($item.TargetValue)" 
        } 
    }
    $rollbackFile = Export-RollbackConfig -RollbackData $rollbackData -TenantName $script:TenantName -OutputPath $ReportPath -FileType 'Remediation'
    Write-Host ' Done' -ForegroundColor Green
    Write-Host "    $rollbackFile" -ForegroundColor Cyan
    Write-Host ''
    
    Write-Host '  Applying changes:' -ForegroundColor Cyan
    $successCount = 0
    foreach ($item in $canApply) {
        Write-Host "    [$($item.CisId)] $($item.Setting) " -NoNewline
        $controlDef = $CISControls | Where-Object { $_.CisId -eq $item.CisId }
        $result = Set-ControlValue -Cmdlet $controlDef.Cmdlet -Setting $controlDef.Setting -Value $controlDef.TargetValue -PolicyIdentity $controlDef.PolicyIdentity
        if ($result.Success) { 
            Write-Host '[OK]' -ForegroundColor Green
            $successCount++
            foreach ($r in $results) { 
                if ($r.CisId -eq $item.CisId) { 
                    $r.Remediated = $true
                    $r.IsCompliant = $true 
                } 
            } 
        }
        else { 
            Write-Host "[FAILED] $($result.Error)" -ForegroundColor Red 
        }
    }
    
    Write-Host ''
    Write-Host "  Completed: $successCount of $($canApply.Count) succeeded" -ForegroundColor Cyan
    
    if ($needPermissions.Count -gt 0) {
        Write-Host ''
        Write-Host "  Skipped: $($needPermissions.Count) controls (insufficient permissions for Teams Service Administrator)" -ForegroundColor Yellow
        Write-Host '  To apply these controls, contact your administrator to request Teams Service Administrator role.' -ForegroundColor Yellow
    }
    
    $reportFile = Export-HtmlReport -Results $results -TenantName $script:TenantName -OutputPath $ReportPath -RollbackFile $rollbackFile
    Write-Host "  Report: $reportFile" -ForegroundColor Green
    Write-Host ''
    Read-Host '  Press Enter to return to menu'
}

function Invoke-Snapshot {
    Write-Banner 'Create Snapshot' 'Yellow'
    $config = Get-CurrentConfig
    Write-Host '  Capturing current state...' -ForegroundColor Cyan
    $snapshotData = @()
    foreach ($control in $CISControls) {
        $compliance = Test-TeamsCompliance -Control $control -Config $config
        $snapshotData += @{ 
            CisId = $control.CisId
            Tier = $control.Tier
            Setting = $control.Setting
            Cmdlet = $control.Cmdlet
            PolicyIdentity = $control.PolicyIdentity
            PreviousValue = if ($null -eq $compliance.CurrentValue) { '' } else { "$($compliance.CurrentValue)" }
            NewValue = "$($control.TargetValue)" 
        }
        Write-Host "    $($control.CisId) $($control.Setting) = $($compliance.CurrentValue)" -ForegroundColor Gray
    }
    $snapshotFile = Export-RollbackConfig -RollbackData $snapshotData -TenantName $script:TenantName -OutputPath $ReportPath -FileType 'Snapshot'
    Write-Host ''
    Write-Host "  Snapshot saved: $snapshotFile" -ForegroundColor Green
    Write-Host ''
    Read-Host '  Press Enter to return to menu'
}

function Invoke-Rollback {
    Write-Banner 'Rollback Changes' 'Magenta'
    $files = Get-ChildItem -Path $ReportPath -Filter 'Teams_*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    if ($files.Count -eq 0) {
        Write-Host ''
        Write-Host '  No rollback files found in: ' -NoNewline -ForegroundColor Yellow
        Write-Host $ReportPath
        Write-Host ''
        Read-Host '  Press Enter to return to menu'
        return
    }
    Write-Host ''
    Write-Host '  Available restore files:' -ForegroundColor Cyan
    Write-Host ''
    $i = 1
    $fileList = @()
    foreach ($f in $files) {
        try {
            $content = Get-Content $f.FullName -Raw | ConvertFrom-Json
            $fileType = if ($content.FileType) { $content.FileType } else { 'Unknown' }
            $fileTypeColor = if ($fileType -eq 'Snapshot') { 'Green' } else { 'Cyan' }
            
            $fileList += @{ File = $f; Content = $content; Type = $fileType }
            
            Write-Host "    [$i] " -NoNewline -ForegroundColor White
            Write-Host "[$fileType] " -NoNewline -ForegroundColor $fileTypeColor
            Write-Host "$($f.Name)"
            Write-Host "        Created: $($content.GeneratedAt) | Tenant: $($content.TenantName) | Changes: $($content.Changes.Count)" -ForegroundColor Gray
            
            if ($fileType -eq 'Snapshot') {
                Write-Host "        Type: Full system state snapshot" -ForegroundColor Green
            } else {
                Write-Host "        Type: Targeted remediation (only changed settings)" -ForegroundColor Cyan
            }
            
        } catch {
            Write-Host "    [$i] $($f.Name) (error reading)" -ForegroundColor Red
        }
        $i++
    }
    Write-Host ''
    Write-Host "    [C] Cancel"
    Write-Host ''
    $sel = Read-Host '  Select file number'
    if ($sel -match '^[Cc]') { return }
    $idx = 0
    if (-not [int]::TryParse($sel, [ref]$idx) -or $idx -lt 1 -or $idx -gt $fileList.Count) {
        Write-Host '  Invalid selection.' -ForegroundColor Red
        Read-Host '  Press Enter'
        return
    }
    
    $selectedEntry = $fileList[$idx - 1]
    $selectedFile = $selectedEntry.File
    $rollbackConfig = $selectedEntry.Content
    
    Write-Host ''
    Write-Host "  File:      $($selectedFile.Name)" -ForegroundColor Cyan
    Write-Host "  File Type: $($selectedEntry.Type)" -ForegroundColor $(if ($selectedEntry.Type -eq 'Snapshot') { 'Green' } else { 'Cyan' })
    Write-Host "  Tenant:    $($rollbackConfig.TenantName)"
    Write-Host "  Created:   $($rollbackConfig.GeneratedAt)"
    Write-Host "  Changes:   $($rollbackConfig.Changes.Count)"
    Write-Host ''
    
    if ($selectedEntry.Type -eq 'Snapshot') {
        Write-Host '  Snapshot Info:' -ForegroundColor Green
        Write-Host '    This is a FULL SYSTEM SNAPSHOT containing all 20 CIS control settings.' -ForegroundColor Green
        Write-Host '    Applying this will restore the system to the state when the snapshot was created.' -ForegroundColor Green
    } else {
        Write-Host '  Remediation Info:' -ForegroundColor Cyan
        Write-Host '    This is a TARGETED REMEDIATION containing only the changed settings.' -ForegroundColor Cyan
        Write-Host '    Applying this will revert only the changes made during remediation.' -ForegroundColor Cyan
    }
    
    Write-Host ''
    Write-Host '  Settings to restore:' -ForegroundColor Yellow
    foreach ($change in $rollbackConfig.Changes) {
        Write-Host "    [$($change.CisId)] $($change.Setting)" -ForegroundColor Gray
        if ([string]::IsNullOrWhiteSpace($change.PreviousValue)) {
            Write-Host "      Previous: <was not set>" -ForegroundColor Gray
        } else {
            Write-Host "      Previous: $($change.PreviousValue)" -ForegroundColor Gray
        }
    }
    Write-Host ''
    if ($script:TenantName -ne $rollbackConfig.TenantName) {
        Write-Host '  WARNING: Tenant mismatch!' -ForegroundColor Yellow
        Write-Host "    Connected: $($script:TenantName)"
        Write-Host "    File:      $($rollbackConfig.TenantName)"
        Write-Host ''
    }
    $confirm = Read-Host '  Apply rollback? (yes/no)'
    if ($confirm -notmatch '^(yes|y)$') {
        Write-Host '  Cancelled.' -ForegroundColor Yellow
        Read-Host '  Press Enter'
        return
    }
    Write-Host ''
    Write-Host '  Applying rollback:' -ForegroundColor Cyan
    $successCount = 0
    $skippedCount = 0
    foreach ($change in $rollbackConfig.Changes) {
        Write-Host "    [$($change.CisId)] $($change.Setting) " -NoNewline
        
        $restoreValue = $change.PreviousValue
        if ([string]::IsNullOrWhiteSpace($restoreValue)) {
            Write-Host "[SKIPPED - was null/empty]" -ForegroundColor Yellow
            $skippedCount++
            continue
        }
        
        if ($restoreValue -eq 'True') { $restoreValue = $true }
        elseif ($restoreValue -eq 'False') { $restoreValue = $false }
        
        $result = Set-ControlValue -Cmdlet $change.Cmdlet -Setting $change.Setting -Value $restoreValue -PolicyIdentity $change.PolicyIdentity
        if ($result.Success) { Write-Host '[OK]' -ForegroundColor Green; $successCount++ }
        else { Write-Host "[FAILED] $($result.Error)" -ForegroundColor Red }
    }
    Write-Host ''
    Write-Host "  Rollback complete: $successCount restored" -NoNewline -ForegroundColor Green
    if ($skippedCount -gt 0) { Write-Host ", $skippedCount skipped (were null)" -ForegroundColor Yellow } else { Write-Host '' }
    Write-Host ''
    Read-Host '  Press Enter to return to menu'
}

function Test-RequiredPermissions {
    Write-Banner 'Checking Required Permissions' 'Cyan'
    Write-Host ''
    Write-Host '  Testing permissions and parameter validity...' -ForegroundColor Cyan
    Write-Host ''
    
    # Define cmdlet permissions and required roles
    $cmdletRequirements = @{
        'Set-CsTenantFederationConfiguration' = @{
            RequiredRole = 'Teams Service Administrator'
            Controls = @()
        }
        'Set-CsTeamsClientConfiguration' = @{
            RequiredRole = 'Teams Administrator'
            Controls = @()
        }
        'Set-CsTeamsMeetingPolicy' = @{
            RequiredRole = 'Teams Service Administrator'
            Controls = @()
        }
        'Set-CsTeamsMessagingPolicy' = @{
            RequiredRole = 'Teams Administrator'
            Controls = @()
        }
    }
    
    # Group controls by cmdlet
    foreach ($control in $CISControls) {
        $cmdlet = $control.Cmdlet
        if ($cmdletRequirements.ContainsKey($cmdlet)) {
            $cmdletRequirements[$cmdlet].Controls += @{
                CisId = $control.CisId
                Setting = $control.Setting
                Title = $control.Title
            }
        }
    }
    
    $allPermissionsValid = $true
    $failedCmdlets = @()
    $invalidParameters = @()
    $insufficientRoles = @()
    
    # Test each cmdlet
    foreach ($cmdlet in $cmdletRequirements.Keys) {
        $requirements = $cmdletRequirements[$cmdlet]
        Write-Host "  Testing: $cmdlet" -NoNewline -ForegroundColor White
        
        try {
            # Try to get current config to test permissions
            $config = $null
            switch ($cmdlet) {
                'Set-CsTenantFederationConfiguration' {
                    $config = Get-CsTenantFederationConfiguration -ErrorAction Stop
                }
                'Set-CsTeamsClientConfiguration' {
                    $config = Get-CsTeamsClientConfiguration -ErrorAction Stop
                }
                'Set-CsTeamsMeetingPolicy' {
                    $config = Get-CsTeamsMeetingPolicy -Identity Global -ErrorAction Stop
                }
                'Set-CsTeamsMessagingPolicy' {
                    $config = Get-CsTeamsMessagingPolicy -Identity Global -ErrorAction Stop
                }
            }
            
            # Test that all settings exist as properties
            $missingProps = @()
            foreach ($control in $requirements.Controls) {
                if ($config -and -not ($config.PSObject.Properties.Name -contains $control.Setting)) {
                    $missingProps += @{
                        CisId = $control.CisId
                        Setting = $control.Setting
                        Title = $control.Title
                    }
                }
            }
            
            if ($missingProps.Count -gt 0) {
                Write-Host ' [INVALID PARAMETERS]' -ForegroundColor Yellow
                $invalidParameters += @{
                    Cmdlet = $cmdlet
                    MissingProperties = $missingProps
                }
                $allPermissionsValid = $false
            } else {
                # Do a WRITE TEST to verify actual write permission
                Write-Host ' (testing write permission)' -NoNewline -ForegroundColor Gray
                try {
                    switch ($cmdlet) {
                        'Set-CsTenantFederationConfiguration' {
                            $originalValue = $config.AllowTeamsConsumer
                            Set-CsTenantFederationConfiguration -AllowTeamsConsumer $originalValue -Identity Global -ErrorAction Stop
                        }
                        'Set-CsTeamsClientConfiguration' {
                            $originalValue = $config.AllowEmailIntoChannel
                            Set-CsTeamsClientConfiguration -AllowEmailIntoChannel $originalValue -Identity Global -ErrorAction Stop
                        }
                        'Set-CsTeamsMeetingPolicy' {
                            $originalValue = $config.AllowAnonymousUsersToStartMeeting
                            Set-CsTeamsMeetingPolicy -Identity Global -AllowAnonymousUsersToStartMeeting $originalValue -ErrorAction Stop
                        }
                        'Set-CsTeamsMessagingPolicy' {
                            $originalValue = $config.AllowSecurityEndUserReporting
                            Set-CsTeamsMessagingPolicy -Identity Global -AllowSecurityEndUserReporting $originalValue -ErrorAction Stop
                        }
                    }
                    Write-Host ' [OK]' -ForegroundColor Green
                } catch {
                    $errorMsg = $_.Exception.Message
                    
                    if ($errorMsg -like '*Forbidden*' -or $errorMsg -like '*not authorized*' -or $errorMsg -like '*40301*') {
                        Write-Host ' [INSUFFICIENT ROLE]' -ForegroundColor Yellow
                        $insufficientRoles += @{
                            Cmdlet = $cmdlet
                            RequiredRole = $requirements.RequiredRole
                            Controls = $requirements.Controls
                            Error = $errorMsg
                        }
                        $allPermissionsValid = $false
                    } else {
                        Write-Host ' [FAILED]' -ForegroundColor Red
                        $failedCmdlets += @{
                            Cmdlet = $cmdlet
                            Error = $errorMsg
                            Controls = $requirements.Controls
                        }
                        $allPermissionsValid = $false
                    }
                }
            }
        }
        catch {
            $errorMsg = $_.Exception.Message
            
            if ($errorMsg -like '*Forbidden*' -or $errorMsg -like '*not authorized*' -or $errorMsg -like '*40301*') {
                Write-Host ' [INSUFFICIENT ROLE]' -ForegroundColor Yellow
                $insufficientRoles += @{
                    Cmdlet = $cmdlet
                    RequiredRole = $requirements.RequiredRole
                    Controls = $requirements.Controls
                    Error = $errorMsg
                }
                $allPermissionsValid = $false
            } else {
                Write-Host ' [FAILED]' -ForegroundColor Red
                $failedCmdlets += @{
                    Cmdlet = $cmdlet
                    Error = $errorMsg
                    Controls = $requirements.Controls
                }
                $allPermissionsValid = $false
            }
        }
    }
    
    Write-Host ''
    
    if ($allPermissionsValid) {
        Write-Host '  All permissions validated successfully!' -ForegroundColor Green
        Write-Host ''
        Write-Host '  You have permission to modify:' -ForegroundColor Green
        foreach ($cmdlet in $cmdletRequirements.Keys) {
            $count = $cmdletRequirements[$cmdlet].Controls.Count
            $role = $cmdletRequirements[$cmdlet].RequiredRole
            Write-Host "    + $cmdlet ($count control(s))" -ForegroundColor Green
            Write-Host "      Required Role: $role" -ForegroundColor Cyan
        }
        Write-Host ''
        return $true
    }
    else {
        Write-Host ''
        
        # Show insufficient role issues
        if ($insufficientRoles.Count -gt 0) {
            Write-Host '  INSUFFICIENT ROLE DETECTED!' -ForegroundColor Red
            Write-Host ''
            
            foreach ($insufficient in $insufficientRoles) {
                Write-Host "  Cmdlet: $($insufficient.Cmdlet)" -ForegroundColor Red
                Write-Host "  Current Permission: [X] DENIED" -ForegroundColor Red
                Write-Host "  Required Role: $($insufficient.RequiredRole)" -ForegroundColor Yellow
                Write-Host "  Error Details: $($insufficient.Error)" -ForegroundColor Gray
                Write-Host ''
                Write-Host '  Affected controls (CANNOT be modified):' -ForegroundColor Yellow
                foreach ($control in $insufficient.Controls) {
                    Write-Host "    [$($control.CisId)] $($control.Title)" -ForegroundColor Yellow
                    Write-Host "      Setting: $($control.Setting)" -ForegroundColor Gray
                }
                Write-Host ''
            }
        }
        
        # Show invalid parameter issues
        if ($invalidParameters.Count -gt 0) {
            Write-Host '  INVALID PARAMETER ERRORS DETECTED!' -ForegroundColor Red
            Write-Host ''
            
            foreach ($invalid in $invalidParameters) {
                Write-Host "  Cmdlet: $($invalid.Cmdlet)" -ForegroundColor Red
                Write-Host "  The following properties do not exist on this cmdlet:" -ForegroundColor Yellow
                foreach ($prop in $invalid.MissingProperties) {
                    Write-Host "    [$($prop.CisId)] $($prop.Title)" -ForegroundColor Yellow
                    Write-Host "      Property: $($prop.Setting) (DOES NOT EXIST)" -ForegroundColor Red
                }
                Write-Host ''
            }
        }
        
        # Show other failures
        if ($failedCmdlets.Count -gt 0) {
            Write-Host '  OTHER ERRORS DETECTED!' -ForegroundColor Red
            Write-Host ''
            
            foreach ($failed in $failedCmdlets) {
                Write-Host "  Cmdlet: $($failed.Cmdlet)" -ForegroundColor Red
                Write-Host "  Error: $($failed.Error)" -ForegroundColor Yellow
                Write-Host ''
                Write-Host '  Affected controls:' -ForegroundColor Yellow
                foreach ($control in $failed.Controls) {
                    Write-Host "    [$($control.CisId)] $($control.Title)" -ForegroundColor Yellow
                    Write-Host "      Setting: $($control.Setting)" -ForegroundColor Gray
                }
                Write-Host ''
            }
        }
        
        # Show summary of what works vs what doesn't
        Write-Host '  PERMISSION SUMMARY:' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '  CAN MODIFY (with current role):' -ForegroundColor Green
        $canModify = $cmdletRequirements.Keys | Where-Object {
            -not ($insufficientRoles.Cmdlet -contains $_) -and `
            -not ($failedCmdlets.Cmdlet -contains $_) -and `
            -not ($invalidParameters.Cmdlet -contains $_)
        }
        if ($canModify.Count -gt 0) {
            foreach ($cmdlet in $canModify) {
                $count = $cmdletRequirements[$cmdlet].Controls.Count
                Write-Host "    + $cmdlet ($count control(s))" -ForegroundColor Green
            }
        } else {
            Write-Host "    (None)" -ForegroundColor Gray
        }
        
        Write-Host ''
        Write-Host '  CANNOT MODIFY (insufficient role):' -ForegroundColor Red
        if ($insufficientRoles.Count -gt 0) {
            foreach ($insufficient in $insufficientRoles) {
                $count = $insufficient.Controls.Count
                Write-Host "    [X] $($insufficient.Cmdlet) ($count control(s))" -ForegroundColor Red
                Write-Host "       Requires: $($insufficient.RequiredRole)" -ForegroundColor Yellow
            }
        } else {
            Write-Host "    (None)" -ForegroundColor Green
        }
        
        Write-Host ''
        Write-Host '  REQUIRED ACTIONS:' -ForegroundColor Cyan
        if ($insufficientRoles.Count -gt 0) {
            Write-Host '    1. You do NOT have the required role to make these changes' -ForegroundColor Red
            Write-Host '    2. Contact your Global Administrator' -ForegroundColor White
            Write-Host '    3. Request the following role(s):' -ForegroundColor White
            $roles = $insufficientRoles | ForEach-Object { $_.RequiredRole } | Sort-Object -Unique
            foreach ($role in $roles) {
                Write-Host "       - $role" -ForegroundColor Cyan
            }
            Write-Host '    4. Wait 15-30 minutes for role assignment to propagate' -ForegroundColor White
            Write-Host '    5. Sign out: Disconnect-MicrosoftTeams' -ForegroundColor White
            Write-Host '    6. Close PowerShell completely' -ForegroundColor White
            Write-Host '    7. Reopen PowerShell and run the script again' -ForegroundColor White
        }
        
        Write-Host ''
        
        return $false
    }
}

# ===============================================================================
# MAIN
# ===============================================================================

Clear-Host
try { $null = New-Item -ItemType Directory -Force -Path $ReportPath -ErrorAction Stop } catch { Write-Host "ERROR: Cannot create $ReportPath" -ForegroundColor Red; exit 1 }
$script:LogFile = Join-Path $ReportPath ('Set-TeamsHardening_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.log')
Write-Log "Script started v$($script:Version)"

Write-Host ''
Write-Host '  TEAMS CIS HARDENING' -ForegroundColor Cyan
Write-Host '  Version ' -NoNewline
Write-Host "v$($script:Version)" -ForegroundColor Green
Write-Host ''
Write-Host '  Checking MicrosoftTeams module...' -NoNewline
if (-not (Get-Module -ListAvailable -Name MicrosoftTeams)) {
    Write-Host ' NOT FOUND' -ForegroundColor Red
    Write-Host ''
    Write-Host '  Install: Install-Module MicrosoftTeams -Scope CurrentUser' -ForegroundColor Yellow
    exit 1
}
Import-Module MicrosoftTeams -Force -ErrorAction SilentlyContinue
Write-Host ' OK' -ForegroundColor Green

Write-Host ''
Write-Host '  Connecting to Microsoft Teams...' -ForegroundColor Cyan
Write-Host '  Sign in with Teams Administrator credentials when prompted.'
Write-Host ''
try {
    Connect-MicrosoftTeams -ErrorAction Stop | Out-Null
    $script:TenantName = (Get-CsTenant -ErrorAction Stop).DisplayName
    Write-Host '  Connected to: ' -NoNewline
    Write-Host $script:TenantName -ForegroundColor Green
    Write-Log "Connected: $($script:TenantName)"
} catch {
    Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
Write-Host ''
Read-Host '  Press Enter to continue'

# Check permissions before proceeding
$hasPermissions = Test-RequiredPermissions
$script:HasMeetingPolicyPermission = $hasPermissions 

Write-Host ''
Read-Host '  Press Enter to proceed to main menu'

$exitRequested = $false
while (-not $exitRequested) {
    $choice = Show-MainMenu
    switch ($choice) {
        '1' { Invoke-Assessment }
        '2' { Invoke-GuidedRemediation }
        '3' { Invoke-Snapshot }
        '4' { Invoke-Rollback }
        '?' { Show-FAQ }
        'Q' { $exitRequested = $true }
    }
}

Write-Host ''
Write-Host '  Disconnecting from Microsoft Teams...' -NoNewline
try { Disconnect-MicrosoftTeams -ErrorAction SilentlyContinue } catch { }
Write-Host ' Done' -ForegroundColor Green
Write-Host ''
Write-Host '  Thank you for using Teams CIS Hardening!' -ForegroundColor Cyan
Write-Host "  Log: $($script:LogFile)" -ForegroundColor Gray
Write-Host ''
Write-Log 'Script ended'