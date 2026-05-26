#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Comprehensive Hyper-V host and VM assessment against Microsoft best practices.

.DESCRIPTION
    Performs detailed assessment of Hyper-V environments including:
    
    - Host configuration (power plan, BIOS settings, memory, antivirus, firewall)
    - Antivirus detection (15+ AV products) and Defender exclusion validation
    - Storage configuration (iSCSI, MPIO, disk timeouts, VHDX settings)
    - Network configuration (VMQ, RSS, NIC power management, teaming)
    - VM configuration (generation, integration services, workload-specific)
    - Cluster configuration (quorum, CSV, live migration)
    - Security (Secure Boot, vTPM, shielded VMs)
    
    Auto-detects standalone vs. clustered environments and adjusts checks accordingly.
    Provides remediation commands for each finding without auto-applying changes.

.NOTES
    Script:  HyperVAssessment.ps1
    Author:  Jeff Davidson
    Version: 1.5.0
    Date:    2026-03-09
    
    Supports dual-mode execution:
    - Direct: .\HyperVAssessment.ps1 -Mode Quick
    - Function: Copy-paste script, then call HyperVAssessment -Mode Quick
    
    Exit Codes:
        0  - Success, no critical issues
        1  - Critical issues found
        10 - Warning issues found (no critical)
        20 - Script error / prerequisites not met

.PARAMETER Mode
    Assessment depth: Quick (critical only), Standard (common checks), Full (all checks including all VMs)

.PARAMETER Category
    Limit assessment to specific category: Host, Storage, Network, VM, Cluster, Security, All

.PARAMETER VMName
    Assess specific VMs only. Accepts wildcards. Default: all VMs.

.PARAMETER OutputPath
    Directory for output files. Default: C:\Temp\HyperVAssessment

.PARAMETER OutputFormat
    Report formats to generate: JSON, CSV, HTML, All. Default: All

.PARAMETER Quiet
    Suppress console output for RMM execution.

.PARAMETER PassThru
    Return assessment results as objects for pipeline.

.PARAMETER AutoExport
    Automatically export reports to OutputPath.

.PARAMETER NinjaCustomField
    Write summary to NinjaRMM text custom field.

.PARAMETER NinjaHTMLField
    Write HTML report to NinjaRMM WYSIWYG field.

.EXAMPLE
    .\HyperVAssessment.ps1 -Mode Quick
    Run critical checks only with console output.

.EXAMPLE
    .\HyperVAssessment.ps1 -Mode Standard -AutoExport
    Run standard assessment and save reports to C:\Temp\HyperVAssessment\

.EXAMPLE
    .\HyperVAssessment.ps1 -Mode Full -Category Storage -OutputFormat HTML
    Run full storage assessment and generate HTML report only.

.EXAMPLE
    .\HyperVAssessment.ps1 -Mode Standard -VMName "SQL*" -AutoExport
    Assess only VMs matching "SQL*" pattern.

.EXAMPLE
    .\HyperVAssessment.ps1 -Mode Standard -Quiet -AutoExport -NinjaCustomField 'hvAssessStatus' -NinjaHTMLField 'hvAssessReport'
    NinjaRMM scheduled monitoring - writes summary to text field, full HTML to WYSIWYG field.

.EXAMPLE
    # Copy-paste into PowerShell, then call as function:
    HyperVAssessment -Mode Quick
#>

function HyperVAssessment {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [ValidateSet('Quick', 'Standard', 'Full')]
        [string]$Mode = 'Standard',

        [Parameter()]
        [ValidateSet('Host', 'Storage', 'Network', 'VM', 'Cluster', 'Security', 'All')]
        [string]$Category = 'All',

        [Parameter()]
        [string[]]$VMName = @('*'),

        [Parameter()]
        [string]$OutputPath = "C:\Temp\HyperVAssessment",

        [Parameter()]
        [ValidateSet('JSON', 'CSV', 'HTML', 'Markdown', 'All')]
        [string]$OutputFormat = 'All',

        [Parameter()]
        [switch]$Quiet,

        [Parameter()]
        [switch]$PassThru,

        [Parameter()]
        [switch]$AutoExport,

        [Parameter()]
        [string]$NinjaCustomField = '',

        [Parameter()]
        [string]$NinjaHTMLField = ''
    )

    #region Configuration
# Load System.Web for HTML encoding in reports
Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

$script:ScriptVersion = "1.5.0"
$script:ScriptName = "HyperVAssessment"
$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$script:IsServer = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue).ProductType -ne 1
$script:StartTime = Get-Date
$script:LogFile = $null

# Environment detection (populated during initialization)
$script:Environment = @{
    IsHyperVHost    = $false
    IsClusterNode   = $false
    ClusterName     = $null
    ClusterNodes    = @()
    OSVersion       = $null
    OSBuild         = $null
    HostName        = $env:COMPUTERNAME
}

# Assessment results collection
$script:Findings = [System.Collections.ArrayList]::new()
$script:Summary = @{
    Critical = 0
    Warning  = 0
    Info     = 0
    Pass     = 0
    Total    = 0
}
#endregion

#region NinjaRMM Output
function Write-NinjaOutput {
    if (-not $NinjaCustomField -and -not $NinjaHTMLField) { return }

    try {
        $cluster = if ($script:Environment.IsClusterNode) { $script:Environment.ClusterName } else { 'Standalone' }
        $summaryText = "HyperV: C=$($script:Summary.Critical) W=$($script:Summary.Warning) P=$($script:Summary.Pass) ($($script:Summary.Total) checks) [$cluster]"

        if ($NinjaCustomField) {
            Ninja-Property-Set $NinjaCustomField $summaryText 2>$null
        }
        if ($NinjaHTMLField) {
            $htmlPath = Join-Path $env:TEMP 'HyperVAssessment_ninja.html'
            Export-HtmlReport -Path $htmlPath
            $htmlContent = Get-Content -Path $htmlPath -Raw
            Ninja-Property-Set $NinjaHTMLField $htmlContent 2>$null
            Remove-Item -Path $htmlPath -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Log "NinjaRMM output failed: $_" -Level 'DEBUG'
    }
}
#endregion

#region Logging Functions
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS', 'DEBUG')]
        [string]$Level = 'INFO'
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logLine = "[$timestamp] [$Level] $Message"
    
    if (-not $Quiet) {
        $color = switch ($Level) {
            'INFO'    { 'White' }
            'WARN'    { 'Yellow' }
            'ERROR'   { 'Red' }
            'SUCCESS' { 'Green' }
            'DEBUG'   { 'Gray' }
        }
        Write-Host $logLine -ForegroundColor $color
    }
    
    if ($script:LogFile) {
        $logLine | Out-File -FilePath $script:LogFile -Encoding UTF8 -Append
    }
}

function Write-Finding {
    param(
        [Parameter(Mandatory)]
        [string]$Category,
        
        [Parameter(Mandatory)]
        [string]$Check,
        
        [Parameter(Mandatory)]
        [ValidateSet('Critical', 'Warning', 'Info', 'Pass')]
        [string]$Severity,
        
        [Parameter(Mandatory)]
        [string]$CurrentState,
        
        [string]$ExpectedState = '',
        
        [string]$Impact = '',
        
        [string]$Remediation = '',
        
        [string]$Reference = ''
    )
    
    $finding = [PSCustomObject]@{
        Category      = $Category
        Check         = $Check
        Severity      = $Severity
        CurrentState  = $CurrentState
        ExpectedState = $ExpectedState
        Impact        = $Impact
        Remediation   = $Remediation
        Reference     = $Reference
        Timestamp     = Get-Date -Format 'o'
        Host          = $script:Environment.HostName
    }
    
    [void]$script:Findings.Add($finding)
    $script:Summary[$Severity]++
    $script:Summary.Total++
    
    # Console output
    $icon = switch ($Severity) {
        'Critical' { '[X]' }
        'Warning'  { '[!]' }
        'Info'     { '[i]' }
        'Pass'     { '[+]' }
    }
    
    $color = switch ($Severity) {
        'Critical' { 'Red' }
        'Warning'  { 'Yellow' }
        'Info'     { 'Cyan' }
        'Pass'     { 'Green' }
    }
    
    if (-not $Quiet) {
        Write-Host "  $icon " -ForegroundColor $color -NoNewline
        Write-Host "$Check - " -NoNewline
        Write-Host $CurrentState -ForegroundColor $color
    }
}
#endregion

#region Output Functions
function Initialize-OutputDirectory {
    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
        Write-Log "Created output directory: $OutputPath" -Level 'DEBUG'
    }
    $script:LogFile = Join-Path $OutputPath "$script:ScriptName`_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
}

function Export-Results {
    if (-not $AutoExport) { return }
    
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $baseName = "$script:ScriptName`_$($script:Environment.HostName)_$timestamp"
    
    # JSON Export
    if ($OutputFormat -in @('JSON', 'All')) {
        $jsonPath = Join-Path $OutputPath "$baseName.json"
        $exportData = @{
            Metadata = @{
                ScriptVersion = $script:ScriptVersion
                AssessmentDate = $script:StartTime.ToString('o')
                Duration = ((Get-Date) - $script:StartTime).ToString()
                Mode = $Mode
                Category = $Category
                Host = $script:Environment.HostName
                IsCluster = $script:Environment.IsClusterNode
                ClusterName = $script:Environment.ClusterName
            }
            Summary = $script:Summary
            Findings = $script:Findings
        }
        $exportData | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8
        Write-Log "Exported JSON: $jsonPath" -Level 'SUCCESS'
    }
    
    # CSV Export
    if ($OutputFormat -in @('CSV', 'All')) {
        $csvPath = Join-Path $OutputPath "$baseName.csv"
        $script:Findings | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        Write-Log "Exported CSV: $csvPath" -Level 'SUCCESS'
    }
    
    # HTML Export
    if ($OutputFormat -in @('HTML', 'All')) {
        $htmlPath = Join-Path $OutputPath "$baseName.html"
        Export-HtmlReport -Path $htmlPath
        Write-Log "Exported HTML: $htmlPath" -Level 'SUCCESS'
    }
    
    # Markdown Export
    if ($OutputFormat -in @('Markdown', 'All')) {
        $mdPath = Join-Path $OutputPath "$baseName.md"
        Export-MarkdownReport -Path $mdPath
        Write-Log "Exported Markdown: $mdPath" -Level 'SUCCESS'
    }
}

