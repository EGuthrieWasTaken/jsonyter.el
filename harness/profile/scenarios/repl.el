;;; repl.el --- the REPL buffer, driven through the command loop -*- lexical-binding: t; -*-

;; Everything here goes through `eh-send-keys' / `eh-type-text' rather
;; than calling `jsonyter--execute' directly.  Calling the function
;; exercises neither the keymap nor the command loop, and would pass
;; happily while RET itself was unbound (emacs-harness AGENTS.md 5).

(eh-scenario jsonyter/repl-starts-and-reports-its-kernel
  :doc "Starting a REPL resolves a kernel spec by language, starts the
        kernel, subscribes to its events, and lands on an idle prompt --
        the whole connection lifecycle, in the order a real one happens."
  :tags (jsonyter repl)

  (jy-start-repl)
  (eh-expect-match "Jupyter REPL" (buffer-string))
  ;; base.jsonl offers a python and an R spec and names python3 the
  ;; server default; resolving by declared language is the thing under
  ;; test, so assert on which one came back.
  (eh-expect-match "kernel python3" (buffer-string))
  (eh-expect-equal (jy-harness-state) ":idle"))

(eh-scenario jsonyter/repl-sends-input-and-renders-stdout
  :doc "RET sends the current input and the kernel's stdout is rendered
        into the buffer.  The input that was sent becomes read-only; what
        comes after the new prompt does not."
  :tags (jsonyter repl)

  (jy-start-repl)
  (eh-type-text "print(\"first cell\")")
  (eh-send-keys "RET")
  (eh-wait (lambda () (string-match-p "first cell\n" (buffer-string))) 20)
  (jy-wait-idle)

  (eh-expect-match "first cell" (buffer-string))
  (eh-expect-equal (jy-harness-state) ":idle")
  ;; The sent input is frozen; the fresh input area is not.  Both halves
  ;; matter: a REPL that froze everything would pass the first assertion
  ;; alone and be unusable.
  (save-excursion
    (goto-char (point-min))
    (search-forward "print(\"first cell\")")
    (eh-expect-read-only (list (match-beginning 0) (match-end 0))
                         "input, once sent, must not be editable"))
  (goto-char (point-max))
  (eh-expect-editable (list (point-max) (point-max))
                      "the live input area must still accept typing"))

(eh-scenario jsonyter/repl-renders-an-execute-result-with-its-prompt
  :doc "An execute_result is not a stream: it gets an `Out[N]:' prompt,
        faced, and the execution count follows the kernel's."
  :tags (jsonyter repl)

  (jy-start-repl)
  (eh-type-text "6 * 7")
  (eh-send-keys "RET")
  (eh-wait (lambda () (string-match-p "Out\\[2\\]: 42" (buffer-string))) 20)
  (jy-wait-idle)

  (save-excursion
    (goto-char (point-min))
    (search-forward "Out[2]:")
    (eh-expect-face (match-beginning 0) 'jsonyter-output-prompt-face)))

(eh-scenario jsonyter/repl-shows-output-while-the-kernel-is-still-busy
  :doc "The claim is that a long-running cell shows its print output
        live.  A REPL that buffered everything until the final reply
        would look identical once the cell finished, so the assertion has
        to land *during* the run: first chunk visible, kernel still
        reporting `:run'."
  :tags (jsonyter repl streaming)

  (jy-use-scripts "streaming.jsonl")
  (jy-start-repl)
  (eh-type-text "slow_loop()")
  (eh-send-keys "RET")

  (eh-wait (lambda () (string-match-p "step 1" (buffer-string))) 20)
  (eh-expect-equal (jy-harness-state) ":run"
                   "the first chunk must be on screen before the cell finishes")
  (eh-expect (not (string-match-p "step 3" (buffer-string)))
             "the last chunk cannot have arrived yet -- this scenario is not testing anything if it has")

  (eh-wait (lambda () (string-match-p "step 3" (buffer-string))) 20)
  (jy-wait-idle)
  (eh-expect-equal (jy-harness-state) ":idle")
  ;; Order, not just presence: chunks rendered out of order would still
  ;; contain all three strings.
  (let ((text (buffer-string)))
    (eh-expect (< (string-match "step 1" text)
                  (string-match "step 2" text)
                  (string-match "step 3" text))
               "streamed chunks must render in arrival order")))

(eh-scenario jsonyter/repl-does-not-double-render-a-streamed-cell
  :doc "The final reply repeats every chunk the bridge already streamed.
        Rendering the reply's outputs wholesale would print everything
        twice -- the reconciliation bug this counts, rather than merely
        looks for the text."
  :tags (jsonyter repl streaming)

  (jy-use-scripts "streaming.jsonl")
  (jy-start-repl)
  (eh-type-text "slow_loop()")
  (eh-send-keys "RET")
  (eh-wait (lambda () (string-match-p "step 3" (buffer-string))) 20)
  (jy-wait-idle)

  (let ((count 0) (start 0) (text (buffer-string)))
    (while (string-match "step 1" text start)
      (setq count (1+ count) start (match-end 0)))
    (eh-expect-equal count 1 "each streamed chunk must be rendered exactly once")))

(eh-scenario jsonyter/repl-faces-stderr-differently-from-stdout
  :doc "stderr and stdout are both `stream' outputs and differ only by a
        `name' field.  Rendering them the same way is an easy bug and an
        invisible one without a face assertion."
  :tags (jsonyter repl)

  (jy-start-repl)
  (eh-type-text "warn_about_something()")
  (eh-send-keys "RET")
  (eh-wait (lambda () (string-match-p "UserWarning" (buffer-string))) 20)
  (jy-wait-idle)

  (save-excursion
    (goto-char (point-min))
    (search-forward "UserWarning")
    (eh-expect-face (match-beginning 0) 'jsonyter-stderr-face)))

(eh-scenario jsonyter/repl-renders-a-traceback
  :doc "An error output arrives as a list of traceback lines carrying raw
        ANSI escapes.  The escapes must be resolved into faces, not left
        as literal text -- `ESC[0;31m' on screen is the failure this
        catches."
  :tags (jsonyter repl)

  (jy-start-repl)
  (eh-type-text "raise ValueError(\"boom\")")
  (eh-send-keys "RET")
  (eh-wait (lambda () (string-match-p "ValueError" (buffer-string))) 20)
  (jy-wait-idle)

  (eh-expect-match "boom" (buffer-string))
  (eh-expect (not (string-match-p "\\[0;31m" (buffer-string)))
             "ANSI escapes must be resolved, not rendered literally"))

(eh-scenario jsonyter/repl-continues-input-the-kernel-calls-incomplete
  :doc "RET on incomplete input opens a new line instead of sending, and
        the buffer's idea of \"the current input\" spans both lines.
        M-RET forces the send regardless -- the escape hatch for a kernel
        that gets is_complete wrong."
  :tags (jsonyter repl)

  (jy-start-repl)
  (eh-type-text "if True:")
  (eh-send-keys "RET")
  (jy-wait-idle)

  ;; Nothing was sent: no output, and the kernel is still idle.
  (eh-expect (not (string-match-p "first cell" (buffer-string)))
             "incomplete input must not have been executed")
  (eh-expect-equal (jy-harness-state) ":idle")
  (eh-expect-match "if True:" (jsonyter--current-input))
  (eh-expect-match "\n" (jsonyter--current-input)
                   "RET on incomplete input must have opened a continuation line"))

(eh-scenario jsonyter/repl-cycles-input-history
  :doc "M-p/M-n walk the history and restore the half-typed input that
        was stashed on the way in -- losing that stash is the bug users
        actually notice."
  :tags (jsonyter repl)

  (jy-start-repl)
  (eh-type-text "6 * 7")
  (eh-send-keys "RET")
  (eh-wait (lambda () (string-match-p "42" (buffer-string))) 20)
  (jy-wait-idle)

  (eh-type-text "half typed")
  (eh-send-keys "M-p")
  (eh-expect-equal (jsonyter--current-input) "6 * 7")
  (eh-send-keys "M-n")
  (eh-expect-equal (jsonyter--current-input) "half typed"
                   "leaving the history must restore what was stashed"))

(eh-scenario jsonyter/repl-completes-at-point-from-the-kernel
  :doc "TAB is `completion-at-point' backed by the kernel's own
        `complete' reply, including the cursor_start/cursor_end bounds
        that decide what gets replaced."
  :tags (jsonyter repl)

  (jy-start-repl)
  (eh-type-text "pri")
  (let ((capf (jsonyter-completion-at-point)))
    (eh-expect capf "no completion offered at point")
    (eh-expect-equal (nth 2 capf) '("print" "printf" "prio"))
    (eh-expect-equal (nth 0 capf) (marker-position jsonyter--input-start)
                     "completion must start where the kernel said it does")))

(eh-scenario jsonyter/repl-clears-previous-output-but-keeps-the-prompt
  :doc "C-c M-o clears what has been printed without destroying the live
        input area or the read-only-ness of what remains."
  :tags (jsonyter repl)

  (jy-start-repl)
  (eh-type-text "print(\"first cell\")")
  (eh-send-keys "RET")
  (eh-wait (lambda () (string-match-p "first cell\n" (buffer-string))) 20)
  (jy-wait-idle)

  (eh-send-keys "C-c M-o")
  (eh-expect (not (string-match-p "first cell" (buffer-string)))
             "cleared output must be gone from the buffer")
  (goto-char (point-max))
  (eh-expect-editable (list (point-max) (point-max))
                      "clearing output must leave a usable input area"))

(eh-scenario jsonyter/repl-restart-asks-first-and-resets-the-count
  :doc "C-c C-r is destructive, so it asks.  Answering yes restarts the
        kernel, re-subscribes to its events, and resets the execution
        count -- and the prompt guard is what makes the question
        assertable rather than a hang."
  :tags (jsonyter repl)

  (jy-start-repl)
  (eh-type-text "6 * 7")
  (eh-send-keys "RET")
  (eh-wait (lambda () (string-match-p "Out\\[2\\]" (buffer-string))) 20)
  (jy-wait-idle)
  (eh-expect-equal jsonyter--execution-count 2)

  (eh-push-answer 'yes)
  (eh-send-keys "C-c C-r")
  (jy-wait-idle)

  (eh-expect-equal jsonyter--execution-count 0
                   "a restart must reset the execution count")
  (eh-expect-match "restarted" (buffer-string))
  (eh-expect-equal (jy-harness-state) ":idle"
                   "a restarted kernel must re-subscribe, or the mode line goes quiet"))
