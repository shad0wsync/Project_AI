#Requires -Version 5.1

<#
.SYNOPSIS
    Windows Credential and User Account Audit Tool.

.DESCRIPTION
    Comprehensive audit tool for investigating user accounts, stored credentials, and authentication
    events on Windows systems. Combines data from local SAM, registry, Credential Manager, and
    Security Event Logs into a unified report.

.NOTES
    Script:  WindowsCredentialAudit.ps1
    Author:  Jeff Davidson
    Version: 1.1.0
    Date:    2026-02-05

    Requires: PowerShell 5.1+, Administrator privileges recommended
    Dependencies: CredentialManager module (auto-installed on first run)

    Event IDs Used:
    - 4624: Successful logon
    - 4625: Failed logon attempt
    - 4740: Account locked out

.EXAMPLE
    .\WindowsCredentialAudit.ps1
    
    Run full audit on all users and credentials (press Enter at prompt).

.EXAMPLE
    .\WindowsCredentialAudit.ps1
    
    When prompted, enter "jsmith" to filter results for specific user.

.PARAMETER UserSearch
    Optional username filter. If omitted and Quiet is not set, prompts interactively. Case-insensitive regex match.

.PARAMETER EventLogDays
    Number of days of Security log events to include (default 7, max 365).

.PARAMETER Quiet
    Suppresses interactive prompts and informational messages.
#>

# ============================================================================
# PARAMETERS / CONFIGURATION
# ============================================================================

[CmdletBinding(SupportsShouldProcess = $false)]
param(
    [string]$UserSearch,
    [ValidateRange(1, 365)]
    [int]$EventLogDays = 7,
    [switch]$Quiet
)

# Event log time range (days to look back for authentication events)
$script:EventLogDays = $EventLogDays

# Local groups to search for service accounts
$script:ServiceAccountGroups = @("Administrators", "Users")

# System accounts to filter out from results
$script:SystemAccountFilter = "^(NT AUTHORITY|LOCAL|Window Manager|SYSTEM)$"

# Registry paths for application account discovery
$script:AppAccountRegistryPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon",
    "HKLM:\SYSTEM\CurrentControlSet\Services"
)

# ============================================================================
# FUNCTIONS
# ============================================================================

<#
.SYNOPSIS
    Retrieves and displays local user accounts from the SAM database.

.DESCRIPTION
    Queries the local Security Account Manager (SAM) to enumerate all local user accounts,
    showing their enabled status and description. Useful for identifying built-in and
    custom local accounts.

.PARAMETER userSearch
    Optional username or partial username to filter results. Case-insensitive regex match.

.EXAMPLE
    Get-LocalUserAccounts -userSearch "admin"
    Shows all local accounts matching "admin" (Administrator, admin, etc.)
#>
function Get-LocalUserAccounts {
    param($userSearch)
    
    Write-Host "`n=== Local User Accounts ==="
    Write-Host ("{0,-20} {1,-8} {2}" -f "Name", "Enabled", "Description")
    
    # Query local SAM database for all user accounts
    Get-LocalUser | Where-Object { 
        # Filter: if userSearch provided, match against username; otherwise show all
        -not $userSearch -or ($_.Name -match $userSearch) 
    } | ForEach-Object {
        Write-Host ("{0,-20} {1,-8} {2}" -f $_.Name, $_.Enabled, $_.Description)
    }
}

<#
.SYNOPSIS
    Retrieves domain user profiles and local group membership information.

.DESCRIPTION
    Queries the Windows registry ProfileList to find domain users who have logged on to
    this computer, then enumerates all local group memberships to show which domain users
    and groups have access. Essential for security audits and access reviews.

.PARAMETER userSearch
    Optional username or partial username to filter results. Matches against profile paths
    and group member names.

.EXAMPLE
    Get-DomainUserProfiles -userSearch "DOMAIN\"
    Shows all domain user profiles and group memberships from specified domain
