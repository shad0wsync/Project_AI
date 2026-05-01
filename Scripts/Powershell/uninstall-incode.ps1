<#
.SYNOPSIS
Silent uninstall script for Tyler Technologies Central Pro Shell (all versions)

.DESCRIPTION
Removes Tyler Technologies Central Pro Shell via multiple detection and removal methods:
- WMI product query (Win32_Product)
- Registry uninstall string execution
- Direct MSI GUID-based removal (if GUID is discovered)
- Process termination before uninstall
Logs all operations to C:\Temp\Uninstall-CentralProShell\ with timestamp formatting.
Generates professional HTML execution report with status visualization.

.PARAMETER Verbose
Switch to enable verbose logging output to console and log file

.PARAMETER SkipProcessKill
Switch to skip process termination (not recommended for silent uninstall)

.EXAMPLE
# Direct copy/paste into PowerShell ISE or console
. { Invoke-Expression (New-Object System.Net.WebClient).DownloadString('script_url_here') }

# Or save as PS1 and run:
powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File "Uninstall-CentralProShell.ps1"

.NOTES
Source Documentation: Microsoft Win32_Product class
Community Reference: MSDN WMI uninstallation patterns
Tested Against: Windows Server 2019+, Windows 10/11
Author: Coder Agent
Date: 2026-04-29
NinjaRMM Compatible: Yes (silent execution with no console window)
#>

[CmdletBinding()]
param(
    [switch]$SkipProcessKill,
    [switch]$EnableConsoleLogging
)

# ============================================================================
# CONFIGURATION SECTION (Centralized)
# ============================================================================

$ScriptName = "Uninstall-CentralProShell"
$LogDirectory = "C:\Temp\$ScriptName"
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile = Join-Path $LogDirectory "$($ScriptName)_$($Timestamp).log"
$ErrorLogFile = Join-Path $LogDirectory "$($ScriptName)_$($Timestamp)_ERROR.log"
$ReportFile = Join-Path $LogDirectory "$($ScriptName)_$($Timestamp)_REPORT.html"

# Search criteria for Central Pro Shell
$ProductSearchPatterns = @(
    "*Central Pro Shell*",
    "*Ice.Shell*",
    "*Tyler*Pro*Shell*"
)

$ProcessNamesToTerminate = @(
    "Shell",
    "CentralProShell",
    "IceShell"
)

# ============================================================================
# EMBEDDED CSS FOR HTML REPORT
# ============================================================================

