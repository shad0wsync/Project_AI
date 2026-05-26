#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication

<#
.SYNOPSIS
    Detects baseline gaps in an Intune tenant and optionally deploys missing objects.

.DESCRIPTION
    Compares a live Intune tenant against the standard baseline catalog
    (Standards/BaselineObjects.md). Produces a structured gap report and, in
    Deploy mode, creates missing objects idempotently from JSON templates.

    Modes:
    - Detect  : Read-only gap report. No tenant changes made.
    - Deploy  : Creates missing baseline objects. Skips objects that already exist.
    - Menu    : Interactive mode selection at runtime.

    Data sources:
    - Live Graph query (default): connects to Microsoft Graph, queries all relevant
      object types, and compares against the baseline catalog.
    - Prior audit report (-AuditReportPath): parses a Markdown report from
      Invoke-IntuneAudit.ps1 and appends its FINDING/WARNING/GAP lines as
      supplemental context in the gap report.

    Deploy order: Groups first (they are assignment targets), then policies.
    Every deployment action is logged to a TenantManifest JSON for drift tracking.

.NOTES
    Script:  Invoke-IntuneTenantPrep.ps1
    Author:  Jeff Davidson
    Version: 1.5.1
    Date:    2026-05-26

    v1.5.1 - Bugfix: misleading 'Placeholder deployed' Note text on 5 Endpoint
      Security catalog entries replaced with accurate 'Cannot auto-deploy'
      reason. Settings Catalog policies (configurationPolicies) require at
      least 1 setting; empty settings[] are rejected by the API and these
      objects are always SkippedManual. TechGuide updated to match.

    v1.5.0 - Client profiles, template variables, pre/post-deploy analysis:
      - -ProfilePath: load a client profile JSON (ClientName, Platform,
        TemplatePath, OutputPath, ExcludeObject) in one step; explicit
        parameters still override profile values; Menu L option loads a
        profile interactively; Menu S option saves current settings
      - -PostDeployVerify: re-query live tenant after Deploy and append a
        Post-Deploy Verification section to the gap report; always enabled
        in Menu mode after a successful Deploy
      - Template variable injection: {{Key}} placeholders in template JSON
        are replaced with values from Variables.json in the template folder
        at deploy time; unreplaced placeholders are logged as warnings
      - Pre-deploy summary: shows per-category breakdown (to create / exist /
        excluded / no template) before deploying; prompts Y/N in Menu mode;
        logs summary silently in direct -Mode Deploy

    v1.4.0 - Selective deploy and catalog viewer:
      - -ExcludeObject: string array parameter; named baseline items are skipped
        in Detect gap analysis and Deploy; applies in all modes including Menu
        (session-scoped via X option; excluded from reports but not Undo/Reset)
      - Menu X option: set or clear the session exclusion list inline
        (comma-separated names; excluded items shown dimmed in B catalog view)
      - Menu B option: view full baseline catalog with template-on-disk status,
        active platform filter, and excluded item highlighting; summary totals
        at bottom show excluded count and missing template count

    v1.3.0 - Group catalog externalized to template file:
      - Groups catalog moved from script to Templates\Groups\Groups.json
      - Script reads group definitions from file at runtime; no script edits
        needed to add, remove, or modify baseline groups
      - Import-GroupCatalog: loads and validates Groups.json; logs warn on
        missing file and continues with empty group list
      - Groups catalog reloads on every menu action (picks up edits without
        restarting the session)
      - Menu: G option shows loaded group catalog and template file path
      - Menu: Settings section shows group catalog status alongside template path

    v1.2.0 - Group management additions:
      - NewGroup mode: create a single Entra security group non-interactively via
        -GroupName, -GroupType, -GroupDescription, -GroupMembershipRule parameters
      - DeleteGroup mode: delete a group by exact display name non-interactively
        via -GroupName parameter; exact-match lookup prevents accidental deletion
      - Menu option N: interactive New Group wizard with naming convention guidance
        (GRP-{PLATFORM}-{Category}-{Detail}), standard category list, auto-generated
        dynamic membership rule from platform selection with override capability
      - Menu option D: interactive Delete Group wizard with case-insensitive name
        search (Graph $search + ConsistencyLevel:eventual), numbered result list,
        type-to-confirm safety step
      - Connect-GraphForPrep: NewGroup and DeleteGroup now use Deploy (write) scopes
      - Invoke-IntuneAudit.ps1: em-dashes replaced with ASCII ' - ' to fix UTF-8
        encoding corruption in output reports when running under PS 5.1

    v1.1.2 — Reset mode + additional API fixes:
      - Added Reset mode: queries live tenant for all baseline-catalog-named objects,
        builds a synthetic manifest with Status=Created and correct DeleteUris covering
        every deploy run regardless of which manifest file was used; write to disk for
        immediate use with Undo mode to start from scratch
      - Menu option 4 added for Reset
      - Menu loops back after each action (no longer exits after running an option)
      - ENR-WIN-AutopilotDefault: marked SkipManual — windowsAutopilotDeploymentProfiles
        endpoint rejects all SDK POST requests with a zero-operation-ID 400 regardless
        of body content; profile must be created manually in the Intune portal
      - CFG-IOS-Email assignment: Add-PolicyAssignment now uses the creation endpoint
        (beta) instead of the category default (v1.0) — fixes 500 on assign for
        beta-only profile types

    v1.1.1 — Template and endpoint fixes from live deploy test:
      - CFG-IOS-Baseline: removed airdropForceUnmanagedDropTarget (no longer valid
        on iosGeneralDeviceConfiguration v1.0 API)
      - CFG-IOS-Email / CFG-IOS-WiFi: OverrideEndpoint added in catalog pointing to
        beta/deviceManagement/deviceConfigurations (iosEasEmailProfileConfiguration
        and iosWiFiConfiguration types only exist on beta endpoint)
      - ENR-WIN-AutopilotDefault: removed keyboardSelectionPageSkippedFor from
        outOfBoxExperienceSettings (property removed from API)
      - configurationPolicies empty-settings guard: endpoint rejects settings:[] with
        count validation error; placeholder EndpointSecurity policies now log as
        SkippedManual with explicit guidance to create in Intune GUI

    v1.1.0 — Initial multi-template release (see CHANGELOG)

    Exit Codes:
        0  - Success
        1  - Partial (some objects failed or were skipped)
        10 - Warning (Graph connectivity issues, partial data)
        20 - Critical (auth failure, prerequisites not met)

.PARAMETER Mode
    Operating mode: Detect (default), Deploy, Menu, Undo, Reset, NewGroup, or DeleteGroup.
    Undo reads a TenantManifest JSON from a prior Deploy run and deletes every
    object that was Created, in safe order (policies first, groups last).
    Requires -ManifestPath. Interactive YES confirmation required.
    Reset scans the live tenant for all baseline-catalog-named objects, builds a
    synthetic manifest with their current IDs and DeleteUris ready for Undo, and
    writes it to disk. Use Reset when multiple Deploy runs were made and no single
    manifest covers all created objects.
    NewGroup creates a single Entra security group using -GroupName, -GroupType,
    -GroupDescription, and optionally -GroupMembershipRule. Requires write scopes.
    DeleteGroup deletes a group by exact display name (-GroupName). Requires write scopes.

.PARAMETER ClientName
    Client identifier used in report headers and TenantManifest.json.

.PARAMETER Platform
    Scope to a specific platform: All (default), WIN, IOS, or MAC.

.PARAMETER OutputPath
    Directory for report and manifest output. Default: C:\Temp\IntuneTenantPrep

.PARAMETER TemplatePath
    Path to the JSON templates folder.
    Default: <script-dir>\..\..\Intune\Templates\JSON (resolved at runtime).

.PARAMETER AuditReportPath
    Optional path to a prior Invoke-IntuneAudit.ps1 Markdown report (.md).
    FINDING, WARNING, and GAP lines are imported as supplemental context.

.PARAMETER ManifestPath
    Required for Undo mode. Path to a TenantManifest JSON written by a prior
    Deploy run (e.g. C:\Temp\IntuneTenantPrep\TenantManifest_Contoso_*.json).

.PARAMETER Quiet
    Suppress console output. Report and manifest are still written to disk.

.PARAMETER SkipModuleCheck
    Skip the Graph module prerequisite check.

.PARAMETER ExcludeObject
    Names of specific baseline items to skip during Detect and Deploy. Accepts
    multiple values (string array). Items are matched by exact display name.
    Use the B option in Menu mode to list all item names with template status.
    Exclusions apply in all modes including Menu and persist for the session.
    Does not affect Undo or Reset operations.
    Example: -ExcludeObject 'CFG-WIN-UpdateRingBroad','CFG-WIN-UpdateRingPilot'

.PARAMETER ProfilePath
    Optional path to a client profile JSON file. When provided, the profile is
    loaded before applying command-line parameters, restoring ClientName,
    Platform, TemplatePath, OutputPath, and ExcludeObject in one step. Explicit
    parameters passed on the command line always override profile values.
    Use Menu option S to save the current settings as a profile and L to load
    one interactively. Profile JSON schema:
      { "ClientName": "Contoso", "Platform": "WIN", "TemplatePath": "C:\\...",
        "OutputPath": "C:\\Temp\\...", "ExcludeObject": [] }

.PARAMETER PostDeployVerify
    Re-query the live tenant immediately after a Deploy run and append a
    Post-Deploy Verification section to the gap report, showing which objects
    are now present and which (if any) are still missing. Always active in
    Menu mode after a successful Deploy.

.EXAMPLE
    .\Invoke-IntuneTenantPrep.ps1 -ClientName "Contoso"

.EXAMPLE
    .\Invoke-IntuneTenantPrep.ps1 -ClientName "Contoso" -Mode Deploy -Platform WIN

.EXAMPLE
    .\Invoke-IntuneTenantPrep.ps1 -ClientName "Contoso" -Mode Detect `
        -AuditReportPath "C:\Temp\IntuneAudit\IntuneAudit_Contoso_20260505.md"

.EXAMPLE
    .\ Invoke-IntuneTenantPrep.ps1 -ClientName "Contoso" -Mode Undo `
        -ManifestPath "C:\Temp\IntuneTenantPrep\TenantManifest_Contoso_20260505_143000.json"

.EXAMPLE
    # Copy-paste mode: paste entire script into a PS session, then call:
    Invoke-IntuneTenantPrep -ClientName "Contoso" -Mode Detect
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Detect', 'Deploy', 'Menu', 'Undo', 'Reset', 'NewGroup', 'DeleteGroup')]
    [string]$Mode = 'Detect',

    [string]$ClientName = 'Unknown',

    [ValidateSet('All', 'WIN', 'IOS', 'MAC')]
    [string]$Platform = 'All',

    [string]$OutputPath = 'C:\Temp\IntuneTenantPrep',

    [string]$TemplatePath = '',

    [string]$AuditReportPath = '',

    [string]$ManifestPath = '',

    # Group management parameters (used with -Mode NewGroup / DeleteGroup)
    [string]$GroupName = '',

    [ValidateSet('Assigned', 'Dynamic')]
    [string]$GroupType = 'Assigned',

    [string]$GroupDescription = '',

    [string]$GroupMembershipRule = '',

    [string[]]$ExcludeObject = @(),

    [switch]$Quiet,

    [switch]$SkipModuleCheck,

    [string]$ProfilePath = '',

    [switch]$PostDeployVerify
)

# ─── Configuration ────────────────────────────────────────────────────────────

$script:ScriptVersion        = '1.5.1'
$script:ClientName           = $ClientName
$script:OutputPath           = $OutputPath
$script:Platform             = $Platform
$script:Quiet                = $Quiet.IsPresent
$script:SkipModuleCheck      = $SkipModuleCheck.IsPresent
$script:Mode                 = $Mode
$script:AuditReportPath      = $AuditReportPath
$script:ManifestPath         = $ManifestPath
$script:GroupName            = $GroupName
$script:GroupType            = $GroupType
$script:GroupDescription     = $GroupDescription
$script:GroupMembershipRule  = $GroupMembershipRule
$script:ExcludeObject        = $ExcludeObject
$script:ExitCode             = 0
$script:ErrorLog             = [System.Collections.Generic.List[string]]::new()
$script:Manifest             = [System.Collections.Generic.List[hashtable]]::new()
$script:GroupIdCache         = @{}   # displayName → objectId, populated during detect/deploy
$script:ProfilePath          = $ProfilePath
$script:PostDeployVerify     = $PostDeployVerify.IsPresent
$script:TemplateVariables    = @{}

# Template path resolution — checked in priority order:
#   1. Explicit -TemplatePath parameter
#   2. Templates\ subfolder beside the script ($PSScriptRoot — when run as .ps1)
#   3. Intune\Templates\JSON relative to CWD  (repo-root invocation)
#   4. Templates\ relative to CWD            (running from TenantPrep folder)
# If none resolve, $script:TemplatePath stays '' and Invoke-IntuneTenantPrep
# will prompt interactively (or warn in -Quiet mode).
function Resolve-TemplatePath {
    param([string]$Explicit)
    if ($Explicit -ne '' -and (Test-Path -LiteralPath $Explicit -PathType Container)) { return $Explicit }
    if ($Explicit -ne '') { Write-Log "TemplatePath supplied but not found: $Explicit" -Level WARN }

    $candidates = @(
        if ($PSScriptRoot) { Join-Path $PSScriptRoot 'Templates' }
        [System.IO.Path]::GetFullPath((Join-Path $PWD 'Intune\Templates\JSON'))
        [System.IO.Path]::GetFullPath((Join-Path $PWD 'Templates'))
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Container)) { return $c }
    }
    return $null
}

