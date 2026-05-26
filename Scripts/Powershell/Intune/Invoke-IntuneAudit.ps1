#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication

<#
.SYNOPSIS
    Exports a Microsoft Intune tenant configuration for audit and best practice assessment.

.DESCRIPTION
    Read-only audit export of an Intune tenant. Connects to Microsoft Graph,
    pulls configuration across all major policy areas, and generates a structured
    Markdown report suitable for review by the IntuneAdvisor Hatz.AI agent or
    manual assessment.

    No changes are made to the tenant. All operations are read-only.

    Audit areas:
    1. Device Enrollment (Autopilot, ESP, enrollment restrictions)
    2. Configuration Profiles
    3. Compliance Policies
    4. App Management (Win32, M365 Apps, app protection)
    5. Security Baselines (Intents)
    6. Endpoint Security (BitLocker, firewall, antivirus, ASR)
    7. Conditional Access
    8. RBAC & Scope Tags
    9. Reporting & Monitoring (device status summary)
    10. Licensing (subscribed SKUs)

.NOTES
    Script:  Invoke-IntuneAudit.ps1
    Author:  Jeff Davidson
    Version: 1.4.0
    Date:    2026-05-06

    v1.4.0  -  TenantPrep alignment checks:
      - Endpoint Security: placeholder policy detection  -  settingCount = 0 emits
        WARNING; coverage flags (BitLocker/Firewall/AV/ASR/LAPS) only set when
        policy has at least one configured setting
      - Group Inventory: dynamic group membership rule validation  -  groups using
        device.operatingSystem (wrong) emit WARNING with remediation guidance;
        direct baseline group coverage table queries for all 13 expected
        GRP-* groups and emits FINDING for any missing
      - Config Profiles: OMA-URI placeholder GUID detection  -  scans
        windows10CustomConfiguration omaSettings and decodes macOSCustomConfiguration
        Base64 payload; emits WARNING when 00000000-0000-0000-0000-000000000000
        is found in either
      - Enrollment: ESP empty app tracking warning  -  emits WARNING when
        showInstallationProgress = true but selectedMobileAppIds is empty

    v1.3.0  -  Eight-pillar coverage + recommendations summary:
      - Reporting & Monitoring expanded: audit-log accessibility (last activity
        timestamp), Endpoint Analytics enablement, app install failure summary
        (via reports/getAppsInstallSummaryReport), Azure Monitor diagnostic-
        settings note (ARM-only, flagged for manual verification)
      - Licensing expanded: Intune Suite feature signals (Remote Help,
        Microsoft Tunnel, Endpoint Privilege Management policy count),
        Entra ID P1/P2 utilization markers (CA policy count, riskyUsers/PIM
        endpoint reachability), license-assignment health (consumed vs
        available per Intune-relevant SKU)
      - New Findings & Recommendations Summary section consolidates every
        FINDING / WARNING raised across the eight audit pillars into a
        single recommendations table at end of report

    v1.2.0  -  Gap-assessment additions (drives downstream Tenant Configuration Review):
      - Tenant Overview header section (counts of profiles, policies, apps, groups, rings, baselines)
      - Co-Management workload-slider audit (per-workload Intune-vs-SCCM table + device managementAgent breakdown)
      - BitLocker XTS-AES 256 + escrow surfacing (parsed from disk-encryption settings)
      - Windows LAPS policy detection (Settings Catalog templateFamily)
      - Update Rings summary: pilot vs broad detection, count check
      - Settings Catalog multi-area bundle flag (e.g. OneDrive+Edge+Outlook in one policy)
      - Company Portal deployment detection in Apps section
      - Over-scoped sensitive policy flagging (All Users/All Devices on LocalAdmin/LAPS/BitLocker/ASR)
      - Compliance scheduled-actions rendered as readable rows
      - Conditional Access → device compliance integration check (already in v1.1, formalised)
      - Available security baseline templates listed alongside deployed instances
      - Platform Readiness section: APNs cert (subject + expiry), Android Enterprise binding, VPP tokens
      - Consolidated Group Inventory (deduped from cache) at end of report

    v1.1.0  -  Per-item configuration detail dump (was summary-only in v1.0.0):
      - Group ID -> display name resolution with caching
      - Autopilot / ESP / enrollment restrictions: full settings + assignments
      - Settings Catalog: per-policy setting names + values via $expand=settingDefinitions
      - Compliance policies: every rule property + scheduled actions + assignments
      - Apps: per-app assignment intent (Required/Available/Uninstall) + target group
      - App Protection: PIN, data transfer, save-as, copy-paste, conditional launch
      - Security Baselines: per-intent settings via /intents/{id}/settings
      - Conditional Access: full conditions/controls/session dump
      - RBAC: per-assignment members + scope members + scope tags
      - Header calls out HQ / Property / Business Center (Kiosk) profile goal

    Exit Codes:
        0  - Success, report generated
        1  - Partial success (some audit areas failed)
        10 - Warning (Graph connection issues, partial data)
        20 - Critical error (authentication failed or prerequisites not met)

.PARAMETER OutputPath
    Directory for the report output. Default: C:\Temp\IntuneAudit

.PARAMETER ClientName
    Client identifier included in the report header. Default: Unknown

.PARAMETER SkipModuleCheck
    Skip the Graph module prerequisite check (use if modules are confirmed installed).

.PARAMETER Quiet
    Suppress console output. Report is still written to file.

.EXAMPLE
    .\Invoke-IntuneAudit.ps1 -ClientName "Contoso"

.EXAMPLE
    .\Invoke-IntuneAudit.ps1 -ClientName "Contoso" -OutputPath "D:\Audits"

.EXAMPLE
    # Copy-paste mode: paste entire script into a PS session, then call:
    Invoke-IntuneAudit -ClientName "Contoso"
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$OutputPath = 'C:\Temp\IntuneAudit',

    [Parameter()]
    [string]$ClientName = 'Unknown',

    [switch]$SkipModuleCheck,

    [switch]$Quiet
)

# ─── Configuration ────────────────────────────────────────────────────────────

# Graph modules required for full audit
$script:RequiredModules = @(
    'Microsoft.Graph.Authentication'
    'Microsoft.Graph.DeviceManagement'
    'Microsoft.Graph.DeviceManagement.Enrollment'
    'Microsoft.Graph.DeviceManagement.Administration'
    'Microsoft.Graph.Identity.SignIns'
    'Microsoft.Graph.Users'
)

# Read-only scopes  -  no write permissions requested
$script:GraphScopes = @(
    'DeviceManagementConfiguration.Read.All'
    'DeviceManagementManagedDevices.Read.All'
    'DeviceManagementApps.Read.All'
    'DeviceManagementServiceConfig.Read.All'
    'DeviceManagementRBAC.Read.All'
    'Policy.Read.All'
    'Directory.Read.All'
    'Organization.Read.All'
)

# ─── Helper Functions ─────────────────────────────────────────────────────────

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format 'HH:mm:ss'
    $prefix = switch ($Level) {
        'INFO'    { '[.]' }
        'WARN'    { '[!]' }
        'ERROR'   { '[X]' }
        'SUCCESS' { '[+]' }
    }
    if (-not $script:Quiet) {
        $color = switch ($Level) {
            'INFO'    { 'Cyan' }
            'WARN'    { 'Yellow' }
            'ERROR'   { 'Red' }
            'SUCCESS' { 'Green' }
        }
        Write-Host "$timestamp $prefix $Message" -ForegroundColor $color
    }
}

function Add-ReportSection {
    param(
        [string]$Title,
        [string]$Content
    )
    [void]$script:Report.AppendLine("")
    [void]$script:Report.AppendLine("---")
    [void]$script:Report.AppendLine("")
    [void]$script:Report.AppendLine("## $Title")
    [void]$script:Report.AppendLine("")
    [void]$script:Report.AppendLine($Content)
}

function Invoke-GraphRequestSafe {
    <#
    .SYNOPSIS
        Wraps Invoke-MgGraphRequest with error handling. Returns $null on failure.
    #>
    param(
        [string]$Uri,
        [string]$AuditArea,
        [switch]$Quiet   # Suppress error logging for endpoints expected to occasionally 400 (e.g. nav props not supported by all policy subtypes)
    )
    try {
        $response = Invoke-MgGraphRequest -Method GET -Uri $Uri -ErrorAction Stop
        if ($response.value) { return $response.value }
        return $response
    }
    catch {
        if (-not $Quiet) {
            $errMsg = "[$AuditArea] Failed: $Uri - $($_.Exception.Message)"
            Write-Log $errMsg -Level ERROR
            $script:ErrorLog.Add($errMsg)
            if ($script:ExitCode -lt 1) { $script:ExitCode = 1 }
        }
        return $null
    }
}

function Invoke-GraphRequestPaged {
    <#
    .SYNOPSIS
        Paginated Graph GET. Follows @odata.nextLink until exhausted.
        Returns aggregated .value items.
    #>
    param(
        [string]$Uri,
        [string]$AuditArea,
        [int]$MaxPages = 50
    )
    $all = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    $page = 0
    while ($next -and $page -lt $MaxPages) {
        try {
            $resp = Invoke-MgGraphRequest -Method GET -Uri $next -ErrorAction Stop
        }
        catch {
            $errMsg = "[$AuditArea] Paged fetch failed (page $page): $next - $($_.Exception.Message)"
            Write-Log $errMsg -Level ERROR
            $script:ErrorLog.Add($errMsg)
            if ($script:ExitCode -lt 1) { $script:ExitCode = 1 }
            break
        }
        if ($resp.value) { foreach ($v in $resp.value) { $all.Add($v) } }
        $next = $resp.'@odata.nextLink'
        $page++
    }
    if ($page -ge $MaxPages -and $next) {
        Write-Log "[$AuditArea] Pagination cap ($MaxPages pages) reached for $Uri" -Level WARN
    }
    return ,$all.ToArray()
}

function Format-Table-Md {
    <#
    .SYNOPSIS
        Converts an array of objects to a Markdown table.
    #>
    param(
        [Parameter(ValueFromPipeline)]
        [object[]]$InputObject,
        [string[]]$Properties
    )
    begin { $items = [System.Collections.Generic.List[object]]::new() }
    process { foreach ($obj in $InputObject) { $items.Add($obj) } }
    end {
        if ($items.Count -eq 0) { return "*None found.*" }
        if (-not $Properties) { $Properties = ($items[0].PSObject.Properties | Select-Object -ExpandProperty Name) }

        $sb = [System.Text.StringBuilder]::new()
        # Header
        [void]$sb.AppendLine("| $($Properties -join ' | ') |")
        [void]$sb.AppendLine("| $( ($Properties | ForEach-Object { '---' }) -join ' | ') |")
        # Rows
        foreach ($item in $items) {
            $vals = foreach ($prop in $Properties) {
                $v = $item.$prop
                if ($null -eq $v) { '' } else { "$v" -replace '\|', '\|' -replace "`r?`n", ' ' }
            }
            [void]$sb.AppendLine("| $($vals -join ' | ') |")
        }
        return $sb.ToString()
    }
}

function Resolve-GroupName {
    <#
    .SYNOPSIS
        Resolves an Entra group ID to display name. Cached per session.
    #>
    param([string]$GroupId)
    if (-not $GroupId) { return '' }
    if ($script:GroupCache.ContainsKey($GroupId)) { return $script:GroupCache[$GroupId] }
    try {
        $g = Invoke-MgGraphRequest -Method GET `
            -Uri "https://graph.microsoft.com/v1.0/groups/$GroupId`?`$select=displayName" `
            -ErrorAction Stop
        $name = if ($g.displayName) { $g.displayName } else { "[$($GroupId.Substring(0, [Math]::Min(8,$GroupId.Length)))...]" }
    }
    catch {
        $name = "[$($GroupId.Substring(0, [Math]::Min(8,$GroupId.Length)))...]"
    }
    $script:GroupCache[$GroupId] = $name
    return $name
}

function Format-Assignment {
    <#
    .SYNOPSIS
        Formats a single assignment target into a human-readable string.
    #>
    param($Target, $Intent)
    if (-not $Target) { return '' }
    $type = $Target.'@odata.type'
    $group = if ($Target.groupId) { Resolve-GroupName $Target.groupId } else { '' }
    $filterMode = if ($Target.deviceAndAppManagementAssignmentFilterType -and
                       $Target.deviceAndAppManagementAssignmentFilterType -ne 'none') {
        " [filter:$($Target.deviceAndAppManagementAssignmentFilterType)]"
    } else { '' }
    $intentTag = if ($Intent) { "($Intent) " } else { '' }
    switch -Regex ($type) {
        'allDevices'         { return "${intentTag}All Devices${filterMode}" }
        'allLicensedUsers'   { return "${intentTag}All Users${filterMode}" }
        'exclusionGroup'     { return "${intentTag}EXCLUDE: $group${filterMode}" }
        'groupAssignment'    { return "${intentTag}Group: $group${filterMode}" }
        default              { return "${intentTag}$($type -replace '#microsoft\.graph\.','')${filterMode}" }
    }
}

function Get-AssignmentList {
    <#
    .SYNOPSIS
        Fetches assignments for a policy and returns formatted list.
    #>
    param([string]$Uri, [string]$AuditArea)
    $a = Invoke-GraphRequestSafe -Uri $Uri -AuditArea $AuditArea
    if (-not $a) { return @() }
    return @($a | ForEach-Object { Format-Assignment -Target $_.target -Intent $_.intent })
}

function Format-PropertyDetail {
    <#
    .SYNOPSIS
        Renders an object's properties as a markdown bullet list.
        Skips system fields and empty values. Truncates large nested values.
    #>
    param(
        [Parameter(ValueFromPipeline)]$Item,
        [string[]]$Skip = @(
            'id','displayName','description','version','createdDateTime',
            'lastModifiedDateTime','roleScopeTagIds','supportsScopeTags',
            '@odata.type','@odata.context','assignments','deviceStatusOverview',
            'userStatusOverview','deviceStatuses','userStatuses'
        ),
        [int]$MaxLength = 250
    )
    process {
        if (-not $Item) { return '' }
        $sb = [System.Text.StringBuilder]::new()
        $props = $Item.PSObject.Properties | Where-Object {
            $_.Name -notin $Skip -and $null -ne $_.Value -and "$($_.Value)" -ne ''
        } | Sort-Object Name
        foreach ($p in $props) {
            $val = $p.Value
            if ($val -is [System.Collections.IDictionary] -or
                ($val -is [System.Collections.IEnumerable] -and $val -isnot [string])) {
                try {
                    $val = ($val | ConvertTo-Json -Compress -Depth 4 -WarningAction SilentlyContinue)
                } catch {
                    $val = "$val"
                }
            }
            $val = "$val" -replace '\|','\|' -replace "`r?`n",' '
            if ($val.Length -gt $MaxLength) { $val = $val.Substring(0,$MaxLength) + '...' }
            [void]$sb.AppendLine("- **$($p.Name):** $val")
        }
        if ($sb.Length -eq 0) { return '*(no non-default settings)*' }
        return $sb.ToString()
    }
}

function Format-SettingsCatalog {
    <#
    .SYNOPSIS
        Renders a Settings Catalog setting collection as a markdown bullet list.
        Strips long Microsoft setting prefixes for readability.
    #>
    param($Settings)
    if (-not $Settings -or $Settings.Count -eq 0) { return "*No settings retrieved.*" }
    $sb = [System.Text.StringBuilder]::new()
    foreach ($s in $Settings) {
        $inst = $s.settingInstance
        if (-not $inst) { continue }
        $defId = "$($inst.settingDefinitionId)"
        # Trim noisy prefix: device_vendor_msft_policy_config_<area>_<setting> -> <setting>
        $name = $defId -replace '^device_vendor_msft_policy_config_','' `
                       -replace '^user_vendor_msft_policy_config_',''
        $value = ''
        if ($null -ne $inst.choiceSettingValue.value) {
            $value = "$($inst.choiceSettingValue.value)" -replace "^${defId}_",''
            # Render any child settings
            if ($inst.choiceSettingValue.children -and $inst.choiceSettingValue.children.Count -gt 0) {
                $childParts = foreach ($c in $inst.choiceSettingValue.children) {
                    $cName = ($c.settingDefinitionId -split '_' | Select-Object -Last 1)
                    $cVal = if ($null -ne $c.choiceSettingValue.value) { "$($c.choiceSettingValue.value)" -replace "^.*?_$cName`_",'' }
                            elseif ($null -ne $c.simpleSettingValue.value) { "$($c.simpleSettingValue.value)" }
                            else { '' }
                    "$cName=$cVal"
                }
                $value = "$value { $($childParts -join '; ') }"
            }
        }
        elseif ($null -ne $inst.simpleSettingValue.value) {
            $value = "$($inst.simpleSettingValue.value)"
        }
        elseif ($inst.choiceSettingCollectionValue) {
            $value = ($inst.choiceSettingCollectionValue | ForEach-Object {
                "$($_.value)" -replace "^${defId}_",''
            }) -join ', '
        }
        elseif ($inst.simpleSettingCollectionValue) {
            $value = ($inst.simpleSettingCollectionValue.value) -join ', '
        }
        elseif ($inst.groupSettingCollectionValue) {
            $value = "[group: $($inst.groupSettingCollectionValue.Count) item(s)]"
        }
        $value = "$value" -replace '\|','\|' -replace "`r?`n",' '
        if ($value.Length -gt 200) { $value = $value.Substring(0,200) + '...' }
        [void]$sb.AppendLine("- ``$name`` = $value")
    }
    if ($sb.Length -eq 0) { return '*No renderable settings.*' }
    return $sb.ToString()
}

