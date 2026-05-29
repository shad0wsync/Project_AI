#Requires -Modules Microsoft.Graph.Identity.DirectoryManagement

<#
.SYNOPSIS
    Retrieves Microsoft 365 subscriptions and exports to interactive HTML and JSON reports.

.DESCRIPTION
    This script connects to Microsoft Graph and queries subscriptions to identify which ones have
    month-to-month billing terms. It displays SKU information, license usage, and billing details.
    
    The script automatically exports results to both interactive HTML and JSON formats.
    Export files are saved to: c:\temp\Get-M365MonthToMonthSubscriptions\[TenantName]__MM_DD_YY_HH_MM_SS.[filetype]

.PARAMETER TenantId
    Optional. The Azure AD tenant ID. If not specified, will prompt during connection.

.EXAMPLE
    .\Get-M365MonthToMonthSubscriptions.ps1
    Connects to default tenant and exports both HTML and JSON reports
    
.EXAMPLE
    .\Get-M365MonthToMonthSubscriptions.ps1 -TenantId "your-tenant-id"
    Connects to specified tenant and exports both HTML and JSON reports
    
.NOTES
    Export file naming convention: [TenantName]__MM_DD_YY_HH_MM_SS.[filetype]
    Example: Contoso_Inc__04_20_26_14_30_45.html
            Contoso_Inc__04_20_26_14_30_45.json
    
    Both files are always generated automatically to c:\temp\Get-M365MonthToMonthSubscriptions\
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$TenantId
)

# Script metadata for naming convention
$ScriptName = "Get-M365MonthToMonthSubscriptions"
$BaseExportPath = "c:\temp\$ScriptName"

function Connect-ToMgGraph {
    Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
    
    $scopes = @(
        "Organization.Read.All"
        "Directory.Read.All"
    )
    
    if ($TenantId) {
        Connect-MgGraph -TenantId $TenantId -Scopes $scopes -NoWelcome
    }
    else {
        Connect-MgGraph -Scopes $scopes -NoWelcome
    }
}

function Get-SKUAlias {
    param([string]$SkuPartNumber)
    
    # Mapping of SKU part numbers to friendly names
    $skuAliases = @{
        "MICROSOFT_TEAMS_PHONE_STANDARD"           = "Teams Phone Standard"
        "MICROSOFT_TEAMS_PHONE_STANDARD_GCC"       = "Teams Phone Standard (GCC)"
        "MEETING_ROOM_STANDARD"                    = "Meeting Room Standard"
        "TEAMS_EXPLORATORY"                        = "Teams Exploratory"
        "TEAMS_COMMERCIAL_TRIAL"                   = "Teams Commercial Trial"
        "POWER_BI_STANDARD"                        = "Power BI Standard"
        "POWER_BI_PRO"                             = "Power BI Pro"
        "M365_BUSINESS_BASIC"                      = "Microsoft 365 Business Basic"
        "M365_BUSINESS_STANDARD"                   = "Microsoft 365 Business Standard"
        "M365_BUSINESS_PREMIUM"                    = "Microsoft 365 Business Premium"
        "SPB"                                      = "Microsoft 365 Business Premium"
        "PROJECTPREMIUM"                           = "Project Premium"
        "PROJECTPROFESSIONAL"                      = "Project Professional"
        "VISIO_PRO_PLUS"                           = "Visio Pro Plus"
        "DESKLESS"                                 = "Dynamics 365 F0"
        "DYN365_ENTERPRISE_SALES_PREMIUM"          = "Dynamics 365 Sales Premium"
        "COMMUNICATIONS_DLP"                       = "Data Loss Prevention"
        "TEAMS_VOICE_CONFERENCING"                 = "Teams Voice Conferencing"
        "COMMUNICATIONS_COMPLIANCE"                = "Communications Compliance"
        "PHONESYSTEM_VIRTUALUSER"                  = "Teams Phone (Virtual User)"
        "EXCHANGE_S_FOUNDATION"                    = "Exchange Online (Kiosk)"
        "EXCHANGESERVER"                           = "Exchange Server"
        "O365_SB_ESSENTIALS"                       = "Microsoft 365 Business Basic"
        "O365_SB_PREMIUM"                          = "Microsoft 365 Business Premium"
    }
    
    if ($skuAliases.ContainsKey($SkuPartNumber)) {
        return $skuAliases[$SkuPartNumber]
    }
    else {
        return "Unknown"
    }
}

