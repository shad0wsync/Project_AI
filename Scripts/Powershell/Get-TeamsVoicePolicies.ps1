#Requires -Modules MicrosoftTeams, Microsoft.Graph.Identity.DirectoryManagement

<#
.SYNOPSIS
    Retrieves Microsoft Teams voice policies and exports to interactive HTML and JSON reports.

.DESCRIPTION
    This script connects to Microsoft Teams and Microsoft Graph, queries all Teams voice policies
    including call policies, voicemail policies, calling line identity policies, and voice routing
    policies. It displays policy information with detailed configurations and exports results to
    interactive HTML and JSON formats.
    
    The script automatically exports results to both interactive HTML and JSON formats.
    Export files are saved to: c:\temp\Get-TeamsVoicePolicies\[OrganizationName]__MM_DD_YY_HH_MM_SS.[filetype]

.PARAMETER TenantId
    Optional. The Azure AD tenant ID. If not specified, will prompt during connection.

.EXAMPLE
    .\Get-TeamsVoicePolicies.ps1
    Connects to default tenant and exports both HTML and JSON reports
    
.EXAMPLE
    .\Get-TeamsVoicePolicies.ps1 -TenantId "your-tenant-id"
    Connects to specified tenant and exports both HTML and JSON reports
    
.NOTES
    Export file naming convention: [OrganizationName]__MM_DD_YY_HH_MM_SS.[filetype]
    Example: Contoso_Inc__04_20_26_14_30_45.html
            Contoso_Inc__04_20_26_14_30_45.json
    
    Both files are always generated automatically to c:\temp\Get-TeamsVoicePolicies\
    
    Requires Teams PowerShell Module: Install-Module -Name MicrosoftTeams -Force
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$TenantId
)

# Script metadata for naming convention
$ScriptName = "Get-TeamsVoicePolicies"
$BaseExportPath = "c:\temp\$ScriptName"

function Connect-TeamsAdmin {
    Write-Host "Connecting to Microsoft Teams Admin..." -ForegroundColor Cyan
    
    try {
        if ($TenantId) {
            Connect-MicrosoftTeams -TenantId $TenantId | Out-Null
        }
        else {
            Connect-MicrosoftTeams | Out-Null
        }
        Write-Host "Connected to Teams successfully." -ForegroundColor Green
    }
    catch {
        Write-Host "Error connecting to Teams: $_" -ForegroundColor Red
        throw $_
    }
}

function Connect-ToMgGraph {
    Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
    
    $scopes = @(
        "Organization.Read.All"
        "Directory.Read.All"
    )
    
    try {
        if ($TenantId) {
            Connect-MgGraph -TenantId $TenantId -Scopes $scopes -NoWelcome -ErrorAction Stop | Out-Null
        }
        else {
            Connect-MgGraph -Scopes $scopes -NoWelcome -ErrorAction Stop | Out-Null
        }
        Write-Host "Connected to Microsoft Graph successfully." -ForegroundColor Green
    }
    catch {
        Write-Host "Error connecting to Microsoft Graph: $_" -ForegroundColor Red
        throw $_
    }
}

function Get-OrganizationInfo {
    Write-Host "Retrieving organization information..." -ForegroundColor Cyan
    
    try {
        $org = Get-MgOrganization -Property "displayName"
        
        if ($org) {
            Write-Host "Organization: $($org.DisplayName)" -ForegroundColor Green
            return $org
        }
    }
    catch {
        Write-Host "Could not retrieve organization info: $_" -ForegroundColor Yellow
    }
    return $null
}

