(version 1)

;; ============================================================
;; DENY EVERYTHING BY DEFAULT
;; ============================================================
(deny default)

;; ============================================================
;; PROCESS EXECUTION (restricted to system binaries only)
;; ============================================================
(allow process-exec
  (subpath "/usr/bin")
  (subpath "/bin")
  (subpath "/usr/sbin")
  (subpath "/sbin")
  (subpath "/opt/homebrew/bin")
  (subpath "/usr/local/bin"))

(allow process-fork)
(allow signal (target self))

;; ============================================================
;; FILESYSTEM — WRITE ACCESS (clone directory only)
;; ============================================================
(allow file-read* file-write* file-write-data file-write-flags
       file-write-mode file-write-owner file-write-setugid
       file-write-times file-write-unlink
  (subpath "{{CLONE}}"))

;; ============================================================
;; FILESYSTEM — READ-ONLY ACCESS (minimal system paths)
;; ============================================================
(allow file-read*
  (subpath "/usr/lib")
  (subpath "/usr/bin")
  (subpath "/bin")
  (subpath "/usr/sbin")
  (subpath "/sbin")
  (subpath "/Library/Frameworks")
  (subpath "/System")
  (subpath "/opt/homebrew")
  (subpath "/usr/local")
  (subpath "/etc")
  (subpath "/private/etc")
  (subpath "/var/select")
  (subpath "/private/var/select")
  (subpath "/private/tmp")
  (subpath "/tmp")
  (literal "/dev/null")
  (literal "/dev/zero")
  (literal "/dev/random")
  (literal "/dev/urandom")
  (literal "/dev/tty")
  (regex #"^/dev/ttys[0-9]+$")
  (literal "/dev/fd")
  (subpath "/dev/fd"))

;; Shell config (read-only, so prompt works)
(allow file-read*
  (literal "{{HOME}}/.zshrc")
  (literal "{{HOME}}/.zshenv")
  (literal "{{HOME}}/.zprofile")
  (literal "{{HOME}}/.bashrc")
  (literal "{{HOME}}/.bash_profile")
  (literal "{{HOME}}/.profile"))

;; NOTE: {{HOME}}/.claude is NOT whitelisted here.
;; Claude config is injected into the clone at {{CLONE}}/.claude/
;; and persisted to ~/.parcai/sessions/<hash>/claude-config/ on exit.

;; ============================================================
;; DENY sensitive paths explicitly (belt + suspenders)
;; ============================================================
(deny file-read* file-write*
  (subpath "{{HOME}}/.ssh")
  (subpath "{{HOME}}/.aws")
  (subpath "{{HOME}}/.gnupg")
  (subpath "{{HOME}}/.config/gcloud")
  (subpath "{{HOME}}/.kube")
  (subpath "{{HOME}}/.docker")
  (subpath "{{HOME}}/.claude")
  (subpath "{{HOME}}/Documents")
  (subpath "{{HOME}}/Desktop")
  (subpath "{{HOME}}/Downloads")
  (literal "{{HOME}}/.env")
  (literal "{{HOME}}/.netrc")
  (literal "{{HOME}}/.npmrc"))

;; ============================================================
;; PROCESS VISIBILITY — deny inspecting other processes
;; ============================================================
(deny process-info*)
(allow process-info* (target self))
(allow process-info-pidinfo)
(allow process-info-pidfdinfo)

;; ============================================================
;; NETWORK
;; {{NETWORK_RULE}} (allowed by default / denied with --no-network)
;; ============================================================
{{NETWORK_POLICY}}

;; Secret proxy loopback — present only when --secrets is active
;; Allows Claude to reach parcai-proxy on localhost regardless of --no-network
{{PROXY_LOOPBACK_RULE}}

;; ============================================================
;; IPC — minimal for shell operation
;; ============================================================
(allow ipc-posix-shm-read-data)
(allow ipc-posix-shm-write-data)
(allow mach-lookup)

;; ============================================================
;; SYSCTL — read-only system info
;; ============================================================
(allow sysctl-read)
