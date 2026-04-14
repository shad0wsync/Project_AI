#Requires -Version 5.1
<#
.SYNOPSIS
    Performs comprehensive PC health checks and generates remediation recommendations.

.DESCRIPTION
    This script runs diagnostic checks across multiple system categories:
    - System File Integrity (SFC, DISM)
    - Disk Health (SMART, space, fragmentation)
    - Event Log Analysis (critical errors, crashes)
    - Windows Update Health
    - Performance Metrics
    - Startup Impact
    - Network Health
    - Cleanup Opportunities
    - Pending Restart Detection

    Generates an HTML report with findings and remediation commands.
    Does NOT automatically repair - provides commands for manual execution.
    Requires: PowerShell 5.1+ (compatible with PS 7)
    Recommendation: Run as Administrator for full functionality

.PARAMETER Mode
    Execution mode: Quick (2-5 min), Standard (10-15 min), Full (30-60 min), or Custom.

.PARAMETER Categories
    Specific categories to run when using Custom mode.
    Valid values: SystemFiles, Disk, EventLog, WindowsUpdate, Performance, Startup, Network, Cleanup, Security, Drivers

.PARAMETER OutputPath
    Path to save the HTML report. Defaults to current directory.

.PARAMETER LogPath
    Path for detailed log file output.

.PARAMETER Quiet
    Suppress console output.

.PARAMETER ExportCsv
    Export findings to CSV file for SIEM/reporting integration.

.PARAMETER DaysBack
    Number of days to look back for event log analysis. Default: 7

.EXAMPLE
    .\PCHealthCheck.ps1 -Mode Quick
    
    Runs quick health checks (disk space, recent errors, basic status).

.EXAMPLE
    .\PCHealthCheck.ps1 -Mode Standard -OutputPath "C:\Reports"
    
    Runs standard checks and saves HTML report to C:\Reports.

.EXAMPLE
    .\PCHealthCheck.ps1 -Mode Full
    
    Runs comprehensive checks including SFC and DISM scans.

.EXAMPLE
    .\PCHealthCheck.ps1 -Mode Custom -Categories SystemFiles, Disk, Cleanup
    
    Runs only specified categories.

.EXAMPLE
    .\PCHealthCheck.ps1 -Mode Standard -ExportCsv
    
    Runs standard checks and exports findings to CSV for SIEM integration.

.EXAMPLE
    .\PCHealthCheck.ps1 -Mode Standard -ExportJson
    
    Runs standard checks and exports findings to JSON for API/automation integration.

.EXAMPLE
    .\PCHealthCheck.ps1 -Mode Full -Exclude SystemFiles
    
    Runs full checks but skips SFC and DISM scans (SystemFiles category).

.EXAMPLE
    .\PCHealthCheck.ps1 -Mode Standard -Exclude Cleanup, Drivers
    
    Runs standard checks but excludes Cleanup and Drivers categories.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet("Quick", "Standard", "Full", "Custom")]
    [string]$Mode = "Standard",

    [Parameter()]
    [ValidateSet("SystemFiles", "Disk", "EventLog", "WindowsUpdate", "Performance", "Startup", "Network", "Cleanup", "Security", "Drivers")]
    [string[]]$Categories,

    [Parameter()]
    [ValidateSet("SystemFiles", "Disk", "EventLog", "WindowsUpdate", "Performance", "Startup", "Network", "Cleanup", "Security", "Drivers")]
    [string[]]$Exclude,

    [Parameter()]
    [string]$OutputPath = "C:\Temp\PCHealthCheck",

    [Parameter()]
    [string]$LogPath = "C:\Temp\PCHealthCheck\Logs",

    [Parameter()]
    [switch]$Quiet,

    [Parameter()]
    [switch]$ExportCsv,

    [Parameter()]
    [switch]$ExportJson,

    [Parameter()]
    [int]$DaysBack = 7
)

#region --- INITIALIZATION ---
$script:StartTime = Get-Date
$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$script:IsServer = (Get-CimInstance -ClassName Win32_OperatingSystem).ProductType -ne 1
$script:Results = @{}
$script:RemediationCommands = @()

# Ensure output directory exists
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

# Admin check
if (-not $script:IsAdmin) {
    Write-Warning "Running without Administrator privileges. Some checks may be limited or skipped."
    Write-Warning "For full functionality, run PowerShell as Administrator."
}

# Determine which categories to run based on mode
$script:CategoriesToRun = switch ($Mode) {
    "Quick" { @("Disk", "EventLog", "WindowsUpdate", "Cleanup") }
    "Standard" { @("SystemFiles", "Disk", "EventLog", "WindowsUpdate", "Performance", "Startup", "Cleanup", "Drivers") }
    "Full" { @("SystemFiles", "Disk", "EventLog", "WindowsUpdate", "Performance", "Startup", "Network", "Cleanup", "Security", "Drivers") }
    "Custom" { 
        if (-not $Categories) {
            Write-Error "Custom mode requires -Categories parameter"
            exit 1
        }
        $Categories 
    }
}

# Apply exclusions if specified
if ($Exclude -and $Exclude.Count -gt 0) {
    $script:CategoriesToRun = $script:CategoriesToRun | Where-Object { $_ -notin $Exclude }
    
    if ($script:CategoriesToRun.Count -eq 0) {
        Write-Error "All categories have been excluded. Nothing to run."
        exit 1
    }
}
#endregion

#region --- LOGGING ---
$script:LogFile = $null
if ($LogPath) {
    if (-not (Test-Path $LogPath)) {
        New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
    }
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:LogFile = Join-Path $LogPath ("PCHealthCheck-$env:COMPUTERNAME-$timestamp.log")
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "OK", "WARN", "ERROR", "SECTION")]
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] [$Level] $Message"
    
    if ($script:LogFile) {
        $logLine | Out-File -FilePath $script:LogFile -Append -Encoding UTF8
    }
    
    if (-not $Quiet) {
        $color = switch ($Level) {
            "ERROR" { "Red" }
            "WARN" { "Yellow" }
            "OK" { "Green" }
            "SECTION" { "Cyan" }
            default { "White" }
        }
        if ($Level -eq "SECTION") {
            Write-Host ""
            Write-Host "================================================================" -ForegroundColor $color
            Write-Host " $Message" -ForegroundColor $color
            Write-Host "================================================================" -ForegroundColor $color
        } else {
            Write-Host $logLine -ForegroundColor $color
        }
    }
}

function Add-Finding {
    param(
        [string]$Category,
        [string]$Check,
        [ValidateSet("Pass", "Warning", "Fail", "Info", "Skipped")]
        [string]$Status,
        [string]$Message,
        [string]$Details = "",
        [string]$Remediation = ""
    )
    
    if (-not $script:Results.ContainsKey($Category)) {
        $script:Results[$Category] = @()
    }
    
    $finding = [PSCustomObject]@{
        Check       = $Check
        Status      = $Status
        Message     = $Message
        Details     = $Details
        Remediation = $Remediation
    }
    
    $script:Results[$Category] += $finding
    
    # Log the finding
    $logLevel = switch ($Status) {
        "Pass" { "OK" }
        "Warning" { "WARN" }
        "Fail" { "ERROR" }
        "Skipped" { "WARN" }
        default { "INFO" }
    }
    Write-Log "$Check : $Message" -Level $logLevel
    
    # Track remediation commands
    if ($Remediation) {
        $script:RemediationCommands += [PSCustomObject]@{
            Category = $Category
            Check    = $Check
            Command  = $Remediation
        }
    }
}
#endregion

#region --- SYSTEM INFORMATION ---

# Helper function for human-readable sizes
function Format-Size {
    param([double]$SizeMB)
    if ($SizeMB -ge 1024) {
        return "{0:N2} GB" -f ($SizeMB / 1024)
    } else {
        return "{0:N0} MB" -f $SizeMB
    }
}

# Helper function for friendly uptime
function Format-Uptime {
    param([TimeSpan]$TimeSpan)
    $parts = @()
    if ($TimeSpan.Days -gt 0) { $parts += "$($TimeSpan.Days)d" }
    if ($TimeSpan.Hours -gt 0) { $parts += "$($TimeSpan.Hours)h" }
    if ($TimeSpan.Minutes -gt 0) { $parts += "$($TimeSpan.Minutes)m" }
    if ($TimeSpan.Seconds -gt 0 -and $TimeSpan.Days -eq 0) { $parts += "$($TimeSpan.Seconds)s" }
    if ($parts.Count -eq 0) { return "0s" }
    return $parts -join " "
}

function Get-SystemInfo {
    Write-Log "Collecting System Information" -Level SECTION
    
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem
        $bios = Get-CimInstance -ClassName Win32_BIOS
        
        # Remove duplicate manufacturer from model (e.g., "HP HP ZBook" -> "HP ZBook")
        $model = $cs.Model
        $manufacturer = $cs.Manufacturer
        if ($model -match "^$([regex]::Escape($manufacturer))\s+") {
            $model = $model -replace "^$([regex]::Escape($manufacturer))\s+", ""
        }
        
        $uptimeSpan = New-TimeSpan -Start $os.LastBootUpTime -End (Get-Date)
        
        $info = [PSCustomObject]@{
            ComputerName  = $env:COMPUTERNAME
            Domain        = $cs.Domain
            Manufacturer  = $manufacturer
            Model         = $model
            SerialNumber  = $bios.SerialNumber
            OSName        = $os.Caption
            OSVersion     = $os.Version
            OSBuild       = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue).DisplayVersion
            Architecture  = $os.OSArchitecture
            InstallDate   = $os.InstallDate
            LastBoot      = $os.LastBootUpTime
            Uptime        = Format-Uptime -TimeSpan $uptimeSpan
            TotalMemoryGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 2)
            IsServer      = $script:IsServer
            IsAdmin       = $script:IsAdmin
            PowerShellVer = $PSVersionTable.PSVersion.ToString()
        }
        
        Write-Log "Computer: $($info.ComputerName) | OS: $($info.OSName) $($info.OSBuild)"
        Write-Log "Model: $($info.Manufacturer) $($info.Model) | Memory: $($info.TotalMemoryGB) GB"
        Write-Log "Uptime: $($info.Uptime) | Last Boot: $($info.LastBoot)"
        
        return $info
    } catch {
        Write-Log "Failed to collect system info: $_" -Level ERROR
        return $null
    }
}
#endregion

