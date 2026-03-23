#!/bin/bash
# test_session.sh — Verifies Claude config persistence across parcai sessions
# Run this OUTSIDE the sandbox (on the host).

set -uo pipefail

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; ((PASS++)); }
fail() { echo "  FAIL: $1"; ((FAIL++)); }

PARCAI_BIN="${1:-./parcai}"
TEST_DIR="$(mktemp -d)"
ORIG_DIR="$(pwd)"

echo "=== parcai session persistence tests ==="
echo ""
echo "Test directory: $TEST_DIR"

cleanup() {
  cd "$ORIG_DIR"
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# Create a test project
mkdir -p "$TEST_DIR/test-project"
echo "hello" > "$TEST_DIR/test-project/file.txt"
cd "$TEST_DIR/test-project"

# Compute expected session dir
HASH=$(printf '%s' "$TEST_DIR/test-project" | sha256sum 2>/dev/null || printf '%s' "$TEST_DIR/test-project" | shasum -a 256 2>/dev/null)
HASH="${HASH%% *}"
HASH="${HASH:0:12}"
SESS_DIR="$HOME/.parcai/sessions/$HASH"

echo "Expected session dir: $SESS_DIR"
echo ""

# --- Test 1: First run creates session dir ---
echo "--- Test 1: First run ---"

# Run parcai with --discard, create a .claude/settings.json inside
echo 'echo "{\"theme\": \"dark\"}" > .claude/settings.json && exit' | \
  "$PARCAI_BIN" --discard 2>/dev/null

if [[ -d "$SESS_DIR" ]]; then
  pass "session directory created"
else
  fail "session directory not created at $SESS_DIR"
fi

if [[ -d "$SESS_DIR/claude-config" ]]; then
  pass "claude-config directory created"
else
  fail "claude-config directory not created"
fi

if [[ -f "$SESS_DIR/claude-config/settings.json" ]]; then
  pass "settings.json persisted"
else
  fail "settings.json not persisted"
fi

# --- Test 2: Subsequent run restores config ---
echo ""
echo "--- Test 2: Subsequent run ---"

echo 'cat .claude/settings.json && exit' | \
  "$PARCAI_BIN" --discard 2>/dev/null > "$TEST_DIR/output.txt"

if grep -q "dark" "$TEST_DIR/output.txt" 2>/dev/null; then
  pass "settings.json restored on subsequent run"
else
  fail "settings.json not restored (output: $(cat "$TEST_DIR/output.txt" 2>/dev/null))"
fi

# --- Test 3: Global ~/.claude is NOT accessible ---
echo ""
echo "--- Test 3: Global config isolation ---"

echo 'ls ~/.claude/ 2>&1 && exit' | \
  "$PARCAI_BIN" --discard 2>/dev/null > "$TEST_DIR/output2.txt"

# In the sandbox, ~/.claude should not resolve to the global one
# On Linux (unshare), HOME=/project, so ~/.claude is .claude/ (the injected one)
# On macOS, ~/.claude is denied in the sandbox profile
if grep -q "projects" "$TEST_DIR/output2.txt" 2>/dev/null; then
  fail "global ~/.claude appears accessible (projects/ dir found)"
else
  pass "global ~/.claude not accessible"
fi

# --- Test 4: credentials not leaked ---
echo ""
echo "--- Test 4: Credential isolation ---"

# The sandbox should not have the user's global ~/.claude/settings.json or mcp configs
echo 'ls -la ~/.claude/ 2>&1 && exit' | \
  "$PARCAI_BIN" --discard 2>/dev/null > "$TEST_DIR/output3.txt"

if grep -q "mcp" "$TEST_DIR/output3.txt" 2>/dev/null; then
  fail "MCP configs from global ~/.claude leaked into sandbox"
else
  pass "no MCP configs leaked"
fi

# --- Cleanup session ---
rm -rf "$SESS_DIR"

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