#>
function Get-DomainUserProfiles {
    param($userSearch)
    
    Write-Host "`nDomain User Profiles (from registry):"
    
    # Query registry ProfileList for all user profiles on this system
    # Each user who logs on gets a profile entry with their SID and profile path
    Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*" | Where-Object {
        $_.ProfileImagePath -like "C:\Users\*"  # Filter to user profiles (exclude system profiles)
    } | ForEach-Object {
        if (-not $userSearch -or ($_.ProfileImagePath -match $userSearch)) {
            # PSChildName contains the user's SID
            Write-Host ("SID: {0} | Profile Path: {1}" -f $_.PSChildName, $_.ProfileImagePath)
        }
    }

    Write-Host "`nAll Local Group Members:"
    
    # Enumerate all local groups and their members (includes domain users/groups)
    Get-LocalGroup | ForEach-Object {
        $group = $_.Name
        Get-LocalGroupMember -Group $group -ErrorAction SilentlyContinue | ForEach-Object {
            if (-not $userSearch -or ($_.Name -match $userSearch)) {
                # ObjectClass: User (account) or Group (nested group)
                Write-Host ("Group: {0} | Name: {1} | Type: {2}" -f $group, $_.Name, $_.ObjectClass)
            }
        }
    }
}

<#
.SYNOPSIS
    Identifies service accounts (machine accounts) in local groups.

.DESCRIPTION
    Searches local Administrators and Users groups for service accounts, which typically
    end with a dollar sign ($). These accounts are often used by Windows services, domain
    computers, and managed service accounts (gMSA/sMSA).

.PARAMETER userSearch
    Optional filter to match specific service accounts.

.EXAMPLE
    Get-ServiceAccounts
    Shows all service accounts: NETWORK SERVICE, LOCAL SERVICE, WORKSTATION01$, etc.
#>
function Get-ServiceAccounts {
    param($userSearch)
    
    Write-Host "`n=== Service Accounts ==="
    
    # Check configured groups for service account enumeration
    $groups = $script:ServiceAccountGroups
    $localUsers = Get-LocalUser | Select-Object -ExpandProperty Name
    $serviceAccounts = @()
    
    # Service accounts typically end with $ (machine accounts, MSAs)
    foreach ($group in $groups) {
        $serviceAccounts += Get-LocalGroupMember -Group $group -ErrorAction SilentlyContinue |
            Where-Object { 
                $_.ObjectClass -eq "User" -and $_.Name -like "*$" 
            }
    }
    
    # Remove duplicates, filter out local users, normalize to uppercase for consistency
    $uniqueAccounts = $serviceAccounts | 
        Where-Object { $localUsers -notcontains $_.Name } | 
        Select-Object -ExpandProperty Name | 
        ForEach-Object { $_.ToUpper() } | 
        Sort-Object | 
        Get-Unique
    
    foreach ($account in $uniqueAccounts) {
        if (-not $userSearch -or ($account -match $userSearch.ToUpper())) {
            Write-Host ("{0,-25} {1}" -f $account, "Service")
        }
    }
}

<#
.SYNOPSIS
    Discovers application accounts configured in registry and services.

.DESCRIPTION
    Searches Windows registry (Winlogon and Services keys) to find accounts configured
    for service logon or application use. Identifies accounts that may not be visible
    through standard user enumeration but are configured for automated tasks.

.PARAMETER userSearch
    Optional filter to match specific application accounts.

.EXAMPLE
    Get-ApplicationAccounts
    Shows accounts configured for services: NT AUTHORITY\SYSTEM, DOMAIN\ServiceAccount, etc.
#>
function Get-ApplicationAccounts {
    param($userSearch)
    
    Write-Host "`n=== Application Accounts (Registry/Service Logon) ==="
    
    # Search registry paths for accounts configured in services
    $regPaths = $script:AppAccountRegistryPaths
    $localUsers = Get-LocalUser | Select-Object -ExpandProperty Name
    $accounts = @()
    
    foreach ($path in $regPaths) {
        Get-ChildItem $path -ErrorAction SilentlyContinue | ForEach-Object {
            # ObjectName property contains the service logon account
            $user = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).ObjectName
            if ($user -and ($localUsers -notcontains $user)) {
                $accounts += $user.ToUpper()
            }
        }
    }
    
    # Deduplicate and sort
    $uniqueAccounts = $accounts | Sort-Object | Get-Unique
    
    foreach ($account in $uniqueAccounts) {
        if (-not $userSearch -or ($account -match $userSearch.ToUpper())) {
            Write-Host ("{0,-25} {1}" -f $account, "App/Service")
        }
    }
}

