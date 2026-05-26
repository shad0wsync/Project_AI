#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Applies HPE MSA Best Practices and fixes iSCSI Multipathing on a Hyper-V Host.
.DESCRIPTION
    1. Validates Hyper-V role and cluster safety (ClusSvc must be stopped on cluster nodes).
    2. Installs/Configures MPIO with HPE-specific timers; smart device claim detection (skips reboot if already claimed).
    3. Disconnects iSCSI sessions for the specified target IPs only.
    4. Re-maps iSCSI into a full mesh (Local NICs -> All Target IPs).
    5. Rescans storage (Update-HostStorageCache) for accurate MPIO path enumeration.
    6. Validates session count and MPIO paths.
.PARAMETER TargetIPs
    Array of MSA Controller iSCSI target portal IP addresses.
.PARAMETER NicNames
    Array of iSCSI NIC interface aliases as shown in Network Connections.
.PARAMETER DeviceString
    MPIO device claim string. Default: 'HPE     MSA 2060'
.PARAMETER AutoReboot
    Schedule a reboot 60 seconds after completion (for RMM use).
.PARAMETER SkipTimers
    Skip MPIO timer configuration. MPIO install and device claim still apply.
.PARAMETER Force
    Skip the interactive DRAINED confirmation prompt.
.PARAMETER Quiet
    Suppress console output (RMM silent mode). Log file is still written.
.PARAMETER NinjaCustomField
    NinjaRMM text custom field name to write summary result.
.EXAMPLE
    .\Repair-MSAMultipath.ps1 -TargetIPs "192.168.77.11","192.168.77.14" -NicNames "iSCSI Port 1","iSCSI Port 2"
.EXAMPLE
    .\Repair-MSAMultipath.ps1 -TargetIPs "10.0.5.11","10.0.5.14" -NicNames "SAN1","SAN2" -Force -AutoReboot
.EXAMPLE
    .\Repair-MSAMultipath.ps1 -TargetIPs "10.0.5.11","10.0.5.14" -NicNames "SAN1","SAN2" -Force -Quiet -NinjaCustomField "msaRepairStatus"
.NOTES
    Script  : Repair-MSAMultipath.ps1
    Author  : Jeff Davidson
    Version : 1.3.0
    Date    : 2026-03-12
    Output  : C:\Temp\Repair-MSAMultipath\
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateCount(1, 16)]
    [string[]]$TargetIPs,

    [Parameter(Mandatory)]
    [ValidateCount(1, 8)]
    [string[]]$NicNames,

    [string]$DeviceString = 'HPE     MSA 2060',

    [switch]$AutoReboot,

    [switch]$SkipTimers,

    [switch]$Force,

    [switch]$Quiet,

    [string]$NinjaCustomField
)

# --- INIT ---
$script:OutputPath = 'C:\Temp\Repair-MSAMultipath'
if (-not (Test-Path $script:OutputPath)) { New-Item -Path $script:OutputPath -ItemType Directory -Force | Out-Null }
$script:LogFile = Join-Path $script:OutputPath "Repair-MSAMultipath_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$script:ExitCode = 0
$script:RebootRequired = $false
$script:Summary = [System.Collections.Generic.List[string]]::new()

function Write-Log {
    param([string]$Message, [ValidateSet('Info','Warning','Error')][string]$Level = 'Info')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$ts] [$Level] $Message"
    Add-Content -Path $script:LogFile -Value $entry
    if (-not $Quiet) {
        switch ($Level) {
            'Error'   { Write-Host "  $Message" -ForegroundColor Red }
            'Warning' { Write-Host "  $Message" -ForegroundColor Yellow }
            default   { Write-Host "  $Message" -ForegroundColor Cyan }
        }
    }
}

function Get-TargetSessionsByIP {
    # Server 2025 removed TargetAddress from Get-IscsiSession.
    # Fall back to matching via Get-IscsiConnection which has TargetAddress.
    param([string[]]$IPs)
    $sessions = Get-IscsiSession -ErrorAction SilentlyContinue
    if (-not $sessions) { return @() }

    $sample = $sessions | Select-Object -First 1
    if ($sample.PSObject.Properties.Name -contains 'TargetAddress') {
        return @($sessions | Where-Object { $_.TargetAddress -in $IPs })
    }

    # Server 2025: match via connection objects
    $matched = [System.Collections.Generic.List[object]]::new()
    foreach ($s in $sessions) {
        $conns = $s | Get-IscsiConnection -ErrorAction SilentlyContinue
        if ($conns | Where-Object { $_.TargetAddress -in $IPs }) {
            $matched.Add($s)
        }
    }
    return @($matched)
}

