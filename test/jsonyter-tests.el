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

(provide 'jsonyter-tests)
;;; jsonyter-tests.el ends here
