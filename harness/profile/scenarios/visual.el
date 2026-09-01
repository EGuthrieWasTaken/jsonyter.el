;;; visual.el --- what only a real frame can answer -*- lexical-binding: t; -*-

;; Everything in this file needs a graphical Emacs with a live frame, and
;; skips legibly without one (`:needs (:cairo t)').  Under batch ERT they
;; all report `skipped' -- correct, and the reason `harness/run-batch.sh'
;; is a fast loop rather than a substitute for a container run.
;;
;; The budget for pixel baselines is deliberately small (emacs-harness
;; DESIGN 8.3: on the order of 10-15 for a whole profile).  Anything about
;; text, faces, properties, overlays or read-only-ness belongs in the
;; other files, where the assertion is exact and the failure message is
;; legible.  What is left here is the set of questions whose answer is
;; literally "did this rasterise": an image that decoded versus a
;; placeholder box, and a tall image that became N drawable rows rather
;; than one blob.

(eh-scenario jsonyter/notebook-image-actually-decodes
  :doc "A stored image/png mimebundle in an .ipynb has to become a real
        decoded image, not a placeholder.  Asserting the display property
        alone would pass on an image spec pointing at bytes Emacs could
        not read; asserting its pixel size is what needs the decoder to
        have run."
  :fixture "demo.ipynb"
  :needs (:cairo t)
  :tags (jsonyter notebook visual)

  (let* ((region (jy-cell-output-region 3))
         (positions (jy-image-positions (nth 0 region) (nth 1 region))))
    (eh-expect positions "the plot cell's output must carry an image")
    (eh-expect-display-image (car positions) :type 'png :min-width 300)))

(eh-scenario jsonyter/notebook-image-is-sliced-into-drawable-rows
  :doc "A tall image is inserted sliced, one buffer row per slice, so a
        notebook can be scrolled through a figure instead of jumping past
        it whole.  The assertion is on slice geometry: same source image
        for every slice, distinct y offsets, in top-to-bottom order --
        which is exactly what a click has to resolve a pixel coordinate
        from."
  :fixture "demo.ipynb"
  :needs (:cairo t)
  :tags (jsonyter notebook visual slicing)

  (let* ((region (jy-cell-output-region 3))
         (positions (jy-image-positions (nth 0 region) (nth 1 region)))
         (slices (delq nil
                       (mapcar (lambda (pos)
                                 (let ((disp (get-char-property pos 'display)))
                                   (and (consp disp) (consp (car disp))
                                        (eq (caar disp) 'slice)
                                        (car disp))))
                               positions))))
    (eh-expect (> (length slices) 1)
               "a tall image must be sliced into more than one row")
    (let ((ys (mapcar (lambda (slice) (nth 2 slice)) slices)))
      (eh-expect-equal ys (sort (copy-sequence ys) #'<)
                       "slice y offsets must be in top-to-bottom order")
      (eh-expect-equal (length (delete-dups (copy-sequence ys))) (length ys)
                       "slice y offsets must all be distinct"))
    (eh-expect-display-image (car positions) :type 'png :slices t)))

(eh-scenario jsonyter/notebook-line-spacing-is-dropped-so-slices-tile
  :doc "A sliced image tiles only if every buffer row is exactly as tall
        as the slice it shows.  `line-spacing' breaks that -- Emacs adds
        the leading below an image glyph as readily as below a character
        -- so a plot ends up drawn through a set of blinds.  It cannot be
        fixed per line, so the mode drops it buffer-wide; this pins that
        it does, and that a buffer with none is left alone."
  :fixture "demo.ipynb"
  :needs (:cairo t)
  :tags (jsonyter notebook visual slicing)

  (eh-expect-equal line-spacing nil
                   "a notebook buffer must not carry line-spacing while slicing"))

(eh-scenario jsonyter/repl-image-rasterises-in-a-live-frame
  :doc "The same question for the REPL, and the one place a screenshot
        earns its cost: the image arrives over the wire as base64 in a
        mimebundle, is decoded, inserted, and actually laid out.  The
        frame export is what proves redisplay got as far as pixels."
  :needs (:cairo t)
  :tags (jsonyter repl visual)

  (jy-start-repl)
  (eh-type-text "small_plot()")
  (eh-send-keys "RET")
  (eh-wait (lambda () (jy-image-positions)) 20)
  (jy-wait-idle)
  (eh-settle)

  (let ((positions (jy-image-positions)))
    (eh-expect positions "the REPL must show a decoded image")
    (eh-expect-display-image (car positions) :type 'png :min-width 120))

  (eh-expect-no-error
   (eh-shot-to-file (expand-file-name
                     "repl-image.png"
                     (eh--scenario-artifact-dir 'jsonyter/repl-image-rasterises-in-a-live-frame)))))

(eh-scenario jsonyter/mode-line-tag-reaches-the-rendered-mode-line
  :doc "Everywhere else the kernel state is asserted through
        `jsonyter--mode-line-string'.  That is the value; this is the
        only scenario that checks it survives into the mode line a user
        actually reads, which needs a frame with one."
  :needs (:graphic t)
  :tags (jsonyter repl visual)

  (jy-start-repl)
  (eh-expect-mode-line-matches ":idle"))

(eh-scenario jsonyter/notebook-does-not-drift-visually
  :doc "One full-frame reference shot of a rendered notebook, the
        \"here is what this looks like\" baseline DESIGN 8.3 budgets for.
        It skips until somebody runs `eh baseline accept' for this
        Emacs version, geometry and theme -- an unestablished baseline is
        not a regression, and a committed PNG would only ever match the
        one environment it was captured in."
  :fixture "demo.ipynb"
  :needs (:cairo t)
  :tags (jsonyter notebook visual)

  (goto-char (point-min))
  (eh-settle)
  (eh-expect-no-visual-drift "notebook-rendered"))
