;;; jsonyter-tests.el --- Tests for jsonyter.el -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;
;;   emacs -Q --batch -L . -l test/jsonyter-tests.el \
;;         -f ert-run-tests-batch-and-exit
;;
;; The tests that save a notebook drive the real `jsonyter' Python
;; bridge, which handles `.ipynb' files locally and needs no Jupyter
;; server; they skip themselves when it is not installed.  Nothing here
;; ever starts a kernel: a cell's results are fed in directly, in the
;; shape the kernel would have sent them.

;;; Code:

(require 'ert)
(require 'json)
(require 'cl-lib)
(require 'jsonyter)

;; `-Q' has no `auto-mode-alist' entry for notebooks; the tests open
;; real `.ipynb' files, so register the one the README tells users to.
(add-to-list 'auto-mode-alist '("\\.ipynb\\'" . jsonyter-notebook-open))

;;;; Fixtures

(defconst jsonyter-tests--notebook "\
{
 \"cells\": [
  {\"cell_type\": \"code\", \"id\": \"aaa\", \"execution_count\": null,
   \"metadata\": {}, \"outputs\": [], \"source\": \"x = 1\\n\"},
  {\"cell_type\": \"code\", \"id\": \"bbb\", \"execution_count\": null,
   \"metadata\": {}, \"outputs\": [], \"source\": \"print(x)\\n\"},
  {\"cell_type\": \"markdown\", \"id\": \"ccc\",
   \"metadata\": {}, \"source\": \"# heading\\n\"}
 ],
 \"metadata\": {\"kernelspec\": {\"display_name\": \"Python 3\",
                            \"language\": \"python\", \"name\": \"python3\"}},
 \"nbformat\": 4,
 \"nbformat_minor\": 5
}
"
  "A three-cell notebook: two code cells and a markdown one.
Written out verbatim rather than encoded from a Lisp value, so that what
the tests open is exactly what a real `.ipynb' file looks like — and so
that a save can be judged against it byte for byte.")

(defun jsonyter-tests--write-notebook (path)
  "Write the fixture notebook to PATH."
  (with-temp-file path (insert jsonyter-tests--notebook)))

(defmacro jsonyter-tests--with-notebook (&rest body)
  "Open the fixture notebook in a temp file and run BODY in its buffer.
`path' is bound to the file, so BODY can read back what a save wrote."
  (declare (indent 0) (debug t))
  `(let* ((path (make-temp-file "jsonyter-test-" nil ".ipynb"))
          (buffer nil))
     (unwind-protect
         (progn
           (jsonyter-tests--write-notebook path)
           (setq buffer (find-file-noselect path))
           (with-current-buffer buffer ,@body))
       (when (buffer-live-p buffer)
         (with-current-buffer buffer (set-buffer-modified-p nil))
         (kill-buffer buffer))
       (delete-file path))))

(defconst jsonyter-tests--notebook-with-outputs "\
{
 \"cells\": [
  {\"cell_type\": \"code\", \"id\": \"aaa\", \"execution_count\": 1,
   \"metadata\": {},
   \"outputs\": [{\"output_type\": \"stream\", \"name\": \"stdout\",
                \"text\": [\"stored one\\n\", \"stored two\\n\"]}],
   \"source\": \"x = 1\\n\"},
  {\"cell_type\": \"code\", \"id\": \"bbb\", \"execution_count\": 2,
   \"metadata\": {},
   \"outputs\": [{\"output_type\": \"stream\", \"name\": \"stdout\",
                \"text\": \"stored three\\n\"}],
   \"source\": \"print(x)\\n\"}
 ],
 \"metadata\": {\"kernelspec\": {\"display_name\": \"Python 3\",
                            \"language\": \"python\", \"name\": \"python3\"}},
 \"nbformat\": 4,
 \"nbformat_minor\": 5
}
"
  "Two code cells whose results are already saved in the file.")

(defun jsonyter-tests--cell (n)
  "The Nth cell overlay, counting from zero."
  (nth n (jsonyter--nb-cells)))

(defun jsonyter-tests--output-text (cell)
  "The buffer text CELL shows as its output."
  (buffer-substring-no-properties
   (marker-position (overlay-get cell 'jsonyter-source-end))
   (overlay-end cell)))

(defun jsonyter-tests--stream (text)
  "A kernel stream output carrying TEXT."
  (list :type "stream" :name "stdout" :text text))

(defun jsonyter-tests--png (base64)
  "A kernel display_data output carrying BASE64 as a PNG."
  (list :type "display_data" :data (list :image/png base64) :metadata nil))

(defmacro jsonyter-tests--with-fake-display (height line-height &rest body)
  "Run BODY as though on a graphical display showing HEIGHT-pixel images.
LINE-HEIGHT is the pixel height a text line is reported to have, so a
sliced image is expected to occupy HEIGHT/LINE-HEIGHT of them."
  (declare (indent 2) (debug t))
  `(cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
             ((symbol-function 'display-images-p) (lambda (&rest _) t))
             ((symbol-function 'image-type-available-p) (lambda (&rest _) t))
             ((symbol-function 'image-size) (lambda (&rest _) (cons 400.0 (float ,height))))
             ((symbol-function 'default-font-height) (lambda (&rest _) ,line-height)))
     ,@body))

(defun jsonyter-tests--bridge-available-p ()
  "Non-nil if the jsonyter Python package can be run as a bridge."
  (eq 0 (call-process "python3" nil nil nil "-c" "import jsonyter")))

(defun jsonyter-tests--saved-sources (path)
  "The `source' of every cell in the notebook file at PATH."
  (let* ((json-object-type 'alist)
         (nb (json-read-file path)))
    (mapcar (lambda (cell)
              (let ((source (alist-get 'source cell)))
                (if (stringp source) source (mapconcat #'identity source ""))))
            (append (alist-get 'cells nb) nil))))

;;;; Source and output are separate regions

(ert-deftest jsonyter-test-cell-source-excludes-output ()
  "A cell's source is what was typed, whatever it has since printed."
  (jsonyter-tests--with-notebook
    (let ((cell (jsonyter-tests--cell 0)))
      (should (equal (jsonyter--nb-cell-source cell) "x = 1"))
      (jsonyter--nb-set-output cell "hello from the kernel\n" nil t)
      (should (equal (jsonyter--nb-cell-source cell) "x = 1"))
      ;; ...and the output really is in the buffer, not on the overlay.
      (should (null (overlay-get cell 'after-string)))
      (should (string-match-p "hello from the kernel"
                              (jsonyter-tests--output-text cell)))
      (should (> (overlay-end cell)
                 (marker-position (overlay-get cell 'jsonyter-source-end)))))))

(ert-deftest jsonyter-test-output-is-scrollable-lines ()
  "Output occupies as many buffer lines as it has newlines.
This is the whole point of the change: `next-line' and
`scroll-up-command' move point, and point can only stop on a line that
is really in the buffer."
  (jsonyter-tests--with-notebook
    (let ((cell (jsonyter-tests--cell 0)))
      (jsonyter--nb-set-output cell "one\ntwo\nthree\n" nil t)
      (let* ((start (marker-position (overlay-get cell 'jsonyter-source-end)))
             (end (overlay-end cell)))
        ;; three lines of text, plus the rule above and the rule below.
        (should (= 5 (count-lines start end)))
        ;; Point can be put on each of them.
        (goto-char start)
        (dotimes (_ 4) (should (= 0 (forward-line 1))))
        (should (<= (point) end))))))

(ert-deftest jsonyter-test-empty-output-leaves-no-text ()
  "A cell with no output contributes no buffer text at all."
  (jsonyter-tests--with-notebook
    (let ((cell (jsonyter-tests--cell 0)))
      (should (= (overlay-end cell)
                 (marker-position (overlay-get cell 'jsonyter-source-end))))
      (jsonyter--nb-set-output cell "something\n" nil t)
      (should (> (overlay-end cell)
                 (marker-position (overlay-get cell 'jsonyter-source-end))))
      (jsonyter--nb-set-output cell "" nil t)
      (should (= (overlay-end cell)
                 (marker-position (overlay-get cell 'jsonyter-source-end))))
      (should (equal "" (jsonyter-tests--output-text cell))))))

(ert-deftest jsonyter-test-cells-stay-back-to-back ()
  "Rendering output never lets the next cell swallow it."
  (jsonyter-tests--with-notebook
    (let ((first (jsonyter-tests--cell 0))
          (second (jsonyter-tests--cell 1)))
      (jsonyter--nb-set-output first "printed\n" nil t)
      (should (= (overlay-end first) (overlay-start second)))
      (should (equal (jsonyter--nb-cell-source second) "print(x)"))
      ;; And again when the output is replaced with a longer one.
      (jsonyter--nb-set-output first "printed\nmore\nand more\n" nil t)
      (should (= (overlay-end first) (overlay-start second)))
      (should (equal (jsonyter--nb-cell-source second) "print(x)")))))

;;;; Image slicing now reaches notebook cells

(ert-deftest jsonyter-test-notebook-image-is-sliced ()
  "A tall image in a notebook cell is spread over one line per row."
  (jsonyter-tests--with-notebook
    (jsonyter-tests--with-fake-display 300 15
      (let ((cell (jsonyter-tests--cell 0)))
        (jsonyter--nb-append-output
         cell (jsonyter-tests--png (base64-encode-string "not really a png")))
        (let ((text (jsonyter-tests--output-text cell)))
          ;; 300px over 15px lines is 20 slices, between the two rules.
          (should (= 22 (length (split-string text "\n" t)))))))))

(ert-deftest jsonyter-test-slicing-can-be-turned-off ()
  "With `jsonyter-slice-images' nil the image is one whole glyph."
  (jsonyter-tests--with-notebook
    (jsonyter-tests--with-fake-display 300 15
      (let ((jsonyter-slice-images nil)
            (cell (jsonyter-tests--cell 0)))
        (jsonyter--nb-append-output
         cell (jsonyter-tests--png (base64-encode-string "not really a png")))
        (let ((text (jsonyter-tests--output-text cell)))
          (should (= 3 (length (split-string text "\n" t)))))))))

(ert-deftest jsonyter-test-repl-image-is-still-sliced ()
  "The REPL path, which already worked, is unchanged."
  (jsonyter-tests--with-fake-display 300 15
    (with-temp-buffer
      (jsonyter--insert-image (create-image "x" 'png t) "[png image]")
      (should (= 20 (count-lines (point-min) (point-max)))))))

(ert-deftest jsonyter-test-script-image-is-not-sliced ()
  "A script cell's output is still an overlay string, so it is unsliced."
  (jsonyter-tests--with-fake-display 300 15
    (with-temp-buffer
      (insert "# %%\nprint(1)\n")
      (let ((ov (make-overlay (point-max) (point-max))))
        (overlay-put ov 'jsonyter-script-cell t)
        (jsonyter--nb-append-output
         ov (jsonyter-tests--png (base64-encode-string "not really a png")))
        ;; Nothing was written into the buffer...
        (should (equal (buffer-string) "# %%\nprint(1)\n"))
        ;; ...and the overlay string holds one image, not twenty slices.
        (should (= 3 (length (split-string (overlay-get ov 'after-string)
                                           "\n" t))))))))

;;;; Output is protected, but readable

(ert-deftest jsonyter-test-output-is-read-only ()
  "Output cannot be typed into or deleted, but can be copied."
  (jsonyter-tests--with-notebook
    (let* ((cell (jsonyter-tests--cell 0)))
      (jsonyter--nb-set-output cell "results\n" nil t)
      (let ((src-end (marker-position (overlay-get cell 'jsonyter-source-end)))
            (end (overlay-end cell)))
        (goto-char (1+ src-end))
        (should-error (insert "x") :type 'text-read-only)
        (should-error (delete-char 1) :type 'text-read-only)
        (should-error (kill-region (1+ src-end) (1- end)) :type 'text-read-only)
        ;; Typing at the boundary is refused rather than silently
        ;; joining the source.
        (goto-char src-end)
        (should-error (insert "x") :type 'text-read-only)
        ;; Copying is not.
        (let ((kill-ring nil))
          (copy-region-as-kill src-end end)
          (should (string-match-p "results" (current-kill 0))))))))

(ert-deftest jsonyter-test-source-stays-editable-beside-output ()
  "The source's own last line is still editable once output is below it."
  (jsonyter-tests--with-notebook
    (let ((cell (jsonyter-tests--cell 0)))
      (jsonyter--nb-set-output cell "results\n" nil t)
      (goto-char (1- (marker-position (overlay-get cell 'jsonyter-source-end))))
      (insert " + 1")
      (should (equal (jsonyter--nb-cell-source cell) "x = 1 + 1"))
      ;; The source-end marker followed the insertion.
      (should (string-prefix-p "output"
                               (string-trim-left
                                (jsonyter-tests--output-text cell)))))))

;;;; Cell commands

(ert-deftest jsonyter-test-insert-cell-below-clears-the-output ()
  "A cell inserted below one that has run lands after its output."
  (jsonyter-tests--with-notebook
    (let ((cell (jsonyter-tests--cell 0)))
      (jsonyter--nb-set-output cell "results\n" nil t)
      (goto-char (overlay-start cell))
      (jsonyter-insert-cell-below)
      (let ((new (jsonyter-tests--cell 1)))
        (should (= (overlay-start new) (overlay-end cell)))
        (should (equal (jsonyter--nb-cell-source new) ""))
        ;; The output still belongs to the cell that produced it.
        (should (string-match-p "results" (jsonyter-tests--output-text cell)))
        (should (equal "" (jsonyter-tests--output-text new)))))))

(ert-deftest jsonyter-test-insert-cell-above-clears-the-output ()
  "A cell inserted above another lands before its source, not in it."
  (jsonyter-tests--with-notebook
    (let ((first (jsonyter-tests--cell 0)))
      (jsonyter--nb-set-output first "results\n" nil t)
      (goto-char (overlay-start (jsonyter-tests--cell 1)))
      (jsonyter-insert-cell-above)
      (let ((new (jsonyter-tests--cell 1)))
        (should (equal (jsonyter--nb-cell-source new) ""))
        (should (= (overlay-end first) (overlay-start new)))
        (should (equal (jsonyter--nb-cell-source (jsonyter-tests--cell 2))
                       "print(x)"))))))

(ert-deftest jsonyter-test-delete-cell-takes-its-output ()
  "Deleting a cell removes its output too, leaving nothing read-only."
  (jsonyter-tests--with-notebook
    (let ((cell (jsonyter-tests--cell 0)))
      (jsonyter--nb-set-output cell "results\n" nil t)
      (goto-char (overlay-start cell))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (jsonyter-delete-cell))
      (should (= 2 (length (jsonyter--nb-cells))))
      (should-not (string-match-p "results" (buffer-string)))
      (should-not (text-property-not-all (point-min) (point-max) 'read-only nil))
      (should (equal (jsonyter--nb-cell-source (jsonyter-tests--cell 0))
                     "print(x)")))))

(ert-deftest jsonyter-test-toggle-to-markdown-clears-output ()
  "A code cell turned into markdown loses its output text entirely."
  (jsonyter-tests--with-notebook
    (let ((cell (jsonyter-tests--cell 0)))
      (jsonyter--nb-set-output cell "results\n" nil t)
      (goto-char (overlay-start cell))
      (jsonyter-toggle-cell-type)
      (should (equal (overlay-get cell 'jsonyter-cell-type) "markdown"))
      (should (equal "" (jsonyter-tests--output-text cell)))
      (should-not (string-match-p "results" (buffer-string)))
      (should-not (text-property-not-all (point-min) (point-max) 'read-only nil)))))

(ert-deftest jsonyter-test-move-cell-carries-its-output ()
  "Moving a cell moves its output with it, still correctly attributed."
  (jsonyter-tests--with-notebook
    (let ((first (jsonyter-tests--cell 0))
          (second (jsonyter-tests--cell 1)))
      (jsonyter--nb-set-output first "from the first\n" nil t)
      (jsonyter--nb-set-output second "from the second\n" nil t)
      (goto-char (overlay-start first))
      (jsonyter-move-cell-down)
      (let ((a (jsonyter-tests--cell 0))
            (b (jsonyter-tests--cell 1)))
        (should (equal (jsonyter--nb-cell-source a) "print(x)"))
        (should (equal (jsonyter--nb-cell-source b) "x = 1"))
        (should (string-match-p "from the second" (jsonyter-tests--output-text a)))
        (should (string-match-p "from the first" (jsonyter-tests--output-text b)))
        (should (= (overlay-end a) (overlay-start b)))
        ;; And back again.
        (goto-char (overlay-start b))
        (jsonyter-move-cell-up)
        (should (equal (jsonyter--nb-cell-source (jsonyter-tests--cell 0)) "x = 1"))
        (should (string-match-p "from the first"
                                (jsonyter-tests--output-text
                                 (jsonyter-tests--cell 0))))))))

;;;; Staleness

(ert-deftest jsonyter-test-editing-source-marks-output-stale ()
  "Editing a cell flags its output stale; undoing the edit clears it."
  (jsonyter-tests--with-notebook
    (buffer-enable-undo)
    (let ((cell (jsonyter-tests--cell 0)))
      (overlay-put cell 'jsonyter-source-hash
                   (jsonyter--source-hash (jsonyter--nb-cell-source cell)))
      (jsonyter--nb-set-output cell "results\n" nil t)
      (should-not (overlay-get cell 'jsonyter-output-stale))
      (goto-char (1- (marker-position (overlay-get cell 'jsonyter-source-end))))
      (insert " + 1")
      (should (overlay-get cell 'jsonyter-output-stale))
      (should (string-match-p "stale" (jsonyter-tests--output-text cell)))
      (primitive-undo 1 buffer-undo-list)
      (should (equal (jsonyter--nb-cell-source cell) "x = 1"))
      (should-not (overlay-get cell 'jsonyter-output-stale))
      (should-not (string-match-p "stale" (jsonyter-tests--output-text cell))))))

;;;; Undo

(ert-deftest jsonyter-test-output-is-not-undoable ()
  "Rendering output adds nothing to the undo history."
  (jsonyter-tests--with-notebook
    (buffer-enable-undo)
    (setq buffer-undo-list nil)
    (let ((cell (jsonyter-tests--cell 0)))
      (jsonyter--nb-set-output cell "results\n" nil t)
      (should (null buffer-undo-list))
      (should-not (buffer-modified-p)))))

(ert-deftest jsonyter-test-undo-of-an-earlier-edit-survives-a-run ()
  "An edit before a cell's output can still be undone after it runs."
  (jsonyter-tests--with-notebook
    (buffer-enable-undo)
    (let ((cell (jsonyter-tests--cell 0)))
      (goto-char (1- (marker-position (overlay-get cell 'jsonyter-source-end))))
      (insert " + 1")
      (should (equal (jsonyter--nb-cell-source cell) "x = 1 + 1"))
      (jsonyter--nb-set-output cell "results\n" nil t)
      (primitive-undo 1 buffer-undo-list)
      (should (equal (jsonyter--nb-cell-source cell) "x = 1"))
      ;; The output is still where it was, and still owned by the cell.
      (should (string-match-p "results" (jsonyter-tests--output-text cell))))))

(ert-deftest jsonyter-test-undo-entries-past-new-output-are-dropped ()
  "An edit after a cell's output is forgotten rather than misapplied."
  (jsonyter-tests--with-notebook
    (buffer-enable-undo)
    (setq buffer-undo-list nil)
    (let ((first (jsonyter-tests--cell 0))
          (second (jsonyter-tests--cell 1)))
      ;; Edit the *second* cell, then run the first.  The output shifts
      ;; every position after it, so replaying that edit where it was
      ;; recorded would land in the wrong text.
      (goto-char (1- (marker-position (overlay-get second 'jsonyter-source-end))))
      (insert ", x")
      (should buffer-undo-list)
      (jsonyter--nb-set-output first "results\n" nil t)
      (should (null buffer-undo-list))
      ;; The edit itself stands; only the ability to undo it is gone.
      (should (equal (jsonyter--nb-cell-source second) "print(x), x")))))

(ert-deftest jsonyter-test-undo-entry-classification ()
  "`jsonyter--undo-entry-before-p' reads each kind of undo entry."
  (should (jsonyter--undo-entry-before-p nil 10))              ; boundary
  (should (jsonyter--undo-entry-before-p '(t . 0) 10))         ; modtime
  (should (jsonyter--undo-entry-before-p 5 10))                ; point
  (should-not (jsonyter--undo-entry-before-p 50 10))
  (should (jsonyter--undo-entry-before-p '(2 . 5) 10))         ; insertion
  (should-not (jsonyter--undo-entry-before-p '(2 . 50) 10))
  (should (jsonyter--undo-entry-before-p '("hi" . 5) 10))      ; deletion
  (should-not (jsonyter--undo-entry-before-p '("hi" . -50) 10))
  (should (jsonyter--undo-entry-before-p '(nil face nil 2 . 5) 10))
  (should-not (jsonyter--undo-entry-before-p '(nil face nil 2 . 50) 10))
  (should (jsonyter--undo-entry-before-p (cons (make-marker) 3) 10))
  (should (jsonyter--undo-entry-before-p '(apply 0 2 5 ignore) 10))
  (should-not (jsonyter--undo-entry-before-p '(apply 0 2 50 ignore) 10))
  ;; An `apply' form with no declared range cannot be shown to be safe.
  (should-not (jsonyter--undo-entry-before-p '(apply ignore) 10)))

;;;; clear_output

(ert-deftest jsonyter-test-clear-output-redraws-in-place ()
  "`clear_output' replaces the output rather than accumulating frames."
  (jsonyter-tests--with-notebook
    (let ((cell (jsonyter-tests--cell 0)))
      (jsonyter--nb-append-output cell (jsonyter-tests--stream "frame 1\n"))
      (jsonyter--nb-append-output cell (list :type "clear_output" :wait t))
      (jsonyter--nb-append-output cell (jsonyter-tests--stream "frame 2\n"))
      (let ((text (jsonyter-tests--output-text cell)))
        (should (string-match-p "frame 2" text))
        (should-not (string-match-p "frame 1" text))
        ;; One frame, not two stacked.
        (should (= 3 (length (split-string text "\n" t))))))))

;;;; Font lock

(ert-deftest jsonyter-test-font-lock-leaves-output-alone ()
  "The language's font-lock does not repaint or strip output faces."
  (jsonyter-tests--with-notebook
    (let ((cell (jsonyter-tests--cell 0)))
      ;; Output that reads exactly like Python source, so any
      ;; fontification of it would be unmistakable.
      (jsonyter--nb-set-output
       cell (propertize "import os\n" 'face 'jsonyter-stderr-face) nil t)
      (font-lock-mode 1)
      (font-lock-ensure)
      (let* ((src-end (marker-position (overlay-get cell 'jsonyter-source-end)))
             (at (save-excursion
                   (goto-char src-end)
                   (search-forward "import os" (overlay-end cell))
                   (match-beginning 0))))
        (should (eq (get-text-property at 'face) 'jsonyter-stderr-face))
        ;; The source above it did get fontified.
        (should (get-text-property (overlay-start cell) 'face))))))

;;;; Saving

(ert-deftest jsonyter-test-save-writes-source-only ()
  "Saving writes the typed code, never the rendered output.
Checked against the JSON actually on disk: getting this wrong is silent
corruption of the user's notebook, not a visible failure."
  (skip-unless (jsonyter-tests--bridge-available-p))
  (jsonyter-tests--with-notebook
    (let ((jsonyter-command '("python3" "-m" "jsonyter"))
          (cell (jsonyter-tests--cell 0)))
      (jsonyter--nb-append-output cell (jsonyter-tests--stream "1 2 3\n"))
      (jsonyter--nb-append-output
       cell (jsonyter-tests--png (base64-encode-string "not really a png")))
      (jsonyter-notebook-save)
      (should (equal (jsonyter-tests--saved-sources path)
                     '("x = 1" "print(x)" "# heading")))
      ;; Nothing from the frame or the renderer leaked in.
      (let ((json (with-temp-buffer (insert-file-contents path) (buffer-string))))
        (should-not (string-match-p "1 2 3" json))
        (should-not (string-match-p "output ─" json))))))

(ert-deftest jsonyter-test-save-with-outputs-round-trips ()
  "Saved outputs come back the same when the notebook is reopened."
  (skip-unless (jsonyter-tests--bridge-available-p))
  (jsonyter-tests--with-notebook
    (let ((jsonyter-command '("python3" "-m" "jsonyter"))
          (cell (jsonyter-tests--cell 0))
          (shown nil))
      (jsonyter--nb-append-output cell (jsonyter-tests--stream "1 2 3\n"))
      (setq shown (jsonyter-tests--output-text cell))
      (jsonyter-notebook-save-with-outputs)
      (should (equal (jsonyter-tests--saved-sources path)
                     '("x = 1" "print(x)" "# heading")))
      (kill-buffer)
      (let ((reopened (find-file-noselect path)))
        (unwind-protect
            (with-current-buffer reopened
              (should (equal (jsonyter-tests--output-text
                              (jsonyter-tests--cell 0))
                             shown)))
          (kill-buffer reopened)))
      ;; The macro's cleanup expects a live buffer to return to.
      (setq buffer (find-file-noselect path)))))

(ert-deftest jsonyter-test-stored-outputs-render-back-to-back ()
  "Opening a notebook that already has results lays the cells out right.
Each cell's overlay has to reach past the output written in after its
source, or the next cell is rendered inside the previous one's results."
  (let ((path (make-temp-file "jsonyter-test-" nil ".ipynb"))
        (buffer nil))
    (unwind-protect
        (progn
          (with-temp-file path (insert jsonyter-tests--notebook-with-outputs))
          (setq buffer (find-file-noselect path))
          (with-current-buffer buffer
            (let ((first (jsonyter-tests--cell 0))
                  (second (jsonyter-tests--cell 1)))
              (should (= 2 (length (jsonyter--nb-cells))))
              (should (equal (jsonyter--nb-cell-source first) "x = 1"))
              (should (equal (jsonyter--nb-cell-source second) "print(x)"))
              (should (= (overlay-end first) (overlay-start second)))
              (should (string-match-p "stored one"
                                      (jsonyter-tests--output-text first)))
              (should (string-match-p "stored two"
                                      (jsonyter-tests--output-text first)))
              (should (string-match-p "stored three"
                                      (jsonyter-tests--output-text second)))
              ;; The second cell shows only its own results.
              (should-not (string-match-p "stored one"
                                          (jsonyter-tests--output-text second)))
              ;; And nothing was left modified or undoable by rendering.
              (should-not (buffer-modified-p)))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-file path))))

(ert-deftest jsonyter-test-clear-all-output-leaves-plain-text ()
  "Clearing every output leaves a buffer of nothing but source."
  (jsonyter-tests--with-notebook
    (dolist (cell (jsonyter--nb-cells))
      ;; Only code cells can have produced anything.
      (when (equal (overlay-get cell 'jsonyter-cell-type) "code")
        (jsonyter--nb-set-output cell "results\n" nil t)))
    (jsonyter-notebook-clear-all-output)
    (should (equal (buffer-string) "x = 1\nprint(x)\n# heading\n"))
    (should-not (text-property-not-all (point-min) (point-max) 'read-only nil))
    (should (equal (mapcar #'jsonyter--nb-cell-source (jsonyter--nb-cells))
                   '("x = 1" "print(x)" "# heading")))))

(ert-deftest jsonyter-test-toggle-back-to-code ()
  "A cell toggled to markdown and back is a code cell with no output."
  (jsonyter-tests--with-notebook
    (let ((cell (jsonyter-tests--cell 0)))
      (jsonyter--nb-set-output cell "results\n" nil t)
      (goto-char (overlay-start cell))
      (jsonyter-toggle-cell-type)
      (jsonyter-toggle-cell-type)
      (should (equal (overlay-get cell 'jsonyter-cell-type) "code"))
      (should (equal (jsonyter--nb-cell-source cell) "x = 1"))
      (should (equal "" (jsonyter-tests--output-text cell)))
      (should (= (overlay-end cell) (overlay-start (jsonyter-tests--cell 1)))))))

;;;; The session table (M1)

;; These never touch a bridge: a session's kernel binding is set on the
;; struct directly, and events are fed to `jsonyter--handle-event' in the
;; shape the bridge tags them with.

(defmacro jsonyter-tests--with-sessions (&rest body)
  "Run BODY in a fresh temp buffer with an empty session table."
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (setq-local jsonyter--sessions (make-hash-table :test #'equal))
     (setq-local jsonyter--process nil)
     ,@body))

(defun jsonyter-tests--bind-session (key id &optional own)
  "Put a session for KEY bound to kernel ID, owned when OWN, and return it."
  (let ((session (jsonyter--session-put key)))
    (setf (jsonyter--session-kernel-id session) id
          (jsonyter--session-state session) "idle"
          (jsonyter--session-own session) (and own id))
    session))

(ert-deftest jsonyter-test-session-put-is-idempotent ()
  "`jsonyter--session-put' creates once and returns the same object after."
  (jsonyter-tests--with-sessions
    (let ((a (jsonyter--session-put '("python" . "main")))
          (b (jsonyter--session-put '("python" . "main"))))
      (should (eq a b))
      (should (equal (jsonyter--session-language a) "python"))
      (should (= 1 (length (jsonyter--session-list)))))))

(ert-deftest jsonyter-test-sessions-keyed-by-language-and-name ()
  "jy:main in Python and in R are two different sessions."
  (jsonyter-tests--with-sessions
    (jsonyter--session-put '("python" . "main"))
    (jsonyter--session-put '("R" . "main"))
    (should (= 2 (length (jsonyter--session-list))))))

(ert-deftest jsonyter-test-session-for-kernel-round-trips ()
  "A kernel id resolves back to the session it is bound to, and unknown ids to nil."
  (jsonyter-tests--with-sessions
    (let ((py (jsonyter-tests--bind-session '("python" . "") "kid-py"))
          (r  (jsonyter-tests--bind-session '("R" . "") "kid-r")))
      (should (eq py (jsonyter--session-for-kernel "kid-py")))
      (should (eq r (jsonyter--session-for-kernel "kid-r")))
      (should (null (jsonyter--session-for-kernel "kid-nope")))
      (should (null (jsonyter--session-for-kernel nil))))))

(ert-deftest jsonyter-test-event-routes-to-owning-session-only ()
  "A `dead' event blanks only its own session; the sibling is untouched."
  (jsonyter-tests--with-sessions
    (let ((py (jsonyter-tests--bind-session '("python" . "") "kid-py"))
          (r  (jsonyter-tests--bind-session '("R" . "") "kid-r")))
      (setf (jsonyter--session-busy py) t
            (jsonyter--session-busy r) t)
      (jsonyter--handle-event
       '(:kernel_id "kid-r" :event (:type "dead")))
      (should (equal (jsonyter--session-state r) "dead"))
      (should (null (jsonyter--session-busy r)))
      ;; Python is left exactly as it was.
      (should (equal (jsonyter--session-state py) "idle"))
      (should (jsonyter--session-busy py)))))

(ert-deftest jsonyter-test-event-for-unknown-kernel-is-a-no-op ()
  "An event whose kernel this buffer no longer tracks is dropped, not an error."
  (jsonyter-tests--with-sessions
    (jsonyter-tests--bind-session '("python" . "") "kid-py")
    (should-not
     (jsonyter--handle-event '(:kernel_id "gone" :event (:type "dead"))))))

(ert-deftest jsonyter-test-status-event-updates-only-its-session ()
  "A busy/idle status event moves one session's state and leaves others alone."
  (jsonyter-tests--with-sessions
    (let ((py (jsonyter-tests--bind-session '("python" . "") "kid-py"))
          (r  (jsonyter-tests--bind-session '("R" . "") "kid-r")))
      (jsonyter--handle-event
       '(:kernel_id "kid-py" :event (:type "status" :execution_state "busy")))
      (should (equal (jsonyter--session-state py) "busy"))
      (should (equal (jsonyter--session-state r) "idle")))))

(ert-deftest jsonyter-test-mode-line-single-session ()
  "With one session the mode line reports that session's state."
  (jsonyter-tests--with-sessions
    (let ((s (jsonyter-tests--bind-session '("python" . "") "kid")))
      (setq-local jsonyter--session-key '("python" . ""))
      (should (equal ":idle" (jsonyter--mode-line-string)))
      (setf (jsonyter--session-busy s) t)
      (should (equal ":run" (jsonyter--mode-line-string)))
      (setf (jsonyter--session-busy s) nil
            (jsonyter--session-state s) "dead")
      (should (equal ":dead" (jsonyter--mode-line-string))))))

(ert-deftest jsonyter-test-mode-line-summarizes-many-sessions ()
  "An Org-style buffer with no current session summarizes the table."
  (jsonyter-tests--with-sessions
    (jsonyter-tests--bind-session '("python" . "main") "kid-py")
    (jsonyter-tests--bind-session '("R" . "main") "kid-r")
    (setq-local jsonyter--session-key nil)
    (should (equal ":2 kernels" (jsonyter--mode-line-string)))
    (setf (jsonyter--session-busy (jsonyter--session-for-kernel "kid-py")) t)
    (should (equal ":2 kernels!" (jsonyter--mode-line-string)))))

(ert-deftest jsonyter-test-cleanup-shuts-down-every-owned-kernel ()
  "`jsonyter--cleanup' ends each kernel this buffer started, not adopted ones."
  (jsonyter-tests--with-sessions
    (jsonyter-tests--bind-session '("python" . "main") "own-py" t)
    (jsonyter-tests--bind-session '("R" . "main") "own-r" t)
    (jsonyter-tests--bind-session '("julia" . "main") "adopted" nil)
    (let ((shutdowns '()))
      (cl-letf (((symbol-function 'process-live-p) (lambda (&rest _) t))
                ((symbol-function 'jsonyter--kill-process) #'ignore)
                ((symbol-function 'jsonyter--request-sync)
                 (lambda (method params &rest _)
                   (when (equal method "shutdown_kernel")
                     (push (plist-get params :kernel_id) shutdowns)))))
        (jsonyter--cleanup))
      (should (equal (sort shutdowns #'string<) '("own-py" "own-r"))))))

(ert-deftest jsonyter-test-legacy-kernel-vars-are-obsolete ()
  "The pre-2.0 scalars carry an obsolescence notice pointing at the accessors."
  (should (get 'jsonyter--kernel-id 'byte-obsolete-variable))
  (should (get 'jsonyter--busy 'byte-obsolete-variable)))

(ert-deftest jsonyter-test-public-accessors-are-nil-safe ()
  "The public accessors return nil in a buffer that has no session."
  (with-temp-buffer
    (should (null (jsonyter-current-session)))
    (should (null (jsonyter-current-kernel-id)))
    (should (null (jsonyter-current-kernel-busy-p)))))

;;;; Org-mode cell layer (M3/M4)

;; No kernel: outputs are fed to the overlay in kernel shape, and session
;; resolution / commit / staleness are pure buffer operations.

(require 'org)

(defmacro jsonyter-tests--with-org-file (text &rest body)
  "Run BODY in a buffer visiting a temp .org file containing TEXT."
  (declare (indent 1) (debug t))
  `(let ((path (make-temp-file "jsonyter-org-" nil ".org"))
         (buffer nil))
     (unwind-protect
         (progn
           (with-temp-file path (insert ,text))
           (setq buffer (find-file-noselect path))
           (with-current-buffer buffer
             (jsonyter-org-mode 1)
             ,@body))
       (when (buffer-live-p buffer)
         (with-current-buffer buffer (set-buffer-modified-p nil))
         (kill-buffer buffer))
       (when (file-exists-p path) (delete-file path))
       (let ((d (expand-file-name ".jsonyter"
                                  (file-name-directory path))))
         (when (file-directory-p d) (delete-directory d t))))))

(defun jsonyter-tests--info (lang &rest header-args)
  "A fake `org-babel-get-src-block-info' list for LANG with HEADER-ARGS (plist)."
  (list lang "body"
        (let (alist)
          (while header-args
            (push (cons (pop header-args) (pop header-args)) alist))
          (nreverse alist))
        nil nil 1 nil))

(ert-deftest jsonyter-test-org-session-key-opts-in-on-jy-prefix ()
  "`:session jy:...' resolves to a (language . name) key; anything else is nil."
  (should (equal '("python" . "main")
                 (jsonyter--org-session-key
                  (jsonyter-tests--info "python" :session "jy:main"))))
  (should (equal '("python" . "")
                 (jsonyter--org-session-key
                  (jsonyter-tests--info "python" :session "jy:"))))
  (should (equal '("R" . "@abc123")
                 (jsonyter--org-session-key
                  (jsonyter-tests--info "R" :session "jy:@abc123"))))
  (should (null (jsonyter--org-session-key
                 (jsonyter-tests--info "python" :session "none"))))
  (should (null (jsonyter--org-session-key
                 (jsonyter-tests--info "python" :session "main"))))
  (should (null (jsonyter--org-session-key (jsonyter-tests--info "python")))))

(ert-deftest jsonyter-test-org-buffer-detection ()
  "`jsonyter--org-buffer-has-jy-p' sees inline and property-line opt-ins."
  (with-temp-buffer
    (insert "#+begin_src python :session jy:main\n1\n#+end_src\n")
    (should (jsonyter--org-buffer-has-jy-p)))
  (with-temp-buffer
    (insert "#+PROPERTY: header-args:R :session jy:shared\n* h\n")
    (should (jsonyter--org-buffer-has-jy-p)))
  (with-temp-buffer
    (insert "#+begin_src python :session main\n1\n#+end_src\n")
    (should-not (jsonyter--org-buffer-has-jy-p))))

(ert-deftest jsonyter-test-org-commit-writes-stamped-drawer ()
  "Committing a block's shown output writes a hash-stamped `#+RESULTS:' drawer."
  (jsonyter-tests--with-org-file
      "* h\n#+begin_src python :session jy:main\nx = 1\nx + 1\n#+end_src\n"
    (goto-char (point-min))
    (search-forward "x + 1")
    (pcase-let* ((`(,code . ,anchor) (jsonyter--org-block-region))
                 (ov (jsonyter--org-cell-overlay anchor t)))
      (overlay-put ov 'jsonyter-source-hash (jsonyter--source-hash code))
      (overlay-put ov 'jsonyter-raw-outputs
                   (list (jsonyter-tests--stream "first\n")
                         (jsonyter-tests--stream "second\n")))
      (overlay-put ov 'jsonyter-output-string "x")) ; non-empty => committable
    (jsonyter-org-commit-block)
    (let ((text (buffer-string)))
      (should (string-match-p "#\\+RESULTS\\[[0-9a-f]\\{7\\}\\]:" text))
      (should (string-match-p ":results:" text))
      (should (string-match-p "^: first$" text))
      (should (string-match-p "^: second$" text))
      (should (string-match-p ":end:" text)))
    ;; the overlay is gone -- the committed text is the result now
    (should (null (jsonyter--org-cell-at)))))

(ert-deftest jsonyter-test-org-commit-writes-image-file-and-link ()
  "An image output is written to a content-addressed file and linked."
  (jsonyter-tests--with-org-file
      "* h\n#+begin_src python :session jy:main\nplot()\n#+end_src\n"
    (goto-char (point-min))
    (search-forward "plot()")
    (pcase-let* ((`(,code . ,anchor) (jsonyter--org-block-region))
                 (ov (jsonyter--org-cell-overlay anchor t))
                 ;; 1x1 transparent PNG
                 (png (concat "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfF"
                              "cSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")))
      (overlay-put ov 'jsonyter-source-hash (jsonyter--source-hash code))
      (overlay-put ov 'jsonyter-output-string "x")
      (overlay-put ov 'jsonyter-raw-outputs
                   (list (list :type "display_data"
                               :data (list :image/png png) :metadata nil))))
    (jsonyter-org-commit-block)
    (should (string-match-p "\\[\\[file:[^]]*/?plot-[0-9a-f]+\\.png\\]\\]"
                            (buffer-string)))
    (let ((dir (expand-file-name ".jsonyter"
                                 (file-name-directory buffer-file-name))))
      (should (directory-files dir nil "\\`plot-.*\\.png\\'")))))

(ert-deftest jsonyter-test-org-reload-flags-stale-committed-result ()
  "A committed `#+RESULTS[hash]:' whose block changed is framed on mode start."
  (jsonyter-tests--with-org-file
      (concat "* h\n#+begin_src python :session jy:main\nx = 1\n#+end_src\n\n"
              "#+RESULTS[deadbee]:\n:results:\n: 1\n:end:\n")
    ;; jsonyter-org-mode already ran once via the macro; re-scan explicitly.
    (jsonyter--org-scan-committed)
    (should (seq-some (lambda (o) (overlay-get o 'jsonyter-org-committed))
                      (overlays-in (point-min) (point-max))))))

(ert-deftest jsonyter-test-org-reload-leaves-matching-result-alone ()
  "A committed result whose stamp matches its block's hash is not framed."
  (let* ((body "x = 1")
         (stamp (substring (jsonyter--source-hash body) 0 7)))
    (jsonyter-tests--with-org-file
        (concat "* h\n#+begin_src python :session jy:main\n" body "\n#+end_src\n\n"
                "#+RESULTS[" stamp "]:\n:results:\n: 1\n:end:\n")
      (jsonyter--org-scan-committed)
      (should-not (seq-some (lambda (o) (overlay-get o 'jsonyter-org-committed))
                            (overlays-in (point-min) (point-max)))))))

(ert-deftest jsonyter-test-org-edit-marks-overlay-output-stale ()
  "Editing a block's body flips its shown output to the stale face."
  (jsonyter-tests--with-org-file
      "* h\n#+begin_src python :session jy:main\nx = 1\n#+end_src\n"
    (goto-char (point-min))
    (search-forward "x = 1")
    (pcase-let* ((`(,code . ,anchor) (jsonyter--org-block-region))
                 (ov (jsonyter--org-cell-overlay anchor t)))
      (overlay-put ov 'jsonyter-source-hash (jsonyter--source-hash code))
      (overlay-put ov 'jsonyter-output-string "1\n")
      (should-not (overlay-get ov 'jsonyter-output-stale))
      (goto-char (line-end-position))
      (insert " + 9")
      (should (overlay-get ov 'jsonyter-output-stale)))))

(ert-deftest jsonyter-test-org-clean-images-removes-unreferenced ()
  "`jsonyter-org-clean-images' deletes managed pngs no link points at."
  (jsonyter-tests--with-org-file
      "* h\n[[file:.jsonyter/plot-keepme.png]]\n"
    (let* ((dir (jsonyter--org-image-dir)))
      (make-directory dir t)
      (write-region "x" nil (expand-file-name "plot-keepme.png" dir) nil 'quiet)
      (write-region "x" nil (expand-file-name "plot-orphan.png" dir) nil 'quiet)
      (jsonyter-org-clean-images)
      (should (file-exists-p (expand-file-name "plot-keepme.png" dir)))
      (should-not (file-exists-p (expand-file-name "plot-orphan.png" dir))))))

(ert-deftest jsonyter-test-org-dispatch-key-branches-on-block ()
  "A shadowing key runs the jsonyter action in a jy: block, else falls through."
  (jsonyter-tests--with-org-file
      "* h\nprose\n#+begin_src python :session jy:main\n1\n#+end_src\n"
    (let (acted fell)
      (cl-letf (((symbol-function 'jsonyter-org-run-block)
                 (lambda (&rest _) (interactive) (setq acted t)))
                ((symbol-function 'jsonyter--org-fallthrough)
                 (lambda (&rest _) (setq fell t))))
        ;; inside the block -> jsonyter action
        (goto-char (point-min)) (search-forward "1\n#+end")
        (goto-char (match-beginning 0))
        (call-interactively #'jsonyter-org-C-RET)
        (should acted) (should-not fell)
        ;; on the prose line -> Org's own command
        (setq acted nil fell nil)
        (goto-char (point-min)) (search-forward "prose")
        (call-interactively #'jsonyter-org-C-RET)
        (should fell) (should-not acted)))))

(ert-deftest jsonyter-test-org-mode-refuses-non-org-buffer ()
  "`jsonyter-org-mode' will not turn on outside an Org buffer."
  (with-temp-buffer
    (fundamental-mode)
    (should-error (jsonyter-org-mode 1))
    (should-not (bound-and-true-p jsonyter-org-mode))))

(ert-deftest jsonyter-test-org-folding-hides-overlay-output ()
  "An output after-string anchored inside a folded subtree is not displayed.
This is the M2 spike, codified: the overlay approach only works if Org's
own visibility cycling hides committed-free session output for us."
  (jsonyter-tests--with-org-file
      "* h\nprose\n#+begin_src python :session jy:main\n1\n#+end_src\nafter\n"
    (goto-char (point-min))
    (search-forward "#+end_src")
    (let* ((anchor (line-beginning-position 2))
           (ov (make-overlay (1- anchor) anchor)))
      (overlay-put ov 'after-string "\n[OUT]\n")
      (should-not (org-invisible-p anchor))
      (goto-char (point-min))
      (org-cycle)                       ; fold the subtree
      (should (org-invisible-p anchor)))))

;;;; org-babel backend (M5)

(ert-deftest jsonyter-test-babel-jy-p-detects-prefix ()
  "`jsonyter--org-babel-jy-p' matches only a `jy:'-prefixed `:session'."
  (should (jsonyter--org-babel-jy-p '((:session . "jy:main"))))
  (should-not (jsonyter--org-babel-jy-p '((:session . "main"))))
  (should-not (jsonyter--org-babel-jy-p nil)))

(ert-deftest jsonyter-test-babel-key-strips-jy-prefix ()
  "`jsonyter--org-babel-key' turns `:session jy:NAME' into (LANG . NAME)."
  (should (equal '("python" . "main")
                 (jsonyter--org-babel-key "python" '((:session . "jy:main")))))
  (should (equal '("R" . "") (jsonyter--org-babel-key "R" '((:session . "jy:"))))))

(ert-deftest jsonyter-test-babel-dispatch-falls-through-without-jy ()
  "A block with no `jy:' session calls ORIG-FUN, not jsonyter."
  (let (called)
    (should (equal "orig"
                   (jsonyter--org-babel-dispatch
                    "python"
                    (lambda (body params) (setq called (list body params)) "orig")
                    "print(1)" '((:session . "main")))))
    (should (equal called '("print(1)" ((:session . "main")))))))

(ert-deftest jsonyter-test-babel-dispatch-errors-without-orig-fun ()
  "No ORIG-FUN and no `jy:' session — the same failure Org itself signals."
  (should-error (jsonyter--org-babel-dispatch "SAS" nil "x" '((:session . "main")))))

(ert-deftest jsonyter-test-babel-value-stream-for-output ()
  "RESULT-TYPE `output' returns concatenated stream text."
  (should (equal "a\nb\n"
                 (jsonyter--org-babel-value
                  (list (jsonyter-tests--stream "a\n") (jsonyter-tests--stream "b\n"))
                  'output nil))))

(ert-deftest jsonyter-test-babel-value-execute-result-for-value ()
  "RESULT-TYPE `value' returns the last execute_result's text/plain."
  (should (equal "42"
                 (jsonyter--org-babel-value
                  (list (list :type "execute_result" :data (list :text/plain "42")))
                  'value nil))))

(ert-deftest jsonyter-test-babel-value-falls-back-to-stream-for-value ()
  "With no execute_result, RESULT-TYPE `value' falls back to stream text."
  (should (equal "hi\n"
                 (jsonyter--org-babel-value (list (jsonyter-tests--stream "hi\n")) 'value nil))))

(ert-deftest jsonyter-test-babel-value-error-wins-over-everything ()
  "An error's traceback is returned regardless of RESULT-TYPE/RESULT-PARAMS."
  (should (equal "boom"
                 (jsonyter--org-babel-value
                  (list (list :type "error" :traceback '("boom"))) 'value '("html")))))

(ert-deftest jsonyter-test-babel-value-html-when-requested ()
  "`:results html' returns the text/html payload, not the plain-text one."
  (should (equal "<b>hi</b>"
                 (jsonyter--org-babel-value
                  (list (list :type "execute_result"
                              :data (list :text/plain "hi" :text/html "<b>hi</b>")))
                  'value '("html")))))

(ert-deftest jsonyter-test-babel-value-file-writes-image ()
  "`:results file' writes the image and returns a bare path, not a link."
  (jsonyter-tests--with-org-file "* h\n"
    (let ((value (jsonyter--org-babel-value (list (jsonyter-tests--png "eA==")) 'value '("file"))))
      (should (stringp value))
      (should (file-exists-p (expand-file-name value (file-name-directory buffer-file-name)))))))

(ert-deftest jsonyter-test-babel-execute-runs-synchronously ()
  "`jsonyter--org-babel-execute' blocks for a reply and returns the value."
  (jsonyter-tests--with-org-file
      "* h\n#+begin_src python :session jy:main\n1 + 1\n#+end_src\n"
    (cl-letf (((symbol-function 'jsonyter--org-connect)
               (lambda (key &rest _) (jsonyter-tests--bind-session key "kid" t)))
              ((symbol-function 'jsonyter--send)
               (lambda (_method _params handlers)
                 (funcall (plist-get handlers :result)
                          (list :result
                                (list :outputs
                                      (list (list :type "execute_result"
                                                  :data (list :text/plain "2")))))))))
      (should (equal "2" (jsonyter--org-babel-execute
                          "python" "1 + 1" '((:session . "jy:main"))))))))

(ert-deftest jsonyter-test-babel-execute-refuses-when-session-busy ()
  "A session already busy refuses a second execute rather than queuing it."
  (jsonyter-tests--with-org-file
      "* h\n#+begin_src python :session jy:main\n1\n#+end_src\n"
    (cl-letf (((symbol-function 'jsonyter--org-connect)
               (lambda (key &rest _)
                 (let ((s (jsonyter-tests--bind-session key "kid" t)))
                   (setf (jsonyter--session-busy s) t)
                   s))))
      (should-error (jsonyter--org-babel-execute "python" "1" '((:session . "jy:main")))))))

(ert-deftest jsonyter-test-tangle-marks-jy-blocks-not-others ()
  "`org-babel-tangle' prefixes a jy: block with `# %%'; a plain one is untouched."
  (require 'ob-tangle)
  (jsonyter-tests--with-org-file
      (concat "* h\n"
              "#+begin_src python :session jy:main :tangle yes\nprint(1)\n#+end_src\n"
              "#+begin_src python :tangle yes\nprint(2)\n#+end_src\n")
    (let ((target (org-babel-effective-tangled-filename buffer-file-name "python" "yes")))
      (unwind-protect
          (progn
            (org-babel-tangle)
            (should (file-exists-p target))
            (with-temp-buffer
              (insert-file-contents target)
              (goto-char (point-min))
              (should (search-forward "# %%" nil t))
              (should (search-forward "print(1)" nil t))
              (goto-char (point-min))
              (search-forward "print(2)")
              (goto-char (line-beginning-position 0))
              (should-not (looking-at "# %%"))))
        (when (file-exists-p target) (delete-file target))))))

;;;; async babel path (M6)

(ert-deftest jsonyter-test-babel-async-inserts-placeholder-then-replaces ()
  "`:async yes' returns a placeholder immediately; the reply replaces it in place."
  (jsonyter-tests--with-org-file
      "* h\n#+begin_src python :session jy:main :async yes\n1 + 1\n#+end_src\n"
    (let (stashed-handlers)
      (cl-letf (((symbol-function 'jsonyter--org-connect)
                 (lambda (key &rest _) (jsonyter-tests--bind-session key "kid" t)))
                ((symbol-function 'jsonyter--send)
                 (lambda (_method _params handlers) (setq stashed-handlers handlers))))
        (goto-char (point-min))
        (search-forward "1 + 1")
        (let* ((info (jsonyter--org-block-info))
               (params (org-babel-process-params (nth 2 info)))
               (placeholder (jsonyter--org-babel-execute "python" "1 + 1" params)))
          (should (string-match "\\[\\[.+\\]\\]" placeholder))
          (org-babel-insert-result placeholder (cdr (assq :result-params params)) info)
          (goto-char (point-min))
          (should (search-forward placeholder nil t))
          (funcall (plist-get stashed-handlers :result)
                   (list :result
                         (list :outputs
                               (list (list :type "execute_result" :data (list :text/plain "2"))))))
          (goto-char (point-min))
          (should-not (search-forward placeholder nil t))
          (goto-char (point-min))
          (should (search-forward "2" nil t)))))))

(ert-deftest jsonyter-test-babel-async-drops-reply-with-no-placeholder ()
  "A reply for a token no longer in the buffer is dropped, not an error."
  (jsonyter-tests--with-org-file "* h\nno placeholder here\n"
    (should (equal (concat "jsonyter: async result [gone-token] arrived for a block "
                          "that no longer has its placeholder — dropped")
                   (jsonyter--org-babel-async-reply "gone-token" (list :result nil))))))

(ert-deftest jsonyter-test-babel-async-ignored-during-export ()
  "Even with `:async yes', exporting forces the synchronous path."
  (require 'ox)
  (jsonyter-tests--with-org-file
      "* h\n#+begin_src python :session jy:main :async yes\n1\n#+end_src\n"
    (cl-letf (((symbol-function 'jsonyter--org-connect)
               (lambda (key &rest _) (jsonyter-tests--bind-session key "kid" t)))
              ((symbol-function 'jsonyter--send)
               (lambda (_method _params handlers)
                 (funcall (plist-get handlers :result)
                          (list :result
                                (list :outputs
                                      (list (list :type "execute_result"
                                                  :data (list :text/plain "1")))))))))
      (let ((org-export-current-backend 'ascii))
        (should (equal "1" (jsonyter--org-babel-execute
                            "python" "1" '((:session . "jy:main") (:async . "yes")))))))))

;;;; :var marshalling (M7)

(ert-deftest jsonyter-test-var-python-scalar-and-string ()
  "A Python scalar is a literal; a string is quoted and escaped."
  (should (equal "n = 5" (jsonyter--org-var-value-python "n" 5 nil)))
  (should (equal "s = \"hi\\nthere\"" (jsonyter--org-var-value-python "s" "hi\nthere" nil))))

(ert-deftest jsonyter-test-var-python-table-list-of-lists ()
  "A Python table with no colnames is a list of lists."
  (should (equal "data = [[1, 2], [3, 4]]"
                 (jsonyter--org-var-value-python "data" '((1 2) (3 4)) nil))))

(ert-deftest jsonyter-test-var-python-table-with-colnames-is-dataframe ()
  "`:colnames yes' makes a Python table a pandas DataFrame."
  (should (equal (concat "import pandas as pd\n"
                        "data = pd.DataFrame([[1, 2], [3, 4]], columns=[\"a\", \"b\"])")
                 (jsonyter--org-var-value-python "data" '((1 2) (3 4)) '("a" "b")))))

(ert-deftest jsonyter-test-var-r-table-is-matrix ()
  "An R table with no colnames is a `matrix'."
  (should (equal "data <- matrix(c(1, 2, 3, 4), nrow = 2, byrow = TRUE)"
                 (jsonyter--org-var-value-r "data" '((1 2) (3 4)) nil))))

(ert-deftest jsonyter-test-var-r-table-with-colnames-is-data-frame ()
  "`:colnames yes' makes an R table a `data.frame' with those names."
  (should (equal (concat "data <- as.data.frame(matrix(c(1, 2, 3, 4), nrow = 2, byrow = TRUE))\n"
                        "colnames(data) <- c(\"a\", \"b\")")
                 (jsonyter--org-var-value-r "data" '((1 2) (3 4)) '("a" "b")))))

(ert-deftest jsonyter-test-var-julia-table-is-matrix-literal ()
  "A Julia table is always a `Matrix' literal unless the DataFrame opt-in is on."
  (should (equal "data = [1 2; 3 4]" (jsonyter--org-var-value-julia "data" '((1 2) (3 4)) nil))))

(ert-deftest jsonyter-test-var-julia-dataframe-requires-opt-in ()
  "Colnames alone do not make a Julia table a DataFrame without the option."
  (let ((jsonyter-org-var-julia-dataframe nil))
    (should (equal "data = [1 2; 3 4]"
                   (jsonyter--org-var-value-julia "data" '((1 2) (3 4)) '("a" "b")))))
  (let ((jsonyter-org-var-julia-dataframe t))
    (should (equal "data = DataFrame([1 2; 3 4], [Symbol(\"a\"), Symbol(\"b\")])"
                   (jsonyter--org-var-value-julia "data" '((1 2) (3 4)) '("a" "b"))))))

(ert-deftest jsonyter-test-var-sas-scalar-is-let ()
  "A SAS scalar is a `%let'."
  (should (equal "%let n = 5;" (jsonyter--org-var-value-sas "n" 5))))

(ert-deftest jsonyter-test-var-sas-numeric-table-is-datalines ()
  "An all-numeric SAS table becomes a DATALINES step."
  (should (equal "data t;\n  input col1 col2;\n  datalines;\n1 2\n3 4\n;\nrun;"
                 (jsonyter--org-var-value-sas "t" '((1 2) (3 4))))))

(ert-deftest jsonyter-test-var-sas-whitespace-character-table-errors ()
  "A SAS table with a whitespace-containing character field refuses, not corrupts."
  (should-error (jsonyter--org-var-value-sas "t" '(("hi there" 1)))))

(ert-deftest jsonyter-test-var-code-prepends-prelude-for-every-var ()
  "`jsonyter--org-var-code' prepends one prelude line per `:var' binding."
  (should (equal "n = 5\nx = 1" (jsonyter--org-var-code "python" "x = 1" '((:var n . 5))))))

(ert-deftest jsonyter-test-var-code-passes-body-through-with-no-vars ()
  "With no `:var' bindings at all, the body is returned unchanged."
  (should (equal "x = 1" (jsonyter--org-var-code "python" "x = 1" nil))))

(ert-deftest jsonyter-test-var-size-limit-signals-clear-error ()
  "Past `jsonyter-org-var-size-limit', jsonyter refuses rather than sends it anyway."
  (let ((jsonyter-org-var-size-limit 5))
    (should-error (jsonyter--org-var-check-size "n" "way too long a string"))))

;;;; .ipynb <-> .org conversion (M8)

(ert-deftest jsonyter-test-org-from-notebook-writes-property-and-drawers ()
  "Converting a fixture notebook writes a session `#+PROPERTY:' and per-cell ids."
  (let* ((jsonyter-org-markdown-converter (lambda (text _dir) text))
         (ipynb (make-temp-file "jsonyter-test-" nil ".ipynb"))
         (org (make-temp-file "jsonyter-test-" nil ".org")))
    (unwind-protect
        (progn
          (jsonyter-tests--write-notebook ipynb)
          (delete-file org)
          (jsonyter-org-from-notebook ipynb org "main")
          (with-temp-buffer
            (insert-file-contents org)
            (goto-char (point-min))
            (should (search-forward "#+PROPERTY: header-args:python :session jy:main" nil t))
            (goto-char (point-min))
            (should (search-forward ":JSONYTER_CELL_ID: aaa" nil t))
            (goto-char (point-min))
            (should (search-forward "#+begin_src python :session jy:main\nx = 1\n#+end_src" nil t))
            (goto-char (point-min))
            (should (search-forward ":JSONYTER_CELL_ID: ccc" nil t))
            (goto-char (point-min))
            (should (search-forward "# heading" nil t))))
      (dolist (f (list ipynb org)) (when (file-exists-p f) (delete-file f)))
      (let ((buf (find-buffer-visiting org))) (when buf (kill-buffer buf))))))

(ert-deftest jsonyter-test-org-from-notebook-commits-stored-output ()
  "A cell with stored output gets a committed `#+RESULTS:' drawer, not just source."
  (let* ((jsonyter-org-markdown-converter (lambda (text _dir) text))
         (ipynb (make-temp-file "jsonyter-test-" nil ".ipynb"))
         (org (make-temp-file "jsonyter-test-" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file ipynb (insert jsonyter-tests--notebook-with-outputs))
          (delete-file org)
          (jsonyter-org-from-notebook ipynb org "main")
          (with-temp-buffer
            (insert-file-contents org)
            (goto-char (point-min))
            (should (search-forward "#+RESULTS" nil t))
            (goto-char (point-min))
            (should (search-forward "stored one" nil t))))
      (dolist (f (list ipynb org)) (when (file-exists-p f) (delete-file f)))
      (let ((buf (find-buffer-visiting org))) (when buf (kill-buffer buf))))))

(ert-deftest jsonyter-test-org-to-notebook-cells-splits-on-id-drawers ()
  "`jsonyter--org-to-notebook-cells' recovers each cell's id, type and source."
  (let ((jsonyter-org-markdown-converter (lambda (text _dir) text)))
    (jsonyter-tests--with-org-file
        (concat "#+PROPERTY: header-args:python :session jy:main\n\n"
                ":PROPERTIES:\n:JSONYTER_CELL_ID: aaa\n:END:\n"
                "#+begin_src python :session jy:main\nx = 1\n#+end_src\n\n"
                ":PROPERTIES:\n:JSONYTER_CELL_ID: ccc\n:END:\n"
                "# heading\n\n")
      (let ((cells (jsonyter--org-to-notebook-cells)))
        (should (= 2 (length cells)))
        (should (equal "aaa" (plist-get (nth 0 cells) :id)))
        (should (equal "code" (plist-get (nth 0 cells) :cell_type)))
        (should (equal "x = 1" (plist-get (nth 0 cells) :source)))
        (should (equal "ccc" (plist-get (nth 1 cells) :id)))
        (should (equal "markdown" (plist-get (nth 1 cells) :cell_type)))
        (should (equal "# heading" (plist-get (nth 1 cells) :source)))))))

(ert-deftest jsonyter-test-org-to-notebook-cell-with-no-drawer-is-new ()
  "A span with no `:JSONYTER_CELL_ID:' drawer becomes a cell with id `:null'."
  (let ((jsonyter-org-markdown-converter (lambda (text _dir) text)))
    (jsonyter-tests--with-org-file "#+begin_src python :session jy:main\nx = 1\n#+end_src\n"
      (let ((cells (jsonyter--org-to-notebook-cells)))
        (should (= 1 (length cells)))
        (should (eq :null (plist-get (car cells) :id)))))))

(ert-deftest jsonyter-test-org-parse-results-drawer-recovers-stream-text ()
  "A committed text drawer reads back as one combined stream output."
  (jsonyter-tests--with-org-file
      "* h\n#+begin_src python :session jy:main\nx = 1\n#+end_src\n\n#+RESULTS:\n:results:\n: line one\n: line two\n:end:\n"
    (goto-char (point-min))
    (search-forward "x = 1")
    (let* ((info (jsonyter--org-block-info))
           (outputs (jsonyter--org-parse-results-drawer info default-directory)))
      (should (= 1 (length outputs)))
      (should (equal "stream" (plist-get (car outputs) :output_type)))
      (should (equal "line one\nline two\n" (plist-get (car outputs) :text))))))

(ert-deftest jsonyter-test-org-to-notebook-round-trips-with-bridge ()
  "An unedited round trip through `write_notebook' preserves every cell id."
  (skip-unless (jsonyter-tests--bridge-available-p))
  (let* ((jsonyter-org-markdown-converter (lambda (text _dir) text))
         (ipynb (make-temp-file "jsonyter-test-" nil ".ipynb"))
         (org (make-temp-file "jsonyter-test-" nil ".org")))
    (unwind-protect
        (progn
          (jsonyter-tests--write-notebook ipynb)
          (delete-file org)
          (jsonyter-org-from-notebook ipynb org "main")
          (let ((org-buf (find-buffer-visiting org)))
            (when org-buf
              (with-current-buffer org-buf (set-buffer-modified-p nil))
              (kill-buffer org-buf)))
          (jsonyter-org-to-notebook org ipynb)
          (let* ((json-object-type 'alist)
                 (nb (json-read-file ipynb))
                 (ids (mapcar (lambda (c) (alist-get 'id c)) (append (alist-get 'cells nb) nil))))
            (should (equal '("aaa" "bbb" "ccc") ids))))
      (dolist (f (list ipynb org)) (when (file-exists-p f) (delete-file f)))
      (let ((buf (find-buffer-visiting org))) (when buf (kill-buffer buf))))))

(provide 'jsonyter-tests)
;;; jsonyter-tests.el ends here
