#!/usr/bin/env bash
# lib-validate.sh — input validation, auth-mode resolution, and provider preflight checks.
#
# Extracted from lib.sh. No cross-lib dependencies — all functions are self-contained.
# Source this file in any orchestrator that needs these functions; do not let one lib
# source another.

# lib-validate.sh is a sourced library; avoid "return" errors when run directly.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  echo "scripts/lib-validate.sh is a library and should be sourced, not executed." >&2
  exit 0
fi

if [ -n "${HIVEMOOT_LIB_VALIDATE_LOADED:-}" ]; then
  return 0
fi
HIVEMOOT_LIB_VALIDATE_LOADED=1

resolve_effective_auth_mode() {
  local provider="$1"
  local configured_auth_mode="${2:-auto}"

  case "$configured_auth_mode" in
    api_key|subscription)
      printf '%s' "$configured_auth_mode"
      return 0
      ;;
    auto|'')
      ;;
    *)
      return 1
      ;;
  esac

  case "$provider" in
    codex)
      if [ -n "${OPENAI_API_KEY:-}" ]; then
        printf 'api_key'
      else
        printf 'subscription'
      fi
      ;;
    gemini)
      if [ -n "${GOOGLE_API_KEY:-}" ] || [ -n "${GEMINI_API_KEY:-}" ]; then
        printf 'api_key'
      else
        printf 'subscription'
      fi
      ;;
    claude)
      if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        printf 'api_key'
      else
        printf 'subscription'
      fi
      ;;
    kilo)
      if [ -n "${KILOCODE_TOKEN:-}" ] || [ -n "${KILO_PROVIDER:-}" ]; then
        printf 'api_key'
      else
        printf 'subscription'
      fi
      ;;
    opencode)
      if [ -n "${OPENCODE_PROVIDER:-}" ]; then
        printf 'api_key'
      else
        printf 'subscription'
      fi
      ;;
    *)
      return 1
      ;;
  esac
}

repo_name_is_valid() {
  local repo_name="$1"
  local repo_segment=""

  if ! printf '%s' "$repo_name" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9_.-]+$'; then
    return 1
  fi

  repo_segment="${repo_name#*/}"
  case "$repo_segment" in
    .|..)
      return 1
      ;;
  esac

  return 0
}

validate_target_repo() {
  local target_repo="$1"

  if [ -z "$target_repo" ]; then
    echo "TARGET_REPO is required. Set it as owner/repo." >&2
    exit 1
  fi

  if ! repo_name_is_valid "$target_repo"; then
    echo "Invalid TARGET_REPO: ${target_repo}. Expected owner/repo." >&2
    exit 1
  fi
}

validate_workspace_root() {
  local workspace_root="$1"

  case "$workspace_root" in
    /*) ;;
    *)
      echo "WORKSPACE_ROOT must be an absolute path" >&2
      exit 1
      ;;
  esac
}

validate_agent_id() {
  local agent_id="$1"

  case "$agent_id" in
    ''|*[!a-zA-Z0-9_-]*)
      echo "Invalid AGENT_ID: ${agent_id}" >&2
      exit 1
      ;;
  esac
}

# Returns 0 if task_id is safe for use in paths and URLs, 1 otherwise.
# Allowed: alphanumeric, hyphens, underscores, dots (no slashes, no whitespace).
# Explicitly rejected: empty string, bare "." and "..".
task_id_is_valid() {
  local task_id="$1"
  case "$task_id" in
    ''|.|..|*[!A-Za-z0-9._-]*)
      return 1
      ;;
  esac
  return 0
}

validate_task_id() {
  local task_id="$1"
  if ! task_id_is_valid "$task_id"; then
    echo "Invalid task_id: ${task_id}" >&2
    exit 1
  fi
}

preflight_check_provider_auth() {
  local provider="$1"
  local auth_mode="${2:-auto}"
  local failures=0

  # Provider auth check
  case "$provider" in
    codex)
      local resolved="$auth_mode"
      [ "$resolved" = "auto" ] && resolved=$( [ -n "${OPENAI_API_KEY:-}" ] && echo "api_key" || echo "subscription" )
      if [ "$resolved" = "api_key" ] && [ -z "${OPENAI_API_KEY:-}" ]; then
        echo "Pre-flight: OPENAI_API_KEY missing for codex + api_key mode." >&2
        failures=$((failures + 1))
      fi
      ;;
    gemini)
      local resolved="$auth_mode"
      [ "$resolved" = "auto" ] && resolved=$( { [ -n "${GOOGLE_API_KEY:-}" ] || [ -n "${GEMINI_API_KEY:-}" ]; } && echo "api_key" || echo "subscription" )
      if [ "$resolved" = "api_key" ] && [ -z "${GOOGLE_API_KEY:-}" ] && [ -z "${GEMINI_API_KEY:-}" ]; then
        echo "Pre-flight: GOOGLE_API_KEY/GEMINI_API_KEY missing for gemini + api_key mode." >&2
        failures=$((failures + 1))
      fi
      ;;
    claude)
      local resolved="$auth_mode"
      [ "$resolved" = "auto" ] && resolved=$( [ -n "${ANTHROPIC_API_KEY:-}" ] && echo "api_key" || echo "subscription" )
      if [ "$resolved" = "api_key" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
        echo "Pre-flight: ANTHROPIC_API_KEY missing for claude + api_key mode." >&2
        failures=$((failures + 1))
      fi
      ;;
    kilo)
      if [ -z "${KILOCODE_TOKEN:-}" ]; then
        if [ -z "${KILO_PROVIDER:-}" ]; then
          echo "Pre-flight: KILO_PROVIDER is required for kilo (unless KILOCODE_TOKEN is set for gateway mode)." >&2
          failures=$((failures + 1))
        else
          case "${KILO_PROVIDER}" in
            anthropic)
              if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
                echo "Pre-flight: ANTHROPIC_API_KEY missing for KILO_PROVIDER=anthropic." >&2
                failures=$((failures + 1))
              fi
              ;;
            openai)
              if [ -z "${OPENAI_API_KEY:-}" ]; then
                echo "Pre-flight: OPENAI_API_KEY missing for KILO_PROVIDER=openai." >&2
                failures=$((failures + 1))
              fi
              ;;
            google)
              if [ -z "${GOOGLE_API_KEY:-}" ] && [ -z "${GEMINI_API_KEY:-}" ]; then
                echo "Pre-flight: GOOGLE_API_KEY/GEMINI_API_KEY missing for KILO_PROVIDER=google." >&2
                failures=$((failures + 1))
              fi
              ;;
            openrouter)
              if [ -z "${OPENROUTER_API_KEY:-}" ]; then
                echo "Pre-flight: OPENROUTER_API_KEY missing for KILO_PROVIDER=openrouter." >&2
                failures=$((failures + 1))
              fi
              ;;
          esac
        fi
      fi
      ;;
    opencode)
      if [ -n "${OPENCODE_PROVIDER:-}" ]; then
        case "${OPENCODE_PROVIDER}" in
          zai)
            if [ -z "${ZAI_API_KEY:-}" ]; then
              echo "Pre-flight: ZAI_API_KEY missing for OPENCODE_PROVIDER=zai." >&2
              failures=$((failures + 1))
            fi
            ;;
        esac
      elif [ ! -f "/home/node/.local/share/opencode/auth.json" ]; then
        echo "Pre-flight: OpenCode auth not configured. Set OPENCODE_PROVIDER + API key, or run: opencode auth login." >&2
        failures=$((failures + 1))
      fi
      ;;
  esac

  return "$failures"
}
