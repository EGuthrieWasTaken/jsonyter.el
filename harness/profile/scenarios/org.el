;;; org.el --- `jy:' source blocks in Org files -*- lexical-binding: t; -*-

;; The claim that makes this mode safe to turn on globally: a block
;; without a `jy:' session is left entirely to Org.  Every scenario here
;; that asserts jsonyter did something is paired with one asserting it
;; did nothing where it had no business acting.

(eh-scenario jsonyter/org-mode-turns-itself-on-only-for-a-file-that-opts-in
  :doc "`jsonyter-org-mode-maybe' on `org-mode-hook' enables the mode
        only in files with a `jy:' session, so adding the hook changes
        the behaviour of no existing Org file."
  :fixture "blocks.org"
  :tags (jsonyter org)

  (eh-expect (bound-and-true-p jsonyter-org-mode)
             "an org file with a jy: block must get jsonyter-org-mode")

  (let ((plain (expand-file-name "plain.org" eh-profile-scratch-dir)))
    (with-temp-file plain
      (insert "#+begin_src python\nprint(1)\n#+end_src\n"))
    (let ((buffer (find-file-noselect plain)))
      (unwind-protect
          (with-current-buffer buffer
            (eh-expect-equal (bound-and-true-p jsonyter-org-mode) nil
                             "an org file with no jy: session must be left alone"))
        (kill-buffer buffer)))))

(eh-scenario jsonyter/org-runs-a-block-into-an-overlay-not-the-file
  :doc "C-RET on a jy: block runs it and the output appears beneath the
        block -- in an overlay, leaving the file untouched until the user
        asks for a #+RESULTS: drawer with C-c C-s."
  :fixture "blocks.org"
  :tags (jsonyter org)

  (let ((before (buffer-string)))
    (goto-char (point-min))
    (search-forward "print(\"first cell\")")
    (eh-send-keys "<C-return>")
    (eh-wait (lambda ()
               (seq-find (lambda (ov)
                           (let ((shown (overlay-get ov 'jsonyter-output-string)))
                             (and shown (string-match-p "first cell" shown))))
                         (overlays-in (point-min) (point-max))))
             20)
    (jy-wait-idle)

    (eh-expect-equal (buffer-string) before
                     "a jy: block's output must not enter the buffer text")
    (eh-expect (not (string-match-p "#\\+RESULTS:" (buffer-string)))
               "running a block must not write a results drawer on its own")
    (eh-expect-equal (buffer-modified-p) nil
                     "running a jy: block must not modify the buffer")))

(eh-scenario jsonyter/org-keeps-two-sessions-in-one-file-apart
  :doc "Two blocks with different `jy:' session names get two kernels,
        and the mode line summarises them rather than reporting one.
        Driving both from one buffer is what jsonyter 2.0 added and is
        the case a single-kernel implementation silently gets wrong."
  :fixture "blocks.org"
  :tags (jsonyter org)

  (goto-char (point-min))
  (search-forward "jy:py")
  (eh-send-keys "<C-return>")
  (eh-wait (lambda () (= (length (jsonyter--session-list)) 1)) 20)
  (jy-wait-idle)

  (goto-char (point-min))
  (search-forward "jy:other")
  (eh-send-keys "<C-return>")
  (eh-wait (lambda () (= (length (jsonyter--session-list)) 2)) 20)
  (jy-wait-idle)

  (eh-expect-equal (length (jsonyter--session-list)) 2
                   "two jy: session names must produce two sessions")
  ;; Point outside every block: the mode line summarises instead of
  ;; reporting whichever session happened to be last.
  (goto-char (point-min))
  (eh-expect-match ":2 kernels" (jsonyter--mode-line-string)))

(eh-scenario jsonyter/org-leaves-a-block-without-a-jy-session-to-org
  :doc "C-RET on a plain `#+begin_src' block is not jsonyter's to run.
        The user-visible half of \"enabling this mode changes nothing for
        files that don't opt in\", and the only way to catch a dispatch
        that grabs every block once the mode is on."
  :fixture "blocks.org"
  :tags (jsonyter org)

  (goto-char (point-min))
  (search-forward "ordinary org babel")
  (eh-expect-equal (jsonyter--org-session-key (jsonyter--org-block-info)) nil
                   "a block with no jy: session must not resolve to a jsonyter session")
  (eh-expect-equal (jsonyter--session-list) nil
                   "and must not have started a kernel"))
