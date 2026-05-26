#Requires -Version 5.1
# =============================================================================
# ServerDecomAssessment: Server Inventory for Decommission/Migration Planning
# Author: Jeff Davidson
# Version: 1.1.0
# =============================================================================
# Features:
#   - Comprehensive server inventory (OS, hardware, network, volumes)
#   - Installed applications, roles/features, services, scheduled tasks
#   - Deep role analysis: AD, DNS, DHCP, IIS, SQL, Hyper-V, Cluster
#   - Multiple output formats: JSON, HTML, CSV with Excel merge
#   - Local and remote execution support
# -----------------------------------------------------------------------------

# Merge-CsvToExcel (TOP-LEVEL)
function Merge-CsvToExcel {
<#
.SYNOPSIS
Merge multiple CSV files into a single Excel .xlsx with one worksheet per CSV (no external modules).
.PARAMETER CsvFolder
Folder containing CSV files to merge.
.PARAMETER OutXlsx
Output Excel workbook path to create.
.PARAMETER WorksheetNamePrefix
Optional prefix for sheet names.
.NOTES
Uses Excel COM automation; requires Excel installed on the machine.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$CsvFolder,
        [Parameter(Mandatory=$true)]
        [string]$OutXlsx,
        [string]$WorksheetNamePrefix
    )
    if (-not (Test-Path $CsvFolder)) { throw "CsvFolder not found: $CsvFolder" }

    $destDir = [System.IO.Path]::GetDirectoryName($OutXlsx)
    if ($destDir -and -not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    $excel = $null
    try { $excel = New-Object -ComObject Excel.Application } catch {
        throw "Excel COM object could not be created. Is Microsoft Excel installed? Error: $($_.Exception.Message)"
    }
    $excel.Visible = $false
    $excel.DisplayAlerts = $false

    $workbook = $null
    try {
        $workbook = $excel.Workbooks.Add()
        try { ($workbook.Worksheets.Item(1)).Delete() } catch { }

        function Get-SafeSheetName([string]$name) {
            $bad = '[\[\]\:\*\?\\/]'
            $clean = ($name -replace $bad,'_')
            if ($clean.Length -gt 31) { $clean.Substring(0,31) } else { $clean }
        }

        $csvs = Get-ChildItem -Path $CsvFolder -Filter *.csv -ErrorAction SilentlyContinue | Sort-Object Name
        if (-not $csvs -or $csvs.Count -eq 0) {
            $workbook.SaveAs($OutXlsx)
            Write-Host "[Excel] No CSV files found in $CsvFolder. Created empty workbook: $OutXlsx" -ForegroundColor Yellow
            return
        }

        foreach ($csv in $csvs) {
            $csvPath = $csv.FullName
            $base    = [System.IO.Path]::GetFileNameWithoutExtension($csv.Name)
            $sheetName = Get-SafeSheetName $base
            if ($WorksheetNamePrefix) { $sheetName = Get-SafeSheetName ("$WorksheetNamePrefix$sheetName") }

            $sheet = $workbook.Worksheets.Add()
            try { $sheet.Name = $sheetName } catch { }

            $tempWb = $excel.Workbooks.Open($csvPath)
            try {
                $tempWs = $tempWb.Worksheets.Item(1)
                $used   = $tempWs.UsedRange
                $used.Copy()
                $sheet.Range("A1").PasteSpecial()
                $sheet.Rows.Item(1).Font.Bold = $true
                $sheet.Rows.Item(1).Interior.ColorIndex = 15
                $sheet.Columns.AutoFit() | Out-Null
                $sheet.Application.ActiveWindow.SplitRow = 1
                $sheet.Application.ActiveWindow.FreezePanes = $true
            } finally {
                if ($tempWb) { $tempWb.Close($false) }
            }
        }

        $workbook.SaveAs($OutXlsx)
        Write-Host ("[Excel] Merged CSVs to {0}" -f $OutXlsx) -ForegroundColor Green
    }
    finally {
        # Ensure COM objects are always released
        if ($workbook) {
            try { $workbook.Close($false) } catch { }
            try { [System.Runtime.Interopservices.Marshal]::ReleaseComObject($workbook) | Out-Null } catch { }
        }
        if ($excel) {
            try { $excel.Quit() } catch { }
            try { [System.Runtime.Interopservices.Marshal]::ReleaseComObject($excel) | Out-Null } catch { }
        }
        [gc]::Collect(); [gc]::WaitForPendingFinalizers()
    }
}

