#!/usr/bin/env bash
set -euo pipefail

# Unit tests for clone_with_reference_cache() in scripts/lib.sh.
# Tests use a local bare repo as the clone source so no network is required.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "${SCRIPT_DIR}/lib.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# ── Create a minimal local bare repo as a stand-in for GitHub ─────────────

origin_bare="${workdir}/origin.git"
# Seed a working repo then push to bare origin
src="${workdir}/src"
git init "$src" --quiet
GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="t@t.com" \
GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="t@t.com" \
  git -C "$src" commit --allow-empty -m "initial" --quiet
git init --bare "$origin_bare" --quiet
git -C "$src" push "file://${origin_bare}" HEAD:refs/heads/main --quiet
# Point bare HEAD to main so --single-branch clone works without --branch
git -C "$origin_bare" symbolic-ref HEAD refs/heads/main
rm -rf "$src"

echo "Running clone_with_reference_cache tests"

# ── Test 1: cache miss → clone succeeds, mirror is created ────────────────

cache_root="${workdir}/cache1"
dest1="${workdir}/dest1"
# Use file:// URL so no token env vars are needed
clone_url="file://${origin_bare}"
GIT_ASKPASS="" GIT_PAT="" clone_with_reference_cache \
  "$clone_url" "$dest1" "$cache_root" --depth 1 --single-branch

[ -d "${dest1}/.git" ] || fail "dest1 should be a git repo after cache-miss clone"

# Mirror should now exist — derive key using same pattern as clone_with_reference_cache
url_key="$(printf '%s' "$clone_url" | sed 's|^https\?://||; s|\.git$||; s|[/:]|-|g')"
mirror_dir="${cache_root}/${url_key}/mirror.git"
[ -d "$mirror_dir" ] || fail "mirror.git should be created on cache miss: ${mirror_dir}"
[ -f "${mirror_dir}/config" ] || fail "mirror.git should have a git config file"

# gc.auto should be disabled on the mirror
gc_auto="$(git -C "$mirror_dir" config gc.auto 2>/dev/null || echo "missing")"
[ "$gc_auto" = "0" ] || fail "gc.auto should be 0 in mirror, got: ${gc_auto}"

echo "PASS: cache miss creates mirror and produces valid clone"

# ── Test 2: cache hit → clone reuses mirror ───────────────────────────────

dest2="${workdir}/dest2"
GIT_ASKPASS="" GIT_PAT="" clone_with_reference_cache \
  "$clone_url" "$dest2" "$cache_root" --depth 1 --single-branch

[ -d "${dest2}/.git" ] || fail "dest2 should be a git repo after cache-hit clone"

echo "PASS: cache hit reuses mirror and produces valid clone"

# ── Test 3: --dissociate — working clone is self-contained ────────────────
# Delete the mirror and verify the working clone still has its objects.

rm -rf "$mirror_dir"
git -C "$dest2" log --oneline >/dev/null 2>&1 || fail "dest2 lost objects after mirror deletion"

echo "PASS: working clone is self-contained after --dissociate"

# ── Test 4: corrupt mirror triggers fallback to direct clone ──────────────

cache_root2="${workdir}/cache2"
url_key2="$(printf '%s' "$clone_url" | sed 's|^https\?://||; s|\.git$||; s|[/:]|-|g')"
mirror_dir2="${cache_root2}/${url_key2}/mirror.git"
# Create a corrupt mirror (empty directory looks like a missing repo to git)
mkdir -p "${mirror_dir2}"
touch "${mirror_dir2}/CORRUPT"

dest3="${workdir}/dest3"
GIT_ASKPASS="" GIT_PAT="" clone_with_reference_cache \
  "$clone_url" "$dest3" "$cache_root2" --depth 1 --single-branch

[ -d "${dest3}/.git" ] || fail "dest3 should be a git repo after fallback clone"

echo "PASS: corrupt mirror triggers fallback to direct clone"

echo "All clone_with_reference_cache tests passed"