# --- INPUT VALIDATION ---
foreach ($ip in $TargetIPs) {
    if (-not ($ip -as [System.Net.IPAddress])) {
        Write-Error "Invalid IP address: '$ip'"
        exit 1
    }
}

# Verify Hyper-V role
if (-not (Get-WindowsFeature Hyper-V -ErrorAction SilentlyContinue).Installed) {
    Write-Error 'Hyper-V role is not installed. This script targets Hyper-V hosts.'
    exit 20
}

# Cluster safety -- ClusSvc must be stopped before running on cluster nodes
$clusSvc = Get-Service ClusSvc -ErrorAction SilentlyContinue
if ($clusSvc -and $clusSvc.Status -eq 'Running') {
    Write-Error @"
Failover Cluster service is running. Before running this script:
  1. Drain this node (Pause -> Drain Roles)
  2. Stop the Cluster service: Stop-Service ClusSvc -Force
  3. Run this script
  4. Reboot, then rejoin the cluster
"@
    exit 20
}
if ($clusSvc) {
    Write-Host 'Cluster service detected but stopped -- OK to proceed.' -ForegroundColor Green
}

# Validate NIC names exist before destructive phase
foreach ($nic in $NicNames) {
    if (-not (Get-NetAdapter -Name $nic -ErrorAction SilentlyContinue)) {
        Write-Error "Network adapter '$nic' not found. Check interface names in Network Connections."
        exit 1
    }
}

# --- SAFETY CHECKS ---
Write-Log "Running on: $env:COMPUTERNAME"
Write-Log "Target IPs: $($TargetIPs -join ', ')"
Write-Log "NIC Names: $($NicNames -join ', ')"

if (-not $Force) {
    Write-Host "`nCRITICAL: This script will disconnect storage. Ensure this node is DRAINED (No VMs running)." -ForegroundColor Red
    $conf = Read-Host "Type 'DRAINED' to proceed"
    if ($conf -ne 'DRAINED') {
        Write-Log 'User aborted -- DRAINED confirmation not provided.' -Level Error
        exit 1
    }
}

# --- PHASE 1: MPIO CONFIGURATION ---
Write-Log '[1/3] Configuring MPIO...'

# Install Feature
if ($PSCmdlet.ShouldProcess('Multipath-IO', 'Install Windows Feature')) {
    if (-not (Get-WindowsFeature Multipath-IO).Installed) {
        Install-WindowsFeature Multipath-IO | Out-Null
        Write-Log 'MPIO feature installed -- reboot required.'
        $script:RebootRequired = $true
    } else {
        Write-Log 'MPIO feature already installed.'
    }
}

# Set HPE MSA Best Practice Timers (Reference: HPE MSA Gen6 Implementation Guide)
# Note: HPE recommends DiskTimeout=120, RetryInterval=2 but some OS versions
# cap DiskTimeout at 100 and enforce RetryInterval minimum of 3.
if ($SkipTimers) {
    Write-Log 'Skipping MPIO timer configuration (-SkipTimers).'
} elseif ($PSCmdlet.ShouldProcess('MPIO Settings', 'Apply HPE MSA best-practice timers')) {
    $mpioParams = @(
        @{ NewDiskTimeout = 100 }
        @{ NewRetryInterval = 3 }
        @{ NewRetryCount = 6 }
        @{ NewPathVerificationState = 'Enabled' }
        @{ NewPathVerificationPeriod = 10 }
    )
    # CustomPathRecovery param does not exist on all OS versions
    $setMpioParams = (Get-Command Set-MPIOSetting -ErrorAction SilentlyContinue).Parameters
    if ($setMpioParams -and $setMpioParams.ContainsKey('CustomPathRecovery')) {
        $mpioParams += @{ CustomPathRecovery = 'Enabled'; NewCustomPathRecoveryTime = 20 }
    }
    foreach ($p in $mpioParams) {
        try { Set-MPIOSetting @p -ErrorAction Stop }
        catch { Write-Log "MPIO setting failed: $($_.Exception.Message)" -Level Warning }
    }
    Write-Log 'MPIO timers applied.'
}

