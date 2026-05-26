#Requires -Version 5.1

<#
.SYNOPSIS
    Assesses iSCSI and MPIO configuration against best practices with pass/fail grading.

.DESCRIPTION
    Comprehensive iSCSI initiator and MPIO configuration assessment for Hyper-V hosts
    using iSCSI-attached storage. Evaluates configuration against vendor-neutral and
    array-specific best practices (HPE MSA, HPE Nimble, generic).

    Report types:
    - Assessment: Pass/fail grading of each check (default)
    - Configuration: Factual snapshot of current iSCSI, MPIO, network, and storage settings
    - Recommendations: Prioritized remediation plan from assessment findings
    - All: All three reports exported together

    Assessment categories:
    - iSCSI Initiator: service, portals, targets, sessions, persistence, errant connections
    - MPIO: global settings, path verification, timeouts, load balance policy, array-specific claims
    - Network: MTU/jumbo frames, NIC power management, offload, VMQ, dedicated NICs
    - Paths: per-disk path counts, health, active/standby state, path limits, partition style
    - Performance: queue depth, session count, multi-session recommendations
    - Hyper-V Storage: VHD/VHDx format, pass-through detection, virtual Fibre Channel

    Each check produces a finding with severity (Critical/Warning/Info/Pass),
    current state, expected state, impact, and remediation steps.

.NOTES
    Script:  iSCSIMPIOAssessment.ps1
    Author:  Jeff Davidson
    Version: 1.3.1
    Date:    2026-03-10

    Requirements:
        - MPIO feature installed
        - iSCSI Initiator service present
        - Run as Administrator for full data collection
        - Hyper-V role recommended but not required

    Exit Codes:
        0  - All checks passed or informational only
        1  - One or more critical findings
        10 - Warnings found (no critical)
        20 - Script execution error

.PARAMETER Mode
    Assessment depth: Quick (key checks only), Standard (default), Full (all checks + performance).

.PARAMETER Category
    Scope: All (default), iSCSI, MPIO, Network, Paths, Performance.

.PARAMETER ArrayType
    Storage array for vendor-specific best practices: Auto (default), MSA, Nimble, Generic.
    Auto attempts to detect the array type from iSCSI target names.

.PARAMETER OutputPath
    Directory for report output. Default: C:\Temp\iSCSIMPIOAssessment

.PARAMETER OutputFormat
    Report format: JSON, CSV, HTML, Markdown, All. Default: JSON.

.PARAMETER ReportType
    Report scope: Assessment (default pass/fail), Configuration (current state snapshot),
    Recommendations (prioritized remediation plan), All (all three).

.PARAMETER Quiet
    Suppress console output.

.PARAMETER PassThru
    Return findings objects to pipeline.

.PARAMETER AutoExport
    Automatically export reports to OutputPath.

.PARAMETER NinjaCustomField
    Write summary to NinjaRMM text custom field.

.PARAMETER NinjaHTMLField
    Write HTML report to NinjaRMM WYSIWYG field.

.EXAMPLE
    .\iSCSIMPIOAssessment.ps1
    Run standard assessment with console output.

.EXAMPLE
    .\iSCSIMPIOAssessment.ps1 -Mode Full -AutoExport
    Full assessment with all reports exported.

.EXAMPLE
    .\iSCSIMPIOAssessment.ps1 -ArrayType MSA -Category MPIO -AutoExport
    MPIO-only assessment with HPE MSA best practices.

.EXAMPLE
    . .\iSCSIMPIOAssessment.ps1
    Invoke-iSCSIMPIOAssessment -Mode Full -ArrayType Nimble -AutoExport
    Dot-source and run with Nimble-specific checks.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('Quick', 'Standard', 'Full')]
    [string]$Mode = 'Standard',

    [Parameter()]
    [ValidateSet('All', 'iSCSI', 'MPIO', 'Network', 'Paths', 'Performance')]
    [string]$Category = 'All',

    [Parameter()]
    [ValidateSet('Auto', 'MSA', 'Nimble', 'Generic')]
    [string]$ArrayType = 'Auto',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = 'C:\Temp\iSCSIMPIOAssessment',

    [Parameter()]
    [ValidateSet('JSON', 'CSV', 'HTML', 'Markdown', 'All')]
    [string]$OutputFormat = 'JSON',

    [Parameter()]
    [ValidateSet('Assessment', 'Configuration', 'Recommendations', 'All')]
    [string]$ReportType = 'Assessment',

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

# ============================================================================
# SCRIPT CONFIGURATION
# ============================================================================

$script:ScriptVersion = '1.3.0'
$script:ScriptName = 'iSCSIMPIOAssessment'
$script:LogFile = $null

$script:Mode = $Mode
$script:Category = $Category
$script:ArrayType = $ArrayType
$script:OutputPath = $OutputPath
$script:OutputFormat = $OutputFormat
$script:ReportType = $ReportType
$script:Quiet = $Quiet
$script:PassThru = $PassThru
$script:AutoExport = $AutoExport
$script:NinjaCustomField = $NinjaCustomField
$script:NinjaHTMLField = $NinjaHTMLField

$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$script:Findings = New-Object System.Collections.ArrayList
$script:Summary = @{
    TotalChecks = 0
    Critical    = 0
    Warning     = 0
    Info        = 0
    Pass        = 0
}

$script:Environment = @{}
$script:Configuration = @{}

# ============================================================================
# BEST PRACTICE DEFINITIONS (vendor-specific)
# ============================================================================

function Get-BestPractices {
    param([string]$Array)

    # Base best practices (vendor-neutral)
    $bp = @{
        PathVerificationState      = 'Enabled'
        PathVerificationPeriod     = 10
        RetryCount                 = 6
        RetryInterval              = 2
        DiskTimeoutValue           = 120
        UseCustomPathRecoveryTime  = 'Enabled'
        CustomPathRecoveryTime     = 20
        MinPathsPerDisk            = 2
        RecommendedPathsPerDisk    = 4
        LoadBalancePolicy          = 'RR'     # Round Robin
        NicPowerManagement         = 'Disabled'
        JumboFrameConsistency      = $true
        VMQOnISCSINics             = 'Disabled'
        SessionPersistence         = $true
        ISCSIServiceStartType      = 'Automatic'
        MinSessionsPerTarget       = 2
        MaxPathsPerDisk            = 8        # >8 paths slows MPIO failover
    }

    switch ($Array) {
        'MSA' {
            # HPE MSA 2060 / 2062 specific recommendations
            $bp.RetryCount = 6
            $bp.DiskTimeoutValue = 120
            $bp.LoadBalancePolicy = 'RR'
            $bp.RecommendedPathsPerDisk = 4
            $bp.MSAVendorId = 'HPE'
            $bp.MSAProductId = 'MSA 2060'
            $bp.ArrayReference = 'HPE MSA Gen6 Implementation Guide (a00119216ENW)'
            $bp.ArrayNotes = 'HPE MSA 2060: Round Robin with Subset (RRWS) or Round Robin recommended. 4 paths per LUN (2 per controller). Ensure dual-controller ownership is balanced.'
        }
        'Nimble' {
            # HPE Nimble specific recommendations
            $bp.RetryCount = 6
            $bp.RetryInterval = 3
            $bp.DiskTimeoutValue = 120
            $bp.LoadBalancePolicy = 'LQD'     # Least Queue Depth for Nimble
            $bp.RecommendedPathsPerDisk = 4
            $bp.PathVerificationPeriod = 10
            $bp.ArrayNotes = 'HPE Nimble: Least Queue Depth (LQD) recommended. Use Nimble Connection Manager (NCM) for optimal configuration. Ensure ALUA is enabled.'
        }
        default {
            $bp.ArrayNotes = 'Generic best practices applied. Specify -ArrayType for vendor-specific recommendations.'
        }
    }

    return $bp
}

# ============================================================================
# LOGGING
# ============================================================================

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS', 'DEBUG')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logLine = "[$timestamp] [$Level] $Message"

    if (-not $script:Quiet) {
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

# ============================================================================
# FINDINGS ENGINE
# ============================================================================

function Write-Finding {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Critical', 'Warning', 'Info', 'Pass')]
        [string]$Severity,

        [Parameter(Mandatory)]
        [ValidateSet('iSCSI', 'MPIO', 'Network', 'Paths', 'Performance')]
        [string]$Category,

        [Parameter(Mandatory)]
        [string]$Check,

        [string]$CurrentState = '',
        [string]$ExpectedState = '',
        [string]$Impact = '',
        [string]$Remediation = '',
        [string]$Reference = ''
    )

    $finding = [PSCustomObject]@{
        Severity     = $Severity
        Category     = $Category
        Check        = $Check
        CurrentState = $CurrentState
        ExpectedState = $ExpectedState
        Impact       = $Impact
        Remediation  = $Remediation
        Reference    = $Reference
    }

    $null = $script:Findings.Add($finding)
    $script:Summary.TotalChecks++
    $script:Summary[$Severity]++

    if (-not $script:Quiet) {
        $icon = switch ($Severity) {
            'Critical' { '[CRITICAL]' }
            'Warning'  { '[WARNING] ' }
            'Info'     { '[INFO]    ' }
            'Pass'     { '[PASS]    ' }
        }
        $color = switch ($Severity) {
            'Critical' { 'Red' }
            'Warning'  { 'Yellow' }
            'Info'     { 'Cyan' }
            'Pass'     { 'Green' }
        }
        Write-Host "  $icon $Category | $Check" -ForegroundColor $color
        if ($Severity -ne 'Pass' -and $CurrentState) {
            Write-Host "           Current: $CurrentState" -ForegroundColor Gray
            if ($ExpectedState) { Write-Host "           Expected: $ExpectedState" -ForegroundColor Gray }
            if ($Remediation) { Write-Host "           Fix: $Remediation" -ForegroundColor Gray }
        }
    }
}

# ============================================================================
# OUTPUT & EXPORT
# ============================================================================

function Initialize-OutputDirectory {
    if (-not (Test-Path $script:OutputPath)) {
        New-Item -ItemType Directory -Path $script:OutputPath -Force | Out-Null
        Write-Log "Created output directory: $script:OutputPath" -Level 'DEBUG'
    }
    $script:LogFile = Join-Path $script:OutputPath "$script:ScriptName`_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
}

function Export-Results {
    if (-not $script:AutoExport) { return }

    $dateTag = Get-Date -Format 'yyyyMMdd'
    $basePath = Join-Path $script:OutputPath "$script:ScriptName`_$dateTag"

    $formats = if ($script:OutputFormat -eq 'All') { @('JSON', 'CSV', 'HTML', 'Markdown') } else { @($script:OutputFormat) }

    $reportTypes = if ($script:ReportType -eq 'All') {
        @('Assessment', 'Configuration', 'Recommendations')
    } else {
        @($script:ReportType)
    }

    # ── Assessment Report ──
    if ('Assessment' -in $reportTypes) {
        $payload = [PSCustomObject]@{
            Generated   = Get-Date -Format 'o'
            ScriptVersion = $script:ScriptVersion
            ComputerName = $env:COMPUTERNAME
            ArrayType   = $script:ArrayType
            Mode        = $script:Mode
            Summary     = $script:Summary
            Environment = $script:Environment
            Findings    = @($script:Findings)
        }

        foreach ($fmt in $formats) {
            switch ($fmt) {
                'JSON' {
                    $jsonPath = "$basePath.json"
                    $payload | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8
                    Write-Log "Exported JSON: $jsonPath" -Level 'SUCCESS'
                }
                'CSV' {
                    $csvPath = "$basePath.csv"
                    $script:Findings | ConvertTo-Csv -NoTypeInformation | Out-File -FilePath $csvPath -Encoding UTF8
                    Write-Log "Exported CSV: $csvPath" -Level 'SUCCESS'
                }
                'HTML' {
                    $htmlPath = "$basePath.html"
                    Export-HtmlReport -Path $htmlPath
                    Write-Log "Exported HTML: $htmlPath" -Level 'SUCCESS'
                }
                'Markdown' {
                    $mdPath = "$basePath.md"
                    Export-MarkdownReport -Path $mdPath
                    Write-Log "Exported Markdown: $mdPath" -Level 'SUCCESS'
                }
            }
        }
    }

    # ── Configuration Report ──
    if ('Configuration' -in $reportTypes -and $script:Configuration.Count -gt 0) {
        foreach ($fmt in $formats) {
            switch ($fmt) {
                'HTML' {
                    $configHtml = "$basePath`_Configuration.html"
                    Export-ConfigurationReportHtml -Path $configHtml
                    Write-Log "Exported Configuration HTML: $configHtml" -Level 'SUCCESS'
                }
                'Markdown' {
                    $configMd = "$basePath`_Configuration.md"
                    Export-ConfigurationReportMarkdown -Path $configMd
                    Write-Log "Exported Configuration Markdown: $configMd" -Level 'SUCCESS'
                }
                'JSON' {
                    $configJson = "$basePath`_Configuration.json"
                    [PSCustomObject]@{
                        Generated     = Get-Date -Format 'o'
                        ScriptVersion = $script:ScriptVersion
                        ComputerName  = $env:COMPUTERNAME
                        ArrayType     = $script:ArrayType
                        Configuration = $script:Configuration
                    } | ConvertTo-Json -Depth 10 | Out-File -FilePath $configJson -Encoding UTF8
                    Write-Log "Exported Configuration JSON: $configJson" -Level 'SUCCESS'
                }
                'CSV' {
                    Write-Log 'Configuration report: CSV not applicable for hierarchical data — use JSON, HTML, or Markdown' -Level 'DEBUG'
                }
            }
        }
    }

    if ('Recommendations' -in $reportTypes -and $script:Findings.Count -gt 0) {
        foreach ($fmt in $formats) {
            switch ($fmt) {
                'HTML' {
                    $recHtml = "$basePath`_Recommendations.html"
                    Export-RecommendationReportHtml -Path $recHtml
                    Write-Log "Exported Recommendations HTML: $recHtml" -Level 'SUCCESS'
                }
                'Markdown' {
                    $recMd = "$basePath`_Recommendations.md"
                    Export-RecommendationReportMarkdown -Path $recMd
                    Write-Log "Exported Recommendations Markdown: $recMd" -Level 'SUCCESS'
                }
                'JSON' {
                    $actionable = @($script:Findings | Where-Object { $_.Severity -in @('Critical', 'Warning') } |
                        Sort-Object @{Expression={switch($_.Severity){'Critical'{0}'Warning'{1}}}; Ascending=$true})
                    $recJson = "$basePath`_Recommendations.json"
                    [PSCustomObject]@{
                        Generated       = Get-Date -Format 'o'
                        ScriptVersion   = $script:ScriptVersion
                        ComputerName    = $env:COMPUTERNAME
                        ArrayType       = $script:ArrayType
                        Summary         = $script:Summary
                        Recommendations = @($actionable)
                    } | ConvertTo-Json -Depth 10 | Out-File -FilePath $recJson -Encoding UTF8
                    Write-Log "Exported Recommendations JSON: $recJson" -Level 'SUCCESS'
                }
                'CSV' {
                    Write-Log 'Recommendations report: CSV not applicable for hierarchical data — use JSON, HTML, or Markdown' -Level 'DEBUG'
                }
            }
        }
    }
}

