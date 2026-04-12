#!/usr/bin/env bash
# Guard that gh auth setup-git runs after the HOME isolation switch in
# worker/run-once.sh. If the order is reversed the credential helper is
# written into the container HOME, so authenticated git operations under
# the isolated job HOME silently fail (see issue #477).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/worker/run-once.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Find the line numbers for the two anchors.
# shellcheck disable=SC2016  # single-quoted pattern is intentional: grep sees \$ as literal $
home_line="$(grep -n 'export HOME="\$job_home"' "$script" | head -1 | cut -d: -f1)"
setup_git_line="$(grep -n 'gh auth setup-git' "$script" | head -1 | cut -d: -f1 || true)"

# gh auth setup-git lives in integrations/github/setup.sh (called from
# workload_setup); confirm that call site is reachable from worker/run-once.sh.
[ -n "$home_line" ] || fail "could not find 'export HOME=\"\$job_home\"' in $script"

if [ -z "$setup_git_line" ]; then
  # gh auth setup-git is in the integration file; verify the integration is
  # sourced after the HOME switch by checking workload_setup call ordering.
  workload_line="$(grep -n '^workload_setup' "$script" | head -1 | cut -d: -f1)"
  [ -n "$workload_line" ] || fail "could not find 'workload_setup' call in $script"
  if [ "$home_line" -ge "$workload_line" ]; then
    fail "'workload_setup' (line $workload_line) must appear after 'export HOME=\"\$job_home\"' (line $home_line) in $script"
  fi
  echo "PASS: workload_setup (line $workload_line) is after HOME switch (line $home_line) — gh auth setup-git runs in the correct HOME"
  exit 0
fi

if [ "$home_line" -ge "$setup_git_line" ]; then
  fail "'gh auth setup-git' (line $setup_git_line) must appear after 'export HOME=\"\$job_home\"' (line $home_line) in $script"
fi

echo "PASS: gh auth setup-git (line $setup_git_line) is after HOME switch (line $home_line)"
