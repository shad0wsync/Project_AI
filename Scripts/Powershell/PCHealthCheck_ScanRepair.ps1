#Requires -Version 5.1

<#
.SYNOPSIS
    PC Health Check Script with Scan and Repair Options

.DESCRIPTION
    This script performs system health checks using DISM, SFC, and CHKDSK.
    It allows the user to choose between scan-only or scan and repair modes.
    Results are exported to HTML and JSON files in C:\temp\
    Hardened for production use with logging, timeouts, and safety checks.

.PARAMETER Repair
    Switch to enable repair mode. If not specified, only scans are performed.

.PARAMETER WhatIf
    Switch to simulate operations without executing repairs.

.PARAMETER LogPath
    Path to save transcript log file.

.PARAMETER Timeout
    Timeout in minutes for long-running operations (default: 60).

.EXAMPLE
    .\PCHealthCheck_ScanRepair.ps1

    Prompts for scan or repair mode.

.EXAMPLE
    .\PCHealthCheck_ScanRepair.ps1 -Repair

    Runs scans and repairs without prompting.

.EXAMPLE
    .\PCHealthCheck_ScanRepair.ps1 -WhatIf

    Simulates all operations for testing.
#>

param(
    [switch]$Repair,
    [switch]$WhatIf,
    [string]$LogPath = "$env:TEMP\PCHealthCheck_ScanRepair.log",
    [int]$Timeout = 60
)

# Script metadata
$ScriptVersion = "1.1.0"
$ScriptDate = "2026-04-16"

# Validate OS
$osInfo = Get-CimInstance -ClassName Win32_OperatingSystem
if ($osInfo.Caption -notmatch "Windows 10|Windows 11|Windows Server") {
    Write-Error "This script requires Windows 10, 11, or Server 2016+. Current OS: $($osInfo.Caption)"
    exit 1
}

# Start transcript logging
Start-Transcript -Path $LogPath -Append

