#Requires -Module Microsoft.Graph

# Check if Microsoft.Graph module is available
if (-not (Get-Module -Name Microsoft.Graph -ListAvailable)) {
    Write-Error "Microsoft.Graph module is not installed. Please install it using: Install-Module Microsoft.Graph -Scope CurrentUser"
    exit 1
}

<#
.SYNOPSIS
    Exports all Microsoft 365 users and their phone numbers (used as caller ID) to a sortable HTML file using Microsoft Graph.

.DESCRIPTION
    This script connects to Microsoft Graph, retrieves all users with their display name, email, and phone numbers,
    and exports the data to an HTML file with sortable columns. Phone numbers are used as proxy for caller ID
    since Microsoft Graph does not expose CallingLineIdentity policies directly.

.PARAMETER OutputPath
    The path where the HTML file will be saved. Default is "TeamsUsersCallerIdGraph.html" in the current directory.

.PARAMETER Scopes
    The Microsoft Graph scopes required. Default includes User.Read.All.

.PARAMETER WhatIf
    Shows what would happen if the script runs without actually saving the file.

.PARAMETER LogFile
    Optional path to a log file for detailed execution logging.

.EXAMPLE
    .\Export-TeamsUsersCallerIdGraph.ps1

.EXAMPLE
    .\Export-TeamsUsersCallerIdGraph.ps1 -OutputPath "C:\Reports\UsersCallerId.html" -LogFile "C:\Logs\script.log"

.EXAMPLE
    .\Export-TeamsUsersCallerIdGraph.ps1 -WhatIf -Verbose

.NOTES
    Requires Microsoft.Graph module installed and appropriate permissions.
    Connects with User.Read.All scope by default.
    Phone numbers include business and mobile phones.
#>

param (
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = "TeamsUsersCallerIdGraph.html",

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string[]]$Scopes = @("User.Read.All"),

    [Parameter(Mandatory = $false)]
    [switch]$WhatIf,

    [Parameter(Mandatory = $false)]
    [string]$LogFile
)

# Function to write to log file
function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )
    if ($LogFile) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "$timestamp [$Level] $Message" | Out-File -FilePath $LogFile -Append -Encoding UTF8
    }
}

