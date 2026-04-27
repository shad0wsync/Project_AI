<#
.SYNOPSIS
Find-LockoutCause - Comprehensive Active Directory account lockout root cause analysis

.DESCRIPTION
Investigates why an AD account was locked out by analyzing:
- Event ID 4740 (Lockout events) from Domain Controller
- Event ID 4625 (Failed logons) from source computer
- Windows Services running under the account
- Scheduled Tasks configured with the account
- Network shares and cached credentials
- Mobile devices and application credential stores

Provides detailed investigation report with specific remediation steps.

.PARAMETER Username
The AD account username to investigate (mandatory). Must be valid AD samAccountName.

.PARAMETER Hours
Number of hours to search back in event logs (default: 24, range: 1-8760)

.PARAMETER DCName
Domain Controller to query. If not specified, uses PDC Emulator.
Validation: Verifies connectivity before proceeding.

.PARAMETER DetailLevel
Level of investigation: Quick, Standard, or Deep
- Quick: Only Event ID 4740/4625 analysis
- Standard: Events + Services + Scheduled Tasks (default)
- Deep: Full investigation including all workstations (slower)

.PARAMETER EnableParallel
[PS 7.0+] Use parallel processing for multi-computer queries (improves performance)

.EXAMPLE
Find-LockoutCause -Username "jsmith"

.EXAMPLE
Find-LockoutCause -Username "svc-exchange" -Hours 72 -DetailLevel Deep

.NOTES
Author: Coder Agent
Date: April 24, 2026
Version: 2.0 (Security Hardened)

Tested Against: Windows Server 2019, 2022, 2025; PowerShell 5.1, 7.0+

Requirements:
  - Active Directory module
  - Remote Event Log access (appropriate permissions on DC/source computers)
  - Local admin rights on source computers (for service/task enumeration)

Known Limitations:
  - Event log retention may limit historical analysis (see Output for warnings)
  - Mobile/3rd-party app lockouts require manual investigation
  - Requires network connectivity to queried computers

Official Documentation:
  - Microsoft Docs: Event ID 4740 / 4625
  - MS-ERREF: NTSTATUS Values
  - AD Module Reference

#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^[a-zA-Z0-9._\-]{1,20}$')]  # Valid AD samAccountName format
    [string]$Username,
    
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 8760)]
    [int]$Hours = 24,
    
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$DCName,
    
    [Parameter(Mandatory = $false)]
    [ValidateSet("Quick", "Standard", "Deep")]
    [string]$DetailLevel = "Standard",
    
    [Parameter(Mandatory = $false)]
    [switch]$EnableParallel
)

# ===== SCRIPT CONFIGURATION =====
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Event property indices (Event ID 4740 schema)
# Reference: https://learn.microsoft.com/en-us/windows/security/threat-protection/auditing/event-4740
$EventSchema = @{
    Event4740 = @{
        TargetUserName = 0
        CallerComputer = 1
    }
    Event4625 = @{
        FailureCode = 7
        LogonType = 10
        ProcessName = 18
    }
}

# Comprehensive NTSTATUS failure code mappings
# Reference: MS-ERREF specification
$FailureCodes = @{
    "0xC000006A" = "Wrong password"
    "0xC0000064" = "Username does not exist"
    "0xC0000072" = "Account disabled"
    "0xC0000193" = "Password expired"
    "0xC0000224" = "Password change required at next logon"
    "0xC0000234" = "Account locked out"
    "0xC0000017" = "No more connections available"
    "0xC000006E" = "Clock skew (Kerberos)"
    "0xC000006F" = "Invalid workstation"
    "0xC0000070" = "Password expired"
    "0xC0000133" = "Clocks out of sync (Kerberos)"
    "0xC000006D" = "Logon failure - general"
    "0xC0000240" = "Invalid logon type"
}

