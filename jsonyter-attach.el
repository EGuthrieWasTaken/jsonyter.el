;;; jsonyter-attach.el --- Attaching to a kernel that is already running -*- lexical-binding: t; -*-

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

;; Attaching to a kernel that is already running.  One part of jsonyter.el, which loads
;; every part; see jsonyter.el for the overview and the entry points.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'jsonyter-repl)

;; Defined in other parts of the package, which load after this one.
(declare-function jsonyter--org-babel-ensure-plumbing "jsonyter-babel")

;;;; Attaching to a kernel that is already running

;; Everything above starts a kernel and holds it for the life of the
;; buffer.  These commands go the other way: they point a buffer that
;; already exists at a kernel that already exists.
;;
;; What makes that necessary is a remote server plus a laptop that slept
;; or lost its network.  The bridge's websocket to the kernel is then
;; half-open — the socket object still reports itself connected, so the
;; bridge's own "reconnect on the next send" never fires, and every
;; later request waits for a reply that cannot arrive.  Closing the
;; socket explicitly is the only thing that breaks that, which is why
;; `jsonyter-kernel-connect' sends `disconnect' before `subscribe' even
;; when it looks redundant.  The kernel itself is untouched by any of
;; this: it kept running on the server the whole time, with all of its
;; state, which is exactly why reattaching is worth doing.

(defun jsonyter--short-id (kernel-id)
  "The leading 8 characters of KERNEL-ID, enough to tell kernels apart."
  (cond ((not (stringp kernel-id)) "?")
        ((> (length kernel-id) 8) (substring kernel-id 0 8))
        (t kernel-id)))