# Claim Device (smart detection -- skip reboot if already claimed)
if ($PSCmdlet.ShouldProcess($DeviceString, 'MPIO device claim (mpclaim)')) {
    if (Get-Command mpclaim -ErrorAction SilentlyContinue) {
        $claimedDevices = mpclaim -s -d 2>$null
        $alreadyClaimed = $claimedDevices | Where-Object { $_ -match [regex]::Escape($DeviceString) }
        if ($alreadyClaimed) {
            Write-Log "Device already claimed: $DeviceString -- no reboot needed for claim."
        } else {
            $null = mpclaim -n -I -d $DeviceString 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Log "Device claimed: $DeviceString -- reboot required."
                $script:RebootRequired = $true
            } else {
                Write-Log "mpclaim returned exit code $LASTEXITCODE for '$DeviceString'" -Level Warning
            }
        }
    } else {
        Write-Log 'mpclaim not found on this system -- skipping device claim.' -Level Warning
    }
}

# --- PHASE 2: iSCSI REMAPPING ---
Write-Log '[2/3] Remapping iSCSI Mesh...'

# 2a. Get Local IPs dynamically
$LocalPortals = @()
foreach ($nic in $NicNames) {
    try {
        $ip = (Get-NetIPAddress -InterfaceAlias $nic -AddressFamily IPv4 -ErrorAction Stop).IPAddress
        $LocalPortals += $ip
        Write-Log "Found local IP for '$nic': $ip"
    } catch {
        Write-Log "Interface '$nic' not found or has no IPv4 address. Skipping." -Level Warning
    }
}

if ($LocalPortals.Count -eq 0) {
    Write-Log 'No valid iSCSI NICs found. Cannot continue.' -Level Error
    exit 20
}

# 2b. Clear Sessions for Target IPs Only (preserves unrelated iSCSI storage)
if ($PSCmdlet.ShouldProcess("iSCSI sessions for $($TargetIPs -join ', ')", 'Disconnect')) {
    $allSessions = Get-IscsiSession -ErrorAction SilentlyContinue
    $targetSessions = @(Get-TargetSessionsByIP -IPs $TargetIPs)
    $otherCount = ($allSessions | Measure-Object).Count - $targetSessions.Count
    if ($otherCount -gt 0) {
        Write-Log "$otherCount session(s) to other targets will be preserved."
    }
    if ($targetSessions.Count -gt 0) {
        Write-Log "Disconnecting $($targetSessions.Count) session(s) for target IPs..."
        try {
            if (Get-Command Disconnect-IscsiSession -ErrorAction SilentlyContinue) {
                $targetSessions | Disconnect-IscsiSession -ErrorAction Stop -Confirm:$false
            } else {
                # Server 2025: Disconnect-IscsiSession removed, use Disconnect-IscsiTarget per IQN
                $targetIQNs = @($targetSessions | Select-Object -ExpandProperty TargetNodeAddress -Unique)
                foreach ($iqn in $targetIQNs) {
                    Disconnect-IscsiTarget -NodeAddress $iqn -Confirm:$false -ErrorAction Stop
                }
            }
        } catch {
            Write-Log "Session disconnect error: $($_.Exception.Message)" -Level Error
            exit 20
        }
        # Verify target sessions cleared
        $remaining = @(Get-TargetSessionsByIP -IPs $TargetIPs).Count
        if ($remaining -gt 0) {
            Write-Log "$remaining target session(s) still active after disconnect. Aborting." -Level Error
            exit 20
        }
        Write-Log 'Target sessions disconnected.'
    } else {
        Write-Log 'No existing sessions for the specified target IPs.'
    }
}

# 2c. Build the Mesh (Every Local IP -> Every Target IP)
# Server 2025 removed -TargetPortalAddress from iSCSI cmdlets -- detect once
$script:HasPortalParam = @{}
foreach ($cmd in 'New-IscsiTargetPortal', 'Get-IscsiTarget', 'Connect-IscsiTarget') {
    $script:HasPortalParam[$cmd] = (Get-Command $cmd -ErrorAction SilentlyContinue).Parameters.ContainsKey('TargetPortalAddress')
}

