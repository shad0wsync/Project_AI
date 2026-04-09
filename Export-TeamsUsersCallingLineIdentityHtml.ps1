# Script: Export-TeamsUsersCallingLineIdentityHtml.ps1
# Description: Retrieves Teams users and their Calling Line Identity, then exports to a sortable HTML file.

<#
.SYNOPSIS
Exports Teams users and their Calling Line Identity to a sortable HTML report.

.DESCRIPTION
Connects to Microsoft Teams via SkypeOnlineConnector, retrieves all users with their CallingLineIdentity,
and generates a sortable HTML file.

.PARAMETER IncludeGuests
Include guest accounts in the report.

.PARAMETER ExportHtmlPath
Path to the generated sortable HTML report.
#>

[CmdletBinding()]
param(
    [switch]$IncludeGuests,
    [string]$ExportHtmlPath = "TeamsUsersCallingLineIdentity.html"
)

function New-SortableHtmlTable {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IEnumerable]$Data,
        [Parameter(Mandatory = $true)]
        [string]$Title
    )

    $htmlBody = $Data | ConvertTo-Html -Property DisplayName, UserPrincipalName, InterpretedUserType, EnterpriseVoiceEnabled, CallingLineIdentity -Title $Title -PreContent "<h1>$Title</h1>" -PostContent '<p>Generated on ' + (Get-Date).ToString('u') + '</p>'

    $style = @"
<style>
    body {
        font-family: Segoe UI, Arial, sans-serif;
        margin: 20px;
        background: #f7f8fb;
        color: #202124;
    }
    h1 {
        font-size: 24px;
        margin-bottom: 16px;
    }
    table {
        border-collapse: collapse;
        width: 100%;
        background: white;
        box-shadow: 0 0 12px rgba(0,0,0,0.08);
    }
    th, td {
        padding: 12px 14px;
        text-align: left;
        border-bottom: 1px solid #e1e3e8;
    }
    th {
        cursor: pointer;
        position: sticky;
        top: 0;
        background: #fafbff;
        color: #111827;
    }
    th:hover {
        background: #f0f4ff;
    }
    tr:nth-child(even) {
        background: #f7f8fb;
    }
    tr:hover {
        background: #eef2ff;
    }
    .small {
        font-size: 0.9em;
        color: #5f6d7a;
    }
</style>
"@

    $script = @"
<script>
    function sortTable(columnIndex) {
        const table = document.getElementById('callingLineIdentityTable');
        const tbody = table.tBodies[0];
        const rows = Array.from(tbody.querySelectorAll('tr'));
        const currentOrder = table.getAttribute('data-sort-order') || 'asc';
        const newOrder = currentOrder === 'asc' ? 'desc' : 'asc';

        rows.sort((a, b) => {
            const aText = a.children[columnIndex].innerText.trim().toLowerCase();
            const bText = b.children[columnIndex].innerText.trim().toLowerCase();
            if (!isNaN(Date.parse(aText)) && !isNaN(Date.parse(bText))) {
                return newOrder === 'asc' ? new Date(aText) - new Date(bText) : new Date(bText) - new Date(aText);
            }
            if (!isNaN(aText) && !isNaN(bText)) {
                return newOrder === 'asc' ? aText - bText : bText - aText;
            }
            return newOrder === 'asc' ? aText.localeCompare(bText) : bText.localeCompare(aText);
        });

        rows.forEach(row => tbody.appendChild(row));
        table.setAttribute('data-sort-order', newOrder);
    }
</script>
"@

    $htmlBody = $htmlBody -replace '<table>', '<table id="callingLineIdentityTable">'
    $htmlBody = $htmlBody -replace '<th>', '<th onclick="sortTable(Array.prototype.indexOf.call(this.parentNode.children, this))">'
    return $htmlBody + $style + $script
}

try {
    if (-not (Get-Module -ListAvailable -Name SkypeOnlineConnector)) {
        throw "SkypeOnlineConnector module not found."
    }
    Import-Module SkypeOnlineConnector -ErrorAction Stop
    Write-Verbose "Imported SkypeOnlineConnector module."
}
catch {
    Write-Error "The SkypeOnlineConnector module is not installed. Install it from https://www.microsoft.com/en-us/download/details.aspx?id=39366."
    return
}

try {
    Write-Verbose "Connecting to Skype for Business Online..."
    $session = New-CsOnlineSession -ErrorAction Stop
    Import-PSSession $session -AllowClobber -ErrorAction Stop
    Write-Verbose "Successfully connected to Skype for Business Online."
}
catch {
    Write-Error "Failed to connect to Skype for Business Online. Verify your credentials."
    return
}

$filter = if ($IncludeGuests) { $null } else { "InterpretedUserType -ne 'Guest'" }

Write-Verbose "Retrieving users with filter: $filter"
$users = Get-CsUser -Filter $filter -ErrorAction Stop |
    Select-Object DisplayName, UserPrincipalName, InterpretedUserType, EnterpriseVoiceEnabled, CallingLineIdentity

Write-Verbose "Generating HTML report..."
$htmlReport = New-SortableHtmlTable -Data $users -Title 'Teams Users Calling Line Identity Report'
$htmlReport | Set-Content -Path $ExportHtmlPath -Encoding UTF8
Write-Host "Generated sortable HTML report: $ExportHtmlPath"

# Clean up session
Remove-PSSession $session
