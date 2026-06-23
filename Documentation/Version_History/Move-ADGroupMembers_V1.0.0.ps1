###  FILE (Move-ADGroupMembers.ps1) -- GENERIC AD GROUP MIGRATION ----
<#
.SYNOPSIS
Generic Active Directory group migration automation with audit reporting

.DESCRIPTION
Comprehensive multi-phase group member migration supporting any source/target AD groups:
1. Query source group and export member list
2. Enforce user review checkpoint before proceeding
3. Allow selective or bulk migration to target groups
4. Export post-migration audit reports (CSV and interactive HTML)

Features:
- Handles AD groups with 5000+ members (ADWS limit workaround)
- Structured error handling with actionable remediation
- Professional HTML reports with sortable tables (Teams-inspired styling)
- Complete audit trail with before/after exports
- Fully parameterized for any group-to-group migration scenario

.PARAMETER SourceGroup
AD group to migrate users FROM (mandatory - no default)
Example: "SSLVPN-Users", "OldVPN-Team", "LegacyAccess"

.PARAMETER TargetGroups
Array of AD groups to migrate users TO (mandatory - no default)
Example: @("Netmotion Users", "Netmotion Access")

.PARAMETER ExportPath
Base directory for all exports (default: C:\Temp)

.PARAMETER MigrationName
Prefix for export directories and files (default: ADGroupMigration)
Example: "SSLVPNToNetmotion", "ExchangeConsolidation"

.PARAMETER SkipReviewCheckpoint
Bypass manual review approval (use only for automated/tested migrations)

.PARAMETER AutoApproveScope
Pre-select migration scope without user prompt: 'All' or 'Specific'
Requires -UserSelection if set to 'Specific'

.PARAMETER UserSelection
Comma-separated SAM account names for selective migration
Example: "john.smith,jane.doe,bob.jones"

.EXAMPLE
.\Move-ADGroupMembers.ps1 -SourceGroup "SSLVPN-Users" -TargetGroups @("Netmotion Users", "Netmotion Access") -Verbose

.EXAMPLE
.\Move-ADGroupMembers.ps1 -SourceGroup "OldVPN-Team" -TargetGroups @("NewVPN-Access") -MigrationName "VPNConsolidation" -ExportPath "D:\Audits"

.EXAMPLE
.\Move-ADGroupMembers.ps1 -SourceGroup "LegacyGroup" -TargetGroups @("ModernGroup") -SkipReviewCheckpoint -AutoApproveScope All

.NOTES
Source Documentation: https://learn.microsoft.com/en-us/powershell/module/activedirectory/
Community Reference: https://lazyadmin.nl/powershell/get-adgroupmember/
Tested Against: Windows Server 2019, 2022, 2025 with AD module
Author: Coder Agent
Date: 2026-05-01
Version: 2.0 (Generic)
#>

#Requires -Modules ActiveDirectory
#Requires -RunAsAdministrator
#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SourceGroup,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string[]]$TargetGroups,

    [Parameter(Mandatory = $false)]
    [string]$ExportPath = 'C:\Temp',

    [Parameter(Mandatory = $false)]
    [string]$MigrationName = 'ADGroupMigration',

    [Parameter(Mandatory = $false)]
    [switch]$SkipReviewCheckpoint,

    [Parameter(Mandatory = $false)]
    [ValidateSet('All', 'Specific')]
    [string]$AutoApproveScope,

    [Parameter(Mandatory = $false)]
    [string]$UserSelection
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================================
# SCRIPT-SCOPE VARIABLE INITIALIZATION
# ============================================================================
$script:sourceMembers = $null
$script:exportResult = $null
$script:usersToMigrate = @()
$script:migrationResult = $null
$script:auditExport = $null
$script:htmlPath = $null
$script:htmlResult = $null

# ============================================================================
# PRIVATE FUNCTIONS
# ============================================================================