$HTMLStyles = @"
<style>
    * {
        margin: 0;
        padding: 0;
        box-sizing: border-box;
    }
    
    body {
        font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
        background-color: #f5f5f5;
        color: #333;
        line-height: 1.6;
    }
    
    .container {
        max-width: 1200px;
        margin: 20px auto;
        background-color: white;
        border-radius: 8px;
        box-shadow: 0 2px 8px rgba(0, 0, 0, 0.1);
        overflow: hidden;
    }
    
    .header {
        background: linear-gradient(135deg, #354B5E 0%, #4A6FA5 100%);
        color: white;
        padding: 30px;
        border-bottom: 4px solid #2c3e50;
    }
    
    .header h1 {
        font-size: 28px;
        margin-bottom: 10px;
        font-weight: 600;
    }
    
    .header p {
        font-size: 14px;
        opacity: 0.9;
    }
    
    .content {
        padding: 30px;
    }
    
    .section {
        margin-bottom: 30px;
    }
    
    .section h2 {
        font-size: 18px;
        color: #354B5E;
        margin-bottom: 15px;
        padding-bottom: 10px;
        border-bottom: 2px solid #e0e0e0;
    }
    
    .metadata {
        display: grid;
        grid-template-columns: 1fr 1fr;
        gap: 15px;
        background-color: #f9f9f9;
        padding: 15px;
        border-radius: 5px;
        margin-bottom: 20px;
        border-left: 4px solid #4A6FA5;
    }
    
    .metadata-item {
        display: flex;
        flex-direction: column;
    }
    
    .metadata-label {
        font-weight: 600;
        color: #354B5E;
        font-size: 12px;
        text-transform: uppercase;
        margin-bottom: 5px;
    }
    
    .metadata-value {
        color: #666;
        font-size: 14px;
    }
    
    .status-badge {
        display: inline-block;
        padding: 8px 15px;
        border-radius: 20px;
        font-size: 12px;
        font-weight: 600;
        text-transform: uppercase;
        margin: 10px 0;
    }
    
    .status-success {
        background-color: #d4edda;
        color: #155724;
        border: 1px solid #c3e6cb;
    }
    
    .status-error {
        background-color: #f8d7da;
        color: #721c24;
        border: 1px solid #f5c6cb;
    }
    
    .status-warning {
        background-color: #fff3cd;
        color: #856404;
        border: 1px solid #ffeaa7;
    }
    
    .status-info {
        background-color: #d1ecf1;
        color: #0c5460;
        border: 1px solid #bee5eb;
    }
    
    table {
        width: 100%;
        border-collapse: collapse;
        margin-top: 15px;
        border-radius: 5px;
        overflow: hidden;
        box-shadow: 0 1px 3px rgba(0, 0, 0, 0.05);
    }
    
    table th {
        background-color: #354B5E;
        color: white;
        padding: 12px 15px;
        text-align: left;
        font-weight: 600;
        font-size: 13px;
        text-transform: uppercase;
        letter-spacing: 0.5px;
    }
    
    table td {
        padding: 12px 15px;
        border-bottom: 1px solid #e0e0e0;
        font-size: 13px;
    }
    
    table tr:hover {
        background-color: #f9f9f9;
    }
    
    table tr:nth-child(even) {
        background-color: #fafafa;
    }
    
    .cell-success {
        color: #28a745;
        font-weight: 600;
    }
    
    .cell-error {
        color: #dc3545;
        font-weight: 600;
    }
    
    .cell-warning {
        color: #ffc107;
        font-weight: 600;
    }
    
    .empty-state {
        text-align: center;
        padding: 30px;
        color: #999;
        background-color: #f9f9f9;
        border-radius: 5px;
        border: 1px dashed #ddd;
    }
    
    .footer {
        background-color: #f5f5f5;
        padding: 20px 30px;
        border-top: 1px solid #e0e0e0;
        font-size: 12px;
        color: #999;
        text-align: center;
    }
    
    .summary-grid {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
        gap: 15px;
        margin-bottom: 20px;
    }
    
    .summary-card {
        background-color: #f9f9f9;
        border-left: 4px solid #4A6FA5;
        padding: 15px;
        border-radius: 5px;
    }
    
    .summary-card h3 {
        font-size: 12px;
        color: #999;
        text-transform: uppercase;
        margin-bottom: 8px;
        font-weight: 600;
    }
    
    .summary-card .number {
        font-size: 28px;
        color: #354B5E;
        font-weight: 700;
    }
    
    @media print {
        body {
            background-color: white;
        }
        .container {
            box-shadow: none;
            margin: 0;
        }
    }
</style>
"@

# ============================================================================
# FUNCTION DEFINITIONS
# ============================================================================

<#
.SYNOPSIS
Initialize logging directory and files
#>
function Initialize-LoggingEnvironment {
    [CmdletBinding()]
    param()

    Try {
        if (-not (Test-Path -Path $LogDirectory)) {
            $null = New-Item -ItemType Directory -Path $LogDirectory -Force
            Write-Verbose "Created log directory: $LogDirectory"
        }

        # Create log file with header
        $header = @{
            "ScriptName"     = $ScriptName
            "ExecutionTime"  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            "ComputerName"   = $env:COMPUTERNAME
            "ExecutedBy"     = $env:USERNAME
            "PSVersion"      = $PSVersionTable.PSVersion.ToString()
            "OSInfo"         = (Get-WmiObject -Class Win32_OperatingSystem | Select-Object -ExpandProperty Caption)
        } | ConvertTo-Json -Depth 2

        Add-Content -Path $LogFile -Value "=== EXECUTION HEADER ===" -Encoding UTF8
        Add-Content -Path $LogFile -Value $header -Encoding UTF8
        Add-Content -Path $LogFile -Value "`n=== EXECUTION LOG ===" -Encoding UTF8

        Write-Verbose "Logging initialized to: $LogFile"
        return $true
    }
    Catch {
        Write-Error "Failed to initialize logging environment: $($_.Exception.Message)" -ErrorAction Stop
        return $false
    }
}

<#
.SYNOPSIS
Write structured log entries to file and optionally console
#>
function Write-LogEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")]
        [string]$Level,
        
        [Parameter(Mandatory)]
        [string]$Message,
        
        [switch]$ToConsole
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"

    Try {
        Add-Content -Path $LogFile -Value $logEntry -Encoding UTF8
        
        if ($EnableConsoleLogging -or $ToConsole) {
            switch ($Level) {
                "ERROR" { Write-Host $logEntry -ForegroundColor Red }
                "WARN" { Write-Host $logEntry -ForegroundColor Yellow }
                "SUCCESS" { Write-Host $logEntry -ForegroundColor Green }
                default { Write-Host $logEntry }
            }
        }
    }
    Catch {
        Write-Error "Failed to write log entry: $($_.Exception.Message)"
    }
}