function Get-SettingsCatalogValues {
    <#
    .SYNOPSIS
        Fetches settings for a Settings Catalog policy with definitions expanded.
    #>
    param([string]$PolicyId)
    if (-not $PolicyId) { return $null }
    return Invoke-GraphRequestSafe `
        -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$PolicyId/settings?`$expand=settingDefinitions&`$top=1000" `
        -AuditArea 'SettingsCatalog'
}

function Get-SettingsCatalogAreas {
    <#
    .SYNOPSIS
        Returns the distinct functional areas covered by a Settings Catalog policy.
        Settings IDs follow `device_vendor_msft_policy_config_<area>_*`  -  we extract <area>
        and surrounding shorthand (onedrive, edge, outlook, defender, etc.) to detect
        single-purpose vs. bundled (multi-area) policies.
    #>
    param($Settings)
    if (-not $Settings) { return @() }
    $areas = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($s in $Settings) {
        $defId = "$($s.settingInstance.settingDefinitionId)"
        if (-not $defId) { continue }
        # Normalise by stripping common prefixes
        $stripped = $defId -replace '^(device_vendor_msft_policy_config_|user_vendor_msft_policy_config_|admx_)', ''
        # Take first segment as area; for known apps, prefer the app keyword
        $area = ($stripped -split '_')[0]
        # Map well-known app/feature keywords (winning over generic prefixes)
        switch -Regex ($defId.ToLower()) {
            'onedrive'                                  { $area = 'OneDrive' }
            '(^|_)edge(_|$)'                            { $area = 'Edge' }
            '(^|_)outlook'                              { $area = 'Outlook' }
            'office16|office_v3|microsoft_office'       { $area = 'Office' }
            'defender|wdav|asr|attacksurface'           { $area = 'Defender' }
            'bitlocker'                                 { $area = 'BitLocker' }
            'firewall|mdmfirewall'                      { $area = 'Firewall' }
            'laps'                                      { $area = 'LAPS' }
            'sharedpc'                                  { $area = 'SharedPC' }
            'localadmin|localusers|localpoliciessecurityoptions_accounts' { $area = 'LocalAccounts' }
            'wifi|vpn|networkqos'                       { $area = 'Network' }
            'update_'                                   { $area = 'Update' }
        }
        if ($area) { [void]$areas.Add($area) }
    }
    return @($areas)
}

# Lower-case keywords that indicate a sensitive policy where over-scoped
# (All Users / All Devices) assignments warrant a warning. Compared against
# the policy display name.
$script:SensitivePolicyKeywords = @(
    'localadmin','local administrator','laps','bitlocker','disk encryption',
    'asr','attack surface','defender','antivirus','firewall',
    'shared pc','sharedpc','kiosk','autopilot','update ring',
    'compliance','conditional access','wifi','vpn'
)

function Test-PolicySensitive {
    <#
    .SYNOPSIS
        True if the policy display name suggests a sensitive/security policy
        that should not be assigned All Users / All Devices.
    #>
    param([string]$Name)
    if (-not $Name) { return $false }
    $n = $Name.ToLower()
    foreach ($k in $script:SensitivePolicyKeywords) {
        if ($n -like "*$k*") { return $true }
    }
    return $false
}

function Test-AssignmentBroad {
    <#
    .SYNOPSIS
        True if any assignment string indicates an unscoped All-Users/All-Devices target.
    #>
    param([string[]]$Assignments)
    foreach ($a in $Assignments) {
        if ($a -match 'All Users|All Devices') { return $true }
    }
    return $false
}

function Write-OverScopeWarning {
    <#
    .SYNOPSIS
        Emits a markdown warning line into the supplied StringBuilder if the policy
        is sensitive and has broad assignments. No-op otherwise.
    #>
    param(
        [System.Text.StringBuilder]$Sb,
        [string]$PolicyName,
        [string[]]$Assignments
    )
    if ((Test-PolicySensitive $PolicyName) -and (Test-AssignmentBroad $Assignments)) {
        [void]$Sb.AppendLine("> **OVER-SCOPED:** Sensitive policy ``$PolicyName`` is assigned to All Users / All Devices. Scope to a targeted group (e.g. ``GRP-WIN-Security-Baseline`` or ``GRP-WIN-Compliance-All``) instead.")
        [void]$Sb.AppendLine("")
    }
}

# ─── Prerequisites ────────────────────────────────────────────────────────────

function Test-Prerequisites {
    Write-Log "Checking prerequisites..." -Level INFO

    # Output directory
    if (-not (Test-Path $script:OutputPath)) {
        try {
            New-Item -ItemType Directory -Path $script:OutputPath -Force | Out-Null
            Write-Log "Created output directory: $script:OutputPath" -Level INFO
        }
        catch {
            Write-Log "Cannot create output directory: $script:OutputPath" -Level ERROR
            return $false
        }
    }

    # Module check
    if (-not $script:SkipModuleCheck) {
        $missing = @()
        foreach ($mod in $script:RequiredModules) {
            if (-not (Get-Module -ListAvailable -Name $mod)) {
                $missing += $mod
            }
        }
        if ($missing.Count -gt 0) {
            Write-Log "Missing Graph modules:" -Level ERROR
            foreach ($m in $missing) { Write-Log "  - $m" -Level ERROR }
            Write-Log "Install with: Install-Module $($missing -join ', ') -Scope CurrentUser" -Level WARN
            return $false
        }
        Write-Log "All required modules found" -Level SUCCESS
    }

    return $true
}

function Connect-GraphForAudit {
    Write-Log "Connecting to Microsoft Graph (read-only scopes)..." -Level INFO
    try {
        Connect-MgGraph -Scopes $script:GraphScopes -NoWelcome -ErrorAction Stop
        $context = Get-MgContext
        if (-not $context) {
            Write-Log "Graph connection returned no context" -Level ERROR
            return $false
        }
        Write-Log "Connected as: $($context.Account) | Tenant: $($context.TenantId)" -Level SUCCESS
        return $true
    }
    catch {
        Write-Log "Graph authentication failed: $($_.Exception.Message)" -Level ERROR
        return $false
    }
}

# ─── Audit Functions ──────────────────────────────────────────────────────────

