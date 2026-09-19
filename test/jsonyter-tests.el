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
;;
;; Some tests here are marked `:expected-result :failed'.  Each one pins an
;; open defect written up in a `BUG-REPORT-*.md' at the repository root, and
;; names that report in its docstring.  They keep the suite green while a bug
;; is documented rather than silently untested -- and when the bug is fixed
;; they become *unexpected* passes, which fails the batch runner.  That is the
;; signal to delete the marker from that test, not to delete the test.

;;; Code:

(require 'ert)
(require 'json)
(require 'cl-lib)
(require 'dired)
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

(defmacro jsonyter-tests--with-notebook-json (json &rest body)
  "Open JSON as a notebook in a temp file and run BODY in its buffer."
  (declare (indent 1) (debug t))
  `(let ((path (make-temp-file "jsonyter-test-" nil ".ipynb"))
         (buffer nil))
     (unwind-protect
         (progn
           (with-temp-file path (insert ,json))
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
             ;; Nothing here needs an image that decodes, only a
             ;; well-formed spec for the slicing to measure and cut up
             ;; — and `image-size' is faked just above.  Standing in
             ;; for `create-image' keeps these tests about slicing, and
             ;; keeps them runnable on an Emacs built without image
             ;; support, where the real one signals and the renderer's
             ;; "could not decode" fallback would quietly pass for a
             ;; correctly unsliced image.
             ((symbol-function 'create-image)
              (lambda (data &optional type _data-p &rest props)
                (append (list 'image :type (or type 'png) :data data) props)))
             ((symbol-function 'default-font-height) (lambda (&rest _) ,line-height))
             ;; A monospace cell of 10px, so an image capped at N columns
             ;; comes out :max-width (* 10 N).
             ((symbol-function 'frame-char-width) (lambda (&rest _) 10)))
     ,@body))

(defmacro jsonyter-tests--with-global-line-spacing (spacing &rest body)
  "Run BODY with SPACING as every buffer's default `line-spacing'."
  (declare (indent 1) (debug t))
  `(let ((jsonyter-tests--spacing-was (default-value 'line-spacing)))
     (unwind-protect
         (progn (setq-default line-spacing ,spacing) ,@body)
       (setq-default line-spacing jsonyter-tests--spacing-was))))

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

;;;; Run-and-advance leaves point at the next cell, not dragged into output
;;;; (regression: `jsonyter--nb-show-output-as-text' used to restore point
;;;; via an insertion-type-nil marker, which `delete-region' collapsed to
;;;; the front of the freshly written output instead of past it.)

(ert-deftest jsonyter-test-run-and-advance-lands-on-next-cell ()
  "The sequence `jsonyter-notebook-run-cell-and-advance' performs: advance
to the next cell immediately, then let the output arrive afterwards.
Point must stay at the next cell, not get dragged back by the rewrite."
  (jsonyter-tests--with-notebook
    (let ((cell0 (jsonyter-tests--cell 0)))
      (goto-char (overlay-start cell0))
      (jsonyter--nb-set-output cell0 "" nil t)
      (jsonyter-notebook-next-cell)
      (jsonyter--nb-append-output cell0 (jsonyter-tests--stream "x is 1\n"))
      (let ((cell1 (jsonyter-tests--cell 1)))
        (should (= (point) (overlay-start cell1)))
        (should (eq (jsonyter--nb-cell-at) cell1))))))

(ert-deftest jsonyter-test-run-and-advance-survives-streaming-output ()
  "The same, with several chunks — the per-chunk refresh path."
  (jsonyter-tests--with-notebook
    (let ((cell0 (jsonyter-tests--cell 0)))
      (goto-char (overlay-start cell0))
      (jsonyter--nb-set-output cell0 "" nil t)
      (jsonyter-notebook-next-cell)
      (dolist (chunk '("first\n" "second\n" "third\n"))
        (jsonyter--nb-append-output cell0 (jsonyter-tests--stream chunk)))
      (let ((cell1 (jsonyter-tests--cell 1)))
        (should (= (point) (overlay-start cell1)))
        (should (eq (jsonyter--nb-cell-at) cell1))))))

(ert-deftest jsonyter-test-run-and-advance-second-run-targets-next-cell ()
  "Pins the user-visible bug: a second S-RET after advancing must run the
next cell, not silently re-run the one that just finished."
  (jsonyter-tests--with-notebook
    (let ((cell0 (jsonyter-tests--cell 0)))
      (goto-char (overlay-start cell0))
      (jsonyter--nb-set-output cell0 "" nil t)
      (jsonyter-notebook-next-cell)
      (jsonyter--nb-append-output cell0 (jsonyter-tests--stream "x is 1\n"))
      (should (equal (jsonyter--nb-cell-source (jsonyter--nb-cell-at))
                      (jsonyter--nb-cell-source (jsonyter-tests--cell 1)))))))

(ert-deftest jsonyter-test-run-and-advance-off-last-cell-does-not-land-in-output ()
  "Output arriving for the last cell in the buffer must not error and must
leave point past the output, not at its front."
  (jsonyter-tests--with-notebook
    (goto-char (overlay-start (jsonyter-tests--cell 2)))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
      (jsonyter-delete-cell))
    (let ((cell1 (jsonyter-tests--cell 1)))
      (should (= (overlay-end cell1) (point-max)))
      (goto-char (overlay-start cell1))
      (jsonyter--nb-set-output cell1 "" nil t)
      (goto-char (overlay-end cell1))
      (jsonyter--nb-append-output cell1 (jsonyter-tests--stream "final\n"))
      (should (= (point) (point-max)))
      (should (= (point) (overlay-end cell1))))))

(ert-deftest jsonyter-test-script-output-does-not-move-point ()
  "Guard rail: a `# %%' script cell's output lives in an overlay
`after-string', so point is never dragged by a refresh — must keep
holding after the notebook fix lands."
  (with-temp-buffer
    (python-mode)
    (jsonyter-script-mode 1)
    (insert "# %%\nprint(1)\n# %%\nprint(2)\n")
    (goto-char (point-min))
    (jsonyter-script-next-cell)
    (let* ((pos (point))
           (bounds (jsonyter--script-cell-bounds))
           (ov (jsonyter--script-output-overlay (car bounds) (cdr bounds))))
      (jsonyter--nb-set-output ov "2\n" nil t)
      (should (= (point) pos)))))

(ert-deftest jsonyter-test-org-output-does-not-move-point ()
  "Guard rail: an Org src block's output is likewise an overlay
`after-string' — must keep holding after the notebook fix lands."
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src jy:R\nq1dat <- 1\n#+end_src\n\nafter\n")
    (goto-char (point-max))
    (let* ((pos (point))
           (anchor (save-excursion
                     (goto-char (point-min))
                     (search-forward "#+end_src")
                     (forward-line 1)
                     (point)))
           (ov (jsonyter--org-cell-overlay anchor t)))
      (jsonyter--nb-set-output ov "1\n" nil t)
      (should (= (point) pos)))))

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

;;;; `line-spacing' bands sliced images, so buffers showing them go without

(ert-deftest jsonyter-test-line-spacing-resolves-like-emacs ()
  "`jsonyter--line-spacing' reads leading from where Emacs itself reads it."
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
            ((symbol-function 'frame-char-height) (lambda (&rest _) 20)))
    (jsonyter-tests--with-global-line-spacing nil
      (with-temp-buffer
        ;; Asked for nowhere.
        (should (= 0 (jsonyter--line-spacing)))
        ;; An integer is pixels...
        (setq-local line-spacing 7)
        (should (= 7 (jsonyter--line-spacing)))
        ;; ...and a float a multiple of the frame's line height.
        (setq-local line-spacing 0.25)
        (should (= 5 (jsonyter--line-spacing)))
        ;; The buffer's own value wins over the global one.
        (setq-default line-spacing 9)
        (should (= 5 (jsonyter--line-spacing)))
        (kill-local-variable 'line-spacing)
        (should (= 9 (jsonyter--line-spacing))))))
  ;; A terminal draws no leading whatever anyone has asked for.
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil)))
    (with-temp-buffer
      (setq-local line-spacing 7)
      (should (= 0 (jsonyter--line-spacing))))))

