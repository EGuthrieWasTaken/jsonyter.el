;;; kernel-state.el --- the states a real server won't produce on cue -*- lexical-binding: t; -*-

;; Every scenario in this file exists because `eh-fake-bridge' can be
;; told to misbehave and a real Jupyter server cannot (emacs-harness
;; DESIGN 9.2).  Killing a real kernel to see the dead state is racy and
;; destroys the session under test; a half-open socket needs the network
;; actually broken mid-request; "busy on behalf of another client" needs
;; a second client attached at exactly the right moment.  These are also
;; the states a user hits on a bad day, which is to say the ones whose
;; handling is least often exercised and most often wrong.

(eh-scenario jsonyter/kernel-death-is-reported-and-stays-reported
  :doc "A `dead' event arrives with no request of ours in flight.  The
        mode line must say so, the buffer must say what fixes it, and --
        the half that is easy to get wrong -- a kernel that reports
        `idle' on its way out must not undo the verdict."
  :tags (jsonyter kernel-state)

  (jy-use-scripts "dying-kernel.jsonl")
  (jy-start-repl)
  (eh-expect-equal (jy-harness-state) ":idle")

  (eh-wait (lambda () (jy-harness--state-p ":dead")) 20)
  (eh-expect-match "kernel died" (buffer-string))
  (eh-expect-match "C-c C-r" (buffer-string)
                   "the message must name the key that fixes it")

  ;; A status event after the death must not resurrect it.
  (jsonyter--handle-event
   '(:kernel_id "kernel-python-0001"
     :event (:type "status" :execution_state "idle")))
  (eh-expect-equal (jy-harness-state) ":dead"
                   "once dead, a trailing `idle' status must not undo the verdict"))

