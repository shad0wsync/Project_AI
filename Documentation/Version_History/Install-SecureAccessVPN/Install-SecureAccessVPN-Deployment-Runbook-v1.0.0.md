---
title: NetMotion SecureAccess VPN Client - Deployment Runbook
version: 1.0.0
last_updated: 2026-05-27
author: Jay Smith
scriptname: Install-SecureAccessVPN.ps1
location: Scripts/Powershell/
language: PowerShell 5.1+
---

# NetMotion SecureAccess VPN Client - Deployment Runbook v1.0.0

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites & Requirements](#prerequisites--requirements)
3. [Pre-Deployment Validation](#pre-deployment-validation)
4. [Quick Start](#quick-start)
5. [Parameters Reference](#parameters-reference)
6. [Installation Phases](#installation-phases)
7. [Post-Install Verification](#post-install-verification)
8. [Registry Configuration Details](#registry-configuration-details)
9. [Common Issues & Troubleshooting](#common-issues--troubleshooting)
10. [Rollback Procedures](#rollback-procedures)
11. [Version History](#version-history)

---

## Overview

The **NetMotion SecureAccess VPN Client Deployment Runbook** provides step-by-step procedures for automated installation and configuration of NetMotion SecureAccess Client v14.10 (x64) with pre-configured VPN gateway settings.

### What This Script Does

✓ Copies MSI installer from shared network location (`\\svr-fs\support\Software\Absolute VPN\Secure Access\Client`)  
✓ Performs silent (unattended) installation with no user interaction  
✓ Automatically configures VPN gateway in system registry:
  - **Gateway Name:** VPN.HPTX.ORG
  - **Primary IP:** 209.116.238.253
  - **Secondary IP:** 97.105.183.196
  - **Port:** 443 (HTTPS)
✓ Starts SecureAccess services post-install  
✓ Validates registry configuration with diagnostic reporting  
✓ Implements automatic rollback if configuration fails  
✓ Cleans up installation file post-deployment  
✓ Provides comprehensive logging for audit and troubleshooting  

### Key Benefits

| Benefit | Impact |
| --- | --- |
| **Fully Automated** | Zero post-install manual configuration required |
| **Self-Healing** | Automatic rollback on configuration failure prevents broken installations |
| **Audit-Ready** | Complete logging with timestamps for compliance and troubleshooting |
| **Enterprise-Grade** | Retry logic, error handling, and service management built-in |
| **Network-Resilient** | Handles transient network failures with exponential backoff |

---

## Prerequisites & Requirements

### System Requirements

| Requirement | Specification |
| --- | --- |
| **Operating System** | Windows Server 2019, 2022, or Windows 10/11 (x64) |
| **PowerShell** | 5.1 or higher (Windows Management Framework) |
| **Administrator Privileges** | Required (script validates and exits if not admin) |
| **Network Access** | Direct access to `\\svr-fs\support\Software\Absolute VPN\Secure Access\Client` share |
| **Internet/VPN** | Connectivity to VPN gateway IPs: 209.116.238.253:443, 97.105.183.196:443 |
| **Disk Space** | Minimum 500 MB free in `C:\temp` and system drive |
| **Execution Policy** | Must allow script execution: `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser` |

### Network Requirements

**Required Network Connectivity:**
- Source PC must reach `\\svr-fs` via SMB/445
- Target PC must reach VPN gateway IPs on port 443 (TCP)
- No proxy authentication required (uses Windows Credentials)

**Network Access Validation:**
```powershell
# Test file share access
Test-Path "\\svr-fs\support\Software\Absolute VPN\Secure Access\Client"

# Test VPN gateway connectivity
Test-NetConnection -ComputerName 209.116.238.253 -Port 443
Test-NetConnection -ComputerName 97.105.183.196 -Port 443
```

### Software Dependencies

| Component | Status | Action |
| --- | --- | --- |
| **.NET Framework 4.x** | Likely required by SecureAccess | Verify pre-install if deployment fails |
| **MSVC Runtime** | Likely required | Usually present on Windows Server |
| **Windows Installer (MSI)** | Built-in | No additional installation needed |

### File Share Access

**Required UNC Path:**
```
\\svr-fs\support\Software\Absolute VPN\Secure Access\Client\SecureAccess_client_14.10_x64_release.msi
```

**Verify Share Accessibility:**
```powershell
# As administrator, test share access
Get-Item -Path "\\svr-fs\support\Software\Absolute VPN\Secure Access\Client"

# If access denied, ensure credentials are cached or add network location:
net use \\svr-fs\support /user:DOMAIN\username password
```

---

## Pre-Deployment Validation

### Phase 1: Environment Assessment (Lab or Pilot)

**CRITICAL:** Before production rollout, validate the script in a controlled lab environment.

#### Step 1: Prepare Test VM
1. Create clean Windows Server 2019/2022 VM or use test workstation
2. Configure with administrative access
3. Ensure network connectivity to:
   - `\\svr-fs` file share (network accessibility)
   - VPN gateway IPs (209.116.238.253 and 97.105.183.196 on port 443)

#### Step 2: Obtain Script and MSI
```powershell
# Copy script to test system
Copy-Item -Path "\\path\to\Install-SecureAccessVPN.ps1" -Destination "C:\Temp\" -Force

# Verify MSI availability
Get-Item "\\svr-fs\support\Software\Absolute VPN\Secure Access\Client\SecureAccess_client_14.10_x64_release.msi"
```

#### Step 3: Run Script with SkipCleanup Flag
```powershell
# Run as administrator
cd C:\Temp
.\Install-SecureAccessVPN.ps1 -SkipCleanup
```

**Expected Outcome:**
- Script completes with exit code 0
- Log file created: `C:\temp\SecureAccessInstall_Logs\SecureAccessInstall_[timestamp].log`
- MSI installed to system (verify: Control Panel → Programs → Programs and Features)
- VPN client service running (verify: Services → NetMotion SecureAccess)

#### Step 4: Verify Registry Configuration
```powershell
# After installation, validate registry structure
$regPath = "HKLM:\SOFTWARE\NetMotion\SecureAccess\Client\Gateways\VPN.HPTX.ORG"
Get-ItemProperty -Path $regPath

# Expected output (sample):
# GatewayName : VPN.HPTX.ORG
# PrimaryAddress : 209.116.238.253
# SecondaryAddress : 97.105.183.196
# Enabled : 1
# Port : 443
```

#### Step 5: Validate Service Startup
```powershell
# Check if SecureAccess service is running
Get-Service -Name "*SecureAccess*" | Select-Object Name, Status, StartType

# Expected output (one of these):
# NetMotion SecureAccess        Running    Automatic
# SecureAccessService           Running    Automatic
```

#### Step 6: Test VPN Gateway Connectivity
```powershell
# After installation, test if VPN client can reach configured gateways
# This may require user authentication in the VPN client UI
# But verify network-level connectivity:

Test-NetConnection -ComputerName 209.116.238.253 -Port 443 -InformationLevel Detailed
Test-NetConnection -ComputerName 97.105.183.196 -Port 443 -InformationLevel Detailed

# Expected: TcpTestSucceeded = True (if gateways are accessible)
```

#### Step 7: Document Findings
Create a lab validation report:
```
Test VM: [OS, IP, hostname]
MSI Installation: [Success/Failed]
Registry Path: [Verified/Failed]
Service Status: [Running/Stopped/Not Found]
Gateway Connectivity: [Reachable/Unreachable]
Issues Found: [List any registry path mismatches, service name differences, etc.]
Recommended Actions: [Adjustments needed before production rollout]
```

---

### Phase 2: Pre-Production Validation (Optional but Recommended)

Before deploying to production systems:

#### 1. Cross-Reference NetMotion Documentation

**Obtain official resources:**
- NetMotion SecureAccess 14.10 System Administrator Guide
- Verify registry path structure matches current script assumptions
- Confirm service names and startup behavior
- Review any deprecated configurations

**Key Questions to Answer:**
- [ ] Are registry paths exactly as expected: `HKLM:\SOFTWARE\NetMotion\SecureAccess\Client\Gateways\{GatewayName}`?
- [ ] Are registry value names correct: `GatewayName`, `PrimaryAddress`, `SecondaryAddress`, `Enabled`, `Port`, `UseCompression`?
- [ ] Does registry-only configuration suffice, or are XML profiles/additional setup needed?
- [ ] Do users need pre-configured credentials or can they authenticate on first use?

#### 2. Validate Network Paths
```powershell
# Confirm file share accessibility from production network
$msiPath = "\\svr-fs\support\Software\Absolute VPN\Secure Access\Client\SecureAccess_client_14.10_x64_release.msi"
Test-Path -Path $msiPath

# Test network connectivity from production segment
$gateways = @("209.116.238.253", "97.105.183.196")
foreach ($gateway in $gateways) {
    Test-NetConnection -ComputerName $gateway -Port 443 -InformationLevel Quiet
}
```

#### 3. Pilot Rollout (5-10 Systems)
- Select 5-10 representative systems (mix of OS versions, network segments)
- Deploy script with `-SkipCleanup` flag to retain logs
- Monitor for 24-48 hours for service stability
- Collect feedback from pilot users on VPN connectivity
- Review logs for any registry or service issues

---

## Quick Start

### Basic Deployment (Default Settings)

```powershell
# Run as administrator
cd C:\temp
.\Install-SecureAccessVPN.ps1
```

**Expected Flow:**
1. Validates admin privileges
2. Checks shared path and MSI availability
3. Copies MSI to `C:\temp`
4. Silently installs SecureAccess Client
5. Configures VPN gateway in registry
6. Starts SecureAccess services
7. Validates registry structure
8. Deletes MSI file
9. Outputs completion summary with log file location

**Success Indicator:**
```
Done. See results at: C:\temp\SecureAccessInstall_Logs\SecureAccessInstall_[timestamp].log
```

### Deployment with Logging Retained (Debugging)

```powershell
# Keep MSI file and logs for troubleshooting
.\Install-SecureAccessVPN.ps1 -SkipCleanup
```

**Result:**
- MSI remains in `C:\temp` (allows manual inspection)
- Log files retained in `C:\temp\SecureAccessInstall_Logs\`
- Useful for troubleshooting failed deployments

### Deployment with Custom MSI Path

```powershell
# Use non-default file share location
.\Install-SecureAccessVPN.ps1 -SharedPath "\\custom-server\share\VPN" -MSIFileName "SecureAccess_custom.msi"
```

---

## Parameters Reference

### Command-Line Parameters

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `-SharedPath` | String | `\\svr-fs\support\Software\Absolute VPN\Secure Access\Client` | UNC path to MSI installer location |
| `-MSIFileName` | String | `SecureAccess_client_14.10_x64_release.msi` | Filename of the MSI installer |
| `-LogPath` | String | `C:\temp\SecureAccessInstall_Logs` | Directory for storing logs |
| `-SkipCleanup` | Switch | `$false` | If set, MSI file is retained in C:\temp after install |

### Configuration Constants (Hard-Coded)

These are set within the script and should only be modified if deployment requirements change:

| Constant | Value | Purpose |
| --- | --- | --- |
| `$VPNGatewayName` | `VPN.HPTX.ORG` | Friendly name for VPN gateway |
| `$PrimaryIP` | `209.116.238.253` | Primary VPN gateway IP address |
| `$SecondaryIP` | `97.105.183.196` | Secondary/failover VPN gateway IP |
| `$RegistryPath` | `HKLM:\SOFTWARE\NetMotion\SecureAccess\Client` | Base registry location for client config |
| `$GatewayRegistryPath` | (derived) | Gateway-specific registry subkey |

---

## Installation Phases

### Phase 1: Initialization & Logging
- Creates log directory if missing: `C:\temp\SecureAccessInstall_Logs\`
- Generates timestamped log file: `SecureAccessInstall_[yyyyMMdd_HHmmss].log`
- Logs system information: OS, PowerShell version, username, hostname

### Phase 2: Administrator Privilege Verification
- Checks if script is running with admin rights
- **Exits if not admin** — Required for registry writes and MSI installation
- Logs: `Administrator privileges verified.`

### Phase 3: Prerequisites Check
- Verifies .NET Framework 4.x (logs warning if missing, but continues)
- Tests `\\svr-fs` share accessibility
- Confirms MSI file exists at: `\\svr-fs\support\...\SecureAccess_client_14.10_x64_release.msi`
- **Exits if any check fails**

### Phase 4: Copy Installation File
- Creates `C:\temp` directory if missing
- Copies MSI from network share to local `C:\temp`
- **Implements 3-retry logic with 5-second backoff** on transient failures
- Verifies file size post-copy
- Logs: `MSI successfully copied to C:\temp\... (Size: XX.XX MB)`

### Phase 5: Silent Installation
- Executes: `msiexec.exe /i "C:\temp\SecureAccess_client_14.10_x64_release.msi" /quiet /norestart`
- Monitors exit code:
  - `0` = Success
  - `3010` = Success (system restart required)
  - Other = Failure (logs error details)
- Generates MSI installation log: `*_msi_install.log`

### Phase 6: VPN Gateway Configuration
- Creates registry paths if missing:
  - `HKLM:\SOFTWARE\NetMotion\SecureAccess\Client\`
  - `HKLM:\SOFTWARE\NetMotion\SecureAccess\Client\Gateways\VPN.HPTX.ORG\`
- Sets registry values:
  - `GatewayName` (String) = `VPN.HPTX.ORG`
  - `PrimaryAddress` (String) = `209.116.238.253`
  - `SecondaryAddress` (String) = `97.105.183.196`
  - `Enabled` (DWORD) = `1`
  - `Port` (DWORD) = `443`
  - `UseCompression` (DWORD) = `0`
  - `DefaultGateway` (String) = `VPN.HPTX.ORG` (at Client root)

### Phase 7: Service Startup
- Searches for services matching: `NetMotion SecureAccess`, `SecureAccessService`, `SAService`
- For each found service:
  - If stopped → Starts the service
  - If already running → Logs "already running" status
- **Non-fatal if services not found** (may be started on-demand)

### Phase 8: Registry Structure Validation
- Checks if registry paths exist post-install
- Verifies required values are present: `GatewayName`, `PrimaryAddress`, `SecondaryAddress`, `Enabled`
- Flags any missing values as warnings (non-blocking)
- Logs diagnostic summary

### Phase 9: Installation Verification
- Checks if SecureAccess processes are running
- Validates registry configuration entries
- Logs: `Gateway configuration verified in registry`

### Phase 10: Cleanup
- **Unless `-SkipCleanup` flag is set:**
  - Deletes MSI file from `C:\temp`
  - Verifies deletion successful
  - Logs: `Installation file removed: C:\temp\SecureAccess_client_14.10_x64_release.msi`

---

## Post-Install Verification

### Immediate Verification (5 minutes after installation)

```powershell
# 1. Check installation was recorded
$installed = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" | 
    Where-Object { $_.DisplayName -match "SecureAccess" }
if ($installed) {
    Write-Host "✓ SecureAccess client installed: $($installed.DisplayName)"
} else {
    Write-Host "✗ SecureAccess not found in Add/Remove Programs"
}

# 2. Verify registry gateway configuration
$regPath = "HKLM:\SOFTWARE\NetMotion\SecureAccess\Client\Gateways\VPN.HPTX.ORG"
$regConfig = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
if ($regConfig) {
    Write-Host "✓ Registry configuration found"
    Write-Host "  Gateway: $($regConfig.GatewayName)"
    Write-Host "  Primary IP: $($regConfig.PrimaryAddress)"
    Write-Host "  Secondary IP: $($regConfig.SecondaryAddress)"
} else {
    Write-Host "✗ Registry configuration not found at: $regPath"
}

# 3. Check service status
$services = Get-Service -Name "*SecureAccess*" -ErrorAction SilentlyContinue
if ($services) {
    Write-Host "✓ Services found:"
    $services | ForEach-Object { Write-Host "  $($_.Name): $($_.Status)" }
} else {
    Write-Host "⚠ No SecureAccess services found (may start on-demand)"
}

# 4. Check logs for errors
$logFile = Get-ChildItem -Path "C:\temp\SecureAccessInstall_Logs\" -Filter "*.log" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($logFile) {
    Write-Host "✓ Installation log: $($logFile.FullName)"
    $errors = Select-String -Path $logFile.FullName -Pattern "ERROR|FAILED" -ErrorAction SilentlyContinue
    if ($errors) {
        Write-Host "⚠ Errors detected in log:"
        $errors | ForEach-Object { Write-Host "  $_" }
    } else {
        Write-Host "✓ No errors in installation log"
    }
}
```

### 24-Hour Monitoring

**Service Stability:**
```powershell
# Monitor service for 24 hours
$service = Get-Service -Name "NetMotion SecureAccess" -ErrorAction SilentlyContinue
if ($service) {
    $startTime = Get-Date
    $statusHistory = @()
    
    while ((Get-Date) -lt $startTime.AddHours(24)) {
        $status = (Get-Service -Name "NetMotion SecureAccess").Status
        $statusHistory += @{ Time = Get-Date; Status = $status }
        Start-Sleep -Seconds 3600  # Check every hour
    }
    
    # Report any restarts or status changes
    $statusHistory | Group-Object -Property Status | ForEach-Object {
        Write-Host "Status $($_.Name): $($_.Count) hours"
    }
}
```

**Event Log Review:**
```powershell
# Check Windows Event Log for installation events
Get-EventLog -LogName System -Source "MsiInstaller" -Newest 5 | 
    Select-Object TimeGenerated, EventID, Message
```

---

## Registry Configuration Details

### Registry Structure Overview

```
HKEY_LOCAL_MACHINE
  └─ SOFTWARE
      └─ NetMotion
          └─ SecureAccess
              └─ Client
                  ├─ DefaultGateway = "VPN.HPTX.ORG" (String)
                  └─ Gateways
                      └─ VPN.HPTX.ORG
                          ├─ GatewayName = "VPN.HPTX.ORG" (String)
                          ├─ Address = "209.116.238.253" (String - legacy)
                          ├─ PrimaryAddress = "209.116.238.253" (String)
                          ├─ SecondaryAddress = "97.105.183.196" (String)
                          ├─ Enabled = 1 (DWORD)
                          ├─ Port = 443 (DWORD)
                          └─ UseCompression = 0 (DWORD)
```

### Registry Value Descriptions

| Value | Type | Value | Purpose |
| --- | --- | --- | --- |
| **GatewayName** | REG_SZ | VPN.HPTX.ORG | Friendly name for VPN gateway (displayed in VPN client UI) |
| **Address** | REG_SZ | 209.116.238.253 | Legacy primary IP field (may be deprecated in newer versions) |
| **PrimaryAddress** | REG_SZ | 209.116.238.253 | Primary gateway IP address (main connection target) |
| **SecondaryAddress** | REG_SZ | 97.105.183.196 | Secondary IP for failover if primary unreachable |
| **Enabled** | REG_DWORD | 1 | Gateway enabled (1 = enabled, 0 = disabled) |
| **Port** | REG_DWORD | 443 | TCP port for VPN connections (443 = HTTPS/SSL) |
| **UseCompression** | REG_DWORD | 0 | Enable/disable data compression (0 = disabled, 1 = enabled) |
| **DefaultGateway** | REG_SZ | VPN.HPTX.ORG | Sets which gateway is default when client starts |

### Viewing Registry Configuration

```powershell
# View entire gateway configuration
$regPath = "HKLM:\SOFTWARE\NetMotion\SecureAccess\Client\Gateways\VPN.HPTX.ORG"
Get-ItemProperty -Path $regPath | Format-List

# Export to file for backup
Get-ItemProperty -Path $regPath | Export-Clixml -Path "C:\temp\VPN_Gateway_Config.xml"

# Compare with expected values
$expected = @{
    GatewayName = "VPN.HPTX.ORG"
    PrimaryAddress = "209.116.238.253"
    SecondaryAddress = "97.105.183.196"
    Enabled = 1
    Port = 443
    UseCompression = 0
}

$actual = Get-ItemProperty -Path $regPath
$expected.GetEnumerator() | ForEach-Object {
    $match = $actual.$($_.Key) -eq $_.Value
    $status = if ($match) { "✓" } else { "✗" }
    Write-Host "$status $($_.Key): Expected=$($_.Value), Actual=$($actual.$($_.Key))"
}
```

### Modifying Registry Configuration

**To change gateway IPs after deployment:**
```powershell
$regPath = "HKLM:\SOFTWARE\NetMotion\SecureAccess\Client\Gateways\VPN.HPTX.ORG"

# Update primary IP
Set-ItemProperty -Path $regPath -Name "PrimaryAddress" -Value "NEW.IP.ADDRESS"

# Update secondary IP
Set-ItemProperty -Path $regPath -Name "SecondaryAddress" -Value "NEW.IP.ADDRESS"

# Restart service to apply changes
Restart-Service -Name "NetMotion SecureAccess" -Force
```

---

## Common Issues & Troubleshooting

### Issue 1: "Administrator privileges not found"

**Error Message:**
```
[ERROR] This script requires administrator privileges. Please run as Administrator.
```

**Cause:** Script was executed without admin rights.

**Resolution:**
1. Right-click PowerShell window → Select "Run as Administrator"
2. Re-run the script:
   ```powershell
   .\Install-SecureAccessVPN.ps1
   ```

---

### Issue 2: "Shared path not accessible"

**Error Message:**
```
[ERROR] Shared path not accessible: \\svr-fs\support\Software\Absolute VPN\Secure Access\Client
```

**Cause:** 
- Network share is unreachable
- Credentials not cached or expired
- Network connectivity issue
- Share permissions denied

**Resolution:**
1. **Verify network connectivity:**
   ```powershell
   Test-NetConnection -ComputerName svr-fs -Port 445
   ```

2. **Cache credentials (if needed):**
   ```powershell
   net use \\svr-fs\support /user:DOMAIN\username password
   ```

3. **Verify share access:**
   ```powershell
   Get-ChildItem -Path "\\svr-fs\support\Software\Absolute VPN\Secure Access\Client"
   ```

4. **Check firewall rules:**
   - Ensure SMB (port 445) is allowed
   - Test from another workstation to isolate issue

---

### Issue 3: "MSI file not found"

**Error Message:**
```
[ERROR] MSI file not found: \\svr-fs\support\...\SecureAccess_client_14.10_x64_release.msi
```

**Cause:**
- Incorrect path or filename
- MSI file moved or deleted
- Custom path provided with typo

**Resolution:**
1. **Verify MSI location:**
   ```powershell
   Get-ChildItem -Path "\\svr-fs\support\Software\Absolute VPN\Secure Access\Client" -Filter "*.msi"
   ```

2. **If file is in different location, specify custom path:**
   ```powershell
   .\Install-SecureAccessVPN.ps1 -SharedPath "\\svr-fs\custom\path" -MSIFileName "SecureAccess_v14.10.msi"
   ```

3. **Request correct MSI location from IT/vendor**

---

### Issue 4: "Installation failed with exit code"

**Error Message:**
```
[ERROR] Installation failed with exit code: 1603
```

**Common MSI Exit Codes:**

| Code | Meaning | Action |
| --- | --- | --- |
| `1603` | Fatal error during installation | Check MSI integrity; try redownloading |
| `1605` | Product not currently installed | Ignore (first installation) |
| `1616` | No source found for product | Verify MSI path is correct |
| `1618` | Another MSI already in progress | Wait a few minutes and retry |
| `1619` | Could not open package | MSI file corrupted; redownload |

**Resolution:**
1. **Check MSI integrity:**
   ```powershell
   $msiPath = "\\svr-fs\support\Software\Absolute VPN\Secure Access\Client\SecureAccess_client_14.10_x64_release.msi"
   (Get-FileHash -Path $msiPath -Algorithm SHA256).Hash
   # Compare against known good hash if available
   ```

2. **Review detailed MSI log:**
   ```powershell
   $logFile = Get-ChildItem -Path "C:\temp\SecureAccessInstall_Logs\" -Filter "*_msi_install.log" | 
       Sort-Object LastWriteTime -Descending | Select-Object -First 1
   Get-Content $logFile.FullName | Select-String "error|fail" -Context 3
   ```

3. **Manual MSI installation for testing:**
   ```powershell
   msiexec.exe /i "C:\temp\SecureAccess_client_14.10_x64_release.msi" /quiet /norestart /log "C:\temp\manual_install.log"
   ```

4. **Redownload MSI and retry**

---

### Issue 5: "Registry configuration not found"

**Warning Message:**
```
[WARNING] Gateway registry path not found: HKLM:\SOFTWARE\NetMotion\SecureAccess\Client\Gateways\VPN.HPTX.ORG
```

**Cause:**
- MSI installed but didn't create expected registry structure
- Registry path structure differs from script expectations (version-specific)
- NetMotion 14.10 uses different registry location

**Resolution:**
1. **Inspect actual registry created by MSI:**
   ```powershell
   Get-ChildItem -Path "HKLM:\SOFTWARE\NetMotion" -Recurse | Format-List
   ```

2. **If registry structure differs, document actual path:**
   ```powershell
   # Search for SecureAccess references
   Get-ChildItem -Path "HKLM:\SOFTWARE" -Recurse | Where-Object { $_.Name -match "SecureAccess" }
   ```

3. **Create registry path manually if needed:**
   ```powershell
   $regPath = "HKLM:\SOFTWARE\NetMotion\SecureAccess\Client\Gateways\VPN.HPTX.ORG"
   New-Item -Path $regPath -Force | Out-Null
   Set-ItemProperty -Path $regPath -Name "GatewayName" -Value "VPN.HPTX.ORG" -Type String
   # ... repeat for other values
   ```

4. **Update script with correct registry paths if needed**

---

### Issue 6: "Service not found or failed to start"

**Warning Message:**
```
[WARNING] No SecureAccess services found (may start on-demand)
```

**Cause:**
- Service name differs from expected pattern
- Service not installed or disabled
- Service failed to start due to dependency or permission issue

**Resolution:**
1. **Find actual service name:**
   ```powershell
   Get-Service | Where-Object { $_.Name -match "Secure|NetMotion" }
   ```

2. **Manually start the service:**
   ```powershell
   $service = Get-Service -Name "NetMotion SecureAccess" -ErrorAction SilentlyContinue
   if ($service) {
       Start-Service -Name $service.Name
       Get-Service -Name $service.Name  # Verify status
   }
   ```

3. **Check service dependencies:**
   ```powershell
   Get-Service "NetMotion SecureAccess" | Select-Object -ExpandProperty ServicesDependedOn
   ```

4. **Review Windows Event Log for startup errors:**
   ```powershell
   Get-EventLog -LogName System -Source "Service Control Manager" -Newest 10
   ```

---

### Issue 7: "VPN Gateway IP not reachable"

**When testing connectivity:**
```
Test-NetConnection -ComputerName 209.116.238.253 -Port 443
TcpTestSucceeded : False
```

**Cause:**
- Gateway IP is incorrect or misconfigured
- Firewall blocking port 443
- Gateway is offline/unavailable
- Network routing issue

**Resolution:**
1. **Verify gateway IPs are correct:**
   ```powershell
   $regPath = "HKLM:\SOFTWARE\NetMotion\SecureAccess\Client\Gateways\VPN.HPTX.ORG"
   Get-ItemProperty -Path $regPath | Select-Object PrimaryAddress, SecondaryAddress
   # Compare with known correct IPs
   ```

2. **Test each IP individually:**
   ```powershell
   Test-NetConnection -ComputerName 209.116.238.253 -Port 443 -InformationLevel Detailed
   Test-NetConnection -ComputerName 97.105.183.196 -Port 443 -InformationLevel Detailed
   ```

3. **Check firewall rules:**
   ```powershell
   Get-NetFirewallRule -DisplayName "*VPN*" -Direction Outbound
   netsh advfirewall firewall show rule name="all" dir=out action=block | findstr 443
   ```

4. **Verify network routing:**
   ```powershell
   route print
   # Look for default gateway and primary/secondary gateway routes
   ```

5. **Escalate to network team if gateway IPs are confirmed unreachable**

---

## Rollback Procedures

### Automatic Rollback (During Installation)

If VPN gateway configuration fails during installation, the script automatically:
1. Logs the failure: `[ERROR] VPN gateway configuration failed. Initiating rollback...`
2. Triggers uninstall: `msiexec.exe /x "C:\temp\SecureAccess_client_14.10_x64_release.msi"`
3. Removes SecureAccess completely
4. Generates uninstall log: `*_msi_uninstall.log`

**Review automatic rollback:**
```powershell
# Check if uninstall log was generated
Get-ChildItem -Path "C:\temp\SecureAccessInstall_Logs\" -Filter "*_msi_uninstall.log"

# Verify SecureAccess is not installed
Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" | 
    Where-Object { $_.DisplayName -match "SecureAccess" }
    # Should return nothing
```

---

### Manual Rollback (If Needed Post-Deployment)

**To uninstall SecureAccess after deployment:**

```powershell
# Method 1: Using Control Panel
# Settings → Apps → Programs and Features → Search "SecureAccess" → Uninstall

# Method 2: Using PowerShell (as Administrator)
$msi = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" | 
    Where-Object { $_.DisplayName -match "SecureAccess" }

if ($msi) {
    $productCode = $msi.PSChildName
    msiexec.exe /x "$productCode" /quiet /norestart
    Write-Host "Uninstall initiated for: $($msi.DisplayName)"
} else {
    Write-Host "SecureAccess not found in registry."
}

# Method 3: Direct MSI uninstall (if MSI file available)
msiexec.exe /x "C:\temp\SecureAccess_client_14.10_x64_release.msi" /quiet /norestart
```

**Verify complete removal:**
```powershell
# Check if client is fully removed
Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" | 
    Where-Object { $_.DisplayName -match "SecureAccess" }

# Check if registry configuration is removed
Test-Path "HKLM:\SOFTWARE\NetMotion\SecureAccess\Client"

# Check if services are removed
Get-Service -Name "*SecureAccess*" -ErrorAction SilentlyContinue

# All should return "nothing" or "False"
```

---

### Rollback Verification Checklist

After rollback (automatic or manual), verify:

- [ ] VPN client is not in Programs and Features
- [ ] Registry path `HKLM:\SOFTWARE\NetMotion` has no SecureAccess keys
- [ ] SecureAccess services no longer appear in Services
- [ ] Installation logs show success or rollback completion
- [ ] No SecureAccess processes running (`Get-Process -Name "*SecureAccess*"` returns nothing)

---

## Version History

| Version | Date | Changes |
| --- | --- | --- |
| **1.0.0** | 2026-05-27 | Initial deployment runbook. Includes lab validation procedures, registry structure documentation, troubleshooting guide, and rollback procedures. Documented registry assumptions and pre-deployment validation requirements. |

---

## Appendix: Quick Reference Commands

### Installation
```powershell
# Basic deployment
.\Install-SecureAccessVPN.ps1

# Keep MSI for debugging
.\Install-SecureAccessVPN.ps1 -SkipCleanup
```

### Verification
```powershell
# Check installation
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" | 
    Where-Object { $_.DisplayName -match "SecureAccess" }

# Check registry config
Get-ItemProperty "HKLM:\SOFTWARE\NetMotion\SecureAccess\Client\Gateways\VPN.HPTX.ORG"

# Check service status
Get-Service -Name "*SecureAccess*"
```

### Troubleshooting
```powershell
# View latest log
Get-ChildItem "C:\temp\SecureAccessInstall_Logs\" -Filter "*.log" | 
    Sort-Object LastWriteTime -Descending | 
    Select-Object -First 1 | 
    ForEach-Object { Get-Content $_.FullName }

# Test gateway connectivity
Test-NetConnection -ComputerName 209.116.238.253 -Port 443
```

### Rollback
```powershell
# Uninstall
msiexec.exe /x "SecureAccess_client_14.10_x64_release.msi" /quiet /norestart

# Verify removal
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" | 
    Where-Object { $_.DisplayName -match "SecureAccess" }
```

---

**Deployment Runbook Author:** Jay Smith  
**Script Version:** 1.1.0  
**Last Updated:** 2026-05-27  
**Status:** Production-Ready (with pre-deployment lab validation required)
