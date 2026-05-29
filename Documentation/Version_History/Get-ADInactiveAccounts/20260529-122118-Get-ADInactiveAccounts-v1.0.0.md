---
name: Get-ADInactiveAccounts
version: 1.0.0
title: 'Get-ADInactiveAccounts - Active Directory Inactive Account Report'
last_updated: 2026-05-29T12:21:18Z
author: Jay Smith
change_type: add
artifacts:
  - Scripts/Powershell/Get-ADInactiveAccounts.ps1
  - Documentation/Get-ADInactiveAccounts.md
persona_pipeline:
  - Coder
  - Reviewer
  - DocuWriter
reviewer_summary: pass; verified author metadata, ActiveDirectory module dependency, and timestamped export path compliance.
doc_summary: Added live documentation and version history entry for Get-ADInactiveAccounts.ps1, including usage, parameters, output details, and audit-ready export behavior.
author_normalization: Author header set to Jay Smith on both script and documentation.
citations: []
---

# Version History: Get-ADInactiveAccounts

## v1.0.0

- Initial implementation of `Get-ADInactiveAccounts.ps1`
- Created documentation in `Documentation/Get-ADInactiveAccounts.md`
- Added version history entry under `Documentation/Version_History/Get-ADInactiveAccounts/`
- Report exports save to `c:\temp\Get-ADInactiveAccounts\` with timestamped filenames
