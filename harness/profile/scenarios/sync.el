;;; sync.el --- directory sync, the interactive paths -*- lexical-binding: t; -*-

;; `test/jsonyter-tests.el' covers the sync logic off a stubbed bridge:
;; pair resolution, plan rendering, override bookkeeping, the
;; destructive-review threshold, and the `:sync' mode-line tag driven by
;; fed `progress' lines.  This scenario drives `jsonyter-sync' end to end
;; through `eh-fake-bridge' (`sync.jsonl'): a plan with nothing
;; destructive in it applies without the review buffer ever appearing,
;; and reports its completion the way a real sync would.
;;
;; As with `transfer.el', the mid-flight `progress' stream (the scan
;; phase, the `:sync I/N' mode-line tag) is not asserted here --
;; `eh-fake-bridge' has no `progress' emit key -- and is instead covered
;; by the batch ERT `jsonyter-test-sync-run-*' tests, which feed real
;; `progress' lines to `jsonyter--dispatch' directly.

(eh-scenario jsonyter/sync-runs-end-to-end-without-review
  :doc "A plan with a single new local file, no conflicts and nothing to
        delete is well under `jsonyter-sync-review-threshold': `jsonyter-sync'
        applies it directly -- the plan buffer is never shown -- and prints
        a completion line naming what moved.  The mode-line transfer tag is
        back to `:idle' afterwards, same as a finished upload."
  :tags (jsonyter sync)

  (jy-use-scripts "sync.jsonl")
  (jy-start-repl)

  (let ((jsonyter-sync-pairs
         (list (list :local eh-profile-scratch-dir :remote "work/synctest"))))
    (jsonyter-sync)
    (jy-wait-idle)

    ;; The completion line: the pair, the direction, the count.
    (eh-expect-messages-match "synced .* <-> work/synctest")
    (eh-expect-messages-match "1 up")
    ;; The mode-line transfer tag is cleared once the sync is done.
    (eh-expect-equal (jy-harness-state) (concat ":idle" jy-harness-kernel-id-suffix))
    ;; Nothing destructive here, so the review buffer never opened.
    (eh-expect
     (not (seq-find (lambda (b) (string-prefix-p "*jsonyter-sync: " (buffer-name b)))
                    (buffer-list)))
     "a non-destructive sync must not open the review buffer")))
