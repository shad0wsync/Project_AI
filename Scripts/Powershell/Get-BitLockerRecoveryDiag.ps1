#Requires -Version 5.1

<#
.SYNOPSIS
    Diagnose what caused a BitLocker recovery key prompt.

.DESCRIPTION
    Collects diagnostic data to determine why BitLocker triggered recovery mode:
    - BitLocker management event log (768=recovery triggered, 769/770=suspend/resume,
      773-778=encryption/boot changes, 783=TPM profile, 817/846=key backup)
    - TPM status and health
    - Current BitLocker protector configuration
    - PCR validation profile
    - Recent BIOS/firmware/Secure Boot changes
    - Boot configuration (BCD) entries

    Supports: Windows 10/11, Server 2016/2019/2022/2025

.NOTES
    Script:  Get-BitLockerRecoveryDiag.ps1
    Author:  Jeff Davidson
    Version: 1.0.0
    Date:    2026-04-03

    Requires: PowerShell 5.1+, Run as Administrator
    Compatibility: PowerShell 5.1 and 7.x
    Default Export Path: C:\Temp\BitLockerRecoveryDiag

.PARAMETER HoursBack
    Number of hours to search back in event logs. Default: 168 (7 days).

.PARAMETER Drive
    Drive letter to inspect. Default: C:

.PARAMETER Quiet
    Suppress console output (for RMM/automation).

.PARAMETER AutoExport
    Export ALL report formats (JSON, HTML, TXT, MD) to C:\Temp\BitLockerRecoveryDiag.

.PARAMETER ExportJson
    Export only JSON report.

.PARAMETER ExportHtml
    Export only HTML report.

.PARAMETER ExportTxt
    Export only plain-text report.

.PARAMETER ExportMarkdown
    Export only Markdown report.

.PARAMETER PassThru
    Return diagnostic object to pipeline.

.EXAMPLE
    .\Get-BitLockerRecoveryDiag.ps1

    Run with defaults — check drive C:, last 7 days, output to console.

.EXAMPLE
    .\Get-BitLockerRecoveryDiag.ps1 -AutoExport

    Run and export all formats (JSON, HTML, TXT, MD) to C:\Temp\BitLockerRecoveryDiag.

.EXAMPLE
    .\Get-BitLockerRecoveryDiag.ps1 -ExportHtml

    Export only an HTML report.

.EXAMPLE
    .\Get-BitLockerRecoveryDiag.ps1 -HoursBack 48 -Drive D:

    Check drive D: over the last 48 hours.
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 8760)]
    [int]$HoursBack = 168,

    [ValidatePattern('^[A-Za-z]:?$')]
    [string]$Drive = 'C:',

    [switch]$Quiet,
    [switch]$AutoExport,
    [switch]$ExportJson,
    [switch]$ExportHtml,
    [switch]$ExportTxt,
    [switch]$ExportMarkdown,
    [switch]$PassThru
)

function Invoke-BitLockerRecoveryDiag {
    <#
    .SYNOPSIS
        Diagnose what caused a BitLocker recovery key prompt.
    #>
    [CmdletBinding()]
    param(
        [ValidateRange(1, 8760)]
        [int]$HoursBack = 168,

        [ValidatePattern('^[A-Za-z]:?$')]
        [string]$Drive = 'C:',

        [switch]$Quiet,
        [switch]$AutoExport,
        [switch]$ExportJson,
        [switch]$ExportHtml,
        [switch]$ExportTxt,
        [switch]$ExportMarkdown,
        [switch]$PassThru
    )

# ────────────────────────── Setup ──────────────────────────
$ErrorActionPreference = 'Stop'
$script:ScriptVersion = '1.0.0'
$script:ScriptName    = 'BitLockerRecoveryDiag'
$script:OutputBase    = "C:\Temp\$script:ScriptName"
$script:IsAdmin       = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$script:IsServer      = (Get-CimInstance -ClassName Win32_OperatingSystem).ProductType -ne 1

# Normalise drive letter
$Drive = $Drive.ToUpper()
if ($Drive -notmatch ':$') { $Drive = "$Drive`:" }

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS','DEBUG')]
        [string]$Level = 'INFO'
    )
    if ($Quiet -and $Level -notin @('ERROR')) { return }
    $colour = switch ($Level) {
        'INFO'    { 'Cyan' }
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red' }
        'SUCCESS' { 'Green' }
        'DEBUG'   { 'Gray' }
    }
    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Host "[$ts $Level] $Message" -ForegroundColor $colour
}

# ────────────────────────── Admin Check ──────────────────────────
if (-not $script:IsAdmin) {
    Write-Log 'This script requires Administrator privileges.' -Level ERROR
    exit 20
}