<#
.SYNOPSIS
Discover installed Central Pro Shell instances via WMI
#>
function Get-InstalledCentralProShell {
    [CmdletBinding()]
    param()

    $foundProducts = @()

    Try {
        Write-Verbose "Querying installed products via WMI..."
        Write-LogEntry -Level "INFO" -Message "Initiating product discovery via WMI Win32_Product class"

        foreach ($pattern in $ProductSearchPatterns) {
            Try {
                $products = Get-WmiObject -Class Win32_Product -Filter "Name like '$pattern'" -ErrorAction SilentlyContinue

                if ($products) {
                    foreach ($product in $products) {
                        $productInfo = @{
                            Name           = $product.Name
                            Version        = $product.Version
                            Publisher      = $product.Vendor
                            IdentifyingNumber = $product.IdentifyingNumber
                            InstallLocation = $product.InstallLocation
                            DetectionMethod = "WMI"
                        }
                        $foundProducts += $productInfo
                        Write-Verbose "Found product: $($product.Name) v$($product.Version)"
                        Write-LogEntry -Level "INFO" -Message "WMI Discovery: Found '$($product.Name)' v$($product.Version) (GUID: $($product.IdentifyingNumber))"
                    }
                }
            }
            Catch {
                Write-LogEntry -Level "WARN" -Message "WMI query error for pattern '$pattern': $($_.Exception.Message)"
            }
        }
    }
    Catch {
        Write-LogEntry -Level "ERROR" -Message "Failed to query installed products: $($_.Exception.Message)"
    }

    return $foundProducts
}

<#
.SYNOPSIS
Search registry for uninstall strings matching Central Pro Shell
#>
function Get-UninstallStringFromRegistry {
    [CmdletBinding()]
    param()

    $foundUninstallers = @()
    $registryPaths = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\",
        "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\"
    )

    Try {
        Write-Verbose "Scanning registry for uninstall strings..."
        Write-LogEntry -Level "INFO" -Message "Scanning registry uninstall keys for Central Pro Shell"

        foreach ($regPath in $registryPaths) {
            Try {
                if (Test-Path -Path $regPath) {
                    $subkeys = Get-ChildItem -Path $regPath -ErrorAction SilentlyContinue

                    foreach ($subkey in $subkeys) {
                        $displayName = $subkey.GetValue("DisplayName")
                        $displayPublisher = $subkey.GetValue("Publisher")
                        $uninstallString = $subkey.GetValue("UninstallString")
                        $displayVersion = $subkey.GetValue("DisplayVersion")

                        if ($displayName -and ($displayName -like "*Central Pro Shell*" -or $displayName -like "*Ice.Shell*")) {
                            if ($displayPublisher -like "*Tyler*" -or -not $displayPublisher) {
                                $uninstallerInfo = @{
                                    DisplayName       = $displayName
                                    Publisher         = $displayPublisher
                                    Version           = $displayVersion
                                    UninstallString   = $uninstallString
                                    RegistryKey       = $subkey.PSPath
                                    DetectionMethod   = "Registry"
                                }
                                $foundUninstallers += $uninstallerInfo
                                Write-LogEntry -Level "INFO" -Message "Registry Discovery: Found '$displayName' at '$($subkey.PSPath)'"
                            }
                        }
                    }
                }
            }
            Catch {
                Write-LogEntry -Level "WARN" -Message "Error scanning registry path '$regPath': $($_.Exception.Message)"
            }
        }
    }
    Catch {
        Write-LogEntry -Level "ERROR" -Message "Failed to scan registry: $($_.Exception.Message)"
    }

    return $foundUninstallers
}

