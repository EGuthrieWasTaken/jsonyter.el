;;; transfer.el --- file transfer, the interactive paths -*- lexical-binding: t; -*-

;; `test/jsonyter-tests.el' covers the wiring off a stubbed bridge: a
;; `progress' line routed to its handler, the reporter reaching 100% and
;; being torn down on an error partway, the recovery hints
;; `jsonyter--error-message' adds.  These scenarios drive the commands
;; end to end through `eh-fake-bridge' (`transfer.jsonl'): the upload and
;; conflict paths as whole commands, and `jsonyter-remote-dired'
;; rendering a real listing.
;;
;; Streaming `progress' into the echo area *while* a transfer runs is the
;; one thing not asserted here: `eh-fake-bridge' has no `progress' emit
;; key (only `output' / `event' / `input_request' / `raw'), so it cannot
;; produce the lines.  The batch ERT `jsonyter-test-transfer-*' tests
;; feed real `progress' lines to `jsonyter--dispatch' and cover that.

(defun jsonyter-transfer--scratch-file (name contents)
  "Write CONTENTS to NAME under the profile scratch dir and return its path."
  (let ((path (expand-file-name name eh-profile-scratch-dir)))
    (make-directory (file-name-directory path) t)
    (with-temp-file path (insert contents))
    path))

(eh-scenario jsonyter/upload-runs-end-to-end-and-reports-completion
  :doc "An upload driven as a whole command: `jsonyter-upload-file'
        resolves the session, sends the transfer, and on the reply prints
        a completion line naming both ends, the byte count and the
        verification level -- and the mode-line transfer tag is back to
        `:idle' afterwards.  (The mid-flight progress stream is asserted
        in the batch `jsonyter-test-transfer-*' tests; `eh-fake-bridge'
        cannot emit `progress' lines.)"
  :tags (jsonyter transfer)

  (jy-use-scripts "transfer.jsonl")
  (jy-start-repl)

  (let ((local (jsonyter-transfer--scratch-file "up/fresh.csv" "id,val\n1,2\n3,4\n")))
    (jsonyter-upload-file local "work/data/fresh.csv")
    (jy-wait-idle)

    ;; The completion line: source, destination, size, guarantee.
    (eh-expect-messages-match "work/data/fresh\\.csv (192 B, sha256 verified")
    ;; The mode-line transfer tag is cleared once the transfer is done.
    (eh-expect-equal (jy-harness-state) ":idle")))

(eh-scenario jsonyter/upload-conflict-surfaces-the-overwrite-recovery
  :doc "Uploading onto a file that already exists comes back as a
        structured conflict, and the message says what to do about it --
        pass a prefix argument to overwrite -- rather than a bare
        `already exists'.  The last failure is also recorded, so
        `jsonyter-resume-upload' has something to act on."
  :tags (jsonyter transfer)

  (jy-use-scripts "transfer.jsonl")
  (jy-start-repl)

  (let ((local (jsonyter-transfer--scratch-file "up/notes.txt" "hello\n")))
    (jsonyter-upload-file local "work/notes.txt")
    (jy-wait-idle)

    (eh-expect-messages-match "already exists on the server")
    (eh-expect-messages-match "overwrite")
    (eh-expect
     (jy-harness--in-buffer
       (equal "upload" (plist-get jsonyter--last-failed-transfer :method)))
     "a failed upload must be recorded for jsonyter-resume-upload")))

(eh-scenario jsonyter/remote-dired-lists-a-directory-and-dims-readonly
  :doc "`jsonyter-remote-dired' seeds itself from the working-directory
        probe, lists that directory over `list_contents', and shows a
        non-writable entry in a dimmed face instead of leaving it to fail
        at the point of use.  Directories sort first and carry a `/'."
  :tags (jsonyter transfer)

  (jy-use-scripts "transfer.jsonl")
  (jy-start-repl)

  (jsonyter-remote-dired)
  (set-buffer
   (or (seq-find (lambda (b)
                   (string-prefix-p "*jsonyter-remote: " (buffer-name b)))
                 (buffer-list))
       (error "jsonyter-harness: no remote browser buffer was created")))
  (eh-expect (derived-mode-p 'jsonyter-remote-dired-mode)
             "jsonyter-remote-dired must land in its own mode")

  (eh-expect-match "data/" (buffer-string))
  (eh-expect-match "notes.txt" (buffer-string))
  (eh-expect-match "readonly.csv" (buffer-string))
  ;; The read-only row is dimmed; a writable one is not.
  (jy-expect-faced-text "readonly.csv" 'jsonyter-remote-readonly-face)
  (save-excursion
    (goto-char (point-min))
    (search-forward "notes.txt")
    (eh-expect (not (eq 'jsonyter-remote-readonly-face
                        (get-text-property (match-beginning 0) 'face)))
               "a writable entry must not be dimmed"))
  ;; The directory sorts above the files.
  (eh-expect (< (save-excursion (goto-char (point-min)) (search-forward "data/"))
                (save-excursion (goto-char (point-min)) (search-forward "notes.txt")))
             "directories must sort before files"))
