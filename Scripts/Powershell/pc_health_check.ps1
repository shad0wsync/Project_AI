<#
.SYNOPSIS
Runs a general PC health check, exports results to sortable HTML, and provides remediation suggestions.
.DESCRIPTION
This script runs DISM image health checking, disk space analysis, disk error scans, network connectivity validation, and recent Event Viewer error collection.
It exports results to C:\Temp\pc_health_check\<computername>_MM-DD-YY_HH-MM-SS.html.
#>

[CmdletBinding()]
param ()

function New-OutputFile {
    $computerName = $env:COMPUTERNAME
    $timestamp = Get-Date -Format 'MM-dd-yy_HH-mm-ss'
    $outputDir = 'C:\Temp\pc_health_check'
    if (-not (Test-Path -Path $outputDir)) {
        New-Item -Path $outputDir -ItemType Directory | Out-Null
    }

    return Join-Path -Path $outputDir -ChildPath "${computerName}_${timestamp}.html"
}

function Invoke-DismCheck {
    Write-Host 'Running DISM image health check...'
    $result = & dism.exe /Online /Cleanup-Image /CheckHealth 2>&1
    $status = if ($LASTEXITCODE -eq 0) { 'Healthy' } else { 'IssuesFound' }

    return [pscustomobject]@{
        Test       = 'DISM CheckHealth'
        Status     = $status
        Details    = ($result -join "`n")
        Suggestion = if ($status -eq 'IssuesFound') { 'Run: DISM /Online /Cleanup-Image /RestoreHealth' } else { 'No action required.' }
    }
}

function Get-FixedVolumes {
    if (Get-Command Get-Volume -ErrorAction SilentlyContinue) {
        return Get-Volume | Where-Object { ($_.DriveType -eq 'Fixed' -or $_.DriveType -eq 3) -and $_.DriveLetter } | Select-Object DriveLetter, FileSystem, Size, SizeRemaining, HealthStatus
    }

    $logicalDisks = Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3'
    foreach ($disk in $logicalDisks) {
        [pscustomobject]@{
            DriveLetter   = [string]$disk.DeviceID.TrimEnd(':')
            FileSystem    = $disk.FileSystem
            Size          = [int64]$disk.Size
            SizeRemaining = [int64]$disk.FreeSpace
            HealthStatus  = 'Healthy'
        }
    }
}

function Get-DiskSpaceReport {
    Write-Host 'Collecting disk space information...'
    Get-FixedVolumes | Sort-Object -Property DriveLetter | ForEach-Object {
        if ($null -ne $_.DriveLetter) { $driveLabel = "$($_.DriveLetter):" } else { $driveLabel = $_.Path }
        [pscustomobject]@{
            Drive        = $driveLabel
            FileSystem   = $_.FileSystem
            SizeGB       = '{0:N2}' -f ($_.Size / 1GB)
            FreeSpaceGB  = '{0:N2}' -f ($_.SizeRemaining / 1GB)
            FreePercent  = '{0:N2}' -f (($_.SizeRemaining / $_.Size) * 100)
            HealthStatus = $_.HealthStatus
        }
    }
}