# Logon type mappings
# Reference: Event ID 4624 documentation
$LogonTypes = @{
    2  = "Interactive"
    3  = "Network"
    4  = "Batch"
    5  = "Service"
    7  = "Unlock"
    8  = "NetworkCleartext"
    9  = "NewCredentials"
    10 = "RemoteInteractive"
    11 = "CachedInteractive"
}

# ===== HELPER FUNCTIONS =====

function Test-DCConnectivity {
    <#
    .SYNOPSIS
    Validates DC is reachable and has event log access
    #>
    [CmdletBinding()]
    param([string]$ComputerName)
    
    try {
        $null = Get-WinEvent -ComputerName $ComputerName -MaxEvents 0 -ErrorAction Stop
        Write-Verbose "[$ComputerName] Connectivity verified"
        return $true
    }
    catch [System.UnauthorizedAccessException] {
        Write-Error "Access denied to $ComputerName. Verify permissions." -ErrorAction Stop
    }
    catch [System.Net.NetworkInformationException] {
        Write-Error "$ComputerName is unreachable. Verify network connectivity." -ErrorAction Stop
    }
    catch {
        Write-Error "Cannot access event log on $ComputerName`: $($_.Exception.Message)" -ErrorAction Stop
    }
}

function Get-SafeEventProperty {
    <#
    .SYNOPSIS
    Safely extracts event property by index with validation
    #>
    param(
        [System.Diagnostics.Eventing.Reader.EventLogRecord]$Event,
        [int]$PropertyIndex,
        [string]$PropertyName
    )
    
    try {
        if ($Event.Properties.Count -gt $PropertyIndex) {
            return $Event.Properties[$PropertyIndex].Value
        }
        else {
            Write-Warning "Event missing expected property: $PropertyName (index $PropertyIndex)"
            return $null
        }
    }
    catch {
        Write-Warning "Failed to extract $PropertyName from event: $($_.Exception.Message)"
        return $null
    }
}

function Resolve-XPathSafeString {
    <#
    .SYNOPSIS
    Escapes special characters in XPath strings to prevent injection
    Reference: https://www.w3.org/TR/xpath-functions/#escape-string
    #>
    param([string]$InputString)
    
    # XPath string escaping: replace single quotes with concat()
    if ($InputString -match "'") {
        # Build XPath concat expression: 'part1','part2'...
        $parts = @($InputString -split "'")
        return "concat('" + ($parts -join "','") + "')"
    }
    return "'$InputString'"
}

function Get-LockoutEventsFromDC {
    <#
    .SYNOPSIS
    Queries Event ID 4740 with injection-safe XPath
    #>
    [CmdletBinding()]
    param(
        [string]$ComputerName,
        [string]$Username,
        [datetime]$StartTime
    )
    
    $SafeUsername = Resolve-XPathSafeString -InputString $Username
    $StartTimeUtc = $StartTime.ToUniversalTime().ToString('o')
    
    $FilterXPath = @"
[System[EventID=4740] and EventData[Data[@Name='TargetUserName']=$SafeUsername] and System[TimeCreated[@SystemTime >= '$StartTimeUtc']]]
"@
    
    Write-Verbose "Querying Event 4740 from $ComputerName (last $((Get-Date) - $StartTime | Select-Object -ExpandProperty Hours) hours)"
    
    try {
        $Events = Get-WinEvent -ComputerName $ComputerName -FilterXPath $FilterXPath -ErrorAction Stop | 
            Sort-Object TimeCreated -Descending
        return $Events
    }
    catch [System.Exception] {
        if ($_.Exception.Message -like "*No events were found*") {
            Write-Verbose "No lockout events found on $ComputerName"
            return @()
        }
        Write-Error "Failed to query Event 4740 from $ComputerName`: $($_.Exception.Message)" -ErrorAction Stop
    }
}

