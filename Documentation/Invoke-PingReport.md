Version: 1.0.0  
Last Updated: 2026-04-16

## Table of Contents
- [Overview](#overview)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Parameters Reference](#parameters-reference)
- [Output](#output)
- [Examples](#examples)
- [Troubleshooting](#troubleshooting)

## Overview
`Invoke-PingReport.ps1` runs ICMP ping tests from the local NIC and exports the results to a timestamped CSV file. It supports both continuous pinging and scheduled timeframes, with optional custom target selection.

The script is designed for quick network reachability validation and basic latency logging for troubleshooting from a Windows host.

## Requirements
| Component | Version/Details | Notes |
|-----------|-----------------|-------|
| Operating System | Windows 10/11 or Windows Server 2016+ | Required for PowerShell and Test-Connection |
| PowerShell | 5.1 or higher | PowerShell 7+ is supported |
| Network | ICMP allowed to target | Firewall rules may block ping traffic |

## Quick Start
Run the script from a PowerShell prompt:
```powershell
.\Scripts\Powershell\Invoke-PingReport.ps1
```

This launches interactive prompts for target selection and mode.

## Parameters Reference
| Parameter | Type | Default | Mandatory | Description |
|-----------|------|---------|-----------|-------------|
| `Target` | String | `8.8.8.8` | No | IP address or hostname to ping |
| `Mode` | String | `Continuous` or `Scheduled` | No | Choose `Continuous` or `Scheduled` mode |
| `Count` | Int | `0` | No | Number of ping iterations for continuous mode; `0` means run until stopped |
| `DurationMinutes` | Int | `0` | No | Duration in minutes for scheduled mode |
| `IntervalSeconds` | Int | `1` | No | Seconds to wait between ping iterations |
| `OutputRoot` | String | `C:\Temp` | No | Base folder used for output export |
| `ScriptName` | String | `PingReport` | No | Subfolder name under `OutputRoot` |

## Output
The script exports results to a CSV file using this path pattern:

`C:\Temp\PingReport\[HostName]MM_DD_YY_HH-mm-ss.csv`

Each row contains:
- `Timestamp`
- `Target`
- `Source`
- `Status`
- `ResponseTimeMs`
- `BufferSize`
- `TimeToLive`
- `Address`
- `ErrorMessage` (only on failures)

## Examples
Run the script interactively using default target:
```powershell
.\Scripts\Powershell\Invoke-PingReport.ps1
```

Run a scheduled 10-minute ping to `1.1.1.1`:
```powershell
Invoke-PingReport -Target 1.1.1.1 -Mode Scheduled -DurationMinutes 10
```

Run 15 ping iterations to `8.8.8.8` with a 2-second interval:
```powershell
Invoke-PingReport -Mode Continuous -Count 15 -IntervalSeconds 2
```

## Troubleshooting
| Issue | Symptom | Solution |
|-------|---------|----------|
| No output file created | Script reports no results | Verify ICMP traffic is permitted and the target is reachable |
| Script prompts repeatedly for target | Invalid or blank target input | Enter a valid IP address or hostname when prompted |
| CSV export fails | Permission denied or path issue | Confirm write access to `C:\Temp` and ensure the folder is not locked |
| Ping failures only | All results show `Failure` | Check network connectivity, firewall policies, and target availability |
