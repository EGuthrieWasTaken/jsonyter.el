;;; notebook.el --- rendered .ipynb buffers -*- lexical-binding: t; -*-

;; A notebook buffer is the hardest thing jsonyter does, and the reason
;; the harness exists: cell output is buffer *text* that must be
;; read-only, outside the undo history, outside the language's font-lock,
;; and absent from what a save writes -- four properties that a batch
;; assertion can check but that only a real frame can prove render.

(eh-scenario jsonyter/notebook-renders-its-stored-outputs
  :doc "Opening an .ipynb renders every cell's stored outputs without a
        kernel: text, an `Out[N]' result, and an image all come from the
        file.  A notebook that only renders after a run is useless for
        reading someone else's work."
  :fixture "demo.ipynb"
  :tags (jsonyter notebook)

  (eh-expect (bound-and-true-p jsonyter-notebook-mode)
             "opening an .ipynb must enable notebook mode")
  (eh-expect-equal (length (jy-cells)) 6)
  (eh-expect-match "hello from a stored output" (jy-cell-output-string 1))
  (eh-expect-match "42" (jy-cell-output-string 2))
  ;; No kernel was started, and nothing may have tried to.
  (eh-expect-equal (jy-harness--bridge-live-p) nil
                   "rendering a notebook must not start a bridge"))

(eh-scenario jsonyter/notebook-source-is-editable-and-output-is-not
  :doc "The central claim of the notebook buffer: a cell's source is
        ordinary editable text and its output, sitting in the same
        buffer immediately after it, is not.  `eh-expect-editable' types
        a character through the command loop rather than reading a
        property, because being able to type is the behaviour and the
        property is only the mechanism."
  :fixture "demo.ipynb"
  :tags (jsonyter notebook)

  (eh-expect-read-only (jy-cell-output-region 1)
                       "rendered cell output must be read-only")
  (jy-goto-cell 1)
  (eh-expect-editable (jy-cell-source-region 1)
                      "cell source must still be editable beside its output"))

(eh-scenario jsonyter/notebook-output-is-not-undoable-or-a-modification
  :doc "Rendering output writes buffer text.  If that text landed in the
        undo history or set the modified flag, opening a notebook would
        offer to save a file nobody touched, and one undo would eat the
        output instead of the user's last edit."
  :fixture "demo.ipynb"
  :tags (jsonyter notebook)

  (eh-expect-equal (buffer-modified-p) nil
                   "rendering stored output must not modify the buffer")
  (eh-expect-equal buffer-undo-list nil
                   "rendering stored output must not push undo entries"))

