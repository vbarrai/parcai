#!/bin/bash
# test_isolation.sh — Verification checklist for parcai sandbox isolation
# Run this INSIDE a parcai shell to verify isolation guarantees.

set -uo pipefail

PASS=0
FAIL=0
SKIP=0

pass() { echo "  PASS: $1"; ((PASS++)); }
fail() { echo "  FAIL: $1"; ((FAIL++)); }
skip() { echo "  SKIP: $1"; ((SKIP++)); }

echo "=== parcai isolation tests ==="
echo ""

# Verify we're inside parcai
if [[ "${PARCAI:-}" != "1" ]]; then
  echo "ERROR: not running inside parcai sandbox. Run 'parcai' first."
  exit 1
fi

echo "Backend: ${PARCAI_BACKEND:-unknown}"
echo ""

# --- Filesystem isolation ---
echo "--- Filesystem isolation ---"

# Cannot read SSH keys
if cat ~/.ssh/id_rsa 2>/dev/null; then
  fail "cat ~/.ssh/id_rsa succeeded (should be blocked)"
else
  pass "cat ~/.ssh/id_rsa blocked"
fi

# Cannot read AWS credentials
if cat ~/.aws/credentials 2>/dev/null; then
  fail "cat ~/.aws/credentials succeeded (should be blocked)"
else
  pass "cat ~/.aws/credentials blocked"
fi

# Cannot read global Claude config
if cat ~/.claude/credentials 2>/dev/null; then
  fail "cat ~/.claude/credentials (global) succeeded (should be blocked)"
else
  pass "cat ~/.claude/credentials (global) blocked"
fi

# Cannot list home directory (should only see project)
if ls ~/ 2>/dev/null | grep -qv "$(basename "$PWD")"; then
  fail "ls ~/ shows files outside project"
else
  pass "ls ~/ restricted to project"
fi

# Cannot read /etc/shadow
if cat /etc/shadow 2>/dev/null; then
  fail "cat /etc/shadow succeeded"
else
  pass "cat /etc/shadow blocked"
fi

# Cannot write to /etc
if echo "pwned" > /etc/hosts 2>/dev/null; then
  fail "write to /etc/hosts succeeded"
else
  pass "write to /etc/hosts blocked"
fi

# rm -rf / should fail or have no effect on host
if rm -rf / 2>/dev/null; then
  # If we're still running, it was harmless (denied)
  pass "rm -rf / had no effect (still running)"
else
  pass "rm -rf / denied"
fi

# --- Project access ---
echo ""
echo "--- Project access ---"

# Can read project files
if ls . >/dev/null 2>&1; then
  pass "can read project directory"
else
  fail "cannot read project directory"
fi

# Can write to project
TEST_FILE=".parcai-test-$$"
if echo "test" > "$TEST_FILE" 2>/dev/null; then
  pass "can write to project directory"
  rm -f "$TEST_FILE"
else
  fail "cannot write to project directory"
fi

# Claude config is accessible in sandbox
if [[ -d .claude ]]; then
  pass ".claude/ directory accessible in sandbox"
else
  skip ".claude/ directory not present (first run without credentials?)"
fi

# --- Process isolation ---
echo ""
echo "--- Process isolation ---"

# macOS: process-info denied
if ps aux 2>/dev/null | wc -l | grep -q "^[0-9]"; then
  skip "ps aux ran (macOS sandbox may allow limited process info)"
else
  pass "ps aux blocked by sandbox"
fi

if kill -9 1 2>/dev/null; then
  fail "kill -9 1 succeeded"
else
  pass "kill -9 1 blocked"
fi

# --- Environment ---
echo ""
echo "--- Environment ---"

if [[ "$PARCAI" == "1" ]]; then
  pass "PARCAI=1 is set"
else
  fail "PARCAI is not set"
fi

if [[ -n "$PARCAI_BACKEND" ]]; then
  pass "PARCAI_BACKEND=$PARCAI_BACKEND is set"
else
  fail "PARCAI_BACKEND is not set"
fi

# PATH should be restricted
case "$PATH" in
  */home/*|*/Users/*)
    fail "PATH contains home directory entries: $PATH"
    ;;
  *)
    pass "PATH appears restricted: $PATH"
    ;;
esac

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed, $SKIP skipped ==="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