<#
.SYNOPSIS
Terminate running processes related to Central Pro Shell
#>
function Stop-CentralProShellProcesses {
    [CmdletBinding()]
    param()

    $terminatedProcesses = @()

    Try {
        Write-Verbose "Scanning for running Central Pro Shell processes..."
        Write-LogEntry -Level "INFO" -Message "Initiating process termination check"

        foreach ($processName in $ProcessNamesToTerminate) {
            Try {
                $processes = Get-Process -Name $processName -ErrorAction SilentlyContinue

                foreach ($process in $processes) {
                    Write-Verbose "Terminating process: $($process.Name) (PID: $($process.Id))"
                    Write-LogEntry -Level "WARN" -Message "Terminating process: $($process.Name) (PID: $($process.Id)) - Memory: $([math]::Round($process.WorkingSet/1MB, 2))MB"

                    $process | Stop-Process -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Milliseconds 500

                    if (-not (Get-Process -Id $process.Id -ErrorAction SilentlyContinue)) {
                        Write-LogEntry -Level "SUCCESS" -Message "Successfully terminated process: $($process.Name) (PID: $($process.Id))"
                        $terminatedProcesses += [PSCustomObject]@{
                            ProcessName = $process.Name
                            PID         = $process.Id
                            Status      = "Terminated"
                        }
                    }
                    else {
                        Write-LogEntry -Level "ERROR" -Message "Failed to terminate process: $($process.Name) (PID: $($process.Id))"
                        $terminatedProcesses += [PSCustomObject]@{
                            ProcessName = $process.Name
                            PID         = $process.Id
                            Status      = "Failed to Terminate"
                        }
                    }
                }
            }
            Catch {
                Write-LogEntry -Level "WARN" -Message "Error checking process '$processName': $($_.Exception.Message)"
            }
        }
    }
    Catch {
        Write-LogEntry -Level "ERROR" -Message "Failed during process termination: $($_.Exception.Message)"
    }

    return $terminatedProcesses
}

<#
.SYNOPSIS
Execute uninstall via WMI (Win32_Product.Uninstall method)
#>
function Uninstall-ViaMSI {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject[]]$Products
    )

    $uninstallResults = @()

    foreach ($product in $Products) {
        Try {
            Write-Verbose "Uninstalling via MSI: $($product.IdentifyingNumber)"
            Write-LogEntry -Level "INFO" -Message "Initiating MSI uninstall for '$($product.Name)' (GUID: $($product.IdentifyingNumber))"

            $wmiProduct = Get-WmiObject -Class Win32_Product -Filter "IdentifyingNumber='$($product.IdentifyingNumber)'" -ErrorAction Stop

            if ($wmiProduct) {
                $returnCode = $wmiProduct.Uninstall().ReturnValue

                Start-Sleep -Seconds 2

                $stillExists = Get-WmiObject -Class Win32_Product -Filter "IdentifyingNumber='$($product.IdentifyingNumber)'" -ErrorAction SilentlyContinue

                if (-not $stillExists) {
                    Write-LogEntry -Level "SUCCESS" -Message "MSI uninstall successful for '$($product.Name)' (Return Code: $returnCode)"
                    $uninstallResults += [PSCustomObject]@{
                        Product        = $product.Name
                        Version        = $product.Version
                        Method         = "MSI"
                        Status         = "Success"
                        ReturnCode     = $returnCode
                        Timestamp      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    }
                }
                else {
                    Write-LogEntry -Level "ERROR" -Message "MSI uninstall claimed success, but product still exists: $($product.Name)"
                    $uninstallResults += [PSCustomObject]@{
                        Product        = $product.Name
                        Version        = $product.Version
                        Method         = "MSI"
                        Status         = "Failed"
                        ReturnCode     = $returnCode
                        Error          = "Product still detected after uninstall"
                        Timestamp      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    }
                }
            }
        }
        Catch {
            Write-LogEntry -Level "ERROR" -Message "MSI uninstall failed for '$($product.Name)': $($_.Exception.Message)"
            $uninstallResults += [PSCustomObject]@{
                Product    = $product.Name
                Version    = $product.Version
                Method     = "MSI"
                Status     = "Failed"
                Error      = $_.Exception.Message
                Timestamp  = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            }
        }
    }

    return $uninstallResults
}

