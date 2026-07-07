#Requires -Version 5.1

<#
.SYNOPSIS
    Creates a rollback snapshot for a target file, supports a dry run, and prompts before applying changes.

.DESCRIPTION
    This script creates a backup snapshot of a target file in C:\Temp using the naming convention
    <scriptname>_snapshot.<filename>. It can preview the change without modifying the file, then prompt
    the operator to either stop or commit the change after reviewing the preview.

.PARAMETER TargetPath
    Path to the file that will be inspected and modified.

.PARAMETER ChangeText
    Text to append to the target file when changes are committed.

.PARAMETER SnapshotDirectory
    Directory where the rollback snapshot and metadata will be stored. Defaults to C:\Temp.

.PARAMETER DryRun
    Displays the planned change without modifying the file.

.PARAMETER Rollback
    Restores the file from the saved snapshot backup instead of applying a new change.

.PARAMETER Force
    Skips the confirmation prompt and commits immediately.

.EXAMPLE
    .\Invoke-ChangeWithSnapshot.ps1 -TargetPath C:\Temp\example.txt -ChangeText "Applied by automation" -DryRun

.EXAMPLE
    .\Invoke-ChangeWithSnapshot.ps1 -TargetPath C:\Temp\example.txt -ChangeText "Applied by automation"
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$TargetPath,

    [Parameter()]
    [string]$ChangeText = "Temporary change applied by Invoke-ChangeWithSnapshot",

    [Parameter()]
    [string]$SnapshotDirectory = "C:\Temp",

    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [switch]$Rollback,

    [Parameter()]
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Script metadata
$ScriptVersion = "1.0.0"
$ScriptName = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Name)

function New-ChangeSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$BackupPath,

        [Parameter(Mandatory = $true)]
        [string]$MetadataPath
    )

    $fileExists = Test-Path -LiteralPath $Path
    $originalHash = $null

    if ($fileExists) {
        $originalContent = Get-Content -LiteralPath $Path -Raw
        $originalHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }

    $snapshot = [ordered]@{
        Timestamp      = (Get-Date).ToUniversalTime().ToString("o")
        ScriptName     = $ScriptName
        ScriptVersion  = $ScriptVersion
        TargetPath     = $Path
        FileExists     = $fileExists
        OriginalHash   = $originalHash
        BackupPath     = $BackupPath
        MetadataPath   = $MetadataPath
    }

    $snapshot | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $MetadataPath -Encoding UTF8

    if ($fileExists) {
        Copy-Item -LiteralPath $Path -Destination $BackupPath -Force
    }

    return $snapshot
}

function Restore-ChangeSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MetadataPath,

        [Parameter(Mandatory = $true)]
        [string]$BackupPath,

        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    if (-not (Test-Path -LiteralPath $MetadataPath)) {
        throw "Snapshot metadata not found at $MetadataPath"
    }

    if (-not (Test-Path -LiteralPath $BackupPath)) {
        throw "Snapshot backup not found at $BackupPath"
    }

    $targetDirectory = Split-Path -Parent $TargetPath
    if ($targetDirectory -and -not (Test-Path -LiteralPath $targetDirectory)) {
        New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
    }

    Copy-Item -LiteralPath $BackupPath -Destination $TargetPath -Force
    Write-Host "Restored $TargetPath from snapshot backup $BackupPath" -ForegroundColor Green
}

try {
    if (-not (Test-Path -LiteralPath $SnapshotDirectory)) {
        New-Item -ItemType Directory -Path $SnapshotDirectory -Force | Out-Null
    }

    $resolvedTargetPath = $TargetPath
    if (-not ([System.IO.Path]::IsPathRooted($TargetPath))) {
        $resolvedTargetPath = Join-Path -Path (Get-Location).Path -ChildPath $TargetPath
    }

    $targetFileName = [System.IO.Path]::GetFileName($resolvedTargetPath)
    if ([string]::IsNullOrWhiteSpace($targetFileName)) {
        throw "TargetPath must include a file name."
    }

    $backupFileName = "$ScriptName`_snapshot.$targetFileName"
    $backupPath = Join-Path -Path $SnapshotDirectory -ChildPath $backupFileName
    $metadataPath = "$backupPath.json"

    if ($Rollback) {
        Restore-ChangeSnapshot -MetadataPath $metadataPath -BackupPath $backupPath -TargetPath $resolvedTargetPath
        exit 0
    }

    if (-not (Test-Path -LiteralPath $resolvedTargetPath)) {
        $parentDirectory = Split-Path -Parent $resolvedTargetPath
        if ($parentDirectory -and -not (Test-Path -LiteralPath $parentDirectory)) {
            New-Item -ItemType Directory -Path $parentDirectory -Force | Out-Null
        }
    }

    Write-Host "Snapshot backup path: $backupPath" -ForegroundColor Cyan
    Write-Host "Snapshot metadata path: $metadataPath" -ForegroundColor Cyan

    if ($DryRun) {
        Write-Host "[DRY RUN] No changes will be made." -ForegroundColor Yellow
    }

    $snapshot = New-ChangeSnapshot -Path $resolvedTargetPath -BackupPath $backupPath -MetadataPath $metadataPath

    $changePreview = @"
Planned change:
  - Append the following text to $resolvedTargetPath
  - $ChangeText
"@

    Write-Host $changePreview -ForegroundColor Yellow

    if ($DryRun) {
        Write-Host "Dry run completed. Re-run without -DryRun to commit the change." -ForegroundColor Green
        exit 0
    }

    if (-not $Force) {
        $confirmation = Read-Host "Proceed with the change? Type Y to commit or N to stop"
        if ($confirmation -notmatch '^(Y|YES)$') {
            Write-Host "Change cancelled by user." -ForegroundColor Yellow
            exit 0
        }
    }

    if ($PSCmdlet.ShouldProcess($resolvedTargetPath, "Append change text")) {
        if (-not (Test-Path -LiteralPath $resolvedTargetPath)) {
            Set-Content -LiteralPath $resolvedTargetPath -Value "" -Encoding UTF8
        }

        Add-Content -LiteralPath $resolvedTargetPath -Value "`n$ChangeText"
        Write-Host "Change committed successfully to $resolvedTargetPath" -ForegroundColor Green
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