<#
.SYNOPSIS
    Enumerates stored credentials from Windows Credential Manager.

.DESCRIPTION
    Retrieves all stored credentials from the current user's Windows Credential Manager vault.
    This includes generic credentials, domain passwords, web credentials, and certificate-based
    credentials. Identifies incomplete or corrupted credential entries.

.PARAMETER userSearch
    Optional filter to match specific usernames in stored credentials.

.NOTES
    - Requires CredentialManager PowerShell module (auto-installed if missing)
    - Only shows credentials for the current user context
    - Some credentials (certificates, tokens) may not have username/password properties

.EXAMPLE
    Show-CredentialManagerAccountsAndProperties -userSearch "rdp"
    Shows all Credential Manager entries containing "rdp" (RDP saved credentials)
#>
function Show-CredentialManagerAccountsAndProperties {
    param($userSearch)
    
    Write-Host "`n=== Credential Manager Accounts ==="
    Write-Host "===================================="
    
    # Check if CredentialManager module is installed
    if (-not (Get-Module -ListAvailable -Name CredentialManager)) {
        Write-Host "CredentialManager module not found. Attempting to install..."
        try { 
            Install-Module -Name CredentialManager -Scope CurrentUser -Force -ErrorAction Stop 
            Write-Host "CredentialManager module installed successfully." -ForegroundColor Green
        }
        catch { 
            Write-Host "CredentialManager module could not be installed." -ForegroundColor Yellow 
            Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Yellow
            return
        }
    }
    
    if (Get-Module -ListAvailable -Name CredentialManager) {
        Import-Module CredentialManager
        $warnings = @()
        $results = @()
        
        # Enumerate all stored credentials in Credential Manager
        foreach ($cred in Get-StoredCredential) {
            # Determine credential name (different property names across versions)
            $credName = $cred.Target
            if (-not $credName) {
                if ($cred.PSObject.Properties['TargetName']) { 
                    $credName = $cred.PSObject.Properties['TargetName'].Value 
                }
                elseif ($cred.ApplicationName) { 
                    $credName = $cred.ApplicationName 
                }
                else { 
                    $credName = "<No Credential Name>" 
                }
            }
            
            # Check for username and password properties
            $hasUser = $cred.PSObject.Properties['UserName'] -and $cred.UserName
            $hasPass = $cred.PSObject.Properties['Password'] -and $cred.Password
            
            # Determine credential status
            $issue = if (-not $hasUser -and -not $hasPass) { 
                "Missing username and password" 
            }
            elseif (-not $hasUser) { 
                "Missing username" 
            }
            elseif (-not $hasPass) { 
                "Missing password" 
            }
            else { 
                "Has username and password" 
            }
            
            # Collect warnings for incomplete credentials (certificate-based, tokens, etc.)
            if (-not $hasUser -or -not $hasPass) {
                $warnings += "WARNING: Unable to convert Credential object without username or password to PSCredential object"
            }
            
            # Filter by username if search specified, or show incomplete credentials
            if (-not $userSearch -or ($hasUser -and $cred.UserName -match $userSearch)) {
                $results += ("{0,-30} {1,-25} {2,-25} {3}" -f 
                    "Credential Name: $credName", 
                    "Username: $($cred.UserName)", 
                    "Type: Credential Manager", 
                    "Status: $issue")
            } 
            elseif (-not $hasUser -or -not $hasPass) {
                # Show incomplete credentials even without username match
                $results += ("{0,-30} {1,-25} {2,-25} {3}" -f 
                    "Credential Name: $credName", 
                    "Username: <none>", 
                    "Type: Credential Manager", 
                    "Status: $issue")
            }
        }
        
        # Display unique warnings first
        $warnings | Get-Unique | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
        
        # Display credential results
        $results | ForEach-Object { Write-Host $_ }
    } 
    else {
        Write-Host "CredentialManager module is not available." -ForegroundColor Yellow
    }
}

