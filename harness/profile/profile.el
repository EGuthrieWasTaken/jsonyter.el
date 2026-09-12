;;; profile.el --- the jsonyter.el harness manifest -*- lexical-binding: t; -*-

;; The declarative half of the profile (emacs-harness DESIGN.md 8.4):
;; what `eh snapshot' reports without being asked, what `eh wait NAME'
;; can wait for, and what gets swept into a failure bundle.
;;
;; Loaded from `init.el', not by the harness core.  Skipping that load is
;; a silent trap: every session still starts with no error, but none of
;; the waiters below register, and `eh wait jsonyter-idle' then fails
;; with "no such waiter" forever.

(eh-defprofile jsonyter
  :package-path "/srv/package"
  :requires (jsonyter)
  :emacs-versions ("27.1" "28.2" "29.4" "30.2")
  :services ()                          ; the fake bridge is a subprocess,
                                        ; not a service to bring up
  :geometry (1280 . 800)

  ;; The properties every jsonyter buffer's structure is carried in.
  ;; Reported by default so a snapshot of a notebook or a REPL is
  ;; readable without knowing to ask for them.
  :snapshot-props (jsonyter-cell jsonyter-cell-id jsonyter-cell-type
                   jsonyter-source-end jsonyter-source-hash
                   jsonyter-output-stale jsonyter-exec-count
                   jsonyter-output-string jsonyter-raw-outputs
                   jsonyter-script-cell jsonyter-org-cell
                   jsonyter-org-committed jsonyter-running
                   read-only)

  ;; Named waiters.  Every one of these is a state a kernel or a
  ;; subprocess reaches asynchronously, which is to say every one of them
  ;; is a place a fixed sleep would eventually fail in CI.
  ;; State waiters compare against a live kernel's exact mode-line tag,
  ;; which includes `jy-harness-kernel-id-suffix' once one is running
  ;; (`jsonyter-mode-line-show-kernel-id' is on by default) -- see its
  ;; docstring in init.el.
  :waiters ((jsonyter-bridge-live   . (lambda () (jy-harness--bridge-live-p)))
            (jsonyter-kernel-live   . (lambda () (jy-harness--kernel-live-p)))
            (jsonyter-idle          . (lambda () (jy-harness--state-p (concat ":idle" jy-harness-kernel-id-suffix))))
            (jsonyter-running       . (lambda () (jy-harness--state-p (concat ":run" jy-harness-kernel-id-suffix))))
            (jsonyter-dead          . (lambda () (jy-harness--state-p (concat ":dead" jy-harness-kernel-id-suffix))))
            (jsonyter-offline       . (lambda () (jy-harness--state-p (concat ":offline" jy-harness-kernel-id-suffix))))
            (jsonyter-external-busy . (lambda () (jy-harness--state-p (concat ":run[ext]" jy-harness-kernel-id-suffix))))
            (jsonyter-settled       . (lambda () (jy-harness--settled-p))))

  ;; The bridge's stderr is a hidden buffer on purpose -- jsonyter's
  ;; claim is that a Python warning on it can never corrupt the protocol
  ;; on stdout -- so a failure bundle that omits it omits the one place
  ;; the reason usually is.
  :log-buffers (" *jsonyter stderr*" "*Messages*"))
