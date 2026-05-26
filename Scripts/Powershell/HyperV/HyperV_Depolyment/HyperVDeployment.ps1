#Requires -Version 5.1

<#
.SYNOPSIS
    Hyper-V host deployment script with optional iSCSI/MPIO and Failover Clustering.

.DESCRIPTION
    Idempotent Hyper-V host setup with optional iSCSI/MPIO and Failover Clustering.
    Compatible with Windows Server 2019/2022, PowerShell 5.1+ and 7.x.

    Deployment steps (each validated after execution):
    1. Windows features: Hyper-V, Failover Clustering, MPIO
    2. Host configuration: Power plan, NUMA spanning, Enhanced Session Mode, default paths
    3. Defender exclusions: Hyper-V processes, VHD extensions, storage paths
    4. Networking: vSwitch with SET or LBFO, management vNIC VLAN
    5. Storage: iSCSI target portals, MPIO multipath, disk timeout registry
    6. Clustering: Validation, creation, quorum configuration
    7. Live Migration: Protocol, authentication, concurrent limit
    8. Post-deploy: Optional HyperVAssessment run

    Supports YAML template files for repeatable, preconfigured deployments.
    Omit a section or set it to 'skip' to exclude it from deployment.

    Supports dual-mode execution:
    - Direct: .\HyperVDeployment.ps1 -Mode Fix -TemplatePath .\cluster-host.yaml
    - Function: Copy-paste, then Invoke-HyperVDeployment -Mode Fix
    - Interactive: .\HyperVDeployment.ps1 -Mode Menu

.NOTES
    Script:  HyperVDeployment.ps1
    Author:  Jeff Davidson
    Version: 2.4.0
    Date:    2026-03-11

    Exit Codes:
        0  - Success, deployment completed
        1  - Action required (reboot needed to finalize features)
        10 - Warning (partial completion, some steps had warnings)
        20 - Critical error (prerequisites not met or deployment failed)

.PARAMETER Mode
    Operation mode: Detect (preview only), Fix (deploy), Menu (interactive).

.PARAMETER TemplatePath
    Path to a YAML deployment template. Values override parameter defaults.
    Sections set to 'skip' or omitted entirely are excluded from deployment.
    Requires powershell-yaml module or uses built-in parser for simple templates.

.PARAMETER AutoReboot
    Automatically reboot if features require it.

.PARAMETER VSwitchName
    Name for the Hyper-V virtual switch. Default: vSwitch_Prod

.PARAMETER LanAdapters
    Physical NIC names to back the vSwitch.

.PARAMETER UseSET
    Prefer Switch Embedded Teaming over LBFO. Default: true.

.PARAMETER AllowManagementOS
    Create host vNIC on the vSwitch. Default: true.

.PARAMETER ManagementVLAN
    VLAN ID for the management vNIC. 0 = no VLAN tagging.

.PARAMETER JumboMTU
    Set Jumbo Frame MTU on LAN and iSCSI adapters. 0 = skip (default). Typical: 9014.

.PARAMETER IscsiAdapters
    Physical NIC names for dedicated iSCSI adapters.

.PARAMETER IscsiAdapterIPs
    IP addresses for iSCSI adapters (paired 1:1 with IscsiAdapters by index).

.PARAMETER IscsiSubnetPrefix
    Subnet prefix length for iSCSI adapter IPs. Default: 24.

.PARAMETER IscsiVLAN
    VLAN ID for iSCSI adapters. 0 = no VLAN tagging.

.PARAMETER TeamName
    LBFO team name when UseSET is false. Default: ProdTeam

.PARAMETER LbfoMode
    LBFO teaming mode: SwitchIndependent, LACP, Static.

.PARAMETER LbfoLba
    LBFO load balancing algorithm: Dynamic, TransportPorts, IPAddresses, MacAddresses.

.PARAMETER StorageMode
    Storage type: Local, iSCSI, or skip.

.PARAMETER InstallMPIO
    Install MPIO feature.

.PARAMETER EnableIscsiMultipath
    Enable multipath on iSCSI connections.

.PARAMETER IscsiTargetPortals
    iSCSI target portal IP addresses.

.PARAMETER IscsiAuth
    iSCSI authentication: None or OneWayCHAP.

.PARAMETER IscsiChapUsername
    CHAP username for OneWayCHAP authentication.

.PARAMETER IscsiChapSecret
    SecureString CHAP secret for OneWayCHAP authentication.

.PARAMETER IscsiTargetPortalPort
    iSCSI target portal port. 0 = use default (3260).

.PARAMETER MPIOPolicy
    MPIO load balance policy: RR, FOO, LQD, WP, RRWS. Default: RR.

.PARAMETER DiskTimeout
    Disk timeout in seconds for iSCSI/SAN disks. Default: 60.

.PARAMETER FormatVolumes
    Format iSCSI volumes after connection. Accepts an array of hashtables:
    @{ DiskNumber=1; DriveLetter='E'; Label='VMs'; FileSystem='ReFS'; AllocationUnit=65536 }
    Or use template key Storage.Volumes for YAML-based configuration.
    Skipped if empty (default). WARNING: Formats disks - data loss on targeted disks.

.PARAMETER InstallFailoverClustering
    Install Failover Clustering feature.

.PARAMETER ClusterName
    Name for the failover cluster.

.PARAMETER ClusterNodes
    Node names for the failover cluster.

.PARAMETER ClusterIP
    Static IP address for the cluster.

.PARAMETER Quorum
    Quorum type: None, FileShare, Disk.

.PARAMETER FileShareWitnessPath
    UNC path for file share witness when Quorum is FileShare.

.PARAMETER DiskWitnessResource
    Cluster disk resource name for Disk witness quorum (e.g., 'Cluster Disk 1').

.PARAMETER DefaultVMPath
    Default VM configuration storage path. Empty = skip.

.PARAMETER DefaultVHDPath
    Default VHD storage path. Empty = skip.

.PARAMETER PowerPlan
    Power plan: HighPerformance, Ultimate, or skip. Default: HighPerformance.

.PARAMETER NUMASpanning
    Enable or disable NUMA spanning. $null = skip (leave as-is).

.PARAMETER EnhancedSessionMode
    Enable or disable Enhanced Session Mode. $null = skip (leave as-is).

.PARAMETER DefenderExclusions
    Add Hyper-V Defender exclusions: true, false, or skip. Default: true.

.PARAMETER LiveMigrationProtocol
    Live Migration performance option: SMB, Compression, TCPIP, or skip.

.PARAMETER LiveMigrationAuth
    Live Migration authentication: Kerberos or CredSSP.

.PARAMETER LiveMigrationMaxConcurrent
    Maximum concurrent live migrations. Default: 2.

.PARAMETER RunPostAssessment
    Run HyperVAssessment in Quick mode after deployment. Default: false.

.PARAMETER OutputPath
    Directory for log and report files. Default: C:\Temp\HyperVDeployment

.PARAMETER Quiet
    Suppress console output for RMM execution.

.PARAMETER PassThru
    Return deployment results as objects for pipeline.

.PARAMETER AutoExport
    Automatically export reports to OutputPath.

.PARAMETER NinjaCustomField
    NinjaRMM text custom field name for summary output.

.PARAMETER NinjaHTMLField
    NinjaRMM WYSIWYG custom field name for HTML report.

.PARAMETER Force
    Skip confirmation prompts (for automation).

.EXAMPLE
    .\HyperVDeployment.ps1 -Mode Detect
    Preview planned configuration without making changes.

.EXAMPLE
    .\HyperVDeployment.ps1 -Mode Fix -TemplatePath .\templates\cluster-host.yaml -AutoExport
    Deploy using a YAML template with logging.

.EXAMPLE
    .\HyperVDeployment.ps1 -Mode Fix -LanAdapters "NIC1","NIC2" -DefaultVMPath "D:\VMs" -DefaultVHDPath "D:\VHDs" -AutoExport
    Deploy with custom paths and logging.

.EXAMPLE
    .\HyperVDeployment.ps1 -Mode Fix -Quiet -AutoExport -NinjaCustomField 'hvDeployStatus'
    RMM scheduled deployment with Ninja field output.

.EXAMPLE
    . .\HyperVDeployment.ps1
    Invoke-HyperVDeployment -Mode Fix -TemplatePath .\templates\standalone-host.yaml
    Dot-source and call the entry-point function with a template.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Position = 0)]
    [ValidateSet('Detect', 'Fix', 'Menu')]
    [string]$Mode = 'Detect',

    # Template
    [string]$TemplatePath = '',

    # General
    [switch]$AutoReboot,

    # Host Configuration
    [ValidateSet('HighPerformance', 'Ultimate', 'skip')]
    [string]$PowerPlan = 'HighPerformance',
    [System.Nullable[bool]]$NUMASpanning = $null,
    [System.Nullable[bool]]$EnhancedSessionMode = $null,
    [string]$DefaultVMPath = '',
    [string]$DefaultVHDPath = '',
    [string]$DefenderExclusions = 'true',

    # Hyper-V Networking
    [string]$VSwitchName = 'vSwitch_Prod',
    [string[]]$LanAdapters = @(),
    [switch]$UseSET = $true,
    [switch]$AllowManagementOS = $true,
    [int]$ManagementVLAN = 0,
    [int]$JumboMTU = 0,

    # iSCSI Dedicated NICs
    [string[]]$IscsiAdapters = @(),
    [string[]]$IscsiAdapterIPs = @(),
    [int]$IscsiSubnetPrefix = 24,
    [int]$IscsiVLAN = 0,

    # Legacy LBFO (if UseSET:$false)
    [string]$TeamName = 'ProdTeam',
    [ValidateSet('SwitchIndependent', 'LACP', 'Static')]
    [string]$LbfoMode = 'SwitchIndependent',
    [ValidateSet('Dynamic', 'TransportPorts', 'IPAddresses', 'MacAddresses')]
    [string]$LbfoLba = 'Dynamic',

    # Storage
    [ValidateSet('Local', 'iSCSI', 'skip')]
    [string]$StorageMode = 'Local',
    [switch]$InstallMPIO,
    [switch]$EnableIscsiMultipath,
    [string[]]$IscsiTargetPortals = @(),
    [ValidateSet('None', 'OneWayCHAP')]
    [string]$IscsiAuth = 'None',
    [string]$IscsiChapUsername = '',
    [System.Security.SecureString]$IscsiChapSecret,
    [int]$IscsiTargetPortalPort = 0,
    [ValidateSet('RR', 'FOO', 'LQD', 'WP', 'RRWS')]
    [string]$MPIOPolicy = 'RR',
    [int]$DiskTimeout = 60,
    [hashtable[]]$FormatVolumes = @(),

    # Failover Clustering
    [switch]$InstallFailoverClustering,
    [string]$ClusterName,
    [string[]]$ClusterNodes = @(),
    [string]$ClusterIP,
    [ValidateSet('None', 'FileShare', 'Disk')]
    [string]$Quorum = 'None',
    [string]$FileShareWitnessPath,
    [string]$DiskWitnessResource = '',

    # Live Migration
    [ValidateSet('SMB', 'Compression', 'TCPIP', 'skip')]
    [string]$LiveMigrationProtocol = 'skip',
    [ValidateSet('Kerberos', 'CredSSP')]
    [string]$LiveMigrationAuth = 'Kerberos',
    [int]$LiveMigrationMaxConcurrent = 2,

    # Post-Deploy
    [switch]$RunPostAssessment,

    # Output / RMM
    [string]$OutputPath = 'C:\Temp\HyperVDeployment',
    [switch]$Quiet,
    [switch]$PassThru,
    [switch]$AutoExport,
    [string]$NinjaCustomField = '',
    [string]$NinjaHTMLField = '',
    [switch]$Force
)