# ServerDecomAssessment
function ServerDecomAssessment {
<#
.SYNOPSIS
Inventory server(s) for decommission/migration planning with readable summary and optional JSON/HTML/CSV exports.
#>
    [CmdletBinding()]
    param(
        [string[]]$ComputerName = @($env:COMPUTERNAME),
        [pscredential]$Credential,
        [ValidateSet('None','Json','Html','Csv')]
        [string]$OutputFormat = 'None',
        [string]$OutputPath = 'C:\Temp\SDA_Results',
        [string]$LogPath,
        [switch]$IncludeInstalledUpdates,
        [switch]$Summary,
        [int]$AppsTop = 40,
        [int]$ServicesTop = 40,
        [int]$TasksTop = 40,
        [int]$SharesTop = 40,
        [int]$CertsTop = 40,
        [int]$InstalledFeaturesTop = 80,
        [switch]$GridApps,
        [switch]$GridServices,
        [switch]$GridShares,
        [switch]$ExportIISConfig,
        [switch]$ExportCertificates,
        [switch]$ExcelMergeAfterCsv,
        [string]$MergedExcelPath,
        [switch]$DeepRoles,

        # Configurable filters for "Non-Microsoft" scheduled tasks (recommended defaults)
        [string[]]$ExcludeTaskAuthorLike = @('Microsoft','Microsoft Corporation'),
        [string[]]$ExcludeTaskNamePrefix = @('Microsoft'),
        [string[]]$IncludeTaskNamePrefix = @('SQL','MSSQL','SQLServer')  # force-include (keeps SQL visible)
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # --- Logging helpers ---------------------------------------------------------------
    $Global:SDA_LogFile = $null
    function Initialize-Logging {
        param([string]$LogPath,[string]$ComputerName)
        if (-not $LogPath) { return }
        try {
            if (-not (Test-Path $LogPath)) { New-Item -ItemType Directory -Path $LogPath -Force | Out-Null }
            $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
            $Global:SDA_LogFile = Join-Path $LogPath ("SDA-" + $ComputerName + "-" + $ts + ".log")
            "[$(Get-Date -Format o)] INFO Init logging for $ComputerName" | Out-File -FilePath $Global:SDA_LogFile -Encoding UTF8 -Append
        } catch {
            Write-Warning "Failed to initialize logging: $($_.Exception.Message)"
        }
    }
    function Write-Log {
        param(
            [ValidateSet('INFO','WARN','ERROR','DEBUG')] [string]$Level,
            [string]$Message,
            [string]$Section
        )
        try {
            $line = "[$(Get-Date -Format o)] $Level" + (if ($Section) { " [$Section]" } else { '' }) + " - " + $Message
            if ($Global:SDA_LogFile) { $line | Out-File -FilePath $Global:SDA_LogFile -Encoding UTF8 -Append }
        } catch { }
    }

    function New-AssessmentCollectorScriptBlock {
        param(
            [switch]$IncludeInstalledUpdates,
            [switch]$DeepRoles,
            [string[]]$ExcludeTaskAuthorLike,
            [string[]]$ExcludeTaskNamePrefix,
            [string[]]$IncludeTaskNamePrefix
        )
        return {
            param(
                [switch]$IncludeInstalledUpdates,
                [switch]$DeepRoles,
                [string[]]$ExcludeTaskAuthorLike,
                [string[]]$ExcludeTaskNamePrefix,
                [string[]]$IncludeTaskNamePrefix
            )

            function Import-ModuleSafe([string]$Name) {
                try { Import-Module -Name $Name -ErrorAction Stop | Out-Null; $true } catch { $false }
            }

            function Get-SafeValue { param($Obj,[string]$Name)
                $prop = $Obj.PSObject.Properties[$Name]
                if ($prop) { $prop.Value } else { $null }
            }

            function Get-OsAndHardware {
                $cs   = Get-CimInstance Win32_ComputerSystem
                $os   = Get-CimInstance Win32_OperatingSystem
                $procs= Get-CimInstance Win32_Processor
                $bios = Get-CimInstance Win32_BIOS
                $boot = try { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime } catch { $null }
                [pscustomobject]@{
                    ComputerName     = $env:COMPUTERNAME
                    Domain           = $cs.Domain
                    Workgroup        = if ($cs.PartOfDomain) { $null } else { $cs.Workgroup }
                    PartOfDomain     = [bool]$cs.PartOfDomain
                    Model            = $cs.Model
                    Manufacturer     = $cs.Manufacturer
                    OS               = $os.Caption
                    OSVersion        = $os.Version
                    OSInstallDate    = $os.InstallDate
                    LastBootUpTime   = $boot
                    BIOSVersion      = $bios.SMBIOSBIOSVersion
                    PhysicalMemoryGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 2)
                    CPU              = @($procs | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors)
                }
            }

            function Get-Volumes {
                try {
                    Get-Volume | Select-Object DriveLetter, FileSystemLabel, FileSystem, DriveType, Size, SizeRemaining, Path
                } catch {
                    $vols = Get-CimInstance Win32_LogicalDisk | Select-Object DeviceID, VolumeName, FileSystem, DriveType, Size, FreeSpace
                    $vols | ForEach-Object {
                        [pscustomobject]@{
                            DriveLetter     = $_.DeviceID
                            FileSystemLabel = $_.VolumeName
                            FileSystem      = $_.FileSystem
                            DriveType       = $_.DriveType
                            Size            = $_.Size
                            SizeRemaining   = $_.FreeSpace
                            Path            = $_.DeviceID
                        }
                    }
                }
            }

            function Get-NetworkSummary {
                try {
                    Get-NetIPConfiguration | ForEach-Object {
                        [pscustomobject]@{
                            InterfaceAlias = $_.InterfaceAlias
                            IPv4Address    = $_.IPv4Address.IPAddress
                            IPv6Address    = $_.IPv6Address.IPAddress
                            IPv4DefaultGw  = $_.IPv4DefaultGateway.NextHop
                            DNSServers     = ($_.DNSServer.ServerAddresses -join ',')
                        }
                    }
                } catch {
                    Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=TRUE" | ForEach-Object {
                        [pscustomobject]@{
                            InterfaceAlias = $_.Description
                            IPv4Address    = ($_.IPAddress | Where-Object { $_ -match '^\d+\.' }) -join ','
                            IPv6Address    = ($_.IPAddress | Where-Object { $_ -match ':' }) -join ','
                            IPv4DefaultGw  = ($_.DefaultIPGateway -join ',')
                            DNSServers     = ($_.DNSServerSearchOrder -join ',')
                        }
                    }
                }
            }

            function Get-InstalledProgramsFromRegHive([string]$HiveRootPath) {
                $paths = @(
                    "$HiveRootPath\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
                    "$HiveRootPath\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
                )
                $items = @()
                foreach ($p in $paths) {
                    try { $items += Get-ItemProperty -Path $p -ErrorAction SilentlyContinue } catch { }
                }
                $out = @()
                foreach ($it in $items) {
                    $dn = Get-SafeValue -Obj $it -Name 'DisplayName'
                    if (-not $dn) { continue }
                    if (-not $IncludeInstalledUpdates) {
                        $token = ($dn -split '\s+')[0]
                        if ($token -in @('Update','Security','Hotfix','KB','Cumulative')) { continue }
                    }
                    $dv = Get-SafeValue -Obj $it -Name 'DisplayVersion'
                    $pub= Get-SafeValue -Obj $it -Name 'Publisher'
                    $id = Get-SafeValue -Obj $it -Name 'InstallDate'
                    $il = Get-SafeValue -Obj $it -Name 'InstallLocation'
                    $esRaw = Get-SafeValue -Obj $it -Name 'EstimatedSize'
                    $un = Get-SafeValue -Obj $it -Name 'UninstallString'
                    $esMB = if ($esRaw) { [math]::Round([int]$esRaw / 1024, 2) } else { $null }

                    $out += [pscustomobject]@{
                        DisplayName     = $dn
                        DisplayVersion  = $dv
                        Publisher       = $pub
                        InstallDate     = $id
                        InstallLocation = $il
                        EstimatedSizeMB = $esMB
                        UninstallString = $un
                        RegistryKey     = $it.PSPath
                    }
                }
                $out
            }

            function Get-InstalledPrograms {
                $local = Get-InstalledProgramsFromRegHive -HiveRootPath 'HKLM:'
                $user  = @()
                try { $user = Get-InstalledProgramsFromRegHive -HiveRootPath 'HKCU:' } catch { $user = @() }
                $local + $user
            }

            function Get-RolesAndFeatures {
                $result = [pscustomobject]@{ Method=''; Installed=@() }
                if (Import-ModuleSafe 'ServerManager') {
                    $result.Method = 'ServerManager'
                    $result.Installed = Get-WindowsFeature | Where-Object Installed |
                        Select-Object Name, DisplayName, Installed
                } else {
                    try {
                        $out = & dism.exe /online /Get-Features /Format:Table 2>$null
                        $installed = @()
                        foreach ($line in $out) {
                            if ($line -match '^\s*([\w\-\._]+)\s+\|\s+Enabled\s*$') {
                                $installed += [pscustomobject]@{ Name=$matches[1]; DisplayName=$matches[1]; Installed=$true }
                            }
                        }
                        $result.Method = 'DISM'
                        $result.Installed = $installed
                    } catch {
                        $result.Method = 'Unavailable'
                    }
                }
                $result
            }

            function Get-ServicesSummary {
                $svcs = Get-CimInstance Win32_Service | Select-Object Name, DisplayName, State, StartMode, PathName
                $autoNotRunning = $svcs | Where-Object { $_.StartMode -eq 'Auto' -and $_.State -ne 'Running' }
                $thirdParty = $svcs | Where-Object {
                    $_.PathName -and ($_.PathName -notmatch '\\Windows\\System32\\' -and $_.PathName -notmatch '^"?(?:System32|C:\\Windows)\\')
                }
                [pscustomobject]@{
                    All                 = $svcs
                    AutoButNotRunning   = $autoNotRunning
                    SuspectedThirdParty = $thirdParty
                }
            }

            function Get-KeyServicesStatus {
                $key = @(
                    'AzureADPasswordProtectionProxy','AzureADPasswordProtectionDCAgent',
                    'MSSQLSERVER','SQLSERVERAGENT','W3SVC','AppHostSvc','DhcpServer','DNS',
                    'vmms','WinRM','LanmanServer','Spooler','TermService'
                )
                $out = @()
                foreach ($name in $key) {
                    $s = Get-Service -Name $name -ErrorAction SilentlyContinue
                    if ($s) {
                        $startMode = $null
                        try { $startMode = (Get-CimInstance Win32_Service -Filter "Name='$($s.Name)'").StartMode } catch { }
                        $out += [pscustomobject]@{
                            Name      = $s.Name
                            Display   = $s.DisplayName
                            Status    = $s.Status.ToString()
                            StartType = $startMode
                        }
                    }
                }
                $out
            }

            function Get-ServiceLogonAccounts {
                # Collect services with unique Log On As accounts (excluding common built-in accounts)
                $builtIn = @(
                    'LocalSystem', 'NT AUTHORITY\LocalService', 'NT AUTHORITY\NetworkService',
                    'NT AUTHORITY\SYSTEM', 'NT AUTHORITY\LOCAL SERVICE', 'NT AUTHORITY\NETWORK SERVICE',
                    'Local System', 'LocalService', 'NetworkService'
                )
                $svcs = Get-CimInstance Win32_Service | Where-Object {
                    $_.StartName -and ($builtIn -notcontains $_.StartName)
                } | Select-Object Name, DisplayName, StartName, State, StartMode, PathName

                # Group by StartName for summary
                $grouped = $svcs | Group-Object StartName | ForEach-Object {
                    [pscustomobject]@{
                        LogonAccount  = $_.Name
                        ServiceCount  = $_.Count
                        Services      = ($_.Group | ForEach-Object { $_.DisplayName }) -join '; '
                    }
                } | Sort-Object LogonAccount

                [pscustomobject]@{
                    UniqueAccounts = $grouped
                    AllServices    = $svcs
                }
            }

            function Get-SmbShares {
                try {
                    Get-SmbShare | Where-Object { $_.Name -notin @('ADMIN$','C$','IPC$') } |
                        Select-Object Name, Path, Description, FolderEnumerationMode, EncryptData, ContinuouslyAvailable, CurrentUsers
                } catch {
                    try {
                        Get-CimInstance Win32_Share | Where-Object { $_.Name -notin @('ADMIN$','C$','IPC$') } |
                            Select-Object Name, Path, Description, Type, MaximumAllowed
                    } catch { @() }
                }
            }

            function Get-IISSummary {
                $iisInstalled = Test-Path 'HKLM:\SOFTWARE\Microsoft\InetStp'
                $sites=@(); $pools=@()
                if ($iisInstalled) {
                    if (Import-ModuleSafe 'WebAdministration') {
                        try {
                            $sites = Get-Website | Select-Object Name, State, PhysicalPath, Bindings
                            $pools = Get-WebAppPoolState | ForEach-Object { [pscustomobject]@{ Name=$_.ItemName; State=$_.Value } }
                        } catch { }
                    } else {
                        $cfg = "$env:windir\system32\inetsrv\config\applicationHost.config"
                        if (Test-Path $cfg) {
                            try {
                                [xml]$xml = Get-Content $cfg -ErrorAction Stop
                                $sites = $xml.configuration.'system.applicationHost'.sites.site | ForEach-Object {
                                    [pscustomobject]@{
                                        Name         = $_.name
                                        State        = $null
                                        PhysicalPath = $_.application.virtualDirectory.physicalPath
                                        Bindings     = ($_.bindings.binding | ForEach-Object { "$($_.protocol)://$($_.bindingInformation)" }) -join '; '
                                    }
                                }
                            } catch { }
                        }
                    }
                }
                [pscustomobject]@{ Installed=[bool]$iisInstalled; Sites=$sites; AppPools=$pools }
            }

            function Get-CertSummary {
                $stores=@('My','WebHosting'); $out=@()
                foreach ($st in $stores) {
                    try {
                        $path="Cert:\LocalMachine\$st"
                        if (Test-Path $path) {
                            $out += Get-ChildItem -Path $path | Select-Object @{n='Store';e={$st}}, Subject, NotAfter, Thumbprint, HasPrivateKey, FriendlyName
                        }
                    } catch { }
                }
                $out
            }

            function Get-ScheduledTasksSummary {
                try {
                    $tasks = Get-ScheduledTask | Select-Object TaskName, TaskPath, State, Author, Description, Triggers, Actions

                    # Helper: does name start with any prefix (case-insensitive)?
                    function StartsWithAny($value, [string[]]$prefixes) {
                        if (-not $value -or -not $prefixes -or $prefixes.Count -eq 0) { return $false }
                        foreach ($p in $prefixes) {
                            if ($value.StartsWith($p, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
                        }
                        return $false
                    }

                    # Helper: does author contain any token (case-insensitive)?
                    function AuthorContainsAny($author, [string[]]$tokens) {
                        if (-not $author -or -not $tokens -or $tokens.Count -eq 0) { return $false }
                        foreach ($t in $tokens) {
                            if ($author.IndexOf($t, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
                        }
                        return $false
                    }

                    # Filter: exclude path under \Microsoft\*, authors containing tokens, names with prefixes
                    # but force-include by IncludeTaskNamePrefix (e.g., SQL/MSSQL/SQLServer)
                    $custom = $tasks | Where-Object {
                        $t = $_
                        $underMicrosoft = ($t.TaskPath -like '\Microsoft\*')
                        $forceInclude   = StartsWithAny $t.TaskName $IncludeTaskNamePrefix
                        if ($forceInclude) { return $true }
                        if ($underMicrosoft) { return $false }
                        $excludeByAuthor = AuthorContainsAny $t.Author $ExcludeTaskAuthorLike
                        $excludeByName   = StartsWithAny $t.TaskName $ExcludeTaskNamePrefix
                        return -not ($excludeByAuthor -or $excludeByName)
                    }

                    [pscustomobject]@{ All=$tasks; NonMicrosoft=$custom }
                } catch {
                    [pscustomobject]@{ All=@(); NonMicrosoft=@() }
                }
            }

            function Get-PrinterSummary {
                try {
                    Get-Printer | Select-Object Name, DriverName, PortName, Shared, Published
                } catch {
                    try {
                        Get-CimInstance Win32_Printer | Select-Object Name, DriverName, PortName, Shared, Network
                    } catch { @() }
                }
            }

            function Get-RoleHints {
                $sqlHints=@()
                try { $sqlHints += Get-Service -Name 'MSSQLSERVER','SQLSERVERAGENT' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } } catch { }
                try {
                    $sqlHints += (Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL" -ErrorAction SilentlyContinue |
                        Select-Object -ExpandProperty Property -ErrorAction SilentlyContinue)
                } catch { }
                $hyperv = Get-Service -Name 'vmms' -ErrorAction SilentlyContinue
                [pscustomobject]@{
                    SqlLikelyPresent            = [bool]$sqlHints
                    SqlInstancesHint            = $sqlHints
                    HyperVPresent               = [bool]$hyperv
                    DNSServerPresent            = [bool](Get-Service -Name 'DNS' -ErrorAction SilentlyContinue)
                    DHCPServerPresent           = [bool](Get-Service -Name 'DhcpServer' -ErrorAction SilentlyContinue)
                    IISPresent                  = Test-Path 'HKLM:\SOFTWARE\Microsoft\InetStp'
                    ADPasswordProtectionProxy   = [bool](Get-Service -Name 'AzureADPasswordProtectionProxy' -ErrorAction SilentlyContinue)
                    ADPasswordProtectionDCAgent = [bool](Get-Service -Name 'AzureADPasswordProtectionDCAgent' -ErrorAction SilentlyContinue)
                }
            }

            # Deep-role collectors (only run when -DeepRoles)
            function Get-ADSummary {
                $out = [pscustomobject]@{
                    IsDomainController = $false
                    DomainName         = $null
                    ForestName         = $null
                    FSMO               = @()
                    ReplicationIssues  = @()
                    DFL                = $null
                    FFL                = $null
                }
                try {
                    $isDC = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters' -ErrorAction SilentlyContinue
                    if ($isDC) { $out.IsDomainController = $true }
                } catch { }
                if (-not $out.IsDomainController) { return $out }

                $adOk = Import-ModuleSafe 'ActiveDirectory'
                try {
                    $dom = if ($adOk) { Get-ADDomain } else { $null }
                    $fore= if ($adOk) { Get-ADForest } else { $null }
                    $out.DomainName = $dom?.DNSRoot
                    $out.ForestName = $fore?.Name
                    $out.DFL        = $dom?.DomainMode
                    $out.FFL        = $fore?.ForestMode
                    $fsmo = @()
                    if ($dom) {
                        $fsmo += [pscustomobject]@{ Role='RID';      Owner=$dom.RIDMaster }
                        $fsmo += [pscustomobject]@{ Role='PDC';      Owner=$dom.PDCEmulator }
                        $fsmo += [pscustomobject]@{ Role='Infra';    Owner=$dom.InfrastructureMaster }
                    }
                    if ($fore) {
                        $fsmo += [pscustomobject]@{ Role='Schema';   Owner=$fore.SchemaMaster }
                        $fsmo += [pscustomobject]@{ Role='DomainNaming'; Owner=$fore.DomainNamingMaster }
                    }
                    $out.FSMO = $fsmo
                    $repIssues = @()
                    if ($adOk -and $fore) {
                        try {
                            $fail = Get-ADReplicationFailure -Scope Forest -Target $fore.Name -ErrorAction SilentlyContinue
                            $repIssues = @($fail | Select-Object Server,Partner,FailureType,FirstFailureTime)
                        } catch { }
                    }
                    $out.ReplicationIssues = $repIssues
                } catch { }
                $out
            }

            function Get-DNSSummary {
                $result = [pscustomobject]@{ Installed=$false; Zones=@(); Forwarders=@(); Scavenging=$null }
                try {
                    $svc = Get-Service -Name 'DNS' -ErrorAction SilentlyContinue
                    $result.Installed = [bool]$svc
                    if (-not $result.Installed) { return $result }
                    $dnsOk = Import-ModuleSafe 'DnsServer'
                    if ($dnsOk) {
                        try { $zones = Get-DnsServerZone -ErrorAction Stop; $result.Zones = @($zones | Select-Object ZoneName, ZoneType, IsPaused, IsPrimary) } catch { }
                        try { $fwds = Get-DnsServerForwarder -ErrorAction Stop; $result.Forwarders = @($fwds | Select-Object IPAddress, Recurse, UseRootHint) } catch { }
                        try { $scav = Get-DnsServerScavenging -ErrorAction Stop; $result.Scavenging = $scav } catch { }
                    }
                } catch { }
                $result
            }

            function Get-DHCPSummary {
                $result = [pscustomobject]@{ Installed=$false; Scopes=@(); Reservations=@(); Options=@(); Failover=@() }
                try {
                    $svc = Get-Service -Name 'DhcpServer' -ErrorAction SilentlyContinue
                    $result.Installed = [bool]$svc
                    if (-not $result.Installed) { return $result }

                    $dhcpOk = Import-ModuleSafe 'DhcpServer'
                    $server = $env:COMPUTERNAME

                    # Scopes (module first; fallback to legacy DHCP CLI)
                    $scopes = @()
                    if ($dhcpOk) {
                        try {
                            $scopes = @(Get-DhcpServerv4Scope -ComputerName $server -ErrorAction Stop)
                            $result.Scopes = @($scopes | Select-Object ScopeId,Name,State,StartRange,EndRange,SubnetMask)
                        } catch {
                            $scopes = @()
                            $result.Scopes = @()
                        }
                    }
                    if ($scopes.Count -eq 0) {
                        # Fallback via legacy DHCP CLI to get scopes
                        try {
                            $out = & netsh dhcp server $server show scope 2>$null
                            $parsed = @()
                            foreach ($line in $out) {
                                if ($line -match '^\s*Scope Address:\s+(\d{1,3}(?:\.\d{1,3}){3}).*?Scope Name:\s*(.+)$') {
                                    $sid = $matches[1]
                                    $name = $matches[2].Trim()
                                    $parsed += [pscustomobject]@{ ScopeId = $sid; Name = $name; State = $null; StartRange = $null; EndRange = $null; SubnetMask = $null }
                                }
                            }
                            if ($parsed.Count -gt 0) { $result.Scopes = $parsed; $scopes = $parsed }
                        } catch { }
        }

                    # Reservations per scope — only if we have scopes; never call the cmdlet without a ScopeId
                    $reservations = @()
                    if ($scopes.Count -gt 0) {
                        if ($dhcpOk) {
                            foreach ($s in $scopes) {
                                $sid = $s.ScopeId
                                # Normalize ScopeId to string IP to avoid type binding quirks
                                if ($sid -is [System.Net.IPAddress]) { $sid = $sid.ToString() }
                                try {
                                    $reservations += Get-DhcpServerv4Reservation -ComputerName $server -ScopeId $sid -ErrorAction Stop |
                                        Select-Object @{n='ScopeId';e={$sid}}, IPAddress, ClientId, Name
                                } catch {
                                    # ignore per-scope errors; continue collecting
                                }
                            }
                        }
                        # Fallback to legacy DHCP CLI if module path yielded nothing
                        if ($reservations.Count -eq 0) {
                            foreach ($s in $scopes) {
                                $sid = $s.ScopeId
                                if ($sid -is [System.Net.IPAddress]) { $sid = $sid.ToString() }
                                try {
                                    $out = & netsh dhcp server $server scope $sid show reservedip 2>$null
                                    foreach ($line in $out) {
                                        # Typical CLI line: "IP Address  : 10.0.0.10   Unique ID : 00155D123456   Name : MyHost"
                                        if ($line -match 'IP Address\s*:\s*(\d{1,3}(?:\.\d{1,3}){3}).*?Unique ID\s*:\s*([^\s]+).*?Name\s*:\s*(.+)$') {
                                            $ip = $matches[1]
                                            $cid = $matches[2]
                                            $name = $matches[3].Trim()
                                            $reservations += [pscustomobject]@{
                                                ScopeId  = $sid
                                                IPAddress= $ip
                                                ClientId = $cid
                                                Name     = $name
                                            }
                                        }
                                    }
                                } catch { }
                            }
                        }
                    }
                    $result.Reservations = @($reservations)

                    # Options
                    if ($dhcpOk) {
                        try {
                            $result.Options = @(Get-DhcpServerv4OptionValue -ComputerName $server -ErrorAction Stop |
                                Select-Object OptionId,Name,Value,PolicyName,ScopeId)
                        } catch {
                            $result.Options = @()
                        }
                    }

                    # Failover
                    if ($dhcpOk) {
                        try {
                            $result.Failover = @(Get-DhcpServerv4Failover -ComputerName $server -ErrorAction Stop |
                                Select-Object Name,PrimaryServer,SecondaryServer,State,Mode)
                        } catch {
                            $result.Failover = @()
                        }
                    }
                } catch { }
                $result
            }

            function Get-SharePermissions {
                try {
                    $items=@()
                    Get-SmbShare | Where-Object { $_.Name -notin @('ADMIN$','C$','IPC$') } | ForEach-Object {
                        $s = $_
                        $acl = Get-SmbShareAccess -Name $s.Name -ErrorAction SilentlyContinue
                        foreach ($a in $acl) {
                            $items += [pscustomobject]@{
                                ShareName   = $s.Name
                                Path        = $s.Path
                                AccountName = $a.Name
                                Right       = $a.AccessRight
                                Type        = $a.AccessControlType
                            }
                        }
                    }
                    $items
                } catch { @() }
            }

            function Get-IISDeep {
                $out = [pscustomobject]@{ AppPools=@(); Bindings=@() }
                if (-not (Test-Path 'HKLM:\SOFTWARE\Microsoft\InetStp')) { return $out }
                if (-not (Import-ModuleSafe 'WebAdministration')) { return $out }
                try {
                    $out.AppPools = @(Get-Item IIS:\AppPools\* | Select-Object Name,
                        @{n='Identity';e={ $_.ProcessModel.IdentityType }},
                        @{n='Runtime'; e={ $_.ManagedRuntimeVersion }},
                        @{n='State';   e={ (Get-WebAppPoolState -Name $_.Name).Value }})
                } catch { }
                try {
                    $bindings=@()
                    Get-Website | ForEach-Object {
                        $site = $_
                        foreach ($b in $site.Bindings.Collection) {
                            $bindings += [pscustomobject]@{
                                Site         = $site.Name
                                Protocol     = $b.Protocol
                                BindingInfo  = $b.BindingInformation
                                CertThumb    = $b.CertificateHash
                            }
                        }
                    }
                    $out.Bindings = $bindings
                } catch { }
                $out
            }

            function Get-SQLSummary {
                $result = [pscustomobject]@{ Installed=$false; Instances=@(); Databases=@(); AgentJobs=@() }
                try {
                    $svc = Get-Service -Name 'MSSQLSERVER' -ErrorAction SilentlyContinue
                    if ($svc) { $result.Installed = $true }
                    $hints = @()
                    try {
                        $hints += (Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL" -ErrorAction SilentlyContinue |
                            Select-Object -ExpandProperty Property -ErrorAction SilentlyContinue)
                    } catch { }
                    $result.Instances = @($hints)
                } catch { }
                $result
            }

            function Get-HyperVSummary {
                $result = [pscustomobject]@{ Installed=$false; VMs=@(); Switches=@() }
                try {
                    $svc = Get-Service -Name 'vmms' -ErrorAction SilentlyContinue
                    $result.Installed = [bool]$svc
                    if (-not $result.Installed) { return $result }
                    if (Import-ModuleSafe 'Hyper-V') {
                        try { $result.VMs = @(Get-VM | Select-Object Name, State, CPUUsage, MemoryAssigned, Uptime) } catch { }
                        try { $result.Switches = @(Get-VMSwitch | Select-Object Name, SwitchType) } catch { }
                    }
                } catch { }
                $result
            }

            function Get-ClusterSummary {
                $result = [pscustomobject]@{ Installed=$false; Nodes=@(); Resources=@(); Quorum=@() }
                if (-not (Import-ModuleSafe 'FailoverClusters')) { return $result }
                try {
                    $cl = Get-Cluster -ErrorAction SilentlyContinue
                    if ($cl) {
                        $result.Installed = $true
                        try { $result.Nodes = @(Get-ClusterNode | Select-Object Name, State) } catch { }
                        try { $result.Resources = @(Get-ClusterResource | Select-Object Name, ResourceType, OwnerGroup, State) } catch { }
                        try { $q = Get-ClusterQuorum; $result.Quorum = @($q) } catch { }
                    }
                } catch { }
                $result
            }

            # Assemble result (conditionally include deep roles)
            $res = [pscustomobject]@{
                TimestampUtc         = (Get-Date).ToUniversalTime()
                Basic                = Get-OsAndHardware
                Network              = Get-NetworkSummary
                Volumes              = Get-Volumes
                InstalledApps        = Get-InstalledPrograms
                RolesFeatures        = Get-RolesAndFeatures
                Services             = Get-ServicesSummary
                KeyServices          = Get-KeyServicesStatus
                ServiceLogonAccounts = Get-ServiceLogonAccounts
                Shares               = Get-SmbShares
                IIS             = Get-IISSummary
                Certificates    = Get-CertSummary
                ScheduledTasks  = Get-ScheduledTasksSummary
                Printers        = Get-PrinterSummary
                RoleHints       = Get-RoleHints
            }

            if ($DeepRoles) {
                $res | Add-Member -NotePropertyName SharePermissions -NotePropertyValue (Get-SharePermissions)
                $res | Add-Member -NotePropertyName IISDeep         -NotePropertyValue (Get-IISDeep)
                $res | Add-Member -NotePropertyName AD              -NotePropertyValue (Get-ADSummary)
                $res | Add-Member -NotePropertyName DNS             -NotePropertyValue (Get-DNSSummary)
                $res | Add-Member -NotePropertyName DHCP            -NotePropertyValue (Get-DHCPSummary)
                $res | Add-Member -NotePropertyName SQL             -NotePropertyValue (Get-SQLSummary)
                $res | Add-Member -NotePropertyName HyperV          -NotePropertyValue (Get-HyperVSummary)
                $res | Add-Member -NotePropertyName Cluster         -NotePropertyValue (Get-ClusterSummary)
            }

            $res
        }
    }

    function Invoke-AssessmentLocal {
        param(
            [switch]$IncludeInstalledUpdates,
            [switch]$DeepRoles,
            [string[]]$ExcludeTaskAuthorLike,
            [string[]]$ExcludeTaskNamePrefix,
            [string[]]$IncludeTaskNamePrefix
        )
        $sb = New-AssessmentCollectorScriptBlock `
            -IncludeInstalledUpdates:$IncludeInstalledUpdates `
            -DeepRoles:$DeepRoles `
            -ExcludeTaskAuthorLike:$ExcludeTaskAuthorLike `
            -ExcludeTaskNamePrefix:$ExcludeTaskNamePrefix `
            -IncludeTaskNamePrefix:$IncludeTaskNamePrefix
        & $sb -IncludeInstalledUpdates:$IncludeInstalledUpdates -DeepRoles:$DeepRoles `
              -ExcludeTaskAuthorLike:$ExcludeTaskAuthorLike -ExcludeTaskNamePrefix:$ExcludeTaskNamePrefix -IncludeTaskNamePrefix:$IncludeTaskNamePrefix
    }

    function Invoke-AssessmentRemote {
        param(
            [string]$ComputerName,
            [pscredential]$Credential,
            [switch]$IncludeInstalledUpdates,
            [switch]$DeepRoles,
            [string[]]$ExcludeTaskAuthorLike,
            [string[]]$ExcludeTaskNamePrefix,
            [string[]]$IncludeTaskNamePrefix
        )
        $sb = New-AssessmentCollectorScriptBlock `
            -IncludeInstalledUpdates:$IncludeInstalledUpdates `
            -DeepRoles:$DeepRoles `
            -ExcludeTaskAuthorLike:$ExcludeTaskAuthorLike `
            -ExcludeTaskNamePrefix:$ExcludeTaskNamePrefix `
            -IncludeTaskNamePrefix:$IncludeTaskNamePrefix
        $p=@{ ComputerName=$ComputerName }
        if ($Credential) { $p.Credential=$Credential }
        Invoke-Command @p -ScriptBlock $sb -ArgumentList $IncludeInstalledUpdates,$DeepRoles,$ExcludeTaskAuthorLike,$ExcludeTaskNamePrefix,$IncludeTaskNamePrefix
    }

    function Save-Assessment {
        param(
            [object]$Data,
            [ValidateSet('None','Json','Html','Csv')][string]$Format='None',
            [string]$OutputPath,
            [switch]$ExcelMergeAfterCsv,
            [string]$MergedExcelPath
        )
        if ($Format -eq 'None') { return }

        if (-not $OutputPath) {
            $base = 'C:\Temp\SDA_Results'
            if (-not (Test-Path $base)) { New-Item -ItemType Directory -Path $base -Force | Out-Null }
            $OutputPath = Join-Path $base ("ServerAssessment-{0}-{1}" -f $Data.Basic.ComputerName,(Get-Date -Format yyyyMMdd-HHmmss))
        }
        if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

        switch ($Format) {
            'Json' {
                $jsonFile = Join-Path $OutputPath 'assessment.json'
                $Data | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonFile -Encoding UTF8
                Write-Host ("[JSON] {0}" -f $jsonFile) -ForegroundColor Green
                Write-Log -Level INFO -Message "Wrote JSON assessment: $jsonFile" -Section 'Output'
            }
            'Html' {
                $htmlFile = Join-Path $OutputPath 'assessment.html'
                $scriptVersion = '1.1.0'

                function HtmlEncode($s) {
                    if ($null -eq $s) { return '' }
                    $t = [string]$s
                    $t = $t -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;' -replace "'",'&#39;'
                    return $t
                }

                function SafeToTable([string]$id, [string]$title, $rows, [switch]$NoCount) {
                    try {
                        $rowCount = 0
                        if ($null -eq $rows) { $rowCount = 0 }
                        elseif ($rows -is [string]) { $rows = @($rows); $rowCount = 1 }
                        elseif ($rows -isnot [System.Collections.IEnumerable]) { $rows = @($rows); $rowCount = 1 }
                        else { $rows = @($rows); $rowCount = $rows.Count }

                        $countLabel = if (-not $NoCount -and $rowCount -gt 0) { " <span class='count'>($rowCount)</span>" } else { '' }
                        if ($rowCount -eq 0) { return "<h2 id='$id'>$title$countLabel</h2><p class='empty'>None</p>" }

                        function _Str($v) {
                            if ($null -eq $v) { return '' }
                            if ($v -is [string]) { return $v }
                            if ($v -is [System.Collections.IEnumerable] -and ($v -isnot [string])) {
                                $arr = @(); foreach ($i in $v) { $arr += (_Str $i) }; return ($arr -join ', ')
                            }
                            try { return ($v | Out-String).Trim() } catch { return "${v}" }
                        }

                        $first = $rows | Select-Object -First 1
                        $noteProps = @($first.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' } | Select-Object -ExpandProperty Name)
                        $props = if ($noteProps.Count -gt 0) { $noteProps } else { @($first.PSObject.Properties | Select-Object -ExpandProperty Name) }

                        if (-not $props -or $props.Count -eq 0) {
                            $body = ($rows | ForEach-Object { "<tr><td>$(HtmlEncode (_Str $_))</td></tr>" }) -join "`n"
                            return "<h2 id='$id'>$title$countLabel</h2><div class='table-wrap'><table><thead><tr><th>Value</th></tr></thead><tbody>$body</tbody></table></div>"
                        }

                        $head = ($props | ForEach-Object { "<th>" + (HtmlEncode $_) + "</th>" }) -join ''
                        $rowIdx = 0
                        $body = ($rows | ForEach-Object {
                            $row = $_
                            $rowClass = if ($rowIdx++ % 2 -eq 1) { " class='alt'" } else { '' }
                            $cells = ($props | ForEach-Object {
                                $name = $_
                                $p = $row.PSObject.Properties[$name]
                                $val = if ($p) { $p.Value } else { $null }
                                "<td>" + (HtmlEncode (_Str $val)) + "</td>"
                            }) -join ''
                            "<tr$rowClass>$cells</tr>"
                        }) -join "`n"

                        return "<h2 id='$id'>$title$countLabel</h2><div class='table-wrap'><table><thead><tr>$head</tr></thead><tbody>$body</tbody></table></div>"
                    } catch {
                        return "<h2 id='$id'>$title</h2><p class='error'>Error rendering section: $(HtmlEncode $_.Exception.Message)</p>"
                    }
                }

                try {
                    # Build TOC entries and sections together
                    $tocEntries = @()
                    $sections = @()

                    # Report header with metadata
                    $generatedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss') + ' UTC'
                    $headerHtml = @"
<div class="report-header">
    <h1>Server Assessment Report</h1>
    <div class="meta">
        <span><strong>Server:</strong> $(HtmlEncode $Data.Basic.ComputerName)</span>
        <span><strong>Domain:</strong> $(HtmlEncode $Data.Basic.Domain)</span>
        <span><strong>Generated:</strong> $generatedUtc</span>
        <span><strong>Script Version:</strong> $scriptVersion</span>
    </div>
</div>
"@

                    # Basic section (special formatting)
                    $tocEntries += "<li><a href='#basic'>Basic Info</a></li>"
                    $basicHtml = "<h2 id='basic'>Basic Info</h2><div class='basic-info'>"
                    $basicHtml += "<div><b>Computer Name:</b> $(HtmlEncode $Data.Basic.ComputerName)</div>"
                    $basicHtml += "<div><b>OS:</b> $(HtmlEncode $Data.Basic.OS)</div>"
                    $basicHtml += "<div><b>OS Version:</b> $(HtmlEncode $Data.Basic.OSVersion)</div>"
                    $basicHtml += "<div><b>Domain:</b> $(HtmlEncode $Data.Basic.Domain)</div>"
                    $basicHtml += "<div><b>Last Boot:</b> $(HtmlEncode $Data.Basic.LastBootUpTime)</div>"
                    $basicHtml += "<div><b>Model:</b> $(HtmlEncode $Data.Basic.Model)</div>"
                    $basicHtml += "<div><b>Memory (GB):</b> $(HtmlEncode $Data.Basic.PhysicalMemoryGB)</div>"
                    $basicHtml += "</div>"
                    $sections += $basicHtml

                    # Standard sections with TOC
                    $sectionDefs = @(
                        @{ Id='network'; Title='Network'; Data=$Data.Network },
                        @{ Id='volumes'; Title='Volumes'; Data=$Data.Volumes },
                        @{ Id='apps'; Title='Installed Apps'; Data=$Data.InstalledApps },
                        @{ Id='roles'; Title='Roles/Features (Installed)'; Data=$Data.RolesFeatures.Installed },
                        @{ Id='keysvcs'; Title='Key Services'; Data=$Data.KeyServices },
                        @{ Id='autonotrun'; Title='Services: Auto but Not Running'; Data=$Data.Services.AutoButNotRunning },
                        @{ Id='thirdparty'; Title='Suspected Third-Party Services'; Data=$Data.Services.SuspectedThirdParty },
                        @{ Id='svclogon'; Title='Service Logon Accounts (non-built-in)'; Data=$Data.ServiceLogonAccounts.UniqueAccounts },
                        @{ Id='shares'; Title='SMB Shares'; Data=$Data.Shares },
                        @{ Id='iissites'; Title='IIS Sites'; Data=$Data.IIS.Sites },
                        @{ Id='iispools'; Title='IIS App Pools'; Data=$Data.IIS.AppPools },
                        @{ Id='certs'; Title='Certificates'; Data=$Data.Certificates },
                        @{ Id='tasks'; Title='Scheduled Tasks (Non-Microsoft)'; Data=$Data.ScheduledTasks.NonMicrosoft },
                        @{ Id='printers'; Title='Printers'; Data=$Data.Printers },
                        @{ Id='rolehints'; Title='Role Hints'; Data=@($Data.RoleHints) }
                    )

                    foreach ($def in $sectionDefs) {
                        $tocEntries += "<li><a href='#$($def.Id)'>$($def.Title)</a></li>"
                        $sections += (SafeToTable -id $def.Id -title $def.Title -rows $def.Data)
                    }

                    # Deep roles (conditional sections)
                    if ($Data.PSObject.Properties['SharePermissions']) {
                        $tocEntries += "<li><a href='#shareperms'>Share Permissions</a></li>"
                        $sections += (SafeToTable -id 'shareperms' -title 'Share Permissions' -rows $Data.SharePermissions)
                    }
                    if ($Data.PSObject.Properties['IISDeep']) {
                        $tocEntries += "<li><a href='#iisdeep-pools'>IIS App Pools (Deep)</a></li>"
                        $tocEntries += "<li><a href='#iisdeep-bindings'>IIS Bindings</a></li>"
                        $sections += (SafeToTable -id 'iisdeep-pools' -title 'IIS App Pools (Deep)' -rows $Data.IISDeep.AppPools)
                        $sections += (SafeToTable -id 'iisdeep-bindings' -title 'IIS Bindings (with cert thumbprints)' -rows $Data.IISDeep.Bindings)
                    }
                    if ($Data.PSObject.Properties['AD']) {
                        $tocEntries += "<li><a href='#ad'>Active Directory</a></li>"
                        $adBasic = @([pscustomobject]@{
                            IsDomainController = $Data.AD.IsDomainController
                            Domain = $Data.AD.DomainName
                            Forest = $Data.AD.ForestName
                            DFL = $Data.AD.DFL
                            FFL = $Data.AD.FFL
                        })
                        $sections += "<h2 id='ad'>Active Directory</h2>"
                        $sections += (SafeToTable -id 'ad-basics' -title 'AD Basics' -rows $adBasic -NoCount)
                        $sections += (SafeToTable -id 'ad-fsmo' -title 'AD FSMO Roles' -rows $Data.AD.FSMO)
                        $sections += (SafeToTable -id 'ad-repl' -title 'AD Replication Issues' -rows $Data.AD.ReplicationIssues)
                    }
                    if ($Data.PSObject.Properties['DNS']) {
                        $tocEntries += "<li><a href='#dns'>DNS</a></li>"
                        $sections += "<h2 id='dns'>DNS</h2>"
                        $sections += (SafeToTable -id 'dns-basics' -title 'DNS Basics' -rows @([pscustomobject]@{ Installed = $Data.DNS.Installed }) -NoCount)
                        $sections += (SafeToTable -id 'dns-zones' -title 'DNS Zones' -rows $Data.DNS.Zones)
                        $sections += (SafeToTable -id 'dns-fwd' -title 'DNS Forwarders' -rows $Data.DNS.Forwarders)
                        $sections += (SafeToTable -id 'dns-scav' -title 'DNS Scavenging' -rows @($Data.DNS.Scavenging))
                    }
                    if ($Data.PSObject.Properties['DHCP']) {
                        $tocEntries += "<li><a href='#dhcp'>DHCP</a></li>"
                        $sections += "<h2 id='dhcp'>DHCP</h2>"
                        $sections += (SafeToTable -id 'dhcp-basics' -title 'DHCP Basics' -rows @([pscustomobject]@{ Installed = $Data.DHCP.Installed }) -NoCount)
                        $sections += (SafeToTable -id 'dhcp-scopes' -title 'DHCP Scopes' -rows $Data.DHCP.Scopes)
                        $sections += (SafeToTable -id 'dhcp-res' -title 'DHCP Reservations' -rows $Data.DHCP.Reservations)
                        $sections += (SafeToTable -id 'dhcp-opts' -title 'DHCP Options' -rows $Data.DHCP.Options)
                        $sections += (SafeToTable -id 'dhcp-fail' -title 'DHCP Failover' -rows $Data.DHCP.Failover)
                    }
                    if ($Data.PSObject.Properties['SQL']) {
                        $tocEntries += "<li><a href='#sql'>SQL Server</a></li>"
                        $sections += "<h2 id='sql'>SQL Server</h2>"
                        $sections += (SafeToTable -id 'sql-basics' -title 'SQL Basics' -rows @([pscustomobject]@{ Installed = $Data.SQL.Installed }) -NoCount)
                        $sections += (SafeToTable -id 'sql-inst' -title 'SQL Instances' -rows @($Data.SQL.Instances))
                    }
                    if ($Data.PSObject.Properties['HyperV']) {
                        $tocEntries += "<li><a href='#hyperv'>Hyper-V</a></li>"
                        $sections += "<h2 id='hyperv'>Hyper-V</h2>"
                        $sections += (SafeToTable -id 'hv-basics' -title 'Hyper-V Basics' -rows @([pscustomobject]@{ Installed = $Data.HyperV.Installed }) -NoCount)
                        $sections += (SafeToTable -id 'hv-vms' -title 'Hyper-V VMs' -rows $Data.HyperV.VMs)
                        $sections += (SafeToTable -id 'hv-switches' -title 'Hyper-V Switches' -rows $Data.HyperV.Switches)
                    }
                    if ($Data.PSObject.Properties['Cluster']) {
                        $tocEntries += "<li><a href='#cluster'>Failover Cluster</a></li>"
                        $sections += "<h2 id='cluster'>Failover Cluster</h2>"
                        $sections += (SafeToTable -id 'cl-basics' -title 'Cluster Basics' -rows @([pscustomobject]@{ Installed = $Data.Cluster.Installed }) -NoCount)
                        $sections += (SafeToTable -id 'cl-nodes' -title 'Cluster Nodes' -rows $Data.Cluster.Nodes)
                        $sections += (SafeToTable -id 'cl-res' -title 'Cluster Resources' -rows $Data.Cluster.Resources)
                        $sections += (SafeToTable -id 'cl-quorum' -title 'Cluster Quorum' -rows @($Data.Cluster.Quorum))
                    }

                    # Build TOC
                    $tocHtml = "<nav class='toc'><h3>Table of Contents</h3><ul>$($tocEntries -join "`n")</ul></nav>"

                    # Modern CSS with responsive design, zebra striping, sticky headers, print-friendly
                    $css = @"
<style>
:root { --primary: #0078d4; --bg: #f9f9f9; --border: #ddd; --alt-row: #f5f9fc; }
* { box-sizing: border-box; }
body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; font-size: 13px; line-height: 1.5; margin: 0; padding: 20px; background: var(--bg); color: #333; }
.report-header { background: var(--primary); color: #fff; padding: 20px 24px; margin: -20px -20px 20px -20px; }
.report-header h1 { margin: 0 0 10px 0; font-size: 24px; }
.report-header .meta { display: flex; flex-wrap: wrap; gap: 20px; font-size: 12px; }
.report-header .meta span { background: rgba(255,255,255,0.15); padding: 4px 10px; border-radius: 3px; }
.toc { background: #fff; border: 1px solid var(--border); border-radius: 6px; padding: 16px 20px; margin-bottom: 24px; }
.toc h3 { margin: 0 0 10px 0; font-size: 14px; color: var(--primary); }
.toc ul { margin: 0; padding: 0; list-style: none; column-count: 3; column-gap: 20px; }
.toc li { break-inside: avoid; margin-bottom: 4px; }
.toc a { color: var(--primary); text-decoration: none; font-size: 12px; }
.toc a:hover { text-decoration: underline; }
h2 { color: var(--primary); border-bottom: 2px solid var(--primary); padding-bottom: 6px; margin: 28px 0 12px 0; font-size: 16px; }
h2 .count { font-weight: normal; color: #666; font-size: 13px; }
.basic-info { background: #fff; border: 1px solid var(--border); border-radius: 6px; padding: 16px; display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 8px; }
.basic-info div { padding: 4px 0; }
.basic-info b { color: #555; }
.table-wrap { overflow-x: auto; margin-bottom: 16px; }
table { width: 100%; border-collapse: collapse; background: #fff; border: 1px solid var(--border); border-radius: 6px; overflow: hidden; font-size: 12px; }
thead { position: sticky; top: 0; z-index: 1; }
th { background: linear-gradient(180deg, #f8f8f8 0%, #e8e8e8 100%); padding: 10px 12px; text-align: left; font-weight: 600; border-bottom: 2px solid var(--border); white-space: nowrap; }
td { padding: 8px 12px; border-bottom: 1px solid #eee; vertical-align: top; }
tr.alt { background: var(--alt-row); }
tr:hover { background: #e8f4fc; }
.empty { color: #888; font-style: italic; padding: 12px; background: #fff; border: 1px solid var(--border); border-radius: 4px; }
.error { color: #c00; background: #fee; padding: 12px; border: 1px solid #fcc; border-radius: 4px; }
@media print {
    body { background: #fff; padding: 0; }
    .report-header { background: #333; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
    .toc { page-break-after: always; }
    h2 { page-break-after: avoid; }
    table { page-break-inside: auto; }
    tr { page-break-inside: avoid; }
}
@media (max-width: 768px) {
    .toc ul { column-count: 1; }
    .basic-info { grid-template-columns: 1fr; }
}
</style>
"@

                    $html = "<!DOCTYPE html><html lang='en'><head><meta charset='UTF-8'><meta name='viewport' content='width=device-width, initial-scale=1.0'>$css<title>Server Assessment - $(HtmlEncode $Data.Basic.ComputerName)</title></head><body>$headerHtml$tocHtml$($sections -join "`n")</body></html>"

                    [System.IO.File]::WriteAllText($htmlFile, $html, [System.Text.Encoding]::UTF8)
                    Write-Host ("[HTML] {0}" -f $htmlFile) -ForegroundColor Green
                    Write-Log -Level INFO -Message "Wrote HTML assessment: $htmlFile" -Section 'Output'
                } catch {
                    $msg = $_.Exception.Message
                    $fallback = "<!DOCTYPE html><html><head><title>Server Assessment - $(HtmlEncode $Data.Basic.ComputerName)</title></head><body><h1>Server Assessment</h1><p>HTML rendering failed: $(HtmlEncode $msg)</p></body></html>"
                    try {
                        if (-not (Test-Path $OutputPath)) {
                            New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
                        }
                        [System.IO.File]::WriteAllText($htmlFile, $fallback, [System.Text.Encoding]::UTF8)
                        Write-Warning "HTML export error; wrote minimal file: $htmlFile"
                        Write-Log -Level WARN -Message "HTML export error; wrote minimal file: $htmlFile | $msg" -Section 'Output'
                    } catch {
                        Write-Error "Failed to write HTML (including fallback). Path: $htmlFile | Error: $($_.Exception.Message)"
                        Write-Log -Level ERROR -Message "Failed to write HTML fallback: $htmlFile | $($_.Exception.Message)" -Section 'Output'
                    }
                }
            }
            'Csv' {
                function WriteCsv($name, $rows) {
                    try {
                        $file = Join-Path $OutputPath ($name + '.csv')
                        if ($rows -and ($rows | Measure-Object).Count -gt 0) {
                            $rows | Export-Csv -Path $file -NoTypeInformation -Encoding UTF8
                        } else {
                            @() | Export-Csv -Path $file -NoTypeInformation -Encoding UTF8
                        }
                        Write-Host ("[CSV] {0}" -f $file) -ForegroundColor Green
                        Write-Log -Level INFO -Message "Wrote CSV: $file" -Section 'Output'
                    } catch {
                        Write-Warning "Failed CSV export ($name): $($_.Exception.Message)"
                        Write-Log -Level WARN -Message "Failed CSV export ($name): $($_.Exception.Message)" -Section 'Output'
                    }
                }
                WriteCsv 'Basic' @($Data.Basic)
                WriteCsv 'Network' $Data.Network
                WriteCsv 'Volumes' $Data.Volumes
                WriteCsv 'InstalledApps' $Data.InstalledApps
                WriteCsv 'RolesFeatures.Installed' $Data.RolesFeatures.Installed
                WriteCsv 'KeyServices' $Data.KeyServices
                WriteCsv 'Services.All' $Data.Services.All
                WriteCsv 'Services.AutoButNotRunning' $Data.Services.AutoButNotRunning
                WriteCsv 'Services.SuspectedThirdParty' $Data.Services.SuspectedThirdParty
                WriteCsv 'Services.LogonAccounts' $Data.ServiceLogonAccounts.UniqueAccounts
                WriteCsv 'Services.LogonAccountsDetail' $Data.ServiceLogonAccounts.AllServices
                WriteCsv 'Shares' $Data.Shares
                WriteCsv 'IIS.Sites' $Data.IIS.Sites
                WriteCsv 'Certificates' $Data.Certificates
                WriteCsv 'ScheduledTasks.All' $Data.ScheduledTasks.All
                WriteCsv 'ScheduledTasks.NonMicrosoft' $Data.ScheduledTasks.NonMicrosoft
                WriteCsv 'Printers' $Data.Printers
                WriteCsv 'RoleHints' @($Data.RoleHints)

                # Deep roles (conditional CSVs)
                if ($Data.PSObject.Properties['SharePermissions']) { WriteCsv 'SharePermissions' $Data.SharePermissions }
                if ($Data.PSObject.Properties['IISDeep']) {
                    WriteCsv 'IISDeep.AppPools' $Data.IISDeep.AppPools
                    WriteCsv 'IISDeep.Bindings' $Data.IISDeep.Bindings
                }
                if ($Data.PSObject.Properties['AD']) {
                    WriteCsv 'AD.FSMO' $Data.AD.FSMO
                    WriteCsv 'AD.ReplicationIssues' $Data.AD.ReplicationIssues
                }
                if ($Data.PSObject.Properties['DNS']) {
                    WriteCsv 'DNS.Zones' $Data.DNS.Zones
                    WriteCsv 'DNS.Forwarders' $Data.DNS.Forwarders
                }
                if ($Data.PSObject.Properties['DHCP']) {
                    WriteCsv 'DHCP.Scopes' $Data.DHCP.Scopes
                    WriteCsv 'DHCP.Reservations' $Data.DHCP.Reservations
                    WriteCsv 'DHCP.Options' $Data.DHCP.Options
                    WriteCsv 'DHCP.Failover' $Data.DHCP.Failover
                }
                if ($Data.PSObject.Properties['SQL']) {
                    WriteCsv 'SQL.Instances' @($Data.SQL.Instances)
                }
                if ($Data.PSObject.Properties['HyperV']) {
                    WriteCsv 'HyperV.VMs' $Data.HyperV.VMs
                    WriteCsv 'HyperV.Switches' $Data.HyperV.Switches
                }
                if ($Data.PSObject.Properties['Cluster']) {
                    WriteCsv 'Cluster.Nodes' $Data.Cluster.Nodes
                    WriteCsv 'Cluster.Resources' $Data.Cluster.Resources
                    WriteCsv 'Cluster.Quorum' @($Data.Cluster.Quorum)
                }

                if ($ExcelMergeAfterCsv) {
                    $xlsx = if ($MergedExcelPath) { $MergedExcelPath } else { Join-Path $OutputPath 'Assessment-All.xlsx' }
                    try {
                        Merge-CsvToExcel -CsvFolder $OutputPath -OutXlsx $xlsx
                        Write-Log -Level INFO -Message "Merged CSVs to Excel: $xlsx" -Section 'Output'
                    } catch {
                        Write-Warning "Excel merge failed: $($_.Exception.Message)"
                        Write-Log -Level WARN -Message "Excel merge failed: $($_.Exception.Message)" -Section 'Output'
                    }
                }
            }
        }

        # Checklist generation removed per user request
    }