#region --- PENDING RESTART CHECK ---
function Test-PendingRestart {
    Write-Log "Checking for Pending Restart" -Level SECTION
    
    $pendingRestart = $false
    $reasons = @()
    
    try {
        # Check Component Based Servicing
        $cbsKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"
        if (Test-Path $cbsKey) {
            $pendingRestart = $true
            $reasons += "Component Based Servicing"
        }
        
        # Check Windows Update
        $wuKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
        if (Test-Path $wuKey) {
            $pendingRestart = $true
            $reasons += "Windows Update"
        }
        
        # Check Pending File Rename Operations
        $pfroKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"
        $pfroValue = Get-ItemProperty -Path $pfroKey -Name "PendingFileRenameOperations" -ErrorAction SilentlyContinue
        if ($pfroValue.PendingFileRenameOperations) {
            $pendingRestart = $true
            $reasons += "Pending File Rename Operations"
        }
        
        # Check Computer Rename
        $activeComputerName = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName" -ErrorAction SilentlyContinue).ComputerName
        $pendingComputerName = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName" -ErrorAction SilentlyContinue).ComputerName
        if ($activeComputerName -ne $pendingComputerName) {
            $pendingRestart = $true
            $reasons += "Computer Rename Pending"
        }
        
        # Check Domain Join
        $djKey = "HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon"
        $djValue = Get-ItemProperty -Path $djKey -Name "JoinDomain" -ErrorAction SilentlyContinue
        if ($djValue.JoinDomain) {
            $pendingRestart = $true
            $reasons += "Domain Join Pending"
        }
        
        if ($pendingRestart) {
            Add-Finding -Category "System" -Check "Pending Restart" -Status "Warning" `
                -Message "System restart is pending" `
                -Details ($reasons -join ", ") `
                -Remediation "Restart-Computer -Force"
        } else {
            Add-Finding -Category "System" -Check "Pending Restart" -Status "Pass" `
                -Message "No pending restart detected"
        }
        
        return [PSCustomObject]@{
            PendingRestart = $pendingRestart
            Reasons        = $reasons
        }
    } catch {
        Write-Log "Failed to check pending restart: $_" -Level ERROR
        return $null
    }
}
#endregion