$script:TemplatePath = Resolve-TemplatePath -Explicit $TemplatePath

# Required Graph modules
$script:RequiredModules = @(
    'Microsoft.Graph.Authentication'
    'Microsoft.Graph.DeviceManagement'
    'Microsoft.Graph.DeviceManagement.Enrollment'
    'Microsoft.Graph.DeviceManagement.Administration'
    'Microsoft.Graph.Groups'
)

# Read-only scopes for Detect mode
$script:DetectScopes = @(
    'DeviceManagementConfiguration.Read.All'
    'DeviceManagementManagedDevices.Read.All'
    'DeviceManagementApps.Read.All'
    'DeviceManagementServiceConfig.Read.All'
    'DeviceManagementRBAC.Read.All'
    'Directory.Read.All'
    'Group.Read.All'
)

# Read-write scopes for Deploy mode
$script:DeployScopes = @(
    'DeviceManagementConfiguration.ReadWrite.All'
    'DeviceManagementManagedDevices.Read.All'
    'DeviceManagementApps.ReadWrite.All'
    'DeviceManagementServiceConfig.ReadWrite.All'
    'DeviceManagementRBAC.Read.All'
    'Directory.Read.All'
    'Group.ReadWrite.All'
)

# ─── Baseline Catalog ─────────────────────────────────────────────────────────
# Source: Standards/BaselineObjects.md and Standards/GroupCatalog.md.
# Groups with Type='Dynamic' receive a MembershipRule; Type='Assigned' are manual.
# For deploy mode, ConfigProfiles/CompliancePolicies/EndpointSecurity require
# a matching JSON template in the TemplatePath folder.

$script:BaselineCatalog = @{

    # Groups loaded at runtime from Templates\Groups\Groups.json via Import-GroupCatalog.
    # Edit that file to add, remove, or modify baseline groups — no script changes needed.
    Groups = @()

    ConfigProfiles = @(
        @{ Name = 'CFG-WIN-Baseline';        Platform = 'WIN'
           Template = 'ConfigProfiles\CFG-WIN-Baseline.json'
           AssignTo = 'GRP-WIN-Config-All' }
        @{ Name = 'CFG-WIN-OneDriveKFM';     Platform = 'WIN'
           Template = 'ConfigProfiles\CFG-WIN-OneDriveKFM.json'
           AssignTo = 'GRP-WIN-Config-All' }
        @{ Name = 'CFG-WIN-UpdateRingBroad'; Platform = 'WIN'
           Template = 'ConfigProfiles\CFG-WIN-UpdateRingBroad.json'
           AssignTo = 'GRP-WIN-Updates-All' }
        @{ Name = 'CFG-WIN-UpdateRingPilot'; Platform = 'WIN'
           Template = 'ConfigProfiles\CFG-WIN-UpdateRingPilot.json'
           AssignTo = $null }   # Assigned to pilot group manually per client
        @{ Name = 'CFG-IOS-Baseline';        Platform = 'IOS'
           Template = 'ConfigProfiles\CFG-IOS-Baseline.json'
           AssignTo = 'GRP-IOS-Config-All' }
        @{ Name = 'CFG-IOS-Email';           Platform = 'IOS'
           Template = 'ConfigProfiles\CFG-IOS-Email.json'
           AssignTo = 'GRP-IOS-Config-All'
           # iosEasEmailProfileConfiguration only exists on the beta endpoint
           OverrideEndpoint = 'https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations' }
        @{ Name = 'CFG-IOS-WiFi';            Platform = 'IOS'
           Template = 'ConfigProfiles\CFG-IOS-WiFi.json'
           AssignTo = $null   # SSID is client-specific
           # iosWiFiConfiguration only exists on the beta endpoint
           OverrideEndpoint = 'https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations' }
        @{ Name = 'CFG-MAC-Baseline';        Platform = 'MAC'
           Template = 'ConfigProfiles\CFG-MAC-Baseline.json'
           AssignTo = 'GRP-MAC-Config-All' }
        @{ Name = 'CFG-MAC-OneDrive';        Platform = 'MAC'
           Template = 'ConfigProfiles\CFG-MAC-OneDrive.json'
           AssignTo = 'GRP-MAC-Config-All' }
    )

    CompliancePolicies = @(
        @{ Name = 'CMP-WIN-Baseline'; Platform = 'WIN'
           Template = 'Compliance\CMP-WIN-Baseline.json'
           AssignTo = 'GRP-WIN-Compliance-All' }
        @{ Name = 'CMP-IOS-Baseline'; Platform = 'IOS'
           Template = 'Compliance\CMP-IOS-Baseline.json'
           AssignTo = 'GRP-IOS-Compliance-All' }
        @{ Name = 'CMP-MAC-Baseline'; Platform = 'MAC'
           Template = 'Compliance\CMP-MAC-Baseline.json'
           AssignTo = 'GRP-MAC-Compliance-All' }
    )

    EndpointSecurity = @(
        @{ Name = 'POL-WIN-BitLocker';         Platform = 'WIN'
           Template = 'EndpointSecurity\POL-WIN-BitLocker.json'
           AssignTo = 'GRP-WIN-Security-Baseline'
           Note = 'Cannot auto-deploy — Settings Catalog requires ≥1 setting (API rejects empty settings[]). Create POL-WIN-BitLocker manually in Intune portal: Endpoint security → Disk encryption. Configure enforcement settings, TPM requirements, and recovery key escrow.' }
        @{ Name = 'POL-WIN-WindowsFirewall';   Platform = 'WIN'
           Template = 'EndpointSecurity\POL-WIN-WindowsFirewall.json'
           AssignTo = 'GRP-WIN-Security-Baseline'
           Note = 'Cannot auto-deploy — Settings Catalog requires ≥1 setting (API rejects empty settings[]). Create POL-WIN-WindowsFirewall manually in Intune portal: Endpoint security → Firewall. Configure Domain, Private, and Public profile rules.' }
        @{ Name = 'POL-WIN-DefenderAntivirus'; Platform = 'WIN'
           Template = 'EndpointSecurity\POL-WIN-DefenderAntivirus.json'
           AssignTo = 'GRP-WIN-Security-Baseline'
           Note = 'Cannot auto-deploy — Settings Catalog requires ≥1 setting (API rejects empty settings[]). Create POL-WIN-DefenderAntivirus manually in Intune portal: Endpoint security → Antivirus. Configure scan schedules, cloud protection level, and remediation actions.' }
        @{ Name = 'POL-WIN-ASRRules';          Platform = 'WIN'
           Template = 'EndpointSecurity\POL-WIN-ASRRules.json'
           AssignTo = 'GRP-WIN-Security-Baseline'
           Note = 'Cannot auto-deploy — Settings Catalog requires ≥1 setting (API rejects empty settings[]). Create POL-WIN-ASRRules manually in Intune portal: Endpoint security → Attack surface reduction. Start all rules in Audit mode; review impact before switching to Block.' }
        @{ Name = 'POL-MAC-FileVault';         Platform = 'MAC'
           Template = 'EndpointSecurity\POL-MAC-FileVault.json'
           AssignTo = 'GRP-MAC-Config-All'
           Note = 'Cannot auto-deploy — Settings Catalog requires ≥1 setting (API rejects empty settings[]). Create POL-MAC-FileVault manually in Intune portal: Endpoint security → Disk encryption. Configure FileVault recovery key escrow and enforcement settings.' }
    )

    Enrollment = @(
        @{ Name = 'ENR-WIN-AutopilotDefault'; Platform = 'WIN'
           Template = 'Enrollment\ENR-WIN-AutopilotDefault.json'
           # The windowsAutopilotDeploymentProfiles Graph API endpoint rejects all POST
           # requests from the SDK with a zero-operation-ID 400 regardless of body content
           # (confirmed across multiple body variations and encoding approaches). The Autopilot
           # profile must be created manually in the Intune portal. The script detects it in
           # Detect mode and logs it as SkippedManual in Deploy mode.
           SkipManual = $true
           Note = 'Graph API POST not supported for this tenant/SDK combination — create ENR-WIN-AutopilotDefault manually in Intune portal (Devices → Enrollment → Windows → Windows Autopilot deployment profiles).' }
        @{ Name = 'ENR-WIN-ESP';              Platform = 'WIN'
           Template = 'Enrollment\ENR-WIN-ESP.json'
           # ESP lives under deviceEnrollmentConfigurations, not windowsAutopilotDeploymentProfiles
           OverrideEndpoint = 'https://graph.microsoft.com/beta/deviceManagement/deviceEnrollmentConfigurations'
           # NOTE: this creates a NEW ESP configuration named ENR-WIN-ESP alongside the tenant's
           # built-in default ESP (usually named "All devices" or "Default"). The built-in default
           # cannot be deleted via the Graph API (405 Method Not Allowed) and will remain in the
           # tenant after an Undo — this is expected. Only the script-created ENR-WIN-ESP is removed.
           Note = 'Enrollment Status Page — required app list is client-specific. The built-in default ESP (All devices) cannot be deleted and will remain after Undo.' }
    )

    AppProtection = @(
        @{ Name = 'APR-IOS-ManagedApps'; Platform = 'IOS'
           Template = 'AppProtection\APR-IOS-ManagedApps.json'
           AssignTo = 'GRP-IOS-Apps-All' }
    )
}

# Graph POST endpoints per category
$script:CategoryEndpoints = @{
    ConfigProfiles     = 'https://graph.microsoft.com/v1.0/deviceManagement/deviceConfigurations'
    CompliancePolicies = 'https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies'
    EndpointSecurity   = 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies'
    Enrollment         = 'https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles'
    AppProtection      = 'https://graph.microsoft.com/v1.0/deviceAppManagement/iosManagedAppProtections'
}

# Assign endpoints per category (POST /{id}/assign)
$script:AssignEndpointBases = @{
    ConfigProfiles     = 'https://graph.microsoft.com/v1.0/deviceManagement/deviceConfigurations'
    CompliancePolicies = 'https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies'
    EndpointSecurity   = 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies'
    AppProtection      = 'https://graph.microsoft.com/v1.0/deviceAppManagement/iosManagedAppProtections'
}

# ─── Helper Functions ─────────────────────────────────────────────────────────

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )
    $ts     = Get-Date -Format 'HH:mm:ss'
    $prefix = switch ($Level) { 'INFO' { '[.]' } 'WARN' { '[!]' } 'ERROR' { '[X]' } 'SUCCESS' { '[+]' } }
    if (-not $script:Quiet) {
        $color = switch ($Level) { 'INFO' { 'Cyan' } 'WARN' { 'Yellow' } 'ERROR' { 'Red' } 'SUCCESS' { 'Green' } }
        Write-Host "$ts $prefix $Message" -ForegroundColor $color
    }
}

function Invoke-GraphRequestSafe {
    param([string]$Uri, [string]$Area, [switch]$Silent)
    try {
        $r = Invoke-MgGraphRequest -Method GET -Uri $Uri -ErrorAction Stop
        if ($null -ne $r.value) { return $r.value }
        return $r
    }
    catch {
        if (-not $Silent) {
            $msg = "[$Area] GET failed: $Uri — $($_.Exception.Message)"
            Write-Log $msg -Level ERROR
            $script:ErrorLog.Add($msg)
            if ($script:ExitCode -lt 1) { $script:ExitCode = 1 }
        }
        return $null
    }
}

function Invoke-GraphRequestPaged {
    param([string]$Uri, [string]$Area, [int]$MaxPages = 50)
    $all  = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    $page = 0
    while ($next -and $page -lt $MaxPages) {
        try {
            $resp = Invoke-MgGraphRequest -Method GET -Uri $next -ErrorAction Stop
        }
        catch {
            $msg = "[$Area] Paged fetch failed (page $page): $next — $($_.Exception.Message)"
            Write-Log $msg -Level ERROR
            $script:ErrorLog.Add($msg)
            if ($script:ExitCode -lt 1) { $script:ExitCode = 1 }
            break
        }
        if ($resp.value) { foreach ($v in $resp.value) { $all.Add($v) } }
        $next = $resp.'@odata.nextLink'
        $page++
    }
    return ,$all.ToArray()
}

function Invoke-GraphPost {
    param([string]$Uri, [hashtable]$Body, [string]$Area)
    try {
        $json   = $Body | ConvertTo-Json -Depth 10 -Compress
        # Send the JSON string directly (not as a byte array) so the SDK sets a
        # Content-Length header rather than Transfer-Encoding: chunked. Some Intune
        # backend services (e.g. StatelessDeviceEnrollmentFEService for Autopilot)
        # reject chunked request bodies with a zero-operation-ID 400.
        $result = Invoke-MgGraphRequest -Method POST -Uri $Uri -Body $json -ContentType 'application/json' -ErrorAction Stop
        return $result
    }
    catch {
        # ErrorDetails.Message contains the Graph API JSON error body (error code + message).
        # Fall back to the exception message when that is unavailable.
        $detail = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        $msg = "[$Area] POST failed: $Uri — $detail"
        Write-Log $msg -Level ERROR
        Write-Log "[$Area] Request body: $json" -Level ERROR
        $script:ErrorLog.Add($msg)
        if ($script:ExitCode -lt 1) { $script:ExitCode = 1 }
        return $null
    }
}