# ────────────────────────── Event Log Collection ──────────────────────────
function Get-BitLockerEvents {
    param([int]$Hours)

    $startTime = (Get-Date).AddHours(-$Hours)
    $results   = [System.Collections.Generic.List[PSObject]]::new()
    $logName   = 'Microsoft-Windows-BitLocker/BitLocker Management'

    # Key event IDs and their meanings
    $eventMeanings = @{
        768   = 'Recovery was triggered'
        769   = 'Protection was suspended'
        770   = 'Protection was resumed'
        771   = 'Protector was changed/removed'
        773   = 'Encryption started'
        774   = 'Encryption paused'
        775   = 'Encryption resumed'
        776   = 'Encryption completed'
        778   = 'Boot configuration changed'
        783   = 'TPM validation profile changed'
        796   = 'Key rotation occurred'
        817   = 'Recovery password backed up to AD/Entra'
        840   = 'TPM unsealed volume master key (normal boot)'
        845   = 'TPM was reset'
        846   = 'Recovery key uploaded'
        890   = 'BitLocker Group Policy settings refreshed'
        892   = 'BitLocker Group Policy applied to OS drive'
        900   = 'BitLocker drive encryption status reported'
        24577 = 'Volume encrypted successfully'
        24578 = 'Decryption started'
        24579 = 'Decryption completed'
        24588 = 'BitLocker error'
        24620 = 'BitLocker error'
        24621 = 'BitLocker warning'
    }

    try {
        $events = Get-WinEvent -FilterHashtable @{
            LogName   = $logName
            StartTime = $startTime
        } -ErrorAction SilentlyContinue

        if ($events) {
            foreach ($ev in $events) {
                $meaning = if ($eventMeanings.ContainsKey([int]$ev.Id)) { $eventMeanings[[int]$ev.Id] } else { 'Other BitLocker event' }
                $results.Add([PSCustomObject]@{
                    TimeCreated = $ev.TimeCreated
                    EventId     = $ev.Id
                    Meaning     = $meaning
                    Message     = ($ev.Message -split "`n")[0..2] -join ' '
                    Level       = $ev.LevelDisplayName
                })
            }
        }
    } catch {
        Write-Log "Could not read BitLocker event log: $_" -Level WARN
    }

    return $results
}

function Get-TPMEvents {
    param([int]$Hours)

    $startTime = (Get-Date).AddHours(-$Hours)
    $results   = [System.Collections.Generic.List[PSObject]]::new()

    try {
        $events = Get-WinEvent -FilterHashtable @{
            LogName      = 'System'
            ProviderName = @('Microsoft-Windows-TPM-WMI', 'TPM')
            StartTime    = $startTime
        } -ErrorAction SilentlyContinue

        if ($events) {
            foreach ($ev in $events) {
                $results.Add([PSCustomObject]@{
                    TimeCreated = $ev.TimeCreated
                    EventId     = $ev.Id
                    Provider    = $ev.ProviderName
                    Message     = ($ev.Message -split "`n")[0..1] -join ' '
                    Level       = $ev.LevelDisplayName
                })
            }
        }
    } catch {
        Write-Log "Could not read TPM events: $_" -Level WARN
    }

    return $results
}

function Get-BootConfigEvents {
    param([int]$Hours)

    $startTime = (Get-Date).AddHours(-$Hours)
    $results   = [System.Collections.Generic.List[PSObject]]::new()

    # Check for BIOS/firmware/Secure Boot related events
    $providers = @('Microsoft-Windows-Kernel-Boot', 'Microsoft-Windows-EFI')
    foreach ($prov in $providers) {
        try {
            $events = Get-WinEvent -FilterHashtable @{
                LogName      = 'System'
                ProviderName = $prov
                StartTime    = $startTime
            } -ErrorAction SilentlyContinue

            if ($events) {
                foreach ($ev in $events) {
                    $results.Add([PSCustomObject]@{
                        TimeCreated = $ev.TimeCreated
                        EventId     = $ev.Id
                        Provider    = $ev.ProviderName
                        Message     = ($ev.Message -split "`n")[0..1] -join ' '
                    })
                }
            }
        } catch { <# provider may not exist #> }
    }

    return $results
}

# ────────────────────────── BCD & PCR Collection ──────────────────────────
function Get-BCDEntries {
    $bcd = @{
        Entries = @()
        Error   = $null
    }

    try {
        $raw = bcdedit /enum ACTIVE 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            $bcd.Error = "bcdedit returned exit code $LASTEXITCODE"
        } else {
            $bcd.Entries = @($raw -split '(?m)^-{3,}' | Where-Object { $_.Trim() } | ForEach-Object {
                $block = $_.Trim()
                [PSCustomObject]@{
                    Raw = $block
                }
            })
        }
    } catch {
        $bcd.Error = $_.Exception.Message
    }

    return [PSCustomObject]$bcd
}

function Get-PCRValidationProfile {
    param([string]$DriveLetter)

    $pcr = @{
        Values  = @()
        Raw     = $null
        Error   = $null
    }

    try {
        $raw = manage-bde -protectors -get $DriveLetter 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            $pcr.Error = "manage-bde returned exit code $LASTEXITCODE"
        } else {
            $pcr.Raw = $raw
            # Extract PCR Validation Profile line(s)
            $pcrLines = ($raw -split "`n" | Where-Object { $_ -match 'PCR Validation Profile' }) -join ', '
            if ($pcrLines) {
                $pcr.Values = @([regex]::Matches($pcrLines, '\d+') | ForEach-Object { [int]$_.Value })
            }
        }
    } catch {
        $pcr.Error = $_.Exception.Message
    }

    return [PSCustomObject]$pcr
}

# ────────────────────────── System Info Collection ──────────────────────────
function Get-TPMStatus {
    $tpm = @{
        Available = $false
        Ready     = $false
        Enabled   = $false
        Owned     = $false
        Version   = 'Unknown'
        Error     = $null
    }

    try {
        $tpmInfo = Get-Tpm -ErrorAction Stop
        $tpm.Available = [bool]$tpmInfo.TpmPresent
        $tpm.Ready     = [bool]$tpmInfo.TpmReady
        $tpm.Enabled   = [bool]$tpmInfo.TpmEnabled
        $tpm.Owned     = [bool]$tpmInfo.TpmOwned

        # TPM version from WMI
        try {
            $tpmWmi = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName 'Win32_Tpm' -ErrorAction Stop
            if ($tpmWmi.SpecVersion) {
                $tpm.Version = ($tpmWmi.SpecVersion -split ',')[0].Trim()
            }
        } catch { $tpm.Version = 'Could not determine' }
    } catch {
        $tpm.Error = $_.Exception.Message
    }

    return [PSCustomObject]$tpm
}