function Get-AllTeamsVoicePolicies {
    Write-Host "Retrieving Teams voice policies..." -ForegroundColor Cyan
    
    try {
        $policies = @()
        
        # Get Teams Call Policies
        Write-Host "  - Retrieving Teams Call Policies..." -ForegroundColor Gray
        $callPolicies = Get-CsTeamsCallingPolicy -ErrorAction SilentlyContinue | Select-Object `
            @{Name = "PolicyType"; Expression = { "Teams Calling Policy" } },
            @{Name = "PolicyName"; Expression = { $_.Identity } },
            @{Name = "Description"; Expression = { $_.Description } },
            @{Name = "AllowPrivateCalling"; Expression = { $_.AllowPrivateCalling } },
            @{Name = "AllowVoicemail"; Expression = { $_.AllowVoicemail } },
            @{Name = "AllowCallGroups"; Expression = { $_.AllowCallGroups } },
            @{Name = "AllowDelegation"; Expression = { $_.AllowDelegation } },
            @{Name = "BusyOnBusyEnabledUsers"; Expression = { $_.BusyOnBusyEnabledUsers } },
            @{Name = "MusicOnHoldEnabled"; Expression = { $_.MusicOnHoldEnabled } }
        
        $policies += $callPolicies
        
        # Get Teams Voicemail Policies (if available in this version)
        Write-Host "  - Retrieving Teams Voicemail Policies..." -ForegroundColor Gray
        try {
            $voicemailPolicies = Get-CsVoicemailPolicy -ErrorAction Stop | Select-Object `
                @{Name = "PolicyType"; Expression = { "Teams Voicemail Policy" } },
                @{Name = "PolicyName"; Expression = { $_.Identity } },
                @{Name = "Description"; Expression = { $_.Description } },
                @{Name = "EnableTranscription"; Expression = { $_.EnableTranscription } },
                @{Name = "EnableTranscriptionProfanityMasking"; Expression = { $_.EnableTranscriptionProfanityMasking } },
                @{Name = "EnableTranscriptionTranslation"; Expression = { $_.EnableTranscriptionTranslation } },
                @{Name = "MaximumVoicemailDurationInSeconds"; Expression = { $_.MaximumVoicemailDurationInSeconds } },
                @{Name = "VoicemailFormat"; Expression = { $_.VoicemailFormat } },
                @{Name = "AdditionalSettings"; Expression = { "See Details" } }
            
            $policies += $voicemailPolicies
        }
        catch {
            Write-Host "  - Voicemail policies not available in this Teams module version (skipping)" -ForegroundColor Yellow
        }
        
        # Get Teams Calling Line Identity Policies
        Write-Host "  - Retrieving Teams Calling Line Identity Policies..." -ForegroundColor Gray
        $callingLineIdPolicies = Get-CsCallingLineIdentity -ErrorAction SilentlyContinue | Select-Object `
            @{Name = "PolicyType"; Expression = { "Calling Line Identity Policy" } },
            @{Name = "PolicyName"; Expression = { $_.Identity } },
            @{Name = "Description"; Expression = { $_.Description } },
            @{Name = "CallingIDSubstitute"; Expression = { $_.CallingIDSubstitute } },
            @{Name = "EnableUserOverride"; Expression = { $_.EnableUserOverride } },
            @{Name = "ResourceAccount"; Expression = { $_.ResourceAccount } },
            @{Name = "ComplianceRecordingPaused"; Expression = { $_.ComplianceRecordingPaused } },
            @{Name = "AdditionalSettings"; Expression = { "See Details" } }
        
        $policies += $callingLineIdPolicies
        
        # Get Teams Voice Routing Policies (if available in this version)
        Write-Host "  - Retrieving Teams Voice Routing Policies..." -ForegroundColor Gray
        try {
            $voiceRoutingPolicies = Get-CsTeamsVoiceRoutingPolicy -ErrorAction Stop | Select-Object `
                @{Name = "PolicyType"; Expression = { "Teams Voice Routing Policy" } },
                @{Name = "PolicyName"; Expression = { $_.Identity } },
                @{Name = "Description"; Expression = { $_.Description } },
                @{Name = "OnlinePSTNGatewayFqdn"; Expression = { $_.OnlinePSTNGatewayFqdn } },
                @{Name = "RouteType"; Expression = { $_.RouteType } },
                @{Name = "AdditionalSettings"; Expression = { "See Details" } }
            
            $policies += $voiceRoutingPolicies
        }
        catch {
            Write-Host "  - Voice routing policies not available in this Teams module version (skipping)" -ForegroundColor Yellow
        }
        
        if ($policies.Count -eq 0) {
            Write-Host "No voice policies found." -ForegroundColor Yellow
            return $null
        }
        
        Write-Host "Found $($policies.Count) total voice policies" -ForegroundColor Green
        Write-Host "`n"
        
        return $policies
    }
    catch {
        Write-Host "Error retrieving voice policies: $_" -ForegroundColor Red
        return $null
    }
}