# ============================================================================
# SCRIPT CONFIGURATION
# ============================================================================

$script:ScriptVersion = '2.4.0'
$script:ScriptName    = 'HyperVDeployment'
$script:IsAdmin       = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$script:IsServer      = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue).ProductType -ne 1
$script:LogFile       = $null
$script:StepResults   = @()
$script:TotalSteps    = 8

# ============================================================================
# YAML TEMPLATE LOADER
# ============================================================================

function Import-DeploymentTemplate {
    param([string]$Path)

    if (-not $Path -or -not (Test-Path $Path)) {
        if ($Path) { throw "Template not found: $Path" }
        return $null
    }

    Write-Log "Loading template: $Path"
    $raw = Get-Content -Path $Path -Raw -Encoding UTF8

    # Try powershell-yaml module first
    if (Get-Module -ListAvailable -Name 'powershell-yaml' -ErrorAction SilentlyContinue) {
        Import-Module powershell-yaml -ErrorAction SilentlyContinue
        if (Get-Command -Name ConvertFrom-Yaml -ErrorAction SilentlyContinue) {
            Write-Log 'Using powershell-yaml module.' -Level 'DEBUG'
            return ConvertFrom-Yaml $raw
        }
    }

    # Built-in lightweight parser for simple YAML (key-value, arrays, one level nesting)
    Write-Log 'Using built-in YAML parser.' -Level 'DEBUG'
    return ConvertFrom-SimpleYaml $raw
}

function ConvertFrom-SimpleYaml {
    param([string]$Yaml)

    $result = @{}
    $currentSection = $null
    $lastArrayKey = $null
    $lines = $Yaml -split "`n" | ForEach-Object { $_.TrimEnd("`r") }

    foreach ($line in $lines) {
        # Skip empty lines and comments
        if ($line -match '^\s*$' -or $line -match '^\s*#') { continue }

        # Array item (  - value)
        if ($line -match '^(\s+)-\s+(.+)$') {
            $indent = $Matches[1].Length
            $value = $Matches[2].Trim().Trim('"').Trim("'")
            if ($indent -ge 4 -and $currentSection) {
                $lastKey = ($result[$currentSection].Keys | Select-Object -Last 1)
                if ($lastKey -and $result[$currentSection][$lastKey] -is [System.Collections.ArrayList]) {
                    $null = $result[$currentSection][$lastKey].Add($value)
                }
            } elseif ($currentSection -and $lastArrayKey) {
                if ($result[$currentSection][$lastArrayKey] -is [System.Collections.ArrayList]) {
                    $null = $result[$currentSection][$lastArrayKey].Add($value)
                }
            }
            continue
        }

        # Top-level key: value  OR  top-level key: (start of section)
        if ($line -match '^([A-Za-z]\w*):\s*(.*)$') {
            $key = $Matches[1]
            $val = $Matches[2].Trim().Trim('"').Trim("'")

            if ($val -eq '' -or $val -eq $null) {
                # Section header
                $currentSection = $key
                if (-not $result.ContainsKey($key)) { $result[$key] = @{} }
                $lastArrayKey = $null
            } else {
                # Top-level scalar
                $currentSection = $null
                $result[$key] = Convert-YamlValue $val
            }
            continue
        }

        # Indented key: value (nested under section)
        if ($line -match '^\s{2,}([A-Za-z]\w*):\s*(.*)$' -and $currentSection) {
            $key = $Matches[1]
            $val = $Matches[2].Trim().Trim('"').Trim("'")

            if ($val -eq '') {
                # Array follows
                $result[$currentSection][$key] = [System.Collections.ArrayList]@()
                $lastArrayKey = $key
            } else {
                $result[$currentSection][$key] = Convert-YamlValue $val
                $lastArrayKey = $null
            }
            continue
        }
    }
    return $result
}

function Convert-YamlValue {
    param([string]$Val)
    if ($Val -eq 'true')  { return $true }
    if ($Val -eq 'false') { return $false }
    if ($Val -eq 'skip')  { return 'skip' }
    if ($Val -eq 'null' -or $Val -eq '~') { return $null }
    if ($Val -match '^\d+$') { return [int]$Val }
    return $Val
}

function Merge-TemplateValues {
    param([hashtable]$Template)
    if (-not $Template) { return }

    # Helper: only override if not explicitly set via command-line
    # Template values act as defaults, command-line params win

    # Top-level scalars
    if ($Template.ContainsKey('Mode') -and -not $PSBoundParameters.ContainsKey('Mode')) {
        $script:Mode = $Template['Mode']
    }

    # HostConfig section
    $hc = $Template['HostConfig']
    if ($hc -is [hashtable]) {
        if ($hc.ContainsKey('PowerPlan') -and -not $PSBoundParameters.ContainsKey('PowerPlan')) {
            $script:PowerPlan = [string]$hc['PowerPlan']
        }
        if ($hc.ContainsKey('NUMASpanning') -and -not $PSBoundParameters.ContainsKey('NUMASpanning')) {
            $script:NUMASpanning = $hc['NUMASpanning']
        }
        if ($hc.ContainsKey('EnhancedSessionMode') -and -not $PSBoundParameters.ContainsKey('EnhancedSessionMode')) {
            $script:EnhancedSessionMode = $hc['EnhancedSessionMode']
        }
        if ($hc.ContainsKey('DefaultVMPath') -and -not $PSBoundParameters.ContainsKey('DefaultVMPath')) {
            $script:DefaultVMPath = [string]$hc['DefaultVMPath']
        }
        if ($hc.ContainsKey('DefaultVHDPath') -and -not $PSBoundParameters.ContainsKey('DefaultVHDPath')) {
            $script:DefaultVHDPath = [string]$hc['DefaultVHDPath']
        }
    } elseif ($hc -eq 'skip') {
        if (-not $PSBoundParameters.ContainsKey('PowerPlan')) { $script:PowerPlan = 'skip' }
        if (-not $PSBoundParameters.ContainsKey('DefaultVMPath')) { $script:DefaultVMPath = '' }
        if (-not $PSBoundParameters.ContainsKey('DefaultVHDPath')) { $script:DefaultVHDPath = '' }
    }

    # Defender section
    $def = $Template['Defender']
    if ($def -is [hashtable]) {
        if ($def.ContainsKey('AddExclusions') -and -not $PSBoundParameters.ContainsKey('DefenderExclusions')) {
            $script:DefenderExclusions = [string]$def['AddExclusions']
        }
    } elseif ($null -ne $def -and -not $PSBoundParameters.ContainsKey('DefenderExclusions')) {
        $script:DefenderExclusions = [string]$def
    }

    # Networking section
    $net = $Template['Networking']
    if ($net -is [hashtable]) {
        if ($net.ContainsKey('VSwitchName') -and -not $PSBoundParameters.ContainsKey('VSwitchName')) {
            $script:VSwitchName = [string]$net['VSwitchName']
        }
        if ($net.ContainsKey('LanAdapters') -and -not $PSBoundParameters.ContainsKey('LanAdapters')) {
            $script:LanAdapters = @($net['LanAdapters'])
        }
        if ($net.ContainsKey('UseSET') -and -not $PSBoundParameters.ContainsKey('UseSET')) {
            $script:UseSET = [bool]$net['UseSET']
        }
        if ($net.ContainsKey('AllowManagementOS') -and -not $PSBoundParameters.ContainsKey('AllowManagementOS')) {
            $script:AllowManagementOS = [bool]$net['AllowManagementOS']
        }
        if ($net.ContainsKey('ManagementVLAN') -and -not $PSBoundParameters.ContainsKey('ManagementVLAN')) {
            $script:ManagementVLAN = [int]$net['ManagementVLAN']
        }
        if ($net.ContainsKey('TeamName') -and -not $PSBoundParameters.ContainsKey('TeamName')) {
            $script:TeamName = [string]$net['TeamName']
        }
        if ($net.ContainsKey('LbfoMode') -and -not $PSBoundParameters.ContainsKey('LbfoMode')) {
            $script:LbfoMode = [string]$net['LbfoMode']
        }
        if ($net.ContainsKey('LbfoLba') -and -not $PSBoundParameters.ContainsKey('LbfoLba')) {
            $script:LbfoLba = [string]$net['LbfoLba']
        }
        if ($net.ContainsKey('JumboMTU') -and -not $PSBoundParameters.ContainsKey('JumboMTU')) {
            $script:JumboMTU = [int]$net['JumboMTU']
        }
        if ($net.ContainsKey('IscsiAdapters') -and -not $PSBoundParameters.ContainsKey('IscsiAdapters')) {
            $script:IscsiAdapters = @($net['IscsiAdapters'])
        }
        if ($net.ContainsKey('IscsiAdapterIPs') -and -not $PSBoundParameters.ContainsKey('IscsiAdapterIPs')) {
            $script:IscsiAdapterIPs = @($net['IscsiAdapterIPs'])
        }
        if ($net.ContainsKey('IscsiSubnetPrefix') -and -not $PSBoundParameters.ContainsKey('IscsiSubnetPrefix')) {
            $script:IscsiSubnetPrefix = [int]$net['IscsiSubnetPrefix']
        }
        if ($net.ContainsKey('IscsiVLAN') -and -not $PSBoundParameters.ContainsKey('IscsiVLAN')) {
            $script:IscsiVLAN = [int]$net['IscsiVLAN']
        }
    }

    # Storage section
    $stor = $Template['Storage']
    if ($stor -is [hashtable]) {
        if ($stor.ContainsKey('Mode') -and -not $PSBoundParameters.ContainsKey('StorageMode')) {
            $script:StorageMode = [string]$stor['Mode']
        }
        if ($stor.ContainsKey('InstallMPIO') -and -not $PSBoundParameters.ContainsKey('InstallMPIO')) {
            $script:InstallMPIO = [bool]$stor['InstallMPIO']
        }
        if ($stor.ContainsKey('EnableMultipath') -and -not $PSBoundParameters.ContainsKey('EnableIscsiMultipath')) {
            $script:EnableIscsiMultipath = [bool]$stor['EnableMultipath']
        }
        if ($stor.ContainsKey('DiskTimeout') -and -not $PSBoundParameters.ContainsKey('DiskTimeout')) {
            $script:DiskTimeout = [int]$stor['DiskTimeout']
        }
        if ($stor.ContainsKey('TargetPortals') -and -not $PSBoundParameters.ContainsKey('IscsiTargetPortals')) {
            $script:IscsiTargetPortals = @($stor['TargetPortals'])
        }
        if ($stor.ContainsKey('Auth') -and -not $PSBoundParameters.ContainsKey('IscsiAuth')) {
            $script:IscsiAuth = [string]$stor['Auth']
        }
        if ($stor.ContainsKey('ChapUsername') -and -not $PSBoundParameters.ContainsKey('IscsiChapUsername')) {
            $script:IscsiChapUsername = [string]$stor['ChapUsername']
        }
        if ($stor.ContainsKey('TargetPortalPort') -and -not $PSBoundParameters.ContainsKey('IscsiTargetPortalPort')) {
            $script:IscsiTargetPortalPort = [int]$stor['TargetPortalPort']
        }
        if ($stor.ContainsKey('MPIOPolicy') -and -not $PSBoundParameters.ContainsKey('MPIOPolicy')) {
            $script:MPIOPolicy = [string]$stor['MPIOPolicy']
        }
        if ($stor.ContainsKey('Volumes') -and -not $PSBoundParameters.ContainsKey('FormatVolumes')) {
            # Volumes can be array of strings "DiskNum:DriveLetter:Label:FileSystem:AllocationUnit"
            # or array of hashtables (from powershell-yaml)
            $script:FormatVolumes = @($stor['Volumes'] | ForEach-Object {
                if ($_ -is [hashtable]) {
                    @{
                        DiskNumber     = if ($_.ContainsKey('DiskNumber'))     { [int]$_['DiskNumber'] }     else { -1 }
                        DriveLetter    = if ($_.ContainsKey('DriveLetter'))    { [string]$_['DriveLetter'] }  else { '' }
                        Label          = if ($_.ContainsKey('Label'))          { [string]$_['Label'] }        else { '' }
                        FileSystem     = if ($_.ContainsKey('FileSystem'))     { [string]$_['FileSystem'] }   else { 'ReFS' }
                        AllocationUnit = if ($_.ContainsKey('AllocationUnit')) { [int]$_['AllocationUnit'] }  else { 65536 }
                    }
                } elseif ($_ -is [string] -and $_.Contains(':')) {
                    $parts = $_.Split(':')
                    @{
                        DiskNumber     = if ($parts.Count -gt 0 -and $parts[0]) { [int]$parts[0] } else { -1 }
                        DriveLetter    = if ($parts.Count -gt 1) { $parts[1] } else { '' }
                        Label          = if ($parts.Count -gt 2) { $parts[2] } else { '' }
                        FileSystem     = if ($parts.Count -gt 3 -and $parts[3]) { $parts[3] } else { 'ReFS' }
                        AllocationUnit = if ($parts.Count -gt 4 -and $parts[4]) { [int]$parts[4] } else { 65536 }
                    }
                }
            } | Where-Object { $_ })
        }
    } elseif ($stor -eq 'skip' -and -not $PSBoundParameters.ContainsKey('StorageMode')) {
        $script:StorageMode = 'skip'
    }

    # Clustering section
    $cl = $Template['Clustering']
    if ($cl -is [hashtable]) {
        if (-not $PSBoundParameters.ContainsKey('InstallFailoverClustering')) {
            $script:InstallFailoverClustering = $true
        }
        if ($cl.ContainsKey('ClusterName') -and -not $PSBoundParameters.ContainsKey('ClusterName')) {
            $script:ClusterName = [string]$cl['ClusterName']
        }
        if ($cl.ContainsKey('ClusterNodes') -and -not $PSBoundParameters.ContainsKey('ClusterNodes')) {
            $script:ClusterNodes = @($cl['ClusterNodes'])
        }
        if ($cl.ContainsKey('ClusterIP') -and -not $PSBoundParameters.ContainsKey('ClusterIP')) {
            $script:ClusterIP = [string]$cl['ClusterIP']
        }
        if ($cl.ContainsKey('Quorum') -and -not $PSBoundParameters.ContainsKey('Quorum')) {
            $script:Quorum = [string]$cl['Quorum']
        }
        if ($cl.ContainsKey('FileShareWitnessPath') -and -not $PSBoundParameters.ContainsKey('FileShareWitnessPath')) {
            $script:FileShareWitnessPath = [string]$cl['FileShareWitnessPath']
        }
        if ($cl.ContainsKey('DiskWitnessResource') -and -not $PSBoundParameters.ContainsKey('DiskWitnessResource')) {
            $script:DiskWitnessResource = [string]$cl['DiskWitnessResource']
        }
    } elseif ($cl -eq 'skip') {
        if (-not $PSBoundParameters.ContainsKey('InstallFailoverClustering')) {
            $script:InstallFailoverClustering = $false
        }
    }

    # LiveMigration section
    $lm = $Template['LiveMigration']
    if ($lm -is [hashtable]) {
        if ($lm.ContainsKey('Protocol') -and -not $PSBoundParameters.ContainsKey('LiveMigrationProtocol')) {
            $script:LiveMigrationProtocol = [string]$lm['Protocol']
        }
        if ($lm.ContainsKey('Auth') -and -not $PSBoundParameters.ContainsKey('LiveMigrationAuth')) {
            $script:LiveMigrationAuth = [string]$lm['Auth']
        }
        if ($lm.ContainsKey('MaxConcurrent') -and -not $PSBoundParameters.ContainsKey('LiveMigrationMaxConcurrent')) {
            $script:LiveMigrationMaxConcurrent = [int]$lm['MaxConcurrent']
        }
    } elseif ($lm -eq 'skip' -and -not $PSBoundParameters.ContainsKey('LiveMigrationProtocol')) {
        $script:LiveMigrationProtocol = 'skip'
    }

    # PostDeploy section
    $pd = $Template['PostDeploy']
    if ($pd -is [hashtable]) {
        if ($pd.ContainsKey('RunAssessment') -and -not $PSBoundParameters.ContainsKey('RunPostAssessment')) {
            $script:RunPostAssessment = [bool]$pd['RunAssessment']
        }
    }

    Write-Log 'Template values merged.' -Level 'SUCCESS'
}

