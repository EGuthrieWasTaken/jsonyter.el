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
    (eh-expect-display-image (car positions) :type 'png)
    ;; tall-plot.png is 300x500. Not asserted as an exact width -- see
    ;; `jy-expect-decoded-image' for why that would test the font rather
    ;; than the package.
    (jy-expect-decoded-image (car positions) 300 500)))

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

(eh-scenario jsonyter/notebook-sliced-image-has-no-background-bands
  :doc "The other two slicing scenarios stop at the display properties:
        distinct increasing y-offsets, and `line-spacing' reading nil.
        Both stay true even if every sliced row sat on its own bar of
        background -- neither one looks at an actual pixel.  This one
        does. `solid-plot.png' is a single flat colour top to bottom,
        240px tall, with no gradient or gridline anywhere in it, so
        every pixel inside its rendered box has to be that one colour;
        a second colour showing up can only be a gap cut through it by
        `line-spacing' leaking into the buffer, or a slice a fraction
        short of the line it sits on."
  :fixture "solid-plot.ipynb"
  :needs (:cairo t)
  :tags (jsonyter notebook visual slicing)

  ;; Give the buffer the whole frame, scrolled to its own top, rather
  ;; than trusting either is already so: scenario teardown kills the
  ;; buffers a scenario creates but never touches window configuration
  ;; (`eh--scenario-teardown'), so a window split earlier in the run
  ;; carries over -- as it did the first time this ran inside the full
  ;; suite, where a normal-sized frame split by an earlier scenario left
  ;; less than half the height on screen. Needed so the image's whole
  ;; box, mode-line excluded, ends up on screen for `eh-shot-to-file' to
  ;; capture -- a partly cut-off image would fail below for a reason
  ;; that has nothing to do with slicing.
  (delete-other-windows)
  (goto-char (point-min))
  (set-window-start (selected-window) (point-min))
  (eh-settle)
  (let* ((region (jy-cell-output-region 1))
         (positions (jy-image-positions (nth 0 region) (nth 1 region))))
    (eh-expect positions "the plot cell's output must carry an image")
    (eh-expect (> (length positions) 1)
               "solid-plot.png is 240px tall and must be sliced into more than one row")
    (eh-expect (and (pos-visible-in-window-p (car positions))
                    (pos-visible-in-window-p (1- (nth 1 region))))
               "the sliced image does not fit in the window -- shrink the fixture \
or the scenario's own bookkeeping, not the assertion below")
    (let ((colors (jy-bbox-unique-colors (jy-image-pixel-bbox (car positions)))))
      (eh-expect-equal
       colors 1
       (format "the sliced image shows %d distinct colours inside its box, not 1 -- \
something other than its own fill is drawn through it" colors)))))

(eh-scenario jsonyter/notebook-sliced-image-tiles-under-display-line-numbers
  :doc "The scenario above passes in a bare buffer and always did, while a
        user whose config has `display-line-numbers-mode' on
        `prog-mode-hook' -- a notebook buffer is a `python-mode' buffer
        -- kept seeing every plot drawn through a set of blinds.  Line
        numbers put a glyph from the buffer's text font on every row, and
        that glyph asks the row for the font's full ascent above the
        baseline; an image slice with the default `:ascent 50' puts its
        own baseline at its middle.  Neither is wrong on its own, but
        together the row is font-ascent plus half a slice tall, and the
        difference is drawn as a band of background under every slice.
        Nothing about `line-spacing' or the slice geometry moves, so the
        other slicing scenarios cannot see it: this one opens the fixture
        with the user's hook in place and asserts, first, that each
        sliced row is exactly one text line tall -- the legible failure
        -- and then the same single-colour pixel check as above."
  :needs (:cairo t)
  :tags (jsonyter notebook visual slicing)

  ;; The hook is global; put it back whatever happens, or every later
  ;; prog-mode buffer in this session gets line numbers it did not ask for.
  (add-hook 'prog-mode-hook #'display-line-numbers-mode)
  (unwind-protect
      (progn
        (eh-open-fixture "solid-plot.ipynb")
        (eh-expect display-line-numbers
                   "the hook must have switched line numbers on in the notebook buffer, \
or this scenario is not testing anything")
        ;; Same reasoning as the scenario above: the whole image has to be
        ;; on screen for the screenshot to see all of it.
        (delete-other-windows)
        (goto-char (point-min))
        (set-window-start (selected-window) (point-min))
        (eh-settle)
        (let* ((region (jy-cell-output-region 1))
               (positions (jy-image-positions (nth 0 region) (nth 1 region)))
               (line-height (default-font-height)))
          (eh-expect positions "the plot cell's output must carry an image")
          (eh-expect (> (length positions) 1)
                     "solid-plot.png is 240px tall and must be sliced into more than one row")
          (eh-expect (and (pos-visible-in-window-p (car positions))
                          (pos-visible-in-window-p (1- (nth 1 region))))
                     "the sliced image does not fit in the window -- shrink the fixture \
or the scenario's own bookkeeping, not the assertion below")
          (let ((heights (mapcar (lambda (pos)
                                   (save-excursion (goto-char pos) (line-pixel-height)))
                                 positions)))
            (eh-expect (seq-every-p (lambda (h) (= h line-height)) heights)
                       (format "every sliced row must be exactly one text line (%dpx) tall \
with line numbers on; got %S -- each extra pixel is a band of background under that slice"
                               line-height heights)))
          (let ((colors (jy-bbox-unique-colors (jy-image-pixel-bbox (car positions)))))
            (eh-expect-equal
             colors 1
             (format "with line numbers on, the sliced image shows %d distinct colours \
inside its box, not 1 -- something other than its own fill is drawn through it" colors)))))
    (remove-hook 'prog-mode-hook #'display-line-numbers-mode)))

(eh-scenario jsonyter/image-fits-to-the-frame-showing-it-not-the-selected-one
  :doc "Kernel output arrives through `jsonyter--filter', a process
        filter: it sets `current-buffer' but has no reason to also
        select the frame that is actually showing that buffer, and
        normally does not.  `default-font-height' has no frame argument
        at all and always measures whichever frame Emacs currently
        calls selected (see its own docstring) -- invisible in a
        single-frame Emacs, where the two never differ, but not in a
        daemon with more than one `emacsclient' frame open, where they
        routinely do.  This scenario is the one place batch ERT cannot
        follow: it needs a *second real frame*, which `make-frame'
        refuses to create without a display.  Puts one in play, with a
        deliberately different font, and confirms `jsonyter--display-
        frame' still resolves to the frame actually showing the buffer
        rather than to the one merely selected."
  :fixture "solid-plot.ipynb"
  :needs (:graphic t)
  :tags (jsonyter notebook visual slicing)

  (let* ((real-frame (selected-frame))
         (buffer (current-buffer))
         (other-frame (make-frame '((font . "DejaVu Sans Mono-32")
                                     (name . "jsonyter-other-frame")))))
    (unwind-protect
        (progn
          ;; A fresh frame's initial window defaults to showing whatever
          ;; buffer was current when it was made -- this one, unless told
          ;; otherwise -- which would leave the fixture visible on *both*
          ;; frames and make `get-buffer-window' free to return either.
          ;; The scenario is about a frame that is merely selected while
          ;; showing something else entirely, so make that true.
          (set-window-buffer (frame-selected-window other-frame)
                              (get-buffer-create "*scratch*"))
          (select-frame other-frame)
          (eh-expect (/= (default-font-height) (with-selected-frame real-frame (default-font-height)))
                     "the two frames must actually have different line heights, \
or this scenario is not testing anything")
          (with-current-buffer buffer
            (eh-expect (eq (jsonyter--display-frame) real-frame)
                       "jsonyter--display-frame must resolve to the frame actually \
showing this buffer, not the merely-selected other-frame")
            (eh-expect-equal
             (with-selected-frame (jsonyter--display-frame) (default-font-height))
             (with-selected-frame real-frame (default-font-height))
             "an image must be measured against the buffer's own frame, not \
whichever frame happened to be selected when it arrived")))
      ;; `eh--scenario-teardown' kills buffers the scenario created but
      ;; never touches window/frame configuration (jsonyter/notebook-
      ;; sliced-image-has-no-background-bands' own comment above found
      ;; this out the hard way) -- so a leaked frame is this scenario's
      ;; to clean up, not the next one's problem.
      (when (frame-live-p other-frame) (delete-frame other-frame))
      (when (frame-live-p real-frame) (select-frame real-frame)))))

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
    (eh-expect-display-image (car positions) :type 'png)
    ;; plot.png is 120x90.
    (jy-expect-decoded-image (car positions) 120 90))

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
