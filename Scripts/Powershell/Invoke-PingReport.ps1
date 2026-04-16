<#
.SYNOPSIS
Runs ping tests from the local NIC and exports results to CSV.
.DESCRIPTION
This script prompts for a target (default 8.8.8.8 or custom IP), asks whether to run a continuous ping or a scheduled timeframe, and exports the results to a timestamped CSV file under C:\Temp\PingReport.
.EXAMPLE
.\Invoke-PingReport.ps1
.EXAMPLE
Invoke-PingReport -Target 1.1.1.1 -Mode Scheduled -DurationMinutes 10
#>

function Invoke-PingReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string]$Target,

        [Parameter(Mandatory=$false)]
        [ValidateSet("Continuous", "Scheduled")]
        [string]$Mode,

        [Parameter(Mandatory=$false)]
        [int]$Count = 0,

        [Parameter(Mandatory=$false)]
        [int]$DurationMinutes = 0,

        [Parameter(Mandatory=$false)]
        [int]$IntervalSeconds = 1,

        [Parameter(Mandatory=$false)]
        [string]$OutputRoot = "C:\Temp",

        [Parameter(Mandatory=$false)]
        [string]$ScriptName = "PingReport"
    )

    $defaultTarget = '8.8.8.8'
    if (-not $Target) {
        $selection = Read-Host 'Ping default target 8.8.8.8 or custom IP? Enter D for default or C for custom'
        if ($selection -match '^[Cc]') {
            do {
                $Target = Read-Host 'Enter custom IP address or hostname'
            } while (-not $Target)
        }
        else {
            $Target = $defaultTarget
        }
    }

    if (-not $Mode) {
        do {
            $modeSelection = Read-Host 'Run continuous ping or scheduled timeframe? Enter C for continuous or S for scheduled'
        } while ($modeSelection -notmatch '^[CsS]$')

        $Mode = if ($modeSelection -match '^[Cc]$') { 'Continuous' } else { 'Scheduled' }
    }

    if ($IntervalSeconds -lt 1) {
        $IntervalSeconds = 1
    }

    if ($Mode -eq 'Scheduled') {
        if ($DurationMinutes -le 0) {
            do {
                $durationInput = Read-Host 'Enter scheduled duration in minutes (positive integer)'
            } while (-not [int]::TryParse($durationInput, [ref]$null) -or [int]$durationInput -le 0)
            $DurationMinutes = [int]$durationInput
        }
    }
    else {
        if ($Count -lt 0) {
            $Count = 0
        }

        if ($Count -eq 0) {
            $countInput = Read-Host 'Enter number of ping iterations (0 to run until stopped with Ctrl+C)'
            if ([int]::TryParse($countInput, [ref]$parsedCount)) {
                $Count = [int]$parsedCount
            }
        }
    }

    $computerName = $env:COMPUTERNAME
    $timestampFile = Get-Date -Format 'MM_dd_yy_HH-mm-ss'
    $outputFolder = Join-Path -Path $OutputRoot -ChildPath $ScriptName
    if (-not (Test-Path -Path $outputFolder)) {
        New-Item -Path $outputFolder -ItemType Directory -Force | Out-Null
    }

    $csvPath = Join-Path -Path $outputFolder -ChildPath "$computerName$timestampFile.csv"

    $results = @()
    $iteration = 0
    $endTime = if ($Mode -eq 'Scheduled') { (Get-Date).AddMinutes($DurationMinutes) } else { $null }

    Write-Host "Starting ping report to $Target from local NIC. Mode: $Mode" -ForegroundColor Cyan
    if ($Mode -eq 'Scheduled') {
        Write-Host "Scheduled duration: $DurationMinutes minute(s), interval: $IntervalSeconds second(s)" -ForegroundColor Cyan
    }
    else {
        if ($Count -gt 0) {
            Write-Host "Continuous ping for $Count iteration(s) at $IntervalSeconds second(s) interval." -ForegroundColor Cyan
        }
        else {
            Write-Host "Continuous ping until stopped with Ctrl+C." -ForegroundColor Cyan
        }
    }

    while ($true) {
        if ($Mode -eq 'Scheduled' -and (Get-Date) -ge $endTime) {
            break
        }

        if ($Mode -ne 'Scheduled' -and $Count -gt 0 -and $iteration -ge $Count) {
            break
        }

        $iteration++
        $timestamp = Get-Date

        try {
            $pingReply = Test-Connection -ComputerName $Target -Count 1 -ErrorAction Stop
            foreach ($reply in $pingReply) {
                $results += [PSCustomObject]@{
                    Timestamp      = $timestamp.ToString('yyyy-MM-dd HH:mm:ss')
                    Target         = $Target
                    Source         = ($reply.Source -or $computerName)
                    Status         = 'Success'
                    ResponseTimeMs = $reply.ResponseTime
                    BufferSize     = $reply.BufferSize
                    TimeToLive     = $reply.TimeToLive
                    Address        = $reply.Address.IPAddressToString
                }
            }
        }
        catch {
            $results += [PSCustomObject]@{
                Timestamp      = $timestamp.ToString('yyyy-MM-dd HH:mm:ss')
                Target         = $Target
                Source         = $computerName
                Status         = 'Failure'
                ResponseTimeMs = ''
                BufferSize     = ''
                TimeToLive     = ''
                Address        = $Target
                ErrorMessage   = $_.Exception.Message
            }
        }

        if ($Mode -eq 'Scheduled' -and (Get-Date) -ge $endTime) {
            break
        }

        if ($Mode -ne 'Scheduled' -and $Count -gt 0 -and $iteration -ge $Count) {
            break
        }

        Start-Sleep -Seconds $IntervalSeconds
    }

    if ($results.Count -eq 0) {
        Write-Warning 'No ping results were collected.'
        return
    }

    $results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8 -Force
    Write-Host "Ping results exported to: $csvPath" -ForegroundColor Green
    return $csvPath
}

if ($MyInvocation.MyCommand.Path -and $MyInvocation.MyCommand.Path -eq $PSCommandPath) {
    Invoke-PingReport
}