#region --- SYSTEM FILE INTEGRITY ---
function Test-SystemFileIntegrity {
    Write-Log "System File Integrity Checks" -Level SECTION
    
    if (-not $script:IsAdmin) {
        Add-Finding -Category "SystemFiles" -Check "SFC Scan" -Status "Skipped" `
            -Message "Requires Administrator privileges" `
            -Remediation "Run PowerShell as Administrator"
        Add-Finding -Category "SystemFiles" -Check "DISM Health" -Status "Skipped" `
            -Message "Requires Administrator privileges" `
            -Remediation "Run PowerShell as Administrator"
        return
    }
    
    # SFC - Verify Only for Quick/Standard, Full scan for Full mode
    if ($Mode -eq "Full") {
        Write-Log "Running SFC /scannow (this may take 15-30 minutes)..."
        try {
            $sfcOutput = & sfc /scannow 2>&1 | Out-String
            
            # Handle UTF-16 encoding from sfc.exe - remove null chars and normalize
            $sfcOutput = $sfcOutput -replace "`0", "" -replace '\s+', ' '
            
            if ($sfcOutput -match "did not find any integrity violations") {
                Add-Finding -Category "SystemFiles" -Check "SFC Scan" -Status "Pass" `
                    -Message "No integrity violations found"
            } elseif ($sfcOutput -match "found corrupt files and successfully repaired") {
                Add-Finding -Category "SystemFiles" -Check "SFC Scan" -Status "Warning" `
                    -Message "Corrupt files were found and repaired" `
                    -Details "Review CBS.log for details" `
                    -Remediation "findstr /c:'[SR]' %windir%\Logs\CBS\CBS.log > C:\SFC_Results.txt"
            } elseif ($sfcOutput -match "found corrupt files but was unable to fix") {
                Add-Finding -Category "SystemFiles" -Check "SFC Scan" -Status "Fail" `
                    -Message "Corrupt files found but could not be repaired" `
                    -Details "Run DISM RestoreHealth first, then SFC again" `
                    -Remediation "DISM /Online /Cleanup-Image /RestoreHealth; sfc /scannow"
            } elseif ($sfcOutput -match "resource protection could not perform") {
                Add-Finding -Category "SystemFiles" -Check "SFC Scan" -Status "Fail" `
                    -Message "SFC could not perform the requested operation" `
                    -Details "Try running in Safe Mode or use DISM first" `
                    -Remediation "DISM /Online /Cleanup-Image /RestoreHealth"
            } else {
                Add-Finding -Category "SystemFiles" -Check "SFC Scan" -Status "Info" `
                    -Message "SFC completed - review CBS.log for details" `
                    -Remediation "findstr /c:'[SR]' %windir%\Logs\CBS\CBS.log > C:\SFC_Results.txt"
            }
        } catch {
            Add-Finding -Category "SystemFiles" -Check "SFC Scan" -Status "Fail" `
                -Message "SFC failed to run: $_"
        }
    } else {
        # Verify only (faster)
        Write-Log "Running SFC /verifyonly..."
        try {
            $sfcOutput = & sfc /verifyonly 2>&1 | Out-String
            
            # Handle UTF-16 encoding from sfc.exe - remove null chars and normalize
            $sfcOutput = $sfcOutput -replace "`0", "" -replace '\s+', ' '
            
            if ($sfcOutput -match "did not find any integrity violations") {
                Add-Finding -Category "SystemFiles" -Check "SFC Verify" -Status "Pass" `
                    -Message "No integrity violations found"
            } elseif ($sfcOutput -match "found corrupt files|integrity violations") {
                Add-Finding -Category "SystemFiles" -Check "SFC Verify" -Status "Warning" `
                    -Message "Integrity issues detected" `
                    -Remediation "sfc /scannow"
            } elseif ($sfcOutput -match "resource protection could not perform") {
                Add-Finding -Category "SystemFiles" -Check "SFC Verify" -Status "Fail" `
                    -Message "SFC could not perform the requested operation" `
                    -Remediation "DISM /Online /Cleanup-Image /RestoreHealth"
            } else {
                Add-Finding -Category "SystemFiles" -Check "SFC Verify" -Status "Warning" `
                    -Message "Potential integrity issues detected" `
                    -Remediation "sfc /scannow"
            }
        } catch {
            Add-Finding -Category "SystemFiles" -Check "SFC Verify" -Status "Fail" `
                -Message "SFC verify failed: $_"
        }
    }
    
    # DISM Health Check
    if ($Mode -eq "Full") {
        Write-Log "Running DISM RestoreHealth (this may take 20-40 minutes)..."
        try {
            $dismOutput = & DISM /Online /Cleanup-Image /RestoreHealth 2>&1 | Out-String
            
            if ($dismOutput -match "The restore operation completed successfully") {
                Add-Finding -Category "SystemFiles" -Check "DISM RestoreHealth" -Status "Pass" `
                    -Message "Component store is healthy"
            } elseif ($dismOutput -match "The component store corruption was repaired") {
                Add-Finding -Category "SystemFiles" -Check "DISM RestoreHealth" -Status "Warning" `
                    -Message "Component store was repaired" `
                    -Details "Run SFC again to verify" `
                    -Remediation "sfc /scannow"
            } else {
                Add-Finding -Category "SystemFiles" -Check "DISM RestoreHealth" -Status "Info" `
                    -Message "DISM completed" `
                    -Details $(if ($dismOutput) { $dismOutput.Substring(0, [Math]::Min(500, $dismOutput.Length)) } else { '' })
            }
        } catch {
            Add-Finding -Category "SystemFiles" -Check "DISM RestoreHealth" -Status "Fail" `
                -Message "DISM failed: $_"
        }
    } else {
        # Quick health check
        Write-Log "Running DISM CheckHealth..."
        try {
            $dismOutput = & DISM /Online /Cleanup-Image /CheckHealth 2>&1 | Out-String
            
            if ($dismOutput -match "No component store corruption detected") {
                Add-Finding -Category "SystemFiles" -Check "DISM CheckHealth" -Status "Pass" `
                    -Message "Component store is healthy"
            } elseif ($dismOutput -match "component store corruption") {
                Add-Finding -Category "SystemFiles" -Check "DISM CheckHealth" -Status "Fail" `
                    -Message "Component store corruption detected" `
                    -Remediation "DISM /Online /Cleanup-Image /RestoreHealth"
            } else {
                # Run ScanHealth for more detail in Standard mode
                if ($Mode -eq "Standard") {
                    Write-Log "Running DISM ScanHealth..."
                    $dismScan = & DISM /Online /Cleanup-Image /ScanHealth 2>&1 | Out-String
                    
                    if ($dismScan -match "No component store corruption detected") {
                        Add-Finding -Category "SystemFiles" -Check "DISM ScanHealth" -Status "Pass" `
                            -Message "Component store scan passed"
                    } else {
                        Add-Finding -Category "SystemFiles" -Check "DISM ScanHealth" -Status "Warning" `
                            -Message "Component store may need repair" `
                            -Remediation "DISM /Online /Cleanup-Image /RestoreHealth"
                    }
                }
            }
        } catch {
            Add-Finding -Category "SystemFiles" -Check "DISM CheckHealth" -Status "Fail" `
                -Message "DISM check failed: $_"
        }
    }
    
    # WMI Repository Health Check
    Test-WMIHealth
}

function Test-WMIHealth {
    Write-Log "WMI Repository Health Check"
    
    if (-not $script:IsAdmin) {
        Add-Finding -Category "SystemFiles" -Check "WMI Repository" -Status "Skipped" `
            -Message "Requires Administrator privileges" `
            -Remediation "Run PowerShell as Administrator"
        return
    }
    
    try {
        $wmiOutput = & winmgmt /verifyrepository 2>&1 | Out-String
        
        if ($wmiOutput -match "consistent") {
            Add-Finding -Category "SystemFiles" -Check "WMI Repository" -Status "Pass" `
                -Message "WMI repository is consistent"
        } elseif ($wmiOutput -match "inconsistent") {
            Add-Finding -Category "SystemFiles" -Check "WMI Repository" -Status "Fail" `
                -Message "WMI repository is inconsistent" `
                -Details "WMI corruption can cause many system issues" `
                -Remediation "winmgmt /salvagerepository"
        } else {
            Add-Finding -Category "SystemFiles" -Check "WMI Repository" -Status "Info" `
                -Message "WMI verification completed" `
                -Details $(if ($wmiOutput) { $wmiOutput.Trim().Substring(0, [Math]::Min(200, $wmiOutput.Trim().Length)) } else { '' })
        }
    } catch {
        Add-Finding -Category "SystemFiles" -Check "WMI Repository" -Status "Warning" `
            -Message "Could not verify WMI repository: $_"
    }
}

function Get-BIOSInfo {
    Write-Log "BIOS/Firmware Information"
    
    try {
        $bios = Get-CimInstance -ClassName Win32_BIOS
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem
        
        # Get BIOS date
        $biosDate = $bios.ReleaseDate
        $biosAge = if ($biosDate) { (New-TimeSpan -Start $biosDate -End (Get-Date)).Days } else { $null }
        
        # Check for UEFI vs Legacy BIOS
        $firmwareType = "Unknown"
        try {
            $null = Confirm-SecureBootUEFI -ErrorAction SilentlyContinue
            $firmwareType = "UEFI"
        } catch {
            # If Confirm-SecureBootUEFI fails, likely Legacy BIOS or Secure Boot not supported
            $bcdeditOutput = bcdedit 2>&1 | Out-String
            if ($bcdeditOutput -match "path.*\\efi\\") {
                $firmwareType = "UEFI"
            } else {
                $firmwareType = "Legacy BIOS"
            }
        }
        
        # Determine status based on BIOS age
        $status = "Info"
        $details = "Manufacturer: $($bios.Manufacturer)"
        $remediation = ""
        
        if ($biosAge -and $biosAge -gt 90) {
            # Older than 3 months
            $status = "Warning"
            $details = "BIOS is over 3 months old. Manufacturer: $($bios.Manufacturer)"
            $remediation = "# Check manufacturer website for BIOS updates: $($cs.Manufacturer)"
        }
        
        $biosDateStr = if ($biosDate) { $biosDate.ToString('yyyy-MM-dd') } else { "Unknown" }
        
        Add-Finding -Category "System" -Check "BIOS/Firmware" -Status $status `
            -Message "$firmwareType | Version: $($bios.SMBIOSBIOSVersion) | Date: $biosDateStr" `
            -Details $details `
            -Remediation $remediation
        
        # Check Secure Boot status (UEFI systems only)
        if ($firmwareType -eq "UEFI") {
            try {
                $secureBoot = Confirm-SecureBootUEFI -ErrorAction Stop
                $sbStatus = if ($secureBoot) { "Pass" } else { "Warning" }
                Add-Finding -Category "Security" -Check "Secure Boot" -Status $sbStatus `
                    -Message "Secure Boot: $(if ($secureBoot) { 'Enabled' } else { 'Disabled' })" `
                    -Details $(if (-not $secureBoot) { "Secure Boot disabled reduces protection against bootkits" } else { "" }) `
                    -Remediation $(if (-not $secureBoot) { "# Enable Secure Boot in UEFI/BIOS settings" } else { "" })
            } catch {
                Add-Finding -Category "Security" -Check "Secure Boot" -Status "Info" `
                    -Message "Secure Boot status not available"
            }
        }
        
    } catch {
        Add-Finding -Category "System" -Check "BIOS/Firmware" -Status "Info" `
            -Message "Could not retrieve BIOS information: $_"
    }
}
#endregion

#region --- DISK HEALTH ---
function Test-DiskHealth {
    Write-Log "Disk Health Checks" -Level SECTION
    
    # Disk Space
    $volumes = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3"
    
    foreach ($vol in $volumes) {
        if (-not $vol.Size -or $vol.Size -eq 0) { continue }
        $freePercent = [math]::Round(($vol.FreeSpace / $vol.Size) * 100, 1)
        $freeGB = [math]::Round($vol.FreeSpace / 1GB, 2)
        $totalGB = [math]::Round($vol.Size / 1GB, 2)
        
        $status = if ($freePercent -lt 10) { "Fail" }
        elseif ($freePercent -lt 20) { "Warning" }
        else { "Pass" }
        
        $remediation = if ($status -ne "Pass") {
            "cleanmgr /d $($vol.DeviceID.TrimEnd(':')) /sagerun:1"
        } else { "" }
        
        Add-Finding -Category "Disk" -Check "Disk Space ($($vol.DeviceID))" -Status $status `
            -Message "$freeGB GB free of $totalGB GB ($freePercent%)" `
            -Remediation $remediation
    }
    
    # SMART Status
    try {
        $disks = Get-CimInstance -Namespace "root\wmi" -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction SilentlyContinue
        
        if ($disks) {
            foreach ($disk in $disks) {
                $diskName = "Disk $($disk.InstanceName.Split('_')[0])"
                if ($disk.PredictFailure) {
                    Add-Finding -Category "Disk" -Check "SMART Status ($diskName)" -Status "Fail" `
                        -Message "SMART predicts imminent failure!" `
                        -Details "Back up data immediately" `
                        -Remediation "# CRITICAL: Back up data immediately. Replace disk."
                } else {
                    Add-Finding -Category "Disk" -Check "SMART Status" -Status "Pass" `
                        -Message "No disk failures predicted"
                }
            }
        } else {
            # Try alternative method
            $physicalDisks = Get-CimInstance -ClassName Win32_DiskDrive
            foreach ($disk in $physicalDisks) {
                if ($disk.Status -eq "OK" -or $disk.Status -eq "Pred Fail") {
                    $status = if ($disk.Status -eq "Pred Fail") { "Fail" } else { "Pass" }
                    Add-Finding -Category "Disk" -Check "Disk Status ($($disk.Model))" -Status $status `
                        -Message "Status: $($disk.Status)"
                }
            }
        }
    } catch {
        Add-Finding -Category "Disk" -Check "SMART Status" -Status "Info" `
            -Message "SMART status not available"
    }
    
    # Fragmentation (only for HDDs, skip SSDs)
    if ($script:IsAdmin -and $Mode -ne "Quick") {
        try {
            $volumes = Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' }
            
            foreach ($vol in $volumes) {
                $analysis = Optimize-Volume -DriveLetter $vol.DriveLetter -Analyze -ErrorAction SilentlyContinue
                $fragPercent = $analysis.FragmentPercent
                
                if ($null -ne $fragPercent) {
                    $status = if ($fragPercent -gt 50) { "Fail" }
                    elseif ($fragPercent -gt 30) { "Warning" }
                    else { "Pass" }
                    
                    $remediation = if ($status -ne "Pass") {
                        "Optimize-Volume -DriveLetter $($vol.DriveLetter) -Defrag -Verbose"
                    } else { "" }
                    
                    Add-Finding -Category "Disk" -Check "Fragmentation ($($vol.DriveLetter):)" -Status $status `
                        -Message "$fragPercent% fragmented" `
                        -Remediation $remediation
                }
            }
        } catch {
            Write-Log "Fragmentation analysis not available: $_" -Level WARN
        }
    }
    
    # Check for disk errors in event log
    $diskErrors = Get-WinEvent -FilterHashtable @{LogName = 'System'; ProviderName = 'disk'; Level = 2, 3; StartTime = (Get-Date).AddDays(-$DaysBack) } -MaxEvents 10 -ErrorAction SilentlyContinue
    
    if ($diskErrors) {
        Add-Finding -Category "Disk" -Check "Disk Errors (Event Log)" -Status "Warning" `
            -Message "$($diskErrors.Count) disk error events in last $DaysBack days" `
            -Details (($diskErrors | Select-Object -First 3 | ForEach-Object { if ($_.Message) { $_.Message.Substring(0, [Math]::Min(100, $_.Message.Length)) } else { '(no message)' } }) -join "; ") `
            -Remediation "chkdsk C: /scan"
    } else {
        Add-Finding -Category "Disk" -Check "Disk Errors (Event Log)" -Status "Pass" `
            -Message "No disk errors in event log"
    }
}
#endregion

#region --- EVENT LOG ANALYSIS ---
function Get-EventLogIssues {
    Write-Log "Event Log Analysis" -Level SECTION
    
    $startDate = (Get-Date).AddDays(-$DaysBack)
    
    # System Critical/Error events
    try {
        $systemErrors = Get-WinEvent -FilterHashtable @{
            LogName   = 'System'
            Level     = 1, 2  # Critical, Error
            StartTime = $startDate
        } -MaxEvents 100 -ErrorAction SilentlyContinue
        
        if ($systemErrors) {
            $criticalCount = ($systemErrors | Where-Object { $_.Level -eq 1 }).Count
            $errorCount = ($systemErrors | Where-Object { $_.Level -eq 2 }).Count
            
            $status = if ($criticalCount -gt 0) { "Fail" }
            elseif ($errorCount -gt 10) { "Warning" }
            else { "Info" }
            
            # Group by source
            $topSources = $systemErrors | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 5
            $sourceDetails = ($topSources | ForEach-Object { "$($_.Name): $($_.Count)" }) -join ", "
            
            Add-Finding -Category "EventLog" -Check "System Errors" -Status $status `
                -Message "$criticalCount critical, $errorCount errors in last $DaysBack days" `
                -Details "Top sources: $sourceDetails" `
                -Remediation "Get-WinEvent -FilterHashtable @{LogName='System';Level=1,2;StartTime=(Get-Date).AddDays(-7)} | Group-Object ProviderName | Sort-Object Count -Descending"
        } else {
            Add-Finding -Category "EventLog" -Check "System Errors" -Status "Pass" `
                -Message "No critical/error events in last $DaysBack days"
        }
    } catch {
        Add-Finding -Category "EventLog" -Check "System Errors" -Status "Info" `
            -Message "Could not query system event log"
    }
    
    # Application crashes
    try {
        $appCrashes = Get-WinEvent -FilterHashtable @{
            LogName      = 'Application'
            ProviderName = 'Application Error', 'Windows Error Reporting', 'Application Hang'
            StartTime    = $startDate
        } -MaxEvents 50 -ErrorAction SilentlyContinue
        
        if ($appCrashes) {
            $status = if ($appCrashes.Count -gt 20) { "Warning" } else { "Info" }
            
            Add-Finding -Category "EventLog" -Check "Application Crashes" -Status $status `
                -Message "$($appCrashes.Count) application errors/crashes in last $DaysBack days" `
                -Remediation "Get-WinEvent -FilterHashtable @{LogName='Application';ProviderName='Application Error','Windows Error Reporting';StartTime=(Get-Date).AddDays(-7)} | Select-Object TimeCreated, Message -First 20"
        } else {
            Add-Finding -Category "EventLog" -Check "Application Crashes" -Status "Pass" `
                -Message "No application crashes detected"
        }
    } catch {
        # Ignore if not found
    }
    
    # BSOD/BugCheck events
    try {
        $bsodEvents = Get-WinEvent -FilterHashtable @{
            LogName      = 'System'
            ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'
            StartTime    = $startDate
        } -MaxEvents 10 -ErrorAction SilentlyContinue
        
        if ($bsodEvents) {
            Add-Finding -Category "EventLog" -Check "Blue Screen Errors" -Status "Fail" `
                -Message "$($bsodEvents.Count) BSOD events in last $DaysBack days" `
                -Details "System stability issues detected" `
                -Remediation "Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Microsoft-Windows-WER-SystemErrorReporting'} | Select-Object TimeCreated, Message"
        } else {
            Add-Finding -Category "EventLog" -Check "Blue Screen Errors" -Status "Pass" `
                -Message "No BSOD events detected"
        }
    } catch {
        Add-Finding -Category "EventLog" -Check "Blue Screen Errors" -Status "Pass" `
            -Message "No BSOD events detected"
    }
    
    # Unexpected shutdowns
    try {
        $unexpectedShutdowns = Get-WinEvent -FilterHashtable @{
            LogName   = 'System'
            Id        = 6008  # Unexpected shutdown
            StartTime = $startDate
        } -MaxEvents 10 -ErrorAction SilentlyContinue
        
        if ($unexpectedShutdowns) {
            Add-Finding -Category "EventLog" -Check "Unexpected Shutdowns" -Status "Warning" `
                -Message "$($unexpectedShutdowns.Count) unexpected shutdowns in last $DaysBack days" `
                -Details "May indicate power issues or system instability"
        } else {
            Add-Finding -Category "EventLog" -Check "Unexpected Shutdowns" -Status "Pass" `
                -Message "No unexpected shutdowns"
        }
    } catch {
        # Ignore
    }
}
#endregion

#region --- WINDOWS UPDATE HEALTH ---
function Test-WindowsUpdateHealth {
    Write-Log "Windows Update Health" -Level SECTION
    
    # Windows Update Service Status
    $wuService = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
    
    if ($wuService) {
        $status = if ($wuService.StartType -eq 'Disabled') { "Warning" } else { "Pass" }
        Add-Finding -Category "WindowsUpdate" -Check "Windows Update Service" -Status $status `
            -Message "Service: $($wuService.Status), StartType: $($wuService.StartType)" `
            -Remediation $(if ($status -eq "Warning") { "Set-Service -Name wuauserv -StartupType Manual" } else { "" })
    }
    
    # Last Update Check
    try {
        $auSession = New-Object -ComObject Microsoft.Update.Session
        $auSearcher = $auSession.CreateUpdateSearcher()
        
        # Get update history
        $historyCount = $auSearcher.GetTotalHistoryCount()
        if ($historyCount -gt 0) {
            $history = $auSearcher.QueryHistory(0, [Math]::Min($historyCount, 10))
            $lastUpdate = $history | Where-Object { $_.ResultCode -eq 2 } | Select-Object -First 1
            
            if ($lastUpdate) {
                $daysSinceUpdate = (New-TimeSpan -Start $lastUpdate.Date -End (Get-Date)).Days
                
                $status = if ($daysSinceUpdate -gt 60) { "Fail" }
                elseif ($daysSinceUpdate -gt 30) { "Warning" }
                else { "Pass" }
                
                Add-Finding -Category "WindowsUpdate" -Check "Last Successful Update" -Status $status `
                    -Message "Last update: $($lastUpdate.Date.ToString('yyyy-MM-dd')) ($daysSinceUpdate days ago)" `
                    -Remediation $(if ($status -ne "Pass") { "# Check for updates: Start-Process 'ms-settings:windowsupdate'" } else { "" })
            }
        }
        
        # Check for pending updates
        Write-Log "Checking for pending updates..."
        $searchResult = $auSearcher.Search("IsInstalled=0 and Type='Software'")
        
        if ($searchResult.Updates.Count -gt 0) {
            $criticalCount = ($searchResult.Updates | Where-Object { $_.MsrcSeverity -eq 'Critical' }).Count
            $importantCount = ($searchResult.Updates | Where-Object { $_.MsrcSeverity -eq 'Important' }).Count
            
            $status = if ($criticalCount -gt 0) { "Fail" }
            elseif ($importantCount -gt 0 -or $searchResult.Updates.Count -gt 5) { "Warning" }
            else { "Info" }
            
            Add-Finding -Category "WindowsUpdate" -Check "Pending Updates" -Status $status `
                -Message "$($searchResult.Updates.Count) updates pending ($criticalCount critical, $importantCount important)" `
                -Remediation "# Install updates: Start-Process 'ms-settings:windowsupdate-action'"
        } else {
            Add-Finding -Category "WindowsUpdate" -Check "Pending Updates" -Status "Pass" `
                -Message "System is up to date"
        }
    } catch {
        Add-Finding -Category "WindowsUpdate" -Check "Windows Update Status" -Status "Info" `
            -Message "Could not query Windows Update: $_"
    }
}
#endregion

#region --- PERFORMANCE METRICS ---
function Get-PerformanceBaseline {
    Write-Log "Performance Metrics" -Level SECTION
    
    # CPU Usage
    try {
        $cpuUsage = (Get-CimInstance -ClassName Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
        
        $status = if ($cpuUsage -gt 95) { "Fail" }
        elseif ($cpuUsage -gt 90) { "Warning" }
        else { "Pass" }
        
        Add-Finding -Category "Performance" -Check "CPU Usage" -Status $status `
            -Message "Current CPU: $cpuUsage%" `
            -Remediation $(if ($status -ne "Pass") { "Get-Process | Sort-Object CPU -Descending | Select-Object -First 10 Name, CPU, Id" } else { "" })
    } catch {
        Write-Log "Could not get CPU usage: $_" -Level WARN
    }
    
    # Memory Usage
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $totalMem = $os.TotalVisibleMemorySize / 1MB
        $freeMem = $os.FreePhysicalMemory / 1MB
        $usedPercent = [math]::Round((($totalMem - $freeMem) / $totalMem) * 100, 1)
        
        $status = if ($usedPercent -gt 95) { "Fail" }
        elseif ($usedPercent -gt 90) { "Warning" }
        else { "Pass" }
        
        Add-Finding -Category "Performance" -Check "Memory Usage" -Status $status `
            -Message "Memory: $usedPercent% used ($([math]::Round($freeMem, 2)) GB free of $([math]::Round($totalMem, 2)) GB)" `
            -Remediation $(if ($status -ne "Pass") { "Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 10 Name, @{N='MemMB';E={[math]::Round(`$_.WorkingSet64/1MB,0)}}, Id" } else { "" })
    } catch {
        Write-Log "Could not get memory usage: $_" -Level WARN
    }
    
    # Top Processes
    if ($Mode -ne "Quick") {
        try {
            $processes = Get-Process
            $topCPU = $processes | Sort-Object CPU -Descending | Select-Object -First 5 Name, CPU, Id
            $topMem = $processes | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 Name, @{N = 'MemMB'; E = { [math]::Round($_.WorkingSet64 / 1MB, 0) } }, Id
            
            $cpuDetails = ($topCPU | ForEach-Object { "$($_.Name): $([math]::Round($_.CPU, 0))s" }) -join ", "
            $memDetails = ($topMem | ForEach-Object { "$($_.Name): $($_.MemMB)MB" }) -join ", "
            
            Add-Finding -Category "Performance" -Check "Top CPU Consumers" -Status "Info" `
                -Message $cpuDetails
            
            Add-Finding -Category "Performance" -Check "Top Memory Consumers" -Status "Info" `
                -Message $memDetails
        } catch {
            Write-Log "Could not analyze processes: $_" -Level WARN
        }
    }
    
    # Boot Time (if available)
    try {
        $bootEvents = Get-WinEvent -FilterHashtable @{
            LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'
            Id      = 100
        } -MaxEvents 1 -ErrorAction SilentlyContinue
        
        if ($bootEvents) {
            $bootTime = $bootEvents[0].Properties[1].Value / 1000  # Convert to seconds
            
            $status = if ($bootTime -gt 180) { "Fail" }
            elseif ($bootTime -gt 120) { "Warning" }
            else { "Pass" }
            
            Add-Finding -Category "Performance" -Check "Last Boot Time" -Status $status `
                -Message "Boot duration: $([math]::Round($bootTime, 1)) seconds" `
                -Remediation $(if ($status -ne "Pass") { "# Review startup items: Get-CimInstance Win32_StartupCommand | Select-Object Name, Command, Location" } else { "" })
        }
    } catch {
        # Boot diagnostics not available
    }
}
#endregion

