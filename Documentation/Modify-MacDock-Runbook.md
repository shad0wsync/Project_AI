---
title: macOS Dock Standardization Workflow for Jamf Pro
version: 1.0.0
last_updated: 2026-07-29
author: Jay Smith
scriptname: Set-MacDock.sh
location: Scripts/Bash/
language: Bash (macOS)
change_type: feature/deployment
---

# macOS Dock Standardization Workflow for Jamf Pro v1.0.0

## Overview

This workflow standardizes the Dock on managed macOS devices by applying a consistent baseline configuration through Jamf Pro and a lightweight shell script. It is intended for environments where IT wants the same Dock behavior across all Macs without relying on users to configure it manually.

## What This Workflow Does

✓ Applies a consistent Dock layout policy to managed Macs
✓ Sets Dock appearance and behavior such as autohide, size, orientation, and recent-app visibility
✓ Restarts the Dock so the new settings take effect immediately
✓ Can be scoped to all Macs or a specific smart group in Jamf Pro

## Recommended Jamf Pro Approach

Use a combination of:
1. A Jamf Pro smart group for target Macs
2. A macOS configuration profile for the Dock payload when you need stricter enforcement
3. A policy that runs the included shell script for a baseline configuration

> The exact configuration profile UI path can vary slightly by Jamf Pro version. In most recent versions, the payload is found under the macOS Dock settings when creating a configuration profile.

## Prerequisites

- Jamf Pro with macOS management enabled
- Devices enrolled in Jamf Pro
- Administrative access to create policies and configuration profiles
- The script file available on the target device or pushed via Jamf Pro

## Targeting Strategy

### Suggested Scope

- Scope the policy to:
  - All Managed Macs, or
  - A smart group such as `Operating System Is macOS` and `Computer Group Is Corporate`

### Recommended Execution

- Trigger: `Recurring Check-In` or `Once per computer`
- Execution Frequency: `Once per computer` for initial rollout
- Reboot: Not required; the script restarts the Dock directly

## Script Behavior

The included script applies these baseline settings:
- Dock autohide: enabled
- Dock tile size: 48
- Dock orientation: bottom
- Recent apps section: disabled
- Dock magnification: disabled

These values are easy to adjust by editing the script or passing environment variables at runtime.

## Example Jamf Pro Policy Flow

1. Create a policy in Jamf Pro.
2. Add the script from the repository as a shell script payload.
3. Set the execution method to `bash`.
4. Scope the policy to the intended Mac smart group.
5. Trigger it on recurring check-in.
6. Verify the result on a test Mac before rolling it out broadly.

## Verification Steps

After the policy runs, validate on a test Mac:

```bash
defaults read com.apple.dock autohide
defaults read com.apple.dock tilesize
defaults read com.apple.dock orientation
defaults read com.apple.dock show-recents
```

You should also confirm the Dock restarts and reflects the new settings.

## Rollback / Recovery

If you need to revert the baseline Dock settings:
- Remove or disable the policy
- Re-run the script with adjusted environment variables
- Optionally restore a previous Dock plist from a backup if the environment requires full rollback

## Notes

- This workflow is intentionally conservative and focused on a standardized baseline.
- If you need to pin specific applications such as Microsoft Teams, Self Service, or managed browsers, extend the workflow with a more explicit app-list policy.
- For highly regulated environments, pair this with a configuration profile for stronger enforcement and clearer auditability.

## Version History

| Version | Date | Notes |
| --- | --- | --- |
| 1.0.0 | 2026-07-29 | Initial Dock standardization workflow and shell script |