function Get-AuditTenantOverview {
    Write-Log "Auditing: Tenant Overview" -Level INFO
    $sb = [System.Text.StringBuilder]::new()

    # Lightweight counts via Graph $count headers where supported, else page-count.
    # Each call is independent so a failure in one row does not blank the table.
    $counts = [ordered]@{}

    $counts['Configuration Profiles (Classic)'] = (
        Invoke-GraphRequestSafe -Uri 'https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations?$select=id' -AuditArea 'Overview' | Measure-Object).Count
    $counts['Settings Catalog Policies']        = (
        Invoke-GraphRequestSafe -Uri 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?$select=id&$top=200' -AuditArea 'Overview' | Measure-Object).Count
    $counts['Compliance Policies']              = (
        Invoke-GraphRequestSafe -Uri 'https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies?$select=id' -AuditArea 'Overview' | Measure-Object).Count
    $counts['Mobile Apps']                      = (
        Invoke-GraphRequestSafe -Uri 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?$select=id&$top=200' -AuditArea 'Overview' | Measure-Object).Count
    $counts['App Protection (MAM) Policies']    = (
        Invoke-GraphRequestSafe -Uri 'https://graph.microsoft.com/beta/deviceAppManagement/managedAppPolicies?$select=id' -AuditArea 'Overview' | Measure-Object).Count
    $counts['Conditional Access Policies']      = (
        Invoke-GraphRequestSafe -Uri 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies?$select=id' -AuditArea 'Overview' | Measure-Object).Count
    $counts['Security Baseline Instances']      = (
        Invoke-GraphRequestSafe -Uri 'https://graph.microsoft.com/beta/deviceManagement/intents?$select=id' -AuditArea 'Overview' | Measure-Object).Count
    $counts['Autopilot Profiles']               = (
        Invoke-GraphRequestSafe -Uri 'https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles?$select=id' -AuditArea 'Overview' | Measure-Object).Count
    $counts['Role Assignments']                 = (
        Invoke-GraphRequestSafe -Uri 'https://graph.microsoft.com/beta/deviceManagement/roleAssignments?$select=id' -AuditArea 'Overview' | Measure-Object).Count
    $counts['Scope Tags']                       = (
        Invoke-GraphRequestSafe -Uri 'https://graph.microsoft.com/beta/deviceManagement/roleScopeTags?$select=id' -AuditArea 'Overview' | Measure-Object).Count

    # Update rings  -  derived from classic config profiles
    $allConfigs = Invoke-GraphRequestSafe -Uri 'https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations?$select=id,displayName' -AuditArea 'Overview'
    $rings = if ($allConfigs) { @($allConfigs | Where-Object { $_.'@odata.type' -match 'windowsUpdateForBusinessConfiguration' }) } else { @() }
    $counts['Windows Update Rings'] = $rings.Count

    # Device totals from managedDeviceOverview
    $overview = Invoke-GraphRequestSafe -Uri 'https://graph.microsoft.com/beta/deviceManagement/managedDeviceOverview' -AuditArea 'Overview'

    [void]$sb.AppendLine("### Object Counts")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("| Object Type | Count |")
    [void]$sb.AppendLine("| --- | ---: |")
    foreach ($k in $counts.Keys) {
        [void]$sb.AppendLine("| $k | $($counts[$k]) |")
    }
    [void]$sb.AppendLine("")

    if ($overview) {
        [void]$sb.AppendLine("### Device Totals")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("| Metric | Count |")
        [void]$sb.AppendLine("| --- | ---: |")
        [void]$sb.AppendLine("| Enrolled Devices | $($overview.enrolledDeviceCount) |")
        [void]$sb.AppendLine("| MDM-only | $($overview.mdmEnrolledCount) |")
        [void]$sb.AppendLine("| Co-Managed (dual) | $($overview.dualEnrolledDeviceCount) |")
        if ($overview.deviceOperatingSystemSummary) {
            $os = $overview.deviceOperatingSystemSummary
            [void]$sb.AppendLine("| Windows | $($os.windowsCount) |")
            [void]$sb.AppendLine("| iOS / iPadOS | $($os.iosCount) |")
            [void]$sb.AppendLine("| macOS | $($os.macOSCount) |")
            [void]$sb.AppendLine("| Android | $($os.androidCount) |")
        }
        [void]$sb.AppendLine("")
    }

    Add-ReportSection -Title 'Tenant Overview' -Content $sb.ToString()
}

function Get-AuditCoManagement {
    Write-Log "Auditing: Co-Management" -Level INFO
    $sb = [System.Text.StringBuilder]::new()

    # Tenant-wide co-management settings (workload sliders)
    # /deviceManagement contains intuneAccountId, settings, etc.; the workload
    # sliders for ConfigMgr-coexistence live on each ConfigMgr collection
    # rather than tenant-wide. The reliable source is the device-level
    # configurationManagerClientEnabledFeatures on each managed device, which
    # tells you which workloads ARE actually moved to Intune for that device.

    $devices = Invoke-GraphRequestPaged `
        -Uri 'https://graph.microsoft.com/beta/deviceManagement/managedDevices?$select=id,deviceName,managementAgent,configurationManagerClientEnabledFeatures,operatingSystem&$top=200' `
        -AuditArea 'CoManagement'

    [void]$sb.AppendLine("### Management Agent Breakdown")
    [void]$sb.AppendLine("")
    if ($devices -and $devices.Count -gt 0) {
        $byAgent = $devices | Group-Object managementAgent | Sort-Object Count -Descending
        $rows = foreach ($g in $byAgent) {
            [PSCustomObject]@{
                ManagementAgent = $g.Name
                Count           = $g.Count
                Description     = switch ($g.Name) {
                    'mdm'                              { 'Intune MDM only' }
                    'configurationManagerClient'       { 'SCCM / ConfigMgr only (NOT Intune-enrolled)' }
                    'configurationManagerClientMdm'    { 'Co-managed (SCCM + Intune)' }
                    'configurationManagerClientEas'    { 'SCCM + Exchange ActiveSync' }
                    'eas'                              { 'Exchange ActiveSync only' }
                    'easMdm'                           { 'EAS + Intune MDM' }
                    'intuneClient'                     { 'Legacy Intune client' }
                    'easIntuneClient'                  { 'EAS + legacy Intune client' }
                    default                            { '(see Microsoft docs)' }
                }
            }
        }
        [void]$sb.AppendLine(($rows | Format-Table-Md -Properties 'ManagementAgent','Count','Description'))
        [void]$sb.AppendLine("")

        # Per-workload pivot  -  only co-managed devices report
        # configurationManagerClientEnabledFeatures (a device-level workload map).
        $coManaged = @($devices | Where-Object { $_.managementAgent -eq 'configurationManagerClientMdm' })
        if ($coManaged.Count -gt 0) {
            [void]$sb.AppendLine("### Workload Authority  -  Co-Managed Devices ($($coManaged.Count))")
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("Per-device count of which workload is delivered by **Intune** vs. **SCCM** based on `configurationManagerClientEnabledFeatures`.")
            [void]$sb.AppendLine("")

            $workloads = @(
                'inventory','modernApps','resourceAccess','deviceConfiguration',
                'compliancePolicy','windowsUpdateForBusiness','endpointProtection',
                'officeApps','clientApps'
            )
            [void]$sb.AppendLine("| Workload | Devices on Intune | Devices on SCCM |")
            [void]$sb.AppendLine("| --- | ---: | ---: |")
            foreach ($w in $workloads) {
                $intuneCount = (@($coManaged | Where-Object { $_.configurationManagerClientEnabledFeatures.$w -eq $true })).Count
                $sccmCount   = $coManaged.Count - $intuneCount
                [void]$sb.AppendLine("| $w | $intuneCount | $sccmCount |")
            }
            [void]$sb.AppendLine("")

            # Critical security workload check: endpoint protection
            $epOnIntune = (@($coManaged | Where-Object { $_.configurationManagerClientEnabledFeatures.endpointProtection -eq $true })).Count
            if ($epOnIntune -lt $coManaged.Count) {
                [void]$sb.AppendLine("> **NOTE:** Endpoint Protection workload is still on SCCM for $($coManaged.Count - $epOnIntune) of $($coManaged.Count) co-managed device(s). Intune Endpoint Security policies (BitLocker, Defender AV, Firewall, ASR) **will not apply** to those devices until the slider is moved.")
                [void]$sb.AppendLine("")
            }
        } else {
            [void]$sb.AppendLine("*No co-managed devices detected (no `configurationManagerClientMdm` agents).*")
            [void]$sb.AppendLine("")
        }
    } else {
        [void]$sb.AppendLine("*No managed devices returned (or access denied).*")
        [void]$sb.AppendLine("")
    }

    Add-ReportSection -Title 'Co-Management & Workload Authority' -Content $sb.ToString()
}

function Get-AuditEnrollment {
    Write-Log "Auditing: Device Enrollment" -Level INFO
    $sb = [System.Text.StringBuilder]::new()

    # ── Autopilot deployment profiles ──────────────────────────────────────
    $autopilotProfiles = Invoke-GraphRequestSafe `
        -Uri 'https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles' `
        -AuditArea 'Enrollment'

    [void]$sb.AppendLine("### Autopilot Deployment Profiles")
    [void]$sb.AppendLine("")
    if ($autopilotProfiles) {
        $summary = foreach ($p in $autopilotProfiles) {
            $oobe = $p.outOfBoxExperienceSettings
            [PSCustomObject]@{
                Name        = $p.displayName
                Mode        = if ($p.'@odata.type' -match 'azureAD') { 'Entra Joined' }
                              elseif ($p.'@odata.type' -match 'activeDirectory') { 'Hybrid Entra Joined' }
                              else { 'Other' }
                UserType    = $oobe.userType
                Self        = $p.deviceType
                LastModified = if ($p.lastModifiedDateTime) { ([datetime]$p.lastModifiedDateTime).ToString('yyyy-MM-dd') } else { '' }
            }
        }
        [void]$sb.AppendLine("**Total: $($autopilotProfiles.Count) Autopilot profile(s)**")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine(($summary | Format-Table-Md -Properties 'Name','Mode','UserType','Self','LastModified'))

        # Per-profile detail
        foreach ($p in $autopilotProfiles) {
            if (-not $p.id) { continue }   # skip malformed/wrapper entries
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("#### Autopilot: $($p.displayName)")
            [void]$sb.AppendLine("")
            if ($p.description) { [void]$sb.AppendLine("> $($p.description)"); [void]$sb.AppendLine("") }
            [void]$sb.AppendLine("**Profile Settings:**")
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("- **Join Type:** $(($p.'@odata.type') -replace '#microsoft\.graph\.','')")
            [void]$sb.AppendLine("- **Device Name Template:** $($p.deviceNameTemplate)")
            [void]$sb.AppendLine("- **Locale:** $($p.locale)")
            [void]$sb.AppendLine("- **Language:** $($p.language)")
            [void]$sb.AppendLine("- **Hybrid AAD Skip Connectivity Check:** $($p.hybridAzureADJoinSkipConnectivityCheck)")
            [void]$sb.AppendLine("- **Pre-Provisioning Allowed:** $($p.preprovisioningAllowed)")
            [void]$sb.AppendLine("- **Hardware Hash Extraction:** $($p.extractHardwareHash)")
            [void]$sb.AppendLine("- **Role Scope Tags:** $(($p.roleScopeTagIds -join ', '))")
            [void]$sb.AppendLine("")
            $oobe = $p.outOfBoxExperienceSettings
            if ($oobe) {
                [void]$sb.AppendLine("**OOBE Settings:**")
                [void]$sb.AppendLine("")
                [void]$sb.AppendLine("- **User Type:** $($oobe.userType) (Standard or Administrator)")
                [void]$sb.AppendLine("- **Device Usage Type:** $($oobe.deviceUsageType) (singleUser or shared)")
                [void]$sb.AppendLine("- **Hide EULA:** $($oobe.hideEULA)")
                [void]$sb.AppendLine("- **Hide Privacy Settings:** $($oobe.hidePrivacySettings)")
                [void]$sb.AppendLine("- **Hide Change Account Options:** $($oobe.hideEscapeLink)")
                [void]$sb.AppendLine("- **Skip Keyboard Selection:** $($oobe.skipKeyboardSelectionPage)")
                [void]$sb.AppendLine("")
            }
            $assignments = Get-AssignmentList `
                -Uri "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles/$($p.id)/assignments" `
                -AuditArea 'Enrollment'
            if ($assignments.Count -gt 0) {
                [void]$sb.AppendLine("**Assignments:**")
                [void]$sb.AppendLine("")
                foreach ($a in $assignments) { [void]$sb.AppendLine("- $a") }
                [void]$sb.AppendLine("")
            } else {
                [void]$sb.AppendLine("> **WARNING:** Profile is not assigned to any group.")
                [void]$sb.AppendLine("")
            }
        }

        # Cross-check vs target profiles (HQ / Property / Business Center)
        $expected = @('HQ','Property','Business Center')
        $missing = @()
        foreach ($e in $expected) {
            if (-not ($autopilotProfiles | Where-Object { $_.displayName -match $e })) { $missing += $e }
        }
        if ($missing.Count -gt 0) {
            [void]$sb.AppendLine("> **PROFILE-PLAN GAP:** Expected Autopilot profile(s) not found by name: $($missing -join ', ')")
            [void]$sb.AppendLine("")
        }
    }
    else {
        [void]$sb.AppendLine("*No Autopilot profiles found or access denied.*")
        [void]$sb.AppendLine("")
    }

    # ── All enrollment configurations (one fetch, filter client-side) ──────
    $allEnrollConfigs = Invoke-GraphRequestSafe `
        -Uri 'https://graph.microsoft.com/beta/deviceManagement/deviceEnrollmentConfigurations' `
        -AuditArea 'Enrollment'

    # ── Enrollment Status Page ─────────────────────────────────────────────
    $espProfiles = if ($allEnrollConfigs) {
        @($allEnrollConfigs | Where-Object { $_.deviceEnrollmentConfigurationType -eq 'windowsEnrollmentStatusPageConfiguration' })
    }

    [void]$sb.AppendLine("### Enrollment Status Page (ESP)")
    [void]$sb.AppendLine("")
    if ($espProfiles -and $espProfiles.Count -gt 0) {
        $summary = foreach ($e in $espProfiles) {
            [PSCustomObject]@{
                Name              = $e.displayName
                Priority          = $e.priority
                ShowProgress      = $e.showInstallationProgress
                BlockUntilDone    = $e.blockDeviceSetupRetryByUser
                TimeoutMin        = $e.installProgressTimeoutInMinutes
                AllowReset        = $e.allowDeviceResetOnInstallFailure
                AllowSkip         = $e.allowDeviceUseOnInstallFailure
            }
        }
        [void]$sb.AppendLine(($summary | Format-Table-Md -Properties 'Name','Priority','ShowProgress','BlockUntilDone','TimeoutMin','AllowReset','AllowSkip'))

        foreach ($e in $espProfiles) {
            if (-not $e.id) { continue }
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("#### ESP: $($e.displayName)")
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("- **Show Installation Progress:** $($e.showInstallationProgress)")
            [void]$sb.AppendLine("- **Block Device Setup Retry by User:** $($e.blockDeviceSetupRetryByUser)")
            [void]$sb.AppendLine("- **Allow Device Use Before Profile Apply:** $($e.allowDeviceUseOnInstallFailure)")
            [void]$sb.AppendLine("- **Allow Device Reset on Install Failure:** $($e.allowDeviceResetOnInstallFailure)")
            [void]$sb.AppendLine("- **Allow Log Collection on Install Failure:** $($e.allowLogCollectionOnInstallFailure)")
            [void]$sb.AppendLine("- **Install Progress Timeout (min):** $($e.installProgressTimeoutInMinutes)")
            [void]$sb.AppendLine("- **Custom Error Message:** $($e.customErrorMessage)")
            [void]$sb.AppendLine("- **Block on Apps:** $($e.selectedMobileAppIds.Count) app(s) tracked")
            if ($e.selectedMobileAppIds -and $e.selectedMobileAppIds.Count -gt 0) {
                [void]$sb.AppendLine("- **Tracked App IDs:** $(($e.selectedMobileAppIds | Select-Object -First 10) -join ', ')$(if ($e.selectedMobileAppIds.Count -gt 10) { ' ...' })")
            }
            if ($e.showInstallationProgress -eq $true -and (-not $e.selectedMobileAppIds -or $e.selectedMobileAppIds.Count -eq 0)) {
                [void]$sb.AppendLine("")
                [void]$sb.AppendLine("> **WARNING:** ESP ``$($e.displayName)`` is configured to show installation progress but no apps are tracked. Add required apps to the blocking list before using this profile in production. (Intune \u2192 Devices \u2192 Enrollment \u2192 Windows \u2192 Enrollment Status Page \u2192 $($e.displayName) \u2192 Settings \u2192 Select apps to track)")
                [void]$sb.AppendLine("")
            }
            [void]$sb.AppendLine("- **Disable User Status Tracking:** $($e.disableUserStatusTrackingAfterFirstUser)")
            [void]$sb.AppendLine("- **Track Install Progress for Autopilot Only:** $($e.trackInstallProgressForAutopilotOnly)")
            [void]$sb.AppendLine("")
            $assignments = Get-AssignmentList `
                -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceEnrollmentConfigurations/$($e.id)/assignments" `
                -AuditArea 'Enrollment'
            [void]$sb.AppendLine("**Assignments:**")
            [void]$sb.AppendLine("")
            if ($assignments.Count -gt 0) {
                foreach ($a in $assignments) { [void]$sb.AppendLine("- $a") }
            } else { [void]$sb.AppendLine("- *(unassigned)*") }
            [void]$sb.AppendLine("")
        }
    }
    else {
        [void]$sb.AppendLine("*No ESP profiles found or access denied.*")
        [void]$sb.AppendLine("")
    }

    # ── Enrollment Restrictions ────────────────────────────────────────────
    $restrictions = if ($allEnrollConfigs) {
        @($allEnrollConfigs | Where-Object {
            $_.deviceEnrollmentConfigurationType -eq 'deviceEnrollmentPlatformRestrictionsConfiguration' -or
            $_.deviceEnrollmentConfigurationType -eq 'deviceEnrollmentLimitConfiguration' -or
            $_.deviceEnrollmentConfigurationType -eq 'singlePlatformRestriction'
        })
    }

    [void]$sb.AppendLine("### Enrollment Restrictions")
    [void]$sb.AppendLine("")
    if ($restrictions -and $restrictions.Count -gt 0) {
        $summary = foreach ($r in $restrictions) {
            [PSCustomObject]@{
                Name     = $r.displayName
                Type     = $r.deviceEnrollmentConfigurationType
                Priority = $r.priority
            }
        }
        [void]$sb.AppendLine(($summary | Format-Table-Md -Properties 'Name','Type','Priority'))

        foreach ($r in $restrictions) {
            if (-not $r.id) { continue }
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("#### Restriction: $($r.displayName)")
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("- **Type:** $($r.deviceEnrollmentConfigurationType)")
            [void]$sb.AppendLine("- **Priority:** $($r.priority)")
            if ($r.limit) {
                [void]$sb.AppendLine("- **Per-User Device Limit:** $($r.limit)")
            }
            if ($r.platformRestrictions) {
                [void]$sb.AppendLine("")
                [void]$sb.AppendLine("**Platform Restrictions:**")
                [void]$sb.AppendLine("")
                [void]$sb.AppendLine("| Platform | Platform Allowed | Personal Allowed | Min OS | Max OS | Blocked Mfrs |")
                [void]$sb.AppendLine("| --- | --- | --- | --- | --- | --- |")
                foreach ($platform in @('windowsRestriction','windowsHomeSkuRestriction','windowsMobileRestriction','iosRestriction','androidRestriction','androidForWorkRestriction','macOSRestriction','macRestriction')) {
                    $pr = $r.platformRestrictions.$platform
                    if ($pr) {
                        $allowed  = if ($pr.platformBlocked) { 'NO' } else { 'YES' }
                        $personal = if ($pr.personalDeviceEnrollmentBlocked) { 'NO' } else { 'YES' }
                        $blockedMfrs = if ($pr.blockedManufacturers) { ($pr.blockedManufacturers -join ', ') } else { '' }
                        [void]$sb.AppendLine("| $platform | $allowed | $personal | $($pr.osMinimumVersion) | $($pr.osMaximumVersion) | $blockedMfrs |")
                    }
                }
                [void]$sb.AppendLine("")
            }
            $assignments = Get-AssignmentList `
                -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceEnrollmentConfigurations/$($r.id)/assignments" `
                -AuditArea 'Enrollment'
            [void]$sb.AppendLine("**Assignments:**")
            [void]$sb.AppendLine("")
            if ($assignments.Count -gt 0) {
                foreach ($a in $assignments) { [void]$sb.AppendLine("- $a") }
            } else { [void]$sb.AppendLine("- *(default scope)*") }
            [void]$sb.AppendLine("")
        }
    }
    else {
        [void]$sb.AppendLine("*No enrollment restrictions found or access denied.*")
        [void]$sb.AppendLine("")
    }

    Add-ReportSection -Title 'Device Enrollment' -Content $sb.ToString()
}

function Get-AuditConfigProfiles {
    Write-Log "Auditing: Configuration Profiles" -Level INFO
    $sb = [System.Text.StringBuilder]::new()

    # ── Classic Device Configuration profiles ──────────────────────────────
    $profiles = Invoke-GraphRequestSafe `
        -Uri 'https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations' `
        -AuditArea 'ConfigProfiles'

    [void]$sb.AppendLine("### Device Configuration Profiles (Classic)")
    [void]$sb.AppendLine("")
    if ($profiles) {
        $summary = foreach ($p in $profiles) {
            [PSCustomObject]@{
                Name         = $p.displayName
                Type         = ($p.'@odata.type' -replace '#microsoft\.graph\.', '')
                Platform     = if ($p.'@odata.type' -match 'windows') { 'Windows' }
                               elseif ($p.'@odata.type' -match 'ios|iPhone') { 'iOS' }
                               elseif ($p.'@odata.type' -match 'mac|macOS') { 'macOS' }
                               elseif ($p.'@odata.type' -match 'android') { 'Android' }
                               else { 'Other' }
                LastModified = if ($p.lastModifiedDateTime) { ([datetime]$p.lastModifiedDateTime).ToString('yyyy-MM-dd') } else { '' }
            }
        }
        [void]$sb.AppendLine("**Total: $($profiles.Count) classic profile(s)**")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine(($summary | Format-Table-Md -Properties 'Name','Type','Platform','LastModified'))

        foreach ($p in $profiles) {
            if (-not $p.id) { continue }
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("#### Profile: $($p.displayName)")
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("- **Type:** $(($p.'@odata.type') -replace '#microsoft\.graph\.','')")
            if ($p.description) { [void]$sb.AppendLine("- **Description:** $($p.description)") }
            [void]$sb.AppendLine("- **Last Modified:** $($p.lastModifiedDateTime)")
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("**Settings:**")
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine((Format-PropertyDetail -Item $p))
            # OMA-URI placeholder GUID detection (windows10CustomConfiguration)
            if ($p.'@odata.type' -match '(?i)customConfiguration' -and $p.omaSettings) {
                $placeholderOmas = @($p.omaSettings | Where-Object {
                    "$($_.value)$($_.secretReferenceValueId)" -match '00000000-0000-0000-0000-000000000000'
                })
                foreach ($oma in $placeholderOmas) {
                    [void]$sb.AppendLine("> **WARNING:** OMA-URI ``$($oma.omaUri)`` contains placeholder GUID ``00000000-0000-0000-0000-000000000000``. Replace with the client's Azure AD Tenant ID before activating this profile.")
                    [void]$sb.AppendLine("")
                }
            }
            # macOS custom configuration  -  decode base64 payload and check for placeholder GUID
            if ($p.'@odata.type' -match '(?i)macOSCustomConfiguration' -and $p.payload) {
                try {
                    $decoded = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($p.payload))
                    if ($decoded -match '00000000-0000-0000-0000-000000000000') {
                        [void]$sb.AppendLine("> **WARNING:** macOS custom configuration ``$($p.displayName)`` payload contains placeholder GUID ``00000000-0000-0000-0000-000000000000``. Decode the mobileconfig plist, replace with the client's Azure AD Tenant ID, re-encode as Base64, and re-upload.")
                        [void]$sb.AppendLine("")
                    }
                } catch { $null = $_ }
            }
            $assignments = Get-AssignmentList `
                -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations/$($p.id)/assignments" `
                -AuditArea 'ConfigProfiles'
            [void]$sb.AppendLine("**Assignments:**")
            [void]$sb.AppendLine("")
            if ($assignments.Count -gt 0) {
                foreach ($a in $assignments) { [void]$sb.AppendLine("- $a") }
            } else { [void]$sb.AppendLine("- *(unassigned)*") }
            [void]$sb.AppendLine("")
            Write-OverScopeWarning -Sb $sb -PolicyName $p.displayName -Assignments $assignments
        }
    }
    else {
        [void]$sb.AppendLine("*No classic configuration profiles found.*")
        [void]$sb.AppendLine("")
    }

    # ── Settings Catalog policies ──────────────────────────────────────────
    $settingsCatalog = Invoke-GraphRequestSafe `
        -Uri 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?$top=200' `
        -AuditArea 'ConfigProfiles'

    [void]$sb.AppendLine("### Settings Catalog Policies")
    [void]$sb.AppendLine("")
    if ($settingsCatalog) {
        $summary = foreach ($p in $settingsCatalog) {
            [PSCustomObject]@{
                Name         = $p.name
                Platform     = $p.platforms
                Technologies = $p.technologies
                Settings     = $p.settingCount
                LastModified = if ($p.lastModifiedDateTime) { ([datetime]$p.lastModifiedDateTime).ToString('yyyy-MM-dd') } else { '' }
            }
        }
        [void]$sb.AppendLine("**Total: $($settingsCatalog.Count) Settings Catalog polic(ies)**")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine(($summary | Format-Table-Md -Properties 'Name','Platform','Technologies','Settings','LastModified'))

        foreach ($p in $settingsCatalog) {
            if (-not $p.id) { continue }
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("#### Settings Catalog: $($p.name)")
            [void]$sb.AppendLine("")
            if ($p.description) { [void]$sb.AppendLine("> $($p.description)"); [void]$sb.AppendLine("") }
            [void]$sb.AppendLine("- **Platforms:** $($p.platforms)")
            [void]$sb.AppendLine("- **Technologies:** $($p.technologies)")
            [void]$sb.AppendLine("- **Setting Count:** $($p.settingCount)")
            [void]$sb.AppendLine("- **Template Reference:** $($p.templateReference.templateDisplayName)")
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("**Configured Settings:**")
            [void]$sb.AppendLine("")
            $settings = Get-SettingsCatalogValues -PolicyId $p.id
            [void]$sb.AppendLine((Format-SettingsCatalog -Settings $settings))
            $assignments = Get-AssignmentList `
                -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$($p.id)/assignments" `
                -AuditArea 'ConfigProfiles'
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("**Assignments:**")
            [void]$sb.AppendLine("")
            if ($assignments.Count -gt 0) {
                foreach ($a in $assignments) { [void]$sb.AppendLine("- $a") }
            } else { [void]$sb.AppendLine("- *(unassigned)*") }
            [void]$sb.AppendLine("")
        }
    }
    else {
        [void]$sb.AppendLine("*No Settings Catalog policies found or access denied.*")
        [void]$sb.AppendLine("")
    }

    # ── Windows Update Rings ───────────────────────────────────────────────
    $updateRings = if ($profiles) {
        @($profiles | Where-Object { $_.'@odata.type' -match 'windowsUpdateForBusinessConfiguration' })
    }

    [void]$sb.AppendLine("### Windows Update Rings")
    [void]$sb.AppendLine("")
    if ($updateRings -and $updateRings.Count -gt 0) {
        foreach ($u in $updateRings) {
            if (-not $u.id) { continue }
            [void]$sb.AppendLine("#### Update Ring: $($u.displayName)")
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("- **Quality Update Deferral:** $($u.qualityUpdatesDeferralPeriodInDays) day(s)")
            [void]$sb.AppendLine("- **Feature Update Deferral:** $($u.featureUpdatesDeferralPeriodInDays) day(s)")
            [void]$sb.AppendLine("- **Quality Update Pause Until:** $($u.qualityUpdatesPauseExpiryDateTime)")
            [void]$sb.AppendLine("- **Feature Update Pause Until:** $($u.featureUpdatesPauseExpiryDateTime)")
            [void]$sb.AppendLine("- **Auto Update Mode:** $($u.automaticUpdateMode)")
            [void]$sb.AppendLine("- **Microsoft Updates Allowed:** $($u.microsoftUpdateServiceAllowed)")
            [void]$sb.AppendLine("- **Drivers Excluded:** $($u.driversExcluded)")
            [void]$sb.AppendLine("- **Business Ready Updates Only:** $($u.businessReadyUpdatesOnly)")
            [void]$sb.AppendLine("- **Delivery Optimization Mode:** $($u.deliveryOptimizationMode)")
            [void]$sb.AppendLine("- **Pre-Release Feature:** $($u.prereleaseFeatures)")
            [void]$sb.AppendLine("- **Engaged Restart Deadline (days):** $($u.engagedRestartDeadlineInDays)")
            [void]$sb.AppendLine("- **Engaged Restart Snooze (days):** $($u.engagedRestartSnoozeScheduleInDays)")
            [void]$sb.AppendLine("- **Auto Restart Notifications:** $($u.autoRestartNotificationDismissal)")
            [void]$sb.AppendLine("- **Active Hours Start:** $($u.activeHoursStart)")
            [void]$sb.AppendLine("- **Active Hours End:** $($u.activeHoursEnd)")
            [void]$sb.AppendLine("- **Update Notification Level:** $($u.updateNotificationLevel)")
            [void]$sb.AppendLine("- **Allow Windows 11 Upgrade:** $($u.allowWindows11Upgrade)")
            [void]$sb.AppendLine("")
            $assignments = Get-AssignmentList `
                -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations/$($u.id)/assignments" `
                -AuditArea 'ConfigProfiles'
            [void]$sb.AppendLine("**Assignments:**")
            [void]$sb.AppendLine("")
            if ($assignments.Count -gt 0) {
                foreach ($a in $assignments) { [void]$sb.AppendLine("- $a") }
            } else { [void]$sb.AppendLine("- *(unassigned)*") }
            [void]$sb.AppendLine("")
        }
    }
    else {
        [void]$sb.AppendLine("*No Windows Update rings configured.*")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("> **FINDING:** No Update Rings detected. Microsoft recommends at least Pilot + Broad rings to stage Windows quality and feature updates.")
        [void]$sb.AppendLine("")
    }

    Add-ReportSection -Title 'Configuration Profiles' -Content $sb.ToString()
}

function Get-AuditCompliance {
    Write-Log "Auditing: Compliance Policies" -Level INFO
    $sb = [System.Text.StringBuilder]::new()

    $policies = Invoke-GraphRequestSafe `
        -Uri 'https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies' `
        -AuditArea 'Compliance'

    if ($policies) {
        $summary = foreach ($p in $policies) {
            [PSCustomObject]@{
                Name         = $p.displayName
                Platform     = ($p.'@odata.type' -replace '#microsoft\.graph\.', '' -replace 'CompliancePolicy', '')
                LastModified = if ($p.lastModifiedDateTime) { ([datetime]$p.lastModifiedDateTime).ToString('yyyy-MM-dd') } else { '' }
            }
        }
        [void]$sb.AppendLine("**Total: $($policies.Count) compliance polic(ies)**")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine(($summary | Format-Table-Md -Properties 'Name','Platform','LastModified'))

        $unassignedNames = @()
        foreach ($p in $policies) {
            if (-not $p.id) { continue }
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("#### Compliance: $($p.displayName)")
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("- **Platform:** $(($p.'@odata.type') -replace '#microsoft\.graph\.','')")
            if ($p.description) { [void]$sb.AppendLine("- **Description:** $($p.description)") }
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("**Compliance Rules:**")
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine((Format-PropertyDetail -Item $p))

            # Scheduled actions (e.g., mark non-compliant after N days)
            # Note: $expand=scheduledActionConfigurations is not supported on the
            # scheduledActionsForRule collection  -  must fetch configs per rule.
            # Some policy subtypes (e.g. newer compliance engine) reject this nav
            # property entirely with 400; suppress those expected errors.
            $actions = Invoke-GraphRequestSafe `
                -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies/$($p.id)/scheduledActionsForRule" `
                -AuditArea 'Compliance' -Quiet
            if ($actions) {
                [void]$sb.AppendLine("**Scheduled Actions for Non-Compliance:**")
                [void]$sb.AppendLine("")
                foreach ($a in $actions) {
                    if (-not $a.id) { continue }
                    $cfgs = Invoke-GraphRequestSafe `
                        -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies/$($p.id)/scheduledActionsForRule/$($a.id)/scheduledActionConfigurations" `
                        -AuditArea 'Compliance'
                    foreach ($cfg in $cfgs) {
                        [void]$sb.AppendLine("- **$($cfg.actionType)** after $($cfg.gracePeriodHours) hour(s)$(if ($cfg.notificationTemplateId) { " (notification template: $($cfg.notificationTemplateId))" })")
                    }
                }
                [void]$sb.AppendLine("")
            }

            $assignments = Get-AssignmentList `
                -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies/$($p.id)/assignments" `
                -AuditArea 'Compliance'
            [void]$sb.AppendLine("**Assignments:**")
            [void]$sb.AppendLine("")
            if ($assignments.Count -gt 0) {
                foreach ($a in $assignments) { [void]$sb.AppendLine("- $a") }
            } else {
                [void]$sb.AppendLine("- *(unassigned)*")
                $unassignedNames += $p.displayName
            }
            [void]$sb.AppendLine("")
        }

        if ($unassignedNames.Count -gt 0) {
            [void]$sb.AppendLine("> **WARNING:** $($unassignedNames.Count) unassigned compliance polic(ies): $($unassignedNames -join ', ')")
            [void]$sb.AppendLine("")
        }
    }
    else {
        [void]$sb.AppendLine("*No compliance policies found or access denied.*")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("> **FINDING:** No compliance policies detected. Without compliance policies, Conditional Access cannot enforce device-state requirements.")
    }

    Add-ReportSection -Title 'Compliance Policies' -Content $sb.ToString()
}

function Get-AuditApps {
    Write-Log "Auditing: App Management" -Level INFO
    $sb = [System.Text.StringBuilder]::new()

    # ── Mobile apps with assignments (paged  -  no truncation) ──────────────
    $apps = Invoke-GraphRequestPaged `
        -Uri 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?$expand=assignments&$top=200' `
        -AuditArea 'Apps'

    [void]$sb.AppendLine("### Deployed Applications")
    [void]$sb.AppendLine("")
    if ($apps -and $apps.Count -gt 0) {
        # Filter out Microsoft built-in / store catalog noise but keep displayable
        $nonSystem = @($apps | Where-Object { $_.displayName })

        $byType = $nonSystem | Group-Object { $_.'@odata.type' -replace '#microsoft\.graph\.', '' } |
            ForEach-Object { [PSCustomObject]@{ AppType = $_.Name; Count = $_.Count } } |
            Sort-Object Count -Descending

        [void]$sb.AppendLine("**Total: $($nonSystem.Count) application(s)** (paged fetch  -  all results)")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine(($byType | Format-Table-Md -Properties 'AppType','Count'))
        [void]$sb.AppendLine("")

        $unassignedApps = @()
        $appRows = foreach ($a in ($nonSystem | Sort-Object displayName)) {
            $type = ($a.'@odata.type' -replace '#microsoft\.graph\.','')

            # Version: try every known field across app types
            $version = @(
                $a.displayVersion           # Win32 LOB, line-of-business installers
                $a.version                  # Generic
                $a.committedContentVersion  # Win32, MSIX (latest committed package)
                $a.bundleVersion            # iOS LOB (.ipa)
                $a.versionName              # Android LOB (.apk display version)
                $a.versionCode              # Android LOB (numeric)
                $a.productVersion           # MSI / WindowsMobileMSI
                $a.identityVersion          # Android Managed Store
                $a.packageIdentityName      # MSIX/AppX identifier (fallback)
            ) | Where-Object { $_ -and "$_".Trim() -ne '' } | Select-Object -First 1
            if (-not $version) { $version = '-' }

            $assignmentLines = @()
            if ($a.assignments) {
                foreach ($asn in $a.assignments) {
                    $assignmentLines += (Format-Assignment -Target $asn.target -Intent $asn.intent)
                }
            }
            $assignText = if ($assignmentLines.Count -gt 0) { $assignmentLines -join '; ' } else { 'UNASSIGNED' }
            if ($assignmentLines.Count -eq 0) { $unassignedApps += $a.displayName }

            [PSCustomObject]@{
                Name        = $a.displayName
                Type        = $type
                Publisher   = $a.publisher
                Version     = $version
                Assignments = $assignText
            }
        }
        [void]$sb.AppendLine(($appRows | Format-Table-Md -Properties 'Name','Type','Publisher','Version','Assignments'))

        if ($unassignedApps.Count -gt 0) {
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("> **WARNING:** $($unassignedApps.Count) app(s) have no assignment: $(($unassignedApps | Select-Object -First 15) -join ', ')$(if ($unassignedApps.Count -gt 15) { ' ...' })")
            [void]$sb.AppendLine("")
        }

        # ── Baseline app presence check ────────────────────────────────────
        # Company Portal is a baseline expectation for self-service install and
        # compliance visibility. Check by name (multiple variants), bundleId,
        # packageId, and Microsoft Store package family for winGetApp/storeApp.
        $cpMatch = @($apps | Where-Object {
            $_.displayName -match '(?i)company portal' -or
            $_.bundleId -eq 'com.microsoft.CompanyPortal' -or
            $_.packageId -eq 'com.microsoft.windowsintune.companyportal' -or
            $_.packageIdentifier -eq '9wzdncrfj3pz'
        })
        $authMatch = @($apps | Where-Object {
            $_.displayName -match '(?i)microsoft authenticator' -or
            $_.bundleId -eq 'com.azure.authenticator' -or
            $_.packageId -eq 'com.azure.authenticator'
        })
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("### Baseline App Coverage")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("| Baseline App | Deployed? |")
        [void]$sb.AppendLine("| --- | --- |")
        [void]$sb.AppendLine("| Company Portal | $(if ($cpMatch.Count -gt 0) { 'YES (' + $cpMatch.Count + ')' } else { 'NO' }) |")
        [void]$sb.AppendLine("| Microsoft Authenticator | $(if ($authMatch.Count -gt 0) { 'YES (' + $authMatch.Count + ')' } else { 'NO (only required if mobile devices are in scope)' }) |")
        [void]$sb.AppendLine("")
        if ($cpMatch.Count -eq 0) {
            [void]$sb.AppendLine("> **FINDING:** Company Portal not deployed. Without it, end users cannot self-service install assigned apps or view their device compliance status.")
            [void]$sb.AppendLine("")
        }
    }
    else {
        [void]$sb.AppendLine("*No applications found or access denied.*")
        [void]$sb.AppendLine("")
    }

    # ── App Protection Policies (MAM) ──────────────────────────────────────
    $appProtection = Invoke-GraphRequestSafe `
        -Uri 'https://graph.microsoft.com/beta/deviceAppManagement/managedAppPolicies' `
        -AuditArea 'Apps'

    [void]$sb.AppendLine("### App Protection Policies (MAM)")
    [void]$sb.AppendLine("")
    if ($appProtection) {
        $summary = foreach ($p in $appProtection) {
            [PSCustomObject]@{
                Name     = $p.displayName
                Type     = ($p.'@odata.type' -replace '#microsoft\.graph\.', '')
                Platform = if ($p.'@odata.type' -match 'ios') { 'iOS' }
                           elseif ($p.'@odata.type' -match 'android') { 'Android' }
                           elseif ($p.'@odata.type' -match 'windows') { 'Windows' }
                           else { 'Other' }
            }
        }
        [void]$sb.AppendLine("**Total: $($appProtection.Count) MAM polic(ies)**")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine(($summary | Format-Table-Md -Properties 'Name','Type','Platform'))

        foreach ($p in $appProtection) {
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("#### MAM Policy: $($p.displayName)")
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("- **Type:** $(($p.'@odata.type') -replace '#microsoft\.graph\.','')")
            if ($p.description) { [void]$sb.AppendLine("- **Description:** $($p.description)") }
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("**Protection Settings:**")
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine((Format-PropertyDetail -Item $p))
        }
    }
    else {
        [void]$sb.AppendLine("*No app protection policies found or access denied.*")
        [void]$sb.AppendLine("")
    }

    # ── App Configuration Policies ─────────────────────────────────────────
    $appConfig = Invoke-GraphRequestSafe `
        -Uri 'https://graph.microsoft.com/beta/deviceAppManagement/mobileAppConfigurations' `
        -AuditArea 'Apps'

    [void]$sb.AppendLine("### App Configuration Policies")
    [void]$sb.AppendLine("")
    if ($appConfig) {
        foreach ($c in $appConfig) {
            [void]$sb.AppendLine("#### App Config: $($c.displayName)")
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("- **Targeted Apps:** $(($c.targetedMobileApps -join ', '))")
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine((Format-PropertyDetail -Item $c -Skip @('id','displayName','description','version','createdDateTime','lastModifiedDateTime','roleScopeTagIds','@odata.type','@odata.context','targetedMobileApps')))
        }
    }
    else {
        [void]$sb.AppendLine("*No app configuration policies found.*")
        [void]$sb.AppendLine("")
    }

    Add-ReportSection -Title 'App Management' -Content $sb.ToString()
}

function Get-AuditSecurityBaselines {
    Write-Log "Auditing: Security Baselines" -Level INFO
    $sb = [System.Text.StringBuilder]::new()

    # Security baselines use the Intent API
    $intents = Invoke-GraphRequestSafe `
        -Uri 'https://graph.microsoft.com/beta/deviceManagement/intents' `
        -AuditArea 'SecurityBaselines'

    if ($intents) {
        $summary = foreach ($i in $intents) {
            [PSCustomObject]@{
                Name         = $i.displayName
                IsAssigned   = $i.isAssigned
                LastModified = if ($i.lastModifiedDateTime) { ([datetime]$i.lastModifiedDateTime).ToString('yyyy-MM-dd') } else { '' }
                TemplateId   = $i.templateId
            }
        }
        [void]$sb.AppendLine("**Total: $($intents.Count) security baseline instance(s)**")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine(($summary | Format-Table-Md -Properties 'Name','IsAssigned','LastModified','TemplateId'))

        foreach ($i in $intents) {
            if (-not $i.id) { continue }   # skip malformed entries (Graph occasionally returns wrapper rows without id)
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("#### Baseline: $($i.displayName)")
            [void]$sb.AppendLine("")
            if ($i.description) { [void]$sb.AppendLine("> $($i.description)"); [void]$sb.AppendLine("") }
            [void]$sb.AppendLine("- **Template ID:** $($i.templateId)")
            [void]$sb.AppendLine("- **Is Assigned:** $($i.isAssigned)")
            [void]$sb.AppendLine("- **Last Modified:** $($i.lastModifiedDateTime)")
            [void]$sb.AppendLine("")

            $intentSettings = Invoke-GraphRequestSafe `
                -Uri "https://graph.microsoft.com/beta/deviceManagement/intents/$($i.id)/settings" `
                -AuditArea 'SecurityBaselines'
            if ($intentSettings) {
                [void]$sb.AppendLine("**Configured Settings ($($intentSettings.Count)):**")
                [void]$sb.AppendLine("")
                foreach ($s in $intentSettings) {
                    $defKey = if ($s.definitionId) { ($s.definitionId -split '\.' | Select-Object -Last 1) } else { 'unknown' }
                    $val = $s.value
                    if ($null -eq $val -and $s.valueJson) { $val = $s.valueJson }
                    if ($val -is [System.Collections.IDictionary] -or
                        ($val -is [System.Collections.IEnumerable] -and $val -isnot [string])) {
                        try { $val = ($val | ConvertTo-Json -Compress -Depth 4) } catch { $val = "$val" }
                    }
                    $val = "$val" -replace '\|','\|' -replace "`r?`n",' '
                    if ($val.Length -gt 200) { $val = $val.Substring(0,200) + '...' }
                    [void]$sb.AppendLine("- ``$defKey`` = $val")
                }
                [void]$sb.AppendLine("")
            }

            $assignments = Get-AssignmentList `
                -Uri "https://graph.microsoft.com/beta/deviceManagement/intents/$($i.id)/assignments" `
                -AuditArea 'SecurityBaselines'
            [void]$sb.AppendLine("**Assignments:**")
            [void]$sb.AppendLine("")
            if ($assignments.Count -gt 0) {
                foreach ($a in $assignments) { [void]$sb.AppendLine("- $a") }
            } else { [void]$sb.AppendLine("- *(unassigned)*") }
            [void]$sb.AppendLine("")
        }

        # Flag unassigned baselines
        $unassigned = @($intents | Where-Object { $_.isAssigned -eq $false })
        if ($unassigned.Count -gt 0) {
            [void]$sb.AppendLine("> **WARNING:** $($unassigned.Count) security baseline $(if ($unassigned.Count -eq 1) {'instance is'} else {'instances are'}) not assigned: $(($unassigned.displayName) -join ', ')")
            [void]$sb.AppendLine("")
        }
    }
    else {
        [void]$sb.AppendLine("*No security baselines deployed or access denied.*")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("> **FINDING:** No security baselines detected. Microsoft recommends deploying the Windows Security Baseline (current: 25H2), Defender for Endpoint baseline (24H1), and Microsoft Edge baseline (v128).")
        [void]$sb.AppendLine("")
    }

    # Templates available (for version comparison)
    $templates = Invoke-GraphRequestSafe `
        -Uri 'https://graph.microsoft.com/beta/deviceManagement/templates?$filter=templateType%20eq%20%27securityBaseline%27' `
        -AuditArea 'SecurityBaselines'

    if ($templates) {
        [void]$sb.AppendLine("### Available Baseline Templates")
        [void]$sb.AppendLine("")
        $rows = foreach ($t in $templates) {
            [PSCustomObject]@{
                Name    = $t.displayName
                Version = $t.versionInfo
                Id      = $t.id
            }
        }
        [void]$sb.AppendLine(($rows | Format-Table-Md -Properties 'Name','Version','Id'))
    }

    Add-ReportSection -Title 'Security Baselines' -Content $sb.ToString()
}

function Get-AuditEndpointSecurity {
    Write-Log "Auditing: Endpoint Security" -Level INFO
    $sb = [System.Text.StringBuilder]::new()

    # Endpoint security policies via configurationPolicies (includes Settings Catalog)
    $configPolicies = Invoke-GraphRequestSafe `
        -Uri 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?$top=200' `
        -AuditArea 'EndpointSecurity'

    # Filter for endpoint security related
    $secPolicies = @()
    if ($configPolicies) {
        $secPolicies = @($configPolicies | Where-Object {
            $_.technologies -match 'microsoftSense|endpointSecurity|mdm.*defender' -or
            $_.name -match 'BitLocker|Firewall|Antivirus|Defender|ASR|Encryption|Endpoint|Attack Surface|Disk Encryption|EDR|LAPS|Local Admin'
        })
    }

    # Track key-control coverage so we can render a posture summary at the end.
    $coverage = [ordered]@{
        BitLocker         = $false
        BitLockerXts256   = $false
        BitLockerEscrow   = $false
        Firewall          = $false
        DefenderAv        = $false
        AsrRules          = $false
        Laps              = $false
    }

    [void]$sb.AppendLine("### Endpoint Security Policies (Settings Catalog)")
    [void]$sb.AppendLine("")
    if ($secPolicies.Count -gt 0) {
        $summary = foreach ($p in $secPolicies) {
            [PSCustomObject]@{
                Name         = $p.name
                Platform     = $p.platforms
                Technologies = $p.technologies
                Settings     = $p.settingCount
                LastModified = if ($p.lastModifiedDateTime) { ([datetime]$p.lastModifiedDateTime).ToString('yyyy-MM-dd') } else { '' }
            }
        }
        [void]$sb.AppendLine("**Total: $($secPolicies.Count) endpoint security polic(ies)**")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine(($summary | Format-Table-Md -Properties 'Name','Platform','Technologies','Settings','LastModified'))

        foreach ($p in $secPolicies) {
            if (-not $p.id) { continue }
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("#### Endpoint Security: $($p.name)")
            [void]$sb.AppendLine("")
            if ($p.description) { [void]$sb.AppendLine("> $($p.description)"); [void]$sb.AppendLine("") }
            [void]$sb.AppendLine("- **Template:** $($p.templateReference.templateDisplayName)")
            [void]$sb.AppendLine("- **Platforms:** $($p.platforms)")
            [void]$sb.AppendLine("- **Technologies:** $($p.technologies)")
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("**Configured Settings:**")
            [void]$sb.AppendLine("")
            $settings = Get-SettingsCatalogValues -PolicyId $p.id
            [void]$sb.AppendLine((Format-SettingsCatalog -Settings $settings))

            # ── Per-policy posture extraction ─────────────────────────────
            # Inspect raw setting IDs/values to populate the coverage map and
            # surface the most-asked-about details (BitLocker XTS-AES, escrow).
            $tmplName = "$($p.templateReference.templateDisplayName)"
            $isBitLocker = ($p.name -match '(?i)bitlocker|disk encryption' -or $tmplName -match '(?i)bitlocker|disk encryption')
            $isFirewall  = ($p.name -match '(?i)firewall' -or $tmplName -match '(?i)firewall')
            $isAv        = ($p.name -match '(?i)antivirus|defender' -or $tmplName -match '(?i)antivirus')
            $isAsr       = ($p.name -match '(?i)asr|attack surface' -or $tmplName -match '(?i)attack surface')
            $isLaps      = ($p.name -match '(?i)laps|local admin' -or $tmplName -match '(?i)laps|local admin')

            # Gate coverage flags  -  placeholder policies (settingCount = 0) do not count as configured
            $hasSettings = ($p.settingCount -gt 0)
            if ($isBitLocker -and $hasSettings) { $coverage.BitLocker  = $true }
            if ($isFirewall  -and $hasSettings) { $coverage.Firewall   = $true }
            if ($isAv        -and $hasSettings) { $coverage.DefenderAv = $true }
            if ($isAsr       -and $hasSettings) { $coverage.AsrRules   = $true }
            if ($isLaps      -and $hasSettings) { $coverage.Laps       = $true }

            if (-not $hasSettings) {
                [void]$sb.AppendLine("")
                [void]$sb.AppendLine("> **WARNING:** ``$($p.name)`` has no configured settings (settingCount = 0)  -  this is a placeholder policy. Configure settings in the Intune portal (Endpoint Security blade) before this policy can enforce anything.")
                [void]$sb.AppendLine("")
            }

            if ($settings) {
                $highlights = [System.Collections.Generic.List[string]]::new()
                foreach ($s in $settings) {
                    $defId = "$($s.settingInstance.settingDefinitionId)".ToLower()
                    if (-not $defId) { continue }

                    # BitLocker: encryption method (XTS-AES 128/256 etc.) + recovery key escrow
                    if ($isBitLocker -and $defId -match 'encryptionmethodwithxts(os|fdv|rdv)dropdown') {
                        $val = "$($s.settingInstance.choiceSettingValue.value)"
                        $coverage.BitLockerXts256 = $coverage.BitLockerXts256 -or ($val -match '(?i)xtsaes256|_4$')
                        $highlights.Add("Encryption method ($($defId -replace '.*encryptionmethodwith',''))= $val")
                    }
                    if ($isBitLocker -and $defId -match 'osrecovery|fixeddriverecovery|requiredeviceencryption|backuprecoverypasswordstoaad|recoverykeybackup') {
                        $val = "$($s.settingInstance.choiceSettingValue.value)"
                        if ($defId -match 'aad|azuread|backuprecovery') { $coverage.BitLockerEscrow = $true }
                        $highlights.Add("$($defId.Split('_')[-1]) = $val")
                    }

                    # LAPS detection (Settings Catalog template family or LAPS setting prefix)
                    if ($defId -match 'laps') { $coverage.Laps = $true; $isLaps = $true }
                }
                if ($highlights.Count -gt 0) {
                    [void]$sb.AppendLine("")
                    [void]$sb.AppendLine("**Key Settings (extracted):**")
                    [void]$sb.AppendLine("")
                    foreach ($h in $highlights) { [void]$sb.AppendLine("- $h") }
                }
            }

            # Multi-area bundle detection on endpoint-security policies too
            $areas = Get-SettingsCatalogAreas -Settings $settings
            if ($areas.Count -gt 1) {
                [void]$sb.AppendLine("")
                [void]$sb.AppendLine("> **BUNDLED POLICY:** Spans $($areas.Count) areas: $($areas -join ', ').")
            }

            $assignments = Get-AssignmentList `
                -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$($p.id)/assignments" `
                -AuditArea 'EndpointSecurity'
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("**Assignments:**")
            [void]$sb.AppendLine("")
            if ($assignments.Count -gt 0) {
                foreach ($a in $assignments) { [void]$sb.AppendLine("- $a") }
            } else { [void]$sb.AppendLine("- *(unassigned)*") }
            [void]$sb.AppendLine("")
            Write-OverScopeWarning -Sb $sb -PolicyName $p.name -Assignments $assignments
        }
    }
    else {
        [void]$sb.AppendLine("*No dedicated endpoint security policies detected in Settings Catalog.*")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("> **FINDING:** No Settings Catalog endpoint security policies. Verify BitLocker, Defender Antivirus, Firewall, and ASR rules are configured via Endpoint Security blade.")
        [void]$sb.AppendLine("")
    }

    # ── Endpoint-Security Posture Summary ─────────────────────────────────
    [void]$sb.AppendLine("### Endpoint-Security Posture Summary")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("| Control | Status |")
    [void]$sb.AppendLine("| --- | --- |")
    [void]$sb.AppendLine("| BitLocker policy present | $(if ($coverage.BitLocker) { 'YES' } else { 'NO' }) |")
    [void]$sb.AppendLine("| BitLocker XTS-AES 256 | $(if ($coverage.BitLockerXts256) { 'YES' } elseif ($coverage.BitLocker) { 'NOT CONFIRMED (default may be AES-128)' } else { 'N/A' }) |")
    [void]$sb.AppendLine("| BitLocker recovery-key escrow to AAD | $(if ($coverage.BitLockerEscrow) { 'YES' } elseif ($coverage.BitLocker) { 'NOT CONFIRMED' } else { 'N/A' }) |")
    [void]$sb.AppendLine("| Windows Firewall policy | $(if ($coverage.Firewall) { 'YES' } else { 'NO' }) |")
    [void]$sb.AppendLine("| Defender Antivirus policy | $(if ($coverage.DefenderAv) { 'YES' } else { 'NO' }) |")
    [void]$sb.AppendLine("| ASR Rules policy | $(if ($coverage.AsrRules) { 'YES' } else { 'NO' }) |")
    [void]$sb.AppendLine("| Windows LAPS policy | $(if ($coverage.Laps) { 'YES' } else { 'NO' }) |")
    [void]$sb.AppendLine("")
    $missing = @()
    if (-not $coverage.Firewall)   { $missing += 'Windows Firewall' }
    if (-not $coverage.DefenderAv) { $missing += 'Defender Antivirus' }
    if (-not $coverage.AsrRules)   { $missing += 'ASR Rules' }
    if (-not $coverage.Laps)       { $missing += 'Windows LAPS' }
    if ($missing.Count -gt 0) {
        [void]$sb.AppendLine("> **GAPS:** Missing endpoint-security policy types: $($missing -join ', ').")
        [void]$sb.AppendLine("")
    }
    if ($coverage.BitLocker -and -not $coverage.BitLockerXts256) {
        [void]$sb.AppendLine("> **CHECK:** BitLocker policy exists but XTS-AES 256 was not detected. Verify ``encryptionMethodWithXtsOsDropDown`` is set to XTS-AES 256 (default in some templates is AES-128).")
        [void]$sb.AppendLine("")
    }

    # Check for legacy endpoint security via deviceConfigurations
    [void]$sb.AppendLine("### Endpoint Security (Legacy/Classic Profiles)")
    [void]$sb.AppendLine("")

    $legacyEndpoint = Invoke-GraphRequestSafe `
        -Uri 'https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations' `
        -AuditArea 'EndpointSecurity'

    if ($legacyEndpoint) {
        $secLegacy = @($legacyEndpoint | Where-Object {
            $_.'@odata.type' -match 'bitLocker|endpointProtection|windowsDefender|firewall'
        })
        if ($secLegacy.Count -gt 0) {
            $summary = foreach ($p in $secLegacy) {
                [PSCustomObject]@{
                    Name = $p.displayName
                    Type = ($p.'@odata.type' -replace '#microsoft\.graph\.', '')
                }
            }
            [void]$sb.AppendLine(($summary | Format-Table-Md -Properties 'Name','Type'))
            foreach ($p in $secLegacy) {
                [void]$sb.AppendLine("")
                [void]$sb.AppendLine("#### Legacy: $($p.displayName)")
                [void]$sb.AppendLine("")
                [void]$sb.AppendLine((Format-PropertyDetail -Item $p))
            }
        }
        else {
            [void]$sb.AppendLine("*No legacy endpoint security profiles found.*")
            [void]$sb.AppendLine("")
        }
    }

    Add-ReportSection -Title 'Endpoint Security' -Content $sb.ToString()
}

function Get-AuditConditionalAccess {
    Write-Log "Auditing: Conditional Access" -Level INFO
    $sb = [System.Text.StringBuilder]::new()

    $policies = Invoke-GraphRequestSafe `
        -Uri 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies' `
        -AuditArea 'ConditionalAccess'

    if ($policies) {
        $script:CAPolicyCount = @($policies).Count
        $summary = foreach ($p in $policies) {
            [PSCustomObject]@{
                Name          = $p.displayName
                State         = $p.state
                Created       = if ($p.createdDateTime) { ([datetime]$p.createdDateTime).ToString('yyyy-MM-dd') } else { '' }
                Modified      = if ($p.modifiedDateTime) { ([datetime]$p.modifiedDateTime).ToString('yyyy-MM-dd') } else { '' }
            }
        }
        [void]$sb.AppendLine("**Total: $($policies.Count) Conditional Access polic(ies)**")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine(($summary | Format-Table-Md -Properties 'Name','State','Created','Modified'))

        foreach ($p in $policies) {
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("#### CA: $($p.displayName)")
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("- **State:** $($p.state)")
            [void]$sb.AppendLine("- **ID:** $($p.id)")
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("**Conditions  -  Users:**")
            [void]$sb.AppendLine("")
            $u = $p.conditions.users
            $inclUsers  = if ($u.includeUsers)  { (($u.includeUsers  | ForEach-Object { if ($_ -match '^[0-9a-f-]{36}$') { (Resolve-GroupName $_) } else { $_ } }) -join ', ') } else { '' }
            $exclUsers  = if ($u.excludeUsers)  { (($u.excludeUsers  | ForEach-Object { if ($_ -match '^[0-9a-f-]{36}$') { (Resolve-GroupName $_) } else { $_ } }) -join ', ') } else { '' }
            $inclGroups = if ($u.includeGroups) { (($u.includeGroups | ForEach-Object { Resolve-GroupName $_ }) -join ', ') } else { '' }
            $exclGroups = if ($u.excludeGroups) { (($u.excludeGroups | ForEach-Object { Resolve-GroupName $_ }) -join ', ') } else { '' }
            [void]$sb.AppendLine("- **Include Users:** $inclUsers")
            [void]$sb.AppendLine("- **Exclude Users:** $exclUsers")
            [void]$sb.AppendLine("- **Include Groups:** $inclGroups")
            [void]$sb.AppendLine("- **Exclude Groups:** $exclGroups")
            [void]$sb.AppendLine("- **Include Roles:** $(($u.includeRoles -join ', '))")
            [void]$sb.AppendLine("- **Exclude Roles:** $(($u.excludeRoles -join ', '))")
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("**Conditions  -  Applications:**")
            [void]$sb.AppendLine("")
            $a = $p.conditions.applications
            [void]$sb.AppendLine("- **Include Apps:** $(($a.includeApplications -join ', '))")
            [void]$sb.AppendLine("- **Exclude Apps:** $(($a.excludeApplications -join ', '))")
            [void]$sb.AppendLine("- **Include User Actions:** $(($a.includeUserActions -join ', '))")
            [void]$sb.AppendLine("- **Include Auth Contexts:** $(($a.includeAuthenticationContextClassReferences -join ', '))")
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("**Conditions  -  Other:**")
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("- **Client App Types:** $(($p.conditions.clientAppTypes -join ', '))")
            [void]$sb.AppendLine("- **User Risk Levels:** $(($p.conditions.userRiskLevels -join ', '))")
            [void]$sb.AppendLine("- **Sign-in Risk Levels:** $(($p.conditions.signInRiskLevels -join ', '))")
            if ($p.conditions.platforms) {
                [void]$sb.AppendLine("- **Platforms Include:** $(($p.conditions.platforms.includePlatforms -join ', '))")
                [void]$sb.AppendLine("- **Platforms Exclude:** $(($p.conditions.platforms.excludePlatforms -join ', '))")
            }
            if ($p.conditions.locations) {
                [void]$sb.AppendLine("- **Locations Include:** $(($p.conditions.locations.includeLocations -join ', '))")
                [void]$sb.AppendLine("- **Locations Exclude:** $(($p.conditions.locations.excludeLocations -join ', '))")
            }
            if ($p.conditions.devices -and $p.conditions.devices.deviceFilter) {
                [void]$sb.AppendLine("- **Device Filter Mode:** $($p.conditions.devices.deviceFilter.mode)")
                [void]$sb.AppendLine("- **Device Filter Rule:** $($p.conditions.devices.deviceFilter.rule)")
            }
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("**Grant Controls:**")
            [void]$sb.AppendLine("")
            if ($p.grantControls) {
                [void]$sb.AppendLine("- **Operator:** $($p.grantControls.operator)")
                [void]$sb.AppendLine("- **Built-in Controls:** $(($p.grantControls.builtInControls -join ', '))")
                [void]$sb.AppendLine("- **Custom Auth Factors:** $(($p.grantControls.customAuthenticationFactors -join ', '))")
                [void]$sb.AppendLine("- **Terms of Use:** $(($p.grantControls.termsOfUse -join ', '))")
                if ($p.grantControls.authenticationStrength) {
                    [void]$sb.AppendLine("- **Auth Strength:** $($p.grantControls.authenticationStrength.displayName)")
                }
            } else {
                [void]$sb.AppendLine("- *(no grant controls  -  block-only or report-only)*")
            }
            [void]$sb.AppendLine("")
            if ($p.sessionControls) {
                [void]$sb.AppendLine("**Session Controls:**")
                [void]$sb.AppendLine("")
                if ($p.sessionControls.applicationEnforcedRestrictions.isEnabled) { [void]$sb.AppendLine("- **App Enforced Restrictions:** enabled") }
                if ($p.sessionControls.cloudAppSecurity.isEnabled) { [void]$sb.AppendLine("- **MCAS:** enabled ($($p.sessionControls.cloudAppSecurity.cloudAppSecurityType))") }
                if ($p.sessionControls.signInFrequency.isEnabled) {
                    [void]$sb.AppendLine("- **Sign-in Frequency:** $($p.sessionControls.signInFrequency.value) $($p.sessionControls.signInFrequency.type) ($($p.sessionControls.signInFrequency.frequencyInterval))")
                }
                if ($p.sessionControls.persistentBrowser.isEnabled) {
                    [void]$sb.AppendLine("- **Persistent Browser:** $($p.sessionControls.persistentBrowser.mode)")
                }
                if ($p.sessionControls.continuousAccessEvaluation.mode) {
                    [void]$sb.AppendLine("- **CAE Mode:** $($p.sessionControls.continuousAccessEvaluation.mode)")
                }
                [void]$sb.AppendLine("")
            }
        }

        # Findings
        $requireCompliant = @($policies | Where-Object { $_.grantControls.builtInControls -contains 'compliantDevice' -or $_.grantControls.builtInControls -contains 'domainJoinedDevice' })
        if ($requireCompliant.Count -eq 0) {
            [void]$sb.AppendLine("> **FINDING:** No CA policy requires device compliance or Hybrid/Entra Joined. Add a policy that grants only from compliant devices for primary apps.")
            [void]$sb.AppendLine("")
        }
        $disabled = @($policies | Where-Object { $_.state -eq 'disabled' })
        if ($disabled.Count -gt 0) {
            [void]$sb.AppendLine("> **NOTE:** $($disabled.Count) CA polic(ies) disabled: $(($disabled.displayName) -join ', ')")
            [void]$sb.AppendLine("")
        }
        $reportOnly = @($policies | Where-Object { $_.state -eq 'enabledForReportingButNotEnforced' })
        if ($reportOnly.Count -gt 0) {
            [void]$sb.AppendLine("> **NOTE:** $($reportOnly.Count) CA polic(ies) in Report-Only mode: $(($reportOnly.displayName) -join ', ')")
            [void]$sb.AppendLine("")
        }
    }
    else {
        [void]$sb.AppendLine("*No Conditional Access policies found or access denied.*")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("> **FINDING:** No Conditional Access policies detected. This is a significant security gap.")
    }

    Add-ReportSection -Title 'Conditional Access' -Content $sb.ToString()
}

function Get-AuditRBAC {
    Write-Log "Auditing: RBAC & Scope Tags" -Level INFO
    $sb = [System.Text.StringBuilder]::new()

    # ── Role assignments (with members + scope) ────────────────────────────
    $roleAssignments = Invoke-GraphRequestSafe `
        -Uri 'https://graph.microsoft.com/beta/deviceManagement/roleAssignments' `
        -AuditArea 'RBAC'

    [void]$sb.AppendLine("### Role Assignments")
    [void]$sb.AppendLine("")
    if ($roleAssignments) {
        $summary = foreach ($r in $roleAssignments) {
            [PSCustomObject]@{
                Name        = $r.displayName
                Description = if ($r.description -and $r.description.Length -gt 60) { $r.description.Substring(0,60) + '...' } else { $r.description }
            }
        }
        [void]$sb.AppendLine("**Total: $($roleAssignments.Count) role assignment(s)**")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine(($summary | Format-Table-Md -Properties 'Name','Description'))

        foreach ($r in $roleAssignments) {
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("#### Assignment: $($r.displayName)")
            [void]$sb.AppendLine("")
            if ($r.description) { [void]$sb.AppendLine("- **Description:** $($r.description)") }

            # Fetch full assignment with role + scope details
            $detail = Invoke-GraphRequestSafe `
                -Uri "https://graph.microsoft.com/beta/deviceManagement/roleAssignments/$($r.id)?`$expand=roleDefinition,roleScopeTags" `
                -AuditArea 'RBAC'
            if ($detail) {
                if ($detail.roleDefinition) {
                    [void]$sb.AppendLine("- **Role Definition:** $($detail.roleDefinition.displayName)")
                    [void]$sb.AppendLine("- **Built-in Role:** $($detail.roleDefinition.isBuiltIn)")
                }
                $members = $detail.members
                if ($members) {
                    $memberNames = foreach ($m in $members) { Resolve-GroupName $m }
                    [void]$sb.AppendLine("- **Member Groups ($($members.Count)):** $($memberNames -join ', ')")
                }
                $scopeMembers = $detail.scopeMembers
                if ($scopeMembers) {
                    $scopeNames = foreach ($m in $scopeMembers) { Resolve-GroupName $m }
                    [void]$sb.AppendLine("- **Scope Member Groups ($($scopeMembers.Count)):** $($scopeNames -join ', ')")
                }
                if ($detail.scopeType) {
                    [void]$sb.AppendLine("- **Scope Type:** $($detail.scopeType)")
                }
                if ($detail.roleScopeTags) {
                    [void]$sb.AppendLine("- **Scope Tags:** $(($detail.roleScopeTags.displayName) -join ', ')")
                }
            }
            [void]$sb.AppendLine("")
        }
    }
    else {
        [void]$sb.AppendLine("*No custom role assignments found (default Intune Service Admin / Global Admin only).*")
        [void]$sb.AppendLine("")
    }

    # ── Role definitions ───────────────────────────────────────────────────
    $roleDefinitions = Invoke-GraphRequestSafe `
        -Uri 'https://graph.microsoft.com/beta/deviceManagement/roleDefinitions' `
        -AuditArea 'RBAC'

    [void]$sb.AppendLine("### Role Definitions")
    [void]$sb.AppendLine("")
    if ($roleDefinitions) {
        $custom  = @($roleDefinitions | Where-Object { $_.isBuiltIn -eq $false })
        $builtin = @($roleDefinitions | Where-Object { $_.isBuiltIn -eq $true })
        [void]$sb.AppendLine("- Built-in roles: $($builtin.Count)")
        [void]$sb.AppendLine("- Custom roles: $($custom.Count)")
        [void]$sb.AppendLine("")
        if ($custom.Count -gt 0) {
            [void]$sb.AppendLine("**Custom Roles:**")
            [void]$sb.AppendLine("")
            foreach ($c in $custom) {
                [void]$sb.AppendLine("#### Custom Role: $($c.displayName)")
                [void]$sb.AppendLine("")
                if ($c.description) { [void]$sb.AppendLine("- **Description:** $($c.description)") }
                if ($c.rolePermissions) {
                    $allowedActions = @()
                    foreach ($rp in $c.rolePermissions) {
                        foreach ($ra in $rp.resourceActions) {
                            $allowedActions += $ra.allowedResourceActions
                        }
                    }
                    [void]$sb.AppendLine("- **Allowed Actions ($($allowedActions.Count)):** $((($allowedActions | Select-Object -First 25) -join ', '))$(if ($allowedActions.Count -gt 25) { ' ...' })")
                }
                [void]$sb.AppendLine("")
            }
        }
    }

    # ── Scope tags ─────────────────────────────────────────────────────────
    $scopeTags = Invoke-GraphRequestSafe `
        -Uri 'https://graph.microsoft.com/beta/deviceManagement/roleScopeTags' `
        -AuditArea 'RBAC'

    [void]$sb.AppendLine("### Scope Tags")
    [void]$sb.AppendLine("")
    if ($scopeTags) {
        $rows = foreach ($s in $scopeTags) {
            [PSCustomObject]@{
                Name        = $s.displayName
                Id          = $s.id
                Description = $s.description
                IsBuiltIn   = if ($s.id -eq '0') { 'Yes (Default)' } else { 'No' }
            }
        }
        [void]$sb.AppendLine(($rows | Format-Table-Md -Properties 'Name','Id','IsBuiltIn','Description'))

        # Per-tag assignments (which groups can see tagged objects)
        foreach ($s in ($scopeTags | Where-Object { $_.id -ne '0' })) {
            $tagAssign = Invoke-GraphRequestSafe `
                -Uri "https://graph.microsoft.com/beta/deviceManagement/roleScopeTags/$($s.id)/assignments" `
                -AuditArea 'RBAC'
            if ($tagAssign) {
                [void]$sb.AppendLine("")
                [void]$sb.AppendLine("**Scope Tag '$($s.displayName)' assigned to:**")
                [void]$sb.AppendLine("")
                foreach ($t in $tagAssign) {
                    $g = if ($t.target.groupId) { Resolve-GroupName $t.target.groupId } else { ($t.target.'@odata.type' -replace '#microsoft\.graph\.','') }
                    [void]$sb.AppendLine("- $g")
                }
                [void]$sb.AppendLine("")
            }
        }
    }
    else {
        [void]$sb.AppendLine("*Default scope tag only.*")
        [void]$sb.AppendLine("")
    }

    Add-ReportSection -Title 'RBAC & Scope Tags' -Content $sb.ToString()
}

function Get-AuditDeviceStatus {
    Write-Log "Auditing: Reporting & Monitoring" -Level INFO
    $sb = [System.Text.StringBuilder]::new()

    # Managed device overview
    $overview = Invoke-GraphRequestSafe `
        -Uri 'https://graph.microsoft.com/beta/deviceManagement/managedDeviceOverview' `
        -AuditArea 'Reporting'

    [void]$sb.AppendLine("### Managed Device Overview")
    [void]$sb.AppendLine("")
    if ($overview) {
        [void]$sb.AppendLine("| Metric | Count |")
        [void]$sb.AppendLine("| --- | --- |")
        [void]$sb.AppendLine("| Enrolled Devices | $($overview.enrolledDeviceCount) |")
        [void]$sb.AppendLine("| MDM Enrolled | $($overview.mdmEnrolledCount) |")
        [void]$sb.AppendLine("| Co-Managed | $($overview.dualEnrolledDeviceCount) |")
        [void]$sb.AppendLine("")

        if ($overview.deviceOperatingSystemSummary) {
            $os = $overview.deviceOperatingSystemSummary
            [void]$sb.AppendLine("**OS Distribution:**")
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("| OS | Count |")
            [void]$sb.AppendLine("| --- | --- |")
            [void]$sb.AppendLine("| Windows | $($os.windowsCount) |")
            [void]$sb.AppendLine("| iOS | $($os.iosCount) |")
            [void]$sb.AppendLine("| macOS | $($os.macOSCount) |")
            [void]$sb.AppendLine("| Android | $($os.androidCount) |")
            [void]$sb.AppendLine("")
        }
    }
    else {
        [void]$sb.AppendLine("*Device overview unavailable or access denied.*")
        [void]$sb.AppendLine("")
    }

    # Device compliance summary
    $complianceSummary = Invoke-GraphRequestSafe `
        -Uri 'https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicyDeviceStateSummary' `
        -AuditArea 'Reporting'

    [void]$sb.AppendLine("### Compliance Status Summary")
    [void]$sb.AppendLine("")
    if ($complianceSummary) {
        [void]$sb.AppendLine("| Status | Count |")
        [void]$sb.AppendLine("| --- | --- |")
        [void]$sb.AppendLine("| Compliant | $($complianceSummary.compliantDeviceCount) |")
        [void]$sb.AppendLine("| Non-Compliant | $($complianceSummary.nonCompliantDeviceCount) |")
        [void]$sb.AppendLine("| In Grace Period | $($complianceSummary.inGracePeriodCount) |")
        [void]$sb.AppendLine("| Conflict | $($complianceSummary.conflictDeviceCount) |")
        [void]$sb.AppendLine("| Not Evaluated | $($complianceSummary.notApplicableDeviceCount) |")
        [void]$sb.AppendLine("| Error | $($complianceSummary.errorDeviceCount) |")
        [void]$sb.AppendLine("")

        $total = $complianceSummary.compliantDeviceCount + $complianceSummary.nonCompliantDeviceCount +
                 $complianceSummary.inGracePeriodCount + $complianceSummary.conflictDeviceCount
        if ($total -gt 0) {
            $complianceRate = [math]::Round(($complianceSummary.compliantDeviceCount / $total) * 100, 1)
            [void]$sb.AppendLine("**Compliance Rate: ${complianceRate}%**")
            [void]$sb.AppendLine("")
            if ($complianceRate -lt 80) {
                [void]$sb.AppendLine("> **WARNING:** Compliance rate below 80%. Review non-compliant devices and policy assignments.")
            }
        }
    }
    else {
        [void]$sb.AppendLine("*Compliance summary unavailable or access denied.*")
        [void]$sb.AppendLine("")
    }

    # ── Audit Log Accessibility ─────────────────────────────────────────────
    [void]$sb.AppendLine("### Intune Audit Log")
    [void]$sb.AppendLine("")
    $auditEvents = Invoke-GraphRequestSafe `
        -Uri 'https://graph.microsoft.com/beta/deviceManagement/auditEvents?$top=1&$orderby=activityDateTime desc' `
        -AuditArea 'Reporting' -Quiet
    if ($auditEvents) {
        $latest = if ($auditEvents -is [array]) { $auditEvents[0] } else { $auditEvents }
        [void]$sb.AppendLine("- Audit-log endpoint accessible.")
        if ($latest.activityDateTime) {
            [void]$sb.AppendLine("- Most recent audit event: ``$($latest.activityDateTime)`` ($($latest.activity))")
        }
        [void]$sb.AppendLine("- Intune retains audit logs for **1 year** by default. Forward to Log Analytics for longer retention.")
    }
    else {
        [void]$sb.AppendLine("> **WARNING:** Could not read Intune audit events. Permission ``DeviceManagementApps.Read.All`` or admin role may be missing.")
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("> **NOTE:** Azure Monitor diagnostic settings (Log Analytics / Storage / Event Hub forwarding for Intune logs) live in Azure Resource Manager and cannot be enumerated via Microsoft Graph. **Manually verify** in Intune admin center → Tenant administration → Diagnostic settings that ``AuditLogs``, ``OperationalLogs``, and ``DeviceComplianceOrg`` categories are forwarded to a Log Analytics workspace.")
    [void]$sb.AppendLine("")

    # ── Endpoint Analytics ──────────────────────────────────────────────────
    [void]$sb.AppendLine("### Endpoint Analytics")
    [void]$sb.AppendLine("")
    $eaSettings = Invoke-GraphRequestSafe `
        -Uri 'https://graph.microsoft.com/beta/deviceManagement/userExperienceAnalyticsSettings' `
        -AuditArea 'Reporting' -Quiet
    if ($eaSettings) {
        $eaEnabled = [bool]$eaSettings.configurationManagerDataConnectorConfigured -or
                     ($null -ne $eaSettings.id)
        [void]$sb.AppendLine("- Endpoint Analytics settings object: present")
        if ($null -ne $eaSettings.configurationManagerDataConnectorConfigured) {
            [void]$sb.AppendLine("- Configuration Manager data connector: $($eaSettings.configurationManagerDataConnectorConfigured)")
        }
        if (-not $eaEnabled) {
            [void]$sb.AppendLine("> **FINDING:** Endpoint Analytics appears unconfigured. Enable to gain startup performance, app reliability, and proactive remediation insights (no extra license cost for Intune-licensed devices).")
        }
    }
    else {
        [void]$sb.AppendLine("> **FINDING:** Endpoint Analytics endpoint not reachable or feature not enabled. Microsoft recommends enabling Endpoint Analytics for proactive device-experience monitoring.")
    }
    [void]$sb.AppendLine("")

    # ── App Install Summary ─────────────────────────────────────────────────
    [void]$sb.AppendLine("### App Install Summary")
    [void]$sb.AppendLine("")
    try {
        $reportBody = @{
            select  = @('DisplayName','Platform','AppVersion','FailedDeviceCount','InstalledDeviceCount','PendingInstallDeviceCount','NotApplicableDeviceCount','NotInstalledDeviceCount')
            skip    = 0
            top     = 50
            orderBy = @('FailedDeviceCount desc')
        } | ConvertTo-Json -Depth 4
        $appReport = Invoke-MgGraphRequest -Method POST `
            -Uri 'https://graph.microsoft.com/beta/deviceManagement/reports/getAppsInstallSummaryReport' `
            -Body $reportBody -ContentType 'application/json' -ErrorAction Stop
        $rows = @()
        if ($appReport.Schema -and $appReport.Values) {
            $cols = $appReport.Schema | ForEach-Object { $_.Column }
            foreach ($r in $appReport.Values) {
                $obj = [ordered]@{}
                for ($i = 0; $i -lt $cols.Count; $i++) { $obj[$cols[$i]] = $r[$i] }
                $rows += [PSCustomObject]$obj
            }
        }
        if ($rows.Count -gt 0) {
            $totalFailed = ($rows | Measure-Object -Property FailedDeviceCount -Sum).Sum
            [void]$sb.AppendLine("Top $([Math]::Min(15, $rows.Count)) apps by failed install count:")
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine(($rows | Select-Object -First 15 | Format-Table-Md -Properties 'DisplayName','Platform','FailedDeviceCount','InstalledDeviceCount','NotInstalledDeviceCount'))
            if ($totalFailed -gt 0) {
                [void]$sb.AppendLine("> **WARNING:** $totalFailed total app install failures across reported apps. Investigate top offenders and validate detection rules / requirements.")
            }
        }
        else {
            [void]$sb.AppendLine("*No app install summary rows returned.*")
        }
    }
    catch {
        [void]$sb.AppendLine("*App install summary report unavailable: $($_.Exception.Message)*")
    }
    [void]$sb.AppendLine("")

    Add-ReportSection -Title 'Reporting & Monitoring' -Content $sb.ToString()
}

function Get-AuditLicensing {
    Write-Log "Auditing: Licensing" -Level INFO
    $sb = [System.Text.StringBuilder]::new()

    $skus = Invoke-GraphRequestSafe `
        -Uri 'https://graph.microsoft.com/v1.0/subscribedSkus' `
        -AuditArea 'Licensing'

    if ($skus) {
        # Filter to Intune-relevant SKUs
        $intuneSkuIds = @(
            'INTUNE_A'              # Intune Plan 1
            'INTUNE_EDU'            # Intune for Education
            'INTUNE_PLAN2'          # Intune Plan 2 (add-on)
            'INTUNE_SUITE'          # Intune Suite
            'SPE_E3'               # Microsoft 365 E3 (includes Intune P1)
            'SPE_E5'               # Microsoft 365 E5 (includes Intune P1)
            'SPB'                  # Microsoft 365 Business Premium
            'MICROSOFT_365_BUSINESS_STANDARD' # M365 Business Standard
            'EMS_E3'              # EMS E3
            'EMS_E5'              # EMS E5
            'AAD_PREMIUM_P1'      # Entra ID P1
            'AAD_PREMIUM_P2'      # Entra ID P2
        )

        $relevantSkus = @($skus | Where-Object {
            $_.skuPartNumber -in $intuneSkuIds -or
            $_.skuPartNumber -match 'INTUNE|EMS|MICROSOFT_365|SPE_E|SPB|AAD_PREMIUM'
        })

        [void]$sb.AppendLine("### Intune-Relevant Licenses")
        [void]$sb.AppendLine("")

        if ($relevantSkus.Count -gt 0) {
            $rows = foreach ($s in $relevantSkus) {
                [PSCustomObject]@{
                    License   = $s.skuPartNumber
                    Total     = $s.prepaidUnits.enabled
                    Assigned  = $s.consumedUnits
                    Available = $s.prepaidUnits.enabled - $s.consumedUnits
                    Status    = $s.capabilityStatus
                }
            }
            [void]$sb.AppendLine(($rows | Format-Table-Md -Properties 'License','Total','Assigned','Available','Status'))
        }
        else {
            [void]$sb.AppendLine("*No Intune-specific licenses detected. The tenant may use bundled licensing (M365 E3/E5/BP).*")
            [void]$sb.AppendLine("")
        }

        # Show all SKUs for completeness
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("### All Subscribed SKUs")
        [void]$sb.AppendLine("")
        $allRows = foreach ($s in $skus) {
            [PSCustomObject]@{
                SKU       = $s.skuPartNumber
                Total     = $s.prepaidUnits.enabled
                Assigned  = $s.consumedUnits
                Status    = $s.capabilityStatus
            }
        }
        [void]$sb.AppendLine(($allRows | Format-Table-Md -Properties 'SKU','Total','Assigned','Status'))
    }
    else {
        [void]$sb.AppendLine("*License information unavailable or access denied.*")
        [void]$sb.AppendLine("")
    }

    # ── Intune Suite Feature Signals ────────────────────────────────────────
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("### Intune Suite Feature Utilization")
    [void]$sb.AppendLine("")

    # Remote Help
    $remoteHelp = Invoke-GraphRequestSafe `
        -Uri 'https://graph.microsoft.com/beta/deviceManagement/remoteAssistanceSettings' `
        -AuditArea 'Licensing' -Quiet
    $rhState = if ($remoteHelp -and $remoteHelp.remoteAssistanceState) {
        $remoteHelp.remoteAssistanceState
    } elseif ($remoteHelp) { 'present (state unknown)' } else { 'not reachable' }

    # Microsoft Tunnel
    $tunnelSites = Invoke-GraphRequestSafe `
        -Uri 'https://graph.microsoft.com/beta/deviceManagement/microsoftTunnelSites' `
        -AuditArea 'Licensing' -Quiet
    $tunnelCount = if ($tunnelSites) { @($tunnelSites).Count } else { 0 }

    # Endpoint Privilege Management policies
    $epm = Invoke-GraphRequestSafe `
        -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?`$filter=technologies has 'endpointPrivilegeManagement'&`$select=id,name" `
        -AuditArea 'Licensing' -Quiet
    $epmCount = if ($epm) { @($epm).Count } else { 0 }

    [void]$sb.AppendLine("| Feature | Status | Notes |")
    [void]$sb.AppendLine("| --- | --- | --- |")
    [void]$sb.AppendLine("| Remote Help | $rhState | Requires Intune Suite or Remote Help add-on |")
    [void]$sb.AppendLine("| Microsoft Tunnel | $tunnelCount site(s) | Requires Intune Plan 2 / Suite |")
    [void]$sb.AppendLine("| Endpoint Privilege Management | $epmCount polic(ies) | Requires Intune Suite or EPM add-on |")
    [void]$sb.AppendLine("")
    if ($rhState -eq 'not reachable' -and $tunnelCount -eq 0 -and $epmCount -eq 0) {
        [void]$sb.AppendLine("> **NOTE:** No Intune Suite premium features detected in active use. If the tenant holds Intune Suite or Plan 2 licenses, these features are unutilized.")
    }
    [void]$sb.AppendLine("")

    # ── Entra ID P1/P2 Utilization Markers ─────────────────────────────────
    [void]$sb.AppendLine("### Entra ID Premium Utilization Markers")
    [void]$sb.AppendLine("")
    $caCount = if ($script:CAPolicyCount -is [int]) { $script:CAPolicyCount } else { '?' }
    [void]$sb.AppendLine("- Conditional Access policies in tenant: **$caCount** (any non-zero count requires Entra ID P1)")

    # Risky users (P2 indicator)
    $p2Indicator = $false
    try {
        $risky = Invoke-MgGraphRequest -Method GET `
            -Uri 'https://graph.microsoft.com/v1.0/identityProtection/riskyUsers?$top=1' `
            -ErrorAction Stop
        $p2Indicator = $true
        $riskyCount = if ($risky.value) { @($risky.value).Count } else { 0 }
        [void]$sb.AppendLine("- Identity Protection (riskyUsers) endpoint: **reachable** (Entra ID P2 indicator). Sample risky users returned: $riskyCount")
    }
    catch {
        [void]$sb.AppendLine("- Identity Protection (riskyUsers) endpoint: not reachable. Tenant may lack Entra ID P2 or caller lacks ``IdentityRiskyUser.Read.All``.")
    }

    # PIM (P2 indicator)
    try {
        $pim = Invoke-MgGraphRequest -Method GET `
            -Uri 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleEligibilityScheduleInstances?$top=1' `
            -ErrorAction Stop
        $pimCount = if ($pim.value) { @($pim.value).Count } else { 0 }
        [void]$sb.AppendLine("- Privileged Identity Management eligible-role instances (sampled): $pimCount (Entra ID P2 indicator)")
        if (-not $p2Indicator -and $pimCount -gt 0) { $p2Indicator = $true }
    }
    catch {
        [void]$sb.AppendLine("- PIM endpoint: not reachable. Tenant may lack Entra ID P2 or caller lacks ``RoleManagement.Read.Directory``.")
    }

    if (-not $p2Indicator) {
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("> **NOTE:** No Entra ID P2 utilization detected. If P2 licenses are owned (e.g. via M365 E5), Identity Protection and PIM are unutilized.")
    }
    [void]$sb.AppendLine("")

    Add-ReportSection -Title 'Licensing' -Content $sb.ToString()
}

function Get-AuditPlatformReadiness {
    Write-Log "Auditing: Platform Readiness (APNs / Android Enterprise / VPP)" -Level INFO
    $sb = [System.Text.StringBuilder]::new()

    # ── Apple Push Notification certificate (iOS / iPadOS / macOS) ─────────
    $apns = Invoke-GraphRequestSafe `
        -Uri 'https://graph.microsoft.com/beta/deviceManagement/applePushNotificationCertificate' `
        -AuditArea 'PlatformReadiness' -Quiet
    [void]$sb.AppendLine("### Apple Push Notification Certificate (APNs)")
    [void]$sb.AppendLine("")
    if ($apns -and $apns.appleIdentifier) {
        $expiry = if ($apns.expirationDateTime) { ([datetime]$apns.expirationDateTime) } else { $null }
        $daysLeft = if ($expiry) { [math]::Floor(($expiry - (Get-Date)).TotalDays) } else { $null }
        [void]$sb.AppendLine("- **Apple ID:** $($apns.appleIdentifier)")
        [void]$sb.AppendLine("- **Topic Identifier:** $($apns.topicIdentifier)")
        [void]$sb.AppendLine("- **Expiration:** $(if ($expiry) { $expiry.ToString('yyyy-MM-dd') } else { '(unknown)' })$(if ($null -ne $daysLeft) { " ($daysLeft days left)" })")
        [void]$sb.AppendLine("- **Last Modified:** $($apns.lastModifiedDateTime)")
        [void]$sb.AppendLine("")
        if ($null -ne $daysLeft -and $daysLeft -lt 30) {
            [void]$sb.AppendLine("> **EXPIRING:** APNs certificate expires in $daysLeft day(s). Renew immediately or iOS/iPadOS/macOS enrollment will break.")
            [void]$sb.AppendLine("")
        }
    } else {
        [void]$sb.AppendLine("*No APNs certificate configured.*")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("> **NOTE:** APNs is **required** for any iOS, iPadOS or macOS enrollment. Pre-configure if mobile/Mac devices are planned.")
        [void]$sb.AppendLine("")
    }

    # ── Apple VPP / ABM tokens ─────────────────────────────────────────────
    $vpp = Invoke-GraphRequestSafe `
        -Uri 'https://graph.microsoft.com/beta/deviceAppManagement/vppTokens' `
        -AuditArea 'PlatformReadiness' -Quiet
    [void]$sb.AppendLine("### Apple VPP / Apps & Books Tokens")
    [void]$sb.AppendLine("")
    if ($vpp -and $vpp.Count -gt 0) {
        $rows = foreach ($t in $vpp) {
            [PSCustomObject]@{
                AppleId    = $t.appleId
                OrgName    = $t.organizationName
                State      = $t.state
                Country    = $t.countryOrRegion
                Expires    = if ($t.expirationDateTime) { ([datetime]$t.expirationDateTime).ToString('yyyy-MM-dd') } else { '' }
                LastSync   = if ($t.lastSyncDateTime)  { ([datetime]$t.lastSyncDateTime).ToString('yyyy-MM-dd') } else { '' }
            }
        }
        [void]$sb.AppendLine(($rows | Format-Table-Md -Properties 'AppleId','OrgName','State','Country','Expires','LastSync'))
        [void]$sb.AppendLine("")
    } else {
        [void]$sb.AppendLine("*No VPP / Apps & Books tokens configured.*")
        [void]$sb.AppendLine("")
    }

    # ── Apple Device Enrollment Program (DEP / ABM) ────────────────────────
    $dep = Invoke-GraphRequestSafe `
        -Uri 'https://graph.microsoft.com/beta/deviceManagement/depOnboardingSettings' `
        -AuditArea 'PlatformReadiness' -Quiet
    [void]$sb.AppendLine("### Apple ABM/DEP Tokens")
    [void]$sb.AppendLine("")
    if ($dep -and $dep.Count -gt 0) {
        $rows = foreach ($d in $dep) {
            [PSCustomObject]@{
                AppleId  = $d.appleIdentifier
                TokenType = $d.tokenType
                Expires  = if ($d.tokenExpirationDateTime) { ([datetime]$d.tokenExpirationDateTime).ToString('yyyy-MM-dd') } else { '' }
                LastSync = if ($d.lastSyncTriggeredDateTime) { ([datetime]$d.lastSyncTriggeredDateTime).ToString('yyyy-MM-dd') } else { '' }
                SyncOk   = $null -ne $d.lastSuccessfulSyncDateTime
            }
        }
        [void]$sb.AppendLine(($rows | Format-Table-Md -Properties 'AppleId','TokenType','Expires','LastSync','SyncOk'))
        [void]$sb.AppendLine("")
    } else {
        [void]$sb.AppendLine("*No Apple ABM/DEP tokens configured.*")
        [void]$sb.AppendLine("")
    }

    # ── Android Enterprise binding ─────────────────────────────────────────
    $aeBinding = Invoke-GraphRequestSafe `
        -Uri 'https://graph.microsoft.com/beta/deviceManagement/androidManagedStoreAccountEnterpriseSettings' `
        -AuditArea 'PlatformReadiness' -Quiet
    [void]$sb.AppendLine("### Android Enterprise (Managed Google Play)")
    [void]$sb.AppendLine("")
    if ($aeBinding -and $aeBinding.bindStatus) {
        [void]$sb.AppendLine("- **Bind Status:** $($aeBinding.bindStatus)")
        [void]$sb.AppendLine("- **Owner Account:** $($aeBinding.ownerUserPrincipalName)")
        [void]$sb.AppendLine("- **Enterprise ID:** $($aeBinding.enterpriseId)")
        [void]$sb.AppendLine("- **Last Modified:** $($aeBinding.lastModifiedDateTime)")
        [void]$sb.AppendLine("- **Device Owner Mgmt Enabled:** $($aeBinding.deviceOwnerManagementEnabled)")
        [void]$sb.AppendLine("")
        if ($aeBinding.bindStatus -ne 'bound') {
            [void]$sb.AppendLine("> **NOTE:** Android Enterprise is not in 'bound' state. Re-bind before enrolling Android Work Profile or Fully Managed devices.")
            [void]$sb.AppendLine("")
        }
    } else {
        [void]$sb.AppendLine("*Android Enterprise not bound.*")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("> **NOTE:** Required for Android Work Profile / Fully Managed enrollment. Pre-configure if Android devices are planned.")
        [void]$sb.AppendLine("")
    }

    Add-ReportSection -Title 'Platform Readiness (APNs / VPP / Android Enterprise)' -Content $sb.ToString()
}

function Get-AuditGroupInventory {
    Write-Log "Auditing: Group Inventory" -Level INFO
    $sb = [System.Text.StringBuilder]::new()

    # GroupCache is populated as Resolve-GroupName is called from every other
    # audit section, so by the time this runs we have a deduped list of every
    # group referenced by any Intune object in the tenant.
    if (-not $script:GroupCache -or $script:GroupCache.Count -eq 0) {
        [void]$sb.AppendLine("*No groups were referenced by any audited Intune object.*")
        Add-ReportSection -Title 'Group Inventory (Referenced by Intune Objects)' -Content $sb.ToString()
        return
    }

    [void]$sb.AppendLine("Consolidated list of Entra ID groups referenced by any Intune object")
    [void]$sb.AppendLine("(assignments, exclusions, CA conditions, RBAC scopes). Total: **$($script:GroupCache.Count)**.")
    [void]$sb.AppendLine("")

    # Try to enrich with group type (security/M365, dynamic/assigned).
    $rows = foreach ($id in ($script:GroupCache.Keys | Sort-Object { $script:GroupCache[$_] })) {
        $name = $script:GroupCache[$id]
        $detail = $null
        if ($id -match '^[0-9a-f-]{36}$') {
            $detail = Invoke-GraphRequestSafe `
                -Uri "https://graph.microsoft.com/v1.0/groups/$id`?`$select=id,displayName,securityEnabled,mailEnabled,groupTypes,membershipRule,membershipRuleProcessingState" `
                -AuditArea 'GroupInventory' -Quiet
        }
        $kind = if ($detail) {
            if ($detail.groupTypes -contains 'Unified') { 'M365' }
            elseif ($detail.securityEnabled -and -not $detail.mailEnabled) { 'Security' }
            elseif ($detail.mailEnabled -and $detail.securityEnabled) { 'Mail-enabled Security' }
            elseif ($detail.mailEnabled) { 'Distribution' }
            else { '?' }
        } else { '?' }
        $member = if ($detail -and $detail.groupTypes -contains 'DynamicMembership') {
            "Dynamic ($($detail.membershipRuleProcessingState))"
        } elseif ($detail) { 'Assigned' } else { '?' }
        [PSCustomObject]@{
            DisplayName    = $name
            Type           = $kind
            Membership     = $member
            MembershipRule = if ($detail) { "$($detail.membershipRule)" } else { '' }
            ObjectId       = $id
        }
    }
    [void]$sb.AppendLine(($rows | Format-Table-Md -Properties 'DisplayName','Type','Membership','ObjectId'))
    [void]$sb.AppendLine("")

    # Quick health flags
    $assigned = @($rows | Where-Object { $_.Membership -eq 'Assigned' })
    if ($assigned.Count -gt 0) {
        [void]$sb.AppendLine("> **NOTE:** $($assigned.Count) of $($rows.Count) referenced group(s) use **assigned** membership. Consider dynamic device groups for self-maintaining baseline assignment.")
        [void]$sb.AppendLine("")
    }

    # Dynamic group rule attribute validation
    $wrongAttr = @($rows | Where-Object { $_.MembershipRule -match 'device\.operatingSystem' })
    foreach ($g in $wrongAttr) {
        [void]$sb.AppendLine("> **WARNING:** Group ``$($g.DisplayName)`` uses ``device.operatingSystem`` in its membership rule. The correct attribute for Intune device dynamic groups is ``device.deviceOSType``. Update the rule in Entra ID (Entra admin center \u2192 Groups \u2192 $($g.DisplayName) \u2192 Dynamic membership rules).")
        [void]$sb.AppendLine("")
    }

    # Baseline group coverage  -  direct query for all expected TenantPrep GRP-* groups
    [void]$sb.AppendLine("### Baseline Group Coverage")
    [void]$sb.AppendLine("")
    $expectedBaselineGroups = @(
        'GRP-WIN-Autopilot-UserDriven', 'GRP-WIN-Config-All', 'GRP-WIN-Compliance-All',
        'GRP-WIN-Security-Baseline', 'GRP-WIN-UpdateRing-Broad', 'GRP-WIN-UpdateRing-Pilot',
        'GRP-IOS-Config-All', 'GRP-IOS-Compliance-All', 'GRP-IOS-Apps-All',
        'GRP-MAC-Config-All', 'GRP-MAC-Compliance-All',
        'GRP-ALL-Enrollment-Allowed', 'GRP-ALL-CA-Excluded'
    )
    $gGrpQuery = Invoke-GraphRequestSafe `
        -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=startsWith(displayName,'GRP-')&`$select=displayName,id&`$top=200" `
        -AuditArea 'GroupInventory'
    $foundGrpNames = if ($gGrpQuery) { @($gGrpQuery | ForEach-Object { $_.displayName }) } else { @() }
    $missingBaselineGroups = @($expectedBaselineGroups | Where-Object { $_ -notin $foundGrpNames })
    [void]$sb.AppendLine("| Group | Present |")
    [void]$sb.AppendLine("| --- | --- |")
    foreach ($g in $expectedBaselineGroups) {
        $status = if ($g -in $foundGrpNames) { 'YES' } else { '**NO**' }
        [void]$sb.AppendLine("| $g | $status |")
    }
    [void]$sb.AppendLine("")
    if ($missingBaselineGroups.Count -gt 0) {
        [void]$sb.AppendLine("> **FINDING:** $($missingBaselineGroups.Count) expected baseline group(s) not found in this tenant: $($missingBaselineGroups -join ', '). Run ``Invoke-IntuneTenantPrep -Mode Deploy`` to create them.")
        [void]$sb.AppendLine("")
    } else {
        [void]$sb.AppendLine("*All 13 expected baseline groups are present.*")
        [void]$sb.AppendLine("")
    }

    Add-ReportSection -Title 'Group Inventory (Referenced by Intune Objects)' -Content $sb.ToString()
}

# ─── Report Assembly ──────────────────────────────────────────────────────────

function Build-ReportHeader {
    $context = Get-MgContext
    [void]$script:Report.AppendLine("# Intune Deployment Audit  -  $script:ClientName")
    [void]$script:Report.AppendLine("")
    [void]$script:Report.AppendLine("| Field | Value |")
    [void]$script:Report.AppendLine("| --- | --- |")
    [void]$script:Report.AppendLine("| **Client** | $script:ClientName |")
    [void]$script:Report.AppendLine("| **Tenant ID** | $($context.TenantId) |")
    [void]$script:Report.AppendLine("| **Audit Date** | $(Get-Date -Format 'yyyy-MM-dd HH:mm') |")
    [void]$script:Report.AppendLine("| **Auditor** | $($context.Account) |")
    [void]$script:Report.AppendLine("| **Script Version** | 1.4.0 |")
    [void]$script:Report.AppendLine("| **Scope** | Read-only export  -  all Intune policy areas, per-item detail, gap-assessment helpers |")
    [void]$script:Report.AppendLine("")
    [void]$script:Report.AppendLine("> This report was generated by ``Invoke-IntuneAudit.ps1``. It is an inventory export,")
    [void]$script:Report.AppendLine("> not an assessment. Feed this report to the **IntuneAdvisor** agent or review manually")
    [void]$script:Report.AppendLine("> against Microsoft best practices.")
    [void]$script:Report.AppendLine("")
    [void]$script:Report.AppendLine("### Audit Scope")
    [void]$script:Report.AppendLine("")
    [void]$script:Report.AppendLine("1. Tenant Overview  -  object counts and device totals")
    [void]$script:Report.AppendLine("2. Co-Management  -  management-agent breakdown and per-workload Intune-vs-SCCM authority")
    [void]$script:Report.AppendLine("3. Device Enrollment  -  methods, restrictions, Autopilot configuration")
    [void]$script:Report.AppendLine("4. Configuration Profiles  -  redundancy, conflicts, outdated settings, multi-area bundles, update rings")
    [void]$script:Report.AppendLine("5. Compliance Policies  -  rules and conditional access integration")
    [void]$script:Report.AppendLine("6. App Management  -  deployment, MAM protection, baseline app coverage (Company Portal)")
    [void]$script:Report.AppendLine("7. Security Baselines  -  vs Microsoft latest baselines")
    [void]$script:Report.AppendLine("8. Endpoint Security  -  BitLocker XTS-AES, Defender, Firewall, ASR, LAPS posture summary")
    [void]$script:Report.AppendLine("9. Conditional Access  -  device-compliance integration check")
    [void]$script:Report.AppendLine("10. Role-Based Access (RBAC)  -  admin roles and scope tags")
    [void]$script:Report.AppendLine("11. Reporting & Monitoring  -  audit-log accessibility, Endpoint Analytics, app install summary, compliance status")
    [void]$script:Report.AppendLine("12. Licensing  -  SKU assignment health, Intune Suite feature signals, Entra P1/P2 utilization")
    [void]$script:Report.AppendLine("13. Platform Readiness  -  APNs, Apple ABM/VPP, Android Enterprise binding")
    [void]$script:Report.AppendLine("14. Group Inventory  -  every Entra group referenced by an Intune object")
    [void]$script:Report.AppendLine("15. Findings & Recommendations Summary  -  consolidated findings and remediation guidance")
    [void]$script:Report.AppendLine("")
    [void]$script:Report.AppendLine("### Target Deployment Profiles")
    [void]$script:Report.AppendLine("")
    [void]$script:Report.AppendLine("| Profile | Use Case | Notes |")
    [void]$script:Report.AppendLine("| --- | --- | --- |")
    [void]$script:Report.AppendLine("| **HQ** | Headquarters knowledge workers | Standard user-driven Autopilot, full app catalog |")
    [void]$script:Report.AppendLine("| **Property** | Property / field staff | User-driven Autopilot, scoped app set |")
    [void]$script:Report.AppendLine("| **Business Center** | Shared / public terminals | **Kiosk mode**  -  self-deploying or shared multi-app kiosk |")
}

function Build-FindingsSummary {
    <#
    .SYNOPSIS
        Scans the assembled report for FINDING / WARNING markers and consolidates
        them into a recommendations summary mapped to the eight audit pillars.
    #>
    $reportText = $script:Report.ToString()
    $lines = $reportText -split "`r?`n"

    # Walk lines tracking the current "## " section so each finding can be
    # tagged with its parent audit area.
    $currentSection = '(unknown)'
    $findings = [System.Collections.Generic.List[object]]::new()
    foreach ($line in $lines) {
        if ($line -match '^##\s+(.+?)\s*$') {
            $currentSection = $matches[1].Trim()
            continue
        }
        if ($line -match '^\s*>\s+\*\*(FINDING|WARNING|NOTE)\:\*\*\s+(.+)$') {
            $findings.Add([PSCustomObject]@{
                Severity = $matches[1]
                Section  = $currentSection
                Message  = $matches[2].Trim()
            })
        }
    }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("This summary consolidates every finding raised during the eight-pillar audit. Use it as the starting point for the deliverable findings report. Each row maps to a specific section above for full context.")
    [void]$sb.AppendLine("")

    # Pillar coverage map
    [void]$sb.AppendLine("### Eight-Pillar Coverage Map")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("| # | Pillar | Report Section(s) |")
    [void]$sb.AppendLine("| --- | --- | --- |")
    [void]$sb.AppendLine("| 1 | Device Enrollment | Device Enrollment |")
    [void]$sb.AppendLine("| 2 | Configuration Profiles | Configuration Profiles |")
    [void]$sb.AppendLine("| 3 | Compliance Policies | Compliance Policies + Conditional Access |")
    [void]$sb.AppendLine("| 4 | App Management | App Management |")
    [void]$sb.AppendLine("| 5 | Security Baselines | Security Baselines + Endpoint Security |")
    [void]$sb.AppendLine("| 6 | Role-Based Access (RBAC) | RBAC & Scope Tags |")
    [void]$sb.AppendLine("| 7 | Reporting & Monitoring | Reporting & Monitoring |")
    [void]$sb.AppendLine("| 8 | Licensing | Licensing |")
    [void]$sb.AppendLine("")

    if ($findings.Count -eq 0) {
        [void]$sb.AppendLine("### Consolidated Findings")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("*No FINDING / WARNING / NOTE markers were raised during this audit. Review individual sections for inventory detail.*")
    }
    else {
        $bySev = $findings | Group-Object Severity | Sort-Object {
            switch ($_.Name) { 'FINDING' {1} 'WARNING' {2} 'NOTE' {3} default {4} }
        }
        [void]$sb.AppendLine("### Consolidated Findings")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("Total: **$($findings.Count)** \u2014 " + (($bySev | ForEach-Object { "$($_.Name): $($_.Count)" }) -join ', '))
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("| # | Severity | Section | Finding |")
        [void]$sb.AppendLine("| --- | --- | --- | --- |")
        $i = 0
        foreach ($f in ($findings | Sort-Object @{ Expression = { switch ($_.Severity) { 'FINDING' {1} 'WARNING' {2} 'NOTE' {3} default {4} } } }, Section)) {
            $i++
            $msg = ($f.Message -replace '\|', '\|') -replace "`r?`n", ' '
            [void]$sb.AppendLine("| $i | $($f.Severity) | $($f.Section) | $msg |")
        }
    }

    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("### Recommended Next Steps")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("1. Address all **FINDING** rows first \u2014 these represent capability or coverage gaps.")
    [void]$sb.AppendLine("2. Triage **WARNING** rows \u2014 these indicate misconfiguration or operational risk.")
    [void]$sb.AppendLine("3. Review **NOTE** rows for licensed-but-unutilized features (Intune Suite, Entra P2) and forwarded-log destinations.")
    [void]$sb.AppendLine("4. Manually verify items the script cannot reach via Graph: Azure Monitor diagnostic-settings (ARM), Microsoft Secure Score baseline comparison, app deployment success rates over time.")
    [void]$sb.AppendLine("5. Feed this report to the **IntuneAdvisor** Hatz.AI agent for prioritized remediation recommendations.")

    Add-ReportSection -Title 'Findings & Recommendations Summary' -Content $sb.ToString()
}

function Build-ReportFooter {
    [void]$script:Report.AppendLine("")
    [void]$script:Report.AppendLine("---")
    [void]$script:Report.AppendLine("")
    [void]$script:Report.AppendLine("## Audit Errors")
    [void]$script:Report.AppendLine("")

    if ($script:ErrorLog.Count -gt 0) {
        [void]$script:Report.AppendLine("The following errors occurred during the audit:")
        [void]$script:Report.AppendLine("")
        foreach ($err in $script:ErrorLog) {
            [void]$script:Report.AppendLine("- $err")
        }
    }
    else {
        [void]$script:Report.AppendLine("*No errors. All audit areas completed successfully.*")
    }

    [void]$script:Report.AppendLine("")
    [void]$script:Report.AppendLine("---")
    [void]$script:Report.AppendLine("*Generated by Invoke-IntuneAudit.ps1 v1.4.0 on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')*")
}

# ─── Main Execution ───────────────────────────────────────────────────────────

function Invoke-IntuneAudit {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$OutputPath = 'C:\Temp\IntuneAudit',
        [string]$ClientName = 'Unknown',
        [switch]$SkipModuleCheck,
        [switch]$Quiet
    )

    # Initialize per-run state  -  script-scoped so helper functions can access
    $script:ExitCode = 0
    $script:Quiet = $Quiet.IsPresent
    $script:OutputPath = $OutputPath
    $script:ClientName = $ClientName
    $script:SkipModuleCheck = $SkipModuleCheck.IsPresent
    $script:AuditTimestamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $script:ReportFile = Join-Path $OutputPath "IntuneAudit_${ClientName}_${script:AuditTimestamp}.md"
    $script:ErrorLog = [System.Collections.Generic.List[string]]::new()
    $script:Report = [System.Text.StringBuilder]::new()
    $script:GroupCache = @{}
    $script:CAPolicyCount = 0

    Write-Log "═══ Intune Deployment Audit  -  $ClientName ═══" -Level INFO
    Write-Log "Output: $OutputPath" -Level INFO
    Write-Log "" -Level INFO

    # Prerequisites
    if (-not (Test-Prerequisites)) {
        Write-Log "Prerequisites check failed. Exiting." -Level ERROR
        exit 20
    }

    # Connect to Graph
    if (-not (Connect-GraphForAudit)) {
        Write-Log "Graph authentication failed. Exiting." -Level ERROR
        exit 20
    }

    # Build report
    Build-ReportHeader

    # Run all audit areas
    $auditFunctions = @(
        'Get-AuditTenantOverview'
        'Get-AuditCoManagement'
        'Get-AuditEnrollment'
        'Get-AuditConfigProfiles'
        'Get-AuditCompliance'
        'Get-AuditApps'
        'Get-AuditSecurityBaselines'
        'Get-AuditEndpointSecurity'
        'Get-AuditConditionalAccess'
        'Get-AuditRBAC'
        'Get-AuditDeviceStatus'
        'Get-AuditLicensing'
        'Get-AuditPlatformReadiness'
        'Get-AuditGroupInventory'
    )

    foreach ($fn in $auditFunctions) {
        try {
            & $fn
        }
        catch {
            $errMsg = "CRITICAL: $fn failed  -  $($_.Exception.Message)"
            Write-Log $errMsg -Level ERROR
            $script:ErrorLog.Add($errMsg)
            Add-ReportSection -Title "$fn (FAILED)" -Content "*This audit area failed. See error log.*"
            if ($script:ExitCode -lt 1) { $script:ExitCode = 1 }
        }
    }

    # Findings summary (must run AFTER all audit sections so it can scan them)
    try { Build-FindingsSummary }
    catch {
        $errMsg = "CRITICAL: Build-FindingsSummary failed \u2014 $($_.Exception.Message)"
        Write-Log $errMsg -Level ERROR
        $script:ErrorLog.Add($errMsg)
        if ($script:ExitCode -lt 1) { $script:ExitCode = 1 }
    }

    # Footer
    Build-ReportFooter

    # Write report to file
    try {
        $script:Report.ToString() | Out-File -FilePath $script:ReportFile -Encoding UTF8 -Force
        Write-Log "" -Level INFO
        Write-Log "═══ Audit Complete ═══" -Level SUCCESS
        Write-Log "Report: $($script:ReportFile)" -Level SUCCESS
        Write-Log "Errors: $($script:ErrorLog.Count)" -Level $(if ($script:ErrorLog.Count -gt 0) { 'WARN' } else { 'SUCCESS' })
    }
    catch {
        Write-Log "Failed to write report file: $($_.Exception.Message)" -Level ERROR
        $script:ExitCode = 20
    }

    # Disconnect
    try { Disconnect-MgGraph -ErrorAction SilentlyContinue }
    catch { Write-Log "Note: Graph disconnect returned: $($_.Exception.Message)" -Level WARN }

    exit $script:ExitCode
}

# ─── Entry Point ──────────────────────────────────────────────────────────────
# Direct execution: .\Invoke-IntuneAudit.ps1 -ClientName "Contoso"
# Copy-paste mode:  Paste script, then call Invoke-IntuneAudit -ClientName "Contoso"

if ($MyInvocation.InvocationName -ne '.' -and $MyInvocation.InvocationName -ne '') {
    $splat = @{}
    if ($PSBoundParameters.ContainsKey('OutputPath'))      { $splat['OutputPath'] = $OutputPath }
    if ($PSBoundParameters.ContainsKey('ClientName'))      { $splat['ClientName'] = $ClientName }
    if ($PSBoundParameters.ContainsKey('SkipModuleCheck')) { $splat['SkipModuleCheck'] = $true }
    if ($PSBoundParameters.ContainsKey('Quiet'))           { $splat['Quiet'] = $true }
    Invoke-IntuneAudit @splat
}
