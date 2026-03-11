#!/usr/bin/env bash
# token-extractor.sh — sourced library for extracting per-provider token usage
# from NDJSON agent logs.
# Best-effort: each function returns empty string on failure.

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  echo "scripts/token-extractor.sh is a library and should be sourced, not executed." >&2
  exit 0
fi

if [ -n "${HIVEMOOT_TOKEN_EXTRACTOR_LOADED:-}" ]; then
  return 0
fi
HIVEMOOT_TOKEN_EXTRACTOR_LOADED=1

# Extract token usage from a Claude NDJSON stream log.
# Uses the final "type":"result" event.
# Sums tokens from .modelUsage (captures all models, including subagent models).
# Top-level fields: input_tokens, output_tokens, cache_read_input_tokens,
#   cache_creation_input_tokens, cost_usd, num_turns, model_breakdown.
# Outputs a compact JSON object or empty string on failure/unavailable.
extract_claude_token_usage_from_log() {
  local path="$1"
  if [ ! -f "$path" ] || ! command -v jq >/dev/null 2>&1; then
    return 0
  fi
  jq -Rrs '
    [split("\n")[] | select(length > 0) | try fromjson catch null | select(. != null)]
    | map(select(.type == "result")) | last
    | if . == null then empty
      else
        (.modelUsage // {}) as $mu |
        {
          input_tokens:                ([$mu | to_entries[].value.input_tokens               // 0] | add // null),
          output_tokens:               ([$mu | to_entries[].value.output_tokens              // 0] | add // null),
          cache_read_input_tokens:     ([$mu | to_entries[].value.cache_read_input_tokens    // 0] | add // null),
          cache_creation_input_tokens: ([$mu | to_entries[].value.cache_creation_input_tokens // 0] | add // null),
          cost_usd:  (.total_cost_usd // null),
          num_turns: (.num_turns // null),
          model_breakdown: (
            if ($mu | keys | length) > 0 then
              $mu | with_entries(.value = (
                .value | {
                  input_tokens:                .input_tokens,
                  output_tokens:               .output_tokens,
                  cache_read_input_tokens:     .cache_read_input_tokens,
                  cache_creation_input_tokens: .cache_creation_input_tokens,
                  cost_usd:                    .cost_usd
                } | with_entries(select(.value != null))
              ))
            else null end
          )
        }
        | with_entries(select(.value != null))
      end
  ' "$path" 2>/dev/null || true
}

# Extract token usage from a Codex NDJSON stream log.
# Sums usage across all "type":"turn.completed" events (no final summary exists).
# Codex reports: input_tokens, output_tokens, cached_input_tokens (→ cache_read_input_tokens).
# Outputs a compact JSON object or empty string on failure/unavailable.
extract_codex_token_usage_from_log() {
  local path="$1"
  if [ ! -f "$path" ] || ! command -v jq >/dev/null 2>&1; then
    return 0
  fi
  jq -Rrs '
    [split("\n")[] | select(length > 0) | try fromjson catch null | select(. != null)]
    | map(select(.type == "turn.completed"))
    | if length == 0 then empty
      else
        {
          input_tokens:            ([.[].usage.input_tokens          // 0] | add),
          output_tokens:           ([.[].usage.output_tokens         // 0] | add),
          cache_read_input_tokens: ([.[].usage.cached_input_tokens   // 0] | add),
          num_turns:               length
        }
        | with_entries(select(.value != null))
      end
  ' "$path" 2>/dev/null || true
}

# Extract a plain-text run summary from a provider's NDJSON stream log.
# Returns the agent's final text output, capped at RUN_SUMMARY_MAX_BYTES.
# Best-effort: returns empty string on failure or when unavailable.
#
# Args:
#   provider  — provider name (claude|codex|gemini|kilo|opencode)
#   path      — path to the NDJSON stream log
#
# Support:
#   claude  — parses last "type":"result" event; .result is the final assistant text
#   others  — not yet supported; returns empty string
extract_run_summary_from_log() {
  local provider="$1"
  local path="$2"
  local max_bytes="${RUN_SUMMARY_MAX_BYTES:-1500}"
  if [ ! -f "$path" ] || ! [ -s "$path" ] || ! command -v jq >/dev/null 2>&1; then
    return 0
  fi
  case "$provider" in
    claude)
      jq -Rrs '
        [split("\n")[] | select(length > 0) | try fromjson catch null | select(. != null)]
        | map(select(.type == "result")) | last
        | if . == null then empty else (.result // empty) end
      ' "$path" 2>/dev/null | head -c "$max_bytes" || true
      ;;
    *)
      return 0
      ;;
  esac
}