function Get-TemplateJson {
    param([string]$RelativePath)
    $fullPath = Join-Path $script:TemplatePath $RelativePath
    if (-not (Test-Path -LiteralPath $fullPath)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $fullPath -Raw -ErrorAction Stop
        if ($script:TemplateVariables -and $script:TemplateVariables.Count -gt 0) {
            foreach ($key in $script:TemplateVariables.Keys) {
                $raw = $raw -replace [regex]::Escape("{{$key}}"), $script:TemplateVariables[$key]
            }
            $remaining = [regex]::Matches($raw, '\{\{[^}]+\}\}')
            if ($remaining.Count -gt 0) {
                $names = ($remaining | ForEach-Object { $_.Value }) -join ', '
                Write-Log "Template '$RelativePath' has unreplaced placeholder(s): $names" -Level WARN
            }
        }
        return $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Log "Template load failed ($RelativePath): $($_.Exception.Message)" -Level WARN
        return $null
    }
}

function Import-GroupCatalog {
    # Loads baseline group definitions from Templates\Groups\Groups.json.
    # Returns an array of hashtables compatible with $script:BaselineCatalog.Groups.
    if (-not $script:TemplatePath -or -not (Test-Path -LiteralPath $script:TemplatePath -PathType Container)) {
        Write-Log 'Group catalog: template path not set — groups will be skipped.' -Level WARN
        return @()
    }
    $groupsFile = Join-Path $script:TemplatePath 'Groups\Groups.json'
    if (-not (Test-Path -LiteralPath $groupsFile)) {
        Write-Log "Group catalog file not found: $groupsFile" -Level WARN
        Write-Log '  Create Templates\Groups\Groups.json to define baseline groups.' -Level WARN
        return @()
    }
    try {
        $raw    = Get-Content -LiteralPath $groupsFile -Raw -ErrorAction Stop
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        $groups = @(foreach ($g in $parsed) {
            $ht = @{ Name = $g.Name; Platform = $g.Platform; Type = $g.Type; Description = $g.Description }
            if ($g.MembershipRule) { $ht['MembershipRule'] = $g.MembershipRule }
            $ht
        })
        Write-Log "Group catalog loaded: $($groups.Count) group(s) from Groups\Groups.json" -Level SUCCESS
        return $groups
    }
    catch {
        Write-Log "Failed to load group catalog: $($_.Exception.Message)" -Level ERROR
        return @()
    }
}

function Show-BaselineCatalog {
    param([string]$FilterPlatform = 'All')
    $categoryOrder = @('Groups', 'ConfigProfiles', 'CompliancePolicies', 'EndpointSecurity', 'Enrollment', 'AppProtection')
    $total = 0; $excludedCount = 0; $missingCount = 0

    Write-Host ''
    Write-Host '  ── Baseline Catalog ──────────────────────────────────────' -ForegroundColor DarkGray
    $platLabel = if ($FilterPlatform -eq 'All') { 'All platforms' } else { $FilterPlatform }
    Write-Host "  Platform filter : $platLabel" -ForegroundColor Gray
    if ($script:ExcludeObject.Count -gt 0) {
        Write-Host "  Excluded        : $($script:ExcludeObject -join ', ')" -ForegroundColor Yellow
    }
    Write-Host ''

    foreach ($cat in $categoryOrder) {
        $items = @($script:BaselineCatalog[$cat] | Where-Object {
            $FilterPlatform -eq 'All' -or $_.Platform -eq $FilterPlatform
        })
        if ($items.Count -eq 0) { continue }

        Write-Host "  ── $cat" -ForegroundColor DarkGray
        Write-Host ('  {0,-5} {1,-10} {2}' -f 'Plat', 'Template', 'Name') -ForegroundColor DarkGray

        foreach ($item in ($items | Sort-Object Platform, Name)) {
            $isExcluded = $script:ExcludeObject.Count -gt 0 -and $item.Name -in $script:ExcludeObject
            $total++
            if ($isExcluded) { $excludedCount++ }

            if ($cat -eq 'Groups') {
                $tplLabel = '(JSON)'; $tplColor = 'DarkGray'
            } elseif (-not $item.Template) {
                $tplLabel = 'n/a'; $tplColor = 'DarkGray'
            } elseif ($script:TemplatePath -and
                      (Test-Path -LiteralPath (Join-Path $script:TemplatePath $item.Template))) {
                $tplLabel = 'Ready'; $tplColor = 'DarkGreen'
            } else {
                $tplLabel = 'Missing'; $tplColor = 'Red'
                if (-not $isExcluded) { $missingCount++ }
            }

            $nameColor = if ($isExcluded) { 'DarkGray' } else { 'White' }
            Write-Host ('  {0,-5} ' -f $item.Platform) -NoNewline -ForegroundColor Gray
            Write-Host ('{0,-10} ' -f $tplLabel) -NoNewline -ForegroundColor $tplColor
            Write-Host $item.Name -NoNewline -ForegroundColor $nameColor
            if ($isExcluded) { Write-Host '  [excluded]' -ForegroundColor Yellow } else { Write-Host '' }
        }
        Write-Host ''
    }

    Write-Host "  Total: $total" -NoNewline -ForegroundColor Gray
    if ($excludedCount -gt 0) { Write-Host "   Excluded: $excludedCount" -NoNewline -ForegroundColor Yellow }
    if ($missingCount -gt 0)  { Write-Host "   Templates missing: $missingCount" -NoNewline -ForegroundColor Red }
    Write-Host ''
    Write-Host ''
    Write-Host '  Change platform filter with P in the menu. Press B again to refresh.' -ForegroundColor DarkGray
}

function Import-TemplateVariables {
    # Loads per-client variable substitutions from Variables.json in the template folder.
    # Returns a hashtable of key-value pairs; empty if file not found or path not set.
    if (-not $script:TemplatePath -or -not (Test-Path -LiteralPath $script:TemplatePath -PathType Container)) {
        return @{}
    }
    $varsFile = Join-Path $script:TemplatePath 'Variables.json'
    if (-not (Test-Path -LiteralPath $varsFile)) { return @{} }
    try {
        $raw    = Get-Content -LiteralPath $varsFile -Raw -ErrorAction Stop
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        $vars   = @{}
        foreach ($prop in $parsed.PSObject.Properties) { $vars[$prop.Name] = [string]$prop.Value }
        Write-Log "Template variables: $($vars.Count) variable(s) from Variables.json" -Level SUCCESS
        return $vars
    }
    catch {
        Write-Log "Failed to load Variables.json: $($_.Exception.Message)" -Level ERROR
        return @{}
    }
}

function Import-ClientProfile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "Profile not found: $Path" -Level WARN
        return $false
    }
    try {
        $raw   = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        $p     = $raw | ConvertFrom-Json -ErrorAction Stop
        $props = $p.PSObject.Properties.Name
        if ('ClientName'    -in $props -and $p.ClientName)    { $script:ClientName    = $p.ClientName }
        if ('Platform'      -in $props -and $p.Platform)      { $script:Platform      = $p.Platform }
        if ('TemplatePath'  -in $props -and $p.TemplatePath)  {
            $tp = Resolve-TemplatePath -Explicit $p.TemplatePath
            if ($tp) { $script:TemplatePath = $tp }
            else { Write-Log "Profile TemplatePath not found: $($p.TemplatePath)" -Level WARN }
        }
        if ('OutputPath'    -in $props -and $p.OutputPath)    { $script:OutputPath    = $p.OutputPath }
        if ('ExcludeObject' -in $props -and $p.ExcludeObject) { $script:ExcludeObject = @($p.ExcludeObject | Where-Object { $_ }) }
        $script:ProfilePath = $Path
        Write-Log "Profile loaded: $Path" -Level SUCCESS
        return $true
    }
    catch {
        Write-Log "Failed to load profile: $($_.Exception.Message)" -Level ERROR
        return $false
    }
}

function Export-ClientProfile {
    param([string]$Path)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch { $null = $_ }
    }
    $profileData = [ordered]@{
        ClientName    = $script:ClientName
        Platform      = $script:Platform
        TemplatePath  = $script:TemplatePath
        OutputPath    = $script:OutputPath
        ExcludeObject = @($script:ExcludeObject)
    }
    try {
        $profileData | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $Path -Encoding UTF8 -Force
        $script:ProfilePath = $Path
        Write-Log "Profile saved: $Path" -Level SUCCESS
        return $true
    }
    catch {
        Write-Log "Failed to save profile: $($_.Exception.Message)" -Level ERROR
        return $false
    }
}

# ─── Prerequisites ────────────────────────────────────────────────────────────

function Test-Prerequisites {
    if (-not (Test-Path -LiteralPath $script:OutputPath)) {
        try {
            New-Item -ItemType Directory -Path $script:OutputPath -Force | Out-Null
        }
        catch {
            Write-Log "Cannot create output directory: $script:OutputPath — $($_.Exception.Message)" -Level ERROR
            return $false
        }
    }
    if ($script:SkipModuleCheck) { return $true }

    $missing = @()
    foreach ($mod in $script:RequiredModules) {
        if (-not (Get-Module -ListAvailable -Name $mod)) { $missing += $mod }
    }
    if ($missing.Count -gt 0) {
        Write-Log "Missing Graph modules: $($missing -join ', ')" -Level ERROR
        Write-Log "Install with: Install-Module $($missing -join ', ') -Scope CurrentUser" -Level WARN
        return $false
    }
    return $true
}

function Connect-GraphForPrep {
    param([string]$PrepMode)
    $scopes = if ($PrepMode -in 'Deploy', 'Undo', 'NewGroup', 'DeleteGroup') { $script:DeployScopes } else { $script:DetectScopes }
    Write-Log "Connecting to Microsoft Graph ($PrepMode scopes)..." -Level INFO
    try {
        Connect-MgGraph -Scopes $scopes -NoWelcome -ErrorAction Stop
        $ctx = Get-MgContext
        if (-not $ctx) {
            Write-Log "Graph connection returned no context." -Level ERROR
            return $false
        }
        Write-Log "Connected: $($ctx.Account) | Tenant: $($ctx.TenantId)" -Level SUCCESS
        return $true
    }
    catch {
        Write-Log "Graph authentication failed: $($_.Exception.Message)" -Level ERROR
        return $false
    }
}

# ─── Live Tenant Query ────────────────────────────────────────────────────────

function Get-LiveTenantObjects {
    Write-Log "Querying live tenant objects..." -Level INFO

    $live = @{
        Groups             = @{}
        ConfigProfiles     = @{}
        CompliancePolicies = @{}
        EndpointSecurity   = @{}
        Enrollment         = @{}
        AppProtection      = @{}
    }

    # Groups — all security-enabled groups; filter to GRP-* locally
    $groups = Invoke-GraphRequestPaged `
        -Uri 'https://graph.microsoft.com/v1.0/groups?$filter=securityEnabled eq true&$select=id,displayName,groupTypes,membershipRule&$top=999' `
        -Area 'Groups'
    foreach ($g in $groups) {
        if ($g.displayName -like 'GRP-*') {
            $live.Groups[$g.displayName]        = $g
            $script:GroupIdCache[$g.displayName] = $g.id
        }
    }
    Write-Log "  Groups (GRP-*) in tenant: $($live.Groups.Count)" -Level INFO

    # Config profiles — classic device configurations (includes Update Rings, iOS email/Wi-Fi).
    # Use beta endpoint so profiles created via beta (iosEasEmailProfileConfiguration,
    # iosWiFiConfiguration) are visible — the v1.0 endpoint omits certain beta-only types.
    $cfgs = Invoke-GraphRequestPaged `
        -Uri 'https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations?$select=id,displayName&$top=200' `
        -Area 'ConfigProfiles'
    foreach ($c in $cfgs) {
        if ($c.displayName) { $live.ConfigProfiles[$c.displayName] = $c }
    }

    # Config profiles — Settings Catalog
    $sc = Invoke-GraphRequestPaged `
        -Uri 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?$select=id,name,technologies,platforms&$top=200' `
        -Area 'ConfigProfiles'
    foreach ($p in $sc) {
        if ($p.name) {
            $live.ConfigProfiles[$p.name] = $p
            # POL-* names in Settings Catalog also count as EndpointSecurity
            if ($p.name -like 'POL-*') { $live.EndpointSecurity[$p.name] = $p }
        }
    }
    Write-Log "  Config profiles in tenant: $($live.ConfigProfiles.Count)" -Level INFO

    # Compliance policies
    $cmp = Invoke-GraphRequestPaged `
        -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies?$select=id,displayName&$top=200' `
        -Area 'CompliancePolicies'
    foreach ($c in $cmp) {
        if ($c.displayName) { $live.CompliancePolicies[$c.displayName] = $c }
    }
    Write-Log "  Compliance policies in tenant: $($live.CompliancePolicies.Count)" -Level INFO

    # Endpoint Security — legacy intents (security baselines + older AV/FW/BitLocker)
    $intents = Invoke-GraphRequestPaged `
        -Uri 'https://graph.microsoft.com/beta/deviceManagement/intents?$select=id,displayName&$top=200' `
        -Area 'EndpointSecurity'
    foreach ($i in $intents) {
        if ($i.displayName) { $live.EndpointSecurity[$i.displayName] = $i }
    }
    Write-Log "  Endpoint security objects in tenant: $($live.EndpointSecurity.Count)" -Level INFO

    # Enrollment — Autopilot deployment profiles
    $ap = Invoke-GraphRequestPaged `
        -Uri 'https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles?$select=id,displayName&$top=200' `
        -Area 'Enrollment'
    foreach ($a in $ap) {
        if ($a.displayName) { $live.Enrollment[$a.displayName] = $a }
    }

    # Enrollment — Enrollment Status Page and other enrollment configurations
    $enrCfg = Invoke-GraphRequestPaged `
        -Uri 'https://graph.microsoft.com/beta/deviceManagement/deviceEnrollmentConfigurations?$select=id,displayName&$top=200' `
        -Area 'Enrollment'
    foreach ($e in $enrCfg) {
        if ($e.displayName) { $live.Enrollment[$e.displayName] = $e }
    }
    Write-Log "  Enrollment objects in tenant: $($live.Enrollment.Count)" -Level INFO

    # App protection — iOS MAM policies
    $apr = Invoke-GraphRequestPaged `
        -Uri 'https://graph.microsoft.com/v1.0/deviceAppManagement/iosManagedAppProtections?$select=id,displayName&$top=200' `
        -Area 'AppProtection'
    foreach ($a in $apr) {
        if ($a.displayName) { $live.AppProtection[$a.displayName] = $a }
    }
    Write-Log "  App protection policies in tenant: $($live.AppProtection.Count)" -Level INFO

    return $live
}

