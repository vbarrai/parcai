(version 1)

;; ============================================================
;; DENY EVERYTHING BY DEFAULT
;; Whitelist only what Claude Code needs to function.
;; ============================================================
(deny default)

;; ============================================================
;; PROCESS — execution and lifecycle
;; ============================================================
(allow process-exec
  (subpath "/usr/bin")
  (subpath "/bin")
  (subpath "/usr/sbin")
  (subpath "/sbin")
  (subpath "/opt/homebrew")
  (subpath "/usr/local/bin")
  ;; Claude binary
  (subpath "{{HOME}}/.local")
  ;; Node.js (needed for MCP servers via npx)
  (subpath "{{HOME}}/.nvm"))

(allow process-fork)
(allow signal (target self))
(allow process-info* (target self))
(allow process-info-pidinfo)
(allow process-info-pidfdinfo)

;; ============================================================
;; FILESYSTEM — project clone (read-write)
;; ============================================================
(allow file-read* file-write*
  (subpath "{{CLONE}}"))

;; ============================================================
;; FILESYSTEM — Claude CLI state (read-write)
;; ============================================================
(allow file-read* file-write*
  (subpath "{{HOME}}/.claude")
  (subpath "{{HOME}}/.npm"))

;; ============================================================
;; FILESYSTEM — Claude binary + Node.js (read-only)
;; ============================================================
(allow file-read*
  (subpath "{{HOME}}/.local")
  (subpath "{{HOME}}/.nvm"))

;; ============================================================
;; FILESYSTEM — macOS Library (read-only, needed by Bun runtime)
;; ============================================================
(allow file-read*
  (subpath "{{HOME}}/Library"))

;; ============================================================
;; FILESYSTEM — shell config (read-only)
;; ============================================================
(allow file-read*
  (literal "{{HOME}}")
  (literal "{{HOME}}/.zshrc")
  (literal "{{HOME}}/.zshenv")
  (literal "{{HOME}}/.zprofile")
  (literal "{{HOME}}/.bashrc")
  (literal "{{HOME}}/.bash_profile")
  (literal "{{HOME}}/.profile"))

;; ============================================================
;; FILESYSTEM — system (read-only)
;; ============================================================
(allow file-read*
  (literal "/")
  (literal "/.file")
  (subpath "/usr")
  (subpath "/bin")
  (subpath "/sbin")
  (subpath "/System")
  (subpath "/Library")
  (subpath "/opt")
  (subpath "/etc")
  (subpath "/private")
  (subpath "/tmp")
  (subpath "/var")
  (subpath "/Applications")
  (subpath "/Volumes")
  (subpath "/cores"))

;; ============================================================
;; FILESYSTEM — devices
;; ============================================================
(allow file-read* file-write*
  (subpath "/dev"))

;; ============================================================
;; FILESYSTEM — temp directories (read-write)
;; ============================================================
(allow file-read* file-write*
  (subpath "/private/tmp")
  (subpath "/tmp")
  (subpath "/private/var/folders"))

;; ============================================================
;; DENY — sensitive secrets (overrides any allows above)
;; ============================================================
(deny file-read* file-write*
  (subpath "{{HOME}}/.ssh")
  (subpath "{{HOME}}/.aws")
  (subpath "{{HOME}}/.gnupg")
  (subpath "{{HOME}}/.config/gcloud")
  (subpath "{{HOME}}/.kube")
  (subpath "{{HOME}}/.docker")
  (literal "{{HOME}}/.env")
  (literal "{{HOME}}/.netrc")
  (literal "{{HOME}}/.npmrc")
  (literal "{{HOME}}/.zsh_history")
  (literal "{{HOME}}/.bash_history"))

;; ============================================================
;; NETWORK — {{NETWORK_RULE}}
;; ============================================================
{{NETWORK_POLICY}}

;; ============================================================
;; IPC — required for shell and Claude TUI
;; ============================================================
(allow ipc-posix-shm-read-data)
(allow ipc-posix-shm-write-data)
(allow ipc-posix-shm-write-create)
(allow mach-lookup)
(allow iokit-open)
(allow system-socket)

;; ============================================================
;; SYSCTL — read-only system info
;; ============================================================
(allow sysctl-read)