try {
    # Script name for output
    $scriptName = "PCHealthCheck_ScanRepair"

    # Timestamp for output files
    $timestamp = Get-Date -Format "MM_dd_yy_HH_mm_ss"

    # Output directory
    $outputDir = "C:\temp"
    if (-not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    # Base name for output files
    $baseName = "$outputDir\$scriptName$timestamp"

    # Results hashtable
    $results = @{
        ScriptVersion = $ScriptVersion
        Timestamp     = $timestamp
        Mode          = if ($Repair) { 'Scan and Repair' } else { 'Scan Only' }
        WhatIf        = $WhatIf
        OS            = $osInfo.Caption
        PSVersion     = $PSVersionTable.PSVersion.ToString()
    }

    # Check if running as admin
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $results.AdminPrivileges = $isAdmin
    if (-not $isAdmin) {
        Write-Warning "This script requires Administrator privileges for full functionality."
        Write-Warning "Some operations may fail or be skipped."
    }

    # Prompt user if not specified and not WhatIf
    if (-not $Repair -and -not $WhatIf) {
        $choice = Read-Host "Do you want to run scan only (S) or scan and repair (R)? [S/R]"
        if ($choice -eq 'R' -or $choice -eq 'r') {
            $Repair = $true
        }
    }

    Write-Host "Starting PC Health Check v$ScriptVersion..." -ForegroundColor Green
    Write-Host "Mode: $($results.Mode)" -ForegroundColor Cyan
    if ($WhatIf) { Write-Host "WhatIf mode enabled - no changes will be made" -ForegroundColor Yellow }

    # Helper function to run command with timeout and console progress
    function Invoke-CommandWithTimeout {
        param(
            [string]$Command,
            [string]$Arguments,
            [int]$TimeoutMinutes = $Timeout
        )
        
        $stdoutFile = Join-Path $env:TEMP "cmd_out.txt"
        $stderrFile = Join-Path $env:TEMP "cmd_err.txt"

        if (Test-Path $stdoutFile) { Remove-Item $stdoutFile -Force -ErrorAction SilentlyContinue }
        if (Test-Path $stderrFile) { Remove-Item $stderrFile -Force -ErrorAction SilentlyContinue }

        $process = Start-Process -FilePath $Command -ArgumentList $Arguments -NoNewWindow -PassThru -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
        
        $timeout = $TimeoutMinutes * 60 * 1000  # Convert to milliseconds
        $startTime = Get-Date
        $activity = "$Command $Arguments"

        while (-not $process.HasExited) {
            $elapsed = (Get-Date) - $startTime
            $percent = [int]((($elapsed.TotalMilliseconds) / $timeout) * 100)
            if ($percent -gt 99) { $percent = 99 }
            Write-Progress -Activity $activity -Status "Elapsed $([int]$elapsed.TotalMinutes)m $([int]$elapsed.Seconds)s" -PercentComplete $percent
            Start-Sleep -Seconds 3
            if ($process.WaitForExit(0)) { break }
        }

        if ($process.HasExited) {
            Write-Progress -Activity $activity -Completed
            $output = Get-Content $stdoutFile -Raw -ErrorAction SilentlyContinue
            $errorOutput = Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue
            return ($output + $errorOutput).Trim()
        }

        $process.Kill()
        Write-Progress -Activity $activity -Status "Timed out" -Completed
        throw "Command timed out after $TimeoutMinutes minutes"
    }

    # DISM Scan
    Write-Host "Running DISM scan..." -ForegroundColor Yellow
    try {
        if (-not $WhatIf) {
            $results.DISM_Scan = Invoke-CommandWithTimeout -Command "dism.exe" -Arguments "/online /cleanup-image /scanhealth"
        } else {
            $results.DISM_Scan = "WhatIf: Would run DISM /online /cleanup-image /scanhealth"
        }
        Write-Host "DISM scan completed." -ForegroundColor Green
    } catch {
        $results.DISM_Scan = "Error running DISM scan: $_"
        Write-Host "DISM scan failed." -ForegroundColor Red
    }

    if ($Repair) {
        Write-Host "Running DISM repair..." -ForegroundColor Yellow
        try {
            if (-not $WhatIf) {
                $results.DISM_Repair = Invoke-CommandWithTimeout -Command "dism.exe" -Arguments "/online /cleanup-image /restorehealth"
            } else {
                $results.DISM_Repair = "WhatIf: Would run DISM /online /cleanup-image /restorehealth"
            }
            Write-Host "DISM repair completed." -ForegroundColor Green
        } catch {
            $results.DISM_Repair = "Error running DISM repair: $_"
            Write-Host "DISM repair failed." -ForegroundColor Red
        }
    }

    # SFC Scan/Repair
    Write-Host "Running SFC..." -ForegroundColor Yellow
    try {
        if (-not $WhatIf) {
            $results.SFC = Invoke-CommandWithTimeout -Command "sfc.exe" -Arguments "/scannow"
        } else {
            $results.SFC = "WhatIf: Would run SFC /scannow"
        }
        Write-Host "SFC completed." -ForegroundColor Green
    } catch {
        $results.SFC = "Error running SFC: $_"
        Write-Host "SFC failed." -ForegroundColor Red
    }

    # CHKDSK Scan
    Write-Host "Running CHKDSK scan..." -ForegroundColor Yellow
    try {
        if (-not $WhatIf) {
            $results.CHKDSK_Scan = Invoke-CommandWithTimeout -Command "chkdsk.exe" -Arguments "/scan C:"
        } else {
            $results.CHKDSK_Scan = "WhatIf: Would run CHKDSK /scan C:"
        }
        Write-Host "CHKDSK scan completed." -ForegroundColor Green
    } catch {
        $results.CHKDSK_Scan = "Error running CHKDSK scan: $_"
        Write-Host "CHKDSK scan failed." -ForegroundColor Red
    }

    if ($Repair) {
        Write-Host "Scheduling CHKDSK repair..." -ForegroundColor Yellow
        try {
            if (-not $WhatIf) {
                # Use cmd to automate the Y response
                $results.CHKDSK_Repair = cmd /c "echo Y | chkdsk /f C:" 2>&1 | Out-String
            } else {
                $results.CHKDSK_Repair = "WhatIf: Would schedule CHKDSK /f C:"
            }
            Write-Host "CHKDSK repair scheduled." -ForegroundColor Green
        } catch {
            $results.CHKDSK_Repair = "Error scheduling CHKDSK repair: $_"
            Write-Host "CHKDSK repair scheduling failed." -ForegroundColor Red
        }
    }

    # Export to JSON
    Write-Host "Exporting results to JSON..." -ForegroundColor Cyan
    $results | ConvertTo-Json -Depth 10 | Out-File "$baseName.json" -Encoding UTF8

    # Generate HTML
    Write-Host "Generating HTML report..." -ForegroundColor Cyan
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>PC Health Check Report v$ScriptVersion</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; margin: 0; padding: 20px; background-color: #f5f5f5; }
        .container { max-width: 1200px; margin: 0 auto; background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        h1 { color: #2c3e50; border-bottom: 3px solid #3498db; padding-bottom: 10px; }
        h2 { color: #34495e; margin-top: 30px; border-left: 4px solid #3498db; padding-left: 10px; }
        .metadata { background: #ecf0f1; padding: 15px; border-radius: 5px; margin-bottom: 20px; }
        .metadata strong { color: #2c3e50; }
        pre { background-color: #2d3748; color: #e2e8f0; padding: 15px; border-radius: 5px; overflow-x: auto; font-family: 'Courier New', monospace; font-size: 14px; }
        .warning { background: #fff3cd; border: 1px solid #ffeaa7; color: #856404; padding: 10px; border-radius: 5px; margin: 10px 0; }
        .error { background: #f8d7da; border: 1px solid #f5c6cb; color: #721c24; padding: 10px; border-radius: 5px; margin: 10px 0; }
        .success { background: #d4edda; border: 1px solid #c3e6cb; color: #155724; padding: 10px; border-radius: 5px; margin: 10px 0; }
        table { width: 100%; border-collapse: collapse; margin: 20px 0; }
        th, td { border: 1px solid #ddd; padding: 12px; text-align: left; }
        th { background-color: #f8f9fa; font-weight: bold; }
        .footer { margin-top: 30px; padding-top: 20px; border-top: 1px solid #eee; color: #7f8c8d; font-size: 14px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>PC Health Check Report v$ScriptVersion</h1>
        
        <div class="metadata">
            <p><strong>Generated on:</strong> $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
            <p><strong>Mode:</strong> $($results.Mode)</p>
            <p><strong>WhatIf Mode:</strong> $($results.WhatIf)</p>
            <p><strong>Operating System:</strong> $($results.OS)</p>
            <p><strong>PowerShell Version:</strong> $($results.PSVersion)</p>
            <p><strong>Administrator Privileges:</strong> $($results.AdminPrivileges)</p>
        </div>
        
        <h2>DISM Scan</h2>
        <pre>$($results.DISM_Scan)</pre>
"@

    if ($Repair) {
        $html += @"
        <h2>DISM Repair</h2>
        <pre>$($results.DISM_Repair)</pre>
"@
    }

    $html += @"
        <h2>SFC</h2>
        <pre>$($results.SFC)</pre>
        
        <h2>CHKDSK Scan</h2>
        <pre>$($results.CHKDSK_Scan)</pre>
"@

    if ($Repair) {
        $html += @"
        <h2>CHKDSK Repair</h2>
        <pre>$($results.CHKDSK_Repair)</pre>
"@
    }

    $html += @"
        <div class="footer">
            <p><strong>Important Notes:</strong></p>
            <ul>
                <li>CHKDSK repairs may require a system restart to complete.</li>
                <li>For rollback, use System Restore or backup recovery.</li>
                <li>Review official Microsoft documentation for detailed error codes.</li>
                <li>Log file: $LogPath</li>
            </ul>
        </div>
    </div>
</body>
</html>
"@

    $html | Out-File "$baseName.html" -Encoding UTF8

    Write-Host "Report saved to:" -ForegroundColor Green
    Write-Host "  HTML: $baseName.html" -ForegroundColor Green
    Write-Host "  JSON: $baseName.json" -ForegroundColor Green
    Write-Host "  Log: $LogPath" -ForegroundColor Green

    Write-Host "PC Health Check completed successfully." -ForegroundColor Green

} finally {
    Stop-Transcript
}