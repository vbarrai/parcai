(version 1)

;; ============================================================
;; DENY EVERYTHING BY DEFAULT
;; ============================================================
(deny default)

;; ============================================================
;; PROCESS EXECUTION (restricted to system binaries + claude)
;; ============================================================
(allow process-exec
  (subpath "/usr/bin")
  (subpath "/bin")
  (subpath "/usr/sbin")
  (subpath "/sbin")
  (subpath "/opt/homebrew/bin")
  (subpath "/usr/local/bin")
{{CLAUDE_EXEC_RULE}})

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
;; FILESYSTEM — READ-ONLY ACCESS
;; ============================================================

;; Root directory (needed for path resolution)
(allow file-read* (literal "/"))

;; System paths
(allow file-read*
  (subpath "/usr")
  (subpath "/bin")
  (subpath "/sbin")
  (subpath "/Library")
  (subpath "/System")
  (subpath "/opt")
  (subpath "/etc")
  (subpath "/private/etc")
  (subpath "/private/var")
  (subpath "/var")
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

;; User home — broad read (claude needs symlink resolution, Library, etc.)
(allow file-read*
  (literal "/Users")
  (subpath "{{HOME}}"))

;; ============================================================
;; DENY sensitive paths explicitly (overrides the broad home read)
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

;; Temp + device write access
(allow file-write* (subpath "/private/tmp") (subpath "/tmp"))
(allow file-write* (literal "/dev/null") (literal "/dev/tty") (regex #"^/dev/ttys[0-9]+$"))

;; TTY access (needed for setRawMode / interactive terminal)
(allow file-ioctl
  (literal "/dev/tty")
  (regex #"^/dev/ttys[0-9]+$"))

;; ============================================================
;; PROCESS VISIBILITY — deny inspecting other processes
;; ============================================================
(deny process-info*)
(allow process-info* (target self))
(allow process-info-pidinfo (target self))
(allow process-info-pidfdinfo (target self))

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