(eh-scenario jsonyter/notebook-runs-a-cell-through-its-key-binding
  :doc "C-RET on a cell runs it and its output lands under that cell and
        no other.  Driven through the keymap: `jsonyter-notebook-run-cell'
        called directly would pass while C-RET itself was unbound."
  :fixture "demo.ipynb"
  :tags (jsonyter notebook)

  (jy-goto-cell 1)
  (eh-send-keys "C-c C-k")              ; start the kernel explicitly
  (eh-wait #'jy-harness--kernel-live-p 20)
  (jy-wait-idle)

  (jy-goto-cell 1)
  (eh-send-keys "<C-return>")
  (eh-wait (lambda () (string-match-p "hello from a stored output"
                                      (jy-cell-output-string 1)))
           20)
  (jy-wait-idle)

  (eh-expect-match "hello from a stored output" (jy-cell-output-string 1))
  (eh-expect-equal (jy-cell-output-string 4) ""
                   "running one cell must not put output under another"))

(eh-scenario jsonyter/notebook-marks-output-stale-when-its-source-changes
  :doc "Editing a cell's source flips its output frame to the stale face,
        and undoing the edit flips it back.  The verdict is a hash
        comparison on every keystroke, so `back again' is the half that
        catches a one-way implementation."
  :fixture "demo.ipynb"
  :tags (jsonyter notebook)

  (let ((cell (jy-cell 1)))
    (eh-expect-equal (overlay-get cell 'jsonyter-output-stale) nil
                     "freshly rendered output is not stale")
    (jy-goto-cell 1)
    ;; Inside the source, not at its very end: `source-end' is the
    ;; boundary itself, and inserting *at* it lands on the read-only
    ;; output rather than in the cell.
    (goto-char (1- (nth 1 (jy-cell-source-region 1))))
    (eh-send-keys "z")
    (eh-expect (overlay-get cell 'jsonyter-output-stale)
               "editing a cell's source must mark its output stale")
    (eh-send-keys "DEL")
    (eh-expect-equal (overlay-get cell 'jsonyter-output-stale) nil
                     "undoing the edit must clear the stale mark again")))

(defun jsonyter-harness--file-bytes (path)
  "PATH's contents as raw bytes, for a byte-for-byte comparison."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally path)
    (buffer-string)))

(eh-scenario jsonyter/notebook-save-says-so-when-there-is-nothing-to-write
  :doc "Running a cell changes no buffer text, so Emacs sees an
        unmodified buffer and `save-buffer' returns without calling any
        save hook -- indistinguishable from a save that failed, which is
        exactly how it looks after re-running cells for new figures.
        C-x C-s must say which of the two happened, and leave the file
        alone either way."
  :fixture "demo.ipynb"
  :tags (jsonyter notebook save)

  (let* ((path buffer-file-name)
         (original (jsonyter-harness--file-bytes path)))
    (eh-send-keys "C-x C-s")
    (eh-expect-messages-match "no changes to save")
    (eh-expect-equal (jsonyter-harness--file-bytes path) original
                     "a save with nothing to write must not touch the file")))

(eh-scenario jsonyter/notebook-save-round-trips-the-file-byte-for-byte
  :doc "The lossless-save claim, judged against the bytes on disk.  This
        one needs the *real* bridge: the file a save produces is written
        by the Python package's own `write_notebook', which merges cell
        source into the stored JSON, and a fixture cannot stand in for a
        file the backend wrote (emacs-harness DESIGN 9.1).  It starts no
        kernel and needs no Jupyter server."
  :fixture "demo.ipynb"
  :needs (:executable "jsonyter")
  :tags (jsonyter notebook save real-bridge)

  (let* ((path buffer-file-name)
         (original (jsonyter-harness--file-bytes path)))
    (jy-use-real-bridge)
    ;; Touch and untouch a cell, so the buffer is modified and the save
    ;; hook actually runs, while what gets written is unchanged source.
    (jy-goto-cell 4)
    (goto-char (1- (nth 1 (jy-cell-source-region 4))))
    (eh-send-keys "z" "DEL")
    (eh-expect (buffer-modified-p) "the buffer must be modified for the save hook to run")
    (eh-send-keys "C-x C-s")
    (jy-wait-idle)
    (eh-expect-equal (jsonyter-harness--file-bytes path) original
                     "an edit-and-undo round trip must leave the file byte-identical")))

(eh-scenario jsonyter/notebook-editing-a-cell-saves-only-that-edit
  :doc "An edit to one cell's source reaches the file; the rendered
        output of every cell does not.  The failure this catches is the
        one jsonyter's own source warns about: a cell whose overlay ran
        past its `source-end' would write its frame rules, resolved ANSI
        text and image placeholders into the .ipynb as code."
  :fixture "demo.ipynb"
  :needs (:executable "jsonyter")
  :tags (jsonyter notebook save real-bridge)

  (let ((path buffer-file-name))
    (jy-use-real-bridge)
    (jy-goto-cell 4)
    (goto-char (1- (nth 1 (jy-cell-source-region 4))))
    (eh-type-text "\ny = 2")
    (eh-send-keys "C-x C-s")
    (jy-wait-idle)

    (let* ((json (with-temp-buffer
                   (insert-file-contents path)
                   (json-parse-buffer :object-type 'plist :array-type 'list)))
           (cells (plist-get json :cells))
           ;; nbformat writes a cell's source as a list of lines, so a
           ;; scenario reading the file back has to join them; comparing
           ;; against the list would silently never match.
           (sources (mapcar (lambda (c)
                              (let ((source (plist-get c :source)))
                                (if (listp source) (apply #'concat source) source)))
                            cells)))
      (eh-expect-match "y = 2" (nth 4 sources)
                       "the edit must have reached the file")
      (dolist (source sources)
        (eh-expect (not (string-match-p "hello from a stored output" source))
                   "rendered output must never be written back as cell source"))
      (eh-expect-equal (length cells) 6
                       "a save must not add or lose cells"))))

(eh-scenario jsonyter/notebook-insert-and-delete-take-their-output-along
  :doc "Structural edits move output with the cell it belongs to.  A cell
        deleted while its output stayed behind leaves orphaned read-only
        text nobody can remove -- and the buffer is unusable from then on."
  :fixture "demo.ipynb"
  :tags (jsonyter notebook)

  (let ((before (length (jy-cells))))
    (jy-goto-cell 1)
    (eh-send-keys "C-c C-i")            ; insert a cell below
    (eh-expect-equal (length (jy-cells)) (1+ before))
    ;; The new cell is empty, and the one it came from kept its output.
    (eh-expect-match "hello from a stored output" (jy-cell-output-string 1))

    (jy-goto-cell 2)
    (eh-send-keys "C-c C-w")            ; delete it again
    (eh-expect-equal (length (jy-cells)) before)
    (eh-expect (not (string-match-p "hello from a stored output"
                                    (jy-cell-output-string 2)))
               "a deleted cell must not leave its output behind")))

(eh-scenario jsonyter/notebook-clear-all-output-leaves-plain-source
  :doc "C-c M-O removes every rendered output, and what is left is source
        text with none of the read-only spans still in it."
  :fixture "demo.ipynb"
  :tags (jsonyter notebook)

  (eh-send-keys "C-c M-O")
  (eh-expect (not (string-match-p "hello from a stored output" (buffer-string)))
             "cleared output must be gone")
  (eh-expect-equal (text-property-not-all (point-min) (point-max) 'read-only nil)
                   nil
                   "nothing may still be read-only once every output is cleared"))

(eh-scenario jsonyter/notebook-renders-a-traceback-from-a-run
  :doc "A cell that raises renders its traceback under that cell, with
        the kernel's ANSI escapes resolved rather than shown."
  :fixture "demo.ipynb"
  :tags (jsonyter notebook)

  (eh-send-keys "C-c C-k")
  (eh-wait #'jy-harness--kernel-live-p 20)
  (jy-wait-idle)

  (jy-goto-cell 5)
  (eh-send-keys "<C-return>")
  (eh-wait (lambda () (string-match-p "ValueError" (jy-cell-output-string 5))) 20)
  (jy-wait-idle)

  (eh-expect-match "boom" (jy-cell-output-string 5))
  (eh-expect (not (string-match-p "\\[0;31m" (jy-cell-output-string 5)))
             "ANSI escapes must be resolved, not rendered literally"))

(eh-scenario jsonyter/notebook-toggling-a-cell-to-markdown-clears-its-output
  :doc "A markdown cell cannot have output.  Toggling a code cell that
        has some must therefore drop it, not leave read-only text stranded
        under a cell that can never regenerate it."
  :fixture "demo.ipynb"
  :tags (jsonyter notebook)

  (jy-goto-cell 1)
  (eh-send-keys "C-c C-t")
  (eh-expect-equal (overlay-get (jy-cell 1) 'jsonyter-cell-type) "markdown")
  (eh-expect-equal (jy-cell-output-string 1) ""
                   "a markdown cell must not keep the output it had as code"))