<#
.SYNOPSIS
    Retrieves successful logon events from the Security event log.

.DESCRIPTION
    Queries the Security log for Event ID 4624 (successful logon) from the last 7 days.
    Shows who logged on, from where, to this computer. Filters out system accounts
    (NT AUTHORITY, LOCAL, etc.) to focus on user accounts.

.PARAMETER userSearch
    Optional filter to match specific usernames in logon events.

.NOTES
    - Requires Security log read access (typically Administrator)
    - Default time range: Last 7 days (configurable via $script:EventLogDays)
    - Filters out system/service account logons

.EXAMPLE
    Get-LogonEvents -userSearch "DOMAIN\jsmith"
    Shows all successful logons for specified user
#>
function Get-LogonEvents {
    param($userSearch)
    
    Write-Host "`n=== Users Who Have Logged On (last $script:EventLogDays days) ==="
    $destination = $env:COMPUTERNAME
    Write-Host ("{0,-30} {1,-25} {2,-25} {3,-25}" -f "User", "Source", "Destination", "Timestamp")
    
    # Query Security log for Event ID 4624 (successful logon)
    Get-WinEvent -FilterHashtable @{
        LogName='Security';
        Id=4624;
        StartTime=(Get-Date).AddDays(-$script:EventLogDays)
    } -ErrorAction SilentlyContinue | ForEach-Object {
        $props = $_.Properties
        
        # Event ID 4624 property indexes:
        # [5] = TargetUserName (who logged on)
        # [6] = TargetDomainName (user's domain)
        # [18] = IpAddress or Workstation (source of logon)
        $user = $props[5].Value
        $domain = $props[6].Value
        $source = $props[18].Value
        $timestamp = $_.TimeCreated
        
        # Filter out system accounts and only show domain/user accounts
        if ($domain -and $user -and $domain -notmatch $script:SystemAccountFilter) {
            $fullUser = "$domain\$user"
            if (-not $userSearch -or ($fullUser -match $userSearch)) {
                Write-Host ("{0,-30} {1,-25} {2,-25} {3,-25}" -f $fullUser, $source, $destination, $timestamp)
            }
        }
    }
}

<#
.SYNOPSIS
    Retrieves failed logon events from the Security event log.

.DESCRIPTION
    Queries the Security log for Event ID 4625 (failed logon) from the last 7 days.
    Useful for identifying brute force attempts, misconfigured services, or user
    password issues. Shows who attempted to log on, from where, and when.

.PARAMETER userSearch
    Optional filter to match specific usernames in failed logon events.

.NOTES
    - Requires Security log read access (typically Administrator)
    - Default time range: Last 7 days (configurable via $script:EventLogDays)
    - Multiple failures may indicate account lockout or service misconfiguration

.EXAMPLE
    Get-FailedLogonEvents -userSearch "svc-"
    Shows failed logon attempts for service accounts
#>
function Get-FailedLogonEvents {
    param($userSearch)
    
    Write-Host "`n=== Users Who Have Failed Logon (last $script:EventLogDays days) ==="
    $destination = $env:COMPUTERNAME
    Write-Host ("{0,-30} {1,-25} {2,-25} {3,-25}" -f "User", "Source", "Destination", "Timestamp")
    
    # Query Security log for Event ID 4625 (failed logon)
    Get-WinEvent -FilterHashtable @{
        LogName='Security';
        Id=4625;
        StartTime=(Get-Date).AddDays(-$script:EventLogDays)
    } -ErrorAction SilentlyContinue | ForEach-Object {
        $props = $_.Properties
        
        # Event ID 4625 property indexes:
        # [5] = TargetUserName (who attempted logon)
        # [6] = TargetDomainName (user's domain)
        # [18] = IpAddress or Workstation (source of failed attempt)
        $user = $props[5].Value
        $domain = $props[6].Value
        $source = $props[18].Value
        $timestamp = $_.TimeCreated
        
        # Filter out system accounts
        if ($domain -and $user -and $domain -notmatch $script:SystemAccountFilter) {
            $fullUser = "$domain\$user"
            if (-not $userSearch -or ($fullUser -match $userSearch)) {
                Write-Host ("{0,-30} {1,-25} {2,-25} {3,-25}" -f $fullUser, $source, $destination, $timestamp)
            }
        }
    }
}

