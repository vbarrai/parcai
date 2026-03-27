# parcai test examples

This directory contains fake credentials for testing parcai's secret masking.

**None of these are real credentials.** They are safe to commit.

## Usage

```bash
cd examples

# Test with default .env auto-detection
parcai --shell

# Inside the sandbox, verify secrets are masked:
cat .env              # should show fake_parcai_* tokens
env | grep API_KEY    # should show fake_parcai_* tokens

# Test with multiple files
parcai --secrets .env --secrets .env.prod --shell

# Test with the .parcai.json config (masks .env + .env.local)
parcai --shell

# Test with domain filtering
parcai --shell  # then edit .parcai.json to add allowed_domains
```

## Files

| File | Purpose |
|------|---------|
| `.env` | Main secrets file (10 keys) — auto-detected by parcai |
| `.env.local` | Local overrides (3 keys) — test multi-file masking |
| `.env.prod` | Production-like secrets (4 keys) — test explicit `--secrets` |
| `.parcai.json` | Config that masks `.env` + `.env.local` with audit logging |