function Invoke-DiskErrorChecks {
    Write-Host 'Scanning fixed volumes for disk errors...'
    $results = @()
    $volumes = Get-FixedVolumes | Sort-Object DriveLetter

    foreach ($volume in $volumes) {
        $driveLetter = $volume.DriveLetter
        if (-not $driveLetter) { continue }

        $driveLabel = '{0}:' -f $driveLetter
        Write-Host ('Scanning ' + $driveLabel)

        if (Get-Command Repair-Volume -ErrorAction SilentlyContinue) {
            try {
                $scan = Repair-Volume -DriveLetter $driveLetter -Scan -ErrorAction Stop
                $status = if ($scan.IsCorrupted) { 'CorruptionFound' } else { 'NoErrorsFound' }
                if ($status -eq 'CorruptionFound') {
                    $suggestion = 'Run: Repair-Volume -DriveLetter ' + $driveLetter + ' -OfflineScanAndFix or chkdsk ' + $driveLetter + ' /f'
                } else {
                    $suggestion = 'No action required.'
                }

                $results += [pscustomobject]@{
                    Drive      = $driveLabel
                    Status     = $status
                    Details    = $scan.Message
                    Suggestion = $suggestion
                }
            } catch {
                $results += [pscustomobject]@{
                    Drive      = $driveLabel
                    Status     = 'ScanFailed'
                    Details    = $_.Exception.Message
                    Suggestion = 'Run disk scan manually: chkdsk ' + $driveLetter + ' /f'
                }
            }
        } else {
            $results += [pscustomobject]@{
                Drive      = $driveLabel
                Status     = 'NotSupported'
                Details    = 'Repair-Volume is not available on this host.'
                Suggestion = 'Run disk scan manually: chkdsk ' + $driveLetter + ' /f'
            }
        }
    }

    return $results
}

function Invoke-NetworkConnectivityCheck {
    Write-Verbose 'Checking network connectivity...'

    $details = @()
    $pingSuccess = $false
    $tcpSuccess = $false
    $dnsSuccess = $false

    if (Get-Command Test-NetConnection -ErrorAction SilentlyContinue) {
        try {
            $pingResult = Test-NetConnection -ComputerName 8.8.8.8 -InformationLevel Detailed -WarningAction SilentlyContinue
            $pingSuccess = $pingResult.PingSucceeded
            $details += "ICMP 8.8.8.8: $($pingResult.PingSucceeded)"
        } catch {
            $details += "ICMP check failed: $($_.Exception.Message)"
        }

        try {
            $tcpResult = Test-NetConnection -ComputerName google.com -Port 443 -WarningAction SilentlyContinue
            $tcpSuccess = $tcpResult.TcpTestSucceeded
            $details += "TCP 443 to google.com: $($tcpResult.TcpTestSucceeded)"
        } catch {
            $details += "TCP check failed: $($_.Exception.Message)"
        }
    } else {
        $details += 'Test-NetConnection is not available on this host.'
    }

    try {
        $dnsResult = Resolve-DnsName -Name google.com -ErrorAction Stop
        $dnsSuccess = $true
        $details += "DNS resolved google.com to $($dnsResult[0].IPAddress)"
    } catch {
        $details += "DNS resolution failed: $($_.Exception.Message)"
    }

    $status = if ($pingSuccess -and $tcpSuccess -and $dnsSuccess) { 'Online' } else { 'Offline' }

    return [pscustomobject]@{
        Test          = 'Network Connectivity'
        Status        = $status
        Ping          = $pingSuccess
        Tcp443        = $tcpSuccess
        DnsResolution = $dnsSuccess
        Details       = $details -join "`n"
        Suggestion    = if ($status -eq 'Online') { 'No action required.' } else { 'Verify gateway, DNS, and firewall rules. Run Test-NetConnection or Test-Connection to isolate the failure.' }
    }
}

function Get-RecentEventErrors {
    Write-Verbose 'Collecting latest Event Viewer errors...'

    try {
        $events = Get-WinEvent -FilterHashtable @{ LogName = @('System', 'Application'); Level = 2 } -MaxEvents 10 -ErrorAction Stop | Sort-Object TimeCreated -Descending
        return $events | Select-Object @{Name = 'TimeCreated'; Expression = { $_.TimeCreated } }, @{Name = 'LogName'; Expression = { $_.LogName } }, @{Name = 'ProviderName'; Expression = { $_.ProviderName } }, Id, @{Name = 'Message'; Expression = { $_.Message } }
    } catch {
        Write-Verbose "Event query failed: $($_.Exception.Message)"
        return @([pscustomobject]@{
                TimeCreated  = Get-Date
                LogName      = 'N/A'
                ProviderName = 'N/A'
                Id           = 0
                Message      = "Failed to query Event Viewer: $($_.Exception.Message)"
            })
    }
}