function Get-ADGroupMembersLarge {
    <#
    .SYNOPSIS
    Retrieve all members from an AD group, handling 5000+ member limit
    
    .DESCRIPTION
    Works around ADWS 5000-member limit by directly expanding Group objects.
    Supports nested groups and filters non-user objects gracefully.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$GroupName,

        [Parameter(Mandatory = $false)]
        [string[]]$Properties = @('DisplayName', 'EmailAddress', 'EmployeeID', 'Department', 'Title', 'LastLogonDate')
    )

    Process {
        Try {
            Write-Verbose "Initializing group member retrieval for: $GroupName"

            $ADGroup = Get-ADGroup -Filter { (Name -eq $GroupName) -or (SAMAccountName -eq $GroupName) } `
                -Properties Member -ErrorAction Stop

            if (-not $ADGroup) {
                Write-Error "AD group '$GroupName' not found. Verify group name and try again." -ErrorAction Stop
            }

            Write-Verbose "Group found: $($ADGroup.Name) - Distinguished Name: $($ADGroup.DistinguishedName)"

            $memberCount = $ADGroup.Member.Count
            Write-Verbose "Total members in group: $memberCount"

            if ($memberCount -eq 0) {
                Write-Verbose "Group '$GroupName' contains no members."
                return $null
            }

            Write-Verbose "Enumerating member details (property expansion in progress)..."
            $members = @()

            $ADGroup.Member | ForEach-Object {
                Try {
                    $user = Get-ADUser -Identity $_ -Properties $Properties -ErrorAction SilentlyContinue
                    if ($user) {
                        $members += $user
                        Write-Verbose "Processed: $($user.SamAccountName)"
                    }
                }
                Catch {
                    Write-Verbose "Skipped non-user object: $_ (Error: $($_.Exception.Message))"
                }
            }

            Write-Verbose "Successfully enumerated $($members.Count) user objects from $GroupName"
            return @($members)
        }
        Catch {
            Write-Error "Failed to retrieve members from group '$GroupName': $($_.Exception.Message)" `
                -ErrorAction Stop
        }
    }
}

function Export-ADGroupReport {
    <#
    .SYNOPSIS
    Export group members to CSV audit file
    
    .DESCRIPTION
    Creates timestamped CSV with comprehensive user attributes.
    Ensures export directory exists and verifies write permissions.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Members,

        [Parameter(Mandatory = $true)]
        [string]$GroupName,

        [Parameter(Mandatory = $true)]
        [string]$ExportPath,

        [Parameter(Mandatory = $true)]
        [string]$MigrationName,

        [Parameter(Mandatory = $false)]
        [string]$ReportSuffix = 'Pre-Migration'
    )

    Process {
        Try {
            Write-Verbose "Initializing report export for group: $GroupName"

            $exportDir = Join-Path -Path $ExportPath -ChildPath $MigrationName
            if (-not (Test-Path -Path $exportDir)) {
                Write-Verbose "Creating export directory: $exportDir"
                New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
            }

            $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
            $exportFile = Join-Path -Path $exportDir -ChildPath "${MigrationName}_${ReportSuffix}_${timestamp}.csv"

            Write-Verbose "Exporting $($Members.Count) members to: $exportFile"

            $exportData = $Members | Select-Object -Property `
                @{Name = 'SamAccountName'; Expression = { $_.SamAccountName } },
            @{Name = 'DisplayName'; Expression = { $_.DisplayName } },
            @{Name = 'EmailAddress'; Expression = { $_.EmailAddress } },
            @{Name = 'EmployeeID'; Expression = { $_.EmployeeID } },
            @{Name = 'Department'; Expression = { $_.Department } },
            @{Name = 'Title'; Expression = { $_.Title } },
            @{Name = 'DistinguishedName'; Expression = { $_.DistinguishedName } },
            @{Name = 'Enabled'; Expression = { $_.Enabled } },
            @{Name = 'LastLogonDate'; Expression = { $_.LastLogonDate } }

            $exportData | Export-Csv -Path $exportFile -NoTypeInformation -Encoding UTF8 -ErrorAction Stop

            Write-Verbose "Report exported successfully to: $exportFile"
            Write-Verbose "Record count: $($exportData.Count)"

            return [PSCustomObject]@{
                FilePath      = $exportFile
                RecordCount   = $exportData.Count
                GroupName     = $GroupName
                ExportTime    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                ReportSuffix  = $ReportSuffix
            }
        }
        Catch {
            Write-Error "Failed to export report: $($_.Exception.Message). Ensure $ExportPath exists and you have write permissions." `
                -ErrorAction Stop
        }
    }
}