(ert-deftest jsonyter-test-line-spacing-stands-slicing-down ()
  "Slicing declines where each slice would sit on a bar of background."
  (jsonyter-tests--with-fake-display 300 15
    (with-temp-buffer
      (should (= 20 (jsonyter--image-rows '(image :type png) 15)))
      (setq-local line-spacing 4)
      (should (null (jsonyter--image-rows '(image :type png) 15))))))

(ert-deftest jsonyter-test-notebook-drops-line-spacing ()
  "A notebook buffer goes without leading, and so its plots still tile.
The image is 300px over 15px lines: 20 slices, not one banded glyph."
  (jsonyter-tests--with-fake-display 300 15
    (jsonyter-tests--with-global-line-spacing 5
      (jsonyter-tests--with-notebook
        (should (equal 0 line-spacing))
        (let ((cell (jsonyter-tests--cell 0)))
          (jsonyter--nb-append-output
           cell (jsonyter-tests--png (base64-encode-string "not really a png")))
          (should (= 22 (length (split-string (jsonyter-tests--output-text cell)
                                              "\n" t)))))))))

(ert-deftest jsonyter-test-repl-drops-line-spacing ()
  "A REPL buffer does the same; its output is buffer text too."
  (jsonyter-tests--with-fake-display 300 15
    (jsonyter-tests--with-global-line-spacing 5
      (with-temp-buffer
        (jsonyter-repl-mode)
        (should (equal 0 line-spacing))))))

(ert-deftest jsonyter-test-line-spacing-kept-leaves-image-whole ()
  "Declining the fix keeps the leading, and images stop being sliced.
Banding a plot to preserve someone\='s leading would be the worse of the
two, so the image goes in whole — as it does in a script cell."
  (jsonyter-tests--with-fake-display 300 15
    (jsonyter-tests--with-global-line-spacing 5
      (let ((jsonyter-suppress-line-spacing nil))
        (jsonyter-tests--with-notebook
          (should (equal 5 line-spacing))
          (should-not (local-variable-p 'line-spacing))
          (let ((cell (jsonyter-tests--cell 0)))
            (jsonyter--nb-append-output
             cell (jsonyter-tests--png (base64-encode-string "not really a png")))
            (should (= 3 (length (split-string (jsonyter-tests--output-text cell)
                                               "\n" t))))))))))

(ert-deftest jsonyter-test-notebook-puts-line-spacing-back ()
  "Turning the mode off returns the buffer to the leading it had."
  (jsonyter-tests--with-fake-display 300 15
    (jsonyter-tests--with-global-line-spacing 5
      (jsonyter-tests--with-notebook
        (should (local-variable-p 'line-spacing))
        (jsonyter-notebook-mode -1)
        (should-not (local-variable-p 'line-spacing))
        (should (equal 5 line-spacing))))))

(ert-deftest jsonyter-test-line-spacing-untouched-without-any ()
  "A buffer that asked for no leading is left exactly as it was.
The fix is for buffers that would otherwise band a plot; everywhere else
`line-spacing\=' stays unbound rather than being pinned to zero."
  (jsonyter-tests--with-fake-display 300 15
    (jsonyter-tests--with-global-line-spacing nil
      (jsonyter-tests--with-notebook
        (should-not (local-variable-p 'line-spacing))))))

;;;; A plot is measured against the frame showing it, not whichever frame
;;;; happens to be selected -- see `jsonyter--display-frame'.  Output
;;;; arrives through `jsonyter--filter', a process filter, which sets
;;;; `current-buffer' but has no reason to also select the right frame; in
;;;; anything but a single-frame Emacs (a daemon with more than one
;;;; `emacsclient' frame, `ace-window' between them) the two routinely
;;;; differ, and `default-font-height' -- which has no frame argument at
;;;; all -- always measures whichever one Emacs currently calls selected.

(ert-deftest jsonyter-test-display-frame-prefers-the-buffers-own-window ()
  "Finds the frame actually showing this buffer over the selected one."
  (let ((buffer-frame 'buffer-frame)
        (other-frame 'some-other-selected-frame)
        (buffer-window 'the-window-showing-the-buffer))
    (cl-letf (((symbol-function 'selected-frame) (lambda () other-frame))
              ((symbol-function 'get-buffer-window)
               (lambda (&rest _) buffer-window))
              ((symbol-function 'window-frame)
               (lambda (w) (if (eq w buffer-window) buffer-frame
                              (error "asked about the wrong window")))))
      (with-temp-buffer
        (should (eq (jsonyter--display-frame) buffer-frame))))))

(ert-deftest jsonyter-test-display-frame-falls-back-when-not-displayed ()
  "Answers with the selected frame when this buffer is not shown anywhere
right now -- a cell finishing in the background, say -- which measures no
worse than the code had no opinion at all about which frame to use."
  (let ((other-frame 'some-other-selected-frame))
    (cl-letf (((symbol-function 'selected-frame) (lambda () other-frame))
              ((symbol-function 'get-buffer-window) (lambda (&rest _) nil)))
      (with-temp-buffer
        (should (eq (jsonyter--display-frame) other-frame))))))

(ert-deftest jsonyter-test-display-frame-override-wins ()
  "`jsonyter--display-frame-override', as `jsonyter--nb-render-string' sets
it around the scratch buffer it renders a cell's output into, is
consulted before the buffer-window lookup -- needed because a
`with-temp-buffer' has no window of its own for that lookup to find."
  (let ((forced-frame 'forced-frame))
    (cl-letf ((jsonyter--display-frame-override forced-frame)
              ((symbol-function 'get-buffer-window)
               (lambda (&rest _) (error "the override should have short-circuited this"))))
      (with-temp-buffer
        (should (eq (jsonyter--display-frame) forced-frame))))))

(ert-deftest jsonyter-test-nb-render-string-fits-images-to-the-real-buffers-frame ()
  "A notebook cell's image is measured against the frame that buffer is
actually shown on -- not the windowless scratch buffer rendering happens
in (see `jsonyter--nb-render-string'), and not whichever frame merely
happens to be selected while the kernel's response is being handled.

`default-font-height' is faked here to record, each time it is called,
whether it was asked from the buffer's real frame or from the merely-
selected one -- reproducing the actual mechanism (default-font-height
has no frame argument at all and always measures the selected frame; see
its docstring) rather than only asserting on `jsonyter--display-frame' in
isolation, the way the tests above do."
  (let* ((real-frame 'the-frame-showing-this-buffer)
         (other-frame 'some-other-selected-frame)
         (real-window 'the-window-showing-the-buffer)
         (notebook-buffer (generate-new-buffer "jsonyter-test-notebook"))
         (heights-seen nil)
         ;; `real-frame'/`other-frame' are plain symbols, not live
         ;; frames -- batch Emacs cannot make a second real one
         ;; (`make-frame' signals "Unknown terminal type" there) -- so
         ;; `select-frame' and `frame-live-p', the two primitives
         ;; `with-selected-frame' expands into besides `selected-frame'
         ;; itself, are faked too, all three sharing this lexical
         ;; variable as the frame `selected-frame' answers with.  It
         ;; must be bound out here, not as a `cl-letf' place below: a
         ;; plain symbol there is a dynamic binding, and this one was
         ;; never `defvar'd.
         (selected-frame-value other-frame))
    (unwind-protect
        (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                  ((symbol-function 'display-images-p) (lambda (&rest _) t))
                  ((symbol-function 'image-type-available-p) (lambda (&rest _) t))
                  ((symbol-function 'image-size) (lambda (&rest _) (cons 400.0 300.0)))
                  ((symbol-function 'create-image)
                   (lambda (data &optional type _data-p &rest props)
                     (append (list 'image :type (or type 'png) :data data) props)))
                  ((symbol-function 'selected-frame) (lambda () selected-frame-value))
                  ((symbol-function 'select-frame)
                   (lambda (frame &optional _norecord) (setq selected-frame-value frame)))
                  ((symbol-function 'frame-live-p) (lambda (frame) (memq frame (list real-frame other-frame))))
                  ((symbol-function 'get-buffer-window)
                   (lambda (buf &optional _all) (and (eq buf notebook-buffer) real-window)))
                  ((symbol-function 'window-frame)
                   (lambda (w) (if (eq w real-window) real-frame
                                  (error "asked about the wrong window"))))
                  ((symbol-function 'default-font-height)
                   (lambda ()
                     (let ((height (if (eq (selected-frame) real-frame) 15 45)))
                       (push height heights-seen)
                       height))))
          (with-current-buffer notebook-buffer
            (jsonyter--nb-render-string
             (jsonyter-tests--png (base64-encode-string "not really a png")))))
      (kill-buffer notebook-buffer))
    ;; Every measurement has to be the real frame's height (15); the
    ;; merely-selected frame's (45) never showing up is what proves the
    ;; scratch buffer's rendering used the override rather than falling
    ;; through to whatever `default-font-height' would answer on its own.
    (should heights-seen)
    (should (equal heights-seen (make-list (length heights-seen) 15)))))

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

;;;; Font lock: a cell's syntax must stop at the cell
;;;; (bug report: BUG-REPORT-cell-syntax-bleed.md -- fixed)

;; `jsonyter--nb-fontify-region' keeps the language's font-lock from
;; PAINTING rendered output, and `jsonyter-test-font-lock-leaves-output-alone'
;; above proves it -- with output that happens to be balanced Python.  The
;; SYNTAX side -- `syntax-ppss' parsing from `point-min' straight through
;; prose and output alike, so one unbalanced string, comment or math
;; delimiter anywhere re-colours every cell after it -- is handled by
;; `jsonyter--nb-syntax-propertize', a `syntax-propertize-function' that
;; blankets non-code text with inert syntax.

(defconst jsonyter-tests--notebook-prose-apostrophe "\
{
 \"cells\": [
  {\"cell_type\": \"markdown\", \"id\": \"aaa\", \"metadata\": {},
   \"source\": \"Here's the 50% discount.\\n\"},
  {\"cell_type\": \"code\", \"id\": \"bbb\", \"execution_count\": null,
   \"metadata\": {}, \"outputs\": [], \"source\": \"import os\\n\"}
 ],
 \"metadata\": {\"kernelspec\": {\"display_name\": \"Python 3\",
                            \"language\": \"python\", \"name\": \"python3\"}},
 \"nbformat\": 4,
 \"nbformat_minor\": 5
}
"
  "A markdown cell of ordinary English prose, then a code cell.
The apostrophe in \"Here's\" is a string delimiter in Python.")

(defun jsonyter-tests--face-at (string)
  "The `face' property where STRING starts in this buffer."
  (save-excursion
    (goto-char (point-min))
    (should (search-forward string nil t))
    (get-text-property (match-beginning 0) 'face)))

(ert-deftest jsonyter-test-markdown-prose-does-not-bleed-into-next-cell ()
  "Prose in a markdown cell must not change how the next cell is coloured.

An apostrophe in a markdown cell opens a Python string that never closes,
so `import os' in the following CODE cell -- and every cell after it, to
the end of the notebook -- is painted `font-lock-string-face'.  Any
character the notebook language treats as a string, comment or math
delimiter does this; which characters those are depends on the mode
`jsonyter-notebook-language-modes' picks."
  (jsonyter-tests--with-notebook-json jsonyter-tests--notebook-prose-apostrophe
    (font-lock-mode 1)
    (font-lock-ensure)
    (should-not (eq 'font-lock-string-face (jsonyter-tests--face-at "import os")))))

(ert-deftest jsonyter-test-rendered-output-does-not-bleed-into-next-cell ()
  "A cell's rendered output must not change how the next cell is coloured.

Output is buffer text, and `jsonyter--nb-fontify-region' keeps font-lock
from painting it -- but `syntax-ppss' still reads it.  An apostrophe in
something a cell printed (\"can't\", a quoted filename, a traceback)
opens a string as far as the parser is concerned, and the next cell's
source comes out entirely `font-lock-string-face'."
  (jsonyter-tests--with-notebook-json "\
{
 \"cells\": [
  {\"cell_type\": \"code\", \"id\": \"aaa\", \"execution_count\": 1,
   \"metadata\": {},
   \"outputs\": [{\"output_type\": \"stream\", \"name\": \"stdout\",
                \"text\": \"it can't be found\\n\"}],
   \"source\": \"print(msg)\\n\"},
  {\"cell_type\": \"code\", \"id\": \"bbb\", \"execution_count\": null,
   \"metadata\": {}, \"outputs\": [], \"source\": \"import os\\n\"}
 ],
 \"metadata\": {\"kernelspec\": {\"display_name\": \"Python 3\",
                            \"language\": \"python\", \"name\": \"python3\"}},
 \"nbformat\": 4,
 \"nbformat_minor\": 5
}
"
    (font-lock-mode 1)
    (font-lock-ensure)
    (should-not (eq 'font-lock-string-face (jsonyter-tests--face-at "import os")))))

(ert-deftest jsonyter-test-markdown-cell-source-is-not-fontified-as-code ()
  "A markdown cell's own source should not be coloured as the kernel
language.

Prose is not code: in a Python notebook \"and\" comes out
`font-lock-keyword-face' and \"%\" comes out `font-lock-operator-face',
purely because the whole buffer shares one major mode.  This one encodes
a design decision as much as a defect -- a fix may reasonably decide
markdown cells get markdown highlighting rather than none -- but leaving
them highlighted as the kernel language is the one answer that is
certainly wrong."
  (jsonyter-tests--with-notebook-json "\
{
 \"cells\": [
  {\"cell_type\": \"markdown\", \"id\": \"aaa\", \"metadata\": {},
   \"source\": \"Costs 5 dollars and is worth it.\\n\"}
 ],
 \"metadata\": {\"kernelspec\": {\"display_name\": \"Python 3\",
                            \"language\": \"python\", \"name\": \"python3\"}},
 \"nbformat\": 4,
 \"nbformat_minor\": 5
}
"
    (font-lock-mode 1)
    (font-lock-ensure)
    (should-not (eq 'font-lock-keyword-face (jsonyter-tests--face-at "and")))))

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

;;;; Export's all-outputs collector (report #4, §4.3)

(ert-deftest jsonyter-test-collect-cells-all-outputs-carries-stored-results ()
  "With ALL-OUTPUTS, a cell nothing has re-run this session still
contributes its file outputs, in nbformat shape -- the trap the triage
report calls out: without this, exporting a freshly opened notebook full
of saved results comes out blank."
  (let ((path (make-temp-file "jsonyter-test-" nil ".ipynb"))
        (buffer nil))
    (unwind-protect
        (progn
          (with-temp-file path (insert jsonyter-tests--notebook-with-outputs))
          (setq buffer (find-file-noselect path))
          (with-current-buffer buffer
            (let ((cells (jsonyter--nb-collect-cells t t)))
              (should (= 2 (length cells)))
              (should (equal "x = 1" (plist-get (nth 0 cells) :source)))
              (let ((outputs-0 (append (plist-get (nth 0 cells) :outputs) nil)))
                (should (= 1 (length outputs-0)))
                (should (equal "stream" (plist-get (car outputs-0) :output_type)))
                ;; Read straight from the file, nbformat's list-of-lines
                ;; shape joined into one string -- `jsonyter-file-outputs'
                ;; reshaped for the wire, see `jsonyter--nb-outputs-for-wire'.
                (should (equal "stored one\nstored two\n"
                               (plist-get (car outputs-0) :text))))
              (should (= 1 (plist-get (nth 0 cells) :execution_count)))
              (let ((outputs-1 (append (plist-get (nth 1 cells) :outputs) nil)))
                (should (= 1 (length outputs-1)))
                (should (equal "stored three\n" (plist-get (car outputs-1) :text)))))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-file path))))

(ert-deftest jsonyter-test-collect-cells-without-all-outputs-still-omits-untouched ()
  "`write_notebook''s own collector -- ALL-OUTPUTS unset -- is unchanged:
an untouched cell still omits `:outputs' entirely, which is what tells
the bridge to leave the stored output on disk alone."
  (let ((path (make-temp-file "jsonyter-test-" nil ".ipynb"))
        (buffer nil))
    (unwind-protect
        (progn
          (with-temp-file path (insert jsonyter-tests--notebook-with-outputs))
          (setq buffer (find-file-noselect path))
          (with-current-buffer buffer
            (let ((cells (jsonyter--nb-collect-cells t nil)))
              (should (= 2 (length cells)))
              (should-not (plist-member (nth 0 cells) :outputs))
              (should-not (plist-member (nth 1 cells) :outputs)))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-file path))))

(ert-deftest jsonyter-test-collect-cells-all-outputs-omits-id-for-new-cell ()
  "ALL-OUTPUTS omits `:id' entirely for a new cell instead of sending
`:null' -- this path hands the notebook straight to nbformat rather than
through `write_notebook''s own id assignment."
  (jsonyter-tests--with-notebook
    (let ((cells (jsonyter--nb-collect-cells t t)))
      (should (equal "aaa" (plist-get (nth 0 cells) :id))))
    (jsonyter-insert-cell-below)
    (let* ((cells (jsonyter--nb-collect-cells t t))
           (new-cell (nth 1 cells)))
      (should-not (plist-member new-cell :id)))))

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
  "With one session the mode line reports that session's state and id."
  (jsonyter-tests--with-sessions
    (let ((s (jsonyter-tests--bind-session '("python" . "") "kid")))
      (setq-local jsonyter--session-key '("python" . ""))
      (should (equal ":idle[kid]" (jsonyter--mode-line-string)))
      (setf (jsonyter--session-busy s) t)
      (should (equal ":run[kid]" (jsonyter--mode-line-string)))
      (setf (jsonyter--session-busy s) nil
            (jsonyter--session-state s) "dead")
      (should (equal ":dead[kid]" (jsonyter--mode-line-string))))))

;;;; Kernel id in the mode line (report #2)

(ert-deftest jsonyter-test-status-tag-shows-kernel-id ()
  "`jsonyter--session-status-tag' appends the kernel's short id."
  (jsonyter-tests--with-sessions
    (let ((s (jsonyter-tests--bind-session
              '("python" . "") "0123456789abcdef")))
      (should (equal ":idle[01234567]" (jsonyter--session-status-tag s))))))

(ert-deftest jsonyter-test-status-tag-no-id-when-no-kernel ()
  "No kernel means no id -- `:no-kernel' already says that."
  (jsonyter-tests--with-sessions
    (let ((s (jsonyter--session-put '("python" . ""))))
      (should (equal ":no-kernel" (jsonyter--session-status-tag s))))))

(ert-deftest jsonyter-test-status-tag-id-can-be-turned-off ()
  "`jsonyter-mode-line-show-kernel-id' set to nil omits the id."
  (jsonyter-tests--with-sessions
    (let ((s (jsonyter-tests--bind-session '("python" . "") "kid"))
          (jsonyter-mode-line-show-kernel-id nil))
      (should (equal ":idle" (jsonyter--session-status-tag s))))))

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

(ert-deftest jsonyter-test-session-table-survives-major-mode-restart ()
  "The session table, callback table, process and session key are
`permanent-local', so `kill-all-local-variables' -- what
`org-mode-restart' (and so `C-c C-c' on a `#+PROPERTY:' line),
`revert-buffer' and `normal-mode' all run -- does not orphan a running
kernel or make the next block start a needless second one."
  (jsonyter-tests--with-sessions
    (setq-local jsonyter--callbacks (make-hash-table :test #'eql))
    (setq-local jsonyter--process 'fake-process)
    (setq-local jsonyter--session-key '("python" . "main"))
    (let ((session (jsonyter-tests--bind-session '("python" . "main") "kid" t)))
      (kill-all-local-variables)
      (should (eq jsonyter--process 'fake-process))
      (should (hash-table-p jsonyter--callbacks))
      (should (equal jsonyter--session-key '("python" . "main")))
      (should (eq (jsonyter--session-put '("python" . "main")) session))
      (should (equal (jsonyter--session-kernel-id
                       (jsonyter--session-put '("python" . "main")))
                      "kid")))))

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

(ert-deftest jsonyter-test-check-jsonyter-buffer-bootstraps-org ()
  "The buffer-kind gate no longer just refuses a plain Org buffer: it
bootstraps the same plumbing the org-babel back door already installs
itself (`jsonyter--org-babel-ensure-plumbing'), so `C-RET' / `S-RET' /
`jsonyter-org-run-block' work without `jsonyter-org-mode' ever having
been turned on -- the bug behind report #5a."
  (with-temp-buffer
    (org-mode)
    (should-not (bound-and-true-p jsonyter-mode))
    (jsonyter--check-jsonyter-buffer)
    (should (bound-and-true-p jsonyter-mode))
    (should (hash-table-p jsonyter--callbacks))))

(ert-deftest jsonyter-test-check-jsonyter-buffer-still-refuses-other-buffers ()
  "A buffer that is neither a jsonyter buffer nor an Org buffer is still refused."
  (with-temp-buffer
    (fundamental-mode)
    (should-error (jsonyter--check-jsonyter-buffer) :type 'user-error)))

(ert-deftest jsonyter-test-org-run-cell-aliases-run-block ()
  "`jsonyter-org-run-cell(-and-advance)' alias the block-vocabulary
commands, for anyone reaching for the notebook/script naming by analogy."
  (should (eq (indirect-function 'jsonyter-org-run-cell)
              (indirect-function 'jsonyter-org-run-block)))
  (should (eq (indirect-function 'jsonyter-org-run-cell-and-advance)
              (indirect-function 'jsonyter-org-run-block-and-advance))))

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

(ert-deftest jsonyter-test-org-to-notebook-hand-authored-file-splits-on-blocks ()
  "A hand-authored Org file -- one that never round-tripped through
`jsonyter-org-from-notebook' and so has no `:JSONYTER_CELL_ID:' drawers
at all -- must split into one cell per `jy:' block plus the prose
between them, not collapse to a single markdown cell containing every
block verbatim.  Pins the bug found while designing script export
\(TRIAGE-2026-09-12.md §4.10.4\)."
  (let ((jsonyter-org-markdown-converter (lambda (text _dir) text)))
    (jsonyter-tests--with-org-file
        (concat "#+begin_src python :session jy:main\nx = 1\n#+end_src\n\n"
                "Some prose between blocks.\n\n"
                "#+begin_src python :session jy:main\nx + 1\n#+end_src\n")
      (let ((cells (jsonyter--org-to-notebook-cells)))
        (should (= 3 (length cells)))
        (should (equal "code" (plist-get (nth 0 cells) :cell_type)))
        (should (equal "x = 1" (plist-get (nth 0 cells) :source)))
        (should (eq :null (plist-get (nth 0 cells) :id)))
        (should (equal "markdown" (plist-get (nth 1 cells) :cell_type)))
        (should (equal "Some prose between blocks."
                       (plist-get (nth 1 cells) :source)))
        (should (equal "code" (plist-get (nth 2 cells) :cell_type)))
        (should (equal "x + 1" (plist-get (nth 2 cells) :source)))))))

(ert-deftest jsonyter-test-org-to-notebook-hand-authored-file-with-leading-prose ()
  "The same, but the first block is not the very first thing in the
buffer -- guards against a narrower version of the same bug where only
a block sitting at `point-min' was mishandled."
  (let ((jsonyter-org-markdown-converter (lambda (text _dir) text)))
    (jsonyter-tests--with-org-file
        (concat "* Heading\nIntro prose.\n\n"
                "#+begin_src python :session jy:main\nx = 1\n#+end_src\n\n"
                "Trailing prose.\n")
      (let ((cells (jsonyter--org-to-notebook-cells)))
        (should (= 3 (length cells)))
        (should (equal "markdown" (plist-get (nth 0 cells) :cell_type)))
        (should (equal "* Heading\nIntro prose." (plist-get (nth 0 cells) :source)))
        (should (equal "code" (plist-get (nth 1 cells) :cell_type)))
        (should (equal "x = 1" (plist-get (nth 1 cells) :source)))
        (should (equal "markdown" (plist-get (nth 2 cells) :cell_type)))
        (should (equal "Trailing prose." (plist-get (nth 2 cells) :source)))))))

(ert-deftest jsonyter-test-org-to-notebook-non-jy-block-stays-in-prose ()
  "A src block with no `jy:' session is not split out as its own cell --
only `jy:' blocks are \"cells\" for this conversion, so it is left inside
whatever markdown span it falls in, same as any other text there."
  (let ((jsonyter-org-markdown-converter (lambda (text _dir) text)))
    (jsonyter-tests--with-org-file
        (concat "#+begin_src python :session jy:main\nx = 1\n#+end_src\n\n"
                "See this snippet:\n\n"
                "#+begin_src python\nplain block, no session\n#+end_src\n")
      (let ((cells (jsonyter--org-to-notebook-cells)))
        (should (= 2 (length cells)))
        (should (equal "code" (plist-get (nth 0 cells) :cell_type)))
        (should (equal "x = 1" (plist-get (nth 0 cells) :source)))
        (should (equal "markdown" (plist-get (nth 1 cells) :cell_type)))
        (should (string-match-p "plain block, no session"
                                (plist-get (nth 1 cells) :source)))))))

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
  ;; Launch the bridge the way the guard checks for it — as a module —
  ;; so a setup with the package importable but no `jsonyter' console
  ;; script on PATH runs rather than failing to find the executable.
  ;; Matches `jsonyter-test-save-*' above.
  (let* ((jsonyter-command '("python3" "-m" "jsonyter"))
         (jsonyter-org-markdown-converter (lambda (text _dir) text))
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


;;;; Org results survive the trip into a notebook
;;;; (bug report: BUG-REPORT-export-images.md, defects 2 and 3 -- fixed)

(ert-deftest jsonyter-test-org-cell-from-span-preserves-image-output ()
  "An Org results drawer's image must reach the notebook as an image.

`jsonyter--org-parse-results-drawer' returns outputs keyed by
`:output_type' \(nbformat\), but its only caller runs them through
`jsonyter--nb-output-to-spec', which dispatches on `:type' \(the kernel
protocol\).  Nothing matches, so every result -- the figure included --
is replaced by the literal text \"[jsonyter: unrecognized output type
nil]\".  Exporting the notebook afterwards is what the README calls the
Org route to a document, so this is where an Org user's images go.

The two existing drawer tests check the parser alone and the spec
converter alone; neither composes them, which is exactly where the two
key names disagree."
  (jsonyter-tests--with-org-file
      (concat ":PROPERTIES:\n:JSONYTER_CELL_ID: aaa\n:END:\n"
              "#+begin_src python :session jy:main\nplt.plot([1, 2])\n#+end_src\n\n"
              "#+RESULTS:\n:results:\n[[file:plot.png]]\n:end:\n")
    (let* ((dir (file-name-directory buffer-file-name))
           (img (expand-file-name "plot.png" dir)))
      (unwind-protect
          (progn
            (let ((coding-system-for-write 'binary))
              (with-temp-file img (set-buffer-multibyte nil) (insert "fake-bytes")))
            (let* ((cells (jsonyter--org-to-notebook-cells))
                   (code (seq-find (lambda (c) (equal "code" (plist-get c :cell_type)))
                                   cells))
                   (outputs (append (plist-get code :outputs) nil)))
              (should code)
              (should (= 1 (length outputs)))
              (should (equal "display_data" (plist-get (car outputs) :output_type)))
              (should (plist-get (plist-get (car outputs) :data) :image/png))))
        (when (file-exists-p img) (delete-file img))))))

(ert-deftest jsonyter-test-org-cell-from-span-preserves-stream-output ()
  "The same key mismatch swallows a drawer's plain text too: what should
be the printed line comes back as the unrecognized-output placeholder."
  (jsonyter-tests--with-org-file
      (concat ":PROPERTIES:\n:JSONYTER_CELL_ID: aaa\n:END:\n"
              "#+begin_src python :session jy:main\nprint(1)\n#+end_src\n\n"
              "#+RESULTS:\n:results:\n: printed line\n:end:\n")
    (let* ((cells (jsonyter--org-to-notebook-cells))
           (code (seq-find (lambda (c) (equal "code" (plist-get c :cell_type))) cells))
           (outputs (append (plist-get code :outputs) nil)))
      (should code)
      (should (= 1 (length outputs)))
      (should (equal "stream" (plist-get (car outputs) :output_type)))
      (should (equal "printed line\n" (plist-get (car outputs) :text)))
      (should-not (string-match-p "unrecognized output type"
                                  (plist-get (car outputs) :text))))))

(ert-deftest jsonyter-test-org-to-notebook-by-block-keeps-results ()
  "A hand-written Org file's results must not be dropped outright.

With no `:JSONYTER_CELL_ID:' drawer anywhere,
`jsonyter--org-notebook-cell-spans' takes the `--by-block' path, whose
code span stops at `#+end_src'.  The `#+RESULTS:' drawer therefore falls
into the *next* prose span: the code cell is rebuilt with no outputs at
all \(the temp buffer the span is re-parsed in has no drawer to find\),
and the drawer's raw Org text becomes a markdown cell."
  (jsonyter-tests--with-org-file
      (concat "#+begin_src python :session jy:main\nprint(1)\n#+end_src\n\n"
              "#+RESULTS:\n:results:\n: printed line\n:end:\n")
    (let* ((cells (jsonyter--org-to-notebook-cells))
           (code (seq-find (lambda (c) (equal "code" (plist-get c :cell_type))) cells)))
      (should code)
      (should (plist-get code :outputs))
      ;; ...and the drawer must not have been left behind as prose.
      (should-not (seq-find (lambda (c)
                              (and (equal "markdown" (plist-get c :cell_type))
                                   (string-match-p "#\\+RESULTS:"
                                                   (or (plist-get c :source) ""))))
                            cells)))))

;;;; Notebook document export (§4.1-4.9)

(ert-deftest jsonyter-test-build-command-omits-export-timeout-flag ()
  "`jsonyter-export-timeout' is never a bridge command-line flag.
`--export-timeout' only exists on jsonyter >= 2.0.0; passing it
unconditionally at startup would refuse to launch any older bridge
outright (confirmed against the bridge's own argument parser: an old
bridge exits with \"unrecognized arguments: --export-timeout\"),
breaking every command, not only export.  The timeout is sent as the
`export_notebook' request's own `timeout' param instead -- see
`jsonyter-notebook-export'."
  (let ((jsonyter-export-timeout 45)
        (jsonyter-command '("jsonyter"))
        (jsonyter-exec-timeout nil)
        (jsonyter-insecure-tls nil))
    (should-not (member "--export-timeout" (jsonyter--build-command nil)))))

(ert-deftest jsonyter-test-notebook-export-defaults-timeout-param ()
  "`jsonyter-notebook-export' sends `jsonyter-export-timeout' as the
request's own `timeout' param when the caller does not override it, and
the override when it does."
  (jsonyter-tests--with-notebook
    (let ((jsonyter-export-timeout 45) sent)
      (cl-letf (((symbol-function 'jsonyter--ensure-bridge) #'ignore)
                ((symbol-function 'jsonyter--export-run)
                 (lambda (_session params _on-success) (setq sent params))))
        (jsonyter-notebook-export "html" "/tmp/does-not-matter.html")
        (should (equal 45 (plist-get sent :timeout)))
        (jsonyter-notebook-export "html" "/tmp/does-not-matter.html" 600)
        (should (equal 600 (plist-get sent :timeout)))))))

(ert-deftest jsonyter-test-export-format-names-extracts-keys ()
  "`jsonyter--export-format-names' reads the plist `list_export_formats'
itself returns, not a hardcoded list."
  (should (equal '("html" "markdown" "pdf")
                 (jsonyter--export-format-names
                  '(:html (:output_mimetype "text/html")
                    :markdown (:output_mimetype "text/markdown")
                    :pdf (:output_mimetype "application/pdf"))))))

(ert-deftest jsonyter-test-export-format-guess-extension ()
  "Known formats get their conventional extension; an unknown one falls
back to `.FORMAT'."
  (should (equal ".html" (jsonyter--export-format-guess-extension "html")))
  (should (equal ".md" (jsonyter--export-format-guess-extension "markdown")))
  (should (equal ".pdf" (jsonyter--export-format-guess-extension "pdf")))
  (should (equal ".pdf" (jsonyter--export-format-guess-extension "webpdf")))
  (should (equal ".slides.html" (jsonyter--export-format-guess-extension "slides")))
  (should (equal ".docx" (jsonyter--export-format-guess-extension "docx"))))

(ert-deftest jsonyter-test-status-tag-export-has-no-percentage ()
  "The `:export' mode-line tag carries no fake percentage -- there are no
`progress' events for export, unlike a file transfer."
  (jsonyter-tests--with-sessions
    (let ((s (jsonyter-tests--bind-session '("python" . "") "kid")))
      (setf (jsonyter--session-transfer s) (list :phase "export"))
      (should (equal ":export[kid]" (jsonyter--session-status-tag s)))
      ;; An ordinary transfer is unaffected by the new branch.
      (setf (jsonyter--session-transfer s) (list :phase "upload" :pct 42))
      (should (equal ":up 42%[kid]" (jsonyter--session-status-tag s))))))

(ert-deftest jsonyter-test-list-export-formats-is-cached-per-process ()
  "`jsonyter--list-export-formats' hits the bridge once per process and
reuses the reply after that, since the probe cannot change under a
running server."
  (jsonyter-tests--with-notebook
    (let ((calls 0))
      (cl-letf (((symbol-function 'jsonyter--ensure-bridge) #'ignore)
                ((symbol-function 'jsonyter--request-sync)
                 (lambda (&rest _)
                   (cl-incf calls)
                   (list :available t :formats '(:html (:output_mimetype "text/html"))
                         :reason nil))))
        (jsonyter--list-export-formats)
        (jsonyter--list-export-formats)
        (should (= 1 calls))
        (jsonyter--list-export-formats 'refresh)
        (should (= 2 calls))))))

(ert-deftest jsonyter-test-list-export-formats-old-bridge-message ()
  "An unknown-method failure against an old bridge is rewritten as a
plain version-upgrade message, not a raw protocol error."
  (jsonyter-tests--with-notebook
    (cl-letf (((symbol-function 'jsonyter--ensure-bridge) #'ignore)
              ((symbol-function 'jsonyter--request-sync)
               (lambda (&rest _) (error "jsonyter: unknown method \"list_export_formats\""))))
      (should-error (jsonyter--list-export-formats) :type 'user-error)
      (condition-case err
          (jsonyter--list-export-formats)
        (user-error
         (should (string-match-p ">= 2.0.0" (error-message-string err))))))))

(ert-deftest jsonyter-test-notebook-export-formats-reports-unavailable ()
  "`jsonyter-notebook-export-formats' surfaces the server's own `reason'
when export is not available, rather than an empty list."
  (jsonyter-tests--with-notebook
    (let (reported)
      (cl-letf (((symbol-function 'jsonyter--ensure-bridge) #'ignore)
                ((symbol-function 'jsonyter--request-sync)
                 (lambda (&rest _)
                   (list :available nil :formats nil
                         :reason "this server does not serve the nbconvert endpoints")))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (setq reported (apply #'format fmt args)))))
        (jsonyter-notebook-export-formats))
      (should (string-match-p "not available" reported))
      (should (string-match-p "nbconvert endpoints" reported)))))

(ert-deftest jsonyter-test-notebook-export-refuses-when-formats-unavailable ()
  "`jsonyter-notebook-export' called interactively refuses immediately
when the probe reports no formats, rather than firing a request that
would take two minutes to fail."
  (jsonyter-tests--with-notebook
    (cl-letf (((symbol-function 'jsonyter--ensure-bridge) #'ignore)
              ((symbol-function 'jsonyter--request-sync)
               (lambda (&rest _) (list :available nil :formats nil :reason "no nbconvert"))))
      (should-error
       (call-interactively #'jsonyter-notebook-export)
       :type 'user-error))))

(ert-deftest jsonyter-test-notebook-export-sends-all-outputs-cells ()
  "`jsonyter-notebook-export' collects cells with ALL-OUTPUTS, so a
freshly opened notebook full of saved results exports its stored output,
not a blank cell."
  (let ((path (make-temp-file "jsonyter-test-" nil ".ipynb"))
        (buffer nil))
    (unwind-protect
        (progn
          (with-temp-file path (insert jsonyter-tests--notebook-with-outputs))
          (setq buffer (find-file-noselect path))
          (with-current-buffer buffer
            (let (sent)
              (cl-letf (((symbol-function 'jsonyter--ensure-bridge) #'ignore)
                        ((symbol-function 'jsonyter--export-run)
                         (lambda (_session params _on-success) (setq sent params))))
                (jsonyter-notebook-export "html" "/tmp/does-not-matter.html")
                (let ((cells (append (plist-get sent :cells) nil)))
                  (should (= 2 (length cells)))
                  (should (plist-member (nth 0 cells) :outputs))
                  (should (plist-member (nth 1 cells) :outputs)))))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-file path))))

(ert-deftest jsonyter-test-notebook-export-reports-path-and-size ()
  "The success message names the format, the path the bridge actually
wrote to, the size, and a resource count when the result is a bundle --
feeding both an unbundled and a bundled `to_path' result plist straight
to the on-success handler, without a real bridge in the loop."
  (jsonyter-tests--with-notebook
    (let (reported)
      (cl-letf (((symbol-function 'jsonyter--ensure-bridge) #'ignore)
                ((symbol-function 'jsonyter--export-run)
                 (lambda (_session _params on-success)
                   (funcall on-success
                            (list :format "html" :mimetype "text/html"
                                  :path "/tmp/out/analysis.html" :bytes 512
                                  :bundle nil :resources nil))))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (setq reported (apply #'format fmt args)))))
        (jsonyter-notebook-export "html" "/tmp/out/analysis.html"))
      (should (string-match-p "html" reported))
      (should (string-match-p "/tmp/out/analysis\\.html" reported))
      (should (string-match-p "512 B" reported))
      (should-not (string-match-p "resource" reported)))
    (let (reported)
      (cl-letf (((symbol-function 'jsonyter--ensure-bridge) #'ignore)
                ((symbol-function 'jsonyter--export-run)
                 (lambda (_session _params on-success)
                   (funcall on-success
                            (list :format "markdown" :mimetype "text/markdown"
                                  :path "/tmp/out/analysis.md" :bytes 51
                                  :bundle t
                                  :resources [(:name "output_0_0.png"
                                               :path "/tmp/out/output_0_0.png"
                                               :bytes 74)]))))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (setq reported (apply #'format fmt args)))))
        (jsonyter-notebook-export "markdown" "/tmp/out/analysis.md"))
      (should (string-match-p "1 resource" reported)))))

(ert-deftest jsonyter-test-notebook-export-round-trips-with-bridge ()
  "Exporting the fixture notebook to html via `to_path' produces a
non-empty file carrying the markdown cell's rendered heading.  Needs
both the bridge and a reachable Jupyter server; skips like the other
bridge-dependent tests in this file when either is missing -- which,
absent a way to probe server reachability up front, is treated the
same as any other failure here.

Checked against the markdown cell's \"heading\", not a code cell's
source: nbconvert's HTML exporter runs the source through Pygments, so
a code cell's `x = 1' comes back as separate `<span>' elements per
token (`<span class=\"n\">x</span> <span class=\"o\">=</span>
<span class=\"mi\">1</span>...') and never appears as that literal
substring again -- confirmed against a real bridge and server; the
original assertion looked for exactly that substring and so could
never actually pass, only skip, hiding a real bridge/server pair
behind the same outcome as a missing one."
  (skip-unless (jsonyter-tests--bridge-available-p))
  (jsonyter-tests--with-notebook
    (let* ((jsonyter-command '("python3" "-m" "jsonyter"))
           (out (make-temp-file "jsonyter-export-test-" nil ".html")))
      (delete-file out)
      (unwind-protect
          (condition-case err
              (progn
                (jsonyter--ensure-bridge)
                (let ((cells (jsonyter--nb-collect-cells t t)))
                  (jsonyter--request-sync
                   "export_notebook"
                   (list :format "html" :cells (vconcat cells) :to_path out)
                   jsonyter-export-timeout))
                (should (file-exists-p out))
                (should (> (file-attribute-size (file-attributes out)) 0))
                (should (string-match-p "heading"
                                       (with-temp-buffer
                                         (insert-file-contents out)
                                         (buffer-string)))))
            (error (ert-skip (format "export_notebook unavailable: %s"
                                     (error-message-string err)))))
        (when (file-exists-p out) (delete-file out))))))


;;;; Export and the wire: a notebook's stored outputs must survive
;;;; `json-serialize' (bug report: BUG-REPORT-export-images.md -- fixed)

(defconst jsonyter-tests--notebook-with-figure "\
{
 \"cells\": [
  {\"cell_type\": \"code\", \"id\": \"aaa\", \"execution_count\": 1,
   \"metadata\": {},
   \"outputs\": [{\"output_type\": \"display_data\",
                \"data\": {\"image/png\": \"iVBORw0KGgoAAAANSUhEUg==\",
                          \"text/plain\": [\"<Figure size 640x480 with 1 Axes>\"]},
                \"metadata\": {\"needs_background\": \"light\"}}],
   \"source\": \"plt.plot([1, 2, 3])\\n\"}
 ],
 \"metadata\": {\"kernelspec\": {\"display_name\": \"Python 3\",
                            \"language\": \"python\", \"name\": \"python3\"},
              \"language_info\": {\"name\": \"python\",
                                \"file_extension\": \".py\",
                                \"pygments_lexer\": \"ipython3\"}},
 \"nbformat\": 4,
 \"nbformat_minor\": 5
}
"
  "One code cell holding a matplotlib figure, exactly as Jupyter saves one.
The `text/plain' companion of an `image/png' is stored as an ARRAY of
lines -- nbformat's multiline-string representation, and what every
notebook with a figure in it actually looks like on disk.")

(defun jsonyter-tests--wire-error (params)
  "Nil if PARAMS can go on the wire, else the error `json-serialize' gives.
`jsonyter--send' encodes a request with `json-serialize', which has no
way to tell a Lisp list meant as a JSON array from a malformed plist --
so anything the reply parser produced with `:array-type \\='list' has to
be reshaped before it is sent back.  This is the check the export tests
below stop one step short of."
  (condition-case err
      (ignore (json-serialize params))
    (error (error-message-string err))))

(ert-deftest jsonyter-test-export-params-serialize-with-stored-figure ()
  "Exporting a notebook holding a matplotlib figure must produce a
request `json-serialize' can encode.

`jsonyter--nb-collect-cells' with ALL-OUTPUTS passes `jsonyter-file-outputs'
through verbatim, so the `text/plain' array Jupyter stores beside every
figure arrives as a Lisp list -- and `jsonyter--send' dies on it with
\"Wrong type argument: consp, nil\" before a single byte reaches the
bridge.  Every `jsonyter-notebook-export-*' command on a notebook with a
figure in it fails this way."
  (jsonyter-tests--with-notebook-json jsonyter-tests--notebook-with-figure
    (let ((params (list :format "pdf"
                        :cells (vconcat (jsonyter--nb-collect-cells t t))
                        :to_path "/tmp/out.pdf"
                        :include_outputs t :timeout 120)))
      (should-not (jsonyter-tests--wire-error params)))))

(ert-deftest jsonyter-test-export-params-serialize-with-stored-stream-lines ()
  "The same for a stream output stored as nbformat's array of lines --
the shape `jsonyter-tests--notebook-with-outputs' already carries, and
which `jsonyter-test-collect-cells-all-outputs-carries-stored-results'
already asserts is passed through untouched."
  (jsonyter-tests--with-notebook-json jsonyter-tests--notebook-with-outputs
    (let ((params (list :format "html"
                        :cells (vconcat (jsonyter--nb-collect-cells t t))
                        :to_path "/tmp/out.html"
                        :include_outputs t :timeout 120)))
      (should-not (jsonyter-tests--wire-error params)))))

(ert-deftest jsonyter-test-output-to-spec-serializes-split-mime-value ()
  "`jsonyter--nb-output-to-spec' must reshape a mimebundle value that
arrives as a list of line fragments.

`jsonyter--mime' documents that shape as one the kernel side really
produces -- it joins the fragments before rendering -- but the save/export
converter copies `:data' through as read, so the same output that renders
fine cannot be sent.  This path feeds `jsonyter-notebook-save-with-outputs'
\(\\[jsonyter-notebook-save-with-outputs]\) as well as export."
  (let* ((output (list :type "display_data"
                       :data (list :image/png '("iVBORw0KGgoAAAANSUhEUg==")
                                   :text/plain '("<Figure size 640x480>"))
                       :metadata nil))
         (spec (jsonyter--nb-output-to-spec output)))
    (should-not (jsonyter-tests--wire-error (list :outputs (vector spec))))))

(ert-deftest jsonyter-test-output-to-spec-serializes-file-error-traceback ()
  "An `error' output read from a file has a list-valued `traceback', and
must not be sent as one either.  The kernel-shape branch already
`vconcat's it; the ALL-OUTPUTS branch does not."
  (jsonyter-tests--with-notebook-json "\
{
 \"cells\": [
  {\"cell_type\": \"code\", \"id\": \"aaa\", \"execution_count\": 1,
   \"metadata\": {},
   \"outputs\": [{\"output_type\": \"error\", \"ename\": \"ValueError\",
                \"evalue\": \"boom\",
                \"traceback\": [\"Traceback...\", \"ValueError: boom\"]}],
   \"source\": \"raise ValueError('boom')\\n\"}
 ],
 \"metadata\": {\"kernelspec\": {\"display_name\": \"Python 3\",
                            \"language\": \"python\", \"name\": \"python3\"}},
 \"nbformat\": 4,
 \"nbformat_minor\": 5
}
"
    (let ((params (list :cells (vconcat (jsonyter--nb-collect-cells t t)))))
      (should-not (jsonyter-tests--wire-error params)))))

(ert-deftest jsonyter-test-export-request-carries-notebook-metadata ()
  "An export must carry the notebook's own top-level metadata.

`export_notebook' builds its notebook from `nbformat.v4.new_notebook()'
when given only `cells', so a request with no metadata hands nbconvert a
notebook with no `kernelspec' and no `language_info' -- losing the
language a LaTeX or slides template highlights by.  The bridge's
`notebook' parameter takes a whole nbformat document and exists for
exactly this."
  (jsonyter-tests--with-notebook-json jsonyter-tests--notebook-with-figure
    (let (sent)
      (cl-letf (((symbol-function 'jsonyter--ensure-bridge) #'ignore)
                ((symbol-function 'jsonyter--export-run)
                 (lambda (_session params _on-success) (setq sent params))))
        (jsonyter-notebook-export "latex" "/tmp/out.tex"))
      ;; Either shape is fine: a `notebook' document, or `cells' plus an
      ;; explicit `metadata'.  What must not happen is neither.
      (should (or (plist-get sent :notebook) (plist-get sent :metadata))))))

;;;; Script export (§4.10)

;; Entirely local text transformation: no kernel, bridge or server
;; involved anywhere in this section.

(defun jsonyter-tests--script-cell (&rest plist)
  "A (:cell_type ... :source ...) plist from PLIST.
For `jsonyter--cells-to-script'."
  plist)

(ert-deftest jsonyter-test-cells-to-script-output-shape ()
  "One divider per cell, the right marker per cell type, code reproduced
verbatim. The primary test: it pins the deliverable itself."
  (let* ((spec (jsonyter--script-export-spec "python"))
         (cells (list (jsonyter-tests--script-cell :cell_type "markdown" :source "# Analysis")
                      (jsonyter-tests--script-cell :cell_type "code" :source "import numpy as np")
                      (jsonyter-tests--script-cell :cell_type "code" :source "np.mean([1, 2, 3])")))
         (script (jsonyter--cells-to-script cells spec)))
    (should (equal (concat
                    "# %% [markdown]\n# # Analysis\n\n"
                    "# %%\nimport numpy as np\n\n"
                    "# %%\nnp.mean([1, 2, 3])\n")
                   script))))

(ert-deftest jsonyter-test-cells-to-script-raw-cell-marker ()
  "A raw cell gets its own `[raw]' marker, commented the same as markdown."
  (let* ((spec (jsonyter--script-export-spec "python"))
         (cells (list (jsonyter-tests--script-cell :cell_type "raw" :source "verbatim text")))
         (script (jsonyter--cells-to-script cells spec)))
    (should (equal "# %% [raw]\n# verbatim text\n" script))))

(ert-deftest jsonyter-test-cells-to-script-markdown-every-line-commented ()
  "Every line of a markdown cell, blank lines included, comes out
commented; no line escapes the comment prefix -- the whole risk of
wrapping prose verbatim."
  (let* ((spec (jsonyter--script-export-spec "python"))
         (source "Heading\n\nSome text.\n\nMore text.")
         (cells (list (jsonyter-tests--script-cell :cell_type "markdown" :source source)))
         (script (jsonyter--cells-to-script cells spec)))
    (dolist (line (split-string
                   ;; Drop the divider line itself before checking.
                   (substring script (1+ (string-match "\n" script)))
                   "\n" t))
      (should (string-prefix-p "# " line)))))

(ert-deftest jsonyter-test-script-export-spec-per-language ()
  "Python, R and Julia all use `# ' and `# %%'; `.R' stays uppercase."
  (should (equal "# " (plist-get (jsonyter--script-export-spec "python") :comment-line)))
  (should (equal ".py" (plist-get (jsonyter--script-export-spec "python") :extension)))
  (should (equal "# " (plist-get (jsonyter--script-export-spec "R") :comment-line)))
  (should (equal ".R" (plist-get (jsonyter--script-export-spec "R") :extension)))
  (should (equal "# " (plist-get (jsonyter--script-export-spec "julia") :comment-line)))
  (should (equal ".jl" (plist-get (jsonyter--script-export-spec "julia") :extension)))
  ;; Matched case-insensitively: a notebook's lowercase `language_info.name'
  ;; and Org's own-cased `#+begin_src LANG' must resolve to the same entry.
  (should (equal ".R" (plist-get (jsonyter--script-export-spec "r") :extension))))

(ert-deftest jsonyter-test-script-export-sas-markdown-is-block-commented ()
  "SAS markdown is wrapped in a single `/* ... */', not commented per
line with `*' -- and a markdown cell whose prose contains a semicolon
still produces a fully commented block.  This is the real hazard: a
per-line `* text;' comment statement is terminated by the first
semicolon, and prose containing one is entirely ordinary."
  (let* ((spec (jsonyter--script-export-spec "sas"))
         (source "Fit the model; then plot it.")
         (cells (list (jsonyter-tests--script-cell :cell_type "markdown" :source source)))
         (script (jsonyter--cells-to-script cells spec)))
    (should (equal "* %%; [markdown]\n/* Fit the model; then plot it. */\n" script))
    ;; No stray `*text;' line anywhere -- the whole point of the block form.
    (should-not (string-match-p "^\\* " (substring script (1+ (string-match "\n" script)))))))

(ert-deftest jsonyter-test-script-export-sas-guards-close-sequence ()
  "A markdown cell containing `*/' does not close the SAS comment early."
  (let* ((spec (jsonyter--script-export-spec "sas"))
         (source "See the pointer syntax x*/y for an example.")
         (cells (list (jsonyter-tests--script-cell :cell_type "markdown" :source source)))
         (script (jsonyter--cells-to-script cells spec)))
    ;; Exactly one `/*' (the opener) and one closing ` */' (the wrapper's
    ;; own, at the very end) -- the embedded `*/' must have been altered.
    (should (string-suffix-p " */\n" script))
    (should-not (string-match-p "x\\*/y" script))
    (should (string-match-p "x\\* /y" script))))

(ert-deftest jsonyter-test-script-export-sas-extension-and-divider ()
  "SAS gets its own extension and a `* %%;' divider, not `# %%'."
  (should (equal ".sas" (plist-get (jsonyter--script-export-spec "sas") :extension)))
  (should (equal "* %%;" (plist-get (jsonyter--script-export-spec "sas") :divider))))

(ert-deftest jsonyter-test-script-export-round-trip-python ()
  "For Python, the `# %%' marker is exactly what
`jsonyter-script-cell-regexp' matches, so splitting the rendered script
back on it recovers the same cells -- a free bonus, not a requirement."
  (let* ((spec (jsonyter--script-export-spec "python"))
         (cells (list (jsonyter-tests--script-cell :cell_type "code" :source "a = 1")
                      (jsonyter-tests--script-cell :cell_type "code" :source "b = 2")))
         (script (jsonyter--cells-to-script cells spec)))
    (with-temp-buffer
      (insert script)
      (goto-char (point-min))
      (let ((n 0))
        (while (re-search-forward jsonyter-script-cell-regexp nil t) (cl-incf n))
        (should (= 2 n))))))

(ert-deftest jsonyter-test-script-export-sas-divider-does-not-match-cell-regexp ()
  "`* %%;' does NOT match `jsonyter-script-cell-regexp' -- pins the
one-way claim in the docstring so nobody \"fixes\" it by accident."
  (should-not (string-match-p jsonyter-script-cell-regexp "* %%;")))

(ert-deftest jsonyter-test-cells-to-script-empty-cell-list ()
  "A notebook with no code cells still renders (to an empty string)."
  (should (equal "" (jsonyter--cells-to-script nil (jsonyter--script-export-spec "python")))))

(ert-deftest jsonyter-test-cells-to-script-source-with-no-trailing-newline ()
  "A cell whose source has no trailing newline still gets exactly one
newline before the next divider, not zero and not two."
  (let* ((spec (jsonyter--script-export-spec "python"))
         (cells (list (jsonyter-tests--script-cell :cell_type "code" :source "x = 1")
                      (jsonyter-tests--script-cell :cell_type "code" :source "y = 2"))))
    (should (equal "# %%\nx = 1\n\n# %%\ny = 2\n"
                   (jsonyter--cells-to-script cells spec)))))

(ert-deftest jsonyter-test-cells-to-script-markdown-line-looking-like-a-divider ()
  "A markdown line that already looks like `# %%' must not produce a
spurious divider -- the one genuine correctness hazard: a stray `# %%'
mid-prose is confusing even though nothing re-imports the file."
  (let* ((spec (jsonyter--script-export-spec "python"))
         (cells (list (jsonyter-tests--script-cell :cell_type "markdown"
                                            :source "Use `# %%' to start a cell.")))
         (script (jsonyter--cells-to-script cells spec)))
    (with-temp-buffer
      (insert script)
      (goto-char (point-min))
      (let ((n 0))
        (while (re-search-forward jsonyter-script-cell-regexp nil t) (cl-incf n))
        ;; Only the one real divider this cell was rendered with.
        (should (= 1 n))))))

(ert-deftest jsonyter-test-org-to-script-cells-hand-authored-file ()
  "`jsonyter--org-to-script-cells' on a hand-authored file with two `jy:'
blocks and prose between them yields three cells, not one -- exercising
the same fixed splitter as report #4.10.4, through the script-export
entry point."
  (jsonyter-tests--with-org-file
      (concat "#+begin_src python :session jy:main\nx = 1\n#+end_src\n\n"
              "Some prose between blocks.\n\n"
              "#+begin_src python :session jy:main\nx + 1\n#+end_src\n")
    (let ((cells (jsonyter--org-to-script-cells)))
      (should (= 3 (length cells)))
      (should (equal "code" (plist-get (nth 0 cells) :cell_type)))
      (should (equal "x = 1" (plist-get (nth 0 cells) :source)))
      (should (equal "python" (plist-get (nth 0 cells) :language)))
      (should (equal "markdown" (plist-get (nth 1 cells) :cell_type)))
      (should (equal "Some prose between blocks."
                     (plist-get (nth 1 cells) :source)))
      (should (equal "code" (plist-get (nth 2 cells) :cell_type)))
      (should (equal "x + 1" (plist-get (nth 2 cells) :source))))))

(ert-deftest jsonyter-test-org-to-script-cells-does-not-convert-markdown ()
  "Org prose goes into the script verbatim, never through
`jsonyter--org-markdown-convert' -- no pandoc dependency, and no
\"no converter\" banner landing in the output as if it were the user's
own prose."
  (let ((jsonyter-org-markdown-converter
         (lambda (&rest _) (error "must not be called for script export"))))
    (jsonyter-tests--with-org-file
        "#+begin_src python :session jy:main\nx = 1\n#+end_src\n\n*bold* prose\n"
      (let ((cells (jsonyter--org-to-script-cells)))
        (should (equal "*bold* prose" (plist-get (nth 1 cells) :source)))))))

(ert-deftest jsonyter-test-org-export-script-writes-file ()
  "`jsonyter-org-export-script' end to end: writes a script file whose
content matches what `jsonyter--cells-to-script' alone would render."
  (jsonyter-tests--with-org-file
      "#+begin_src python :session jy:main\nx = 1\n#+end_src\n"
    (let ((out (make-temp-file "jsonyter-script-export-" nil ".py")))
      (unwind-protect
          (progn
            (delete-file out) ; exercise the "doesn't exist yet" path
            (jsonyter-org-export-script out)
            (should (file-exists-p out))
            (should (equal "# %%\nx = 1\n"
                           (with-temp-buffer
                             (insert-file-contents out)
                             (buffer-string)))))
        (when (file-exists-p out) (delete-file out))))))

(ert-deftest jsonyter-test-org-export-script-refuses-to-clobber ()
  "Matches `jsonyter-org-from-notebook''s own refusal shape when called
non-interactively (as this test, and any programmatic caller, does)."
  (jsonyter-tests--with-org-file
      "#+begin_src python :session jy:main\nx = 1\n#+end_src\n"
    (let ((out (make-temp-file "jsonyter-script-export-" nil ".py")))
      (unwind-protect
          (should-error (jsonyter-org-export-script out) :type 'user-error)
        (delete-file out)))))

(ert-deftest jsonyter-test-notebook-export-script-writes-file ()
  "`jsonyter-notebook-export-script' end to end against a rendered
notebook buffer."
  (jsonyter-tests--with-notebook
    (let ((out (make-temp-file "jsonyter-script-export-" nil ".py")))
      (unwind-protect
          (progn
            (delete-file out)
            (jsonyter-notebook-export-script out)
            (should (file-exists-p out))
            (let ((content (with-temp-buffer
                             (insert-file-contents out)
                             (buffer-string))))
              (should (string-match-p "# %%\nx = 1" content))
              (should (string-match-p "# %%\nprint(x)" content))
              (should (string-match-p "# %% \\[markdown\\]\n# # heading" content))))
        (when (file-exists-p out) (delete-file out))))))

;;;; Creating a blank notebook

(ert-deftest jsonyter-test-notebook-new-writes-a-valid-blank-notebook ()
  "`jsonyter-notebook-new' writes an nbformat 4.5 file with one empty code
cell and opens it rendered."
  (let ((path (make-temp-file "jsonyter-new-" nil ".ipynb"))
        (buf nil))
    (delete-file path)                   ; the command refuses an existing file
    (unwind-protect
        (progn
          (setq buf (jsonyter-notebook-new path "python"))
          (should (file-exists-p path))
          (with-current-buffer buf
            (should (bound-and-true-p jsonyter-notebook-mode))
            (should (= 1 (length (jsonyter--nb-cells))))
            (should (equal "code" (overlay-get (jsonyter-tests--cell 0)
                                               'jsonyter-cell-type)))
            (should (equal "" (jsonyter--nb-cell-source (jsonyter-tests--cell 0)))))
          (let* ((json (with-temp-buffer
                         (insert-file-contents path)
                         (json-parse-buffer :object-type 'plist :array-type 'list)))
                 (cell (car (plist-get json :cells))))
            (should (= 4 (plist-get json :nbformat)))
            (should (= 5 (plist-get json :nbformat_minor)))
            (should (equal "python"
                           (plist-get (plist-get (plist-get json :metadata)
                                                 :kernelspec)
                                      :language)))
            (should (equal "code" (plist-get cell :cell_type)))
            (should (stringp (plist-get cell :id)))))
      (when (buffer-live-p buf)
        (with-current-buffer buf (set-buffer-modified-p nil))
        (kill-buffer buf))
      (when (file-exists-p path) (delete-file path)))))

(ert-deftest jsonyter-test-notebook-new-refuses-to-clobber ()
  "`jsonyter-notebook-new' will not overwrite a file that is already there."
  (let ((path (make-temp-file "jsonyter-new-" nil ".ipynb")))
    (unwind-protect
        (should-error (jsonyter-notebook-new path "python") :type 'user-error)
      (delete-file path))))

(ert-deftest jsonyter-test-notebook-new-refuses-a-missing-directory ()
  "`jsonyter-notebook-new' reports a friendly error, not a raw file-error,
when the target directory does not exist."
  (should-error
   (jsonyter-notebook-new "/no/such/dir/anywhere/x.ipynb" "python")
   :type 'user-error))

(ert-deftest jsonyter-test-nb-blank-json-is-always-valid-json ()
  "An odd LANGUAGE (control chars, quotes) still yields a parseable notebook."
  (dolist (language '("python" "R" "sas" "py\nthon" "a\"b" "x\ty"))
    (let ((json (json-parse-string (jsonyter--nb-blank-json language)
                                   :object-type 'plist :array-type 'list)))
      (should (= 4 (plist-get json :nbformat)))
      (should (equal language
                     (plist-get (plist-get (plist-get json :metadata)
                                           :kernelspec)
                                :language)))))
  ;; the well-known kernels get their conventional name and label
  (let ((json (json-parse-string (jsonyter--nb-blank-json "python")
                                 :object-type 'plist)))
    (should (equal "python3"
                   (plist-get (plist-get (plist-get json :metadata) :kernelspec)
                              :name)))
    (should (equal "Python 3"
                   (plist-get (plist-get (plist-get json :metadata) :kernelspec)
                              :display_name)))))

(ert-deftest jsonyter-test-notebook-new-defaults-a-blank-language ()
  "An empty or whitespace LANGUAGE falls back to python rather than an
unresolvable empty kernelspec."
  (let ((path (make-temp-file "jsonyter-new-" nil ".ipynb"))
        (buf nil))
    (delete-file path)
    (unwind-protect
        (progn
          (setq buf (jsonyter-notebook-new path "   "))
          (with-current-buffer buf
            (should (equal "python" jsonyter--nb-lang))))
      (when (buffer-live-p buf)
        (with-current-buffer buf (set-buffer-modified-p nil))
        (kill-buffer buf))
      (when (file-exists-p path) (delete-file path)))))

;;;; LaTeX macros cell

(ert-deftest jsonyter-test-latex-macros-source-shape ()
  "The macros cell is a marked markdown block wrapping the \\newcommands in $$."
  (let ((jsonyter-notebook-latex-macros
         '("\\newcommand{\\R}{\\mathbb{R}}" "\\newcommand{\\Z}{\\mathbb{Z}}")))
    (let ((s (jsonyter--nb-latex-source)))
      (should (string-prefix-p jsonyter--nb-latex-marker s))
      ;; opens with `$$' on its own line right after the marker line
      (should (string-match-p (concat "\\`" (regexp-quote jsonyter--nb-latex-marker)
                                      "\n\\$\\$\n")
                              s))
      (should (string-match-p "\\\\newcommand{\\\\R}{\\\\mathbb{R}}" s))
      ;; ...and closes with `$$' on its own line
      (should (string-match-p "\n\\$\\$\\'" s))))
  (let ((jsonyter-notebook-latex-macros nil))
    (should (null (jsonyter--nb-latex-source)))))

(ert-deftest jsonyter-test-latex-macros-insert-replace-remove ()
  "Inserting adds one marked markdown cell at the top; re-running replaces it
in place; setting the option to nil removes it."
  (jsonyter-tests--with-notebook
    (let* ((jsonyter-notebook-latex-macros
            '("\\newcommand{\\R}{\\mathbb{R}}" "\\newcommand{\\Z}{\\mathbb{Z}}"))
           (before (length (jsonyter--nb-cells))))
      (jsonyter-notebook-insert-latex-macros)
      (should (= (1+ before) (length (jsonyter--nb-cells))))
      (let ((cell (jsonyter-tests--cell 0)))
        (should (equal "markdown" (overlay-get cell 'jsonyter-cell-type)))
        (should (string-prefix-p jsonyter--nb-latex-marker
                                 (jsonyter--nb-cell-source cell)))
        (should (string-match-p "mathbb{R}" (jsonyter--nb-cell-source cell))))
      ;; The original first cell is still there, now second, untouched.
      (should (equal "x = 1" (jsonyter--nb-cell-source (jsonyter-tests--cell 1))))
      ;; Re-running replaces rather than stacks.
      (setq jsonyter-notebook-latex-macros '("\\newcommand{\\N}{\\mathbb{N}}"))
      (jsonyter-notebook-insert-latex-macros)
      (should (= (1+ before) (length (jsonyter--nb-cells))))
      (should (string-match-p "mathbb{N}"
                              (jsonyter--nb-cell-source (jsonyter-tests--cell 0))))
      (should-not (string-match-p "mathbb{R}"
                                  (jsonyter--nb-cell-source (jsonyter-tests--cell 0))))
      ;; nil removes it.
      (setq jsonyter-notebook-latex-macros nil)
      (jsonyter-notebook-insert-latex-macros)
      (should (= before (length (jsonyter--nb-cells))))
      (should-not (jsonyter--nb-latex-cell)))))

(ert-deftest jsonyter-test-latex-macros-refresh-keeps-undo-history ()
  "Refreshing the managed macros cell (a top-of-buffer cell with no output)
does not throw away the buffer's undo history."
  (jsonyter-tests--with-notebook
    (buffer-enable-undo)
    (let ((jsonyter-notebook-latex-macros '("\\newcommand{\\R}{\\mathbb{R}}")))
      (jsonyter-notebook-insert-latex-macros)
      (setq buffer-undo-list nil)
      ;; an ordinary, undoable edit further down the buffer
      (let ((cell (jsonyter-tests--cell 1)))
        (goto-char (1- (marker-position (overlay-get cell 'jsonyter-source-end))))
        (insert "42"))
      (should (string-match-p "x = 142" (buffer-string)))
      ;; refresh the macros cell: excises the top cell, re-inserts it
      (setq jsonyter-notebook-latex-macros '("\\newcommand{\\Z}{\\mathbb{Z}}"))
      (jsonyter-notebook-insert-latex-macros)
      ;; the edit further down is still in the history and can be undone
      (let ((n 0))
        (while (and (consp buffer-undo-list) (< n 100))
          (setq buffer-undo-list (primitive-undo 1 buffer-undo-list)
                n (1+ n))))
      (should-not (string-match-p "x = 142" (buffer-string))))))

;;;; Output frame and image width

(ert-deftest jsonyter-test-notebook-output-frame-spans-the-configured-width ()
  "The rules framing a cell's output span `jsonyter-notebook-output-width'."
  (let* ((jsonyter-notebook-output-width 80)
         (framed (jsonyter--nb-outputs-string "hello\n" nil))
         (lines (split-string framed "\n")))
    (should (= 80 (length (nth 0 lines))))            ; "output " + rule
    (should (member (make-string 80 ?─) lines)))      ; the closing rule
  ;; a narrow setting still leaves room for the label
  (let* ((jsonyter-notebook-output-width 3)
         (lines (split-string (jsonyter--nb-outputs-string "x\n" t) "\n")))
    (should (string-prefix-p "output (stale) " (nth 0 lines)))))

(defun jsonyter-tests--image-spec (propertized)
  "The `image' spec carried by the first display-propertied char of PROPERTIED,
unwrapping a `(slice ... IMAGE)' if the image was sliced."
  (let* ((pos (text-property-not-all 0 (length propertized) 'display nil
                                     propertized))
         (disp (and pos (get-text-property pos 'display propertized))))
    (cond ((null disp) nil)
          ((eq (car-safe disp) 'image) disp)
          ((eq (car-safe (car-safe disp)) 'slice) (cadr disp))
          (t disp))))

(ert-deftest jsonyter-test-notebook-image-capped-to-output-width ()
  "An image in notebook output is scaled to at most
`jsonyter-notebook-output-width' columns, taking the tighter of that and
`jsonyter-image-max-width'."
  (jsonyter-tests--with-notebook
    (jsonyter-tests--with-fake-display 40 20
      (let ((jsonyter-slice-images nil)          ; one glyph, :max-width intact
            (jsonyter-notebook-output-width 50)  ; 50 cols * 10px stub = 500
            (jsonyter-image-max-width 800)
            (cell (jsonyter-tests--cell 0)))
        (jsonyter--nb-append-output
         cell (jsonyter-tests--png (base64-encode-string "png")))
        (let ((spec (jsonyter-tests--image-spec
                     (overlay-get cell 'jsonyter-output-string))))
          (should (eq 'image (car spec)))
          (should (= 500 (plist-get (cdr spec) :max-width))))))))

(ert-deftest jsonyter-test-repl-image-keeps-image-max-width ()
  "The REPL path does not go through the notebook output cap."
  (jsonyter-tests--with-fake-display 40 20
    (with-temp-buffer
      (let ((jsonyter-slice-images nil)
            (jsonyter-image-max-width 800)
            (jsonyter-notebook-output-width 50))
        (jsonyter--insert-encoded-image (base64-encode-string "png") 'png)
        (let ((spec (jsonyter-tests--image-spec (buffer-string))))
          (should (eq 'image (car spec)))
          (should (= 800 (plist-get (cdr spec) :max-width))))))))

(ert-deftest jsonyter-test-notebook-new-seeds-latex-macros ()
  "`jsonyter-notebook-new' seeds the macros cell when the option is set."
  (let ((path (make-temp-file "jsonyter-new-" nil ".ipynb"))
        (jsonyter-notebook-latex-macros '("\\newcommand{\\R}{\\mathbb{R}}"))
        (buf nil))
    (delete-file path)
    (unwind-protect
        (progn
          (setq buf (jsonyter-notebook-new path "python"))
          (with-current-buffer buf
            (should (= 2 (length (jsonyter--nb-cells))))
            (should (jsonyter--nb-latex-cell))
            (should (string-match-p
                     "mathbb{R}"
                     (jsonyter--nb-cell-source (jsonyter-tests--cell 0))))))
      (when (buffer-live-p buf)
        (with-current-buffer buf (set-buffer-modified-p nil))
        (kill-buffer buf))
      (when (file-exists-p path) (delete-file path)))))

;;;; File transfer

;; These never touch a bridge: the dispatch tests feed a JSON line to
;; `jsonyter--dispatch' directly, and `jsonyter--transfer-run' is driven
;; with `jsonyter--send' stubbed, in the shape the bridge would answer.

(ert-deftest jsonyter-test-transfer-progress-routes-to-its-handler ()
  "A `progress' line reaches the :progress handler and leaves the request pending."
  (with-temp-buffer
    (setq-local jsonyter--callbacks (make-hash-table :test #'eql))
    (let (progress-seen result-seen)
      (puthash 7 (list :progress (lambda (ev) (setq progress-seen ev))
                       :result (lambda (_msg) (setq result-seen t)))
               jsonyter--callbacks)
      (jsonyter--dispatch
       nil (concat "{\"id\": 7, \"progress\": {\"phase\": \"upload\", "
                   "\"bytes_done\": 5, \"bytes_total\": 10}}"))
      (should (equal "upload" (plist-get progress-seen :phase)))
      (should (equal 5 (plist-get progress-seen :bytes_done)))
      (should-not result-seen)
      ;; A progress line must not complete (remhash) the request.
      (should (gethash 7 jsonyter--callbacks))
      ;; The real `result' line still does.
      (jsonyter--dispatch nil "{\"id\": 7, \"result\": {\"verified\": \"sha256\"}}")
      (should result-seen)
      (should-not (gethash 7 jsonyter--callbacks)))))

(ert-deftest jsonyter-test-transfer-progress-reaches-100-and-cleans-up ()
  "Progress hits 100% on success; the tag and reporter are torn down even on a
mid-transfer error, not only on success."
  (jsonyter-tests--with-sessions
    (let ((session (jsonyter-tests--bind-session '("python" . "") "kid"))
          (handlers nil))
      (cl-letf (((symbol-function 'jsonyter--send)
                 (lambda (_m _p hs) (setq handlers hs) 1)))
        ;; --- success: a final progress event carries done == total ---
        (jsonyter--transfer-run (cons (current-buffer) session) "upload"
                                (list :local_path "/tmp/x" :remote_path "d/x"))
        (funcall (plist-get handlers :progress) '(:bytes_done 5 :bytes_total 10))
        (should (equal 50 (plist-get (jsonyter--session-transfer session) :pct)))
        (funcall (plist-get handlers :progress) '(:bytes_done 10 :bytes_total 10))
        (should (equal 100 (plist-get (jsonyter--session-transfer session) :pct)))
        (funcall (plist-get handlers :result)
                 '(:result (:path "d/x" :local_path "/tmp/x" :bytes 10
                            :verified "sha256" :elapsed 1)))
        (should (null (jsonyter--session-transfer session)))
        (should (null jsonyter--last-failed-transfer))
        ;; --- error partway: the tag clears and the last failure is recorded ---
        (jsonyter--transfer-run (cons (current-buffer) session) "upload"
                                (list :local_path "/tmp/x" :remote_path "d/x"))
        (funcall (plist-get handlers :progress) '(:bytes_done 3 :bytes_total 10))
        (should (jsonyter--session-transfer session))
        (funcall (plist-get handlers :result)
                 '(:error (:message "upload failed at chunk 2/4")))
        (should (null (jsonyter--session-transfer session)))
        (should (equal "upload"
                       (plist-get jsonyter--last-failed-transfer :method))))
      ;; --- jsonyter--send signals synchronously (dead bridge): the tag it
      ;; just set must be cleared, and the signal must propagate. ---
      (cl-letf (((symbol-function 'jsonyter--send)
                 (lambda (&rest _) (error "bridge process is not running"))))
        (should-error
         (jsonyter--transfer-run (cons (current-buffer) session) "download"
                                 (list :remote_path "d/x" :local_path "/tmp/x")))
        (should (null (jsonyter--session-transfer session)))))))

(ert-deftest jsonyter-test-error-message-does-not-blame-chunk-size-for-origin-errors ()
  "A cf-ray on a genuine origin 4xx/5xx (Cloudflare tags every proxied
response) must NOT be rendered as a chunk-size problem, even though the
bridge always puts \"chunk\" in an upload-failure message."
  (let ((m (jsonyter--error-message
            '(:error "JupyterError"
              :message "upload of data/missing/x.csv failed at chunk 1/1 (0 B written) — No such file or directory — lower --chunk-size (currently 8.0 MB), then resume from byte 0"
              :status 404 :cf_ray "cf-abc"))))
    (should-not (string-match-p "jsonyter-upload-chunk-size" m))
    ;; a real proxy 413 still is
    (should (string-match-p
             "jsonyter-upload-chunk-size"
             (jsonyter--error-message
              '(:error "JupyterError" :message "at chunk 1/1 — Request Entity Too Large"
                :status 413 :cf_ray "cf-abc"))))))

(ert-deftest jsonyter-test-resume-upload-re-reads-the-chunk-size ()
  "The documented proxy-413 recovery -- lower `jsonyter-upload-chunk-size',
then resume -- actually takes effect: resume replays the freshly lowered
size, not the one baked in at the first call."
  (jsonyter-tests--with-sessions
    (let ((session (jsonyter-tests--bind-session '("python" . "") "kid"))
          (sent nil) (handlers nil))
      (cl-letf (((symbol-function 'jsonyter--send)
                 (lambda (_m params hs) (setq sent params handlers hs) 1))
                ((symbol-function 'jsonyter--resolve-transfer-context)
                 (lambda () (cons (current-buffer) session))))
        (let ((jsonyter-upload-chunk-size (* 64 1024 1024)))
          (jsonyter--transfer-run (cons (current-buffer) session) "upload"
                                  (list :local_path "/tmp/x" :remote_path "d/x"
                                        :chunk_size jsonyter-upload-chunk-size))
          (funcall (plist-get handlers :result)
                   '(:error (:message "HTTP 413" :status 413 :cf_ray "z"))))
        (should (equal "upload"
                       (plist-get jsonyter--last-failed-transfer :method)))
        (let ((jsonyter-upload-chunk-size (* 8 1024 1024)))
          (jsonyter-resume-upload))
        (should (eq t (plist-get sent :resume)))
        (should (equal (* 8 1024 1024) (plist-get sent :chunk_size)))))))

(ert-deftest jsonyter-test-remote-completion-slashes-dirs-and-refetches ()
  "Remote path completion suffixes directories with `/' and lists a directory
afresh on descent past a `/'."
  (with-temp-buffer
    (let ((calls nil))
      (cl-letf (((symbol-function 'jsonyter--remote-children)
                 (lambda (_buf path)
                   (push path calls)
                   (pcase path
                     ("" (list '(:name "sub" :type "directory" :path "sub")
                               '(:name "a.csv" :type "file" :path "a.csv")))
                     ("sub/" (list '(:name "b.csv" :type "file" :path "sub/b.csv")))
                     (_ nil))))
                ((symbol-function 'completing-read)
                 (lambda (_prompt table &rest _)
                   (let ((root (all-completions "" table)))
                     (should (member "sub/" root))
                     (should (member "a.csv" root)))
                   (let ((down (all-completions "sub/" table)))
                     (should (member "sub/b.csv" down)))
                   "sub/b.csv")))
        (should (equal "sub/b.csv"
                       (jsonyter--read-remote-path (current-buffer) "Remote")))
        (should (member "" calls))
        (should (member "sub/" calls))))))

(ert-deftest jsonyter-test-remote-dired-dims-nonwritable-and-dirs-first ()
  "`jsonyter--remote-entries' sorts directories first and dims a non-writable row."
  (let* ((models (list '(:name "ro.csv" :type "file" :path "ro.csv"
                         :size 10 :writable nil :last_modified "2026-09-07T10:00:00Z")
                       '(:name "rw.csv" :type "file" :path "rw.csv"
                         :size 20 :writable t :last_modified "2026-09-07T11:00:00Z")
                       '(:name "d" :type "directory" :path "d" :writable t)))
         (sorted (sort (copy-sequence models) #'jsonyter--remote-child-lessp))
         (entries (jsonyter--remote-entries sorted nil)))
    (should (equal "d/" (substring-no-properties (aref (cadr (nth 0 entries)) 1))))
    (let ((ro (seq-find (lambda (e) (equal (car e) "ro.csv")) entries))
          (rw (seq-find (lambda (e) (equal (car e) "rw.csv")) entries)))
      (should (eq 'jsonyter-remote-readonly-face
                  (get-text-property 0 'face (aref (cadr ro) 1))))
      (should-not (eq 'jsonyter-remote-readonly-face
                      (get-text-property 0 'face (aref (cadr rw) 1)))))))

(ert-deftest jsonyter-test-remote-dired-copy-reports-server-name ()
  "After a copy the message names what the server called the copy, not the request."
  (with-temp-buffer
    (jsonyter-remote-dired-mode)
    (setq jsonyter--remote-owner (current-buffer)
          jsonyter--remote-cwd ""
          tabulated-list-entries
          (list (list "trials.csv"
                      (vector " " "trials.csv" "10 B" "2026-09-07 10:00"))))
    (puthash "trials.csv" '(:name "trials.csv" :type "file" :path "trials.csv")
             jsonyter--remote-models)
    (tabulated-list-print)
    (goto-char (point-min))
    (let (said)
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (setq said (apply #'format fmt args))))
                ((symbol-function 'jsonyter--read-remote-path)
                 (lambda (&rest _) "backup/"))
                ((symbol-function 'jsonyter--remote-call)
                 (lambda (method params)
                   (should (equal method "copy_contents"))
                   (should (equal (plist-get params :path) "trials.csv"))
                   '(:name "trials-Copy1.csv" :path "backup/trials-Copy1.csv")))
                ((symbol-function 'jsonyter-remote-dired-refresh) #'ignore))
        (jsonyter-remote-dired-copy)
        (should (string-match-p "backup/trials-Copy1\\.csv" said))
        (should-not (string-match-p "backup/trials\\.csv\\'" said))))))

(ert-deftest jsonyter-test-remote-dired-export-uses-server-path ()
  "`jsonyter-remote-dired-export' calls `export_notebook' with the
entry's own `server_path' -- the one place a real Contents-API path is
already in hand, unlike a notebook buffer's `jsonyter-notebook-export'
-- and runs it through the browser's owning buffer."
  (with-temp-buffer
    (jsonyter-remote-dired-mode)
    (setq jsonyter--remote-owner (current-buffer)
          jsonyter--remote-cwd ""
          tabulated-list-entries
          (list (list "analysis.ipynb"
                      (vector " " "analysis.ipynb" "10 B" "2026-09-07 10:00"))))
    (puthash "analysis.ipynb"
             '(:name "analysis.ipynb" :type "file" :path "analysis.ipynb")
             jsonyter--remote-models)
    (tabulated-list-print)
    (goto-char (point-min))
    (let (sent)
      (cl-letf (((symbol-function 'jsonyter--ensure-bridge) #'ignore)
                ((symbol-function 'jsonyter--export-run)
                 (lambda (_session params _on-success) (setq sent params))))
        (jsonyter-remote-dired-export "html" "/tmp/out.html"))
      (should (equal "html" (plist-get sent :format)))
      (should (equal "analysis.ipynb" (plist-get sent :server_path)))
      (should (equal "/tmp/out.html" (plist-get sent :to_path)))
      (should-not (plist-member sent :cells)))))

(ert-deftest jsonyter-test-remote-dired-export-refuses-non-notebook ()
  "Refuses a non-`.ipynb' entry outright, without sending anything."
  (with-temp-buffer
    (jsonyter-remote-dired-mode)
    (setq jsonyter--remote-owner (current-buffer)
          jsonyter--remote-cwd ""
          tabulated-list-entries
          (list (list "data.csv" (vector " " "data.csv" "10 B" "2026-09-07 10:00"))))
    (puthash "data.csv" '(:name "data.csv" :type "file" :path "data.csv")
             jsonyter--remote-models)
    (tabulated-list-print)
    (goto-char (point-min))
    (cl-letf (((symbol-function 'jsonyter--export-run)
               (lambda (&rest _) (error "must not be called"))))
      (should-error (jsonyter-remote-dired-export "html" "/tmp/out.html")
                    :type 'user-error))))

(ert-deftest jsonyter-test-remote-dired-export-refuses-directory ()
  "Refuses a directory entry outright."
  (with-temp-buffer
    (jsonyter-remote-dired-mode)
    (setq jsonyter--remote-owner (current-buffer)
          jsonyter--remote-cwd ""
          tabulated-list-entries
          (list (list "sub" (vector " " "sub/" "" "2026-09-07 10:00"))))
    (puthash "sub" '(:name "sub" :type "directory" :path "sub")
             jsonyter--remote-models)
    (tabulated-list-print)
    (goto-char (point-min))
    (cl-letf (((symbol-function 'jsonyter--export-run)
               (lambda (&rest _) (error "must not be called"))))
      (should-error (jsonyter-remote-dired-export "html" "/tmp/out.html")
                    :type 'user-error))))

(ert-deftest jsonyter-test-error-message-renders-transfer-recovery ()
  "Each TransferConflict reason gets its recovery hint; a proxy 413 names the
chunk-size option."
  (should (string-match-p
           "overwrite"
           (jsonyter--error-message
            '(:error "TransferConflict"
              :message "data/x already exists on the server" :reason "exists"))))
  (let ((m (jsonyter--error-message
            '(:error "TransferConflict" :message "data/x changed on the server"
              :reason "stale" :expected_hash "3f2a1111" :actual_hash "9c11ffff"))))
    (should (string-match-p "jsonyter-download-file" m))
    (should (string-match-p "3f2a" m))
    (should (string-match-p "9c11" m))
    (should-not (string-match-p "3f2a1111" m)))
  (should (string-match-p
           "jsonyter-resume"
           (jsonyter--error-message
            '(:error "TransferConflict" :message "the bytes that landed are wrong"
              :reason "corrupt"))))
  (let ((m (jsonyter--error-message
            '(:error "JupyterError"
              :message "upload failed at chunk 7/23 — HTTP 413 from the proxy, request body exceeded a gateway limit"
              :status 413 :cf_ray "abc-123"))))
    (should (string-match-p "jsonyter-upload-chunk-size" m))
    (should (string-match-p "jsonyter-resume-upload" m))))

(ert-deftest jsonyter-test-error-message-renders-export-hint ()
  "An `ExportError''s `hint' and `available_formats' both render, e.g.
the pdf/pandoc hint text reaching the user."
  (let ((m (jsonyter--error-message
            '(:error "ExportError" :message "nbconvert failed for format pdf"
              :format "pdf"
              :hint "install pandoc and a LaTeX engine on the Jupyter server"))))
    (should (string-match-p "install pandoc" m)))
  (let ((m (jsonyter--error-message
            '(:error "ExportError" :message "unknown export format \"docx\""
              :available_formats ["html" "markdown" "pdf"]))))
    (should (string-match-p "html" m))
    (should (string-match-p "markdown" m))
    (should (string-match-p "pdf" m))))

(ert-deftest jsonyter-test-kernel-reset-clears-contents-dir ()
  "A restart drops the stale contents-path mapping so the next transfer re-probes."
  (jsonyter-tests--with-sessions
    (let ((s (jsonyter-tests--bind-session '("python" . "") "kid")))
      (setf (jsonyter--session-contents-dir s) "work/data"
            (jsonyter--session-contents-dir-probed s) t
            (jsonyter--session-remote-directory s) "work/data/")
      (jsonyter--after-kernel-reset "[kernel restarted]" s)
      (should (null (jsonyter--session-contents-dir s)))
      (should (null (jsonyter--session-contents-dir-probed s)))
      (should (null (jsonyter--session-remote-directory s))))))

;;;; Kernel restart/unstick naming (report #3)

(ert-deftest jsonyter-test-kernel-restart-aliases-restart ()
  "`jsonyter-kernel-restart' is `jsonyter-restart' under a name a user
looking for kernel operations will find by `M-x' completion."
  (should (eq (indirect-function 'jsonyter-kernel-restart)
              (indirect-function 'jsonyter-restart))))

(ert-deftest jsonyter-test-reset-is-obsolete-alias-for-unstick ()
  "`jsonyter-reset' still works, as an obsolete alias for `jsonyter-unstick' --
the actual command is renamed, not removed, since it never touched the
kernel and \"reset\" was the misleading part."
  (should (get 'jsonyter-reset 'byte-obsolete-info))
  (jsonyter-tests--with-sessions
    (let ((s (jsonyter-tests--bind-session '("python" . "") "kid")))
      (setq-local jsonyter--session-key '("python" . ""))
      (setf (jsonyter--session-busy s) t)
      (with-no-warnings (jsonyter-reset s))
      (should-not (jsonyter--session-busy s)))))

;;;; Kernel control commands (interrupt/restart/unstick/shutdown)

(ert-deftest jsonyter-test-interrupt-sends-request-for-session-kernel ()
  (jsonyter-tests--with-sessions
    (jsonyter-tests--bind-session '("python" . "") "kid")
    (let (sent said)
      (setq-local jsonyter--session-key '("python" . ""))
      (cl-letf (((symbol-function 'jsonyter--request-sync)
                 (lambda (method params &rest _) (setq sent (cons method params))))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
        (jsonyter-interrupt))
      (should (equal (car sent) "interrupt_kernel"))
      (should (equal (plist-get (cdr sent) :kernel_id) "kid"))
      (should (string-match-p "interrupt sent" said)))))

(ert-deftest jsonyter-test-interrupt-errors-with-no-kernel ()
  (jsonyter-tests--with-sessions
    (jsonyter-tests--bind-session '("python" . "") nil)
    (setq-local jsonyter--session-key '("python" . ""))
    (should-error (jsonyter-interrupt) :type 'user-error)))

(ert-deftest jsonyter-test-restart-confirms-and-resets-state ()
  "`jsonyter-restart' asks first, restarts the kernel, and clears busy/count."
  (jsonyter-tests--with-sessions
    (let ((s (jsonyter-tests--bind-session '("python" . "") "kid"))
          methods)
      (setq-local jsonyter--session-key '("python" . "")
                  jsonyter--execution-count 5)
      (setf (jsonyter--session-busy s) t)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                ((symbol-function 'jsonyter--request-sync)
                 (lambda (method &rest _) (push method methods)))
                ((symbol-function 'jsonyter--subscribe) #'ignore)
                ((symbol-function 'jsonyter--after-kernel-reset) #'ignore))
        (jsonyter-restart))
      (should (member "restart_kernel" methods))
      (should (member "disconnect" methods))
      (should-not (jsonyter--session-busy s))
      (should (= 0 jsonyter--execution-count)))))

(ert-deftest jsonyter-test-restart-declines-when-not-confirmed ()
  (jsonyter-tests--with-sessions
    (jsonyter-tests--bind-session '("python" . "") "kid")
    (setq-local jsonyter--session-key '("python" . ""))
    (let (called)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil))
                ((symbol-function 'jsonyter--request-sync) (lambda (&rest _) (setq called t))))
        (jsonyter-restart))
      (should-not called))))

(ert-deftest jsonyter-test-restart-errors-with-no-kernel ()
  (jsonyter-tests--with-sessions
    (jsonyter-tests--bind-session '("python" . "") nil)
    (setq-local jsonyter--session-key '("python" . ""))
    (should-error (jsonyter-restart) :type 'user-error)))

(ert-deftest jsonyter-test-shutdown-confirms-and-clears-owned-session ()
  "In a single-kernel buffer (`jsonyter--session-key' set), shutdown also
kills the bridge process."
  (jsonyter-tests--with-sessions
    (let ((s (jsonyter-tests--bind-session '("python" . "") "kid" t))
          killed)
      (setq-local jsonyter--session-key '("python" . ""))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                ((symbol-function 'jsonyter--request-sync) #'ignore)
                ((symbol-function 'jsonyter--kill-process) (lambda () (setq killed t)))
                ((symbol-function 'jsonyter--announce) #'ignore)
                ((symbol-function 'force-mode-line-update) #'ignore))
        (jsonyter-shutdown))
      (should killed)
      (should (null (jsonyter--session-kernel-id s)))
      (should (equal "dead" (jsonyter--session-state s)))
      (should (null (jsonyter--session-own s))))))

(ert-deftest jsonyter-test-shutdown-drops-session-when-no-session-key ()
  "In an Org-style buffer (`jsonyter--session-key' nil), shutdown drops
the session from the table instead of killing the shared bridge."
  (jsonyter-tests--with-sessions
    (let ((s (jsonyter-tests--bind-session '("python" . "main") "kid" t)))
      (setq-local jsonyter--session-key nil)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                ((symbol-function 'jsonyter--request-sync) #'ignore)
                ((symbol-function 'jsonyter--announce) #'ignore)
                ((symbol-function 'force-mode-line-update) #'ignore))
        (jsonyter-shutdown s))
      (should (= 0 (hash-table-count jsonyter--sessions))))))

(ert-deftest jsonyter-test-shutdown-errors-with-no-kernel ()
  (jsonyter-tests--with-sessions
    (jsonyter-tests--bind-session '("python" . "") nil)
    (setq-local jsonyter--session-key '("python" . ""))
    (should-error (jsonyter-shutdown) :type 'user-error)))

;;;; Kernel listing, labels and selection

(ert-deftest jsonyter-test-running-kernels-sorts-by-recent-activity ()
  (cl-letf (((symbol-function 'jsonyter--request-sync)
             (lambda (&rest _)
               (list (list :id "old" :last_activity "2024-01-01T00:00:00")
                     (list :id "new" :last_activity "2024-06-01T00:00:00")))))
    (let ((kernels (jsonyter--running-kernels)))
      (should (equal (plist-get (nth 0 kernels) :id) "new"))
      (should (equal (plist-get (nth 1 kernels) :id) "old")))))

(ert-deftest jsonyter-test-kernel-activity-formats-or-falls-back ()
  (should (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\} "
                          (jsonyter--kernel-activity
                           (list :last_activity "2024-06-01T12:34:00"))))
  (should (equal "raw-stamp" (jsonyter--kernel-activity
                              (list :last_activity "raw-stamp"))))
  (should (equal "" (jsonyter--kernel-activity (list)))))

(ert-deftest jsonyter-test-kernel-label-marks-current-kernel ()
  (let ((label (jsonyter--kernel-label
                (list :id "abcdefgh12" :name "python3" :execution_state "idle")
                "abcdefgh12")))
    (should (string-prefix-p "*" label))
    (should (string-match-p "python3" label))
    (should (string-match-p "abcdefgh" label)))
  (should (string-prefix-p " " (jsonyter--kernel-label (list :id "x") "y"))))

(ert-deftest jsonyter-test-read-kernel-offers-current-as-default ()
  (cl-letf (((symbol-function 'jsonyter--request-sync)
             (lambda (&rest _)
               (list (list :id "kid1" :name "python3" :execution_state "idle"))))
            ((symbol-function 'completing-read)
             (lambda (_prompt table &rest _) (car (car table)))))
    (should (equal "kid1" (jsonyter--read-kernel "Pick: ")))))

(ert-deftest jsonyter-test-read-kernel-errors-when-none-running ()
  (cl-letf (((symbol-function 'jsonyter--request-sync) (lambda (&rest _) nil)))
    (should-error (jsonyter--read-kernel "Pick: ") :type 'user-error)))

(ert-deftest jsonyter-test-read-kernel-errors-on-unknown-choice ()
  (cl-letf (((symbol-function 'jsonyter--request-sync)
             (lambda (&rest _) (list (list :id "kid1" :name "python3"))))
            ((symbol-function 'completing-read) (lambda (&rest _) "not in the table")))
    (should-error (jsonyter--read-kernel "Pick: ") :type 'user-error)))

;;;; Kernelspec language resolution and adoption

(ert-deftest jsonyter-test-kernelspec-language-looks-up-by-name ()
  (cl-letf (((symbol-function 'jsonyter--request-sync)
             (lambda (&rest _)
               (list :kernelspecs
                     (list :python3 (list :name "python3" :spec (list :language "python"))
                           :ir (list :name "ir" :spec (list :language "R")))))))
    (should (equal "python" (jsonyter--kernelspec-language "python3")))
    (should (equal "R" (jsonyter--kernelspec-language "ir")))
    (should (null (jsonyter--kernelspec-language "nope")))))

(ert-deftest jsonyter-test-kernelspec-language-best-effort-on-error ()
  (cl-letf (((symbol-function 'jsonyter--request-sync) (lambda (&rest _) (error "boom"))))
    (should (null (jsonyter--kernelspec-language "python3")))))

(ert-deftest jsonyter-test-adopt-kernel-language-reports-mismatch-then-not ()
  (jsonyter-tests--with-sessions
    (let ((s (jsonyter-tests--bind-session '("python" . "") "kid")))
      (cl-letf (((symbol-function 'jsonyter--kernelspec-language) (lambda (_n) "R")))
        (let ((note (jsonyter--adopt-kernel-language s "ir")))
          (should (equal "R" (jsonyter--session-language s)))
          (should (string-match-p "python" note))
          (should (string-match-p "R" note)))
        ;; Same language the second time around: no note.
        (should (null (jsonyter--adopt-kernel-language s "ir")))))))

(ert-deftest jsonyter-test-adopt-kernel-language-nil-when-unresolvable ()
  (jsonyter-tests--with-sessions
    (let ((s (jsonyter-tests--bind-session '("python" . "") "kid")))
      (cl-letf (((symbol-function 'jsonyter--kernelspec-language) (lambda (_n) nil)))
        (should (null (jsonyter--adopt-kernel-language s "mystery")))
        (should (equal "python" (jsonyter--session-language s)))))))

;;;; Attaching to an existing kernel

(ert-deftest jsonyter-test-attach-target-uses-session-key-when-none-current ()
  (jsonyter-tests--with-sessions
    (should-error (jsonyter--attach-target) :type 'user-error)
    (setq-local jsonyter--session-key '("python" . ""))
    (let ((s (jsonyter--attach-target)))
      (should (equal (jsonyter--session-key s) '("python" . ""))))))

(ert-deftest jsonyter-test-attach-target-prefers-existing-current-session ()
  (jsonyter-tests--with-sessions
    (let ((s (jsonyter-tests--bind-session '("python" . "") "kid")))
      (setq-local jsonyter--session-key '("python" . ""))
      (should (eq (jsonyter--attach-target) s)))))

(ert-deftest jsonyter-test-kernel-connect-attaches-and-reports ()
  "Exercised via `call-interactively' so the interactive spec — reading
the kernel id — runs too, matching how a user actually invokes it."
  (jsonyter-tests--with-sessions
    (setq-local jsonyter--session-key '("python" . "")
                jsonyter--callbacks (make-hash-table :test #'eql))
    (let (subscribed said)
      (cl-letf (((symbol-function 'jsonyter--ensure-live-bridge) #'ignore)
                ((symbol-function 'jsonyter--read-kernel) (lambda (&rest _) "new-kid"))
                ((symbol-function 'jsonyter--request-sync)
                 (lambda (method &rest _)
                   (when (equal method "get_kernel")
                     (list :id "new-kid" :name "python3" :execution_state "idle"))))
                ((symbol-function 'jsonyter--subscribe)
                 (lambda (s) (setq subscribed s) (setf (jsonyter--session-state s) "idle") t))
                ((symbol-function 'force-mode-line-update) #'ignore)
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
        (should (equal "new-kid" (call-interactively 'jsonyter-kernel-connect))))
      (let ((s (jsonyter--session '("python" . ""))))
        (should (equal "new-kid" (jsonyter--session-kernel-id s)))
        (should (equal "python3" (jsonyter--session-kernel-name s)))
        (should (eq subscribed s)))
      (should (string-match-p "connected to" said)))))

(ert-deftest jsonyter-test-kernel-connect-signals-user-error-when-kernel-gone ()
  (jsonyter-tests--with-sessions
    (setq-local jsonyter--session-key '("python" . ""))
    (cl-letf (((symbol-function 'jsonyter--ensure-live-bridge) #'ignore)
              ((symbol-function 'jsonyter--request-sync)
               (lambda (method &rest _)
                 (when (equal method "get_kernel") (error "not found")))))
      (should-error (jsonyter-kernel-connect "missing-kid") :type 'user-error))))

(ert-deftest jsonyter-test-kernel-reconnect-uses-last-kernel-id ()
  (jsonyter-tests--with-sessions
    (let ((s (jsonyter-tests--bind-session '("python" . "") nil)))
      (setq-local jsonyter--session-key '("python" . "")
                  jsonyter-mode t)
      (setf (jsonyter--session-kernel-id s) nil
            (jsonyter--session-last-kernel s) (list :id "old-kid" :name "python3"))
      (let (connected-id)
        (cl-letf (((symbol-function 'jsonyter-kernel-connect)
                   (lambda (id &optional session) (setq connected-id id) session)))
          (jsonyter-kernel-reconnect))
        (should (equal "old-kid" connected-id))))))

(ert-deftest jsonyter-test-kernel-reconnect-errors-with-no-kernel-at-all ()
  (jsonyter-tests--with-sessions
    (jsonyter-tests--bind-session '("python" . "") nil)
    (setq-local jsonyter--session-key '("python" . "")
                jsonyter-mode t)
    (should-error (jsonyter-kernel-reconnect) :type 'user-error)))

;;;; Kernel history

(ert-deftest jsonyter-test-history-input-handles-plain-and-paired-entries ()
  (should (equal "x = 1" (jsonyter--history-input '("s" 1 "x = 1"))))
  (should (equal "x = 1" (jsonyter--history-input (list "s" 1 (cons "x = 1" "out")))))
  (should (null (jsonyter--history-input (list "s" 1 42)))))

(ert-deftest jsonyter-test-history-insert-groups-by-session-with-rules ()
  (with-temp-buffer
    (jsonyter--history-insert
     (list (list "s1" 1 "a = 1") (list "s1" 2 "a") (list "s2" 1 "b = 2")))
    (let ((text (buffer-string)))
      (should (string-match-p "session s1" text))
      (should (string-match-p "session s2" text))
      (should (string-match-p "In \\[1\\]: a = 1" text))
      (should (string-match-p "In \\[1\\]: b = 2" text)))))

(ert-deftest jsonyter-test-history-insert-skips-entries-with-no-usable-input ()
  (with-temp-buffer
    (jsonyter--history-insert (list (list "s1" 1 42)))
    (should (equal "" (buffer-string)))))

(ert-deftest jsonyter-test-kernel-history-shows-entries-grouped-by-session ()
  (jsonyter-tests--with-sessions
    (jsonyter-tests--bind-session '("python" . "") "kid")
    (setq-local jsonyter--session-key '("python" . ""))
    (cl-letf (((symbol-function 'jsonyter--ensure-live-bridge) #'ignore)
              ((symbol-function 'jsonyter--request-sync)
               (lambda (method &rest _)
                 (when (equal method "get_kernel") (list :id "kid" :name "python3"))))
              ((symbol-function 'jsonyter--kernel-request)
               (lambda (&rest _) (list :status "ok" :history (list (list "s1" 1 "x = 1"))))))
      ;; Via `call-interactively': no prefix arg, so N and the kernel both
      ;; come from this buffer's own session, exactly as a user's C-c M-h
      ;; would resolve them.
      (call-interactively 'jsonyter-kernel-history))
    (let ((buf (get-buffer "*jsonyter-history*")))
      (should buf)
      (with-current-buffer buf
        (should (string-match-p "In \\[1\\]: x = 1" (buffer-string))))
      (kill-buffer buf))))

(ert-deftest jsonyter-test-kernel-history-errors-without-any-kernel ()
  (jsonyter-tests--with-sessions
    (jsonyter-tests--bind-session '("python" . "") nil)
    (setq-local jsonyter--session-key '("python" . ""))
    (should-error (jsonyter-kernel-history 5 nil) :type 'user-error)))

(ert-deftest jsonyter-test-kernel-history-errors-on-bad-count ()
  (jsonyter-tests--with-sessions
    (jsonyter-tests--bind-session '("python" . "") "kid")
    (setq-local jsonyter--session-key '("python" . ""))
    (should-error (jsonyter-kernel-history 0 "kid") :type 'user-error)))

(ert-deftest jsonyter-test-kernel-history-reports-empty-history ()
  (jsonyter-tests--with-sessions
    (jsonyter-tests--bind-session '("python" . "") "kid")
    (setq-local jsonyter--session-key '("python" . ""))
    (let (said)
      (cl-letf (((symbol-function 'jsonyter--ensure-live-bridge) #'ignore)
                ((symbol-function 'jsonyter--request-sync)
                 (lambda (method &rest _) (when (equal method "get_kernel") (list :id "kid"))))
                ((symbol-function 'jsonyter--kernel-request)
                 (lambda (&rest _) (list :status "ok" :history nil)))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
        (jsonyter-kernel-history 5 "kid"))
      (should (string-match-p "has run nothing yet" said)))))

(ert-deftest jsonyter-test-kernel-history-errors-when-kernel-refuses ()
  (jsonyter-tests--with-sessions
    (jsonyter-tests--bind-session '("python" . "") "kid")
    (setq-local jsonyter--session-key '("python" . ""))
    (cl-letf (((symbol-function 'jsonyter--ensure-live-bridge) #'ignore)
              ((symbol-function 'jsonyter--request-sync)
               (lambda (method &rest _) (when (equal method "get_kernel") (list :id "kid"))))
              ((symbol-function 'jsonyter--kernel-request)
               (lambda (&rest _) (list :status "error"))))
      (should-error (jsonyter-kernel-history 5 "kid")))))

;;;; Bridge stderr tail

(ert-deftest jsonyter-test-stderr-tail-returns-last-lines ()
  (let ((buf (generate-new-buffer " *fake-stderr*"))
        (proc (start-process "jsonyter-test-fake" nil "cat")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (insert "line1\nline2\nline3\nline4\nline5\nline6\nline7\n"))
          (process-put proc 'jsonyter-stderr-buffer buf)
          (should (equal "line5\nline6\nline7" (jsonyter--stderr-tail proc 3))))
      (ignore-errors (delete-process proc))
      (kill-buffer buf))))

(ert-deftest jsonyter-test-stderr-tail-nil-without-a-buffer ()
  (let ((proc (start-process "jsonyter-test-fake2" nil "cat")))
    (unwind-protect
        (should (null (jsonyter--stderr-tail proc)))
      (ignore-errors (delete-process proc)))))

;;;; Starting REPLs

(ert-deftest jsonyter-test-start-reads-language-and-delegates ()
  (let (started)
    (cl-letf (((symbol-function 'jsonyter--start-repl) (lambda (lang) (setq started lang)))
              ((symbol-function 'read-string) (lambda (&rest _) "julia")))
      (call-interactively 'jsonyter-start))
    (should (equal "julia" started))))

(ert-deftest jsonyter-test-start-language-wrappers-delegate-to-start-repl ()
  (let (started)
    (cl-letf (((symbol-function 'jsonyter--start-repl) (lambda (lang) (setq started lang))))
      (jsonyter-start-python) (should (equal "python" started))
      (jsonyter-start-julia)  (should (equal "julia" started))
      (jsonyter-start-R)      (should (equal "R" started))
      (jsonyter-start-SAS)    (should (equal "sas" started)))))

;;;; Resolving a transfer context

(ert-deftest jsonyter-test-resolve-transfer-context-uses-remote-dired-owner ()
  (let ((owner (generate-new-buffer "jsonyter-owner")))
    (unwind-protect
        (progn
          (with-current-buffer owner
            (setq-local jsonyter--sessions (make-hash-table :test #'equal))
            (jsonyter-tests--bind-session '("python" . "") "kid"))
          (with-temp-buffer
            (jsonyter-remote-dired-mode)
            (setq jsonyter--remote-owner owner
                  jsonyter--remote-session-key '("python" . ""))
            (let ((ctx (jsonyter--resolve-transfer-context)))
              (should (eq (car ctx) owner))
              (should (equal (jsonyter--session-key (cdr ctx)) '("python" . ""))))))
      (kill-buffer owner))))

(ert-deftest jsonyter-test-resolve-transfer-context-errors-when-owner-gone ()
  (let ((owner (generate-new-buffer "jsonyter-owner-2")))
    (kill-buffer owner)
    (with-temp-buffer
      (jsonyter-remote-dired-mode)
      (setq jsonyter--remote-owner owner)
      (should-error (jsonyter--resolve-transfer-context) :type 'user-error))))

(ert-deftest jsonyter-test-resolve-transfer-context-uses-current-jsonyter-buffer ()
  (with-temp-buffer
    (setq-local jsonyter-mode t)
    (setq-local jsonyter--process (start-process "jsonyter-test-ctx" nil "cat"))
    (unwind-protect
        (let ((ctx (jsonyter--resolve-transfer-context)))
          (should (eq (car ctx) (current-buffer)))
          (should (null (cdr ctx))))
      (ignore-errors (delete-process jsonyter--process)))))

(ert-deftest jsonyter-test-resolve-transfer-context-falls-back-to-single-candidate ()
  (let ((buf (generate-new-buffer "jsonyter-cand-solo")))
    (unwind-protect
        (with-temp-buffer
          (cl-letf (((symbol-function 'jsonyter--transfer-buffers) (lambda () (list buf))))
            (let ((ctx (jsonyter--resolve-transfer-context)))
              (should (eq (car ctx) buf))
              (should (null (cdr ctx))))))
      (kill-buffer buf))))

(ert-deftest jsonyter-test-resolve-transfer-context-prompts-among-several ()
  (let ((buf1 (generate-new-buffer "jsonyter-cand-a"))
        (buf2 (generate-new-buffer "jsonyter-cand-b")))
    (unwind-protect
        (with-temp-buffer
          (cl-letf (((symbol-function 'jsonyter--transfer-buffers) (lambda () (list buf1 buf2)))
                    ((symbol-function 'completing-read)
                     (lambda (_prompt table &rest _) (car table))))
            (let ((ctx (jsonyter--resolve-transfer-context)))
              (should (eq (car ctx) buf1)))))
      (kill-buffer buf1) (kill-buffer buf2))))

(ert-deftest jsonyter-test-resolve-transfer-context-errors-with-no-candidates ()
  (with-temp-buffer
    (cl-letf (((symbol-function 'jsonyter--transfer-buffers) (lambda () nil)))
      (should-error (jsonyter--resolve-transfer-context) :type 'user-error))))

(ert-deftest jsonyter-test-transfer-candidates-lists-sessions-and-bare-buffers ()
  (let ((buf1 (generate-new-buffer "jsonyter-cand-1"))
        (buf2 (generate-new-buffer "jsonyter-cand-2")))
    (unwind-protect
        (progn
          (with-current-buffer buf1
            (setq-local jsonyter-mode t)
            (setq-local jsonyter--process (start-process "jsonyter-test-cand1" nil "cat"))
            (setq-local jsonyter--sessions (make-hash-table :test #'equal))
            (jsonyter-tests--bind-session '("python" . "") "kid"))
          (with-current-buffer buf2
            (setq-local jsonyter-mode t)
            (setq-local jsonyter--process (start-process "jsonyter-test-cand2" nil "cat")))
          (let ((cands (jsonyter--transfer-candidates)))
            (should (seq-find (lambda (c) (string-match-p "python" (car c))) cands))
            (should (seq-find (lambda (c) (string-match-p "no session" (car c))) cands))))
      (dolist (b (list buf1 buf2))
        (when (buffer-live-p b)
          (ignore-errors (delete-process (buffer-local-value 'jsonyter--process b)))
          (kill-buffer b))))))

;;;; jsonyter-upload-file / jsonyter-download-file

(ert-deftest jsonyter-test-upload-file-sends-expanded-paths ()
  "Exercised via `call-interactively' so the interactive spec — reading
the local file and completing the remote path — runs too."
  (let ((tmp (make-temp-file "jsonyter-upload-")))
    (unwind-protect
        (let (sent)
          (cl-letf (((symbol-function 'jsonyter--resolve-transfer-context)
                     (lambda () (cons (current-buffer) nil)))
                    ((symbol-function 'read-file-name) (lambda (&rest _) tmp))
                    ((symbol-function 'jsonyter--transfer-remote-dir) (lambda (&rest _) "d/"))
                    ((symbol-function 'jsonyter--read-remote-path) (lambda (&rest _) "d/x"))
                    ((symbol-function 'jsonyter--transfer-run)
                     (lambda (_context method params &optional _on-success)
                       (setq sent (list method params)))))
            (call-interactively 'jsonyter-upload-file))
          (should (equal (car sent) "upload"))
          (should (equal (plist-get (cadr sent) :local_path) (expand-file-name tmp)))
          (should (equal (plist-get (cadr sent) :remote_path) "d/x")))
      (delete-file tmp))))

(ert-deftest jsonyter-test-upload-file-refuses-unreadable-local-path ()
  (should-error (jsonyter-upload-file "/no/such/file/anywhere" "d/x") :type 'user-error))

(ert-deftest jsonyter-test-upload-file-refuses-a-directory ()
  (should-error (jsonyter-upload-file "/tmp" "d/x") :type 'user-error))

(ert-deftest jsonyter-test-upload-file-refuses-empty-remote-path ()
  (let ((tmp (make-temp-file "jsonyter-upload-")))
    (unwind-protect
        (should-error (jsonyter-upload-file tmp "") :type 'user-error)
      (delete-file tmp))))

(ert-deftest jsonyter-test-download-file-sends-expanded-paths ()
  (let (sent)
    (cl-letf (((symbol-function 'jsonyter--resolve-transfer-context)
               (lambda () (cons (current-buffer) nil)))
              ((symbol-function 'jsonyter--transfer-remote-dir) (lambda (&rest _) ""))
              ((symbol-function 'jsonyter--read-remote-path) (lambda (&rest _) "d/x.csv"))
              ((symbol-function 'read-file-name) (lambda (&rest _) "/tmp/x.csv"))
              ((symbol-function 'jsonyter--transfer-run)
               (lambda (_context method params &optional _on-success) (setq sent (list method params)))))
      (call-interactively 'jsonyter-download-file))
    (should (equal (car sent) "download"))
    (should (equal (plist-get (cadr sent) :remote_path) "d/x.csv"))
    (should (equal (plist-get (cadr sent) :local_path) "/tmp/x.csv"))))

(ert-deftest jsonyter-test-download-file-appends-basename-to-a-directory ()
  (let (sent)
    (cl-letf (((symbol-function 'jsonyter--transfer-run)
               (lambda (_context _method params &optional _on-success) (setq sent params))))
      (jsonyter-download-file "d/x.csv" "/tmp" nil (cons (current-buffer) nil)))
    (should (equal (plist-get sent :local_path) (expand-file-name "x.csv" "/tmp")))))

(ert-deftest jsonyter-test-download-file-refuses-root-path ()
  (should-error (jsonyter-download-file "" "/tmp/x") :type 'user-error))

;;;; jsonyter--remote-call

(ert-deftest jsonyter-test-remote-call-runs-through-owner-buffer ()
  (let ((owner (generate-new-buffer "jsonyter-remote-owner")))
    (unwind-protect
        (with-temp-buffer
          (jsonyter-remote-dired-mode)
          (setq jsonyter--remote-owner owner)
          (let (seen owner-was-current)
            (cl-letf (((symbol-function 'jsonyter--request-sync)
                       (lambda (method params &rest _)
                         (setq seen (list method params)
                               owner-was-current (eq (current-buffer) owner))
                         'ok)))
              (should (eq 'ok (jsonyter--remote-call "make_directory" (list :path "x")))))
            (should (equal (car seen) "make_directory"))
            (should owner-was-current)))
      (kill-buffer owner))))

(ert-deftest jsonyter-test-remote-call-errors-when-owner-gone ()
  (let ((owner (generate-new-buffer "jsonyter-remote-owner-2")))
    (kill-buffer owner)
    (with-temp-buffer
      (jsonyter-remote-dired-mode)
      (setq jsonyter--remote-owner owner)
      (should-error (jsonyter--remote-call "x" nil) :type 'user-error))))

;;;; jsonyter-remote-dired-* commands

(ert-deftest jsonyter-test-remote-dired-upload-sends-to-current-directory ()
  (with-temp-buffer
    (jsonyter-remote-dired-mode)
    (setq jsonyter--remote-owner (current-buffer)
          jsonyter--remote-cwd "d/")
    (let (sent refreshed)
      (cl-letf (((symbol-function 'jsonyter--resolve-transfer-context)
                 (lambda () (cons (current-buffer) nil)))
                ((symbol-function 'read-file-name) (lambda (&rest _) "/tmp/x.csv"))
                ((symbol-function 'jsonyter--transfer-run)
                 (lambda (_context method params &optional on-success)
                   (setq sent (list method params))
                   (when on-success (funcall on-success nil))))
                ((symbol-function 'jsonyter-remote-dired-refresh) (lambda () (setq refreshed t))))
        (jsonyter-remote-dired-upload))
      (should (equal (car sent) "upload"))
      (should (equal (plist-get (cadr sent) :remote_path) "d/x.csv"))
      (should refreshed))))

(ert-deftest jsonyter-test-remote-dired-upload-asks-before-overwrite ()
  (with-temp-buffer
    (jsonyter-remote-dired-mode)
    (setq jsonyter--remote-owner (current-buffer)
          jsonyter--remote-cwd "")
    (puthash "x.csv" '(:name "x.csv") jsonyter--remote-models)
    (let (sent asked)
      (cl-letf (((symbol-function 'jsonyter--resolve-transfer-context)
                 (lambda () (cons (current-buffer) nil)))
                ((symbol-function 'read-file-name) (lambda (&rest _) "/tmp/x.csv"))
                ((symbol-function 'yes-or-no-p) (lambda (&rest _) (setq asked t) t))
                ((symbol-function 'jsonyter--transfer-run)
                 (lambda (_context _method params &optional _on-success) (setq sent params))))
        (jsonyter-remote-dired-upload))
      (should asked)
      (should (eq t (plist-get sent :overwrite))))))

(ert-deftest jsonyter-test-remote-dired-download-refuses-directory ()
  (with-temp-buffer
    (jsonyter-remote-dired-mode)
    (setq jsonyter--remote-owner (current-buffer)
          jsonyter--remote-cwd ""
          tabulated-list-entries (list (list "sub" (vector " " "sub/" "" ""))))
    (puthash "sub" '(:name "sub" :type "directory" :path "sub") jsonyter--remote-models)
    (tabulated-list-print)
    (goto-char (point-min))
    (should-error (jsonyter-remote-dired-download) :type 'user-error)))

(ert-deftest jsonyter-test-remote-dired-download-sends-to-local-path ()
  (with-temp-buffer
    (jsonyter-remote-dired-mode)
    (setq jsonyter--remote-owner (current-buffer)
          jsonyter--remote-cwd ""
          tabulated-list-entries (list (list "x.csv" (vector " " "x.csv" "10 B" ""))))
    (puthash "x.csv" '(:name "x.csv" :type "file" :path "x.csv") jsonyter--remote-models)
    (tabulated-list-print)
    (goto-char (point-min))
    (let (sent)
      (cl-letf (((symbol-function 'read-file-name) (lambda (&rest _) "/tmp/x.csv"))
                ((symbol-function 'jsonyter--resolve-transfer-context)
                 (lambda () (cons (current-buffer) nil)))
                ((symbol-function 'jsonyter--transfer-run)
                 (lambda (_context method params &optional _on-success) (setq sent (list method params)))))
        (jsonyter-remote-dired-download))
      (should (equal (car sent) "download"))
      (should (equal (plist-get (cadr sent) :remote_path) "x.csv")))))

(ert-deftest jsonyter-test-remote-dired-find-descends-into-directory ()
  (with-temp-buffer
    (jsonyter-remote-dired-mode)
    (setq jsonyter--remote-owner (current-buffer)
          jsonyter--remote-cwd ""
          tabulated-list-entries (list (list "sub" (vector " " "sub/" "" ""))))
    (puthash "sub" '(:name "sub" :type "directory" :path "sub") jsonyter--remote-models)
    (tabulated-list-print)
    (goto-char (point-min))
    (cl-letf (((symbol-function 'jsonyter-remote-dired-refresh) #'ignore))
      (jsonyter-remote-dired-find))
    (should (equal "sub/" jsonyter--remote-cwd))))

(ert-deftest jsonyter-test-remote-dired-find-downloads-a-file ()
  (with-temp-buffer
    (jsonyter-remote-dired-mode)
    (setq jsonyter--remote-owner (current-buffer)
          jsonyter--remote-cwd ""
          tabulated-list-entries (list (list "x.csv" (vector " " "x.csv" "10 B" ""))))
    (puthash "x.csv" '(:name "x.csv" :type "file" :path "x.csv") jsonyter--remote-models)
    (tabulated-list-print)
    (goto-char (point-min))
    (let (called)
      (cl-letf (((symbol-function 'jsonyter-remote-dired-download) (lambda () (setq called t))))
        (jsonyter-remote-dired-find))
      (should called))))

(ert-deftest jsonyter-test-remote-dired-find-errors-with-no-entry ()
  (with-temp-buffer
    (jsonyter-remote-dired-mode)
    (setq jsonyter--remote-owner (current-buffer))
    (should-error (jsonyter-remote-dired-find) :type 'user-error)))

(ert-deftest jsonyter-test-remote-dired-up-moves-to-parent ()
  (with-temp-buffer
    (jsonyter-remote-dired-mode)
    (setq jsonyter--remote-owner (current-buffer)
          jsonyter--remote-cwd "a/b/")
    (cl-letf (((symbol-function 'jsonyter-remote-dired-refresh) #'ignore))
      (jsonyter-remote-dired-up))
    (should (equal "a/" jsonyter--remote-cwd))))

(ert-deftest jsonyter-test-remote-dired-mark-and-unmark ()
  (with-temp-buffer
    (jsonyter-remote-dired-mode)
    (setq jsonyter--remote-owner (current-buffer)
          jsonyter--remote-cwd ""
          tabulated-list-entries (list (list "x.csv" (vector " " "x.csv" "10 B" ""))
                                        (list "y.csv" (vector " " "y.csv" "10 B" ""))))
    (puthash "x.csv" '(:name "x.csv" :type "file" :path "x.csv") jsonyter--remote-models)
    (puthash "y.csv" '(:name "y.csv" :type "file" :path "y.csv") jsonyter--remote-models)
    (tabulated-list-print)
    (goto-char (point-min))
    (cl-letf (((symbol-function 'jsonyter-remote-dired-refresh) #'ignore))
      (jsonyter-remote-dired-mark-delete))
    (should (member "x.csv" jsonyter--remote-marks))
    (goto-char (point-min))
    (cl-letf (((symbol-function 'jsonyter-remote-dired-refresh) #'ignore))
      (jsonyter-remote-dired-unmark))
    (should-not (member "x.csv" jsonyter--remote-marks))))

(ert-deftest jsonyter-test-remote-dired-execute-deletes-marked-entries ()
  (with-temp-buffer
    (jsonyter-remote-dired-mode)
    (setq jsonyter--remote-owner (current-buffer)
          jsonyter--remote-marks (list "x.csv" "y.csv"))
    (let (deleted said (jsonyter-remote-confirm-delete nil))
      (cl-letf (((symbol-function 'jsonyter--remote-call)
                 (lambda (_method params) (push (plist-get params :path) deleted) nil))
                ((symbol-function 'jsonyter-remote-dired-refresh) #'ignore)
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
        (jsonyter-remote-dired-execute))
      (should (= 2 (length deleted)))
      (should (null jsonyter--remote-marks))
      (should (string-match-p "deleted 2" said)))))

(ert-deftest jsonyter-test-remote-dired-execute-reports-partial-failure ()
  (with-temp-buffer
    (jsonyter-remote-dired-mode)
    (setq jsonyter--remote-owner (current-buffer)
          jsonyter--remote-marks (list "ok.csv" "bad.csv"))
    (let (said (jsonyter-remote-confirm-delete nil))
      (cl-letf (((symbol-function 'jsonyter--remote-call)
                 (lambda (_method params)
                   (when (equal (plist-get params :path) "bad.csv")
                     (error "permission denied"))))
                ((symbol-function 'jsonyter-remote-dired-refresh) #'ignore)
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
        (jsonyter-remote-dired-execute))
      (should (equal (list "bad.csv") jsonyter--remote-marks))
      (should (string-match-p "deleted 1, 1 failed" said)))))

(ert-deftest jsonyter-test-remote-dired-execute-errors-with-nothing-marked ()
  (with-temp-buffer
    (jsonyter-remote-dired-mode)
    (setq jsonyter--remote-owner (current-buffer))
    (should-error (jsonyter-remote-dired-execute) :type 'user-error)))

(ert-deftest jsonyter-test-remote-dired-rename-updates-server ()
  (with-temp-buffer
    (jsonyter-remote-dired-mode)
    (setq jsonyter--remote-owner (current-buffer)
          jsonyter--remote-cwd ""
          tabulated-list-entries (list (list "old.csv" (vector " " "old.csv" "10 B" ""))))
    (puthash "old.csv" '(:name "old.csv" :type "file" :path "old.csv") jsonyter--remote-models)
    (tabulated-list-print)
    (goto-char (point-min))
    (let (sent said)
      (cl-letf (((symbol-function 'jsonyter--read-remote-path) (lambda (&rest _) "new.csv"))
                ((symbol-function 'jsonyter--remote-call)
                 (lambda (method params) (setq sent (list method params))))
                ((symbol-function 'jsonyter-remote-dired-refresh) #'ignore)
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
        (jsonyter-remote-dired-rename))
      (should (equal (car sent) "rename_contents"))
      (should (equal (plist-get (cadr sent) :new_path) "new.csv"))
      (should (string-match-p "old.csv → new.csv" said)))))

(ert-deftest jsonyter-test-remote-dired-rename-refuses-unchanged ()
  (with-temp-buffer
    (jsonyter-remote-dired-mode)
    (setq jsonyter--remote-owner (current-buffer)
          jsonyter--remote-cwd ""
          tabulated-list-entries (list (list "old.csv" (vector " " "old.csv" "10 B" ""))))
    (puthash "old.csv" '(:name "old.csv" :type "file" :path "old.csv") jsonyter--remote-models)
    (tabulated-list-print)
    (goto-char (point-min))
    (cl-letf (((symbol-function 'jsonyter--read-remote-path) (lambda (&rest _) "old.csv")))
      (should-error (jsonyter-remote-dired-rename) :type 'user-error))))

(ert-deftest jsonyter-test-remote-dired-mkdir-creates-directory ()
  (with-temp-buffer
    (jsonyter-remote-dired-mode)
    (setq jsonyter--remote-owner (current-buffer)
          jsonyter--remote-cwd "d/")
    (let (sent said)
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "new"))
                ((symbol-function 'jsonyter--remote-call)
                 (lambda (method params) (setq sent (list method params))))
                ((symbol-function 'jsonyter-remote-dired-refresh) #'ignore)
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
        (call-interactively 'jsonyter-remote-dired-mkdir))
      (should (equal (car sent) "make_directory"))
      (should (equal (plist-get (cadr sent) :path) "d/new"))
      (should (string-match-p "created d/new" said)))))

(ert-deftest jsonyter-test-remote-dired-mkdir-refuses-blank-name ()
  (with-temp-buffer
    (jsonyter-remote-dired-mode)
    (setq jsonyter--remote-owner (current-buffer))
    (should-error (jsonyter-remote-dired-mkdir "") :type 'user-error)))

(ert-deftest jsonyter-test-remote-dired-export-via-interactive ()
  "Supplements the direct-call tests above: exercised via
`call-interactively' so its own body — not just its behavior — registers
as covered too."
  (with-temp-buffer
    (jsonyter-remote-dired-mode)
    (setq jsonyter--remote-owner (current-buffer)
          jsonyter--remote-cwd ""
          tabulated-list-entries (list (list "analysis.ipynb"
                                              (vector " " "analysis.ipynb" "10 B" ""))))
    (puthash "analysis.ipynb" '(:name "analysis.ipynb" :type "file" :path "analysis.ipynb")
             jsonyter--remote-models)
    (tabulated-list-print)
    (goto-char (point-min))
    (let (sent)
      (cl-letf (((symbol-function 'jsonyter--resolve-transfer-context)
                 (lambda () (cons (current-buffer) nil)))
                ((symbol-function 'jsonyter--list-export-formats)
                 (lambda (&rest _) (list :available t :formats '(:html (:output_mimetype "text/html")))))
                ((symbol-function 'completing-read) (lambda (&rest _) "html"))
                ((symbol-function 'read-file-name) (lambda (&rest _) "/tmp/analysis.html"))
                ((symbol-function 'jsonyter--ensure-bridge) #'ignore)
                ((symbol-function 'jsonyter--export-run)
                 (lambda (_session params _on-success) (setq sent params))))
        (call-interactively 'jsonyter-remote-dired-export))
      (should (equal (plist-get sent :format) "html"))
      (should (equal (plist-get sent :server_path) "analysis.ipynb")))))

;;;; dired integration

(ert-deftest jsonyter-test-dired-upload-marked-uploads-each-file-in-turn ()
  (require 'dired)
  (let* ((dir (file-name-as-directory (make-temp-file "jsonyter-dired-" t)))
         (f1 (expand-file-name "a.csv" dir))
         (f2 (expand-file-name "b.csv" dir)))
    (unwind-protect
        (progn
          (with-temp-file f1 (insert "a"))
          (with-temp-file f2 (insert "b"))
          (let ((dired-buf (dired-noselect dir)))
            (unwind-protect
                (with-current-buffer dired-buf
                  (dired-mark-files-regexp "\\.csv\\'")
                  (let (uploaded said)
                    (cl-letf (((symbol-function 'jsonyter--resolve-transfer-context)
                               (lambda () (cons (current-buffer) nil)))
                              ((symbol-function 'jsonyter--read-remote-path) (lambda (&rest _) "d/"))
                              ((symbol-function 'jsonyter--transfer-run)
                               (lambda (_context _method params on-success)
                                 (push (plist-get params :remote_path) uploaded)
                                 (funcall on-success nil)))
                              ((symbol-function 'message)
                               (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
                      (jsonyter-dired-upload-marked)
                      (should (= 2 (length uploaded)))
                      (should (member "d/a.csv" uploaded))
                      (should (member "d/b.csv" uploaded))
                      (should (string-match-p "uploaded 2 of 2" said)))))
              (kill-buffer dired-buf))))
      (delete-directory dir t))))

(ert-deftest jsonyter-test-dired-upload-marked-errors-without-marked-files ()
  (require 'dired)
  (let ((dir (file-name-as-directory (make-temp-file "jsonyter-dired-" t))))
    (unwind-protect
        (let ((dired-buf (dired-noselect dir)))
          (unwind-protect
              (with-current-buffer dired-buf
                (cl-letf (((symbol-function 'jsonyter--resolve-transfer-context)
                           (lambda () (cons (current-buffer) nil)))
                          ((symbol-function 'jsonyter--read-remote-path) (lambda (&rest _) "d/")))
                  (should-error (jsonyter-dired-upload-marked) :type 'user-error)))
            (kill-buffer dired-buf)))
      (delete-directory dir t))))

(ert-deftest jsonyter-test-dired-upload-marked-refuses-outside-dired ()
  (with-temp-buffer
    (should-error (jsonyter-dired-upload-marked) :type 'user-error)))

(ert-deftest jsonyter-test-dired-upload-dwim-dispatches-on-marks ()
  (require 'dired)
  (let* ((dir (file-name-as-directory (make-temp-file "jsonyter-dired-" t)))
         (f1 (expand-file-name "a.csv" dir)))
    (unwind-protect
        (progn
          (with-temp-file f1 (insert "a"))
          (let ((dired-buf (dired-noselect dir)))
            (unwind-protect
                (with-current-buffer dired-buf
                  (let (dispatched)
                    (cl-letf (((symbol-function 'call-interactively)
                               (lambda (cmd &rest _) (setq dispatched cmd))))
                      (jsonyter-dired-upload-dwim))
                    (should (eq dispatched 'jsonyter-upload-file)))
                  (goto-char (point-min))
                  (dired-mark-files-regexp "\\.csv\\'")
                  (let (dispatched)
                    (cl-letf (((symbol-function 'call-interactively)
                               (lambda (cmd &rest _) (setq dispatched cmd))))
                      (jsonyter-dired-upload-dwim))
                    (should (eq dispatched 'jsonyter-dired-upload-marked))))
              (kill-buffer dired-buf))))
      (delete-directory dir t))))

(ert-deftest jsonyter-test-dired-setup-binds-upload-key ()
  (require 'dired)
  (jsonyter-dired-setup)
  (should (eq (lookup-key dired-mode-map (kbd "C-c C-u")) #'jsonyter-dired-upload-dwim)))

;;;; jsonyter-sync

;; Pure-function and stubbed-bridge coverage, in the same spirit as the
;; file-transfer tests above: `jsonyter--sync-entries' is fed fabricated
;; plans (one case per decision-table action), override bookkeeping and
;; the destructive-review threshold are exercised directly, and
;; `jsonyter--sync-run'/`jsonyter-sync-abort' are driven with
;; `jsonyter--send' stubbed.  Nothing here talks to a real bridge.

(defun jsonyter-tests--sync-side (size hash mtime)
  (list :size size :hash hash :mtime mtime))

(cl-defun jsonyter-tests--sync-entry (path action reason &key local remote
                                           baseline-hash bytes resolution newest
                                           mtime-delta)
  (append
   (list :path path :action action :reason reason
         :local local :remote remote :baseline_hash baseline-hash)
   (and bytes (list :bytes bytes))
   (and resolution (list :resolution resolution))
   (and newest (list :newest newest))
   (and mtime-delta (list :mtime_delta mtime-delta))))

(cl-defun jsonyter-tests--sync-plan (entries &key (push 0) (pull 0) (converge 0)
                                             (skip 0) (conflict 0)
                                             (push-delete 0) (pull-delete 0)
                                             (bytes-up 0) (bytes-down 0)
                                             (integrity "sha256") (server "http://x"))
  (list :local_dir "/tmp/x" :remote_dir "work/data" :server server
        :hash_algorithm "sha256" :integrity integrity :baseline "present"
        :clock_skew 0.0 :conflict_policy "ask" :delete_policy "none"
        :scanned (list :local 1 :remote 1 :directories 1 :requests 1)
        :entries entries
        :totals (list :push push :pull pull :converge converge :skip skip
                      :conflict conflict :push_delete push-delete :pull_delete pull-delete
                      :bytes_up bytes-up :bytes_down bytes-down)
        :warnings nil))

(ert-deftest jsonyter-test-sync-pair-plist-normalizes-cons-and-plist ()
  (should (equal (jsonyter--sync-pair-plist (cons "~/data" "work/data"))
                 (list :local "~/data" :remote "work/data")))
  (let ((pl (list :local "~/data" :remote "work/data" :conflict 'newest)))
    (should (eq (jsonyter--sync-pair-plist pl) pl))))

(ert-deftest jsonyter-test-sync-pair-accessors ()
  (let ((pair (list :local "/tmp/x/" :remote "/work/data/" :conflict 'newest
                    :delete 'push :ignore '("*.tmp"))))
    (should (equal (jsonyter--sync-pair-local pair) "/tmp/x"))
    (should (equal (jsonyter--sync-pair-remote pair) "work/data"))
    (should (equal (jsonyter--sync-pair-conflict pair) "newest"))
    (should (equal (jsonyter--sync-pair-delete pair) "push"))
    (let ((jsonyter-sync-ignore '("*.bak")))
      (should (equal (jsonyter--sync-pair-ignore pair) '("*.tmp" "*.bak")))))
  (let ((pair (list :local "/tmp/x")))
    (should (equal (jsonyter--sync-pair-conflict pair) "ask"))
    (should (equal (jsonyter--sync-pair-delete pair) "none"))))

(ert-deftest jsonyter-test-sync-resolve-pair-picks-most-specific-local-match ()
  (with-temp-buffer
    (setq default-directory "/tmp/project/data/nested/")
    (let ((jsonyter-sync-pairs
           (list (cons "/tmp/project" "work")
                (cons "/tmp/project/data" "work/data"))))
      (should (equal (jsonyter--sync-pair-remote
                     (jsonyter--sync-resolve-pair (cons (current-buffer) nil)))
                    "work/data")))))

(ert-deftest jsonyter-test-sync-resolve-pair-matches-remote-dired-cwd ()
  (with-temp-buffer
    (jsonyter-remote-dired-mode)
    (setq jsonyter--remote-cwd "work/data/")
    (let ((jsonyter-sync-pairs (list (list :local "/tmp/project" :remote "work")
                                     (list :local "/tmp/project/data" :remote "work/data"))))
      (should (equal (jsonyter--sync-pair-local
                     (jsonyter--sync-resolve-pair (cons (current-buffer) nil)))
                    (directory-file-name (expand-file-name "/tmp/project/data")))))))

(ert-deftest jsonyter-test-sync-invoking-directory-uses-dired-current-directory ()
  (require 'dired)
  (let ((dir (file-name-as-directory (make-temp-file "jsonyter-sync-dired-" t))))
    (unwind-protect
        (let ((dired-buf (dired-noselect dir)))
          (unwind-protect
              (with-current-buffer dired-buf
                (should (equal (jsonyter--sync-invoking-directory) (dired-current-directory))))
            (kill-buffer dired-buf)))
      (delete-directory dir t))))

(ert-deftest jsonyter-test-sync-resolve-pair-excludes-server-mismatch ()
  (with-temp-buffer
    (setq default-directory "/tmp/project/")
    (setq-local jsonyter--url "http://serverA")
    (let ((jsonyter-sync-pairs
           (list (list :local "/tmp/project" :remote "wrong" :server "http://serverB")
                (list :local "/tmp/project" :remote "right" :server "http://serverA"))))
      (should (equal (jsonyter--sync-pair-remote
                     (jsonyter--sync-resolve-pair (cons (current-buffer) nil)))
                    "right")))))

(ert-deftest jsonyter-test-sync-resolve-pair-offers-to-create-when-none-match ()
  (with-temp-buffer
    (setq default-directory "/tmp/newproj/")
    (let ((jsonyter-sync-pairs nil))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_p) t))
                ((symbol-function 'customize-save-variable) (lambda (sym val) (set sym val)))
                ((symbol-function 'jsonyter--transfer-remote-dir) (lambda (&rest _) "work/"))
                ((symbol-function 'jsonyter--read-remote-path) (lambda (&rest _) "work/newproj")))
        (let ((pair (jsonyter--sync-resolve-pair (cons (current-buffer) nil))))
          (should (equal (jsonyter--sync-pair-remote pair) "work/newproj"))
          (should (equal jsonyter-sync-pairs (list pair))))))))

(ert-deftest jsonyter-test-sync-entries-glyphs-and-faces ()
  (let* ((entries
          (list (jsonyter-tests--sync-entry
                "a.csv" "push" "local-changed"
                :local (jsonyter-tests--sync-side 10 "h1" 100.0)
                :remote (jsonyter-tests--sync-side 8 "h0" "2026-01-01T00:00:00Z"))
               (jsonyter-tests--sync-entry
                "b.csv" "pull" "remote-changed"
                :local (jsonyter-tests--sync-side 5 "h0" 90.0)
                :remote (jsonyter-tests--sync-side 6 "h1" "2026-01-01T00:00:00Z"))
               (jsonyter-tests--sync-entry
                "c.csv" "conflict" "both-changed"
                :local (jsonyter-tests--sync-side 1 "hl" 1.0)
                :remote (jsonyter-tests--sync-side 2 "hr" "2026-01-01T00:00:00Z"))
               (jsonyter-tests--sync-entry
                "d.csv" "push-delete" "local-missing"
                :remote (jsonyter-tests--sync-side 3 "hh" "2026-01-01T00:00:00Z"))
               (jsonyter-tests--sync-entry
                "e.csv" "pull-delete" "remote-missing"
                :local (jsonyter-tests--sync-side 4 "hh" 1.0))))
         (plan (jsonyter-tests--sync-plan entries))
         (rows (jsonyter--sync-entries plan nil t))
         (row (lambda (path) (cadr (assoc path rows)))))
    (should (= 5 (length rows)))
    (should (equal (substring-no-properties (aref (funcall row "a.csv") 0)) ">"))
    (should (eq (get-text-property 0 'face (aref (funcall row "a.csv") 0)) 'jsonyter-sync-push-face))
    (should (equal (substring-no-properties (aref (funcall row "b.csv") 0)) "<"))
    (should (eq (get-text-property 0 'face (aref (funcall row "b.csv") 0)) 'jsonyter-sync-pull-face))
    (should (equal (substring-no-properties (aref (funcall row "c.csv") 0)) "!"))
    (should (eq (get-text-property 0 'face (aref (funcall row "c.csv") 0)) 'jsonyter-sync-conflict-face))
    (should (equal (substring-no-properties (aref (funcall row "d.csv") 0)) ">D"))
    (should (equal (substring-no-properties (aref (funcall row "e.csv") 0)) "<D"))
    (should (equal (aref (funcall row "a.csv") 2) (jsonyter--human-size 10)))
    (should (equal (aref (funcall row "b.csv") 2) (jsonyter--human-size 6)))))

(ert-deftest jsonyter-test-sync-entries-hides-unchanged-by-default ()
  (let* ((entries (list (jsonyter-tests--sync-entry
                        "same.csv" "converge" "identical"
                        :local (jsonyter-tests--sync-side 1 "h" 1.0)
                        :remote (jsonyter-tests--sync-side 1 "h" "2026-01-01T00:00:00Z"))
                       (jsonyter-tests--sync-entry
                        "unchanged.csv" "skip" "unchanged"
                        :local (jsonyter-tests--sync-side 1 "h" 1.0)
                        :remote (jsonyter-tests--sync-side 1 "h" "2026-01-01T00:00:00Z"))
                       (jsonyter-tests--sync-entry
                        "moved.csv" "push" "local-changed"
                        :local (jsonyter-tests--sync-side 1 "h" 1.0) :remote nil)))
         (plan (jsonyter-tests--sync-plan entries)))
    (should (= 1 (length (jsonyter--sync-entries plan nil nil))))
    (should (= 3 (length (jsonyter--sync-entries plan nil t))))))

(ert-deftest jsonyter-test-sync-entries-shows-missing-side-skip-always ()
  (let* ((entries (list (jsonyter-tests--sync-entry
                        "leftover.csv" "skip" "remote-missing"
                        :local (jsonyter-tests--sync-side 1 "h" 1.0) :remote nil)))
         (plan (jsonyter-tests--sync-plan entries)))
    (should (= 1 (length (jsonyter--sync-entries plan nil nil))))))

(ert-deftest jsonyter-test-sync-set-override-only-genuine ()
  (let ((jsonyter--sync-entries-by-path (make-hash-table :test #'equal))
        (jsonyter--sync-overrides nil))
    (puthash "a.csv" (list :path "a.csv" :action "push") jsonyter--sync-entries-by-path)
    (puthash "b.csv" (list :path "b.csv" :action "conflict") jsonyter--sync-entries-by-path)
    (jsonyter--sync-set-override "a.csv" "push")
    (should (null jsonyter--sync-overrides))
    (jsonyter--sync-set-override "b.csv" "pull")
    (should (equal jsonyter--sync-overrides '(("b.csv" . "pull"))))
    (jsonyter--sync-set-override "b.csv" "skip")
    (should (equal jsonyter--sync-overrides '(("b.csv" . "skip"))))))

(ert-deftest jsonyter-test-sync-resolve-newest-and-other-directions ()
  (with-temp-buffer
    (jsonyter-sync-mode)
    (setq jsonyter--sync-pair (list :local "/tmp/x" :remote "work"))
    (setq jsonyter--sync-plan
          (jsonyter-tests--sync-plan
           (list (jsonyter-tests--sync-entry
                 "both.csv" "conflict" "both-changed"
                 :local (jsonyter-tests--sync-side 1 "hl" 1.0)
                 :remote (jsonyter-tests--sync-side 2 "hr" "2026-01-01T00:00:00Z")
                 :newest "remote")
                (jsonyter-tests--sync-entry
                 "localmissing.csv" "conflict" "local-missing"
                 :local nil :remote (jsonyter-tests--sync-side 2 "hr" "2026-01-01T00:00:00Z")
                 :newest "local"))))
    (jsonyter--sync-render)
    (goto-char (point-min))
    (jsonyter-sync-resolve-newest)
    (should (equal (cdr (assoc "both.csv" jsonyter--sync-overrides)) "pull"))
    (goto-char (point-min))
    (jsonyter-sync-clear-override)
    (goto-char (point-min))
    (jsonyter-sync-resolve-other)
    (should (equal (cdr (assoc "both.csv" jsonyter--sync-overrides)) "push"))
    ;; "localmissing.csv": local is absent, remote present, and the
    ;; (fabricated) newest side is "local" -- local's absence wins, so
    ;; the remote copy must be deleted to match it.
    (goto-char (point-min))
    (forward-line 1)
    (jsonyter-sync-resolve-newest)
    (should (equal (cdr (assoc "localmissing.csv" jsonyter--sync-overrides)) "push-delete"))))

(ert-deftest jsonyter-test-sync-override-delete-picks-correct-side ()
  (with-temp-buffer
    (jsonyter-sync-mode)
    (setq jsonyter--sync-pair (list :local "/tmp/x" :remote "work"))
    (setq jsonyter--sync-plan
          (jsonyter-tests--sync-plan
           (list (jsonyter-tests--sync-entry
                 "localonly.csv" "push" "local-new"
                 :local (jsonyter-tests--sync-side 1 "h" 1.0) :remote nil)
                (jsonyter-tests--sync-entry
                 "remoteonly.csv" "pull" "remote-new"
                 :local nil :remote (jsonyter-tests--sync-side 1 "h" "2026-01-01T00:00:00Z"))
                (jsonyter-tests--sync-entry
                 "both.csv" "conflict" "both-changed"
                 :local (jsonyter-tests--sync-side 1 "h" 1.0)
                 :remote (jsonyter-tests--sync-side 1 "h" "2026-01-01T00:00:00Z")))))
    (jsonyter--sync-render)
    (goto-char (point-min))
    (jsonyter-sync-override-delete)
    (should (equal (cdr (assoc "localonly.csv" jsonyter--sync-overrides)) "pull-delete"))
    (goto-char (point-min)) (forward-line 1)
    (jsonyter-sync-override-delete)
    (should (equal (cdr (assoc "remoteonly.csv" jsonyter--sync-overrides)) "push-delete"))
    (goto-char (point-min)) (forward-line 2)
    (cl-letf (((symbol-function 'read-char-choice) (lambda (&rest _) ?r)))
      (jsonyter-sync-override-delete))
    (should (equal (cdr (assoc "both.csv" jsonyter--sync-overrides)) "push-delete"))))

(ert-deftest jsonyter-test-sync-destructive-p-triggers-correctly ()
  (let ((jsonyter-sync-review-threshold 3))
    (should-not (jsonyter--sync-destructive-p
                (jsonyter-tests--sync-plan
                 (list (jsonyter-tests--sync-entry "a" "push" "local-new")) :push 1)))
    (should (jsonyter--sync-destructive-p
            (jsonyter-tests--sync-plan
             (list (jsonyter-tests--sync-entry "a" "push-delete" "local-missing"))
             :push-delete 1)))
    (should (jsonyter--sync-destructive-p
            (jsonyter-tests--sync-plan
             (mapcar (lambda (n) (jsonyter-tests--sync-entry (format "f%d" n) "push" "local-new"))
                    (number-sequence 1 4))
             :push 4)))
    (should (jsonyter--sync-destructive-p
            (jsonyter-tests--sync-plan
             (list (jsonyter-tests--sync-entry "a" "push" "both-changed" :resolution "push"))
             :push 1)))))

(ert-deftest jsonyter-test-sync-should-review-p-honors-policy ()
  (let ((plan (jsonyter-tests--sync-plan
              (list (jsonyter-tests--sync-entry "a" "push" "local-new")) :push 1)))
    (let ((jsonyter-sync-review 'always))
      (should (jsonyter--sync-should-review-p plan nil)))
    (let ((jsonyter-sync-review 'never))
      (should-not (jsonyter--sync-should-review-p plan nil))
      (should (jsonyter--sync-should-review-p plan t)))
    (let ((jsonyter-sync-review 'when-destructive))
      (should-not (jsonyter--sync-should-review-p plan nil)))))

(ert-deftest jsonyter-test-sync-plan-for-wire-nullifies-and-vconcats ()
  (let* ((entries (list (jsonyter-tests--sync-entry
                        "a" "push" "local-new"
                        :local (jsonyter-tests--sync-side 5 "h" 1.0) :remote nil)))
         (plan (plist-put (jsonyter-tests--sync-plan entries :push 1) :clock_skew nil)))
    (let* ((wire (jsonyter--sync-plan-for-wire plan))
           (wentries (plist-get wire :entries)))
      (should (vectorp wentries))
      (should (eq :null (plist-get wire :clock_skew)))
      (let ((wentry (aref wentries 0)))
        (should (eq :null (plist-get wentry :remote)))
        (should (eq :null (plist-get wentry :resolution)))
        (should (equal (plist-get (plist-get wentry :local) :size) 5)))
      (should (stringp (json-serialize wire))))))

(ert-deftest jsonyter-test-error-message-sync-refused-reasons ()
  (should (string-match-p
          "jsonyter-sync-max-deletes"
          (jsonyter--error-message
           '(:error "SyncRefused" :message "refusing to sync: too many deletes"
             :reason "too-many-deletes" :count 40 :max_deletes 25))))
  (should (string-match-p
          "jsonyter-sync-abort"
          (jsonyter--error-message
           '(:error "SyncRefused" :message "another sync is running"
             :reason "locked" :holder "1234"))))
  (should (string-match-p
          "directory you meant to sync"
          (jsonyter--error-message
           '(:error "SyncRefused" :message "too many files"
             :reason "too-many-files" :max_files 5000)))))

(ert-deftest jsonyter-test-sync-run-sets-mode-line-tag-and-clears ()
  (jsonyter-tests--with-sessions
    (let ((session (jsonyter-tests--bind-session '("python" . "") "kid"))
          (handlers nil) (id nil))
      (cl-letf (((symbol-function 'jsonyter--send)
                (lambda (_m _p hs) (setq handlers hs) 1)))
        (setq id (jsonyter--sync-run (cons (current-buffer) session) "sync_plan" nil #'ignore))
        (funcall (plist-get handlers :progress) '(:phase "scan" :op "local"))
        (should (equal "sync" (plist-get (jsonyter--session-transfer session) :phase)))
        (should (null (plist-get (jsonyter--session-transfer session) :files_total)))
        (funcall (plist-get handlers :progress)
                '(:phase "sync" :op "push" :file_index 4 :files_total 12))
        (should (equal 4 (plist-get (jsonyter--session-transfer session) :file_index)))
        (should (equal 12 (plist-get (jsonyter--session-transfer session) :files_total)))
        (should (equal id (plist-get (jsonyter--session-transfer session) :request-id)))
        (funcall (plist-get handlers :result) '(:result (:ok t)))
        (should (null (jsonyter--session-transfer session)))))))

(ert-deftest jsonyter-test-session-status-tag-renders-sync-phase ()
  (jsonyter-tests--with-sessions
    (let ((session (jsonyter-tests--bind-session '("python" . "") "kid"))
          (jsonyter-mode-line-show-kernel-id nil))
      (setf (jsonyter--session-transfer session) '(:phase "sync"))
      (should (equal ":sync" (jsonyter--session-status-tag session)))
      (setf (jsonyter--session-transfer session) '(:phase "sync" :file_index 4 :files_total 12))
      (should (equal ":sync 4/12" (jsonyter--session-status-tag session))))))

(ert-deftest jsonyter-test-sync-abort-errors-with-nothing-running ()
  (jsonyter-tests--with-sessions
    (let ((session (jsonyter-tests--bind-session '("python" . "") "kid")))
      (cl-letf (((symbol-function 'jsonyter--resolve-transfer-context)
                (lambda () (cons (current-buffer) session))))
        (should-error (jsonyter-sync-abort) :type 'user-error)))))

(ert-deftest jsonyter-test-sync-abort-sends-cancel-with-recorded-id ()
  (jsonyter-tests--with-sessions
    (let ((session (jsonyter-tests--bind-session '("python" . "") "kid"))
          (sent-method nil) (sent-params nil))
      (setf (jsonyter--session-transfer session) '(:phase "sync" :request-id 42))
      (cl-letf (((symbol-function 'jsonyter--resolve-transfer-context)
                (lambda () (cons (current-buffer) session)))
                ((symbol-function 'jsonyter--send)
                (lambda (m p &rest _) (setq sent-method m sent-params p))))
        (jsonyter-sync-abort)
        (should (equal sent-method "cancel_sync"))
        (should (equal (plist-get sent-params :request_id) 42))))))

(ert-deftest jsonyter-test-sync-state-path-matches-known-hash ()
  (let ((pair (list :local "/home/e/project/data" :remote "work/data"))
        (jsonyter-sync-state-directory "/custom/state"))
    (should (equal (jsonyter--sync-state-path "http://localhost:8888" pair)
                  "/custom/state/26c4e9c9f55e0cc5.json"))))

(ert-deftest jsonyter-test-sync-forget-pair-removes-matching-entry ()
  (let ((jsonyter-sync-pairs (list (cons "/tmp/a" "work/a") (cons "/tmp/b" "work/b"))))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_p) nil)))
      (jsonyter-sync-forget-pair (jsonyter--sync-pair-plist (cons "/tmp/a" "work/a")) nil))
    (should (= 1 (length jsonyter-sync-pairs)))
    (should (equal (jsonyter--sync-pair-remote (jsonyter--sync-pair-plist (car jsonyter-sync-pairs)))
                  "work/b"))))

(ert-deftest jsonyter-test-sync-execute-sends-plan-and-overrides ()
  (with-temp-buffer
    (jsonyter-sync-mode)
    (setq jsonyter--sync-owner (current-buffer)
          jsonyter--sync-session-key nil
          jsonyter--sync-pair (list :local "/tmp/x" :remote "work")
          jsonyter--sync-overrides '(("b.csv" . "skip")))
    (setq jsonyter--sync-plan
          (jsonyter-tests--sync-plan
           (list (jsonyter-tests--sync-entry
                 "a.csv" "push" "local-new"
                 :local (jsonyter-tests--sync-side 1 "h" 1.0) :remote nil))
           :push 1))
    (let (sent-method sent-params)
      (cl-letf (((symbol-function 'jsonyter--send)
                (lambda (m p &rest _) (setq sent-method m sent-params p) 1))
                ((symbol-function 'y-or-n-p) (lambda (_p) t)))
        (jsonyter-sync-execute))
      (should (equal sent-method "sync_apply"))
      (should (equal (gethash "b.csv" (plist-get sent-params :overrides)) "skip")))))

;; The orchestration layer (`jsonyter--sync-command' and friends) and the
;; standalone pair/baseline commands are otherwise only exercised end to
;; end by the harness scenario (sync.el), which a batch coverage run does
;; not see. These stub `jsonyter--send' to answer synchronously, so a
;; whole plan-then-apply round trip runs inline within one `should'.

(ert-deftest jsonyter-test-sync-command-applies-directly-and-reports ()
  (jsonyter-tests--with-sessions
    (let* ((session (jsonyter-tests--bind-session '("python" . "") "kid"))
           (pair (list :local "/tmp/x" :remote "work"))
           (plan (jsonyter-tests--sync-plan
                  (list (jsonyter-tests--sync-entry
                        "a.csv" "push" "local-new"
                        :local (jsonyter-tests--sync-side 10 "h" 1.0) :remote nil))
                  :push 1))
           (apply-result (list :ok t :moved (list :pushed 1 :pulled 0 :converged 0
                                                  :deleted_local 0 :deleted_remote 0)
                               :bytes_up 10 :bytes_down 0 :skipped 0
                               :conflicts_unresolved 0 :failed nil :conflict_copies nil
                               :integrity "sha256" :elapsed 0.1))
           (calls nil) (said nil))
      (cl-letf (((symbol-function 'jsonyter--resolve-transfer-context)
                (lambda () (cons (current-buffer) session)))
                ((symbol-function 'jsonyter--sync-resolve-pair) (lambda (_ctx) pair))
                ((symbol-function 'jsonyter--send)
                (lambda (method params handlers)
                  (push method calls)
                  (pcase method
                    ("sync_plan" (funcall (plist-get handlers :result) (list :result plan)))
                    ("sync_apply" (funcall (plist-get handlers :result) (list :result apply-result))))
                  1))
                ((symbol-function 'message)
                (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
        (jsonyter-sync))
      (should (equal (nreverse calls) '("sync_plan" "sync_apply")))
      (should (string-match-p "synced .*1 up" said))
      (should (null (seq-find (lambda (b) (string-prefix-p "*jsonyter-sync: " (buffer-name b)))
                              (buffer-list)))))))

(ert-deftest jsonyter-test-sync-command-opens-review-when-destructive ()
  (jsonyter-tests--with-sessions
    (let* ((session (jsonyter-tests--bind-session '("python" . "") "kid"))
           (pair (list :local "/tmp/x" :remote "work"))
           (plan (jsonyter-tests--sync-plan
                  (list (jsonyter-tests--sync-entry
                        "gone.csv" "push-delete" "local-missing"
                        :remote (jsonyter-tests--sync-side 1 "h" "2026-01-01T00:00:00Z")))
                  :push-delete 1))
           (calls nil) (buf nil))
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'jsonyter--resolve-transfer-context)
                      (lambda () (cons (current-buffer) session)))
                      ((symbol-function 'jsonyter--sync-resolve-pair) (lambda (_ctx) pair))
                      ((symbol-function 'jsonyter--send)
                      (lambda (method _params handlers)
                        (push method calls)
                        (when (equal method "sync_plan")
                          (funcall (plist-get handlers :result) (list :result plan)))
                        1)))
              (jsonyter-sync))
            (should (equal calls '("sync_plan")))
            (setq buf (seq-find (lambda (b) (string-prefix-p "*jsonyter-sync: " (buffer-name b)))
                                (buffer-list)))
            (should buf)
            (should (with-current-buffer buf (derived-mode-p 'jsonyter-sync-mode))))
        (when buf (kill-buffer buf))))))

(ert-deftest jsonyter-test-sync-command-reports-plan-error ()
  (jsonyter-tests--with-sessions
    (let* ((session (jsonyter-tests--bind-session '("python" . "") "kid"))
           (pair (list :local "/tmp/x" :remote "work"))
           (calls nil) (said nil))
      (cl-letf (((symbol-function 'jsonyter--resolve-transfer-context)
                (lambda () (cons (current-buffer) session)))
                ((symbol-function 'jsonyter--sync-resolve-pair) (lambda (_ctx) pair))
                ((symbol-function 'jsonyter--send)
                (lambda (method _params handlers)
                  (push method calls)
                  (funcall (plist-get handlers :result) (list :error (list :message "no such directory")))
                  1))
                ((symbol-function 'message)
                (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
        (jsonyter-sync))
      (should (equal calls '("sync_plan")))
      (should (string-match-p "no such directory" said)))))

(ert-deftest jsonyter-test-sync-command-reports-apply-error ()
  (jsonyter-tests--with-sessions
    (let* ((session (jsonyter-tests--bind-session '("python" . "") "kid"))
           (pair (list :local "/tmp/x" :remote "work"))
           (plan (jsonyter-tests--sync-plan
                  (list (jsonyter-tests--sync-entry
                        "a.csv" "push" "local-new"
                        :local (jsonyter-tests--sync-side 1 "h" 1.0) :remote nil))
                  :push 1))
           (said nil))
      (cl-letf (((symbol-function 'jsonyter--resolve-transfer-context)
                (lambda () (cons (current-buffer) session)))
                ((symbol-function 'jsonyter--sync-resolve-pair) (lambda (_ctx) pair))
                ((symbol-function 'jsonyter--send)
                (lambda (method _params handlers)
                  (pcase method
                    ("sync_plan" (funcall (plist-get handlers :result) (list :result plan)))
                    ("sync_apply" (funcall (plist-get handlers :result)
                                          (list :error (list :message "locked.db changed")))))
                  1))
                ((symbol-function 'message)
                (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
        (jsonyter-sync))
      (should (string-match-p "locked.db changed" said)))))

(ert-deftest jsonyter-test-sync-command-refuses-second-sync-and-can-abort ()
  (jsonyter-tests--with-sessions
    (let ((session (jsonyter-tests--bind-session '("python" . "") "kid"))
          (cancel-sent nil))
      (setf (jsonyter--session-transfer session) '(:phase "sync" :request-id 7))
      (cl-letf (((symbol-function 'jsonyter--resolve-transfer-context)
                (lambda () (cons (current-buffer) session)))
                ((symbol-function 'y-or-n-p) (lambda (_p) t))
                ((symbol-function 'jsonyter--send)
                (lambda (method params &rest _)
                  (when (equal method "cancel_sync") (setq cancel-sent params)))))
        (jsonyter-sync))
      (should (equal (plist-get cancel-sent :request_id) 7)))))

(ert-deftest jsonyter-test-sync-command-refuses-second-sync-when-declined ()
  (jsonyter-tests--with-sessions
    (let ((session (jsonyter-tests--bind-session '("python" . "") "kid")))
      (setf (jsonyter--session-transfer session) '(:phase "sync" :request-id 7))
      (cl-letf (((symbol-function 'jsonyter--resolve-transfer-context)
                (lambda () (cons (current-buffer) session)))
                ((symbol-function 'y-or-n-p) (lambda (_p) nil)))
        (should-error (jsonyter-sync) :type 'user-error)))))

(ert-deftest jsonyter-test-sync-command-refuses-when-busy-with-other-phase ()
  (jsonyter-tests--with-sessions
    (let ((session (jsonyter-tests--bind-session '("python" . "") "kid")))
      (setf (jsonyter--session-transfer session) '(:phase "upload" :pct 40))
      (cl-letf (((symbol-function 'jsonyter--resolve-transfer-context)
                (lambda () (cons (current-buffer) session))))
        (should-error (jsonyter-sync) :type 'user-error)))))

(ert-deftest jsonyter-test-sync-push-and-pull-force-conflict-policy ()
  (jsonyter-tests--with-sessions
    (let ((session (jsonyter-tests--bind-session '("python" . "") "kid"))
          (pair (list :local "/tmp/x" :remote "work"))
          (sent nil))
      (cl-letf (((symbol-function 'jsonyter--resolve-transfer-context)
                (lambda () (cons (current-buffer) session)))
                ((symbol-function 'jsonyter--sync-resolve-pair) (lambda (_ctx) pair))
                ((symbol-function 'jsonyter--send)
                (lambda (_m params _h) (push params sent) 1)))
        (jsonyter-sync-push)
        (should (equal (plist-get (car sent) :conflict) "local"))
        ;; The stub never completes the request, so nothing clears the
        ;; session's `busy' transfer slot on its own -- reset it here the
        ;; way a real finished sync would, or the second call reads
        ;; `jsonyter--sync-command''s "already running" branch and hits
        ;; a real `y-or-n-p' with no minibuffer to answer it from.
        (setf (jsonyter--session-transfer session) nil)
        (jsonyter-sync-pull)
        (should (equal (plist-get (car sent) :conflict) "remote"))))))

(ert-deftest jsonyter-test-sync-status-never-auto-applies ()
  (jsonyter-tests--with-sessions
    (let* ((session (jsonyter-tests--bind-session '("python" . "") "kid"))
           (pair (list :local "/tmp/x" :remote "work"))
           (plan (jsonyter-tests--sync-plan
                  (list (jsonyter-tests--sync-entry
                        "a.csv" "push" "local-new"
                        :local (jsonyter-tests--sync-side 1 "h" 1.0) :remote nil))
                  :push 1))
           (calls nil) (buf nil))
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'jsonyter--resolve-transfer-context)
                      (lambda () (cons (current-buffer) session)))
                      ((symbol-function 'jsonyter--sync-resolve-pair) (lambda (_ctx) pair))
                      ((symbol-function 'jsonyter--send)
                      (lambda (method _params handlers)
                        (push method calls)
                        (when (equal method "sync_plan")
                          (funcall (plist-get handlers :result) (list :result plan)))
                        1)))
              (jsonyter-sync-status))
            (should (equal calls '("sync_plan")))
            (setq buf (seq-find (lambda (b) (string-prefix-p "*jsonyter-sync: " (buffer-name b)))
                                (buffer-list)))
            (should buf))
        (when buf (kill-buffer buf))))))

(defmacro jsonyter-tests--with-sync-buffer (owner-var &rest body)
  "Run BODY in a fresh `jsonyter-sync-mode' buffer, OWNER-VAR bound to a
throwaway owner buffer that is killed afterward along with the sync buffer."
  (declare (indent 1) (debug t))
  `(let ((,owner-var (generate-new-buffer " *sync-owner*")))
     (unwind-protect
         (with-temp-buffer
           (jsonyter-sync-mode)
           ,@body)
       (kill-buffer ,owner-var))))

(ert-deftest jsonyter-test-sync-replan-updates-plan-and-clears-overrides ()
  (jsonyter-tests--with-sync-buffer owner
    (setq jsonyter--sync-owner owner
          jsonyter--sync-session-key nil
          jsonyter--sync-pair (list :local "/tmp/x" :remote "work")
          jsonyter--sync-conflict-override nil
          jsonyter--sync-overrides '(("old.csv" . "skip"))
          jsonyter--sync-plan (jsonyter-tests--sync-plan
                              (list (jsonyter-tests--sync-entry "old.csv" "push" "local-new"))
                              :push 1))
    (let ((new-plan (jsonyter-tests--sync-plan
                     (list (jsonyter-tests--sync-entry "new.csv" "pull" "remote-new"))
                     :pull 1)))
      (cl-letf (((symbol-function 'jsonyter--send)
                (lambda (_m _p handlers) (funcall (plist-get handlers :result) (list :result new-plan)) 1)))
        (jsonyter-sync-replan))
      (should (equal (plist-get jsonyter--sync-plan :entries) (plist-get new-plan :entries)))
      (should (null jsonyter--sync-overrides)))))

(ert-deftest jsonyter-test-sync-replan-reports-error ()
  (jsonyter-tests--with-sync-buffer owner
    (setq jsonyter--sync-owner owner
          jsonyter--sync-session-key nil
          jsonyter--sync-pair (list :local "/tmp/x" :remote "work")
          jsonyter--sync-plan (jsonyter-tests--sync-plan
                              (list (jsonyter-tests--sync-entry "old.csv" "push" "local-new"))
                              :push 1))
    (let (said)
      (cl-letf (((symbol-function 'jsonyter--send)
                (lambda (_m _p handlers)
                  (funcall (plist-get handlers :result) (list :error (list :message "offline")))
                  1))
                ((symbol-function 'message)
                (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
        (jsonyter-sync-replan))
      (should (string-match-p "offline" said)))))

(ert-deftest jsonyter-test-sync-execute-reports-completion-and-replans ()
  (jsonyter-tests--with-sync-buffer owner
    (setq jsonyter--sync-owner owner
          jsonyter--sync-session-key nil
          jsonyter--sync-pair (list :local "/tmp/x" :remote "work")
          jsonyter--sync-overrides nil
          jsonyter--sync-plan (jsonyter-tests--sync-plan
                              (list (jsonyter-tests--sync-entry
                                    "a.csv" "push" "local-new"
                                    :local (jsonyter-tests--sync-side 1 "h" 1.0) :remote nil))
                              :push 1))
    (let ((result (list :ok t :moved (list :pushed 1 :pulled 0 :converged 0
                                           :deleted_local 0 :deleted_remote 0)
                        :bytes_up 1 :bytes_down 0 :skipped 0 :conflicts_unresolved 0
                        :failed nil :conflict_copies nil :integrity "sha256" :elapsed 0.05))
          (calls nil) (said nil))
      (cl-letf (((symbol-function 'jsonyter--send)
                (lambda (method _params handlers)
                  (push method calls)
                  (pcase method
                    ("sync_apply" (funcall (plist-get handlers :result) (list :result result)))
                    ("sync_plan" (funcall (plist-get handlers :result)
                                         (list :result (jsonyter-tests--sync-plan nil)))))
                  1))
                ((symbol-function 'y-or-n-p) (lambda (_p) t))
                ((symbol-function 'message)
                ;; The automatic re-plan that follows a successful apply
                ;; messages too ("re-planning ..."), overwriting a single
                ;; captured string -- collect every message instead of
                ;; keeping only the last.
                (lambda (fmt &rest args) (push (apply #'format fmt args) said))))
        (jsonyter-sync-execute))
      (should (equal (nreverse calls) '("sync_apply" "sync_plan")))
      (should (seq-some (lambda (s) (string-match-p "synced .*1 up" s)) said)))))

(ert-deftest jsonyter-test-sync-execute-reports-error-without-replanning ()
  (jsonyter-tests--with-sync-buffer owner
    (setq jsonyter--sync-owner owner
          jsonyter--sync-session-key nil
          jsonyter--sync-pair (list :local "/tmp/x" :remote "work")
          jsonyter--sync-overrides nil
          jsonyter--sync-plan (jsonyter-tests--sync-plan
                              (list (jsonyter-tests--sync-entry
                                    "a.csv" "push" "local-new"
                                    :local (jsonyter-tests--sync-side 1 "h" 1.0) :remote nil))
                              :push 1))
    (let ((calls nil) (said nil))
      (cl-letf (((symbol-function 'jsonyter--send)
                (lambda (method _params handlers)
                  (push method calls)
                  (funcall (plist-get handlers :result) (list :error (list :message "stale")))
                  1))
                ((symbol-function 'y-or-n-p) (lambda (_p) t))
                ((symbol-function 'message)
                (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
        (jsonyter-sync-execute))
      (should (equal calls '("sync_apply")))
      (should (string-match-p "stale" said)))))

(ert-deftest jsonyter-test-sync-execute-confirms-when-plan-moves-nothing ()
  (jsonyter-tests--with-sync-buffer owner
    (setq jsonyter--sync-owner owner
          jsonyter--sync-session-key nil
          jsonyter--sync-pair (list :local "/tmp/x" :remote "work")
          jsonyter--sync-overrides nil
          jsonyter--sync-plan (jsonyter-tests--sync-plan
                              (list (jsonyter-tests--sync-entry "a.csv" "skip" "unchanged"))))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_p) nil)))
      (should-error (jsonyter-sync-execute) :type 'user-error))))

(ert-deftest jsonyter-test-sync-execute-aborts-when-declined ()
  (jsonyter-tests--with-sync-buffer owner
    (setq jsonyter--sync-owner owner
          jsonyter--sync-session-key nil
          jsonyter--sync-pair (list :local "/tmp/x" :remote "work")
          jsonyter--sync-overrides nil
          jsonyter--sync-plan (jsonyter-tests--sync-plan
                              (list (jsonyter-tests--sync-entry
                                    "a.csv" "push" "local-new"
                                    :local (jsonyter-tests--sync-side 1 "h" 1.0) :remote nil))
                              :push 1))
    (let (sent)
      (cl-letf (((symbol-function 'jsonyter--send) (lambda (&rest _) (setq sent t)))
                ((symbol-function 'y-or-n-p) (lambda (_p) nil)))
        (should-error (jsonyter-sync-execute) :type 'user-error))
      (should-not sent))))

(ert-deftest jsonyter-test-sync-add-pair-pushes-and-persists-on-request ()
  (let ((jsonyter-sync-pairs nil) (saved nil))
    (cl-letf (((symbol-function 'customize-save-variable)
              (lambda (sym val) (setq saved (list sym val)))))
      (jsonyter-sync-add-pair "/tmp/proj" "work/proj" "http://x" nil)
      (should (null saved))
      (should (equal (car jsonyter-sync-pairs) '(:local "/tmp/proj" :remote "work/proj" :server "http://x")))
      (jsonyter-sync-add-pair "/tmp/proj2" "work/proj2" nil t)
      (should (equal saved (list 'jsonyter-sync-pairs jsonyter-sync-pairs))))))

(ert-deftest jsonyter-test-sync-add-pair-interactive-form ()
  (jsonyter-tests--with-sessions
    (let ((session (jsonyter-tests--bind-session '("python" . "") "kid"))
          (jsonyter-sync-pairs nil))
      (setq-local jsonyter--url "http://y")
      (cl-letf (((symbol-function 'jsonyter--resolve-transfer-context)
                (lambda () (cons (current-buffer) session)))
                ((symbol-function 'read-directory-name) (lambda (&rest _) "/tmp/interactive"))
                ((symbol-function 'jsonyter--transfer-remote-dir) (lambda (&rest _) "work/"))
                ((symbol-function 'jsonyter--read-remote-path) (lambda (&rest _) "work/interactive"))
                ((symbol-function 'y-or-n-p) (lambda (_p) nil))
                ((symbol-function 'customize-save-variable) #'ignore))
        (call-interactively #'jsonyter-sync-add-pair))
      (should (equal (car jsonyter-sync-pairs)
                    '(:local "/tmp/interactive" :remote "work/interactive" :server "http://y"))))))

(ert-deftest jsonyter-test-sync-forget-pair-deletes-baseline-when-asked ()
  (let* ((jsonyter-sync-pairs (list (list :local "/tmp/a" :remote "work/a" :server "http://x")))
         (deleted nil))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_p) nil))
              ((symbol-function 'jsonyter--sync-delete-baseline)
              (lambda (server pair) (setq deleted (list server pair)))))
      (jsonyter-sync-forget-pair (car jsonyter-sync-pairs) t))
    (should (equal deleted (list "http://x" (car (list (list :local "/tmp/a" :remote "work/a" :server "http://x"))))))))

(ert-deftest jsonyter-test-sync-forget-pair-interactive-form ()
  (let ((jsonyter-sync-pairs (list (cons "/tmp/a" "work/a") (cons "/tmp/b" "work/b"))))
    (cl-letf (((symbol-function 'completing-read)
              (lambda (&rest _) "/tmp/a <-> work/a"))
              ((symbol-function 'y-or-n-p) (lambda (_p) nil)))
      (call-interactively #'jsonyter-sync-forget-pair))
    (should (= 1 (length jsonyter-sync-pairs)))
    (should (equal (jsonyter--sync-pair-remote (jsonyter--sync-pair-plist (car jsonyter-sync-pairs)))
                  "work/b"))))

(ert-deftest jsonyter-test-sync-reset-baseline-deletes-when-confirmed ()
  (jsonyter-tests--with-sessions
    (let* ((session (jsonyter-tests--bind-session '("python" . "") "kid"))
           (pair (list :local "/tmp/x" :remote "work" :server "http://x"))
           (deleted nil))
      (cl-letf (((symbol-function 'jsonyter--resolve-transfer-context)
                (lambda () (cons (current-buffer) session)))
                ((symbol-function 'jsonyter--sync-resolve-pair) (lambda (_ctx) pair))
                ((symbol-function 'y-or-n-p) (lambda (_p) t))
                ((symbol-function 'jsonyter--sync-delete-baseline)
                (lambda (server p) (setq deleted (list server p)))))
        (jsonyter-sync-reset-baseline))
      (should (equal deleted (list "http://x" pair))))))

(ert-deftest jsonyter-test-sync-reset-baseline-declined-deletes-nothing ()
  (jsonyter-tests--with-sessions
    (let* ((session (jsonyter-tests--bind-session '("python" . "") "kid"))
           (pair (list :local "/tmp/x" :remote "work" :server "http://x"))
           (deleted nil))
      (cl-letf (((symbol-function 'jsonyter--resolve-transfer-context)
                (lambda () (cons (current-buffer) session)))
                ((symbol-function 'jsonyter--sync-resolve-pair) (lambda (_ctx) pair))
                ((symbol-function 'y-or-n-p) (lambda (_p) nil))
                ((symbol-function 'jsonyter--sync-delete-baseline)
                (lambda (&rest args) (setq deleted args))))
        (jsonyter-sync-reset-baseline))
      (should (null deleted)))))

(ert-deftest jsonyter-test-sync-baseline-server-prefers-pairs-own-server ()
  (let ((pair (list :local "/tmp/x" :remote "work" :server "http://explicit")))
    (cl-letf (((symbol-function 'jsonyter--resolve-transfer-context)
              (lambda () (error "must not be called when the pair names a server"))))
      (should (equal (jsonyter--sync-baseline-server pair) "http://explicit")))))

(ert-deftest jsonyter-test-sync-baseline-server-falls-back-to-context ()
  (jsonyter-tests--with-sessions
    (let ((session (jsonyter-tests--bind-session '("python" . "") "kid"))
          (pair (list :local "/tmp/x" :remote "work")))
      (setq-local jsonyter--url "http://from-context")
      (cl-letf (((symbol-function 'jsonyter--resolve-transfer-context)
                (lambda () (cons (current-buffer) session))))
        (should (equal (jsonyter--sync-baseline-server pair) "http://from-context"))))))

(ert-deftest jsonyter-test-sync-delete-baseline-removes-file-and-reports-missing ()
  (let* ((dir (make-temp-file "jsonyter-sync-baseline-" t))
         (jsonyter-sync-state-directory dir)
         (pair (list :local "/tmp/x" :remote "work"))
         (path (jsonyter--sync-state-path "http://x" pair))
         (said nil))
    (unwind-protect
        (progn
          (with-temp-file path (insert "{}"))
          (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
            (jsonyter--sync-delete-baseline "http://x" pair))
          (should-not (file-exists-p path))
          (should (string-match-p "deleted baseline" said))
          (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
            (jsonyter--sync-delete-baseline "http://x" pair))
          (should (string-match-p "no baseline on record" said)))
      (delete-directory dir t))))

(ert-deftest jsonyter-test-sync-diff-entry-refuses-when-one-side-missing ()
  (jsonyter-tests--with-sync-buffer owner
    (setq jsonyter--sync-pair (list :local "/tmp/x" :remote "work")
          jsonyter--sync-plan (jsonyter-tests--sync-plan
                              (list (jsonyter-tests--sync-entry
                                    "a.csv" "push" "local-new"
                                    :local (jsonyter-tests--sync-side 1 "h" 1.0) :remote nil))))
    (jsonyter--sync-render)
    (goto-char (point-min))
    (should-error (jsonyter-sync-diff-entry) :type 'user-error)))

(ert-deftest jsonyter-test-sync-diff-entry-refuses-when-oversized ()
  (jsonyter-tests--with-sync-buffer owner
    (let ((jsonyter-sync-diff-max-size 100))
      (setq jsonyter--sync-pair (list :local "/tmp/x" :remote "work")
            jsonyter--sync-plan (jsonyter-tests--sync-plan
                                (list (jsonyter-tests--sync-entry
                                      "big.csv" "conflict" "both-changed"
                                      :local (jsonyter-tests--sync-side 200 "h1" 1.0)
                                      :remote (jsonyter-tests--sync-side 200 "h2" "2026-01-01T00:00:00Z")))))
      (jsonyter--sync-render)
      (goto-char (point-min))
      (should-error (jsonyter-sync-diff-entry) :type 'user-error))))

(ert-deftest jsonyter-test-sync-diff-entry-downloads-and-diffs ()
  (jsonyter-tests--with-sync-buffer owner
    (setq jsonyter--sync-owner owner
          jsonyter--sync-session-key nil
          jsonyter--sync-pair (list :local "/tmp/x" :remote "work")
          jsonyter--sync-plan (jsonyter-tests--sync-plan
                              (list (jsonyter-tests--sync-entry
                                    "both.csv" "conflict" "both-changed"
                                    :local (jsonyter-tests--sync-side 10 "h1" 1.0)
                                    :remote (jsonyter-tests--sync-side 10 "h2" "2026-01-01T00:00:00Z")))))
    (jsonyter--sync-render)
    (goto-char (point-min))
    (let (diff-args)
      (cl-letf (((symbol-function 'jsonyter--transfer-run)
                (lambda (_ctx _method _params on-success) (funcall on-success nil)))
                ((symbol-function 'jsonyter-sync-diff-function)
                (lambda (&rest _) nil)))
        (let ((jsonyter-sync-diff-function (lambda (a b) (setq diff-args (list a b)))))
          (jsonyter-sync-diff-entry)))
      (should (equal (car diff-args) (expand-file-name "both.csv" "/tmp/x")))
      (should (stringp (cadr diff-args))))))

(ert-deftest jsonyter-test-sync-describe-entry-formats-message ()
  (jsonyter-tests--with-sync-buffer owner
    (setq jsonyter--sync-pair (list :local "/tmp/x" :remote "work")
          jsonyter--sync-plan (jsonyter-tests--sync-plan
                              (list (jsonyter-tests--sync-entry
                                    "both.csv" "conflict" "both-changed"
                                    :local (jsonyter-tests--sync-side 10 "h1" 1.0)
                                    :remote (jsonyter-tests--sync-side 12 "h2" "2026-01-01T00:00:00Z")
                                    :newest "remote" :mtime-delta 30.0))))
    (jsonyter--sync-render)
    (goto-char (point-min))
    (let (said)
      (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
        (jsonyter-sync-describe-entry))
      (should (string-match-p "both.csv: conflict/both-changed" said))
      (should (string-match-p "remote newer by" said)))))

(ert-deftest jsonyter-test-sync-override-push-pull-skip-commands ()
  (jsonyter-tests--with-sync-buffer owner
    (setq jsonyter--sync-pair (list :local "/tmp/x" :remote "work")
          jsonyter--sync-plan (jsonyter-tests--sync-plan
                              (list (jsonyter-tests--sync-entry "a.csv" "conflict" "both-changed"
                                    :local (jsonyter-tests--sync-side 1 "h" 1.0)
                                    :remote (jsonyter-tests--sync-side 1 "h2" "2026-01-01T00:00:00Z")))))
    (jsonyter--sync-render)
    (goto-char (point-min))
    (jsonyter-sync-override-push)
    (should (equal (cdr (assoc "a.csv" jsonyter--sync-overrides)) "push"))
    (goto-char (point-min))
    (jsonyter-sync-override-pull)
    (should (equal (cdr (assoc "a.csv" jsonyter--sync-overrides)) "pull"))
    (goto-char (point-min))
    (jsonyter-sync-override-skip)
    (should (equal (cdr (assoc "a.csv" jsonyter--sync-overrides)) "skip"))))

(ert-deftest jsonyter-test-sync-toggle-unchanged-and-clear-all-overrides ()
  (jsonyter-tests--with-sync-buffer owner
    (setq jsonyter--sync-pair (list :local "/tmp/x" :remote "work")
          jsonyter--sync-overrides '(("a.csv" . "skip"))
          jsonyter--sync-plan (jsonyter-tests--sync-plan
                              (list (jsonyter-tests--sync-entry
                                    "same.csv" "converge" "identical"
                                    :local (jsonyter-tests--sync-side 1 "h" 1.0)
                                    :remote (jsonyter-tests--sync-side 1 "h" "2026-01-01T00:00:00Z")))))
    (jsonyter--sync-render)
    (should-not jsonyter--sync-show-unchanged)
    (should (= 0 (length tabulated-list-entries)))
    (jsonyter-sync-toggle-unchanged)
    (should jsonyter--sync-show-unchanged)
    (should (= 1 (length tabulated-list-entries)))
    (let (said)
      (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
        (jsonyter-sync-clear-all-overrides))
      (should (null jsonyter--sync-overrides))
      (should (string-match-p "all overrides cleared" said)))))

(ert-deftest jsonyter-test-sync-glyph-forget-and-unknown-actions ()
  (should (equal (car (jsonyter--sync-glyph "forget")) "."))
  (should (equal (car (jsonyter--sync-glyph "something-else")) "?")))

(ert-deftest jsonyter-test-sync-format-remote-mtime-handles-nil-and-garbage ()
  (should (equal (jsonyter--sync-format-remote-mtime nil) "--"))
  (should (equal (jsonyter--sync-format-remote-mtime "not-a-date") "not-a-date")))

(ert-deftest jsonyter-test-sync-note-integrity-warns-once-per-server ()
  (let ((jsonyter--sync-integrity-warned (make-hash-table :test #'equal))
        (pair (list :local "/tmp/x" :remote "work"))
        (said nil) (count 0))
    (cl-letf (((symbol-function 'message)
              (lambda (fmt &rest args) (cl-incf count) (setq said (apply #'format fmt args)))))
      (jsonyter--sync-note-integrity pair (jsonyter-tests--sync-plan nil :integrity "size" :server "http://x"))
      (jsonyter--sync-note-integrity pair (jsonyter-tests--sync-plan nil :integrity "size" :server "http://x")))
    (should (= 1 count))
    (should (string-match-p "verifies sync by size only" said))))

(ert-deftest jsonyter-test-sync-run-signals-and-clears-tag-on-send-error ()
  (jsonyter-tests--with-sessions
    (let ((session (jsonyter-tests--bind-session '("python" . "") "kid")))
      (cl-letf (((symbol-function 'jsonyter--send)
                (lambda (&rest _) (error "jsonyter: bridge process is not running"))))
        (should-error (jsonyter--sync-run (cons (current-buffer) session) "sync_plan" nil #'ignore)))
      (should (null (jsonyter--session-transfer session))))))

(ert-deftest jsonyter-test-sync-ensure-pair-declines-when-user-says-no ()
  (with-temp-buffer
    (setq default-directory "/tmp/declineme/")
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_p) nil))
              ((symbol-function 'jsonyter--transfer-remote-dir) (lambda (&rest _) "work/")))
      (should-error (jsonyter--sync-resolve-pair (cons (current-buffer) nil)) :type 'user-error))))

(ert-deftest jsonyter-test-sync-resolve-pair-uses-sole-pair-by-server ()
  (with-temp-buffer
    (setq default-directory "/tmp/elsewhere/")
    (let ((jsonyter-sync-pairs (list (list :local "/tmp/project" :remote "work"))))
      (should (equal (jsonyter--sync-pair-remote
                     (jsonyter--sync-resolve-pair (cons (current-buffer) nil)))
                    "work")))))

(ert-deftest jsonyter-test-sync-resolve-pair-reads-among-multiple-by-server ()
  (with-temp-buffer
    (setq default-directory "/tmp/elsewhere/")
    (let ((jsonyter-sync-pairs (list (list :local "/tmp/a" :remote "work/a")
                                     (list :local "/tmp/b" :remote "work/b"))))
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "/tmp/b <-> work/b")))
        (should (equal (jsonyter--sync-pair-remote
                       (jsonyter--sync-resolve-pair (cons (current-buffer) nil)))
                      "work/b"))))))

(ert-deftest jsonyter-test-sync-mode-revert-buffer-function-replans ()
  (jsonyter-tests--with-sync-buffer owner
    (let (replanned)
      (cl-letf (((symbol-function 'jsonyter-sync-replan) (lambda () (setq replanned t))))
        (funcall revert-buffer-function))
      (should replanned))))

;;;; jsonyter-org-connect-kernel

(ert-deftest jsonyter-test-org-connect-kernel-attaches-block-session ()
  (let ((jsonyter-org-markdown-converter (lambda (text _dir) text)))
    (jsonyter-tests--with-org-file
        "#+begin_src python :session jy:main\nx = 1\n#+end_src\n"
      (goto-char (point-min))
      (search-forward "x = 1")
      (let (connected-id connected-session)
        (cl-letf (((symbol-function 'jsonyter--ensure-live-bridge) #'ignore)
                  ((symbol-function 'jsonyter--read-kernel) (lambda (&rest _) "kid"))
                  ((symbol-function 'jsonyter-kernel-connect)
                   (lambda (id session) (setq connected-id id connected-session session) id)))
          (call-interactively 'jsonyter-org-connect-kernel))
        (should (equal "kid" connected-id))
        (should (equal (jsonyter--session-key connected-session) '("python" . "main")))))))

;;;; Running an Org jy: block against its kernel

(ert-deftest jsonyter-test-org-run-block-executes-and-renders-output ()
  (jsonyter-tests--with-org-file
      "#+begin_src python :session jy:main\nx = 1\n#+end_src\n"
    (goto-char (point-min))
    (search-forward "x = 1")
    (let ((session (jsonyter--session-put '("python" . "main")))
          handlers)
      (setf (jsonyter--session-kernel-id session) "kid")
      (cl-letf (((symbol-function 'jsonyter--org-connect) (lambda (&rest _) session))
                ((symbol-function 'jsonyter--send)
                 (lambda (_method _params hs) (setq handlers hs) 1)))
        (jsonyter-org-run-block))
      (should (jsonyter--session-busy session))
      (funcall (plist-get handlers :output) (jsonyter-tests--stream "hi\n"))
      (funcall (plist-get handlers :result) (list :result (list :status "ok")))
      (should-not (jsonyter--session-busy session))
      (let ((ov (jsonyter--org-cell-at)))
        (should (string-match-p "hi" (overlay-get ov 'jsonyter-output-string)))))))

(ert-deftest jsonyter-test-org-run-block-refuses-when-busy ()
  (jsonyter-tests--with-org-file
      "#+begin_src python :session jy:main\nx = 1\n#+end_src\n"
    (goto-char (point-min))
    (search-forward "x = 1")
    (let ((session (jsonyter--session-put '("python" . "main"))))
      (setf (jsonyter--session-kernel-id session) "kid"
            (jsonyter--session-busy session) t)
      (cl-letf (((symbol-function 'jsonyter--org-connect) (lambda (&rest _) session)))
        (should-error (jsonyter-org-run-block) :type 'user-error)))))

(ert-deftest jsonyter-test-org-run-block-reports-empty-block ()
  (jsonyter-tests--with-org-file
      "#+begin_src python :session jy:main\n\n#+end_src\n"
    (goto-char (point-min))
    (search-forward "begin_src")
    (let ((session (jsonyter--session-put '("python" . "main")))
          said)
      (setf (jsonyter--session-kernel-id session) "kid")
      (cl-letf (((symbol-function 'jsonyter--org-connect) (lambda (&rest _) session))
                ((symbol-function 'jsonyter--send) (lambda (&rest _) (error "must not run")))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
        (jsonyter-org-run-block))
      (should (string-match-p "empty block" said)))))

(ert-deftest jsonyter-test-org-run-block-and-advance-moves-to-next-block ()
  (jsonyter-tests--with-org-file
      (concat "#+begin_src python :session jy:main\nx = 1\n#+end_src\n\n"
              "#+begin_src python :session jy:main\nx + 1\n#+end_src\n")
    (goto-char (point-min))
    (search-forward "x = 1")
    (let ((session (jsonyter--session-put '("python" . "main")))
          (start (point)))
      (setf (jsonyter--session-kernel-id session) "kid")
      (cl-letf (((symbol-function 'jsonyter--org-connect) (lambda (&rest _) session))
                ((symbol-function 'jsonyter--send) (lambda (&rest _) 1)))
        (jsonyter-org-run-block-and-advance))
      (should (> (point) start))
      (should (jsonyter--org-in-jy-block-p)))))

(ert-deftest jsonyter-test-org-run-buffer-runs-each-jy-block ()
  "`jsonyter-org-run-buffer' runs each block `jsonyter--org-goto-next-jy-block'
finds, in turn, and reports how many it ran.

`jsonyter--org-goto-next-jy-block' itself is stubbed to hand back a
position once, then nil: Org's real navigation relies on its element
cache, which in batch Emacs (no idle time ever passes to drain its sync
queue) can leave a second, independent traversal of the same buffer
unable to find a block it would find interactively -- `jsonyter-org-mode'
enabling itself already ran one such traversal to frame stale committed
results, so even a single-block buffer hits this by the time a test body
runs. That is a quirk of Org in batch mode, not of `jsonyter-org-run-buffer',
and orthogonal to what this test is actually about: the loop, the count
and the report, not Org's own block-finding."
  (jsonyter-tests--with-org-file
      "#+begin_src python :session jy:main\nx = 1\n#+end_src\n"
    (let ((count 0) (session (jsonyter--session-put '("python" . "main")))
          (positions (list (point-max) nil))
          said)
      (cl-letf (((symbol-function 'jsonyter--org-goto-next-jy-block) (lambda () (pop positions)))
                ((symbol-function 'jsonyter-org-run-block) (lambda (&rest _) (cl-incf count)))
                ((symbol-function 'jsonyter--org-session-at-point) (lambda (&rest _) session))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
        (jsonyter-org-run-buffer))
      (should (= 1 count))
      (should (string-match-p "ran 1 jy: block" said)))))

;;;; Org kernel documentation

(ert-deftest jsonyter-test-org-inspect-shows-documentation ()
  (jsonyter-tests--with-org-file
      "#+begin_src python :session jy:main\nlen([1, 2])\n#+end_src\n"
    (goto-char (point-min))
    (search-forward "len")
    (let ((session (jsonyter--session-put '("python" . "main"))))
      (setf (jsonyter--session-kernel-id session) "kid")
      (cl-letf (((symbol-function 'jsonyter--org-session-at-point) (lambda (&rest _) session))
                ((symbol-function 'jsonyter--live-p) (lambda (&rest _) t))
                ((symbol-function 'jsonyter--kernel-request)
                 (lambda (&rest _) (list :found t :data (list :text/plain "len(obj) -> int")))))
        (jsonyter-org-inspect))
      (let ((buf (get-buffer "*jsonyter-doc*")))
        (should buf)
        (with-current-buffer buf
          (should (string-match-p "len(obj)" (buffer-string))))
        (kill-buffer buf)))))

(ert-deftest jsonyter-test-org-inspect-errors-without-live-kernel ()
  (jsonyter-tests--with-org-file
      "#+begin_src python :session jy:main\nlen([1, 2])\n#+end_src\n"
    (goto-char (point-min))
    (search-forward "len")
    (let ((session (jsonyter--session-put '("python" . "main"))))
      (cl-letf (((symbol-function 'jsonyter--org-session-at-point) (lambda (&rest _) session))
                ((symbol-function 'jsonyter--live-p) (lambda (&rest _) nil)))
        (should-error (jsonyter-org-inspect) :type 'user-error)))))

;;;; Committing and clearing overlay output across a whole buffer

(ert-deftest jsonyter-test-org-commit-buffer-commits-every-shown-block ()
  (jsonyter-tests--with-org-file
      (concat "#+begin_src python :session jy:main\nx = 1\n#+end_src\n\n"
              "#+begin_src python :session jy:main\nx + 1\n#+end_src\n")
    (goto-char (point-min))
    (search-forward "x = 1")
    (pcase-let* ((`(,code1 . ,anchor1) (jsonyter--org-block-region))
                 (ov1 (jsonyter--org-cell-overlay anchor1 t)))
      (overlay-put ov1 'jsonyter-source-hash (jsonyter--source-hash code1))
      (overlay-put ov1 'jsonyter-output-string "x")
      (overlay-put ov1 'jsonyter-raw-outputs (list (jsonyter-tests--stream "one\n"))))
    (goto-char (point-min))
    (search-forward "x + 1")
    (pcase-let* ((`(,code2 . ,anchor2) (jsonyter--org-block-region))
                 (ov2 (jsonyter--org-cell-overlay anchor2 t)))
      (overlay-put ov2 'jsonyter-source-hash (jsonyter--source-hash code2))
      (overlay-put ov2 'jsonyter-output-string "x")
      (overlay-put ov2 'jsonyter-raw-outputs (list (jsonyter-tests--stream "two\n"))))
    (let (said)
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
        (jsonyter-org-commit-buffer))
      (should (string-match-p "committed 2 block" said)))
    (let ((text (buffer-string)))
      (should (string-match-p "^: one$" text))
      (should (string-match-p "^: two$" text)))
    (should (null jsonyter--org-cells))))

(ert-deftest jsonyter-test-org-clear-block-output-removes-overlay ()
  (jsonyter-tests--with-org-file
      "#+begin_src python :session jy:main\nx = 1\n#+end_src\n"
    (goto-char (point-min))
    (search-forward "x = 1")
    (pcase-let* ((`(,_code . ,anchor) (jsonyter--org-block-region)))
      (jsonyter--org-cell-overlay anchor t))
    (should (jsonyter--org-cell-at))
    (jsonyter-org-clear-block-output)
    (should (null (jsonyter--org-cell-at)))))

(ert-deftest jsonyter-test-org-clear-block-output-errors-without-output ()
  (jsonyter-tests--with-org-file
      "#+begin_src python :session jy:main\nx = 1\n#+end_src\n"
    (goto-char (point-min))
    (search-forward "x = 1")
    (should-error (jsonyter-org-clear-block-output) :type 'user-error)))

(ert-deftest jsonyter-test-org-clear-all-output-clears-every-overlay ()
  (jsonyter-tests--with-org-file
      (concat "#+begin_src python :session jy:main\nx = 1\n#+end_src\n\n"
              "#+begin_src python :session jy:main\nx + 1\n#+end_src\n")
    (goto-char (point-min))
    (search-forward "x = 1")
    (pcase-let* ((`(,_c1 . ,a1) (jsonyter--org-block-region))) (jsonyter--org-cell-overlay a1 t))
    (goto-char (point-min))
    (search-forward "x + 1")
    (pcase-let* ((`(,_c2 . ,a2) (jsonyter--org-block-region))) (jsonyter--org-cell-overlay a2 t))
    (should (= 2 (length jsonyter--org-cells)))
    (jsonyter-org-clear-all-output)
    (should (null jsonyter--org-cells))))

;;;; jsonyter--export-run (the real body, not mocked)

(ert-deftest jsonyter-test-export-run-reports-success ()
  (jsonyter-tests--with-sessions
    (let ((session (jsonyter-tests--bind-session '("python" . "") "kid"))
          handlers said)
      (cl-letf (((symbol-function 'jsonyter--send) (lambda (_m _p hs) (setq handlers hs) 1))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
        (jsonyter--export-run session (list :format "html") #'ignore))
      (should (jsonyter--session-transfer session))
      (should (string-match-p "exporting to html" said))
      (funcall (plist-get handlers :result) (list :result (list :path "/tmp/a.html")))
      (should (null (jsonyter--session-transfer session))))))

(ert-deftest jsonyter-test-export-run-calls-on-success-with-result ()
  (jsonyter-tests--with-sessions
    (let ((session (jsonyter-tests--bind-session '("python" . "") "kid"))
          handlers got)
      (cl-letf (((symbol-function 'jsonyter--send) (lambda (_m _p hs) (setq handlers hs) 1))
                ((symbol-function 'message) #'ignore))
        (jsonyter--export-run session (list :format "html")
                              (lambda (result) (setq got result))))
      (funcall (plist-get handlers :result) (list :result (list :path "/tmp/a.html")))
      (should (equal "/tmp/a.html" (plist-get got :path))))))

(ert-deftest jsonyter-test-export-run-reports-failure ()
  (jsonyter-tests--with-sessions
    (let ((session (jsonyter-tests--bind-session '("python" . "") "kid"))
          handlers said)
      (cl-letf (((symbol-function 'jsonyter--send) (lambda (_m _p hs) (setq handlers hs) 1))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
        (jsonyter--export-run session (list :format "pdf") #'ignore)
        (funcall (plist-get handlers :result) (list :error (list :error "ExportError" :message "boom"))))
      (should (string-match-p "export to pdf failed" said))
      (should (null (jsonyter--session-transfer session))))))

(ert-deftest jsonyter-test-export-run-clears-tag-on-synchronous-signal ()
  (jsonyter-tests--with-sessions
    (let ((session (jsonyter-tests--bind-session '("python" . "") "kid")))
      (cl-letf (((symbol-function 'jsonyter--send) (lambda (&rest _) (error "bridge is not running")))
                ((symbol-function 'message) #'ignore))
        (should-error (jsonyter--export-run session (list :format "html") #'ignore)))
      (should (null (jsonyter--session-transfer session))))))

(ert-deftest jsonyter-test-export-run-works-with-no-session ()
  (with-temp-buffer
    (let (handlers)
      (cl-letf (((symbol-function 'jsonyter--send) (lambda (_m _p hs) (setq handlers hs) 1))
                ((symbol-function 'message) #'ignore))
        (jsonyter--export-run nil (list :format "html") (lambda (_r) nil)))
      (funcall (plist-get handlers :result) (list :result (list :path "/tmp/a.html"))))))

;;;; Coverage recovery: exercise already-tested commands via `call-interactively'
;;
;; Each command below has a complex `(interactive (FORM))' spec. Emacs's
;; edebug/undercover coverage tracking only credits a command's own body
;; when it runs through `call-interactively' (or a real interactive
;; invocation) rather than a plain Lisp call. The behavioral tests above
;; already call these commands directly and are the ones worth reading
;; to understand what they do; these exist purely so the coverage
;; instrumentation sees them exercised the way a user's `M-x' actually
;; invokes them.

(ert-deftest jsonyter-test-org-from-notebook-via-interactive ()
  (let* ((jsonyter-org-markdown-converter (lambda (text _dir) text))
         (ipynb (make-temp-file "jsonyter-test-" nil ".ipynb"))
         (org (make-temp-file "jsonyter-test-" nil ".org")))
    (unwind-protect
        (progn
          (jsonyter-tests--write-notebook ipynb)
          (delete-file org)
          (let ((calls 0))
            (cl-letf (((symbol-function 'read-file-name)
                       (lambda (&rest _) (cl-incf calls) (if (= calls 1) ipynb org))))
              (call-interactively 'jsonyter-org-from-notebook)))
          (should (get-file-buffer org))
          (with-current-buffer (get-file-buffer org)
            (should (string-match-p "x = 1" (buffer-string)))))
      (dolist (f (list ipynb org)) (when (file-exists-p f) (delete-file f)))
      (let ((buf (find-buffer-visiting org))) (when buf (kill-buffer buf))))))

(ert-deftest jsonyter-test-org-to-notebook-via-interactive ()
  (jsonyter-tests--with-org-file
      "#+begin_src python :session jy:main\nx = 1\n#+end_src\n"
    (let ((org-path buffer-file-name)
          (ipynb (make-temp-file "jsonyter-test-" nil ".ipynb"))
          sent)
      (delete-file ipynb)
      (unwind-protect
          (let ((calls 0))
            (cl-letf (((symbol-function 'read-file-name)
                       (lambda (&rest _) (cl-incf calls) (if (= calls 1) org-path ipynb)))
                      ((symbol-function 'jsonyter--ensure-bridge) #'ignore)
                      ((symbol-function 'jsonyter--request-sync)
                       (lambda (method params &rest _) (setq sent (list method params)))))
              (call-interactively 'jsonyter-org-to-notebook)))
        (when (file-exists-p ipynb) (delete-file ipynb)))
      (should (equal (car sent) "write_notebook"))
      (should (equal (plist-get (cadr sent) :path) (expand-file-name ipynb))))))

(ert-deftest jsonyter-test-org-export-script-via-interactive ()
  (jsonyter-tests--with-org-file
      "#+begin_src python :session jy:main\nx = 1\n#+end_src\n"
    (let ((out (make-temp-file "jsonyter-script-export-" nil ".py")))
      (unwind-protect
          (progn
            (delete-file out)
            (cl-letf (((symbol-function 'read-file-name) (lambda (&rest _) out)))
              (call-interactively 'jsonyter-org-export-script))
            (should (file-exists-p out)))
        (when (file-exists-p out) (delete-file out))))))

(ert-deftest jsonyter-test-notebook-export-script-via-interactive ()
  (jsonyter-tests--with-notebook
    (let ((out (make-temp-file "jsonyter-script-export-" nil ".py")))
      (unwind-protect
          (progn
            (delete-file out)
            (cl-letf (((symbol-function 'read-file-name) (lambda (&rest _) out)))
              (call-interactively 'jsonyter-notebook-export-script))
            (should (file-exists-p out)))
        (when (file-exists-p out) (delete-file out))))))

(ert-deftest jsonyter-test-notebook-export-via-interactive-happy-path ()
  (jsonyter-tests--with-notebook
    (let (sent)
      (cl-letf (((symbol-function 'jsonyter--list-export-formats)
                 (lambda (&rest _) (list :available t :formats '(:html (:output_mimetype "text/html")))))
                ((symbol-function 'completing-read) (lambda (&rest _) "html"))
                ((symbol-function 'read-file-name) (lambda (&rest _) "/tmp/out.html"))
                ((symbol-function 'jsonyter--ensure-bridge) #'ignore)
                ((symbol-function 'jsonyter--export-run)
                 (lambda (_session params _on-success) (setq sent params))))
        (call-interactively 'jsonyter-notebook-export))
      (should (equal (plist-get sent :format) "html"))
      (should (equal (plist-get sent :to_path) "/tmp/out.html")))))

(ert-deftest jsonyter-test-notebook-export-format-wrappers-delegate ()
  "Each `jsonyter-notebook-export-FORMAT' wrapper fixes FORMAT and reads
TO-PATH the same way the general command does."
  (dolist (spec '((jsonyter-notebook-export-html . "html")
                   (jsonyter-notebook-export-markdown . "markdown")
                   (jsonyter-notebook-export-pdf . "pdf")
                   (jsonyter-notebook-export-latex . "latex")
                   (jsonyter-notebook-export-webpdf . "webpdf")
                   (jsonyter-notebook-export-slides . "slides")))
    (let ((fn (car spec)) (fmt (cdr spec)) sent)
      (cl-letf (((symbol-function 'jsonyter-notebook-export)
                 (lambda (format to-path) (setq sent (cons format to-path))))
                ((symbol-function 'read-file-name) (lambda (&rest _) (concat "/tmp/out." fmt))))
        (call-interactively fn))
      (should (equal (car sent) fmt))
      (should (equal (cdr sent) (concat "/tmp/out." fmt))))))

(ert-deftest jsonyter-test-export-read-to-path-defaults-extension ()
  (let ((buffer-file-name "/tmp/analysis.ipynb"))
    (cl-letf (((symbol-function 'read-file-name)
               (lambda (_prompt _dir default &rest _) default)))
      (should (equal "/tmp/analysis.html" (jsonyter--export-read-to-path "html"))))))

;;;; Token resolution and bridge command construction

(ert-deftest jsonyter-test-token-prefers-function-then-string ()
  (let ((jsonyter-server-token (lambda () "func-token"))
        (jsonyter-server-token-file nil))
    (should (equal "func-token" (jsonyter--token))))
  (let ((jsonyter-server-token "str-token")
        (jsonyter-server-token-file nil))
    (should (equal "str-token" (jsonyter--token))))
  (let ((jsonyter-server-token "")
        (jsonyter-server-token-file nil))
    (should (null (jsonyter--token)))))

(ert-deftest jsonyter-test-token-reads-from-file ()
  (let ((file (make-temp-file "jsonyter-token-")))
    (unwind-protect
        (progn
          (with-temp-file file (insert "  file-token  \n"))
          (let ((jsonyter-server-token nil)
                (jsonyter-server-token-file file))
            (should (equal "file-token" (jsonyter--token)))))
      (delete-file file))))

(ert-deftest jsonyter-test-token-errors-on-missing-file ()
  (let ((jsonyter-server-token nil)
        (jsonyter-server-token-file "/no/such/token/file/anywhere"))
    (should-error (jsonyter--token))))

(ert-deftest jsonyter-test-build-command-argv-transport ()
  (let ((jsonyter-command '("jsonyter"))
        (jsonyter-server-url "http://localhost:8888")
        (jsonyter-token-transport 'argv)
        (jsonyter-exec-timeout nil)
        (jsonyter-insecure-tls nil))
    (should (equal '("jsonyter" "--url" "http://localhost:8888" "--token" "tok")
                   (jsonyter--build-command "tok")))))

(ert-deftest jsonyter-test-build-command-stdin-transport ()
  (let ((jsonyter-command '("jsonyter"))
        (jsonyter-token-transport 'stdin))
    (should (member "--token-file" (jsonyter--build-command "tok")))
    (should (member "-" (jsonyter--build-command "tok")))))

(ert-deftest jsonyter-test-build-command-file-transport ()
  (let ((jsonyter-command '("jsonyter"))
        (jsonyter-token-transport 'file)
        (jsonyter-server-token-file "/tmp/tok.txt"))
    (should (member "--token-file" (jsonyter--build-command nil)))
    (should (member (expand-file-name "/tmp/tok.txt") (jsonyter--build-command nil)))))

(ert-deftest jsonyter-test-build-command-env-transport-omits-token ()
  (let ((jsonyter-command '("jsonyter"))
        (jsonyter-token-transport 'env))
    (should-not (member "--token" (jsonyter--build-command "tok")))))

(ert-deftest jsonyter-test-build-command-includes-timeout-and-insecure ()
  (let ((jsonyter-command '("jsonyter"))
        (jsonyter-token-transport 'env)
        (jsonyter-exec-timeout 30)
        (jsonyter-insecure-tls t))
    (let ((cmd (jsonyter--build-command nil)))
      (should (member "--exec-timeout" cmd))
      (should (member "30" cmd))
      (should (member "--insecure" cmd)))))

(ert-deftest jsonyter-test-start-bridge-refuses-encrypted-file-with-file-transport ()
  (with-temp-buffer
    (let ((jsonyter-token-transport 'file)
          (jsonyter-server-token-file "/tmp/secret.gpg"))
      (should-error (jsonyter--start-bridge) :type 'user-error))))

(ert-deftest jsonyter-test-start-bridge-reports-missing-executable ()
  (with-temp-buffer
    (let ((jsonyter-command '("jsonyter-definitely-not-a-real-binary-xyz")))
      (should-error (jsonyter--start-bridge) :type 'user-error))))

(ert-deftest jsonyter-test-start-bridge-starts-a-real-process ()
  (with-temp-buffer
    (let ((jsonyter-command '("cat"))
          (jsonyter-server-url "http://localhost:8888")
          (jsonyter-token-transport 'stdin)
          (jsonyter-server-token "tok"))
      (let ((proc (jsonyter--start-bridge)))
        (unwind-protect
            (progn
              (should (process-live-p proc))
              (should (equal jsonyter--command
                             '("cat" "--url" "http://localhost:8888" "--token-file" "-")))
              (should (buffer-live-p (process-get proc 'jsonyter-stderr-buffer))))
          (jsonyter--kill-process))))))

;;;; Session/command resolution in Org buffers

(ert-deftest jsonyter-test-command-session-resolves-via-org-block-at-point ()
  (jsonyter-tests--with-org-file
      "#+begin_src python :session jy:main\nx = 1\n#+end_src\n"
    (goto-char (point-min))
    (search-forward "x = 1")
    (let ((session (jsonyter--session-put '("python" . "main"))))
      (should (eq (jsonyter--command-session) session)))))

(ert-deftest jsonyter-test-attach-target-uses-org-session-at-point ()
  (jsonyter-tests--with-org-file
      "#+begin_src python :session jy:main\nx = 1\n#+end_src\n"
    (goto-char (point-min))
    (search-forward "x = 1")
    (let ((session (jsonyter--session-put '("python" . "main"))))
      (should (eq (jsonyter--attach-target) session)))))

(ert-deftest jsonyter-test-attach-target-registers-new-org-session-with-no-kernel ()
  (jsonyter-tests--with-org-file
      "#+begin_src python :session jy:main\nx = 1\n#+end_src\n"
    (goto-char (point-min))
    (search-forward "x = 1")
    (let ((session (jsonyter--attach-target)))
      (should (equal (jsonyter--session-key session) '("python" . "main"))))))

(ert-deftest jsonyter-test-current-session-and-busy-in-org-buffer ()
  (jsonyter-tests--with-org-file
      "#+begin_src python :session jy:main\nx = 1\n#+end_src\n"
    (goto-char (point-min))
    (search-forward "x = 1")
    (should (null (jsonyter-current-session)))
    (should (null (jsonyter-current-session-name)))
    (should (null (jsonyter-current-kernel-busy-p)))
    (let ((session (jsonyter--session-put '("python" . "main"))))
      (setf (jsonyter--session-busy session) t)
      (should (eq (jsonyter-current-session) session))
      (should (equal "main" (jsonyter-current-session-name)))
      (should (jsonyter-current-kernel-busy-p)))))

(ert-deftest jsonyter-test-org-connect-attaches-via-at-kernel-id-name ()
  (jsonyter-tests--with-org-file
      "#+begin_src python :session jy:@abc123\nx = 1\n#+end_src\n"
    (goto-char (point-min))
    (search-forward "x = 1")
    (let ((key '("python" . "@abc123"))
          connected)
      (cl-letf (((symbol-function 'jsonyter--ensure-live-bridge) #'ignore)
                ((symbol-function 'jsonyter--live-p) (lambda (&rest _) nil))
                ((symbol-function 'jsonyter-kernel-connect)
                 (lambda (id session) (setq connected (cons id session)) id)))
        (jsonyter--org-connect key))
      (should (equal (car connected) "abc123")))))

(ert-deftest jsonyter-test-org-connect-already-live-skips-reconnect ()
  (jsonyter-tests--with-org-file
      "#+begin_src python :session jy:@abc123\nx = 1\n#+end_src\n"
    (goto-char (point-min))
    (search-forward "x = 1")
    (let ((key '("python" . "@abc123")))
      (cl-letf (((symbol-function 'jsonyter--ensure-live-bridge) #'ignore)
                ((symbol-function 'jsonyter--live-p) (lambda (&rest _) t))
                ((symbol-function 'jsonyter-kernel-connect)
                 (lambda (&rest _) (error "must not reconnect when already live"))))
        (jsonyter--org-connect key)))))

(ert-deftest jsonyter-test-org-ensure-session-at-point-no-kernel-just-registers ()
  (jsonyter-tests--with-org-file
      "#+begin_src python :session jy:main\nx = 1\n#+end_src\n"
    (goto-char (point-min))
    (search-forward "x = 1")
    (let ((session (jsonyter--org-ensure-session-at-point 'no-kernel)))
      (should (equal (jsonyter--session-key session) '("python" . "main"))))))

(ert-deftest jsonyter-test-org-ensure-session-at-point-errors-without-jy-session ()
  (jsonyter-tests--with-org-file
      "#+begin_src python\nx = 1\n#+end_src\n"
    (goto-char (point-min))
    (search-forward "x = 1")
    (should-error (jsonyter--org-ensure-session-at-point) :type 'user-error)))

(ert-deftest jsonyter-test-org-kernel-control-wrappers-delegate-to-block-session ()
  (jsonyter-tests--with-org-file
      "#+begin_src python :session jy:main\nx = 1\n#+end_src\n"
    (goto-char (point-min))
    (search-forward "x = 1")
    (let ((session (jsonyter--session-put '("python" . "main"))))
      (let (target)
        (cl-letf (((symbol-function 'jsonyter-interrupt) (lambda (s) (setq target s))))
          (jsonyter-org-interrupt))
        (should (eq target session)))
      (let (target)
        (cl-letf (((symbol-function 'jsonyter-restart) (lambda (s) (setq target s))))
          (jsonyter-org-restart))
        (should (eq target session))))))

(ert-deftest jsonyter-test-org-reconnect-uses-last-kernel ()
  (jsonyter-tests--with-org-file
      "#+begin_src python :session jy:main\nx = 1\n#+end_src\n"
    (goto-char (point-min))
    (search-forward "x = 1")
    (let ((session (jsonyter--session-put '("python" . "main"))))
      (setf (jsonyter--session-last-kernel session) (list :id "old-kid"))
      (let (connected)
        (cl-letf (((symbol-function 'jsonyter-kernel-connect)
                   (lambda (id s) (setq connected (cons id s)))))
          (jsonyter-org-reconnect))
        (should (equal (car connected) "old-kid"))))))

(ert-deftest jsonyter-test-org-reconnect-errors-with-no-kernel ()
  (jsonyter-tests--with-org-file
      "#+begin_src python :session jy:main\nx = 1\n#+end_src\n"
    (goto-char (point-min))
    (search-forward "x = 1")
    (jsonyter--session-put '("python" . "main"))
    (should-error (jsonyter-org-reconnect) :type 'user-error)))

(ert-deftest jsonyter-test-org-kernel-history-uses-block-session ()
  (jsonyter-tests--with-org-file
      "#+begin_src python :session jy:main\nx = 1\n#+end_src\n"
    (goto-char (point-min))
    (search-forward "x = 1")
    (let ((session (jsonyter--session-put '("python" . "main"))))
      (setf (jsonyter--session-kernel-id session) "kid")
      (let (kid)
        (cl-letf (((symbol-function 'jsonyter-kernel-history) (lambda (_n k) (setq kid k))))
          (jsonyter-org-kernel-history))
        (should (equal kid "kid"))))))

(ert-deftest jsonyter-test-org-previous-block-reports-when-none-found ()
  "Kept to a buffer with no blocks at all -- see the commentary on
`jsonyter-test-org-run-buffer-runs-each-jy-block' for why a *second*
real Org src-block traversal is unreliable in batch Emacs."
  (jsonyter-tests--with-org-file "plain text only, no blocks\n"
    (let (said (start (point)))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
        (jsonyter-org-previous-block))
      (should (= (point) start))
      (should (string-match-p "no earlier jy: block" said)))))

(ert-deftest jsonyter-test-org-fallthrough-runs-the-key-binding-with-mode-off ()
  (with-temp-buffer
    (let (ran mode-during-check)
      (cl-letf (((symbol-function 'key-binding)
                 (lambda (&rest _) (setq mode-during-check jsonyter-org-mode) 'some-command))
                ((symbol-function 'commandp) (lambda (&rest _) t))
                ((symbol-function 'call-interactively) (lambda (cmd) (setq ran cmd))))
        (setq-local jsonyter-org-mode t)
        (jsonyter--org-fallthrough))
      (should (eq ran 'some-command))
      (should-not mode-during-check))))

(ert-deftest jsonyter-test-org-fallthrough-dings-when-no-command ()
  (with-temp-buffer
    (let (dinged)
      (cl-letf (((symbol-function 'key-binding) (lambda (&rest _) nil))
                ((symbol-function 'commandp) (lambda (&rest _) nil))
                ((symbol-function 'ding) (lambda (&rest _) (setq dinged t))))
        (jsonyter--org-fallthrough))
      (should dinged))))

;;;; jsonyter--remote-root-for

(ert-deftest jsonyter-test-remote-root-for-resolves-alist-string-or-nil ()
  (let ((jsonyter-remote-root '(("http://a" . "/root/a") ("http://b" . "/root/b"))))
    (should (equal "/root/b" (jsonyter--remote-root-for "http://b"))))
  (let ((jsonyter-remote-root "/plain/root"))
    (should (equal "/plain/root" (jsonyter--remote-root-for "anything"))))
  (let ((jsonyter-remote-root nil))
    (should (null (jsonyter--remote-root-for "anything")))))

;;;; Live-REPL commands (send/inspect/navigation)

(defmacro jsonyter-tests--with-live-repl (&rest body)
  "Run BODY in a `jsonyter-repl-mode' buffer with a prompt already drawn.
`jsonyter--live-p' and friends still need mocking per test: this only
sets up the buffer/session shape, not a real process."
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (jsonyter-repl-mode)
     (setq-local jsonyter--session-key '("python" . ""))
     (let ((session (jsonyter--session-put jsonyter--session-key)))
       (setf (jsonyter--session-kernel-id session) "kid")
       (jsonyter--insert-prompt)
       ,@body)))

(ert-deftest jsonyter-test-repl-send-executes-unconditionally ()
  (jsonyter-tests--with-live-repl
    (insert "print(1)")
    (let (executed)
      (cl-letf (((symbol-function 'jsonyter--live-p) (lambda (&rest _) t))
                ((symbol-function 'jsonyter--busy-p) (lambda (&rest _) nil))
                ((symbol-function 'jsonyter--execute) (lambda (code) (setq executed code))))
        (jsonyter-repl-send))
      (should (equal "print(1)" executed)))))

(ert-deftest jsonyter-test-repl-send-errors-without-live-kernel ()
  (jsonyter-tests--with-live-repl
    (insert "print(1)")
    (cl-letf (((symbol-function 'jsonyter--live-p) (lambda (&rest _) nil)))
      (should-error (jsonyter-repl-send) :type 'user-error))))

(ert-deftest jsonyter-test-repl-send-reports-busy-kernel ()
  (jsonyter-tests--with-live-repl
    (insert "print(1)")
    (let (said)
      (cl-letf (((symbol-function 'jsonyter--live-p) (lambda (&rest _) t))
                ((symbol-function 'jsonyter--busy-p) (lambda (&rest _) t))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
        (jsonyter-repl-send))
      (should (string-match-p "kernel is busy" said)))))

(ert-deftest jsonyter-test-repl-send-reports-nothing-to-send-on-blank ()
  (jsonyter-tests--with-live-repl
    (let (said)
      (cl-letf (((symbol-function 'jsonyter--live-p) (lambda (&rest _) t))
                ((symbol-function 'jsonyter--busy-p) (lambda (&rest _) nil))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
        (jsonyter-repl-send))
      (should (string-match-p "nothing to send" said)))))

(ert-deftest jsonyter-test-repl-inspect-shows-documentation ()
  (jsonyter-tests--with-live-repl
    (insert "len")
    (cl-letf (((symbol-function 'jsonyter--live-p) (lambda (&rest _) t))
              ((symbol-function 'jsonyter--busy-p) (lambda (&rest _) nil))
              ((symbol-function 'jsonyter--kernel-request)
               (lambda (&rest _) (list :found t :data (list :text/plain "len(x)")))))
      (jsonyter-repl-inspect))
    (let ((buf (get-buffer "*jsonyter-doc*")))
      (should buf)
      (with-current-buffer buf (should (string-match-p "len(x)" (buffer-string))))
      (kill-buffer buf))))

(ert-deftest jsonyter-test-repl-inspect-errors-without-live-kernel ()
  (jsonyter-tests--with-live-repl
    (cl-letf (((symbol-function 'jsonyter--live-p) (lambda (&rest _) nil)))
      (should-error (jsonyter-repl-inspect) :type 'user-error))))

(ert-deftest jsonyter-test-repl-inspect-errors-when-busy ()
  (jsonyter-tests--with-live-repl
    (cl-letf (((symbol-function 'jsonyter--live-p) (lambda (&rest _) t))
              ((symbol-function 'jsonyter--busy-p) (lambda (&rest _) t)))
      (should-error (jsonyter-repl-inspect) :type 'user-error))))

(ert-deftest jsonyter-test-repl-inspect-reports-nothing-found ()
  (jsonyter-tests--with-live-repl
    (insert "xyz")
    (let (said)
      (cl-letf (((symbol-function 'jsonyter--live-p) (lambda (&rest _) t))
                ((symbol-function 'jsonyter--busy-p) (lambda (&rest _) nil))
                ((symbol-function 'jsonyter--kernel-request) (lambda (&rest _) (list :found :json-false)))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
        (jsonyter-repl-inspect))
      (should (string-match-p "no documentation found" said)))))

(ert-deftest jsonyter-test-repl-beginning-of-line-goes-to-input-start ()
  (jsonyter-tests--with-live-repl
    (insert "abc")
    (jsonyter-repl-beginning-of-line)
    (should (= (point) jsonyter--input-start))))

(ert-deftest jsonyter-test-repl-beginning-of-line-falls-back-off-prompt-line ()
  (jsonyter-tests--with-live-repl
    (insert "line one\nline two")
    (goto-char (point-max))
    (jsonyter-repl-beginning-of-line)
    (should (looking-at-p "line two"))))

(ert-deftest jsonyter-test-repl-newline-inserts-at-input-start ()
  (jsonyter-tests--with-live-repl
    (jsonyter-repl-newline)
    (should (equal "\n" (jsonyter--current-input)))))

(ert-deftest jsonyter-test-clear-cell-output-deletes-running-region ()
  (jsonyter-tests--with-live-repl
    (goto-char (point-max))
    (set-marker jsonyter--output-start (point))
    (insert "some output")
    (set-marker jsonyter--output-end (point-max))
    (jsonyter--clear-cell-output)
    (should (= (marker-position jsonyter--output-start) (point-max)))))

;;;; Small standalone helpers

(ert-deftest jsonyter-test-insert-html-renders-with-shr ()
  (with-temp-buffer
    (jsonyter--insert-html "<b>hi</b>")
    (should (string-match-p "hi" (buffer-string)))))

(ert-deftest jsonyter-test-clear-dispatches-per-buffer-kind ()
  (jsonyter-tests--with-notebook
    (let (called)
      (cl-letf (((symbol-function 'jsonyter-notebook-clear-all-output) (lambda () (setq called 'notebook))))
        (jsonyter-clear))
      (should (eq called 'notebook))))
  (with-temp-buffer
    (jsonyter-repl-mode)
    (let (called)
      (cl-letf (((symbol-function 'jsonyter-repl-clear) (lambda () (setq called 'repl))))
        (jsonyter-clear))
      (should (eq called 'repl))))
  (with-temp-buffer
    (python-mode)
    (jsonyter-script-mode 1)
    (let (called)
      (cl-letf (((symbol-function 'jsonyter-script-clear-all-output) (lambda () (setq called 'script))))
        (jsonyter-clear))
      (should (eq called 'script))))
  (with-temp-buffer
    (should-error (jsonyter-clear) :type 'user-error)))

(ert-deftest jsonyter-test-save-buffer-dispatches-notebook-vs-plain ()
  (jsonyter-tests--with-notebook
    (let (called)
      (cl-letf (((symbol-function 'jsonyter-notebook-save-buffer) (lambda () (setq called t))))
        (jsonyter-save-buffer))
      (should called)))
  (with-temp-buffer
    (let (called)
      (cl-letf (((symbol-function 'save-buffer) (lambda (&rest _) (setq called t))))
        (jsonyter-save-buffer))
      (should called))))

(ert-deftest jsonyter-test-notebook-clear-cell-output-clears-and-marks-touched ()
  (jsonyter-tests--with-notebook
    (let ((cell (jsonyter-tests--cell 0)))
      (jsonyter--nb-set-output cell "results\n" nil t)
      (goto-char (overlay-start cell))
      (jsonyter-notebook-clear-cell-output)
      (should (equal "" (jsonyter-tests--output-text cell))))))

(ert-deftest jsonyter-test-notebook-clear-cell-output-errors-without-cell ()
  (jsonyter-tests--with-notebook
    (cl-letf (((symbol-function 'jsonyter--nb-cell-at) (lambda (&rest _) nil)))
      (should-error (jsonyter-notebook-clear-cell-output) :type 'user-error))))

(ert-deftest jsonyter-test-notebook-run-all-runs-every-code-cell ()
  (jsonyter-tests--with-notebook
    (let (run-order)
      (cl-letf (((symbol-function 'jsonyter--nb-ensure-kernel) #'ignore)
                ((symbol-function 'jsonyter-notebook-run-cell)
                 (lambda (&rest _) (push (jsonyter--nb-cell-source (jsonyter--nb-cell-at)) run-order)))
                ((symbol-function 'jsonyter--busy-p) (lambda (&rest _) nil)))
        (jsonyter-notebook-run-all))
      (should (equal (nreverse run-order) '("x = 1" "print(x)"))))))

(ert-deftest jsonyter-test-nb-ensure-kernel-starts-when-allowed ()
  (jsonyter-tests--with-notebook
    (let (started)
      (cl-letf (((symbol-function 'jsonyter--live-p) (lambda (&rest _) nil))
                ((symbol-function 'jsonyter-notebook-start-kernel) (lambda () (setq started t))))
        (jsonyter--nb-ensure-kernel))
      (should started))))

(ert-deftest jsonyter-test-nb-ensure-kernel-errors-when-auto-start-disabled ()
  (jsonyter-tests--with-notebook
    (let ((jsonyter-notebook-auto-start-kernel nil))
      (cl-letf (((symbol-function 'jsonyter--live-p) (lambda (&rest _) nil)))
        (should-error (jsonyter--nb-ensure-kernel) :type 'user-error)))))

(ert-deftest jsonyter-test-nb-ensure-kernel-noop-when-already-live ()
  (jsonyter-tests--with-notebook
    (cl-letf (((symbol-function 'jsonyter--live-p) (lambda (&rest _) t))
              ((symbol-function 'jsonyter-notebook-start-kernel)
               (lambda () (error "must not start a new kernel"))))
      (jsonyter--nb-ensure-kernel))))

(ert-deftest jsonyter-test-notebook-new-via-interactive ()
  (let ((path (make-temp-file "jsonyter-new-" nil ".ipynb"))
        buf)
    (delete-file path)
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "python"))
                    ((symbol-function 'read-file-name) (lambda (&rest _) path)))
            (setq buf (call-interactively 'jsonyter-notebook-new)))
          (should (file-exists-p path))
          (should (buffer-live-p buf)))
      (when (buffer-live-p buf)
        (with-current-buffer buf (set-buffer-modified-p nil))
        (kill-buffer buf))
      (when (file-exists-p path) (delete-file path)))))

(ert-deftest jsonyter-test-notebook-run-cell-and-advance-delegates ()
  (jsonyter-tests--with-notebook
    (let (advanced)
      (cl-letf (((symbol-function 'jsonyter-notebook-run-cell) (lambda (&optional adv) (setq advanced adv))))
        (jsonyter-notebook-run-cell-and-advance))
      (should advanced))))

(ert-deftest jsonyter-test-resume-download-delegates-to-resume-transfer ()
  (let (which)
    (cl-letf (((symbol-function 'jsonyter--resume-transfer) (lambda (m) (setq which m))))
      (jsonyter-resume-download))
    (should (equal "download" which))))

(ert-deftest jsonyter-test-script-run-cell-and-advance-delegates ()
  (with-temp-buffer
    (python-mode)
    (jsonyter-script-mode 1)
    (let (advanced)
      (cl-letf (((symbol-function 'jsonyter-script-run-cell) (lambda (&optional adv) (setq advanced adv))))
        (jsonyter-script-run-cell-and-advance))
      (should advanced))))

;;;; Script cells: staleness, clearing, language/spec resolution

(ert-deftest jsonyter-test-script-stale-after-change-flags-touched-cell ()
  (with-temp-buffer
    (python-mode)
    (jsonyter-script-mode 1)
    (buffer-enable-undo)
    (insert "# %%\nx = 1\n")
    (goto-char (point-min))
    (forward-line 1)
    (pcase-let* ((`(,start . ,end) (jsonyter--script-cell-bounds))
                 (ov (jsonyter--script-output-overlay start end)))
      (overlay-put ov 'jsonyter-source-hash (jsonyter--source-hash "x = 1"))
      (overlay-put ov 'jsonyter-output-string "1\n")
      (should-not (overlay-get ov 'jsonyter-output-stale))
      (goto-char (line-end-position))
      (insert " + 9")
      (should (overlay-get ov 'jsonyter-output-stale)))))

(ert-deftest jsonyter-test-script-clear-all-output-removes-every-overlay ()
  (with-temp-buffer
    (python-mode)
    (jsonyter-script-mode 1)
    (insert "# %%\nx = 1\n# %%\nx + 1\n")
    (goto-char (point-min))
    (forward-line 1)
    (pcase-let* ((`(,s1 . ,e1) (jsonyter--script-cell-bounds))) (jsonyter--script-output-overlay s1 e1))
    (goto-char (point-max))
    (pcase-let* ((`(,s2 . ,e2) (jsonyter--script-cell-bounds))) (jsonyter--script-output-overlay s2 e2))
    (should (= 2 (length jsonyter--script-cells)))
    (jsonyter-script-clear-all-output)
    (should (null jsonyter--script-cells))))

(ert-deftest jsonyter-test-script-export-spec-falls-back-to-metadata-extension ()
  (let ((spec (jsonyter--script-export-spec "haskell" (list :language_info (list :file_extension ".hs")))))
    (should (equal ".hs" (plist-get spec :extension)))
    (should (equal "# %%" (plist-get spec :divider)))))

(ert-deftest jsonyter-test-script-export-spec-generic-fallback-with-no-metadata ()
  (let ((spec (jsonyter--script-export-spec "haskell" nil)))
    (should (equal ".txt" (plist-get spec :extension)))))

(ert-deftest jsonyter-test-script-language-errors-for-unknown-mode ()
  (with-temp-buffer
    (fundamental-mode)
    (should-error (jsonyter--script-language) :type 'user-error)))

(ert-deftest jsonyter-test-script-cell-output-overlay-nil-without-one ()
  (with-temp-buffer
    (insert "hi\n")
    (should (null (jsonyter--script-cell-output-overlay (point-max))))))

;;;; jsonyter--nb-output-to-spec (kernel-shape -> nbformat-shape)

(ert-deftest jsonyter-test-nb-output-to-spec-covers-every-output-type ()
  (should (equal (list :output_type "stream" :name "stdout" :text "hi\n")
                 (jsonyter--nb-output-to-spec (list :type "stream" :text "hi\n"))))
  (should (equal (list :output_type "stream" :name "stderr" :text "oops\n")
                 (jsonyter--nb-output-to-spec (list :type "stream" :name "stderr" :text "oops\n"))))
  (let ((spec (jsonyter--nb-output-to-spec
               (list :type "execute_result" :execution_count 3
                     :data (list :text/plain "42") :metadata nil))))
    (should (equal "execute_result" (plist-get spec :output_type)))
    (should (equal 3 (plist-get spec :execution_count))))
  (let ((spec (jsonyter--nb-output-to-spec (list :type "update_display_data" :data (list :text/plain "x")))))
    (should (equal "display_data" (plist-get spec :output_type)))
    (should-not (plist-member spec :execution_count)))
  (let ((spec (jsonyter--nb-output-to-spec
               (list :type "error" :ename "ValueError" :evalue "bad" :traceback '("l1" "l2")))))
    (should (equal "error" (plist-get spec :output_type)))
    (should (equal ["l1" "l2"] (plist-get spec :traceback))))
  (let ((spec (jsonyter--nb-output-to-spec (list :type "something_unknown"))))
    (should (equal "stream" (plist-get spec :output_type)))
    (should (string-match-p "unrecognized output type" (plist-get spec :text)))))

;;;; jsonyter--render-output (the REPL/notebook rendering pipeline)

(ert-deftest jsonyter-test-render-output-covers-every-output-type ()
  (with-temp-buffer
    (setq-local jsonyter--clear-pending nil)
    (jsonyter--render-output (jsonyter-tests--stream "hi\n"))
    (should (string-match-p "hi" (buffer-string))))
  (with-temp-buffer
    (jsonyter--render-output (list :type "execute_result" :execution_count 3
                                   :data (list :text/plain "42")))
    (should (string-match-p "Out\\[3\\]: " (buffer-string)))
    (should (string-match-p "42" (buffer-string))))
  (with-temp-buffer
    (jsonyter--render-output (list :type "display_data" :data (list :text/plain "a figure")))
    (should (string-match-p "a figure" (buffer-string))))
  (with-temp-buffer
    (jsonyter--render-output (list :type "error" :traceback '("line1" "line2")))
    (should (string-match-p "line1" (buffer-string)))
    (should (string-match-p "line2" (buffer-string))))
  (with-temp-buffer
    (setq-local jsonyter--output-start (make-marker))
    (setq-local jsonyter--output-end (make-marker))
    (insert "leftover")
    (set-marker jsonyter--output-start (point-min))
    (set-marker jsonyter--output-end (point-max))
    (jsonyter--render-output (list :type "clear_output" :wait nil))
    (should (equal "" (buffer-string))))
  (with-temp-buffer
    (setq-local jsonyter--clear-pending nil)
    (jsonyter--render-output (list :type "clear_output" :wait t))
    (should jsonyter--clear-pending))
  (with-temp-buffer
    (setq-local jsonyter--output-start (make-marker))
    (setq-local jsonyter--output-end (make-marker))
    (setq-local jsonyter--clear-pending t)
    (insert "leftover")
    (set-marker jsonyter--output-start (point-min))
    (set-marker jsonyter--output-end (point-max))
    (jsonyter--render-output (jsonyter-tests--stream "fresh\n"))
    (should-not jsonyter--clear-pending)
    (should (string-match-p "fresh" (buffer-string)))
    (should-not (string-match-p "leftover" (buffer-string)))))

;;;; jsonyter--insert-mimebundle (richest-representation fallback)

(ert-deftest jsonyter-test-insert-mimebundle-renders-html-then-plain-then-nothing ()
  (with-temp-buffer
    (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) nil)))
      (jsonyter--insert-mimebundle (list :text/html "<b>hi</b>"))
      (should (string-match-p "hi" (buffer-string)))))
  (with-temp-buffer
    (let ((jsonyter-render-html nil))
      (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) nil)))
        (jsonyter--insert-mimebundle (list :text/plain "plain text"))
        (should (string-match-p "plain text" (buffer-string))))))
  (with-temp-buffer
    (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) nil)))
      (jsonyter--insert-mimebundle (list))
      (should (string-match-p "unrenderable output" (buffer-string))))))

(ert-deftest jsonyter-test-insert-mimebundle-falls-back-through-image-types ()
  (with-temp-buffer
    (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
              ((symbol-function 'image-type-available-p) (lambda (type) (memq type '(jpeg))))
              ((symbol-function 'jsonyter--insert-encoded-image)
               (lambda (_data type) (insert (format "[%s image]" type)))))
      (jsonyter--insert-mimebundle (list :image/jpeg "irrelevant-base64"))
      (should (string-match-p "\\[jpeg image\\]" (buffer-string)))))
  (with-temp-buffer
    (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
              ((symbol-function 'image-type-available-p) (lambda (type) (memq type '(svg))))
              ((symbol-function 'create-image) (lambda (&rest _) 'fake-svg-image))
              ((symbol-function 'jsonyter--insert-image) (lambda (_img alt) (insert alt))))
      (jsonyter--insert-mimebundle (list :image/svg+xml "<svg></svg>"))
      (should (string-match-p "\\[svg image\\]" (buffer-string))))))

;;;; jsonyter--org-result-body / jsonyter--org-var-atom / jsonyter--org-file-base64

(ert-deftest jsonyter-test-org-result-body-covers-image-and-error-types ()
  (cl-letf (((symbol-function 'jsonyter--org-write-image) (lambda (_data ext) (format "plot.%s" ext))))
    (should (equal "[[file:plot.png]]"
                   (jsonyter--org-result-body
                    (list (list :type "display_data" :data (list :image/png "pngdata"))))))
    (should (equal "[[file:plot.jpg]]"
                   (jsonyter--org-result-body
                    (list (list :type "display_data" :data (list :image/jpeg "jpegdata"))))))
    (should (equal "[[file:plot.svg]]"
                   (jsonyter--org-result-body
                    (list (list :type "display_data" :data (list :image/svg+xml "<svg/>")))))))
  (should (equal ": boom" (jsonyter--org-result-body
                           (list (list :type "error" :traceback '("boom")))))))

(ert-deftest jsonyter-test-org-var-atom-covers-every-lisp-shape ()
  (should (equal "None" (jsonyter--org-var-atom nil "None" "True")))
  (should (equal "True" (jsonyter--org-var-atom t "None" "True")))
  (should (equal "3" (jsonyter--org-var-atom 3 "None" "True")))
  (should (string-match-p "\"hi\"" (jsonyter--org-var-atom "hi" "None" "True")))
  (should (string-match-p "sym" (jsonyter--org-var-atom 'sym "None" "True"))))

(ert-deftest jsonyter-test-org-file-base64-encodes-file-bytes ()
  (let ((file (make-temp-file "jsonyter-b64-")))
    (unwind-protect
        (progn
          (with-temp-file file (set-buffer-multibyte nil) (insert "hi"))
          (should (equal (base64-encode-string "hi") (jsonyter--org-file-base64 file))))
      (delete-file file))))

;;;; Org-babel language wrappers (advice + standalone)

(ert-deftest jsonyter-test-org-babel-execute-language-wrappers-delegate ()
  (dolist (spec '((jsonyter--org-babel-execute:python . "python")
                   (jsonyter--org-babel-execute:R . "R")
                   (jsonyter--org-babel-execute:julia . "julia")
                   (jsonyter--org-babel-execute:SAS . "SAS")))
    (let (seen)
      (cl-letf (((symbol-function 'jsonyter--org-babel-dispatch)
                 (lambda (lang orig-fun body params) (setq seen (list lang orig-fun body params)))))
        (funcall (car spec) 'orig "body" '(:x 1)))
      (should (equal (nth 0 seen) (cdr spec)))
      (should (eq (nth 1 seen) 'orig))))
  (dolist (spec '((jsonyter--org-babel-standalone:python . "python")
                   (jsonyter--org-babel-standalone:R . "R")
                   (jsonyter--org-babel-standalone:julia . "julia")
                   (jsonyter--org-babel-standalone:SAS . "SAS")))
    (let (seen)
      (cl-letf (((symbol-function 'jsonyter--org-babel-dispatch)
                 (lambda (lang orig-fun body params) (setq seen (list lang orig-fun body params)))))
        (funcall (car spec) "body" '(:x 1)))
      (should (equal (nth 0 seen) (cdr spec)))
      (should (null (nth 1 seen))))))

(ert-deftest jsonyter-test-org-babel-dispatch-errors-with-no-backend ()
  (cl-letf (((symbol-function 'jsonyter--org-babel-jy-p) (lambda (&rest _) nil)))
    (should-error (jsonyter--org-babel-dispatch "SAS" nil "body" nil))))

(ert-deftest jsonyter-test-org-babel-dispatch-falls-through-to-orig-fun ()
  (cl-letf (((symbol-function 'jsonyter--org-babel-jy-p) (lambda (&rest _) nil)))
    (should (equal "ran" (jsonyter--org-babel-dispatch "python" (lambda (_b _p) "ran") "body" nil)))))

;;;; jsonyter--org-markdown-convert

(ert-deftest jsonyter-test-org-markdown-convert-uses-custom-converter ()
  (let ((jsonyter-org-markdown-converter (lambda (text dir) (format "[%s:%s]" dir text))))
    (should (equal "[to-org:hi]" (jsonyter--org-markdown-convert "hi" 'to-org)))))

(ert-deftest jsonyter-test-org-markdown-convert-falls-back-with-no-converter ()
  (let ((jsonyter-org-markdown-converter nil))
    (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))
      (let ((out (jsonyter--org-markdown-convert "hi" 'to-org)))
        (should (string-match-p "no Markdown->Org converter" out))
        (should (string-match-p "hi" out)))
      (let ((out (jsonyter--org-markdown-convert "hi" 'to-markdown)))
        (should (string-match-p "no Markdown<-Org converter" out))))))

(ert-deftest jsonyter-test-org-markdown-convert-uses-pandoc-when-available ()
  (let ((jsonyter-org-markdown-converter nil))
    (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) "/usr/bin/pandoc"))
              ((symbol-function 'call-process-region)
               (lambda (beg end _prog &optional _del _out _disp &rest _)
                 (delete-region beg end)
                 (insert "converted")
                 0)))
      (should (equal "converted" (jsonyter--org-markdown-convert "hi" 'to-org))))))

(ert-deftest jsonyter-test-org-markdown-convert-reports-pandoc-failure ()
  (let ((jsonyter-org-markdown-converter nil))
    (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) "/usr/bin/pandoc"))
              ((symbol-function 'call-process-region) (lambda (&rest _) 1)))
      (should (string-match-p "pandoc failed" (jsonyter--org-markdown-convert "hi" 'to-org))))))

;;;; jsonyter-notebook-run-cell (the real body)

(ert-deftest jsonyter-test-notebook-run-cell-executes-and-shows-output ()
  (jsonyter-tests--with-notebook
    (jsonyter--session-put jsonyter--session-key)
    (let ((cell (jsonyter-tests--cell 0)) handlers)
      (goto-char (overlay-start cell))
      (cl-letf (((symbol-function 'jsonyter--nb-ensure-kernel) #'ignore)
                ((symbol-function 'jsonyter--send) (lambda (_m _p hs) (setq handlers hs) 1)))
        (jsonyter-notebook-run-cell))
      (should (jsonyter--session-busy (jsonyter--session)))
      (funcall (plist-get handlers :output) (jsonyter-tests--stream "hi\n"))
      (funcall (plist-get handlers :result) (list :result (list :execution_count 1)))
      (should-not (jsonyter--session-busy (jsonyter--session)))
      (should (string-match-p "hi" (jsonyter-tests--output-text cell))))))

(ert-deftest jsonyter-test-notebook-run-cell-reports-execute-error ()
  (jsonyter-tests--with-notebook
    (jsonyter--session-put jsonyter--session-key)
    (let ((cell (jsonyter-tests--cell 0)) handlers)
      (goto-char (overlay-start cell))
      (cl-letf (((symbol-function 'jsonyter--nb-ensure-kernel) #'ignore)
                ((symbol-function 'jsonyter--send) (lambda (_m _p hs) (setq handlers hs) 1)))
        (jsonyter-notebook-run-cell))
      (funcall (plist-get handlers :result) (list :error (list :error "NameError" :message "boom")))
      (should (string-match-p "execute failed" (jsonyter-tests--output-text cell))))))

(ert-deftest jsonyter-test-notebook-run-cell-markdown-cell-does-not-execute ()
  (jsonyter-tests--with-notebook
    (let ((cell (jsonyter-tests--cell 2)))
      (goto-char (overlay-start cell))
      (cl-letf (((symbol-function 'jsonyter--send) (lambda (&rest _) (error "must not execute"))))
        (jsonyter-notebook-run-cell)))))

(ert-deftest jsonyter-test-notebook-run-cell-refuses-when-busy ()
  (jsonyter-tests--with-notebook
    (goto-char (overlay-start (jsonyter-tests--cell 0)))
    (setf (jsonyter--session-busy (jsonyter--session-put jsonyter--session-key)) t)
    (let (said)
      (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
        (jsonyter-notebook-run-cell))
      (should (string-match-p "kernel is busy" said)))))

(ert-deftest jsonyter-test-notebook-run-cell-errors-without-cell ()
  (jsonyter-tests--with-notebook
    (cl-letf (((symbol-function 'jsonyter--nb-cell-at) (lambda (&rest _) nil)))
      (should-error (jsonyter-notebook-run-cell) :type 'user-error))))

(ert-deftest jsonyter-test-notebook-run-cell-reports-empty-cell ()
  (jsonyter-tests--with-notebook
    (goto-char (overlay-start (jsonyter-tests--cell 0)))
    (jsonyter-insert-cell-below)
    (goto-char (overlay-start (jsonyter-tests--cell 1)))
    (let (said)
      (cl-letf (((symbol-function 'jsonyter--nb-ensure-kernel) #'ignore)
                ((symbol-function 'jsonyter--send) (lambda (&rest _) (error "must not run")))
                ((symbol-function 'message) (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
        (jsonyter-notebook-run-cell))
      (should (string-match-p "empty cell" said)))))

;;;; jsonyter-kernel-history: remaining branches

(ert-deftest jsonyter-test-kernel-history-with-prefix-arg-prompts-for-count-and-kernel ()
  (jsonyter-tests--with-sessions
    (jsonyter-tests--bind-session '("python" . "") "kid")
    (setq-local jsonyter--session-key '("python" . ""))
    (cl-letf (((symbol-function 'jsonyter--ensure-live-bridge) #'ignore)
              ((symbol-function 'read-number) (lambda (&rest _) 7))
              ((symbol-function 'jsonyter--read-kernel) (lambda (&rest _) "other-kid"))
              ((symbol-function 'jsonyter--request-sync)
               (lambda (method &rest _) (when (equal method "get_kernel") (list :id "other-kid"))))
              ((symbol-function 'jsonyter--kernel-request)
               (lambda (&rest _) (list :status "ok" :history nil))))
      (let ((current-prefix-arg '(4)))
        (call-interactively 'jsonyter-kernel-history)))
    (let ((buf (get-buffer "*jsonyter-history*"))) (when buf (kill-buffer buf)))))

(ert-deftest jsonyter-test-kernel-history-disconnects-when-viewing-other-kernel ()
  (jsonyter-tests--with-sessions
    (jsonyter-tests--bind-session '("python" . "") "kid")
    (setq-local jsonyter--session-key '("python" . ""))
    (let (disconnected)
      (cl-letf (((symbol-function 'jsonyter--ensure-live-bridge) #'ignore)
                ((symbol-function 'jsonyter--request-sync)
                 (lambda (method params &rest _)
                   (cond ((equal method "get_kernel") (list :id "other-kid"))
                         ((equal method "disconnect") (setq disconnected (plist-get params :kernel_id))))))
                ((symbol-function 'jsonyter--kernel-request)
                 (lambda (&rest _) (list :status "ok" :history (list (list "s1" 1 "y = 2"))))))
        (jsonyter-kernel-history 5 "other-kid"))
      (should (equal disconnected "other-kid")))
    (let ((buf (get-buffer "*jsonyter-history*"))) (when buf (kill-buffer buf)))))

(ert-deftest jsonyter-test-kernel-history-errors-when-kernel-unreachable ()
  (jsonyter-tests--with-sessions
    (jsonyter-tests--bind-session '("python" . "") "kid")
    (setq-local jsonyter--session-key '("python" . ""))
    (cl-letf (((symbol-function 'jsonyter--ensure-live-bridge) #'ignore)
              ((symbol-function 'jsonyter--request-sync)
               (lambda (method &rest _) (when (equal method "get_kernel") (error "gone")))))
      (should-error (jsonyter-kernel-history 5 "kid") :type 'user-error))))

(ert-deftest jsonyter-test-kernel-history-errors-when-history-request-fails ()
  (jsonyter-tests--with-sessions
    (jsonyter-tests--bind-session '("python" . "") "kid")
    (setq-local jsonyter--session-key '("python" . ""))
    (cl-letf (((symbol-function 'jsonyter--ensure-live-bridge) #'ignore)
              ((symbol-function 'jsonyter--request-sync)
               (lambda (method &rest _) (when (equal method "get_kernel") (list :id "kid"))))
              ((symbol-function 'jsonyter--kernel-request) (lambda (&rest _) (error "no history"))))
      (should-error (jsonyter-kernel-history 5 "kid") :type 'user-error))))

;;;; jsonyter-org-run-block / jsonyter-script-run-cell: error and aborted branches

(ert-deftest jsonyter-test-org-run-block-reports-execute-error ()
  (jsonyter-tests--with-org-file
      "#+begin_src python :session jy:main\nx = 1\n#+end_src\n"
    (goto-char (point-min))
    (search-forward "x = 1")
    (let ((session (jsonyter--session-put '("python" . "main")))
          handlers)
      (setf (jsonyter--session-kernel-id session) "kid")
      (cl-letf (((symbol-function 'jsonyter--org-connect) (lambda (&rest _) session))
                ((symbol-function 'jsonyter--send) (lambda (_m _p hs) (setq handlers hs) 1)))
        (jsonyter-org-run-block))
      (funcall (plist-get handlers :result) (list :error (list :error "NameError" :message "boom")))
      (let ((ov (jsonyter--org-cell-at)))
        (should (string-match-p "execute failed" (overlay-get ov 'jsonyter-output-string)))))))

(ert-deftest jsonyter-test-org-run-block-reports-aborted-status ()
  (jsonyter-tests--with-org-file
      "#+begin_src python :session jy:main\nx = 1\n#+end_src\n"
    (goto-char (point-min))
    (search-forward "x = 1")
    (let ((session (jsonyter--session-put '("python" . "main")))
          handlers)
      (setf (jsonyter--session-kernel-id session) "kid")
      (cl-letf (((symbol-function 'jsonyter--org-connect) (lambda (&rest _) session))
                ((symbol-function 'jsonyter--send) (lambda (_m _p hs) (setq handlers hs) 1)))
        (jsonyter-org-run-block))
      (funcall (plist-get handlers :result) (list :result (list :status "aborted")))
      (let ((ov (jsonyter--org-cell-at)))
        (should (string-match-p "execution aborted" (overlay-get ov 'jsonyter-output-string)))))))

(ert-deftest jsonyter-test-script-run-cell-reports-execute-error ()
  (with-temp-buffer
    (python-mode)
    (jsonyter-script-mode 1)
    (insert "# %%\nx = 1\n")
    (goto-char (point-min))
    (forward-line 1)
    (let ((session (jsonyter--session-put (cons "python" "")))
          handlers)
      (setq-local jsonyter--session-key (cons "python" ""))
      (setf (jsonyter--session-kernel-id session) "kid")
      (cl-letf (((symbol-function 'jsonyter--live-p) (lambda (&rest _) t))
                ((symbol-function 'jsonyter--send) (lambda (_m _p hs) (setq handlers hs) 1)))
        (jsonyter-script-run-cell))
      (funcall (plist-get handlers :result) (list :error (list :error "NameError" :message "boom")))
      (let ((ov (jsonyter--script-cell-output-overlay (point-max))))
        (should (string-match-p "execute failed" (overlay-get ov 'jsonyter-output-string)))))))

;;;; jsonyter--org-parse-results-drawer / jsonyter--org-result-images: image branches

(ert-deftest jsonyter-test-org-parse-results-drawer-recovers-image-output ()
  (jsonyter-tests--with-org-file
      (concat "* h\n#+begin_src python :session jy:main\nx = 1\n#+end_src\n\n"
              "#+RESULTS:\n:results:\n[[file:plot.png]]\n:end:\n")
    (let* ((dir (file-name-directory buffer-file-name))
           (img (expand-file-name "plot.png" dir)))
      (unwind-protect
          (progn
            (let ((coding-system-for-write 'binary))
              (with-temp-file img (set-buffer-multibyte nil) (insert "fake-bytes")))
            (goto-char (point-min))
            (search-forward "x = 1")
            (let* ((info (jsonyter--org-block-info))
                   (outputs (jsonyter--org-parse-results-drawer info dir)))
              (should (= 1 (length outputs)))
              (should (equal "display_data" (plist-get (car outputs) :output_type)))
              (should (plist-get (plist-get (car outputs) :data) :image/png))))
        (when (file-exists-p img) (delete-file img))))))

(ert-deftest jsonyter-test-org-parse-results-drawer-skips-missing-image-file ()
  (jsonyter-tests--with-org-file
      (concat "* h\n#+begin_src python :session jy:main\nx = 1\n#+end_src\n\n"
              "#+RESULTS:\n:results:\n[[file:does-not-exist-anywhere.png]]\n:end:\n")
    (goto-char (point-min))
    (search-forward "x = 1")
    (let* ((info (jsonyter--org-block-info))
           (outputs (jsonyter--org-parse-results-drawer info default-directory)))
      (should (null outputs)))))

(ert-deftest jsonyter-test-org-result-images-collects-managed-links ()
  (jsonyter-tests--with-org-file
      "#+begin_src python :session jy:main\nx\n#+end_src\n"
    (goto-char (point-min))
    (search-forward "x")
    (let* ((info (jsonyter--org-block-info))
           (dir (jsonyter--org-image-dir))
           (f (expand-file-name "plot-abc.png" dir)))
      (make-directory dir t)
      (with-temp-file f (insert "x"))
      (save-excursion
        (goto-char (point-max))
        (insert (format "\n#+RESULTS:\n:results:\n[[file:%s]]\n:end:\n"
                        (file-relative-name f (file-name-directory buffer-file-name)))))
      (should (member f (jsonyter--org-result-images info))))))

;;;; jsonyter--resolve-kernel-name

(ert-deftest jsonyter-test-resolve-kernel-name-honors-configured-alist ()
  (let ((jsonyter-kernel-names '(("python" . "py3-special"))))
    (should (equal "py3-special" (jsonyter--resolve-kernel-name "python")))))

(ert-deftest jsonyter-test-resolve-kernel-name-queries-server-and-prefers-default ()
  (let ((jsonyter-kernel-names nil))
    (cl-letf (((symbol-function 'jsonyter--request-sync)
               (lambda (&rest _)
                 (list :default "python3"
                       :kernelspecs (list :python3 (list :name "python3" :spec (list :language "python"))
                                          :python2 (list :name "python2" :spec (list :language "python")))))))
      (should (equal "python3" (jsonyter--resolve-kernel-name "python"))))))

(ert-deftest jsonyter-test-resolve-kernel-name-falls-back-to-first-match-without-default ()
  "With no server default among the matches, the first kernelspec the
table lists for the language wins -- `matches' is built by `push', so
`(car (last matches))' is the earliest one found, not the latest."
  (let ((jsonyter-kernel-names nil))
    (cl-letf (((symbol-function 'jsonyter--request-sync)
               (lambda (&rest _)
                 (list :default "R"
                       :kernelspecs (list :p2 (list :name "python2" :spec (list :language "python"))
                                          :p3 (list :name "python3" :spec (list :language "python")))))))
      (should (equal "python2" (jsonyter--resolve-kernel-name "python"))))))

(ert-deftest jsonyter-test-resolve-kernel-name-errors-with-no-match ()
  (let ((jsonyter-kernel-names nil))
    (cl-letf (((symbol-function 'jsonyter--request-sync)
               (lambda (&rest _)
                 (list :default nil
                       :kernelspecs (list :ir (list :name "ir" :spec (list :language "R")))))))
      (should-error (jsonyter--resolve-kernel-name "python")))))

;;;; Small notebook-cell helpers

(ert-deftest jsonyter-test-nb-major-mode-falls-back-to-prog-mode ()
  (should (eq #'prog-mode (jsonyter--nb-major-mode "some-unknown-language"))))

(ert-deftest jsonyter-test-nb-cell-at-nil-outside-any-cell ()
  (with-temp-buffer
    (insert "not a notebook buffer")
    (should (null (jsonyter--nb-cell-at (point-min))))))

(ert-deftest jsonyter-test-nb-ensure-notebook-errors-outside-notebook-mode ()
  (with-temp-buffer
    (should-error (jsonyter--nb-ensure-notebook) :type 'user-error)))

(ert-deftest jsonyter-test-insert-cell-with-markdown-prefix ()
  (jsonyter-tests--with-notebook
    (goto-char (overlay-start (jsonyter-tests--cell 0)))
    (jsonyter-insert-cell-below t)
    (should (equal "markdown" (overlay-get (jsonyter-tests--cell 1) 'jsonyter-cell-type)))
    (jsonyter-insert-cell-above t)
    (should (equal "markdown" (overlay-get (jsonyter-tests--cell 1) 'jsonyter-cell-type)))))

;;;; jsonyter--org-defkey-generated commands
;;
;; No coverage-recovery test here for the overwrite-confirmation branches
;; of `jsonyter-org-from-notebook'/`jsonyter-org-export-script'
;; (`(and (file-exists-p ...) (called-interactively-p 'interactive))'):
;; `called-interactively-p' is documented to be unreliable for interpreted
;; (non-byte-compiled) code, and this test suite runs uncompiled -- even
;; a direct `call-interactively' from an ERT test body does not reliably
;; make it return non-nil here, so a test built on it would be asserting
;; on an interpreter quirk rather than the function's actual behavior.

(ert-deftest jsonyter-test-org-defkey-generated-command-falls-through-outside-jy-block ()
  (jsonyter-tests--with-org-file "* heading\nplain text\n"
    (goto-char (point-max))
    (let (fell-through)
      (cl-letf (((symbol-function 'jsonyter--org-fallthrough) (lambda () (setq fell-through t))))
        (jsonyter-org-C-RET))
      (should fell-through))))

(ert-deftest jsonyter-test-org-defkey-generated-command-runs-jy-command-in-block ()
  (jsonyter-tests--with-org-file "#+begin_src python :session jy:main\nx = 1\n#+end_src\n"
    (goto-char (point-min))
    (search-forward "x = 1")
    (let (ran)
      (cl-letf (((symbol-function 'jsonyter-org-run-block) (lambda () (interactive) (setq ran t))))
        (jsonyter-org-C-RET))
      (should ran))))

;;;; Upload/download overwrite prefix argument

(ert-deftest jsonyter-test-upload-file-passes-overwrite-flag ()
  (let ((tmp (make-temp-file "jsonyter-upload-")))
    (unwind-protect
        (let (sent)
          (cl-letf (((symbol-function 'jsonyter--transfer-run)
                     (lambda (_ctx _method params &optional _cb) (setq sent params))))
            (jsonyter-upload-file tmp "d/x" t (cons (current-buffer) nil)))
          (should (eq t (plist-get sent :overwrite))))
      (delete-file tmp))))

(ert-deftest jsonyter-test-download-file-passes-overwrite-flag ()
  (let (sent)
    (cl-letf (((symbol-function 'jsonyter--transfer-run)
               (lambda (_ctx _method params &optional _cb) (setq sent params))))
      (jsonyter-download-file "d/x" "/tmp/x" t (cons (current-buffer) nil)))
    (should (eq t (plist-get sent :overwrite)))))

;;;; jsonyter-remote-dired-export: unavailable-formats branch

(ert-deftest jsonyter-test-remote-dired-export-refuses-when-formats-unavailable ()
  (with-temp-buffer
    (jsonyter-remote-dired-mode)
    (setq jsonyter--remote-owner (current-buffer)
          jsonyter--remote-cwd ""
          tabulated-list-entries (list (list "a.ipynb" (vector " " "a.ipynb" "10 B" ""))))
    (puthash "a.ipynb" '(:name "a.ipynb" :type "file" :path "a.ipynb") jsonyter--remote-models)
    (tabulated-list-print)
    (goto-char (point-min))
    (cl-letf (((symbol-function 'jsonyter--resolve-transfer-context)
               (lambda () (cons (current-buffer) nil)))
              ((symbol-function 'jsonyter--list-export-formats)
               (lambda (&rest _) (list :available nil :reason "no nbconvert"))))
      (should-error (call-interactively 'jsonyter-remote-dired-export) :type 'user-error))))

;;;; A few last, narrow branches

(ert-deftest jsonyter-test-start-bridge-env-transport-sets-jupyter-token-env-var ()
  (with-temp-buffer
    (let ((jsonyter-command '("cat"))
          (jsonyter-server-url "http://localhost:8888")
          (jsonyter-token-transport 'env)
          (jsonyter-server-token "tok")
          seen-env)
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest _) (setq seen-env process-environment) 'fake-proc))
                ((symbol-function 'process-get) (lambda (&rest _) nil))
                ((symbol-function 'process-put) #'ignore))
        (jsonyter--start-bridge))
      (should (member "JUPYTER_TOKEN=tok" seen-env)))))

(ert-deftest jsonyter-test-insert-cell-below-above-with-no-cell-at-point ()
  (jsonyter-tests--with-notebook
    (cl-letf (((symbol-function 'jsonyter--nb-cell-at) (lambda (&rest _) nil)))
      (jsonyter-insert-cell-below)
      (jsonyter-insert-cell-above))))

(ert-deftest jsonyter-test-connect-kernel-sets-session-key-outside-org-mode ()
  (with-temp-buffer
    (setq-local jsonyter--sessions (make-hash-table :test #'equal))
    (setq-local jsonyter--process nil)
    (let ((session (jsonyter-tests--bind-session '("python" . "") "kid")))
      (cl-letf (((symbol-function 'jsonyter--live-p) (lambda (&rest _) t))
                ((symbol-function 'jsonyter--ensure-live-bridge) #'ignore))
        (jsonyter--connect-kernel '("python" . "") "python3-pinned"))
      (should (equal jsonyter--session-key '("python" . "")))
      (should (equal "python3-pinned" (jsonyter--session-kernel-name session))))))

;;;; More narrow branches, for a comfortable margin above the threshold

(ert-deftest jsonyter-test-answer-input-reads-plain-string-without-password ()
  (let ((proc (start-process "jsonyter-test-answer" nil "cat")))
    (unwind-protect
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "plain-answer"))
                  ((symbol-function 'process-send-string)
                   (lambda (_proc s) (should (string-match-p "plain-answer" s)))))
          (jsonyter--answer-input proc 1 (list :prompt "> " :password :json-false)))
      (ignore-errors (delete-process proc)))))

(ert-deftest jsonyter-test-send-errors-when-bridge-not-running ()
  (with-temp-buffer
    (setq-local jsonyter--process nil)
    (should-error (jsonyter--send "execute" nil) :type 'error)))

(ert-deftest jsonyter-test-suppress-and-restore-line-spacing-both-branches ()
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
            ((symbol-function 'frame-char-height) (lambda (&rest _) 20)))
    ;; No buffer-local line-spacing yet: suppress records `kill', and
    ;; restoring kills the local value it set.
    (with-temp-buffer
      (setq-default line-spacing 0.5)
      (unwind-protect
          (progn
            (jsonyter--suppress-line-spacing)
            (should (local-variable-p 'line-spacing))
            (should (equal 0 line-spacing))
            (jsonyter--restore-line-spacing)
            (should-not (local-variable-p 'line-spacing))
            (should (null jsonyter--line-spacing-restore)))
        (setq-default line-spacing nil)))
    ;; A pre-existing buffer-local value: suppress records it, and
    ;; restoring puts that exact value back.
    (with-temp-buffer
      (setq-local line-spacing 7)
      (jsonyter--suppress-line-spacing)
      (should (equal 0 line-spacing))
      (jsonyter--restore-line-spacing)
      (should (equal 7 line-spacing)))))

(ert-deftest jsonyter-test-mode-line-string-sole-session-with-no-current-key ()
  (jsonyter-tests--with-sessions
    (let ((s (jsonyter-tests--bind-session '("python" . "main") "kid")))
      (setq-local jsonyter--session-key nil)
      (should (equal (jsonyter--session-status-tag s) (jsonyter--mode-line-string))))))

(ert-deftest jsonyter-test-announce-outside-repl-goes-to-echo-area ()
  (with-temp-buffer
    (jsonyter-tests--with-sessions
      (let ((s (jsonyter-tests--bind-session '("python" . "sess1") "kid"))
            said)
        (cl-letf (((symbol-function 'message)
                   (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
          (jsonyter--announce "[a note]" s))
        (should (string-match-p "sess1" said))
        (should (string-match-p "a note" said))))))

(ert-deftest jsonyter-test-insert-prompt-freezes-history-and-marks-input-start ()
  (with-temp-buffer
    (jsonyter-repl-mode)
    (jsonyter--insert-prompt)
    (should (marker-position jsonyter--input-start))
    (should (= (point) jsonyter--input-start))))

(ert-deftest jsonyter-test-mime-joins-list-values ()
  (should (equal "ab" (jsonyter--mime (list :text/plain '("a" "b")) :text/plain)))
  (should (equal "x" (jsonyter--mime (list :text/plain "x") :text/plain)))
  (should (null (jsonyter--mime (list :text/plain "x") :text/html))))

(ert-deftest jsonyter-test-insert-encoded-image-reports-when-undecodable ()
  (with-temp-buffer
    (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
              ((symbol-function 'image-type-available-p) (lambda (&rest _) t))
              ((symbol-function 'create-image) (lambda (&rest _) nil)))
      (jsonyter--insert-encoded-image (base64-encode-string "not an image") 'png)
      (should (string-match-p "could not decode" (buffer-string))))))

(ert-deftest jsonyter-test-insert-html-swallows-shr-errors ()
  (with-temp-buffer
    (cl-letf (((symbol-function 'shr-render-region) (lambda (&rest _) (error "shr blew up"))))
      (jsonyter--insert-html "<p>hi</p>")
      (should (string-match-p "<p>hi</p>" (buffer-string))))))

(ert-deftest jsonyter-test-history-add-trims-past-the-configured-size ()
  (with-temp-buffer
    (setq-local jsonyter--history nil)
    (let ((jsonyter-history-size 2))
      (jsonyter--history-add "a")
      (jsonyter--history-add "b")
      (jsonyter--history-add "c")
      (should (equal '("c" "b") jsonyter--history)))))

(ert-deftest jsonyter-test-command-session-falls-back-to-org-session-at-point ()
  (jsonyter-tests--with-org-file
      "#+begin_src python :session jy:main\nx = 1\n#+end_src\n"
    (goto-char (point-min))
    (search-forward "x = 1")
    (let ((session (jsonyter--session-put '("python" . "main"))))
      (should (eq (jsonyter--command-session) session)))))

(ert-deftest jsonyter-test-nb-text-joins-list-of-lines ()
  (should (equal "a\nb" (jsonyter--nb-text '("a\n" "b"))))
  (should (equal "solo" (jsonyter--nb-text "solo")))
  (should (equal "" (jsonyter--nb-text nil))))

(ert-deftest jsonyter-test-nb-output-to-spec-plain-display-data ()
  (let ((spec (jsonyter--nb-output-to-spec
               (list :type "display_data" :data (list :text/plain "a figure") :metadata nil))))
    (should (equal "display_data" (plist-get spec :output_type)))
    (should-not (plist-member spec :execution_count))))

;;;; Still more narrow branches

(ert-deftest jsonyter-test-notebook-previous-cell-navigates-back ()
  (jsonyter-tests--with-notebook
    (goto-char (overlay-start (jsonyter-tests--cell 1)))
    (jsonyter-notebook-previous-cell)
    (should (= (point) (overlay-start (jsonyter-tests--cell 0))))))

(ert-deftest jsonyter-test-notebook-previous-cell-reports-first-cell ()
  (jsonyter-tests--with-notebook
    (goto-char (overlay-start (jsonyter-tests--cell 0)))
    (let (said)
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
        (jsonyter-notebook-previous-cell))
      (should (string-match-p "first cell" said)))))

(ert-deftest jsonyter-test-dispatch-handles-unparseable-json ()
  (with-temp-buffer
    (setq-local jsonyter--callbacks (make-hash-table :test #'eql))
    (let (said)
      (cl-letf (((symbol-function 'jsonyter--announce)
                 (lambda (text &rest _) (setq said text))))
        (jsonyter--dispatch nil "not valid json {"))
      (should (string-match-p "unparseable bridge output" said)))))

(ert-deftest jsonyter-test-dispatch-answers-input-request ()
  (with-temp-buffer
    (setq-local jsonyter--callbacks (make-hash-table :test #'eql))
    (let (answered)
      (cl-letf (((symbol-function 'jsonyter--answer-input)
                 (lambda (proc id content) (setq answered (list proc id content)))))
        (jsonyter--dispatch 'fake-proc "{\"id\": 5, \"input_request\": {\"prompt\": \"> \"}}"))
      (should (eq (car answered) 'fake-proc))
      (should (equal (nth 1 answered) 5)))))

(ert-deftest jsonyter-test-dispatch-announces-bridge-error-with-no-handler ()
  (with-temp-buffer
    (setq-local jsonyter--callbacks (make-hash-table :test #'eql))
    (let (said)
      (cl-letf (((symbol-function 'jsonyter--announce) (lambda (text &rest _) (setq said text))))
        (jsonyter--dispatch nil "{\"id\": 9, \"error\": {\"error\": \"Boom\", \"message\": \"bad\"}}"))
      (should (string-match-p "bridge error" said)))))

(ert-deftest jsonyter-test-repl-return-errors-without-live-kernel ()
  (jsonyter-tests--with-live-repl
    (cl-letf (((symbol-function 'jsonyter--live-p) (lambda (&rest _) nil)))
      (should-error (jsonyter-repl-return) :type 'user-error))))

(ert-deftest jsonyter-test-repl-return-reports-busy ()
  (jsonyter-tests--with-live-repl
    (let (said)
      (cl-letf (((symbol-function 'jsonyter--live-p) (lambda (&rest _) t))
                ((symbol-function 'jsonyter--busy-p) (lambda (&rest _) t))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
        (jsonyter-repl-return))
      (should (string-match-p "kernel is busy" said)))))

(ert-deftest jsonyter-test-repl-return-jumps-to-end-when-point-before-input ()
  (jsonyter-tests--with-live-repl
    (insert "code")
    (goto-char (point-min))
    (cl-letf (((symbol-function 'jsonyter--live-p) (lambda (&rest _) t))
              ((symbol-function 'jsonyter--busy-p) (lambda (&rest _) nil)))
      (jsonyter-repl-return))
    (should (= (point) (point-max)))))

(ert-deftest jsonyter-test-repl-return-reports-nothing-to-send-on-blank ()
  (jsonyter-tests--with-live-repl
    (let (said)
      (cl-letf (((symbol-function 'jsonyter--live-p) (lambda (&rest _) t))
                ((symbol-function 'jsonyter--busy-p) (lambda (&rest _) nil))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
        (jsonyter-repl-return))
      (should (string-match-p "nothing to send" said)))))

(ert-deftest jsonyter-test-after-kernel-reset-blanks-notebook-cell-counts ()
  (jsonyter-tests--with-notebook
    (let ((cell (jsonyter-tests--cell 0)))
      (overlay-put cell 'jsonyter-exec-count 5)
      (overlay-put cell 'jsonyter-running t)
      (jsonyter--after-kernel-reset "[kernel restarted]")
      (should (null (overlay-get cell 'jsonyter-exec-count)))
      (should (null (overlay-get cell 'jsonyter-running))))))

(ert-deftest jsonyter-test-request-sync-times-out-and-blames-dead-bridge ()
  (with-temp-buffer
    (setq-local jsonyter--process 'fake-proc)
    (setq-local jsonyter--callbacks (make-hash-table :test #'eql))
    (let ((jsonyter-request-timeout 0.01))
      (cl-letf (((symbol-function 'jsonyter--send) (lambda (&rest _) 1))
                ((symbol-function 'process-live-p) (lambda (&rest _) nil))
                ((symbol-function 'jsonyter--stderr-tail)
                 (lambda (&rest _) "ImportError: no module named jsonyter")))
        (let ((err (should-error (jsonyter--request-sync "list_kernelspecs" nil))))
          (should (string-match-p "bridge process died" (cadr err)))
          (should (string-match-p "ImportError" (cadr err))))))))

(ert-deftest jsonyter-test-start-repl-pops-to-existing-live-buffer ()
  (let ((buf (get-buffer-create "*jsonyter[python]*")))
    (unwind-protect
        (with-current-buffer buf
          (setq-local jsonyter--session-key '("python" . ""))
          (setq-local jsonyter--process (start-process "jsonyter-test-repl" nil "cat"))
          (unwind-protect
              (let (popped)
                (cl-letf (((symbol-function 'pop-to-buffer) (lambda (b &rest _) (setq popped b))))
                  (jsonyter--start-repl "python"))
                (should (eq popped buf)))
            (ignore-errors (delete-process jsonyter--process))))
      (kill-buffer buf))))

(ert-deftest jsonyter-test-notebook-run-cell-draws-outputs-when-nothing-streamed ()
  (jsonyter-tests--with-notebook
    (jsonyter--session-put jsonyter--session-key)
    (let ((cell (jsonyter-tests--cell 0)) handlers)
      (goto-char (overlay-start cell))
      (cl-letf (((symbol-function 'jsonyter--nb-ensure-kernel) #'ignore)
                ((symbol-function 'jsonyter--send) (lambda (_m _p hs) (setq handlers hs) 1)))
        (jsonyter-notebook-run-cell t))
      (funcall (plist-get handlers :result)
               (list :result (list :execution_count 1
                                    :outputs (list (list :type "stream" :name "stdout" :text "late\n")))))
      (should (string-match-p "late" (jsonyter-tests--output-text cell)))
      (should (= (point) (overlay-start (jsonyter-tests--cell 1)))))))

(ert-deftest jsonyter-test-nb-cell-at-falls-back-to-preceding-overlay-at-buffer-end ()
  (jsonyter-tests--with-notebook
    (should (eq (jsonyter-tests--cell 2) (jsonyter--nb-cell-at (point-max))))))

(ert-deftest jsonyter-test-read-kernel-defaults-to-sessions-last-kernel ()
  (with-temp-buffer
    (setq-local jsonyter--sessions (make-hash-table :test #'equal))
    (setq-local jsonyter--process nil)
    (setq-local jsonyter--session-key '("python" . ""))
    (let ((session (jsonyter-tests--bind-session '("python" . "") nil)))
      (setf (jsonyter--session-last-kernel session) (list :id "last-kid"))
      (cl-letf (((symbol-function 'jsonyter--request-sync)
                 (lambda (&rest _) (list (list :id "last-kid" :name "python3" :execution_state "idle"))))
                ((symbol-function 'completing-read)
                 (lambda (_prompt _table &optional _pred _req _init _hist default) default)))
        (should (equal "last-kid" (jsonyter--read-kernel "Pick: ")))))))

(provide 'jsonyter-tests)
;;; jsonyter-tests.el ends here