function Get-HealthSuggestions {
    param (
        [Parameter(Mandatory)] $DismResult,
        [Parameter(Mandatory)] $DiskSpaceReport,
        [Parameter(Mandatory)] $DiskErrorResults,
        [Parameter(Mandatory)] $NetworkResult,
        [Parameter(Mandatory)] $EventErrors
    )

    $suggestions = @()

    if ($DismResult.Status -eq 'IssuesFound') {
        $suggestions += 'Windows image has corruption. Run: DISM /Online /Cleanup-Image /RestoreHealth and then sfc /scannow.'
    }

    foreach ($volume in $DiskSpaceReport) {
        if ([double]$volume.FreePercent -lt 10) {
            $suggestions += "Drive $($volume.Drive) is low on space (<10%). Clean up temporary files, remove unused installers, or archive large data."
        }
    }

    foreach ($errorResult in $DiskErrorResults) {
        if ($errorResult.Status -in 'CorruptionFound', 'ScanFailed') {
            $suggestions += "Disk scan issue on $($errorResult.Drive): $($errorResult.Suggestion)"
        }
    }

    if ($NetworkResult.Status -ne 'Online') {
        $suggestions += 'Network connectivity is degraded. Verify gateway, DNS, and firewall policies; use Test-NetConnection or Test-Connection to troubleshoot.'
    }

    if ($EventErrors -and $EventErrors.Count -gt 0) {
        $suggestions += 'Review the most recent Event Viewer errors included in this report to identify underlying system or application issues.'
    }

    if (-not $suggestions) {
        $suggestions += 'No corrective actions detected from this health check. System status appears normal.'
    }

    return $suggestions
}