function Get-MonthToMonthSubscriptions {
    Write-Host "Retrieving subscriptions from Microsoft 365..." -ForegroundColor Cyan
    
    try {
        $subscriptions = Get-MgSubscribedSku -All
        
        if (-not $subscriptions) {
            Write-Host "No subscriptions found." -ForegroundColor Yellow
            return $null
        }
        
        Write-Host "Found $($subscriptions.Count) total subscriptions" -ForegroundColor Green
        Write-Host "`n"
        
        # Display all subscriptions with usage details
        $subscriptionDetails = $subscriptions | Select-Object `
            @{Name = "SKU"; Expression = { $_.SkuPartNumber } },
            @{Name = "Alias"; Expression = { Get-SKUAlias -SkuPartNumber $_.SkuPartNumber } },
            @{Name = "SKU ID"; Expression = { $_.SkuId } },
            @{Name = "Status"; Expression = { $_.ServiceStatus[0].ServiceProvisioningStatus } },
            @{Name = "Total Licenses"; Expression = { 
                $_.PrepaidUnits.Enabled + $_.PrepaidUnits.Suspended + $_.PrepaidUnits.Warning 
            }},
            @{Name = "Active Licenses"; Expression = { $_.PrepaidUnits.Enabled } },
            @{Name = "Suspended"; Expression = { $_.PrepaidUnits.Suspended } },
            @{Name = "Warning"; Expression = { $_.PrepaidUnits.Warning } },
            @{Name = "Consumed Units"; Expression = { $_.ConsumedUnits } }
        
        return $subscriptionDetails
    }
    catch {
        Write-Host "Error retrieving subscriptions: $_" -ForegroundColor Red
        return $null
    }
}

function Get-OrganizationLicensingInfo {
    Write-Host "Retrieving organization licensing information..." -ForegroundColor Cyan
    
    try {
        $org = Get-MgOrganization -Property "createdDateTime"
        
        if ($org) {
            Write-Host "Organization: $($org.DisplayName)" -ForegroundColor Green
            Write-Host "Tenant ID: $($org.Id)" -ForegroundColor Green
            return $org
        }
    }
    catch {
        Write-Host "Could not retrieve organization info: $_" -ForegroundColor Yellow
    }
    return $null
}

function Export-ToHTML {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Data,
        
        [Parameter(Mandatory = $true)]
        [string]$TenantName,
        
        [Parameter(Mandatory = $true)]
        [string]$BaseExportPath
    )
    
    # Create directory structure
    if (-not (Test-Path $BaseExportPath)) {
        New-Item -ItemType Directory -Path $BaseExportPath -Force | Out-Null
    }
    
    $timestamp = Get-Date -Format "MM_dd_yy_HH_mm_ss"
    $fileName = "${TenantName}__${timestamp}.html"
    $filePath = Join-Path $BaseExportPath $fileName
    
    $htmlContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Microsoft 365 Subscriptions Report</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            padding: 20px;
        }
        
        .container {
            max-width: 1400px;
            margin: 0 auto;
            background: white;
            border-radius: 12px;
            box-shadow: 0 20px 60px rgba(0, 0, 0, 0.3);
            overflow: hidden;
        }
        
        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 30px;
            text-align: center;
        }
        
        .header h1 {
            font-size: 2.5em;
            margin-bottom: 10px;
        }
        
        .header p {
            font-size: 1.1em;
            opacity: 0.95;
        }
        
        .controls {
            padding: 20px 30px;
            background: #f8f9fa;
            border-bottom: 1px solid #e9ecef;
            display: flex;
            gap: 15px;
            flex-wrap: wrap;
            align-items: center;
        }
        
        .search-box {
            flex: 1;
            min-width: 250px;
        }
        
        .search-box input {
            width: 100%;
            padding: 10px 15px;
            border: 1px solid #ddd;
            border-radius: 6px;
            font-size: 1em;
        }
        
        .search-box input:focus {
            outline: none;
            border-color: #667eea;
            box-shadow: 0 0 0 3px rgba(102, 126, 234, 0.1);
        }
        
        .controls button {
            padding: 10px 20px;
            background: #667eea;
            color: white;
            border: none;
            border-radius: 6px;
            cursor: pointer;
            font-size: 1em;
            transition: background 0.3s;
        }
        
        .controls button:hover {
            background: #5568d3;
        }
        
        .table-wrapper {
            overflow-x: auto;
            padding: 20px 30px;
        }
        
        table {
            width: 100%;
            border-collapse: collapse;
            font-size: 0.95em;
        }
        
        th {
            background: #667eea;
            color: white;
            padding: 15px;
            text-align: left;
            font-weight: 600;
            cursor: pointer;
            user-select: none;
            white-space: nowrap;
            position: sticky;
            top: 0;
            z-index: 10;
        }
        
        th:hover {
            background: #5568d3;
        }
        
        th::after {
            content: ' ⇅';
            opacity: 0.5;
        }
        
        td {
            padding: 12px 15px;
            border-bottom: 1px solid #e9ecef;
        }
        
        tbody tr:hover {
            background: #f8f9fa;
        }
        
        tbody tr:nth-child(odd) {
            background: #ffffff;
        }
        
        tbody tr:nth-child(even) {
            background: #f8f9fa;
        }
        
        .status-active {
            background: #d4edda;
            color: #155724;
            padding: 6px 12px;
            border-radius: 4px;
            font-weight: 500;
        }
        
        .status-warning {
            background: #fff3cd;
            color: #856404;
            padding: 6px 12px;
            border-radius: 4px;
            font-weight: 500;
        }
        
        .sku-name {
            font-family: 'Courier New', monospace;
            background: #f8f9fa;
            padding: 4px 8px;
            border-radius: 3px;
            font-size: 0.9em;
        }
        
        .footer {
            padding: 20px 30px;
            background: #f8f9fa;
            border-top: 1px solid #e9ecef;
            color: #6c757d;
            font-size: 0.9em;
            text-align: center;
        }
        
        .hide {
            display: none;
        }
        
        .info-box {
            background: #e7f3ff;
            border-left: 4px solid #667eea;
            padding: 15px;
            margin: 20px 30px;
            border-radius: 4px;
            color: #0c5aa0;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>Microsoft 365 Subscriptions Report</h1>
            <p>Generated on $(Get-Date -Format 'MMMM dd, yyyy HH:mm:ss')</p>
        </div>
        
        <div class="controls">
            <div class="search-box">
                <input type="text" id="searchInput" placeholder="Search by SKU, Alias, Status...">
            </div>
            <button onclick="resetFilters()">Reset Filters</button>
            <button onclick="exportToCSV()">Export to CSV</button>
        </div>
        
        <div class="info-box">
            <strong>💡 Tip:</strong> Click on column headers to sort. Use the search box to filter results.
        </div>
        
        <div class="table-wrapper">
            <table id="subscriptionsTable">
                <thead>
                    <tr>
                        <th onclick="sortTable(0)">SKU</th>
                        <th onclick="sortTable(1)">Alias</th>
                        <th onclick="sortTable(2)">Status</th>
                        <th onclick="sortTable(3)">Total Licenses</th>
                        <th onclick="sortTable(4)">Active Licenses</th>
                        <th onclick="sortTable(5)">Suspended</th>
                        <th onclick="sortTable(6)">Warning</th>
                        <th onclick="sortTable(7)">Consumed Units</th>
                    </tr>
                </thead>
                <tbody>
"@

    # Add table rows
    foreach ($item in $Data) {
        $statusClass = if ($item.Status -eq "ServiceAvailable") { "status-active" } else { "status-warning" }
        $htmlContent += @"
                    <tr>
                        <td><span class="sku-name">$($item.SKU)</span></td>
                        <td>$($item.Alias)</td>
                        <td><span class="$statusClass">$($item.Status)</span></td>
                        <td>$($item."Total Licenses")</td>
                        <td>$($item."Active Licenses")</td>
                        <td>$($item.Suspended)</td>
                        <td>$($item.Warning)</td>
                        <td>$($item."Consumed Units")</td>
                    </tr>
"@
    }

    $htmlContent += @"
                </tbody>
            </table>
        </div>
        
        <div class="footer">
            <p>Total Subscriptions: <strong>$($Data.Count)</strong></p>
            <p>Report generated using M365 Subscription Auditor</p>
        </div>
    </div>
    
    <script>
        function sortTable(columnIndex) {
            const table = document.getElementById('subscriptionsTable');
            const tbody = table.querySelector('tbody');
            const rows = Array.from(tbody.querySelectorAll('tr'));
            
            let isAscending = true;
            const header = table.querySelectorAll('th')[columnIndex];
            
            if (header.dataset.sorted === 'asc') {
                isAscending = false;
                header.dataset.sorted = 'desc';
            } else {
                header.dataset.sorted = 'asc';
            }
            
            rows.sort((a, b) => {
                const aValue = a.cells[columnIndex].textContent.trim();
                const bValue = b.cells[columnIndex].textContent.trim();
                
                const aNum = parseFloat(aValue);
                const bNum = parseFloat(bValue);
                
                if (!isNaN(aNum) && !isNaN(bNum)) {
                    return isAscending ? aNum - bNum : bNum - aNum;
                }
                
                return isAscending ? aValue.localeCompare(bValue) : bValue.localeCompare(aValue);
            });
            
            rows.forEach(row => tbody.appendChild(row));
        }
        
        function searchTable() {
            const searchInput = document.getElementById('searchInput').value.toLowerCase();
            const table = document.getElementById('subscriptionsTable');
            const rows = table.querySelectorAll('tbody tr');
            
            rows.forEach(row => {
                const text = row.textContent.toLowerCase();
                row.classList.toggle('hide', !text.includes(searchInput));
            });
        }
        
        function resetFilters() {
            document.getElementById('searchInput').value = '';
            searchTable();
            const headers = document.querySelectorAll('th');
            headers.forEach(h => delete h.dataset.sorted);
        }
        
        function exportToCSV() {
            const table = document.getElementById('subscriptionsTable');
            let csv = [];
            const rows = table.querySelectorAll('tr');
            
            rows.forEach(row => {
                const cols = row.querySelectorAll('td, th');
                const csvRow = [];
                cols.forEach(col => {
                    csvRow.push('"' + col.textContent.trim().replace(/"/g, '""') + '"');
                });
                csv.push(csvRow.join(','));
            });
            
            const csvContent = csv.join('\\n');
            const blob = new Blob([csvContent], { type: 'text/csv' });
            const link = document.createElement('a');
            link.href = URL.createObjectURL(blob);
            link.download = 'M365_Subscriptions_$timestamp.csv';
            link.click();
        }
        
        document.getElementById('searchInput').addEventListener('keyup', searchTable);
    </script>
</body>
</html>
"@

    $htmlContent | Out-File -FilePath $filePath -Encoding UTF8 -Force
    Write-Host "HTML report exported to: $filePath" -ForegroundColor Green
    return $filePath
}

function Export-ToJSON {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Data,
        
        [Parameter(Mandatory = $true)]
        [string]$TenantName,
        
        [Parameter(Mandatory = $true)]
        [string]$BaseExportPath
    )
    
    # Create directory structure
    if (-not (Test-Path $BaseExportPath)) {
        New-Item -ItemType Directory -Path $BaseExportPath -Force | Out-Null
    }
    
    $timestamp = Get-Date -Format "MM_dd_yy_HH_mm_ss"
    $fileName = "${TenantName}__${timestamp}.json"
    $filePath = Join-Path $BaseExportPath $fileName
    
    $jsonData = @{
        GeneratedDate = Get-Date -Format "o"
        TotalSubscriptions = $Data.Count
        Subscriptions = @()
    }
    
    foreach ($item in $Data) {
        $jsonData.Subscriptions += @{
            SKU = $item.SKU
            Alias = $item.Alias
            Status = $item.Status
            TotalLicenses = [int]$item."Total Licenses"
            ActiveLicenses = [int]$item."Active Licenses"
            Suspended = [int]$item.Suspended
            Warning = [int]$item.Warning
            ConsumedUnits = [int]$item."Consumed Units"
        }
    }
    
    $jsonData | ConvertTo-Json | Out-File -FilePath $filePath -Encoding UTF8 -Force
    Write-Host "JSON report exported to: $filePath" -ForegroundColor Green
    return $filePath
}

# Main execution
try {
    # Connect to Microsoft Graph
    Connect-ToMgGraph
    
    # Get organization info
    $orgInfo = Get-OrganizationLicensingInfo
    
    # Validate organization info and set tenant name
    if ($null -eq $orgInfo -or [string]::IsNullOrWhiteSpace($orgInfo.DisplayName)) {
        Write-Host "Warning: Could not retrieve organization display name. Using default." -ForegroundColor Yellow
        $tenantName = "Unknown_Tenant_$(Get-Date -Format 'MM_dd_yy')"
    }
    else {
        $tenantName = $orgInfo.DisplayName -replace '\s+', '_'  # Replace spaces with underscores
    }
    
    Write-Host "`n==========================================`n" -ForegroundColor Yellow
    
    # Get subscriptions
    $subs = Get-MonthToMonthSubscriptions
    
    if ($subs) {
        # Display to console
        Write-Host "Subscription Summary:" -ForegroundColor Cyan
        Write-Host "==========================================`n" -ForegroundColor Yellow
        
        $subs | Format-Table -AutoSize
        
        Write-Host "`n"
        Write-Host "Note: Month-to-month subscriptions typically show:" -ForegroundColor Yellow
        Write-Host "  - Consumed Units close to or equal to Active Licenses" -ForegroundColor Gray
        Write-Host "  - Status as 'ServiceAvailable'" -ForegroundColor Gray
        
        # Always export to HTML
        Write-Host "`nGenerating HTML report..." -ForegroundColor Cyan
        $htmlFile = Export-ToHTML -Data $subs -TenantName $tenantName -BaseExportPath $BaseExportPath
        
        # Always export to JSON
        Write-Host "Generating JSON report..." -ForegroundColor Cyan
        $jsonFile = Export-ToJSON -Data $subs -TenantName $tenantName -BaseExportPath $BaseExportPath
        
        # Summary
        Write-Host "`n==========================================`n" -ForegroundColor Yellow
        Write-Host "Export Summary:" -ForegroundColor Cyan
        Write-Host "  Output Directory: $BaseExportPath" -ForegroundColor Green
        Write-Host "  Tenant Name: $tenantName" -ForegroundColor Green
        Write-Host "  Total Subscriptions: $($subs.Count)" -ForegroundColor Green
        Write-Host "  HTML File: $(Split-Path $htmlFile -Leaf)" -ForegroundColor Green
        Write-Host "  JSON File: $(Split-Path $jsonFile -Leaf)" -ForegroundColor Green
        
        Write-Host "`nFor detailed renewal and billing cycle information, check in:" -ForegroundColor Cyan
        Write-Host "  Azure Portal > Subscriptions > Your Subscription > Overview" -ForegroundColor Gray
    }
    
    Write-Host "`nDisconnecting from Microsoft Graph..." -ForegroundColor Cyan
    Disconnect-MgGraph | Out-Null
    Write-Host "Disconnected successfully." -ForegroundColor Green
}
catch {
    Write-Host "An error occurred: $_" -ForegroundColor Red
    exit 1
}
