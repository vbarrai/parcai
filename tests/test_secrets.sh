#!/bin/bash
# test_secrets.sh — Verifies real secrets never appear in sandbox
# Run this INSIDE a parcai shell started with --secrets

set -uo pipefail

PASS=0
FAIL=0
SKIP=0

pass() { echo "  PASS: $1"; ((PASS++)); }
fail() { echo "  FAIL: $1"; ((FAIL++)); }
skip() { echo "  SKIP: $1"; ((SKIP++)); }

echo "=== parcai secrets masking tests ==="
echo ""

if [[ "${PARCAI:-}" != "1" ]]; then
  echo "ERROR: not running inside parcai sandbox. Run 'parcai --secrets <file>' first."
  exit 1
fi

# --- .env contains only fake tokens ---
echo "--- Fake token format ---"

if [[ ! -f .env ]]; then
  echo "ERROR: no .env file found. Was --secrets used?"
  exit 1
fi

# Check that all values match fake_parcai_* pattern
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
  if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    if [[ "$value" =~ ^fake_parcai_ ]]; then
      pass "$key has fake token format"
    else
      fail "$key has unexpected value: $value (expected fake_parcai_*)"
    fi
  fi
done < .env

# --- Environment variables contain only fake tokens ---
echo ""
echo "--- Environment variables ---"

# Check common secret env var names
for var in OPENAI_API_KEY DATABASE_URL AWS_SECRET_ACCESS_KEY AWS_ACCESS_KEY_ID; do
  val="${!var:-}"
  if [[ -z "$val" ]]; then
    skip "$var not set"
  elif [[ "$val" =~ ^fake_parcai_ ]]; then
    pass "$var contains fake token"
  else
    fail "$var contains unexpected value (not fake_parcai_*)"
  fi
done

# --- No real-looking secrets in environment ---
echo ""
echo "--- Scanning environment for real secrets ---"

# Check for common real secret patterns
LEAKED=false
while IFS='=' read -r key value; do
  # Skip parcai internal vars
  [[ "$key" =~ ^PARCAI ]] && continue
  [[ "$key" =~ ^(PATH|HOME|PWD|OLDPWD|SHLVL|TERM|SHELL|USER|LOGNAME|LANG|LC_)$ ]] && continue

  # Check for real-looking API keys
  if [[ "$value" =~ ^sk- ]] || [[ "$value" =~ ^pk- ]] || \
     [[ "$value" =~ ^ghp_ ]] || [[ "$value" =~ ^gho_ ]] || \
     [[ "$value" =~ ^AKIA ]] || [[ "$value" =~ ^xoxb- ]] || \
     [[ "$value" =~ ^xoxp- ]]; then
    fail "possible real secret found in $key"
    LEAKED=true
  fi
done < <(env)

if ! $LEAKED; then
  pass "no real-looking secrets found in environment"
fi

# --- Proxy is configured ---
echo ""
echo "--- Proxy configuration ---"

if [[ -n "${HTTPS_PROXY:-}" ]]; then
  pass "HTTPS_PROXY is set: $HTTPS_PROXY"
else
  skip "HTTPS_PROXY not set (proxy may not be running)"
fi

if [[ -n "${HTTP_PROXY:-}" ]]; then
  pass "HTTP_PROXY is set: $HTTP_PROXY"
else
  skip "HTTP_PROXY not set"
fi

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed, $SKIP skipped ==="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