#region --- STARTUP IMPACT ---
function Get-StartupImpact {
    Write-Log "Startup Impact Analysis" -Level SECTION
    
    # Get startup items
    try {
        $startupItems = Get-CimInstance -ClassName Win32_StartupCommand -ErrorAction SilentlyContinue
        
        if ($startupItems) {
            $count = $startupItems.Count
            $status = if ($count -gt 25) { "Fail" }
            elseif ($count -gt 15) { "Warning" }
            else { "Pass" }
            
            Add-Finding -Category "Startup" -Check "Startup Items" -Status $status `
                -Message "$count programs configured to run at startup" `
                -Details (($startupItems | Select-Object -First 5 | ForEach-Object { $_.Name }) -join ", ") `
                -Remediation $(if ($status -ne "Pass") { "Get-CimInstance Win32_StartupCommand | Select-Object Name, Command, Location | Format-Table -AutoSize" } else { "" })
        }
    } catch {
        Write-Log "Could not enumerate startup items: $_" -Level WARN
    }
    
    # Scheduled Tasks (enabled, running at logon)
    try {
        $logonTasks = Get-ScheduledTask | Where-Object { 
            $_.State -ne 'Disabled' -and 
            $_.Triggers.GetType().Name -match 'Logon'
        } -ErrorAction SilentlyContinue
        
        if ($logonTasks) {
            Add-Finding -Category "Startup" -Check "Logon Scheduled Tasks" -Status "Info" `
                -Message "$($logonTasks.Count) scheduled tasks run at logon" `
                -Details (($logonTasks | Select-Object -First 5 | ForEach-Object { $_.TaskName }) -join ", ")
        }
    } catch {
        # Ignore
    }
    
    # Services set to Automatic start
    try {
        $autoServices = Get-Service | Where-Object { $_.StartType -eq 'Automatic' -and $_.Status -eq 'Running' }
        
        Add-Finding -Category "Startup" -Check "Auto-Start Services" -Status "Info" `
            -Message "$($autoServices.Count) services set to start automatically"
    } catch {
        # Ignore
    }
}
#endregion

#region --- NETWORK HEALTH ---
function Test-NetworkHealth {
    Write-Log "Network Health Checks" -Level SECTION
    
    # Network Adapters - Active
    $adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
    
    foreach ($adapter in $adapters) {
        Add-Finding -Category "Network" -Check "Adapter: $($adapter.Name)" -Status "Pass" `
            -Message "Status: $($adapter.Status), Speed: $($adapter.LinkSpeed)"
    }
    
    # Disconnected adapters - group them together, exclude virtual/hidden adapters
    $disconnected = @(Get-NetAdapter | Where-Object { 
            $_.Status -eq 'Disconnected' -and 
            $_.MediaType -ne 'Unspecified' -and
            $_.Virtual -eq $false -and
            $_.InterfaceDescription -notmatch 'Virtual|VPN|TAP|Hyper-V|VMware|VirtualBox|Docker|WSL'
        })
    
    if ($disconnected.Count -gt 0) {
        # Group disconnected physical adapters into a single finding
        $adapterNames = ($disconnected | ForEach-Object { $_.Name }) -join ", "
        Add-Finding -Category "Network" -Check "Disconnected Adapters" -Status "Info" `
            -Message "$($disconnected.Count) physical adapter(s) disconnected" `
            -Details $adapterNames
    }
    
    # Virtual/VPN adapters - separate group if any are disconnected
    $virtualDisconnected = @(Get-NetAdapter | Where-Object { 
            $_.Status -eq 'Disconnected' -and 
            ($_.Virtual -eq $true -or $_.InterfaceDescription -match 'Virtual|VPN|TAP|Hyper-V|VMware|VirtualBox|Docker|WSL')
        })
    
    if ($virtualDisconnected.Count -gt 0) {
        $adapterNames = ($virtualDisconnected | ForEach-Object { $_.Name }) -join ", "
        Add-Finding -Category "Network" -Check "Virtual Adapters (Inactive)" -Status "Info" `
            -Message "$($virtualDisconnected.Count) virtual/VPN adapter(s) inactive" `
            -Details $adapterNames
    }
    
    # DNS Resolution
    try {
        $null = Resolve-DnsName -Name "www.microsoft.com" -Type A -ErrorAction Stop
        Add-Finding -Category "Network" -Check "DNS Resolution" -Status "Pass" `
            -Message "DNS is working"
    } catch {
        Add-Finding -Category "Network" -Check "DNS Resolution" -Status "Fail" `
            -Message "DNS resolution failed" `
            -Remediation "ipconfig /flushdns; Clear-DnsClientCache"
    }
    
    # Internet Connectivity
    try {
        $webTest = Invoke-WebRequest -Uri "http://www.msftconnecttest.com/connecttest.txt" -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        if ($webTest.Content -match "Microsoft Connect Test") {
            Add-Finding -Category "Network" -Check "Internet Connectivity" -Status "Pass" `
                -Message "Internet connection verified"
        }
    } catch {
        Add-Finding -Category "Network" -Check "Internet Connectivity" -Status "Warning" `
            -Message "Could not verify internet connectivity" `
            -Remediation "Test-NetConnection -ComputerName 8.8.8.8 -Port 443"
    }
    
    # Network Configuration Issues
    try {
        $ipConfig = Get-NetIPConfiguration | Where-Object { $_.NetAdapter.Status -eq 'Up' }
        
        foreach ($config in $ipConfig) {
            if (-not $config.IPv4DefaultGateway) {
                Add-Finding -Category "Network" -Check "Gateway ($($config.InterfaceAlias))" -Status "Warning" `
                    -Message "No default gateway configured"
            }
            if (-not $config.DNSServer) {
                Add-Finding -Category "Network" -Check "DNS ($($config.InterfaceAlias))" -Status "Warning" `
                    -Message "No DNS server configured"
            }
        }
    } catch {
        Write-Log "Could not analyze network configuration: $_" -Level WARN
    }
}
#endregion

#region --- CLEANUP OPPORTUNITIES ---
function Get-CleanupOpportunities {
    Write-Log "Cleanup Opportunities" -Level SECTION
    
    $totalCleanupMB = 0
    
    # Windows Temp
    $winTemp = "$env:SystemRoot\Temp"
    if (Test-Path $winTemp) {
        $size = (Get-ChildItem $winTemp -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB
        $sizeMB = [math]::Round($size, 2)
        $totalCleanupMB += $sizeMB
        $sizeStr = Format-Size -SizeMB $sizeMB
        
        if ($sizeMB -gt 500) {
            Add-Finding -Category "Cleanup" -Check "Windows Temp" -Status "Warning" `
                -Message "$sizeStr in Windows temp folder" `
                -Remediation "Remove-Item -Path '$winTemp\*' -Recurse -Force -ErrorAction SilentlyContinue"
        } else {
            Add-Finding -Category "Cleanup" -Check "Windows Temp" -Status "Info" `
                -Message "$sizeStr in Windows temp folder"
        }
    }
    
    # User Temp
    $userTemp = $env:TEMP
    if (Test-Path $userTemp) {
        $size = (Get-ChildItem $userTemp -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB
        $sizeMB = [math]::Round($size, 2)
        $totalCleanupMB += $sizeMB
        $sizeStr = Format-Size -SizeMB $sizeMB
        
        if ($sizeMB -gt 500) {
            Add-Finding -Category "Cleanup" -Check "User Temp" -Status "Warning" `
                -Message "$sizeStr in user temp folder" `
                -Remediation "Remove-Item -Path '$userTemp\*' -Recurse -Force -ErrorAction SilentlyContinue"
        } else {
            Add-Finding -Category "Cleanup" -Check "User Temp" -Status "Info" `
                -Message "$sizeStr in user temp folder"
        }
    }
    
    # Windows Update Cache
    $wuCache = "$env:SystemRoot\SoftwareDistribution\Download"
    if (Test-Path $wuCache) {
        $size = (Get-ChildItem $wuCache -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB
        $sizeMB = [math]::Round($size, 2)
        $totalCleanupMB += $sizeMB
        $sizeStr = Format-Size -SizeMB $sizeMB
        
        if ($sizeMB -gt 1000) {
            Add-Finding -Category "Cleanup" -Check "Windows Update Cache" -Status "Warning" `
                -Message "$sizeStr in Windows Update cache" `
                -Remediation "Stop-Service wuauserv -Force; Remove-Item '$wuCache\*' -Recurse -Force; Start-Service wuauserv"
        } else {
            Add-Finding -Category "Cleanup" -Check "Windows Update Cache" -Status "Info" `
                -Message "$sizeStr in Windows Update cache"
        }
    }
    
    # Recycle Bin
    try {
        $shell = New-Object -ComObject Shell.Application
        $recycleBin = $shell.NameSpace(0x0a)
        $rbSize = ($recycleBin.Items() | Measure-Object -Property Size -Sum).Sum / 1MB
        $rbSizeMB = [math]::Round($rbSize, 2)
        $totalCleanupMB += $rbSizeMB
        $sizeStr = Format-Size -SizeMB $rbSizeMB
        
        if ($rbSizeMB -gt 1000) {
            Add-Finding -Category "Cleanup" -Check "Recycle Bin" -Status "Warning" `
                -Message "$sizeStr in Recycle Bin" `
                -Remediation "Clear-RecycleBin -Force -ErrorAction SilentlyContinue"
        } else {
            Add-Finding -Category "Cleanup" -Check "Recycle Bin" -Status "Info" `
                -Message "$sizeStr in Recycle Bin"
        }
    } catch {
        # Ignore
    }
    
    # CBS Logs
    $cbsLogs = "$env:SystemRoot\Logs\CBS"
    if (Test-Path $cbsLogs) {
        $size = (Get-ChildItem $cbsLogs -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB
        $sizeMB = [math]::Round($size, 2)
        $sizeStr = Format-Size -SizeMB $sizeMB
        
        if ($sizeMB -gt 500) {
            $totalCleanupMB += $sizeMB
            Add-Finding -Category "Cleanup" -Check "CBS Logs" -Status "Warning" `
                -Message "$sizeStr in CBS logs" `
                -Remediation "DISM /Online /Cleanup-Image /StartComponentCleanup"
        }
    }
    
    # Summary
    $totalSizeStr = Format-Size -SizeMB $totalCleanupMB
    Add-Finding -Category "Cleanup" -Check "Total Cleanup Potential" -Status "Info" `
        -Message "Approximately $totalSizeStr can be reclaimed" `
        -Remediation "cleanmgr /sagerun:1"
}
#endregion

#region --- DRIVER CHECKS ---
function Test-DriverHealth {
    Write-Log "Driver Health Checks" -Level SECTION
    
    # ConfigManagerErrorCode lookup table
    $errorCodes = @{
        1  = "Not configured"
        2  = "Windows cannot load the driver"
        3  = "Driver corrupted or missing"
        4  = "Not working properly (registry/INF issue)"
        5  = "Missing resource"
        6  = "Boot conflict"
        7  = "Cannot filter"
        8  = "Missing driver loader"
        9  = "Incorrect resource control"
        10 = "Device cannot start"
        11 = "Device failed"
        12 = "Not enough resources"
        13 = "Resources not verified"
        14 = "Requires restart"
        15 = "Re-enumeration problem"
        16 = "Not fully identified"
        17 = "Unknown resource type"
        18 = "Reinstall drivers"
        19 = "Registry error"
        20 = "VxD Loader failure"
        21 = "System failure"
        22 = "Device disabled"
        23 = "System failure"
        24 = "Device not present"
        25 = "Setup in progress"
        26 = "Setup in progress"
        27 = "Invalid log configuration"
        28 = "Drivers not installed"
        29 = "BIOS did not allocate resources"
        30 = "IRQ conflict"
        31 = "Not working properly"
    }
    
    # Problematic Drivers (devices with issues)
    try {
        $problemDevices = @(Get-CimInstance -ClassName Win32_PnPEntity | Where-Object { 
                $_.ConfigManagerErrorCode -ne 0 
            })
        
        if ($problemDevices.Count -gt 0) {
            # Build detailed list with error descriptions
            $deviceDetails = $problemDevices | Select-Object -First 5 | ForEach-Object {
                $errorDesc = $errorCodes[$_.ConfigManagerErrorCode]
                if (-not $errorDesc) { $errorDesc = "Error code $($_.ConfigManagerErrorCode)" }
                "$($_.Name): $errorDesc"
            }
            $deviceList = $deviceDetails -join "; "
            Add-Finding -Category "Drivers" -Check "Problematic Devices" -Status "Fail" `
                -Message "$($problemDevices.Count) device(s) with driver issues" `
                -Details $deviceList `
                -Remediation "Get-CimInstance Win32_PnPEntity | Where-Object { `$_.ConfigManagerErrorCode -ne 0 } | Select-Object Name, ConfigManagerErrorCode"
        } else {
            Add-Finding -Category "Drivers" -Check "Problematic Devices" -Status "Pass" `
                -Message "No devices with driver problems"
        }
    } catch {
        Write-Log "Could not check for problematic devices: $_" -Level WARN
    }
    
    # Unsigned Drivers
    if ($script:IsAdmin) {
        try {
            $unsignedDrivers = Get-CimInstance -ClassName Win32_PnPSignedDriver | Where-Object { 
                $_.IsSigned -eq $false -and $_.DeviceName
            }
            
            if ($unsignedDrivers) {
                $driverList = ($unsignedDrivers | Select-Object -First 5 | ForEach-Object { $_.DeviceName }) -join ", "
                $status = if ($unsignedDrivers.Count -gt 3) { "Warning" } else { "Info" }
                Add-Finding -Category "Drivers" -Check "Unsigned Drivers" -Status $status `
                    -Message "$($unsignedDrivers.Count) unsigned driver(s) found" `
                    -Details $driverList `
                    -Remediation "Get-CimInstance Win32_PnPSignedDriver | Where-Object { `$_.IsSigned -eq `$false } | Select-Object DeviceName, DriverVersion, Manufacturer"
            } else {
                Add-Finding -Category "Drivers" -Check "Unsigned Drivers" -Status "Pass" `
                    -Message "All drivers are signed"
            }
        } catch {
            Write-Log "Could not check driver signatures: $_" -Level WARN
        }
        
        # Old/Outdated Drivers (drivers older than 3 years, excluding bogus dates)
        try {
            $threeYearsAgo = (Get-Date).AddYears(-3)
            $minValidDate = [DateTime]::new(1980, 1, 1)  # Filter out bogus 1968/1970 epoch dates
            $oldDrivers = Get-CimInstance -ClassName Win32_PnPSignedDriver | Where-Object { 
                $_.DriverDate -and $_.DriverDate -lt $threeYearsAgo -and $_.DriverDate -gt $minValidDate -and $_.DeviceName
            }
            
            if ($oldDrivers -and $oldDrivers.Count -gt 5) {
                $driverList = ($oldDrivers | Sort-Object DriverDate | Select-Object -First 5 | ForEach-Object { 
                        "$($_.DeviceName) ($($_.DriverDate.ToString('yyyy-MM-dd')))" 
                    }) -join ", "
                Add-Finding -Category "Drivers" -Check "Outdated Drivers" -Status "Info" `
                    -Message "$($oldDrivers.Count) drivers older than 3 years" `
                    -Details $driverList
            } else {
                Add-Finding -Category "Drivers" -Check "Outdated Drivers" -Status "Pass" `
                    -Message "Drivers are reasonably current"
            }
        } catch {
            Write-Log "Could not check driver dates: $_" -Level WARN
        }
    } else {
        Add-Finding -Category "Drivers" -Check "Driver Signatures" -Status "Skipped" `
            -Message "Requires Administrator privileges"
    }
    
    # Driver crashes in event log
    try {
        $driverCrashes = Get-WinEvent -FilterHashtable @{
            LogName      = 'System'
            ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting', 'Microsoft-Windows-Kernel-Power'
            Level        = 1, 2
            StartTime    = (Get-Date).AddDays(-$DaysBack)
        } -MaxEvents 20 -ErrorAction SilentlyContinue | Where-Object {
            $_.Message -match 'driver|hardware'
        }
        
        if ($driverCrashes) {
            Add-Finding -Category "Drivers" -Check "Driver-Related Crashes" -Status "Warning" `
                -Message "$($driverCrashes.Count) driver-related events in last $DaysBack days" `
                -Remediation "Get-WinEvent -FilterHashtable @{LogName='System';Level=1,2} -MaxEvents 50 | Where-Object { `$_.Message -match 'driver' }"
        } else {
            Add-Finding -Category "Drivers" -Check "Driver-Related Crashes" -Status "Pass" `
                -Message "No driver-related crashes detected"
        }
    } catch {
        # Ignore if no events found
    }
}
#endregion

#region --- MEMORY DIAGNOSTICS ---
function Test-MemoryDiagnostics {
    Write-Log "Memory Diagnostics" -Level SECTION
    
    # Memory errors in event log
    try {
        $memoryErrors = Get-WinEvent -FilterHashtable @{
            LogName      = 'System'
            ProviderName = 'Microsoft-Windows-MemoryDiagnostics-Results', 'WHEA-Logger'
            StartTime    = (Get-Date).AddDays(-30)
        } -MaxEvents 20 -ErrorAction SilentlyContinue
        
        if ($memoryErrors) {
            $wheaErrors = $memoryErrors | Where-Object { $_.ProviderName -eq 'WHEA-Logger' }
            $diagResults = $memoryErrors | Where-Object { $_.ProviderName -eq 'Microsoft-Windows-MemoryDiagnostics-Results' }
            
            if ($wheaErrors) {
                Add-Finding -Category "Performance" -Check "Hardware Memory Errors (WHEA)" -Status "Fail" `
                    -Message "$($wheaErrors.Count) hardware memory errors detected" `
                    -Details "WHEA errors indicate potential RAM issues" `
                    -Remediation "# Run Windows Memory Diagnostic: mdsched.exe"
            }
            
            if ($diagResults) {
                # Check if any diagnostics found errors
                $errorResults = $diagResults | Where-Object { $_.Message -notmatch 'no errors' }
                if ($errorResults) {
                    Add-Finding -Category "Performance" -Check "Memory Diagnostic Results" -Status "Fail" `
                        -Message "Memory diagnostic found errors" `
                        -Details $errorResults[0].Message.Substring(0, [Math]::Min(200, $errorResults[0].Message.Length)) `
                        -Remediation "# Consider replacing RAM modules"
                } else {
                    Add-Finding -Category "Performance" -Check "Memory Diagnostic Results" -Status "Pass" `
                        -Message "Memory diagnostic passed (no errors)"
                }
            }
        } else {
            Add-Finding -Category "Performance" -Check "Memory Hardware Errors" -Status "Pass" `
                -Message "No memory errors in event log"
        }
    } catch {
        Add-Finding -Category "Performance" -Check "Memory Hardware Errors" -Status "Info" `
            -Message "No memory diagnostic data available"
    }
}
#endregion