# ============================================================================
# LOGGING
# ============================================================================

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS', 'DEBUG')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logLine = "[$timestamp] [$Level] $Message"

    if (-not $Quiet) {
        $color = switch ($Level) {
            'INFO'    { 'White' }
            'WARN'    { 'Yellow' }
            'ERROR'   { 'Red' }
            'SUCCESS' { 'Green' }
            'DEBUG'   { 'Gray' }
        }
        Write-Host $logLine -ForegroundColor $color
    }

    if ($script:LogFile) {
        $logLine | Out-File -FilePath $script:LogFile -Encoding UTF8 -Append
    }
}

# ============================================================================
# OUTPUT FUNCTIONS
# ============================================================================

function Initialize-OutputDirectory {
    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
        Write-Log "Created output directory: $OutputPath" -Level 'DEBUG'
    }
    $script:LogFile = Join-Path $OutputPath "$script:ScriptName`_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
}

function Export-Results {
    param(
        [Parameter(Mandatory)]
        [object]$Results
    )

    if (-not $AutoExport) { return }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $jsonPath = Join-Path $OutputPath "$script:ScriptName`_$timestamp.json"

    $Results | ConvertTo-Json -Depth 5 | Out-File -FilePath $jsonPath -Encoding UTF8
    Write-Log "Exported JSON: $jsonPath" -Level 'SUCCESS'
}

function Write-NinjaOutput {
    param(
        [string]$Summary,
        [string]$HTMLReport
    )

    if ($NinjaCustomField -and $Summary) {
        try {
            Ninja-Property-Set $NinjaCustomField $Summary
            Write-Log "Updated Ninja field: $NinjaCustomField" -Level 'DEBUG'
        } catch {
            Write-Log "Failed to set Ninja field: $_" -Level 'WARN'
        }
    }

    if ($NinjaHTMLField -and $HTMLReport) {
        try {
            Ninja-Property-Set $NinjaHTMLField $HTMLReport
            Write-Log "Updated Ninja HTML field: $NinjaHTMLField" -Level 'DEBUG'
        } catch {
            Write-Log "Failed to set Ninja HTML field: $_" -Level 'WARN'
        }
    }
}

# ============================================================================
# STEP TRACKING & VALIDATION
# ============================================================================

function Add-StepResult {
    param(
        [string]$Step,
        [ValidateSet('Pass', 'Fail', 'Warning', 'Skipped')]
        [string]$Status,
        [string]$Detail
    )
    $script:StepResults += [PSCustomObject]@{
        Step      = $Step
        Status    = $Status
        Detail    = $Detail
        Timestamp = Get-Date -Format 'o'
    }
    $level = switch ($Status) {
        'Pass'    { 'SUCCESS' }
        'Fail'    { 'ERROR' }
        'Warning' { 'WARN' }
        'Skipped' { 'INFO' }
    }
    Write-Log "  [$Status] $Step - $Detail" -Level $level
}

function Test-FeatureInstalled {
    param([string]$FeatureName)
    $f = Get-WindowsFeature -Name $FeatureName -ErrorAction SilentlyContinue
    return ($f -and $f.InstallState -eq 'Installed')
}

# ============================================================================
# DEPLOYMENT HELPERS
# ============================================================================

function Install-RequiredFeatures {
    param(
        [switch]$HyperV,
        [switch]$Clustering,
        [switch]$MPIO
    )
    $rebootNeeded = $false
    if ($HyperV) {
        Write-Log 'Installing Hyper-V features...'
        $r = Install-WindowsFeature -Name Hyper-V, Hyper-V-PowerShell -IncludeManagementTools -ErrorAction Stop
        if ($r.RestartNeeded -ne 'No') { $rebootNeeded = $true }
    }
    if ($Clustering) {
        Write-Log 'Installing Failover Clustering features...'
        $r = Install-WindowsFeature -Name Failover-Clustering, RSAT-Clustering, RSAT-Clustering-PowerShell -IncludeManagementTools -ErrorAction Stop
        if ($r.RestartNeeded -ne 'No') { $rebootNeeded = $true }
    }
    if ($MPIO) {
        Write-Log 'Installing Multipath-IO feature...'
        $r = Install-WindowsFeature -Name Multipath-IO -ErrorAction Stop
        if ($r.RestartNeeded -ne 'No') { $rebootNeeded = $true }
    }
    return $rebootNeeded
}

function Set-ServiceRunning {
    param([string]$Name, [string]$StartupType = 'Automatic')
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { throw "Service $Name not found." }
    if ($svc.StartType -ne $StartupType) { Set-Service -Name $Name -StartupType $StartupType }
    if ($svc.Status -ne 'Running') { Start-Service -Name $Name -ErrorAction Stop }
}

function Initialize-VSwitch {
    param(
        [string]$Name,
        [string[]]$Adapters,
        [switch]$UseSET,
        [switch]$AllowManagementOS,
        [string]$TeamName,
        [string]$LbfoMode,
        [string]$LbfoLba
    )
    $existing = Get-VMSwitch -Name $Name -ErrorAction SilentlyContinue
    if ($existing) { Write-Log "vSwitch '$Name' already exists - skipping." -Level 'DEBUG'; return }

    if ($Adapters.Count -eq 0) { throw 'LanAdapters is empty; provide at least one adapter name.' }

    if ($UseSET) {
        Write-Log "Creating SET vSwitch '$Name' on adapters: $($Adapters -join ', ')"
        New-VMSwitch -Name $Name -NetAdapterName $Adapters -EnableEmbeddedTeaming $true -AllowManagementOS:$AllowManagementOS | Out-Null
    } else {
        if ($Adapters.Count -lt 2) { throw 'LBFO requires at least 2 adapters.' }
        $team = Get-NetLbfoTeam -Name $TeamName -ErrorAction SilentlyContinue
        if (-not $team) {
            Write-Log "Creating LBFO team '$TeamName'..."
            New-NetLbfoTeam -Name $TeamName -TeamMembers $Adapters -TeamingMode $LbfoMode -LoadBalancingAlgorithm $LbfoLba | Out-Null
        }
        Write-Log "Creating vSwitch '$Name' on LBFO team '$TeamName'..."
        New-VMSwitch -Name $Name -NetAdapterName $TeamName -AllowManagementOS:$AllowManagementOS | Out-Null
    }
}