(defun jsonyter--check-jsonyter-buffer ()
  "Signal unless the current buffer is some kind of jsonyter buffer.

An Org buffer bootstraps itself here rather than being turned away:
`jsonyter-mode' being off in Org only ever means `jsonyter-org-mode'
(or `jsonyter-org-mode-maybe') has not run yet, never that the buffer
cannot talk to a kernel — the org-babel back door
\(`jsonyter--org-babel-ensure-plumbing') already proves that by working
with the minor mode off, so the cell layer (`C-RET' / `S-RET' /
`jsonyter-org-run-block', `jsonyter-kernel-connect', ...) gets the same
treatment instead of a gate that serves no purpose on this path."
  (unless (bound-and-true-p jsonyter-mode)
    (if (derived-mode-p 'org-mode)
        (jsonyter--org-babel-ensure-plumbing)
      (user-error "jsonyter: not a jsonyter buffer — needs a REPL, a rendered .ipynb, `jsonyter-script-mode', or an Org buffer (see `jsonyter-org-mode-maybe')"))))

(defun jsonyter--ensure-live-bridge ()
  "Make sure this jsonyter buffer has a live bridge process.

Starts one if the buffer never had one, and replaces one that has
exited — a bridge is a subprocess, and a broken pipe to the server can
leave Python far enough gone that it takes the process with it.  A
replacement process cannot answer requests the old one accepted, so the
callback table is emptied along with it rather than left holding
handlers that will never be called."
  (jsonyter--check-jsonyter-buffer)
  (unless jsonyter--callbacks
    (setq-local jsonyter--callbacks (make-hash-table :test #'eql)))
  (unless (process-live-p jsonyter--process)
    (jsonyter--kill-process)
    (clrhash jsonyter--callbacks)
    ;; A replacement bridge has none of the old one's kernel sockets, so
    ;; no execute of ours is in flight on any session any more.
    (dolist (session (jsonyter--session-list))
      (setf (jsonyter--session-busy session) nil))
    (setq jsonyter--process (jsonyter--start-bridge)))
  jsonyter--process)

(defun jsonyter--running-kernels ()
  "Kernels running on `jsonyter-server-url', most recently active first.
Each is a plist with at least :id, :name, :execution_state and
:last_activity."
  (sort (jsonyter--request-sync "list_kernels" nil)
        (lambda (a b)
          ;; The server's timestamps are fixed-layout UTC, so they sort
          ;; correctly as plain strings; reversed to put the kernel you
          ;; were most likely just using at the top of the list.
          (string< (or (plist-get b :last_activity) "")
                   (or (plist-get a :last_activity) "")))))

(defun jsonyter--kernel-activity (kernel)
  "KERNEL's `last_activity' as a local time, or the raw value it sent."
  (let ((stamp (plist-get kernel :last_activity)))
    (or (and stamp (ignore-errors
                     (format-time-string "%F %H:%M" (date-to-time stamp))))
        stamp
        "")))

(defun jsonyter--kernel-label (kernel current)
  "One completion line describing KERNEL, marked when its id is CURRENT."
  (format "%s %-16s %-8s  %-9s %s"
          (if (equal (plist-get kernel :id) current) "*" " ")
          (or (plist-get kernel :name) "?")
          (jsonyter--short-id (plist-get kernel :id))
          (or (plist-get kernel :execution_state) "?")
          (jsonyter--kernel-activity kernel)))

(defun jsonyter--read-kernel (prompt &optional current)
  "Read the id of a kernel running on the server, prompting with PROMPT.
CURRENT, an id, is marked with a `*' and offered as the default; it
defaults to the current session's kernel (or the one it last used), so
reattaching after a dropped connection is one RET."
  (let ((kernels (jsonyter--running-kernels)))
    (unless kernels
      (user-error "jsonyter: no kernels are running on %s" jsonyter-server-url))
    (let* ((current (or current
                        (jsonyter-current-kernel-id)
                        (let ((s (jsonyter--session)))
                          (and s (plist-get (jsonyter--session-last-kernel s) :id)))))
           (table (mapcar (lambda (kernel)
                            (cons (jsonyter--kernel-label kernel current)
                                  (plist-get kernel :id)))
                          kernels))
           (default (car (rassoc current table)))
           ;; The labels are padded columns, so completion has to match
           ;; on the whole line rather than on a prefix of it.
           (completion-styles (cons 'substring completion-styles))
           (choice (completing-read prompt table nil t nil nil default)))
      (or (cdr (assoc choice table))
          (user-error "jsonyter: no such kernel")))))

(defun jsonyter--kernelspec-language (name)
  "Declared language of kernel spec NAME, or nil if it cannot be resolved.
Best effort: a server that will not describe its kernelspecs is no
reason to refuse a connection to a kernel it is plainly running."
  (ignore-errors
    (let ((table (plist-get (jsonyter--request-sync "list_kernelspecs" nil)
                            :kernelspecs)))
      (cl-loop for (_key spec) on table by #'cddr
               when (equal (plist-get spec :name) name)
               return (plist-get (plist-get spec :spec) :language)))))

(defun jsonyter--adopt-kernel-language (session name)
  "Adopt kernel spec NAME's language into SESSION, reporting a change.
Returns a clause to append to the connection message when the session was
set up for a different language — attaching a Python script buffer to an
R kernel is a mistake worth seeing rather than a silent one — else nil."
  (let ((language (jsonyter--kernelspec-language name))
        (previous (jsonyter--session-language session)))
    (when language
      (setf (jsonyter--session-language session) language))
    (and language previous
         (not (string-equal (downcase previous) (downcase language)))
         (format " (note: this buffer was set up for %s, not %s)"
                 previous language))))

(defun jsonyter--attach-target ()
  "The session `jsonyter-kernel-connect' (re)binds here, made if it must."
  (or (jsonyter--session)
      (and jsonyter--session-key (jsonyter--session-put jsonyter--session-key))
      (and (derived-mode-p 'org-mode)
           (fboundp 'jsonyter--org-session-at-point)
           (or (jsonyter--org-session-at-point 'noerror)
               (and (fboundp 'jsonyter--org-ensure-session-at-point)
                    (jsonyter--org-ensure-session-at-point 'no-kernel))))
      (user-error "jsonyter: nowhere to attach a kernel here")))

(defun jsonyter-kernel-connect (kernel-id &optional session)
  "Attach SESSION (default the one in play) to KERNEL-ID, running on the server.

Works in any jsonyter buffer — a REPL, a rendered .ipynb, a script with
`jsonyter-script-mode' on, or an Org buffer — and replaces whatever
kernel that session was talking to.  Called interactively, offers the
kernels `jsonyter-server-url' currently reports, most recently active
first, with this session's own kernel marked `*' and offered as the
default.

Two quite different jobs, both of which come down to the same steps:

  - Recovering a connection that broke.  Give it the kernel this buffer
    already has (which is all `jsonyter-kernel-reconnect' does) and the
    kernel keeps running with every variable it had; only the socket is
    rebuilt.  Nothing is lost but output that was in flight.
  - Borrowing someone else\\='s kernel — running a script\\='s cells against
    the kernel a notebook already has warm, say, so both see the same
    variables.

Requests still outstanding are abandoned: after a broken pipe their
replies are never coming, and a reply to a request issued against the
old socket would be meaningless against the new one anyway.  A REPL gets
a fresh prompt for that reason.  Its number may be behind what the
kernel actually counts, since the kernel kept running while we were
away; it resyncs on the next execution.

A kernel attached to this way is not shut down when the buffer is
killed, however `jsonyter-shutdown-on-kill' is set — it is not this
buffer\\='s to end.  Nor does attaching elsewhere disown the kernel this
buffer started, if it started one: that one stays its responsibility,
and stays what gets shut down when the buffer dies.

Returns KERNEL-ID."
  (interactive
   (list (progn (jsonyter--ensure-live-bridge)
                (jsonyter--read-kernel "Connect to kernel: "))))
  (jsonyter--ensure-live-bridge)
  (let* ((session (or session (jsonyter--attach-target)))
         (same (equal kernel-id (jsonyter--session-kernel-id session)))
         ;; Ask about the kernel before disturbing anything: if it is
         ;; gone from the server there is nothing to attach to, and the
         ;; session should be left exactly as it was.
         (kernel (condition-case err
                     (jsonyter--request-sync "get_kernel"
                                             (list :kernel_id kernel-id))
                   (error
                    (user-error "jsonyter: cannot attach to kernel %s on %s — %s"
                                (jsonyter--short-id kernel-id)
                                jsonyter-server-url
                                (error-message-string err)))))
         (name (plist-get kernel :name)))
    ;; Nothing pending can be answered across a new socket.
    (clrhash jsonyter--callbacks)
    (setf (jsonyter--session-busy session) nil)
    (setq jsonyter--clear-pending nil
          jsonyter--is-complete-failures 0)
    ;; The whole point (see the commentary above): close the old socket
    ;; before opening a new one, because a half-open one will happily
    ;; claim it is still connected and be reused.  Harmless when there
    ;; is nothing to close, which is the case on a fresh bridge.
    (ignore-errors
      (jsonyter--request-sync "disconnect" (list :kernel_id kernel-id)))
    (setq jsonyter--url jsonyter-server-url)
    (setf (jsonyter--session-kernel-id session) kernel-id
          (jsonyter--session-kernel-name session) name
          (jsonyter--session-state session) (plist-get kernel :execution_state)
          ;; `own' is deliberately untouched: attaching to a kernel never
          ;; makes it ours, and wandering off to one never stops the
          ;; kernel we started from being.
          (jsonyter--session-last-kernel session) (list :id kernel-id :name name))
    (jsonyter--subscribe session)
    ;; A socket opened moments ago has not seen a status message yet, so
    ;; `subscribe' can legitimately report no state at all; the REST
    ;; call above knows what the server thinks.
    (unless (jsonyter--session-state session)
      (setf (jsonyter--session-state session)
            (plist-get kernel :execution_state)))
    (let ((mismatch (jsonyter--adopt-kernel-language session name))
          (verb (if same "reconnected to" "connected to")))
      (force-mode-line-update)
      (when (derived-mode-p 'jsonyter-repl-mode)
        (jsonyter--note (format "\n[%s kernel %s (%s) on %s]"
                                verb name (jsonyter--short-id kernel-id)
                                jsonyter--url))
        (jsonyter--insert-prompt))
      (message "jsonyter: %s kernel %s (%s) on %s%s"
               verb name (jsonyter--short-id kernel-id) jsonyter--url
               (or mismatch "")))
    kernel-id))

(defun jsonyter-kernel-reconnect ()
  "Reconnect this buffer to the kernel it was last using.

The command for a REPL that has gone quiet because the network dropped
or the machine slept: the kernel is still on the server with all of its
state, and only the connection to it needs rebuilding.  Equivalent to
`jsonyter-kernel-connect' on this buffer\\='s own kernel, which is where
the details are; use that one to pick a different kernel."
  (interactive)
  (jsonyter--check-jsonyter-buffer)
  (let* ((session (jsonyter--command-session))
         (kernel-id (or (jsonyter--session-kernel-id session)
                        (plist-get (jsonyter--session-last-kernel session) :id))))
    (unless kernel-id
      (user-error "jsonyter: this session has no kernel to reconnect to (M-x jsonyter-kernel-connect to pick one)"))
    (jsonyter-kernel-connect kernel-id session)))

(defun jsonyter--history-input (entry)
  "Input text of one `history' reply ENTRY, or nil if it carries none.
An entry is (SESSION LINE INPUT).  When a client asks for outputs too —
which jsonyter.el never does, but another front end sharing the kernel
may have — INPUT is instead a pair of the input and its output; take the
input either way."
  (let ((input (nth 2 entry)))
    (cond ((stringp input) input)
          ((and (consp input) (stringp (car input))) (car input))
          (t nil))))

(defun jsonyter--history-insert (entries)
  "Insert history ENTRIES into the current buffer as a transcript.
ENTRIES are `history_reply' triples, oldest first, and stay in that
order: history reads like a transcript, so the newest command belongs at
the bottom where the eye finishes.  Line numbers restart with every
session in the kernel\\='s history store, and that store can span kernels
as well as restarts (see `jsonyter-kernel-history'), so each session
gets a rule of its own — without one a tail reads as several In [1]s
with no hint of why, or whose."
  (let ((session 'jsonyter--none))
    (dolist (entry entries)
      (let ((input (jsonyter--history-input entry)))
        (when input
          (unless (equal (nth 0 entry) session)
            (let* ((first (eq session 'jsonyter--none))
                   (label (format "session %s " (setq session (nth 0 entry))))
                   (rule (make-string (max 4 (- jsonyter-notebook-separator-width
                                                (length label)))
                                      ?─)))
              ;; A blank line separates sessions; there is nothing to
              ;; separate the first one from but the header.
              (unless first (insert "\n"))
              (insert (propertize (concat label rule "\n")
                                  'face 'jsonyter-note-face))))
          (let ((label (format "In [%s]: " (nth 1 entry))))
            (insert (propertize label 'face 'jsonyter-prompt-face)
                    ;; Continuation lines line up under the first, so a
                    ;; multi-line cell reads as one block.
                    (string-join (split-string input "\n")
                                 (concat "\n" (make-string (length label) ?\s)))
                    "\n")))))))

(defun jsonyter-kernel-history (&optional n kernel-id)
  "Show the N commands most recently run by KERNEL-ID.

Asks the kernel for its own history, which is a different thing from
this Emacs session\\='s input ring — what \\[jsonyter-repl-previous-input]
walks.  It is how to see what a REPL whose transcript you have lost
actually ran, and what a kernel you are thinking of attaching to has
been used for.

How far back that history reaches, and whose commands are in it, is the
kernel\\='s business rather than ours — and IPython\\='s in particular reaches
wider than the one kernel you asked.  Its history is a single SQLite
database per profile, shared by every kernel using that profile, so a
tail of it can hand back commands run by a different kernel entirely: a
freshly started kernel that has executed nothing at all still answers
with the last things its neighbours ran.  Entries are grouped and
labelled by session for that reason, and the numbering restarts with
each — the session is what separates one kernel\\='s run from another\\='s.

Interactively, N defaults to `jsonyter-kernel-history-count' and the
kernel is this buffer\\='s own.  A numeric prefix argument sets N
\\(\\[universal-argument] 100 asks for a hundred).  A bare
\\[universal-argument] prompts for both, which is how to read the history
of a kernel this buffer is not attached to; a buffer with no kernel of
its own prompts for one too.

Called from Lisp, both arguments are plain: N is a count and KERNEL-ID
an id as `jsonyter--running-kernels' reports it.  Either way this must
run in a jsonyter buffer, whose bridge process does the asking.

Not every kernel implements history — SAS, for one, never answers — so
this can time out where a REPL against the same kernel works fine."
  (interactive
   (let* ((arg current-prefix-arg)
          ;; Whether we know of a kernel, not whether the bridge is up:
          ;; a buffer reaching for its history after the pipe broke wants
          ;; its own kernel, not a prompt.
          (choose (or (consp arg) (null (jsonyter-current-kernel-id))))
          (n (cond ((consp arg)
                    (read-number "Number of commands: "
                                 jsonyter-kernel-history-count))
                   (arg (prefix-numeric-value arg))
                   (t jsonyter-kernel-history-count))))
     (jsonyter--ensure-live-bridge)
     (list n (if choose
                 (jsonyter--read-kernel "History of kernel: ")
               (jsonyter-current-kernel-id)))))
  (jsonyter--ensure-live-bridge)
  (let ((n (or n jsonyter-kernel-history-count))
        (kernel-id (or kernel-id (jsonyter-current-kernel-id))))
    (unless kernel-id
      (user-error "jsonyter: no kernel to show the history of"))
    (unless (and (integerp n) (> n 0))
      (user-error "jsonyter: number of commands must be a positive integer, not %S" n))
    (let* ((ours (equal kernel-id (jsonyter-current-kernel-id)))
           ;; Names the kernel for the header, and — the reason it comes
           ;; first — says plainly that a kernel is gone, rather than
           ;; leaving that to a socket that fails for its own reasons.
           (kernel (condition-case err
                       (jsonyter--request-sync "get_kernel"
                                               (list :kernel_id kernel-id))
                     (error
                      (user-error "jsonyter: cannot reach kernel %s on %s — %s"
                                  (jsonyter--short-id kernel-id)
                                  jsonyter-server-url
                                  (error-message-string err)))))
           (reply
            (unwind-protect
                (condition-case err
                    (jsonyter--kernel-request "history"
                                              (list :kernel_id kernel-id :n n))
                  (error
                   (user-error "jsonyter: kernel %s gave no history — %s"
                               (jsonyter--short-id kernel-id)
                               (error-message-string err))))
              ;; Asking opens a socket to the kernel; keep one only to a
              ;; kernel this buffer is actually working with.
              (unless ours
                (ignore-errors
                  (jsonyter--request-sync "disconnect"
                                          (list :kernel_id kernel-id))))))
           (status (plist-get reply :status))
           (entries (plist-get reply :history)))
      ;; Kernels that report a status and mean it get taken at their word;
      ;; ones that omit it are judged on whether they sent any history.
      (when (and status (not (equal status "ok")))
        (error "jsonyter: kernel %s refused the history request (%s)"
               (jsonyter--short-id kernel-id) status))
      (if (null entries)
          (message "jsonyter: kernel %s has run nothing yet"
                   (jsonyter--short-id kernel-id))
        (let ((name (or (plist-get kernel :name) "?"))
              (url (if ours (or jsonyter--url jsonyter-server-url)
                     jsonyter-server-url))
              (shown (length entries)))
          (with-help-window "*jsonyter-history*"
            (with-current-buffer standard-output
              (insert (propertize
                       (format "Last %d command%s in the history of kernel %s (%s) on %s%s\n\n"
                               shown (if (= shown 1) "" "s")
                               name (jsonyter--short-id kernel-id) url
                               (if (< shown n) " — all it has" ""))
                       'face 'jsonyter-note-face))
              (jsonyter--history-insert entries))))))))

(provide 'jsonyter-attach)
;;; jsonyter-attach.el ends here
