# TODO — Prioritized Backlog

## P0 — Bugs (fix before release)

### ~~Proxy failure leaves fake .env without translation~~ DONE
Originals are now backed up before masking and restored if proxy fails to start.

### ~~Broad home read — missing deny rules~~ DONE
Expanded deny list to cover: cloud providers (gcloud, gh, azure, oci, terraform), package managers (cargo, npm, bun, nvm, pyenv, gem, m2, gradle), personal folders (Pictures, Movies, Music), shell history files (.zsh_history, .bash_history, .node_repl_history, .python_history, .psql_history, etc.), git credentials, and common project directories (~/Workspace, ~/Projects, ~/repos, ~/src, ~/code, ~/dev).

### ~~SPEC.md session persistence section is outdated~~ DONE
Rewritten to document ~/.parcai/claude-home/ model.

---

## P1 — Security hardening

### ~~PARCAI_HOST_CWD leaks host path info~~ DONE
Now exposes only the basename (project name), not the full absolute path.

### ~~Domain filtering is env-var only — not enforced~~ DONE
Domain filtering is now enforced at the proxy level. `--allowed-domains` and `--blocked-domains` are passed to the proxy, which rejects HTTP 403 / CONNECT 403 for non-matching domains. Subdomain matching is supported (blocking `evil.com` also blocks `sub.evil.com`). Blocked requests are logged in the audit log with `proto: "http:blocked"` or `"https:blocked"`.

### Proxy should validate upstream TLS certificates
**File:** `proxy/parcai-proxy`
**Problem:** `rejectUnauthorized: true` is set (good), but no certificate pinning. A compromised DNS could redirect API calls to a malicious server.
**Fix:** Low priority — standard TLS validation is sufficient for the threat model.

---

## P2 — Robustness

### ~~Proxy buffers entire response body in memory~~ DONE
Added 50MB size limit to collectBody(). Responses exceeding the limit are streamed directly without token replacement.

### ~~Proxy temp file cleanup on crash~~ DONE
Startup routine removes stale /tmp/parcai-leaf-* and /tmp/parcai-ca-* files from previous crashed runs.

### ~~Session hash collision~~ DONE
Increased from 12 chars to 20 chars (2^80 combinations).

### JSON config parsing fragility
**File:** `parcai:82-105`
**Problem:** sed-based JSON parsing. Doesn't handle: escaped quotes in strings, nested objects. `.parcai.json` is user-controlled so not a security risk, but could cause confusing errors.
**Fix:** Consider shipping a minimal JSON parser or requiring `jq` as optional dependency.

---

## P3 — Features & improvements

### ~~SSE streaming support in proxy~~ DONE
SSE responses (Content-Type: text/event-stream) are now streamed line-by-line through a Transform stream with token replacement, instead of being buffered.

### ~~Add `--deny` flag for additional deny paths~~ DONE
`--deny <path>` flag (repeatable) and `deny` array in `.parcai.json` append deny rules to the sandbox profile.

### Run proxy tests in CI
**Problem:** `test_secrets.sh` verifies the env/files but doesn't test the actual proxy MITM flow.
**Fix:** Add integration test that starts proxy, sends request with fake token, verifies real token reaches upstream.

### Homebrew formula needs update for proxy
**File:** `SPEC.md:469-489`
**Problem:** Homebrew formula only installs the `parcai` script. Needs to also install `proxy/parcai-proxy` and ensure Node.js is available.
**Fix:** Update formula to install proxy script and add Node.js as dependency.

---

## P4 — Documentation

### ~~Document the deny list gap (readable home dirs)~~ DONE
Added "What remains readable" section to SPEC.md explaining the broad home read and how to add custom deny rules.

### ~~Add troubleshooting section to README~~ DONE
Added table with 6 common errors and their solutions.
