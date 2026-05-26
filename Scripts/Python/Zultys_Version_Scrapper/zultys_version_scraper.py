#!/usr/bin/env python3
"""
Zultys MX Version Scraper

- Reads a CSV of URLs with columns: url, version
- Scrapes each main page for a pattern like "Version: x.x.x." and writes back the detected version
- Outputs logs and results to: C:\temp\[scriptname]\

Usage:
  python zultys_version_scraper.py --input C:\path\to\zultys_urls.csv [--force]

If --input is omitted, the script looks for:
  C:\temp\zultys_version_scraper\zultys_urls.csv
If not present, it will create a template CSV there and exit with instructions.
"""

import argparse
import csv
import logging
import os
import re
import sys
import time
from pathlib import Path
from typing import Optional, Tuple

import requests
from requests.adapters import HTTPAdapter, Retry
from lxml import html

SCRIPT_NAME = Path(__file__).stem
BASE_DIR = Path(f"C:/temp/{SCRIPT_NAME}")
LOG_PATH = BASE_DIR / f"{SCRIPT_NAME}.log"
RESULTS_CSV = BASE_DIR / f"{SCRIPT_NAME}_results.csv"
ERRORS_CSV = BASE_DIR / f"{SCRIPT_NAME}_errors.csv"
TEMPLATE_CSV = BASE_DIR / "zultys_urls.csv"

VERSION_REGEXES = [
    # Version: 16.0.3.
    re.compile(r"\bVersion\s*:\s*([0-9]+(?:\.[0-9]+){0,3})\.?\b", re.IGNORECASE),
    # v16.0.3 or Ver 16.0.3
    re.compile(r"\b(?:ver(?:sion)?|v)\s*[:#-]?\s*([0-9]+(?:\.[0-9]+){0,3})\b", re.IGNORECASE),
]

HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/124.0 Safari/537.36"
    )
}


def setup_logging():
    BASE_DIR.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        handlers=[
            logging.FileHandler(LOG_PATH, encoding="utf-8"),
            logging.StreamHandler(sys.stdout),
        ],
    )


def make_session() -> requests.Session:
    s = requests.Session()
    retries = Retry(
        total=3,
        backoff_factor=0.5,
        status_forcelist=[429, 500, 502, 503, 504],
        allowed_methods=["GET"],
        raise_on_status=False,
    )
    adapter = HTTPAdapter(max_retries=retries)
    s.mount("http://", adapter)
    s.mount("https://", adapter)
    s.headers.update(HEADERS)
    return s


def create_template_if_missing(path: Path) -> bool:
    if path.exists():
        return False
    BASE_DIR.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=["url", "version"]) 
        writer.writeheader()
        # Add a sample row commented out as guidance
        # Users can remove the leading # to activate
        f.write("# url,version\n")
        f.write("# https://example-zultys-mx-appliance/ ,\n")
    logging.info(f"Template created at: {path}")
    return True


def extract_version_from_text(text: str) -> Optional[str]:
    for rx in VERSION_REGEXES:
        m = rx.search(text)
        if m:
            return m.group(1)
    return None


def scrape_version(session: requests.Session, url: str, timeout: int = 15) -> Tuple[Optional[str], Optional[str]]:
    """Returns (version, error). version is None on failure; error is None on success."""
    try:
        resp = session.get(url, timeout=timeout, allow_redirects=True)
        status = resp.status_code
        if status != 200:
            return None, f"HTTP {status}"
        # Try parsing HTML and extracting text
        try:
            doc = html.fromstring(resp.content)
            # Gather visible text; include script/style stripped automatically
            page_text = doc.text_content()
        except Exception as parse_err:
            page_text = resp.text  # Fallback to raw text
        # Normalize whitespace
        page_text = re.sub(r"\s+", " ", page_text)
        ver = extract_version_from_text(page_text)
        if ver:
            return ver, None
        # As a fallback, also check response headers or small HTML chunks
        head_snippet = resp.text[:4000]
        ver2 = extract_version_from_text(head_snippet)
        if ver2:
            return ver2, None
        return None, "Version pattern not found"
    except requests.RequestException as e:
        return None, f"Request error: {e}" 
    except Exception as e:
        return None, f"Unexpected error: {e}"


def process(input_csv: Path, force: bool = False):
    BASE_DIR.mkdir(parents=True, exist_ok=True)

    # Read input rows
    rows = []
    with input_csv.open("r", newline="", encoding="utf-8") as f:
        # Allow comments (#) and blank lines
        filtered = [line for line in f if line.strip() and not line.lstrip().startswith('#')]
        reader = csv.DictReader(filtered)
        # Normalize fieldnames
        fieldnames = [fn.strip().lower() for fn in reader.fieldnames or []]
        if "url" not in fieldnames:
            raise ValueError("Input CSV must have a 'url' column")
        # Map original fieldnames to normalized
        name_map = {orig: orig.strip().lower() for orig in reader.fieldnames}
        for r in reader:
            url = r.get(next(k for k, v in name_map.items() if v == 'url'), '').strip()
            version = r.get(next((k for k, v in name_map.items() if v == 'version'), 'version'), '').strip()
            if url:
                rows.append({"url": url, "version": version})

    session = make_session()

    results = []
    errors = []

    for idx, row in enumerate(rows, 1):
        url = row["url"]
        cur_ver = row.get("version", "")
        if cur_ver and not force:
            logging.info(f"[{idx}/{len(rows)}] Skipping (already has version): {url} -> {cur_ver}")
            results.append({"url": url, "version": cur_ver, "status": "kept"})
            continue
        logging.info(f"[{idx}/{len(rows)}] Scraping: {url}")
        ver, err = scrape_version(session, url)
        if ver:
            logging.info(f"  ✓ Found version: {ver}")
            results.append({"url": url, "version": ver, "status": "scraped"})
        else:
            logging.warning(f"  ✗ Failed: {err}")
            results.append({"url": url, "version": cur_ver or "", "status": "error"})
            errors.append({"url": url, "error": err or "unknown"})
        # Be polite to endpoints
        time.sleep(0.2)

    # Write results CSV
    with RESULTS_CSV.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=["url", "version", "status"]) 
        writer.writeheader()
        writer.writerows(results)
    logging.info(f"Results written: {RESULTS_CSV}")

    # Write errors CSV if any
    if errors:
        with ERRORS_CSV.open("w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=["url", "error"]) 
            writer.writeheader()
            writer.writerows(errors)
        logging.info(f"Errors written: {ERRORS_CSV}")


def main():
    parser = argparse.ArgumentParser(description="Zultys MX Version Scraper")
    parser.add_argument("--input", "-i", type=str, default=None, help="Path to input CSV with columns: url, version")
    parser.add_argument("--force", "-f", action="store_true", help="Re-scrape even if version already present")
    args = parser.parse_args()

    setup_logging()

    input_csv = Path(args.input) if args.input else TEMPLATE_CSV

    # Create template if missing
    if not input_csv.exists():
        created = create_template_if_missing(input_csv)
        msg = (
            f"Input CSV not found. A template was created at: {input_csv}\n"
            f"Add your Zultys URLs under the 'url' column and re-run the script."
        )
        logging.info(msg)
        print(msg)
        return 0

    try:
        process(input_csv, force=args.force)
        print(f"Done. See results at: {RESULTS_CSV}")
        print(f"Logs: {LOG_PATH}")
        if ERRORS_CSV.exists():
            print(f"Errors: {ERRORS_CSV}")
        return 0
    except Exception as e:
        logging.exception("Fatal error")
        print(f"Fatal error: {e}. See log at {LOG_PATH}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