function ConvertTo-HtmlSafe {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

function Export-HtmlReport {
    param([string]$Path)

    $critColor = '#dc3545'; $warnColor = '#ffc107'; $passColor = '#28a745'; $infoColor = '#17a2b8'

    $html = @"
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>iSCSI/MPIO Assessment - $env:COMPUTERNAME</title>
<style>
body { font-family: 'Segoe UI', Tahoma, sans-serif; margin: 20px; background: #f5f5f5; }
.header { background: #1a1a2e; color: white; padding: 20px; border-radius: 8px; margin-bottom: 20px; }
.header h1 { margin: 0; } .header p { margin: 5px 0 0; opacity: 0.8; }
.summary { display: flex; gap: 15px; margin-bottom: 20px; flex-wrap: wrap; }
.stat { padding: 15px 25px; border-radius: 8px; color: white; min-width: 120px; text-align: center; }
.stat .num { font-size: 2em; font-weight: bold; } .stat .label { font-size: 0.85em; opacity: 0.9; }
.critical { background: $critColor; } .warning { background: $warnColor; color: #333; }
.pass { background: $passColor; } .info { background: $infoColor; }
table { width: 100%; border-collapse: collapse; background: white; border-radius: 8px; overflow: hidden; box-shadow: 0 1px 3px rgba(0,0,0,0.1); margin-bottom: 20px; }
th { background: #2d2d44; color: white; padding: 12px; text-align: left; }
td { padding: 10px 12px; border-bottom: 1px solid #eee; }
tr:hover { background: #f0f0f0; }
.sev-Critical { color: $critColor; font-weight: bold; } .sev-Warning { color: #e6a100; font-weight: bold; }
.sev-Pass { color: $passColor; } .sev-Info { color: $infoColor; }
.env-table td:first-child { font-weight: bold; width: 200px; }
</style></head><body>
<div class="header"><h1>iSCSI / MPIO Assessment Report</h1>
<p>$env:COMPUTERNAME | Array: $($script:ArrayType) | Mode: $($script:Mode) | $(Get-Date -Format 'yyyy-MM-dd HH:mm')</p></div>
<div class="summary">
<div class="stat critical"><div class="num">$($script:Summary.Critical)</div><div class="label">Critical</div></div>
<div class="stat warning"><div class="num">$($script:Summary.Warning)</div><div class="label">Warning</div></div>
<div class="stat info"><div class="num">$($script:Summary.Info)</div><div class="label">Info</div></div>
<div class="stat pass"><div class="num">$($script:Summary.Pass)</div><div class="label">Pass</div></div>
</div>
"@

    if ($script:Environment.Count -gt 0) {
        $html += "<h2>Environment</h2><table class='env-table'>"
        foreach ($key in ($script:Environment.Keys | Sort-Object)) {
            $html += "<tr><td>$(ConvertTo-HtmlSafe $key)</td><td>$(ConvertTo-HtmlSafe "$($script:Environment[$key])")</td></tr>"
        }
        $html += "</table>"
    }

    $html += "<h2>Findings ($($script:Summary.TotalChecks) checks)</h2><table>"
    $html += "<tr><th>Severity</th><th>Category</th><th>Check</th><th>Current</th><th>Expected</th><th>Impact</th><th>Remediation</th></tr>"

    foreach ($f in ($script:Findings | Sort-Object @{Expression={switch($_.Severity){'Critical'{0}'Warning'{1}'Info'{2}'Pass'{3}}}; Ascending=$true})) {
        $html += "<tr><td class='sev-$($f.Severity)'>$($f.Severity)</td><td>$(ConvertTo-HtmlSafe $f.Category)</td><td>$(ConvertTo-HtmlSafe $f.Check)</td><td>$(ConvertTo-HtmlSafe $f.CurrentState)</td><td>$(ConvertTo-HtmlSafe $f.ExpectedState)</td><td>$(ConvertTo-HtmlSafe $f.Impact)</td><td>$(ConvertTo-HtmlSafe $f.Remediation)</td></tr>"
    }
    $html += "</table></body></html>"
    $html | Out-File -FilePath $Path -Encoding UTF8
}

function Export-MarkdownReport {
    param([string]$Path)

    $md = @"
# iSCSI / MPIO Assessment Report

**Host:** $env:COMPUTERNAME
**Array:** $($script:ArrayType) | **Mode:** $($script:Mode) | **Date:** $(Get-Date -Format 'yyyy-MM-dd HH:mm')

## Summary

| Metric | Count |
|--------|-------|
| Critical | $($script:Summary.Critical) |
| Warning | $($script:Summary.Warning) |
| Info | $($script:Summary.Info) |
| Pass | $($script:Summary.Pass) |
| **Total** | **$($script:Summary.TotalChecks)** |

## Findings

| Severity | Category | Check | Current | Expected | Remediation |
|----------|----------|-------|---------|----------|-------------|

"@

    foreach ($f in ($script:Findings | Sort-Object @{Expression={switch($_.Severity){'Critical'{0}'Warning'{1}'Info'{2}'Pass'{3}}}; Ascending=$true})) {
        $md += "| $($f.Severity) | $($f.Category) | $($f.Check) | $($f.CurrentState) | $($f.ExpectedState) | $($f.Remediation) |`n"
    }

    $md | Out-File -FilePath $Path -Encoding UTF8
}

function Write-NinjaOutput {
    if (-not $script:NinjaCustomField -and -not $script:NinjaHTMLField) { return }

    try {
        $summaryText = "iSCSI/MPIO: C=$($script:Summary.Critical) W=$($script:Summary.Warning) P=$($script:Summary.Pass) ($($script:Summary.TotalChecks) checks) [$($script:ArrayType)]"

        if ($script:NinjaCustomField) {
            Ninja-Property-Set $script:NinjaCustomField $summaryText 2>$null
        }
        if ($script:NinjaHTMLField) {
            $htmlPath = Join-Path $env:TEMP 'iSCSIMPIO_ninja.html'
            Export-HtmlReport -Path $htmlPath
            $htmlContent = Get-Content -Path $htmlPath -Raw
            Ninja-Property-Set $script:NinjaHTMLField $htmlContent 2>$null
            Remove-Item -Path $htmlPath -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Log "NinjaRMM output failed: $_" -Level 'DEBUG'
    }
}

# ============================================================================
# ENVIRONMENT DETECTION
# ============================================================================

function Get-AssessmentEnvironment {
    Write-Log 'Collecting environment information...' -Level 'INFO'

    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $script:Environment['ComputerName'] = $env:COMPUTERNAME
    $script:Environment['OSVersion'] = "$($os.Caption) ($($os.Version))"
    $script:Environment['IsAdmin'] = $script:IsAdmin
    $script:Environment['PowerShellVersion'] = $PSVersionTable.PSVersion.ToString()

    # Check Hyper-V
    $hvFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -ErrorAction SilentlyContinue
    if (-not $hvFeature) {
        $hvFeature = Get-WindowsFeature -Name Hyper-V -ErrorAction SilentlyContinue
    }
    $script:Environment['HyperVInstalled'] = if ($hvFeature) { ($hvFeature.State -eq 'Enabled' -or $hvFeature.Installed) } else { $false }

    # Check MPIO feature
    $mpioFeature = Get-WindowsOptionalFeature -Online -FeatureName MultipathIO -ErrorAction SilentlyContinue
    if (-not $mpioFeature) {
        $mpioFeature = Get-WindowsFeature -Name Multipath-IO -ErrorAction SilentlyContinue
    }
    $script:Environment['MPIOInstalled'] = if ($mpioFeature) { ($mpioFeature.State -eq 'Enabled' -or $mpioFeature.Installed) } else { $false }

    # iSCSI Service
    $iscsiSvc = Get-Service -Name MSiSCSI -ErrorAction SilentlyContinue
    $script:Environment['iSCSIServiceStatus'] = if ($iscsiSvc) { "$($iscsiSvc.Status) ($($iscsiSvc.StartType))" } else { 'Not found' }

    # Auto-detect array type
    if ($script:ArrayType -eq 'Auto') {
        $script:ArrayType = Detect-ArrayType
        $script:Environment['ArrayTypeDetected'] = $script:ArrayType
    } else {
        $script:Environment['ArrayTypeSpecified'] = $script:ArrayType
    }

    $script:Environment['AssessmentMode'] = $script:Mode
    $script:Environment['Timestamp'] = Get-Date -Format 'o'
}

function Detect-ArrayType {
    try {
        $targets = Get-IscsiTarget -ErrorAction SilentlyContinue
        if (-not $targets) { return 'Generic' }

        foreach ($target in $targets) {
            $addr = $target.NodeAddress
            if ($addr -match 'msa\b|p2000|2060|2062|sanbloc') { return 'MSA' }
            if ($addr -match 'nimble|nimblestorage|group-') { return 'Nimble' }
        }

    } catch {
        Write-Log "Array auto-detection failed: $_" -Level 'DEBUG'
    }

    return 'Generic'
}

# ============================================================================
# ASSESSMENT: iSCSI INITIATOR
# ============================================================================

function Test-ISCSIConfiguration {
    Write-Log 'Assessing iSCSI Initiator configuration...' -Level 'INFO'
    Write-Host '' -ErrorAction SilentlyContinue

    $bp = Get-BestPractices -Array $script:ArrayType

    # ── iSCSI Service ──
    $svc = Get-Service -Name MSiSCSI -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Finding -Severity 'Critical' -Category 'iSCSI' -Check 'iSCSI Initiator Service exists' `
            -CurrentState 'Service not found' -ExpectedState 'MSiSCSI service present' `
            -Impact 'No iSCSI connectivity possible' -Remediation 'Install iSCSI Initiator feature'
        return
    }

    if ($svc.Status -ne 'Running') {
        Write-Finding -Severity 'Critical' -Category 'iSCSI' -Check 'iSCSI Service running' `
            -CurrentState $svc.Status -ExpectedState 'Running' `
            -Impact 'iSCSI sessions will not reconnect after reboot' `
            -Remediation 'Start-Service MSiSCSI'
    } else {
        Write-Finding -Severity 'Pass' -Category 'iSCSI' -Check 'iSCSI Service running' `
            -CurrentState 'Running'
    }

    if ($svc.StartType -ne 'Automatic') {
        Write-Finding -Severity 'Critical' -Category 'iSCSI' -Check 'iSCSI Service startup type' `
            -CurrentState $svc.StartType -ExpectedState 'Automatic' `
            -Impact 'iSCSI sessions will not reconnect after reboot' `
            -Remediation "Set-Service MSiSCSI -StartupType Automatic"
    } else {
        Write-Finding -Severity 'Pass' -Category 'iSCSI' -Check 'iSCSI Service startup type' `
            -CurrentState 'Automatic'
    }

    # ── Target Portals ──
    $portals = @(Get-IscsiTargetPortal -ErrorAction SilentlyContinue)
    if ($portals.Count -eq 0) {
        Write-Finding -Severity 'Critical' -Category 'iSCSI' -Check 'iSCSI target portals configured' `
            -CurrentState 'No target portals' -ExpectedState '1+ target portals' `
            -Impact 'No iSCSI storage connectivity' `
            -Remediation 'New-IscsiTargetPortal -TargetPortalAddress <SAN_IP>'
        return
    }

    Write-Finding -Severity 'Pass' -Category 'iSCSI' -Check 'iSCSI target portals configured' `
        -CurrentState "$($portals.Count) portal(s)"

    # ── Targets ──
    $targets = @(Get-IscsiTarget -ErrorAction SilentlyContinue)
    $connectedTargets = @($targets | Where-Object { $_.IsConnected })
    $disconnectedTargets = @($targets | Where-Object { -not $_.IsConnected })

    if ($connectedTargets.Count -eq 0) {
        Write-Finding -Severity 'Critical' -Category 'iSCSI' -Check 'Connected iSCSI targets' `
            -CurrentState "0 connected ($($targets.Count) total)" -ExpectedState '1+ connected targets' `
            -Impact 'No iSCSI storage available' `
            -Remediation 'Connect-IscsiTarget -NodeAddress <IQN>'
    } else {
        Write-Finding -Severity 'Pass' -Category 'iSCSI' -Check 'Connected iSCSI targets' `
            -CurrentState "$($connectedTargets.Count) connected"
    }

    if ($disconnectedTargets.Count -gt 0) {
        foreach ($dt in $disconnectedTargets) {
            Write-Finding -Severity 'Warning' -Category 'iSCSI' -Check 'Disconnected target detected' `
                -CurrentState "Target: $($dt.NodeAddress)" -ExpectedState 'All targets connected' `
                -Impact 'Storage on this target is unreachable' `
                -Remediation "Connect-IscsiTarget -NodeAddress '$($dt.NodeAddress)'"
        }
    }

    # ── Sessions ──
    $sessions = @(Get-IscsiSession -ErrorAction SilentlyContinue)
    if ($sessions.Count -eq 0 -and $connectedTargets.Count -gt 0) {
        Write-Finding -Severity 'Critical' -Category 'iSCSI' -Check 'Active iSCSI sessions' `
            -CurrentState '0 sessions' -ExpectedState '1+ sessions' `
            -Impact 'No active storage I/O paths'
    } elseif ($sessions.Count -gt 0) {
        Write-Finding -Severity 'Pass' -Category 'iSCSI' -Check 'Active iSCSI sessions' `
            -CurrentState "$($sessions.Count) session(s)"
    }

    # ── Session Persistence ──
    $nonPersistent = @($sessions | Where-Object { -not $_.IsPersistent })
    if ($nonPersistent.Count -gt 0) {
        Write-Finding -Severity 'Critical' -Category 'iSCSI' -Check 'Session persistence' `
            -CurrentState "$($nonPersistent.Count) non-persistent session(s)" `
            -ExpectedState 'All sessions persistent' `
            -Impact 'Sessions will NOT reconnect after reboot — storage will be missing' `
            -Remediation 'Register-IscsiSession -SessionIdentifier <ID> -IsMultipathEnabled $true -IsPersistent $true'
    } elseif ($sessions.Count -gt 0) {
        Write-Finding -Severity 'Pass' -Category 'iSCSI' -Check 'Session persistence' `
            -CurrentState 'All sessions persistent'
    }

    # ── Persistent Registration vs Active Session Count ──
    if ($sessions.Count -gt 0) {
        $persistentTargets = @(Get-CimInstance -Namespace root/wmi -ClassName MSiSCSIInitiator_PersistentLoginClass -ErrorAction SilentlyContinue)
        if ($persistentTargets.Count -gt $sessions.Count) {
            $staleCount = $persistentTargets.Count - $sessions.Count
            Write-Finding -Severity 'Warning' -Category 'iSCSI' `
                -Check 'Persistent registration count vs active sessions' `
                -CurrentState "$($persistentTargets.Count) persistent registration(s), $($sessions.Count) active session(s) — $staleCount stale" `
                -ExpectedState 'Persistent registration count should match active session count' `
                -Impact 'Stale persistent registrations can cause reconnection attempts to dead paths, slow boot times, and event log noise' `
                -Remediation 'Remove stale registrations: Unregister-IscsiSession or use iSCSI Initiator Properties > Favorite Targets to clean up entries that no longer correspond to active sessions'
        } elseif ($persistentTargets.Count -lt $sessions.Count) {
            $unregistered = $sessions.Count - $persistentTargets.Count
            Write-Finding -Severity 'Warning' -Category 'iSCSI' `
                -Check 'Persistent registration count vs active sessions' `
                -CurrentState "$($persistentTargets.Count) persistent registration(s), $($sessions.Count) active session(s) — $unregistered session(s) not persistent-registered" `
                -ExpectedState 'All active sessions should have a matching persistent registration' `
                -Impact 'Sessions without persistent registrations will not reconnect after reboot' `
                -Remediation 'Register missing sessions: Register-IscsiSession -SessionIdentifier <ID> -IsMultipathEnabled $true -IsPersistent $true'
        } else {
            Write-Finding -Severity 'Pass' -Category 'iSCSI' `
                -Check 'Persistent registration count vs active sessions' `
                -CurrentState "$($persistentTargets.Count) persistent registration(s) match $($sessions.Count) active session(s)"
        }
    }

    # ── Errant Connections (wildcard initiator addresses) ──
    if ($sessions.Count -gt 0 -and $script:Mode -ne 'Quick') {
        $allConnections = @(Get-IscsiConnection -ErrorAction SilentlyContinue)
        $errantConnections = @($allConnections | Where-Object {
            $_.InitiatorAddress -eq '0.0.0.0' -or
            $_.InitiatorAddress -eq '*' -or
            $_.InitiatorAddress -eq '::' -or
            [string]::IsNullOrEmpty($_.InitiatorAddress)
        })
        if ($errantConnections.Count -gt 0) {
            Write-Finding -Severity 'Warning' -Category 'iSCSI' `
                -Check 'Errant iSCSI connections (wildcard initiator)' `
                -CurrentState "$($errantConnections.Count) connection(s) using wildcard initiator address" `
                -ExpectedState 'All connections bound to specific initiator IP addresses' `
                -Impact 'Wildcard connections bypass initiator portal binding and may route iSCSI traffic over unintended NICs' `
                -Remediation 'In iSCSI Initiator Properties, disconnect the errant session and re-add with specific initiator/target IP pairs via Advanced settings' `
                -Reference 'HPE MSA Gen6 Implementation Guide - iSCSI Configuration section'
        } elseif ($allConnections.Count -gt 0) {
            Write-Finding -Severity 'Pass' -Category 'iSCSI' `
                -Check 'iSCSI connection binding' `
                -CurrentState 'All connections use specific initiator addresses'
        }
    }

    # ── Sessions per target (MPIO multi-session) ──
    if ($script:Mode -ne 'Quick' -and $sessions.Count -gt 0) {
        $sessionsByTarget = $sessions | Group-Object -Property TargetNodeAddress
        foreach ($group in $sessionsByTarget) {
            if ($group.Count -lt $bp.MinSessionsPerTarget) {
                $targetShort = ($group.Name -split ':')[-1]
                if ($targetShort.Length -gt 40) { $targetShort = '...' + $targetShort.Substring($targetShort.Length - 37) }
                Write-Finding -Severity 'Warning' -Category 'iSCSI' `
                    -Check "Sessions per target: $targetShort" `
                    -CurrentState "$($group.Count) session(s)" `
                    -ExpectedState "$($bp.MinSessionsPerTarget)+ sessions for MPIO" `
                    -Impact 'Single session = single path. No multipath failover for this target.' `
                    -Remediation 'Add additional iSCSI sessions from different initiator IPs to the same target'
            } else {
                $targetShort = ($group.Name -split ':')[-1]
                if ($targetShort.Length -gt 40) { $targetShort = '...' + $targetShort.Substring($targetShort.Length - 37) }
                Write-Finding -Severity 'Pass' -Category 'iSCSI' `
                    -Check "Sessions per target: $targetShort" `
                    -CurrentState "$($group.Count) session(s)"
            }
        }
    }

    # ── Initiator Portal Binding ──
    if ($script:Mode -eq 'Full') {
        $connections = @(Get-IscsiConnection -ErrorAction SilentlyContinue)
        if ($connections.Count -gt 0) {
            $initiatorIPs = @($connections | Select-Object -ExpandProperty InitiatorAddress -Unique)
            Write-Finding -Severity 'Info' -Category 'iSCSI' -Check 'Initiator IP addresses in use' `
                -CurrentState ($initiatorIPs -join ', ') `
                -ExpectedState 'Should use dedicated iSCSI NICs only'

            # Check for connection diversity
            if ($initiatorIPs.Count -lt 2 -and $sessions.Count -gt 1) {
                Write-Finding -Severity 'Warning' -Category 'iSCSI' `
                    -Check 'Initiator IP diversity' `
                    -CurrentState "All sessions from $($initiatorIPs[0])" `
                    -ExpectedState 'Sessions spread across 2+ initiator IPs' `
                    -Impact 'Single NIC failure will drop all sessions' `
                    -Remediation 'Configure sessions from multiple initiator portal IPs'
            }

            # Check subnet separation (iSCSI subnets A and B should be on different networks)
            if ($initiatorIPs.Count -ge 2) {
                $subnets = @($initiatorIPs | ForEach-Object {
                    $octets = $_ -split '\.'
                    if ($octets.Count -eq 4) { "$($octets[0]).$($octets[1]).$($octets[2])" }
                })
                $uniqueSubnets = @($subnets | Select-Object -Unique)
                if ($uniqueSubnets.Count -lt 2) {
                    Write-Finding -Severity 'Warning' -Category 'iSCSI' `
                        -Check 'iSCSI subnet separation' `
                        -CurrentState "All initiator IPs on same subnet ($($uniqueSubnets[0]).*)" `
                        -ExpectedState 'iSCSI Subnet A and Subnet B on separate physical networks' `
                        -Impact 'Both iSCSI fabrics share a single network — a switch failure takes down all paths' `
                        -Remediation 'Deploy iSCSI initiator ports on separate physical networks (e.g., 10.10.1.x and 10.10.2.x)' `
                        -Reference 'HPE MSA Gen6 Implementation Guide - MPIO Configuration section'
                } else {
                    Write-Finding -Severity 'Pass' -Category 'iSCSI' `
                        -Check 'iSCSI subnet separation' `
                        -CurrentState "Initiator IPs span $($uniqueSubnets.Count) subnet(s)"
                }
            }
        }

        # ── Digest Settings ──
        $digestSessions = @($sessions | Where-Object { $_.IsDataDigest -or $_.IsHeaderDigest })
        if ($digestSessions.Count -gt 0) {
            Write-Finding -Severity 'Info' -Category 'iSCSI' `
                -Check 'iSCSI Digest (CRC) enabled' `
                -CurrentState "$($digestSessions.Count) session(s) with digest" `
                -ExpectedState 'Disabled unless required by array' `
                -Impact 'Digests add CPU overhead (~5-10%) for CRC verification on every PDU'
        }
    }
}

# ============================================================================
# ASSESSMENT: MPIO
# ============================================================================

function Test-MPIOConfiguration {
    Write-Log 'Assessing MPIO configuration...' -Level 'INFO'
    Write-Host '' -ErrorAction SilentlyContinue

    $bp = Get-BestPractices -Array $script:ArrayType

    # ── MPIO Feature ──
    if (-not $script:Environment['MPIOInstalled']) {
        Write-Finding -Severity 'Critical' -Category 'MPIO' -Check 'MPIO feature installed' `
            -CurrentState 'Not installed' -ExpectedState 'Installed' `
            -Impact 'No multipath I/O — single path failure = storage offline' `
            -Remediation 'Enable-WindowsOptionalFeature -Online -FeatureName MultipathIO (requires reboot)'
        return
    }

    Write-Finding -Severity 'Pass' -Category 'MPIO' -Check 'MPIO feature installed' `
        -CurrentState 'Installed'

    # ── MPIO Settings ──
    try {
        $mpioSettings = Get-MPIOSetting
    } catch {
        Write-Finding -Severity 'Critical' -Category 'MPIO' -Check 'MPIO settings accessible' `
            -CurrentState "Error: $_" -Impact 'Cannot validate MPIO configuration'
        return
    }

    # Path Verification State
    if ($mpioSettings.PathVerificationState -ne $bp.PathVerificationState) {
        Write-Finding -Severity 'Critical' -Category 'MPIO' -Check 'Path verification state' `
            -CurrentState $mpioSettings.PathVerificationState `
            -ExpectedState $bp.PathVerificationState `
            -Impact 'Dead paths only detected when live I/O fails — causes VM I/O errors during failover' `
            -Remediation "Set-MPIOSetting -NewPathVerificationState $($bp.PathVerificationState) (requires reboot)"
    } else {
        Write-Finding -Severity 'Pass' -Category 'MPIO' -Check 'Path verification state' `
            -CurrentState $mpioSettings.PathVerificationState
    }

    # Path Verification Period
    if ([int]$mpioSettings.PathVerificationPeriod -gt $bp.PathVerificationPeriod) {
        Write-Finding -Severity 'Warning' -Category 'MPIO' -Check 'Path verification period' `
            -CurrentState "$($mpioSettings.PathVerificationPeriod)s" `
            -ExpectedState "$($bp.PathVerificationPeriod)s or less" `
            -Impact "Dead path detection delayed by $($mpioSettings.PathVerificationPeriod) seconds" `
            -Remediation "Set-MPIOSetting -NewPathVerificationPeriod $($bp.PathVerificationPeriod) (requires reboot)"
    } else {
        Write-Finding -Severity 'Pass' -Category 'MPIO' -Check 'Path verification period' `
            -CurrentState "$($mpioSettings.PathVerificationPeriod)s"
    }

    # Retry Count
    if ([int]$mpioSettings.RetryCount -lt $bp.RetryCount) {
        Write-Finding -Severity 'Warning' -Category 'MPIO' -Check 'Retry count' `
            -CurrentState $mpioSettings.RetryCount -ExpectedState "$($bp.RetryCount)+" `
            -Impact 'Premature path failure declaration — iSCSI needs more retries than FC' `
            -Remediation "Set-MPIOSetting -NewRetryCount $($bp.RetryCount) (requires reboot)"
    } else {
        Write-Finding -Severity 'Pass' -Category 'MPIO' -Check 'Retry count' `
            -CurrentState $mpioSettings.RetryCount
    }

    # Retry Interval
    if ([int]$mpioSettings.RetryInterval -lt $bp.RetryInterval) {
        Write-Finding -Severity 'Warning' -Category 'MPIO' -Check 'Retry interval' `
            -CurrentState "$($mpioSettings.RetryInterval)s" -ExpectedState "$($bp.RetryInterval)s+" `
            -Impact 'Retries too fast may not allow transient network issues to clear' `
            -Remediation "Set-MPIOSetting -NewRetryInterval $($bp.RetryInterval) (requires reboot)"
    } else {
        Write-Finding -Severity 'Pass' -Category 'MPIO' -Check 'Retry interval' `
            -CurrentState "$($mpioSettings.RetryInterval)s"
    }

    # Disk Timeout
    if ([int]$mpioSettings.DiskTimeoutValue -lt $bp.DiskTimeoutValue) {
        Write-Finding -Severity 'Warning' -Category 'MPIO' -Check 'Disk timeout value' `
            -CurrentState "$($mpioSettings.DiskTimeoutValue)s" `
            -ExpectedState "$($bp.DiskTimeoutValue)s+" `
            -Impact 'OS may abandon disk I/O before MPIO finishes failover attempt' `
            -Remediation "Set-MPIOSetting -NewDiskTimeout $($bp.DiskTimeoutValue) (requires reboot)"
    } else {
        Write-Finding -Severity 'Pass' -Category 'MPIO' -Check 'Disk timeout value' `
            -CurrentState "$($mpioSettings.DiskTimeoutValue)s"
    }

    # Custom Path Recovery
    if ($mpioSettings.UseCustomPathRecoveryTime -ne $bp.UseCustomPathRecoveryTime) {
        Write-Finding -Severity 'Warning' -Category 'MPIO' -Check 'Custom path recovery time' `
            -CurrentState $mpioSettings.UseCustomPathRecoveryTime `
            -ExpectedState $bp.UseCustomPathRecoveryTime `
            -Impact 'Recovered paths may not be added back promptly' `
            -Remediation "Set-MPIOSetting -CustomPathRecovery $($bp.UseCustomPathRecoveryTime) -NewCustomPathRecoveryTime $($bp.CustomPathRecoveryTime) (requires reboot)"
    } else {
        Write-Finding -Severity 'Pass' -Category 'MPIO' -Check 'Custom path recovery time' `
            -CurrentState "$($mpioSettings.UseCustomPathRecoveryTime) ($($mpioSettings.CustomPathRecoveryTime)s)"
    }

    # PDO Remove Period (scale recommendation based on volume count)
    if ($script:Mode -eq 'Full') {
        $pdoValue = [int]$mpioSettings.PDORemovePeriod
        $mpioCountOutput = mpclaim -s -d 2>$null
        $diskCount = @($mpioCountOutput | Where-Object { $_ -match 'MPIO Disk' }).Count

        if ($pdoValue -lt 20) {
            Write-Finding -Severity 'Warning' -Category 'MPIO' -Check 'PDO remove period' `
                -CurrentState "$($pdoValue)s (below minimum)" `
                -ExpectedState '20s minimum' `
                -Impact 'Disk device objects removed too quickly during transient failures — pending I/O failed to applications' `
                -Remediation 'Set HKLM:\SYSTEM\CurrentControlSet\Services\mpio\Parameters\PDORemovePeriod to at least 20' `
                -Reference 'HPE MSA Gen6 Implementation Guide - MPIO Failover Tuning section'
        } elseif ($diskCount -gt 10 -and $pdoValue -le 20) {
            Write-Finding -Severity 'Warning' -Category 'MPIO' -Check 'PDO remove period (high volume count)' `
                -CurrentState "$($pdoValue)s with $diskCount MPIO disks" `
                -ExpectedState 'Increase PDORemovePeriod for environments with many volumes' `
                -Impact "Default 20s may be insufficient with $diskCount volumes — MPIO may fail I/O to applications before recovering paths" `
                -Remediation "Set HKLM:\SYSTEM\CurrentControlSet\Services\mpio\Parameters\PDORemovePeriod to 60+ for $diskCount disk environments" `
                -Reference 'HPE MSA Gen6 Implementation Guide - MPIO Failover Tuning section'
        } else {
            Write-Finding -Severity 'Pass' -Category 'MPIO' -Check 'PDO remove period' `
                -CurrentState "$($pdoValue)s ($diskCount MPIO disk(s))"
        }
    }

    # ── Supported Hardware List ──
    $supportedHW = @(Get-MSDSMSupportedHW -ErrorAction SilentlyContinue)
    $hasISCSI = $supportedHW | Where-Object { $_.VendorId -match 'MSFT' -and $_.ProductId -match 'iSCSI' }
    if (-not $hasISCSI) {
        Write-Finding -Severity 'Critical' -Category 'MPIO' -Check 'iSCSI in MPIO supported hardware' `
            -CurrentState 'iSCSI devices not claimed by MPIO' `
            -ExpectedState 'MSFT2005iSCSIBusType_0x9 in supported HW list' `
            -Impact 'iSCSI disks will not use multipath — no failover' `
            -Remediation 'New-MSDSMSupportedHW -VendorId MSFT2005 -ProductId iSCSIBusType_0x9'
    } else {
        Write-Finding -Severity 'Pass' -Category 'MPIO' -Check 'iSCSI in MPIO supported hardware' `
            -CurrentState 'iSCSI devices claimed by MPIO'
    }

    # ── Array-Specific Hardware Claim (MSA) ──
    if ($script:ArrayType -eq 'MSA') {
        $msaBP = Get-BestPractices -Array 'MSA'
        $msaHW = $supportedHW | Where-Object {
            $_.VendorId -match $msaBP.MSAVendorId -and $_.ProductId -match $msaBP.MSAProductId
        }
        if (-not $msaHW) {
            Write-Finding -Severity 'Warning' -Category 'MPIO' `
                -Check 'HPE MSA device claim in MPIO' `
                -CurrentState 'HPE MSA not found in MPIO supported hardware list' `
                -ExpectedState "Vendor=$($msaBP.MSAVendorId), Product=$($msaBP.MSAProductId) in supported HW" `
                -Impact 'MSA volumes may not be using the HPE-specific DSM — suboptimal failover and load balancing' `
                -Remediation "mpclaim -n -I -d `"HPE     MSA 2060`" (note: 5 spaces between HPE and MSA, reboot required)" `
                -Reference $msaBP.ArrayReference
        } else {
            Write-Finding -Severity 'Pass' -Category 'MPIO' `
                -Check 'HPE MSA device claim in MPIO' `
                -CurrentState 'HPE MSA found in supported HW list'
        }
    }

    # ── Global Load Balance Policy ──
    $globalLB = Get-MSDSMGlobalDefaultLoadBalancePolicy -ErrorAction SilentlyContinue

    if ($script:Mode -ne 'Quick') {
        if ($globalLB -eq 'None') {
            Write-Finding -Severity 'Info' -Category 'MPIO' -Check 'Global default LB policy' `
                -CurrentState 'None (per-disk overrides only)' `
                -ExpectedState "Set globally unless per-disk is intentional" `
                -Impact 'New disks will not have a load balance policy until manually set'
        } else {
            Write-Finding -Severity 'Pass' -Category 'MPIO' -Check 'Global default LB policy' `
                -CurrentState $globalLB
        }
    }

    # ── Array-Specific Notes ──
    if ($script:Mode -ne 'Quick') {
        $notes = (Get-BestPractices -Array $script:ArrayType).ArrayNotes
        if ($notes) {
            Write-Finding -Severity 'Info' -Category 'MPIO' -Check 'Array-specific guidance' `
                -CurrentState $notes
        }
    }
}

# ============================================================================
# ASSESSMENT: NETWORK
# ============================================================================

function Test-NetworkConfiguration {
    Write-Log 'Assessing network configuration...' -Level 'INFO'
    Write-Host '' -ErrorAction SilentlyContinue

    $bp = Get-BestPractices -Array $script:ArrayType

    $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -or $_.Status -eq 'Disconnected' })
    if ($adapters.Count -eq 0) {
        Write-Finding -Severity 'Warning' -Category 'Network' -Check 'Network adapters found' `
            -CurrentState 'No adapters detected'
        return
    }

    # ── Jumbo Frame Consistency ──
    $jumboSettings = @(Get-NetAdapterAdvancedProperty -DisplayName '*Jumbo*' -ErrorAction SilentlyContinue)
    if ($jumboSettings.Count -gt 0) {
        $jumboValues = $jumboSettings | Select-Object Name, DisplayValue
        $uniqueValues = @($jumboValues | Select-Object -ExpandProperty DisplayValue -Unique)

        if ($uniqueValues.Count -gt 1) {
            $detail = ($jumboValues | ForEach-Object { "$($_.Name)=$($_.DisplayValue)" }) -join '; '
            Write-Finding -Severity 'Warning' -Category 'Network' -Check 'Jumbo frame consistency' `
                -CurrentState "Mixed MTU: $detail" `
                -ExpectedState 'All iSCSI NICs same MTU' `
                -Impact 'MTU mismatch can cause silent packet drops and iSCSI session failures' `
                -Remediation 'Set all iSCSI NICs, switch ports, and array ports to the same MTU (either all 9014 or all 1500)'
        } else {
            Write-Finding -Severity 'Pass' -Category 'Network' -Check 'Jumbo frame consistency' `
                -CurrentState "All NICs: $($uniqueValues[0])"
        }
    } else {
        Write-Finding -Severity 'Info' -Category 'Network' -Check 'Jumbo frame settings' `
            -CurrentState 'No jumbo frame settings found (likely all standard MTU 1500)' `
            -ExpectedState 'Verify end-to-end MTU matches array configuration'
    }

    # ── NIC Power Management ──
    foreach ($adapter in $adapters) {
        try {
            $pm = Get-NetAdapterPowerManagement -Name $adapter.Name -ErrorAction SilentlyContinue
            if ($pm -and $pm.AllowComputerToTurnOffDevice -notin @('Disabled', 'Unsupported')) {
                Write-Finding -Severity 'Warning' -Category 'Network' `
                    -Check "NIC power management: $($adapter.Name)" `
                    -CurrentState "AllowTurnOff=$($pm.AllowComputerToTurnOffDevice)" `
                    -ExpectedState 'Disabled' `
                    -Impact 'OS may power down NIC during idle — drops iSCSI sessions' `
                    -Remediation "Disable-NetAdapterPowerManagement -Name '$($adapter.Name)' or disable in Device Manager"
            } elseif ($pm -and $pm.AllowComputerToTurnOffDevice -eq 'Disabled') {
                Write-Finding -Severity 'Pass' -Category 'Network' `
                    -Check "NIC power management: $($adapter.Name)" `
                    -CurrentState 'Disabled (good)'
            }
        } catch {
            # Some virtual adapters don't support power management queries
        }
    }

    # ── VMQ on iSCSI NICs ──
    if ($script:Mode -ne 'Quick') {
        $iscsiConnections = @(Get-IscsiConnection -ErrorAction SilentlyContinue)
        if ($iscsiConnections.Count -gt 0) {
            $iscsiIPs = @($iscsiConnections | Select-Object -ExpandProperty InitiatorAddress -Unique)

            foreach ($ip in $iscsiIPs) {
                # Find the NIC that owns this IP
                $ipConfig = Get-NetIPAddress -IPAddress $ip -ErrorAction SilentlyContinue
                if ($ipConfig) {
                    $nicName = (Get-NetAdapter -InterfaceIndex $ipConfig.InterfaceIndex -ErrorAction SilentlyContinue).Name
                    if ($nicName) {
                        $vmq = Get-NetAdapterVmq -Name $nicName -ErrorAction SilentlyContinue
                        if ($vmq -and $vmq.Enabled) {
                            Write-Finding -Severity 'Warning' -Category 'Network' `
                                -Check "VMQ on iSCSI NIC: $nicName" `
                                -CurrentState "VMQ Enabled" `
                                -ExpectedState 'VMQ Disabled on iSCSI-dedicated NICs' `
                                -Impact 'VMQ can cause packet processing delays on iSCSI traffic' `
                                -Remediation "Set-NetAdapterVmq -Name '$nicName' -Enabled `$false"
                        } elseif ($vmq) {
                            Write-Finding -Severity 'Pass' -Category 'Network' `
                                -Check "VMQ on iSCSI NIC: $nicName" `
                                -CurrentState 'Disabled'
                        }
                    }
                }
            }
        }
    }

    # ── NIC Error Statistics ──
    if ($script:Mode -ne 'Quick') {
        $stats = @(Get-NetAdapterStatistics -ErrorAction SilentlyContinue)
        foreach ($stat in $stats) {
            $hardErrors = [long]$stat.ReceivedPacketErrors + [long]$stat.OutboundPacketErrors
            $discards = [long]$stat.ReceivedDiscardedPackets + [long]$stat.OutboundDiscardedPackets

            if ($hardErrors -gt 0) {
                Write-Finding -Severity 'Warning' -Category 'Network' `
                    -Check "NIC errors: $($stat.Name)" `
                    -CurrentState "RxErr=$($stat.ReceivedPacketErrors) TxErr=$($stat.OutboundPacketErrors) RxDiscard=$($stat.ReceivedDiscardedPackets) TxDiscard=$($stat.OutboundDiscardedPackets)" `
                    -ExpectedState 'Zero packet errors' `
                    -Impact 'Packet errors indicate physical layer issues (cable, port, NIC)' `
                    -Remediation 'Check cables, switch port counters, and NIC driver version'
            } elseif ($discards -gt 1000) {
                Write-Finding -Severity 'Warning' -Category 'Network' `
                    -Check "NIC discards: $($stat.Name)" `
                    -CurrentState "RxDiscard=$($stat.ReceivedDiscardedPackets) TxDiscard=$($stat.OutboundDiscardedPackets)" `
                    -ExpectedState 'Minimal discards (< 1000)' `
                    -Impact 'High discard count may indicate buffer overruns, flow control issues, or MTU mismatch' `
                    -Remediation 'Check switch flow control settings, NIC ring buffer size, and MTU consistency'
            } elseif ($discards -gt 0) {
                Write-Finding -Severity 'Info' -Category 'Network' `
                    -Check "NIC discards: $($stat.Name)" `
                    -CurrentState "RxDiscard=$($stat.ReceivedDiscardedPackets) TxDiscard=$($stat.OutboundDiscardedPackets)" `
                    -ExpectedState 'Low discards are often normal — monitor for growth'
            } elseif ($script:Mode -eq 'Full') {
                Write-Finding -Severity 'Pass' -Category 'Network' `
                    -Check "NIC errors: $($stat.Name)" `
                    -CurrentState 'No errors or discards'
            }
        }
    }

    # ── Disconnected NICs ──
    $downAdapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Disconnected' })
    foreach ($da in $downAdapters) {
        Write-Finding -Severity 'Warning' -Category 'Network' `
            -Check "NIC link down: $($da.Name)" `
            -CurrentState "Status=Disconnected ($($da.InterfaceDescription))" `
            -ExpectedState 'Up' `
            -Impact 'If this is an iSCSI NIC, paths through it are unavailable' `
            -Remediation 'Check cable, switch port, and NIC hardware'
    }

    # ── NIC Driver Age ──
    if ($script:Mode -eq 'Full') {
        foreach ($adapter in $adapters) {
            if ($adapter.DriverDate) {
                $driverDateTime = [DateTime]$adapter.DriverDate
                $driverAge = (Get-Date) - $driverDateTime
                if ($driverAge.TotalDays -gt 730) {
                    Write-Finding -Severity 'Info' -Category 'Network' `
                        -Check "NIC driver age: $($adapter.Name)" `
                        -CurrentState "Driver dated $($driverDateTime.ToString('yyyy-MM-dd')) ($([math]::Round($driverAge.TotalDays / 365, 1)) years old)" `
                        -ExpectedState 'Within 2 years' `
                        -Impact 'Old drivers may have known bugs or missing fixes' `
                        -Remediation 'Update NIC driver from vendor (HP SPP, Intel, Broadcom)'
                }
            }
        }
    }
}

# ============================================================================
# ASSESSMENT: PATHS
# ============================================================================

function Test-PathConfiguration {
    Write-Log 'Assessing MPIO path configuration...' -Level 'INFO'
    Write-Host '' -ErrorAction SilentlyContinue

    $bp = Get-BestPractices -Array $script:ArrayType

    # ── Get MPIO Disks ──
    $mpioOutput = mpclaim -s -d 2>&1 | Out-String
    $diskMatches = [regex]::Matches($mpioOutput, 'MPIO Disk(\d+)\s+Disk \d+\s+(\S+)\s+(.+)')

    if ($diskMatches.Count -eq 0) {
        Write-Finding -Severity 'Warning' -Category 'Paths' -Check 'MPIO disks detected' `
            -CurrentState 'No MPIO disks found' `
            -ExpectedState '1+ MPIO disks' `
            -Impact 'Either no multipath disks or MPIO not claiming iSCSI devices' `
            -Remediation 'Verify iSCSI devices are in MPIO supported hardware list'
        return
    }

    Write-Finding -Severity 'Pass' -Category 'Paths' -Check 'MPIO disks detected' `
        -CurrentState "$($diskMatches.Count) MPIO disk(s)"

    # ── Per-Disk Analysis ──
    foreach ($match in $diskMatches) {
        $diskNum = $match.Groups[1].Value
        $lbPolicy = $match.Groups[2].Value.Trim()
        $dsm = $match.Groups[3].Value.Trim()
        $diskLabel = "MPIO Disk$diskNum"

        # Get path detail for this disk
        $diskDetail = mpclaim -s -d $diskNum 2>&1 | Out-String

        # Count paths
        $pathLines = @($diskDetail -split "`n" | Where-Object { $_ -match '^\s+\w+' -and $_ -notmatch 'MPIO Disk|State|------' -and $_ -match '(Active|Standby|Failed|Unavailable)' })
        $totalPaths = $pathLines.Count
        $activePaths = @($pathLines | Where-Object { $_ -match '\bActive\b' }).Count
        $failedPaths = @($pathLines | Where-Object { $_ -match '\b(Failed|Unavailable)\b' }).Count

        # Path count check
        if ($totalPaths -lt $bp.MinPathsPerDisk) {
            Write-Finding -Severity 'Critical' -Category 'Paths' `
                -Check "Path count: $diskLabel" `
                -CurrentState "$totalPaths path(s) (Active=$activePaths, Failed=$failedPaths)" `
                -ExpectedState "$($bp.MinPathsPerDisk)+ paths" `
                -Impact 'Insufficient paths for failover — disk will go offline if current path fails' `
                -Remediation "Add iSCSI sessions from additional initiator portals to create more paths"
        } elseif ($totalPaths -lt $bp.RecommendedPathsPerDisk) {
            Write-Finding -Severity 'Warning' -Category 'Paths' `
                -Check "Path count: $diskLabel" `
                -CurrentState "$totalPaths path(s) (Active=$activePaths)" `
                -ExpectedState "$($bp.RecommendedPathsPerDisk) paths recommended" `
                -Impact 'Fewer paths than recommended — reduced redundancy and performance' `
                -Remediation "Add sessions for $($bp.RecommendedPathsPerDisk - $totalPaths) more path(s)"
        } else {
            Write-Finding -Severity 'Pass' -Category 'Paths' `
                -Check "Path count: $diskLabel" `
                -CurrentState "$totalPaths path(s) (Active=$activePaths)"
        }

        # Failed paths check
        if ($failedPaths -gt 0) {
            Write-Finding -Severity 'Critical' -Category 'Paths' `
                -Check "Failed paths: $diskLabel" `
                -CurrentState "$failedPaths failed path(s)" `
                -ExpectedState '0 failed paths' `
                -Impact 'Degraded multipath — reduced redundancy and potential I/O latency' `
                -Remediation 'Check iSCSI sessions, NIC status, switch ports, and array controller status'
        }

        # Load balance policy check
        $expectedLB = switch ($bp.LoadBalancePolicy) {
            'RR'  { @('RR', 'RRWS') }
            'LQD' { @('LQD') }
            default { @('RR', 'RRWS', 'LQD') }
        }

        if ($lbPolicy -notin $expectedLB) {
            Write-Finding -Severity 'Warning' -Category 'Paths' `
                -Check "Load balance policy: $diskLabel" `
                -CurrentState $lbPolicy `
                -ExpectedState ($expectedLB -join ' or ') `
                -Impact 'Suboptimal I/O distribution across paths' `
                -Remediation "Set-MSDSMGlobalDefaultLoadBalancePolicy -Policy $($bp.LoadBalancePolicy)"
        } else {
            Write-Finding -Severity 'Pass' -Category 'Paths' `
                -Check "Load balance policy: $diskLabel" `
                -CurrentState $lbPolicy
        }

        # Excessive path count check
        if ($totalPaths -gt $bp.MaxPathsPerDisk) {
            Write-Finding -Severity 'Warning' -Category 'Paths' `
                -Check "Excessive paths: $diskLabel" `
                -CurrentState "$totalPaths paths" `
                -ExpectedState "$($bp.MaxPathsPerDisk) or fewer paths per disk" `
                -Impact 'Excessive paths slow MPIO failover — each path must be evaluated during path recovery' `
                -Remediation "Reduce to $($bp.MaxPathsPerDisk) or fewer paths by limiting iSCSI sessions per target" `
                -Reference 'HPE MSA Gen6 Implementation Guide - MPIO Configuration section'
        }
    }

    # ── Partition Style Check (GPT vs MBR) ──
    if ($script:Mode -ne 'Quick') {
        $iscsiDisks = @(Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.BusType -eq 'iSCSI' })
        foreach ($disk in $iscsiDisks) {
            if ($disk.PartitionStyle -eq 'MBR') {
                Write-Finding -Severity 'Warning' -Category 'Paths' `
                    -Check "Partition style: Disk $($disk.Number) ($($disk.FriendlyName))" `
                    -CurrentState 'MBR' -ExpectedState 'GPT' `
                    -Impact 'MBR lacks advanced features, imposes 2 TB capacity limit, and does not support modern volume management' `
                    -Remediation 'Convert to GPT (requires offline conversion or provisioning a new volume)' `
                    -Reference 'HPE MSA Gen6 Implementation Guide - Configuring Hyper-V Storage section'
            } elseif ($disk.PartitionStyle -eq 'GPT' -and $script:Mode -eq 'Full') {
                Write-Finding -Severity 'Pass' -Category 'Paths' `
                    -Check "Partition style: Disk $($disk.Number)" `
                    -CurrentState 'GPT'
            }
        }
    }

    # ── All-Disk Summary ──
    if ($script:Mode -ne 'Quick') {
        $totalDisks = $diskMatches.Count
        Write-Finding -Severity 'Info' -Category 'Paths' `
            -Check 'MPIO disk inventory' `
            -CurrentState "$totalDisks MPIO disk(s) under management"
    }
}

# ============================================================================
# ASSESSMENT: PERFORMANCE
# ============================================================================

function Test-PerformanceConfiguration {
    if ($script:Mode -ne 'Full') { return }

    Write-Log 'Assessing performance configuration...' -Level 'INFO'
    Write-Host '' -ErrorAction SilentlyContinue

    # ── iSCSI Timeout Settings (registry) ──
    try {
        $iscsiParams = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e97b-e325-11ce-bfc1-08002be10318}\*' -Name '*' -ErrorAction SilentlyContinue |
            Where-Object { $_.DriverDesc -like '*iSCSI*' }

        if ($iscsiParams) {
            $linkDownTime = $iscsiParams | ForEach-Object {
                $val = $_ | Select-Object -ExpandProperty 'LinkDownTime' -ErrorAction SilentlyContinue
                if ($val) { $val }
            } | Select-Object -First 1

            if ($linkDownTime -and [int]$linkDownTime -lt 30) {
                Write-Finding -Severity 'Info' -Category 'Performance' `
                    -Check 'iSCSI LinkDownTime' `
                    -CurrentState "${linkDownTime}s" `
                    -ExpectedState '30s+' `
                    -Impact 'Short link-down time may cause premature session drops during transient issues'
            }
        }
    } catch {
        Write-Log "Registry check for iSCSI params skipped: $_" -Level 'DEBUG'
    }

    # ── Disk Timeout vs MPIO Timeout ──
    try {
        $mpioSettings = Get-MPIOSetting
        $totalRetryTime = [int]$mpioSettings.RetryCount * [int]$mpioSettings.RetryInterval
        $diskTimeout = [int]$mpioSettings.DiskTimeoutValue

        if ($diskTimeout -lt ($totalRetryTime * 2)) {
            Write-Finding -Severity 'Warning' -Category 'Performance' `
                -Check 'Disk timeout vs MPIO retry window' `
                -CurrentState "DiskTimeout=${diskTimeout}s, TotalRetryWindow=${totalRetryTime}s ($($mpioSettings.RetryCount) x $($mpioSettings.RetryInterval)s)" `
                -ExpectedState "DiskTimeout should be >= 2x total retry window (>= $($totalRetryTime * 2)s)" `
                -Impact 'OS may time out the disk before MPIO completes all failover retries' `
                -Remediation "Set-MPIOSetting -NewDiskTimeout $([math]::Max($diskTimeout, $totalRetryTime * 3))"
        } else {
            Write-Finding -Severity 'Pass' -Category 'Performance' `
                -Check 'Disk timeout vs MPIO retry window' `
                -CurrentState "DiskTimeout=${diskTimeout}s >> RetryWindow=${totalRetryTime}s"
        }
    } catch {
        Write-Log "Disk timeout check skipped: $_" -Level 'DEBUG'
    }

    # ── VMMQ/RSS on iSCSI NICs ──
    $iscsiConnections = @(Get-IscsiConnection -ErrorAction SilentlyContinue)
    $iscsiIPs = @($iscsiConnections | Select-Object -ExpandProperty InitiatorAddress -Unique)

    foreach ($ip in $iscsiIPs) {
        $ipConfig = Get-NetIPAddress -IPAddress $ip -ErrorAction SilentlyContinue
        if ($ipConfig) {
            $nicName = (Get-NetAdapter -InterfaceIndex $ipConfig.InterfaceIndex -ErrorAction SilentlyContinue).Name
            if ($nicName) {
                $rss = Get-NetAdapterRss -Name $nicName -ErrorAction SilentlyContinue
                if ($rss -and $rss.Enabled) {
                    Write-Finding -Severity 'Info' -Category 'Performance' `
                        -Check "RSS on iSCSI NIC: $nicName" `
                        -CurrentState "RSS Enabled (Queues: $($rss.NumberOfReceiveQueues))" `
                        -ExpectedState 'RSS enabled is fine for iSCSI NICs (improves throughput)' `
                        -Reference 'RSS on dedicated iSCSI NICs is acceptable and can improve performance'
                }
            }
        }
    }
}

# ============================================================================
# ASSESSMENT: HYPER-V STORAGE
# ============================================================================

function Test-HyperVStorageConfiguration {
    if (-not $script:Environment['HyperVInstalled']) { return }
    if ($script:Mode -eq 'Quick') { return }

    Write-Log 'Assessing Hyper-V storage configuration...' -Level 'INFO'
    Write-Host '' -ErrorAction SilentlyContinue

    try {
        $vms = @(Get-VM -ErrorAction Stop)
    } catch {
        Write-Log "Hyper-V VM enumeration skipped: $_ (requires Hyper-V module and admin)" -Level 'DEBUG'
        return
    }

    if ($vms.Count -eq 0) {
        Write-Finding -Severity 'Info' -Category 'Performance' `
            -Check 'Hyper-V VM inventory' `
            -CurrentState 'No VMs found on this host'
        return
    }

    Write-Finding -Severity 'Info' -Category 'Performance' `
        -Check 'Hyper-V VM inventory' `
        -CurrentState "$($vms.Count) VM(s) on this host"

    $vhdCount = 0
    $passThroughCount = 0
    $vfcVMs = @()

    foreach ($vm in $vms) {
        $hardDrives = @(Get-VMHardDiskDrive -VMName $vm.Name -ErrorAction SilentlyContinue)

        foreach ($drive in $hardDrives) {
            # VHD (non-VHDx) format detection
            if ($drive.Path -and $drive.Path -match '\.vhd$') {
                $vhdCount++
                Write-Finding -Severity 'Warning' -Category 'Performance' `
                    -Check "Legacy VHD format: $($vm.Name)" `
                    -CurrentState "VHD file: $(Split-Path $drive.Path -Leaf)" `
                    -ExpectedState 'VHDx format (not VHD)' `
                    -Impact 'VHD format introduces non-aligned I/O causing significant performance degradation on modern storage arrays' `
                    -Remediation "Convert-VHD -Path '$($drive.Path)' -DestinationPath '<new_path>.vhdx' (VM must be stopped)" `
                    -Reference 'HPE MSA Gen6 Implementation Guide - Configuring Hyper-V Storage section'
            }

            # Pass-through disk detection
            if ($null -ne $drive.DiskNumber) {
                $passThroughCount++
                Write-Finding -Severity 'Warning' -Category 'Performance' `
                    -Check "Pass-through disk: $($vm.Name)" `
                    -CurrentState "Physical Disk $($drive.DiskNumber) mapped directly to VM" `
                    -ExpectedState 'VHDx-based storage' `
                    -Impact 'Pass-through disks complicate WFC management, hinder troubleshooting, and obfuscate volume-to-VM mapping. Performance gain over Fixed VHDx is negligible.' `
                    -Remediation 'Replace with Fixed VHDx for equivalent performance with better manageability' `
                    -Reference 'HPE MSA Gen6 Implementation Guide - Additional Storage Methods section'
            }
        }

        # Virtual Fibre Channel detection (Full mode)
        if ($script:Mode -eq 'Full') {
            $vfcAdapters = @(Get-VMFibreChannelHba -VMName $vm.Name -ErrorAction SilentlyContinue)
            if ($vfcAdapters.Count -gt 0) {
                $vfcVMs += $vm.Name
                foreach ($vfc in $vfcAdapters) {
                    $setAEmpty = -not $vfc.WorldWidePortNameSetA -or $vfc.WorldWidePortNameSetA -eq '0000000000000000'
                    $setBEmpty = -not $vfc.WorldWidePortNameSetB -or $vfc.WorldWidePortNameSetB -eq '0000000000000000'

                    if ($setAEmpty -or $setBEmpty) {
                        Write-Finding -Severity 'Warning' -Category 'Performance' `
                            -Check "vFC WWPN sets: $($vm.Name) ($($vfc.SanName))" `
                            -CurrentState "SetA=$(if($setAEmpty){'Missing'}else{'OK'}) SetB=$(if($setBEmpty){'Missing'}else{'OK'})" `
                            -ExpectedState 'Both Set A and Set B WWPNs populated' `
                            -Impact 'Live Migration requires both WWPN sets - missing sets will cause VM migration failure' `
                            -Remediation 'Verify vFC adapter config; ensure both Set A and Set B WWPNs are zoned in FC switches and added to MSA host groups' `
                            -Reference 'HPE MSA Gen6 Implementation Guide - How Live Migration Uses WWPN Sets'
                    }
                }
            }
        }
    }

    # Summary findings
    if ($vhdCount -eq 0 -and $passThroughCount -eq 0) {
        Write-Finding -Severity 'Pass' -Category 'Performance' `
            -Check 'VM storage format compliance' `
            -CurrentState 'All VMs use VHDx format with no pass-through disks'
    }

    if ($vfcVMs.Count -gt 0) {
        Write-Finding -Severity 'Info' -Category 'Performance' `
            -Check 'Virtual Fibre Channel VMs' `
            -CurrentState "$($vfcVMs.Count) VM(s) with vFC: $($vfcVMs -join ', ')" `
            -ExpectedState 'Ensure both Set A and Set B WWPNs are zoned in FC switches and added to MSA host groups' `
            -Reference 'HPE MSA Gen6 Implementation Guide - How Live Migration Uses WWPN Sets'
    }
}

# ============================================================================
# CONFIGURATION COLLECTION
# ============================================================================

function Get-CurrentConfiguration {
    <#
    .SYNOPSIS
        Collects current iSCSI, MPIO, network, path, and Hyper-V storage configuration
        into $script:Configuration for the Configuration Report.
    #>
    Write-Log 'Collecting current configuration snapshot...' -Level 'INFO'

    # ── iSCSI ──
    $iscsiConfig = @{}
    $svc = Get-Service -Name MSiSCSI -ErrorAction SilentlyContinue
    $iscsiConfig['Service'] = if ($svc) {
        @{ Status = $svc.Status.ToString(); StartType = $svc.StartType.ToString() }
    } else { @{ Status = 'Not Found'; StartType = 'N/A' } }

    $iscsiConfig['InitiatorNode'] = try { (Get-InitiatorPort -ErrorAction Stop | Select-Object -First 1).NodeAddress } catch { 'N/A' }

    $portals = @(Get-IscsiTargetPortal -ErrorAction SilentlyContinue)
    $iscsiConfig['TargetPortals'] = @($portals | ForEach-Object {
        @{ Address = $_.TargetPortalAddress; Port = $_.TargetPortalPortNumber }
    })

    $targets = @(Get-IscsiTarget -ErrorAction SilentlyContinue)
    $iscsiConfig['Targets'] = @($targets | ForEach-Object {
        @{ NodeAddress = $_.NodeAddress; IsConnected = $_.IsConnected }
    })

    $sessions = @(Get-IscsiSession -ErrorAction SilentlyContinue)
    $iscsiConfig['Sessions'] = @($sessions | ForEach-Object {
        @{
            SessionId       = $_.SessionIdentifier
            TargetNodeAddr  = $_.TargetNodeAddress
            IsPersistent    = $_.IsPersistent
            IsConnected     = $_.IsConnected
            IsDataDigest    = $_.IsDataDigest
            IsHeaderDigest  = $_.IsHeaderDigest
        }
    })

    $connections = @(Get-IscsiConnection -ErrorAction SilentlyContinue)
    $iscsiConfig['Connections'] = @($connections | ForEach-Object {
        @{
            ConnectionId    = $_.ConnectionIdentifier
            InitiatorAddr   = $_.InitiatorAddress
            InitiatorPort   = $_.InitiatorPortNumber
            TargetAddr      = $_.TargetAddress
            TargetPort      = $_.TargetPortNumber
        }
    })

    $persistentTargets = @(Get-CimInstance -Namespace root/wmi -ClassName MSiSCSIInitiator_PersistentLoginClass -ErrorAction SilentlyContinue)
    $iscsiConfig['PersistentTargets'] = @($persistentTargets | ForEach-Object {
        @{
            TargetNodeAddress       = $_.TargetName
            TargetPortalAddress     = "$($_.TargetPortal.Address):$($_.TargetPortal.Socket)"
            InitiatorPortalAddress  = $_.InitiatorInstance
        }
    })

    $script:Configuration['iSCSI'] = $iscsiConfig

    # ── MPIO ──
    $mpioConfig = @{}
    $mpioConfig['Installed'] = [bool]$script:Environment['MPIOInstalled']

    try {
        $mpioSettings = Get-MPIOSetting -ErrorAction Stop
        $mpioConfig['Settings'] = @{
            PathVerificationState     = $mpioSettings.PathVerificationState
            PathVerificationPeriod    = $mpioSettings.PathVerificationPeriod
            RetryCount                = $mpioSettings.RetryCount
            RetryInterval             = $mpioSettings.RetryInterval
            DiskTimeoutValue          = $mpioSettings.DiskTimeoutValue
            UseCustomPathRecoveryTime = $mpioSettings.UseCustomPathRecoveryTime
            CustomPathRecoveryTime    = $mpioSettings.CustomPathRecoveryTime
            PDORemovePeriod           = $mpioSettings.PDORemovePeriod
        }
    } catch {
        $mpioConfig['Settings'] = @{ Error = 'Unable to retrieve MPIO settings' }
    }

    $supportedHW = @(Get-MSDSMSupportedHW -ErrorAction SilentlyContinue)
    $mpioConfig['SupportedHardware'] = @($supportedHW | ForEach-Object {
        @{ VendorId = $_.VendorId; ProductId = $_.ProductId }
    })

    $globalLB = try { Get-MSDSMGlobalDefaultLoadBalancePolicy -ErrorAction Stop } catch { 'N/A' }
    $mpioConfig['GlobalLoadBalancePolicy'] = $globalLB

    $script:Configuration['MPIO'] = $mpioConfig

    # ── Network ──
    $netConfig = @{}
    $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue)
    $netConfig['Adapters'] = @($adapters | ForEach-Object {
        $jumbo = Get-NetAdapterAdvancedProperty -Name $_.Name -DisplayName '*Jumbo*' -ErrorAction SilentlyContinue
        $pm = Get-NetAdapterPowerManagement -Name $_.Name -ErrorAction SilentlyContinue
        $vmq = Get-NetAdapterVmq -Name $_.Name -ErrorAction SilentlyContinue
        $rss = Get-NetAdapterRss -Name $_.Name -ErrorAction SilentlyContinue
        $stats = Get-NetAdapterStatistics -Name $_.Name -ErrorAction SilentlyContinue
        @{
            Name            = $_.Name
            InterfaceDesc   = $_.InterfaceDescription
            Status          = $_.Status.ToString()
            LinkSpeed       = $_.LinkSpeed
            MacAddress      = $_.MacAddress
            DriverVersion   = $_.DriverVersionString
            DriverDate      = if ($_.DriverDate) { ([DateTime]$_.DriverDate).ToString('yyyy-MM-dd') } else { 'N/A' }
            JumboFrame      = if ($jumbo) { $jumbo.DisplayValue } else { 'N/A (default 1500)' }
            PowerManagement = if ($pm -and $null -ne $pm.AllowComputerToTurnOffDevice) { $pm.AllowComputerToTurnOffDevice.ToString() } else { 'N/A' }
            VMQ             = if ($vmq) { $vmq.Enabled } else { 'N/A' }
            RSS             = if ($rss) { $rss.Enabled } else { 'N/A' }
            RxErrors        = if ($stats) { $stats.ReceivedPacketErrors } else { 0 }
            TxErrors        = if ($stats) { $stats.OutboundPacketErrors } else { 0 }
            RxDiscards      = if ($stats) { $stats.ReceivedDiscardedPackets } else { 0 }
            TxDiscards      = if ($stats) { $stats.OutboundDiscardedPackets } else { 0 }
        }
    })

    $script:Configuration['Network'] = $netConfig

    # ── MPIO Disks / Paths ──
    $pathConfig = @{}
    if ($script:Environment['MPIOInstalled']) {
        $mpioOutput = mpclaim -s -d 2>&1 | Out-String
        $diskMatches = [regex]::Matches($mpioOutput, 'MPIO Disk(\d+)\s+Disk \d+\s+(\S+)\s+(.+)')
    } else {
        $diskMatches = @()
    }

    $pathConfig['Disks'] = @($diskMatches | ForEach-Object {
        $diskNum = $_.Groups[1].Value
        $lbPolicy = $_.Groups[2].Value.Trim()
        $dsm = $_.Groups[3].Value.Trim()
        $diskDetail = mpclaim -s -d $diskNum 2>&1 | Out-String
        $pathLines = @($diskDetail -split "`n" | Where-Object {
            $_ -match '^\s+\w+' -and $_ -notmatch 'MPIO Disk|State|------' -and $_ -match '(Active|Standby|Failed|Unavailable)'
        })
        @{
            DiskNumber      = "MPIO Disk$diskNum"
            LoadBalPolicy   = $lbPolicy
            DSM             = $dsm
            TotalPaths      = $pathLines.Count
            ActivePaths     = @($pathLines | Where-Object { $_ -match '\bActive\b' }).Count
            StandbyPaths    = @($pathLines | Where-Object { $_ -match '\bStandby\b' }).Count
            FailedPaths     = @($pathLines | Where-Object { $_ -match '\b(Failed|Unavailable)\b' }).Count
        }
    })

    # Partition styles for iSCSI disks
    $iscsiDisks = @(Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.BusType -eq 'iSCSI' })
    $pathConfig['iSCSIDisks'] = @($iscsiDisks | ForEach-Object {
        @{
            DiskNumber     = $_.Number
            FriendlyName   = $_.FriendlyName
            SizeGB         = [math]::Round($_.Size / 1GB, 2)
            PartitionStyle = $_.PartitionStyle
            OperationalStatus = $_.OperationalStatus
        }
    })

    $script:Configuration['Paths'] = $pathConfig

    # ── Hyper-V Storage ──
    if ($script:Environment['HyperVInstalled']) {
        $hvConfig = @{}
        try {
            $vms = @(Get-VM -ErrorAction Stop)
            $hvConfig['VMs'] = @($vms | ForEach-Object {
                $vmName = $_.Name
                $hardDrives = @(Get-VMHardDiskDrive -VMName $vmName -ErrorAction SilentlyContinue)
                $vfcAdapters = @(Get-VMFibreChannelHba -VMName $vmName -ErrorAction SilentlyContinue)
                @{
                    Name        = $vmName
                    State       = $_.State.ToString()
                    Generation  = $_.Generation
                    MemoryMB    = [math]::Round($_.MemoryAssigned / 1MB)
                    Disks       = @($hardDrives | ForEach-Object {
                        @{
                            ControllerType = $_.ControllerType.ToString()
                            Path           = $_.Path
                            DiskNumber     = $_.DiskNumber
                            IsPassThrough  = ($null -ne $_.DiskNumber)
                            Format         = if ($_.Path -match '\.vhd$') { 'VHD' } elseif ($_.Path -match '\.vhdx$') { 'VHDx' } else { 'Unknown' }
                        }
                    })
                    FibreChannel = @($vfcAdapters | ForEach-Object {
                        @{
                            SanName                = $_.SanName
                            WorldWideNodeNameSetA   = $_.WorldWideNodeNameSetA
                            WorldWidePortNameSetA   = $_.WorldWidePortNameSetA
                            WorldWideNodeNameSetB   = $_.WorldWideNodeNameSetB
                            WorldWidePortNameSetB   = $_.WorldWidePortNameSetB
                        }
                    })
                }
            })
        } catch {
            $hvConfig['VMs'] = @()
            $hvConfig['Error'] = "Unable to enumerate VMs: $_"
        }

        $script:Configuration['HyperV'] = $hvConfig
    }

    # ── Best Practices Reference (what we're comparing against) ──
    $script:Configuration['BestPractices'] = Get-BestPractices -Array $script:ArrayType

    Write-Log "Configuration snapshot collected ($($script:Configuration.Keys.Count) sections)" -Level 'SUCCESS'
}

# ============================================================================
# CONFIGURATION REPORT EXPORT
# ============================================================================

function Export-ConfigurationReportHtml {
    param([string]$Path)

    $h = @"
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>iSCSI/MPIO Configuration - $env:COMPUTERNAME</title>
<style>
body { font-family: 'Segoe UI', Tahoma, sans-serif; margin: 20px; background: #f5f5f5; color: #333; }
.header { background: #0d47a1; color: white; padding: 20px; border-radius: 8px; margin-bottom: 20px; }
.header h1 { margin: 0; } .header p { margin: 5px 0 0; opacity: 0.8; }
h2 { color: #0d47a1; border-bottom: 2px solid #0d47a1; padding-bottom: 5px; }
h3 { color: #1565c0; margin-top: 15px; }
table { width: 100%; border-collapse: collapse; background: white; border-radius: 8px; overflow: hidden; box-shadow: 0 1px 3px rgba(0,0,0,0.1); margin-bottom: 20px; }
th { background: #1565c0; color: white; padding: 10px 12px; text-align: left; font-size: 0.9em; }
td { padding: 8px 12px; border-bottom: 1px solid #eee; font-size: 0.9em; }
tr:nth-child(even) { background: #f9f9f9; } tr:hover { background: #e3f2fd; }
.kv td:first-child { font-weight: 600; width: 250px; background: #f5f5f5; }
.status-up { color: #2e7d32; font-weight: bold; } .status-down { color: #c62828; font-weight: bold; }
.note { background: #fff3e0; border-left: 4px solid #ff9800; padding: 10px; margin: 10px 0; border-radius: 4px; }
</style></head><body>
<div class="header"><h1>Configuration Report</h1>
<p>$env:COMPUTERNAME | Array: $($script:ArrayType) | Collected: $(Get-Date -Format 'yyyy-MM-dd HH:mm') | v$($script:ScriptVersion)</p></div>
"@

    # Environment
    $h += "<h2>Environment</h2><table class='kv'>"
    foreach ($key in ($script:Environment.Keys | Sort-Object)) {
        $h += "<tr><td>$key</td><td>$($script:Environment[$key])</td></tr>"
    }
    $h += "</table>"

    # iSCSI
    $ic = $script:Configuration['iSCSI']
    $h += "<h2>iSCSI Configuration</h2>"
    $h += "<h3>Service</h3><table class='kv'>"
    $h += "<tr><td>Status</td><td>$($ic.Service.Status)</td></tr>"
    $h += "<tr><td>Startup Type</td><td>$($ic.Service.StartType)</td></tr>"
    $h += "<tr><td>Initiator IQN</td><td>$($ic.InitiatorNode)</td></tr>"
    $h += "</table>"

    if ($ic.TargetPortals.Count -gt 0) {
        $h += "<h3>Target Portals ($($ic.TargetPortals.Count))</h3><table>"
        $h += "<tr><th>Address</th><th>Port</th></tr>"
        foreach ($p in $ic.TargetPortals) { $h += "<tr><td>$($p.Address)</td><td>$($p.Port)</td></tr>" }
        $h += "</table>"
    }

    if ($ic.Targets.Count -gt 0) {
        $h += "<h3>Targets ($($ic.Targets.Count))</h3><table>"
        $h += "<tr><th>Node Address (IQN)</th><th>Connected</th></tr>"
        foreach ($t in $ic.Targets) {
            $connClass = if ($t.IsConnected) { 'status-up' } else { 'status-down' }
            $h += "<tr><td>$($t.NodeAddress)</td><td class='$connClass'>$($t.IsConnected)</td></tr>"
        }
        $h += "</table>"
    }

    if ($ic.Sessions.Count -gt 0) {
        $h += "<h3>Sessions ($($ic.Sessions.Count))</h3><table>"
        $h += "<tr><th>Target</th><th>Persistent</th><th>Data Digest</th><th>Header Digest</th></tr>"
        foreach ($s in $ic.Sessions) {
            $h += "<tr><td>$($s.TargetNodeAddr)</td><td>$($s.IsPersistent)</td><td>$($s.IsDataDigest)</td><td>$($s.IsHeaderDigest)</td></tr>"
        }
        $h += "</table>"
    }

    if ($ic.Connections.Count -gt 0) {
        $h += "<h3>Connections ($($ic.Connections.Count))</h3><table>"
        $h += "<tr><th>Initiator IP</th><th>Initiator Port</th><th>Target IP</th><th>Target Port</th></tr>"
        foreach ($c in $ic.Connections) {
            $h += "<tr><td>$($c.InitiatorAddr)</td><td>$($c.InitiatorPort)</td><td>$($c.TargetAddr)</td><td>$($c.TargetPort)</td></tr>"
        }
        $h += "</table>"
    }

    if ($ic.PersistentTargets.Count -gt 0) {
        $h += "<h3>Persistent Registrations ($($ic.PersistentTargets.Count))</h3><table>"
        $h += "<tr><th>Target IQN</th><th>Target Portal</th><th>Initiator Portal</th></tr>"
        foreach ($pt in $ic.PersistentTargets) {
            $h += "<tr><td>$($pt.TargetNodeAddress)</td><td>$($pt.TargetPortalAddress)</td><td>$($pt.InitiatorPortalAddress)</td></tr>"
        }
        $h += "</table>"
    }

    # MPIO
    $mc = $script:Configuration['MPIO']
    $h += "<h2>MPIO Configuration</h2>"
    $h += "<table class='kv'><tr><td>Installed</td><td>$($mc.Installed)</td></tr>"
    $h += "<tr><td>Global LB Policy</td><td>$($mc.GlobalLoadBalancePolicy)</td></tr></table>"

    if ($mc.Settings -and -not $mc.Settings.Error) {
        $h += "<h3>Settings</h3><table class='kv'>"
        foreach ($key in ($mc.Settings.Keys | Sort-Object)) {
            $h += "<tr><td>$key</td><td>$($mc.Settings[$key])</td></tr>"
        }
        $h += "</table>"
    }

    if ($mc.SupportedHardware.Count -gt 0) {
        $h += "<h3>Supported Hardware ($($mc.SupportedHardware.Count))</h3><table>"
        $h += "<tr><th>Vendor ID</th><th>Product ID</th></tr>"
        foreach ($hw in $mc.SupportedHardware) { $h += "<tr><td>$($hw.VendorId)</td><td>$($hw.ProductId)</td></tr>" }
        $h += "</table>"
    }

    # Network
    $nc = $script:Configuration['Network']
    if ($nc.Adapters.Count -gt 0) {
        $h += "<h2>Network Adapters ($($nc.Adapters.Count))</h2><table>"
        $h += "<tr><th>Name</th><th>Description</th><th>Status</th><th>Speed</th><th>Driver</th><th>Jumbo</th><th>PM</th><th>VMQ</th><th>RSS</th><th>RxErr</th><th>TxErr</th><th>RxDisc</th><th>TxDisc</th></tr>"
        foreach ($a in $nc.Adapters) {
            $sClass = if ($a.Status -eq 'Up') { 'status-up' } else { 'status-down' }
            $h += "<tr><td>$($a.Name)</td><td>$($a.InterfaceDesc)</td><td class='$sClass'>$($a.Status)</td>"
            $h += "<td>$($a.LinkSpeed)</td><td>$($a.DriverVersion) ($($a.DriverDate))</td>"
            $h += "<td>$($a.JumboFrame)</td><td>$($a.PowerManagement)</td><td>$($a.VMQ)</td><td>$($a.RSS)</td>"
            $h += "<td>$($a.RxErrors)</td><td>$($a.TxErrors)</td><td>$($a.RxDiscards)</td><td>$($a.TxDiscards)</td></tr>"
        }
        $h += "</table>"
    }

    # Paths
    $pc = $script:Configuration['Paths']
    if ($pc.Disks.Count -gt 0) {
        $h += "<h2>MPIO Disks ($($pc.Disks.Count))</h2><table>"
        $h += "<tr><th>Disk</th><th>LB Policy</th><th>DSM</th><th>Total Paths</th><th>Active</th><th>Standby</th><th>Failed</th></tr>"
        foreach ($d in $pc.Disks) {
            $failClass = if ($d.FailedPaths -gt 0) { 'status-down' } else { '' }
            $h += "<tr><td>$($d.DiskNumber)</td><td>$($d.LoadBalPolicy)</td><td>$($d.DSM)</td>"
            $h += "<td>$($d.TotalPaths)</td><td>$($d.ActivePaths)</td><td>$($d.StandbyPaths)</td><td class='$failClass'>$($d.FailedPaths)</td></tr>"
        }
        $h += "</table>"
    }

    if ($pc.iSCSIDisks.Count -gt 0) {
        $h += "<h3>iSCSI Disk Volumes</h3><table>"
        $h += "<tr><th>Disk #</th><th>Name</th><th>Size (GB)</th><th>Partition Style</th><th>Status</th></tr>"
        foreach ($d in $pc.iSCSIDisks) {
            $h += "<tr><td>$($d.DiskNumber)</td><td>$($d.FriendlyName)</td><td>$($d.SizeGB)</td><td>$($d.PartitionStyle)</td><td>$($d.OperationalStatus)</td></tr>"
        }
        $h += "</table>"
    }

    # Hyper-V
    if ($script:Configuration.ContainsKey('HyperV')) {
        $hv = $script:Configuration['HyperV']
        if ($hv.VMs.Count -gt 0) {
            $h += "<h2>Hyper-V Virtual Machines ($($hv.VMs.Count))</h2>"
            foreach ($vm in $hv.VMs) {
                $h += "<h3>$($vm.Name) ($($vm.State))</h3><table class='kv'>"
                $h += "<tr><td>Generation</td><td>$($vm.Generation)</td></tr>"
                $h += "<tr><td>Memory (MB)</td><td>$($vm.MemoryMB)</td></tr></table>"
                if ($vm.Disks.Count -gt 0) {
                    $h += "<table><tr><th>Controller</th><th>Path</th><th>Format</th><th>Pass-Through</th></tr>"
                    foreach ($dk in $vm.Disks) {
                        $ptClass = if ($dk.IsPassThrough) { 'status-down' } else { '' }
                        $h += "<tr><td>$($dk.ControllerType)</td><td style='word-break:break-all'>$($dk.Path)</td><td>$($dk.Format)</td><td class='$ptClass'>$($dk.IsPassThrough)</td></tr>"
                    }
                    $h += "</table>"
                }
                if ($vm.FibreChannel.Count -gt 0) {
                    $h += "<table><tr><th>SAN</th><th>WWNN Set A</th><th>WWPN Set A</th><th>WWNN Set B</th><th>WWPN Set B</th></tr>"
                    foreach ($fc in $vm.FibreChannel) {
                        $h += "<tr><td>$($fc.SanName)</td><td>$($fc.WorldWideNodeNameSetA)</td><td>$($fc.WorldWidePortNameSetA)</td><td>$($fc.WorldWideNodeNameSetB)</td><td>$($fc.WorldWidePortNameSetB)</td></tr>"
                    }
                    $h += "</table>"
                }
            }
        }
    }

    $h += "<div class='note'><strong>Best Practices Reference:</strong> $($script:ArrayType) — $(($script:Configuration['BestPractices']).ArrayNotes)</div>"
    $h += "</body></html>"
    $h | Out-File -FilePath $Path -Encoding UTF8
}

function Export-ConfigurationReportMarkdown {
    param([string]$Path)

    $ic = $script:Configuration['iSCSI']
    $mc = $script:Configuration['MPIO']
    $nc = $script:Configuration['Network']
    $pc = $script:Configuration['Paths']

    $md = @"
# iSCSI / MPIO Configuration Report

**Host:** $env:COMPUTERNAME | **Array:** $($script:ArrayType) | **Collected:** $(Get-Date -Format 'yyyy-MM-dd HH:mm') | **v$($script:ScriptVersion)**

---

## Environment

| Setting | Value |
|---------|-------|

"@
    foreach ($key in ($script:Environment.Keys | Sort-Object)) {
        $md += "| $key | $($script:Environment[$key]) |`n"
    }

    $md += @"

## iSCSI Configuration

| Setting | Value |
|---------|-------|
| Service Status | $($ic.Service.Status) |
| Startup Type | $($ic.Service.StartType) |
| Initiator IQN | $($ic.InitiatorNode) |
| Target Portals | $($ic.TargetPortals.Count) |
| Targets | $($ic.Targets.Count) (Connected: $(($ic.Targets | Where-Object { $_.IsConnected }).Count)) |
| Sessions | $($ic.Sessions.Count) (Persistent: $(($ic.Sessions | Where-Object { $_.IsPersistent }).Count)) |
| Persistent Registrations | $($ic.PersistentTargets.Count) |
| Connections | $($ic.Connections.Count) |

"@

    if ($ic.Connections.Count -gt 0) {
        $md += "### iSCSI Connection Map`n`n"
        $md += "| Initiator IP | Port | Target IP | Port |`n|---|---|---|---|`n"
        foreach ($c in $ic.Connections) {
            $md += "| $($c.InitiatorAddr) | $($c.InitiatorPort) | $($c.TargetAddr) | $($c.TargetPort) |`n"
        }
        $md += "`n"
    }

    if ($ic.PersistentTargets.Count -gt 0) {
        $md += "### Persistent Registrations ($($ic.PersistentTargets.Count))`n`n"
        $md += "| Target IQN | Target Portal | Initiator Portal |`n|---|---|---|`n"
        foreach ($pt in $ic.PersistentTargets) {
            $md += "| $($pt.TargetNodeAddress) | $($pt.TargetPortalAddress) | $($pt.InitiatorPortalAddress) |`n"
        }
        $md += "`n"
    }

    $md += @"
## MPIO Configuration

| Setting | Value |
|---------|-------|
| Installed | $($mc.Installed) |
| Global LB Policy | $($mc.GlobalLoadBalancePolicy) |

"@

    if ($mc.Settings -and -not $mc.Settings.Error) {
        $md += "### MPIO Settings`n`n| Setting | Value |`n|---------|-------|`n"
        foreach ($key in ($mc.Settings.Keys | Sort-Object)) {
            $md += "| $key | $($mc.Settings[$key]) |`n"
        }
        $md += "`n"
    }

    if ($mc.SupportedHardware.Count -gt 0) {
        $md += "### Supported Hardware`n`n| Vendor ID | Product ID |`n|-----------|------------|`n"
        foreach ($hw in $mc.SupportedHardware) { $md += "| $($hw.VendorId) | $($hw.ProductId) |`n" }
        $md += "`n"
    }

    if ($nc.Adapters.Count -gt 0) {
        $md += "## Network Adapters ($($nc.Adapters.Count))`n`n"
        $md += "| Name | Status | Speed | Jumbo | PM | VMQ | RSS | RxErr | TxErr |`n|------|--------|-------|-------|----|----|-----|-------|-------|`n"
        foreach ($a in $nc.Adapters) {
            $md += "| $($a.Name) | $($a.Status) | $($a.LinkSpeed) | $($a.JumboFrame) | $($a.PowerManagement) | $($a.VMQ) | $($a.RSS) | $($a.RxErrors) | $($a.TxErrors) |`n"
        }
        $md += "`n"
    }

    if ($pc.Disks.Count -gt 0) {
        $md += "## MPIO Disks ($($pc.Disks.Count))`n`n"
        $md += "| Disk | LB Policy | Paths | Active | Standby | Failed |`n|------|-----------|-------|--------|---------|--------|`n"
        foreach ($d in $pc.Disks) {
            $md += "| $($d.DiskNumber) | $($d.LoadBalPolicy) | $($d.TotalPaths) | $($d.ActivePaths) | $($d.StandbyPaths) | $($d.FailedPaths) |`n"
        }
        $md += "`n"
    }

    if ($pc.iSCSIDisks.Count -gt 0) {
        $md += "### iSCSI Disk Volumes`n`n| Disk # | Name | Size (GB) | Partition | Status |`n|--------|------|-----------|-----------|--------|`n"
        foreach ($d in $pc.iSCSIDisks) {
            $md += "| $($d.DiskNumber) | $($d.FriendlyName) | $($d.SizeGB) | $($d.PartitionStyle) | $($d.OperationalStatus) |`n"
        }
        $md += "`n"
    }

    if ($script:Configuration.ContainsKey('HyperV') -and $script:Configuration['HyperV'].VMs.Count -gt 0) {
        $md += "## Hyper-V Virtual Machines ($($script:Configuration['HyperV'].VMs.Count))`n`n"
        $md += "| VM | State | Gen | Memory (MB) | Disks | vFC Adapters |`n|-------|-------|-----|-------------|-------|--------------|`n"
        foreach ($vm in $script:Configuration['HyperV'].VMs) {
            $md += "| $($vm.Name) | $($vm.State) | $($vm.Generation) | $($vm.MemoryMB) | $($vm.Disks.Count) | $($vm.FibreChannel.Count) |`n"
        }
        $md += "`n"
    }

    $md += "> **Best Practices Reference:** $($script:ArrayType) - $(($script:Configuration['BestPractices']).ArrayNotes)`n"
    $md | Out-File -FilePath $Path -Encoding UTF8
}

# ============================================================================
# RECOMMENDATION REPORT EXPORT
# ============================================================================

function Export-RecommendationReportHtml {
    param([string]$Path)

    $bp = $script:Configuration['BestPractices']
    $actionable = @($script:Findings | Where-Object { $_.Severity -in @('Critical', 'Warning') } |
        Sort-Object @{Expression={switch($_.Severity){'Critical'{0}'Warning'{1}}}; Ascending=$true})

    $critColor = '#dc3545'; $warnColor = '#e6a100'

    $h = @"
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>iSCSI/MPIO Recommendations - $env:COMPUTERNAME</title>
<style>
body { font-family: 'Segoe UI', Tahoma, sans-serif; margin: 20px; background: #f5f5f5; color: #333; }
.header { background: #b71c1c; color: white; padding: 20px; border-radius: 8px; margin-bottom: 20px; }
.header h1 { margin: 0; } .header p { margin: 5px 0 0; opacity: 0.8; }
.summary-bar { display: flex; gap: 15px; margin-bottom: 20px; flex-wrap: wrap; }
.stat { padding: 12px 20px; border-radius: 8px; color: white; min-width: 100px; text-align: center; }
.stat .num { font-size: 1.8em; font-weight: bold; } .stat .label { font-size: 0.8em; }
.critical { background: $critColor; } .warning { background: $warnColor; color: #333; }
.passed { background: #28a745; }
h2 { color: #b71c1c; margin-top: 30px; }
.rec-card { background: white; border-radius: 8px; padding: 15px 20px; margin-bottom: 15px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); border-left: 5px solid; }
.rec-card.sev-Critical { border-color: $critColor; } .rec-card.sev-Warning { border-color: $warnColor; }
.rec-card h3 { margin: 0 0 8px; font-size: 1em; }
.rec-meta { display: flex; gap: 20px; font-size: 0.85em; color: #666; margin-bottom: 8px; }
.rec-meta span { display: inline-block; } .rec-meta .sev { font-weight: bold; }
.sev-Critical { color: $critColor; } .sev-Warning { color: $warnColor; }
.rec-detail { font-size: 0.9em; line-height: 1.6; }
.rec-detail .label { font-weight: 600; color: #555; display: inline-block; width: 100px; }
code { background: #f0f0f0; padding: 2px 6px; border-radius: 3px; font-family: Consolas, monospace; font-size: 0.9em; }
.note { background: #e8f5e9; border-left: 4px solid #4caf50; padding: 12px; margin: 20px 0; border-radius: 4px; }
.priority-label { background: #333; color: white; padding: 3px 10px; border-radius: 12px; font-size: 0.75em; font-weight: bold; display: inline-block; }
</style></head><body>
<div class="header"><h1>Recommendation Report</h1>
<p>$env:COMPUTERNAME | Array: $($script:ArrayType) | $(Get-Date -Format 'yyyy-MM-dd HH:mm') | v$($script:ScriptVersion)</p></div>
<div class="summary-bar">
<div class="stat critical"><div class="num">$($script:Summary.Critical)</div><div class="label">Critical</div></div>
<div class="stat warning"><div class="num">$($script:Summary.Warning)</div><div class="label">Warning</div></div>
<div class="stat passed"><div class="num">$($script:Summary.Pass)</div><div class="label">Passed</div></div>
</div>
"@

    if ($actionable.Count -eq 0) {
        $h += "<div class='note'><strong>No actionable recommendations.</strong> All checks passed or returned informational results only.</div>"
    } else {
        $h += "<h2>Prioritized Remediation Steps ($($actionable.Count) items)</h2>"
        $priority = 1
        foreach ($f in $actionable) {
            $h += "<div class='rec-card sev-$($f.Severity)'>"
            $h += "<h3><span class='priority-label'>#$priority</span> $($f.Check)</h3>"
            $h += "<div class='rec-meta'><span class='sev sev-$($f.Severity)'>$($f.Severity)</span><span>Category: $($f.Category)</span></div>"
            $h += "<div class='rec-detail'>"
            if ($f.CurrentState) { $h += "<div><span class='label'>Current:</span> $(ConvertTo-HtmlSafe $f.CurrentState)</div>" }
            if ($f.ExpectedState) { $h += "<div><span class='label'>Expected:</span> $(ConvertTo-HtmlSafe $f.ExpectedState)</div>" }
            if ($f.Impact) { $h += "<div><span class='label'>Impact:</span> $(ConvertTo-HtmlSafe $f.Impact)</div>" }
            if ($f.Remediation) { $h += "<div><span class='label'>Fix:</span> <code>$(ConvertTo-HtmlSafe $f.Remediation)</code></div>" }
            if ($f.Reference) { $h += "<div><span class='label'>Reference:</span> $(ConvertTo-HtmlSafe $f.Reference)</div>" }
            $h += "</div></div>"
            $priority++
        }

        # Reboot requirement check
        $needsReboot = $actionable | Where-Object { $_.Remediation -match 'reboot|restart' }
        if ($needsReboot) {
            $h += "<div class='note'><strong>Note:</strong> $(@($needsReboot).Count) recommendation(s) require a server reboot. Plan a maintenance window to apply these changes together.</div>"
        }
    }

    # Best practices reference
    if ($bp.ArrayNotes) {
        $h += "<h2>Array-Specific Guidance ($($script:ArrayType))</h2><div class='rec-card sev-Warning' style='border-color: #1565c0;'>"
        $h += "<div class='rec-detail'>$($bp.ArrayNotes)</div></div>"
    }

    $h += "</body></html>"
    $h | Out-File -FilePath $Path -Encoding UTF8
}

function Export-RecommendationReportMarkdown {
    param([string]$Path)

    $bp = $script:Configuration['BestPractices']
    $actionable = @($script:Findings | Where-Object { $_.Severity -in @('Critical', 'Warning') } |
        Sort-Object @{Expression={switch($_.Severity){'Critical'{0}'Warning'{1}}}; Ascending=$true})

    $md = @"
# iSCSI / MPIO Recommendation Report

**Host:** $env:COMPUTERNAME | **Array:** $($script:ArrayType) | **Date:** $(Get-Date -Format 'yyyy-MM-dd HH:mm') | **v$($script:ScriptVersion)**

## Summary

| Metric | Count |
|--------|-------|
| Critical | $($script:Summary.Critical) |
| Warning | $($script:Summary.Warning) |
| Pass | $($script:Summary.Pass) |
| **Total Checks** | **$($script:Summary.TotalChecks)** |

---

"@

    if ($actionable.Count -eq 0) {
        $md += "> **No actionable recommendations.** All checks passed.`n"
    } else {
        $md += "## Prioritized Remediation ($($actionable.Count) items)`n`n"

        $priority = 1
        $currentSev = ''
        foreach ($f in $actionable) {
            if ($f.Severity -ne $currentSev) {
                $currentSev = $f.Severity
                $md += "### $currentSev`n`n"
            }
            $md += "**#$priority — $($f.Check)** ($($f.Category))`n`n"
            if ($f.CurrentState) { $md += "- **Current:** $($f.CurrentState)`n" }
            if ($f.ExpectedState) { $md += "- **Expected:** $($f.ExpectedState)`n" }
            if ($f.Impact) { $md += "- **Impact:** $($f.Impact)`n" }
            if ($f.Remediation) { $md += "- **Fix:** ``$($f.Remediation)```n" }
            if ($f.Reference) { $md += "- **Reference:** $($f.Reference)`n" }
            $md += "`n"
            $priority++
        }

        $needsReboot = @($actionable | Where-Object { $_.Remediation -match 'reboot|restart' })
        if ($needsReboot.Count -gt 0) {
            $md += "> **Note:** $($needsReboot.Count) recommendation(s) require a server reboot. Plan a maintenance window.`n`n"
        }
    }

    if ($bp.ArrayNotes) {
        $md += "## Array-Specific Guidance ($($script:ArrayType))`n`n$($bp.ArrayNotes)`n"
    }

    $md | Out-File -FilePath $Path -Encoding UTF8
}

# ============================================================================
# MAIN ASSESSMENT ORCHESTRATOR
# ============================================================================

function Invoke-Assessment {
    Write-Log "$script:ScriptName v$script:ScriptVersion" -Level 'INFO'
    Write-Log ('-' * 60) -Level 'INFO'
    Write-Log "Mode: $script:Mode | Category: $script:Category | Array: $script:ArrayType" -Level 'INFO'

    if (-not $script:IsAdmin) {
        Write-Log 'WARNING: Not running as Administrator. Some checks may return incomplete data.' -Level 'WARN'
    }

    Get-AssessmentEnvironment

    # Collect configuration snapshot for Configuration and Recommendation reports
    $wantConfig = $script:ReportType -in @('Configuration', 'Recommendations', 'All')
    if ($wantConfig) {
        Get-CurrentConfiguration
    }

    Write-Log "Array type: $script:ArrayType" -Level 'INFO'
    Write-Host '' -ErrorAction SilentlyContinue

    $categories = if ($script:Category -eq 'All') {
        @('iSCSI', 'MPIO', 'Network', 'Paths', 'Performance')
    } else {
        @($script:Category)
    }

    foreach ($cat in $categories) {
        switch ($cat) {
            'iSCSI'       { Test-ISCSIConfiguration }
            'MPIO'        { Test-MPIOConfiguration }
            'Network'     { Test-NetworkConfiguration }
            'Paths'       { Test-PathConfiguration }
            'Performance' { Test-PerformanceConfiguration }
        }
    }

    # ── Hyper-V Storage (runs automatically when assessing all categories) ──
    if ($script:Category -eq 'All') {
        Test-HyperVStorageConfiguration
    }

    # ── Summary ──
    Write-Host '' -ErrorAction SilentlyContinue
    Write-Log ('-' * 60) -Level 'INFO'
    Write-Log "Assessment Complete: $($script:Summary.TotalChecks) checks" -Level 'INFO'

    $severityLine = "Critical=$($script:Summary.Critical)  Warning=$($script:Summary.Warning)  Info=$($script:Summary.Info)  Pass=$($script:Summary.Pass)"

    if ($script:Summary.Critical -gt 0) {
        Write-Log $severityLine -Level 'ERROR'
    } elseif ($script:Summary.Warning -gt 0) {
        Write-Log $severityLine -Level 'WARN'
    } else {
        Write-Log $severityLine -Level 'SUCCESS'
    }

    Export-Results
    Write-NinjaOutput

    if ($script:PassThru) { return @($script:Findings) }

    if ($script:Summary.Critical -gt 0) { return 1 }
    if ($script:Summary.Warning -gt 0) { return 10 }
    return 0
}

# ============================================================================
# ENTRY POINT
# ============================================================================

function Invoke-iSCSIMPIOAssessment {
    <#
    .SYNOPSIS
        Launch iSCSI/MPIO Assessment. Supports paste/dot-source invocation.
    .DESCRIPTION
        Entry-point function with all parameters available.
        Defaults pull from the script param() block so you only
        specify what you want to change.
    .PARAMETER Mode
        Assessment depth: Quick, Standard (default), Full.
    .PARAMETER Category
        Scope: All, iSCSI, MPIO, Network, Paths, Performance.
    .PARAMETER ArrayType
        Storage array: Auto (default), MSA, Nimble, Generic.
    .PARAMETER OutputPath
        Directory for report output.
    .PARAMETER OutputFormat
        Report format: JSON, CSV, HTML, Markdown, All.
    .PARAMETER Quiet
        Suppress console output.
    .PARAMETER PassThru
        Return findings objects to pipeline.
    .PARAMETER AutoExport
        Auto-export reports to OutputPath.
    .PARAMETER NinjaCustomField
        Write summary to NinjaRMM text custom field.
    .PARAMETER NinjaHTMLField
        Write HTML report to NinjaRMM WYSIWYG field.
    .PARAMETER ReportType
        Report scope: Assessment (default), Configuration (state snapshot),
        Recommendations (prioritized remediation), All (all three).
    .EXAMPLE
        Invoke-iSCSIMPIOAssessment
    .EXAMPLE
        Invoke-iSCSIMPIOAssessment -Mode Full -ArrayType MSA -AutoExport
    .EXAMPLE
        Invoke-iSCSIMPIOAssessment -Category MPIO -ArrayType Nimble
    .EXAMPLE
        Invoke-iSCSIMPIOAssessment -ReportType All -Mode Full -AutoExport -OutputFormat HTML
    #>
    [CmdletBinding(SupportsShouldProcess = $false)]
    param(
        [ValidateSet('Quick', 'Standard', 'Full')]
        [string]$Mode = $script:Mode,

        [ValidateSet('All', 'iSCSI', 'MPIO', 'Network', 'Paths', 'Performance')]
        [string]$Category = $script:Category,

        [ValidateSet('Auto', 'MSA', 'Nimble', 'Generic')]
        [string]$ArrayType = $script:ArrayType,

        [ValidateNotNullOrEmpty()]
        [string]$OutputPath = $script:OutputPath,

        [ValidateSet('JSON', 'CSV', 'HTML', 'Markdown', 'All')]
        [string]$OutputFormat = $script:OutputFormat,

        [switch]$Quiet,

        [switch]$PassThru,

        [switch]$AutoExport,

        [string]$NinjaCustomField = $script:NinjaCustomField,

        [string]$NinjaHTMLField = $script:NinjaHTMLField,

        [ValidateSet('Assessment', 'Configuration', 'Recommendations', 'All')]
        [string]$ReportType = $script:ReportType
    )

    $script:Mode = $Mode
    $script:Category = $Category
    $script:ArrayType = $ArrayType
    $script:OutputPath = $OutputPath
    $script:OutputFormat = $OutputFormat
    $script:ReportType = $ReportType

    if ($PSBoundParameters.ContainsKey('Quiet')) { $script:Quiet = $Quiet }
    if ($PSBoundParameters.ContainsKey('PassThru')) { $script:PassThru = $PassThru }
    if ($PSBoundParameters.ContainsKey('AutoExport')) { $script:AutoExport = $AutoExport }
    if ($PSBoundParameters.ContainsKey('NinjaCustomField')) { $script:NinjaCustomField = $NinjaCustomField }
    if ($PSBoundParameters.ContainsKey('NinjaHTMLField')) { $script:NinjaHTMLField = $NinjaHTMLField }

    # Reset findings for fresh run
    $script:Findings = New-Object System.Collections.ArrayList
    $script:Summary = @{ TotalChecks = 0; Critical = 0; Warning = 0; Info = 0; Pass = 0 }
    $script:Environment = @{}
    $script:Configuration = @{}

    if ($script:AutoExport) { Initialize-OutputDirectory }

    $result = Invoke-Assessment

    if ($script:PassThru) { return $result }

    return $result
}

# ============================================================================
# SCRIPT EXECUTION (direct run vs dot-source vs paste)
# ============================================================================

if (-not $PSCommandPath) {
    Write-Host ''
    Write-Host "$script:ScriptName v$($script:ScriptVersion) loaded (pasted)." -ForegroundColor Cyan
    Write-Host 'Run: Invoke-iSCSIMPIOAssessment' -ForegroundColor Gray
    Write-Host 'Run: Invoke-iSCSIMPIOAssessment -Mode Full -ArrayType MSA -AutoExport' -ForegroundColor Gray
    Write-Host 'Run: Invoke-iSCSIMPIOAssessment -ReportType All -Mode Full -AutoExport -OutputFormat HTML' -ForegroundColor Gray
    Write-Host ''
}
elseif ($MyInvocation.InvocationName -ne '.') {
    $exitCode = Invoke-iSCSIMPIOAssessment
    if ($exitCode -is [int]) { exit $exitCode }
}
else {
    Write-Host ''
    Write-Host "$script:ScriptName v$($script:ScriptVersion) loaded." -ForegroundColor Cyan
    Write-Host 'Run: Invoke-iSCSIMPIOAssessment' -ForegroundColor Gray
    Write-Host 'Run: Invoke-iSCSIMPIOAssessment -Mode Full -ArrayType MSA -AutoExport' -ForegroundColor Gray
    Write-Host 'Run: Invoke-iSCSIMPIOAssessment -ReportType All -Mode Full -AutoExport -OutputFormat HTML' -ForegroundColor Gray
    Write-Host ''
}

# ============================================================================
# PRESETS (uncomment one and paste for quick execution)
# ============================================================================

# Invoke-iSCSIMPIOAssessment -Mode Quick
# Invoke-iSCSIMPIOAssessment -Mode Standard -AutoExport
# Invoke-iSCSIMPIOAssessment -Mode Full -AutoExport -OutputFormat All
# Invoke-iSCSIMPIOAssessment -Mode Full -ArrayType MSA -AutoExport
# Invoke-iSCSIMPIOAssessment -Mode Full -ArrayType Nimble -AutoExport
# Invoke-iSCSIMPIOAssessment -ReportType All -Mode Full -AutoExport -OutputFormat HTML
# Invoke-iSCSIMPIOAssessment -ReportType Configuration -AutoExport -OutputFormat HTML
# Invoke-iSCSIMPIOAssessment -Category MPIO
# Invoke-iSCSIMPIOAssessment -Category Network
# Invoke-iSCSIMPIOAssessment -Category Paths