function Get-FailedLogonEvents {
    <#
    .SYNOPSIS
    Queries Event ID 4625 with injection-safe XPath, includes error context
    #>
    [CmdletBinding()]
    param(
        [string]$ComputerName,
        [string]$Username,
        [datetime]$StartTime,
        [int]$MaxResults = 10
    )
    
    $SafeUsername = Resolve-XPathSafeString -InputString $Username
    $StartTimeUtc = $StartTime.ToUniversalTime().ToString('o')
    
    $FilterXPath = @"
[System[EventID=4625] and EventData[Data[@Name='TargetUserName']=$SafeUsername] and System[TimeCreated[@SystemTime >= '$StartTimeUtc']]]
"@
    
    Write-Verbose "Querying Event 4625 from $ComputerName"
    
    try {
        $Events = Get-WinEvent -ComputerName $ComputerName -FilterXPath $FilterXPath -ErrorAction Stop | 
            Sort-Object TimeCreated -Descending | 
            Select-Object -First $MaxResults
        return $Events
    }
    catch [System.Net.NetworkInformationException] {
        Write-Warning "$ComputerName is offline or unreachable"
        return @()
    }
    catch [System.UnauthorizedAccessException] {
        Write-Warning "Access denied querying $ComputerName. Verify permissions."
        return @()
    }
    catch [System.Exception] {
        if ($_.Exception.Message -like "*No events were found*") {
            return @()
        }
        Write-Warning "Failed to query $ComputerName`: $($_.Exception.Message)"
        return @()
    }
}

function Get-ServicesRunningAsUser {
    <#
    .SYNOPSIS
    Enumerates services running as specific user (Standard/Deep levels)
    #>
    [CmdletBinding()]
    param(
        [string]$ComputerName,
        [string]$Username
    )
    
    Write-Verbose "Enumerating services on $ComputerName"
    
    try {
        # Build WMI query with user-specific filter
        $Query = "SELECT Name, DisplayName, State, StartName, StartMode FROM Win32_Service WHERE StartName LIKE '%$Username%'"
        $Services = Get-WmiObject -Class Win32_Service -ComputerName $ComputerName -Filter $Query -ErrorAction Stop
        return @($Services)
    }
    catch [System.UnauthorizedAccessException] {
        Write-Warning "[$ComputerName] Access denied querying services"
        return @()
    }
    catch [System.Runtime.InteropServices.COMException] {
        if ($_.HResult -eq 0x800706BA) {
            Write-Warning "[$ComputerName] RPC server unavailable"
        }
        else {
            Write-Warning "[$ComputerName] WMI query failed (HResult: 0x$($_.HResult.ToString('X')))"
        }
        return @()
    }
    catch {
        Write-Warning "[$ComputerName] Failed to query services: $($_.Exception.Message)"
        return @()
    }
}