function Show-Summary {
    param(
        [object]$Data,
        [int]$AppsTop,
        [int]$ServicesTop,
        [int]$TasksTop,
        [int]$SharesTop,
        [int]$CertsTop,
        [int]$InstalledFeaturesTop
    )

    # Normalize every potentially-enumerable to an array to avoid .Count errors
    $apps           = @($Data.InstalledApps)
    $features       = @($Data.RolesFeatures.Installed)
    $keyServices    = @($Data.KeyServices)
    # $svcsAll        = @($Data.Services.All)  # not used; keep for future debug if needed
    $svcsAutoNR     = @($Data.Services.AutoButNotRunning)
    $svcsThird      = @($Data.Services.SuspectedThirdParty)
    $shares         = @($Data.Shares)
    $iis            = $Data.IIS
    $iisSites       = @($Data.IIS.Sites)
    $certs          = @($Data.Certificates)
    # $tasksAll       = @($Data.ScheduledTasks.All) # not used; keep for future debug if needed
    $tasksNonMs     = @($Data.ScheduledTasks.NonMicrosoft)
    $printers       = @($Data.Printers)
    $roleHints      = @($Data.RoleHints)
    $netIfaces      = @($Data.Network)
    $vols           = @($Data.Volumes)

    Write-Host "================= SERVER ASSESSMENT SUMMARY =================" -ForegroundColor Cyan
    Write-Host ("Target: {0} | Time (UTC): {1}" -f $Data.Basic.ComputerName,$Data.TimestampUtc) -ForegroundColor Cyan
    Write-Host "--------------------------------------------------------------" -ForegroundColor DarkCyan

    Write-Host "Basic System:" -ForegroundColor Yellow
    @($Data.Basic) | Select-Object ComputerName,OS,OSVersion,Domain,PartOfDomain,Model,Manufacturer,PhysicalMemoryGB,LastBootUpTime |
        Format-List

    Write-Host "`nNetwork Interfaces:" -ForegroundColor Yellow
    $netIfaces | Format-Table InterfaceAlias,IPv4Address,IPv4DefaultGw,DNSServers -AutoSize

    Write-Host "`nVolumes:" -ForegroundColor Yellow
    $vols | Sort-Object DriveLetter |
      Select-Object DriveLetter,FileSystem,FileSystemLabel,
        @{n='SizeGB';e={ if ($_.Size) { [math]::Round($_.Size/1GB,2) } else { $null } }},
        @{n='FreeGB';e={ if ($_.SizeRemaining) { [math]::Round($_.SizeRemaining/1GB,2) } else { $null } }},
        Path |
      Format-Table -AutoSize

    Write-Host ("`nInstalled Applications (first {0} of {1}):" -f $AppsTop, $apps.Count) -ForegroundColor Yellow
    $apps | Sort-Object DisplayName | Select-Object -First $AppsTop DisplayName,DisplayVersion,Publisher,InstallDate |
      Format-Table -AutoSize
    if ($apps.Count -gt $AppsTop) {
        Write-Host ("... {0} more not shown." -f ($apps.Count - $AppsTop)) -ForegroundColor DarkYellow
    }

    Write-Host ("`nRoles/Features Installed (first {0} of {1}):" -f $InstalledFeaturesTop, $features.Count) -ForegroundColor Yellow
    $features | Sort-Object DisplayName | Select-Object -First $InstalledFeaturesTop Name,DisplayName |
      Format-Table -AutoSize
    if ($features.Count -gt $InstalledFeaturesTop) {
        Write-Host ("... {0} more features not shown." -f ($features.Count - $InstalledFeaturesTop)) -ForegroundColor DarkYellow
    }
    Write-Host ("Detection method: {0}" -f $Data.RolesFeatures.Method) -ForegroundColor DarkGray

    Write-Host "`nKey Services:" -ForegroundColor Yellow
    $keyServices | Sort-Object Name | Format-Table Name,Status,StartType -AutoSize

    Write-Host ("`nServices (Auto but NOT Running) - first {0} of {1}:" -f $ServicesTop, $svcsAutoNR.Count) -ForegroundColor Yellow
    $svcsAutoNR | Sort-Object DisplayName | Select-Object -First $ServicesTop DisplayName,StartMode,State |
      Format-Table -AutoSize
    if ($svcsAutoNR.Count -gt $ServicesTop) {
        Write-Host ("... {0} more not shown." -f ($svcsAutoNR.Count - $ServicesTop)) -ForegroundColor DarkYellow
    }

    Write-Host ("`nSuspected Third-Party Services - first {0} of {1}:" -f $ServicesTop, $svcsThird.Count) -ForegroundColor Yellow
    $svcsThird | Sort-Object DisplayName | Select-Object -First $ServicesTop DisplayName,State,PathName |
      Format-Table -AutoSize
    if ($svcsThird.Count -gt $ServicesTop) {
        Write-Host ("... {0} more not shown." -f ($svcsThird.Count - $ServicesTop)) -ForegroundColor DarkYellow
    }

    # Service Logon Accounts (non-built-in)
    $svcLogonAccts = @($Data.ServiceLogonAccounts.UniqueAccounts)
    Write-Host ("`nService Logon Accounts (non-built-in) - {0} unique:" -f $svcLogonAccts.Count) -ForegroundColor Yellow
    if ($svcLogonAccts.Count -gt 0) {
        $svcLogonAccts | Select-Object -First $ServicesTop LogonAccount, ServiceCount, Services |
          Format-Table -AutoSize -Wrap
        if ($svcLogonAccts.Count -gt $ServicesTop) {
            Write-Host ("... {0} more accounts not shown." -f ($svcLogonAccts.Count - $ServicesTop)) -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "  (none - all services use built-in accounts)" -ForegroundColor DarkGray
    }

    Write-Host ("`nSMB Shares (first {0} of {1}):" -f $SharesTop, $shares.Count) -ForegroundColor Yellow
    $shares | Select-Object -First $SharesTop Name,Path,EncryptData,CurrentUsers |
      Format-Table -AutoSize
    if ($shares.Count -gt $SharesTop) {
        Write-Host ("... {0} more shares not shown." -f ($shares.Count - $SharesTop)) -ForegroundColor DarkYellow
    }

    Write-Host "`nIIS:" -ForegroundColor Yellow
    if ($iis -and $iis.Installed) {
        $iisSites | Select-Object -First 20 Name,State,PhysicalPath,@{n='Bindings';e={$_.Bindings}} | Format-Table -AutoSize
        if ($iisSites.Count -gt 20) {
            Write-Host ("... {0} more IIS sites not shown." -f ($iisSites.Count - 20)) -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "IIS not installed." -ForegroundColor DarkGray
    }

    Write-Host ("`nCertificates (first {0} of {1}):" -f $CertsTop, $certs.Count) -ForegroundColor Yellow
    $certs | Sort-Object NotAfter | Select-Object -First $CertsTop Store,Subject,@{n='Expires';e={$_.NotAfter}},HasPrivateKey |
      Format-Table -AutoSize
    if ($certs.Count -gt $CertsTop) {
        Write-Host ("... {0} more certificates not shown." -f ($certs.Count - $CertsTop)) -ForegroundColor DarkYellow
    }

    Write-Host ("`nScheduled Tasks (Non-Microsoft) - first {0} of {1}:" -f $TasksTop, $tasksNonMs.Count) -ForegroundColor Yellow
    $tasksNonMs | Sort-Object TaskName | Select-Object -First $TasksTop TaskName,TaskPath,State,Author |
      Format-Table -AutoSize
    if ($tasksNonMs.Count -gt $TasksTop) {
        Write-Host ("... {0} more tasks not shown." -f ($tasksNonMs.Count - $TasksTop)) -ForegroundColor DarkYellow
    }

    Write-Host "`nPrinters:" -ForegroundColor Yellow
    if ($printers.Count -gt 0) {
        $printers | Select-Object -First 40 Name,DriverName,PortName,Shared | Format-Table -AutoSize
        if ($printers.Count -gt 40) {
            Write-Host ("... {0} more printers not shown." -f ($printers.Count - 40)) -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "No printers detected." -ForegroundColor DarkGray
    }

    Write-Host "`nRole Hints:" -ForegroundColor Yellow
    $roleHints | Format-List

    # Deep roles summary (only show if present)
    if ($Data.PSObject.Properties['AD'] -or
        $Data.PSObject.Properties['DNS'] -or
        $Data.PSObject.Properties['DHCP'] -or
        $Data.PSObject.Properties['IISDeep'] -or
        $Data.PSObject.Properties['SharePermissions'] -or
        $Data.PSObject.Properties['SQL'] -or
        $Data.PSObject.Properties['HyperV'] -or
        $Data.PSObject.Properties['Cluster']) {

        Write-Host "`nRole Deep-Dives:" -ForegroundColor Yellow

        if ($Data.PSObject.Properties['AD'] -and $Data.AD.IsDomainController) {
            Write-Host "Active Directory (DC): Domain=$($Data.AD.DomainName) | Forest=$($Data.AD.ForestName) | DFL=$($Data.AD.DFL) | FFL=$($Data.AD.FFL)" -ForegroundColor Yellow
            @($Data.AD.FSMO) | Format-Table Role,Owner -AutoSize
            if (@($Data.AD.ReplicationIssues).Count -gt 0) {
                Write-Host ("Replication issues: {0}" -f (@($Data.AD.ReplicationIssues).Count)) -ForegroundColor DarkYellow
                @($Data.AD.ReplicationIssues) | Select-Object -First 10 Server,Partner,FailureType,FirstFailureTime | Format-Table -AutoSize
            } else {
                Write-Host "Replication: no failures reported." -ForegroundColor DarkGray
            }
        }

        if ($Data.PSObject.Properties['DNS'] -and $Data.DNS.Installed) {
            Write-Host ("DNS: {0} zones, {1} forwarders" -f (@($Data.DNS.Zones).Count), (@($Data.DNS.Forwarders).Count)) -ForegroundColor Yellow
            @($Data.DNS.Zones) | Select-Object -First 10 ZoneName,ZoneType,IsPrimary | Format-Table -AutoSize
        }

        if ($Data.PSObject.Properties['DHCP'] -and $Data.DHCP.Installed) {
            Write-Host ("DHCP: {0} scopes, {1} reservations, {2} options" -f (@($Data.DHCP.Scopes).Count), (@($Data.DHCP.Reservations).Count), (@($Data.DHCP.Options).Count)) -ForegroundColor Yellow
            @($Data.DHCP.Scopes) | Select-Object -First 5 ScopeId,Name,State | Format-Table -AutoSize
            if (@($Data.DHCP.Failover).Count -gt 0) { Write-Host ("Failover pairs: {0}" -f (@($Data.DHCP.Failover).Count)) -ForegroundColor DarkYellow }
        }

        if ($Data.PSObject.Properties['SharePermissions']) {
            $sp = @($Data.SharePermissions)
            Write-Host ("Share Permissions entries: {0}" -f $sp.Count) -ForegroundColor Yellow
            $sp | Select-Object -First 15 ShareName,Path,AccountName,Right | Format-Table -AutoSize
        }

        if ($Data.PSObject.Properties['IISDeep'] -and $Data.IIS.Installed) {
            Write-Host ("IIS AppPools: {0}" -f (@($Data.IISDeep.AppPools).Count)) -ForegroundColor Yellow
            @($Data.IISDeep.AppPools) | Select-Object -First 10 Name,State,Identity,Runtime | Format-Table -AutoSize
            Write-Host ("IIS Bindings: {0}" -f (@($Data.IISDeep.Bindings).Count)) -ForegroundColor Yellow
            @($Data.IISDeep.Bindings) | Select-Object -First 10 Site,Protocol,BindingInfo,CertThumb | Format-Table -AutoSize
        }

        if ($Data.PSObject.Properties['SQL'] -and ($Data.SQL.Installed -or (@($Data.SQL.Instances).Count -gt 0))) {
            Write-Host ("SQL instances (hints): {0}" -f (@($Data.SQL.Instances).Count)) -ForegroundColor Yellow
            @($Data.SQL.Instances) | Select-Object -First 10 | Format-Table -AutoSize
        }

        if ($Data.PSObject.Properties['HyperV'] -and $Data.HyperV.Installed) {
            Write-Host ("Hyper-V VMs: {0} | Switches: {1}" -f (@($Data.HyperV.VMs).Count), (@($Data.HyperV.Switches).Count)) -ForegroundColor Yellow
            @($Data.HyperV.VMs) | Select-Object -First 10 Name,State,CPUUsage,MemoryAssigned | Format-Table -AutoSize
        }

        if ($Data.PSObject.Properties['Cluster'] -and $Data.Cluster.Installed) {
            Write-Host ("Cluster nodes: {0} | resources: {1}" -f (@($Data.Cluster.Nodes).Count), (@($Data.Cluster.Resources).Count)) -ForegroundColor Yellow
            @($Data.Cluster.Resources) | Select-Object -First 10 Name,ResourceType,OwnerGroup,State | Format-Table -AutoSize
        }
    }

    Write-Host "`n================= END SUMMARY =================`n" -ForegroundColor Cyan
}

    function Backup-IISConfigIfRequested {
        param([object]$Data,[string]$OutputPath,[switch]$ExportIISConfig)
        if (-not $ExportIISConfig) { return }
        try {
            if ($Data.IIS.Installed) {
                $src = "$env:windir\system32\inetsrv\config\applicationHost.config"
                if (Test-Path $src) {
                    $dst = Join-Path $OutputPath "applicationHost.config.bak"
                    Copy-Item -Path $src -Destination $dst -Force
                    Write-Host ("[IIS] Backed up applicationHost.config to {0}" -f $dst) -ForegroundColor Green
                }
            }
        } catch {
            Write-Warning "IIS config backup failed: $($_.Exception.Message)"
        }
    }

    function Export-CertPemIfRequested {
        param([object]$Data,[string]$OutputPath,[switch]$ExportCertificates)
        if (-not $ExportCertificates) { return }
        try {
            foreach ($c in $Data.Certificates) {
                $pemFile = Join-Path $OutputPath ("cert-" + ($c.Thumbprint) + ".txt")
                $info = "Store: {0}`nSubject: {1}`nThumbprint: {2}`nExpires: {3}`nHasPrivateKey: {4}`nFriendlyName: {5}" -f `
                    $c.Store,$c.Subject,$c.Thumbprint,$c.NotAfter,$c.HasPrivateKey,$c.FriendlyName
                $info | Out-File -FilePath $pemFile -Encoding UTF8
                Write-Host ("[CERT] Wrote cert info to {0}" -f $pemFile) -ForegroundColor Green
            }
        } catch {
            Write-Warning "Certificate export failed: $($_.Exception.Message)"
        }
    }

    $allResults=@()

    foreach ($c in $ComputerName) {
        $isLocal = ($c -in @('.','localhost',$env:COMPUTERNAME))
        Initialize-Logging -LogPath $LogPath -ComputerName $c
        try {
            Write-Log -Level INFO -Message "Begin assessment" -Section 'Start'
            $result = if ($isLocal) {
                Invoke-AssessmentLocal `
                    -IncludeInstalledUpdates:$IncludeInstalledUpdates `
                    -DeepRoles:$DeepRoles `
                    -ExcludeTaskAuthorLike $ExcludeTaskAuthorLike `
                    -ExcludeTaskNamePrefix $ExcludeTaskNamePrefix `
                    -IncludeTaskNamePrefix $IncludeTaskNamePrefix
            } else {
                Invoke-AssessmentRemote `
                    -ComputerName $c `
                    -Credential $Credential `
                    -IncludeInstalledUpdates:$IncludeInstalledUpdates `
                    -DeepRoles:$DeepRoles `
                    -ExcludeTaskAuthorLike $ExcludeTaskAuthorLike `
                    -ExcludeTaskNamePrefix $ExcludeTaskNamePrefix `
                    -IncludeTaskNamePrefix $IncludeTaskNamePrefix
            }
            Write-Log -Level INFO -Message "Assessment collected" -Section 'Collect'
            $allResults += $result

            if ($Summary) {
                Show-Summary -Data $result -AppsTop $AppsTop -ServicesTop $ServicesTop -TasksTop $TasksTop -SharesTop $SharesTop -CertsTop $CertsTop -InstalledFeaturesTop $InstalledFeaturesTop
                if ($GridApps)     { try { $result.InstalledApps | Out-GridView -Title "$c - Installed Apps" } catch { } }
                if ($GridServices) { try { $result.Services.All | Out-GridView -Title "$c - All Services" } catch { } }
                if ($GridShares)   { try { $result.Shares | Out-GridView -Title "$c - SMB Shares" } catch { } }
            }

            if ($OutputFormat -ne 'None') {
                $outDir = $OutputPath
                if ($ComputerName.Count -gt 1) {
                    $outDir = if ($OutputPath) { Join-Path $OutputPath $c } else { Join-Path $PWD $c }
                }
                Save-Assessment -Data $result -Format $OutputFormat -OutputPath $outDir -ExcelMergeAfterCsv:$ExcelMergeAfterCsv -MergedExcelPath:$MergedExcelPath
                Backup-IISConfigIfRequested -Data $result -OutputPath $outDir -ExportIISConfig:$ExportIISConfig
                Export-CertPemIfRequested -Data $result -OutputPath $outDir -ExportCertificates:$ExportCertificates
                Write-Log -Level INFO -Message "Artifacts saved to $outDir" -Section 'Output'
            }
        } catch {
            Write-Warning "Failed to assess ${c}: $($_.Exception.Message)"
            Write-Log -Level ERROR -Message "Failed assessment: $($_.Exception.Message)" -Section 'Error'
            $allResults += [pscustomobject]@{ ComputerName=$c; Error=$_.Exception.Message }
        }
    }

    if ($allResults.Count -eq 1) { $allResults[0] } else { $allResults }
}

# Optional convenience presets + wrapper -----------------------------------------------------
$SDA_Presets = @{
    LocalHtmlSummary = @{
        Summary = $true
        OutputFormat = 'Html'
    }
    LocalCsvAll = @{
        Summary = $false
        OutputFormat = 'Csv'
        ExportIISConfig = $true
        ExportCertificates = $true
        ExcelMergeAfterCsv = $true
    }
    RemoteHtmlSummary = @{
        Summary = $true
        OutputFormat = 'Html'
    }
}

function SDA {
<#
.SYNOPSIS
Convenience wrapper to run ServerDecomAssessment with preset parameters and overrides.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('LocalHtmlSummary','LocalCsvAll','RemoteHtmlSummary')]
        [string]$Preset,
        [string[]]$ComputerName = @($env:COMPUTERNAME),
        [pscredential]$Credential,
        [ValidateSet('None','Json','Html','Csv')][string]$OutputFormat,
        [string]$OutputPath = 'C:\Temp\SDA_Results',
        [switch]$IncludeInstalledUpdates,
        [switch]$Summary,
        [int]$AppsTop,
        [int]$ServicesTop,
        [int]$TasksTop,
        [int]$SharesTop,
        [int]$CertsTop,
        [int]$InstalledFeaturesTop,
        [switch]$GridApps,
        [switch]$GridServices,
        [switch]$GridShares,
        [switch]$ExportIISConfig,
        [switch]$ExportCertificates,
        [switch]$ExcelMergeAfterCsv,
        [string]$MergedExcelPath,
        [switch]$DeepRoles,

        # Expose the scheduled-task filters in the wrapper as well
        [string[]]$ExcludeTaskAuthorLike = @('Microsoft','Microsoft Corporation'),
        [string[]]$ExcludeTaskNamePrefix = @('Microsoft'),
        [string[]]$IncludeTaskNamePrefix = @('SQL','MSSQL','SQLServer')
    )
    $base = $SDA_Presets[$Preset].Clone()
    if ($PSBoundParameters.ContainsKey('ComputerName')) { $base.ComputerName = $ComputerName }
    if ($PSBoundParameters.ContainsKey('Credential'))   { $base.Credential   = $Credential }
    if ($PSBoundParameters.ContainsKey('OutputFormat')) { $base.OutputFormat = $OutputFormat }
    if ($PSBoundParameters.ContainsKey('OutputPath'))   { $base.OutputPath   = $OutputPath }
    foreach ($k in @(
        'IncludeInstalledUpdates','Summary','AppsTop','ServicesTop','TasksTop','SharesTop','CertsTop','InstalledFeaturesTop',
        'GridApps','GridServices','GridShares','ExportIISConfig','ExportCertificates','ExcelMergeAfterCsv','MergedExcelPath',
        'DeepRoles','ExcludeTaskAuthorLike','ExcludeTaskNamePrefix','IncludeTaskNamePrefix'
    )) {
        if ($PSBoundParameters.ContainsKey($k)) { $base[$k] = $PSBoundParameters[$k] }
    }
    ServerDecomAssessment @base
}

# -------------------------------------------------------------------------------------------
# Examples (reference): cmdlet-style invocations and use cases
# -------------------------------------------------------------------------------------------
# LOCAL RUNS
# ServerDecomAssessment -Summary
# ServerDecomAssessment -Summary -OutputFormat Html -OutputPath "C:\Temp\SDA_Results" -DeepRoles
# ServerDecomAssessment -OutputFormat Json -OutputPath "C:\Temp\SDA_Results"
# ServerDecomAssessment -OutputFormat Csv -OutputPath "C:\Temp\SDA_Results" -ExcelMergeAfterCsv -DeepRoles
# ServerDecomAssessment -Summary -IncludeInstalledUpdates
# ServerDecomAssessment -Summary -AppsTop 100 -ServicesTop 100 -InstalledFeaturesTop 200
# ServerDecomAssessment -Summary -GridApps -GridServices -GridShares
# REMOTE RUNS
# ServerDecomAssessment -ComputerName "srv01" -Credential (Get-Credential) -Summary -OutputFormat Html -OutputPath "C:\Temp\SDA_Results" -DeepRoles
# ServerDecomAssessment -ComputerName "srv01","srv02","srv03" -Credential (Get-Credential) -OutputFormat Csv -OutputPath "C:\Temp\SDA_Results" -ExcelMergeAfterCsv -DeepRoles
# ServerDecomAssessment -ComputerName "srv01" -Credential (Get-Credential) -Summary -ServicesTop 200
# ROLE-AWARE EXTRAS
# ServerDecomAssessment -OutputFormat Html -OutputPath "C:\Temp\SDA_Results" -ExportIISConfig
# ServerDecomAssessment -OutputFormat Csv -OutputPath "C:\Temp\SDA_Results" -ExportCertificates
# TARGETED INVENTORY FOCUSES
# ServerDecomAssessment -IncludeInstalledUpdates -OutputFormat Csv -OutputPath "C:\Temp\SDA_Results"
# ServerDecomAssessment -Summary -SharesTop 100 -ServicesTop 200
# ServerDecomAssessment -Summary -CertsTop 200
# CONVENIENCE WRAPPER (PRESETS)
# SDA LocalHtmlSummary
# SDA LocalCsvAll -OutputPath "C:\Temp\SDA_Results" -DeepRoles
# SDA LocalCsvAll -ComputerName "srv01","srv02" -OutputPath "C:\Temp\SDA_Results" -DeepRoles
# SDA RemoteHtmlSummary -ComputerName "srv01" -Credential (Get-Credential) -OutputPath "C:\Temp\SDA_Results" -DeepRoles
# ON-DEMAND EXCEL MERGE (no reassessment needed)
# Merge-CsvToExcel -CsvFolder "C:\Temp\SDA_Results" -OutXlsx "C:\Temp\SDA_Results\Assessment-All.xlsx"