# ─── Gap Analysis ─────────────────────────────────────────────────────────────

function Get-BaselineGaps {
    param([hashtable]$Live)

    $gaps = [System.Collections.Generic.List[hashtable]]::new()

    $categoryLiveMap = @{
        Groups             = $Live.Groups
        ConfigProfiles     = $Live.ConfigProfiles
        CompliancePolicies = $Live.CompliancePolicies
        EndpointSecurity   = $Live.EndpointSecurity
        Enrollment         = $Live.Enrollment
        AppProtection      = $Live.AppProtection
    }

    foreach ($category in $script:BaselineCatalog.Keys) {
        $liveSet = $categoryLiveMap[$category]
        foreach ($item in $script:BaselineCatalog[$category]) {
            if ($script:Platform -ne 'All' -and $item.Platform -ne $script:Platform) { continue }
            if ($script:ExcludeObject.Count -gt 0 -and $item.Name -in $script:ExcludeObject) { continue }

            $exists  = $liveSet.ContainsKey($item.Name)
            $liveObj = if ($exists) { $liveSet[$item.Name] } else { $null }

            # Check whether a deploy template is available on disk
            $hasTemplate = $false
            if ($category -ne 'Groups' -and $item.Template) {
                $hasTemplate = Test-Path -LiteralPath (Join-Path $script:TemplatePath $item.Template)
            }

            $gaps.Add(@{
                Category    = $category
                Name        = $item.Name
                Platform    = $item.Platform
                Exists      = $exists
                LiveId      = if ($liveObj) { $liveObj.id } else { $null }
                Template    = if ($item.Template)  { $item.Template  } else { $null }
                AssignTo    = if ($item.AssignTo)  { $item.AssignTo  } else { $null }
                HasTemplate = $hasTemplate
                Note        = if ($item.Note)      { $item.Note      } else { $null }
                Definition  = $item
            })
        }
    }

    return ,$gaps.ToArray()
}

# ─── Audit Report Import ──────────────────────────────────────────────────────

function Import-AuditReportFindings {
    param([string]$ReportPath)

    if (-not (Test-Path -LiteralPath $ReportPath)) {
        Write-Log "Audit report not found: $ReportPath" -Level WARN
        return @()
    }

    Write-Log "Importing findings from prior audit report..." -Level INFO
    $findings = [System.Collections.Generic.List[string]]::new()

    $lines = Get-Content -LiteralPath $ReportPath -ErrorAction SilentlyContinue
    if (-not $lines) { return @() }

    foreach ($line in $lines) {
        if ($line -match '>\s*\*\*(FINDING|WARNING|PROFILE-PLAN GAP|OVER-SCOPED):\*\*') {
            $clean = ($line -replace '^>\s*', '') -replace '\*\*', ''
            $findings.Add($clean.Trim())
        }
    }

    Write-Log "  Imported $($findings.Count) finding(s) from prior report" -Level INFO
    return ,$findings.ToArray()
}

# ─── Deploy Functions ─────────────────────────────────────────────────────────

function New-IntuneGroupIfNotExists {
    [CmdletBinding(SupportsShouldProcess)]
    param([hashtable]$GroupDef)

    $name = $GroupDef.Name
    if ($script:GroupIdCache.ContainsKey($name)) {
        Write-Log "  [SKIP] Group already exists: $name" -Level INFO
        $script:Manifest.Add(@{
            Category = 'Groups'; Name = $name
            Status   = 'Skipped'; Reason = 'Already exists'
            ObjectId = $script:GroupIdCache[$name]
        })
        return
    }

    if (-not $PSCmdlet.ShouldProcess($name, 'Create Entra security group')) { return }

    $mailNick = $name -replace '[^A-Za-z0-9]', ''
    $body = @{
        displayName     = $name
        mailEnabled     = $false
        mailNickname    = $mailNick
        securityEnabled = $true
        description     = $GroupDef.Description
    }

    if ($GroupDef.Type -eq 'Dynamic') {
        $body['groupTypes']                  = @('DynamicMembership')
        $body['membershipRule']              = $GroupDef.MembershipRule
        $body['membershipRuleProcessingState'] = 'On'
    } else {
        $body['groupTypes'] = @()
    }

    Write-Log "  Creating group: $name ($($GroupDef.Type))" -Level INFO
    $result = Invoke-GraphPost -Uri 'https://graph.microsoft.com/v1.0/groups' -Body $body -Area 'Groups'

    if ($result -and $result.id) {
        $script:GroupIdCache[$name] = $result.id
        $script:Manifest.Add(@{
            Category  = 'Groups'; Name = $name
            Status    = 'Created'; ObjectId = $result.id
            CreatedAt = (Get-Date -Format 'o')
            DeleteUri = "https://graph.microsoft.com/v1.0/groups/$($result.id)"
        })
        Write-Log "  [OK] Created group: $name  ($($result.id))" -Level SUCCESS
    } else {
        $script:Manifest.Add(@{ Category = 'Groups'; Name = $name; Status = 'Failed'; Reason = 'POST returned no ID' })
    }
}

function New-IntunePolicyFromTemplateIfNotExists {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [hashtable]$PolicyDef,
        [string]$Category,
        [hashtable]$LiveCategory
    )

    $name = $PolicyDef.Name

    if ($LiveCategory.ContainsKey($name)) {
        Write-Log "  [SKIP] $Category already exists: $name" -Level INFO
        $script:Manifest.Add(@{
            Category = $Category; Name = $name
            Status   = 'Skipped'; Reason = 'Already exists'
            ObjectId = $LiveCategory[$name].id
        })
        return
    }

    # SkipManual — catalog entry explicitly opts out of automated creation.
    # Used when the Graph API endpoint rejects POST regardless of body content
    # (e.g. ENR-WIN-AutopilotDefault via windowsAutopilotDeploymentProfiles).
    if ($PolicyDef.SkipManual) {
        $manualNote = if ($PolicyDef.Note) { " $($PolicyDef.Note)" } else { '' }
        Write-Log "  [SKIP] $name requires manual creation.$manualNote" -Level WARN
        $script:Manifest.Add(@{
            Category = $Category; Name = $name
            Status   = 'SkippedManual'
            Reason   = 'Graph API POST not supported — manual creation required in Intune portal'
            Note     = if ($PolicyDef.Note) { $PolicyDef.Note } else { $null }
        })
        return
    }

    if (-not $PolicyDef.Template) {
        Write-Log "  [SKIP] No template path defined for: $name" -Level WARN
        $script:Manifest.Add(@{ Category = $Category; Name = $name; Status = 'Skipped'; Reason = 'No template defined' })
        return
    }

    $templateJson = Get-TemplateJson -RelativePath $PolicyDef.Template
    if (-not $templateJson) {
        $note = if ($PolicyDef.Note) { " Note: $($PolicyDef.Note)" } else { '' }
        Write-Log "  [SKIP] Template not found: $($PolicyDef.Template)$note" -Level WARN
        $script:Manifest.Add(@{
            Category = $Category; Name = $name
            Status   = 'Skipped'; Reason = "Template missing: $($PolicyDef.Template)"
        })
        return
    }

    if (-not $PSCmdlet.ShouldProcess($name, "Create Intune $Category object")) { return }

    # Per-item OverrideEndpoint takes precedence over the category-level default
    $endpoint = if ($PolicyDef.OverrideEndpoint) { $PolicyDef.OverrideEndpoint } else { $script:CategoryEndpoints[$Category] }
    if (-not $endpoint) {
        Write-Log "  [SKIP] No endpoint configured for category: $Category" -Level WARN
        return
    }

    # Build POST body from template; override displayName with canonical catalog name.
    # Also set 'name' for Settings Catalog endpoints — configurationPolicies uses 'name' not 'displayName'.
    # Do NOT set 'name' for other endpoints (Autopilot, device configs, etc.) — those APIs reject unknown fields.
    $body = @{}
    foreach ($prop in $templateJson.PSObject.Properties) { $body[$prop.Name] = $prop.Value }
    $body['displayName'] = $name
    if ($endpoint -match 'configurationPolicies') { $body['name'] = $name }

    # configurationPolicies requires at least 1 setting — the API rejects settings:[].
    # Placeholder templates with empty settings arrays must be created manually in the Intune GUI.
    if ($endpoint -match 'configurationPolicies' -and
        ($null -eq $body['settings'] -or
         ($body['settings'] -is [array] -and $body['settings'].Count -eq 0) -or
         ($body['settings'] -is [System.Collections.IEnumerable] -and -not ($body['settings'] | Select-Object -First 1)))) {
        $manualNote = if ($PolicyDef.Note) { " $($PolicyDef.Note)" } else { '' }
        Write-Log "  [SKIP] $name has empty settings[] — configurationPolicies requires \u22651 setting. Create and configure this policy manually in the Intune portal.$manualNote" -Level WARN
        $script:Manifest.Add(@{
            Category = $Category; Name = $name
            Status   = 'SkippedManual'
            Reason   = 'configurationPolicies requires at least 1 setting; empty placeholder rejected by API. Create manually in Intune portal.'
            Note     = if ($PolicyDef.Note) { $PolicyDef.Note } else { $null }
        })
        return
    }

    Write-Log "  Creating $Category`: $name" -Level INFO
    $result = Invoke-GraphPost -Uri $endpoint -Body $body -Area $Category

    if ($result -and $result.id) {
        $createdId = $result.id
        $script:Manifest.Add(@{
            Category  = $Category; Name = $name
            Status    = 'Created'; ObjectId = $createdId
            CreatedAt = (Get-Date -Format 'o')
            DeleteUri = "$endpoint/$createdId"
        })
        Write-Log "  [OK] Created: $name  ($createdId)" -Level SUCCESS

        # Assign to target group when defined; pass the same endpoint used for creation
        # so beta-endpoint profiles (CFG-IOS-Email, CFG-IOS-WiFi) assign via beta, not v1.0
        if ($PolicyDef.AssignTo) {
            Add-PolicyAssignment -PolicyId $createdId -GroupName $PolicyDef.AssignTo -Category $Category -AssignBase $endpoint
        }
    } else {
        $script:Manifest.Add(@{ Category = $Category; Name = $name; Status = 'Failed'; Reason = 'POST returned no ID' })
    }
}

function Add-PolicyAssignment {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$PolicyId, [string]$GroupName, [string]$Category, [string]$AssignBase = '')

    $groupId = $script:GroupIdCache[$GroupName]
    if (-not $groupId) {
        Write-Log "  [SKIP ASSIGN] Group not in cache (not yet created?): $GroupName" -Level WARN
        return
    }

    $baseUri = if ($AssignBase -ne '') { $AssignBase } else { $script:AssignEndpointBases[$Category] }
    if (-not $baseUri) {
        Write-Log "  [SKIP ASSIGN] No assignment endpoint for category: $Category" -Level WARN
        return
    }

    if (-not $PSCmdlet.ShouldProcess("$Category/$PolicyId", "Assign to group $GroupName")) { return }

    $assignUri  = "$baseUri/$PolicyId/assign"
    $assignBody = @{
        assignments = @(
            @{
                target = @{
                    '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
                    groupId       = $groupId
                }
            }
        )
    }

    Write-Log "  Assigning $Category/$PolicyId to $GroupName..." -Level INFO
    $null = Invoke-GraphPost -Uri $assignUri -Body $assignBody -Area "$Category/Assign"
}

