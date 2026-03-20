(version 1)

;; ============================================================
;; START PERMISSIVE, THEN DENY DANGEROUS PATHS
;; This approach avoids silent hangs from missing permissions.
;; ============================================================
(allow default)

;; ============================================================
;; DENY: all of /Users (home directories)
;; ============================================================
(deny file-read* file-write*
  (subpath "/Users"))

;; ============================================================
;; ALLOW: project clone (read-write)
;; ============================================================
(allow file-read* file-write*
  (subpath "{{CLONE}}"))

;; ============================================================
;; ALLOW: Claude CLI — binary, config, state, cache
;; (read-write to real home so credentials persist)
;; ============================================================
(allow file-read* file-write* process-exec
  (subpath "{{HOME}}/.local")
  (subpath "{{HOME}}/.claude")
  (subpath "{{HOME}}/.config")
  (subpath "{{HOME}}/.cache")
  (subpath "{{HOME}}/Library"))

;; ============================================================
;; ALLOW: shell config (read-only)
;; ============================================================
(allow file-read*
  (literal "{{HOME}}/.zshrc")
  (literal "{{HOME}}/.zshenv")
  (literal "{{HOME}}/.zprofile")
  (literal "{{HOME}}/.bashrc")
  (literal "{{HOME}}/.bash_profile")
  (literal "{{HOME}}/.profile"))

;; ============================================================
;; DENY: sensitive secrets (overrides any allows above)
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
  (literal "{{HOME}}/.npmrc"))

;; ============================================================
;; NETWORK — {{NETWORK_RULE}}
;; ============================================================
{{NETWORK_POLICY}}