function Export-ToHTML {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Data,
        
        [Parameter(Mandatory = $true)]
        [string]$OrganizationName,
        
        [Parameter(Mandatory = $true)]
        [string]$BaseExportPath
    )
    
    # Create directory structure
    if (-not (Test-Path $BaseExportPath)) {
        New-Item -ItemType Directory -Path $BaseExportPath -Force | Out-Null
    }
    
    $timestamp = Get-Date -Format "MM_dd_yy_HH_mm_ss"
    $fileName = "${OrganizationName}__${timestamp}.html"
    $filePath = Join-Path $BaseExportPath $fileName
    
    $htmlContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Microsoft Teams Voice Policies Report</title>
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
            max-width: 1600px;
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
        
        .filter-buttons {
            display: flex;
            gap: 10px;
            flex-wrap: wrap;
        }
        
        .filter-btn {
            padding: 8px 15px;
            background: #f0f0f0;
            border: 1px solid #ddd;
            border-radius: 6px;
            cursor: pointer;
            font-size: 0.9em;
            transition: all 0.3s;
        }
        
        .filter-btn:hover {
            background: #e0e0e0;
        }
        
        .filter-btn.active {
            background: #667eea;
            color: white;
            border-color: #667eea;
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
        
        .policy-type-badge {
            display: inline-block;
            padding: 6px 12px;
            border-radius: 4px;
            font-weight: 500;
            font-size: 0.9em;
        }
        
        .calling-policy {
            background: #d4edda;
            color: #155724;
        }
        
        .voicemail-policy {
            background: #d1ecf1;
            color: #0c5460;
        }
        
        .identity-policy {
            background: #fff3cd;
            color: #856404;
        }
        
        .routing-policy {
            background: #f8d7da;
            color: #721c24;
        }
        
        .enabled {
            color: #28a745;
            font-weight: 600;
        }
        
        .disabled {
            color: #dc3545;
            font-weight: 600;
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
            <h1>Microsoft Teams Voice Policies Report</h1>
            <p>Generated on $(Get-Date -Format 'MMMM dd, yyyy HH:mm:ss')</p>
        </div>
        
        <div class="controls">
            <div class="search-box">
                <input type="text" id="searchInput" placeholder="Search by policy name, type, or setting...">
            </div>
            <div class="filter-buttons">
                <button class="filter-btn active" onclick="filterByType('')">All Policies</button>
                <button class="filter-btn" onclick="filterByType('Calling')">Calling Policies</button>
                <button class="filter-btn" onclick="filterByType('Voicemail')">Voicemail Policies</button>
                <button class="filter-btn" onclick="filterByType('Identity')">Identity Policies</button>
                <button class="filter-btn" onclick="filterByType('Routing')">Routing Policies</button>
            </div>
            <button onclick="resetFilters()">Reset</button>
            <button onclick="exportToCSV()">Export CSV</button>
        </div>
        
        <div class="info-box">
            <strong>Tip:</strong> Click on column headers to sort. Use search and filters to narrow down results.
        </div>
        
        <div class="table-wrapper">
            <table id="policiesTable">
                <thead>
                    <tr>
                        <th onclick="sortTable(0)">Policy Type</th>
                        <th onclick="sortTable(1)">Policy Name</th>
                        <th onclick="sortTable(2)">Description</th>
                        <th onclick="sortTable(3)">Key Settings</th>
                    </tr>
                </thead>
                <tbody>
"@

    # Add table rows
    foreach ($item in $Data) {
        $typeClass = if ($item.PolicyType -match "Calling") { "calling-policy" } 
                    elseif ($item.PolicyType -match "Voicemail") { "voicemail-policy" }
                    elseif ($item.PolicyType -match "Identity") { "identity-policy" }
                    else { "routing-policy" }
        
        $keySettings = @()
        foreach ($prop in $item.PSObject.Properties) {
            if ($prop.Name -notin @("PolicyType", "PolicyName", "Description", "AdditionalSettings") -and $prop.Value) {
                $keySettings += "$($prop.Name): $($prop.Value)"
            }
        }
        $settingsText = ($keySettings | Select-Object -First 3) -join " | "
        
        $htmlContent += @"
                    <tr>
                        <td><span class="policy-type-badge $typeClass">$($item.PolicyType)</span></td>
                        <td><strong>$($item.PolicyName)</strong></td>
                        <td>$($item.Description -replace '<', '&lt;' -replace '>', '&gt;')</td>
                        <td>$settingsText</td>
                    </tr>
"@
    }

    $htmlContent += @"
                </tbody>
            </table>
        </div>
        
        <div class="footer">
            <p>Total Voice Policies: <strong>$($Data.Count)</strong></p>
            <p>Report generated using Teams Voice Policy Auditor</p>
        </div>
    </div>
    
    <script>
        function sortTable(columnIndex) {
            const table = document.getElementById('policiesTable');
            const tbody = table.querySelector('tbody');
            const rows = Array.from(tbody.querySelectorAll('tr:not(.hide)'));
            
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
            const table = document.getElementById('policiesTable');
            const rows = table.querySelectorAll('tbody tr');
            
            rows.forEach(row => {
                const text = row.textContent.toLowerCase();
                row.classList.toggle('hide', !text.includes(searchInput));
            });
        }
        
        function filterByType(typeFilter) {
            const table = document.getElementById('policiesTable');
            const rows = table.querySelectorAll('tbody tr');
            
            document.querySelectorAll('.filter-btn').forEach(btn => {
                btn.classList.remove('active');
            });
            event.target.classList.add('active');
            
            rows.forEach(row => {
                if (typeFilter === '') {
                    row.classList.remove('hide');
                } else {
                    const policyType = row.cells[0].textContent.toLowerCase();
                    row.classList.toggle('hide', !policyType.includes(typeFilter.toLowerCase()));
                }
            });
        }
        
        function resetFilters() {
            document.getElementById('searchInput').value = '';
            document.querySelectorAll('.filter-btn').forEach(btn => btn.classList.remove('active'));
            document.querySelector('.filter-btn').classList.add('active');
            document.querySelectorAll('tbody tr').forEach(row => row.classList.remove('hide'));
        }
        
        function exportToCSV() {
            const table = document.getElementById('policiesTable');
            let csv = [];
            const rows = table.querySelectorAll('tr:not(.hide)');
            
            rows.forEach(row => {
                const cols = row.querySelectorAll('td, th');
                const csvRow = [];
                cols.forEach(col => {
                    csvRow.push('"' + col.textContent.trim().replace(/"/g, '""') + '"');
                });
                csv.push(csvRow.join(','));
            });
            
            const csvContent = csv.join('\n');
            const blob = new Blob([csvContent], { type: 'text/csv' });
            const link = document.createElement('a');
            link.href = URL.createObjectURL(blob);
            link.download = 'TeamsVoicePolicies_$(Get-Date -Format 'MM_dd_yy_HH_mm_ss').csv';
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
        [string]$OrganizationName,
        
        [Parameter(Mandatory = $true)]
        [string]$BaseExportPath
    )
    
    # Create directory structure
    if (-not (Test-Path $BaseExportPath)) {
        New-Item -ItemType Directory -Path $BaseExportPath -Force | Out-Null
    }
    
    $timestamp = Get-Date -Format "MM_dd_yy_HH_mm_ss"
    $fileName = "${OrganizationName}__${timestamp}.json"
    $filePath = Join-Path $BaseExportPath $fileName
    
    $jsonData = @{
        GeneratedDate = Get-Date -Format "o"
        TotalPolicies = $Data.Count
        Policies = @()
    }
    
    foreach ($item in $Data) {
        $policyObject = @{}
        foreach ($prop in $item.PSObject.Properties) {
            $policyObject[$prop.Name] = $prop.Value
        }
        $jsonData.Policies += $policyObject
    }
    
    $jsonData | ConvertTo-Json -Depth 10 | Out-File -FilePath $filePath -Encoding UTF8 -Force
    Write-Host "JSON report exported to: $filePath" -ForegroundColor Green
    return $filePath
}

# Main execution
try {
    # Connect to Teams and Graph
    Connect-TeamsAdmin
    Connect-ToMgGraph
    
    # Get organization info
    $orgInfo = Get-OrganizationInfo
    
    # Validate organization info and set organization name
    if ($null -eq $orgInfo -or [string]::IsNullOrWhiteSpace($orgInfo.DisplayName)) {
        Write-Host "Warning: Could not retrieve organization display name. Using default." -ForegroundColor Yellow
        $organizationName = "Unknown_Organization_$(Get-Date -Format 'MM_dd_yy')"
    }
    else {
        $organizationName = $orgInfo.DisplayName -replace '\s+', '_'  # Replace spaces with underscores
    }
    
    Write-Host "`n==========================================`n" -ForegroundColor Yellow
    
    # Get voice policies
    $policies = Get-AllTeamsVoicePolicies
    
    if ($policies -and $policies.Count -gt 0) {
        # Display to console
        Write-Host "Voice Policies Summary:" -ForegroundColor Cyan
        Write-Host "==========================================`n" -ForegroundColor Yellow
        
        $policies | Format-Table -AutoSize
        
        Write-Host "`n"
        
        # Always export to HTML
        Write-Host "Generating HTML report..." -ForegroundColor Cyan
        $htmlFile = Export-ToHTML -Data $policies -OrganizationName $organizationName -BaseExportPath $BaseExportPath
        
        # Always export to JSON
        Write-Host "Generating JSON report..." -ForegroundColor Cyan
        $jsonFile = Export-ToJSON -Data $policies -OrganizationName $organizationName -BaseExportPath $BaseExportPath
        
        # Summary
        Write-Host "`n==========================================`n" -ForegroundColor Yellow
        Write-Host "Export Summary:" -ForegroundColor Cyan
        Write-Host "  Output Directory: $BaseExportPath" -ForegroundColor Green
        Write-Host "  Organization Name: $organizationName" -ForegroundColor Green
        Write-Host "  Total Voice Policies: $($policies.Count)" -ForegroundColor Green
        Write-Host "  HTML File: $(Split-Path $htmlFile -Leaf)" -ForegroundColor Green
        Write-Host "  JSON File: $(Split-Path $jsonFile -Leaf)" -ForegroundColor Green
        
        Write-Host "`nFor detailed policy settings, open the HTML report in your browser." -ForegroundColor Cyan
    }
    else {
        Write-Host "No voice policies found in the organization." -ForegroundColor Yellow
    }
    
    Write-Host "`nDisconnecting from Teams and Microsoft Graph..." -ForegroundColor Cyan
    Disconnect-MicrosoftTeams -ErrorAction SilentlyContinue | Out-Null
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    Write-Host "Disconnected successfully." -ForegroundColor Green
}
catch {
    Write-Host "An error occurred: $_" -ForegroundColor Red
    exit 1
}