function Convert-ReportToHtml {
    param (
        [Parameter(Mandatory)] $OutputPath,
        [Parameter(Mandatory)] $DismResult,
        [Parameter(Mandatory)] $DiskSpaceReport,
        [Parameter(Mandatory)] $DiskErrorResults,
        [Parameter(Mandatory)] $NetworkResult,
        [Parameter(Mandatory)] $EventErrors,
        [Parameter(Mandatory)] $Suggestions
    )

    $computerName = $env:COMPUTERNAME
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $diskSpaceWarnings = $DiskSpaceReport | Where-Object { [double]$_.FreePercent -lt 10 }
    $diskIssues = $DiskErrorResults | Where-Object { $_.Status -ne 'NoErrorsFound' }
    $eventErrorCount = if ($EventErrors) { $EventErrors.Count } else { 0 }
    $overallStatus = if ($DismResult.Status -ne 'Healthy' -or $diskSpaceWarnings.Count -gt 0 -or $diskIssues.Count -gt 0 -or $NetworkResult.Status -ne 'Online' -or $eventErrorCount -gt 0) { 'Attention Required' } else { 'Healthy' }
    $diskSpaceSummary = if ($diskSpaceWarnings.Count) { $diskSpaceWarnings | ForEach-Object { "${($_.Drive)} (${($_.FreePercent)}%)" } -join ', ' } else { 'None' }
    $diskErrorSummary = if ($diskIssues.Count) { $diskIssues | ForEach-Object { "${($_.Drive)}: ${($_.Status)}" } -join '; ' } else { 'None' }
    $eventSummary = if ($eventErrorCount -gt 0) { $EventErrors | ForEach-Object { "$($_.LogName) $($_.Id)" } -join '; ' } else { 'None' }

    $diskSpaceRows = $DiskSpaceReport | ForEach-Object {
        "<tr><td>$($_.Drive)</td><td>$($_.FileSystem)</td><td>$($_.SizeGB)</td><td>$($_.FreeSpaceGB)</td><td>$($_.FreePercent)</td><td>$($_.HealthStatus)</td></tr>"
    }

    $diskErrorRows = $DiskErrorResults | ForEach-Object {
        $statusClass = if ($_.Status -eq 'NoErrorsFound') { 'status-good' } elseif ($_.Status -eq 'CorruptionFound') { 'status-bad' } else { 'status-warning' }
        "<tr><td>$($_.Drive)</td><td class='$statusClass'>$($_.Status)</td><td><pre>$($_.Details -replace '<','&lt;' -replace '>','&gt;')</pre></td><td>$($_.Suggestion)</td></tr>"
    }

    $networkRows = @(
        "<tr><td>Ping 8.8.8.8</td><td>$($NetworkResult.Ping)</td></tr>",
        "<tr><td>TCP 443 google.com</td><td>$($NetworkResult.Tcp443)</td></tr>",
        "<tr><td>DNS Resolution</td><td>$($NetworkResult.DnsResolution)</td></tr>",
        "<tr><td>Details</td><td><pre>$($NetworkResult.Details -replace '<','&lt;' -replace '>','&gt;')</pre></td></tr>"
    )

    $eventRows = $EventErrors | ForEach-Object {
        "<tr><td>$($_.TimeCreated)</td><td>$($_.LogName)</td><td>$($_.ProviderName)</td><td>$($_.Id)</td><td><pre>$($_.Message -replace '<','&lt;' -replace '>','&gt;')</pre></td></tr>"
    }

    $suggestionRows = $Suggestions | ForEach-Object {
        "<li>$($_ -replace '<','&lt;' -replace '>','&gt;')</li>"
    }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>$computerName Check Report</title>
<style>
    body { font-family: Arial, sans-serif; margin: 20px; color: #222; }
    h1, h2 { color: #004080; }
    table { border-collapse: collapse; width: 100%; margin-bottom: 20px; }
    th, td { border: 1px solid #ccc; padding: 8px; text-align: left; }
    th { background: #f2f7ff; }
    th.sortable { cursor: pointer; }
    tr:nth-child(even) { background: #f9fbff; }
    .status-good { color: green; }
    .status-bad { color: red; }
    .status-warning { color: #b06d00; }
    .section { margin-bottom: 30px; }
    pre { white-space: pre-wrap; word-wrap: break-word; margin: 0; }
</style>
<script>
function sortTable(tableIndex, colIndex) {
    var table = document.getElementsByTagName('table')[tableIndex];
    var rows = Array.prototype.slice.call(table.tBodies[0].rows, 0);
    var asc = table.getAttribute('data-sort-direction-' + colIndex) !== 'asc';
    rows.sort(function(a, b) {
        var x = a.cells[colIndex].innerText.trim();
        var y = b.cells[colIndex].innerText.trim();
        var xNum = parseFloat(x.replace(/[^0-9.\-]/g, ''));
        var yNum = parseFloat(y.replace(/[^0-9.\-]/g, ''));
        if (!isNaN(xNum) && !isNaN(yNum)) { x = xNum; y = yNum; }
        if (x > y) { return asc ? 1 : -1; }
        if (x < y) { return asc ? -1 : 1; }
        return 0;
    });
    for (var i = 0; i < rows.length; i++) { table.tBodies[0].appendChild(rows[i]); }
    table.setAttribute('data-sort-direction-' + colIndex, asc ? 'asc' : 'desc');
}
</script>
</head>
<body>
<h1>$computerName Check Report</h1>
<p>Generated: $timestamp</p>
<p>Computer: $computerName</p>
<div class="section">
    <h2>Summary</h2>
    <table>
        <tr><th>Overall Status</th><td class="$(if ($overallStatus -eq 'Healthy') {'status-good'} else {'status-bad'})">$overallStatus</td></tr>
        <tr><th>DISM Status</th><td>$($DismResult.Status)</td></tr>
        <tr><th>Network Status</th><td>$($NetworkResult.Status)</td></tr>
        <tr><th>Disk Errors</th><td>$diskErrorSummary</td></tr>
        <tr><th>Low Disk Space</th><td>$diskSpaceSummary</td></tr>
        <tr><th>Recent Event Errors</th><td>$eventSummary</td></tr>
    </table>
</div>
<div class="section">
    <h2>DISM Health Check</h2>
    <table>
        <tr><th class="sortable" onclick="sortTable(0,0)">Test</th><th class="sortable" onclick="sortTable(0,1)">Status</th><th>Details</th></tr>
        <tr>
            <td>$($DismResult.Test)</td>
            <td class="$(if ($DismResult.Status -eq 'Healthy') {'status-good'} else {'status-bad'})">$($DismResult.Status)</td>
            <td><pre>$($DismResult.Details -replace '<','&lt;' -replace '>','&gt;')</pre></td>
        </tr>
    </table>
</div>
<div class="section">
    <h2>Network Connectivity</h2>
    <table>
        <tr><th>Test</th><th>Result</th></tr>
        $($networkRows -join "`n")
    </table>
</div>
<div class="section">
    <h2>Disk Space</h2>
    <table>
        <tr><th class="sortable" onclick="sortTable(2,0)">Drive</th><th class="sortable" onclick="sortTable(2,1)">File System</th><th class="sortable" onclick="sortTable(2,2)">Size (GB)</th><th class="sortable" onclick="sortTable(2,3)">Free (GB)</th><th class="sortable" onclick="sortTable(2,4)">Free %</th><th class="sortable" onclick="sortTable(2,5)">Health Status</th></tr>
        $($diskSpaceRows -join "`n")
    </table>
</div>
<div class="section">
    <h2>Disk Error Scan</h2>
    <table>
        <tr><th class="sortable" onclick="sortTable(3,0)">Drive</th><th class="sortable" onclick="sortTable(3,1)">Status</th><th>Details</th><th>Suggestion</th></tr>
        $($diskErrorRows -join "`n")
    </table>
</div>
<div class="section">
    <h2>Recent Event Viewer Errors</h2>
    <table>
        <tr><th class="sortable" onclick="sortTable(4,0)">Time</th><th class="sortable" onclick="sortTable(4,1)">Log</th><th class="sortable" onclick="sortTable(4,2)">Provider</th><th class="sortable" onclick="sortTable(4,3)">Event ID</th><th>Message</th></tr>
        $($eventRows -join "`n")
    </table>
</div>
<div class="section">
    <h2>Suggested Remediation Actions</h2>
    <ol>
        $($suggestionRows -join "`n")
    </ol>
</div>
</body>
</html>
"@
    $html | Set-Content -Path $OutputPath -Encoding UTF8
}

function Main {
    if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Error 'Administrator privileges are required to run this health check.'
        exit 1
    }

    Write-Verbose 'Starting PC health check...'
    $outputPath = New-OutputFile

    Write-Verbose 'Running DISM health check...'
    $dismResult = Invoke-DismCheck

    Write-Verbose 'Gathering disk space details...'
    $diskSpaceReport = Get-DiskSpaceReport

    Write-Verbose 'Checking disks for errors...'
    $diskErrorResults = Invoke-DiskErrorChecks

    Write-Verbose 'Checking network connectivity...'
    $networkResult = Invoke-NetworkConnectivityCheck

    Write-Verbose 'Collecting recent Event Viewer errors...'
    $eventErrors = Get-RecentEventErrors

    Write-Verbose 'Generating remediation suggestions...'
    $suggestions = Get-HealthSuggestions -DismResult $dismResult -DiskSpaceReport $diskSpaceReport -DiskErrorResults $diskErrorResults -NetworkResult $networkResult -EventErrors $eventErrors

    Write-Verbose 'Building HTML report...'
    Convert-ReportToHtml -OutputPath $outputPath -DismResult $dismResult -DiskSpaceReport $diskSpaceReport -DiskErrorResults $diskErrorResults -NetworkResult $networkResult -EventErrors $eventErrors -Suggestions $suggestions

    Write-Host "Health check complete. Report saved to: $outputPath"
}

Main