function SecureStringToPlain {
    param([System.Security.SecureString]$Secure)
    if (-not $Secure) { return $null }
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
    finally { if ($b) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) } }
}

function Set-IscsiAndMPIO {
    param(
        [string[]]$Portals,
        [string[]]$InitiatorIPs = @(),
        [ValidateSet('None', 'OneWayCHAP')]$Auth = 'None',
        [string]$ChapUsername = '',
        [System.Security.SecureString]$ChapSecret,
        [int]$PortalPort = 0,
        [string]$Policy = 'RR',
        [switch]$EnableMultipath
    )

    Set-ServiceRunning -Name 'MSiSCSI' -StartupType 'Automatic'
    Write-Log 'MSiSCSI service running.'

    $cleanPortals = @($Portals | Where-Object { $_ -and $_.Trim().Length -gt 0 } | Select-Object -Unique)
    foreach ($i in 0..($cleanPortals.Count - 1)) {
        $p = $cleanPortals[$i]
        $existing = Get-IscsiTargetPortal -ErrorAction SilentlyContinue | Where-Object { $_.TargetPortalAddress -eq $p }
        if (-not $existing) {
            $portalParams = @{ TargetPortalAddress = $p }
            if ($PortalPort -gt 0) { $portalParams['TargetPortalPortNumber'] = $PortalPort }
            if ($InitiatorIPs.Count -gt $i -and $InitiatorIPs[$i]) {
                $portalParams['InitiatorPortalAddress'] = $InitiatorIPs[$i]
                Write-Log "Adding iSCSI target portal: $p bound to initiator $($InitiatorIPs[$i])"
            } else {
                Write-Log "Adding iSCSI target portal: $p (no initiator binding)"
            }
            New-IscsiTargetPortal @portalParams | Out-Null
        }
    }

    $targets = @(Get-IscsiTarget -ErrorAction SilentlyContinue)
    foreach ($t in $targets) {
        if ($t.IsConnected) { continue }
        $params = @{ NodeAddress = $t.NodeAddress; IsPersistent = $true }
        if ($EnableMultipath) { $params['IsMultipathEnabled'] = $true }

        if ($Auth -eq 'OneWayCHAP' -and $ChapSecret) {
            $plain = SecureStringToPlain $ChapSecret
            $params['AuthenticationType'] = 'OneWayCHAP'
            $params['ChapSecret'] = $plain
            if ($ChapUsername) { $params['ChapUsername'] = $ChapUsername }
            Write-Log "Connecting to target $($t.NodeAddress) with CHAP..."
        } else {
            Write-Log "Connecting to target $($t.NodeAddress)..."
        }
        Connect-IscsiTarget @params | Out-Null
    }

    if ($EnableMultipath) {
        Write-Log "Enabling MSDSM auto-claim for iSCSI and $Policy policy..."
        Enable-MSDSMAutomaticClaim -BusType iSCSI | Out-Null
        Set-MSDSMGlobalDefaultLoadBalancePolicy -Policy $Policy | Out-Null
    }
}

# ============================================================================
# CORE MODES
# ============================================================================

function Invoke-DetectMode {
    Write-Log "$script:ScriptName v$script:ScriptVersion - Preview Mode" -Level 'INFO'
    Write-Log ('-' * 60) -Level 'INFO'
    if ($TemplatePath) { Write-Log "Template: $TemplatePath" }

    # Current state detection
    $hvFeature = Get-WindowsFeature -Name Hyper-V -ErrorAction SilentlyContinue
    $clusterFeature = Get-WindowsFeature -Name Failover-Clustering -ErrorAction SilentlyContinue
    $mpioFeature = Get-WindowsFeature -Name Multipath-IO -ErrorAction SilentlyContinue
    $existingSwitch = Get-VMSwitch -Name $VSwitchName -ErrorAction SilentlyContinue

    Write-Log ''
    Write-Log '=== Current State ===' -Level 'INFO'
    Write-Log "  Hyper-V:             $(if ($hvFeature.Installed) { 'Installed' } else { 'Not installed' })"
    Write-Log "  Failover Clustering: $(if ($clusterFeature.Installed) { 'Installed' } else { 'Not installed' })"
    Write-Log "  Multipath-IO:        $(if ($mpioFeature.Installed) { 'Installed' } else { 'Not installed' })"
    Write-Log "  vSwitch '$VSwitchName': $(if ($existingSwitch) { 'Exists' } else { 'Not found' })"

    # Current host config
    try {
        $vmHost = Get-VMHost -ErrorAction SilentlyContinue
        if ($vmHost) {
            Write-Log "  Default VM Path:     $($vmHost.VirtualMachinePath)"
            Write-Log "  Default VHD Path:    $($vmHost.VirtualHardDiskPath)"
            Write-Log "  Enhanced Session:    $($vmHost.EnableEnhancedSessionMode)"
            Write-Log "  NUMA Spanning:       $($vmHost.NumaSpanningEnabled)"
        }
    } catch { }

    $activePlan = powercfg /getactivescheme 2>$null
    if ($activePlan) {
        $planName = if ($activePlan -match '\(([^)]+)\)') { $Matches[1] } else { 'Unknown' }
        Write-Log "  Power Plan:          $planName"
    }

    Write-Log ''
    Write-Log '=== Planned Configuration (8 Steps) ===' -Level 'INFO'

    # Step 1: Features
    Write-Log '  [1] Features'
    if (-not $hvFeature.Installed) { Write-Log '      [INSTALL] Hyper-V + management tools' }
    else { Write-Log '      [SKIP] Hyper-V already installed' }

    $needCluster = [bool]$InstallFailoverClustering
    if ($needCluster -and -not $clusterFeature.Installed) { Write-Log '      [INSTALL] Failover Clustering + RSAT tools' }
    $needMpio = [bool]$InstallMPIO -or ($StorageMode -eq 'iSCSI' -and $EnableIscsiMultipath)
    if ($needMpio -and -not $mpioFeature.Installed) { Write-Log '      [INSTALL] Multipath-IO' }

    # Step 2: Host Config
    Write-Log '  [2] Host Configuration'
    if ($PowerPlan -ne 'skip') { Write-Log "      [SET] Power plan: $PowerPlan" }
    else { Write-Log '      [SKIP] Power plan' }
    if ($null -ne $NUMASpanning) { Write-Log "      [SET] NUMA Spanning: $NUMASpanning" }
    else { Write-Log '      [SKIP] NUMA Spanning (leave as-is)' }
    if ($null -ne $EnhancedSessionMode) { Write-Log "      [SET] Enhanced Session Mode: $EnhancedSessionMode" }
    else { Write-Log '      [SKIP] Enhanced Session Mode (leave as-is)' }
    if ($DefaultVMPath) { Write-Log "      [SET] Default VM Path: $DefaultVMPath" }
    if ($DefaultVHDPath) { Write-Log "      [SET] Default VHD Path: $DefaultVHDPath" }

    # Step 3: Defender
    Write-Log '  [3] Defender Exclusions'
    if ($DefenderExclusions -eq 'true') { Write-Log '      [ADD] Hyper-V process, extension, and path exclusions' }
    else { Write-Log '      [SKIP] Defender exclusions' }

    # Step 4: Networking
    Write-Log '  [4] Networking'
    if ($LanAdapters.Count -gt 0) {
        Write-Log "      [CONFIGURE] vSwitch '$VSwitchName' on $(if ($UseSET) { 'SET' } else { 'LBFO' }): $($LanAdapters -join ', ')"
        if ($ManagementVLAN -gt 0) { Write-Log "      [SET] Management vNIC VLAN: $ManagementVLAN" }
        if ($JumboMTU -gt 0) { Write-Log "      [SET] Jumbo Frames MTU: $JumboMTU on $($LanAdapters -join ', ')" }
    } else {
        Write-Log '      [SKIP] No LanAdapters specified'
    }
    if ($IscsiAdapters.Count -gt 0) {
        Write-Log "      [CONFIGURE] iSCSI NICs: $($IscsiAdapters -join ', ')"
        for ($i = 0; $i -lt $IscsiAdapters.Count; $i++) {
            $ip = if ($IscsiAdapterIPs.Count -gt $i) { $IscsiAdapterIPs[$i] } else { '(no IP)' }
            Write-Log "        $($IscsiAdapters[$i]) = $ip/$IscsiSubnetPrefix"
        }
        if ($IscsiVLAN -gt 0) { Write-Log "      [SET] iSCSI VLAN: $IscsiVLAN" }
        if ($JumboMTU -gt 0) { Write-Log "      [SET] Jumbo Frames on iSCSI NICs: $JumboMTU" }
    }

    # Step 5: Storage
    Write-Log '  [5] Storage'
    if ($StorageMode -eq 'iSCSI') {
        Write-Log "      [CONFIGURE] iSCSI - $($IscsiTargetPortals.Count) portal(s), auth=$IscsiAuth, multipath=$EnableIscsiMultipath, MPIO=$MPIOPolicy"
        if ($IscsiAdapterIPs.Count -gt 0) { Write-Log "      [BIND] Initiator IPs: $($IscsiAdapterIPs -join ', ') (paired 1:1 with portals)" }
        if ($IscsiTargetPortalPort -gt 0) { Write-Log "      [SET] Portal port: $IscsiTargetPortalPort" }
        Write-Log "      [SET] Disk timeout: ${DiskTimeout}s"
        if ($FormatVolumes.Count -gt 0) {
            Write-Log "      [FORMAT] $($FormatVolumes.Count) volume(s) to initialize:"
            foreach ($fv in $FormatVolumes) {
                $auKB = [math]::Round($fv.AllocationUnit / 1024)
                Write-Log "        Disk $($fv.DiskNumber) -> $($fv.DriveLetter): '$($fv.Label)' $($fv.FileSystem) ${auKB}KB"
            }
        }
    } elseif ($StorageMode -eq 'skip') {
        Write-Log '      [SKIP] Storage configuration'
    } else {
        Write-Log '      [LOCAL] No iSCSI configuration'
    }

    # Step 6: Clustering
    Write-Log '  [6] Failover Clustering'
    if ($InstallFailoverClustering -and $ClusterName) {
        Write-Log "      [CREATE] Cluster '$ClusterName' ($($ClusterNodes.Count) nodes), quorum=$Quorum"
    } else {
        Write-Log '      [SKIP] Clustering not requested'
    }

    # Step 7: Live Migration
    Write-Log '  [7] Live Migration'
    if ($LiveMigrationProtocol -ne 'skip') {
        Write-Log "      [SET] Protocol=$LiveMigrationProtocol, Auth=$LiveMigrationAuth, Max=$LiveMigrationMaxConcurrent"
    } else {
        Write-Log '      [SKIP] Live Migration configuration'
    }

    # Step 8: Post-Deploy
    Write-Log '  [8] Post-Deploy'
    if ($RunPostAssessment) { Write-Log '      [RUN] HyperVAssessment -Mode Quick' }
    else { Write-Log '      [SKIP] Post-deploy assessment' }

    Write-Log ''
    Write-Log 'Preview complete. Use -Mode Fix to apply.' -Level 'INFO'

    $results = [PSCustomObject]@{
        Timestamp    = Get-Date -Format 'o'
        ComputerName = $env:COMPUTERNAME
        Mode         = 'Detect'
        Template     = $TemplatePath
        Steps        = @()
    }

    Export-Results -Results $results
    if ($PassThru) { return $results }
    return 0
}