function Export-HtmlReport {
    param([string]$Path)
    
    $criticalCount = $script:Summary.Critical
    $warningCount = $script:Summary.Warning
    $infoCount = $script:Summary.Info
    $passCount = $script:Summary.Pass
    
    $overallStatus = if ($criticalCount -gt 0) { 'Critical Issues Found' }
                     elseif ($warningCount -gt 0) { 'Warnings Found' }
                     else { 'All Checks Passed' }
    
    $statusColor = if ($criticalCount -gt 0) { '#dc3545' }
                   elseif ($warningCount -gt 0) { '#ffc107' }
                   else { '#28a745' }
    
    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>Hyper-V Assessment Report - $($script:Environment.HostName)</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, sans-serif; margin: 20px; background: #f5f5f5; }
        .container { max-width: 1200px; margin: 0 auto; background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        h1 { color: #333; border-bottom: 2px solid #0078d4; padding-bottom: 10px; }
        h2 { color: #0078d4; margin-top: 30px; }
        .summary { display: flex; gap: 20px; margin: 20px 0; flex-wrap: wrap; }
        .summary-card { padding: 15px 25px; border-radius: 8px; color: white; text-align: center; min-width: 120px; }
        .critical { background: #dc3545; }
        .warning { background: #ffc107; color: #333; }
        .info { background: #17a2b8; }
        .pass { background: #28a745; }
        .summary-card .count { font-size: 2em; font-weight: bold; }
        .summary-card .label { font-size: 0.9em; }
        .status-banner { padding: 15px; border-radius: 8px; margin: 20px 0; color: white; font-size: 1.2em; }
        table { width: 100%; border-collapse: collapse; margin: 20px 0; }
        th, td { padding: 12px; text-align: left; border-bottom: 1px solid #ddd; }
        th { background: #f8f9fa; font-weight: 600; }
        tr:hover { background: #f5f5f5; }
        .severity-critical { color: #dc3545; font-weight: bold; }
        .severity-warning { color: #856404; font-weight: bold; }
        .severity-info { color: #0c5460; }
        .severity-pass { color: #155724; }
        .remediation { background: #f8f9fa; padding: 10px; border-radius: 4px; font-family: 'Consolas', monospace; font-size: 0.85em; margin-top: 5px; white-space: pre-wrap; }
        .meta { color: #666; font-size: 0.9em; }
        .category-section { margin: 30px 0; }
        details { margin: 10px 0; }
        summary { cursor: pointer; padding: 10px; background: #f8f9fa; border-radius: 4px; }
        summary:hover { background: #e9ecef; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Hyper-V Assessment Report</h1>
        
        <div class="meta">
            <p><strong>Host:</strong> $($script:Environment.HostName) | 
               <strong>Cluster:</strong> $(if ($script:Environment.IsClusterNode) { $script:Environment.ClusterName } else { 'Standalone' }) |
               <strong>Date:</strong> $($script:StartTime.ToString('yyyy-MM-dd HH:mm:ss')) |
               <strong>Mode:</strong> $Mode |
               <strong>Duration:</strong> $((Get-Date) - $script:StartTime | ForEach-Object { '{0:mm}m {0:ss}s' -f $_ })</p>
        </div>
        
        <div class="status-banner" style="background: $statusColor;">
            $overallStatus
        </div>
        
        <div class="summary">
            <div class="summary-card critical">
                <div class="count">$criticalCount</div>
                <div class="label">Critical</div>
            </div>
            <div class="summary-card warning">
                <div class="count">$warningCount</div>
                <div class="label">Warning</div>
            </div>
            <div class="summary-card info">
                <div class="count">$infoCount</div>
                <div class="label">Info</div>
            </div>
            <div class="summary-card pass">
                <div class="count">$passCount</div>
                <div class="label">Pass</div>
            </div>
        </div>
        
        <h2>Findings by Category</h2>
"@

    # Group findings by category
    $categories = $script:Findings | Group-Object -Property Category
    
    foreach ($cat in $categories) {
        $html += @"
        <div class="category-section">
            <h3>$($cat.Name)</h3>
            <table>
                <tr>
                    <th style="width: 5%;">Status</th>
                    <th style="width: 20%;">Check</th>
                    <th style="width: 25%;">Current State</th>
                    <th style="width: 25%;">Expected</th>
                    <th style="width: 25%;">Remediation</th>
                </tr>
"@
        foreach ($finding in $cat.Group) {
            $severityClass = "severity-$($finding.Severity.ToLower())"
            $severityIcon = switch ($finding.Severity) {
                'Critical' { 'X' }
                'Warning'  { '!' }
                'Info'     { 'i' }
                'Pass'     { '+' }
            }
            
            $remediationHtml = if ($finding.Remediation) {
                "<div class='remediation'>$([System.Web.HttpUtility]::HtmlEncode($finding.Remediation))</div>"
            } else { '-' }
            
            $html += @"
                <tr>
                    <td class="$severityClass">[$severityIcon]</td>
                    <td>$([System.Web.HttpUtility]::HtmlEncode($finding.Check))</td>
                    <td>$([System.Web.HttpUtility]::HtmlEncode($finding.CurrentState))</td>
                    <td>$([System.Web.HttpUtility]::HtmlEncode($finding.ExpectedState))</td>
                    <td>$remediationHtml</td>
                </tr>
"@
        }
        $html += @"
            </table>
        </div>
"@
    }
    
    $html += @"
        <hr>
        <p class="meta">Generated by $script:ScriptName v$script:ScriptVersion</p>
    </div>
</body>
</html>
"@
    
    $html | Out-File -FilePath $Path -Encoding UTF8
}

function Export-MarkdownReport {
    param([string]$Path)
    
    $criticalCount = $script:Summary.Critical
    $warningCount = $script:Summary.Warning
    $infoCount = $script:Summary.Info
    $passCount = $script:Summary.Pass
    
    $overallStatus = if ($criticalCount -gt 0) { '❌ Critical Issues Found' }
                     elseif ($warningCount -gt 0) { '⚠️ Warnings Found' }
                     else { '✅ All Checks Passed' }
    
    $duration = (Get-Date) - $script:StartTime | ForEach-Object { '{0:mm}m {0:ss}s' -f $_ }
    
    $md = @"
# Hyper-V Assessment Report

**Host:** $($script:Environment.HostName)  
**Cluster:** $(if ($script:Environment.IsClusterNode) { $script:Environment.ClusterName } else { 'Standalone' })  
**Date:** $($script:StartTime.ToString('yyyy-MM-dd HH:mm:ss'))  
**Mode:** $Mode  
**Duration:** $duration

---

## Overall Status: $overallStatus

| ✅ Pass | ⚠️ Warning | ❌ Critical | ℹ️ Info |
|:-------:|:----------:|:-----------:|:-------:|
| **$passCount** | **$warningCount** | **$criticalCount** | **$infoCount** |

---

## Findings

"@

    # Status icon mapping
    $icons = @{
        Pass     = '✅'
        Warning  = '⚠️'
        Critical = '❌'
        Info     = 'ℹ️'
    }
    
    # Group findings by category
    $categories = $script:Findings | Group-Object -Property Category
    
    foreach ($cat in $categories) {
        $md += "`n### $($cat.Name)`n`n"
        $md += "| Status | Check | Current State | Expected | Remediation |`n"
        $md += "|:------:|-------|---------------|----------|-------------|`n"
        
        foreach ($finding in $cat.Group) {
            $icon = $icons[$finding.Severity]
            if (-not $icon) { $icon = '•' }
            
            # Escape pipe characters and clean up text
            $check = ($finding.Check -replace '\|', '\|').Trim()
            $current = ($finding.CurrentState -replace '\|', '\|').Trim()
            $expected = ($finding.ExpectedState -replace '\|', '\|').Trim()
            
            $remediation = if ($finding.Remediation) {
                "``$($finding.Remediation -replace '`', '' -replace '\|', '\|')``"
            } else { '-' }
            
            $md += "| $icon | $check | $current | $expected | $remediation |`n"
        }
    }
    
    # Add remediation commands section
    $remediations = $script:Findings | Where-Object { $_.Remediation -and $_.Severity -in @('Critical', 'Warning') }
    if ($remediations.Count -gt 0) {
        $md += @"

---

## Remediation Commands

"@
        $groupedRem = $remediations | Group-Object -Property Category
        foreach ($group in $groupedRem) {
            $md += "`n### $($group.Name)`n`n"
            $md += "``````powershell`n"
            foreach ($item in $group.Group) {
                $md += "# $($item.Check)`n"
                $md += "$($item.Remediation)`n`n"
            }
            $md += "```````n"
        }
    }
    
    # Add legend and footer
    $md += @"

---

## Legend

| Icon | Meaning |
|:----:|---------|
| ✅ | Pass - Meets best practices |
| ⚠️ | Warning - Review recommended |
| ❌ | Critical - Action required |
| ℹ️ | Info - For awareness |

---

*Generated by $script:ScriptName v$script:ScriptVersion on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')*
"@
    
    $md | Out-File -FilePath $Path -Encoding UTF8
}
#endregion

#region Environment Detection
function Initialize-Environment {
    Write-Log "Detecting environment..." -Level 'INFO'
    
    # Check if Hyper-V role is installed
    try {
        $hyperVFeature = Get-WindowsFeature -Name Hyper-V -ErrorAction SilentlyContinue
        if ($hyperVFeature -and $hyperVFeature.Installed) {
            $script:Environment.IsHyperVHost = $true
        } else {
            # Try Windows 10/11 check
            $hyperVEnabled = Get-WindowsOptionalFeature -FeatureName Microsoft-Hyper-V -Online -ErrorAction SilentlyContinue
            if ($hyperVEnabled -and $hyperVEnabled.State -eq 'Enabled') {
                $script:Environment.IsHyperVHost = $true
            }
        }
    } catch {
        Write-Log "Could not detect Hyper-V feature status: $_" -Level 'WARN'
    }
    
    if (-not $script:Environment.IsHyperVHost) {
        Write-Log "Hyper-V role not detected on this host!" -Level 'ERROR'
        return $false
    }
    
    # Get OS information
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $script:Environment.OSVersion = $os.Caption
    $script:Environment.OSBuild = $os.BuildNumber
    
    # Check for cluster membership
    try {
        $cluster = Get-Cluster -ErrorAction SilentlyContinue
        if ($cluster) {
            $script:Environment.IsClusterNode = $true
            $script:Environment.ClusterName = $cluster.Name
            $script:Environment.ClusterNodes = (Get-ClusterNode).Name
            Write-Log "Detected cluster: $($cluster.Name) with $($script:Environment.ClusterNodes.Count) nodes" -Level 'INFO'
        }
    } catch {
        $script:Environment.IsClusterNode = $false
        Write-Log "Running as standalone Hyper-V host" -Level 'INFO'
    }
    
    Write-Log "Environment: $($script:Environment.OSVersion) (Build $($script:Environment.OSBuild))" -Level 'DEBUG'
    
    return $true
}
#endregion

#region Host Configuration Checks
function Test-HostConfiguration {
    Write-Log "`n=== Host Configuration ===" -Level 'INFO'
    
    # Power Plan
    Test-PowerPlan
    
    # BIOS Virtualization
    Test-BiosVirtualization
    
    # Memory Configuration
    Test-MemoryConfiguration
    
    # Hyper-V Default Paths
    Test-HyperVDefaultPaths
    
    # Antivirus Detection
    Test-AntivirusStatus
    
    # Windows Defender Exclusions (only if Defender detected)
    Test-DefenderExclusions
    
    # Hyper-V Firewall Rules
    Test-HyperVFirewallRules
    
    # Page File
    if ($Mode -in @('Standard', 'Full')) {
        Test-PageFile
    }
    
    # Integration Services
    if ($Mode -eq 'Full') {
        Test-IntegrationServicesHost
    }
}

function Test-PowerPlan {
    try {
        $activePlan = powercfg /getactivescheme
        $planGuid = ($activePlan -split ' ')[3]
        $planName = ($activePlan -split '  \(')[1] -replace '\)', ''
        
        # High Performance GUID: 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
        # Ultimate Performance GUID: e9a42b02-d5df-448d-aa00-03f14749eb61
        $highPerfGuid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
        $ultimatePerfGuid = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
        
        $isHighPerformance = $planGuid -eq $highPerfGuid -or 
                             $planGuid -eq $ultimatePerfGuid -or 
                             $planName -match 'High [Pp]erformance|Ultimate [Pp]erformance'
        
        # Check for vendor-optimized plans (HP, Dell, etc.) - may be acceptable
        $isVendorOptimized = $planName -match 'HP|Dell|Lenovo|Optimized|Server'
        
        if ($isHighPerformance) {
            Write-Finding -Category 'Host' -Check 'Power Plan' -Severity 'Pass' `
                -CurrentState $planName `
                -ExpectedState "High Performance"
        } elseif ($isVendorOptimized) {
            # Vendor plans need manual verification - could be High Perf based
            Write-Finding -Category 'Host' -Check 'Power Plan' -Severity 'Warning' `
                -CurrentState "$planName (vendor-specific plan)" `
                -ExpectedState "High Performance or equivalent" `
                -Impact "Verify this plan doesn't throttle CPU - check 'Minimum processor state' is 100%" `
                -Remediation "powercfg /query $planGuid SUB_PROCESSOR PROCTHROTTLEMIN"
        } else {
            Write-Finding -Category 'Host' -Check 'Power Plan' -Severity 'Critical' `
                -CurrentState $planName `
                -ExpectedState "High Performance" `
                -Impact "CPU throttling significantly degrades VM performance, especially for SQL and RDS workloads" `
                -Remediation "powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c" `
                -Reference "https://docs.microsoft.com/en-us/windows-server/administration/performance-tuning/role/hyper-v-server/"
        }
    } catch {
        Write-Finding -Category 'Host' -Check 'Power Plan' -Severity 'Warning' `
            -CurrentState "Unable to detect: $_" `
            -ExpectedState "High Performance"
    }
}

function Test-BiosVirtualization {
    try {
        $processor = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
        $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
        
        # HypervisorPresent = $true means hypervisor is running (Hyper-V is active)
        # This is the most reliable indicator since VirtualizationFirmwareEnabled
        # may report incorrectly once the hypervisor is loaded
        $hypervisorPresent = $computerSystem.HypervisorPresent
        $virtFirmwareEnabled = $processor.VirtualizationFirmwareEnabled
        
        # If hypervisor is present, virtualization MUST be enabled (Hyper-V wouldn't work otherwise)
        if ($hypervisorPresent) {
            Write-Finding -Category 'Host' -Check 'BIOS Virtualization (VT-x/AMD-V)' -Severity 'Pass' `
                -CurrentState "Enabled (Hypervisor active)" `
                -ExpectedState "Enabled"
        } elseif ($virtFirmwareEnabled -eq $true) {
            Write-Finding -Category 'Host' -Check 'BIOS Virtualization (VT-x/AMD-V)' -Severity 'Pass' `
                -CurrentState "Enabled" `
                -ExpectedState "Enabled"
        } else {
            # Neither hypervisor present nor firmware flag set - unusual for a Hyper-V host
            Write-Finding -Category 'Host' -Check 'BIOS Virtualization (VT-x/AMD-V)' -Severity 'Warning' `
                -CurrentState "Unable to confirm (VirtualizationFirmwareEnabled: $virtFirmwareEnabled, HypervisorPresent: $hypervisorPresent)" `
                -ExpectedState "Enabled" `
                -Impact "If Hyper-V is functioning, virtualization is enabled; this check may be unreliable on some hardware" `
                -Remediation "Verify VT-x/AMD-V is enabled in BIOS if experiencing VM issues"
        }
        
        # SLAT check - if hypervisor is present, SLAT is supported
        if ($hypervisorPresent) {
            Write-Finding -Category 'Host' -Check 'SLAT (Second Level Address Translation)' -Severity 'Pass' `
                -CurrentState "Supported (Hypervisor active)" `
                -ExpectedState "Supported"
        }
        
    } catch {
        Write-Finding -Category 'Host' -Check 'BIOS Virtualization' -Severity 'Warning' `
            -CurrentState "Unable to detect: $_" `
            -ExpectedState "Enabled"
    }
}

function Test-MemoryConfiguration {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $totalMemoryGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        
        # Calculate memory used by VMs
        $runningVMs = Get-VM | Where-Object { $_.State -eq 'Running' }
        $vmMemoryGB = [math]::Round(($runningVMs | Measure-Object -Property MemoryAssigned -Sum).Sum / 1GB, 1)
        
        # Host should have at least 2-4GB reserved
        $hostReservedGB = $totalMemoryGB - $vmMemoryGB
        $recommendedReserveGB = if ($totalMemoryGB -gt 64) { 4 } else { 2 }
        
        if ($hostReservedGB -ge $recommendedReserveGB) {
            Write-Finding -Category 'Host' -Check 'Host Memory Reserve' -Severity 'Pass' `
                -CurrentState "Host has ${hostReservedGB}GB available (VMs using ${vmMemoryGB}GB of ${totalMemoryGB}GB)" `
                -ExpectedState "Minimum ${recommendedReserveGB}GB for host OS"
        } else {
            Write-Finding -Category 'Host' -Check 'Host Memory Reserve' -Severity 'Warning' `
                -CurrentState "Host has only ${hostReservedGB}GB available (VMs using ${vmMemoryGB}GB of ${totalMemoryGB}GB)" `
                -ExpectedState "Minimum ${recommendedReserveGB}GB for host OS" `
                -Impact "Low host memory can cause management issues and affect all VMs" `
                -Remediation "Reduce VM memory allocation or add physical RAM"
        }
        
    } catch {
        Write-Finding -Category 'Host' -Check 'Memory Configuration' -Severity 'Warning' `
            -CurrentState "Unable to analyze: $_" `
            -ExpectedState "Adequate host memory reserve"
    }
}

function Test-HyperVDefaultPaths {
    try {
        $vmHost = Get-VMHost
        $vhdPath = $vmHost.VirtualHardDiskPath
        $vmPath = $vmHost.VirtualMachinePath
        
        # Check if on system drive (bad practice)
        # EXCEPTION: C:\ClusterStorage\ is a CSV mount point, NOT the system drive
        $systemDrive = $env:SystemDrive
        
        # CSV paths are acceptable even though they start with C:\
        $vhdIsCSV = $vhdPath -like '*\ClusterStorage\*'
        $vmIsCSV = $vmPath -like '*\ClusterStorage\*'
        
        $vhdOnSystemDrive = ($vhdPath -like "$systemDrive*") -and (-not $vhdIsCSV)
        $vmOnSystemDrive = ($vmPath -like "$systemDrive*") -and (-not $vmIsCSV)
        
        if ($vhdIsCSV) {
            Write-Finding -Category 'Host' -Check 'Default VHD Path' -Severity 'Pass' `
                -CurrentState "$vhdPath (Cluster Shared Volume)" `
                -ExpectedState "Dedicated/shared storage"
        } elseif (-not $vhdOnSystemDrive) {
            Write-Finding -Category 'Host' -Check 'Default VHD Path' -Severity 'Pass' `
                -CurrentState $vhdPath `
                -ExpectedState "Not on system drive ($systemDrive)"
        } else {
            Write-Finding -Category 'Host' -Check 'Default VHD Path' -Severity 'Warning' `
                -CurrentState "$vhdPath (on system drive)" `
                -ExpectedState "Dedicated storage volume" `
                -Impact "VHDs on system drive compete with OS I/O and risk filling system volume" `
                -Remediation "Set-VMHost -VirtualHardDiskPath 'D:\Hyper-V\Virtual Hard Disks'"
        }
        
        if ($vmIsCSV) {
            Write-Finding -Category 'Host' -Check 'Default VM Path' -Severity 'Pass' `
                -CurrentState "$vmPath (Cluster Shared Volume)" `
                -ExpectedState "Dedicated/shared storage"
        } elseif (-not $vmOnSystemDrive) {
            Write-Finding -Category 'Host' -Check 'Default VM Path' -Severity 'Pass' `
                -CurrentState $vmPath `
                -ExpectedState "Not on system drive ($systemDrive)"
        } else {
            Write-Finding -Category 'Host' -Check 'Default VM Path' -Severity 'Warning' `
                -CurrentState "$vmPath (on system drive)" `
                -ExpectedState "Dedicated storage volume" `
                -Impact "VM configs on system drive risk filling system volume" `
                -Remediation "Set-VMHost -VirtualMachinePath 'D:\Hyper-V\Virtual Machines'"
        }
        
    } catch {
        Write-Finding -Category 'Host' -Check 'Default Paths' -Severity 'Warning' `
            -CurrentState "Unable to check: $_" `
            -ExpectedState "Dedicated storage volumes"
    }
}

function Test-DefenderExclusions {
    try {
        $preferences = Get-MpPreference -ErrorAction SilentlyContinue
        
        if (-not $preferences) {
            Write-Finding -Category 'Host' -Check 'Windows Defender Status' -Severity 'Info' `
                -CurrentState "Windows Defender not detected or not primary AV" `
                -ExpectedState "Exclusions configured if Defender is active"
            return
        }
        
        $vmHost = Get-VMHost
        $vhdPath = $vmHost.VirtualHardDiskPath
        
        $exclusionPaths = $preferences.ExclusionPath
        $exclusionExtensions = $preferences.ExclusionExtension
        $exclusionProcesses = $preferences.ExclusionProcess
        
        # Check for Hyper-V process exclusions
        $requiredProcesses = @('vmms.exe', 'vmwp.exe', 'vmsp.exe', 'vmcompute.exe')
        $missingProcesses = $requiredProcesses | Where-Object { $_ -notin $exclusionProcesses }
        
        # Check for VHDX extension exclusion
        $hasVhdxExclusion = '.vhdx' -in $exclusionExtensions -or '.vhd' -in $exclusionExtensions
        
        # Check for path exclusions (informational - used in remediation)
        $hasVhdPathExclusion = $exclusionPaths | Where-Object { $vhdPath -like "$_*" }
        $null = $hasVhdPathExclusion  # Suppress unused warning - used for future path validation
        
        if ($missingProcesses.Count -eq 0 -and $hasVhdxExclusion) {
            Write-Finding -Category 'Host' -Check 'Windows Defender Exclusions' -Severity 'Pass' `
                -CurrentState "Hyper-V processes and VHDX extensions excluded" `
                -ExpectedState "Proper exclusions configured"
        } else {
            $missing = @()
            if ($missingProcesses) { $missing += "Processes: $($missingProcesses -join ', ')" }
            if (-not $hasVhdxExclusion) { $missing += "Extensions: .vhdx, .vhd" }
            
            $remediation = @"
# Add Hyper-V exclusions
Add-MpPreference -ExclusionProcess 'vmms.exe','vmwp.exe','vmsp.exe','vmcompute.exe'
Add-MpPreference -ExclusionExtension '.vhdx','.vhd','.avhdx','.vsv','.iso'
Add-MpPreference -ExclusionPath '$vhdPath'
"@
            
            Write-Finding -Category 'Host' -Check 'Windows Defender Exclusions' -Severity 'Warning' `
                -CurrentState "Missing exclusions: $($missing -join '; ')" `
                -ExpectedState "Hyper-V processes, VHD extensions, and storage paths excluded" `
                -Impact "AV scanning VHD files causes significant I/O latency and can trigger false positives" `
                -Remediation $remediation `
                -Reference "https://docs.microsoft.com/en-us/troubleshoot/windows-server/virtualization/antivirus-exclusions-for-hyper-v-hosts"
        }
        
    } catch {
        Write-Finding -Category 'Host' -Check 'Windows Defender Exclusions' -Severity 'Info' `
            -CurrentState "Unable to check: $_" `
            -ExpectedState "Proper exclusions configured"
    }
}

function Test-AntivirusStatus {
    <#
    .SYNOPSIS
        Detects installed antivirus products and their status.
        Works on both servers (service detection) and workstations (Security Center).
    #>
    try {
        $avProducts = @()
        $isServer = $script:IsServer
        
        # Method 1: WMI Security Center (works on workstations)
        if (-not $isServer) {
            try {
                $securityCenter = Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName 'AntiVirusProduct' -ErrorAction Stop
                foreach ($av in $securityCenter) {
                    $avProducts += [PSCustomObject]@{
                        Name = $av.displayName
                        State = switch ($av.productState) {
                            { ($_ -band 0x1000) -eq 0x1000 } { 'Enabled' }
                            { ($_ -band 0x0010) -eq 0x0010 } { 'Out of Date' }
                            default { 'Unknown' }
                        }
                        Method = 'SecurityCenter'
                    }
                }
            } catch {
                # Security Center not available - fall through to service detection
            }
        }
        
        # Method 2: Service/Process Detection (works on servers and as fallback)
        $knownAV = @(
            @{ Name = 'Windows Defender'; Services = @('WinDefend', 'WdNisSvc'); Processes = @('MsMpEng.exe') },
            @{ Name = 'Sophos'; Services = @('Sophos Endpoint Defense Service', 'SAVService', 'Sophos Agent'); Processes = @('SophosHealth.exe', 'SSPService.exe') },
            @{ Name = 'CrowdStrike Falcon'; Services = @('CSFalconService'); Processes = @('CSFalconService.exe', 'CSFalconContainer.exe') },
            @{ Name = 'SentinelOne'; Services = @('SentinelAgent', 'SentinelStaticEngine'); Processes = @('SentinelAgent.exe') },
            @{ Name = 'Carbon Black'; Services = @('CbDefense', 'CbDefenseWSC'); Processes = @('RepMgr.exe', 'RepWsc.exe') },
            @{ Name = 'Symantec/Broadcom'; Services = @('SepMasterService', 'ccSvcHst'); Processes = @('ccSvcHst.exe') },
            @{ Name = 'McAfee/Trellix'; Services = @('McAfeeFramework', 'mfefire', 'masvc'); Processes = @('mfetp.exe') },
            @{ Name = 'Trend Micro'; Services = @('Ntrtscan', 'TmListen', 'ds_agent'); Processes = @('Ntrtscan.exe') },
            @{ Name = 'ESET'; Services = @('ekrn', 'ERAAgent'); Processes = @('ekrn.exe', 'egui.exe') },
            @{ Name = 'Kaspersky'; Services = @('AVP', 'klnagent'); Processes = @('avp.exe') },
            @{ Name = 'Bitdefender'; Services = @('EPSecurityService', 'EPIntegrationService'); Processes = @('bdagent.exe') },
            @{ Name = 'Webroot'; Services = @('WRSVC'); Processes = @('WRSA.exe') },
            @{ Name = 'Malwarebytes'; Services = @('MBAMService'); Processes = @('MBAMService.exe') },
            @{ Name = 'Cortex XDR'; Services = @('CortexXDR'); Processes = @('cyserver.exe') },
            @{ Name = 'Huntress'; Services = @('HuntressAgent', 'HuntressUpdater'); Processes = @('HuntressAgent.exe') }
        )
        
        foreach ($av in $knownAV) {
            foreach ($svc in $av.Services) {
                $service = Get-Service -Name $svc -ErrorAction SilentlyContinue
                if ($service) {
                    $status = if ($service.Status -eq 'Running') { 'Running' } else { 'Stopped' }
                    
                    # Avoid duplicates from Security Center
                    $existing = $avProducts | Where-Object { $_.Name -like "*$($av.Name.Split('/')[0])*" }
                    if (-not $existing) {
                        $avProducts += [PSCustomObject]@{
                            Name = $av.Name
                            State = $status
                            Method = 'ServiceDetection'
                        }
                    }
                    break
                }
            }
        }
        
        # Report findings
        if ($avProducts.Count -eq 0) {
            Write-Finding -Category 'Host' -Check 'Antivirus Status' -Severity 'Critical' `
                -CurrentState "No antivirus detected" `
                -ExpectedState "Antivirus installed and running" `
                -Impact "Hyper-V host is unprotected from malware" `
                -Remediation "Install enterprise antivirus solution with Hyper-V exclusions"
        } elseif ($avProducts.Count -gt 1) {
            $avList = ($avProducts | ForEach-Object { "$($_.Name) ($($_.State))" }) -join ', '
            Write-Finding -Category 'Host' -Check 'Antivirus Status' -Severity 'Warning' `
                -CurrentState "Multiple AV products: $avList" `
                -ExpectedState "Single antivirus solution" `
                -Impact "Multiple AV products can conflict and degrade performance" `
                -Remediation "Uninstall redundant antivirus products, keep only one enterprise solution"
        } else {
            $av = $avProducts[0]
            if ($av.State -in @('Running', 'Enabled')) {
                Write-Finding -Category 'Host' -Check 'Antivirus Status' -Severity 'Pass' `
                    -CurrentState "$($av.Name) - $($av.State)" `
                    -ExpectedState "Antivirus running with Hyper-V exclusions"
            } else {
                Write-Finding -Category 'Host' -Check 'Antivirus Status' -Severity 'Critical' `
                    -CurrentState "$($av.Name) - $($av.State)" `
                    -ExpectedState "Antivirus running" `
                    -Impact "Antivirus is installed but not running" `
                    -Remediation "Start the antivirus service and verify protection is active"
            }
        }
        
        # Store detected AV for later checks
        $script:DetectedAV = $avProducts
        
    } catch {
        Write-Finding -Category 'Host' -Check 'Antivirus Status' -Severity 'Info' `
            -CurrentState "Unable to detect: $_" `
            -ExpectedState "Antivirus installed and running"
    }
}

function Test-HyperVFirewallRules {
    <#
    .SYNOPSIS
        Checks that required Hyper-V Windows Firewall rules are enabled.
    #>
    try {
        # Required Hyper-V firewall rules
        $requiredRules = @(
            @{ DisplayGroup = 'Hyper-V'; Description = 'Core Hyper-V management' },
            @{ DisplayGroup = 'Hyper-V Replica HTTP'; Description = 'Hyper-V Replica over HTTP' },
            @{ DisplayGroup = 'Hyper-V Replica HTTPS'; Description = 'Hyper-V Replica over HTTPS' },
            @{ DisplayGroup = 'Hyper-V Management Clients'; Description = 'Remote Hyper-V management' }
        )
        
        # Get all firewall rules
        $allRules = Get-NetFirewallRule -ErrorAction SilentlyContinue
        
        $missingGroups = @()
        $disabledGroups = @()
        $enabledGroups = @()
        
        foreach ($req in $requiredRules) {
            $groupRules = $allRules | Where-Object { $_.DisplayGroup -eq $req.DisplayGroup }
            
            if (-not $groupRules) {
                $missingGroups += $req.DisplayGroup
            } else {
                $enabled = $groupRules | Where-Object { $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' }
                if ($enabled) {
                    $enabledGroups += $req.DisplayGroup
                } else {
                    $disabledGroups += $req.DisplayGroup
                }
            }
        }
        
        # Check for Live Migration rules (important for clusters)
        $liveMigrationRules = $allRules | Where-Object { $_.DisplayGroup -eq 'Hyper-V - Live Migration' }
        if ($script:Environment.IsClusterNode) {
            if (-not $liveMigrationRules) {
                $missingGroups += 'Hyper-V - Live Migration'
            } else {
                $lmEnabled = $liveMigrationRules | Where-Object { $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' }
                if ($lmEnabled) {
                    $enabledGroups += 'Hyper-V - Live Migration'
                } else {
                    $disabledGroups += 'Hyper-V - Live Migration'
                }
            }
        }
        
        # Report findings
        if ($missingGroups.Count -eq 0 -and $disabledGroups.Count -eq 0) {
            Write-Finding -Category 'Host' -Check 'Hyper-V Firewall Rules' -Severity 'Pass' `
                -CurrentState "All required rules enabled: $($enabledGroups -join ', ')" `
                -ExpectedState "Hyper-V firewall rules enabled"
        } elseif ($disabledGroups.Count -gt 0) {
            $remediation = $disabledGroups | ForEach-Object { "Enable-NetFirewallRule -DisplayGroup '$_'" }
            Write-Finding -Category 'Host' -Check 'Hyper-V Firewall Rules' -Severity 'Warning' `
                -CurrentState "Disabled rule groups: $($disabledGroups -join ', ')" `
                -ExpectedState "All Hyper-V firewall rules enabled" `
                -Impact "Disabled rules may prevent remote management or replication" `
                -Remediation ($remediation -join "`n")
        }
        
        if ($missingGroups.Count -gt 0) {
            Write-Finding -Category 'Host' -Check 'Hyper-V Firewall Rules' -Severity 'Info' `
                -CurrentState "Rule groups not found: $($missingGroups -join ', ')" `
                -ExpectedState "All Hyper-V firewall rules present" `
                -Impact "Some features may not be installed or configured"
        }
        
    } catch {
        Write-Finding -Category 'Host' -Check 'Hyper-V Firewall Rules' -Severity 'Info' `
            -CurrentState "Unable to check: $_" `
            -ExpectedState "Firewall rules properly configured"
    }
}

function Test-PageFile {
    try {
        $pageFiles = Get-CimInstance -ClassName Win32_PageFileSetting
        $autoManaged = (Get-CimInstance -ClassName Win32_ComputerSystem).AutomaticManagedPagefile
        
        if ($autoManaged) {
            Write-Finding -Category 'Host' -Check 'Page File Configuration' -Severity 'Pass' `
                -CurrentState "System managed (automatic)" `
                -ExpectedState "System managed or 1.5x RAM for crash dumps"
        } elseif ($pageFiles) {
            $totalSize = ($pageFiles | Measure-Object -Property MaximumSize -Sum).Sum
            Write-Finding -Category 'Host' -Check 'Page File Configuration' -Severity 'Info' `
                -CurrentState "Manual: $($totalSize)MB configured" `
                -ExpectedState "System managed or adequate for crash dumps" `
                -Impact "Ensure page file is large enough for memory dump requirements"
        } else {
            Write-Finding -Category 'Host' -Check 'Page File Configuration' -Severity 'Warning' `
                -CurrentState "No page file detected" `
                -ExpectedState "System managed or manual configuration" `
                -Impact "No page file can cause system instability under memory pressure" `
                -Remediation "Enable automatic page file management in System Properties > Advanced"
        }
        
    } catch {
        Write-Finding -Category 'Host' -Check 'Page File' -Severity 'Info' `
            -CurrentState "Unable to check: $_" `
            -ExpectedState "Properly configured"
    }
}

function Test-IntegrationServicesHost {
    try {
        $vms = Get-VM
        $outdatedIS = @()
        
        foreach ($vm in $vms) {
            $integrationServices = Get-VMIntegrationService -VMName $vm.Name -ErrorAction SilentlyContinue
            $kvp = $integrationServices | Where-Object { $_.Name -eq 'Key-Value Pair Exchange' }
            
            if ($kvp -and -not $kvp.Enabled) {
                $outdatedIS += $vm.Name
            }
        }
        
        if ($outdatedIS.Count -eq 0) {
            Write-Finding -Category 'Host' -Check 'Integration Services' -Severity 'Pass' `
                -CurrentState "All VMs have Integration Services enabled" `
                -ExpectedState "Integration Services enabled on all VMs"
        } else {
            Write-Finding -Category 'Host' -Check 'Integration Services' -Severity 'Info' `
                -CurrentState "VMs with KVP disabled: $($outdatedIS -join ', ')" `
                -ExpectedState "Integration Services enabled on all VMs" `
                -Remediation "Enable-VMIntegrationService -VMName '<VMName>' -Name 'Key-Value Pair Exchange'"
        }
        
    } catch {
        Write-Finding -Category 'Host' -Check 'Integration Services' -Severity 'Info' `
            -CurrentState "Unable to check: $_" `
            -ExpectedState "Current and enabled"
    }
}
#endregion

#region Storage Checks
function Test-StorageConfiguration {
    Write-Log "`n=== Storage Configuration ===" -Level 'INFO'
    
    # MPIO Installation and Configuration
    Test-MpioConfiguration
    
    # iSCSI Configuration
    Test-IscsiConfiguration
    
    # Disk Timeout
    Test-DiskTimeout
    
    # Local Storage Configuration
    Test-LocalStorageConfiguration
    
    # CSV Configuration (if clustered)
    if ($script:Environment.IsClusterNode) {
        Test-CsvConfiguration
    }
    
    # VHDX Settings
    if ($Mode -in @('Standard', 'Full')) {
        Test-VhdxConfiguration
    }
}

function Test-MpioConfiguration {
    try {
        # Check if MPIO feature is installed
        $mpioFeature = Get-WindowsFeature -Name Multipath-IO -ErrorAction SilentlyContinue
        
        if (-not $mpioFeature -or -not $mpioFeature.Installed) {
            # Check if there's any iSCSI storage that would need MPIO
            $iscsiSessions = Get-IscsiSession -ErrorAction SilentlyContinue
            
            if ($iscsiSessions) {
                Write-Finding -Category 'Storage' -Check 'MPIO Feature' -Severity 'Critical' `
                    -CurrentState "Not installed (iSCSI storage detected)" `
                    -ExpectedState "Installed and configured for iSCSI" `
                    -Impact "Without MPIO, iSCSI has no path redundancy or load balancing. Single path failure = storage outage." `
                    -Remediation "Install-WindowsFeature -Name Multipath-IO -IncludeManagementTools -Restart"
            } else {
                Write-Finding -Category 'Storage' -Check 'MPIO Feature' -Severity 'Info' `
                    -CurrentState "Not installed (no iSCSI storage detected)" `
                    -ExpectedState "Install if using iSCSI or FC SAN storage"
            }
            return
        }
        
        Write-Finding -Category 'Storage' -Check 'MPIO Feature' -Severity 'Pass' `
            -CurrentState "Installed" `
            -ExpectedState "Installed"
        
        # Check MPIO settings
        $mpioPolicy = Get-MSDSMGlobalDefaultLoadBalancePolicy -ErrorAction SilentlyContinue
        
        # Check if iSCSI is claimed by MPIO
        $iscsiClaimEnabled = (Get-MSDSMAutomaticClaimSettings -ErrorAction SilentlyContinue).iSCSI
        
        if ($iscsiClaimEnabled) {
            Write-Finding -Category 'Storage' -Check 'MPIO iSCSI Claim' -Severity 'Pass' `
                -CurrentState "iSCSI automatic claim enabled" `
                -ExpectedState "Enabled"
        } else {
            Write-Finding -Category 'Storage' -Check 'MPIO iSCSI Claim' -Severity 'Warning' `
                -CurrentState "iSCSI automatic claim not enabled" `
                -ExpectedState "Enabled for iSCSI multipathing" `
                -Impact "iSCSI devices may not be claimed by MPIO automatically" `
                -Remediation "Enable-MSDSMAutomaticClaim -BusType iSCSI"
        }
        
        # Check load balance policy
        $recommendedPolicies = @('RR', 'LQD')  # Round Robin, Least Queue Depth
        
        if ($mpioPolicy -in $recommendedPolicies) {
            Write-Finding -Category 'Storage' -Check 'MPIO Load Balance Policy' -Severity 'Pass' `
                -CurrentState $mpioPolicy `
                -ExpectedState "Round Robin (RR) or Least Queue Depth (LQD)"
        } elseif ($mpioPolicy -eq 'FO') {
            Write-Finding -Category 'Storage' -Check 'MPIO Load Balance Policy' -Severity 'Warning' `
                -CurrentState "Failover Only (FO)" `
                -ExpectedState "Round Robin (RR) or Least Queue Depth (LQD)" `
                -Impact "Failover Only does not distribute I/O across paths - wasted bandwidth" `
                -Remediation "Set-MSDSMGlobalDefaultLoadBalancePolicy -Policy RR"
        } else {
            Write-Finding -Category 'Storage' -Check 'MPIO Load Balance Policy' -Severity 'Info' `
                -CurrentState "$mpioPolicy" `
                -ExpectedState "Round Robin (RR) or Least Queue Depth (LQD)" `
                -Remediation "Set-MSDSMGlobalDefaultLoadBalancePolicy -Policy RR"
        }
        
    } catch {
        Write-Finding -Category 'Storage' -Check 'MPIO Configuration' -Severity 'Warning' `
            -CurrentState "Unable to check: $_" `
            -ExpectedState "MPIO installed and configured"
    }
}

function Test-IscsiConfiguration {
    try {
        $iscsiService = Get-Service -Name MSiSCSI -ErrorAction SilentlyContinue
        
        if (-not $iscsiService -or $iscsiService.Status -ne 'Running') {
            # Check if iSCSI is actually being used
            $iscsiDisks = Get-Disk | Where-Object { $_.BusType -eq 'iSCSI' }
            
            if ($iscsiDisks) {
                Write-Finding -Category 'Storage' -Check 'iSCSI Initiator Service' -Severity 'Critical' `
                    -CurrentState "Not running (iSCSI disks present!)" `
                    -ExpectedState "Running and set to Automatic" `
                    -Impact "iSCSI storage may become unavailable after reboot" `
                    -Remediation "Set-Service -Name MSiSCSI -StartupType Automatic; Start-Service MSiSCSI"
            } else {
                Write-Finding -Category 'Storage' -Check 'iSCSI Initiator Service' -Severity 'Info' `
                    -CurrentState "Not running (no iSCSI disks detected)" `
                    -ExpectedState "Running if using iSCSI storage"
                return
            }
        } else {
            Write-Finding -Category 'Storage' -Check 'iSCSI Initiator Service' -Severity 'Pass' `
                -CurrentState "Running (StartType: $($iscsiService.StartType))" `
                -ExpectedState "Running"
        }
        
        # Check iSCSI sessions and connections
        $sessions = Get-IscsiSession -ErrorAction SilentlyContinue
        
        if ($sessions) {
            $targets = $sessions | Group-Object -Property TargetNodeAddress
            
            foreach ($target in $targets) {
                $connectionCount = $target.Count
                $targetName = ($target.Name -split ':')[0]
                
                if ($connectionCount -ge 2) {
                    Write-Finding -Category 'Storage' -Check "iSCSI Target: $targetName" -Severity 'Pass' `
                        -CurrentState "$connectionCount active sessions (multipath)" `
                        -ExpectedState "Multiple sessions for redundancy"
                } else {
                    Write-Finding -Category 'Storage' -Check "iSCSI Target: $targetName" -Severity 'Warning' `
                        -CurrentState "Only $connectionCount session (no multipath)" `
                        -ExpectedState "Multiple sessions for redundancy" `
                        -Impact "Single path to storage - no failover capability" `
                        -Remediation "Connect additional iSCSI sessions through secondary network paths"
                }
            }
            
            # Check for persistent targets
            $persistentTargets = Get-IscsiTargetPortal -ErrorAction SilentlyContinue
            
            if ($persistentTargets) {
                Write-Finding -Category 'Storage' -Check 'iSCSI Target Portals' -Severity 'Pass' `
                    -CurrentState "$($persistentTargets.Count) persistent portal(s) configured" `
                    -ExpectedState "Persistent portals configured"
            }
        }
        
    } catch {
        Write-Finding -Category 'Storage' -Check 'iSCSI Configuration' -Severity 'Info' `
            -CurrentState "Unable to check: $_" `
            -ExpectedState "Properly configured if using iSCSI"
    }
}

function Test-DiskTimeout {
    try {
        # Check disk timeout for iSCSI/SAN disks
        $iscsiDisks = Get-Disk | Where-Object { $_.BusType -eq 'iSCSI' -or $_.BusType -eq 'Fibre Channel' }
        
        if (-not $iscsiDisks) {
            Write-Finding -Category 'Storage' -Check 'Disk Timeout' -Severity 'Info' `
                -CurrentState "No iSCSI/FC disks detected" `
                -ExpectedState "60+ seconds for SAN storage"
            return
        }
        
        # Check registry timeout value
        $timeoutPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\Disk'
        $timeoutValue = Get-ItemProperty -Path $timeoutPath -Name TimeOutValue -ErrorAction SilentlyContinue
        
        $currentTimeout = if ($timeoutValue) { $timeoutValue.TimeOutValue } else { 60 }  # Default is 60
        
        if ($currentTimeout -ge 60) {
            Write-Finding -Category 'Storage' -Check 'Disk Timeout' -Severity 'Pass' `
                -CurrentState "${currentTimeout} seconds" `
                -ExpectedState "60 seconds or higher"
        } else {
            Write-Finding -Category 'Storage' -Check 'Disk Timeout' -Severity 'Critical' `
                -CurrentState "${currentTimeout} seconds" `
                -ExpectedState "60 seconds minimum" `
                -Impact "Low timeout causes false path failures during storage latency spikes or failovers" `
                -Remediation "Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Disk' -Name TimeOutValue -Value 60"
        }
        
    } catch {
        Write-Finding -Category 'Storage' -Check 'Disk Timeout' -Severity 'Info' `
            -CurrentState "Unable to check: $_" `
            -ExpectedState "60+ seconds for SAN storage"
    }
}

function Test-LocalStorageConfiguration {
    try {
        # Get physical disks used for VMs
        $vmHost = Get-VMHost
        $vhdPath = $vmHost.VirtualHardDiskPath
        $vmPath  = $vmHost.VirtualMachinePath

        # Identify iSCSI disk numbers for matching
        $iscsiDisks = @()
        $iscsiSessions = @(Get-IscsiSession -ErrorAction SilentlyContinue)
        if ($iscsiSessions.Count -gt 0) {
            $iscsiSessions | ForEach-Object {
                Get-Disk -iSCSISession $_ -ErrorAction SilentlyContinue
            } | ForEach-Object { $iscsiDisks += $_.Number }
        }

        # Check volumes WITH drive letters
        $volumes = Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' }

        foreach ($vol in $volumes) {
            $partition = Get-Partition -DriveLetter $vol.DriveLetter -ErrorAction SilentlyContinue
            if (-not $partition) { continue }

            $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction SilentlyContinue
            if (-not $disk) { continue }

            # Check if this volume is relevant: contains VHDs, is on iSCSI, or has a VM-related label
            $volPath = "$($vol.DriveLetter):\"
            $isVmStorage = $vhdPath -like "$volPath*" -or $vmPath -like "$volPath*"
            $isIscsiDisk = $partition.DiskNumber -in $iscsiDisks
            $hasVmLabel  = $vol.FileSystemLabel -match 'VM|Hyper|VHD|CSV|iSCSI|SAN|Quorum'

            if (-not ($isVmStorage -or $isIscsiDisk -or $hasVmLabel)) { continue }

            $volumeLabel = if ($isIscsiDisk) { "Volume $($vol.DriveLetter): (iSCSI Disk $($partition.DiskNumber))" } else { "Volume $($vol.DriveLetter):" }

            # Check allocation unit size (should be 64KB for VHDX)
            $clusterSize = (Get-CimInstance -ClassName Win32_Volume -ErrorAction SilentlyContinue |
                Where-Object { $_.DriveLetter -eq "$($vol.DriveLetter):" }).BlockSize

            if ($clusterSize -ge 65536) {  # 64KB
                Write-Finding -Category 'Storage' -Check "$volumeLabel Allocation Unit" -Severity 'Pass' `
                    -CurrentState "$([math]::Round($clusterSize/1024))KB" `
                    -ExpectedState "64KB for VM storage"
            } elseif ($clusterSize) {
                Write-Finding -Category 'Storage' -Check "$volumeLabel Allocation Unit" -Severity 'Info' `
                    -CurrentState "$([math]::Round($clusterSize/1024))KB" `
                    -ExpectedState "64KB optimal for VHDX" `
                    -Impact "Suboptimal but functional - 64KB improves VHDX I/O alignment" `
                    -Remediation "Reformat volume with 64KB allocation unit size (requires data migration)"
            }

            # Check file system type
            if ($vol.FileSystem -eq 'ReFS') {
                Write-Finding -Category 'Storage' -Check "$volumeLabel File System" -Severity 'Pass' `
                    -CurrentState "ReFS" `
                    -ExpectedState "ReFS for VHDX storage"
            } elseif ($vol.FileSystem -eq 'NTFS') {
                Write-Finding -Category 'Storage' -Check "$volumeLabel File System" -Severity 'Info' `
                    -CurrentState "NTFS" `
                    -ExpectedState "ReFS preferred for VHDX storage" `
                    -Impact "ReFS provides faster VHDX operations (fixed-to-dynamic, merge) and better integrity"
            }
        }

        # Check CSV mount-point volumes (no drive letter — mounted under C:\ClusterStorage\)
        $csvVolumes = Get-CimInstance -ClassName Win32_Volume -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like '*ClusterStorage*' -and $_.DriveType -eq 3 }

        foreach ($csvVol in $csvVolumes) {
            $csvLabel = if ($csvVol.Label) { $csvVol.Label } else { ($csvVol.Name -replace '\\$','') -replace '.*\\','' }
            $volName = "CSV: $csvLabel"

            if ($csvVol.BlockSize -ge 65536) {
                Write-Finding -Category 'Storage' -Check "$volName Allocation Unit" -Severity 'Pass' `
                    -CurrentState "$([math]::Round($csvVol.BlockSize/1024))KB" `
                    -ExpectedState "64KB for CSV storage"
            } elseif ($csvVol.BlockSize) {
                Write-Finding -Category 'Storage' -Check "$volName Allocation Unit" -Severity 'Info' `
                    -CurrentState "$([math]::Round($csvVol.BlockSize/1024))KB" `
                    -ExpectedState "64KB optimal for CSV/VHDX" `
                    -Impact "Suboptimal but functional - 64KB improves VHDX I/O alignment" `
                    -Remediation "Reformat volume with 64KB allocation unit size (requires data migration)"
            }

            $fs = $csvVol.FileSystem
            if ($fs -eq 'ReFS') {
                Write-Finding -Category 'Storage' -Check "$volName File System" -Severity 'Pass' `
                    -CurrentState "ReFS" -ExpectedState "ReFS for CSV storage"
            } elseif ($fs -eq 'NTFS') {
                Write-Finding -Category 'Storage' -Check "$volName File System" -Severity 'Info' `
                    -CurrentState "NTFS" -ExpectedState "ReFS preferred for CSV storage" `
                    -Impact "ReFS provides faster VHDX operations and better integrity for CSV volumes"
            }
        }

    } catch {
        Write-Finding -Category 'Storage' -Check 'Local Storage' -Severity 'Info' `
            -CurrentState "Unable to check: $_" `
            -ExpectedState "64KB allocation, ReFS preferred"
    }
}

function Test-CsvConfiguration {
    try {
        $csvs = Get-ClusterSharedVolume -ErrorAction SilentlyContinue
        
        if (-not $csvs) {
            Write-Finding -Category 'Storage' -Check 'Cluster Shared Volumes' -Severity 'Info' `
                -CurrentState "No CSVs configured" `
                -ExpectedState "CSVs for shared VM storage in clusters"
            return
        }
        
        foreach ($csv in $csvs) {
            $csvState = $csv.State
            $csvOwner = $csv.OwnerNode.Name
            
            if ($csvState -eq 'Online') {
                Write-Finding -Category 'Storage' -Check "CSV: $($csv.Name)" -Severity 'Pass' `
                    -CurrentState "Online (Owner: $csvOwner)" `
                    -ExpectedState "Online"
            } else {
                Write-Finding -Category 'Storage' -Check "CSV: $($csv.Name)" -Severity 'Critical' `
                    -CurrentState "$csvState (Owner: $csvOwner)" `
                    -ExpectedState "Online" `
                    -Impact "CSV not online - VMs on this storage may be inaccessible" `
                    -Remediation "Get-ClusterSharedVolume '$($csv.Name)' | Start-ClusterResource"
            }
            
            # Check CSV redirect mode
            $redirectedAccess = $csv.SharedVolumeInfo.FaultState
            if ($redirectedAccess -ne 'NoFaults') {
                Write-Finding -Category 'Storage' -Check "CSV: $($csv.Name) Access Mode" -Severity 'Warning' `
                    -CurrentState "Redirected access: $redirectedAccess" `
                    -ExpectedState "Direct I/O (no faults)" `
                    -Impact "Redirected access significantly reduces CSV performance" `
                    -Reference "Check cluster event logs for CSV redirect cause"
            }
        }
        
    } catch {
        Write-Finding -Category 'Storage' -Check 'CSV Configuration' -Severity 'Info' `
            -CurrentState "Unable to check: $_" `
            -ExpectedState "Online and healthy"
    }
}

function Test-VhdxConfiguration {
    try {
        $vms = Get-VM
        
        foreach ($vm in $vms) {
            $vhds = Get-VMHardDiskDrive -VMName $vm.Name -ErrorAction SilentlyContinue
            
            foreach ($vhd in $vhds) {
                $vhdInfo = Get-VHD -Path $vhd.Path -ErrorAction SilentlyContinue
                
                if (-not $vhdInfo) { continue }
                
                $vhdName = Split-Path $vhd.Path -Leaf
                
                # Check VHD vs VHDX
                if ($vhdInfo.VhdFormat -eq 'VHD') {
                    Write-Finding -Category 'Storage' -Check "VM: $($vm.Name) - $vhdName Format" -Severity 'Warning' `
                        -CurrentState "VHD (legacy format)" `
                        -ExpectedState "VHDX format" `
                        -Impact "VHD limited to 2TB, less resilient, worse performance than VHDX" `
                        -Remediation "Convert-VHD -Path '$($vhd.Path)' -DestinationPath '$($vhd.Path -replace '\.vhd$','.vhdx')' -VHDType Dynamic"
                }
                
                # Check for SQL-like VMs with dynamic disks (potential issue)
                if ($vm.Name -match 'SQL' -and $vhdInfo.VhdType -eq 'Dynamic') {
                    Write-Finding -Category 'Storage' -Check "VM: $($vm.Name) - $vhdName Type" -Severity 'Info' `
                        -CurrentState "Dynamic VHDX" `
                        -ExpectedState "Fixed VHDX recommended for SQL" `
                        -Impact "Dynamic disks may cause I/O latency during expansion; fixed provides consistent performance" `
                        -Remediation "Consider converting to Fixed VHDX for production SQL workloads"
                }
                
                # Check for differencing disks in production
                if ($vhdInfo.VhdType -eq 'Differencing' -and $vm.State -eq 'Running') {
                    Write-Finding -Category 'Storage' -Check "VM: $($vm.Name) - $vhdName Type" -Severity 'Warning' `
                        -CurrentState "Differencing disk on running VM" `
                        -ExpectedState "Avoid differencing disks in production" `
                        -Impact "Differencing disks have I/O overhead and grow over time" `
                        -Remediation "Merge differencing disk or convert to standalone VHDX"
                }
            }
        }
        
    } catch {
        Write-Finding -Category 'Storage' -Check 'VHDX Configuration' -Severity 'Info' `
            -CurrentState "Unable to check: $_" `
            -ExpectedState "VHDX format, appropriate types"
    }
}
#endregion

#region Network Checks
function Test-NetworkConfiguration {
    if ($Category -notin @('Network', 'All')) { return }
    
    Write-Log "`n=== Network Configuration ===" -Level 'INFO'
    
    # VMQ Configuration
    Test-VmqConfiguration
    
    # RSS on Management NIC
    Test-RssConfiguration
    
    # NIC Power Management
    Test-NicPowerManagement
    
    # Virtual Switch Configuration
    Test-VirtualSwitchConfiguration
    
    # SET Teaming
    if ($Mode -in @('Standard', 'Full')) {
        Test-SetTeamingConfiguration
    }
    
    # Jumbo Frames
    if ($Mode -eq 'Full') {
        Test-JumboFrames
    }
}

function Test-VmqConfiguration {
    try {
        $vmSwitches = Get-VMSwitch -ErrorAction SilentlyContinue
        
        foreach ($switch in $vmSwitches) {
            if ($switch.SwitchType -eq 'External') {
                $netAdapter = Get-NetAdapter | Where-Object { $_.InterfaceDescription -eq $switch.NetAdapterInterfaceDescription }
                
                if (-not $netAdapter) { continue }
                
                # Check VMQ status
                $vmqStatus = Get-NetAdapterVmq -Name $netAdapter.Name -ErrorAction SilentlyContinue
                
                if ($vmqStatus) {
                    if ($vmqStatus.Enabled) {
                        # Check VMQ processor settings
                        $baseProc = $vmqStatus.BaseProcessorNumber
                        $maxProc = $vmqStatus.MaxProcessors
                        
                        if ($baseProc -eq 0) {
                            Write-Finding -Category 'Network' -Check "VMQ: $($netAdapter.Name)" -Severity 'Warning' `
                                -CurrentState "Enabled but BaseProcessor=0 (shares CPU 0 with OS)" `
                                -ExpectedState "BaseProcessor > 0 to avoid CPU 0" `
                                -Impact "VMQ queues on CPU 0 compete with OS interrupts" `
                                -Remediation "Set-NetAdapterVmq -Name '$($netAdapter.Name)' -BaseProcessorNumber 2 -MaxProcessors 8" `
                                -Reference "https://docs.microsoft.com/en-us/windows-server/networking/technologies/vrss/vrss-resolve-issues"
                        } else {
                            Write-Finding -Category 'Network' -Check "VMQ: $($netAdapter.Name)" -Severity 'Pass' `
                                -CurrentState "Enabled (Base: CPU $baseProc, Max: $maxProc)" `
                                -ExpectedState "Enabled with proper CPU assignment"
                        }
                    } else {
                        # VMQ disabled - check if it's a 10Gb+ adapter
                        $linkSpeed = $netAdapter.LinkSpeed
                        if ($linkSpeed -match '10|25|40|100.*Gbps') {
                            Write-Finding -Category 'Network' -Check "VMQ: $($netAdapter.Name)" -Severity 'Warning' `
                                -CurrentState "Disabled on high-speed adapter ($linkSpeed)" `
                                -ExpectedState "Enabled for 10Gb+ adapters" `
                                -Impact "VMQ offloads network processing - improves throughput" `
                                -Remediation "Enable-NetAdapterVmq -Name '$($netAdapter.Name)'"
                        } else {
                            Write-Finding -Category 'Network' -Check "VMQ: $($netAdapter.Name)" -Severity 'Info' `
                                -CurrentState "Disabled ($linkSpeed adapter)" `
                                -ExpectedState "Optional for 1Gb adapters"
                        }
                    }
                }
            }
        }
    } catch {
        Write-Finding -Category 'Network' -Check 'VMQ Configuration' -Severity 'Info' `
            -CurrentState "Unable to check: $_" `
            -ExpectedState "VMQ enabled on 10Gb+ adapters"
    }
}

function Test-RssConfiguration {
    try {
        # Check RSS on management/host vNICs
        $vmHost = Get-VMHost
        $hostVnics = Get-VMNetworkAdapter -ManagementOS -ErrorAction SilentlyContinue
        
        foreach ($vnic in $hostVnics) {
            $vrssEnabled = $vnic.VrssEnabled
            
            if ($vrssEnabled) {
                Write-Finding -Category 'Network' -Check "vRSS: $($vnic.Name)" -Severity 'Pass' `
                    -CurrentState "Enabled" `
                    -ExpectedState "Enabled for management vNICs"
            } else {
                Write-Finding -Category 'Network' -Check "vRSS: $($vnic.Name)" -Severity 'Info' `
                    -CurrentState "Disabled" `
                    -ExpectedState "Enabled for better throughput" `
                    -Remediation "Set-VMNetworkAdapter -ManagementOS -Name '$($vnic.Name)' -VrssEnabled `$true"
            }
        }
        
        # Check RSS on physical adapters
        $physicalAdapters = Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' }
        
        foreach ($adapter in $physicalAdapters) {
            $rss = Get-NetAdapterRss -Name $adapter.Name -ErrorAction SilentlyContinue
            
            if ($rss -and -not $rss.Enabled) {
                Write-Finding -Category 'Network' -Check "RSS: $($adapter.Name)" -Severity 'Info' `
                    -CurrentState "Disabled" `
                    -ExpectedState "Enabled for multi-core processing" `
                    -Remediation "Enable-NetAdapterRss -Name '$($adapter.Name)'"
            }
        }
        
    } catch {
        Write-Finding -Category 'Network' -Check 'RSS Configuration' -Severity 'Info' `
            -CurrentState "Unable to check: $_" `
            -ExpectedState "RSS/vRSS enabled"
    }
}

function Test-NicPowerManagement {
    try {
        $physicalAdapters = Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' }
        
        foreach ($adapter in $physicalAdapters) {
            $powerMgmt = Get-NetAdapterPowerManagement -Name $adapter.Name -ErrorAction SilentlyContinue
            
            if ($powerMgmt) {
                # Check if power saving is enabled
                if ($powerMgmt.AllowComputerToTurnOffDevice -eq 'Enabled') {
                    Write-Finding -Category 'Network' -Check "NIC Power: $($adapter.Name)" -Severity 'Warning' `
                        -CurrentState "Power saving enabled (can turn off device)" `
                        -ExpectedState "Power saving disabled (PnPCapabilities = 24)" `
                        -Impact "NIC may be disabled during idle periods causing network drops" `
                        -Remediation "Disable 'Allow the computer to turn off this device to save power' in the adapter's Power Management tab (Device Manager > NIC properties > Power Management)"
                }
            }
            
            # Check for energy-efficient ethernet
            $eee = Get-NetAdapterAdvancedProperty -Name $adapter.Name -RegistryKeyword '*EEE' -ErrorAction SilentlyContinue
            
            if ($eee -and $eee.RegistryValue -eq '1') {
                Write-Finding -Category 'Network' -Check "Energy Efficient Ethernet: $($adapter.Name)" -Severity 'Info' `
                    -CurrentState "Enabled" `
                    -ExpectedState "Disabled for consistent performance" `
                    -Impact "EEE can add latency during low traffic periods" `
                    -Remediation "Set-NetAdapterAdvancedProperty -Name '$($adapter.Name)' -RegistryKeyword '*EEE' -RegistryValue 0"
            }
        }
        
    } catch {
        Write-Finding -Category 'Network' -Check 'NIC Power Management' -Severity 'Info' `
            -CurrentState "Unable to check: $_" `
            -ExpectedState "Power saving disabled"
    }
}

function Test-VirtualSwitchConfiguration {
    try {
        $vmSwitches = Get-VMSwitch -ErrorAction SilentlyContinue
        
        if (-not $vmSwitches) {
            Write-Finding -Category 'Network' -Check 'Virtual Switches' -Severity 'Warning' `
                -CurrentState "No virtual switches configured" `
                -ExpectedState "At least one external virtual switch" `
                -Remediation "New-VMSwitch -Name 'External' -NetAdapterName 'Ethernet' -AllowManagementOS `$true"
            return
        }
        
        $hasExternal = $false
        
        foreach ($switch in $vmSwitches) {
            $switchType = $switch.SwitchType
            
            if ($switchType -eq 'External') {
                $hasExternal = $true
                
                # Check if management OS is allowed
                if ($switch.AllowManagementOS) {
                    Write-Finding -Category 'Network' -Check "vSwitch: $($switch.Name)" -Severity 'Pass' `
                        -CurrentState "External switch with management OS access" `
                        -ExpectedState "External switch configured"
                } else {
                    Write-Finding -Category 'Network' -Check "vSwitch: $($switch.Name)" -Severity 'Info' `
                        -CurrentState "External switch (no management OS access)" `
                        -ExpectedState "Consider if management OS needs network access"
                }
                
                # Check for SR-IOV
                if ($switch.IovEnabled) {
                    Write-Finding -Category 'Network' -Check "SR-IOV: $($switch.Name)" -Severity 'Pass' `
                        -CurrentState "Enabled" `
                        -ExpectedState "Enabled for high-performance VMs"
                }
            }
        }
        
        if (-not $hasExternal) {
            Write-Finding -Category 'Network' -Check 'External Virtual Switch' -Severity 'Warning' `
                -CurrentState "No external virtual switch found" `
                -ExpectedState "External switch for VM network connectivity" `
                -Impact "VMs cannot communicate with physical network"
        }
        
    } catch {
        Write-Finding -Category 'Network' -Check 'Virtual Switch' -Severity 'Info' `
            -CurrentState "Unable to check: $_" `
            -ExpectedState "Properly configured"
    }
}

function Test-SetTeamingConfiguration {
    try {
        # Check for SET teams (Switch Embedded Teaming)
        $vmSwitches = Get-VMSwitch | Where-Object { $_.EmbeddedTeamingEnabled -eq $true }
        
        foreach ($switch in $vmSwitches) {
            $teamMembers = $switch.NetAdapterInterfaceDescriptions
            
            if ($teamMembers.Count -ge 2) {
                Write-Finding -Category 'Network' -Check "SET Team: $($switch.Name)" -Severity 'Pass' `
                    -CurrentState "$($teamMembers.Count) adapters in team" `
                    -ExpectedState "Multiple adapters for redundancy"
            } else {
                Write-Finding -Category 'Network' -Check "SET Team: $($switch.Name)" -Severity 'Warning' `
                    -CurrentState "Only $($teamMembers.Count) adapter(s) in team" `
                    -ExpectedState "At least 2 adapters for redundancy" `
                    -Impact "Single adapter provides no failover"
            }
            
            # Check team mode
            $teamingMode = $switch.LoadBalancingAlgorithm
            $teamingModeStr = if ([string]::IsNullOrEmpty($teamingMode)) { 'Not configured' } else { $teamingMode.ToString() }
            Write-Finding -Category 'Network' -Check "SET Load Balancing: $($switch.Name)" -Severity 'Info' `
                -CurrentState $teamingModeStr `
                -ExpectedState "Dynamic or HyperVPort recommended"
        }
        
        # Check for legacy LBFO teams (not recommended with Hyper-V)
        $lbfoTeams = Get-NetLbfoTeam -ErrorAction SilentlyContinue
        
        if ($lbfoTeams) {
            foreach ($team in $lbfoTeams) {
                # Check if LBFO team is used by Hyper-V
                $vmSwitch = Get-VMSwitch | Where-Object { $_.NetAdapterInterfaceDescription -eq $team.Name }
                
                if ($vmSwitch) {
                    Write-Finding -Category 'Network' -Check "LBFO Team: $($team.Name)" -Severity 'Warning' `
                        -CurrentState "LBFO team used by Hyper-V switch" `
                        -ExpectedState "Use SET (Switch Embedded Teaming) instead" `
                        -Impact "LBFO has known issues with Hyper-V, SET is preferred" `
                        -Reference "https://docs.microsoft.com/en-us/windows-server/networking/technologies/nic-teaming/nic-teaming"
                }
            }
        }
        
    } catch {
        Write-Finding -Category 'Network' -Check 'SET Teaming' -Severity 'Info' `
            -CurrentState "Unable to check: $_" `
            -ExpectedState "SET teaming for redundancy"
    }
}

function Test-JumboFrames {
    try {
        $vmSwitches = Get-VMSwitch | Where-Object { $_.SwitchType -eq 'External' }
        
        foreach ($switch in $vmSwitches) {
            $netAdapter = Get-NetAdapter | Where-Object { $_.InterfaceDescription -eq $switch.NetAdapterInterfaceDescription }
            
            if (-not $netAdapter) { continue }
            
            # Check MTU/Jumbo Frames
            $jumboFrame = Get-NetAdapterAdvancedProperty -Name $netAdapter.Name -RegistryKeyword '*JumboPacket' -ErrorAction SilentlyContinue
            
            if ($jumboFrame) {
                # RegistryValue can be a string array; get first element
                $mtuValue = if ($jumboFrame.RegistryValue -is [array]) { $jumboFrame.RegistryValue[0] } else { $jumboFrame.RegistryValue }
                
                if ($mtuValue -and [int]$mtuValue -gt 1514) {
                    Write-Finding -Category 'Network' -Check "Jumbo Frames: $($netAdapter.Name)" -Severity 'Info' `
                        -CurrentState "MTU: $mtuValue" `
                        -ExpectedState "Consistent across all network devices" `
                        -Impact "Ensure switches and storage also support jumbo frames"
                }
            }
        }
        
        # Check for jumbo frame consistency on iSCSI adapters
        $iscsiAdapters = Get-NetAdapter | Where-Object { $_.Name -match 'iSCSI|Storage' }
        
        foreach ($adapter in $iscsiAdapters) {
            $mtu = (Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).NlMtu
            
            if ($mtu -and $mtu -lt 9000) {
                Write-Finding -Category 'Network' -Check "iSCSI MTU: $($adapter.Name)" -Severity 'Info' `
                    -CurrentState "MTU: $mtu" `
                    -ExpectedState "9000 for jumbo frames (if supported by network)" `
                    -Impact "Jumbo frames improve iSCSI throughput" `
                    -Remediation "Set-NetAdapterAdvancedProperty -Name '$($adapter.Name)' -RegistryKeyword '*JumboPacket' -RegistryValue 9014"
            }
        }
        
    } catch {
        Write-Finding -Category 'Network' -Check 'Jumbo Frames' -Severity 'Info' `
            -CurrentState "Unable to check: $_" `
            -ExpectedState "Consistent MTU configuration"
    }
}
#endregion

#region VM Checks
function Test-VMConfiguration {
    if ($Category -notin @('VM', 'All')) { return }
    
    Write-Log "`n=== VM Configuration ===" -Level 'INFO'
    
    $vms = Get-VM | Where-Object { 
        foreach ($pattern in $VMName) {
            if ($_.Name -like $pattern) { return $true }
        }
        return $false
    }
    
    if (-not $vms) {
        Write-Finding -Category 'VM' -Check 'VM Detection' -Severity 'Info' `
            -CurrentState "No VMs found matching pattern: $($VMName -join ', ')" `
            -ExpectedState "VMs to assess"
        return
    }
    
    Write-Log "Assessing $($vms.Count) VMs..." -Level 'INFO'
    
    foreach ($vm in $vms) {
        # VM State (Running, Stopped, etc.)
        Test-VMState -VM $vm
        
        # Generation check
        Test-VMGeneration -VM $vm
        
        # Integration Services
        Test-VMIntegrationServices -VM $vm
        
        # Memory configuration
        Test-VMMemoryConfiguration -VM $vm
        
        # CPU configuration
        if ($Mode -in @('Standard', 'Full')) {
            Test-VMCpuConfiguration -VM $vm
        }
        
        # Checkpoints
        Test-VMCheckpoints -VM $vm
        
        # Workload-specific checks
        if ($Mode -eq 'Full') {
            Test-VMWorkloadSpecific -VM $vm
        }
    }
    
    # Automatic start/stop actions (host level)
    Test-VMAutomaticActions -VMs $vms
}

function Test-VMState {
    param([Microsoft.HyperV.PowerShell.VirtualMachine]$VM)
    
    try {
        $state = $VM.State.ToString()
        $uptime = if ($VM.Uptime) { $VM.Uptime.ToString('d\.hh\:mm\:ss') } else { 'N/A' }
        
        switch ($state) {
            'Running' {
                Write-Finding -Category 'VM' -Check "VM: $($VM.Name) - State" -Severity 'Pass' `
                    -CurrentState "Running (Uptime: $uptime)" `
                    -ExpectedState "Running"
            }
            'Off' {
                Write-Finding -Category 'VM' -Check "VM: $($VM.Name) - State" -Severity 'Info' `
                    -CurrentState "Off" `
                    -ExpectedState "Running or Off (as expected)" `
                    -Impact "VM is powered off - verify this is intentional"
            }
            'Saved' {
                Write-Finding -Category 'VM' -Check "VM: $($VM.Name) - State" -Severity 'Warning' `
                    -CurrentState "Saved" `
                    -ExpectedState "Running or Off" `
                    -Impact "Saved state consumes disk space and may cause issues after host updates" `
                    -Remediation "Start-VM -Name '$($VM.Name)'  # or  Remove-VMSavedState -VMName '$($VM.Name)'"
            }
            'Paused' {
                Write-Finding -Category 'VM' -Check "VM: $($VM.Name) - State" -Severity 'Warning' `
                    -CurrentState "Paused" `
                    -ExpectedState "Running" `
                    -Impact "VM is paused - often indicates memory pressure or manual pause" `
                    -Remediation "Resume-VM -Name '$($VM.Name)'"
            }
            'Critical' {
                Write-Finding -Category 'VM' -Check "VM: $($VM.Name) - State" -Severity 'Critical' `
                    -CurrentState "Critical" `
                    -ExpectedState "Running" `
                    -Impact "VM is in critical state - likely paused due to low disk space or memory" `
                    -Remediation "Check host resources, then: Resume-VM -Name '$($VM.Name)'"
            }
            default {
                Write-Finding -Category 'VM' -Check "VM: $($VM.Name) - State" -Severity 'Info' `
                    -CurrentState $state `
                    -ExpectedState "Running or Off"
            }
        }
    } catch {
        # Silently continue if we can't check
    }
}

function Test-VMGeneration {
    param([Microsoft.HyperV.PowerShell.VirtualMachine]$VM)
    
    try {
        if ($VM.Generation -eq 2) {
            Write-Finding -Category 'VM' -Check "VM: $($VM.Name) - Generation" -Severity 'Pass' `
                -CurrentState "Generation 2" `
                -ExpectedState "Generation 2"
        } else {
            # Check if it can be converted (no physical disks, etc.)
            $ide = Get-VMIdeController -VMName $VM.Name -ErrorAction SilentlyContinue
            
            Write-Finding -Category 'VM' -Check "VM: $($VM.Name) - Generation" -Severity 'Info' `
                -CurrentState "Generation 1" `
                -ExpectedState "Generation 2 (UEFI, Secure Boot, larger VHDX)" `
                -Impact "Gen1 limited to BIOS boot, no Secure Boot, 2TB VHD limit" `
                -Remediation "Consider migrating to Gen2 VM (requires OS reinstall or conversion)"
        }
    } catch {
        # Silently continue if we can't check
    }
}

function Test-VMIntegrationServices {
    param([Microsoft.HyperV.PowerShell.VirtualMachine]$VM)
    
    try {
        $integrationServices = Get-VMIntegrationService -VMName $VM.Name -ErrorAction SilentlyContinue
        
        $criticalServices = @(
            'Guest Service Interface',
            'Heartbeat',
            'Key-Value Pair Exchange',
            'Shutdown',
            'Time Synchronization',
            'VSS'
        )
        
        $disabledCritical = @()
        
        foreach ($service in $integrationServices) {
            if ($service.Name -in $criticalServices -and -not $service.Enabled) {
                $disabledCritical += $service.Name
            }
        }
        
        if ($disabledCritical.Count -eq 0) {
            Write-Finding -Category 'VM' -Check "VM: $($VM.Name) - Integration Services" -Severity 'Pass' `
                -CurrentState "All critical services enabled" `
                -ExpectedState "Critical integration services enabled"
        } else {
            Write-Finding -Category 'VM' -Check "VM: $($VM.Name) - Integration Services" -Severity 'Warning' `
                -CurrentState "Disabled: $($disabledCritical -join ', ')" `
                -ExpectedState "All critical services enabled" `
                -Impact "Missing services affect backup (VSS), monitoring (Heartbeat), and management" `
                -Remediation "Enable-VMIntegrationService -VMName '$($VM.Name)' -Name '$($disabledCritical[0])'"
        }
        
        # Check if Time Sync is enabled for domain controllers (should often be disabled)
        $timeSyncService = $integrationServices | Where-Object { $_.Name -eq 'Time Synchronization' }
        if ($timeSyncService.Enabled -and $VM.Name -match 'DC|DomainController|PDC') {
            Write-Finding -Category 'VM' -Check "VM: $($VM.Name) - Time Sync" -Severity 'Warning' `
                -CurrentState "Time Synchronization enabled on potential DC" `
                -ExpectedState "Disabled on Domain Controllers" `
                -Impact "DCs should sync time from PDC emulator, not Hyper-V host" `
                -Remediation "Disable-VMIntegrationService -VMName '$($VM.Name)' -Name 'Time Synchronization'"
        }
        
    } catch {
        Write-Finding -Category 'VM' -Check "VM: $($VM.Name) - Integration Services" -Severity 'Info' `
            -CurrentState "Unable to check: $_" `
            -ExpectedState "Integration services enabled"
    }
}

function Test-VMMemoryConfiguration {
    param([Microsoft.HyperV.PowerShell.VirtualMachine]$VM)
    
    try {
        $memory = Get-VMMemory -VMName $VM.Name
        
        # Check dynamic memory
        if ($memory.DynamicMemoryEnabled) {
            $startup = [math]::Round($memory.Startup / 1GB, 1)
            $min = [math]::Round($memory.Minimum / 1GB, 1)
            $max = [math]::Round($memory.Maximum / 1GB, 1)
            
            # Check for common issues
            if ($min -eq $max) {
                Write-Finding -Category 'VM' -Check "VM: $($VM.Name) - Dynamic Memory" -Severity 'Info' `
                    -CurrentState "Min=Max (${min}GB) - effectively static" `
                    -ExpectedState "Different min/max for true dynamic memory"
            } elseif ($max -gt ($startup * 4)) {
                Write-Finding -Category 'VM' -Check "VM: $($VM.Name) - Memory Range" -Severity 'Info' `
                    -CurrentState "Large range: ${min}GB - ${max}GB (Startup: ${startup}GB)" `
                    -ExpectedState "Consider narrower range for predictable performance"
            }
            
            # SQL Server specific check
            if ($VM.Name -match 'SQL') {
                Write-Finding -Category 'VM' -Check "VM: $($VM.Name) - Dynamic Memory" -Severity 'Info' `
                    -CurrentState "Dynamic Memory enabled on SQL VM" `
                    -ExpectedState "Consider static memory for SQL Server" `
                    -Impact "SQL manages its own memory - dynamic memory can cause issues" `
                    -Remediation "Set-VMMemory -VMName '$($VM.Name)' -DynamicMemoryEnabled `$false"
            }
        } else {
            $static = [math]::Round($memory.Startup / 1GB, 1)
            Write-Finding -Category 'VM' -Check "VM: $($VM.Name) - Memory" -Severity 'Pass' `
                -CurrentState "Static: ${static}GB" `
                -ExpectedState "Appropriate for workload"
        }
        
    } catch {
        # Silently continue
    }
}

function Test-VMCpuConfiguration {
    param([Microsoft.HyperV.PowerShell.VirtualMachine]$VM)
    
    try {
        $processor = Get-VMProcessor -VMName $VM.Name
        $vCPUCount = $processor.Count
        
        # Check for NUMA awareness
        $hostNumaNodes = (Get-VMHost).NumaSpanningEnabled
        $vmNumaNodes = $processor.MaximumCountPerNumaNode
        
        # Get host logical processor count
        $hostCPUs = (Get-CimInstance -ClassName Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
        
        # Check if VM has more vCPUs than physical cores
        if ($vCPUCount -gt $hostCPUs) {
            Write-Finding -Category 'VM' -Check "VM: $($VM.Name) - vCPU Count" -Severity 'Warning' `
                -CurrentState "$vCPUCount vCPUs (Host has $hostCPUs logical processors)" `
                -ExpectedState "vCPUs should not exceed host logical processors" `
                -Impact "Over-provisioning causes CPU scheduling overhead" `
                -Remediation "Set-VMProcessor -VMName '$($VM.Name)' -Count $hostCPUs"
        }
        
        # Check NUMA spanning for large VMs
        if ($vCPUCount -gt 8 -and -not $processor.ExposeVirtualizationExtensions) {
            # Large VM, check NUMA configuration
            Write-Finding -Category 'VM' -Check "VM: $($VM.Name) - NUMA Config" -Severity 'Info' `
                -CurrentState "$vCPUCount vCPUs, MaxPerNuma: $vmNumaNodes" `
                -ExpectedState "Configure MaximumCountPerNumaNode for NUMA-aware apps"
        }
        
        # Check for nested virtualization
        if ($processor.ExposeVirtualizationExtensions) {
            Write-Finding -Category 'VM' -Check "VM: $($VM.Name) - Nested Virtualization" -Severity 'Info' `
                -CurrentState "Enabled" `
                -ExpectedState "Enabled only if needed (adds overhead)"
        }
        
    } catch {
        # Silently continue
    }
}

function Test-VMCheckpoints {
    param([Microsoft.HyperV.PowerShell.VirtualMachine]$VM)
    
    try {
        $checkpoints = Get-VMCheckpoint -VMName $VM.Name -ErrorAction SilentlyContinue
        
        if ($checkpoints) {
            $oldCheckpoints = $checkpoints | Where-Object { $_.CreationTime -lt (Get-Date).AddDays(-7) }
            
            if ($oldCheckpoints) {
                Write-Finding -Category 'VM' -Check "VM: $($VM.Name) - Old Checkpoints" -Severity 'Warning' `
                    -CurrentState "$($oldCheckpoints.Count) checkpoint(s) older than 7 days" `
                    -ExpectedState "Remove old checkpoints" `
                    -Impact "Checkpoints consume storage and degrade I/O performance" `
                    -Remediation "Remove-VMCheckpoint -VMName '$($VM.Name)' -Name '<CheckpointName>'"
            } else {
                Write-Finding -Category 'VM' -Check "VM: $($VM.Name) - Checkpoints" -Severity 'Info' `
                    -CurrentState "$($checkpoints.Count) recent checkpoint(s)" `
                    -ExpectedState "Checkpoints should be temporary"
            }
        }
        
        # Check checkpoint type
        $checkpointType = $VM.CheckpointType
        
        if ($checkpointType -eq 'Standard') {
            Write-Finding -Category 'VM' -Check "VM: $($VM.Name) - Checkpoint Type" -Severity 'Info' `
                -CurrentState "Standard checkpoints" `
                -ExpectedState "Production checkpoints for production VMs" `
                -Impact "Standard checkpoints save memory state - may cause app inconsistency" `
                -Remediation "Set-VM -VMName '$($VM.Name)' -CheckpointType Production"
        }
        
    } catch {
        # Silently continue
    }
}

function Test-VMWorkloadSpecific {
    param([Microsoft.HyperV.PowerShell.VirtualMachine]$VM)
    
    try {
        $vmName = $VM.Name.ToLower()
        
        # SQL Server VM checks
        if ($vmName -match 'sql') {
            $vhds = Get-VMHardDiskDrive -VMName $VM.Name
            
            if ($vhds.Count -lt 2) {
                Write-Finding -Category 'VM' -Check "VM: $($VM.Name) - SQL Disk Layout" -Severity 'Info' `
                    -CurrentState "$($vhds.Count) virtual disk(s)" `
                    -ExpectedState "Separate VHDXs for OS, Data, Logs, TempDB" `
                    -Impact "Multiple VHDXs allow I/O distribution and separate backups"
            }
            
            # Check for pass-through disks (good for SQL)
            $passthrough = $vhds | Where-Object { $_.Path -eq $null -and $_.DiskNumber -ne $null }
            if ($passthrough) {
                Write-Finding -Category 'VM' -Check "VM: $($VM.Name) - Pass-through Disks" -Severity 'Pass' `
                    -CurrentState "$($passthrough.Count) pass-through disk(s)" `
                    -ExpectedState "Pass-through for high-performance SQL"
            }
        }
        
        # RDS/Terminal Server checks
        if ($vmName -match 'rds|terminal|ts|citrix') {
            $memory = Get-VMMemory -VMName $VM.Name
            $processor = Get-VMProcessor -VMName $VM.Name
            
            if ($memory.DynamicMemoryEnabled) {
                Write-Finding -Category 'VM' -Check "VM: $($VM.Name) - RDS Memory" -Severity 'Pass' `
                    -CurrentState "Dynamic memory enabled" `
                    -ExpectedState "Dynamic memory good for RDS"
            }
            
            if ($processor.Count -lt 4) {
                Write-Finding -Category 'VM' -Check "VM: $($VM.Name) - RDS vCPU" -Severity 'Info' `
                    -CurrentState "$($processor.Count) vCPUs" `
                    -ExpectedState "4+ vCPUs for multi-user RDS"
            }
        }
        
        # Domain Controller checks
        if ($vmName -match '^dc|domain|pdc|bdc') {
            $checkpoints = Get-VMCheckpoint -VMName $VM.Name -ErrorAction SilentlyContinue
            
            if ($checkpoints) {
                Write-Finding -Category 'VM' -Check "VM: $($VM.Name) - DC Checkpoints" -Severity 'Warning' `
                    -CurrentState "$($checkpoints.Count) checkpoint(s) exist" `
                    -ExpectedState "No checkpoints on Domain Controllers" `
                    -Impact "Restoring DC checkpoints can cause USN rollback and AD corruption" `
                    -Remediation "Remove all checkpoints and disable: Set-VM -VMName '$($VM.Name)' -CheckpointType Disabled"
            }
        }
        
        # File Server checks
        if ($vmName -match 'file|fs\d|nas|storage') {
            $vhds = Get-VMHardDiskDrive -VMName $VM.Name
            
            foreach ($vhd in $vhds) {
                $vhdInfo = Get-VHD -Path $vhd.Path -ErrorAction SilentlyContinue
                if ($vhdInfo -and $vhdInfo.VhdType -eq 'Dynamic') {
                    $sizeGB = [math]::Round($vhdInfo.Size / 1GB, 0)
                    $usedGB = [math]::Round($vhdInfo.FileSize / 1GB, 1)
                    
                    if ($usedGB / $sizeGB -gt 0.8) {
                        Write-Finding -Category 'VM' -Check "VM: $($VM.Name) - Disk Space" -Severity 'Warning' `
                            -CurrentState "$(Split-Path $vhd.Path -Leaf): ${usedGB}GB / ${sizeGB}GB (>80%)" `
                            -ExpectedState "Monitor disk growth on file servers" `
                            -Impact "Dynamic VHDX may fail to expand if host storage is full"
                    }
                }
            }
        }
        
    } catch {
        # Silently continue
    }
}

function Test-VMAutomaticActions {
    param([Microsoft.HyperV.PowerShell.VirtualMachine[]]$VMs)
    
    try {
        # Check automatic start settings
        $noAutoStart = $VMs | Where-Object { $_.AutomaticStartAction -eq 'Nothing' }
        
        if ($noAutoStart) {
            Write-Finding -Category 'VM' -Check 'Automatic Start Action' -Severity 'Info' `
                -CurrentState "$($noAutoStart.Count) VM(s) won't auto-start: $($noAutoStart.Name -join ', ' | Select-Object -First 100)" `
                -ExpectedState "Configure based on requirements" `
                -Remediation "Set-VM -VMName '<VMName>' -AutomaticStartAction StartIfRunning"
        }
        
        # Check start delay for staggered startup
        $noDelay = $VMs | Where-Object { $_.AutomaticStartDelay -eq 0 -and $_.AutomaticStartAction -ne 'Nothing' }
        
        if ($noDelay.Count -gt 5) {
            Write-Finding -Category 'VM' -Check 'Automatic Start Delay' -Severity 'Info' `
                -CurrentState "$($noDelay.Count) VMs with no start delay" `
                -ExpectedState "Stagger VM startup to prevent resource contention" `
                -Impact "All VMs starting simultaneously can overwhelm storage and CPU" `
                -Remediation "Set-VM -VMName '<VMName>' -AutomaticStartDelay <seconds>"
        }
        
        # Check stop action
        $shutdownStop = $VMs | Where-Object { $_.AutomaticStopAction -eq 'ShutDown' }
        $saveStop = $VMs | Where-Object { $_.AutomaticStopAction -eq 'Save' }
        
        if ($saveStop.Count -gt 0) {
            Write-Finding -Category 'VM' -Check 'Automatic Stop Action' -Severity 'Info' `
                -CurrentState "$($saveStop.Count) VM(s) set to Save state on host shutdown" `
                -ExpectedState "ShutDown recommended for most VMs" `
                -Impact "Save state requires disk space and may fail on memory-heavy VMs"
        }
        
    } catch {
        Write-Finding -Category 'VM' -Check 'Automatic Actions' -Severity 'Info' `
            -CurrentState "Unable to check: $_" `
            -ExpectedState "Configured appropriately"
    }
}
#endregion

#region Cluster Checks
function Test-ClusterConfiguration {
    if (-not $script:Environment.IsClusterNode) { return }
    if ($Category -notin @('Cluster', 'All')) { return }
    
    Write-Log "`n=== Cluster Configuration ===" -Level 'INFO'
    
    # Quorum Configuration
    Test-QuorumConfiguration
    
    # Live Migration Settings
    Test-LiveMigrationConfiguration
    
    # Cluster Network Configuration
    Test-ClusterNetworkConfiguration
    
    # Cluster Aware Updating
    if ($Mode -in @('Standard', 'Full')) {
        Test-ClusterAwareUpdating
    }
    
    # Anti-Affinity Rules
    if ($Mode -eq 'Full') {
        Test-AntiAffinityRules
    }
    
    # Drain on Shutdown
    Test-DrainOnShutdown
}

function Test-QuorumConfiguration {
    try {
        $quorum = Get-ClusterQuorum -ErrorAction SilentlyContinue
        
        if (-not $quorum) {
            Write-Finding -Category 'Cluster' -Check 'Quorum Configuration' -Severity 'Warning' `
                -CurrentState "Unable to retrieve quorum configuration" `
                -ExpectedState "Proper quorum configuration"
            return
        }
        
        $quorumType = $quorum.QuorumType
        $quorumResource = $quorum.QuorumResource
        
        $nodeCount = $script:Environment.ClusterNodes.Count
        
        # Evaluate quorum based on node count
        switch ($quorumType) {
            'Majority' {
                if ($nodeCount -eq 2) {
                    Write-Finding -Category 'Cluster' -Check 'Quorum Configuration' -Severity 'Warning' `
                        -CurrentState "Node Majority with 2 nodes (no witness)" `
                        -ExpectedState "Disk or Cloud Witness for 2-node clusters" `
                        -Impact "Losing one node loses quorum and stops cluster" `
                        -Remediation "Set-ClusterQuorum -CloudWitness -AccountName '<storage>' -AccessKey '<key>'"
                } else {
                    Write-Finding -Category 'Cluster' -Check 'Quorum Configuration' -Severity 'Pass' `
                        -CurrentState "Node Majority ($nodeCount nodes)" `
                        -ExpectedState "Node Majority appropriate for odd node count"
                }
            }
            'NodeAndDiskMajority' {
                Write-Finding -Category 'Cluster' -Check 'Quorum Configuration' -Severity 'Pass' `
                    -CurrentState "Node and Disk Majority (Witness: $($quorumResource.Name))" `
                    -ExpectedState "Disk witness configured"
            }
            'NodeAndFileShareMajority' {
                Write-Finding -Category 'Cluster' -Check 'Quorum Configuration' -Severity 'Pass' `
                    -CurrentState "Node and File Share Majority" `
                    -ExpectedState "File share witness configured" `
                    -Reference "Ensure file share witness is on separate failure domain"
            }
            'NodeAndCloudMajority' {
                Write-Finding -Category 'Cluster' -Check 'Quorum Configuration' -Severity 'Pass' `
                    -CurrentState "Cloud Witness configured" `
                    -ExpectedState "Cloud witness (recommended)"
            }
            default {
                Write-Finding -Category 'Cluster' -Check 'Quorum Configuration' -Severity 'Info' `
                    -CurrentState $quorumType `
                    -ExpectedState "Appropriate quorum for node count"
            }
        }
        
    } catch {
        Write-Finding -Category 'Cluster' -Check 'Quorum Configuration' -Severity 'Info' `
            -CurrentState "Unable to check: $_" `
            -ExpectedState "Proper quorum configuration"
    }
}

function Test-LiveMigrationConfiguration {
    try {
        $cluster = Get-Cluster
        $migrationSettings = Get-VMHost
        
        # Check Live Migration network
        $lmNetworks = Get-ClusterNetwork | Where-Object { $_.Role -eq 1 -or $_.Role -eq 3 }  # Live Migration enabled
        
        if ($lmNetworks) {
            $lmNetwork = $lmNetworks | Select-Object -First 1
            Write-Finding -Category 'Cluster' -Check 'Live Migration Network' -Severity 'Pass' `
                -CurrentState "Enabled on: $($lmNetworks.Name -join ', ')" `
                -ExpectedState "Dedicated Live Migration network"
        } else {
            Write-Finding -Category 'Cluster' -Check 'Live Migration Network' -Severity 'Warning' `
                -CurrentState "No dedicated Live Migration network" `
                -ExpectedState "Dedicated network for Live Migration" `
                -Impact "Live Migration on general network competes with VM traffic"
        }
        
        # Check concurrent migrations
        $maxMigrations = $migrationSettings.MaximumVirtualMachineMigrations
        
        if ($maxMigrations -gt 4) {
            Write-Finding -Category 'Cluster' -Check 'Concurrent Live Migrations' -Severity 'Info' `
                -CurrentState "$maxMigrations concurrent migrations allowed" `
                -ExpectedState "2-4 recommended for most environments" `
                -Impact "Too many concurrent migrations can saturate network/storage"
        } else {
            Write-Finding -Category 'Cluster' -Check 'Concurrent Live Migrations' -Severity 'Pass' `
                -CurrentState "$maxMigrations concurrent migrations" `
                -ExpectedState "2-4 concurrent migrations"
        }
        
        # Check migration type
        $migrationType = $migrationSettings.VirtualMachineMigrationPerformanceOption
        
        $migrationTypeDisplay = switch ($migrationType) {
            'TCPIP' { 'TCP/IP' }
            'Compression' { 'Compression' }
            'SMB' { 'SMB Direct (RDMA)' }
            default { $migrationType }
        }
        
        Write-Finding -Category 'Cluster' -Check 'Live Migration Type' -Severity 'Info' `
            -CurrentState $migrationTypeDisplay `
            -ExpectedState "SMB Direct (RDMA) if available, otherwise Compression" `
            -Remediation "Set-VMHost -VirtualMachineMigrationPerformanceOption SMB"
        
        # Check authentication type
        $authType = $migrationSettings.VirtualMachineMigrationAuthenticationType
        
        if ($authType -eq 'Kerberos') {
            Write-Finding -Category 'Cluster' -Check 'Live Migration Auth' -Severity 'Pass' `
                -CurrentState "Kerberos (constrained delegation)" `
                -ExpectedState "Kerberos for security"
        } else {
            Write-Finding -Category 'Cluster' -Check 'Live Migration Auth' -Severity 'Info' `
                -CurrentState "CredSSP" `
                -ExpectedState "Kerberos preferred for security" `
                -Remediation "Set-VMHost -VirtualMachineMigrationAuthenticationType Kerberos"
        }
        
    } catch {
        Write-Finding -Category 'Cluster' -Check 'Live Migration' -Severity 'Info' `
            -CurrentState "Unable to check: $_" `
            -ExpectedState "Properly configured"
    }
}

function Test-ClusterNetworkConfiguration {
    try {
        $networks = Get-ClusterNetwork
        
        foreach ($network in $networks) {
            $role = switch ($network.Role) {
                0 { 'None (disabled)' }
                1 { 'Cluster only' }
                2 { 'Client access only' }  # Deprecated
                3 { 'Cluster and Client' }
                default { "Unknown ($($network.Role))" }
            }
            
            # Check for networks with Role 0 (disabled)
            if ($network.Role -eq 0) {
                Write-Finding -Category 'Cluster' -Check "Cluster Network: $($network.Name)" -Severity 'Info' `
                    -CurrentState "Disabled for cluster use" `
                    -ExpectedState "Verify this is intentional (e.g., iSCSI network)"
            }
            
            # Check cluster heartbeat network
            if ($network.Role -eq 1) {
                Write-Finding -Category 'Cluster' -Check "Cluster Network: $($network.Name)" -Severity 'Pass' `
                    -CurrentState "Dedicated cluster communication" `
                    -ExpectedState "Cluster-only network configured"
            }
        }
        
        # Check for multiple cluster networks (redundancy)
        $clusterNetworks = $networks | Where-Object { $_.Role -in @(1, 3) }
        
        if ($clusterNetworks.Count -lt 2) {
            Write-Finding -Category 'Cluster' -Check 'Cluster Network Redundancy' -Severity 'Warning' `
                -CurrentState "Only $($clusterNetworks.Count) cluster-enabled network(s)" `
                -ExpectedState "Multiple networks for redundancy" `
                -Impact "Single network failure can cause cluster split"
        } else {
            Write-Finding -Category 'Cluster' -Check 'Cluster Network Redundancy' -Severity 'Pass' `
                -CurrentState "$($clusterNetworks.Count) cluster-enabled networks" `
                -ExpectedState "Multiple networks for redundancy"
        }
        
    } catch {
        Write-Finding -Category 'Cluster' -Check 'Cluster Networks' -Severity 'Info' `
            -CurrentState "Unable to check: $_" `
            -ExpectedState "Properly configured"
    }
}

function Test-ClusterAwareUpdating {
    try {
        $cauInfo = Get-CauClusterRole -ErrorAction SilentlyContinue
        
        if ($cauInfo) {
            Write-Finding -Category 'Cluster' -Check 'Cluster-Aware Updating' -Severity 'Pass' `
                -CurrentState "Configured (Days: $($cauInfo.DaysOfWeek), Time: $($cauInfo.StartDate.ToShortTimeString()))" `
                -ExpectedState "CAU configured for automated patching"
        } else {
            Write-Finding -Category 'Cluster' -Check 'Cluster-Aware Updating' -Severity 'Info' `
                -CurrentState "Not configured" `
                -ExpectedState "Consider CAU for automated cluster patching" `
                -Remediation "Add-CauClusterRole -ClusterName '$($script:Environment.ClusterName)' -Force"
        }
        
    } catch {
        Write-Finding -Category 'Cluster' -Check 'Cluster-Aware Updating' -Severity 'Info' `
            -CurrentState "Unable to check (CAU module may not be loaded)" `
            -ExpectedState "CAU configured"
    }
}

function Test-AntiAffinityRules {
    try {
        $groups = Get-ClusterGroup | Where-Object { $_.GroupType -eq 'VirtualMachine' }
        
        $antiAffinityGroups = @{}
        
        foreach ($group in $groups) {
            $antiAffinity = ($group | Get-ClusterParameter -Name AntiAffinityClassNames -ErrorAction SilentlyContinue).Value
            
            if ($antiAffinity) {
                if (-not $antiAffinityGroups.ContainsKey($antiAffinity)) {
                    $antiAffinityGroups[$antiAffinity] = @()
                }
                $antiAffinityGroups[$antiAffinity] += $group.Name
            }
        }
        
        if ($antiAffinityGroups.Count -gt 0) {
            foreach ($className in $antiAffinityGroups.Keys) {
                $vms = $antiAffinityGroups[$className]
                Write-Finding -Category 'Cluster' -Check "Anti-Affinity: $className" -Severity 'Pass' `
                    -CurrentState "$($vms.Count) VMs: $($vms -join ', ' | Select-Object -First 100)" `
                    -ExpectedState "Anti-affinity keeps related VMs on different nodes"
            }
        } else {
            Write-Finding -Category 'Cluster' -Check 'Anti-Affinity Rules' -Severity 'Info' `
                -CurrentState "No anti-affinity rules configured" `
                -ExpectedState "Consider for HA pairs (DCs, SQL AG nodes, etc.)" `
                -Remediation "(Get-ClusterGroup 'VM1').AntiAffinityClassNames = 'MyAntiAffinityGroup'"
        }
        
    } catch {
        Write-Finding -Category 'Cluster' -Check 'Anti-Affinity' -Severity 'Info' `
            -CurrentState "Unable to check: $_" `
            -ExpectedState "Configured for HA pairs"
    }
}

function Test-DrainOnShutdown {
    try {
        $nodes = Get-ClusterNode
        
        foreach ($node in $nodes) {
            $drainBehavior = ($node | Get-ClusterParameter -Name DrainOnShutdown -ErrorAction SilentlyContinue).Value
            
            if ($drainBehavior -eq 1) {
                Write-Finding -Category 'Cluster' -Check "Drain on Shutdown: $($node.Name)" -Severity 'Pass' `
                    -CurrentState "Enabled" `
                    -ExpectedState "Drain on shutdown enabled"
            } else {
                Write-Finding -Category 'Cluster' -Check "Drain on Shutdown: $($node.Name)" -Severity 'Warning' `
                    -CurrentState "Disabled" `
                    -ExpectedState "Enabled for graceful VM migration" `
                    -Impact "VMs may not migrate gracefully during planned maintenance" `
                    -Remediation "(Get-ClusterNode '$($node.Name)') | Set-ClusterParameter -Name DrainOnShutdown -Value 1"
            }
        }
        
    } catch {
        Write-Finding -Category 'Cluster' -Check 'Drain on Shutdown' -Severity 'Info' `
            -CurrentState "Unable to check: $_" `
            -ExpectedState "Enabled on all nodes"
    }
}
#endregion

#region Security Checks
function Test-SecurityConfiguration {
    if ($Category -notin @('Security', 'All')) { return }
    
    Write-Log "`n=== Security Configuration ===" -Level 'INFO'
    
    # Secure Boot on VMs
    Test-VMSecureBoot
    
    # vTPM Configuration
    Test-VMTpm
    
    # Shielded VMs
    if ($Mode -in @('Standard', 'Full')) {
        Test-ShieldedVMs
    }
    
    # Host Guardian Service
    if ($Mode -eq 'Full') {
        Test-HostGuardianService
    }
    
    # BitLocker on CSV
    if ($script:Environment.IsClusterNode -and $Mode -eq 'Full') {
        Test-CsvBitLocker
    }
    
    # Hyper-V Host Security Features
    Test-HostSecurityFeatures
}

function Test-VMSecureBoot {
    try {
        $gen2VMs = Get-VM | Where-Object { $_.Generation -eq 2 }
        
        if (-not $gen2VMs) {
            Write-Finding -Category 'Security' -Check 'VM Secure Boot' -Severity 'Info' `
                -CurrentState "No Generation 2 VMs found" `
                -ExpectedState "Gen2 VMs support Secure Boot"
            return
        }
        
        $secureBootDisabled = @()
        
        foreach ($vm in $gen2VMs) {
            $firmware = Get-VMFirmware -VMName $vm.Name -ErrorAction SilentlyContinue
            
            if ($firmware -and -not $firmware.SecureBoot -eq 'On') {
                $secureBootDisabled += $vm.Name
            }
        }
        
        if ($secureBootDisabled.Count -eq 0) {
            Write-Finding -Category 'Security' -Check 'VM Secure Boot' -Severity 'Pass' `
                -CurrentState "Enabled on all $($gen2VMs.Count) Gen2 VMs" `
                -ExpectedState "Secure Boot enabled"
        } else {
            $vmList = if ($secureBootDisabled.Count -gt 5) { 
                "$($secureBootDisabled[0..4] -join ', ') (+$($secureBootDisabled.Count - 5) more)"
            } else {
                $secureBootDisabled -join ', '
            }
            
            Write-Finding -Category 'Security' -Check 'VM Secure Boot' -Severity 'Warning' `
                -CurrentState "$($secureBootDisabled.Count) Gen2 VMs without Secure Boot: $vmList" `
                -ExpectedState "Secure Boot enabled on all Gen2 VMs" `
                -Impact "Secure Boot prevents boot-level malware" `
                -Remediation "Set-VMFirmware -VMName '<VMName>' -EnableSecureBoot On -SecureBootTemplate 'MicrosoftWindows'"
        }
        
    } catch {
        Write-Finding -Category 'Security' -Check 'VM Secure Boot' -Severity 'Info' `
            -CurrentState "Unable to check: $_" `
            -ExpectedState "Enabled on Gen2 VMs"
    }
}

function Test-VMTpm {
    # Get-VMTpm requires Windows Server 2016+ and may not be available on all systems
    if (-not (Get-Command -Name 'Get-VMTpm' -ErrorAction SilentlyContinue)) {
        Write-Finding -Category 'Security' -Check 'Virtual TPM' -Severity 'Info' `
            -CurrentState "Get-VMTpm cmdlet not available (requires Server 2016+)" `
            -ExpectedState "vTPM assessment skipped"
        return
    }
    
    try {
        $gen2VMs = Get-VM | Where-Object { $_.Generation -eq 2 }
        
        if (-not $gen2VMs) { return }
        
        $withTpm = @()
        $withoutTpm = @()
        
        foreach ($vm in $gen2VMs) {
            $tpm = Get-VMTpm -VMName $vm.Name -ErrorAction SilentlyContinue
            
            if ($tpm -and $tpm.TpmEnabled) {
                $withTpm += $vm.Name
            } else {
                $withoutTpm += $vm.Name
            }
        }
        
        if ($withTpm.Count -gt 0) {
            Write-Finding -Category 'Security' -Check 'Virtual TPM' -Severity 'Pass' `
                -CurrentState "$($withTpm.Count) VMs have vTPM enabled" `
                -ExpectedState "vTPM for BitLocker and security features"
        }
        
        if ($withoutTpm.Count -gt 0) {
            $vmList = if ($withoutTpm.Count -gt 5) {
                "$($withoutTpm[0..4] -join ', ') (+$($withoutTpm.Count - 5) more)"
            } else {
                $withoutTpm -join ', '
            }
            
            Write-Finding -Category 'Security' -Check 'Virtual TPM' -Severity 'Info' `
                -CurrentState "$($withoutTpm.Count) Gen2 VMs without vTPM: $vmList" `
                -ExpectedState "vTPM enables BitLocker without external key" `
                -Remediation "Enable-VMTpm -VMName '<VMName>' (requires HGS or local key protector)"
        }
        
    } catch {
        Write-Finding -Category 'Security' -Check 'Virtual TPM' -Severity 'Info' `
            -CurrentState "Unable to check: $_" `
            -ExpectedState "vTPM enabled where needed"
    }
}

function Test-ShieldedVMs {
    try {
        $vms = Get-VM
        $shieldedCount = 0
        $encryptionSupportedCount = 0
        
        foreach ($vm in $vms) {
            $security = Get-VMSecurity -VMName $vm.Name -ErrorAction SilentlyContinue
            
            if ($security) {
                if ($security.Shielded) {
                    $shieldedCount++
                } elseif ($security.EncryptStateAndVmMigrationTraffic) {
                    $encryptionSupportedCount++
                }
            }
        }
        
        if ($shieldedCount -gt 0) {
            Write-Finding -Category 'Security' -Check 'Shielded VMs' -Severity 'Pass' `
                -CurrentState "$shieldedCount shielded VM(s) detected" `
                -ExpectedState "Shielded VMs for sensitive workloads"
        }
        
        if ($encryptionSupportedCount -gt 0) {
            Write-Finding -Category 'Security' -Check 'VM Encryption' -Severity 'Info' `
                -CurrentState "$encryptionSupportedCount VM(s) with encryption support enabled" `
                -ExpectedState "Encryption supported VMs"
        }
        
        if ($shieldedCount -eq 0 -and $encryptionSupportedCount -eq 0) {
            Write-Finding -Category 'Security' -Check 'Shielded/Encrypted VMs' -Severity 'Info' `
                -CurrentState "No shielded or encrypted VMs detected" `
                -ExpectedState "Consider for sensitive workloads" `
                -Reference "Requires Host Guardian Service for full shielding"
        }
        
    } catch {
        Write-Finding -Category 'Security' -Check 'Shielded VMs' -Severity 'Info' `
            -CurrentState "Unable to check: $_" `
            -ExpectedState "Evaluate for sensitive workloads"
    }
}

function Test-HostGuardianService {
    try {
        # Check if HGS client is configured
        $hgsClientConfig = Get-HgsClientConfiguration -ErrorAction SilentlyContinue
        
        if ($hgsClientConfig) {
            if ($hgsClientConfig.IsHostGuarded) {
                Write-Finding -Category 'Security' -Check 'Host Guardian Status' -Severity 'Pass' `
                    -CurrentState "Host is guarded (Mode: $($hgsClientConfig.Mode))" `
                    -ExpectedState "Guarded host for shielded VMs"
                    
                Write-Finding -Category 'Security' -Check 'HGS Attestation' -Severity 'Pass' `
                    -CurrentState "Attestation URL: $($hgsClientConfig.AttestationServerUrl)" `
                    -ExpectedState "HGS attestation configured"
            } else {
                Write-Finding -Category 'Security' -Check 'Host Guardian Status' -Severity 'Info' `
                    -CurrentState "HGS client configured but host not currently guarded" `
                    -ExpectedState "Host attested for shielded VMs" `
                    -Impact "Cannot run shielded VMs without attestation"
            }
        } else {
            Write-Finding -Category 'Security' -Check 'Host Guardian Service' -Severity 'Info' `
                -CurrentState "HGS not configured" `
                -ExpectedState "Configure HGS for shielded VMs" `
                -Reference "https://docs.microsoft.com/en-us/windows-server/security/guarded-fabric-shielded-vm/guarded-fabric-and-shielded-vms"
        }
        
    } catch {
        # HGS cmdlets may not be available
        Write-Finding -Category 'Security' -Check 'Host Guardian Service' -Severity 'Info' `
            -CurrentState "HGS not available or not configured" `
            -ExpectedState "Optional for shielded VM support"
    }
}

function Test-CsvBitLocker {
    try {
        $csvs = Get-ClusterSharedVolume -ErrorAction SilentlyContinue
        
        if (-not $csvs) { return }
        
        foreach ($csv in $csvs) {
            $volumePath = $csv.SharedVolumeInfo.Partition.Name
            
            # Check BitLocker status
            $bitlocker = Get-BitLockerVolume -MountPoint $volumePath -ErrorAction SilentlyContinue
            
            if ($bitlocker) {
                if ($bitlocker.ProtectionStatus -eq 'On') {
                    Write-Finding -Category 'Security' -Check "CSV BitLocker: $($csv.Name)" -Severity 'Pass' `
                        -CurrentState "Encrypted ($($bitlocker.EncryptionMethod))" `
                        -ExpectedState "BitLocker enabled"
                } else {
                    Write-Finding -Category 'Security' -Check "CSV BitLocker: $($csv.Name)" -Severity 'Info' `
                        -CurrentState "Not encrypted" `
                        -ExpectedState "Consider BitLocker for data at rest protection" `
                        -Impact "Unencrypted CSVs expose data if disks are removed"
                }
            }
        }
        
    } catch {
        # BitLocker cmdlets may require specific module
        Write-Finding -Category 'Security' -Check 'CSV BitLocker' -Severity 'Info' `
            -CurrentState "Unable to check BitLocker status" `
            -ExpectedState "BitLocker for data at rest protection"
    }
}

function Test-HostSecurityFeatures {
    try {
        # Check Credential Guard
        $deviceGuard = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction SilentlyContinue
        
        if ($deviceGuard) {
            # VBS Status
            $vbsStatus = switch ($deviceGuard.VirtualizationBasedSecurityStatus) {
                0 { 'Disabled' }
                1 { 'Enabled but not running' }
                2 { 'Running' }
                default { 'Unknown' }
            }
            
            if ($deviceGuard.VirtualizationBasedSecurityStatus -eq 2) {
                Write-Finding -Category 'Security' -Check 'Virtualization Based Security' -Severity 'Pass' `
                    -CurrentState "Running" `
                    -ExpectedState "VBS running for Credential Guard"
            } else {
                Write-Finding -Category 'Security' -Check 'Virtualization Based Security' -Severity 'Info' `
                    -CurrentState $vbsStatus `
                    -ExpectedState "Enabled for Credential Guard" `
                    -Remediation "Enable via Group Policy or registry"
            }
            
            # Credential Guard
            if ($deviceGuard.SecurityServicesRunning -contains 1) {
                Write-Finding -Category 'Security' -Check 'Credential Guard' -Severity 'Pass' `
                    -CurrentState "Running" `
                    -ExpectedState "Credential Guard protects credentials"
            }
        }
        
        # Check Windows Firewall
        $firewallProfiles = Get-NetFirewallProfile -ErrorAction SilentlyContinue
        
        $disabledProfiles = $firewallProfiles | Where-Object { -not $_.Enabled }
        
        if ($disabledProfiles) {
            Write-Finding -Category 'Security' -Check 'Windows Firewall' -Severity 'Warning' `
                -CurrentState "Disabled on: $($disabledProfiles.Name -join ', ')" `
                -ExpectedState "Enabled on all profiles" `
                -Remediation "Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled True"
        } else {
            Write-Finding -Category 'Security' -Check 'Windows Firewall' -Severity 'Pass' `
                -CurrentState "Enabled on all profiles" `
                -ExpectedState "Firewall enabled"
        }
        
    } catch {
        Write-Finding -Category 'Security' -Check 'Host Security Features' -Severity 'Info' `
            -CurrentState "Unable to check: $_" `
            -ExpectedState "VBS and Credential Guard"
    }
}
#endregion

#region Main Execution
function Show-Banner {
    if ($Quiet) { return }
    
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  Hyper-V Assessment Tool v$script:ScriptVersion" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Show-Summary {
    if ($Quiet) { return }
    
    $duration = (Get-Date) - $script:StartTime
    
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  Assessment Summary" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Host:     $($script:Environment.HostName)" -ForegroundColor White
    Write-Host "  Cluster:  $(if ($script:Environment.IsClusterNode) { $script:Environment.ClusterName } else { 'Standalone' })" -ForegroundColor White
    Write-Host "  Mode:     $Mode" -ForegroundColor White
    Write-Host "  Duration: $($duration.ToString('mm\:ss'))" -ForegroundColor White
    Write-Host ""
    
    $critColor = if ($script:Summary.Critical -gt 0) { 'Red' } else { 'Green' }
    $warnColor = if ($script:Summary.Warning -gt 0) { 'Yellow' } else { 'Green' }
    
    Write-Host "  Results:" -ForegroundColor White
    Write-Host "    Critical: $($script:Summary.Critical)" -ForegroundColor $critColor
    Write-Host "    Warning:  $($script:Summary.Warning)" -ForegroundColor $warnColor
    Write-Host "    Info:     $($script:Summary.Info)" -ForegroundColor Cyan
    Write-Host "    Pass:     $($script:Summary.Pass)" -ForegroundColor Green
    Write-Host ""
    
    if ($AutoExport) {
        Write-Host "  Reports saved to: $OutputPath" -ForegroundColor Green
    }
    
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
}

# Main
Show-Banner

# Initialize
if ($AutoExport) {
    Initialize-OutputDirectory
}

# Check prerequisites
if (-not $script:IsAdmin) {
    Write-Log "This script requires administrator privileges." -Level 'ERROR'
    exit 20
}

# Detect environment
$envReady = Initialize-Environment
if (-not $envReady) {
    Write-Log "Failed to initialize environment. Ensure Hyper-V role is installed." -Level 'ERROR'
    exit 20
}

# Run assessments based on category
if ($Category -in @('Host', 'All')) {
    Test-HostConfiguration
}

if ($Category -in @('Storage', 'All')) {
    Test-StorageConfiguration
}

if ($Category -in @('Network', 'All')) {
    Test-NetworkConfiguration
}

if ($Category -in @('VM', 'All')) {
    Test-VMConfiguration
}

if ($Category -in @('Cluster', 'All')) {
    Test-ClusterConfiguration
}

if ($Category -in @('Security', 'All')) {
    Test-SecurityConfiguration
}

# Export results
Export-Results

# Write NinjaRMM fields
Write-NinjaOutput

# Show summary
Show-Summary

# Return objects if PassThru
    if ($PassThru) {
        return [PSCustomObject]@{
            Environment = $script:Environment
            Summary     = $script:Summary
            Findings    = $script:Findings
        }
    }

    # Determine exit code for RMM/automation
    $exitCode = if ($script:Summary.Critical -gt 0) { 1 }
                elseif ($script:Summary.Warning -gt 0) { 10 }
                else { 0 }

    # Return exit code as property (caller can use $LASTEXITCODE or check result)
    return [PSCustomObject]@{
        ExitCode = $exitCode
        Summary  = $script:Summary
    }
    #endregion
}

# Auto-run ONLY when executed as a script file (.\HyperVAssessment.ps1)
# Does NOT run when: copy-pasted to console, dot-sourced, or imported
# $MyInvocation.MyCommand.Path is only set when running from a file
if ($MyInvocation.MyCommand.Path) {
    $result = HyperVAssessment @PSBoundParameters
    if ($result.ExitCode) {
        exit $result.ExitCode
    }
}

# Example invocations (copy-paste method - paste script first, then call):
# HyperVAssessment -Mode Quick                                       # Critical checks only, console output
# HyperVAssessment -Mode Standard                                    # Common checks, console output
# HyperVAssessment -Mode Full -AutoExport                            # All checks, save reports to C:\Temp\HyperVAssessment\
# HyperVAssessment -Category Storage -AutoExport                     # Storage checks only with reports
# HyperVAssessment -Category Network -OutputFormat HTML -AutoExport  # Network checks only
# HyperVAssessment -Category Security -AutoExport                    # Security assessment with reports
# HyperVAssessment -Mode Standard -VMName "SQL*" -AutoExport         # Assess only SQL VMs
# HyperVAssessment -Mode Full -OutputFormat HTML -AutoExport         # Full assessment, HTML report only
# HyperVAssessment -Mode Standard -PassThru                          # Return objects for pipeline processing
# HyperVAssessment -Mode Quick -Quiet                                # Silent mode for RMM/automation
# HyperVAssessment -Mode Standard -Quiet -AutoExport -NinjaCustomField 'hvAssessStatus' -NinjaHTMLField 'hvAssessReport'  # NinjaRMM scheduled monitoring
#
# Direct execution (run as .ps1 file):
# .\HyperVAssessment.ps1 -Mode Full -AutoExport
# .\HyperVAssessment.ps1 -Category Storage
# .\HyperVAssessment.ps1 -Mode Standard -VMName "DC*","SQL*"
