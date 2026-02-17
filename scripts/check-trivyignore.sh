#!/usr/bin/env bash
set -euo pipefail

ignore_file="${1:-.trivyignore}"
report_file="${2:-trivy-report.json}"
today_utc="$(date -u +%Y-%m-%d)"

if [ ! -f "$ignore_file" ]; then
  echo "Ignore file not found: $ignore_file" >&2
  exit 1
fi

if [ ! -f "$report_file" ]; then
  echo "Trivy report not found: $report_file" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required for stale-ignore validation" >&2
  exit 1
fi

entries=""
pending_expiry=""
while IFS= read -r raw_line || [ -n "$raw_line" ]; do
  line="${raw_line%$'\r'}"
  if [[ -z "${line//[[:space:]]/}" ]]; then
    continue
  fi

  if [[ "$line" =~ ^[[:space:]]*# ]]; then
    if [[ "$line" =~ exp:([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
      pending_expiry="${BASH_REMATCH[1]}"
    fi
    continue
  fi

  if [[ "$line" =~ (CVE-[0-9]{4}-[0-9]+) ]]; then
    cve="${BASH_REMATCH[1]}"
    entries+="${cve}"$'\t'"${pending_expiry}"$'\n'
    pending_expiry=""
  fi
done < "$ignore_file"
entries="${entries%$'\n'}"

ignored_cves="$(printf '%s\n' "$entries" | cut -f1 | grep -E '^CVE-[0-9]{4}-[0-9]+$' | sort -u || true)"

if [ -z "$ignored_cves" ]; then
  echo "No CVEs listed in $ignore_file"
  exit 0
fi

present_cves="$(jq -r '
  ..
  | objects
  | select(has("VulnerabilityID"))
  | .VulnerabilityID
' "$report_file" \
  | { grep -E '^CVE-[0-9]{4}-[0-9]+$' || true; } \
  | sort -u)"

stale_cves="$(comm -23 \
  <(printf '%s\n' "$ignored_cves") \
  <(printf '%s\n' "$present_cves"))"

exit_code=0

if [ -n "$stale_cves" ]; then
  echo "Stale CVE suppressions found in $ignore_file:" >&2
  while IFS= read -r cve; do
    [ -n "$cve" ] || continue
    echo "  - $cve" >&2
  done <<< "$stale_cves"
  echo "Remove stale entries or rerun Trivy if the report is outdated." >&2
  exit_code=1
fi

expired_entries="$(
  while IFS=$'\t' read -r cve expiry; do
    [ -n "$cve" ] || continue
    [ -n "$expiry" ] || continue
    if [[ "$expiry" < "$today_utc" ]]; then
      printf '%s\t%s\n' "$cve" "$expiry"
    fi
  done <<< "$entries"
)"

if [ -n "$expired_entries" ]; then
  echo "Expired CVE suppressions found in $ignore_file (today: $today_utc UTC):" >&2
  while IFS=$'\t' read -r cve expiry; do
    [ -n "$cve" ] || continue
    echo "  - $cve (expired $expiry)" >&2
  done <<< "$expired_entries"
  echo "Update or remove expired entries and rerun validation." >&2
  exit_code=1
fi

if [ "$exit_code" -ne 0 ]; then
  exit "$exit_code"
fi

echo "All CVEs in $ignore_file are present in $report_file and have valid expiries"
