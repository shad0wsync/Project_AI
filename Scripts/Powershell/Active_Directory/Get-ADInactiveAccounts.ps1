#Requires -Modules ActiveDirectory

<#
.SYNOPSIS
    Finds Active Directory user and computer accounts that have not signed in for 30 days or more.

.DESCRIPTION
    Queries Active Directory for user and computer accounts and exports stale account details to timestamped CSV, JSON, and HTML files.
    Export files are saved to: c:\temp\Get-ADInactiveAccounts\Get-ADInactiveAccounts[yyyyMMdd-HHmmss].[filetype]
    The HTML report includes sortable columns and search functionality for interactive analysis.

.PARAMETER DaysInactive
    Number of days since the last logon to consider an account inactive. Default is 30.

.PARAMETER IncludeDisabled
    Include disabled user and computer accounts in the report. Default is $true.

.PARAMETER ExportRoot
    Root export directory. Default is c:\temp\Get-ADInactiveAccounts.

.EXAMPLE
    .\Get-ADInactiveAccounts.ps1
    Runs the report with the default 30-day threshold and exports CSV and JSON files.

.EXAMPLE
    .\Get-ADInactiveAccounts.ps1 -DaysInactive 60 -IncludeDisabled:$false
    Reports accounts inactive for 60 days and excludes disabled accounts.

.NOTES
    Author: Jay Smith
    Requires the ActiveDirectory PowerShell module and domain-connectivity privileges.
#>

param(
    [Parameter(Mandatory = $false)]
    [int]$DaysInactive = 30,

    [Parameter(Mandatory = $false)]
    [bool]$IncludeDisabled = $true,

    [Parameter(Mandatory = $false)]
    [string]$ExportRoot = 'c:\temp'
)

$ScriptName = 'Get-ADInactiveAccounts'
$OutputFolder = Join-Path -Path $ExportRoot -ChildPath $ScriptName
$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$CsvFile      = "$ScriptName$Timestamp.csv"
$JsonFile     = "$ScriptName$Timestamp.json"
$HtmlFile     = "$ScriptName$Timestamp.html"
$CsvPath      = Join-Path -Path $OutputFolder -ChildPath $CsvFile
$JsonPath     = Join-Path -Path $OutputFolder -ChildPath $JsonFile
$HtmlPath     = Join-Path -Path $OutputFolder -ChildPath $HtmlFile
$CutoffDate   = (Get-Date).AddDays(-$DaysInactive)

function Write-Header {
    Write-Host "[INFO] $($MyInvocation.MyCommand.Name) - $([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Cyan
}

function Import-ActiveDirectoryModule {
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        Write-Error 'The ActiveDirectory module is not installed or available on this system. Install RSAT or enable the feature and rerun the script.'
        exit 1
    }

    Import-Module ActiveDirectory -ErrorAction Stop
}

function New-ReportItem {
    param(
        [Parameter(Mandatory = $true)] [Microsoft.ActiveDirectory.Management.ADObject]$Object,
        [Parameter(Mandatory = $true)] [string]$ObjectType,
        [Parameter(Mandatory = $true)] [DateTime]$Cutoff
    )

    $lastLogonDate = $Object.LastLogonDate
    $lastLogonText = if ($lastLogonDate) { $lastLogonDate.ToString('yyyy-MM-dd HH:mm:ss') } else { 'Never' }
    $inactiveReason = if (-not $lastLogonDate) { 'Never signed in' } elseif ($lastLogonDate -lt $Cutoff) { 'Last sign-in older than threshold' } else { 'Within threshold' }

    [PSCustomObject]@{
        ObjectType         = $ObjectType
        Name               = $Object.Name
        SamAccountName     = $Object.SamAccountName
        DistinguishedName  = $Object.DistinguishedName
        Enabled            = $Object.Enabled
        LastLogonDate      = $lastLogonText
        LastLogonTimestamp = if ($lastLogonDate) { $lastLogonDate.ToUniversalTime().ToString('o') } else { '' }
        InactiveThreshold  = $Cutoff.ToString('yyyy-MM-dd')
        InactiveReason     = $inactiveReason
        WhenCreated        = if ($Object.whenCreated) { $Object.whenCreated.ToString('yyyy-MM-dd') } else { '' }
        WhenChanged        = if ($Object.whenChanged) { $Object.whenChanged.ToString('yyyy-MM-dd') } else { '' }
        AdditionalInfo     = if ($ObjectType -eq 'Computer') { $Object.OperatingSystem } else { $Object.UserPrincipalName }
    }
}