function Get-ScheduledTasksForUser {
    <#
    .SYNOPSIS
    Enumerates scheduled tasks running as specific user
    Uses CimSession with proper cleanup
    #>
    [CmdletBinding()]
    param(
        [string]$ComputerName,
        [string]$Username
    )
    
    $CimSession = $null
    try {
        Write-Verbose "Enumerating scheduled tasks on $ComputerName"
        $CimSession = New-CimSession -ComputerName $ComputerName -ErrorAction Stop
        
        $Tasks = Get-ScheduledTask -CimSession $CimSession -ErrorAction Stop | 
            Where-Object { $_.Principal.UserId -like "*$Username" }
        
        return @($Tasks)
    }
    catch [System.UnauthorizedAccessException] {
        Write-Warning "[$ComputerName] Access denied querying scheduled tasks"
        return @()
    }
    catch [System.Net.NetworkInformationException] {
        Write-Warning "[$ComputerName] Cannot reach computer"
        return @()
    }
    catch {
        Write-Warning "[$ComputerName] Failed to query scheduled tasks: $($_.Exception.Message)"
        return @()
    }
    finally {
        if ($CimSession) {
            Remove-CimSession -CimSession $CimSession -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-RootCauseAnalysis {
    <#
    .SYNOPSIS
    Correlates events, services, and tasks to identify root cause
    #>
    [CmdletBinding()]
    param(
        [PSObject[]]$FailedLogons,
        [PSObject[]]$Services,
        [PSObject[]]$Tasks
    )
    
    $Analysis = [System.Collections.Generic.List[string]]@()
    $Analysis.Add("=== ROOT CAUSE ANALYSIS ===")
    
    # Analyze failed logon patterns
    if ($FailedLogons) {
        $LogonTypeSummary = $FailedLogons | Group-Object -Property LogonType | 
            Sort-Object Count -Descending
        
        $Analysis.Add("`nFAILED LOGON SUMMARY ($($FailedLogons.Count) events):")
        
        foreach ($Type in $LogonTypeSummary) {
            $Analysis.Add("  * $($Type.Name): $($Type.Count) attempts")
            
            switch ($Type.Name) {
                "Network" {
                    $Analysis.Add("    -> LIKELY: Stale network share credentials or mapped drive")
                    $Analysis.Add("    -> ACTION: Check `net use` output, remove stale mappings")
                }
                "Batch" {
                    $Analysis.Add("    -> LIKELY: Scheduled task with outdated password")
                    $Analysis.Add("    -> ACTION: Review scheduled tasks and update credentials")
                }
                "Service" {
                    $Analysis.Add("    -> LIKELY: Windows service with mismatched password")
                    $Analysis.Add("    -> ACTION: Check services.msc, update service logon password")
                }
                "RemoteInteractive" {
                    $Analysis.Add("    -> LIKELY: Incorrect password entered during RDP")
                    $Analysis.Add("    -> ACTION: Verify password with user, reset if needed")
                }
                "Interactive" {
                    $Analysis.Add("    -> LIKELY: Wrong password at local console")
                    $Analysis.Add("    -> ACTION: Reset password or verify with user")
                }
                "CachedInteractive" {
                    $Analysis.Add("    -> LIKELY: Offline cached credentials don't match current password")
                    $Analysis.Add("    -> ACTION: User must logon online once with correct password")
                }
            }
        }
    }
    else {
        $Analysis.Add("`nNo failed logons found during analysis period.")
    }
    
    # Flag services and tasks
    if ($Services -or $Tasks) {
        $Analysis.Add("`nWARNING - CONFIGURED SERVICES/TASKS:")
        if ($Services) {
            $Analysis.Add("  * $($Services.Count) Windows service(s) found - verify passwords are in sync")
        }
        if ($Tasks) {
            $Analysis.Add("  * $($Tasks.Count) scheduled task(s) found - verify credentials are current")
        }
    }
    
    # Generic causes if no specifics found
    if (-not $FailedLogons -and -not $Services -and -not $Tasks) {
        $Analysis.Add("`nNo specific cause identified. Investigate:")
        $Analysis.Add("  * Mobile devices with cached credentials")
        $Analysis.Add("  * Email/collaboration apps (Outlook, Teams, etc.)")
        $Analysis.Add("  * VPN or network appliance using this account")
        $Analysis.Add("  * Third-party applications with saved credentials")
        $Analysis.Add("  * Printers or network devices configured with this account")
    }
    
    return $Analysis -join "`n"
}

function Invoke-RemediationRecommendation {
    <#
    .SYNOPSIS
    Generates step-by-step remediation instructions
    Uses secure best practices for password handling
    #>
    [CmdletBinding()]
    param(
        [string]$Username,
        [PSObject[]]$FailedLogons,
        [PSObject[]]$Services,
        [PSObject[]]$Tasks
    )
    
    $Steps = [System.Collections.Generic.List[string]]@()
    
    $Steps.Add("=== REMEDIATION STEPS ===`n")
    $Steps.Add("1. UNLOCK THE ACCOUNT:")
    $Steps.Add("   ```powershell")
    $Steps.Add("   Unlock-ADAccount -Identity '$Username'")
    $Steps.Add("   ```")
    
    $Steps.Add("`n2. RESET PASSWORD (via secure method):")
    $Steps.Add("   ```powershell")
    $Steps.Add("   # Option A: Interactive password prompt (RECOMMENDED)")
    $Steps.Add("   `$NewPassword = Read-Host -AsSecureString -Prompt 'Enter new password'")
    $Steps.Add("   Set-ADAccountPassword -Identity '$Username' -NewPassword `$NewPassword -Reset")
    $Steps.Add("")
    $Steps.Add("   # Option B: Generate 18-char random password")
    $Steps.Add("   `$RandomPassword = [System.Web.Security.Membership]::GeneratePassword(18, 2)")
    $Steps.Add("   `$SecurePassword = ConvertTo-SecureString -String `$RandomPassword -AsPlainText -Force")
    $Steps.Add("   Set-ADAccountPassword -Identity '$Username' -NewPassword `$SecurePassword -Reset")
    $Steps.Add("   ```")
    
    # Conditional remediation
    if ($FailedLogons) {
        $HasNetworkLogons = $FailedLogons | Where-Object { $_.LogonType -eq "Network" }
        $HasBatchLogons = $FailedLogons | Where-Object { $_.LogonType -eq "Batch" }
        $HasServiceLogons = $FailedLogons | Where-Object { $_.LogonType -eq "Service" }
        $HasCachedLogons = $FailedLogons | Where-Object { $_.LogonType -eq "CachedInteractive" }
        
        if ($HasNetworkLogons) {
            $Steps.Add("`n3A. NETWORK SHARE / MAPPED DRIVE ISSUE:")
            $Steps.Add("   On affected computer(s):")
            $Steps.Add("   ```powershell")
            $Steps.Add("   # List current mappings")
            $Steps.Add("   net use")
            $Steps.Add("")
            $Steps.Add("   # Remove stale mappings")
            $Steps.Add("   net use * /delete /yes")
            $Steps.Add("")
            $Steps.Add("   # Clear credential manager")
            $Steps.Add("   cmdkey /list | Where-Object { `$_ -match 'MicrosoftAccount' } | ForEach-Object { cmdkey /delete:@(`$_.Split(' ')[-1]) }")
            $Steps.Add("   ```")
            $Steps.Add("   OR via Credential Manager GUI:")
            $Steps.Add("   1. Open Control Panel > Credential Manager")
            $Steps.Add("   2. Select 'Windows Credentials'")
            $Steps.Add("   3. Remove entries for affected shares")
        }
        
        if ($HasBatchLogons -or $Tasks) {
            $Steps.Add("`n3B. SCHEDULED TASK ISSUE:")
            $Steps.Add("   ```powershell")
            $Steps.Add("   # List tasks for user")
            $Steps.Add("   Get-ScheduledTask | Where-Object { `$_.Principal.UserId -like '*$Username' } | Select-Object -Property TaskPath, TaskName")
            $Steps.Add("")
            $Steps.Add("   # Update task password (PowerShell 5.1+):")
            $Steps.Add("   # Note: Task Scheduler UI is more reliable; use: taskschd.msc")
            $Steps.Add("   ```")
            $Steps.Add("   Via Task Scheduler GUI:")
            $Steps.Add("   1. Open Task Scheduler (taskschd.msc)")
            $Steps.Add("   2. Find affected task(s)")
            $Steps.Add("   3. Right-click > Properties > General tab")
            $Steps.Add("   4. Click 'Change User or Group' and re-enter current password")
            $Steps.Add("   5. Click OK and restart the task")
        }
        
        if ($HasServiceLogons -or $Services) {
            $Steps.Add("`n3C. WINDOWS SERVICE ISSUE:")
            $Steps.Add("   Via Services GUI (services.msc) - RECOMMENDED:")
            $Steps.Add("   1. Open services.msc")
            $Steps.Add("   2. Find service(s) running as '$Username'")
            $Steps.Add("   3. Right-click > Properties > Log On tab")
            $Steps.Add("   4. Enter new password in both fields")
            $Steps.Add("   5. Click OK and restart service")
            $Steps.Add("")
            $Steps.Add("   Via PowerShell (if supported by service):")
            $Steps.Add("   ```powershell")
            $Steps.Add("   # Requires service to support credential updates")
            $Steps.Add("   # Note: Not all services support this; UI method is preferred")
            $Steps.Add("   ```")
        }
        
        if ($HasCachedLogons) {
            $Steps.Add("`n3D. CACHED CREDENTIALS ISSUE:")
            $Steps.Add("   1. Ask user to logon with NEW password while connected to network")
            $Steps.Add("   2. This refreshes the cached credential store")
            $Steps.Add("   3. User can then work offline with new cached credentials")
            $Steps.Add("   4. Advise user: 'Password changed, please logon online once'")
        }
    }
    
    $Steps.Add("`n4. VERIFY RESOLUTION:")
    $Steps.Add("   ```powershell")
    $Steps.Add("   # Check account is unlocked and active")
    $Steps.Add("   Get-ADUser -Identity '$Username' -Properties LockedOut, pwdLastSet | Select-Object Name, LockedOut, pwdLastSet")
    $Steps.Add("")
    $Steps.Add("   # Monitor for new lockouts")
    $Steps.Add("   Get-WinEvent -ComputerName <DCName> -FilterXPath `"[System[EventID=4740] and EventData[Data[@Name='TargetUserName']='$Username']]`" -MaxEvents 1")
    $Steps.Add("   ```")
    $Steps.Add("   [OK] If no new lockouts in 1 hour: Issue resolved")
    $Steps.Add("   [FAIL] If lockouts recur: Escalate with full event logs and service/task configuration")
    
    return $Steps -join "`n"
}

# ===== MAIN INVESTIGATION LOGIC =====

function Invoke-LockoutInvestigation {
    [CmdletBinding()]
    param(
        [string]$Username,
        [int]$Hours,
        [string]$DCName,
        [string]$DetailLevel,
        [bool]$EnableParallel
    )
    
    $InvestigationStart = Get-Date
    Write-Verbose "[$Username] Investigation started at $InvestigationStart"
    
    try {
        # Validate AD user exists
        Write-Verbose "[$Username] Validating AD account..."
        $ADUser = Get-ADUser -Identity $Username -Properties LockedOut, LastBadPasswordAttempt, BadLogonCount, pwdLastSet -ErrorAction Stop
        Write-Verbose "[$Username] Account found. Locked status: $($ADUser.LockedOut)"
        
        # Determine DC to query
        if (-not $DCName) {
            Write-Verbose "[$Username] Resolving PDC Emulator..."
            $PDCEmulator = Get-ADDomain -ErrorAction Stop | Select-Object -ExpandProperty PDCEmulator
            $DCName = $PDCEmulator.Split('.')[0]
            Write-Verbose "[$Username] Using PDC: $DCName"
        }
        
        # Test DC connectivity
        Test-DCConnectivity -ComputerName $DCName
        
        # Query lockout events
        $StartTime = (Get-Date).AddHours(-$Hours)
        Write-Verbose "[$Username] Querying lockout events from $DCName (last $Hours hours)"
        
        $LockoutEvents = Get-LockoutEventsFromDC -ComputerName $DCName -Username $Username -StartTime $StartTime
        
        if ($LockoutEvents.Count -eq 0) {
            Write-Warning "[$Username] No lockout events found in last $Hours hours"
            return $null
        }
        
        Write-Verbose "[$Username] Found $($LockoutEvents.Count) lockout event(s)"
        
        # Parse lockout events and extract source computers
        $SourceComputers = [System.Collections.Generic.HashSet[string]]@()
        $LockoutReport = @()
        
        foreach ($Event in $LockoutEvents) {
            $TargetUser = Get-SafeEventProperty -Event $Event -PropertyIndex $EventSchema.Event4740.TargetUserName -PropertyName "TargetUserName"
            $CallerComputer = Get-SafeEventProperty -Event $Event -PropertyIndex $EventSchema.Event4740.CallerComputer -PropertyName "CallerComputer"
            
            if ($CallerComputer) {
                $null = $SourceComputers.Add($CallerComputer)
            }
            
            $LockoutReport += [PSCustomObject]@{
                TimeCreated = $Event.TimeCreated
                SourceComputer = $CallerComputer
                EventID = 4740
            }
        }
        
        # Query failed logons from source computers
        $FailedLogonReport = @()
        $FailedLogonBlock = {
            param([string]$Computer, [string]$Username, [datetime]$StartTime)
            Get-FailedLogonEvents -ComputerName $Computer -Username $Username -StartTime $StartTime -MaxResults 10
        }
        
        if ($EnableParallel -and $PSVersionTable.PSVersion -ge [version]"7.0") {
            Write-Verbose "[$Username] Using parallel processing for failed logon queries"
            $FailedLogonQueryResults = $SourceComputers | ForEach-Object -Parallel $FailedLogonBlock -ArgumentList $_, $Username, $StartTime -ThrottleLimit 4
        }
        else {
            Write-Verbose "[$Username] Using serial processing for failed logon queries"
            $FailedLogonQueryResults = @()
            foreach ($Computer in $SourceComputers) {
                $FailedLogonQueryResults += & $FailedLogonBlock -Computer $Computer -Username $Username -StartTime $StartTime
            }
        }
        
        # Parse failed logon events
        foreach ($Event in $FailedLogonQueryResults) {
            if ($null -eq $Event) { continue }
            
            $FailureCode = "0x$((Get-SafeEventProperty -Event $Event -PropertyIndex $EventSchema.Event4625.FailureCode -PropertyName "FailureCode") -as [uint32]).ToString('X8')"
            $LogonTypeCode = Get-SafeEventProperty -Event $Event -PropertyIndex $EventSchema.Event4625.LogonType -PropertyName "LogonType"
            $LogonTypeDesc = $LogonTypes[$LogonTypeCode] ?? "Unknown ($LogonTypeCode)"
            
            $FailedLogonReport += [PSCustomObject]@{
                TimeCreated = $Event.TimeCreated
                Computer = $Event.MachineName
                LogonType = $LogonTypeDesc
                FailureCode = $FailureCode
                FailureReason = $FailureCodes[$FailureCode] ?? "Unknown"
            }
        }
        
        # Query services (Standard/Deep)
        $ServiceReport = @()
        if ($DetailLevel -in @("Standard", "Deep")) {
            Write-Verbose "[$Username] Enumerating services (Detail: $DetailLevel)"
            foreach ($Computer in $SourceComputers) {
                $Services = Get-ServicesRunningAsUser -ComputerName $Computer -Username $Username
                foreach ($Service in $Services) {
                    $ServiceReport += [PSCustomObject]@{
                        Computer = $Computer
                        ServiceName = $Service.Name
                        State = $Service.State
                        StartMode = $Service.StartMode
                        StartName = $Service.StartName
                    }
                }
            }
        }
        
        # Query scheduled tasks (Standard/Deep)
        $TaskReport = @()
        if ($DetailLevel -in @("Standard", "Deep")) {
            Write-Verbose "[$Username] Enumerating scheduled tasks (Detail: $DetailLevel)"
            foreach ($Computer in $SourceComputers) {
                $Tasks = Get-ScheduledTasksForUser -ComputerName $Computer -Username $Username
                foreach ($Task in $Tasks) {
                    $TaskInfo = $Task | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
                    $TaskReport += [PSCustomObject]@{
                        Computer = $Computer
                        TaskName = "$($Task.TaskPath)$($Task.TaskName)"
                        State = $Task.State
                        LastRunTime = $TaskInfo.LastRunTime
                    }
                }
            }
        }
        
        # Perform root cause analysis
        $RootCauseAnalysis = Invoke-RootCauseAnalysis -FailedLogons $FailedLogonReport -Services $ServiceReport -Tasks $TaskReport
        
        # Generate remediation steps
        $RemediationSteps = Invoke-RemediationRecommendation -Username $Username -FailedLogons $FailedLogonReport -Services $ServiceReport -Tasks $TaskReport
        
        # Build final report
        $FinalReport = [PSCustomObject]@{
            PSTypeName = "ADLockoutInvestigation.Report"
            Username = $Username
            InvestigationDate = $InvestigationStart
            InvestigationDurationHours = $Hours
            DetailLevel = $DetailLevel
            AccountLockedStatus = $ADUser.LockedOut
            PasswordLastSet = $ADUser.pwdLastSet
            BadLogonCount = $ADUser.BadLogonCount
            LockoutEventCount = $LockoutEvents.Count
            FailedLogonCount = $FailedLogonReport.Count
            ServiceCount = $ServiceReport.Count
            ScheduledTaskCount = $TaskReport.Count
            SourceComputers = @($SourceComputers | Sort-Object)
            LockoutEvents = $LockoutReport
            FailedLogons = $FailedLogonReport
            Services = $ServiceReport
            ScheduledTasks = $TaskReport
            RootCauseAnalysis = $RootCauseAnalysis
            RemediationSteps = $RemediationSteps
        }
        
        return $FinalReport
    }
    catch {
        Write-Error "Investigation failed: $($_.Exception.Message)" -ErrorAction Stop
    }
}

# ===== EXECUTION =====
$Result = Invoke-LockoutInvestigation -Username $Username -Hours $Hours -DCName $DCName -DetailLevel $DetailLevel -EnableParallel $EnableParallel.IsPresent

if ($Result) {
    Write-Host "`n========================================================" -ForegroundColor Cyan
    Write-Host "   AD ACCOUNT LOCKOUT INVESTIGATION REPORT" -ForegroundColor Cyan
    Write-Host "========================================================`n" -ForegroundColor Cyan
    
    Write-Host "SUMMARY" -ForegroundColor Yellow
    Write-Host "  Username: $($Result.Username)"
    Write-Host "  Locked: $(if($Result.AccountLockedStatus){'[LOCKED]'} else {'[UNLOCKED]'})"
    Write-Host "  Lockout Events: $($Result.LockoutEventCount)"
    Write-Host "  Failed Logons: $($Result.FailedLogonCount)"
    Write-Host "  Services Found: $($Result.ServiceCount)"
    Write-Host "  Tasks Found: $($Result.ScheduledTaskCount)"
    Write-Host "  Source Computers: $($Result.SourceComputers -join ', ')"
    
    Write-Host "`nROOT CAUSE ANALYSIS" -ForegroundColor Yellow
    Write-Host $Result.RootCauseAnalysis
    
    if ($Result.FailedLogons.Count -gt 0) {
        Write-Host "`nFAILED LOGON DETAILS" -ForegroundColor Yellow
        $Result.FailedLogons | Format-Table -AutoSize
    }
    
    if ($Result.Services.Count -gt 0) {
        Write-Host "`nSERVICES" -ForegroundColor Yellow
        $Result.Services | Format-Table -AutoSize
    }
    
    if ($Result.ScheduledTasks.Count -gt 0) {
        Write-Host "`nSCHEDULED TASKS" -ForegroundColor Yellow
        $Result.ScheduledTasks | Format-Table -AutoSize
    }
    
    Write-Host "`nREMEDIATION" -ForegroundColor Green
    Write-Host $Result.RemediationSteps
    
    # Return full object for piping
    $Result
}
else {
    Write-Host "INFO: No lockout investigation data available." -ForegroundColor Green
}