function Get-BitLockerStatus {
    param([string]$DriveLetter)

    $status = @{
        Drive            = $DriveLetter
        ProtectionStatus = 'Unknown'
        EncryptionMethod = 'Unknown'
        VolumeStatus     = 'Unknown'
        Protectors       = @()
        Error            = $null
    }

    # BitLocker module may not be available (Server Core, non-Enterprise SKU)
    if (-not (Get-Command -Name Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
        $status.Error = 'BitLocker module not available (Get-BitLockerVolume not found)'
        return [PSCustomObject]$status
    }

    try {
        $vol = Get-BitLockerVolume -MountPoint $DriveLetter -ErrorAction Stop
        $status.ProtectionStatus = $vol.ProtectionStatus.ToString()
        $status.EncryptionMethod = $vol.EncryptionMethod.ToString()
        $status.VolumeStatus     = $vol.VolumeStatus.ToString()
        $status.Protectors       = @($vol.KeyProtector | ForEach-Object {
            [PSCustomObject]@{
                Type = $_.KeyProtectorType.ToString()
                Id   = $_.KeyProtectorId
            }
        })
    } catch {
        $status.Error = $_.Exception.Message
    }

    return [PSCustomObject]$status
}

function Get-SecureBootStatus {
    try {
        $sb = Confirm-SecureBootUEFI -ErrorAction Stop
        return [PSCustomObject]@{
            Enabled = $sb
            Error   = $null
        }
    } catch {
        return [PSCustomObject]@{
            Enabled = $null
            Error   = $_.Exception.Message
        }
    }
}

function Get-RecentFirmwareUpdates {
    param([int]$Hours)

    $startTime = (Get-Date).AddHours(-$Hours)
    $results   = [System.Collections.Generic.List[PSObject]]::new()

    try {
        $events = Get-WinEvent -FilterHashtable @{
            LogName   = 'System'
            Id        = @(19, 20, 21, 22, 24, 25)  # Windows Update / driver install events
            StartTime = $startTime
        } -ErrorAction SilentlyContinue

        if ($events) {
            $firmwareEvents = $events | Where-Object {
                $_.Message -match 'firmware|BIOS|UEFI|TPM'
            }
            foreach ($ev in $firmwareEvents) {
                $results.Add([PSCustomObject]@{
                    TimeCreated = $ev.TimeCreated
                    EventId     = $ev.Id
                    Message     = ($ev.Message -split "`n")[0]
                })
            }
        }
    } catch { <# no matching events #> }

    return $results
}

# ────────────────────────── Diagnosis Logic ──────────────────────────
function Get-RecoveryDiagnosis {
    param($BitLockerEvents, $TPMStatus, $SecureBootStatus, $TPMEvents, $BootEvents, $FirmwareUpdates, $PCRProfile)

    $findings = [System.Collections.Generic.List[string]]::new()
    $severity = 'INFO'

    # Check for Event 768 — direct recovery trigger
    $recoveryEvents = @($BitLockerEvents | Where-Object { $_.EventId -eq 768 })
    if ($recoveryEvents.Count -gt 0) {
        $severity = 'CRITICAL'
        foreach ($re in $recoveryEvents) {
            $findings.Add("RECOVERY TRIGGERED at $($re.TimeCreated): $($re.Message)")
        }
    }

    # Check for boot config changes (778)
    $bootChanges = @($BitLockerEvents | Where-Object { $_.EventId -eq 778 })
    if ($bootChanges.Count -gt 0) {
        if ($severity -ne 'CRITICAL') { $severity = 'WARNING' }
        $findings.Add("Boot configuration was changed ($($bootChanges.Count) event(s)) — can trigger recovery if PCR values shift.")
    }

    # Check for TPM profile changes (783)
    $tpmProfileChanges = @($BitLockerEvents | Where-Object { $_.EventId -eq 783 })
    if ($tpmProfileChanges.Count -gt 0) {
        if ($severity -ne 'CRITICAL') { $severity = 'WARNING' }
        $findings.Add("TPM validation profile was changed ($($tpmProfileChanges.Count) event(s)).")
    }

    # Check for TPM reset (845)
    $tpmResets = @($BitLockerEvents | Where-Object { $_.EventId -eq 845 })
    if ($tpmResets.Count -gt 0) {
        $severity = 'CRITICAL'
        $findings.Add("TPM was RESET ($($tpmResets.Count) event(s)) — triggers recovery unless protection was suspended beforehand.")
    }

    # Check for protection suspended (769) without resume (770)
    $suspends = @($BitLockerEvents | Where-Object { $_.EventId -eq 769 })
    $resumes  = @($BitLockerEvents | Where-Object { $_.EventId -eq 770 })
    if ($suspends.Count -gt $resumes.Count) {
        if ($severity -ne 'CRITICAL') { $severity = 'WARNING' }
        $findings.Add("Protection was suspended $($suspends.Count) time(s) but only resumed $($resumes.Count) time(s) — may still be suspended.")
    }

    # Check for errors
    $errors = @($BitLockerEvents | Where-Object { $_.EventId -in @(24588, 24620) })
    if ($errors.Count -gt 0) {
        if ($severity -ne 'CRITICAL') { $severity = 'WARNING' }
        $findings.Add("BitLocker errors detected ($($errors.Count) event(s)).")
    }

    # TPM health
    if ($TPMStatus.Error) {
        $severity = 'CRITICAL'
        $findings.Add("TPM query failed: $($TPMStatus.Error)")
    } elseif (-not $TPMStatus.Ready) {
        $severity = 'CRITICAL'
        $findings.Add("TPM is NOT READY (Present=$($TPMStatus.Available), Enabled=$($TPMStatus.Enabled), Owned=$($TPMStatus.Owned)).")
    }

    # TPM events
    if ($TPMEvents.Count -gt 0) {
        if ($severity -ne 'CRITICAL') { $severity = 'WARNING' }
        $findings.Add("$($TPMEvents.Count) TPM event(s) found in System log — review for firmware/ownership changes.")
    }

    # Firmware updates
    if ($FirmwareUpdates.Count -gt 0) {
        if ($severity -ne 'CRITICAL') { $severity = 'WARNING' }
        $findings.Add("$($FirmwareUpdates.Count) firmware/BIOS update(s) detected — BIOS updates change PCR values and trigger recovery.")
    }

    # Boot events
    if ($BootEvents.Count -gt 0) {
        if ($severity -eq 'INFO') { $severity = 'INFO' }
        $findings.Add("$($BootEvents.Count) boot/EFI event(s) found — review for boot order or Secure Boot changes.")
    }

    # Secure Boot
    if ($null -eq $SecureBootStatus.Enabled) {
        $findings.Add("Secure Boot status could not be determined (legacy BIOS or non-UEFI).")
    } elseif (-not $SecureBootStatus.Enabled) {
        if ($severity -ne 'CRITICAL') { $severity = 'WARNING' }
        $findings.Add("Secure Boot is DISABLED — toggling Secure Boot changes PCR[7] and triggers recovery.")
    }

    # PCR profile
    if ($PCRProfile -and $PCRProfile.Error) {
        $findings.Add("Could not read PCR validation profile: $($PCRProfile.Error)")
    } elseif ($PCRProfile -and $PCRProfile.Values.Count -gt 0) {
        $pcrList = ($PCRProfile.Values | Sort-Object -Unique) -join ','
        $findings.Add("Active PCR validation profile: $pcrList")
    }

    if ($findings.Count -eq 0) {
        $findings.Add("No BitLocker recovery triggers found in the specified time window.")
    }

    return [PSCustomObject]@{
        Severity = $severity
        Findings = $findings
    }
}

# ────────────────────────── Main ──────────────────────────
Write-Log "BitLocker Recovery Diagnostics v$script:ScriptVersion" -Level INFO
Write-Log "Checking drive $Drive, last $HoursBack hours" -Level INFO
Write-Log ('-' * 60) -Level INFO

# Collect all data
Write-Log 'Collecting BitLocker event log...' -Level INFO
$blEvents = Get-BitLockerEvents -Hours $HoursBack

Write-Log 'Collecting TPM events...' -Level INFO
$tpmEvents = Get-TPMEvents -Hours $HoursBack

Write-Log 'Collecting boot/EFI events...' -Level INFO
$bootEvents = Get-BootConfigEvents -Hours $HoursBack

Write-Log 'Checking TPM status...' -Level INFO
$tpmStatus = Get-TPMStatus

Write-Log 'Checking BitLocker volume status...' -Level INFO
$blStatus = Get-BitLockerStatus -DriveLetter $Drive

Write-Log 'Checking Secure Boot...' -Level INFO
$sbStatus = Get-SecureBootStatus

Write-Log 'Checking for firmware updates...' -Level INFO
$fwUpdates = Get-RecentFirmwareUpdates -Hours $HoursBack

Write-Log 'Collecting BCD configuration...' -Level INFO
$bcdInfo = Get-BCDEntries

Write-Log 'Collecting PCR validation profile...' -Level INFO
$pcrInfo = Get-PCRValidationProfile -DriveLetter $Drive

# Run diagnosis
$diagnosis = Get-RecoveryDiagnosis -BitLockerEvents $blEvents -TPMStatus $tpmStatus `
    -SecureBootStatus $sbStatus -TPMEvents $tpmEvents -BootEvents $bootEvents `
    -FirmwareUpdates $fwUpdates -PCRProfile $pcrInfo

# ────────────────────────── Output ──────────────────────────
Write-Log ('-' * 60) -Level INFO

# TPM Status
Write-Log "TPM STATUS" -Level INFO
if ($tpmStatus.Error) {
    Write-Log "  Error: $($tpmStatus.Error)" -Level ERROR
} else {
    Write-Log "  Present=$($tpmStatus.Available)  Ready=$($tpmStatus.Ready)  Enabled=$($tpmStatus.Enabled)  Owned=$($tpmStatus.Owned)  Version=$($tpmStatus.Version)" -Level INFO
}

# BitLocker Status
Write-Log "BITLOCKER STATUS ($Drive)" -Level INFO
if ($blStatus.Error) {
    Write-Log "  Error: $($blStatus.Error)" -Level ERROR
} else {
    Write-Log "  Protection=$($blStatus.ProtectionStatus)  Encryption=$($blStatus.EncryptionMethod)  Volume=$($blStatus.VolumeStatus)" -Level INFO
    foreach ($p in $blStatus.Protectors) {
        Write-Log "  Protector: $($p.Type) ($($p.Id))" -Level INFO
    }
}

# Secure Boot
Write-Log "SECURE BOOT" -Level INFO
if ($null -eq $sbStatus.Enabled) {
    Write-Log "  Could not determine ($($sbStatus.Error))" -Level WARN
} else {
    $sbLevel = if ($sbStatus.Enabled) { 'SUCCESS' } else { 'WARN' }
    Write-Log "  Enabled=$($sbStatus.Enabled)" -Level $sbLevel
}

# PCR Validation Profile
Write-Log "PCR VALIDATION PROFILE" -Level INFO
if ($pcrInfo.Error) {
    Write-Log "  Error: $($pcrInfo.Error)" -Level WARN
} elseif ($pcrInfo.Values.Count -gt 0) {
    Write-Log "  PCR values: $(($pcrInfo.Values | Sort-Object -Unique) -join ', ')" -Level INFO
} else {
    Write-Log "  No PCR profile detected (TPM protector may not be configured)" -Level WARN
}

# BCD Configuration
Write-Log "BCD CONFIGURATION" -Level INFO
if ($bcdInfo.Error) {
    Write-Log "  Error: $($bcdInfo.Error)" -Level WARN
} else {
    Write-Log "  Active BCD entries: $($bcdInfo.Entries.Count)" -Level INFO
}

# Event Summary
Write-Log "EVENTS (last $HoursBack hours)" -Level INFO
Write-Log "  BitLocker events: $($blEvents.Count)" -Level INFO
Write-Log "  TPM events:       $($tpmEvents.Count)" -Level INFO
Write-Log "  Boot/EFI events:  $($bootEvents.Count)" -Level INFO
Write-Log "  Firmware updates: $($fwUpdates.Count)" -Level INFO

if ($blEvents.Count -gt 0) {
    Write-Log '' -Level INFO
    Write-Log 'BITLOCKER EVENT DETAILS' -Level INFO
    foreach ($ev in ($blEvents | Sort-Object TimeCreated -Descending | Select-Object -First 20)) {
        $lvl = if ($ev.EventId -in @(768, 845, 24588, 24620)) { 'ERROR' } elseif ($ev.EventId -in @(778, 783, 769)) { 'WARN' } else { 'INFO' }
        Write-Log "  [$($ev.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))] ID $($ev.EventId) - $($ev.Meaning)" -Level $lvl
    }
}

if ($tpmEvents.Count -gt 0) {
    Write-Log '' -Level INFO
    Write-Log 'TPM EVENT DETAILS' -Level INFO
    foreach ($ev in ($tpmEvents | Sort-Object TimeCreated -Descending | Select-Object -First 20)) {
        $lvl = if ($ev.Level -eq 'Error') { 'ERROR' } elseif ($ev.Level -eq 'Warning') { 'WARN' } else { 'INFO' }
        Write-Log "  [$($ev.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))] ID $($ev.EventId) ($($ev.Provider)) - $($ev.Message)" -Level $lvl
    }
}

# Diagnosis
Write-Log '' -Level INFO
Write-Log ('-' * 60) -Level INFO
$diagLevel = switch ($diagnosis.Severity) {
    'CRITICAL' { 'ERROR' }
    'WARNING'  { 'WARN' }
    default    { 'SUCCESS' }
}
Write-Log "DIAGNOSIS: $($diagnosis.Severity)" -Level $diagLevel
foreach ($f in $diagnosis.Findings) {
    Write-Log "  - $f" -Level $diagLevel
}

# ────────────────────────── Export ──────────────────────────
$report = [PSCustomObject]@{
    ComputerName     = $env:COMPUTERNAME
    Timestamp        = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    ScriptVersion    = $script:ScriptVersion
    IsServer         = $script:IsServer
    Drive            = $Drive
    HoursBack        = $HoursBack
    TPMStatus        = $tpmStatus
    BitLockerStatus  = $blStatus
    SecureBootStatus = $sbStatus
    PCRProfile       = $pcrInfo
    BCDConfig        = $bcdInfo
    Diagnosis        = $diagnosis
    BitLockerEvents  = @($blEvents)
    TPMEvents        = @($tpmEvents)
    BootEvents       = @($bootEvents)
    FirmwareUpdates  = @($fwUpdates)
}

# Resolve export flags: AutoExport = all formats; individual switches pick specific ones
$doJson     = $AutoExport -or $ExportJson
$doHtml     = $AutoExport -or $ExportHtml
$doTxt      = $AutoExport -or $ExportTxt
$doMarkdown = $AutoExport -or $ExportMarkdown
$anyExport  = $doJson -or $doHtml -or $doTxt -or $doMarkdown

if ($anyExport) {
    if (-not (Test-Path $script:OutputBase)) {
        New-Item -ItemType Directory -Path $script:OutputBase -Force | Out-Null
    }
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $fileBase  = "${script:ScriptName}_${env:COMPUTERNAME}_${timestamp}"
}

if ($doJson) {
    $jsonPath = Join-Path $script:OutputBase "${fileBase}.json"
    try {
        $report | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonPath -Encoding UTF8
        Write-Log "Report exported: $jsonPath" -Level SUCCESS
    } catch {
        Write-Log "Failed to export JSON: $_" -Level ERROR
    }
}

if ($doTxt) {
    $txtPath = Join-Path $script:OutputBase "${fileBase}.txt"
    try {
        $txt = [System.Text.StringBuilder]::new()
        [void]$txt.AppendLine("BitLocker Recovery Diagnostics v$($script:ScriptVersion)")
        [void]$txt.AppendLine("Computer: $($env:COMPUTERNAME)  |  Drive: $Drive  |  Time window: $HoursBack hours")
        [void]$txt.AppendLine("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
        [void]$txt.AppendLine(('=' * 70))

        [void]$txt.AppendLine("`nTPM STATUS")
        if ($tpmStatus.Error) { [void]$txt.AppendLine("  Error: $($tpmStatus.Error)") }
        else { [void]$txt.AppendLine("  Present=$($tpmStatus.Available)  Ready=$($tpmStatus.Ready)  Enabled=$($tpmStatus.Enabled)  Owned=$($tpmStatus.Owned)  Version=$($tpmStatus.Version)") }

        [void]$txt.AppendLine("`nBITLOCKER STATUS ($Drive)")
        if ($blStatus.Error) { [void]$txt.AppendLine("  Error: $($blStatus.Error)") }
        else {
            [void]$txt.AppendLine("  Protection=$($blStatus.ProtectionStatus)  Encryption=$($blStatus.EncryptionMethod)  Volume=$($blStatus.VolumeStatus)")
            foreach ($p in $blStatus.Protectors) { [void]$txt.AppendLine("  Protector: $($p.Type) ($($p.Id))") }
        }

        [void]$txt.AppendLine("`nSECURE BOOT")
        if ($null -eq $sbStatus.Enabled) { [void]$txt.AppendLine("  Could not determine ($($sbStatus.Error))") }
        else { [void]$txt.AppendLine("  Enabled=$($sbStatus.Enabled)") }

        [void]$txt.AppendLine("`nPCR VALIDATION PROFILE")
        if ($pcrInfo.Error) { [void]$txt.AppendLine("  Error: $($pcrInfo.Error)") }
        elseif ($pcrInfo.Values.Count -gt 0) { [void]$txt.AppendLine("  PCR values: $(($pcrInfo.Values | Sort-Object -Unique) -join ', ')") }
        else { [void]$txt.AppendLine("  No PCR profile detected") }

        [void]$txt.AppendLine("`nEVENTS (last $HoursBack hours)")
        [void]$txt.AppendLine("  BitLocker: $($blEvents.Count)  |  TPM: $($tpmEvents.Count)  |  Boot/EFI: $($bootEvents.Count)  |  Firmware: $($fwUpdates.Count)")

        if ($blEvents.Count -gt 0) {
            [void]$txt.AppendLine("`nBITLOCKER EVENT DETAILS")
            foreach ($ev in ($blEvents | Sort-Object TimeCreated -Descending | Select-Object -First 20)) {
                [void]$txt.AppendLine("  [$($ev.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))] ID $($ev.EventId) - $($ev.Meaning)")
            }
        }

        if ($tpmEvents.Count -gt 0) {
            [void]$txt.AppendLine("`nTPM EVENT DETAILS")
            foreach ($ev in ($tpmEvents | Sort-Object TimeCreated -Descending | Select-Object -First 20)) {
                [void]$txt.AppendLine("  [$($ev.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))] ID $($ev.EventId) ($($ev.Provider)) - $($ev.Message)")
            }
        }

        [void]$txt.AppendLine("`n$('=' * 70)")
        [void]$txt.AppendLine("DIAGNOSIS: $($diagnosis.Severity)")
        foreach ($f in $diagnosis.Findings) { [void]$txt.AppendLine("  - $f") }

        $txt.ToString() | Set-Content -Path $txtPath -Encoding UTF8
        Write-Log "Report exported: $txtPath" -Level SUCCESS
    } catch {
        Write-Log "Failed to export TXT: $_" -Level ERROR
    }
}

if ($doHtml) {
    $htmlPath = Join-Path $script:OutputBase "${fileBase}.html"
    try {
        $sevColor = switch ($diagnosis.Severity) { 'CRITICAL' { '#dc3545' } 'WARNING' { '#ffc107' } default { '#28a745' } }
        $sevText  = switch ($diagnosis.Severity) { 'CRITICAL' { 'color:#fff' } 'WARNING' { 'color:#000' } default { 'color:#fff' } }

        $tpmHtml = if ($tpmStatus.Error) { "<tr><td colspan='2' class='fail'>Error: $([System.Net.WebUtility]::HtmlEncode($tpmStatus.Error))</td></tr>" }
        else {
            "<tr><td>Present</td><td>$($tpmStatus.Available)</td></tr>" +
            "<tr><td>Ready</td><td>$($tpmStatus.Ready)</td></tr>" +
            "<tr><td>Enabled</td><td>$($tpmStatus.Enabled)</td></tr>" +
            "<tr><td>Owned</td><td>$($tpmStatus.Owned)</td></tr>" +
            "<tr><td>Version</td><td>$([System.Net.WebUtility]::HtmlEncode($tpmStatus.Version))</td></tr>"
        }

        $blHtml = if ($blStatus.Error) { "<tr><td colspan='2' class='fail'>Error: $([System.Net.WebUtility]::HtmlEncode($blStatus.Error))</td></tr>" }
        else {
            "<tr><td>Protection</td><td>$($blStatus.ProtectionStatus)</td></tr>" +
            "<tr><td>Encryption</td><td>$($blStatus.EncryptionMethod)</td></tr>" +
            "<tr><td>Volume</td><td>$($blStatus.VolumeStatus)</td></tr>" +
            (($blStatus.Protectors | ForEach-Object { "<tr><td>Protector</td><td>$($_.Type) ($($_.Id))</td></tr>" }) -join '')
        }

        $evtRows = ''
        if ($blEvents.Count -gt 0) {
            foreach ($ev in ($blEvents | Sort-Object TimeCreated -Descending | Select-Object -First 20)) {
                $rowClass = if ($ev.EventId -in @(768, 845, 24588, 24620)) { " class='fail'" } elseif ($ev.EventId -in @(778, 783, 769)) { " class='warn'" } else { '' }
                $evtRows += "<tr$rowClass><td>$($ev.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))</td><td>$($ev.EventId)</td><td>$([System.Net.WebUtility]::HtmlEncode($ev.Meaning))</td></tr>`n"
            }
        } else {
            $evtRows = "<tr><td colspan='3'>No BitLocker events in time window</td></tr>"
        }

        $findingsHtml = ($diagnosis.Findings | ForEach-Object { "<li>$([System.Net.WebUtility]::HtmlEncode($_))</li>" }) -join "`n"

        $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>BitLocker Recovery Diagnostics - $($env:COMPUTERNAME)</title>
<style>
body{font-family:Segoe UI,sans-serif;margin:20px;background:#f5f5f5;color:#333}
h1{color:#0078d4}h2{border-bottom:2px solid #0078d4;padding-bottom:4px}
table{border-collapse:collapse;width:100%;margin-bottom:20px}
th,td{border:1px solid #ddd;padding:8px;text-align:left}
th{background:#0078d4;color:#fff}
tr:nth-child(even){background:#f9f9f9}
.badge{display:inline-block;padding:6px 16px;border-radius:4px;font-weight:bold;font-size:1.1em}
.fail{background:#f8d7da;color:#721c24}.warn{background:#fff3cd;color:#856404}
.info{font-size:0.9em;color:#666}
</style>
</head>
<body>
<h1>BitLocker Recovery Diagnostics</h1>
<p><strong>Computer:</strong> $($env:COMPUTERNAME) | <strong>Drive:</strong> $Drive | <strong>Window:</strong> $HoursBack hours | <strong>Generated:</strong> $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | <strong>Version:</strong> $($script:ScriptVersion)</p>

<h2>Diagnosis</h2>
<p><span class="badge" style="background:$sevColor;$sevText">$($diagnosis.Severity)</span></p>
<ul>$findingsHtml</ul>

<h2>TPM Status</h2>
<table><tr><th>Property</th><th>Value</th></tr>$tpmHtml</table>

<h2>BitLocker Status ($Drive)</h2>
<table><tr><th>Property</th><th>Value</th></tr>$blHtml</table>

<h2>Secure Boot</h2>
<p>$(if ($null -eq $sbStatus.Enabled) { "Could not determine ($([System.Net.WebUtility]::HtmlEncode($sbStatus.Error)))" } else { "Enabled = $($sbStatus.Enabled)" })</p>

<h2>PCR Validation Profile</h2>
<p>$(if ($pcrInfo.Error) { "Error: $([System.Net.WebUtility]::HtmlEncode($pcrInfo.Error))" } elseif ($pcrInfo.Values.Count -gt 0) { "PCR values: $(($pcrInfo.Values | Sort-Object -Unique) -join ', ')" } else { 'No PCR profile detected' })</p>

<h2>Event Summary</h2>
<table><tr><th>Source</th><th>Count</th></tr>
<tr><td>BitLocker</td><td>$($blEvents.Count)</td></tr>
<tr><td>TPM</td><td>$($tpmEvents.Count)</td></tr>
<tr><td>Boot/EFI</td><td>$($bootEvents.Count)</td></tr>
<tr><td>Firmware Updates</td><td>$($fwUpdates.Count)</td></tr></table>

<h2>BitLocker Event Details</h2>
<table><tr><th>Time</th><th>Event ID</th><th>Meaning</th></tr>
$evtRows</table>

<h2>TPM Event Details</h2>
<table><tr><th>Time</th><th>Event ID</th><th>Provider</th><th>Message</th></tr>
$(if ($tpmEvents.Count -gt 0) { ($tpmEvents | Sort-Object TimeCreated -Descending | Select-Object -First 20 | ForEach-Object { "<tr><td>$($_.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))</td><td>$($_.EventId)</td><td>$([System.Net.WebUtility]::HtmlEncode($_.Provider))</td><td>$([System.Net.WebUtility]::HtmlEncode($_.Message))</td></tr>" }) -join "`n" } else { "<tr><td colspan='4'>No TPM events in time window</td></tr>" })
</table>

<p class="info">BCD entries: $($bcdInfo.Entries.Count) | Server OS: $($script:IsServer)</p>
</body></html>
"@
        $html | Set-Content -Path $htmlPath -Encoding UTF8
        Write-Log "Report exported: $htmlPath" -Level SUCCESS
    } catch {
        Write-Log "Failed to export HTML: $_" -Level ERROR
    }
}

if ($doMarkdown) {
    $mdPath = Join-Path $script:OutputBase "${fileBase}.md"
    try {
        $md = [System.Text.StringBuilder]::new()
        [void]$md.AppendLine("# BitLocker Recovery Diagnostics")
        [void]$md.AppendLine('')
        [void]$md.AppendLine("**Computer:** $($env:COMPUTERNAME) | **Drive:** $Drive | **Window:** $HoursBack hours | **Generated:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | **Version:** $($script:ScriptVersion)")
        [void]$md.AppendLine('')
        [void]$md.AppendLine('---')
        [void]$md.AppendLine('')

        [void]$md.AppendLine("## Diagnosis: $($diagnosis.Severity)")
        [void]$md.AppendLine('')
        foreach ($f in $diagnosis.Findings) { [void]$md.AppendLine("- $f") }
        [void]$md.AppendLine('')

        [void]$md.AppendLine('## TPM Status')
        [void]$md.AppendLine('')
        [void]$md.AppendLine('| Property | Value |')
        [void]$md.AppendLine('|----------|-------|')
        if ($tpmStatus.Error) { [void]$md.AppendLine("| Error | $($tpmStatus.Error) |") }
        else {
            [void]$md.AppendLine("| Present | $($tpmStatus.Available) |")
            [void]$md.AppendLine("| Ready | $($tpmStatus.Ready) |")
            [void]$md.AppendLine("| Enabled | $($tpmStatus.Enabled) |")
            [void]$md.AppendLine("| Owned | $($tpmStatus.Owned) |")
            [void]$md.AppendLine("| Version | $($tpmStatus.Version) |")
        }
        [void]$md.AppendLine('')

        [void]$md.AppendLine("## BitLocker Status ($Drive)")
        [void]$md.AppendLine('')
        [void]$md.AppendLine('| Property | Value |')
        [void]$md.AppendLine('|----------|-------|')
        if ($blStatus.Error) { [void]$md.AppendLine("| Error | $($blStatus.Error) |") }
        else {
            [void]$md.AppendLine("| Protection | $($blStatus.ProtectionStatus) |")
            [void]$md.AppendLine("| Encryption | $($blStatus.EncryptionMethod) |")
            [void]$md.AppendLine("| Volume | $($blStatus.VolumeStatus) |")
            foreach ($p in $blStatus.Protectors) { [void]$md.AppendLine("| Protector | $($p.Type) ($($p.Id)) |") }
        }
        [void]$md.AppendLine('')

        [void]$md.AppendLine('## Secure Boot')
        [void]$md.AppendLine('')
        if ($null -eq $sbStatus.Enabled) { [void]$md.AppendLine("Could not determine ($($sbStatus.Error))") }
        else { [void]$md.AppendLine("Enabled = **$($sbStatus.Enabled)**") }
        [void]$md.AppendLine('')

        [void]$md.AppendLine('## PCR Validation Profile')
        [void]$md.AppendLine('')
        if ($pcrInfo.Error) { [void]$md.AppendLine("Error: $($pcrInfo.Error)") }
        elseif ($pcrInfo.Values.Count -gt 0) { [void]$md.AppendLine("PCR values: ``$(($pcrInfo.Values | Sort-Object -Unique) -join ', ')``") }
        else { [void]$md.AppendLine('No PCR profile detected') }
        [void]$md.AppendLine('')

        [void]$md.AppendLine('## Event Summary')
        [void]$md.AppendLine('')
        [void]$md.AppendLine('| Source | Count |')
        [void]$md.AppendLine('|--------|-------|')
        [void]$md.AppendLine("| BitLocker | $($blEvents.Count) |")
        [void]$md.AppendLine("| TPM | $($tpmEvents.Count) |")
        [void]$md.AppendLine("| Boot/EFI | $($bootEvents.Count) |")
        [void]$md.AppendLine("| Firmware Updates | $($fwUpdates.Count) |")
        [void]$md.AppendLine('')

        if ($blEvents.Count -gt 0) {
            [void]$md.AppendLine('## BitLocker Event Details')
            [void]$md.AppendLine('')
            [void]$md.AppendLine('| Time | Event ID | Meaning |')
            [void]$md.AppendLine('|------|----------|---------|')
            foreach ($ev in ($blEvents | Sort-Object TimeCreated -Descending | Select-Object -First 20)) {
                [void]$md.AppendLine("| $($ev.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')) | $($ev.EventId) | $($ev.Meaning) |")
            }
            [void]$md.AppendLine('')
        }

        if ($tpmEvents.Count -gt 0) {
            [void]$md.AppendLine('## TPM Event Details')
            [void]$md.AppendLine('')
            [void]$md.AppendLine('| Time | Event ID | Provider | Message |')
            [void]$md.AppendLine('|------|----------|----------|---------|')
            foreach ($ev in ($tpmEvents | Sort-Object TimeCreated -Descending | Select-Object -First 20)) {
                [void]$md.AppendLine("| $($ev.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')) | $($ev.EventId) | $($ev.Provider) | $($ev.Message) |")
            }
            [void]$md.AppendLine('')
        }

        $md.ToString() | Set-Content -Path $mdPath -Encoding UTF8
        Write-Log "Report exported: $mdPath" -Level SUCCESS
    } catch {
        Write-Log "Failed to export Markdown: $_" -Level ERROR
    }
}

# ────────────────────────── Exit ──────────────────────────
$exitCode = switch ($diagnosis.Severity) {
    'CRITICAL' { 20 }
    'WARNING'  { 10 }
    default    { 0 }
}

if ($PassThru) { return $report }

return [PSCustomObject]@{
    ExitCode = $exitCode
    Severity = $diagnosis.Severity
    Drive    = $Drive
}

} # end Invoke-BitLockerRecoveryDiag

# Auto-run only when executed as a script file (not dot-sourced, not pasted)
if ($PSCommandPath -and $MyInvocation.InvocationName -ne '.') {
    $invokeResult = Invoke-BitLockerRecoveryDiag @PSBoundParameters
    Write-Host ''
    Read-Host 'Press Enter to close'
    exit $invokeResult.ExitCode
} else {
    Write-Host ''
    Write-Host '  Invoke-BitLockerRecoveryDiag loaded. Sample commands:' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '    Invoke-BitLockerRecoveryDiag                                    # Default: drive C:, last 7 days' -ForegroundColor Gray
    Write-Host '    Invoke-BitLockerRecoveryDiag -AutoExport                         # All formats (JSON+HTML+TXT+MD)' -ForegroundColor Gray
    Write-Host '    Invoke-BitLockerRecoveryDiag -ExportHtml                         # HTML report only' -ForegroundColor Gray
    Write-Host '    Invoke-BitLockerRecoveryDiag -ExportJson                         # JSON report only' -ForegroundColor Gray
    Write-Host '    Invoke-BitLockerRecoveryDiag -ExportTxt                          # Plain-text report only' -ForegroundColor Gray
    Write-Host '    Invoke-BitLockerRecoveryDiag -ExportMarkdown                     # Markdown report only' -ForegroundColor Gray
    Write-Host '    Invoke-BitLockerRecoveryDiag -ExportHtml -ExportJson             # Specific formats' -ForegroundColor Gray
    Write-Host '    Invoke-BitLockerRecoveryDiag -HoursBack 48                       # Narrow to last 48 hours' -ForegroundColor Gray
    Write-Host '    Invoke-BitLockerRecoveryDiag -Drive D:                           # Check alternate drive' -ForegroundColor Gray
    Write-Host '    Invoke-BitLockerRecoveryDiag -PassThru                           # Return object to pipeline' -ForegroundColor Gray
    Write-Host '    Invoke-BitLockerRecoveryDiag -Quiet -AutoExport                  # Silent RMM mode, all formats' -ForegroundColor Gray
    Write-Host ''
}