if ($PSCmdlet.ShouldProcess("$($LocalPortals.Count) NICs x $($TargetIPs.Count) targets", 'Connect iSCSI mesh')) {
    Write-Log 'Connecting mesh...'
    $meshOK = 0; $meshFail = 0
    foreach ($SourceIP in $LocalPortals) {
        foreach ($TargetIP in $TargetIPs) {
            # Create Portal (if missing)
            $portalParams = @{ InitiatorPortalAddress = $SourceIP; ErrorAction = 'SilentlyContinue' }
            if ($script:HasPortalParam['New-IscsiTargetPortal']) {
                $portalParams['TargetPortalAddress'] = $TargetIP
            } else {
                $portalParams['TargetPortalAddress'] = $TargetIP  # Primary param -- always required
            }
            New-IscsiTargetPortal @portalParams | Out-Null

            # Connect each target IQN presented on this portal
            try {
                if ($script:HasPortalParam['Get-IscsiTarget']) {
                    $targets = @(Get-IscsiTarget -TargetPortalAddress $TargetIP -ErrorAction Stop)
                } else {
                    $targets = @(Get-IscsiTarget -ErrorAction Stop)
                }
                foreach ($t in $targets) {
                    $connectParams = @{
                        NodeAddress            = $t.NodeAddress
                        InitiatorPortalAddress = $SourceIP
                        IsPersistent           = $true
                        IsMultipathEnabled     = $true
                        ErrorAction            = 'Stop'
                    }
                    if ($script:HasPortalParam['Connect-IscsiTarget']) {
                        $connectParams['TargetPortalAddress'] = $TargetIP
                    }
                    Connect-IscsiTarget @connectParams | Out-Null
                    Write-Log "[OK] $SourceIP -> $TargetIP ($($t.NodeAddress))"
                    $meshOK++
                }
            } catch {
                if ($_.Exception.Message -match 'already.*log|already.*connect|already exists') {
                    Write-Log "[SKIP] $SourceIP -> $TargetIP -- already connected"
                    $meshOK++
                } else {
                    Write-Log "[FAIL] $SourceIP -> $TargetIP -- $($_.Exception.Message)" -Level Warning
                    $meshFail++
                }
            }
        }
    }
    Write-Log "Mesh results: $meshOK connected, $meshFail failed."
    $script:Summary.Add("Mesh: $meshOK OK, $meshFail failed")
    if ($meshOK -eq 0) {
        Write-Log 'No iSCSI connections succeeded.' -Level Error
        $script:ExitCode = 20
    } elseif ($meshFail -gt 0) {
        $script:ExitCode = 10
    }
}

# Rescan storage so Windows re-enumerates MPIO paths
Write-Log 'Rescanning storage...'
Update-HostStorageCache

# --- PHASE 3: VALIDATION ---
Write-Log '[3/3] Validation'
$sessions = Get-IscsiSession -ErrorAction SilentlyContinue
$expectedMin = $LocalPortals.Count * $TargetIPs.Count
Write-Log "Active sessions: $($sessions.Count) (expected: $expectedMin if all ports wired)"
$script:Summary.Add("Sessions: $($sessions.Count)/$expectedMin")

if ($sessions.Count -lt $expectedMin) {
    Write-Log "Session count ($($sessions.Count)) is below expected ($expectedMin)." -Level Warning
    if ($script:ExitCode -lt 10) { $script:ExitCode = 10 }
}

# Check MPIO paths per disk
try {
    $mpioDisks = Get-CimInstance -Namespace root/wmi -ClassName MPIO_DISK_INFO -ErrorAction Stop
    foreach ($disk in $mpioDisks.DriveInfo) {
        Write-Log "MPIO Disk: $($disk.Name) -- Paths: $($disk.NumberPaths)"
        if ($disk.NumberPaths -lt 2) {
            Write-Log "Disk $($disk.Name) has only $($disk.NumberPaths) path(s) -- multipathing may not be active." -Level Warning
            if ($script:ExitCode -lt 10) { $script:ExitCode = 10 }
        }
    }
} catch {
    Write-Log "Could not query MPIO disk info -- MPIO may require a reboot to finalize." -Level Warning
}

# --- FINISH ---
$statusLabel = switch ($script:ExitCode) {
    0       { 'Success' }
    10      { 'Warning' }
    default { 'Critical' }
}
$summaryText = "$statusLabel | $($script:Summary -join ' | ')"
Write-Log "Result: $summaryText"
Write-Log "Log saved: $script:LogFile"

# NinjaRMM output
if ($NinjaCustomField) {
    try {
        Ninja-Property-Set $NinjaCustomField $summaryText 2>$null
        Write-Log "NinjaRMM field '$NinjaCustomField' updated."
    } catch {
        Write-Log "Could not set Ninja field '$NinjaCustomField' -- not running in NinjaRMM context." -Level Warning
    }
}

if ($script:RebootRequired) {
    if ($AutoReboot) {
        if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Schedule reboot in 60 seconds')) {
            Write-Log 'Scheduling reboot in 60 seconds...'
            shutdown.exe /r /t 60 /c "Repair-MSAMultipath: Reboot for MPIO claim finalization"
        }
    } else {
        Write-Log 'REBOOT REQUIRED -- MPIO feature or device claim needs a reboot to finalize.' -Level Warning
    }
} else {
    Write-Log 'No reboot required -- MPIO feature and device claim were already in place.'
}

exit $script:ExitCode