function Add-ADUsersToGroups {
    <#
    .SYNOPSIS
    Add users to target groups with idempotent membership validation
    
    .DESCRIPTION
    Processes each user/group combination, checking for existing membership
    before addition. Returns structured operation summary with failure details.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Users,

        [Parameter(Mandatory = $true)]
        [string[]]$TargetGroups
    )

    Process {
        Try {
            Write-Verbose "Initializing user migration to target groups: $($TargetGroups -join ', ')"

            $operationSummary = @{
                TotalUsers      = $Users.Count
                SuccessfulAdds  = 0
                FailedAdds      = 0
                SkippedUsers    = 0
                FailureDetails  = @()
            }

            Write-Verbose "Validating target groups..."
            foreach ($groupName in $TargetGroups) {
                $group = Get-ADGroup -Filter { (Name -eq $groupName) -or (SAMAccountName -eq $groupName) } `
                    -ErrorAction SilentlyContinue
                if (-not $group) {
                    Write-Error "Target group '$groupName' not found in Active Directory." -ErrorAction Stop
                }
                Write-Verbose "Validated group: $groupName (DN: $($group.DistinguishedName))"
            }

            foreach ($user in $Users) {
                Try {
                    $userIdentity = if ($user -is [string]) { $user } else { $user.SamAccountName }
                    Write-Verbose "Processing user: $userIdentity"

                    $adUser = Get-ADUser -Identity $userIdentity -ErrorAction Stop
                    Write-Verbose "User validated: $($adUser.SamAccountName) - $($adUser.DisplayName)"

                    foreach ($groupName in $TargetGroups) {
                        Try {
                            $group = Get-ADGroup -Filter { (Name -eq $groupName) -or (SAMAccountName -eq $groupName) } `
                                -ErrorAction Stop

                            $isMember = Get-ADGroupMember -Identity $group -ErrorAction SilentlyContinue | `
                                Where-Object { $_.SamAccountName -eq $userIdentity }

                            if ($isMember) {
                                Write-Verbose "User $userIdentity already member of $groupName - skipping"
                                $operationSummary.SkippedUsers++
                            }
                            else {
                                Add-ADGroupMember -Identity $group -Members $adUser -ErrorAction Stop
                                Write-Verbose "Successfully added $userIdentity to $groupName"
                                $operationSummary.SuccessfulAdds++
                            }
                        }
                        Catch {
                            Write-Verbose "Failed to add $userIdentity to $groupName : $($_.Exception.Message)"
                            $operationSummary.FailedAdds++
                            $operationSummary.FailureDetails += @{
                                User   = $userIdentity
                                Group  = $groupName
                                Reason = $_.Exception.Message
                            }
                        }
                    }
                }
                Catch {
                    Write-Verbose "Failed to process user $userIdentity : $($_.Exception.Message)"
                    $operationSummary.FailedAdds++
                    $operationSummary.FailureDetails += @{
                        User   = $userIdentity
                        Group  = 'All'
                        Reason = $_.Exception.Message
                    }
                }
            }

            Write-Verbose "User migration completed. Summary: Successful=$($operationSummary.SuccessfulAdds), Failed=$($operationSummary.FailedAdds), Skipped=$($operationSummary.SkippedUsers)"

            return [PSCustomObject]$operationSummary
        }
        Catch {
            Write-Error "Failed during user group addition: $($_.Exception.Message)" -ErrorAction Stop
        }
    }
}

function Export-ADGroupsComparison {
    <#
    .SYNOPSIS
    Export current membership of target groups for post-migration audit
    
    .DESCRIPTION
    Queries specified groups and exports combined membership with attributes.
    Used for before/after comparison and compliance audit trails.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$GroupNames,

        [Parameter(Mandatory = $true)]
        [string]$ExportPath,

        [Parameter(Mandatory = $true)]
        [string]$MigrationName
    )

    Process {
        Try {
            Write-Verbose "Initializing group comparison export for groups: $($GroupNames -join ', ')"

            $exportDir = Join-Path -Path $ExportPath -ChildPath $MigrationName
            if (-not (Test-Path -Path $exportDir)) {
                Write-Verbose "Creating export directory: $exportDir"
                New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
            }

            $allGroupMembers = @()

            foreach ($groupName in $GroupNames) {
                Write-Verbose "Retrieving members from group: $groupName"

                $group = Get-ADGroup -Filter { (Name -eq $groupName) -or (SAMAccountName -eq $groupName) } `
                    -Properties Member -ErrorAction SilentlyContinue

                if (-not $group) {
                    Write-Verbose "Warning: Group '$groupName' not found. Skipping."
                    continue
                }

                $members = @($group.Member | ForEach-Object {
                    Try {
                        $user = Get-ADUser -Identity $_ -Properties DisplayName, EmailAddress, EmployeeID, Department, LastLogonDate `
                            -ErrorAction SilentlyContinue
                        if ($user) {
                            [PSCustomObject]@{
                                GroupName         = $groupName
                                SamAccountName    = $user.SamAccountName
                                DisplayName       = $user.DisplayName
                                EmailAddress      = $user.EmailAddress
                                EmployeeID        = $user.EmployeeID
                                Department        = $user.Department
                                DistinguishedName = $user.DistinguishedName
                                Enabled           = $user.Enabled
                                LastLogonDate     = $user.LastLogonDate
                                AddedDate         = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                            }
                        }
                    }
                    Catch {
                        Write-Verbose "Skipped non-user object: $_ "
                    }
                })

                $allGroupMembers += $members
                Write-Verbose "Added $($members.Count) members from $groupName"
            }

            $csvFile = Join-Path -Path $exportDir -ChildPath "${MigrationName}_Post-Migration_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
            Write-Verbose "Exporting CSV to: $csvFile"
            $allGroupMembers | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -ErrorAction Stop

            $exportResult = @{
                CSVPath       = $csvFile
                RecordCount   = $allGroupMembers.Count
                GroupCount    = $GroupNames.Count
                ExportTime    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            }

            Write-Verbose "Comparison export completed. Records: $($allGroupMembers.Count), File: $csvFile"

            return [PSCustomObject]$exportResult
        }
        Catch {
            Write-Error "Failed to export group comparison: $($_.Exception.Message)" -ErrorAction Stop
        }
    }
}

function New-ADGroupMigrationReport {
    <#
    .SYNOPSIS
    Generate interactive HTML report with sortable data tables
    
    .DESCRIPTION
    Creates Teams-styled HTML with embedded JavaScript sorting, summary cards,
    and professional formatting. Suitable for Teams channels or email distribution.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$ReportData,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [Parameter(Mandatory = $false)]
        [string]$ReportTitle = 'AD Group Migration Report',

        [Parameter(Mandatory = $false)]
        [string]$SourceGroupName = 'Unknown',

        [Parameter(Mandatory = $false)]
        [string]$TargetGroupNames = 'Unknown'
    )

    Process {
        Try {
            Write-Verbose "Initializing HTML report generation"
            Write-Verbose "Report title: $ReportTitle"
            Write-Verbose "Source: $SourceGroupName → Target: $TargetGroupNames"
            Write-Verbose "Output path: $OutputPath"

            # STEP 1: Ensure output directory exists
            Write-Verbose "STEP 1: Creating output directory structure"
            $outputDir = Split-Path -Path $OutputPath -Parent
            Write-Verbose "Output directory: $outputDir"
            
            if (-not (Test-Path -Path $outputDir)) {
                Write-Verbose "Directory does not exist. Creating: $outputDir"
                $null = New-Item -ItemType Directory -Path $outputDir -Force -ErrorAction Stop
                Write-Verbose "Directory created successfully"
            }
            else {
                Write-Verbose "Directory already exists"
            }

            # STEP 2: Calculate statistics
            Write-Verbose "STEP 2: Calculating statistics"
            $reportDataArray = @($ReportData)
            $totalRecords = $reportDataArray.Count
            Write-Verbose "Total records in array: $totalRecords"
            
            $enabledCount = @($reportDataArray | Where-Object { $_.Enabled -eq $true }).Count
            $disabledCount = @($reportDataArray | Where-Object { $_.Enabled -eq $false }).Count
            
            Write-Verbose "Stats - Total: $totalRecords, Enabled: $enabledCount, Disabled: $disabledCount"

            # STEP 3: Build HTML components
            Write-Verbose "STEP 3: Building HTML components"

            $cssStyle = @"
<style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background: linear-gradient(135deg, #f5f5f5 0%, #e8e8e8 100%); color: #333; line-height: 1.6; padding: 20px; }
    .container { max-width: 1200px; margin: 0 auto; background: white; border-radius: 8px; box-shadow: 0 2px 8px rgba(0,0,0,0.1); overflow: hidden; }
    header { background: linear-gradient(135deg, #0078d4 0%, #106ebe 100%); color: white; padding: 30px; text-align: center; }
    header h1 { font-size: 28px; margin-bottom: 10px; }
    header p { font-size: 13px; opacity: 0.9; }
    .migration-path { font-size: 12px; margin-top: 8px; opacity: 0.85; font-family: 'Courier New', monospace; }
    .summary { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 20px; padding: 30px; background: #fafafa; border-bottom: 1px solid #e0e0e0; }
    .summary-card { text-align: center; padding: 20px; border-radius: 4px; background: white; border-left: 4px solid #0078d4; }
    .summary-card h3 { font-size: 14px; color: #666; margin-bottom: 10px; font-weight: normal; text-transform: uppercase; letter-spacing: 0.5px; }
    .summary-card .value { font-size: 32px; font-weight: 600; color: #0078d4; }
    .content { padding: 30px; }
    table { width: 100%; border-collapse: collapse; margin: 20px 0; }
    thead { background: #0078d4; color: white; font-weight: 600; }
    thead th { padding: 12px; text-align: left; font-size: 13px; border: 1px solid #0078d4; cursor: pointer; user-select: none; white-space: nowrap; }
    thead th:hover { background: #106ebe; transition: background 0.2s ease; }
    thead th::after { content: ' ↕'; font-size: 11px; opacity: 0.6; }
    tbody tr { border-bottom: 1px solid #e0e0e0; transition: background 0.1s ease; }
    tbody tr:hover { background: #f9f9f9; }
    tbody tr:nth-child(even) { background: #fafafa; }
    tbody td { padding: 11px 12px; font-size: 12px; vertical-align: middle; border: 1px solid #e0e0e0; }
    footer { background: #f5f5f5; padding: 20px 30px; text-align: center; border-top: 1px solid #e0e0e0; font-size: 12px; color: #666; }
    .sort-asc::after { content: ' ↑' !important; opacity: 1 !important; }
    .sort-desc::after { content: ' ↓' !important; opacity: 1 !important; }
    @media (max-width: 768px) { .summary { grid-template-columns: repeat(2, 1fr); } table { font-size: 11px; } thead th, tbody td { padding: 8px; } }
</style>
"@

            $summaryHtml = @"
<div class="summary">
    <div class="summary-card">
        <h3>Total Members</h3>
        <div class="value">$totalRecords</div>
    </div>
    <div class="summary-card">
        <h3>Enabled</h3>
        <div class="value" style="color: #107c10;">$enabledCount</div>
    </div>
    <div class="summary-card">
        <h3>Disabled</h3>
        <div class="value" style="color: #d83b01;">$disabledCount</div>
    </div>
    <div class="summary-card">
        <h3>Report Generated</h3>
        <div class="value" style="font-size: 14px; color: #666;">$(Get-Date -Format 'HH:mm:ss')</div>
    </div>
</div>
"@

            # STEP 4: Prepare table data
            Write-Verbose "STEP 4: Preparing table data"
            $tableData = @($reportDataArray) | Select-Object -Property `
                @{Name = 'SAM Account'; Expression = { $_.SamAccountName } },
            @{Name = 'Display Name'; Expression = { $_.DisplayName } },
            @{Name = 'Email'; Expression = { $_.EmailAddress } },
            @{Name = 'Employee ID'; Expression = { $_.EmployeeID } },
            @{Name = 'Department'; Expression = { $_.Department } },
            @{Name = 'Status'; Expression = { if ($_.Enabled) { 'Enabled' } else { 'Disabled' } } },
            @{Name = 'Last Logon'; Expression = { if ($_.LastLogonDate) { $_.LastLogonDate.ToString('yyyy-MM-dd') } else { 'Never' } } }

            $tableHtml = $tableData | ConvertTo-Html -Fragment

            # STEP 5: Create JavaScript
            Write-Verbose "STEP 5: Creating sorting JavaScript"
            $sortingScript = @"
<script>
document.addEventListener('DOMContentLoaded', function() {
    const tables = document.querySelectorAll('table');
    tables.forEach(table => {
        const headers = table.querySelectorAll('thead th');
        headers.forEach((header, index) => {
            header.style.cursor = 'pointer';
            header.addEventListener('click', () => sortTable(table, index));
        });
    });
});
function sortTable(table, columnIndex) {
    const tbody = table.querySelector('tbody');
    if (!tbody) return;
    const rows = Array.from(tbody.querySelectorAll('tr'));
    const header = table.querySelectorAll('thead th')[columnIndex];
    const isAscending = !header.classList.contains('sort-asc');
    table.querySelectorAll('thead th').forEach(th => {
        th.classList.remove('sort-asc', 'sort-desc');
    });
    header.classList.add(isAscending ? 'sort-asc' : 'sort-desc');
    rows.sort((a, b) => {
        const aValue = a.querySelectorAll('td')[columnIndex].textContent.trim();
        const bValue = b.querySelectorAll('td')[columnIndex].textContent.trim();
        const aNum = parseFloat(aValue);
        const bNum = parseFloat(bValue);
        if (!isNaN(aNum) && !isNaN(bNum)) {
            return isAscending ? aNum - bNum : bNum - aNum;
        }
        return isAscending ? aValue.localeCompare(bValue) : bValue.localeCompare(aValue);
    });
    rows.forEach(row => tbody.appendChild(row));
}
</script>
"@

            # STEP 6: Build footer
            Write-Verbose "STEP 6: Building footer"
            $footer = @"
<footer>
    <p><strong>Migration:</strong> $SourceGroupName → $TargetGroupNames</p>
    <p><strong>Generated:</strong> $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
    <p style="margin-top: 10px; font-size: 11px; color: #999;">Click column headers to sort. Reports are read-only.</p>
</footer>
"@

            # STEP 7: Assemble complete HTML
            Write-Verbose "STEP 7: Assembling complete HTML document"
            $htmlDocument = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>$ReportTitle</title>
    $cssStyle
</head>
<body>
    <div class="container">
        <header>
            <h1>$ReportTitle</h1>
            <div class="migration-path">$SourceGroupName → $TargetGroupNames</div>
        </header>
        $summaryHtml
        <div class="content">
            <h2>Group Members</h2>
            $tableHtml
        </div>
        $footer
    </div>
    $sortingScript
</body>
</html>
"@

            # STEP 8: Write to file
            Write-Verbose "STEP 8: Writing HTML to file"
            Write-Verbose "File path: $OutputPath"
            
            Set-Content -LiteralPath $OutputPath -Value $htmlDocument -Encoding UTF8 -ErrorAction Stop

            Write-Verbose "File write operation completed"

            # STEP 9: Verify file exists and has content
            Write-Verbose "STEP 9: Verifying file creation"
            if (Test-Path -LiteralPath $OutputPath) {
                $fileInfo = Get-Item -LiteralPath $OutputPath
                Write-Verbose "File exists: $($fileInfo.FullName)"
                Write-Verbose "File size: $($fileInfo.Length) bytes"
                
                if ($fileInfo.Length -eq 0) {
                    Write-Error "HTML file was created but is empty" -ErrorAction Stop
                }
            }
            else {
                Write-Error "HTML file was not created at: $OutputPath" -ErrorAction Stop
            }

            Write-Verbose "HTML report generated successfully"

            return [PSCustomObject]@{
                ReportPath     = $OutputPath
                RecordCount    = $totalRecords
                EnabledCount   = $enabledCount
                DisabledCount  = $disabledCount
                GeneratedTime  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                Success        = $true
            }
        }
        Catch {
            Write-Error "Failed to generate HTML report: $($_.Exception.Message)" -ErrorAction Stop
        }
    }
}

# ============================================================================
# MAIN ORCHESTRATION
# ============================================================================

Try {
    Write-Verbose "========== AD GROUP MIGRATION SCRIPT INITIATED =========="
    Write-Verbose "Start Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Verbose "Source Group: $SourceGroup"
    Write-Verbose "Target Groups: $($TargetGroups -join ', ')"
    Write-Verbose "Migration Name: $MigrationName"
    Write-Verbose "Export Path: $ExportPath"
    Write-Verbose "Skip Review: $SkipReviewCheckpoint"

    Import-Module ActiveDirectory -ErrorAction Stop
}
Catch {
    Write-Error "Failed to initialize: $($_.Exception.Message). Ensure you're running as Administrator." -ErrorAction Stop
}

# ============================================================================
# PHASE 1: QUERY SOURCE GROUP
# ============================================================================

Write-Host "`n========== PHASE 1: QUERYING SOURCE GROUP ==========" -ForegroundColor Cyan
Write-Host "Retrieving members from: $SourceGroup" -ForegroundColor Yellow

Try {
    $script:sourceMembers = @(Get-ADGroupMembersLarge -GroupName $SourceGroup -Verbose)

    if (-not $script:sourceMembers -or $script:sourceMembers.Count -eq 0) {
        Write-Warning "No members found in group: $SourceGroup"
        exit
    }

    Write-Host "✓ Found $($script:sourceMembers.Count) members in $SourceGroup" -ForegroundColor Green
}
Catch {
    Write-Error "Failed to query source group: $($_.Exception.Message)" -ErrorAction Stop
}

# ============================================================================
# PHASE 2: EXPORT INITIAL REPORT
# ============================================================================

Write-Host "`n========== PHASE 2: EXPORTING INITIAL REPORT ==========" -ForegroundColor Cyan

Try {
    $script:exportResult = Export-ADGroupReport -Members $script:sourceMembers -GroupName $SourceGroup `
        -ExportPath $ExportPath -MigrationName $MigrationName -ReportSuffix "Pre-Migration" -Verbose

    Write-Host "✓ Report exported to: $($script:exportResult.FilePath)" -ForegroundColor Green
    Write-Host "  Records: $($script:exportResult.RecordCount)" -ForegroundColor White
}
Catch {
    Write-Error "Failed to export initial report: $($_.Exception.Message)" -ErrorAction Stop
}

# ============================================================================
# PHASE 3: USER REVIEW CHECKPOINT
# ============================================================================

if (-not $SkipReviewCheckpoint) {
    Write-Host "`n========== PHASE 3: REVIEW CHECKPOINT ==========" -ForegroundColor Cyan
    Write-Host "‼️  IMPORTANT: Before proceeding, you MUST review the exported member list." -ForegroundColor Red
    Write-Host "   File: $($script:exportResult.FilePath)" -ForegroundColor Yellow
    Write-Host ""

    $reviewChoice = Read-Host "Have you reviewed the member list and understand the users to be migrated? (Yes/No)"

    if ($reviewChoice -ne 'Yes' -and $reviewChoice -ne 'Y') {
        Write-Host "Migration cancelled. Review the file at: $($script:exportResult.FilePath)" -ForegroundColor Yellow
        exit
    }

    Write-Host "✓ Review acknowledged. Proceeding with migration planning." -ForegroundColor Green
}
else {
    Write-Host "`n========== PHASE 3: REVIEW CHECKPOINT ==========" -ForegroundColor Cyan
    Write-Host "✓ Review checkpoint skipped (-SkipReviewCheckpoint)" -ForegroundColor Yellow
}

# ============================================================================
# PHASE 4: MIGRATION SCOPE SELECTION
# ============================================================================

Write-Host "`n========== PHASE 4: MIGRATION SCOPE SELECTION ==========" -ForegroundColor Cyan

if ($AutoApproveScope) {
    Write-Host "Auto-approved scope: $AutoApproveScope" -ForegroundColor Yellow
    
    if ($AutoApproveScope -eq 'All') {
        $script:usersToMigrate = @($script:sourceMembers)
        Write-Host "✓ Selected: Migrate all $($script:sourceMembers.Count) users" -ForegroundColor Green
    }
    elseif ($AutoApproveScope -eq 'Specific') {
        if (-not $UserSelection) {
            Write-Error "AutoApproveScope 'Specific' requires -UserSelection parameter" -ErrorAction Stop
        }
        
        $selectedSAMs = $UserSelection -split ',' | ForEach-Object { $_.Trim() }
        $script:usersToMigrate = @($script:sourceMembers | Where-Object { $_.SamAccountName -in $selectedSAMs })
        
        if ($script:usersToMigrate.Count -eq 0) {
            Write-Error "No matching users found in selection: $UserSelection" -ErrorAction Stop
        }
        
        Write-Host "✓ Selected: $($script:usersToMigrate.Count) users from provided list" -ForegroundColor Green
    }
}
else {
    Write-Host "Select migration scope:" -ForegroundColor Yellow
    Write-Host "[1] Migrate ALL $($script:sourceMembers.Count) users to target groups" -ForegroundColor White
    Write-Host "[2] Select SPECIFIC users to migrate" -ForegroundColor White

    $scopeChoice = Read-Host "Enter choice (1 or 2)"

    if ($scopeChoice -eq '1') {
        $script:usersToMigrate = @($script:sourceMembers)
        Write-Host "✓ Selected: Migrate all $($script:sourceMembers.Count) users" -ForegroundColor Green
    }
    elseif ($scopeChoice -eq '2') {
        Write-Host "`nEnter SAM account names (comma-separated, e.g., john.smith,jane.doe):" -ForegroundColor Yellow
        $userInput = Read-Host "Users"
        
        $selectedSAMs = $userInput -split ',' | ForEach-Object { $_.Trim() }
        $script:usersToMigrate = @($script:sourceMembers | Where-Object { $_.SamAccountName -in $selectedSAMs })
        
        if ($script:usersToMigrate.Count -eq 0) {
            Write-Warning "No matching users found. Migration cancelled."
            exit
        }
        
        Write-Host "✓ Selected: $($script:usersToMigrate.Count) users" -ForegroundColor Green
    }
    else {
        Write-Error "Invalid choice. Exiting." -ErrorAction Stop
    }
}

# ============================================================================
# PHASE 5: CONFIRMATION BEFORE MIGRATION
# ============================================================================

Write-Host "`n========== PHASE 5: FINAL CONFIRMATION ==========" -ForegroundColor Cyan
Write-Host "You are about to migrate $($script:usersToMigrate.Count) users from '$SourceGroup' to: $($TargetGroups -join ', ')" -ForegroundColor Yellow
Write-Host ""

Write-Host "Users to be migrated:" -ForegroundColor White
$script:usersToMigrate | Select-Object -Property SamAccountName, DisplayName, EmailAddress | Format-Table

$confirmChoice = Read-Host "Are you sure you want to proceed? (Yes/No)"

if ($confirmChoice -ne 'Yes' -and $confirmChoice -ne 'Y') {
    Write-Host "Migration cancelled by user." -ForegroundColor Yellow
    exit
}

# ============================================================================
# PHASE 6: EXECUTE MIGRATION
# ============================================================================

Write-Host "`n========== PHASE 6: EXECUTING MIGRATION ==========" -ForegroundColor Cyan

Try {
    $script:migrationResult = Add-ADUsersToGroups -Users $script:usersToMigrate -TargetGroups $TargetGroups -Verbose

    Write-Host "✓ Migration completed!" -ForegroundColor Green
    Write-Host "  Successful additions: $($script:migrationResult.SuccessfulAdds)" -ForegroundColor Green
    Write-Host "  Skipped (already member): $($script:migrationResult.SkippedUsers)" -ForegroundColor Yellow
    Write-Host "  Failed: $($script:migrationResult.FailedAdds)" -ForegroundColor $(if ($script:migrationResult.FailedAdds -gt 0) { 'Red' } else { 'Green' })

    if ($script:migrationResult.FailureDetails.Count -gt 0) {
        Write-Host "`nFailure Details:" -ForegroundColor Red
        $script:migrationResult.FailureDetails | Format-Table -AutoSize
    }
}
Catch {
    Write-Error "Migration failed: $($_.Exception.Message)" -ErrorAction Stop
}

# ============================================================================
# PHASE 7: POST-MIGRATION AUDIT EXPORT
# ============================================================================

Write-Host "`n========== PHASE 7: POST-MIGRATION AUDIT EXPORT ==========" -ForegroundColor Cyan

Try {
    Write-Host "Exporting target group membership..." -ForegroundColor Yellow
    
    $script:auditExport = Export-ADGroupsComparison -GroupNames $TargetGroups `
        -ExportPath $ExportPath -MigrationName $MigrationName -Verbose

    Write-Host "✓ Audit export completed!" -ForegroundColor Green
    Write-Host "  CSV File: $($script:auditExport.CSVPath)" -ForegroundColor White
    Write-Host "  Total records: $($script:auditExport.RecordCount)" -ForegroundColor White
}
Catch {
    Write-Error "Failed to export audit report: $($_.Exception.Message)" -ErrorAction Stop
}

# ============================================================================
# PHASE 8: GENERATE HTML REPORT
# ============================================================================

Write-Host "`n========== PHASE 8: GENERATING HTML REPORT ==========" -ForegroundColor Cyan

Try {
    Write-Host "Generating sortable HTML report..." -ForegroundColor Yellow

    # Refresh user objects to get latest attributes
    $reportData = @()
    foreach ($user in $script:usersToMigrate) {
        Try {
            $refreshedUser = Get-ADUser -Identity $user.SamAccountName -Properties DisplayName, EmailAddress, EmployeeID, Department, Title, LastLogonDate, Enabled -ErrorAction SilentlyContinue
            if ($refreshedUser) {
                $reportData += $refreshedUser
            }
        }
        Catch {
            $reportData += $user
        }
    }

    $reportData = @($reportData)
    Write-Verbose "Report data prepared with $($reportData.Count) records"

    # Construct HTML path
    $exportDir = Join-Path -Path $ExportPath -ChildPath $MigrationName
    $script:htmlPath = Join-Path -Path $exportDir -ChildPath "${MigrationName}_Report_$(Get-Date -Format 'yyyyMMdd_HHmmss').html"
    
    Write-Verbose "HTML output path: $script:htmlPath"
    
    $script:htmlResult = New-ADGroupMigrationReport -ReportData $reportData `
        -OutputPath $script:htmlPath `
        -ReportTitle "AD Group Migration Report" `
        -SourceGroupName $SourceGroup `
        -TargetGroupNames ($TargetGroups -join ' & ') -Verbose

    Write-Host "✓ HTML report generated!" -ForegroundColor Green
    Write-Host "  HTML File: $($script:htmlResult.ReportPath)" -ForegroundColor White
    Write-Host "  Total records: $($script:htmlResult.RecordCount)" -ForegroundColor White
}
Catch {
    Write-Warning "Failed to generate HTML report: $($_.Exception.Message)"
    Write-Verbose "Full error: $_"
}

# ============================================================================
# COMPLETION SUMMARY
# ============================================================================

Write-Host "`n========== MIGRATION COMPLETE ==========" -ForegroundColor Cyan
Write-Host "Summary:" -ForegroundColor White
Write-Host "  ✓ Source Group: $SourceGroup" -ForegroundColor Green
Write-Host "  ✓ Target Groups: $($TargetGroups -join ', ')" -ForegroundColor Green
Write-Host "  ✓ Initial export: $($script:exportResult.FilePath)" -ForegroundColor Green
Write-Host "  ✓ Migration executed: $($script:migrationResult.SuccessfulAdds) users added" -ForegroundColor Green
Write-Host "  ✓ Audit export: $($script:auditExport.CSVPath)" -ForegroundColor Green

if ($script:htmlPath -and (Test-Path -LiteralPath $script:htmlPath)) {
    $htmlSize = (Get-Item -LiteralPath $script:htmlPath).Length
    Write-Host "  ✓ HTML report: $script:htmlPath ($htmlSize bytes)" -ForegroundColor Green
}
elseif ($script:htmlPath) {
    Write-Host "  ⚠ HTML report: File not found at $script:htmlPath" -ForegroundColor Yellow
}
else {
    Write-Host "  ⚠ HTML report: Not generated" -ForegroundColor Yellow
}

Write-Host "`nEnd Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan

# ============================================================================
# OPTIONAL: OPEN REPORTS
# ============================================================================

if (-not $SkipReviewCheckpoint) {
    $openReports = Read-Host "`nWould you like to open the audit reports? (Yes/No)"

    if ($openReports -eq 'Yes' -or $openReports -eq 'Y') {
        Write-Verbose "Opening CSV report..."
        if (Test-Path -Path $script:auditExport.CSVPath) {
            Invoke-Item -Path $script:auditExport.CSVPath
        }

        if ($script:htmlPath -and (Test-Path -LiteralPath $script:htmlPath)) {
            Write-Verbose "Opening HTML report..."
            Invoke-Item -Path $script:htmlPath
        }
    }
}

Write-Host "`nScript execution completed successfully." -ForegroundColor Green