function Invoke-BaselineDeploy {
    param([hashtable]$Live)

    Write-Log "Starting baseline deployment (Platform: $script:Platform)..." -Level INFO

    # Phase 1 — Groups (must exist before any assignment)
    Write-Log "Phase 1: Groups" -Level INFO
    $groupDefs = $script:BaselineCatalog.Groups |
        Where-Object { ($script:Platform -eq 'All' -or $_.Platform -eq $script:Platform) -and $_.Name -notin $script:ExcludeObject }
    foreach ($gDef in $groupDefs) {
        New-IntuneGroupIfNotExists -GroupDef $gDef
    }

    # Phase 2 — Policies (require groups to be present for assignment)
    foreach ($category in @('CompliancePolicies', 'ConfigProfiles', 'EndpointSecurity', 'Enrollment', 'AppProtection')) {
        Write-Log "Phase 2: $category" -Level INFO
        $liveCategory = $Live[$category]
        $defs = $script:BaselineCatalog[$category] |
            Where-Object { ($script:Platform -eq 'All' -or $_.Platform -eq $script:Platform) -and $_.Name -notin $script:ExcludeObject }
        foreach ($def in $defs) {
            New-IntunePolicyFromTemplateIfNotExists -PolicyDef $def -Category $category -LiveCategory $liveCategory
        }
    }
}

# ─── Rollback / Undo ─────────────────────────────────────────────────────────

function Invoke-GraphDelete {
    param([string]$Uri, [string]$Area)
    try {
        Invoke-MgGraphRequest -Method DELETE -Uri $Uri -ErrorAction Stop
        return $true
    }
    catch {
        # 404 = already gone — treat as success for idempotency
        if ($_.Exception.Message -match '404|NotFound|Not Found') { return $true }
        # 405 Method Not Allowed — Graph returns this for built-in / default system objects
        # that cannot be deleted via the API (e.g. the tenant's built-in default Enrollment
        # Status Page named "All devices" or "Default"). Treat as a skip, not a script error.
        # The script-created ENR-WIN-ESP is a separate policy with its own ID and can be deleted;
        # the built-in default will remain and that is expected behaviour.
        if ($_.Exception.Message -match '405|MethodNotAllowed|Method Not Allowed') {
            Write-Log "  [SKIP] $Area : built-in system object cannot be deleted (405 Method Not Allowed). It will remain in the tenant — this is expected." -Level WARN
            return $true
        }
        $msg = "[$Area] DELETE failed: $Uri — $($_.Exception.Message)"
        Write-Log $msg -Level ERROR
        $script:ErrorLog.Add($msg)
        if ($script:ExitCode -lt 1) { $script:ExitCode = 1 }
        return $false
    }
}

function Invoke-BaselineUndo {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$ManifestFile)

    if (-not (Test-Path -LiteralPath $ManifestFile)) {
        Write-Log "Manifest file not found: $ManifestFile" -Level ERROR
        $script:ExitCode = 20; return
    }

    $manifest = $null
    try {
        $raw      = Get-Content -LiteralPath $ManifestFile -Raw -ErrorAction Stop
        $manifest = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Log "Failed to load manifest: $($_.Exception.Message)" -Level ERROR
        $script:ExitCode = 20; return
    }

    # Only objects this script created that have a recorded DeleteUri
    $toDelete = @($manifest.Objects | Where-Object { $_.Status -eq 'Created' -and $_.DeleteUri })

    if ($toDelete.Count -eq 0) {
        Write-Log 'No Created objects found in manifest — nothing to undo.' -Level INFO
        return
    }

    $manifestMode = if ($manifest.Mode) { $manifest.Mode } else { 'unknown' }
    $statusBreakdown = $manifest.Objects | Group-Object Status |
        ForEach-Object { "$($_.Name)=$($_.Count)" }
    Write-Log "Manifest: $($manifest.ClientName) | Mode: $manifestMode | Generated: $($manifest.GeneratedAt)" -Level INFO
    Write-Log "Status breakdown: $($statusBreakdown -join ', ')" -Level INFO
    Write-Log "Objects to delete (Status=Created): $($toDelete.Count)" -Level WARN

    if ($manifestMode -ne 'Deploy') {
        Write-Log "WARNING: This manifest was generated in '$manifestMode' mode, not 'Deploy'. It may contain no Created objects." -Level WARN
    }

    # Separate groups (deleted last) from everything else
    $nonGroups = @($toDelete | Where-Object { $_.Category -ne 'Groups' })
    $groups    = @($toDelete | Where-Object { $_.Category -eq 'Groups' })

    Write-Host ''
    Write-Host '  The following objects will be PERMANENTLY DELETED from the tenant:' -ForegroundColor Yellow
    Write-Host ''
    foreach ($o in ($nonGroups + $groups)) {
        Write-Host "    $($o.Category.PadRight(22)) $($o.Name)" -ForegroundColor White
    }
    Write-Host ''

    if ($script:Quiet) {
        Write-Log '-Quiet is set — Undo requires interactive confirmation. Re-run without -Quiet.' -Level ERROR
        $script:ExitCode = 20; return
    }

    $confirm = (Read-Host '  Type YES to confirm deletion, or anything else to abort').Trim()
    if ($confirm -ne 'YES') {
        Write-Log 'Undo aborted by user.' -Level INFO
        return
    }

    # Phase 1 — delete policies/profiles first so group assignments are cleared
    Write-Log 'Phase 1: Deleting policies and profiles...' -Level INFO
    foreach ($o in $nonGroups) {
        if (-not $PSCmdlet.ShouldProcess($o.Name, "DELETE $($o.Category) from tenant")) { continue }
        Write-Log "  Deleting $($o.Category): $($o.Name)  ($($o.ObjectId))" -Level INFO
        $ok = Invoke-GraphDelete -Uri $o.DeleteUri -Area $o.Category
        if ($ok) { Write-Log "  [OK] Deleted: $($o.Name)" -Level SUCCESS }
    }

    # Phase 2 — groups last
    Write-Log 'Phase 2: Deleting groups...' -Level INFO
    foreach ($o in $groups) {
        if (-not $PSCmdlet.ShouldProcess($o.Name, 'DELETE Entra group')) { continue }
        Write-Log "  Deleting group: $($o.Name)  ($($o.ObjectId))" -Level INFO
        $ok = Invoke-GraphDelete -Uri $o.DeleteUri -Area 'Groups'
        if ($ok) { Write-Log "  [OK] Deleted group: $($o.Name)" -Level SUCCESS }
    }

    Write-Log "Undo complete. $($toDelete.Count) object(s) processed." -Level SUCCESS
}

# ─── Reset Manifest Builder ──────────────────────────────────────────────────

function New-ResetManifest {
    param([hashtable]$Live)

    Write-Log 'Building reset manifest from live tenant state...' -Level INFO

    $categoryLiveMap = @{
        Groups             = $Live.Groups
        ConfigProfiles     = $Live.ConfigProfiles
        CompliancePolicies = $Live.CompliancePolicies
        EndpointSecurity   = $Live.EndpointSecurity
        Enrollment         = $Live.Enrollment
        AppProtection      = $Live.AppProtection
    }

    $found = 0
    foreach ($category in $script:BaselineCatalog.Keys) {
        $liveSet = $categoryLiveMap[$category]
        foreach ($item in $script:BaselineCatalog[$category]) {
            if ($script:Platform -ne 'All' -and $item.Platform -ne $script:Platform) { continue }
            if (-not $liveSet.ContainsKey($item.Name)) { continue }

            $liveId = $liveSet[$item.Name].id
            if (-not $liveId) { continue }

            # Determine delete base: OverrideEndpoint > category default > groups fallback
            $deleteBase = if ($item.OverrideEndpoint)     { $item.OverrideEndpoint }
                          elseif ($category -eq 'Groups') { 'https://graph.microsoft.com/v1.0/groups' }
                          else                            { $script:CategoryEndpoints[$category] }

            $script:Manifest.Add(@{
                Category  = $category
                Name      = $item.Name
                Status    = 'Created'
                ObjectId  = $liveId
                CreatedAt = 'reset-scan'
                DeleteUri = "$deleteBase/$liveId"
            })
            Write-Log "  [FOUND] $($category.PadRight(20)) $($item.Name)" -Level INFO
            $found++
        }
    }

    if ($found -gt 0) {
        Write-Log "Reset manifest: $found baseline object(s) found in live tenant." -Level SUCCESS
    } else {
        Write-Log 'No baseline objects found in live tenant — tenant appears clean.' -Level INFO
    }
}

# ─── Report Generation ────────────────────────────────────────────────────────

function Show-PreDeploySummary {
    param(
        [object[]]$Gaps,
        [switch]$PromptConfirm
    )
    $categoryOrder = @('Groups', 'ConfigProfiles', 'CompliancePolicies', 'EndpointSecurity', 'Enrollment', 'AppProtection')
    $totalCreate = 0; $totalExist = 0; $totalExcluded = 0; $totalNoTmpl = 0

    Write-Host ''
    Write-Host '  ── Pre-Deploy Summary ──────────────────────────────────────' -ForegroundColor Cyan
    Write-Host ('  {0,-22} {1,9} {2,7} {3,8} {4,11}' -f 'Category', 'To Create', 'Exist', 'Excluded', 'No Template') -ForegroundColor DarkGray
    Write-Host ('  {0,-22} {1,9} {2,7} {3,8} {4,11}' -f '----------------------', '---------', '-------', '--------', '-----------') -ForegroundColor DarkGray

    foreach ($cat in $categoryOrder) {
        $catItems = @($script:BaselineCatalog[$cat] | Where-Object { $script:Platform -eq 'All' -or $_.Platform -eq $script:Platform })
        if ($catItems.Count -eq 0) { continue }

        $catGaps  = @($Gaps | Where-Object { $_.Category -eq $cat })
        $excluded = @($catItems | Where-Object { $_.Name -in $script:ExcludeObject }).Count
        $toCreate = @($catGaps | Where-Object { -not $_.Exists }).Count
        $exist    = @($catGaps | Where-Object { $_.Exists }).Count
        $noTmpl   = @($catGaps | Where-Object { -not $_.Exists -and -not $_.HasTemplate -and $_.Category -ne 'Groups' }).Count

        $totalCreate   += $toCreate
        $totalExist    += $exist
        $totalExcluded += $excluded
        $totalNoTmpl   += $noTmpl

        $rowColor = if ($toCreate -gt 0) { 'White' } else { 'DarkGray' }
        Write-Host ('  {0,-22} {1,9} {2,7} {3,8} {4,11}' -f $cat, $toCreate, $exist, $excluded, $noTmpl) -ForegroundColor $rowColor
    }

    Write-Host ('  {0,-22} {1,9} {2,7} {3,8} {4,11}' -f '----------------------', '---------', '-------', '--------', '-----------') -ForegroundColor DarkGray
    Write-Host ('  {0,-22} {1,9} {2,7} {3,8} {4,11}' -f 'Total', $totalCreate, $totalExist, $totalExcluded, $totalNoTmpl) -ForegroundColor White
    if ($totalNoTmpl -gt 0) {
        Write-Host ''
        Write-Host "  [!] $totalNoTmpl item(s) lack a template file and will be skipped." -ForegroundColor Yellow
    }
    Write-Host ''

    if ($PromptConfirm) {
        $answer = (Read-Host "  Deploy $totalCreate new object(s)? [Y/N]").Trim().ToUpper()
        return $answer -eq 'Y'
    }
    return $true
}

