;;; jsonyter-sync.el --- Bidirectional directory sync against a baseline -*- lexical-binding: t; -*-

;; Author: Ethan Guthrie
;; Assisted-by: Claude:claude-fable-5
;; Assisted-by: Claude:claude-sonnet-5
;; Keywords: languages, processes, jupyter
;; URL: https://github.com/EGuthrieWasTaken/jsonyter.el

;; Copyright (C) 2026 Ethan Guthrie

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Bidirectional directory sync against a baseline.  One part of jsonyter.el, which loads
;; every part; see jsonyter.el for the overview and the entry points.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'jsonyter-transfer)

(declare-function dired-current-directory "dired" (&optional localp))

;;;; Directory sync (see FEATURE-REQUEST-directory-sync.md)

(defcustom jsonyter-sync-pairs nil
  "Directory pairs `jsonyter-sync' and friends can reconcile.

Each entry is (LOCAL . REMOTE), or a plist for the fuller form:

    (:local \"~/project/data\" :remote \"work/data\"
     :server \"https://jupyter.example.org\"   ; nil = any server
     :conflict newest :delete none :ignore (\"*.tmp\"))

LOCAL is expanded with `expand-file-name'.  REMOTE is a Contents-API
path -- relative to the server's `root_dir', no leading slash -- not the
kernel's absolute working directory.  :conflict and :delete override
`jsonyter-sync-conflict-policy' and `jsonyter-sync-delete-policy' for
that pair alone; :ignore adds patterns on top of `jsonyter-sync-ignore'.

See `jsonyter-sync-add-pair' to define one interactively."
  :type '(repeat sexp)
  :group 'jsonyter)

(defcustom jsonyter-sync-conflict-policy 'ask
  "Default conflict policy for `jsonyter-sync' and `jsonyter-sync-status'.

One of `ask' (leave it for the plan buffer to resolve), `newest' (the
side with the later modification time wins, clock-skew corrected),
`local', `remote', or `skip'.  A pair's own :conflict overrides this.

`ask' is the default here even though the bridge's own non-interactive
`sync()' defaults to `newest' -- a script cannot answer a question, but
Emacs can, and putting the decision in front of whoever knows which edit
they meant to keep is the entire reason for a front end."
  :type '(choice (const ask) (const newest) (const local) (const remote)
                 (const skip))
  :group 'jsonyter)

(defcustom jsonyter-sync-delete-policy 'none
  "Default deletion policy for `jsonyter-sync' and friends.

One of `none' (never propagate a deletion), `push' (a local deletion
removes the remote copy), `pull' (a remote deletion removes the local
copy), or `both'.  A pair's own :delete overrides this.  Matches the
bridge's own default: deletion propagation is opt-in."
  :type '(choice (const none) (const push) (const pull) (const both))
  :group 'jsonyter)

(defcustom jsonyter-sync-ignore nil
  "Extra ignore patterns for every sync, added to the bridge's own
defaults (`.git/', `__pycache__/', `*.jsonyter-conflict-*' and so on)
and to a pair's own :ignore.  `fnmatch'-style; a trailing `/' prunes a
whole directory."
  :type '(repeat string)
  :group 'jsonyter)

(defcustom jsonyter-sync-review 'when-destructive
  "When `jsonyter-sync' shows the plan buffer before applying.

`always' shows it every time; `never' applies the plan (with any `ask'
conflicts left unresolved and therefore skipped) without ever showing
it; `when-destructive' (the default) shows it only when the plan would
delete something, resolve a conflict by overwriting the losing side, or
move more than `jsonyter-sync-review-threshold' files.  A prefix
argument to any sync command forces the buffer regardless."
  :type '(choice (const always) (const when-destructive) (const never))
  :group 'jsonyter)

(defcustom jsonyter-sync-review-threshold 10
  "Under `jsonyter-sync-review' `when-destructive', force review past this
many files moved, even with no conflict or deletion."
  :type 'integer
  :group 'jsonyter)

(defcustom jsonyter-sync-keep-conflict-copies t
  "Whether resolving a conflict renames the losing side aside first.

The loser is renamed to `NAME.jsonyter-conflict-TIMESTAMP' -- locally on
disk, or via `rename_contents' on the server -- rather than simply
overwritten, so a wrong guess is recoverable.  Conflict copies are
excluded from the next sync by the bridge's default ignore list."
  :type 'boolean
  :group 'jsonyter)

(defcustom jsonyter-sync-max-deletes 25
  "Refuse a sync plan that would delete more than this many files.
The signature of an unmounted local volume or a mistyped directory, not
of real intent."
  :type 'integer
  :group 'jsonyter)

(defcustom jsonyter-sync-state-directory nil
  "Directory holding sync baselines, or nil for the bridge's own XDG
default (`$XDG_STATE_HOME/jsonyter/sync/', falling back to
`~/.local/state/jsonyter/sync/').  Baseline filenames are a hash of the
server URL, remote directory and local directory, matching the bridge's
own `default_state_path' exactly, so `jsonyter-sync-reset-baseline' and
`jsonyter-sync-forget-pair' can find and remove one without a round trip."
  :type '(choice (const :tag "Bridge's XDG default" nil) directory)
  :group 'jsonyter)

(defcustom jsonyter-sync-diff-max-size (* 2 1024 1024)
  "Refuse \\[jsonyter-sync-diff-entry] on a file larger than this many
bytes.  Downloading and diffing a multi-hundred-megabyte file is rarely
what a `D' keypress meant."
  :type 'integer
  :group 'jsonyter)

(defcustom jsonyter-sync-diff-function nil
  "Function `jsonyter-sync-diff-entry' calls with two local file paths
\(the local copy, then the downloaded remote copy\), or nil to use
`ediff-files'."
  :type '(choice (const :tag "ediff-files" nil) function)
  :group 'jsonyter)

;;;; jsonyter-sync: bidirectional directory sync against a baseline

;; See FEATURE-REQUEST-directory-sync.md (this repo) for the design, and
;; the document of the same name in the `jsonyter' Python repo for the
;; protocol and the three-way comparison this is a front end for.  One
;; idea worth holding on to: the baseline -- a record of what local and
;; remote last agreed on -- is what lets a sync tell a routine one-sided
;; update apart from a genuine conflict.  The bridge owns hashing,
;; walking both trees and every byte that moves; this side owns the
;; pair, the review, and the reporting.

;;; Pairs (§3)

(defun jsonyter--sync-pair-plist (raw)
  "Normalize one `jsonyter-sync-pairs' entry RAW to a plist.
Accepts both the short `(LOCAL . REMOTE)' cons form and the full plist
form; a plist is returned unchanged."
  (if (and (stringp (car-safe raw)) (stringp (cdr-safe raw)))
      (list :local (car raw) :remote (cdr raw))
    raw))

(defun jsonyter--sync-clean-remote (path)
  "PATH with leading and trailing slashes stripped, mirroring the
bridge's own `_clean_remote' exactly -- so a baseline path hashed from
this matches the one the bridge computes."
  (replace-regexp-in-string
   "/+\\'" "" (replace-regexp-in-string "\\`/+" "" (or path ""))))

(defun jsonyter--sync-pair-local (pair)
  "PAIR's local directory, expanded and without a trailing slash."
  (directory-file-name (expand-file-name (plist-get pair :local))))

(defun jsonyter--sync-pair-remote (pair)
  "PAIR's remote (contents) directory, slashes stripped."
  (jsonyter--sync-clean-remote (plist-get pair :remote)))

(defun jsonyter--sync-pair-server (pair)
  "PAIR's :server, or nil for \"any server\"."
  (plist-get pair :server))

(defun jsonyter--sync-policy-string (value)
  "VALUE (a policy symbol or already a string) as a string for the wire."
  (if (symbolp value) (symbol-name value) value))

(defun jsonyter--sync-pair-conflict (pair)
  (jsonyter--sync-policy-string
   (or (plist-get pair :conflict) jsonyter-sync-conflict-policy)))

(defun jsonyter--sync-pair-delete (pair)
  (jsonyter--sync-policy-string
   (or (plist-get pair :delete) jsonyter-sync-delete-policy)))

(defun jsonyter--sync-pair-ignore (pair)
  (append (plist-get pair :ignore) jsonyter-sync-ignore))

(defun jsonyter--sync-server (context)
  "The actual server URL CONTEXT's bridge talks to."
  (or (buffer-local-value 'jsonyter--url (car context)) jsonyter-server-url))

(defun jsonyter--sync-invoking-directory ()
  "The local directory relevant to resolving a sync pair from this buffer."
  (require 'dired)
  (if (derived-mode-p 'dired-mode) (dired-current-directory) default-directory))

(defun jsonyter--sync-server-match-p (pair server)
  (let ((wanted (jsonyter--sync-pair-server pair)))
    (or (null wanted) (equal wanted server))))

(defun jsonyter--sync-local-match-p (pair dir)
  "T if PAIR's :local is DIR or one of DIR's parents."
  (string-prefix-p (file-name-as-directory (jsonyter--sync-pair-local pair))
                    (file-name-as-directory (expand-file-name dir))))

(defun jsonyter--sync-remote-match-p (pair remote)
  "T if PAIR's :remote is REMOTE or one of REMOTE's parents."
  (string-prefix-p (jsonyter--remote-dir-slash (jsonyter--sync-pair-remote pair))
                    (jsonyter--remote-dir-slash remote)))

(defun jsonyter--sync-most-specific (pairs key-fn)
  "The PAIRS entry whose KEY-FN is longest, or nil for an empty list."
  (car (sort (copy-sequence pairs)
             (lambda (a b) (> (length (funcall key-fn a)) (length (funcall key-fn b)))))))

(defun jsonyter--sync-step1 (pairs server)
  "Step 1 of §3.1: the most specific directory match for the current buffer."
  (if (derived-mode-p 'jsonyter-remote-dired-mode)
      (jsonyter--sync-most-specific
       (seq-filter (lambda (p) (and (jsonyter--sync-server-match-p p server)
                                    (jsonyter--sync-remote-match-p p jsonyter--remote-cwd)))
                   pairs)
       #'jsonyter--sync-pair-remote)
    (let ((dir (jsonyter--sync-invoking-directory)))
      (jsonyter--sync-most-specific
       (seq-filter (lambda (p) (and (jsonyter--sync-server-match-p p server)
                                    (jsonyter--sync-local-match-p p dir)))
                   pairs)
       #'jsonyter--sync-pair-local))))

(defun jsonyter--sync-read-pair (pairs)
  "`completing-read' among PAIRS, formatted as \"LOCAL <-> REMOTE\"."
  (let* ((labels (mapcar (lambda (p) (format "%s <-> %s"
                                             (jsonyter--sync-pair-local p)
                                             (jsonyter--sync-pair-remote p)))
                         pairs))
         (choice (completing-read "Sync pair: " labels nil t)))
    (nth (or (cl-position choice labels :test #'equal) 0) pairs)))

(defun jsonyter--sync-ensure-pair (context server)
  "No configured pair matched; offer to create and optionally persist one.
Seeded from the invoking buffer's directory and the kernel-cwd probe
\(§3.1 step 4\), so the common case is confirming two prompts with the
remote path already filled in."
  (let* ((buffer (car context))
         (session (cdr context))
         (local (jsonyter--sync-invoking-directory))
         (probe (with-current-buffer buffer
                  (jsonyter--transfer-remote-dir buffer session))))
    (unless (y-or-n-p (format "jsonyter: no sync pair covers %s -- create one? " local))
      (user-error "jsonyter: no sync pair to use"))
    (let* ((remote (jsonyter--read-remote-path
                    buffer "Remote (contents) directory" probe t))
           (pair (list :local local :remote (jsonyter--sync-clean-remote remote)
                       :server server)))
      (push pair jsonyter-sync-pairs)
      (when (y-or-n-p "Persist this pair to `jsonyter-sync-pairs'? ")
        (customize-save-variable 'jsonyter-sync-pairs jsonyter-sync-pairs))
      pair)))

(defun jsonyter--sync-resolve-pair (context)
  "Return the `jsonyter-sync-pairs' plist a sync command should use.
See `jsonyter-sync-pairs' and the design doc §3.1 for the order: the most
specific directory match, else the sole pair on this server, else a
choice among several, else an offer to create one."
  (let* ((server (jsonyter--sync-server context))
         (pairs (mapcar #'jsonyter--sync-pair-plist jsonyter-sync-pairs))
         (by-server (seq-filter (lambda (p) (jsonyter--sync-server-match-p p server)) pairs)))
    (or (jsonyter--sync-step1 pairs server)
        (and (= (length by-server) 1) (car by-server))
        (and (> (length by-server) 1) (jsonyter--sync-read-pair by-server))
        (jsonyter--sync-ensure-pair context server))))

;;; Baselines (bridge §5.1) -- located without a round trip

(defun jsonyter--sync-state-dir ()
  "Directory holding sync baselines: `jsonyter-sync-state-directory', or
the bridge's own XDG default."
  (or jsonyter-sync-state-directory
      (expand-file-name "jsonyter/sync"
                        (or (getenv "XDG_STATE_HOME") "~/.local/state"))))

(defun jsonyter--sync-state-path (server pair)
  "The baseline file PAIR would use on SERVER, matching the bridge's own
`default_state_path' hash exactly: sha256 of \"SERVER\\0REMOTE\\0LOCAL\",
first 16 hex characters, `.json'."
  (let* ((local (jsonyter--sync-pair-local pair))
         (remote (jsonyter--sync-pair-remote pair))
         (key (concat server "\0" remote "\0" local))
         (digest (substring (secure-hash 'sha256 key) 0 16)))
    (expand-file-name (concat digest ".json") (jsonyter--sync-state-dir))))

(defun jsonyter--sync-baseline-server (pair)
  "The server URL to use for PAIR's baseline.
PAIR's own :server when it names one; otherwise the current context's --
which may require a live jsonyter session, but only when PAIR is
ambiguous about which server it means."
  (or (jsonyter--sync-pair-server pair)
      (jsonyter--sync-server (jsonyter--resolve-transfer-context))))

(defun jsonyter--sync-delete-baseline (server pair)
  "Delete PAIR's baseline file on SERVER, if one is on record."
  (let ((path (jsonyter--sync-state-path server pair)))
    (if (file-exists-p path)
        (progn (delete-file path) (message "jsonyter: deleted baseline %s" path))
      (message "jsonyter: no baseline on record for %s <-> %s"
               (jsonyter--sync-pair-local pair) (jsonyter--sync-pair-remote pair)))))

;;; Reshaping a plan for the wire (bridge §8.1)

;; `jsonyter--dispatch' parses every reply with `:array-type \\='list' and
;; `:null-object nil', which is fine for the flat results every other
;; command returns but loses two distinctions a plan needs back: the
;; native `json-serialize' cannot tell a plain list apart from a
;; malformed plist (so `entries', an array of objects, must become a
;; vector again before `sync_apply' can be sent), and it cannot tell
;; nil-as-null apart from nil-as-empty-object (so a field the schema
;; defines as "a value, or null" -- never as {} or [] -- must have its
;; nil explicitly re-marked `:null').  Every field this touches is one of
;; those two kinds; nothing here is a guess about the schema.

(defun jsonyter--sync-nullify (value)
  "VALUE for the wire: Lisp nil becomes JSON null."
  (if (null value) :null value))

(defun jsonyter--sync-side-for-wire (side)
  "A plan entry's `:local' or `:remote' sub-object for the wire, or :null."
  (if (null side)
      :null
    (list :size (jsonyter--sync-nullify (plist-get side :size))
          :hash (jsonyter--sync-nullify (plist-get side :hash))
          :mtime (jsonyter--sync-nullify (plist-get side :mtime)))))

(defun jsonyter--sync-entry-for-wire (entry)
  "One `sync_plan' ENTRY reshaped for the wire."
  (list :path (plist-get entry :path)
        :action (plist-get entry :action)
        :reason (plist-get entry :reason)
        :local (jsonyter--sync-side-for-wire (plist-get entry :local))
        :remote (jsonyter--sync-side-for-wire (plist-get entry :remote))
        :baseline_hash (jsonyter--sync-nullify (plist-get entry :baseline_hash))
        :bytes (or (plist-get entry :bytes) 0)
        :resolution (jsonyter--sync-nullify (plist-get entry :resolution))
        :newest (jsonyter--sync-nullify (plist-get entry :newest))
        :mtime_delta (jsonyter--sync-nullify (plist-get entry :mtime_delta))))

(defun jsonyter--sync-plan-for-wire (plan)
  "PLAN as returned by `sync_plan', reshaped so `json-serialize' can send
it back unchanged as `sync_apply''s `:plan' parameter."
  (list :local_dir (plist-get plan :local_dir)
        :remote_dir (plist-get plan :remote_dir)
        :server (plist-get plan :server)
        :hash_algorithm (plist-get plan :hash_algorithm)
        :integrity (plist-get plan :integrity)
        :baseline (plist-get plan :baseline)
        :clock_skew (jsonyter--sync-nullify (plist-get plan :clock_skew))
        :conflict_policy (plist-get plan :conflict_policy)
        :delete_policy (plist-get plan :delete_policy)
        :scanned (plist-get plan :scanned)
        :entries (vconcat (mapcar #'jsonyter--sync-entry-for-wire
                                  (plist-get plan :entries)))
        :totals (plist-get plan :totals)
        :warnings (vconcat (plist-get plan :warnings))
        :state_path (plist-get plan :state_path)))

(defun jsonyter--sync-overrides-table (overrides)
  "OVERRIDES (an alist of PATH . ACTION) as a hash table for the wire --
`json-serialize' needs a string-keyed JSON object as a hash table, not
an alist, whose keys it requires to be symbols."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (cell overrides) (puthash (car cell) (cdr cell) table))
    table))

;;; Sending a sync request, with progress (§7)

(defun jsonyter--sync-progress-message (ev)
  "Echo-area text for a sync/scan progress event EV (bridge §11.1)."
  (pcase (plist-get ev :phase)
    ("scan"
     (format "jsonyter: scanning the %s..."
             (if (equal (plist-get ev :op) "remote") "server" "local directory")))
    ("sync"
     (format "jsonyter: %s %s (%s/%s) — %s / %s"
             (if (equal (plist-get ev :op) "pull") "pulling" "pushing")
             (file-name-nondirectory
              (directory-file-name (or (plist-get ev :path) (plist-get ev :local_path) "?")))
             (or (plist-get ev :file_index) "?") (or (plist-get ev :files_total) "?")
             (jsonyter--human-size (plist-get ev :bytes_done))
             (jsonyter--human-size (plist-get ev :bytes_total))))
    (_ "")))

(defun jsonyter--sync-tag (ev)
  "The `transfer' slot plist to show in the mode line for progress EV."
  (append (list :phase "sync")
          (and (equal (plist-get ev :phase) "sync")
               (list :file_index (plist-get ev :file_index)
                     :files_total (plist-get ev :files_total)))))

(defun jsonyter--sync-run (context method params on-result)
  "Send sync METHOD (sync_plan/sync_apply/sync/sync_status) with PARAMS
through CONTEXT, asynchronously -- like `jsonyter--transfer-run', but for
the sync verbs: a `:sync' mode-line tag (bare during the scan phase,
`:sync I/N' once files start moving) instead of a percentage.  ON-RESULT
is called with (ERROR-PLIST-OR-NIL RESULT-PLIST-OR-NIL).  Returns the
request id, so a caller can record it for `jsonyter-sync-abort'."
  (let* ((buffer (car context))
         (session (cdr context))
         id)
    (with-current-buffer buffer
      (when session
        (setf (jsonyter--session-transfer session) (list :phase "sync"))
        (force-mode-line-update t))
      (condition-case err
          (progn
            (setq id
                  (jsonyter--send
                   method params
                   (list
                    :progress
                    (lambda (ev)
                      (let ((text (jsonyter--sync-progress-message ev)))
                        (unless (string-empty-p text) (message "%s" text)))
                      (when session
                        (setf (jsonyter--session-transfer session)
                              (append (jsonyter--sync-tag ev) (list :request-id id)))
                        (force-mode-line-update t)))
                    :result
                    (lambda (msg)
                      (when session
                        (setf (jsonyter--session-transfer session) nil)
                        (force-mode-line-update t))
                      (funcall on-result (plist-get msg :error) (plist-get msg :result))))))
            (when session
              (setf (jsonyter--session-transfer session) (list :phase "sync" :request-id id))
              (force-mode-line-update t))
            id)
        (error
         (when session
           (setf (jsonyter--session-transfer session) nil)
           (force-mode-line-update t))
         (signal (car err) (cdr err)))))))

(defvar jsonyter--sync-integrity-warned (make-hash-table :test #'equal)
  "Servers already warned about size-only sync integrity this session.
Global rather than per-buffer or per-pair: the warning is about the
server, not about any one sync of it, and firing every time would be a
warning nobody reads.")

(defun jsonyter--sync-note-integrity (pair plan)
  "Warn once per server when PLAN's integrity degraded to size-only."
  (when (equal (plist-get plan :integrity) "size")
    (let ((server (or (plist-get plan :server) (jsonyter--sync-pair-server pair)
                      jsonyter-server-url)))
      (unless (gethash server jsonyter--sync-integrity-warned)
        (puthash server t jsonyter--sync-integrity-warned)
        (message "jsonyter: %s verifies sync by size only, not sha256 -- it predates jupyter_server 2.11 and does not return content hashes, so a same-size edit cannot be detected"
                 server)))))

;;; Deciding whether to review, and building requests

(defun jsonyter--sync-destructive-p (plan)
  "T if PLAN would delete anything, resolves a conflict by overwriting
the losing side, or moves more than `jsonyter-sync-review-threshold'
files -- the trigger for `jsonyter-sync-review' `when-destructive'."
  (let* ((totals (plist-get plan :totals))
         (deletes (+ (or (plist-get totals :push_delete) 0)
                    (or (plist-get totals :pull_delete) 0)))
         (moved (+ (or (plist-get totals :push) 0) (or (plist-get totals :pull) 0) deletes)))
    (or (> deletes 0)
        (> moved jsonyter-sync-review-threshold)
        (seq-some (lambda (e) (member (plist-get e :resolution)
                                      '("push" "pull" "push-delete" "pull-delete")))
                  (plist-get plan :entries)))))

(defun jsonyter--sync-should-review-p (plan force)
  (or force
      (pcase jsonyter-sync-review
        ('always t)
        ('never nil)
        (_ (jsonyter--sync-destructive-p plan)))))

(defun jsonyter--sync-plan-params (pair context &optional conflict-override)
  "The `sync_plan' PARAMS for PAIR, resolved against CONTEXT's server.
CONFLICT-OVERRIDE (a string) replaces the pair's own conflict policy for
this call only -- how `jsonyter-sync-push'/`jsonyter-sync-pull' work."
  (let* ((local (jsonyter--sync-pair-local pair))
         (remote (jsonyter--sync-pair-remote pair))
         (server (jsonyter--sync-server context))
         (ignore (jsonyter--sync-pair-ignore pair))
         (state-path (and jsonyter-sync-state-directory
                         (jsonyter--sync-state-path server pair))))
    (append
     (list :local_dir local :remote_dir remote
          :conflict (or conflict-override (jsonyter--sync-pair-conflict pair))
          :delete (jsonyter--sync-pair-delete pair)
          :max_deletes jsonyter-sync-max-deletes)
     (and ignore (list :ignore (vconcat ignore)))
     (and state-path (list :state_path state-path)))))

(defun jsonyter--sync-apply-params (plan &optional overrides)
  (append (list :plan (jsonyter--sync-plan-for-wire plan))
          (and overrides (list :overrides (jsonyter--sync-overrides-table overrides)))
          (list :keep_conflict_copies (if jsonyter-sync-keep-conflict-copies t :false))))

;;; Reporting (§8)

(defun jsonyter--sync-log (pair result)
  "Append RESULT's per-file detail to `*jsonyter-sync-log*', newest first."
  (with-current-buffer (get-buffer-create "*jsonyter-sync-log*")
    (goto-char (point-min))
    (insert (format "=== %s <-> %s -- %s ===\n"
                    (jsonyter--sync-pair-local pair) (jsonyter--sync-pair-remote pair)
                    (format-time-string "%Y-%m-%d %H:%M:%S")))
    (dolist (f (append (plist-get result :failed) nil))
      (insert (format "FAILED  %s -- %s\n" (plist-get f :path) (plist-get f :error))))
    (dolist (c (append (plist-get result :conflict_copies) nil))
      (insert (format "COPY    %s\n" c)))
    (insert (format "moved: %S\n\n" (plist-get result :moved)))))

(defun jsonyter--sync-report (pair result started)
  "Announce a finished sync: what moved, what did not, and the recovery
for anything left unresolved or failed."
  (jsonyter--sync-log pair result)
  (let* ((moved (plist-get result :moved))
         (pushed (or (plist-get moved :pushed) 0))
         (pulled (or (plist-get moved :pulled) 0))
         (converged (or (plist-get moved :converged) 0))
         (deleted (+ (or (plist-get moved :deleted_local) 0)
                    (or (plist-get moved :deleted_remote) 0)))
         (bytes-up (or (plist-get result :bytes_up) 0))
         (bytes-down (or (plist-get result :bytes_down) 0))
         (conflicts (or (plist-get result :conflicts_unresolved) 0))
         (failed (append (plist-get result :failed) nil))
         (cancelled (eq (plist-get result :cancelled) t))
         (elapsed (or (plist-get result :elapsed)
                     (and started (- (float-time) started)) 0))
         (moved-total (+ pushed pulled deleted))
         (where (format "%s <-> %s" (jsonyter--sync-pair-local pair)
                       (jsonyter--sync-pair-remote pair))))
    (cond
     (failed
      (message "jsonyter: synced %s — %d moved (%s up, %s down) and failed on %d: %s [see *jsonyter-sync-log*]"
               where moved-total (jsonyter--human-size bytes-up) (jsonyter--human-size bytes-down)
               (length failed)
               (mapconcat (lambda (f) (format "%s (%s)" (plist-get f :path) (plist-get f :error)))
                         failed "; ")))
     ((> conflicts 0)
      (message "jsonyter: synced %s — %d moved; %d conflict%s left unresolved [M-x jsonyter-sync-status to resolve]"
               where moved-total conflicts (if (= conflicts 1) "" "s")))
     (cancelled
      (message "jsonyter: sync of %s stopped early — %d file%s synced before you stopped; re-run to continue"
               where moved-total (if (= moved-total 1) "" "s")))
     (t
      (message "jsonyter: synced %s — %d up (%s), %d down (%s)%s%s, %s, %ds"
               where pushed (jsonyter--human-size bytes-up) pulled (jsonyter--human-size bytes-down)
               (if (> converged 0) (format ", %d converged" converged) "")
               (if (> deleted 0) (format ", %d deleted" deleted) "")
               (jsonyter--transfer-verified-phrase (plist-get result :integrity))
               (round elapsed))))))

;;; The plan buffer: `jsonyter-sync-mode' (§6)

(defface jsonyter-sync-push-face '((t :inherit success))
  "Face for a row in `jsonyter-sync-mode' that will push (local wins)."
  :group 'jsonyter)
(defface jsonyter-sync-pull-face '((t :inherit font-lock-constant-face))
  "Face for a row in `jsonyter-sync-mode' that will pull (remote wins)."
  :group 'jsonyter)
(defface jsonyter-sync-conflict-face '((t :inherit warning))
  "Face for an unresolved conflict row in `jsonyter-sync-mode'."
  :group 'jsonyter)
(defface jsonyter-sync-delete-face '((t :inherit error))
  "Face for a row in `jsonyter-sync-mode' that deletes a copy, either direction."
  :group 'jsonyter)
(defface jsonyter-sync-unchanged-face '((t :inherit shadow))
  "Face for an unchanged, converged, or skipped row in `jsonyter-sync-mode'."
  :group 'jsonyter)

(defvar-local jsonyter--sync-owner nil
  "The bridge-owning jsonyter buffer this sync buffer issues requests through.")
(defvar-local jsonyter--sync-session-key nil
  "Session key (LANGUAGE . NAME) in `jsonyter--sync-owner', or nil.")
(defvar-local jsonyter--sync-pair nil
  "The `jsonyter-sync-pairs' plist this buffer is reconciling.")
(defvar-local jsonyter--sync-conflict-override nil
  "\"local\"/\"remote\"/nil: the forced conflict policy from
`jsonyter-sync-push'/`jsonyter-sync-pull', carried across `g' re-plans.")
(defvar-local jsonyter--sync-plan nil
  "The last `sync_plan' result plist shown in this buffer.")
(defvar-local jsonyter--sync-overrides nil
  "Alist of PATH . ACTION overrides set from this buffer, per entry.")
(defvar-local jsonyter--sync-show-unchanged nil
  "Whether unchanged (`=') rows are shown; toggled by \\[jsonyter-sync-toggle-unchanged].")
(defvar-local jsonyter--sync-entries-by-path nil
  "Hash of path -> plan entry for this buffer's current plan.")

(defvar jsonyter-sync-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'jsonyter-sync-describe-entry)
    (define-key map (kbd ">")   #'jsonyter-sync-override-push)
    (define-key map (kbd "<")   #'jsonyter-sync-override-pull)
    (define-key map (kbd "d")   #'jsonyter-sync-override-delete)
    (define-key map (kbd "k")   #'jsonyter-sync-override-skip)
    (define-key map (kbd "n")   #'jsonyter-sync-resolve-newest)
    (define-key map (kbd "N")   #'jsonyter-sync-resolve-other)
    (define-key map (kbd "u")   #'jsonyter-sync-clear-override)
    (define-key map (kbd "U")   #'jsonyter-sync-clear-all-overrides)
    (define-key map (kbd "g")   #'jsonyter-sync-replan)
    (define-key map (kbd "T")   #'jsonyter-sync-toggle-unchanged)
    (define-key map (kbd "D")   #'jsonyter-sync-diff-entry)
    (define-key map (kbd "x")   #'jsonyter-sync-execute)
    (define-key map (kbd "q")   #'quit-window)
    map)
  "Keymap for `jsonyter-sync-mode'.")

(define-derived-mode jsonyter-sync-mode tabulated-list-mode "Jsonyter-Sync"
  "Review and apply a directory-sync plan (`sync_plan'/`sync_apply').

Every row is one relative path; the glyph column says what will happen
to it: `>' push, `<' pull, `!' unresolved conflict, `=' already
identical, `>D'/`<D' delete on that side, `x' skipped.  `x' is the only
key in this buffer that writes anything.

\\{jsonyter-sync-mode-map}"
  (setq tabulated-list-format [("" 3 nil)
                              ("File" 36 t)
                              ("Size" 9 nil :right-align t)
                              ("Local" 12 nil)
                              ("Remote" 12 nil)
                              ("Note" 0 nil)]
        tabulated-list-sort-key nil)
  (setq-local revert-buffer-function (lambda (&rest _) (jsonyter-sync-replan)))
  (tabulated-list-init-header))

(defun jsonyter--sync-glyph (action)
  "The (GLYPH . FACE) `jsonyter-sync-mode' shows for ACTION."
  (pcase action
    ("push" (cons ">" 'jsonyter-sync-push-face))
    ("pull" (cons "<" 'jsonyter-sync-pull-face))
    ("conflict" (cons "!" 'jsonyter-sync-conflict-face))
    ("converge" (cons "=" 'jsonyter-sync-unchanged-face))
    ("skip" (cons "x" 'jsonyter-sync-unchanged-face))
    ("push-delete" (cons ">D" 'jsonyter-sync-delete-face))
    ("pull-delete" (cons "<D" 'jsonyter-sync-delete-face))
    ("forget" (cons "." 'jsonyter-sync-unchanged-face))
    (_ (cons "?" 'default))))

(defun jsonyter--sync-same-day-p (a b)
  (let ((da (decode-time a)) (db (decode-time b)))
    (equal (list (nth 3 da) (nth 4 da) (nth 5 da))
          (list (nth 3 db) (nth 4 db) (nth 5 db)))))

(defun jsonyter--sync-format-local-mtime (epoch)
  "EPOCH (a float seconds-since-epoch, or nil) as a short local timestamp."
  (if (null epoch) "--"
    (format-time-string
     (if (jsonyter--sync-same-day-p epoch (float-time)) "%H:%M" "%m-%d %H:%M")
     epoch)))

(defun jsonyter--sync-format-remote-mtime (ts)
  "TS (an ISO-8601 string, or nil) as a short local timestamp."
  (if (not (stringp ts)) "--"
    (let ((time (ignore-errors (encode-time (iso8601-parse ts)))))
      (if time (jsonyter--sync-format-local-mtime (float-time time)) ts))))

(defun jsonyter--sync-format-duration (seconds)
  (cond ((< seconds 60) (format "%ds" (round seconds)))
        ((< seconds 3600) (format "%dm" (round (/ seconds 60))))
        (t (format "%.1fh" (/ seconds 3600.0)))))

(defun jsonyter--sync-note (entry)
  "A short free-text annotation for ENTRY, for the Note column."
  (let ((action (plist-get entry :action))
        (reason (plist-get entry :reason))
        (newest (plist-get entry :newest))
        (delta (plist-get entry :mtime_delta)))
    (cond
     ((equal action "conflict")
      (if newest
          (format "both changed; %s newer by %s" newest
                  (jsonyter--sync-format-duration (abs (or delta 0))))
        "both changed; too close to call"))
     ((equal reason "local-missing") "remote only -- not pulled")
     ((equal reason "remote-missing") "local only -- not pushed")
     ((member reason '("local-new" "remote-new")) "new")
     (t ""))))

(defun jsonyter--sync-entries (plan overrides show-unchanged)
  "`tabulated-list-entries' for PLAN, OVERRIDES and SHOW-UNCHANGED.
Pure -- no I/O -- so it is unit-testable directly against a fabricated
plan.  Hides converge/unchanged-skip rows unless SHOW-UNCHANGED; a
missing-side skip (the other side has this and the delete policy will
not remove it) always shows, since that is exactly what relying on the
default policy needs to surface."
  (let (out)
    (dolist (entry (plist-get plan :entries))
      (let* ((path (plist-get entry :path))
             (override (cdr (assoc path overrides)))
             (action (or override (plist-get entry :action))))
        (unless (and (not show-unchanged) (null override)
                    (or (equal action "converge")
                        (and (equal action "skip")
                             (equal (plist-get entry :reason) "unchanged"))))
          (let* ((glyph (jsonyter--sync-glyph action))
                 (local (plist-get entry :local))
                 (remote (plist-get entry :remote))
                 (size (cond ((equal action "push") (and local (plist-get local :size)))
                            ((equal action "pull") (and remote (plist-get remote :size)))
                            (t nil))))
            (push (list path
                       (vector (propertize (car glyph) 'face (cdr glyph))
                               path
                               (if size (jsonyter--human-size size) "")
                               (jsonyter--sync-format-local-mtime (and local (plist-get local :mtime)))
                               (jsonyter--sync-format-remote-mtime (and remote (plist-get remote :mtime)))
                               (concat (jsonyter--sync-note entry)
                                       (if override " (overridden)" ""))))
                 out)))))
    (nreverse out)))

(defun jsonyter--sync-header-line (pair plan overrides)
  (if (null plan)
      (format "  %s <-> %s  (no plan yet -- g to plan)"
             (jsonyter--sync-pair-local pair) (jsonyter--sync-pair-remote pair))
    (let* ((totals (plist-get plan :totals))
           (deletes (+ (or (plist-get totals :push_delete) 0)
                      (or (plist-get totals :pull_delete) 0))))
      (format "  %s <-> %s on %s   %d to transfer (%s up, %s down) · %d conflict%s · %d unchanged%s%s"
             (jsonyter--sync-pair-local pair) (jsonyter--sync-pair-remote pair)
             (or (plist-get plan :server) "?")
             (+ (or (plist-get totals :push) 0) (or (plist-get totals :pull) 0))
             (jsonyter--human-size (or (plist-get totals :bytes_up) 0))
             (jsonyter--human-size (or (plist-get totals :bytes_down) 0))
             (or (plist-get totals :conflict) 0)
             (if (equal (plist-get totals :conflict) 1) "" "s")
             (+ (or (plist-get totals :skip) 0) (or (plist-get totals :converge) 0))
             (if (> deletes 0) (format " · %d to delete" deletes) "")
             (if overrides (format " · %d overridden" (length overrides)) "")))))

(defun jsonyter--sync-render ()
  "Rebuild this `jsonyter-sync-mode' buffer's rows from its current plan,
overrides and unchanged-visibility toggle."
  (setq jsonyter--sync-entries-by-path (make-hash-table :test #'equal))
  (dolist (entry (plist-get jsonyter--sync-plan :entries))
    (puthash (plist-get entry :path) entry jsonyter--sync-entries-by-path))
  (setq tabulated-list-entries
        (jsonyter--sync-entries jsonyter--sync-plan jsonyter--sync-overrides
                                jsonyter--sync-show-unchanged))
  (setq-local header-line-format
              (jsonyter--sync-header-line jsonyter--sync-pair jsonyter--sync-plan
                                          jsonyter--sync-overrides))
  (tabulated-list-print t))

(defun jsonyter--sync-entry-at-point ()
  (let ((id (tabulated-list-get-id)))
    (and id jsonyter--sync-entries-by-path (gethash id jsonyter--sync-entries-by-path))))

(defun jsonyter--sync-set-override (path action)
  "Set PATH's override to ACTION, or clear it when ACTION is the plan's
own action for PATH -- so the alist handed to `sync_apply' only ever
contains genuine overrides."
  (let ((entry (gethash path jsonyter--sync-entries-by-path)))
    (setq jsonyter--sync-overrides (assoc-delete-all path jsonyter--sync-overrides))
    (unless (equal action (and entry (plist-get entry :action)))
      (push (cons path action) jsonyter--sync-overrides))))

(defun jsonyter--sync-override-direction (action)
  (let ((entry (jsonyter--sync-entry-at-point)))
    (unless entry (user-error "jsonyter: no entry here"))
    (jsonyter--sync-set-override (plist-get entry :path) action)
    (jsonyter--sync-render)
    (forward-line 1)))

(defun jsonyter-sync-override-push ()
  "Override the entry at point: local wins."
  (interactive)
  (jsonyter--sync-override-direction "push"))

(defun jsonyter-sync-override-pull ()
  "Override the entry at point: remote wins."
  (interactive)
  (jsonyter--sync-override-direction "pull"))

(defun jsonyter-sync-override-skip ()
  "Override the entry at point to be left alone."
  (interactive)
  (jsonyter--sync-override-direction "skip"))

(defun jsonyter-sync-override-delete ()
  "Override the entry at point to delete a copy instead of moving one.
Deletes the only side that exists when just one does; on a two-sided
conflict, asks which copy to delete."
  (interactive)
  (let* ((entry (jsonyter--sync-entry-at-point))
         (has-local (and entry (plist-get entry :local)))
         (has-remote (and entry (plist-get entry :remote))))
    (unless entry (user-error "jsonyter: no entry here"))
    (let ((action
           (cond
            ((and has-local (not has-remote)) "pull-delete")
            ((and has-remote (not has-local)) "push-delete")
            ((and has-local has-remote)
             (pcase (read-char-choice "Delete which copy? (l)ocal (r)emote: " '(?l ?r))
               (?l "pull-delete") (?r "push-delete")))
            (t (user-error "jsonyter: %s exists on neither side" (plist-get entry :path))))))
      (jsonyter--sync-set-override (plist-get entry :path) action)
      (jsonyter--sync-render)
      (forward-line 1))))

(defun jsonyter--sync-resolve-by-newest (other)
  "Set an override at point from the entry's precomputed `:newest' side.
With OTHER, pick the side that is NOT newest instead -- for when you
know better than the clock did."
  (let* ((entry (jsonyter--sync-entry-at-point))
         (newest (and entry (plist-get entry :newest))))
    (unless entry (user-error "jsonyter: no entry here"))
    (unless newest
      (user-error "jsonyter: no newest side recorded for %s -- resolve it with > or < instead"
                  (plist-get entry :path)))
    (let* ((side (if other (if (equal newest "remote") "local" "remote") newest))
           (has-local (plist-get entry :local))
           (has-remote (plist-get entry :remote))
           (action (if (equal side "local")
                      (if has-local "push" "push-delete")
                    (if has-remote "pull" "pull-delete"))))
      (jsonyter--sync-set-override (plist-get entry :path) action)
      (jsonyter--sync-render)
      (forward-line 1))))

(defun jsonyter-sync-resolve-newest ()
  "Resolve the conflict at point in favor of whichever side is newer."
  (interactive)
  (jsonyter--sync-resolve-by-newest nil))

(defun jsonyter-sync-resolve-other ()
  "Resolve the conflict at point in favor of whichever side is NOT newer."
  (interactive)
  (jsonyter--sync-resolve-by-newest t))

(defun jsonyter-sync-clear-override ()
  "Clear any override on the entry at point, reverting it to the plan's own action."
  (interactive)
  (let ((entry (jsonyter--sync-entry-at-point)))
    (unless entry (user-error "jsonyter: no entry here"))
    (setq jsonyter--sync-overrides
          (assoc-delete-all (plist-get entry :path) jsonyter--sync-overrides))
    (jsonyter--sync-render)
    (forward-line 1)))

(defun jsonyter-sync-clear-all-overrides ()
  "Clear every override in this buffer."
  (interactive)
  (setq jsonyter--sync-overrides nil)
  (jsonyter--sync-render)
  (message "jsonyter: all overrides cleared"))

(defun jsonyter-sync-toggle-unchanged ()
  "Toggle whether unchanged (`=') rows are shown."
  (interactive)
  (setq jsonyter--sync-show-unchanged (not jsonyter--sync-show-unchanged))
  (jsonyter--sync-render))

(defun jsonyter-sync-describe-entry ()
  "Show what the plan knows about the entry at point: both hashes, both
mtimes, the baseline, and why it was classified the way it was."
  (interactive)
  (let ((entry (jsonyter--sync-entry-at-point)))
    (unless entry (user-error "jsonyter: no entry here"))
    (let* ((local (plist-get entry :local))
           (remote (plist-get entry :remote))
           (override (cdr (assoc (plist-get entry :path) jsonyter--sync-overrides))))
      (message "%s: %s/%s%s -- local %s (%s), remote %s (%s), baseline %s%s"
               (plist-get entry :path) (plist-get entry :action) (plist-get entry :reason)
               (if override (format " [override: %s]" override) "")
               (if local (jsonyter--human-size (plist-get local :size)) "absent")
               (or (plist-get local :hash) "unhashed")
               (if remote (jsonyter--human-size (plist-get remote :size)) "absent")
               (or (plist-get remote :hash) "unhashed")
               (or (plist-get entry :baseline_hash) "none")
               (if (plist-get entry :newest)
                   (format ", %s newer by %s" (plist-get entry :newest)
                          (jsonyter--sync-format-duration
                           (abs (or (plist-get entry :mtime_delta) 0))))
                 "")))))

(defun jsonyter-sync-diff-entry ()
  "Diff the entry at point's local and remote copies.
Downloads the remote copy to a temp file via the ordinary `download'
transfer, then hands both paths to `jsonyter-sync-diff-function' (default
`ediff-files').  Refuses anything over `jsonyter-sync-diff-max-size'."
  (interactive)
  (let* ((entry (jsonyter--sync-entry-at-point))
         (path (and entry (plist-get entry :path)))
         (local-side (and entry (plist-get entry :local)))
         (remote-side (and entry (plist-get entry :remote))))
    (unless entry (user-error "jsonyter: no entry here"))
    (unless (and local-side remote-side)
      (user-error "jsonyter: %s does not exist on both sides -- nothing to diff" path))
    (let ((lsize (plist-get local-side :size))
          (rsize (plist-get remote-side :size)))
      (when (or (and lsize (> lsize jsonyter-sync-diff-max-size))
               (and rsize (> rsize jsonyter-sync-diff-max-size)))
        (user-error "jsonyter: %s is larger than `jsonyter-sync-diff-max-size' (%s) -- refusing to diff"
                    path (jsonyter--human-size jsonyter-sync-diff-max-size))))
    (let* ((pair jsonyter--sync-pair)
           (owner jsonyter--sync-owner)
           (session (and jsonyter--sync-session-key
                        (with-current-buffer owner (jsonyter--session jsonyter--sync-session-key))))
           (local-full (expand-file-name path (jsonyter--sync-pair-local pair)))
           (remote-dir (jsonyter--sync-pair-remote pair))
           (remote-full (if (string-empty-p remote-dir) path (concat remote-dir "/" path)))
           (tmp (make-temp-file "jsonyter-sync-diff-" nil
                                (concat "." (or (file-name-extension path) "txt")))))
      (unless (buffer-live-p owner) (user-error "jsonyter: this sync buffer's session is gone"))
      (jsonyter--transfer-run
       (cons owner session) "download"
       (list :remote_path remote-full :local_path tmp :overwrite t)
       (lambda (_result)
         (funcall (or jsonyter-sync-diff-function #'ediff-files) local-full tmp))))))

(defun jsonyter-sync-replan ()
  "Re-run `sync_plan' for this buffer's pair; the trees may have moved.
Clears overrides -- a path's row may not mean the same thing against a
fresh plan, and carrying a stale override forward risks acting on a file
that has since changed again."
  (interactive)
  (let* ((pair jsonyter--sync-pair)
         (owner jsonyter--sync-owner)
         (conflict-override jsonyter--sync-conflict-override))
    (unless (buffer-live-p owner) (user-error "jsonyter: this sync buffer's session is gone"))
    (let* ((session (and jsonyter--sync-session-key
                        (with-current-buffer owner (jsonyter--session jsonyter--sync-session-key))))
           (context (cons owner session))
           (buf (current-buffer)))
      (setq jsonyter--sync-overrides nil)
      (message "jsonyter: re-planning %s <-> %s..."
               (jsonyter--sync-pair-local pair) (jsonyter--sync-pair-remote pair))
      (jsonyter--sync-run
       context "sync_plan" (jsonyter--sync-plan-params pair context conflict-override)
       (lambda (err result)
         (if err
             (message "jsonyter: sync-plan of %s failed — %s"
                     (jsonyter--sync-pair-local pair) (jsonyter--error-message err))
           (jsonyter--sync-note-integrity pair result)
           (when (buffer-live-p buf)
             (with-current-buffer buf
               (setq jsonyter--sync-plan result)
               (jsonyter--sync-render)))))))))

(defun jsonyter-sync-execute ()
  "Apply this plan: send `sync_apply' with the current overrides.
The only key in this buffer that writes anything.  Confirms first with a
one-line summary naming the counts, and the deletion count separately."
  (interactive)
  (let* ((plan jsonyter--sync-plan)
         (pair jsonyter--sync-pair)
         (owner jsonyter--sync-owner))
    (unless plan (user-error "jsonyter: no plan to apply -- g to plan first"))
    (unless (buffer-live-p owner) (user-error "jsonyter: this sync buffer's session is gone"))
    (let* ((totals (plist-get plan :totals))
           (deletes (+ (or (plist-get totals :push_delete) 0) (or (plist-get totals :pull_delete) 0)))
           (moved (+ (or (plist-get totals :push) 0) (or (plist-get totals :pull) 0)))
           (n-overrides (length jsonyter--sync-overrides)))
      (if (= (+ moved deletes) 0)
          (when (= n-overrides 0)
            (unless (y-or-n-p "jsonyter: this plan moves nothing -- apply anyway? ")
              (user-error "jsonyter: nothing to do")))
        (unless (y-or-n-p
                 (format "jsonyter: apply this sync (%d file%s%s%s)? "
                        (+ moved deletes) (if (= (+ moved deletes) 1) "" "s")
                        (if (> deletes 0) (format ", %d deletion%s" deletes (if (= deletes 1) "" "s")) "")
                        (if (> n-overrides 0) (format ", %d overridden" n-overrides) "")))
          (user-error "jsonyter: aborted")))
      (let* ((session (and jsonyter--sync-session-key
                          (with-current-buffer owner (jsonyter--session jsonyter--sync-session-key))))
             (context (cons owner session))
             (started (float-time))
             (buf (current-buffer)))
        (jsonyter--sync-run
         context "sync_apply" (jsonyter--sync-apply-params plan jsonyter--sync-overrides)
         (lambda (err result)
           (if err
               (message "jsonyter: sync of %s <-> %s failed — %s"
                       (jsonyter--sync-pair-local pair) (jsonyter--sync-pair-remote pair)
                       (jsonyter--error-message err))
             (jsonyter--sync-report pair result started)
             (when (buffer-live-p buf) (with-current-buffer buf (jsonyter-sync-replan))))))))))

;;; Commands (§5)

(defun jsonyter--sync-open-buffer (context pair conflict-override plan)
  "Create or reuse the `jsonyter-sync-mode' buffer for PAIR and show PLAN."
  (let* ((buffer (car context))
         (session (cdr context))
         (name (format "*jsonyter-sync: %s <-> %s*"
                      (jsonyter--sync-pair-local pair) (jsonyter--sync-pair-remote pair)))
         (buf (get-buffer-create name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'jsonyter-sync-mode) (jsonyter-sync-mode))
      (setq jsonyter--sync-owner buffer
            jsonyter--sync-session-key (and session (jsonyter--session-key session))
            jsonyter--sync-pair pair
            jsonyter--sync-conflict-override conflict-override
            jsonyter--sync-plan plan
            jsonyter--sync-overrides nil)
      (jsonyter--sync-render))
    (pop-to-buffer buf)))

(defun jsonyter--sync-command (force conflict-override verb)
  "Shared engine for `jsonyter-sync', `-status', `-push' and `-pull'.
VERB is `sync' (plan, then review-or-apply) or `status' (plan, always
review, never auto-apply).  CONFLICT-OVERRIDE forces `sync_plan''s
`conflict' to \"local\"/\"remote\"; nil uses the pair's own policy.
FORCE (a prefix argument) shows the plan buffer regardless of
`jsonyter-sync-review'."
  (let* ((context (jsonyter--resolve-transfer-context))
         (session (cdr context))
         (busy (and session (jsonyter--session-transfer session))))
    (cond
     ((and busy (equal (plist-get busy :phase) "sync"))
      (if (y-or-n-p "jsonyter: a sync is already running for this session -- abort it? ")
          (jsonyter-sync-abort)
        (user-error "jsonyter: not starting a second sync")))
     (busy
      (user-error "jsonyter: this session is busy with a %s -- try again once it finishes"
                  (plist-get busy :phase)))
     (t
      (let* ((pair (jsonyter--sync-resolve-pair context))
             (params (jsonyter--sync-plan-params pair context conflict-override)))
        (message "jsonyter: planning %s <-> %s..."
                 (jsonyter--sync-pair-local pair) (jsonyter--sync-pair-remote pair))
        (jsonyter--sync-run
         context "sync_plan" params
         (lambda (err plan)
           (if err
               (message "jsonyter: sync-plan of %s failed — %s"
                       (jsonyter--sync-pair-local pair) (jsonyter--error-message err))
             (jsonyter--sync-note-integrity pair plan)
             (if (or (eq verb 'status) (jsonyter--sync-should-review-p plan force))
                 (jsonyter--sync-open-buffer context pair conflict-override plan)
               (let ((started (float-time)))
                 (jsonyter--sync-run
                  context "sync_apply" (jsonyter--sync-apply-params plan)
                  (lambda (aerr aresult)
                    (if aerr
                        (message "jsonyter: sync of %s <-> %s failed — %s"
                                (jsonyter--sync-pair-local pair) (jsonyter--sync-pair-remote pair)
                                (jsonyter--error-message aerr))
                      (jsonyter--sync-report pair aresult started))))))))))))))

;;;###autoload
(defun jsonyter-sync (&optional force)
  "Reconcile the current sync pair: plan it, review if warranted, apply.
See `jsonyter-sync-pairs' for how the pair is chosen and
`jsonyter-sync-review' for when the plan buffer is shown.  FORCE (a
prefix argument) shows it regardless."
  (interactive "P")
  (jsonyter--sync-command force nil 'sync))

;;;###autoload
(defun jsonyter-sync-status (&optional force)
  "Plan the current sync pair and show it; never applies anything.
The read-only \"what would change?\" verb -- see `jsonyter-sync' to
actually reconcile."
  (interactive "P")
  (jsonyter--sync-command force nil 'status))

;;;###autoload
(defun jsonyter-sync-push (&optional force)
  "Reconcile the current sync pair with local winning every conflict.
Not \"upload the tree\": unchanged files are still skipped, ignores
still apply, and nothing is deleted unless the delete policy says so --
only a genuine conflict is forced, to local."
  (interactive "P")
  (jsonyter--sync-command force "local" 'sync))

;;;###autoload
(defun jsonyter-sync-pull (&optional force)
  "Reconcile the current sync pair with remote winning every conflict.
See `jsonyter-sync-push'; the same, mirrored."
  (interactive "P")
  (jsonyter--sync-command force "remote" 'sync))

;;;###autoload
(defun jsonyter-sync-abort ()
  "Stop the sync running for the current session after the current file.
The bridge writes the baseline for everything that completed and
returns normally with a cancelled result -- a partial sync is a valid
one, and re-running resumes naturally."
  (interactive)
  (let* ((context (jsonyter--resolve-transfer-context))
         (buffer (car context))
         (session (cdr context))
         (transfer (and session (jsonyter--session-transfer session))))
    (unless (and transfer (equal (plist-get transfer :phase) "sync"))
      (user-error "jsonyter: no sync in progress for this session"))
    (let ((id (plist-get transfer :request-id)))
      (unless id (user-error "jsonyter: no request id recorded for the running sync"))
      (with-current-buffer buffer (jsonyter--send "cancel_sync" (list :request_id id)))
      (message "jsonyter: sync-abort requested -- it will stop after the current file"))))

(defun jsonyter--sync-ensure-local-dir (dir)
  "Create the local directory DIR, parents included, if it is missing.
Return t when it was created, nil when it already existed."
  (if (file-directory-p dir)
      nil
    (progn
      (make-directory dir t)
      t)))

(defun jsonyter--sync-ensure-remote-dir (buffer remote)
  "Create each missing level of REMOTE on BUFFER's server, outermost first.
REMOTE is a Contents-API directory path such as \"work/new/deep\";
surrounding slashes are ignored (see `jsonyter--sync-clean-remote').
The server's `make_directory' makes exactly one level, so each level is
created in turn and only when it does not already exist.  Signal a
`user-error' when a level exists but is not a directory.  Return the
list of paths created, in order, or nil when everything already existed
or REMOTE is empty."
  (let ((prefix nil) (created nil))
    (dolist (part (split-string (jsonyter--sync-clean-remote remote) "/" t))
      (setq prefix (if prefix (concat prefix "/" part) part))
      (let ((model (condition-case nil
                       (with-current-buffer buffer
                         (jsonyter--request-sync "list_contents" (list :path prefix)))
                       (error 'missing))))
        (cond
         ((eq model 'missing)
          (with-current-buffer buffer
            (jsonyter--request-sync "make_directory" (list :path prefix)))
          (push prefix created))
         ((not (equal (plist-get model :type) "directory"))
          (user-error "jsonyter: %s exists on the server and is not a directory" prefix)))))
    (nreverse created)))

;;;###autoload
(defun jsonyter-sync-add-pair (local remote &optional server persist create-dirs)
  "Define a sync pair between LOCAL and REMOTE, added to `jsonyter-sync-pairs'.
Interactively, REMOTE defaults to this session's current browser
directory (the same kernel-cwd probe transfer commands use) and PERSIST
asks whether to save it now via `customize-save-variable'; a Lisp caller
gets a session-local pair unless PERSIST is non-nil.

With CREATE-DIRS (always when called interactively) a missing LOCAL or
REMOTE directory is created, parents included, before the pair is
recorded.  A REMOTE path that exists but is a file signals a
`user-error', and nothing is recorded."
  (interactive
   (let* ((context (jsonyter--resolve-transfer-context))
          (buffer (car context))
          (session (cdr context))
          (local (expand-file-name
                  (read-directory-name "Local directory: "
                                       (jsonyter--sync-invoking-directory))))
          (remote-default (with-current-buffer buffer
                            (jsonyter--transfer-remote-dir buffer session)))
          (remote (jsonyter--read-remote-path
                   buffer "Remote (contents) directory" remote-default t)))
     (list local (jsonyter--sync-clean-remote remote)
           (buffer-local-value 'jsonyter--url buffer)
           (y-or-n-p "Persist to `jsonyter-sync-pairs' via customize-save-variable? ")
           t)))
  (let ((pair (list :local local :remote remote :server server)))
    (when create-dirs
      (when (jsonyter--sync-ensure-local-dir local)
        (message "jsonyter: created local directory %s" local))
      (unless (string-empty-p (jsonyter--sync-clean-remote remote))
        (dolist (path (jsonyter--sync-ensure-remote-dir
                       (car (jsonyter--resolve-transfer-context)) remote))
          (message "jsonyter: created remote directory %s" path))))
    (push pair jsonyter-sync-pairs)
    (when persist (customize-save-variable 'jsonyter-sync-pairs jsonyter-sync-pairs))
    (message "jsonyter: added sync pair %s <-> %s%s" local remote
             (if persist "" " (session-local only; not persisted)"))
    pair))

;;;###autoload
(defun jsonyter-sync-forget-pair (pair &optional delete-baseline)
  "Drop PAIR from `jsonyter-sync-pairs', optionally deleting its baseline.
Interactively PAIR is read among the configured pairs."
  (interactive
   (let ((pairs (mapcar #'jsonyter--sync-pair-plist jsonyter-sync-pairs)))
     (unless pairs (user-error "jsonyter: no sync pairs configured"))
     (list (jsonyter--sync-read-pair pairs)
           (y-or-n-p "Also delete its baseline (next sync starts fresh)? "))))
  (setq jsonyter-sync-pairs
        (seq-remove (lambda (raw) (equal (jsonyter--sync-pair-plist raw) pair))
                    jsonyter-sync-pairs))
  (when (y-or-n-p "Persist this removal via customize-save-variable? ")
    (customize-save-variable 'jsonyter-sync-pairs jsonyter-sync-pairs))
  (when delete-baseline
    (jsonyter--sync-delete-baseline (jsonyter--sync-baseline-server pair) pair))
  (message "jsonyter: forgot sync pair %s <-> %s"
           (jsonyter--sync-pair-local pair) (jsonyter--sync-pair-remote pair)))

;;;###autoload
(defun jsonyter-sync-reset-baseline ()
  "Discard the current sync pair's baseline; the next sync is a first sync.
The baseline is disposable by design -- this is the supported recovery,
not folklore about deleting a JSON file under `~/.local/state' by hand."
  (interactive)
  (let* ((context (jsonyter--resolve-transfer-context))
         (pair (jsonyter--sync-resolve-pair context)))
    (when (y-or-n-p (format "Discard the baseline for %s <-> %s? "
                            (jsonyter--sync-pair-local pair) (jsonyter--sync-pair-remote pair)))
      (jsonyter--sync-delete-baseline (jsonyter--sync-baseline-server pair) pair))))

(provide 'jsonyter-sync)
;;; jsonyter-sync.el ends here
