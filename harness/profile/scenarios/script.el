;;; script.el --- `# %%' cells in an ordinary script -*- lexical-binding: t; -*-

;; The distinguishing property of this mode: output lives entirely in
;; overlays, so the file on disk is never touched.  A notebook writes
;; output into the buffer and keeps it read-only; a script must not write
;; it at all.  Those are opposite implementations of the same feature,
;; and asserting the file's bytes is the only thing that tells them apart.

(eh-scenario jsonyter/script-mode-turns-itself-on-for-a-file-with-cells
  :doc "`jsonyter-script-mode-maybe' on a language hook enables the mode
        only where there are `# %%' markers, so adding the hook changes
        nothing about every other script the user opens."
  :fixture "cells.py"
  :tags (jsonyter script)

  (eh-expect (bound-and-true-p jsonyter-script-mode)
             "a python file with `# %%' markers must get script mode")
  (eh-expect (bound-and-true-p jsonyter-mode)
             "script mode must turn the umbrella marker mode on too")

  (with-temp-buffer
    (python-mode)
    (insert "print(\"no cells here\")\n")
    (jsonyter-script-mode-maybe)
    (eh-expect-equal (bound-and-true-p jsonyter-script-mode) nil
                     "a script with no cell markers must be left alone")))

(eh-scenario jsonyter/script-runs-a-cell-into-an-overlay-not-the-file
  :doc "C-RET runs the cell at point and its output appears -- as an
        overlay.  The buffer text, and therefore the file, is unchanged:
        that is the whole contract of this mode."
  :fixture "cells.py"
  :tags (jsonyter script)

  (let ((before (buffer-string)))
    ;; No explicit connect: running a cell is what starts the kernel in
    ;; this mode, and testing the path a user actually takes means not
    ;; setting it up by hand first.
    (goto-char (point-min))
    (search-forward "print(\"first cell\")")
    (eh-send-keys "<C-return>")
    (eh-wait #'jy-harness--kernel-live-p 20)
    (eh-wait (lambda ()
               (seq-some (lambda (ov) (overlay-get ov 'jsonyter-output-string))
                         (overlays-in (point-min) (point-max))))
             20)
    (jy-wait-idle)

    (let ((overlay (seq-find (lambda (ov) (overlay-get ov 'jsonyter-script-cell))
                             (overlays-in (point-min) (point-max)))))
      (eh-expect overlay "running a `# %%' cell must create a cell overlay")
      (eh-expect-match "first cell" (or (overlay-get overlay 'jsonyter-output-string) "")))

    (eh-expect-equal (buffer-string) before
                     "a script cell's output must never enter the buffer text")
    (eh-expect-equal (buffer-modified-p) nil
                     "running a `# %%' cell must not modify the buffer")))

(eh-scenario jsonyter/script-navigates-between-cells
  :doc "C-c C-n / C-c C-p move between `# %%' boundaries, and C-c C-p
        actually moves.

        It did not: `jsonyter--script-cell-bounds' called from a marker
        line resolves to the cell that marker introduces, so stepping
        back exactly one line from a cell's start and asking again
        returned that same cell.  `C-c C-p' was a no-op from anywhere in
        any buffer -- silent, since nothing errors and nothing looks
        wrong until you notice point never moved.  Found by writing this
        scenario; the round trip below is what pins it down."
  :fixture "cells.py"
  :tags (jsonyter script)

  (goto-char (point-min))
  (eh-send-keys "C-c C-n")
  (let ((first (point)))
    (eh-send-keys "C-c C-n")
    (let ((second (point)))
      (eh-expect (> second first) "C-c C-n must advance to the next cell")
      (eh-send-keys "C-c C-n")
      (eh-expect (> (point) second) "C-c C-n must keep advancing")
      (eh-send-keys "C-c C-p")
      (eh-expect-equal (point) second "C-c C-p must go back exactly one cell")
      (eh-send-keys "C-c C-p")
      (eh-expect-equal (point) first "and again, to the one before that")))

  ;; Walking off the front stops at the top rather than wrapping or
  ;; wedging: the bug this scenario exists for looked exactly like
  ;; "wedged", so the boundary case is worth its own assertion.
  (dotimes (_ 5) (eh-send-keys "C-c C-p"))
  (eh-expect-equal (point) (point-min)
                   "walking back past the first cell must stop at the top"))
