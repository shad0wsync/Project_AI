---
title: NetMotion Absolute Secure Access VPN Client - Installation & Configuration Runbook
version: 1.0.0
last_updated: 2026-05-27
author: Jay Smith
scriptname: Install-SecureAccessVPN.ps1
location: Scripts/Powershell/
language: PowerShell 5.1+
change_type: feature/deployment
---

# NetMotion Absolute Secure Access VPN Client - Installation & Configuration Runbook v1.0.0

## Table of Contents

1. [Overview](#overview)
2. [Quick Start](#quick-start)
3. [Prerequisites](#prerequisites)
4. [Parameters Reference](#parameters-reference)
5. [Installation Flow](#installation-flow)
6. [Registry Configuration Details](#registry-configuration-details)
7. [Post-Install Verification](#post-install-verification)
8. [Common Issues & Troubleshooting](#common-issues--troubleshooting)
9. [Rollback & Recovery](#rollback--recovery)
10. [Deployment Examples](#deployment-examples)
11. [Version History](#version-history)

---

## Overview

The **NetMotion Absolute Secure Access VPN Client Installation Script** provides a streamlined, single-phase deployment of NetMotion SecureAccess Client v14.10 (x64) with **automatic registry configuration and forced system reboot upon success**.

### What This Script Does

✓ **Copies** MSI installer from shared network location  
✓ **Silently installs** SecureAccess Client with no user interaction  
✓ **Automatically configures** VPN gateway in registry:
  - Server FQDN: `vpn.hptx.org`
  - Registry path: `HKLM:\SYSTEM\CurrentControlSet\Services\NMDRV\Params\Mobility Client`
  - Suppresses all UI warnings automatically  
✓ **Optionally applies** INF configuration profile (disabled by default; use `-AlsoApplyInf` to enable)  
✓ **Cleans up** temporary files (MSI, INF) post-deployment  
✓ **Forces system reboot** upon successful installation (exit code 0 or 3010)  

### Key Design Philosophy

- **Zero-Touch Deployment:** No post-install manual configuration required
- **Opinionated Defaults:** INF profile disabled by default (avoids modal popups on first launch)
- **Automatic Reboot:** Forces immediate reboot to finalize setup without user intervention
- **Aggressive Cleanup:** Removes all temporary files to prevent re-execution
- **Fail-Fast:** Throws exceptions on any errors (no soft-error logging)
- **Service Agnostic:** Does NOT restart services (reboot handles service initialization)

---

## Quick Start

### Basic Deployment (Recommended)

```powershell
# Run as administrator (required)
.\Install-SecureAccessVPN.ps1
```

**Behavior:**
1. Copies MSI from shared location to C:\Temp
2. Silently installs SecureAccess Client
3. Automatically configures VPN server registry settings
4. **Initiates forced system reboot**
5. System reboots → SecureAccess services start automatically
6. Users are ready to connect to VPN.HPTX.ORG immediately

**Expected Output:**
```
msiexec exit code: 0
Installation succeeded (code 0). Rebooting to finalize setup...
```

### Advanced Deployment (With INF Profile)

```powershell
# Apply INF configuration profile (optional; may show vendor UI)
.\Install-SecureAccessVPN.ps1 -AlsoApplyInf
```

**When to use:**
- INF file contains additional customizations (certificates, proxy settings, etc.)
- You need profile-level configurations beyond basic server setup
- You accept potential modal dialogs from vendor setup

---

## Prerequisites

### System Requirements

| Requirement | Specification | Validation |
| --- | --- | --- |
| **OS** | Windows Server 2019, 2022 or Windows 10/11 (x64) | Verified automatically at runtime |
| **PowerShell** | 5.1 or higher | Inherent in Windows Server 2019+ |
| **Admin Rights** | Required (script enforces) | Exits if not admin |
| **Network Access** | SMB/445 to `\\svr-fs\support\...` | Fails with clear error if inaccessible |
| **Execution Policy** | Must allow external scripts | `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned` |

### Network Prerequisites

**Required File Share Access:**
```
\\svr-fs\support\Software\Absolute VPN\Secure Access\Client\SecureAccess_client_14.10_x64_release.msi
```

**Optional INF Profile:**
```
\\svr-fs\support\Software\Absolute VPN\Secure Access\Client\vpn_HPTX_ClientConfig.inf
```

**Test Network Connectivity:**
```powershell
# Verify file share access
Test-Path "\\svr-fs\support\Software\Absolute VPN\Secure Access\Client"

# Result should be True; False indicates network/permission issue
```

### Pre-Deployment Checklist

Before running script on production systems:

- [ ] File share `\\svr-fs` is accessible from target network segment
- [ ] MSI file exists at expected location (script will verify)
- [ ] Target system has admin credentials available
- [ ] Users have been notified: **system will reboot automatically post-install**
- [ ] System is in maintenance window or after-hours
- [ ] Network connectivity to VPN gateway will be available post-reboot
- [ ] No other MSI installations in progress (script exits on failure)

---

## Parameters Reference

### Command-Line Parameters

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `-AlsoApplyInf` | Switch | `$false` | If specified, applies INF configuration profile via setupapi. By default omitted to avoid modal dialogs. |

### Configuration Constants (Hard-Coded)

These values are embedded in the script. **Do not modify unless requirements change:**

| Constant | Value | Purpose |
| --- | --- | --- |
| `$ShareMsi` | `\\svr-fs\support\Software\Absolute VPN\Secure Access\Client\SecureAccess_client_14.10_x64_release.msi` | Network path to MSI installer |
| `$ShareInf` | `\\svr-fs\support\Software\Absolute VPN\Secure Access\Client\vpn_HPTX_ClientConfig.inf` | Network path to INF profile |
| `$TempDir` | `C:\Temp` | Local staging directory |
| `$ServerFqdn` | `vpn.hptx.org` | VPN server FQDN (written to registry) |

### Registry Paths Modified

| Registry Path | Values Set | Purpose |
| --- | --- | --- |
| `HKLM:\SYSTEM\CurrentControlSet\Services\NMDRV\Params\Mobility Client` | `MmsAddress`, `FailoverQuell`, `ConnectDiagnosticQuell`, `FatalQuell`, `ShowWarningMessages` | NetMotion Mobility Client settings |
| `HKLM:\SYSTEM\CurrentControlSet\Services\NMDRV\Params\Mobility Client State` | `CurrentSubkey` | Current MMS server state |

---

## Installation Flow

### Phase 1: Initialization
```
✓ Validate admin privileges (exits if not admin)
✓ Create C:\Temp directory (if missing)
✓ Check file share accessibility
✓ Verify MSI exists at network path
✓ Log: "Preparing for installation..."
```

**Duration:** < 2 seconds

### Phase 2: Copy Payloads
```
✓ Copy MSI from \\svr-fs → C:\Temp\SecureAccess_client_14.10_x64_release.msi
✓ Copy INF from \\svr-fs → C:\Temp\vpn_HPTX_ClientConfig.inf (if exists)
✓ Verify file existence post-copy
✓ Log: "Payloads staged in C:\Temp"
```

**Duration:** 5-15 seconds (depends on network speed and MSI size ~50-100 MB)

**Network Resilience:** No built-in retry logic; transient network failures will cause immediate exit.

### Phase 3: Silent MSI Installation
```
✓ Execute: msiexec.exe /i "C:\Temp\SecureAccess_client_14.10_x64_release.msi" /qn /norestart
✓ Monitor exit code (expect 0 or 3010)
  - 0     = Success
  - 3010  = Success (reboot required) ← This is normal
  - Other = Fatal error (exits script)
✓ Log: MSI installation log to C:\Temp\SecureAccess_install.log
```

**Duration:** 30-60 seconds (typical MSI install time)

**Exit Code Handling:**
- Exit codes 0 and 3010 are treated as success and proceed to registry config
- Any other exit code throws an exception with message: `"MSI install failed with exit code [X]. See C:\Temp\SecureAccess_install.log"`

### Phase 4: Registry Configuration
```
✓ Create registry key: HKLM:\SYSTEM\CurrentControlSet\Services\NMDRV\Params\Mobility Client
✓ Create registry key: HKLM:\SYSTEM\CurrentControlSet\Services\NMDRV\Params\Mobility Client State
✓ Set registry values:
  - MmsAddress = "vpn.hptx.org" (String)
  - FailoverQuell = 1 (DWORD) [suppress failover dialogs]
  - ConnectDiagnosticQuell = 1 (DWORD) [suppress diagnostic dialogs]
  - FatalQuell = 1 (DWORD) [suppress fatal error dialogs]
  - ShowWarningMessages = 0 (DWORD) [suppress all warning UI]
  - CurrentSubkey = "MMS vpn.hptx.org" (String)
✓ Log: "Registry configuration complete"
```

**Duration:** < 1 second

**Purpose:** Replaces manual UI configuration by directly setting all required registry values. Users will NOT see setup dialogs on first launch.

### Phase 5: Optional INF Application (If `-AlsoApplyInf` Specified)
```
✓ If INF exists at \\svr-fs...\vpn_HPTX_ClientConfig.inf:
✓ Execute: rundll32.exe setupapi.dll,InstallHinfSection DefaultInstall 132 "C:\Temp\vpn_HPTX_ClientConfig.inf"
✓ Wait for completion (hidden window)
✓ Log: "INF profile applied" or "INF application skipped"
```

**Duration:** 5-30 seconds (depends on INF complexity)

**Warning:** INF application may show vendor UI dialogs despite "quiet" flag (132). This is why INF is disabled by default.

### Phase 6: Cleanup
```
✓ Delete C:\Temp\SecureAccess_client_14.10_x64_release.msi
✓ Delete C:\Temp\vpn_HPTX_ClientConfig.inf (if copied)
✓ Log: "Temporary files cleaned up"
```

**Duration:** < 1 second

**Note:** MSI deletion prevents accidental re-execution or reuse. INF is cleaned if it was copied.

### Phase 7: Forced System Reboot
```
✓ If MSI exit code is 0 or 3010:
✓ Log: "Installation succeeded (code [X]). Rebooting to finalize setup..."
✓ Execute: shutdown.exe /r /t 0 /c "Rebooting to complete Secure Access install"
✓ **System initiates reboot in 0 seconds (no user intervention)**
```

**User Impact:** 
- Users connected via RDP: Connection will drop during reboot
- Local console users: System will reboot
- Scheduled deployments: Plan for 5-10 minute maintenance window

---

## Registry Configuration Details

### Registry Structure

```
HKEY_LOCAL_MACHINE
  └─ SYSTEM
      └─ CurrentControlSet
          └─ Services
              └─ NMDRV
                  └─ Params
                      └─ Mobility Client
                          ├─ MmsAddress = "vpn.hptx.org" (REG_SZ)
                          ├─ FailoverQuell = 1 (REG_DWORD)
                          ├─ ConnectDiagnosticQuell = 1 (REG_DWORD)
                          ├─ FatalQuell = 1 (REG_DWORD)
                          ├─ ShowWarningMessages = 0 (REG_DWORD)
                          └─ (parent: Params)
                              └─ Mobility Client State
                                  └─ CurrentSubkey = "MMS vpn.hptx.org" (REG_SZ)
```

### Registry Value Descriptions

| Value | Type | Meaning | Purpose |
| --- | --- | --- | --- |
| **MmsAddress** | String | `vpn.hptx.org` | Primary VPN server FQDN (mobility management service address) |
| **FailoverQuell** | DWORD | `1` | Suppress failover warning dialogs (1=suppress, 0=show) |
| **ConnectDiagnosticQuell** | DWORD | `1` | Suppress connection diagnostic dialogs |
| **FatalQuell** | DWORD | `1` | Suppress fatal error dialogs |
| **ShowWarningMessages** | DWORD | `0` | Hide all warning messages in UI (0=hide, 1=show) |
| **CurrentSubkey** | String | `MMS vpn.hptx.org` | Current active MMS server (used by client for state tracking) |

### Viewing Current Configuration

```powershell
# View all Mobility Client settings
Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\NMDRV\Params\Mobility Client"

# View specific value
Get-ItemPropertyValue -Path "HKLM:\SYSTEM\CurrentControlSet\Services\NMDRV\Params\Mobility Client" -Name "MmsAddress"
# Expected output: vpn.hptx.org

# Export all settings to file
reg export "HKLM\SYSTEM\CurrentControlSet\Services\NMDRV\Params" "C:\Temp\NMDRV_export.reg"
```

### Modifying Registry Post-Deployment

**To change VPN server address after installation:**

```powershell
$regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\NMDRV\Params\Mobility Client"

# Update server address
Set-ItemProperty -Path $regPath -Name "MmsAddress" -Value "new-vpn-server.hptx.org" -Type String

# Update state tracking
$statePath = "HKLM:\SYSTEM\CurrentControlSet\Services\NMDRV\Params\Mobility Client State"
Set-ItemProperty -Path $statePath -Name "CurrentSubkey" -Value "MMS new-vpn-server.hptx.org" -Type String

# Restart service to apply changes
# Note: Script does NOT restart services; you must do this manually or reboot
Restart-Service -Name "NetMotion Mobility Client" -Force -ErrorAction SilentlyContinue
```

---

## Post-Install Verification

### Immediate Post-Reboot (First 5 Minutes)

**Check installation success:**
```powershell
# 1. Verify SecureAccess client is installed
Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" | 
    Where-Object { $_.DisplayName -match "SecureAccess" -or $_.DisplayName -match "Absolute" }

# Expected output: SecureAccess_client_14.10_x64_release or similar

# 2. Verify registry configuration
$mcPath = "HKLM:\SYSTEM\CurrentControlSet\Services\NMDRV\Params\Mobility Client"
Get-ItemProperty -Path $mcPath

# Expected output: MmsAddress = vpn.hptx.org, ShowWarningMessages = 0, etc.

# 3. Check installation log
Get-Content "C:\Temp\SecureAccess_install.log" -Tail 20
# Should show success, not errors

# 4. Verify temporary files deleted
Get-ChildItem -Path "C:\Temp" -Filter "SecureAccess*"
# Should return nothing or only SecureAccess_install.log (which is informational)
```

### 24-Hour Post-Deployment Monitoring

**Monitor service health:**
```powershell
# Check if NetMotion services are running
Get-Service -Name "*NetMotion*" -ErrorAction SilentlyContinue | 
    Select-Object Name, Status, StartType

# Expected: Status = Running, StartType = Automatic (or Manual)

# Check system event log for installation events
Get-EventLog -LogName System -Source "MsiInstaller" -Newest 10 |
    Select-Object TimeGenerated, EventID, Message

# Expected: Event ID 1033 (MSI installation completed)
```

### User Testing

**Have users verify VPN connectivity:**
```
1. Open Start Menu → Type "VPN"
2. Look for "NetMotion SecureAccess" or "Absolute Secure Access"
3. Launch the VPN client
4. Confirm server is pre-populated with: vpn.hptx.org
5. Authenticate with domain credentials
6. Monitor connection status
7. Report any dialogs (should be none if script succeeded)
```

---

## Common Issues & Troubleshooting

### Issue 1: "Access Denied: Cannot run as Administrator"

**Error Message:**
```
Script cannot be run because it is not signed. Not running via elevation check failed.
```

**Cause:** Script was executed without admin privileges.

**Resolution:**
1. Right-click PowerShell → Select "Run as Administrator"
2. Navigate to script directory:
   ```powershell
   cd C:\path\to\scripts
   ```
3. Re-run:
   ```powershell
   .\Install-SecureAccessVPN.ps1
   ```

---

### Issue 2: "MSI not found at \\svr-fs\..."

**Error Message:**
```
MSI not found at \\svr-fs\support\Software\Absolute VPN\Secure Access\Client\SecureAccess_client_14.10_x64_release.msi
```

**Causes:**
- File share is unreachable
- MSI file missing or moved
- Network credentials expired

**Resolution:**
1. **Verify file share access:**
   ```powershell
   Get-ChildItem "\\svr-fs\support\Software\Absolute VPN\Secure Access\Client\"
   ```
   If this fails:
   - Check network connectivity to `svr-fs`
   - Verify SMB (port 445) is not blocked by firewall
   - Ensure domain credentials are cached:
     ```powershell
     net use \\svr-fs\support /user:DOMAIN\username password
     ```

2. **Verify MSI file exists:**
   - Contact admin to confirm MSI location
   - If MSI has been moved, update `$ShareMsi` path in script

---

### Issue 3: "MSI install failed with exit code 1603"

**Error Message:**
```
MSI install failed with exit code 1603. See C:\Temp\SecureAccess_install.log
```

**Common causes:**
- Corrupted MSI file
- Missing .NET Framework prerequisites
- File permissions issue
- Another MSI already installing

**Resolution:**
1. **Review MSI log for details:**
   ```powershell
   Get-Content "C:\Temp\SecureAccess_install.log" | Select-String "error" -Context 3
   ```

2. **Check .NET Framework:**
   ```powershell
   Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full"
   # Should show Release and other values
   ```
   If missing, install .NET Framework 4.8 runtime

3. **Wait for other MSI operations:**
   ```powershell
   Get-Process msiexec -ErrorAction SilentlyContinue
   # If running, wait for completion before retrying
   ```

4. **Verify MSI integrity:**
   ```powershell
   $msiPath = "\\svr-fs\support\Software\Absolute VPN\Secure Access\Client\SecureAccess_client_14.10_x64_release.msi"
   (Get-FileHash -Path $msiPath -Algorithm SHA256).Hash
   # Compare with known good hash if available
   ```

---

### Issue 4: "Reboot did not occur" or "System did not restart"

**Symptom:** Installation completed but system is still running.

**Cause:** Exit code was not 0 or 3010, so reboot was skipped.

**Resolution:**
1. **Check MSI exit code:**
   ```powershell
   Get-Content "C:\Temp\SecureAccess_install.log" | Select-String "exit"
   ```

2. **If exit code shows error:** Review Issue 3 (MSI install failure)

3. **Manual reboot if installation successful:**
   ```powershell
   # Confirm registry settings are correct first
   Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\NMDRV\Params\Mobility Client"
   
   # If settings look good, force reboot
   shutdown /r /t 0
   ```

---

### Issue 5: "INF application failed" (If using `-AlsoApplyInf`)

**Warning Message:**
```
Applying INF via setupapi failed: [error details]
```

**Cause:** INF file is missing, corrupted, or has syntax errors.

**Resolution:**
1. **Verify INF exists:**
   ```powershell
   Test-Path "\\svr-fs\support\Software\Absolute VPN\Secure Access\Client\vpn_HPTX_ClientConfig.inf"
   ```

2. **If INF is missing:** Disable `-AlsoApplyInf` flag (basic registry config is sufficient)

3. **If INF exists but fails:** Validate INF syntax
   - Obtain INF from vendor and verify structure
   - Consider deploying without INF initially (registry settings handle basics)

---

### Issue 6: "Registry configuration not applied"

**Symptom:** Registry keys do not exist after installation or VPN server is blank.

**Cause:** Installation was too quick and registry writes not completed, or MSI exited with error code.

**Resolution:**
1. **Check if installation actually succeeded:**
   ```powershell
   Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" | 
       Where-Object { $_.DisplayName -match "SecureAccess" }
   # Should show installation entry
   ```

2. **If client is installed but registry is missing:** Re-run script with `-AlsoApplyInf` to force reapplication:
   ```powershell
   .\Install-SecureAccessVPN.ps1
   ```

3. **If still missing, manually set registry:**
   ```powershell
   $mcKey = "HKLM:\SYSTEM\CurrentControlSet\Services\NMDRV\Params\Mobility Client"
   New-Item -Path $mcKey -Force | Out-Null
   Set-ItemProperty -Path $mcKey -Name "MmsAddress" -Value "vpn.hptx.org" -Type String
   Set-ItemProperty -Path $mcKey -Name "ShowWarningMessages" -Value 0 -Type DWord
   # ... repeat for other values
   ```

---

## Rollback & Recovery

### Uninstall SecureAccess Client

**If deployment failed or rollback is needed:**

```powershell
# Method 1: Via Control Panel (manual)
# Settings → Apps → Programs and Features → Search "SecureAccess" → Uninstall

# Method 2: Via PowerShell
$msi = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" | 
    Where-Object { $_.DisplayName -match "SecureAccess" }

if ($msi) {
    $productCode = $msi.PSChildName
    msiexec.exe /x "$productCode" /qn /norestart /log "C:\Temp\SecureAccess_uninstall.log"
    Write-Host "Uninstall initiated. Monitor log at C:\Temp\SecureAccess_uninstall.log"
} else {
    Write-Host "SecureAccess not found in registry; already uninstalled or not installed."
}
```

### Clean Up Temporary Files

```powershell
# Remove all temporary installation files
Remove-Item -Path "C:\Temp\SecureAccess*" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "C:\Temp\vpn_HPTX*" -Force -ErrorAction SilentlyContinue

Write-Host "Temporary files cleaned up."
```

### Verify Complete Removal

```powershell
# 1. Check uninstall registry
Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" | 
    Where-Object { $_.DisplayName -match "SecureAccess" }
# Should return nothing

# 2. Check registry configuration
Test-Path "HKLM:\SYSTEM\CurrentControlSet\Services\NMDRV\Params"
# May still exist if NMDRV service is installed for other purposes

# 3. Check processes
Get-Process -Name "*SecureAccess*" -ErrorAction SilentlyContinue
# Should return nothing

# 4. Check services
Get-Service -Name "*NetMotion*" -ErrorAction SilentlyContinue | Select-Object Name, Status
# Services may still exist; manual removal via services.msc if needed
```

---

## Deployment Examples

### Example 1: Automated Enterprise Deployment (Group Policy / SCCM)

**Script Block for MDM/SCCM Package:**
```powershell
# Deploy via System Center Configuration Manager (SCCM)
# Program: PowerShell.exe
# Arguments: -NoProfile -ExecutionPolicy Bypass -File "\\share\Install-SecureAccessVPN.ps1"
# Run As: System (admin)
# Reboot: Allow (system will reboot anyway)

.\Install-SecureAccessVPN.ps1
```

**Expected Result:** Client installs → Reboot → Users can connect to VPN immediately post-login

---

### Example 2: Manual Deployment on Single System

```powershell
# Open PowerShell as Administrator
# Navigate to script directory
cd "\\share\scripts"

# Run script
.\Install-SecureAccessVPN.ps1

# Output:
# msiexec exit code: 0
# Installation succeeded (code 0). Rebooting to finalize setup...

# System reboots automatically
```

---

### Example 3: Deployment with INF Profile

```powershell
# If you have custom INF file (vpn_HPTX_ClientConfig.inf) with certificates or proxy settings:
.\Install-SecureAccessVPN.ps1 -AlsoApplyInf

# Expected Result: MSI installs → INF applies → Registry configured → Reboot
```

---

## Version History

| Version | Date | Changes | Author |
| --- | --- | --- | --- |
| **1.0.0** | 2026-05-27 | Initial release. Streamlined single-phase deployment with automatic registry configuration and forced reboot. INF support optional. | Jay Smith |

---

## Appendix: Quick Reference

### Installation Command
```powershell
# Basic (recommended)
.\Install-SecureAccessVPN.ps1

# With INF profile
.\Install-SecureAccessVPN.ps1 -AlsoApplyInf
```

### Verification Commands
```powershell
# Check if installed
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" | 
    Where-Object { $_.DisplayName -match "SecureAccess" }

# Check registry config
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\NMDRV\Params\Mobility Client"

# Check log
Get-Content "C:\Temp\SecureAccess_install.log" -Tail 30
```

### Troubleshooting Commands
```powershell
# Test file share access
Test-Path "\\svr-fs\support\Software\Absolute VPN\Secure Access\Client"

# Check services
Get-Service -Name "*NetMotion*"

# Check event log
Get-EventLog -LogName System -Source "MsiInstaller" -Newest 5
```

### Uninstall Commands
```powershell
# Via PowerShell
$msi = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" | 
    Where-Object { $_.DisplayName -match "SecureAccess" }
msiexec.exe /x "$($msi.PSChildName)" /qn

# Via Command Line
msiexec.exe /x "SecureAccess_client_14.10_x64_release.msi" /qn
```

---

**Installation Runbook Author:** Jay Smith  
**Script Version:** 1.0.0 (current)  
**Last Updated:** 2026-05-27  
**Status:** Production-Ready  
**Deployment Model:** Automated single-phase with forced system reboot