<#
.SYNOPSIS
Execute uninstall via registry UninstallString
#>
function Uninstall-ViaRegistry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject[]]$Uninstallers
    )

    $uninstallResults = @()

    foreach ($uninstaller in $Uninstallers) {
        Try {
            Write-Verbose "Executing uninstall string: $($uninstaller.UninstallString)"
            Write-LogEntry -Level "INFO" -Message "Initiating registry-based uninstall for '$($uninstaller.DisplayName)'"

            if ($uninstaller.UninstallString -like "msiexec*") {
                $msiexecArgs = $uninstaller.UninstallString -replace "msiexec.exe", "" -replace "^/i", "/x"
                $msiexecArgs += " /quiet /norestart"
                
                Write-Verbose "Executing MSI via registry string: msiexec.exe $msiexecArgs"
                $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiexecArgs -Wait -PassThru -NoNewWindow -ErrorAction Stop
                $returnCode = $process.ExitCode
            }
            else {
                $exePath = $uninstaller.UninstallString -replace '"', ""
                $uninstallArgs = "/S /quiet /norestart"
                
                Write-Verbose "Executing uninstall executable: $exePath $uninstallArgs"
                $process = Start-Process -FilePath $exePath -ArgumentList $uninstallArgs -Wait -PassThru -NoNewWindow -ErrorAction Stop
                $returnCode = $process.ExitCode
            }

            Start-Sleep -Seconds 2

            $stillExists = Get-WmiObject -Class Win32_Product -Filter "Name like '$($uninstaller.DisplayName)'" -ErrorAction SilentlyContinue

            if (-not $stillExists) {
                Write-LogEntry -Level "SUCCESS" -Message "Registry-based uninstall successful for '$($uninstaller.DisplayName)' (Return Code: $returnCode)"
                $uninstallResults += [PSCustomObject]@{
                    Product        = $uninstaller.DisplayName
                    Version        = $uninstaller.Version
                    Method         = "Registry"
                    Status         = "Success"
                    ReturnCode     = $returnCode
                    Timestamp      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                }
            }
            else {
                Write-LogEntry -Level "WARN" -Message "Registry-based uninstall completed, but product still detected: $($uninstaller.DisplayName)"
                $uninstallResults += [PSCustomObject]@{
                    Product        = $uninstaller.DisplayName
                    Version        = $uninstaller.Version
                    Method         = "Registry"
                    Status         = "Failed"
                    ReturnCode     = $returnCode
                    Error          = "Product still detected after uninstall"
                    Timestamp      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                }
            }
        }
        Catch {
            Write-LogEntry -Level "ERROR" -Message "Registry-based uninstall failed for '$($uninstaller.DisplayName)': $($_.Exception.Message)"
            $uninstallResults += [PSCustomObject]@{
                Product    = $uninstaller.DisplayName
                Version    = $uninstaller.Version
                Method     = "Registry"
                Status     = "Failed"
                Error      = $_.Exception.Message
                Timestamp  = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            }
        }
    }

    return $uninstallResults
}

