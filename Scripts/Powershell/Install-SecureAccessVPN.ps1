# Install NetMotion/Absolute Secure Access Client and configure settings
# Saved as .txt by request; content is PowerShell. Run elevated.
# - Copies MSI from share to C:\Temp
# - Installs silently; treats 0 and 3010 as success
# - Enforces all required registry settings (server + suppress warnings)
# - DOES NOT apply the INF by default (avoids first-install popups); optional -AlsoApplyInf to run it
# - DOES NOT restart any services
# - Deletes both MSI and INF from C:\Temp
# - Auto-reboots in 10 seconds when exit code is 0 or 3010

param(
    [switch]$AlsoApplyInf
)

$ErrorActionPreference = 'Stop'

# --- Paths / inputs ---
$ShareMsi = "\\svr-fs\support\Software\Absolute VPN\Secure Access\Client\SecureAccess_client_14.10_x64_release.msi"
$ShareInf = "\\svr-fs\support\Software\Absolute VPN\Secure Access\Client\vpn_HPTX_ClientConfig.inf"
$TempDir  = "C:\\Temp"
$LocalMsi = Join-Path $TempDir "SecureAccess_client_14.10_x64_release.msi"
$LocalInf = Join-Path $TempDir "vpn_HPTX_ClientConfig.inf"
$MsiLog   = Join-Path $TempDir "SecureAccess_install.log"
$ServerFqdn = "vpn.hptx.org"

# --- Ensure C:\Temp exists ---
if (-not (Test-Path -LiteralPath $TempDir)) {
    New-Item -ItemType Directory -Path $TempDir | Out-Null
}

# --- Pre-check share files ---
if (-not (Test-Path -LiteralPath $ShareMsi)) { throw "MSI not found at $ShareMsi" }
if (-not (Test-Path -LiteralPath $ShareInf)) { Write-Warning "INF not found at $ShareInf; continuing without INF" }

# --- Copy payloads ---
Copy-Item -LiteralPath $ShareMsi -Destination $LocalMsi -Force
if (Test-Path -LiteralPath $ShareInf) { Copy-Item -LiteralPath $ShareInf -Destination $LocalInf -Force }

# --- Install MSI silently (no restart) ---
$msiArgs = "/i `"$LocalMsi`" /qn /norestart /l*v `"$MsiLog`""
$proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -PassThru -Wait -WindowStyle Hidden
$exit = [int]$proc.ExitCode
Write-Host "msiexec exit code: $exit"

# Treat 0 and 3010 as success; others = failure
if ($exit -ne 0 -and $exit -ne 3010) {
    throw "MSI install failed with exit code $exit. See $MsiLog"
}

# --- Optionally apply INF (disabled by default to avoid modal popups on first install) ---
if ($AlsoApplyInf -and (Test-Path -LiteralPath $LocalInf)) {
    try {
        # 132 commonly used for quiet; still can present vendor UI in some cases. Keep hidden.
        $args = "setupapi.dll,InstallHinfSection DefaultInstall 132 `"$LocalInf`""
        Start-Process -FilePath "rundll32.exe" -ArgumentList $args -Wait -WindowStyle Hidden
    }
    catch {
        Write-Warning "Applying INF via setupapi failed: $($_.Exception.Message)"
    }
}

# --- Enforce registry for server + UI suppression (replace need for manual UI) ---
$mcKey    = "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\NMDRV\\Params\\Mobility Client"
$stateKey = "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\NMDRV\\Params\\Mobility Client State"

New-Item -Path $mcKey -Force | Out-Null
New-Item -Path $stateKey -Force | Out-Null

# Server address and UI state
New-ItemProperty -Path $mcKey -Name "MmsAddress" -Value $ServerFqdn -PropertyType String -Force | Out-Null
New-ItemProperty -Path $stateKey -Name "CurrentSubkey" -Value ("MMS " + $ServerFqdn) -PropertyType String -Force | Out-Null

# Suppress warnings in UI
New-ItemProperty -Path $mcKey -Name "FailoverQuell" -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $mcKey -Name "ConnectDiagnosticQuell" -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $mcKey -Name "FatalQuell" -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $mcKey -Name "ShowWarningMessages" -Value 0 -PropertyType DWord -Force | Out-Null

# --- Cleanup: delete local MSI and INF copies ---
foreach ($p in @($LocalMsi, $LocalInf)) {
    try {
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    } catch {
        Write-Warning "Failed to delete ${p}: $($_.Exception.Message)"
    }
}

# --- Auto-reboot within 10 seconds on 0 or 3010 ---
if ($exit -eq 0 -or $exit -eq 3010) {
    Write-Host "Installation succeeded (code $exit). Rebooting to finalize setup..."
    # Use shutdown.exe to ensure reboot even if this host process exits; suppress UI prompts
    Start-Process -FilePath "shutdown.exe" -ArgumentList "/r /t 0 /c `"Rebooting to complete Secure Access install`"" -WindowStyle Hidden
}