# Function to create sortable HTML table
function New-SortableHtmlTable {
    param (
        [Parameter(Mandatory = $true)]
        [array]$Data,

        [Parameter(Mandatory = $true)]
        [string]$Title,

        [Parameter(Mandatory = $false)]
        [string]$CssStyle = @"
<style>
    body { font-family: Arial, sans-serif; margin: 20px; }
    h1 { color: #0078D4; }
    table { border-collapse: collapse; width: 100%; margin-top: 20px; }
    th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
    th { background-color: #f2f2f2; cursor: pointer; position: relative; }
    th:hover { background-color: #e6e6e6; }
    th.sort-asc::after { content: ' ▲'; }
    th.sort-desc::after { content: ' ▼'; }
    tr:nth-child(even) { background-color: #f9f9f9; }
    tr:hover { background-color: #f1f1f1; }
</style>
"@,

        [Parameter(Mandatory = $false)]
        [string]$JavaScript = @"
<script>
    function sortTable(n, tableId) {
        var table = document.getElementById(tableId);
        var rows = Array.from(table.rows).slice(1); // Skip header
        var isAscending = table.getAttribute('data-sort-dir') !== 'asc';
        table.setAttribute('data-sort-dir', isAscending ? 'asc' : 'desc');

        rows.sort(function(a, b) {
            var aVal = a.cells[n].textContent.toLowerCase();
            var bVal = b.cells[n].textContent.toLowerCase();

            // Check if values are numbers
            var aNum = parseFloat(aVal);
            var bNum = parseFloat(bVal);
            if (!isNaN(aNum) && !isNaN(bNum)) {
                return isAscending ? aNum - bNum : bNum - aNum;
            }

            return isAscending ? aVal.localeCompare(bVal) : bVal.localeCompare(aVal);
        });

        // Clear existing rows
        while (table.rows.length > 1) {
            table.deleteRow(1);
        }

        // Re-add sorted rows
        rows.forEach(function(row) {
            table.appendChild(row);
        });

        // Update sort indicators
        var headers = table.rows[0].cells;
        for (var i = 0; i < headers.length; i++) {
            headers[i].classList.remove('sort-asc', 'sort-desc');
        }
        headers[n].classList.add(isAscending ? 'sort-asc' : 'sort-desc');
    }

    // Add click handlers to headers
    document.addEventListener('DOMContentLoaded', function() {
        var table = document.getElementById('userTable');
        var headers = table.rows[0].cells;
        for (var i = 0; i < headers.length; i++) {
            headers[i].addEventListener('click', (function(index) {
                return function() { sortTable(index, 'userTable'); };
            })(i));
        }
    });
</script>
"@
    )

    # Build HTML content
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>$Title</title>
    $CssStyle
    $JavaScript
</head>
<body>
    <h1>$Title</h1>
    <p>Report generated on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
    <table id="userTable">
        <thead>
            <tr>
"@

    # Add headers
    if ($Data.Count -gt 0) {
        $Data[0].PSObject.Properties.Name | ForEach-Object {
            $html += "                <th>$_</th>`n"
        }
    }

    $html += @"
            </tr>
        </thead>
        <tbody>
"@

    # Add data rows
    foreach ($item in $Data) {
        $html += "            <tr>`n"
        $item.PSObject.Properties | ForEach-Object {
            $value = $_.Value
            if ($null -eq $value) { $value = "" }
            $html += "                <td>$value</td>`n"
        }
        $html += "            </tr>`n"
    }

    $html += @"
        </tbody>
    </table>
</body>
</html>
"@

    return $html
}

# Main script execution
try {
    Write-Log "Script execution started"
    Write-Verbose "Starting script execution"
    Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Yellow
    $connectParams = @{
        Scopes = $Scopes
        NoWelcome = $true
    }
    Connect-MgGraph @connectParams
    Write-Log "Connected to Microsoft Graph with scopes: $($Scopes -join ', ')"
    Write-Verbose "Successfully connected to Microsoft Graph"

    Write-Host "Retrieving users and their phone information..." -ForegroundColor Yellow

    # Define properties to retrieve
    $userProperties = @(
        'Id', 'DisplayName', 'Mail', 'UserPrincipalName',
        'BusinessPhones', 'MobilePhone', 'OfficeLocation', 'Department'
    )

    # Get all users with relevant properties
    # Note: Microsoft Graph does not expose CallingLineIdentity directly
    # Using BusinessPhones and MobilePhone as proxy for caller ID information
    $getMgUserParams = @{
        All = $true
        Property = $userProperties
    }
    $users = Get-MgUser @getMgUserParams
    Write-Log "Retrieved $($users.Count) users from Microsoft Graph"
    Write-Verbose "Retrieved $($users.Count) users from Microsoft Graph"
    Write-Host "Found $($users.Count) users. Processing data..." -ForegroundColor Green

    # Process user data
    Write-Host "Processing user data..." -ForegroundColor Yellow
    Write-Verbose "Starting user data processing"
    $userData = $users | ForEach-Object -Begin { $i = 0 } -Process {
        if ($i % 100 -eq 0) { Write-Progress -Activity "Processing Users" -Status "$i of $($users.Count)" -PercentComplete (($i / $users.Count) * 100) }
        $i++
        # Combine business and mobile phones
        $phones = @()
        if ($_.BusinessPhones) {
            $phones += $_.BusinessPhones
        }
        if ($_.MobilePhone) {
            $phones += $_.MobilePhone
        }
        $phoneString = $phones -join "; "

        [PSCustomObject]@{
            DisplayName     = $_.DisplayName
            Email           = $_.Mail
            UserPrincipalName = $_.UserPrincipalName
            PhoneNumbers    = $phoneString
            OfficeLocation  = $_.OfficeLocation
            Department      = $_.Department
        }
    } -End { Write-Progress -Activity "Processing Users" -Completed }
    Write-Log "Completed processing $($userData.Count) users"
    Write-Verbose "Completed processing $($userData.Count) users"
    Write-Verbose "Completed processing $($userData.Count) users"

    Write-Host "Generating HTML report..." -ForegroundColor Yellow

    # Validate output path
    $outputDir = Split-Path -Path $OutputPath -Parent
    if ($outputDir -and -not (Test-Path -Path $outputDir)) {
        try {
            New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
            Write-Host "Created output directory: $outputDir" -ForegroundColor Green
        } catch {
            Write-Error "Failed to create output directory '$outputDir': $_"
            exit 1
        }
    }

    # Generate HTML content
    $htmlContent = New-SortableHtmlTable -Data $userData -Title "Microsoft 365 Users and Caller ID Information (via Microsoft Graph)"

    # Save to file
    if ($WhatIf) {
        Write-Log "WhatIf mode: Would save HTML report to $OutputPath with $($userData.Count) users"
        Write-Host "WhatIf: Would save HTML report to: $OutputPath" -ForegroundColor Cyan
        Write-Host "WhatIf: Report would contain $($userData.Count) users" -ForegroundColor Cyan
    } else {
        try {
            $htmlContent | Out-File -FilePath $OutputPath -Encoding UTF8
            Write-Log "HTML report saved to $OutputPath with $($userData.Count) users"
            Write-Verbose "HTML report saved to $OutputPath"
        } catch {
            Write-Log "Failed to save HTML report to '$OutputPath': $_" "ERROR"
            Write-Error "Failed to save HTML report to '$OutputPath': $_"
            exit 1
        }
    }

    Write-Host "Report saved to: $OutputPath" -ForegroundColor Green
    Write-Host "Total users exported: $($userData.Count)" -ForegroundColor Green

    # Disconnect from Graph
    Disconnect-MgGraph
    Write-Log "Disconnected from Microsoft Graph. Script completed successfully."
    Write-Verbose "Disconnected from Microsoft Graph"

} catch {
    Write-Log "Script execution failed: $_" "ERROR"
    Write-Error "An error occurred: $_"
    # Ensure we disconnect even on error
    try { Disconnect-MgGraph } catch { }
    exit 1
}