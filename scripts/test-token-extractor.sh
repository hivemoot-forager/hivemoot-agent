#!/usr/bin/env bash
set -euo pipefail

# Test suite for token-extractor.sh extraction functions.
# Uses fixture NDJSON log snippets — no real provider runs required.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS_RUN=0
TESTS_PASSED=0
TEST_TMP=""

setup() {
  TEST_TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "${TEST_TMP}"
}

fail() {
  echo "FAIL: $*" >&2
  teardown
  exit 1
}

pass() {
  TESTS_PASSED=$((TESTS_PASSED + 1))
  echo "  PASS: $1"
}

run_test() {
  TESTS_RUN=$((TESTS_RUN + 1))
  setup
  "$@"
  teardown
}

# Source the extractor library (not a full script execution).
source_extractor() {
  unset HIVEMOOT_TOKEN_EXTRACTOR_LOADED 2>/dev/null || true
  # shellcheck source=scripts/token-extractor.sh
  . "${SCRIPT_DIR}/token-extractor.sh"
}

# ── Claude extraction tests ───────────────────────────────────────

test_claude_extracts_token_sums_from_model_usage() {
  source_extractor
  # Two-model session: sonnet for output, haiku for bulk input.
  cat > "${TEST_TMP}/run.ndjson" <<'EOF'
{"type":"assistant","message":{}}
{"type":"result","subtype":"success","is_error":false,"duration_ms":5000,"num_turns":3,"total_cost_usd":1.23,"modelUsage":{"claude-sonnet-4-6":{"input_tokens":80,"output_tokens":40,"cache_read_input_tokens":200,"cache_creation_input_tokens":100,"cost_usd":1.00},"claude-haiku-4-5-20251001":{"input_tokens":20,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":50,"cost_usd":0.23}}}
EOF
  local result
  result="$(extract_claude_token_usage_from_log "${TEST_TMP}/run.ndjson")"
  [ -n "$result" ] || fail "expected non-empty result"

  local input_tokens output_tokens cache_read cache_creation cost num_turns
  input_tokens="$(printf '%s' "$result" | jq '.input_tokens')"
  output_tokens="$(printf '%s' "$result" | jq '.output_tokens')"
  cache_read="$(printf '%s' "$result" | jq '.cache_read_input_tokens')"
  cache_creation="$(printf '%s' "$result" | jq '.cache_creation_input_tokens')"
  cost="$(printf '%s' "$result" | jq '.cost_usd')"
  num_turns="$(printf '%s' "$result" | jq '.num_turns')"

  [ "$input_tokens" = "100" ]   || fail "input_tokens: expected 100, got ${input_tokens}"
  [ "$output_tokens" = "50" ]   || fail "output_tokens: expected 50, got ${output_tokens}"
  [ "$cache_read" = "200" ]     || fail "cache_read_input_tokens: expected 200, got ${cache_read}"
  [ "$cache_creation" = "150" ] || fail "cache_creation_input_tokens: expected 150, got ${cache_creation}"
  [ "$cost" = "1.23" ]          || fail "cost_usd: expected 1.23, got ${cost}"
  [ "$num_turns" = "3" ]        || fail "num_turns: expected 3, got ${num_turns}"

  pass "claude: sums input/output/cache tokens from modelUsage across all models"
}

test_claude_extracts_token_sums_from_camelcase_model_usage() {
  source_extractor
  cat > "${TEST_TMP}/run.ndjson" <<'EOF'
{"type":"result","subtype":"success","is_error":false,"duration_ms":5000,"num_turns":3,"total_cost_usd":1.23,"modelUsage":{"claude-sonnet-4-6":{"inputTokens":80,"outputTokens":40,"cacheReadInputTokens":200,"cacheCreationInputTokens":100,"costUSD":1.00},"claude-haiku-4-5-20251001":{"inputTokens":20,"outputTokens":10,"cacheReadInputTokens":0,"cacheCreationInputTokens":50,"costUSD":0.23}}}
EOF
  local result
  result="$(extract_claude_token_usage_from_log "${TEST_TMP}/run.ndjson")"
  [ -n "$result" ] || fail "expected non-empty result"

  local input_tokens output_tokens cache_read cache_creation cost num_turns
  input_tokens="$(printf '%s' "$result" | jq '.input_tokens')"
  output_tokens="$(printf '%s' "$result" | jq '.output_tokens')"
  cache_read="$(printf '%s' "$result" | jq '.cache_read_input_tokens')"
  cache_creation="$(printf '%s' "$result" | jq '.cache_creation_input_tokens')"
  cost="$(printf '%s' "$result" | jq '.cost_usd')"
  num_turns="$(printf '%s' "$result" | jq '.num_turns')"

  [ "$input_tokens" = "100" ]   || fail "input_tokens: expected 100, got ${input_tokens}"
  [ "$output_tokens" = "50" ]   || fail "output_tokens: expected 50, got ${output_tokens}"
  [ "$cache_read" = "200" ]     || fail "cache_read_input_tokens: expected 200, got ${cache_read}"
  [ "$cache_creation" = "150" ] || fail "cache_creation_input_tokens: expected 150, got ${cache_creation}"
  [ "$cost" = "1.23" ]          || fail "cost_usd: expected 1.23, got ${cost}"
  [ "$num_turns" = "3" ]        || fail "num_turns: expected 3, got ${num_turns}"

  pass "claude: sums input/output/cache tokens from camelCase modelUsage"
}

test_claude_model_breakdown_includes_all_fields() {
  source_extractor
  cat > "${TEST_TMP}/run.ndjson" <<'EOF'
{"type":"result","subtype":"success","num_turns":1,"total_cost_usd":1.00,"modelUsage":{"claude-sonnet-4-6":{"input_tokens":80,"output_tokens":40,"cache_read_input_tokens":200,"cache_creation_input_tokens":100,"cost_usd":1.00}}}
EOF
  local result
  result="$(extract_claude_token_usage_from_log "${TEST_TMP}/run.ndjson")"
  [ -n "$result" ] || fail "expected non-empty result"

  local bd_input bd_cache_read bd_cost_ok
  bd_input="$(printf '%s' "$result" | jq '.model_breakdown["claude-sonnet-4-6"].input_tokens')"
  bd_cache_read="$(printf '%s' "$result" | jq '.model_breakdown["claude-sonnet-4-6"].cache_read_input_tokens')"
  # Use jq for numeric comparison to avoid float representation differences (1 vs 1.0 vs 1.00).
  bd_cost_ok="$(printf '%s' "$result" | jq '.model_breakdown["claude-sonnet-4-6"].cost_usd == 1.0')"

  [ "$bd_input" = "80" ]       || fail "model_breakdown input_tokens: expected 80, got ${bd_input}"
  [ "$bd_cache_read" = "200" ] || fail "model_breakdown cache_read: expected 200, got ${bd_cache_read}"
  [ "$bd_cost_ok" = "true" ]   || fail "model_breakdown cost_usd: expected 1.0"

  pass "claude: model_breakdown includes cache and cost fields per model"
}

test_claude_camelcase_model_breakdown_includes_all_fields() {
  source_extractor
  cat > "${TEST_TMP}/run.ndjson" <<'EOF'
{"type":"result","subtype":"success","num_turns":1,"total_cost_usd":1.00,"modelUsage":{"claude-sonnet-4-6":{"inputTokens":80,"outputTokens":40,"cacheReadInputTokens":200,"cacheCreationInputTokens":100,"costUSD":1.00}}}
EOF
  local result
  result="$(extract_claude_token_usage_from_log "${TEST_TMP}/run.ndjson")"
  [ -n "$result" ] || fail "expected non-empty result"

  local bd_input bd_cache_read bd_cost_ok
  bd_input="$(printf '%s' "$result" | jq '.model_breakdown["claude-sonnet-4-6"].input_tokens')"
  bd_cache_read="$(printf '%s' "$result" | jq '.model_breakdown["claude-sonnet-4-6"].cache_read_input_tokens')"
  bd_cost_ok="$(printf '%s' "$result" | jq '.model_breakdown["claude-sonnet-4-6"].cost_usd == 1.0')"

  [ "$bd_input" = "80" ]       || fail "model_breakdown input_tokens: expected 80, got ${bd_input}"
  [ "$bd_cache_read" = "200" ] || fail "model_breakdown cache_read: expected 200, got ${bd_cache_read}"
  [ "$bd_cost_ok" = "true" ]   || fail "model_breakdown cost_usd: expected 1.0"

  pass "claude: camelCase model_breakdown includes cache and cost fields per model"
}

test_claude_uses_cost_usd_key_not_total() {
  source_extractor
  cat > "${TEST_TMP}/run.ndjson" <<'EOF'
{"type":"result","subtype":"success","num_turns":1,"total_cost_usd":2.50,"modelUsage":{"claude-sonnet-4-6":{"input_tokens":10,"output_tokens":5}}}
EOF
  local result
  result="$(extract_claude_token_usage_from_log "${TEST_TMP}/run.ndjson")"
  [ -n "$result" ] || fail "expected non-empty result"

  # Must use cost_usd, not total_cost_usd, as the payload key.
  local has_cost_usd has_total_cost_usd
  has_cost_usd="$(printf '%s' "$result" | jq 'has("cost_usd")')"
  has_total_cost_usd="$(printf '%s' "$result" | jq 'has("total_cost_usd")')"

  [ "$has_cost_usd" = "true" ]       || fail "expected cost_usd key in output"
  [ "$has_total_cost_usd" = "false" ] || fail "must not use total_cost_usd as payload key"

  pass "claude: output uses cost_usd key (not total_cost_usd)"
}

test_claude_no_result_event_returns_empty() {
  source_extractor
  cat > "${TEST_TMP}/run.ndjson" <<'EOF'
{"type":"assistant","message":{}}
{"type":"text","text":"hello"}
EOF
  local result
  result="$(extract_claude_token_usage_from_log "${TEST_TMP}/run.ndjson")"
  [ -z "$result" ] || fail "expected empty result when no result event, got: ${result}"
  pass "claude: returns empty when no result event present"
}

test_claude_missing_file_returns_empty() {
  source_extractor
  local result
  result="$(extract_claude_token_usage_from_log "${TEST_TMP}/nonexistent.ndjson")"
  [ -z "$result" ] || fail "expected empty for missing file, got: ${result}"
  pass "claude: returns empty for missing log file"
}

test_claude_empty_file_returns_empty() {
  source_extractor
  : > "${TEST_TMP}/empty.ndjson"
  local result
  result="$(extract_claude_token_usage_from_log "${TEST_TMP}/empty.ndjson")"
  [ -z "$result" ] || fail "expected empty for empty log, got: ${result}"
  pass "claude: returns empty for empty log file"
}

# ── Codex extraction tests ────────────────────────────────────────

test_codex_sums_across_all_turn_completed_events() {
  source_extractor
  cat > "${TEST_TMP}/run.ndjson" <<'EOF'
{"type":"turn.started","turn_id":"t1"}
{"type":"turn.completed","usage":{"input_tokens":100,"output_tokens":20,"cached_input_tokens":50}}
{"type":"turn.started","turn_id":"t2"}
{"type":"turn.completed","usage":{"input_tokens":200,"output_tokens":40,"cached_input_tokens":80}}
EOF
  local result
  result="$(extract_codex_token_usage_from_log "${TEST_TMP}/run.ndjson")"
  [ -n "$result" ] || fail "expected non-empty result"

  local input_tokens output_tokens cache_read num_turns
  input_tokens="$(printf '%s' "$result" | jq '.input_tokens')"
  output_tokens="$(printf '%s' "$result" | jq '.output_tokens')"
  cache_read="$(printf '%s' "$result" | jq '.cache_read_input_tokens')"
  num_turns="$(printf '%s' "$result" | jq '.num_turns')"

  [ "$input_tokens" = "300" ]  || fail "input_tokens: expected 300, got ${input_tokens}"
  [ "$output_tokens" = "60" ]  || fail "output_tokens: expected 60, got ${output_tokens}"
  [ "$cache_read" = "130" ]    || fail "cache_read_input_tokens: expected 130, got ${cache_read}"
  [ "$num_turns" = "2" ]       || fail "num_turns: expected 2, got ${num_turns}"

  pass "codex: sums tokens across all turn.completed events"
}

test_codex_single_turn_returns_correct_counts() {
  source_extractor
  cat > "${TEST_TMP}/run.ndjson" <<'EOF'
{"type":"turn.completed","usage":{"input_tokens":500,"output_tokens":75,"cached_input_tokens":0}}
EOF
  local result
  result="$(extract_codex_token_usage_from_log "${TEST_TMP}/run.ndjson")"
  [ -n "$result" ] || fail "expected non-empty result"

  local num_turns
  num_turns="$(printf '%s' "$result" | jq '.num_turns')"
  [ "$num_turns" = "1" ] || fail "num_turns: expected 1, got ${num_turns}"

  pass "codex: single turn.completed gives num_turns=1"
}

test_codex_includes_nullable_fields_as_null() {
  source_extractor
  cat > "${TEST_TMP}/run.ndjson" <<'EOF'
{"type":"turn.completed","usage":{"input_tokens":500,"output_tokens":75,"cached_input_tokens":0}}
EOF
  local result
  result="$(extract_codex_token_usage_from_log "${TEST_TMP}/run.ndjson")"
  [ -n "$result" ] || fail "expected non-empty result"

  local has_cache_creation has_cost cache_creation cost
  has_cache_creation="$(printf '%s' "$result" | jq 'has("cache_creation_input_tokens")')"
  has_cost="$(printf '%s' "$result" | jq 'has("cost_usd")')"
  cache_creation="$(printf '%s' "$result" | jq '.cache_creation_input_tokens')"
  cost="$(printf '%s' "$result" | jq '.cost_usd')"

  [ "$has_cache_creation" = "true" ] || fail "expected cache_creation_input_tokens key in output"
  [ "$has_cost" = "true" ]           || fail "expected cost_usd key in output"
  [ "$cache_creation" = "null" ]     || fail "expected cache_creation_input_tokens=null, got ${cache_creation}"
  [ "$cost" = "null" ]               || fail "expected cost_usd=null, got ${cost}"

  pass "codex: includes nullable cache creation and cost fields as null"
}

test_codex_no_turn_completed_returns_empty() {
  source_extractor
  cat > "${TEST_TMP}/run.ndjson" <<'EOF'
{"type":"turn.started","turn_id":"t1"}
{"type":"text","content":"hello"}
EOF
  local result
  result="$(extract_codex_token_usage_from_log "${TEST_TMP}/run.ndjson")"
  [ -z "$result" ] || fail "expected empty when no turn.completed events, got: ${result}"
  pass "codex: returns empty when no turn.completed events"
}

test_codex_missing_file_returns_empty() {
  source_extractor
  local result
  result="$(extract_codex_token_usage_from_log "${TEST_TMP}/nonexistent.ndjson")"
  [ -z "$result" ] || fail "expected empty for missing file, got: ${result}"
  pass "codex: returns empty for missing log file"
}

# ── Gemini extraction tests ───────────────────────────────────────

test_gemini_extracts_token_counts_from_result_stats() {
  source_extractor
  cat > "${TEST_TMP}/run.ndjson" <<'EOF'
{"type":"init","timestamp":"2026-01-01T00:00:00Z"}
{"type":"message","role":"assistant","content":"Working on it"}
{"type":"result","timestamp":"2026-01-01T00:00:05Z","status":"success","stats":{"input_tokens":1234,"output_tokens":567,"total_tokens":1801,"cached":0,"duration_ms":3200,"tool_calls":4}}
EOF
  local result
  result="$(extract_gemini_token_usage_from_log "${TEST_TMP}/run.ndjson")"
  [ -n "$result" ] || fail "expected non-empty result"

  local input_tokens output_tokens cache_read num_turns
  input_tokens="$(printf '%s' "$result" | jq '.input_tokens')"
  output_tokens="$(printf '%s' "$result" | jq '.output_tokens')"
  cache_read="$(printf '%s' "$result" | jq '.cache_read_input_tokens')"
  num_turns="$(printf '%s' "$result" | jq '.num_turns')"

  [ "$input_tokens" = "1234" ] || fail "input_tokens: expected 1234, got ${input_tokens}"
  [ "$output_tokens" = "567" ]  || fail "output_tokens: expected 567, got ${output_tokens}"
  [ "$cache_read" = "0" ]       || fail "cache_read_input_tokens: expected 0, got ${cache_read}"
  [ "$num_turns" = "4" ]        || fail "num_turns: expected 4, got ${num_turns}"

  pass "gemini: extracts input/output/cache/turns from result stats"
}

test_gemini_uses_final_result_event_when_multiple_present() {
  source_extractor
  # Two result events — only the last one should be used.
  cat > "${TEST_TMP}/run.ndjson" <<'EOF'
{"type":"result","status":"success","stats":{"input_tokens":100,"output_tokens":10,"cached":0,"tool_calls":1}}
{"type":"result","status":"success","stats":{"input_tokens":999,"output_tokens":88,"cached":5,"tool_calls":7}}
EOF
  local result
  result="$(extract_gemini_token_usage_from_log "${TEST_TMP}/run.ndjson")"
  [ -n "$result" ] || fail "expected non-empty result"

  local input_tokens
  input_tokens="$(printf '%s' "$result" | jq '.input_tokens')"
  [ "$input_tokens" = "999" ] || fail "input_tokens: expected 999 (last event), got ${input_tokens}"

  pass "gemini: uses final result event when multiple are present"
}

test_gemini_includes_nullable_fields_as_absent_when_no_value() {
  source_extractor
  cat > "${TEST_TMP}/run.ndjson" <<'EOF'
{"type":"result","status":"success","stats":{"input_tokens":100,"output_tokens":20,"cached":0,"tool_calls":2}}
EOF
  local result
  result="$(extract_gemini_token_usage_from_log "${TEST_TMP}/run.ndjson")"
  [ -n "$result" ] || fail "expected non-empty result"

  # cache_creation_input_tokens and cost_usd are always null for Gemini — they should be absent.
  local has_cache_creation has_cost
  has_cache_creation="$(printf '%s' "$result" | jq 'has("cache_creation_input_tokens")')"
  has_cost="$(printf '%s' "$result" | jq 'has("cost_usd")')"

  [ "$has_cache_creation" = "false" ] || fail "cache_creation_input_tokens should be absent (null stripped)"
  [ "$has_cost" = "false" ]           || fail "cost_usd should be absent (null stripped)"

  pass "gemini: null cache_creation_input_tokens and cost_usd are stripped from output"
}

test_gemini_with_cache_hits_maps_to_cache_read_field() {
  source_extractor
  cat > "${TEST_TMP}/run.ndjson" <<'EOF'
{"type":"result","status":"success","stats":{"input_tokens":500,"output_tokens":80,"cached":200,"total_tokens":780,"tool_calls":3}}
EOF
  local result
  result="$(extract_gemini_token_usage_from_log "${TEST_TMP}/run.ndjson")"
  [ -n "$result" ] || fail "expected non-empty result"

  local cache_read
  cache_read="$(printf '%s' "$result" | jq '.cache_read_input_tokens')"
  [ "$cache_read" = "200" ] || fail "cache_read_input_tokens: expected 200, got ${cache_read}"

  pass "gemini: stats.cached maps to cache_read_input_tokens"
}

test_gemini_no_result_event_returns_empty() {
  source_extractor
  cat > "${TEST_TMP}/run.ndjson" <<'EOF'
{"type":"init","timestamp":"2026-01-01T00:00:00Z"}
{"type":"message","role":"assistant","content":"hello"}
EOF
  local result
  result="$(extract_gemini_token_usage_from_log "${TEST_TMP}/run.ndjson")"
  [ -z "$result" ] || fail "expected empty when no result event, got: ${result}"
  pass "gemini: returns empty when no result event present"
}

test_gemini_result_without_stats_returns_empty() {
  source_extractor
  cat > "${TEST_TMP}/run.ndjson" <<'EOF'
{"type":"result","status":"success"}
EOF
  local result
  result="$(extract_gemini_token_usage_from_log "${TEST_TMP}/run.ndjson")"
  [ -z "$result" ] || fail "expected empty when result has no stats, got: ${result}"
  pass "gemini: returns empty when result event has no stats field"
}

test_gemini_missing_file_returns_empty() {
  source_extractor
  local result
  result="$(extract_gemini_token_usage_from_log "${TEST_TMP}/nonexistent.ndjson")"
  [ -z "$result" ] || fail "expected empty for missing file, got: ${result}"
  pass "gemini: returns empty for missing log file"
}

test_gemini_empty_file_returns_empty() {
  source_extractor
  : > "${TEST_TMP}/empty.ndjson"
  local result
  result="$(extract_gemini_token_usage_from_log "${TEST_TMP}/empty.ndjson")"
  [ -z "$result" ] || fail "expected empty for empty log, got: ${result}"
  pass "gemini: returns empty for empty log file"
}

# ── Run summary extraction tests ──────────────────────────────────

test_run_summary_claude_extracts_result_field() {
  source_extractor
  cat > "${TEST_TMP}/run.ndjson" <<'EOF'
{"type":"system","subtype":"init","session_id":"abc-123"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Working on it..."}]}}
{"type":"result","subtype":"success","result":"Opened PR #42 to fix auth timeout.\n\n- Updated retry logic\n- Added test coverage","num_turns":3,"total_cost_usd":0.5,"modelUsage":{}}
EOF
  local result
  result="$(extract_run_summary_from_log "claude" "${TEST_TMP}/run.ndjson")"
  [ -n "$result" ] || fail "expected non-empty result"
  printf '%s' "$result" | grep -q "PR #42" || fail "expected result field content, got: ${result}"
  pass "claude: extracts .result field from final result event"
}

test_run_summary_claude_no_result_event_returns_empty() {
  source_extractor
  cat > "${TEST_TMP}/run.ndjson" <<'EOF'
{"type":"system","subtype":"init","session_id":"abc-123"}
{"type":"assistant","message":{"content":[{"type":"text","text":"hello"}]}}
EOF
  local result
  result="$(extract_run_summary_from_log "claude" "${TEST_TMP}/run.ndjson")"
  [ -z "$result" ] || fail "expected empty when no result event, got: ${result}"
  pass "claude: returns empty when no result event"
}

test_run_summary_claude_missing_file_returns_empty() {
  source_extractor
  local result
  result="$(extract_run_summary_from_log "claude" "${TEST_TMP}/nonexistent.ndjson")"
  [ -z "$result" ] || fail "expected empty for missing file, got: ${result}"
  pass "claude: returns empty for missing log file"
}

test_run_summary_codex_extracts_last_agent_message() {
  source_extractor
  # Two agent_message events — expect the last one (plain-text .text fields).
  printf '{"type":"item.completed","item":{"type":"agent_message","text":"First response"}}\n' > "${TEST_TMP}/run.ndjson"
  printf '{"type":"item.completed","item":{"type":"agent_message","text":"Final answer here"}}\n' >> "${TEST_TMP}/run.ndjson"
  local result
  result="$(extract_run_summary_from_log "codex" "${TEST_TMP}/run.ndjson")"
  [ "$result" = "Final answer here" ] || fail "expected last agent_message content, got: ${result}"
  pass "codex: extracts last agent_message from item.completed events"
}

test_run_summary_codex_no_agent_message_returns_empty() {
  source_extractor
  cat > "${TEST_TMP}/run.ndjson" <<'EOF'
{"type":"turn.started","turn_id":"t1"}
{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5}}
EOF
  local result
  result="$(extract_run_summary_from_log "codex" "${TEST_TMP}/run.ndjson")"
  [ -z "$result" ] || fail "expected empty when no agent_message events, got: ${result}"
  pass "codex: returns empty when no agent_message events present"
}

test_run_summary_codex_missing_file_returns_empty() {
  source_extractor
  local result
  result="$(extract_run_summary_from_log "codex" "${TEST_TMP}/nonexistent.ndjson")"
  [ -z "$result" ] || fail "expected empty for missing file, got: ${result}"
  pass "codex: returns empty for missing log file"
}

test_run_summary_unknown_provider_returns_empty() {
  source_extractor
  cat > "${TEST_TMP}/run.ndjson" <<'EOF'
{"type":"result","result":"some output"}
EOF
  local result
  result="$(extract_run_summary_from_log "gemini" "${TEST_TMP}/run.ndjson")"
  [ -z "$result" ] || fail "expected empty for unsupported provider, got: ${result}"
  pass "unsupported provider: returns empty"
}

test_run_summary_truncates_to_max_bytes() {
  source_extractor
  # Build a result string longer than max_bytes (use 20 as cap for test).
  local long_text
  long_text="$(printf '%0.s#' {1..50})"  # 50 '#' chars
  cat > "${TEST_TMP}/run.ndjson" <<EOF
{"type":"result","subtype":"success","result":"${long_text}","num_turns":1,"total_cost_usd":0.1,"modelUsage":{}}
EOF
  local result
  result="$(extract_run_summary_from_log "claude" "${TEST_TMP}/run.ndjson" "20")"
  local result_len
  result_len="${#result}"
  [ "$result_len" -le 20 ] || fail "expected truncation to 20 bytes, got ${result_len} bytes"
  [ "$result_len" -gt 0 ] || fail "expected non-empty truncated result"
  pass "run summary is truncated to max_bytes when result is too long"
}

# ── run all tests ─────────────────────────────────────────────────

echo "Running token extractor tests"
echo ""

echo "  Claude — token extraction:"
run_test test_claude_extracts_token_sums_from_model_usage
run_test test_claude_extracts_token_sums_from_camelcase_model_usage
run_test test_claude_model_breakdown_includes_all_fields
run_test test_claude_camelcase_model_breakdown_includes_all_fields
run_test test_claude_uses_cost_usd_key_not_total
run_test test_claude_no_result_event_returns_empty
run_test test_claude_missing_file_returns_empty
run_test test_claude_empty_file_returns_empty
echo ""

echo "  Codex — token extraction:"
run_test test_codex_sums_across_all_turn_completed_events
run_test test_codex_single_turn_returns_correct_counts
run_test test_codex_includes_nullable_fields_as_null
run_test test_codex_no_turn_completed_returns_empty
run_test test_codex_missing_file_returns_empty
echo ""

echo "  Gemini — token extraction:"
run_test test_gemini_extracts_token_counts_from_result_stats
run_test test_gemini_uses_final_result_event_when_multiple_present
run_test test_gemini_includes_nullable_fields_as_absent_when_no_value
run_test test_gemini_with_cache_hits_maps_to_cache_read_field
run_test test_gemini_no_result_event_returns_empty
run_test test_gemini_result_without_stats_returns_empty
run_test test_gemini_missing_file_returns_empty
run_test test_gemini_empty_file_returns_empty
echo ""

echo "  Run summary — extraction:"
run_test test_run_summary_claude_extracts_result_field
run_test test_run_summary_claude_no_result_event_returns_empty
run_test test_run_summary_claude_missing_file_returns_empty
run_test test_run_summary_codex_extracts_last_agent_message
run_test test_run_summary_codex_no_agent_message_returns_empty
run_test test_run_summary_codex_missing_file_returns_empty
run_test test_run_summary_unknown_provider_returns_empty
run_test test_run_summary_truncates_to_max_bytes
echo ""

echo "Passed ${TESTS_PASSED}/${TESTS_RUN} tests"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ] || exit 1