function Invoke-FixMode {
    Write-Log "$script:ScriptName v$script:ScriptVersion - Deploy Mode" -Level 'INFO'
    Write-Log ('-' * 60) -Level 'INFO'
    Write-Log "Target: $env:COMPUTERNAME | Admin: $script:IsAdmin | Server OS: $script:IsServer"
    if ($TemplatePath) { Write-Log "Template: $TemplatePath" }

    # Pre-flight
    if (-not $script:IsAdmin) {
        Write-Log 'ERROR: Must run in an elevated PowerShell session.' -Level 'ERROR'
        Add-StepResult -Step 'Pre-flight' -Status 'Fail' -Detail 'Not running as Administrator'
        return 20
    }

    if (-not $script:IsServer) {
        Write-Log 'WARNING: Not a Server OS - Hyper-V feature install may differ.' -Level 'WARN'
    }

    $script:StepResults = @()
    $rebootNeeded = $false

    # ── Step 1/8: Install Features ──
    Write-Log ''
    Write-Log "== Step 1/$script:TotalSteps : Windows Features ==" -Level 'INFO'

    $needHyperV  = $true
    $needCluster = [bool]$InstallFailoverClustering
    $needMpio    = [bool]$InstallMPIO -or ($StorageMode -eq 'iSCSI' -and $EnableIscsiMultipath)

    try {
        $rebootNeeded = Install-RequiredFeatures -HyperV:$needHyperV -Clustering:$needCluster -MPIO:$needMpio
    } catch {
        Add-StepResult -Step 'Feature Install' -Status 'Fail' -Detail $_.Exception.Message
        return 20
    }

    if (Test-FeatureInstalled 'Hyper-V') {
        Add-StepResult -Step 'Hyper-V Feature' -Status 'Pass' -Detail 'Installed'
    } else {
        Add-StepResult -Step 'Hyper-V Feature' -Status 'Warning' -Detail 'Reboot likely required'
    }
    if ($needCluster) {
        if (Test-FeatureInstalled 'Failover-Clustering') {
            Add-StepResult -Step 'Failover Clustering Feature' -Status 'Pass' -Detail 'Installed'
        } else {
            Add-StepResult -Step 'Failover Clustering Feature' -Status 'Warning' -Detail 'Reboot may be required'
        }
    }
    if ($needMpio) {
        if (Test-FeatureInstalled 'Multipath-IO') {
            Add-StepResult -Step 'Multipath-IO Feature' -Status 'Pass' -Detail 'Installed'
        } else {
            Add-StepResult -Step 'Multipath-IO Feature' -Status 'Warning' -Detail 'Reboot may be required'
        }
    }

    # ── Step 2/8: Host Configuration ──
    Write-Log ''
    Write-Log "== Step 2/$script:TotalSteps : Host Configuration ==" -Level 'INFO'

    # Power Plan
    if ($PowerPlan -ne 'skip') {
        try {
            $planGuid = switch ($PowerPlan) {
                'HighPerformance' { '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' }
                'Ultimate'        { 'e9a42b02-d5df-448d-aa00-03f14749eb61' }
            }
            if ($PSCmdlet.ShouldProcess("Power plan: $PowerPlan", 'Set active power plan')) {
                $null = powercfg /setactive $planGuid 2>&1
            }
            # Validate
            $active = powercfg /getactivescheme 2>$null
            if ($active -match $planGuid) {
                Add-StepResult -Step 'Power Plan' -Status 'Pass' -Detail "$PowerPlan active"
            } else {
                Add-StepResult -Step 'Power Plan' -Status 'Warning' -Detail "Set to $PowerPlan but verification inconclusive"
            }
        } catch {
            Add-StepResult -Step 'Power Plan' -Status 'Fail' -Detail $_.Exception.Message
        }
    } else {
        Add-StepResult -Step 'Power Plan' -Status 'Skipped' -Detail 'Not configured (skip)'
    }

    # NUMA Spanning
    if ($null -ne $NUMASpanning) {
        try {
            if ($PSCmdlet.ShouldProcess("NUMA Spanning: $NUMASpanning", 'Set NUMA spanning')) {
                Set-VMHost -NumaSpanningEnabled $NUMASpanning -ErrorAction Stop
            }
            $current = (Get-VMHost -ErrorAction SilentlyContinue).NumaSpanningEnabled
            if ($current -eq $NUMASpanning) {
                Add-StepResult -Step 'NUMA Spanning' -Status 'Pass' -Detail "Set to $NUMASpanning"
            } else {
                Add-StepResult -Step 'NUMA Spanning' -Status 'Warning' -Detail "Expected $NUMASpanning, got $current"
            }
        } catch {
            Add-StepResult -Step 'NUMA Spanning' -Status 'Fail' -Detail $_.Exception.Message
        }
    } else {
        Add-StepResult -Step 'NUMA Spanning' -Status 'Skipped' -Detail 'Not specified'
    }

    # Enhanced Session Mode
    if ($null -ne $EnhancedSessionMode) {
        try {
            if ($PSCmdlet.ShouldProcess("Enhanced Session Mode: $EnhancedSessionMode", 'Set Enhanced Session Mode')) {
                Set-VMHost -EnableEnhancedSessionMode $EnhancedSessionMode -ErrorAction Stop
            }
            $current = (Get-VMHost -ErrorAction SilentlyContinue).EnableEnhancedSessionMode
            if ($current -eq $EnhancedSessionMode) {
                Add-StepResult -Step 'Enhanced Session Mode' -Status 'Pass' -Detail "Set to $EnhancedSessionMode"
            } else {
                Add-StepResult -Step 'Enhanced Session Mode' -Status 'Warning' -Detail "Expected $EnhancedSessionMode, got $current"
            }
        } catch {
            Add-StepResult -Step 'Enhanced Session Mode' -Status 'Fail' -Detail $_.Exception.Message
        }
    } else {
        Add-StepResult -Step 'Enhanced Session Mode' -Status 'Skipped' -Detail 'Not specified'
    }

    # Default Paths
    if ($DefaultVMPath) {
        try {
            if (-not (Test-Path $DefaultVMPath)) {
                New-Item -ItemType Directory -Path $DefaultVMPath -Force | Out-Null
                Write-Log "Created directory: $DefaultVMPath" -Level 'DEBUG'
            }
            if ($PSCmdlet.ShouldProcess($DefaultVMPath, 'Set default VM path')) {
                Set-VMHost -VirtualMachinePath $DefaultVMPath -ErrorAction Stop
            }
            $current = (Get-VMHost -ErrorAction SilentlyContinue).VirtualMachinePath
            if ($current -eq $DefaultVMPath) {
                Add-StepResult -Step 'Default VM Path' -Status 'Pass' -Detail $DefaultVMPath
            } else {
                Add-StepResult -Step 'Default VM Path' -Status 'Warning' -Detail "Expected '$DefaultVMPath', got '$current'"
            }
        } catch {
            Add-StepResult -Step 'Default VM Path' -Status 'Fail' -Detail $_.Exception.Message
        }
    } else {
        Add-StepResult -Step 'Default VM Path' -Status 'Skipped' -Detail 'Not specified'
    }

    if ($DefaultVHDPath) {
        try {
            if (-not (Test-Path $DefaultVHDPath)) {
                New-Item -ItemType Directory -Path $DefaultVHDPath -Force | Out-Null
                Write-Log "Created directory: $DefaultVHDPath" -Level 'DEBUG'
            }
            if ($PSCmdlet.ShouldProcess($DefaultVHDPath, 'Set default VHD path')) {
                Set-VMHost -VirtualHardDiskPath $DefaultVHDPath -ErrorAction Stop
            }
            $current = (Get-VMHost -ErrorAction SilentlyContinue).VirtualHardDiskPath
            if ($current -eq $DefaultVHDPath) {
                Add-StepResult -Step 'Default VHD Path' -Status 'Pass' -Detail $DefaultVHDPath
            } else {
                Add-StepResult -Step 'Default VHD Path' -Status 'Warning' -Detail "Expected '$DefaultVHDPath', got '$current'"
            }
        } catch {
            Add-StepResult -Step 'Default VHD Path' -Status 'Fail' -Detail $_.Exception.Message
        }
    } else {
        Add-StepResult -Step 'Default VHD Path' -Status 'Skipped' -Detail 'Not specified'
    }

    # ── Step 3/8: Defender Exclusions ──
    Write-Log ''
    Write-Log "== Step 3/$script:TotalSteps : Defender Exclusions ==" -Level 'INFO'

    if ($DefenderExclusions -eq 'true') {
        try {
            $defenderAvailable = Get-Command Get-MpPreference -ErrorAction SilentlyContinue
            if (-not $defenderAvailable) {
                Add-StepResult -Step 'Defender Exclusions' -Status 'Warning' -Detail 'Windows Defender cmdlets not available (third-party AV?)'
            } else {
                if ($PSCmdlet.ShouldProcess('Defender', 'Add Hyper-V exclusions')) {
                    # Processes
                    Add-MpPreference -ExclusionProcess 'vmms.exe', 'vmwp.exe', 'vmsp.exe', 'vmcompute.exe' -ErrorAction Stop
                    # Extensions
                    Add-MpPreference -ExclusionExtension '.vhdx', '.vhd', '.avhdx', '.vsv', '.iso' -ErrorAction Stop
                    # Paths (default VHD path and ClusterStorage)
                    $pathExclusions = @()
                    if ($DefaultVHDPath) { $pathExclusions += $DefaultVHDPath }
                    if ($DefaultVMPath) { $pathExclusions += $DefaultVMPath }
                    $pathExclusions += 'C:\ClusterStorage\'
                    foreach ($exPath in $pathExclusions) {
                        Add-MpPreference -ExclusionPath $exPath -ErrorAction SilentlyContinue
                    }
                }

                # Validate
                $prefs = Get-MpPreference -ErrorAction SilentlyContinue
                $requiredProcs = @('vmms.exe', 'vmwp.exe', 'vmsp.exe', 'vmcompute.exe')
                $missingProcs = $requiredProcs | Where-Object { $_ -notin @($prefs.ExclusionProcess) }
                $hasVhdx = '.vhdx' -in @($prefs.ExclusionExtension)

                if ($missingProcs.Count -eq 0 -and $hasVhdx) {
                    Add-StepResult -Step 'Defender Exclusions' -Status 'Pass' -Detail "Processes: $($requiredProcs.Count), Extensions: .vhdx/.vhd/.avhdx/.vsv/.iso"
                } else {
                    $detail = ''
                    if ($missingProcs.Count -gt 0) { $detail += "Missing processes: $($missingProcs -join ', '). " }
                    if (-not $hasVhdx) { $detail += 'Missing .vhdx extension.' }
                    Add-StepResult -Step 'Defender Exclusions' -Status 'Warning' -Detail $detail.Trim()
                }
            }
        } catch {
            Add-StepResult -Step 'Defender Exclusions' -Status 'Fail' -Detail $_.Exception.Message
        }
    } else {
        Add-StepResult -Step 'Defender Exclusions' -Status 'Skipped' -Detail 'Not requested'
    }

    # ── Step 4/8: Networking ──
    Write-Log ''
    Write-Log "== Step 4/$script:TotalSteps : Networking (vSwitch) ==" -Level 'INFO'

    if ($LanAdapters.Count -gt 0) {
        try {
            if ($PSCmdlet.ShouldProcess($VSwitchName, 'Configure Hyper-V vSwitch')) {
                Initialize-VSwitch -Name $VSwitchName -Adapters $LanAdapters -UseSET:$UseSET `
                    -AllowManagementOS:$AllowManagementOS -TeamName $TeamName -LbfoMode $LbfoMode -LbfoLba $LbfoLba
            }

            $sw = Get-VMSwitch -Name $VSwitchName -ErrorAction SilentlyContinue
            if ($sw) {
                Add-StepResult -Step 'vSwitch' -Status 'Pass' -Detail "vSwitch '$VSwitchName' exists (type: $($sw.SwitchType))"
            } else {
                Add-StepResult -Step 'vSwitch' -Status 'Fail' -Detail "vSwitch '$VSwitchName' not found after creation attempt"
            }
        } catch {
            Add-StepResult -Step 'vSwitch' -Status 'Fail' -Detail $_.Exception.Message
        }

        # Jumbo Frames
        if ($JumboMTU -gt 0) {
            try {
                foreach ($adapter in $LanAdapters) {
                    if ($PSCmdlet.ShouldProcess("$adapter MTU $JumboMTU", 'Set Jumbo Frames')) {
                        Set-NetAdapterAdvancedProperty -Name $adapter -RegistryKeyword '*JumboPacket' -RegistryValue $JumboMTU -ErrorAction Stop
                    }
                }
                # Validate
                $failedAdapters = @()
                foreach ($adapter in $LanAdapters) {
                    $currentMTU = (Get-NetAdapterAdvancedProperty -Name $adapter -RegistryKeyword '*JumboPacket' -ErrorAction SilentlyContinue).RegistryValue
                    if ([int]$currentMTU -ne $JumboMTU) { $failedAdapters += $adapter }
                }
                if ($failedAdapters.Count -eq 0) {
                    Add-StepResult -Step 'Jumbo Frames' -Status 'Pass' -Detail "MTU $JumboMTU on $($LanAdapters -join ', ')"
                } else {
                    Add-StepResult -Step 'Jumbo Frames' -Status 'Warning' -Detail "MTU not confirmed on: $($failedAdapters -join ', ')"
                }
            } catch {
                Add-StepResult -Step 'Jumbo Frames' -Status 'Fail' -Detail $_.Exception.Message
            }
        }

        # Management vNIC VLAN
        if ($ManagementVLAN -gt 0 -and $AllowManagementOS) {
            try {
                $mgmtAdapter = Get-VMNetworkAdapter -ManagementOS -SwitchName $VSwitchName -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($mgmtAdapter) {
                    if ($PSCmdlet.ShouldProcess("Management vNIC VLAN $ManagementVLAN", 'Set VLAN')) {
                        Set-VMNetworkAdapterVlan -ManagementOS -VMNetworkAdapterName $mgmtAdapter.Name -Access -VlanId $ManagementVLAN -ErrorAction Stop
                    }
                    $vlanInfo = Get-VMNetworkAdapterVlan -ManagementOS -VMNetworkAdapterName $mgmtAdapter.Name -ErrorAction SilentlyContinue
                    if ($vlanInfo -and $vlanInfo.AccessVlanId -eq $ManagementVLAN) {
                        Add-StepResult -Step 'Management VLAN' -Status 'Pass' -Detail "VLAN $ManagementVLAN on management vNIC"
                    } else {
                        Add-StepResult -Step 'Management VLAN' -Status 'Warning' -Detail "VLAN set but verification inconclusive"
                    }
                } else {
                    Add-StepResult -Step 'Management VLAN' -Status 'Warning' -Detail 'No management OS adapter found on vSwitch'
                }
            } catch {
                Add-StepResult -Step 'Management VLAN' -Status 'Fail' -Detail $_.Exception.Message
            }
        }
    } else {
        Add-StepResult -Step 'Networking' -Status 'Skipped' -Detail 'No LanAdapters specified'
    }

    # iSCSI Adapter Configuration
    if ($IscsiAdapters.Count -gt 0 -and $IscsiAdapterIPs.Count -gt 0) {
        if ($IscsiAdapters.Count -ne $IscsiAdapterIPs.Count) {
            Add-StepResult -Step 'iSCSI NIC Config' -Status 'Fail' `
                -Detail "IscsiAdapters count ($($IscsiAdapters.Count)) must match IscsiAdapterIPs count ($($IscsiAdapterIPs.Count))"
        } else {
            try {
                for ($i = 0; $i -lt $IscsiAdapters.Count; $i++) {
                    $adapterName = $IscsiAdapters[$i]
                    $adapterIP = $IscsiAdapterIPs[$i]

                    $nic = Get-NetAdapter -Name $adapterName -ErrorAction SilentlyContinue
                    if (-not $nic) {
                        Add-StepResult -Step "iSCSI NIC '$adapterName'" -Status 'Fail' -Detail 'Adapter not found'
                        continue
                    }

                    if ($PSCmdlet.ShouldProcess("$adapterName IP $adapterIP/$IscsiSubnetPrefix", 'Configure iSCSI adapter')) {
                        $existingIP = Get-NetIPAddress -InterfaceAlias $adapterName -AddressFamily IPv4 -ErrorAction SilentlyContinue
                        if ($existingIP | Where-Object { $_.IPAddress -eq $adapterIP }) {
                            Write-Log "  $adapterName already has IP $adapterIP" -Level 'DEBUG'
                        } else {
                            Set-NetIPInterface -InterfaceAlias $adapterName -Dhcp Disabled -ErrorAction SilentlyContinue
                            $existingIP | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
                            Remove-NetRoute -InterfaceAlias $adapterName -Confirm:$false -ErrorAction SilentlyContinue
                            New-NetIPAddress -InterfaceAlias $adapterName -IPAddress $adapterIP -PrefixLength $IscsiSubnetPrefix -ErrorAction Stop | Out-Null
                        }

                        # Disable DNS registration (iSCSI NICs should not register in DNS)
                        Set-DnsClient -InterfaceAlias $adapterName -RegisterThisConnectionsAddress $false -ErrorAction SilentlyContinue

                        # VLAN if specified
                        if ($IscsiVLAN -gt 0) {
                            Set-NetAdapterAdvancedProperty -Name $adapterName -RegistryKeyword 'VlanID' -RegistryValue $IscsiVLAN -ErrorAction SilentlyContinue
                        }

                        # Jumbo Frames (reuse JumboMTU setting)
                        if ($JumboMTU -gt 0) {
                            Set-NetAdapterAdvancedProperty -Name $adapterName -RegistryKeyword '*JumboPacket' -RegistryValue $JumboMTU -ErrorAction SilentlyContinue
                        }
                    }
                }

                # Validate
                $configuredCount = 0
                for ($i = 0; $i -lt $IscsiAdapters.Count; $i++) {
                    $currentIP = Get-NetIPAddress -InterfaceAlias $IscsiAdapters[$i] -AddressFamily IPv4 -ErrorAction SilentlyContinue
                    if ($currentIP | Where-Object { $_.IPAddress -eq $IscsiAdapterIPs[$i] }) { $configuredCount++ }
                }
                if ($configuredCount -eq $IscsiAdapters.Count) {
                    Add-StepResult -Step 'iSCSI NIC Config' -Status 'Pass' -Detail "$configuredCount adapter(s) configured: $($IscsiAdapters -join ', ')"
                } else {
                    Add-StepResult -Step 'iSCSI NIC Config' -Status 'Warning' -Detail "$configuredCount of $($IscsiAdapters.Count) adapter(s) confirmed"
                }
            } catch {
                Add-StepResult -Step 'iSCSI NIC Config' -Status 'Fail' -Detail $_.Exception.Message
            }
        }
    }

    # ── Step 5/8: Storage ──
    Write-Log ''
    Write-Log "== Step 5/$script:TotalSteps : Storage (iSCSI/MPIO) ==" -Level 'INFO'

    if ($StorageMode -eq 'iSCSI' -or $IscsiTargetPortals.Count -gt 0) {
        try {
            if ($PSCmdlet.ShouldProcess('iSCSI/MPIO', 'Configure storage')) {
                Set-IscsiAndMPIO -Portals $IscsiTargetPortals -InitiatorIPs $IscsiAdapterIPs `
                    -Auth $IscsiAuth -ChapUsername $IscsiChapUsername -ChapSecret $IscsiChapSecret `
                    -PortalPort $IscsiTargetPortalPort -Policy $MPIOPolicy -EnableMultipath:$EnableIscsiMultipath
            }

            # Validate iSCSI service
            $iscsiSvc = Get-Service -Name 'MSiSCSI' -ErrorAction SilentlyContinue
            if ($iscsiSvc -and $iscsiSvc.Status -eq 'Running') {
                Add-StepResult -Step 'iSCSI Service' -Status 'Pass' -Detail 'MSiSCSI running'
            } else {
                Add-StepResult -Step 'iSCSI Service' -Status 'Fail' -Detail 'MSiSCSI not running'
            }

            $registeredPortals = @(Get-IscsiTargetPortal -ErrorAction SilentlyContinue)
            if ($registeredPortals.Count -gt 0) {
                Add-StepResult -Step 'iSCSI Portals' -Status 'Pass' -Detail "$($registeredPortals.Count) portal(s) registered"
            } else {
                Add-StepResult -Step 'iSCSI Portals' -Status 'Warning' -Detail 'No portals registered'
            }

            $sessions = @(Get-IscsiSession -ErrorAction SilentlyContinue)
            if ($sessions.Count -gt 0) {
                Add-StepResult -Step 'iSCSI Sessions' -Status 'Pass' -Detail "$($sessions.Count) active session(s)"
            } else {
                Add-StepResult -Step 'iSCSI Sessions' -Status 'Warning' -Detail 'No active sessions'
            }

            if ($EnableIscsiMultipath) {
                $msdsmClaim = Get-MSDSMAutomaticClaimSettings -ErrorAction SilentlyContinue
                $iscsiClaimed = $false
                if ($msdsmClaim) { $iscsiClaimed = $msdsmClaim.iSCSI }
                if ($iscsiClaimed) {
                    Add-StepResult -Step 'MPIO Auto-Claim' -Status 'Pass' -Detail 'MSDSM iSCSI auto-claim enabled'
                } else {
                    Add-StepResult -Step 'MPIO Auto-Claim' -Status 'Warning' -Detail 'MSDSM iSCSI auto-claim not confirmed'
                }
            }
        } catch {
            Add-StepResult -Step 'Storage Configuration' -Status 'Fail' -Detail $_.Exception.Message
        }

        # Disk Timeout registry
        if ($DiskTimeout -gt 0) {
            try {
                $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\Disk'
                if ($PSCmdlet.ShouldProcess("Disk TimeOutValue: $DiskTimeout", 'Set registry')) {
                    Set-ItemProperty -Path $regPath -Name 'TimeOutValue' -Value $DiskTimeout -Type DWord -ErrorAction Stop
                }
                $current = (Get-ItemProperty -Path $regPath -Name 'TimeOutValue' -ErrorAction SilentlyContinue).TimeOutValue
                if ($current -eq $DiskTimeout) {
                    Add-StepResult -Step 'Disk Timeout' -Status 'Pass' -Detail "${DiskTimeout}s (registry)"
                } else {
                    Add-StepResult -Step 'Disk Timeout' -Status 'Warning' -Detail "Expected $DiskTimeout, got $current"
                }
            } catch {
                Add-StepResult -Step 'Disk Timeout' -Status 'Fail' -Detail $_.Exception.Message
            }
        }
    } elseif ($StorageMode -eq 'skip') {
        Add-StepResult -Step 'Storage' -Status 'Skipped' -Detail 'Storage set to skip'
    } else {
        Add-StepResult -Step 'Storage' -Status 'Skipped' -Detail 'Local storage mode'
    }

    # Volume Formatting (after iSCSI connection, before clustering)
    if ($FormatVolumes.Count -gt 0) {
        Write-Log ''
        Write-Log "== Step 5b/$script:TotalSteps : Volume Formatting ==" -Level 'INFO'

        foreach ($fv in $FormatVolumes) {
            $diskNum  = $fv.DiskNumber
            $letter   = $fv.DriveLetter
            $label    = $fv.Label
            $fs       = if ($fv.FileSystem) { $fv.FileSystem } else { 'ReFS' }
            $auSize   = if ($fv.AllocationUnit) { $fv.AllocationUnit } else { 65536 }
            $auKB     = [math]::Round($auSize / 1024)
            $volDesc  = "Disk $diskNum -> ${letter}: '$label' $fs ${auKB}KB"

            if ($diskNum -lt 0) {
                Add-StepResult -Step "Format: $volDesc" -Status 'Fail' -Detail 'Invalid DiskNumber'
                continue
            }

            try {
                $disk = Get-Disk -Number $diskNum -ErrorAction Stop

                # Check if already formatted with correct settings
                $existingPart = Get-Partition -DiskNumber $diskNum -ErrorAction SilentlyContinue |
                    Where-Object { $_.Type -ne 'Reserved' -and $_.Type -ne 'Unknown' }
                if ($existingPart -and $existingPart.DriveLetter) {
                    $existingVol = Get-Volume -DriveLetter $existingPart.DriveLetter -ErrorAction SilentlyContinue
                    if ($existingVol -and $existingVol.FileSystem -eq $fs) {
                        Add-StepResult -Step "Format: Disk $diskNum" -Status 'Pass' `
                            -Detail "Already formatted ($($existingVol.FileSystem), drive $($existingPart.DriveLetter):) - skipped"
                        continue
                    }
                }

                if ($disk.PartitionStyle -eq 'RAW') {
                    if ($PSCmdlet.ShouldProcess($volDesc, 'Initialize, partition, and format disk')) {
                        Initialize-Disk -Number $diskNum -PartitionStyle GPT -ErrorAction Stop
                        $part = New-Partition -DiskNumber $diskNum -UseMaximumSize -ErrorAction Stop
                        if ($letter) { Set-Partition -DiskNumber $diskNum -PartitionNumber $part.PartitionNumber -NewDriveLetter $letter -ErrorAction Stop }
                        Format-Volume -DriveLetter $letter -FileSystem $fs -AllocationUnitSize $auSize -NewFileSystemLabel $label -Confirm:$false -ErrorAction Stop | Out-Null

                        # Validate
                        $resultVol = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
                        if ($resultVol -and $resultVol.FileSystem -eq $fs) {
                            Add-StepResult -Step "Format: Disk $diskNum" -Status 'Pass' -Detail "${letter}: $label $fs ${auKB}KB"
                        } else {
                            Add-StepResult -Step "Format: Disk $diskNum" -Status 'Warning' -Detail 'Formatted but verification inconclusive'
                        }
                    }
                } else {
                    Add-StepResult -Step "Format: Disk $diskNum" -Status 'Warning' `
                        -Detail "Disk already initialized ($($disk.PartitionStyle)) - skipped to prevent data loss. Wipe manually if reformat needed."
                }
            } catch {
                Add-StepResult -Step "Format: Disk $diskNum" -Status 'Fail' -Detail $_.Exception.Message
            }
        }
    }

    # ── Step 6/8: Failover Clustering ──
    Write-Log ''
    Write-Log "== Step 6/$script:TotalSteps : Failover Clustering ==" -Level 'INFO'

    if ($InstallFailoverClustering) {
        if ($ClusterName -and $ClusterNodes.Count -gt 0) {
            try {
                if ($PSCmdlet.ShouldProcess($ClusterName, 'Create failover cluster')) {
                    try {
                        Write-Log "Running cluster validation on nodes: $($ClusterNodes -join ', ')..."
                        Test-Cluster -Node $ClusterNodes -WarningAction SilentlyContinue | Out-Null
                        Add-StepResult -Step 'Cluster Validation' -Status 'Pass' -Detail 'Validation completed'
                    } catch {
                        Add-StepResult -Step 'Cluster Validation' -Status 'Warning' -Detail "Validation warnings: $($_.Exception.Message)"
                    }

                    if (-not (Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue)) {
                        Write-Log "Creating cluster '$ClusterName'..."
                        $newParams = @{ Name = $ClusterName; Node = $ClusterNodes; NoStorage = $true }
                        if ($ClusterIP) { $newParams['StaticAddress'] = $ClusterIP }
                        New-Cluster @newParams | Out-Null
                    }

                    $cluster = Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue
                    if ($cluster) {
                        Add-StepResult -Step 'Cluster Creation' -Status 'Pass' -Detail "Cluster '$ClusterName' online"
                    } else {
                        Add-StepResult -Step 'Cluster Creation' -Status 'Fail' -Detail "Cluster '$ClusterName' not found after creation"
                    }

                    switch ($Quorum) {
                        'FileShare' {
                            if (-not $FileShareWitnessPath) {
                                Add-StepResult -Step 'Quorum' -Status 'Warning' -Detail 'FileShare quorum requested but no path provided'
                            } else {
                                Set-ClusterQuorum -FileShareWitness $FileShareWitnessPath | Out-Null
                                Add-StepResult -Step 'Quorum' -Status 'Pass' -Detail "File share witness: $FileShareWitnessPath"
                            }
                        }
                        'Disk' {
                            if (-not $DiskWitnessResource) {
                                Add-StepResult -Step 'Quorum' -Status 'Warning' -Detail 'Disk quorum requested but no DiskWitnessResource specified — configure via Failover Cluster Manager'
                            } else {
                                $diskRes = Get-ClusterResource -Name $DiskWitnessResource -ErrorAction SilentlyContinue
                                if ($diskRes) {
                                    Set-ClusterQuorum -DiskWitness $DiskWitnessResource | Out-Null
                                    Add-StepResult -Step 'Quorum' -Status 'Pass' -Detail "Disk witness: $DiskWitnessResource"
                                } else {
                                    Add-StepResult -Step 'Quorum' -Status 'Warning' -Detail "Disk resource '$DiskWitnessResource' not found — add disk to cluster first, then re-run or configure manually"
                                }
                            }
                        }
                        Default {
                            Add-StepResult -Step 'Quorum' -Status 'Skipped' -Detail 'No quorum configuration requested'
                        }
                    }
                }
            } catch {
                Add-StepResult -Step 'Clustering' -Status 'Fail' -Detail $_.Exception.Message
            }
        } else {
            Add-StepResult -Step 'Clustering' -Status 'Warning' -Detail 'Feature installed but no cluster name/nodes provided'
        }
    } else {
        Add-StepResult -Step 'Clustering' -Status 'Skipped' -Detail 'Not requested'
    }

    # ── Step 7/8: Live Migration ──
    Write-Log ''
    Write-Log "== Step 7/$script:TotalSteps : Live Migration ==" -Level 'INFO'

    if ($LiveMigrationProtocol -ne 'skip') {
        try {
            # Enable Live Migration on host
            if ($PSCmdlet.ShouldProcess('Live Migration', 'Configure settings')) {
                Enable-VMMigration -ErrorAction SilentlyContinue

                # Protocol
                $perfOption = switch ($LiveMigrationProtocol) {
                    'SMB'         { 'SMB' }
                    'Compression' { 'Compression' }
                    'TCPIP'       { 'TCPIP' }
                }
                Set-VMHost -VirtualMachineMigrationPerformanceOption $perfOption -ErrorAction Stop

                # Authentication
                Set-VMHost -VirtualMachineMigrationAuthenticationType $LiveMigrationAuth -ErrorAction Stop

                # Concurrent limit
                Set-VMHost -MaximumVirtualMachineMigrations $LiveMigrationMaxConcurrent -ErrorAction Stop
            }

            # Validate
            $vmHost = Get-VMHost -ErrorAction SilentlyContinue
            $validated = $true
            $details = @()

            if ($vmHost.VirtualMachineMigrationEnabled) {
                $details += 'Enabled'
            } else {
                $details += 'NOT enabled'
                $validated = $false
            }

            $currentProto = $vmHost.VirtualMachineMigrationPerformanceOption
            $details += "Protocol=$currentProto"

            $currentAuth = $vmHost.VirtualMachineMigrationAuthenticationType
            $details += "Auth=$currentAuth"

            $currentMax = $vmHost.MaximumVirtualMachineMigrations
            $details += "Max=$currentMax"

            if ($validated) {
                Add-StepResult -Step 'Live Migration' -Status 'Pass' -Detail ($details -join ', ')
            } else {
                Add-StepResult -Step 'Live Migration' -Status 'Warning' -Detail ($details -join ', ')
            }
        } catch {
            Add-StepResult -Step 'Live Migration' -Status 'Fail' -Detail $_.Exception.Message
        }
    } else {
        Add-StepResult -Step 'Live Migration' -Status 'Skipped' -Detail 'Not requested'
    }

    # ── Step 8/8: Post-Deploy Assessment ──
    Write-Log ''
    Write-Log "== Step 8/$script:TotalSteps : Post-Deploy Assessment ==" -Level 'INFO'

    if ($RunPostAssessment) {
        try {
            # Look for HyperVAssessment.ps1 relative to this script
            $assessmentScript = $null
            if ($PSScriptRoot) {
                $candidate = Join-Path (Split-Path $PSScriptRoot -Parent) 'HyperVAssessment\HyperVAssessment.ps1'
                if (Test-Path $candidate) { $assessmentScript = $candidate }
            }

            if ($assessmentScript) {
                Write-Log "Running: $assessmentScript -Mode Quick -Quiet"
                if ($PSCmdlet.ShouldProcess('HyperVAssessment', 'Run post-deploy assessment')) {
                    $assessResult = & $assessmentScript -Mode Quick -Quiet -PassThru -ErrorAction Stop
                    $criticalCount = @($assessResult.Findings | Where-Object { $_.Severity -eq 'Critical' }).Count
                    $warningCount = @($assessResult.Findings | Where-Object { $_.Severity -eq 'Warning' }).Count
                    Add-StepResult -Step 'Post-Deploy Assessment' -Status $(if ($criticalCount -gt 0) { 'Warning' } else { 'Pass' }) `
                        -Detail "Critical=$criticalCount, Warning=$warningCount (HyperVAssessment Quick)"
                }
            } else {
                Add-StepResult -Step 'Post-Deploy Assessment' -Status 'Warning' -Detail 'HyperVAssessment.ps1 not found in sibling directory'
            }
        } catch {
            Add-StepResult -Step 'Post-Deploy Assessment' -Status 'Warning' -Detail "Assessment error: $($_.Exception.Message)"
        }
    } else {
        Add-StepResult -Step 'Post-Deploy Assessment' -Status 'Skipped' -Detail 'Not requested'
    }

    # ── Reboot Handling ──
    if ($rebootNeeded) {
        Write-Log ''
        if ($AutoReboot) {
            Write-Log 'Reboot required - rebooting now...' -Level 'WARN'
            Add-StepResult -Step 'Reboot' -Status 'Pass' -Detail 'Auto-reboot initiated'
        } else {
            Write-Log 'Reboot required to finalize features. Reboot when convenient.' -Level 'WARN'
            Add-StepResult -Step 'Reboot' -Status 'Warning' -Detail 'Reboot required but not auto-initiated'
        }
    }

    # ── Summary ──
    Write-Log ''
    Write-Log '== Deployment Summary ==' -Level 'INFO'

    $failCount = @($script:StepResults | Where-Object { $_.Status -eq 'Fail' }).Count
    $warnCount = @($script:StepResults | Where-Object { $_.Status -eq 'Warning' }).Count
    $passCount = @($script:StepResults | Where-Object { $_.Status -eq 'Pass' }).Count
    $skipCount = @($script:StepResults | Where-Object { $_.Status -eq 'Skipped' }).Count

    Write-Log "  Pass: $passCount | Warning: $warnCount | Fail: $failCount | Skipped: $skipCount"

    $results = [PSCustomObject]@{
        Timestamp     = Get-Date -Format 'o'
        ComputerName  = $env:COMPUTERNAME
        Mode          = 'Fix'
        ScriptVersion = $script:ScriptVersion
        Template      = $TemplatePath
        RebootNeeded  = $rebootNeeded
        Steps         = $script:StepResults
        Summary       = @{
            Pass    = $passCount
            Warning = $warnCount
            Fail    = $failCount
            Skipped = $skipCount
        }
    }

    Export-Results -Results $results

    # Ninja output
    $summaryText = "$env:COMPUTERNAME HyperVDeployment: Pass=$passCount Warn=$warnCount Fail=$failCount"
    if ($rebootNeeded) { $summaryText += ' [REBOOT REQUIRED]' }

    $htmlLines = @(
        '<table><tr><th>Step</th><th>Status</th><th>Detail</th></tr>'
        foreach ($s in $script:StepResults) {
            $color = switch ($s.Status) { 'Pass' { 'green' } 'Fail' { 'red' } 'Warning' { 'orange' } default { 'gray' } }
            "<tr><td>$($s.Step)</td><td style='color:$color;font-weight:bold'>$($s.Status)</td><td>$($s.Detail)</td></tr>"
        }
        '</table>'
    )
    Write-NinjaOutput -Summary $summaryText -HTMLReport ($htmlLines -join '')

    if ($PassThru) { return $results }

    # Reboot (after all reporting)
    if ($rebootNeeded -and $AutoReboot) {
        Restart-Computer -Force
    }

    # Exit code per P-007
    if ($failCount -gt 0) { return 20 }
    if ($rebootNeeded)     { return 1 }
    if ($warnCount -gt 0)  { return 10 }
    return 0
}

function Invoke-MenuMode {
    do {
        Clear-Host
        $boxWidth = 50
        $verLine = "$script:ScriptName v$script:ScriptVersion"
        $vPad = $boxWidth - $verLine.Length
        $vL = [math]::Floor($vPad / 2); $vR = $vPad - $vL
        Write-Host ''
        Write-Host "  +$('=' * $boxWidth)+" -ForegroundColor Cyan
        Write-Host "  |$(' ' * $vL)$verLine$(' ' * $vR)|" -ForegroundColor Cyan
        Write-Host "  +$('=' * $boxWidth)+" -ForegroundColor Cyan
        Write-Host ''
        Write-Host "  Computer: $env:COMPUTERNAME | Admin: $script:IsAdmin | Server: $script:IsServer" -ForegroundColor Gray
        if ($TemplatePath) { Write-Host "  Template: $TemplatePath" -ForegroundColor Gray }
        Write-Host ''
        Write-Host '  ─────────────────────────────────────' -ForegroundColor DarkGray
        Write-Host '  1. Preview Configuration (Detect)'
        Write-Host '  2. Deploy Configuration (Fix)'
        Write-Host '  3. Deploy + Export Report'
        Write-Host ''
        Write-Host '  Q. Quit'
        Write-Host '  ─────────────────────────────────────' -ForegroundColor DarkGray
        Write-Host ''

        $choice = Read-Host '  Select option'

        switch ($choice.ToLower()) {
            '1' {
                Write-Host ''
                Invoke-DetectMode
                Write-Host "`n  Press Enter to continue..." -ForegroundColor Gray; $null = Read-Host
            }
            '2' {
                Write-Host ''
                Invoke-FixMode
                Write-Host "`n  Press Enter to continue..." -ForegroundColor Gray; $null = Read-Host
            }
            '3' {
                Write-Host ''
                $script:AutoExport = $true
                Initialize-OutputDirectory
                Invoke-FixMode
                Write-Host "`n  Press Enter to continue..." -ForegroundColor Gray; $null = Read-Host
            }
            'q' {
                Write-Host "`n  Goodbye!`n" -ForegroundColor Cyan
                return
            }
            default {
                Write-Host '  Invalid option.' -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
    } while ($true)
}

# ============================================================================
# ENTRY POINT
# ============================================================================

function Invoke-HyperVDeployment {
    <#
    .SYNOPSIS
        Launch HyperVDeployment. Supports paste/dot-source invocation.
    .PARAMETER Mode
        Detect = Preview (default). Fix = Deploy. Menu = Interactive.
    .PARAMETER TemplatePath
        Path to a YAML deployment template.
    .PARAMETER OutputPath
        Directory for log and report files.
    .PARAMETER Quiet
        Suppress console output.
    .PARAMETER PassThru
        Return result objects to pipeline.
    .PARAMETER AutoExport
        Auto-export reports to OutputPath.
    .PARAMETER NinjaCustomField
        NinjaRMM text custom field name.
    .PARAMETER NinjaHTMLField
        NinjaRMM WYSIWYG custom field name.
    .PARAMETER Force
        Skip confirmation prompts.
    .EXAMPLE
        Invoke-HyperVDeployment
    .EXAMPLE
        Invoke-HyperVDeployment -Mode Fix -TemplatePath .\cluster-host.yaml
    .EXAMPLE
        Invoke-HyperVDeployment -Mode Fix -Quiet -AutoExport -NinjaCustomField 'hvDeployStatus'
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [ValidateSet('Detect', 'Fix', 'Menu')]
        [string]$Mode = $script:Mode,

        [string]$TemplatePath = $script:TemplatePath,

        [string]$OutputPath = $script:OutputPath,

        [switch]$Quiet,

        [switch]$PassThru,

        [switch]$AutoExport,

        [string]$NinjaCustomField = $script:NinjaCustomField,

        [string]$NinjaHTMLField = $script:NinjaHTMLField,

        [switch]$Force
    )

    # Update script-scoped variables
    $script:Mode             = $Mode
    $script:TemplatePath     = $TemplatePath
    $script:OutputPath       = $OutputPath
    $script:NinjaCustomField = $NinjaCustomField
    $script:NinjaHTMLField   = $NinjaHTMLField

    if ($PSBoundParameters.ContainsKey('Quiet'))      { $script:Quiet      = [bool]$Quiet }
    if ($PSBoundParameters.ContainsKey('PassThru'))    { $script:PassThru   = [bool]$PassThru }
    if ($PSBoundParameters.ContainsKey('AutoExport'))  { $script:AutoExport = [bool]$AutoExport }
    if ($PSBoundParameters.ContainsKey('Force'))       { $script:Force      = [bool]$Force }

    if ($AutoExport -or $script:AutoExport) { Initialize-OutputDirectory }

    # Load template if specified
    if ($TemplatePath) {
        $template = Import-DeploymentTemplate -Path $TemplatePath
        Merge-TemplateValues -Template $template
    }

    $result = switch ($Mode) {
        'Detect' { Invoke-DetectMode }
        'Fix'    { Invoke-FixMode }
        'Menu'   { Invoke-MenuMode }
    }

    if ($PassThru -or $script:PassThru) { return $result }

    if ($Mode -ne 'Menu' -and $result -is [int]) {
        exit $result
    }
}

# ============================================================================
# SCRIPT EXECUTION (direct run vs dot-source vs paste)
# ============================================================================

# Load template early if specified via param (before Invoke-*)
if ($TemplatePath) {
    $template = Import-DeploymentTemplate -Path $TemplatePath
    Merge-TemplateValues -Template $template
}

if (-not $PSCommandPath) {
    # Pasted into console
    Write-Host ''
    Write-Host "$script:ScriptName v$($script:ScriptVersion) loaded (pasted)." -ForegroundColor Cyan
    Write-Host 'Run: Invoke-HyperVDeployment' -ForegroundColor Gray
    Write-Host ''
}
elseif ($MyInvocation.InvocationName -ne '.') {
    # Direct execution (.\Script.ps1 or RMM)
    Invoke-HyperVDeployment
}
else {
    # Dot-sourced (. .\Script.ps1)
    Write-Host ''
    Write-Host "$script:ScriptName v$($script:ScriptVersion) loaded." -ForegroundColor Cyan
    Write-Host 'Run: Invoke-HyperVDeployment' -ForegroundColor Gray
    Write-Host ''
}

# ============================================================================
# PRESETS (uncomment one and paste for quick execution)
# ============================================================================

# Invoke-HyperVDeployment -Mode Detect
# Invoke-HyperVDeployment -Mode Fix
# Invoke-HyperVDeployment -Mode Menu
# Invoke-HyperVDeployment -Mode Fix -TemplatePath '.\templates\cluster-host.yaml' -AutoExport
# Invoke-HyperVDeployment -Mode Fix -Quiet -AutoExport -NinjaCustomField 'hvDeployStatus'