<#
.SYNOPSIS
    Retrieves account lockout events from the Security event log.

.DESCRIPTION
    Queries the Security log for Event ID 4740 (account locked out) from the last 7 days.
    Critical for troubleshooting user lockout issues and identifying the source computer
    or service causing the lockouts.

.PARAMETER userSearch
    Optional filter to match specific usernames in lockout events.

.NOTES
    - Requires Security log read access (typically Administrator)
    - Default time range: Last 7 days (configurable via $script:EventLogDays)
    - Common causes: Expired password in stored credential, misconfigured service,
      mobile device with old password, scheduled task with wrong credentials

.EXAMPLE
    Get-LockedOutUsers -userSearch "jsmith"
    Shows when and where jsmith's account was locked out
#>
function Get-LockedOutUsers {
    param($userSearch)
    
    Write-Host "`n=== Users Locked Out (last $script:EventLogDays days) ==="
    $destination = $env:COMPUTERNAME
    Write-Host ("{0,-30} {1,-25} {2,-25} {3,-25}" -f "User", "Source", "Destination", "Timestamp")
    
    # Query Security log for Event ID 4740 (account locked out)
    Get-WinEvent -FilterHashtable @{
        LogName='Security';
        Id=4740;
        StartTime=(Get-Date).AddDays(-$script:EventLogDays)
    } -ErrorAction SilentlyContinue | ForEach-Object {
        $props = $_.Properties
        
        # Event ID 4740 property indexes:
        # [0] = TargetUserName (who was locked out)
        # [1] = TargetDomainName (user's domain)
        # [2] = SubjectUserName or CallerComputerName (source that triggered lockout)
        $user = $props[0].Value
        $domain = $props[1].Value
        $source = $props[2].Value
        $timestamp = $_.TimeCreated
        
        if ($domain -and $user) {
            $fullUser = "$domain\$user"
            if (-not $userSearch -or ($fullUser -match $userSearch)) {
                Write-Host ("{0,-30} {1,-25} {2,-25} {3,-25}" -f $fullUser, $source, $destination, $timestamp)
            }
        }
    }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

<#
    Main script execution flow:
    1. Prompt for optional username filter
    2. Execute all audit functions in logical order
    3. Display results to console
#>

# Prompt for username search filter (optional) when not provided explicitly
if (-not $PSBoundParameters.ContainsKey('UserSearch') -and -not $Quiet) {
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "WindowsCredentialAudit v1.0" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""
    $UserSearch = Read-Host "Enter a username or part of a username to search for (leave blank for all users)"
}

# Normalize empty input to null for consistent filtering
if ([string]::IsNullOrWhiteSpace($UserSearch)) {
    $UserSearch = $null
    if (-not $Quiet) {
        Write-Host "Auditing all users and credentials..." -ForegroundColor Yellow
    }
} else {
    if (-not $Quiet) {
        Write-Host "Filtering results for: $UserSearch" -ForegroundColor Yellow
    }
}

# Execute audit functions in logical order
Get-LocalUserAccounts $UserSearch
Get-DomainUserProfiles $UserSearch
Get-ServiceAccounts $UserSearch
Get-ApplicationAccounts $UserSearch
Show-CredentialManagerAccountsAndProperties $UserSearch
Get-LogonEvents $UserSearch
Get-FailedLogonEvents $UserSearch
Get-LockedOutUsers $UserSearch

# Completion message
Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "Audit Complete" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
exit 0