<#
.SYNOPSIS
Generate professional HTML execution report
#>
function Generate-HTMLExecutionReport {
    [CmdletBinding()]
    param(
        [PSCustomObject[]]$TerminatedProcesses,
        [PSCustomObject[]]$UninstallResults,
        [string]$ExecutionStatus,
        [int]$DiscoveredProductCount,
        [int]$DiscoveredRegistryCount
    )

    Try {
        Write-Verbose "Generating HTML execution report..."
        Write-LogEntry -Level "INFO" -Message "Generating HTML report"

        # Determine status badge styling
        $statusBadgeClass = switch ($ExecutionStatus) {
            "SUCCESS" { "status-success" }
            "COMPLETED_WITH_ERRORS" { "status-error" }
            "COMPLETED_VERIFICATION_INCONCLUSIVE" { "status-warning" }
            default { "status-info" }
        }

        # Build process termination section
        $processTableHTML = ""
        if ($TerminatedProcesses.Count -gt 0) {
            $processTableHTML = "<table>"
            $processTableHTML += "<tr><th>Process Name</th><th>PID</th><th>Status</th></tr>"
            foreach ($proc in $TerminatedProcesses) {
                $statusClass = if ($proc.Status -eq "Terminated") { "cell-success" } else { "cell-error" }
                $processTableHTML += "<tr><td>$($proc.ProcessName)</td><td>$($proc.PID)</td><td><span class='$statusClass'>$($proc.Status)</span></td></tr>"
            }
            $processTableHTML += "</table>"
        }
        else {
            $processTableHTML = "<div class='empty-state'>No processes found to terminate</div>"
        }

        # Build uninstall results section
        $uninstallTableHTML = ""
        if ($UninstallResults.Count -gt 0) {
            $uninstallTableHTML = "<table>"
            $uninstallTableHTML += "<tr><th>Product</th><th>Version</th><th>Method</th><th>Status</th><th>Return Code</th></tr>"
            foreach ($result in $UninstallResults) {
                $statusClass = if ($result.Status -eq "Success") { "cell-success" } else { "cell-error" }
                $returnCode = if ($result.ReturnCode) { $result.ReturnCode } else { "N/A" }
                $uninstallTableHTML += "<tr><td>$($result.Product)</td><td>$($result.Version)</td><td>$($result.Method)</td><td><span class='$statusClass'>$($result.Status)</span></td><td>$returnCode</td></tr>"
            }
            $uninstallTableHTML += "</table>"
        }
        else {
            $uninstallTableHTML = "<div class='empty-state'>No uninstall operations performed</div>"
        }

        # Calculate success metrics
        $successfulUninstalls = if ($UninstallResults) { ($UninstallResults | Where-Object { $_.Status -eq "Success" }).Count } else { 0 }
        $failedUninstalls = if ($UninstallResults) { ($UninstallResults | Where-Object { $_.Status -eq "Failed" }).Count } else { 0 }

        # Build HTML document
        $htmlContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Uninstall-CentralProShell Report</title>
    $HTMLStyles
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>Central Pro Shell Uninstall Report</h1>
            <p>Tyler Technologies Application Removal</p>
        </div>
        
        <div class="content">
            <!-- Status Badge -->
            <div style="text-align: center;">
                <span class="status-badge $statusBadgeClass">$ExecutionStatus</span>
            </div>
            
            <!-- Execution Metadata -->
            <div class="section">
                <h2>Execution Information</h2>
                <div class="metadata">
                    <div class="metadata-item">
                        <span class="metadata-label">Computer Name</span>
                        <span class="metadata-value">$($env:COMPUTERNAME)</span>
                    </div>
                    <div class="metadata-item">
                        <span class="metadata-label">Executed By</span>
                        <span class="metadata-value">$($env:USERNAME)</span>
                    </div>
                    <div class="metadata-item">
                        <span class="metadata-label">Execution Time</span>
                        <span class="metadata-value">$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")</span>
                    </div>
                    <div class="metadata-item">
                        <span class="metadata-label">PowerShell Version</span>
                        <span class="metadata-value">$($PSVersionTable.PSVersion.ToString())</span>
                    </div>
                    <div class="metadata-item">
                        <span class="metadata-label">Operating System</span>
                        <span class="metadata-value">$($(Get-WmiObject -Class Win32_OperatingSystem | Select-Object -ExpandProperty Caption))</span>
                    </div>
                    <div class="metadata-item">
                        <span class="metadata-label">Log File</span>
                        <span class="metadata-value">$LogFile</span>
                    </div>
                </div>
            </div>
            
            <!-- Summary Metrics -->
            <div class="section">
                <h2>Summary Metrics</h2>
                <div class="summary-grid">
                    <div class="summary-card">
                        <h3>Discovered Products (WMI)</h3>
                        <div class="number">$DiscoveredProductCount</div>
                    </div>
                    <div class="summary-card">
                        <h3>Discovered Registry Entries</h3>
                        <div class="number">$DiscoveredRegistryCount</div>
                    </div>
                    <div class="summary-card">
                        <h3>Successful Uninstalls</h3>
                        <div class="number" style="color: #28a745;">$successfulUninstalls</div>
                    </div>
                    <div class="summary-card">
                        <h3>Failed Uninstalls</h3>
                        <div class="number" style="color: #dc3545;">$failedUninstalls</div>
                    </div>
                </div>
            </div>
            
            <!-- Process Termination Section -->
            <div class="section">
                <h2>Process Termination Results</h2>
                $processTableHTML
            </div>
            
            <!-- Uninstall Operations Section -->
            <div class="section">
                <h2>Uninstall Operations</h2>
                $uninstallTableHTML
            </div>
            
            <!-- Additional Information -->
            <div class="section">
                <h2>Additional Information</h2>
                <div style="background-color: #f9f9f9; padding: 15px; border-radius: 5px; border-left: 4px solid #4A6FA5;">
                    <p><strong>Detection Methods Used:</strong></p>
                    <ul style="margin-top: 10px; margin-left: 20px;">
                        <li>WMI Win32_Product class query</li>
                        <li>Registry HKLM Uninstall scan (32-bit and 64-bit)</li>
                        <li>Process matching against known process names</li>
                    </ul>
                    
                    <p style="margin-top: 15px;"><strong>Log Location:</strong></p>
                    <ul style="margin-top: 10px; margin-left: 20px;">
                        <li>Detailed Log: <code>$LogFile</code></li>
                        <li>Error Log: <code>$ErrorLogFile</code></li>
                    </ul>
                    
                    <p style="margin-top: 15px;"><strong>Recommendations:</strong></p>
                    <ul style="margin-top: 10px; margin-left: 20px;">
                        <li>Verify system restart if required by Windows Installer</li>
                        <li>Review logs for any warnings or errors</li>
                        <li>Confirm application removal via Control Panel or Programs and Features</li>
                    </ul>
                </div>
            </div>
        </div>
        
        <div class="footer">
            <p>Report generated by Uninstall-CentralProShell automation script | $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")</p>
            <p>For support, review logs at: $LogDirectory</p>
        </div>
    </div>
</body>
</html>
"@

        $htmlContent | Out-File -FilePath $ReportFile -Encoding UTF8 -Force
        Write-LogEntry -Level "SUCCESS" -Message "HTML execution report generated: $ReportFile"

        return $ReportFile
    }
    Catch {
        Write-LogEntry -Level "ERROR" -Message "Failed to generate HTML report: $($_.Exception.Message)"
        return $null
    }
}

