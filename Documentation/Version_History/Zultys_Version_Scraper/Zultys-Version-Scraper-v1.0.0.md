---
title: Zultys MX Version Scraper
version: 1.0.0
last_updated: 2026-05-26
author: Jay Smith
scriptname: zultys_version_scraper.py
location: Scripts/Python/Zultys_Version_Scrapper/
language: Python 3.8+
---

# Zultys MX Version Scraper v1.0.0

## Table of Contents

1. [Overview](#overview)
2. [Quick Start](#quick-start)
3. [Requirements](#requirements)
4. [Installation](#installation)
5. [Parameters Reference](#parameters-reference)
6. [Usage Examples](#usage-examples)
7. [Common Use Cases](#common-use-cases)
8. [Output Files](#output-files)
9. [Exit Codes](#exit-codes)
10. [Error Handling & Troubleshooting](#error-handling--troubleshooting)
11. [Version History](#version-history)

---

## Overview

The **Zultys MX Version Scraper** is an automated Python utility designed to extract version information from Zultys MX appliances via HTTP/HTTPS. It:

- ✓ Reads a CSV file containing Zultys appliance URLs
- ✓ Scrapes the main page for version patterns (e.g., "Version: 16.0.3")
- ✓ Writes detected versions back to a results CSV
- ✓ Generates error logs for failed scrapes
- ✓ Includes retry logic and graceful error handling
- ✓ Auto-generates a template CSV if input file is missing
- ✓ Outputs structured logs and results to `C:\temp\zultys_version_scraper\`

### Capabilities

| Capability | Description |
| --- | --- |
| **Automated Discovery** | Extracts version strings using flexible regex patterns |
| **Batch Processing** | Processes multiple URLs in a single run |
| **Template Generation** | Auto-creates template CSV if input file is missing |
| **Retry Logic** | Handles transient HTTP failures (429, 500, 502, 503, 504) |
| **HTML Parsing** | Uses lxml for robust DOM extraction; falls back to raw text |
| **Logging** | Dual output: file log and console stream |
| **Conditional Scraping** | Skips URLs with existing versions unless `--force` flag is used |
| **Error Tracking** | Captures and catalogs failures in a separate errors CSV |

---

## Quick Start

### Basic Invocation (Auto-Detect Input CSV)

```bash
python zultys_version_scraper.py
```

**Expected behavior:**
- If `C:\temp\zultys_version_scraper\zultys_urls.csv` exists, the script reads it and begins scraping.
- If it does not exist, a template CSV is created, and the script exits with instructions.

### With Custom Input File

```bash
python zultys_version_scraper.py --input C:\custom\path\urls.csv
```

### Force Re-Scrape All URLs

```bash
python zultys_version_scraper.py --force
```

This ignores cached versions and re-scrapes every URL, updating the results CSV.

---

## Requirements

### System Requirements

| Requirement | Specification |
| --- | --- |
| **Python Version** | 3.8 or higher |
| **Operating System** | Windows 10+, macOS, Linux |
| **Disk Space** | Minimal (~50 MB for logs and results) |
| **Network Access** | Direct HTTP/HTTPS access to Zultys appliances |

### Python Dependencies

| Package | Version | Purpose |
| --- | --- | --- |
| `requests` | 2.28.0+ | HTTP client with retry logic |
| `lxml` | 4.9.0+ | HTML parsing and DOM extraction |

### Installation

#### Step 1: Ensure Python 3.8+ is installed

```bash
python --version
```

#### Step 2: Install dependencies

```bash
pip install requests lxml
```

#### Step 3: Place script in your working directory

```bash
# Copy zultys_version_scraper.py to your preferred location
cp zultys_version_scraper.py C:\Scripts\
```

---

## Parameters Reference

### Command-Line Arguments

| Argument | Short | Type | Default | Description |
| --- | --- | --- | --- | --- |
| `--input` | `-i` | string | `C:\temp\zultys_version_scraper\zultys_urls.csv` | Path to input CSV file containing Zultys URLs |
| `--force` | `-f` | flag | `false` | Force re-scrape all URLs, ignoring cached versions |

### Input CSV Format

The input CSV must contain at minimum a `url` column. A `version` column is optional but recommended.

**Template format:**

```csv
url,version
https://zultys-mx-01.example.com/,
https://zultys-mx-02.example.com/,16.0.2
https://zultys-mx-03.example.com/,
```

**Rules:**
- Lines starting with `#` are treated as comments and skipped
- Blank lines are ignored
- Column names are case-insensitive and whitespace-tolerant
- The `url` column is required; `version` is optional
- URLs without trailing slashes are accepted

### Configuration (Built-In)

| Setting | Value | Purpose |
| --- | --- | --- |
| **Request Timeout** | 15 seconds | Maximum time to wait for HTTP response |
| **Retry Attempts** | 3 | Total retry attempts for transient failures |
| **Backoff Factor** | 0.5 seconds | Exponential backoff between retries |
| **Polite Delay** | 0.2 seconds | Delay between consecutive requests |
| **User-Agent** | Chrome 124 (Windows NT 10.0) | HTTP User-Agent header |

---

## Usage Examples

### Example 1: Basic Execution with Auto-Detected Input

```bash
python zultys_version_scraper.py
```

**Console output:**
```
[2026-05-26 10:15:42,123] [INFO] Input CSV not found. A template was created at: C:\temp\zultys_version_scraper\zultys_urls.csv
Add your Zultys URLs under the 'url' column and re-run the script.
```

**Action:** Edit the template CSV with your Zultys URLs and re-run.

### Example 2: Custom Input File and Force Re-Scrape

```bash
python zultys_version_scraper.py --input "C:\Shared\zultys_prod.csv" --force
```

**Expected console output:**
```
[2026-05-26 10:16:50,456] [INFO] [1/3] Scraping: https://zultys-mx-01.example.com/
[2026-05-26 10:16:52,789] [INFO]   ✓ Found version: 16.0.3
[2026-05-26 10:16:53,012] [INFO] [2/3] Scraping: https://zultys-mx-02.example.com/
[2026-05-26 10:16:54,234] [INFO]   ✓ Found version: 16.1.0
[2026-05-26 10:16:54,456] [INFO] [3/3] Scraping: https://zultys-mx-03.example.com/
[2026-05-26 10:16:56,789] [WARNING]   ✗ Failed: HTTP 404
[2026-05-26 10:16:57,012] [INFO] Results written: C:\temp\zultys_version_scraper\zultys_version_scraper_results.csv
[2026-05-26 10:16:57,234] [INFO] Errors written: C:\temp\zultys_version_scraper\zultys_version_scraper_errors.csv
Done. See results at: C:\temp\zultys_version_scraper\zultys_version_scraper_results.csv
Logs: C:\temp\zultys_version_scraper\zultys_version_scraper.log
Errors: C:\temp\zultys_version_scraper\zultys_version_scraper_errors.csv
```

### Example 3: View Results CSV

After execution, examine the results:

```bash
# Windows
type C:\temp\zultys_version_scraper\zultys_version_scraper_results.csv

# Linux/macOS
cat /tmp/zultys_version_scraper/zultys_version_scraper_results.csv
```

**Results format:**

| url | version | status |
| --- | --- | --- |
| https://zultys-mx-01.example.com/ | 16.0.3 | scraped |
| https://zultys-mx-02.example.com/ | 16.0.2 | kept |
| https://zultys-mx-03.example.com/ | | error |

---

## Common Use Cases

### Use Case 1: Discover Versions Across Production Zultys Fleet

**Objective:** Audit all Zultys MX appliances in the organization to identify versions and plan upgrade strategy.

**Steps:**
1. Create `inventory.csv` with URLs of all Zultys appliances:
   ```csv
   url,version
   https://zultys-mx-prod-01.internal/,
   https://zultys-mx-prod-02.internal/,
   https://zultys-mx-dr.internal/,
   ```

2. Run the scraper:
   ```bash
   python zultys_version_scraper.py --input inventory.csv
   ```

3. Review results:
   ```bash
   type C:\temp\zultys_version_scraper\zultys_version_scraper_results.csv
   ```

4. **Expected output:** A CSV showing version strings for each appliance. Use this to plan upgrades (e.g., identify which systems are behind on patches).

---

### Use Case 2: Re-Validate Version Information After System Patches

**Objective:** After patching Zultys systems, verify that version updates were applied correctly.

**Steps:**
1. Run with `--force` to bypass cached versions:
   ```bash
   python zultys_version_scraper.py --force
   ```

2. Compare old and new results:
   ```bash
   # Old results backed up as: zultys_version_scraper_results_OLD.csv
   # New results in: zultys_version_scraper_results.csv
   ```

3. **Expected outcome:** Identify systems that successfully updated vs. those requiring remediation.

---

### Use Case 3: Continuous Monitoring with Scheduled Tasks

**Objective:** Run version discovery weekly and track drift over time.

**Windows Task Scheduler:**
1. Create a batch file (`run_scraper.bat`):
   ```batch
   @echo off
   cd C:\Scripts
   python zultys_version_scraper.py >> C:\logs\zultys_audit_%DATE%.log 2>&1
   ```

2. Schedule as a weekly task (e.g., Monday 02:00 AM) with appropriate credentials.

3. **Expected outcome:** Automated weekly audit logs; easy to spot version drifts or appliance unavailability.

---

## Output Files

### Results CSV

**Location:** `C:\temp\zultys_version_scraper\zultys_version_scraper_results.csv`

**Columns:**
- `url`: The appliance URL from input
- `version`: Detected version or cached version
- `status`: One of `scraped`, `kept`, or `error`

**Example:**
```csv
url,version,status
https://mx-01/,16.0.3,scraped
https://mx-02/,16.0.2,kept
https://mx-03/,,error
```

---

### Errors CSV

**Location:** `C:\temp\zultys_version_scraper\zultys_version_scraper_errors.csv` (if errors occur)

**Columns:**
- `url`: The appliance URL that failed
- `error`: Error description (e.g., "HTTP 404", "Request error: Connection timeout", "Version pattern not found")

**Example:**
```csv
url,error
https://mx-03/,HTTP 404
https://mx-04/,Request error: [Errno 11001] getaddrinfo failed
```

---

### Log File

**Location:** `C:\temp\zultys_version_scraper\zultys_version_scraper.log`

**Format:** Each line includes timestamp, log level, and message.

**Example:**
```
2026-05-26 10:15:42,123 [INFO] [1/3] Scraping: https://mx-01/
2026-05-26 10:15:44,456 [INFO]   ✓ Found version: 16.0.3
2026-05-26 10:15:44,789 [INFO] Results written: C:\temp\zultys_version_scraper\zultys_version_scraper_results.csv
```

---

## Exit Codes

| Code | Meaning | Action |
| --- | --- | --- |
| `0` | Success | All tasks completed. Review results CSV. |
| `1` | Fatal Error | Check log file for details. Common causes: invalid input CSV, permission denied, network unreachable. |

---

## Error Handling & Troubleshooting

### Issue: "Input CSV not found. A template was created."

**Cause:** The default input file path does not exist.

**Resolution:**
1. Navigate to `C:\temp\zultys_version_scraper\`
2. Edit `zultys_urls.csv` and add your Zultys appliance URLs
3. Re-run the script

**Example template edit:**
```csv
url,version
https://zultys-mx-prod.example.com/,
https://zultys-mx-dr.example.com/,
```

---

### Issue: "HTTP 404" or "HTTP 503" errors

**Cause:** Target appliance is unreachable or returning an error status code.

**Resolution:**
1. Verify the URL is correct and reachable:
   ```bash
   # Test from command line
   curl -I https://zultys-mx-prod.example.com/
   ```

2. Check appliance status:
   - Verify appliance is powered on
   - Confirm network connectivity (ping, SSH)
   - Check firewall rules

3. Inspect the errors CSV for the specific HTTP status code and take appropriate action

---

### Issue: "Version pattern not found"

**Cause:** The appliance responded with HTTP 200 but the version string did not match any regex pattern.

**Resolution:**
1. Manually visit the appliance URL in a browser
2. Right-click → Inspect (or View Source) and search for "version" or "Version"
3. Note the exact version format
4. If the format differs from expected patterns, report to the development team for regex enhancement

**Current patterns matched:**
- "Version: x.x.x." (case-insensitive)
- "v x.x.x", "Ver x.x.x", "version: x.x.x" with optional separators

---

### Issue: "Request error: Connection timeout"

**Cause:** The HTTP request exceeded 15 seconds (default timeout).

**Resolution:**
1. Check network connectivity to the target appliance
2. Verify appliance is responsive (SSH, ping)
3. Check for network congestion or bandwidth limits
4. Consider running during off-peak hours
5. For permanently slow appliances, modify the timeout constant in the script (line ~60)

---

### Issue: "Unexpected error: KeyError" in logs

**Cause:** Input CSV has an invalid format or missing `url` column.

**Resolution:**
1. Verify the CSV contains at least a `url` column
2. Ensure no headers are missing or misformatted
3. Delete the CSV and let the script regenerate a template
4. Repopulate with your appliances and retry

---

### Issue: Permission Denied on Output Directory

**Cause:** `C:\temp\zultys_version_scraper\` does not exist or is not writable.

**Resolution:**
1. Create the directory manually:
   ```bash
   mkdir C:\temp\zultys_version_scraper
   ```

2. Verify write permissions for your user account

3. Alternatively, specify a different input/output path with appropriate permissions

---

## Version History

| Version | Date | Changes |
| --- | --- | --- |
| 1.0.0 | 2026-05-26 | Initial release. Includes HTTP scraping, CSV I/O, retry logic, and dual-output logging. |

---

## Additional Notes

- **Network Etiquette:** The script includes a 0.2-second delay between requests to avoid overwhelming target appliances.
- **HTTPS Support:** All regex and request logic supports both HTTP and HTTPS URLs.
- **Encoding:** All CSV and log files use UTF-8 encoding for international character support.
- **Idempotency:** Re-running the script on the same input with cached versions skips already-detected appliances (use `--force` to override).

---

**Documentation Author:** Jay Smith  
**Script Author:** Jay Smith  
**Last Updated:** 2026-05-26  
**Version:** 1.0.0