function Write-GapReport {
    param(
        [object[]]$Gaps,
        [string[]]$AuditFindings,
        [object[]]$PostDeployGaps = $null
    )

    $sb   = [System.Text.StringBuilder]::new()
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $safe = $script:ClientName -replace '[^A-Za-z0-9_-]', '_'

    [void]$sb.AppendLine('# Intune Baseline Gap Report')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| Field | Value |')
    [void]$sb.AppendLine('| --- | --- |')
    [void]$sb.AppendLine("| Client | $($script:ClientName) |")
    [void]$sb.AppendLine("| Platform filter | $($script:Platform) |")
    [void]$sb.AppendLine("| Generated | $ts |")
    [void]$sb.AppendLine("| Script version | $($script:ScriptVersion) |")
    [void]$sb.AppendLine('')

    $totalExpected = $Gaps.Count
    $totalMissing  = @($Gaps | Where-Object { -not $_.Exists }).Count
    $totalPresent  = $totalExpected - $totalMissing
    $templateGaps  = @($Gaps | Where-Object { -not $_.Exists -and -not $_.HasTemplate -and $_.Category -ne 'Groups' }).Count

    [void]$sb.AppendLine('## Summary')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| Metric | Count |')
    [void]$sb.AppendLine('| --- | ---: |')
    [void]$sb.AppendLine("| Expected baseline objects | $totalExpected |")
    [void]$sb.AppendLine("| Present in tenant | $totalPresent |")
    [void]$sb.AppendLine("| **Missing (gaps)** | **$totalMissing** |")
    if ($templateGaps -gt 0) {
        [void]$sb.AppendLine("| Missing *and* no template available | $templateGaps |")
    }
    [void]$sb.AppendLine('')

    if ($totalMissing -eq 0) {
        [void]$sb.AppendLine('> **All baseline objects are present in the tenant.**')
        [void]$sb.AppendLine('')
    } else {
        [void]$sb.AppendLine("> **$totalMissing baseline object(s) are missing.** Run with ``-Mode Deploy`` to create them.")
        [void]$sb.AppendLine('')
    }

    # Per-category section
    $categories = $Gaps | Group-Object { $_['Category'] } | Sort-Object Name
    foreach ($cat in $categories) {
        $catMissing = @($cat.Group | Where-Object { -not $_.Exists })

        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('---')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("## $($cat.Name)")
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('| Status | Name | Platform | Deploy-Ready |')
        [void]$sb.AppendLine('| --- | --- | --- | --- |')

        foreach ($g in ($cat.Group | Sort-Object Platform, Name)) {
            $status  = if ($g.Exists)      { 'Present'      } else { '**MISSING**' }
            $deploy  = if ($g.Category -eq 'Groups') { 'Auto' }
                       elseif ($g.HasTemplate)       { 'Yes — template found' }
                       else                          { 'No — template required' }
            [void]$sb.AppendLine("| $status | ``$($g.Name)`` | $($g.Platform) | $deploy |")
        }
        [void]$sb.AppendLine('')

        if ($catMissing.Count -gt 0) {
            [void]$sb.AppendLine("> **GAP:** $($catMissing.Count) of $($cat.Group.Count) expected $($cat.Name) object(s) are missing.")
            # Flag any with deploy notes
            foreach ($m in $catMissing) {
                if ($m.Note) { [void]$sb.AppendLine("> Note for ``$($m.Name)``: $($m.Note)") }
            }
        } else {
            [void]$sb.AppendLine("> All expected $($cat.Name) objects are present.")
        }
    }

    # Prior audit findings supplement
    if ($AuditFindings -and $AuditFindings.Count -gt 0) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('---')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('## Prior Audit Report — Supplemental Findings')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('The following FINDING / WARNING / GAP lines were imported from a prior Invoke-IntuneAudit.ps1 report:')
        [void]$sb.AppendLine('')
        foreach ($f in $AuditFindings) {
            [void]$sb.AppendLine("- $f")
        }
    }

    # Post-deploy verification
    if ($null -ne $PostDeployGaps) {
        $postMissing = @($PostDeployGaps | Where-Object { -not $_.Exists }).Count
        $postPresent = $PostDeployGaps.Count - $postMissing

        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('---')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('## Post-Deploy Verification')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('| Metric | Count |')
        [void]$sb.AppendLine('| --- | ---: |')
        [void]$sb.AppendLine("| Expected baseline objects | $($PostDeployGaps.Count) |")
        [void]$sb.AppendLine("| Present after deploy | $postPresent |")
        [void]$sb.AppendLine("| Still missing | $postMissing |")
        [void]$sb.AppendLine('')
        if ($postMissing -eq 0) {
            [void]$sb.AppendLine('> All baseline objects verified present after deployment.')
        } else {
            [void]$sb.AppendLine("> **$postMissing object(s) still missing after deployment.** Review errors above or check skipped items.")
        }
        $pstCategories = $PostDeployGaps | Group-Object { $_['Category'] } | Sort-Object Name
        foreach ($pstCat in $pstCategories) {
            $catStillMissing = @($pstCat.Group | Where-Object { -not $_.Exists })
            if ($catStillMissing.Count -eq 0) { continue }
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine("### $($pstCat.Name) - Still Missing")
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine('| Name | Platform |')
            [void]$sb.AppendLine('| --- | --- |')
            foreach ($m in $catStillMissing) {
                [void]$sb.AppendLine("| ``$($m.Name)`` | $($m.Platform) |")
            }
        }
        [void]$sb.AppendLine('')
    }

    # Script errors
    if ($script:ErrorLog.Count -gt 0) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('---')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('## Errors During Detection')
        [void]$sb.AppendLine('')
        foreach ($e in $script:ErrorLog) { [void]$sb.AppendLine("- $e") }
    }

    $reportsDir = Join-Path $script:OutputPath 'Reports'
    New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null
    $reportFile = Join-Path $reportsDir "IntuneGapReport_${safe}_$(Get-Date -Format 'yyyyMMdd_HHmmss').md"
    $sb.ToString() | Set-Content -LiteralPath $reportFile -Encoding UTF8
    Write-Log "Gap report: $reportFile" -Level SUCCESS
    return $reportFile
}

function Write-TenantManifest {
    param([string]$PrepMode)

    $safe     = $script:ClientName -replace '[^A-Za-z0-9_-]', '_'
    $manifest = [ordered]@{
        ClientName    = $script:ClientName
        GeneratedAt   = (Get-Date -Format 'o')
        ScriptVersion = $script:ScriptVersion
        Mode          = $PrepMode
        Platform      = $script:Platform
        Objects       = $script:Manifest.ToArray()
    }

    $manifestsDir = Join-Path $script:OutputPath 'Manifests'
    New-Item -ItemType Directory -Path $manifestsDir -Force | Out-Null
    $manifestFile = Join-Path $manifestsDir "TenantManifest_${safe}_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestFile -Encoding UTF8
    Write-Log "Tenant manifest: $manifestFile" -Level SUCCESS
    return $manifestFile
}

# ─── Delete Group Wizard ──────────────────────────────────────────────────────