<#
.SYNOPSIS
Post-check to verify uninstall success
#>
function Test-UninstallSuccess {
    [CmdletBinding()]
    param()

    Try {
        Write-Verbose "Executing post-uninstall verification..."
        Write-LogEntry -Level "INFO" -Message "Performing post-uninstall verification"

        $remainingProducts = Get-WmiObject -Class Win32_Product -ErrorAction SilentlyContinue | 
            Where-Object { $_.Name -like "*Central Pro Shell*" -or $_.Name -like "*Ice.Shell*" }

        if ($remainingProducts) {
            Write-LogEntry -Level "ERROR" -Message "Post-check FAILED: $($remainingProducts.Count) instance(s) of Central Pro Shell still present"
            return $false
        }
        else {
            Write-LogEntry -Level "SUCCESS" -Message "Post-check PASSED: No instances of Central Pro Shell detected"
            return $true
        }
    }
    Catch {
        Write-LogEntry -Level "WARN" -Message "Post-check verification error: $($_.Exception.Message)"
        return $null
    }
}

# ============================================================================
# MAIN EXECUTION FLOW
# ============================================================================

Try {
    Write-Verbose "============= SCRIPT EXECUTION START ============="
    
    # Initialize logging
    if (-not (Initialize-LoggingEnvironment)) {
        Write-Error "Failed to initialize logging. Exiting." -ErrorAction Stop
    }

    Write-LogEntry -Level "INFO" -Message "Script execution initiated"
    Write-LogEntry -Level "INFO" -Message "Target: Tyler Technologies Central Pro Shell (all versions)"

    # Step 1: Terminate running processes
    if (-not $SkipProcessKill) {
        Write-LogEntry -Level "INFO" -Message "Step 1/4: Terminating Central Pro Shell processes"
        $terminatedProcesses = Stop-CentralProShellProcesses
    }
    else {
        Write-LogEntry -Level "INFO" -Message "Step 1/4: Skipped process termination (SkipProcessKill enabled)"
        $terminatedProcesses = @()
    }

    # Step 2: Discover installed products
    Write-LogEntry -Level "INFO" -Message "Step 2/4: Discovering installed Central Pro Shell instances"
    $discoveredProducts = Get-InstalledCentralProShell
    $discoveredUninstallers = Get-UninstallStringFromRegistry

    if ($discoveredProducts.Count -eq 0 -and $discoveredUninstallers.Count -eq 0) {
        Write-LogEntry -Level "WARN" -Message "No instances of Central Pro Shell detected on system"
        $overallStatus = "COMPLETED_NO_ACTION"
        $allUninstallResults = @()
    }
    else {
        Write-LogEntry -Level "INFO" -Message "Discovery Results: $($discoveredProducts.Count) WMI product(s), $($discoveredUninstallers.Count) registry entry(s)"

        # Step 3: Execute uninstall operations
        Write-LogEntry -Level "INFO" -Message "Step 3/4: Executing uninstall operations"
        $msiResults = @()
        $regResults = @()

        if ($discoveredProducts.Count -gt 0) {
            $msiResults = Uninstall-ViaMSI -Products $discoveredProducts
        }

        if ($discoveredUninstallers.Count -gt 0) {
            $regResults = Uninstall-ViaRegistry -Uninstallers $discoveredUninstallers
        }

        $allUninstallResults = $msiResults + $regResults

        # Step 4: Post-check verification
        Write-LogEntry -Level "INFO" -Message "Step 4/4: Post-uninstall verification"
        $postCheckResult = Test-UninstallSuccess

        if ($postCheckResult) {
            $overallStatus = "SUCCESS"
        }
        elseif ($postCheckResult -eq $false) {
            $overallStatus = "COMPLETED_WITH_ERRORS"
        }
        else {
            $overallStatus = "COMPLETED_VERIFICATION_INCONCLUSIVE"
        }
    }

    # Generate final HTML report
    $reportPath = Generate-HTMLExecutionReport -TerminatedProcesses $terminatedProcesses -UninstallResults $allUninstallResults -ExecutionStatus $overallStatus -DiscoveredProductCount $discoveredProducts.Count -DiscoveredRegistryCount $discoveredUninstallers.Count

    Write-LogEntry -Level "INFO" -Message "Script execution completed with status: $overallStatus"
    Write-LogEntry -Level "INFO" -Message "Output files: Log=$LogFile | Report=$ReportFile"
    Write-Verbose "============= SCRIPT EXECUTION END ============="

    # Exit with appropriate code
    if ($overallStatus -eq "SUCCESS") {
        exit 0
    }
    else {
        exit 1
    }
}
Catch {
    Write-LogEntry -Level "ERROR" -Message "FATAL ERROR: $($_.Exception.Message)"
    Write-LogEntry -Level "ERROR" -Message "Stack Trace: $($_.ScriptStackTrace)"
    
    if (Test-Path $ErrorLogFile) {
        $_.Exception | Out-File -FilePath $ErrorLogFile -Append -Encoding UTF8
    }
    
    exit 255
}