#region --- RELIABILITY HISTORY ---
function Get-ReliabilityMetrics {
    Write-Log "Reliability Metrics" -Level SECTION
    
    try {
        $reliability = Get-CimInstance -ClassName Win32_ReliabilityStabilityMetrics -ErrorAction Stop | 
        Sort-Object TimeGenerated -Descending | 
        Select-Object -First 1
        
        if ($reliability) {
            $stabilityIndex = [math]::Round($reliability.SystemStabilityIndex, 1)
            
            $status = if ($stabilityIndex -lt 5) { "Fail" }
            elseif ($stabilityIndex -lt 7) { "Warning" }
            else { "Pass" }
            
            Add-Finding -Category "Performance" -Check "System Stability Index" -Status $status `
                -Message "Stability Index: $stabilityIndex / 10" `
                -Details "Based on Windows Reliability Monitor" `
                -Remediation $(if ($status -ne "Pass") { "# Open Reliability Monitor: perfmon /rel" } else { "" })
        }
        
        # Recent reliability records
        $recentRecords = Get-CimInstance -ClassName Win32_ReliabilityRecords -ErrorAction SilentlyContinue | 
        Where-Object { 
            $_.TimeGenerated -gt (Get-Date).AddDays(-$DaysBack) -and 
            $null -ne $_.EventIdentifier
        }
        
        if ($recentRecords) {
            $appFailures = ($recentRecords | Where-Object { $_.SourceName -match 'Application' }).Count
            $hwFailures = ($recentRecords | Where-Object { $_.SourceName -match 'Hardware|Driver' }).Count
            $winFailures = ($recentRecords | Where-Object { $_.SourceName -match 'Windows' }).Count
            
            if ($appFailures -gt 0 -or $hwFailures -gt 0 -or $winFailures -gt 0) {
                Add-Finding -Category "Performance" -Check "Recent Reliability Events" -Status "Info" `
                    -Message "Last $DaysBack days: $appFailures app, $hwFailures hardware, $winFailures Windows failures" `
                    -Details "View Reliability Monitor for details"
            }
        }
    } catch {
        Add-Finding -Category "Performance" -Check "Reliability Metrics" -Status "Info" `
            -Message "Reliability data not available"
    }
}
#endregion

#region --- POWER SETTINGS ---
function Test-PowerSettings {
    Write-Log "Power Settings Check" -Level SECTION
    
    try {
        # Get active power plan
        $activePlan = powercfg /getactivescheme 2>&1 | Out-String
        
        if ($activePlan -match 'GUID:\s*\S+\s+\((.+)\)') {
            $planName = $matches[1].Trim()
            
            # Check if it's a performance-limiting plan
            $status = if ($planName -match 'Power saver|Battery') { "Warning" }
            elseif ($planName -match 'Balanced') { "Info" }
            else { "Pass" }
            
            $remediation = if ($status -eq "Warning") {
                "powercfg /setactive SCHEME_MIN  # High performance"
            } else { "" }
            
            Add-Finding -Category "Performance" -Check "Active Power Plan" -Status $status `
                -Message "Power Plan: $planName" `
                -Details $(if ($status -eq "Warning") { "Power saver mode may reduce performance" } else { "" }) `
                -Remediation $remediation
        }
        
        # Check for USB selective suspend (can cause device issues)
        $usbSuspend = powercfg /query SCHEME_CURRENT SUB_USB 2>&1 | Out-String
        if ($usbSuspend -match 'USB selective suspend.*Current.*Index:\s*(\w+)' -or $usbSuspend -match '0x00000001') {
            Add-Finding -Category "Performance" -Check "USB Selective Suspend" -Status "Info" `
                -Message "USB selective suspend is enabled" `
                -Details "May cause USB device connectivity issues"
        }
        
        # Check sleep/hibernate settings
        $sleepSettings = powercfg /query SCHEME_CURRENT SUB_SLEEP 2>&1 | Out-String
        
        # Hybrid sleep check
        if ($sleepSettings -match 'Hybrid Sleep.*0x00000001') {
            Add-Finding -Category "Performance" -Check "Hybrid Sleep" -Status "Info" `
                -Message "Hybrid sleep is enabled"
        }
        
    } catch {
        Write-Log "Could not query power settings: $_" -Level WARN
    }
}
#endregion

#region --- PAGE FILE CHECK ---
function Test-PageFileConfiguration {
    Write-Log "Page File Configuration" -Level SECTION
    
    try {
        $pagefile = Get-CimInstance -ClassName Win32_PageFileUsage -ErrorAction SilentlyContinue
        $pagefileSetting = Get-CimInstance -ClassName Win32_PageFileSetting -ErrorAction SilentlyContinue
        $totalRAM = (Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory / 1GB
        
        if ($pagefile) {
            $currentSizeMB = $pagefile.CurrentUsage
            $peakSizeMB = $pagefile.PeakUsage
            $allocatedMB = $pagefile.AllocatedBaseSize
            
            # Check if page file is getting heavily used
            $usagePercent = if ($allocatedMB -gt 0) { [math]::Round(($peakSizeMB / $allocatedMB) * 100, 1) } else { 0 }
            
            $status = if ($usagePercent -gt 90) { "Warning" }
            elseif ($usagePercent -gt 75) { "Info" }
            else { "Pass" }
            
            Add-Finding -Category "Performance" -Check "Page File Usage" -Status $status `
                -Message "Page file: $([math]::Round($allocatedMB/1024, 2)) GB allocated, peak usage $usagePercent%" `
                -Details "Current: $currentSizeMB MB, Peak: $peakSizeMB MB" `
                -Remediation $(if ($status -eq "Warning") { "# Consider increasing page file size or adding RAM" } else { "" })
        }
        
        # Check if page file is system managed
        $autoManaged = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" -Name "PagingFiles" -ErrorAction SilentlyContinue
        
        if ($autoManaged.PagingFiles -match '^\?\\') {
            Add-Finding -Category "Performance" -Check "Page File Management" -Status "Pass" `
                -Message "Page file is system managed"
        } else {
            # Check if size is appropriate
            if ($pagefileSetting) {
                $maxSizeMB = $pagefileSetting.MaximumSize
                $recommendedMin = [math]::Round($totalRAM * 1.5 * 1024)  # 1.5x RAM in MB
                
                if ($maxSizeMB -lt $recommendedMin) {
                    Add-Finding -Category "Performance" -Check "Page File Size" -Status "Warning" `
                        -Message "Page file may be undersized" `
                        -Details "Current max: $([math]::Round($maxSizeMB/1024, 2)) GB, Recommended: $([math]::Round($recommendedMin/1024, 2)) GB" `
                        -Remediation "# Consider setting page file to 1.5x RAM size or enabling system management"
                } else {
                    Add-Finding -Category "Performance" -Check "Page File Size" -Status "Pass" `
                        -Message "Page file size is adequate ($([math]::Round($maxSizeMB/1024, 2)) GB max)"
                }
            }
        }
        
        # Check for page file on multiple drives
        $pagefileLocations = Get-CimInstance -ClassName Win32_PageFileUsage -ErrorAction SilentlyContinue
        if ($pagefileLocations.Count -gt 1) {
            Add-Finding -Category "Performance" -Check "Page File Locations" -Status "Info" `
                -Message "Page file exists on $($pagefileLocations.Count) drives"
        }
        
    } catch {
        Add-Finding -Category "Performance" -Check "Page File" -Status "Info" `
            -Message "Could not query page file configuration"
    }
}
#endregion

#region --- SECURITY POSTURE ---
function Test-SecurityPosture {
    Write-Log "Security Posture Check" -Level SECTION
    
    # Check for third-party antivirus first
    $thirdPartyAV = $null
    try {
        $avProducts = Get-CimInstance -Namespace "root/SecurityCenter2" -ClassName "AntivirusProduct" -ErrorAction SilentlyContinue
        $thirdPartyAV = $avProducts | Where-Object { $_.displayName -notmatch "Windows Defender|Microsoft Defender" }
        
        if ($thirdPartyAV) {
            # Deduplicate by displayName - SecurityCenter2 can return multiple entries for same product
            $uniqueAV = $thirdPartyAV | Group-Object displayName | ForEach-Object { $_.Group | Select-Object -First 1 }
            
            foreach ($av in $uniqueAV) {
                # productState is a bitmap: bits 4-7 = AV state, bits 8-11 = up-to-date state
                # State 0x10 = enabled, 0x00 = disabled; Update 0x00 = up-to-date, 0x10 = out-of-date
                $state = [int]$av.productState
                $enabled = (($state -band 0x1000) -ne 0)
                $upToDate = (($state -band 0x10) -eq 0)
                
                $status = if ($enabled) { "Pass" } else { "Warning" }
                Add-Finding -Category "Security" -Check "Third-Party Antivirus" -Status $status `
                    -Message "$($av.displayName): $(if ($enabled) { 'Active' } else { 'Inactive' })" `
                    -Details "Definitions: $(if ($upToDate) { 'Up-to-date' } else { 'Out-of-date' })"
            }
        }
    } catch {
        # SecurityCenter2 not available (Server OS)
    }
    
    # Windows Defender Status
    try {
        $defenderStatus = Get-MpComputerStatus -ErrorAction Stop
        
        # Real-time Protection - if third-party AV is active, Defender being off is expected
        if ($defenderStatus.RealTimeProtectionEnabled) {
            Add-Finding -Category "Security" -Check "Defender Real-time Protection" -Status "Pass" `
                -Message "Real-time protection: Enabled"
        } elseif ($thirdPartyAV) {
            # Third-party AV detected, Defender off is expected
            Add-Finding -Category "Security" -Check "Defender Real-time Protection" -Status "Info" `
                -Message "Real-time protection: Disabled (Third-party AV active)"
        } else {
            # No third-party AV, Defender off is a problem
            Add-Finding -Category "Security" -Check "Defender Real-time Protection" -Status "Fail" `
                -Message "Real-time protection: Disabled" `
                -Remediation "Set-MpPreference -DisableRealtimeMonitoring `$false"
        }
        
        # Definition Age (only relevant if Defender is active or no third-party AV)
        if ($defenderStatus.RealTimeProtectionEnabled -or -not $thirdPartyAV) {
            $defAge = (New-TimeSpan -Start $defenderStatus.AntivirusSignatureLastUpdated -End (Get-Date)).Days
            $status = if ($defAge -gt 7) { "Fail" } elseif ($defAge -gt 3) { "Warning" } else { "Pass" }
            Add-Finding -Category "Security" -Check "Defender Definitions" -Status $status `
                -Message "Definitions updated $defAge days ago" `
                -Remediation $(if ($status -ne "Pass") { "Update-MpSignature" } else { "" })
        }
        
        # Quick Scan Age (only if Defender is the primary AV)
        if ($defenderStatus.RealTimeProtectionEnabled) {
            $scanAge = (New-TimeSpan -Start $defenderStatus.QuickScanEndTime -End (Get-Date)).Days
            $status = if ($scanAge -gt 14) { "Warning" } else { "Pass" }
            Add-Finding -Category "Security" -Check "Defender Last Scan" -Status $status `
                -Message "Last scan: $scanAge days ago" `
                -Remediation $(if ($status -eq "Warning") { "Start-MpScan -ScanType QuickScan" } else { "" })
        }
        
    } catch {
        if ($thirdPartyAV) {
            Add-Finding -Category "Security" -Check "Windows Defender" -Status "Info" `
                -Message "Windows Defender managed by third-party AV ($($thirdPartyAV[0].displayName))"
        } else {
            Add-Finding -Category "Security" -Check "Windows Defender" -Status "Warning" `
                -Message "Windows Defender status not available"
        }
    }
    
    # Firewall Status
    try {
        $fwProfiles = Get-NetFirewallProfile -ErrorAction SilentlyContinue
        
        foreach ($fwProfile in $fwProfiles) {
            $status = if ($fwProfile.Enabled) { "Pass" } else { "Warning" }
            Add-Finding -Category "Security" -Check "Firewall ($($fwProfile.Name))" -Status $status `
                -Message "Firewall $($fwProfile.Name) profile: $(if ($fwProfile.Enabled) { 'Enabled' } else { 'Disabled' })" `
                -Remediation $(if ($status -eq "Warning") { "Set-NetFirewallProfile -Profile $($fwProfile.Name) -Enabled True" } else { "" })
        }
    } catch {
        Add-Finding -Category "Security" -Check "Windows Firewall" -Status "Info" `
            -Message "Could not query firewall status"
    }
    
    # UAC Status
    try {
        $uacKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
        $enableLUA = (Get-ItemProperty -Path $uacKey -Name "EnableLUA" -ErrorAction SilentlyContinue).EnableLUA
        
        $status = if ($enableLUA -eq 1) { "Pass" } else { "Fail" }
        Add-Finding -Category "Security" -Check "UAC Status" -Status $status `
            -Message "User Account Control: $(if ($enableLUA -eq 1) { 'Enabled' } else { 'Disabled' })" `
            -Remediation $(if ($status -eq "Fail") { "# Enable UAC via: Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'EnableLUA' -Value 1" } else { "" })
    } catch {
        # Ignore
    }
    
    # BitLocker Status (if applicable)
    try {
        $bitlocker = Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue
        
        if ($bitlocker) {
            $status = if ($bitlocker.ProtectionStatus -eq 'On') { "Pass" } else { "Info" }
            Add-Finding -Category "Security" -Check "BitLocker (C:)" -Status $status `
                -Message "BitLocker: $($bitlocker.ProtectionStatus)" `
                -Details "Encryption: $($bitlocker.EncryptionPercentage)%"
        }
    } catch {
        # BitLocker not available or not enabled
    }
}
#endregion

#region --- HTML REPORT GENERATION ---
function New-HealthReport {
    param(
        [hashtable]$Results,
        [object]$SystemInfo,
        [object]$RestartStatus,
        [string]$OutputPath
    )
    
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $reportPath = Join-Path $OutputPath "PCHealthCheck-$env:COMPUTERNAME-$timestamp.html"
    
    # Calculate summary
    $allFindings = $Results.Values | ForEach-Object { $_ }
    $passCount = ($allFindings | Where-Object { $_.Status -eq 'Pass' }).Count
    $warnCount = ($allFindings | Where-Object { $_.Status -eq 'Warning' }).Count
    $failCount = ($allFindings | Where-Object { $_.Status -eq 'Fail' }).Count
    $infoCount = ($allFindings | Where-Object { $_.Status -eq 'Info' }).Count
    $skipCount = ($allFindings | Where-Object { $_.Status -eq 'Skipped' }).Count
    
    $overallStatus = if ($failCount -gt 0) { "Issues Found" }
    elseif ($warnCount -gt 0) { "Warnings" }
    else { "Healthy" }
    
    $statusColor = if ($failCount -gt 0) { "#dc3545" }
    elseif ($warnCount -gt 0) { "#ffc107" }
    else { "#28a745" }
    
    $runtime = (New-TimeSpan -Start $script:StartTime -End (Get-Date)).ToString("mm\:ss")
    
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>PC Health Check - $env:COMPUTERNAME</title>
    <style>
        :root {
            --pass: #28a745;
            --warn: #ffc107;
            --fail: #dc3545;
            --info: #17a2b8;
            --skip: #6c757d;
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background: #f5f5f5; color: #333; line-height: 1.6; }
        .container { max-width: 1200px; margin: 0 auto; padding: 20px; }
        header { background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%); color: white; padding: 30px; border-radius: 10px; margin-bottom: 20px; }
        header h1 { font-size: 2em; margin-bottom: 10px; }
        .header-info { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 15px; margin-top: 20px; }
        .header-info div { background: rgba(255,255,255,0.1); padding: 10px 15px; border-radius: 5px; }
        .header-info label { font-size: 0.8em; opacity: 0.8; display: block; }
        .header-info span { font-size: 1.1em; font-weight: 600; }
        .summary { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 15px; margin-bottom: 20px; }
        .summary-card { background: white; padding: 20px; border-radius: 10px; text-align: center; box-shadow: 0 2px 5px rgba(0,0,0,0.1); }
        .summary-card.overall { background: $statusColor; color: white; }
        .summary-card h3 { font-size: 2em; margin-bottom: 5px; }
        .summary-card p { font-size: 0.9em; opacity: 0.9; }
        .toc { background: white; padding: 20px; border-radius: 10px; margin-bottom: 20px; box-shadow: 0 2px 5px rgba(0,0,0,0.1); }
        .toc h2 { margin-bottom: 15px; color: #1a1a2e; }
        .toc ul { list-style: none; display: flex; flex-wrap: wrap; gap: 10px; }
        .toc a { display: inline-block; padding: 8px 15px; background: #e9ecef; border-radius: 5px; text-decoration: none; color: #333; transition: all 0.2s; }
        .toc a:hover { background: #1a1a2e; color: white; }
        .category { background: white; padding: 20px; border-radius: 10px; margin-bottom: 20px; box-shadow: 0 2px 5px rgba(0,0,0,0.1); }
        .category h2 { color: #1a1a2e; border-bottom: 2px solid #e9ecef; padding-bottom: 10px; margin-bottom: 15px; }
        table { width: 100%; border-collapse: collapse; }
        th, td { padding: 12px; text-align: left; border-bottom: 1px solid #e9ecef; }
        th { background: #f8f9fa; font-weight: 600; }
        .status { display: inline-block; padding: 3px 10px; border-radius: 20px; font-size: 0.85em; font-weight: 600; }
        .status.Pass { background: #d4edda; color: #155724; }
        .status.Warning { background: #fff3cd; color: #856404; }
        .status.Fail { background: #f8d7da; color: #721c24; }
        .status.Info { background: #d1ecf1; color: #0c5460; }
        .status.Skipped { background: #e2e3e5; color: #383d41; }
        .remediation { background: #2d2d2d; color: #f8f8f2; padding: 15px; border-radius: 5px; margin-top: 20px; font-family: 'Consolas', monospace; font-size: 0.9em; white-space: pre-wrap; word-break: break-all; }
        .remediation h3 { color: #66d9ef; margin-bottom: 10px; }
        .remediation code { display: block; padding: 5px 0; border-bottom: 1px solid #444; position: relative; }
        .restart-warning { background: #fff3cd; border: 2px solid #ffc107; padding: 15px; border-radius: 10px; margin-bottom: 20px; }
        .restart-warning h3 { color: #856404; }
        footer { text-align: center; padding: 20px; color: #666; font-size: 0.9em; }
        /* TOC badges */
        .toc-badge { display: inline-block; font-size: 0.75em; padding: 2px 6px; border-radius: 10px; margin-left: 5px; font-weight: 600; }
        .toc-badge.fail { background: var(--fail); color: white; }
        .toc-badge.warn { background: var(--warn); color: #333; }
        .toc-badge.pass { background: var(--pass); color: white; }
        /* Collapsible sections */
        .category-header { display: flex; justify-content: space-between; align-items: center; cursor: pointer; user-select: none; }
        .category-header:hover { opacity: 0.8; }
        .collapse-btn { background: none; border: none; font-size: 1.2em; cursor: pointer; padding: 5px 10px; transition: transform 0.2s; }
        .category.collapsed .collapse-btn { transform: rotate(-90deg); }
        .category.collapsed table { display: none; }
        /* Copy button */
        .copy-btn { background: #4a4a4a; border: 1px solid #666; color: #f8f8f2; padding: 4px 10px; border-radius: 3px; cursor: pointer; font-size: 0.8em; float: right; margin-top: -5px; transition: all 0.2s; }
        .copy-btn:hover { background: #666; }
        .copy-btn.copied { background: var(--pass); border-color: var(--pass); }
        .cmd-wrapper { position: relative; margin-bottom: 10px; }
        @media (max-width: 768px) {
            .header-info { grid-template-columns: 1fr 1fr; }
            .summary { grid-template-columns: repeat(3, 1fr); }
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>&#x1F3E5; PC Health Check Report</h1>
            <div class="header-info">
                <div><label>Computer</label><span>$($SystemInfo.ComputerName)</span></div>
                <div><label>OS</label><span>$($SystemInfo.OSName) $($SystemInfo.OSBuild)</span></div>
                <div><label>Model</label><span>$($SystemInfo.Manufacturer) $($SystemInfo.Model)</span></div>
                <div><label>Memory</label><span>$($SystemInfo.TotalMemoryGB) GB</span></div>
                <div><label>Uptime</label><span>$($SystemInfo.Uptime)</span></div>
                <div><label>Scan Mode</label><span>$Mode</span></div>
                <div><label>Scan Time</label><span>$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</span></div>
                <div><label>Duration</label><span>$runtime</span></div>
            </div>
        </header>
"@

    # Pending restart warning
    if ($RestartStatus.PendingRestart) {
        $html += @"
        <div class="restart-warning">
            <h3>&#x26A0;&#xFE0F; System Restart Required</h3>
            <p>A system restart is pending for: $($RestartStatus.Reasons -join ', ')</p>
            <p>Some checks may not reflect the current system state until after restart.</p>
        </div>
"@
    }

    # Summary cards
    $html += @"
        <div class="summary">
            <div class="summary-card overall">
                <h3>$overallStatus</h3>
                <p>Overall Status</p>
            </div>
            <div class="summary-card">
                <h3 style="color: var(--pass);">$passCount</h3>
                <p>Passed</p>
            </div>
            <div class="summary-card">
                <h3 style="color: var(--warn);">$warnCount</h3>
                <p>Warnings</p>
            </div>
            <div class="summary-card">
                <h3 style="color: var(--fail);">$failCount</h3>
                <p>Failed</p>
            </div>
            <div class="summary-card">
                <h3 style="color: var(--info);">$infoCount</h3>
                <p>Info</p>
            </div>
            <div class="summary-card">
                <h3 style="color: var(--skip);">$skipCount</h3>
                <p>Skipped</p>
            </div>
        </div>
"@

    # Table of Contents - sorted by severity (categories with issues first)
    $categoryStats = @{}
    foreach ($category in $Results.Keys) {
        $findings = $Results[$category]
        $categoryStats[$category] = @{
            FailCount  = ($findings | Where-Object { $_.Status -eq 'Fail' }).Count
            WarnCount  = ($findings | Where-Object { $_.Status -eq 'Warning' }).Count
            PassCount  = ($findings | Where-Object { $_.Status -eq 'Pass' }).Count
            TotalCount = $findings.Count
        }
    }
    
    # Sort: Fail > Warning > Pass
    $sortedCategories = $Results.Keys | Sort-Object { 
        $stats = $categoryStats[$_]
        # Primary sort: has failures (descending), then warnings, then alphabetical
        $priority = 0
        if ($stats.FailCount -gt 0) { $priority = 1000 + $stats.FailCount }
        elseif ($stats.WarnCount -gt 0) { $priority = 500 + $stats.WarnCount }
        - $priority  # Negative for descending sort
    }, { $_ }  # Then alphabetically
    
    $html += @"
        <div class="toc">
            <h2>&#x1F4CB; Categories</h2>
            <ul>
"@
    foreach ($category in $sortedCategories) {
        $stats = $categoryStats[$category]
        $badge = ""
        if ($stats.FailCount -gt 0) {
            $badge = "<span class='toc-badge fail'>$($stats.FailCount) fail</span>"
        } elseif ($stats.WarnCount -gt 0) {
            $badge = "<span class='toc-badge warn'>$($stats.WarnCount) warn</span>"
        } else {
            $badge = "<span class='toc-badge pass'>&#x2713;</span>"
        }
        $html += "                <li><a href=`"#$category`">$category$badge</a></li>`n"
    }
    $html += @"
            </ul>
        </div>
"@

    # Category sections - use same sorted order
    foreach ($category in $sortedCategories) {
        $findings = $Results[$category]
        $stats = $categoryStats[$category]
        
        # Determine category status badge
        $catBadge = ""
        if ($stats.FailCount -gt 0) {
            $catBadge = "<span class='toc-badge fail'>$($stats.FailCount) issues</span>"
        } elseif ($stats.WarnCount -gt 0) {
            $catBadge = "<span class='toc-badge warn'>$($stats.WarnCount) warnings</span>"
        }
        
        $html += @"
        <div class="category" id="$category">
            <div class="category-header" onclick="toggleCategory(this)">
                <h2>$category $catBadge</h2>
                <button class="collapse-btn" title="Collapse/Expand">&#x25BC;</button>
            </div>
            <table>
                <tr>
                    <th style="width: 25%;">Check</th>
                    <th style="width: 10%;">Status</th>
                    <th style="width: 35%;">Message</th>
                    <th style="width: 30%;">Details</th>
                </tr>
"@
        foreach ($finding in $findings) {
            $html += @"
                <tr>
                    <td>$($finding.Check)</td>
                    <td><span class="status $($finding.Status)">$($finding.Status)</span></td>
                    <td>$($finding.Message)</td>
                    <td>$($finding.Details)</td>
                </tr>
"@
        }
        $html += @"
            </table>
        </div>
"@
    }

    # Remediation Commands
    if ($script:RemediationCommands.Count -gt 0) {
        $html += @"
        <div class="remediation">
            <h3>&#x1F527; Remediation Commands</h3>
            <p>Copy and run these commands to address identified issues:</p>
"@
        foreach ($cmd in $script:RemediationCommands) {
            $html += "<code># $($cmd.Category) - $($cmd.Check)`n$($cmd.Command)</code>`n"
        }
        $html += "</div>"
    }

    # Footer with JavaScript
    $html += @"
        <footer>
            <p>Generated by PCHealthCheck.ps1 v1.3.1 | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
            <p>Run as Administrator: $($script:IsAdmin) | PowerShell: $($PSVersionTable.PSVersion)</p>
        </footer>
    </div>
    <script>
        function toggleCategory(header) {
            const category = header.parentElement;
            category.classList.toggle('collapsed');
        }
        
        
        // Collapse all passing categories by default
        document.addEventListener('DOMContentLoaded', function() {
            document.querySelectorAll('.category').forEach(cat => {
                const hasFail = cat.querySelector('.status.Fail');
                const hasWarn = cat.querySelector('.status.Warning');
                if (!hasFail && !hasWarn) {
                    cat.classList.add('collapsed');
                }
            });
        });
    </script>
</body>
</html>
"@

    $html | Out-File -FilePath $reportPath -Encoding UTF8
    Write-Log "Report saved to: $reportPath" -Level OK
    
    return $reportPath
}
#endregion

#region --- MAIN EXECUTION ---
Write-Log "PC Health Check Started" -Level SECTION
Write-Log "Mode: $Mode | Categories: $($script:CategoriesToRun -join ', ')"
Write-Log "Running as Administrator: $($script:IsAdmin)"

# Collect system info
$sysInfo = Get-SystemInfo

# Check pending restart
$restartStatus = Test-PendingRestart

# Check BIOS/Firmware
Get-BIOSInfo

# Run selected categories
foreach ($category in $script:CategoriesToRun) {
    switch ($category) {
        "SystemFiles" { Test-SystemFileIntegrity }
        "Disk" { Test-DiskHealth }
        "EventLog" { Get-EventLogIssues }
        "WindowsUpdate" { Test-WindowsUpdateHealth }
        "Performance" { 
            Get-PerformanceBaseline
            Test-MemoryDiagnostics
            Get-ReliabilityMetrics
            Test-PowerSettings
            Test-PageFileConfiguration
        }
        "Startup" { Get-StartupImpact }
        "Network" { Test-NetworkHealth }
        "Cleanup" { Get-CleanupOpportunities }
        "Security" { Test-SecurityPosture }
        "Drivers" { Test-DriverHealth }
    }
}

# Generate report
$reportPath = New-HealthReport -Results $script:Results -SystemInfo $sysInfo -RestartStatus $restartStatus -OutputPath $OutputPath

# Export CSV if requested
$csvPath = $null
if ($ExportCsv) {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $csvPath = Join-Path $OutputPath "PCHealthCheck-$env:COMPUTERNAME-$timestamp.csv"
    
    $csvData = foreach ($category in $script:Results.Keys) {
        foreach ($finding in $script:Results[$category]) {
            [PSCustomObject]@{
                ComputerName = $env:COMPUTERNAME
                ScanTime     = $script:StartTime.ToString('yyyy-MM-dd HH:mm:ss')
                Category     = $category
                Check        = $finding.Check
                Status       = $finding.Status
                Message      = $finding.Message
                Details      = $finding.Details
                Remediation  = $finding.Remediation
            }
        }
    }
    
    $csvData | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    Write-Log "CSV exported to: $csvPath" -Level OK
}

# Export JSON if requested
$jsonPath = $null
if ($ExportJson) {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $jsonPath = Join-Path $OutputPath "PCHealthCheck-$env:COMPUTERNAME-$timestamp.json"
    
    $jsonData = [ordered]@{
        ComputerName        = $env:COMPUTERNAME
        ScanTime            = $script:StartTime.ToString('yyyy-MM-dd HH:mm:ss')
        ScanMode            = $Mode
        IsAdmin             = $script:IsAdmin
        PendingRestart      = $restartStatus.PendingRestart
        SystemInfo          = [ordered]@{
            OSName        = $sysInfo.OSName
            OSVersion     = $sysInfo.OSVersion
            OSBuild       = $sysInfo.OSBuild
            Manufacturer  = $sysInfo.Manufacturer
            Model         = $sysInfo.Model
            SerialNumber  = $sysInfo.SerialNumber
            TotalMemoryGB = $sysInfo.TotalMemoryGB
            Uptime        = $sysInfo.Uptime
        }
        Summary             = [ordered]@{
            PassCount    = ($script:Results.Values | ForEach-Object { $_ } | Where-Object { $_.Status -eq 'Pass' }).Count
            WarningCount = ($script:Results.Values | ForEach-Object { $_ } | Where-Object { $_.Status -eq 'Warning' }).Count
            FailCount    = ($script:Results.Values | ForEach-Object { $_ } | Where-Object { $_.Status -eq 'Fail' }).Count
            InfoCount    = ($script:Results.Values | ForEach-Object { $_ } | Where-Object { $_.Status -eq 'Info' }).Count
            SkippedCount = ($script:Results.Values | ForEach-Object { $_ } | Where-Object { $_.Status -eq 'Skipped' }).Count
        }
        Categories          = @{}
        RemediationCommands = @()
    }
    
    # Add findings by category
    foreach ($category in $script:Results.Keys | Sort-Object) {
        $jsonData.Categories[$category] = @(
            foreach ($finding in $script:Results[$category]) {
                [ordered]@{
                    Check       = $finding.Check
                    Status      = $finding.Status
                    Message     = $finding.Message
                    Details     = $finding.Details
                    Remediation = $finding.Remediation
                }
            }
        )
    }
    
    # Add remediation commands
    $jsonData.RemediationCommands = @(
        foreach ($cmd in $script:RemediationCommands) {
            [ordered]@{
                Category = $cmd.Category
                Check    = $cmd.Check
                Command  = $cmd.Command
            }
        }
    )
    
    $jsonData | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8
    Write-Log "JSON exported to: $jsonPath" -Level OK
}

# Summary
$endTime = Get-Date
$duration = New-TimeSpan -Start $script:StartTime -End $endTime

Write-Log "Health Check Complete" -Level SECTION
Write-Log "Duration: $($duration.ToString('mm\:ss'))"
Write-Log "Report: $reportPath"
if ($csvPath) { Write-Log "CSV: $csvPath" }
if ($jsonPath) { Write-Log "JSON: $jsonPath" }
#endregion
