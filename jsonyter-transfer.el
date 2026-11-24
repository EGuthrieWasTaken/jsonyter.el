;;; jsonyter-transfer.el --- File transfer to and from the Jupyter server -*- lexical-binding: t; -*-

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

;; File transfer to and from the Jupyter server.  One part of jsonyter.el, which loads
;; every part; see jsonyter.el for the overview and the entry points.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'jsonyter-core)
(require 'jsonyter-attach)
(require 'jsonyter-notebook)

;;;; File transfer

;; The pipeline `jupyter server <-> jsonyter <-> Emacs' moves code and
;; notebook source freely; this section adds the missing leg -- data
;; files, in either direction, without dropping out to scp or the
;; JupyterLab UI.  The heavy lifting (chunking, hashing, file I/O) is the
;; bridge's; Emacs only issues the request and renders progress.
;;
;; The one idea to hold on to: a *remote path here is a Contents-API
;; path*.  POSIX-style, relative to the server's `root_dir', no leading
;; slash.  It is not the kernel's absolute cwd, and the two must never be
;; silently interchanged -- every prompt says "Remote (contents) path".
;; The bridge's `kernel_contents_dir' probe learns the mapping so an
;; "upload here" default can be right; when it cannot (a kernel outside
;; `root_dir'), the default is simply absent rather than a guess, and
;; `jsonyter-remote-root' is the manual override.

(require 'tabulated-list)

;; Defined in other parts of the package, which load after this one.
(declare-function jsonyter--export-run "jsonyter-export")
(declare-function jsonyter--export-format-guess-extension "jsonyter-export")
(declare-function jsonyter--export-format-names "jsonyter-export")
(declare-function jsonyter--list-export-formats "jsonyter-export")
(declare-function jsonyter-sync "jsonyter-sync")
(declare-function jsonyter-sync-status "jsonyter-sync")

(declare-function dired-get-filename "dired"
                  (&optional localp no-error-if-not-filep))
(declare-function dired-get-marked-files "dired"
                  (&optional localp arg filter distinguish-one-marked error))
(declare-function dired-marker-regexp "dired" ())
(defvar dired-mode-map)

;;; Small helpers

(defun jsonyter--human-size (n)
  "N bytes as a short human string: `184.3 MB', `412.0 KB', `0 B'.
Mirrors the bridge's own formatting so a size shown here and one quoted
in a bridge error read alike."
  (cond
   ((null n) "unknown size")
   ((< n 1024) (format "%d B" n))
   (t (let ((x (float n)) (out nil))
        (dolist (unit '("KB" "MB" "GB" "TB"))
          (unless out
            (setq x (/ x 1024.0))
            (when (or (< x 1024) (equal unit "TB"))
              (setq out (format "%.1f %s" x unit)))))
        out))))

(defun jsonyter--remote-dir-slash (path)
  "PATH as a Contents-API directory: no leading slash, trailing slash unless empty."
  (let ((p (replace-regexp-in-string "\\`/+" "" (or path ""))))
    (cond ((string-empty-p p) "")
          ((string-suffix-p "/" p) p)
          (t (concat p "/")))))

(defun jsonyter--remote-dir-parent (path)
  "The parent of Contents-API directory PATH, or \"\" at the root."
  (let ((p (directory-file-name (jsonyter--remote-dir-slash path))))
    (if (string-match "\\`\\(.*/\\)[^/]+\\'" p)
        (match-string 1 p)
      "")))

(defun jsonyter--transfer-verified-phrase (verified)
  "A words-not-jargon rendering of a transfer result's VERIFIED field."
  (pcase verified
    ("sha256" "sha256 verified")
    ("size" "size verified only")
    (_ "unverified")))

;;; Resolving a transfer context: a bridge-owning buffer, and maybe a session

;; A transfer runs REST-only, so it needs a buffer with a live bridge to
;; issue it through; a session on top of that supplies the kernel for the
;; contents-path probe, the sticky browser directory, and the mode-line
;; tag.  Commands invoked from a jsonyter buffer use its own; invoked
;; from a `dired' buffer or bare `M-x', they resolve the one live
;; jsonyter session, or prompt among several.

(defvar-local jsonyter--last-failed-transfer nil
  "Plist (:method :params) of the last transfer that failed in this buffer.
Buffer-local to the bridge-owning buffer.  `jsonyter-resume-upload' and
`jsonyter-resume-download' re-issue it with `resume' set; cleared on any
transfer that then succeeds.")

;; State a `jsonyter-remote-dired' buffer carries.  Declared up here
;; because `jsonyter--resolve-transfer-context' reads the first two to
;; recover a remote browser's origin session.
(defvar-local jsonyter--remote-owner nil
  "The bridge-owning jsonyter buffer this remote browser issues requests through.")
(defvar-local jsonyter--remote-session-key nil
  "Session key (LANGUAGE . NAME) in `jsonyter--remote-owner', or nil.")
(defvar-local jsonyter--remote-cwd ""
  "The Contents-API directory this remote browser is showing.")
(defvar-local jsonyter--remote-marks nil
  "Contents paths marked for deletion in this remote browser.")
(defvar-local jsonyter--remote-models nil
  "Hash of contents path -> child model plist for the current listing.")

(defun jsonyter--transfer-buffers ()
  "Every live jsonyter buffer whose bridge process is running."
  (seq-filter
   (lambda (buf)
     (and (buffer-local-value 'jsonyter-mode buf)
          (process-live-p (buffer-local-value 'jsonyter--process buf))))
   (buffer-list)))

(defun jsonyter--transfer-candidates ()
  "List of (LABEL BUFFER . SESSION) a transfer could run through."
  (let (out)
    (dolist (buf (jsonyter--transfer-buffers))
      (let ((sessions (buffer-local-value 'jsonyter--sessions buf)))
        (if (and sessions (> (hash-table-count sessions) 0))
            (maphash
             (lambda (_key session)
               (let ((n (jsonyter--session-name session)))
                 (push (cons (format "%s  %s%s  %s"
                                     (buffer-name buf)
                                     (or (jsonyter--session-language session) "?")
                                     (if (and n (not (string-empty-p n)))
                                         (format "[%s]" n) "")
                                     (jsonyter--short-id
                                      (jsonyter--session-kernel-id session)))
                             (cons buf session))
                       out)))
             sessions)
          (push (cons (format "%s  (no session)" (buffer-name buf))
                      (cons buf nil))
                out))))
    (nreverse out)))

(defun jsonyter--resolve-transfer-context ()
  "Return (BUFFER . SESSION) for a transfer command to act through.

The current buffer's own context when it has one -- a jsonyter buffer,
or a `jsonyter-remote-dired' buffer that records its origin.  Otherwise
the sole live jsonyter session, or a `completing-read' among several."
  (cond
   ((derived-mode-p 'jsonyter-remote-dired-mode)
    (let ((owner jsonyter--remote-owner)
          (key jsonyter--remote-session-key))
      (unless (buffer-live-p owner)
        (user-error "jsonyter: this remote browser's session is gone"))
      (cons owner (and key (with-current-buffer owner (jsonyter--session key))))))
   ((and (bound-and-true-p jsonyter-mode) (process-live-p jsonyter--process))
    (cons (current-buffer)
          (or (jsonyter--session)
              (and (derived-mode-p 'org-mode)
                   (fboundp 'jsonyter--org-session-at-point)
                   (jsonyter--org-session-at-point 'noerror))
              (car (jsonyter--session-list)))))
   (t
    (let ((cands (jsonyter--transfer-candidates)))
      (cond
       ((null cands)
        (user-error "jsonyter: no running jsonyter session — start a REPL or open a notebook first"))
       ((null (cdr cands)) (cdr (car cands)))
       (t (let ((pick (assoc (completing-read "Transfer through session: "
                                              (mapcar #'car cands) nil t)
                             cands)))
            (cdr (or pick (car cands))))))))))

(defun jsonyter--remote-root-for (url)
  "The configured `jsonyter-remote-root' for server URL, or nil."
  (cond
   ((null jsonyter-remote-root) nil)
   ((stringp jsonyter-remote-root) jsonyter-remote-root)
   ((consp jsonyter-remote-root)
    (cdr (assoc-string url jsonyter-remote-root)))))

(defun jsonyter--transfer-probe (buffer session)
  "Ensure SESSION's contents-dir mapping is known; return it (a path, or nil).

Runs the bridge's `kernel_contents_dir' once, lazily, through BUFFER: it
costs an `execute' on the kernel, and most sessions never transfer a
file.  A nil result -- the kernel is outside `root_dir' and no
`jsonyter-remote-root' resolves it -- is remembered so it is not retried
on every command."
  (when (and session (not (jsonyter--session-contents-dir-probed session)))
    (setf (jsonyter--session-contents-dir-probed session) t)
    (let* ((kid (jsonyter--session-kernel-id session))
           (root (jsonyter--remote-root-for
                  (or (buffer-local-value 'jsonyter--url buffer)
                      jsonyter-server-url)))
           (reply (and kid
                       (ignore-errors
                         (with-current-buffer buffer
                           (jsonyter--request-sync
                            "kernel_contents_dir"
                            (append (list :kernel_id kid)
                                    (and root (list :root root)))
                            jsonyter-startup-timeout)))))
           (dir (plist-get reply :contents_dir)))
      (setf (jsonyter--session-contents-dir session)
            (and (stringp dir) dir))))
  (and session (jsonyter--session-contents-dir session)))

(defun jsonyter--transfer-remote-dir (buffer session)
  "SESSION's sticky remote-browser directory, seeded once from the probe.
Always a Contents-API directory string: no leading slash, and either
empty or trailing-slashed."
  (if (null session)
      ""
    (or (jsonyter--session-remote-directory session)
        (setf (jsonyter--session-remote-directory session)
              (jsonyter--remote-dir-slash
               (or (jsonyter--transfer-probe buffer session) ""))))))

;;; list_contents

(defun jsonyter--remote-children (buffer path)
  "Children of remote directory PATH via BUFFER's bridge, directories first.
Each element is the child model plist from `list_contents'."
  (let* ((model (with-current-buffer buffer
                  (jsonyter--request-sync "list_contents"
                                          (list :path (or path "")))))
         (children (append (plist-get model :content) nil)))
    (sort children #'jsonyter--remote-child-lessp)))

(defun jsonyter--remote-child-lessp (a b)
  "Order child models A before B: directories first, then by name."
  (let ((ad (equal (plist-get a :type) "directory"))
        (bd (equal (plist-get b :type) "directory")))
    (cond ((and ad (not bd)) t)
          ((and bd (not ad)) nil)
          (t (string-lessp (or (plist-get a :name) "")
                           (or (plist-get b :name) ""))))))

;;; Remote path completion -- one listing per directory, on demand (§7)

(defun jsonyter--read-remote-path (buffer prompt &optional default directoryp)
  "Read a Contents-API path with directory-at-a-time completion.

The collection is `list_contents' on the directory portion of the
current input, fetched once and cached; typing past a `/' is a new
directory and a fresh listing.  Directories complete with a trailing
`/', so descending is a single TAB.  Deliberately not a completion over
the whole tree -- one round trip per directory, against a server that
may be on the far side of a slow link.

DEFAULT is the initial input.  With DIRECTORYP, the result is coerced to
a directory (trailing slash); otherwise it is returned as typed, minus
any leading slash."
  (let ((cache (make-hash-table :test #'equal)))
    (cl-labels
        ((names (dir)
           (let ((hit (gethash dir cache 'miss)))
             (if (not (eq hit 'miss))
                 hit
               (puthash dir
                        (condition-case nil
                            (mapcar
                             (lambda (c)
                               (concat (plist-get c :name)
                                       (if (equal (plist-get c :type) "directory")
                                           "/" "")))
                             (jsonyter--remote-children buffer dir))
                          (error nil))
                        cache))))
         (table (string pred action)
           (let* ((dir (if (string-match "\\`\\(.*/\\)" string)
                           (match-string 1 string)
                         ""))
                  (cands (mapcar (lambda (n) (concat dir n)) (names dir))))
             (if (eq action 'metadata)
                 '(metadata (category . file)
                            (display-sort-function . identity)
                            (cycle-sort-function . identity))
               (complete-with-action action cands string pred)))))
      (let ((raw (replace-regexp-in-string
                  "\\`/+" ""
                  (completing-read (format "%s: " prompt) #'table
                                   nil nil default))))
        (if directoryp (jsonyter--remote-dir-slash raw) raw)))))

;;; Running a transfer, with progress (§6)

(defun jsonyter--transfer-run (context method params &optional on-success)
  "Run transfer METHOD (\"upload\"/\"download\") with PARAMS through CONTEXT.

CONTEXT is (BUFFER . SESSION) from `jsonyter--resolve-transfer-context'.
Asynchronous -- it uses `jsonyter--send', never a synchronous request,
since a large transfer runs for minutes.  A `progress-reporter' tracks
bytes and percentage in the echo area, and, when SESSION is set, a
`:up NN%%' / `:down NN%%' tag in that session's mode line, so a transfer
started from a `dired' buffer is still visible from the REPL it belongs
to.  ON-SUCCESS, if given, is called with the result plist after the
completion message."
  (let* ((buffer (car context))
         (session (cdr context))
         (phase (if (equal method "download") "download" "upload"))
         (local (or (plist-get params :local_path) "?"))
         (remote (or (plist-get params :remote_path) "?"))
         (name (file-name-nondirectory
                (directory-file-name
                 (if (equal phase "upload") local remote))))
         (reporter (make-progress-reporter
                    (format "%s %s" (capitalize (concat phase "ing")) name)
                    0 100 0 1 0.01))
         (started (float-time)))
    (with-current-buffer buffer
      (when session
        (setf (jsonyter--session-transfer session)
              (list :phase phase :pct 0 :name name))
        (force-mode-line-update t))
      (condition-case err
          (jsonyter--send
           method params
           (list
            :progress
            (lambda (ev)
              (let* ((done (or (plist-get ev :bytes_done) 0))
                     (total (or (plist-get ev :bytes_total) 0))
                     (pct (if (> total 0)
                              (min 100 (floor (* 100.0 (/ done (float total)))))
                            0)))
                (progress-reporter-update
                 reporter pct
                 (format "(%s / %s)" (jsonyter--human-size done)
                         (jsonyter--human-size total)))
                (when session
                  (setf (jsonyter--session-transfer session)
                        (list :phase phase :pct pct :name name))
                  (force-mode-line-update t))))
            :result
            (lambda (msg)
              (when session
                (setf (jsonyter--session-transfer session) nil)
                (force-mode-line-update t))
              (progress-reporter-done reporter)
              (let ((rerr (plist-get msg :error))
                    (result (plist-get msg :result)))
                (cond
                 (rerr
                  (setq-local jsonyter--last-failed-transfer
                              (list :method method :params params))
                  (let ((rendered (jsonyter--error-message rerr)))
                    ;; §9: name the resume command whenever resuming is
                    ;; possible -- it always is here, the failure was just
                    ;; recorded -- unless the rendered text already did (its
                    ;; cf-ray and `corrupt' branches).
                    (message "jsonyter: %s of %s failed — %s%s"
                             phase name rendered
                             (if (string-match-p "jsonyter-resume" rendered) ""
                               (format " [M-x jsonyter-resume-%s to continue from where it stopped]"
                                       phase)))))
                 (result
                  (setq-local jsonyter--last-failed-transfer nil)
                  (jsonyter--transfer-report phase result started)
                  (when on-success (funcall on-success result))))))))
        (error
         ;; `jsonyter--send' signalled synchronously (a dead bridge):
         ;; no reply is coming, so clear the tag it just set.
         (when session
           (setf (jsonyter--session-transfer session) nil)
           (force-mode-line-update t))
         (signal (car err) (cdr err)))))))

(defun jsonyter--transfer-report (phase result started)
  "Announce a finished transfer: both ends, the size, the guarantee, the time."
  (let* ((remote (plist-get result :path))
         (local (plist-get result :local_path))
         (bytes (plist-get result :bytes))
         (elapsed (or (plist-get result :elapsed)
                      (and started (- (float-time) started))
                      0))
         (note (plist-get result :resume_note))
         (src (if (equal phase "upload")
                  (file-name-nondirectory (directory-file-name (or local "?")))
                remote))
         (dst (if (equal phase "upload") remote local)))
    (message "jsonyter: %s → %s (%s, %s, %ds)%s"
             src dst
             (jsonyter--human-size bytes)
             (jsonyter--transfer-verified-phrase (plist-get result :verified))
             (round elapsed)
             (if (and note (stringp note) (not (string-empty-p note)))
                 (format " — %s" note) ""))))

;;; Commands (§5)

;;;###autoload
(defun jsonyter-upload-file (local-path remote-path &optional overwrite context)
  "Upload LOCAL-PATH to REMOTE-PATH on the Jupyter server, asynchronously.

REMOTE-PATH is a Contents-API path: POSIX-style, relative to the
server's `root_dir', with no leading slash -- not a kernel-side absolute
path.  A prefix argument sets OVERWRITE, so an existing destination is
replaced rather than refused.

Interactively the local side is `read-file-name' (the file at point in a
`dired' buffer); the remote side defaults to the session's current
browser directory plus the local basename and completes one directory
at a time.  On a conflict the error names the recovery -- a prefix
argument to overwrite, or \\[jsonyter-download-file] first for a stale
file.

CONTEXT is the (BUFFER . SESSION) the transfer runs through; the
interactive form resolves it once and threads it here so the request
goes through exactly the session the remote path was completed against.
A Lisp caller may omit it, and one is resolved from the current buffer."
  (interactive
   (let* ((context (jsonyter--resolve-transfer-context))
          (buffer (car context))
          (session (cdr context))
          (at-point (and (derived-mode-p 'dired-mode)
                         (ignore-errors (dired-get-filename nil t))))
          (local (read-file-name "Upload local file: " nil nil t
                                 (and at-point
                                      (file-name-nondirectory at-point))))
          (remote-dir (with-current-buffer buffer
                        (jsonyter--transfer-remote-dir buffer session)))
          (default (concat remote-dir (file-name-nondirectory
                                       (directory-file-name local)))))
     (list local
           (jsonyter--read-remote-path buffer "Remote (contents) path" default)
           current-prefix-arg context)))
  (let ((expanded (expand-file-name local-path)))
    (unless (file-readable-p expanded)
      (user-error "jsonyter: cannot read %s" local-path))
    (when (file-directory-p expanded)
      (user-error "jsonyter: %s is a directory — only single files transfer" local-path))
    (when (string-empty-p (jsonyter--remote-dir-slash remote-path))
      (user-error "jsonyter: a remote (contents) path is required"))
    (jsonyter--transfer-run
     (or context (jsonyter--resolve-transfer-context)) "upload"
     (append (list :local_path expanded
                   :remote_path remote-path
                   :chunk_size jsonyter-upload-chunk-size)
             (and overwrite (list :overwrite t))))))

;;;###autoload
(defun jsonyter-download-file (remote-path local-path &optional overwrite context)
  "Download REMOTE-PATH from the Jupyter server to LOCAL-PATH, asynchronously.

REMOTE-PATH is a Contents-API path (see `jsonyter-upload-file').  The
local side defaults to `jsonyter-download-directory' (or the invoking
buffer's directory) plus the remote basename.  A prefix argument sets
OVERWRITE for an existing local file.

CONTEXT is the (BUFFER . SESSION) the transfer runs through; the
interactive form resolves it once (so the download uses the same session
the remote path was completed against) and threads it here.  A Lisp
caller may omit it."
  (interactive
   (let* ((context (jsonyter--resolve-transfer-context))
          (buffer (car context))
          (session (cdr context))
          (start (with-current-buffer buffer
                   (jsonyter--transfer-remote-dir buffer session)))
          (remote (jsonyter--read-remote-path buffer "Remote (contents) path" start))
          (dir (or jsonyter-download-directory default-directory)))
     (list remote
           (read-file-name "Save to: " dir nil nil
                           (file-name-nondirectory
                            (directory-file-name remote)))
           current-prefix-arg context)))
  (when (string-empty-p (jsonyter--remote-dir-slash remote-path))
    (user-error "jsonyter: a remote file path is required, not the root"))
  (let ((expanded (expand-file-name local-path)))
    (when (file-directory-p expanded)
      (setq expanded (expand-file-name (file-name-nondirectory
                                        (directory-file-name remote-path))
                                       expanded)))
    (jsonyter--transfer-run
     (or context (jsonyter--resolve-transfer-context)) "download"
     (append (list :remote_path remote-path :local_path expanded)
             (and overwrite (list :overwrite t))))))

;;;###autoload
(defun jsonyter-resume-upload ()
  "Re-run the last upload that failed, continuing from where it stopped.
The bridge appends blindly, so a whole-chunk partial is continued; a
chunk that landed torn is restarted from the beginning and the message
says so.  With no failed upload on record, says so rather than prompting
from scratch."
  (interactive)
  (jsonyter--resume-transfer "upload"))

;;;###autoload
(defun jsonyter-resume-download ()
  "Re-run the last download that failed, continuing from the local `.part' file."
  (interactive)
  (jsonyter--resume-transfer "download"))

(defun jsonyter--resume-transfer (want-method)
  "Re-issue the last failed transfer of type WANT-METHOD with `resume' set."
  (let* ((context (jsonyter--resolve-transfer-context))
         (buffer (car context))
         (record (buffer-local-value 'jsonyter--last-failed-transfer buffer)))
    (cond
     ((null record)
      (user-error "jsonyter: no failed transfer to resume in %s"
                  (buffer-name buffer)))
     ((not (equal (plist-get record :method) want-method))
      (user-error "jsonyter: the last failed transfer was %s, not %s"
                  (plist-get record :method) want-method))
     (t
      (let ((params (plist-put (copy-sequence (plist-get record :params))
                               :resume t)))
        ;; Re-read the chunk size: the documented proxy-413 recovery is
        ;; \"lower `jsonyter-upload-chunk-size', then M-x jsonyter-resume-upload\",
        ;; which is a no-op if we replay the size baked in at the first
        ;; call.  The bridge handles a changed chunk size on resume (it
        ;; either resumes at the new offset or restarts from scratch).
        (when (equal want-method "upload")
          (setq params (plist-put params :chunk_size jsonyter-upload-chunk-size)))
        (jsonyter--transfer-run context want-method params))))))

;;; dired: send marked files (§5)

;;;###autoload
(defun jsonyter-dired-upload-marked (&optional remote-dir)
  "Upload the marked files in this `dired' buffer into a remote directory.

Reads the remote (contents) directory once (REMOTE-DIR when called from
Lisp) and uploads the files sequentially -- never concurrently: the
bridge serialises REST work across four workers, and a burst of uploads
would stall unrelated calls."
  (interactive)
  (require 'dired)
  (unless (derived-mode-p 'dired-mode)
    (user-error "jsonyter: not a dired buffer"))
  (let* ((files (dired-get-marked-files nil nil #'file-regular-p))
         (context (jsonyter--resolve-transfer-context))
         (buffer (car context))
         (session (cdr context))
         (dir (or (and remote-dir (jsonyter--remote-dir-slash remote-dir))
                  (jsonyter--read-remote-path
                   buffer "Remote (contents) directory"
                   (with-current-buffer buffer
                     (jsonyter--transfer-remote-dir buffer session))
                   t))))
    (unless files
      (user-error "jsonyter: no marked regular files to upload"))
    (jsonyter--dired-upload-seq context dir files (length files) 0)))

(defun jsonyter--dired-upload-seq (context dir files total done)
  "Upload FILES into remote DIR one at a time; each starts after the last."
  (if (null files)
      (message "jsonyter: uploaded %d of %d file%s to %s"
               done total (if (= total 1) "" "s")
               (if (string-empty-p dir) "the server root" dir))
    (let ((file (car files)))
      (jsonyter--transfer-run
       context "upload"
       (list :local_path (expand-file-name file)
             :remote_path (concat dir (file-name-nondirectory
                                       (directory-file-name file)))
             :chunk_size jsonyter-upload-chunk-size)
       (lambda (_result)
         (jsonyter--dired-upload-seq context dir (cdr files)
                                     total (1+ done)))))))

;;;###autoload
(defun jsonyter-dired-setup ()
  "Bind the transfer commands in `dired-mode-map' (opt-in).

Call this from your init to get \\`C-c C-u' -- upload the marked files,
or the file at point when none are marked -- in every `dired' buffer.
jsonyter never touches `dired-mode-map' on its own."
  (require 'dired)
  (define-key dired-mode-map (kbd "C-c C-u") #'jsonyter-dired-upload-dwim))

;;;###autoload
(defun jsonyter-dired-upload-dwim ()
  "Upload the marked `dired' files, or the file at point if none are marked."
  (interactive)
  (require 'dired)
  (if (save-excursion
        (goto-char (point-min))
        (re-search-forward (dired-marker-regexp) nil t))
      (call-interactively #'jsonyter-dired-upload-marked)
    (call-interactively #'jsonyter-upload-file)))

;;; jsonyter-remote-dired: a dired-like browser over the Contents API (§8)

(defface jsonyter-remote-directory-face
  '((t :inherit font-lock-function-name-face))
  "Face for a directory entry in `jsonyter-remote-dired'."
  :group 'jsonyter)

(defface jsonyter-remote-readonly-face
  '((t :inherit shadow))
  "Face for a non-writable entry in `jsonyter-remote-dired'."
  :group 'jsonyter)

(defvar jsonyter-remote-dired-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'jsonyter-remote-dired-find)
    (define-key map (kbd "^")   #'jsonyter-remote-dired-up)
    (define-key map (kbd "g")   #'jsonyter-remote-dired-refresh)
    (define-key map (kbd "U")   #'jsonyter-remote-dired-upload)
    (define-key map (kbd "D")   #'jsonyter-remote-dired-download)
    (define-key map (kbd "E")   #'jsonyter-remote-dired-export)
    (define-key map (kbd "R")   #'jsonyter-remote-dired-rename)
    (define-key map (kbd "C")   #'jsonyter-remote-dired-copy)
    (define-key map (kbd "+")   #'jsonyter-remote-dired-mkdir)
    (define-key map (kbd "d")   #'jsonyter-remote-dired-mark-delete)
    (define-key map (kbd "u")   #'jsonyter-remote-dired-unmark)
    (define-key map (kbd "x")   #'jsonyter-remote-dired-execute)
    (define-key map (kbd "S")   #'jsonyter-sync)
    (define-key map (kbd "%")   #'jsonyter-sync-status)
    (define-key map (kbd "q")   #'quit-window)
    map)
  "Keymap for `jsonyter-remote-dired-mode'.")

(define-derived-mode jsonyter-remote-dired-mode tabulated-list-mode
  "Jsonyter-Remote"
  "Browse the Jupyter server's filesystem over the Contents API.

Every path here is a Contents-API path -- relative to the server's
`root_dir', no leading slash -- not a kernel-side absolute path.

\\{jsonyter-remote-dired-mode-map}"
  (setq tabulated-list-format [("" 1 nil)
                               ("Name" 44 nil)
                               ("Size" 10 nil :right-align t)
                               ("Modified" 20 nil)]
        tabulated-list-sort-key nil
        jsonyter--remote-models (make-hash-table :test #'equal))
  (setq-local revert-buffer-function
              (lambda (&rest _) (jsonyter-remote-dired-refresh)))
  (tabulated-list-init-header)
  ;; `jsonyter-remote-dired-refresh' puts the current directory in the
  ;; header line, dired-style, in place of `tabulated-list''s column
  ;; labels -- the three columns (a name, a size, a date) read plainly
  ;; enough without them.
  )

;;;###autoload
(defun jsonyter-remote-dired ()
  "Open a `dired'-like browser on the Jupyter server's filesystem.

One buffer per session.  Starts in the session's current browser
directory -- seeded from the kernel's working directory the first time,
where that resolves to a Contents-API path."
  (interactive)
  (let* ((context (jsonyter--resolve-transfer-context))
         (buffer (car context))
         (session (cdr context))
         (server (or (buffer-local-value 'jsonyter--url buffer)
                     jsonyter-server-url))
         (start (with-current-buffer buffer
                  (jsonyter--transfer-remote-dir buffer session)))
         ;; Discriminate by the owning buffer, not by the session name:
         ;; a REPL and a notebook on the same server both hold a session
         ;; named "" and would otherwise collide on one browser buffer
         ;; that `get-buffer-create' then silently repoints.  Each origin
         ;; buffer drives one kernel, so this is one browser per session
         ;; and re-invoking from the same buffer reuses it.
         (owner-tag (string-trim (buffer-name buffer) "[* ]+" "[* ]+"))
         (session-name (and session (jsonyter--session-name session)))
         (bufname (format "*jsonyter-remote: %s [%s%s]*" server owner-tag
                          (if (and session-name (not (string-empty-p session-name)))
                              (concat " " session-name) "")))
         (buf (get-buffer-create bufname)))
    (with-current-buffer buf
      (unless (derived-mode-p 'jsonyter-remote-dired-mode)
        (jsonyter-remote-dired-mode))
      (setq jsonyter--remote-owner buffer
            jsonyter--remote-session-key (and session (jsonyter--session-key session))
            jsonyter--remote-cwd start
            jsonyter--remote-marks nil)
      (jsonyter-remote-dired-refresh))
    (pop-to-buffer buf)))

(defun jsonyter--remote-call (method params)
  "Issue METHOD/PARAMS synchronously through this remote browser's owner."
  (let ((owner jsonyter--remote-owner))
    (unless (buffer-live-p owner)
      (user-error "jsonyter: this remote browser's session is gone"))
    (with-current-buffer owner
      (jsonyter--request-sync method params))))

(defun jsonyter--remote-entries (models marks)
  "Build `tabulated-list' entries from child MODELS, flagging MARKS for deletion.
Directories sort first and are suffixed `/'; a non-writable entry is
dimmed.  Pure -- no I/O -- so the rendering is unit-testable."
  (mapcar
   (lambda (child)
     (let* ((path (plist-get child :path))
            (dir (equal (plist-get child :type) "directory"))
            (name (concat (plist-get child :name) (if dir "/" "")))
            (writable (if (plist-member child :writable)
                          (and (plist-get child :writable) t)
                        t))
            (face (cond ((not writable) 'jsonyter-remote-readonly-face)
                        (dir 'jsonyter-remote-directory-face)
                        (t 'default)))
            (size (if dir "" (jsonyter--human-size (plist-get child :size))))
            (modified (plist-get child :last_modified)))
       (list path
             (vector (if (member path marks) "D" " ")
                     (propertize name 'face face)
                     size
                     (if (stringp modified)
                         (replace-regexp-in-string
                          "T" " " (substring modified 0 (min 16 (length modified))))
                       "")))))
   models))

(defun jsonyter-remote-dired-refresh ()
  "Re-list the current remote directory."
  (interactive)
  (let* ((cwd jsonyter--remote-cwd)
         (children (condition-case err
                       (jsonyter--remote-children jsonyter--remote-owner cwd)
                     (error
                      (user-error "jsonyter: cannot list %s — %s"
                                  (if (string-empty-p cwd) "the server root" cwd)
                                  (error-message-string err))))))
    (clrhash jsonyter--remote-models)
    (dolist (child children)
      (puthash (plist-get child :path) child jsonyter--remote-models))
    (setq jsonyter--remote-marks
          (seq-filter (lambda (p) (gethash p jsonyter--remote-models))
                      jsonyter--remote-marks))
    (setq tabulated-list-entries
          (jsonyter--remote-entries children jsonyter--remote-marks))
    (setq-local header-line-format
                (format "  %s : /%s   %d item%s%s"
                        (or (buffer-local-value 'jsonyter--url jsonyter--remote-owner)
                            jsonyter-server-url)
                        jsonyter--remote-cwd
                        (length children) (if (= (length children) 1) "" "s")
                        (if jsonyter--remote-marks
                            (format "   %d marked" (length jsonyter--remote-marks))
                          "")))
    (tabulated-list-print t)))

(defun jsonyter--remote-at-point ()
  "The child model plist for the entry at point, or nil."
  (let ((id (tabulated-list-get-id)))
    (and id jsonyter--remote-models (gethash id jsonyter--remote-models))))

(defun jsonyter-remote-dired-find ()
  "Descend into the directory at point, or download the file at point."
  (interactive)
  (let ((child (jsonyter--remote-at-point)))
    (unless child (user-error "jsonyter: no entry here"))
    (if (equal (plist-get child :type) "directory")
        (progn
          (setq jsonyter--remote-cwd
                (jsonyter--remote-dir-slash (plist-get child :path)))
          (jsonyter-remote-dired-refresh))
      (jsonyter-remote-dired-download))))

(defun jsonyter-remote-dired-up ()
  "Go up one directory."
  (interactive)
  (setq jsonyter--remote-cwd (jsonyter--remote-dir-parent jsonyter--remote-cwd))
  (jsonyter-remote-dired-refresh))

(defun jsonyter-remote-dired-download ()
  "Download the file at point to the local disk."
  (interactive)
  (let ((child (jsonyter--remote-at-point)))
    (unless child (user-error "jsonyter: no entry here"))
    (when (equal (plist-get child :type) "directory")
      (user-error "jsonyter: %s is a directory" (plist-get child :name)))
    (let* ((remote (plist-get child :path))
           (dir (or jsonyter-download-directory default-directory))
           (local (read-file-name "Save to: " dir nil nil
                                  (file-name-nondirectory
                                   (directory-file-name remote))))
           (overwrite (and (file-exists-p (expand-file-name local))
                           (yes-or-no-p (format "%s exists — overwrite? " local)))))
      (jsonyter--transfer-run
       (jsonyter--resolve-transfer-context) "download"
       (append (list :remote_path remote :local_path (expand-file-name local))
               (and overwrite (list :overwrite t)))))))

(defun jsonyter-remote-dired-export (format to-path)
  "Export the notebook at point on the server to FORMAT, writing the
result to TO-PATH.

Uses `server_path' -- the one place in this package a real path in the
Jupyter server's own Contents API namespace is already in hand, unlike
`jsonyter-notebook-export', which builds its notebook from a buffer's
own cells because an ordinary notebook buffer has no such server path at
all.  Runs through this browser's owning session's bridge, the same one
`jsonyter-remote-dired-download' uses, so it works whether or not that
session's buffer happens to be selected.

Interactively, refuses a directory or a non-`.ipynb' entry outright,
reads FORMAT via `completing-read' over what the server actually offers
-- refusing early when it offers none, before a request that could take
two minutes to fail -- and defaults TO-PATH next to
`jsonyter-download-directory', the same default
`jsonyter-remote-dired-download' uses, with a best-guess extension for
FORMAT."
  (interactive
   (let ((child (jsonyter--remote-at-point)))
     (unless child (user-error "jsonyter: no entry here"))
     (when (equal (plist-get child :type) "directory")
       (user-error "jsonyter: %s is a directory" (plist-get child :name)))
     (unless (string-suffix-p ".ipynb" (plist-get child :path))
       (user-error "jsonyter: %s is not a notebook" (plist-get child :name)))
     (let* ((context (jsonyter--resolve-transfer-context))
            (owner (car context))
            (probe (with-current-buffer owner (jsonyter--list-export-formats)))
            (formats (and (plist-get probe :available)
                         (jsonyter--export-format-names (plist-get probe :formats)))))
       (unless formats
         (user-error "jsonyter: export not available on %s -- %s"
                     (with-current-buffer owner jsonyter-server-url)
                     (or (plist-get probe :reason) "unknown reason")))
       (let* ((format (completing-read "Export format: " formats nil t))
              (dir (or jsonyter-download-directory default-directory))
              (base (file-name-sans-extension
                     (file-name-nondirectory
                      (directory-file-name (plist-get child :path)))))
              (default (expand-file-name
                        (concat base (jsonyter--export-format-guess-extension format))
                        dir)))
         (list format (read-file-name "Export to: " dir default nil
                                      (file-name-nondirectory default)))))))
  (let* ((child (jsonyter--remote-at-point))
         (context (jsonyter--resolve-transfer-context))
         (owner (car context))
         (session (cdr context))
         (remote (and child (plist-get child :path))))
    (unless child (user-error "jsonyter: no entry here"))
    (when (equal (plist-get child :type) "directory")
      (user-error "jsonyter: %s is a directory" (plist-get child :name)))
    (unless (string-suffix-p ".ipynb" remote)
      (user-error "jsonyter: %s is not a notebook" (plist-get child :name)))
    (with-current-buffer owner
      (jsonyter--ensure-bridge)
      (jsonyter--export-run
       session
       (list :format format :server_path remote :to_path (expand-file-name to-path)
             :timeout jsonyter-export-timeout)
       (lambda (result)
         (message "jsonyter: exported %s to %s (%s)"
                  (plist-get result :format)
                  (plist-get result :path)
                  (file-size-human-readable (or (plist-get result :bytes) 0)
                                            nil " " "B")))))))

(defun jsonyter-remote-dired-upload ()
  "Upload a local file into the directory being shown."
  (interactive)
  (let* ((context (jsonyter--resolve-transfer-context))
         (local (read-file-name "Upload local file: " nil nil t))
         (remote (concat jsonyter--remote-cwd
                         (file-name-nondirectory (directory-file-name local))))
         (overwrite (and (gethash remote jsonyter--remote-models)
                         (yes-or-no-p
                          (format "%s exists on the server — overwrite? " remote))))
         (buf (current-buffer)))
    (jsonyter--transfer-run
     context "upload"
     (append (list :local_path (expand-file-name local)
                   :remote_path remote
                   :chunk_size jsonyter-upload-chunk-size)
             (and overwrite (list :overwrite t)))
     (lambda (_r)
       (when (buffer-live-p buf)
         (with-current-buffer buf (jsonyter-remote-dired-refresh)))))))

(defun jsonyter-remote-dired-rename ()
  "Rename or move the entry at point (`rename_contents')."
  (interactive)
  (let ((child (jsonyter--remote-at-point)))
    (unless child (user-error "jsonyter: no entry here"))
    (let* ((old (plist-get child :path))
           (new (jsonyter--read-remote-path
                 jsonyter--remote-owner "Rename to (contents path)" old)))
      (when (or (null new) (string-empty-p new) (equal new old))
        (user-error "jsonyter: unchanged"))
      (jsonyter--remote-call "rename_contents" (list :path old :new_path new))
      (message "jsonyter: %s → %s" old new)
      (jsonyter-remote-dired-refresh))))

(defun jsonyter-remote-dired-copy ()
  "Copy the entry at point into a directory the server names (`copy_contents')."
  (interactive)
  (let ((child (jsonyter--remote-at-point)))
    (unless child (user-error "jsonyter: no entry here"))
    (let* ((src (plist-get child :path))
           (to-dir (jsonyter--read-remote-path
                    jsonyter--remote-owner "Copy into (contents directory)"
                    jsonyter--remote-cwd t))
           (model (jsonyter--remote-call
                   "copy_contents"
                   (list :path src
                         :to_dir (if (string-empty-p to-dir)
                                     ""     ; the contents root
                                   (directory-file-name to-dir)))))
           ;; The server picks the name (appending -Copy1 and so on);
           ;; report what it chose, not what was asked for.
           (chosen (or (plist-get model :path) (plist-get model :name) "?")))
      (message "jsonyter: copied %s → %s" src chosen)
      (jsonyter-remote-dired-refresh))))

(defun jsonyter-remote-dired-mkdir (name)
  "Create directory NAME in the directory being shown (`make_directory')."
  (interactive (list (read-string "New directory name: ")))
  (when (or (null name) (string-empty-p name))
    (user-error "jsonyter: a name is required"))
  (jsonyter--remote-call "make_directory"
                         (list :path (concat jsonyter--remote-cwd name)))
  (message "jsonyter: created %s%s" jsonyter--remote-cwd name)
  (jsonyter-remote-dired-refresh))

(defun jsonyter-remote-dired-mark-delete ()
  "Mark the entry at point for deletion and move to the next line."
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (unless id (user-error "jsonyter: no entry here"))
    (cl-pushnew id jsonyter--remote-marks :test #'equal)
    (jsonyter-remote-dired-refresh)
    (forward-line 1)))

(defun jsonyter-remote-dired-unmark ()
  "Unmark the entry at point."
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (when id
      (setq jsonyter--remote-marks (delete id jsonyter--remote-marks))
      (jsonyter-remote-dired-refresh)
      (forward-line 1))))

(defun jsonyter-remote-dired-execute ()
  "Delete every entry marked with `d', per `jsonyter-remote-confirm-delete'.
A delete that fails -- a non-empty directory, a permission -- does not
abort the rest: each entry is tried, the ones that went through drop
their mark and the listing is refreshed either way, and any failures
are reported together."
  (interactive)
  (let ((marks jsonyter--remote-marks))
    (unless marks (user-error "jsonyter: nothing marked for deletion"))
    (when (or (not jsonyter-remote-confirm-delete)
              (yes-or-no-p (format "Delete %d entr%s on the server? "
                                   (length marks)
                                   (if (= (length marks) 1) "y" "ies"))))
      (let ((done 0) (failures nil))
        (unwind-protect
            (dolist (path marks)
              (condition-case err
                  (progn
                    (jsonyter--remote-call "delete_contents" (list :path path))
                    (setq jsonyter--remote-marks
                          (delete path jsonyter--remote-marks))
                    (cl-incf done))
                (error
                 (push (format "%s (%s)" path (error-message-string err))
                       failures))))
          (jsonyter-remote-dired-refresh))
        (if failures
            (message "jsonyter: deleted %d, %d failed — %s"
                     done (length failures)
                     (mapconcat #'identity (nreverse failures) "; "))
          (message "jsonyter: deleted %d entr%s" done
                   (if (= done 1) "y" "ies")))))))

(provide 'jsonyter-transfer)
;;; jsonyter-transfer.el ends here