function New-HtmlReport {
    param(
        [Parameter(Mandatory = $true)] [array]$ReportData,
        [Parameter(Mandatory = $true)] [PSCustomObject]$Metadata,
        [Parameter(Mandatory = $true)] [string]$OutputPath
    )

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Inactive AD Accounts Report</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background-color: #f5f5f5;
            padding: 20px;
            color: #333;
        }
        .container {
            max-width: 1400px;
            margin: 0 auto;
            background-color: white;
            border-radius: 8px;
            box-shadow: 0 2px 8px rgba(0,0,0,0.1);
            overflow: hidden;
        }
        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 30px;
            text-align: center;
        }
        .header h1 { font-size: 28px; margin-bottom: 10px; }
        .header p { font-size: 14px; opacity: 0.9; }
        .metadata {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 15px;
            padding: 20px;
            background-color: #f9f9f9;
            border-bottom: 1px solid #e0e0e0;
        }
        .metadata-item {
            display: flex;
            flex-direction: column;
        }
        .metadata-item label {
            font-weight: 600;
            color: #667eea;
            font-size: 12px;
            text-transform: uppercase;
            margin-bottom: 5px;
        }
        .metadata-item span {
            font-size: 14px;
            color: #555;
        }
        .controls {
            padding: 20px;
            background-color: #fafafa;
            border-bottom: 1px solid #e0e0e0;
            display: flex;
            gap: 20px;
            flex-wrap: wrap;
            align-items: center;
        }
        .search-box {
            flex: 1;
            min-width: 250px;
        }
        .filter-group {
            display: flex;
            gap: 10px;
            align-items: center;
        }
        .filter-label {
            font-weight: 600;
            color: #333;
            font-size: 13px;
            text-transform: uppercase;
            white-space: nowrap;
        }
        .filter-buttons {
            display: flex;
            gap: 10px;
        }
        .search-box input {
            width: 100%;
            padding: 10px 12px;
            border: 1px solid #ddd;
            border-radius: 4px;
            font-size: 14px;
            transition: border-color 0.3s;
        }
        .search-box input:focus {
            outline: none;
            border-color: #667eea;
            box-shadow: 0 0 0 3px rgba(102, 126, 234, 0.1);
        }
        button {
            padding: 8px 16px;
            border: 1px solid #ddd;
            background-color: white;
            border-radius: 4px;
            cursor: pointer;
            font-size: 13px;
            transition: all 0.3s;
        }
        button:hover {
            background-color: #f0f0f0;
            border-color: #667eea;
            color: #667eea;
        }
        button.active {
            background-color: #667eea;
            color: white;
            border-color: #667eea;
        }
        .table-wrapper {
            overflow-x: auto;
            padding: 0;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            font-size: 13px;
        }
        thead {
            background-color: #f5f5f5;
            position: sticky;
            top: 0;
        }
        thead th {
            padding: 12px;
            text-align: left;
            font-weight: 600;
            color: #333;
            border-bottom: 2px solid #e0e0e0;
            cursor: pointer;
            user-select: none;
            white-space: nowrap;
        }
        thead th:hover {
            background-color: #ececec;
        }
        thead th.sortable::after {
            content: ' ↕';
            font-size: 11px;
            opacity: 0.5;
        }
        thead th.sorted-asc::after { content: ' ↑'; opacity: 1; color: #667eea; }
        thead th.sorted-desc::after { content: ' ↓'; opacity: 1; color: #667eea; }
        tbody tr {
            border-bottom: 1px solid #f0f0f0;
            transition: background-color 0.2s;
        }
        tbody tr:hover {
            background-color: #f9f9f9;
        }
        tbody tr.hidden { display: none; }
        tbody td {
            padding: 11px 12px;
        }
        tbody tr.enabled-true { background-color: #f0f8f0; }
        tbody tr.enabled-false { background-color: #fff5f5; }
        .status-enabled { color: #27ae60; font-weight: 500; }
        .status-disabled { color: #e74c3c; font-weight: 500; }
        .status-never { color: #e67e22; font-weight: 500; }
        .footer {
            padding: 15px 20px;
            background-color: #f9f9f9;
            border-top: 1px solid #e0e0e0;
            font-size: 12px;
            color: #666;
            text-align: right;
        }
        .stats {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
            gap: 15px;
            margin-top: 10px;
            padding-top: 10px;
            border-top: 1px solid #e0e0e0;
        }
        .stat-card {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 15px;
            border-radius: 4px;
            text-align: center;
        }
        .stat-card .number { font-size: 24px; font-weight: bold; }
        .stat-card .label { font-size: 12px; opacity: 0.9; margin-top: 5px; }
        .no-results {
            text-align: center;
            padding: 40px;
            color: #999;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>Inactive Active Directory Accounts Report</h1>
            <p>Identifies user and computer accounts with no logon activity</p>
        </div>
        
        <div class="metadata">
            <div class="metadata-item">
                <label>Generated</label>
                <span>$($Metadata.GeneratedDate)</span>
            </div>
            <div class="metadata-item">
                <label>Inactivity Threshold</label>
                <span>$($Metadata.DaysInactive) days (before $($Metadata.CutoffDate))</span>
            </div>
            <div class="metadata-item">
                <label>Include Disabled</label>
                <span>$($Metadata.IncludeDisabled)</span>
            </div>
            <div class="metadata-item">
                <label>Total Results</label>
                <span>$($Metadata.TotalCount) accounts</span>
            </div>
        </div>
        
        <div class="controls">
            <div class="search-box">
                <input type="text" id="searchInput" placeholder="Search by name, account, or DN...">
            </div>
            <div class="filter-group">
                <span class="filter-label">Type:</span>
                <div class="filter-buttons">
                    <button onclick="filterByType('all')" class="active" id="btn-type-all">All</button>
                    <button onclick="filterByType('User')" id="btn-type-user">Users</button>
                    <button onclick="filterByType('Computer')" id="btn-type-computer">Computers</button>
                </div>
            </div>
            <div class="filter-group">
                <span class="filter-label">Status:</span>
                <div class="filter-buttons">
                    <button onclick="filterByStatus('all')" class="active" id="btn-status-all">All</button>
                    <button onclick="filterByStatus('enabled')" id="btn-status-enabled">Enabled</button>
                    <button onclick="filterByStatus('disabled')" id="btn-status-disabled">Disabled</button>
                </div>
            </div>
        </div>
        
        <div class="table-wrapper">
            <table id="reportTable">
                <thead>
                    <tr>
                        <th class="sortable" onclick="sortTable('ObjectType')">Type</th>
                        <th class="sortable" onclick="sortTable('Name')">Name</th>
                        <th class="sortable" onclick="sortTable('SamAccountName')">SAM Account</th>
                        <th class="sortable" onclick="sortTable('Enabled')">Status</th>
                        <th class="sortable" onclick="sortTable('LastLogonDate')">Last Logon</th>
                        <th class="sortable" onclick="sortTable('InactiveReason')">Reason</th>
                        <th class="sortable" onclick="sortTable('WhenCreated')">Created</th>
                        <th class="sortable" onclick="sortTable('AdditionalInfo')">Details</th>
                    </tr>
                </thead>
                <tbody id="tableBody">
"@

    foreach ($row in $ReportData) {
        $statusClass = if ($row.Enabled) { 'enabled-true' } else { 'enabled-false' }
        $statusText = if ($row.Enabled) { 'Enabled' } else { 'Disabled' }
        $statusHtml = if ($row.Enabled) { "<span class='status-enabled'>$statusText</span>" } else { "<span class='status-disabled'>$statusText</span>" }
        
        $html += @"
                    <tr class="$statusClass" data-enabled="$($row.Enabled.ToString().ToLower())">
                        <td>$($row.ObjectType)</td>
                        <td>$([System.Net.WebUtility]::HtmlEncode($row.Name))</td>
                        <td>$($row.SamAccountName)</td>
                        <td>$statusHtml</td>
                        <td>$($row.LastLogonDate)</td>
                        <td>$($row.InactiveReason)</td>
                        <td>$($row.WhenCreated)</td>
                        <td title="$([System.Net.WebUtility]::HtmlEncode($row.AdditionalInfo))">$([System.Net.WebUtility]::HtmlEncode($row.AdditionalInfo))</td>
                    </tr>
"@
    }

    $html += @"
                </tbody>
            </table>
        </div>
        
        <div class="footer">
            <div class="stats">
                <div class="stat-card">
                    <div class="number">$($Metadata.UserCount)</div>
                    <div class="label">Inactive Users</div>
                </div>
                <div class="stat-card">
                    <div class="number">$($Metadata.ComputerCount)</div>
                    <div class="label">Inactive Computers</div>
                </div>
                <div class="stat-card">
                    <div class="number">$($Metadata.TotalCount)</div>
                    <div class="label">Total Inactive</div>
                </div>
            </div>
        </div>
    </div>
    
    <script>
        let currentSort = { column: null, direction: 'asc' };
        let currentTypeFilter = 'all';
        let currentStatusFilter = 'all';
        
        function sortTable(column) {
            const table = document.getElementById('reportTable');
            const tbody = document.getElementById('tableBody');
            const rows = Array.from(tbody.querySelectorAll('tr:not(.hidden)'));
            const headers = table.querySelectorAll('thead th');
            
            if (currentSort.column === column) {
                currentSort.direction = currentSort.direction === 'asc' ? 'desc' : 'asc';
            } else {
                currentSort.direction = 'asc';
                currentSort.column = column;
            }
            
            headers.forEach(h => h.classList.remove('sorted-asc', 'sorted-desc'));
            const headerIndex = Array.from(headers).findIndex(h => h.textContent.includes(column) || h.textContent.startsWith(column));
            if (headerIndex >= 0) {
                headers[headerIndex].classList.add(currentSort.direction === 'asc' ? 'sorted-asc' : 'sorted-desc');
            }
            
            rows.sort((a, b) => {
                let aVal = a.children[headerIndex]?.textContent.trim() || '';
                let bVal = b.children[headerIndex]?.textContent.trim() || '';
                
                if (!isNaN(aVal) && !isNaN(bVal)) {
                    aVal = parseFloat(aVal);
                    bVal = parseFloat(bVal);
                } else {
                    aVal = aVal.toLowerCase();
                    bVal = bVal.toLowerCase();
                }
                
                if (aVal < bVal) return currentSort.direction === 'asc' ? -1 : 1;
                if (aVal > bVal) return currentSort.direction === 'asc' ? 1 : -1;
                return 0;
            });
            
            tbody.innerHTML = '';
            rows.forEach(row => tbody.appendChild(row));
        }
        
        function filterByType(type) {
            currentTypeFilter = type;
            document.querySelectorAll('#btn-type-all, #btn-type-user, #btn-type-computer').forEach(btn => btn.classList.remove('active'));
            document.getElementById('btn-type-' + (type === 'all' ? 'all' : type.toLowerCase())).classList.add('active');
            applyFilters();
        }
        
        function filterByStatus(status) {
            currentStatusFilter = status;
            document.querySelectorAll('#btn-status-all, #btn-status-enabled, #btn-status-disabled').forEach(btn => btn.classList.remove('active'));
            document.getElementById('btn-status-' + status).classList.add('active');
            applyFilters();
        }
        
        function applyFilters() {
            const searchTerm = document.getElementById('searchInput').value.toLowerCase();
            const rows = document.getElementById('tableBody').querySelectorAll('tr');
            let visibleCount = 0;
            
            rows.forEach(row => {
                let show = true;
                
                // Filter by type (User/Computer)
                if (currentTypeFilter !== 'all') {
                    const objectType = row.children[0]?.textContent.trim();
                    show = objectType === currentTypeFilter;
                }
                
                // Filter by status (Enabled/Disabled)
                if (show && currentStatusFilter !== 'all') {
                    const enabled = row.getAttribute('data-enabled') === 'true';
                    show = (currentStatusFilter === 'enabled') === enabled;
                }
                
                // Filter by search term
                if (show && searchTerm) {
                    const text = row.textContent.toLowerCase();
                    show = text.includes(searchTerm);
                }
                
                row.classList.toggle('hidden', !show);
                if (show) visibleCount++;
            });
            
            if (visibleCount === 0) {
                let noResults = document.getElementById('noResults');
                if (!noResults) {
                    noResults = document.createElement('tr');
                    noResults.id = 'noResults';
                    noResults.innerHTML = '<td colspan="8" class="no-results">No matching records found</td>';
                    document.getElementById('tableBody').appendChild(noResults);
                }
            } else {
                const noResults = document.getElementById('noResults');
                if (noResults) noResults.remove();
            }
        }
        
        document.getElementById('searchInput').addEventListener('input', applyFilters);
    </script>
</body>
</html>
"@

    $html | Set-Content -Path $OutputPath -Encoding UTF8
}

Write-Header
Import-ActiveDirectoryModule

if (-not (Test-Path -Path $OutputFolder)) {
    New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
}

Write-Host "Querying Active Directory for accounts inactive since $($CutoffDate.ToString('yyyy-MM-dd'))..." -ForegroundColor Yellow

$filteredUserProperties = @('Name','SamAccountName','UserPrincipalName','Enabled','LastLogonDate','DistinguishedName','whenCreated','whenChanged')
$filteredComputerProperties = @('Name','SamAccountName','Enabled','LastLogonDate','DistinguishedName','OperatingSystem','OperatingSystemVersion','whenCreated','whenChanged')

$users = Get-ADUser -Filter * -Properties $filteredUserProperties
$computers = Get-ADComputer -Filter * -Properties $filteredComputerProperties

$inactiveUsers = $users | Where-Object {
    $include = $true
    if (-not $IncludeDisabled) { $include = $include -and $_.Enabled }
    $lastLogon = $_.LastLogonDate
    $include -and ( -not $lastLogon -or $lastLogon -lt $CutoffDate )
} | ForEach-Object { New-ReportItem -Object $_ -ObjectType 'User' -Cutoff $CutoffDate }

$inactiveComputers = $computers | Where-Object {
    $include = $true
    if (-not $IncludeDisabled) { $include = $include -and $_.Enabled }
    $lastLogon = $_.LastLogonDate
    $include -and ( -not $lastLogon -or $lastLogon -lt $CutoffDate )
} | ForEach-Object { New-ReportItem -Object $_ -ObjectType 'Computer' -Cutoff $CutoffDate }

$reportRows = $inactiveUsers + $inactiveComputers

$reportMetadata = [PSCustomObject]@{
    GeneratedDate   = (Get-Date).ToString('o')
    ExportFolder    = $OutputFolder
    DaysInactive    = $DaysInactive
    CutoffDate      = $CutoffDate.ToString('yyyy-MM-dd')
    IncludeDisabled = $IncludeDisabled
    UserCount       = $inactiveUsers.Count
    ComputerCount   = $inactiveComputers.Count
    TotalCount      = $reportRows.Count
    FileNameCsv     = $CsvFile
    FileNameJson    = $JsonFile
    FileNameHtml    = $HtmlFile
}

$reportRows | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8 -Force
$reportMetadata | Add-Member -NotePropertyName Results -NotePropertyValue $reportRows -Force
$reportMetadata | ConvertTo-Json -Depth 5 | Set-Content -Path $JsonPath -Encoding UTF8
New-HtmlReport -ReportData $reportRows -Metadata $reportMetadata -OutputPath $HtmlPath

Write-Host "Export complete." -ForegroundColor Green
Write-Host "CSV:  $CsvPath" -ForegroundColor Cyan
Write-Host "JSON: $JsonPath" -ForegroundColor Cyan
Write-Host "HTML: $HtmlPath" -ForegroundColor Cyan
Write-Host "Inactive user accounts: $($inactiveUsers.Count)" -ForegroundColor Cyan
Write-Host "Inactive computer accounts: $($inactiveComputers.Count)" -ForegroundColor Cyan

if ($reportRows.Count -eq 0) {
    Write-Host 'No inactive accounts were found using the current threshold and filter settings.' -ForegroundColor Yellow
}
else {
    Write-Host 'Review the exported report files for the full stale account details.' -ForegroundColor Green
}