(eh-scenario jsonyter/a-lost-connection-is-offline-not-dead
  :doc "A dropped socket is not a dead kernel: the kernel is still
        running on the server with all its state, and reconnecting is a
        real thing a user does.  Reporting it as `:dead' would tell them
        to restart and lose that state, which is why the two states are
        distinct and why this is worth pinning."
  :tags (jsonyter kernel-state)

  (jy-use-scripts "lost-connection.jsonl")
  (jy-start-repl)
  (eh-wait (lambda () (jy-harness--state-p ":offline")) 20)
  (eh-expect-match "connection lost" (buffer-string))
  (eh-expect (not (string-match-p "kernel died" (buffer-string)))
             "a lost connection must not be reported as a dead kernel"))

(eh-scenario jsonyter/a-kernel-busy-for-someone-else-reads-differently
  :doc "A `busy' status with no request of ours outstanding means another
        client is using this kernel.  jsonyter distinguishes that
        (`:run[ext]') from our own cell running (`:run'), and telling
        them apart is the difference between \"wait for me\" and \"wait
        for somebody else\"."
  :tags (jsonyter kernel-state)

  (jy-use-scripts "busy-elsewhere.jsonl")
  (jy-start-repl)
  (eh-wait (lambda () (jy-harness--state-p ":run[ext]")) 20)
  (eh-expect-equal (jy-harness-state) ":run[ext]"))

(eh-scenario jsonyter/an-unanswered-request-times-out-instead-of-hanging
  :doc "The SAS kernel never answers `history' at all, and the bridge
        serializes per kernel, so one unanswered message can queue every
        later execute behind it -- the REPL looking hung at \"kernel is
        busy\" forever.  jsonyter bounds these calls on its own side; the
        proof is a backend that accepts the request and says nothing."
  :tags (jsonyter kernel-state)

  (jy-use-scripts "wedged.jsonl")
  (jy-start-repl)

  (let ((jsonyter-request-timeout 1)
        (started (float-time)))
    ;; The command must return, with an error, rather than block forever.
    (eh-expect-no-error
     (condition-case err
         (jsonyter-kernel-history)
       (error (eh-expect-match "no reply" (error-message-string err)))))
    (eh-expect (< (- (float-time) started) 10)
               "an unanswered request must be bounded, not waited on forever"))

  ;; And the session is usable afterwards: a bounded request that left
  ;; the buffer wedged would have solved nothing.
  (eh-expect (jy-harness--bridge-live-p) "the bridge must survive a timeout")
  (eh-expect-equal (jy-harness-state) ":idle"
                   "a timed-out introspection call must not leave the kernel `busy'"))

(eh-scenario jsonyter/a-forbidden-server-says-what-fixes-it
  :doc "A token-protected server answers an unauthenticated request with
        a bare \"Forbidden\" and nothing else -- confirmed empirically,
        per jsonyter's own source.  The bare word tells a user nothing,
        so the error must name the two settings that fix it."
  :tags (jsonyter kernel-state)

  (jy-use-scripts "unauthorized.jsonl")
  (let ((message
         (condition-case err
             (progn (jsonyter-start "python") "no error was signalled")
           (error (error-message-string err)))))
    (eh-expect-match "Forbidden" message)
    (eh-expect-match "jsonyter-server-token" message
                     "a 403 must name the setting that fixes it")))

(eh-scenario jsonyter/an-old-bridge-without-subscribe-still-works
  :doc "`subscribe' is how the mode line learns kernel state, and an
        older bridge does not have it.  jsonyter's contract is that the
        REPL still works and only the mode line goes quiet -- so this
        asserts both halves: the failure is reported and not fatal, and
        a cell still runs afterwards."
  :tags (jsonyter kernel-state)

  (jy-use-scripts "no-subscribe.jsonl")
  (jy-start-repl)
  (eh-expect-messages-match "kernel events unavailable")

  (eh-type-text "6 * 7")
  (eh-send-keys "RET")
  (eh-wait (lambda () (string-match-p "42" (buffer-string))) 20)
  (jy-wait-idle)
  (eh-expect-match "Out\\[2\\]: 42" (buffer-string)))

(eh-scenario jsonyter/backend-stderr-cannot-corrupt-the-protocol
  :doc "jsonyter's claim is that the bridge's stderr goes to a hidden
        buffer, so a Python import warning on it can never be parsed as
        protocol.  Every real bridge produces some of that noise; only a
        fake produces it on demand, continuously, while a cell runs."
  :tags (jsonyter kernel-state)

  (jy-use-scripts "--fault" "stderr-noise")
  (jy-start-repl)
  (eh-type-text "6 * 7")
  (eh-send-keys "RET")
  (eh-wait (lambda () (string-match-p "42" (buffer-string))) 20)
  (jy-wait-idle)

  (eh-expect-match "Out\\[2\\]: 42" (buffer-string)
                   "the protocol must survive a backend chattering on stderr")
  (eh-expect (not (string-match-p "must never be parsed as protocol" (buffer-string)))
             "backend stderr must never reach the REPL buffer")
  (eh-expect (not (string-match-p "unparseable bridge output" (buffer-string)))
             "backend stderr must never reach the protocol parser")
  ;; It did arrive somewhere -- otherwise this scenario proves nothing.
  (let ((stderr (process-get jsonyter--process 'jsonyter-stderr-buffer)))
    (eh-expect (buffer-live-p stderr) "the bridge must have a stderr buffer")
    (eh-expect (string-prefix-p " " (buffer-name stderr))
               "the bridge's stderr buffer must be hidden")
    (eh-wait (lambda () (> (buffer-size stderr) 0)) 5)))

(eh-scenario jsonyter/a-cell-that-asks-for-input-gets-an-answer
  :doc "`input()' mid-execute: the kernel asks, Emacs prompts, and what
        the user typed goes back over the wire.  A real kernel only
        reaches this state with a human sitting there to answer it; the
        harness's prompt guard supplies the answer instead, and the
        fake's `on_input' rule proves it actually arrived."
  :tags (jsonyter kernel-state)

  (jy-use-scripts "streaming.jsonl")
  (jy-start-repl)
  (eh-push-answer "Dave")

  (eh-type-text "ask_for_input()")
  (eh-send-keys "RET")
  (eh-wait (lambda () (string-match-p "the kernel heard you" (buffer-string))) 20)
  (eh-wait (lambda () (jy-harness--state-p ":idle")) 20)
  (eh-expect-match "the kernel heard you" (buffer-string)))