function Show-DeleteGroupWizard {
    Write-Host ''
    Write-Host '  ── Delete Group ──────────────────────────────────────────' -ForegroundColor DarkGray
    Write-Host '  Searches all security-enabled Entra groups by display name.' -ForegroundColor Gray
    Write-Host '  (Press Enter to cancel)' -ForegroundColor DarkGray
    Write-Host ''

    $searchInput = (Read-Host '  Search name (full or partial)').Trim()
    if ($searchInput -eq '') { return }

    # --- Ensure Graph is connected (read scope is sufficient for search) ---
    if (-not (Get-MgContext)) {
        Write-Host '  Connecting to Microsoft Graph...' -ForegroundColor Gray
        if (-not (Connect-GraphForPrep -PrepMode 'Detect')) {
            Write-Host '  Graph connection failed.' -ForegroundColor Red
            return
        }
    }

    # --- Search Graph (case-insensitive via $search + ConsistencyLevel header) ---
    Write-Host '  Searching...' -ForegroundColor Gray
    $encoded  = [Uri]::EscapeDataString("`"displayName:$searchInput`"")
    $uri      = "https://graph.microsoft.com/v1.0/groups?`$search=$encoded&`$select=id,displayName,groupTypes,membershipRule,securityEnabled&`$count=true&`$top=20"
    try {
        $response = Invoke-MgGraphRequest -Method GET -Uri $uri -Headers @{ ConsistencyLevel = 'eventual' } -ErrorAction Stop
    } catch {
        Write-Host "  Search failed: $($_.Exception.Message)" -ForegroundColor Red
        return
    }
    $allResults    = if ($response -and $response.value) { @($response.value) } else { @() }
    $matchedGroups = @($allResults | Where-Object { $_.securityEnabled -eq $true })

    if ($matchedGroups.Count -eq 0) {
        Write-Host "  No groups found matching '$searchInput'." -ForegroundColor Yellow
        return
    }

    # --- Show results ---
    Write-Host ''
    Write-Host '  Results:' -ForegroundColor Gray
    for ($i = 0; $i -lt $matchedGroups.Count; $i++) {
        $g    = $matchedGroups[$i]
        $type = if ($g.groupTypes -contains 'DynamicMembership') { 'Dynamic' } else { 'Assigned' }
        Write-Host ("  {0,2}. {1}  [{2}]" -f ($i + 1), $g.displayName, $type)
    }
    Write-Host ''

    $selInput = (Read-Host '  Select number to delete (Enter to cancel)').Trim()
    if ($selInput -eq '') { return }

    $selIndex = $null
    if ([int]::TryParse($selInput, [ref]$selIndex) -and $selIndex -ge 1 -and $selIndex -le $matchedGroups.Count) {
        $target = $matchedGroups[$selIndex - 1]
    } else {
        Write-Host '  Invalid selection.' -ForegroundColor Red
        return
    }

    # --- Confirm ---
    Write-Host ''
    Write-Host "  Group   : $($target.displayName)" -ForegroundColor White
    Write-Host "  ID      : $($target.id)" -ForegroundColor Gray
    Write-Host ''
    Write-Host '  WARNING: This permanently deletes the group from Entra ID.' -ForegroundColor Yellow
    $confirm = (Read-Host '  Type the group name to confirm deletion').Trim()

    if ($confirm -ne $target.displayName) {
        Write-Host '  Name did not match. Deletion cancelled.' -ForegroundColor Yellow
        return
    }

    # --- Re-connect with write scopes if needed ---
    $ctx = Get-MgContext
    if (-not $ctx -or $ctx.Scopes -notcontains 'Group.ReadWrite.All') {
        Write-Host '  Re-connecting with write permissions...' -ForegroundColor Gray
        if (-not (Connect-GraphForPrep -PrepMode 'Deploy')) {
            Write-Host '  Graph connection failed. Cannot delete group.' -ForegroundColor Red
            return
        }
    }

    $deleteUri = "https://graph.microsoft.com/v1.0/groups/$($target.id)"
    $ok = Invoke-GraphDelete -Uri $deleteUri -Area 'Groups'
    if ($ok) {
        Write-Host "  [OK] Deleted: $($target.displayName)" -ForegroundColor Green
        # Remove from cache if present
        if ($script:GroupIdCache.ContainsKey($target.displayName)) {
            $script:GroupIdCache.Remove($target.displayName)
        }
    } else {
        Write-Host "  Deletion failed. Check the log for details." -ForegroundColor Red
    }
}

# ─── New Group Wizard ─────────────────────────────────────────────────────────

function Show-NewGroupWizard {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $platformRules = @{
        WIN = '(device.deviceOSType -eq "Windows")'
        IOS = '(device.deviceOSType -eq "iOS")'
        MAC = '(device.deviceOSType -eq "MacMDM")'
    }

    Write-Host ''
    Write-Host '  ── New Group ─────────────────────────────────────────────' -ForegroundColor DarkGray
    Write-Host '  Naming pattern : GRP-{PLATFORM}-{Category}-{Detail}' -ForegroundColor Gray
    Write-Host '  Example        : GRP-WIN-Config-All' -ForegroundColor Gray
    Write-Host '  (Press Enter at any prompt to cancel)' -ForegroundColor DarkGray
    Write-Host ''

    # --- Type ---
    Write-Host '  Group type:' -ForegroundColor Gray
    Write-Host '    1. Assigned  (manual membership)'
    Write-Host '    2. Dynamic   (auto-membership by device OS rule)'
    $typeInput = (Read-Host '  Select').Trim()
    if ($typeInput -eq '') { return }
    $groupType = switch ($typeInput) {
        '1' { 'Assigned' }
        '2' { 'Dynamic'  }
        default {
            Write-Host "  Invalid selection." -ForegroundColor Red
            return
        }
    }

    # --- Platform ---
    Write-Host ''
    Write-Host '  Platform  [WIN / IOS / MAC / ALL]:' -ForegroundColor Gray
    $platInput = (Read-Host '  Platform').Trim().ToUpper()
    if ($platInput -eq '') { return }
    if ($platInput -notin @('WIN', 'IOS', 'MAC', 'ALL')) {
        Write-Host "  Invalid platform. Must be WIN, IOS, MAC, or ALL." -ForegroundColor Red
        return
    }
    $platform = $platInput

    # --- Category ---
    Write-Host ''
    Write-Host '  Standard categories: Autopilot  Apps  Compliance  Config  Updates  Security' -ForegroundColor Gray
    Write-Host '  You may enter a custom category (PascalCase, no spaces).' -ForegroundColor DarkGray
    $catInput = (Read-Host '  Category').Trim()
    if ($catInput -eq '') { return }

    # --- Detail (optional) ---
    Write-Host ''
    Write-Host '  Detail is optional - narrows scope. Use hyphens for compound details.' -ForegroundColor DarkGray
    Write-Host '  Examples: All  Pilot  NinjaAgent  NinjaAgent-TX  UpdateRing-Broad' -ForegroundColor DarkGray
    $detailInput = (Read-Host '  Detail (Enter to skip)').Trim()

    # --- Assemble name ---
    $nameParts = @('GRP', $platform, $catInput)
    if ($detailInput -ne '') { $nameParts += $detailInput }
    $groupName = $nameParts -join '-'

    # --- Description ---
    Write-Host ''
    $descInput = (Read-Host "  Description (Enter to skip)").Trim()

    # --- Membership rule ---
    $membershipRule = $null
    if ($groupType -eq 'Dynamic') {
        $defaultRule = if ($platform -and $platformRules.ContainsKey($platform)) {
            $platformRules[$platform]
        } else {
            ''
        }
        Write-Host ''
        if ($defaultRule -ne '') {
            Write-Host "  Default rule   : $defaultRule" -ForegroundColor Gray
            $ruleInput = (Read-Host '  Membership rule (Enter to accept default)').Trim()
            $membershipRule = if ($ruleInput -ne '') { $ruleInput } else { $defaultRule }
        } else {
            $ruleInput = (Read-Host '  Membership rule').Trim()
            if ($ruleInput -eq '') { return }
            $membershipRule = $ruleInput
        }
    }

    # --- Preview and confirm ---
    Write-Host ''
    Write-Host '  ── Preview ───────────────────────────────────────────────' -ForegroundColor DarkGray
    Write-Host "  Name        : $groupName"
    Write-Host "  Type        : $groupType"
    if ($platform)        { Write-Host "  Platform    : $platform" }
    if ($descInput -ne '') { Write-Host "  Description : $descInput" }
    if ($membershipRule)  { Write-Host "  Rule        : $membershipRule" }
    Write-Host ''

    $confirm = (Read-Host '  Create this group? [Y/N]').Trim().ToUpper()
    if ($confirm -ne 'Y') {
        Write-Host '  Cancelled.' -ForegroundColor Yellow
        return
    }

    # --- Ensure Graph is connected with write scopes ---
    if (-not (Get-MgContext)) {
        Write-Host '  Connecting to Microsoft Graph...' -ForegroundColor Gray
        if (-not (Connect-GraphForPrep -PrepMode 'Deploy')) {
            Write-Host '  Graph connection failed. Cannot create group.' -ForegroundColor Red
            return
        }
    }

    # --- Build def and create ---
    $groupDef = @{
        Name        = $groupName
        Type        = $groupType
        Description = $descInput
    }
    if ($membershipRule) { $groupDef['MembershipRule'] = $membershipRule }

    New-IntuneGroupIfNotExists -GroupDef $groupDef
}

# ─── Menu ─────────────────────────────────────────────────────────────────────

function Show-PrepMenu {
    while ($true) {
        $tpDisplay = if ($script:TemplatePath -and (Test-Path -LiteralPath $script:TemplatePath -PathType Container)) {
            $script:TemplatePath
        } else { '(not set)' }
        $tpColor   = if ($tpDisplay -eq '(not set)') { 'Yellow' } else { 'White' }

        # Groups catalog status for display
        $groupsFile   = if ($script:TemplatePath) { Join-Path $script:TemplatePath 'Groups\Groups.json' } else { $null }
        $groupsFound  = $groupsFile -and (Test-Path -LiteralPath $groupsFile)
        $groupsCount  = $script:BaselineCatalog.Groups.Count
        $groupDisplay = if ($groupsFound)  { "$groupsCount groups  (Groups\Groups.json)" }
                        elseif ($tpDisplay -ne '(not set)') { '[!] Groups\Groups.json not found' }
                        else   { '(template path not set)' }
        $groupColor   = if ($groupsFound) { 'White' } else { 'Yellow' }

        # Variables.json status for display
        $varsFile    = if ($script:TemplatePath) { Join-Path $script:TemplatePath 'Variables.json' } else { $null }
        $varsFound   = $varsFile -and (Test-Path -LiteralPath $varsFile)
        $varsCount   = $script:TemplateVariables.Count
        $varsDisplay = if ($varsFound)                      { "$varsCount variable(s)  (Variables.json)" }
                       elseif ($tpDisplay -ne '(not set)') { '(Variables.json not found — optional)' }
                       else                                { '(template path not set)' }
        $varsColor   = if ($varsFound) { 'White' } else { 'DarkGray' }

        # Profile status for display
        $profDisplay = if ($script:ProfilePath -ne '') { $script:ProfilePath } else { '(none)' }
        $profColor   = if ($script:ProfilePath -ne '') { 'White' } else { 'DarkGray' }

        $exclDisplay  = if ($script:ExcludeObject.Count -gt 0) { $script:ExcludeObject -join ', ' } else { '(none)' }
        $exclColor    = if ($script:ExcludeObject.Count -gt 0) { 'Yellow' } else { 'DarkGray' }

        Write-Host ''
        Write-Host '  ╔════════════════════════════════════════╗' -ForegroundColor Cyan
        Write-Host "  ║    Intune Tenant Prep  v$($script:ScriptVersion.PadRight(15))║" -ForegroundColor Cyan
        Write-Host '  ╚════════════════════════════════════════╝' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '  ── Settings ──────────────────────────────────────────' -ForegroundColor DarkGray
        Write-Host '  C. Client name    : ' -NoNewline -ForegroundColor Gray; Write-Host $script:ClientName  -ForegroundColor White
        Write-Host '  P. Platform       : ' -NoNewline -ForegroundColor Gray; Write-Host $script:Platform    -ForegroundColor White
        Write-Host '  T. Template path  : ' -NoNewline -ForegroundColor Gray; Write-Host $tpDisplay          -ForegroundColor $tpColor
        Write-Host '     Groups catalog : ' -NoNewline -ForegroundColor Gray; Write-Host $groupDisplay       -ForegroundColor $groupColor
        Write-Host '     Variables      : ' -NoNewline -ForegroundColor Gray; Write-Host $varsDisplay        -ForegroundColor $varsColor
        Write-Host '  O. Output path    : ' -NoNewline -ForegroundColor Gray; Write-Host $script:OutputPath  -ForegroundColor White
        Write-Host '  X. Excluded       : ' -NoNewline -ForegroundColor Gray; Write-Host $exclDisplay        -ForegroundColor $exclColor
        Write-Host '  L. Profile        : ' -NoNewline -ForegroundColor Gray; Write-Host $profDisplay        -ForegroundColor $profColor
        Write-Host ''
        Write-Host '  ── Actions ───────────────────────────────────────────' -ForegroundColor DarkGray
        Write-Host '  1. Detect  - Gap report only (read-only, no tenant changes)'
        Write-Host '  2. Deploy  - Create missing baseline objects from templates'
        Write-Host '  3. Undo    - Delete objects created by a prior Deploy run'
        Write-Host '  4. Reset   - Scan live tenant and build a full reset manifest'
        Write-Host '  B. Baselines - View baseline catalog with template status'
        Write-Host '  G. Groups  - View loaded group catalog (edit Groups\Groups.json)'
        Write-Host '  N. New     - Create a new group following naming conventions'
        Write-Host '  D. Delete  - Find and delete a group by name search'
        Write-Host '  S. Save profile  - Save current settings to a profile JSON'
        Write-Host '  Q. Quit'
        Write-Host ''

        $choice = (Read-Host '  Select').Trim().ToUpper()

        switch ($choice) {
            'C' {
                $val = (Read-Host '  Client name').Trim()
                if ($val -ne '') { $script:ClientName = $val }
            }
            'P' {
                Write-Host '  Options: All  WIN  IOS  MAC' -ForegroundColor Gray
                $val = (Read-Host '  Platform').Trim().ToUpper()
                if ($val -in @('ALL', 'WIN', 'IOS', 'MAC')) {
                    $script:Platform = if ($val -eq 'ALL') { 'All' } else { $val }
                } else {
                    Write-Host "  Invalid platform '$val' — must be All, WIN, IOS, or MAC" -ForegroundColor Red
                }
            }
            'T' {
                $val = (Read-Host '  Templates path (Enter to clear)').Trim().Trim('"').Trim("'")
                if ($val -eq '') {
                    $script:TemplatePath = ''
                } elseif (Test-Path -LiteralPath $val -PathType Container) {
                    $script:TemplatePath = $val
                } else {
                    Write-Host "  Path not found: $val" -ForegroundColor Red
                }
            }
            'O' {
                $val = (Read-Host '  Output path').Trim().Trim('"').Trim("'")
                if ($val -ne '') { $script:OutputPath = $val }
            }
            'X' {
                Write-Host ''
                if ($script:ExcludeObject.Count -gt 0) {
                    Write-Host "  Current exclusions: $($script:ExcludeObject -join ', ')" -ForegroundColor Yellow
                }
                Write-Host '  Enter object names to exclude from Detect/Deploy (comma-separated).' -ForegroundColor Gray
                Write-Host '  Press Enter with no input to clear all exclusions.' -ForegroundColor Gray
                $val = (Read-Host '  Exclusions').Trim()
                if ($val -eq '') {
                    $script:ExcludeObject = @()
                    Write-Host '  Exclusions cleared.' -ForegroundColor Green
                } else {
                    $script:ExcludeObject = @($val -split '\s*,\s*' | Where-Object { $_ -ne '' })
                    Write-Host "  Now excluding $($script:ExcludeObject.Count) item(s)." -ForegroundColor Yellow
                }
            }
            'L' {
                $val = (Read-Host '  Profile path (Enter to cancel)').Trim().Trim('"').Trim("'")
                if ($val -ne '') {
                    $null = Import-ClientProfile -Path $val
                }
            }
            'S' {
                $hint = if ($script:ProfilePath -ne '') { "  Save path (Enter = $script:ProfilePath)" } else { '  Save path (e.g. C:\Clients\Contoso.json)' }
                $val  = (Read-Host $hint).Trim().Trim('"').Trim("'")
                if ($val -eq '' -and $script:ProfilePath -ne '') { $val = $script:ProfilePath }
                if ($val -ne '') {
                    $null = Export-ClientProfile -Path $val
                }
            }
            '1' { return 'Detect' }
            '2' { return 'Deploy' }
            '4' { return 'Reset' }
            'B' {
                Show-BaselineCatalog -FilterPlatform $script:Platform
                Write-Host '  Press Enter to return to menu...' -ForegroundColor Gray
                $null = Read-Host
            }
            '3' {
                # Discover available manifests in the Manifests subfolder
                $availableManifests = @()
                $manifestsDir = Join-Path $script:OutputPath 'Manifests'
                if ($script:OutputPath -and (Test-Path $manifestsDir)) {
                    $availableManifests = @(Get-ChildItem -Path $manifestsDir -Filter 'TenantManifest_*.json' -ErrorAction SilentlyContinue |
                        Sort-Object LastWriteTime -Descending)
                }

                Write-Host ''
                if ($availableManifests.Count -gt 0) {
                    Write-Host "  Available manifests in $manifestsDir" -ForegroundColor DarkGray
                    Write-Host ''
                    for ($i = 0; $i -lt $availableManifests.Count; $i++) {
                        $mf  = $availableManifests[$i]
                        $ts  = $mf.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
                        $cur = if ($mf.FullName -eq $script:ManifestPath) { ' *' } else { '   ' }
                        Write-Host ('  {0,2}.{1} {2}  ({3})' -f ($i + 1), $cur, $mf.Name, $ts)
                    }
                    Write-Host ''
                } else {
                    Write-Host "  No TenantManifest_*.json files found in $manifestsDir" -ForegroundColor DarkGray
                    Write-Host ''
                }

                if ($script:ManifestPath -ne '') {
                    Write-Host "  Current : $script:ManifestPath" -ForegroundColor Gray
                }

                $manifestOk = $false
                do {
                    $hint    = if ($script:ManifestPath -ne '') { ', Enter = keep current' } else { ', Enter = go back' }
                    $entered = (Read-Host "  Select number or path$hint").Trim().Trim('"').Trim("'")
                    if ($entered -eq '' -and $script:ManifestPath -ne '') {
                        $manifestOk = $true
                    } elseif ($entered -eq '') {
                        break
                    } elseif ($entered -match '^\d+$') {
                        $idx = [int]$entered - 1
                        if ($idx -ge 0 -and $idx -lt $availableManifests.Count) {
                            $script:ManifestPath = $availableManifests[$idx].FullName
                            $manifestOk = $true
                        } else {
                            Write-Host "  Invalid selection. Enter 1-$($availableManifests.Count)." -ForegroundColor Red
                        }
                    } elseif (-not (Test-Path -LiteralPath $entered)) {
                        Write-Host "  File not found: $entered" -ForegroundColor Red
                    } else {
                        $script:ManifestPath = $entered
                        $manifestOk = $true
                    }
                } while (-not $manifestOk)
                if ($manifestOk) { return 'Undo' }
            }
            'N' {
                Show-NewGroupWizard
                Write-Host ''
                Write-Host '  Press Enter to return to menu...' -ForegroundColor Gray
                $null = Read-Host
            }
            'G' {
                $gFile = if ($script:TemplatePath) { Join-Path $script:TemplatePath 'Groups\Groups.json' } else { '(template path not set)' }
                Write-Host ''
                Write-Host '  ── Group Catalog ─────────────────────────────────────' -ForegroundColor DarkGray
                Write-Host "  File   : $gFile" -ForegroundColor Gray
                Write-Host "  Loaded : $($script:BaselineCatalog.Groups.Count) group(s)" -ForegroundColor White
                Write-Host ''
                if ($script:BaselineCatalog.Groups.Count -gt 0) {
                    Write-Host ('  {0,-10} {1,-10} {2}' -f 'Platform', 'Type', 'Name') -ForegroundColor DarkGray
                    Write-Host ('  {0,-10} {1,-10} {2}' -f '--------', '--------', '----') -ForegroundColor DarkGray
                    foreach ($g in ($script:BaselineCatalog.Groups | Sort-Object Platform, Name)) {
                        Write-Host ('  {0,-10} {1,-10} {2}' -f $g.Platform, $g.Type, $g.Name)
                    }
                    Write-Host ''
                }
                Write-Host '  To add, remove, or modify groups: edit Groups\Groups.json in the template folder.' -ForegroundColor DarkGray
                Write-Host '  Changes take effect on the next Detect, Deploy, or menu action.' -ForegroundColor DarkGray
                Write-Host ''
                Write-Host '  Press Enter to return to menu...' -ForegroundColor Gray
                $null = Read-Host
            }
            'D' {
                Show-DeleteGroupWizard
                Write-Host ''
                Write-Host '  Press Enter to return to menu...' -ForegroundColor Gray
                $null = Read-Host
            }
            'Q' { return 'Quit' }
            default { Write-Host "  Unknown option: $choice" -ForegroundColor Red }
        }
    }
}

# ─── Entry Function ───────────────────────────────────────────────────────────

function Invoke-IntuneTenantPrep {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidateSet('Detect', 'Deploy', 'Menu', 'Undo', 'Reset', 'NewGroup', 'DeleteGroup')]
        [string]$Mode,

        [string]$ClientName,

        [ValidateSet('All', 'WIN', 'IOS', 'MAC')]
        [string]$Platform,

        [string]$OutputPath,
        [string]$TemplatePath,
        [string]$AuditReportPath,
        [string]$ManifestPath,
        [string]$GroupName,

        [ValidateSet('Assigned', 'Dynamic')]
        [string]$GroupType,

        [string]$GroupDescription,
        [string]$GroupMembershipRule,
        [string[]]$ExcludeObject = @(),
        [string]$ProfilePath = '',
        [switch]$PostDeployVerify
    )

    # When called directly in copy-paste / dot-source mode, explicit args
    # override the script-scope vars that were set from the initial param block.
    if ($PSBoundParameters.ContainsKey('Mode'))                 { $script:Mode                = $Mode }
    if ($PSBoundParameters.ContainsKey('ClientName'))           { $script:ClientName           = $ClientName }
    if ($PSBoundParameters.ContainsKey('Platform'))             { $script:Platform             = $Platform }
    if ($PSBoundParameters.ContainsKey('OutputPath'))           { $script:OutputPath           = $OutputPath }
    if ($PSBoundParameters.ContainsKey('TemplatePath'))         { $script:TemplatePath         = $TemplatePath }
    if ($PSBoundParameters.ContainsKey('AuditReportPath'))      { $script:AuditReportPath      = $AuditReportPath }
    if ($PSBoundParameters.ContainsKey('ManifestPath'))         { $script:ManifestPath         = $ManifestPath }
    if ($PSBoundParameters.ContainsKey('GroupName'))            { $script:GroupName            = $GroupName }
    if ($PSBoundParameters.ContainsKey('GroupType'))            { $script:GroupType            = $GroupType }
    if ($PSBoundParameters.ContainsKey('GroupDescription'))     { $script:GroupDescription     = $GroupDescription }
    if ($PSBoundParameters.ContainsKey('GroupMembershipRule'))  { $script:GroupMembershipRule  = $GroupMembershipRule }
    if ($PSBoundParameters.ContainsKey('ExcludeObject'))        { $script:ExcludeObject        = $ExcludeObject }
    if ($PSBoundParameters.ContainsKey('ProfilePath'))          { $script:ProfilePath          = $ProfilePath }
    if ($PSBoundParameters.ContainsKey('PostDeployVerify'))     { $script:PostDeployVerify     = $PostDeployVerify.IsPresent }

    # Load client profile if ProfilePath is set (profile values applied first;
    # any PSBoundParameters already applied above will have overridden defaults,
    # but profile only fills values that weren't explicitly passed).
    # Re-load here so that -ProfilePath on the entry function also works in
    # copy-paste / dot-source mode.
    if ($script:ProfilePath -ne '') {
        $null = Import-ClientProfile -Path $script:ProfilePath
    }

    # Re-resolve template path when called in copy-paste / dot-source mode,
    # since the script-level Resolve-TemplatePath ran with the original args.
    if ($PSBoundParameters.ContainsKey('TemplatePath') -and $TemplatePath -ne '') {
        $script:TemplatePath = $TemplatePath
    }

    # If still unresolved, prompt interactively (Deploy needs templates; Detect
    # and Undo can continue without them).
    if ($script:TemplatePath -eq '' -or -not (Test-Path -LiteralPath $script:TemplatePath -PathType Container)) {
        $autoTp = Resolve-TemplatePath -Explicit ''
        if ($autoTp) {
            $script:TemplatePath = $autoTp
            Write-Log "Templates found at: $script:TemplatePath" -Level INFO
        } elseif (-not $script:Quiet) {
            Write-Host ''
            Write-Host '  Template folder not found automatically.' -ForegroundColor Yellow
            Write-Host '  Press Enter to skip templates (Detect/Undo still work),' -ForegroundColor Yellow
            Write-Host '  or enter the full path to your Templates folder:' -ForegroundColor Yellow
            $entered = (Read-Host '  Templates path').Trim().Trim('"').Trim("'")
            if ($entered -ne '' -and (Test-Path -LiteralPath $entered -PathType Container)) {
                $script:TemplatePath = $entered
                Write-Log "Template path set to: $script:TemplatePath" -Level INFO
            } else {
                if ($entered -ne '') { Write-Host "  Path not found: $entered" -ForegroundColor Red }
                Write-Log 'Template path not provided or not found — Deploy will skip policy templates.' -Level WARN
                $script:TemplatePath = ''
            }
        } else {
            Write-Log 'Template path not found — Deploy will skip policy templates.' -Level WARN
            $script:TemplatePath = ''
        }
    } else {
        Write-Log "Templates: $script:TemplatePath" -Level INFO
    }

    $menuMode = ($script:Mode -eq 'Menu')

    while ($true) {
        # Reset per-run state so successive menu operations start clean
        $script:Manifest = [System.Collections.Generic.List[hashtable]]::new()
        $script:ErrorLog  = [System.Collections.Generic.List[string]]::new()
        $script:ExitCode  = 0

        # Reload group catalog and template variables each iteration so edits
        # take effect without restarting the session (template path may have
        # been changed via the T menu option since the last run).
        $script:BaselineCatalog['Groups'] = Import-GroupCatalog
        $script:TemplateVariables         = Import-TemplateVariables

        if ($menuMode) {
            $resolvedMode = Show-PrepMenu
            if ($resolvedMode -eq 'Quit') {
                Write-Log 'Exiting.' -Level INFO
                exit 0
            }
        } else {
            $resolvedMode = $script:Mode
        }

        Write-Log "Intune Tenant Prep v$($script:ScriptVersion) — Mode: $resolvedMode | Client: $($script:ClientName) | Platform: $($script:Platform)" -Level INFO

        if (-not (Test-Prerequisites)) {
            if ($menuMode) { continue }
            exit 20
        }

        if (-not (Connect-GraphForPrep -PrepMode $resolvedMode)) {
            $script:ExitCode = 20
            if ($menuMode) { continue }
            exit 20
        }

        # NewGroup mode — create a single group non-interactively
        if ($resolvedMode -eq 'NewGroup') {
            if ($script:GroupName -eq '') {
                Write-Log 'NewGroup mode requires -GroupName.' -Level ERROR
                if ($menuMode) { continue }
                exit 20
            }
            $groupDef = @{
                Name        = $script:GroupName
                Type        = if ($script:GroupType -ne '') { $script:GroupType } else { 'Assigned' }
                Description = $script:GroupDescription
            }
            if ($script:GroupMembershipRule -ne '') { $groupDef['MembershipRule'] = $script:GroupMembershipRule }
            New-IntuneGroupIfNotExists -GroupDef $groupDef
            if ($menuMode) {
                Write-Host ''
                Write-Host '  Press Enter to return to menu...' -ForegroundColor Gray
                $null = Read-Host
                continue
            }
            exit $script:ExitCode
        }

        # DeleteGroup mode — delete a group by exact name non-interactively
        if ($resolvedMode -eq 'DeleteGroup') {
            if ($script:GroupName -eq '') {
                Write-Log 'DeleteGroup mode requires -GroupName.' -Level ERROR
                if ($menuMode) { continue }
                exit 20
            }
            $encoded  = [Uri]::EscapeDataString("`"displayName:$($script:GroupName)`"")
            $uri      = "https://graph.microsoft.com/v1.0/groups?`$search=$encoded&`$select=id,displayName,securityEnabled&`$count=true&`$top=5"
            try {
                $resp = Invoke-MgGraphRequest -Method GET -Uri $uri -Headers @{ ConsistencyLevel = 'eventual' } -ErrorAction Stop
            } catch {
                Write-Log "Group search failed: $($_.Exception.Message)" -Level ERROR
                if ($menuMode) { continue }
                exit 20
            }
            $match = @($resp.value | Where-Object { $_.displayName -eq $script:GroupName -and $_.securityEnabled })
            if ($match.Count -eq 0) {
                Write-Log "Group not found: $($script:GroupName)" -Level WARN
                if ($menuMode) { continue }
                exit 1
            }
            $deleteUri = "https://graph.microsoft.com/v1.0/groups/$($match[0].id)"
            $ok = Invoke-GraphDelete -Uri $deleteUri -Area 'Groups'
            if ($ok) {
                Write-Log "[OK] Deleted group: $($script:GroupName)" -Level SUCCESS
                if ($script:GroupIdCache.ContainsKey($script:GroupName)) { $script:GroupIdCache.Remove($script:GroupName) }
            }
            if ($menuMode) {
                Write-Host ''
                Write-Host '  Press Enter to return to menu...' -ForegroundColor Gray
                $null = Read-Host
                continue
            }
            exit $script:ExitCode
        }

        # Undo mode — load manifest and delete; no gap analysis needed
        if ($resolvedMode -eq 'Undo') {
            if ($script:ManifestPath -eq '') {
                Write-Log 'Undo mode requires -ManifestPath pointing to a TenantManifest JSON from a prior Deploy run.' -Level ERROR
                if ($menuMode) { continue }
                exit 20
            }
            Invoke-BaselineUndo -ManifestFile $script:ManifestPath
            if ($menuMode) {
                Write-Host ''
                Write-Host '  Press Enter to return to menu...' -ForegroundColor Gray
                $null = Read-Host
                continue
            }
            exit $script:ExitCode
        }

        # Reset mode — scan live tenant and build a synthetic full-reset manifest
        if ($resolvedMode -eq 'Reset') {
            $live = Get-LiveTenantObjects
            New-ResetManifest -Live $live
            $manifestFile = Write-TenantManifest -PrepMode 'Reset'
            Write-Log 'Reset manifest written. Run Undo mode with this manifest to delete all baseline objects.' -Level SUCCESS
            Write-Log "Manifest: $manifestFile" -Level INFO
            if ($menuMode) {
                Write-Host ''
                Write-Host '  Press Enter to return to menu...' -ForegroundColor Gray
                $null = Read-Host
                continue
            }
            exit $script:ExitCode
        }

        # Import prior audit findings when provided
        $auditFindings = @()
        if ($script:AuditReportPath -ne '' -and (Test-Path -LiteralPath $script:AuditReportPath)) {
            $auditFindings = Import-AuditReportFindings -ReportPath $script:AuditReportPath
        } elseif ($script:AuditReportPath -ne '') {
            Write-Log "AuditReportPath specified but file not found: $($script:AuditReportPath)" -Level WARN
        }

        # Query live tenant state
        $live = Get-LiveTenantObjects

        # Compare against baseline catalog
        $gaps         = Get-BaselineGaps -Live $live
        $missingCount = @($gaps | Where-Object { -not $_.Exists }).Count

        if ($missingCount -gt 0) {
            Write-Log "Gap analysis: $missingCount of $($gaps.Count) expected baseline objects are MISSING" -Level WARN
        } else {
            Write-Log "Gap analysis: all $($gaps.Count) expected baseline objects are present" -Level SUCCESS
            if ($script:ExitCode -lt 1) { $script:ExitCode = 0 }
        }

        # Deploy if requested
        $postDeployGaps = $null
        if ($resolvedMode -eq 'Deploy') {
            if ($missingCount -eq 0) {
                Write-Log 'Nothing to deploy — tenant already matches baseline.' -Level SUCCESS
            } else {
                # Pre-deploy summary; prompts Y/N confirmation in Menu mode
                $proceedDeploy = Show-PreDeploySummary -Gaps $gaps -PromptConfirm:$menuMode
                if ($proceedDeploy) {
                    Invoke-BaselineDeploy -Live $live

                    # Post-deploy verification (always in Menu mode; or when -PostDeployVerify set)
                    if ($script:PostDeployVerify -or $menuMode) {
                        Write-Log 'Running post-deploy verification...' -Level INFO
                        $postLive       = Get-LiveTenantObjects
                        $postDeployGaps = Get-BaselineGaps -Live $postLive
                        $postMissing    = @($postDeployGaps | Where-Object { -not $_.Exists }).Count
                        $postLevel      = if ($postMissing -eq 0) { 'SUCCESS' } else { 'WARN' }
                        Write-Log "Post-deploy: $postMissing of $($postDeployGaps.Count) object(s) still missing" -Level $postLevel
                    }
                } else {
                    Write-Log 'Deployment cancelled by user.' -Level WARN
                    Write-Host ''
                    Write-Host '  Press Enter to return to menu...' -ForegroundColor Gray
                    $null = Read-Host
                    continue
                }
            }
        }

        # Write outputs
        $reportFile   = Write-GapReport   -Gaps $gaps -AuditFindings $auditFindings -PostDeployGaps $postDeployGaps
        $manifestFile = Write-TenantManifest -PrepMode $resolvedMode

        $finalLevel = if ($script:ExitCode -eq 0) { 'SUCCESS' } else { 'WARN' }
        Write-Log "Complete. Exit code: $($script:ExitCode)" -Level $finalLevel
        Write-Log "Report:   $reportFile"   -Level INFO
        Write-Log "Manifest: $manifestFile" -Level INFO

        if ($menuMode) {
            Write-Host ''
            Write-Host '  Press Enter to return to menu...' -ForegroundColor Gray
            $null = Read-Host
            continue
        }
        exit $script:ExitCode
    }  # end while ($true)
}

# ─── Entry Point ──────────────────────────────────────────────────────────────

#Invoke-IntuneTenantPrep -ClientName "AxxysLab" -Mode Menu
#Invoke-IntuneTenantPrep -ProfilePath "C:\Temp\IntuneTenantPrep\Templates\ClientProfile.template.json" -Mode Menu