;;; org-appear-mathjax.el --- Org MathJax previews that reveal at point -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Thysrael
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: Grant
;; Maintainer: Grant
;; Package-Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (org "9.6") (mathjax "0.1"))
;; Keywords: org, tex, convenience

;; Adapted from Thysrael's markdown-ts-appear-mathjax.el.  The Org syntax
;; detector and minor-mode integration replace the Markdown Tree-sitter
;; detector.  See README.md for attribution and usage.

;;; Commentary:
;; Render Org LaTeX fragments and environments with MathJax.  Point inside a
;; formula reveals its source; leaving the formula restores its preview.
;; Requires the GNU ELPA mathjax package and Node.js, but no TeX distribution.
;; Detection, worker, cache, reveal and editing presentation live in this file.
;; Manual \tag is supported; document-wide automatic numbering and
;; cross-formula references are deliberately not implemented.
;;
;; Enable with:
;;   (add-hook 'org-mode-hook #'org-appear-mathjax-mode)

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'image)
(require 'button)
(require 'org)
(require 'org-element)

(declare-function mathjax-available-p "mathjax")
(declare-function posframe-show "posframe")
(declare-function posframe-hide "posframe")
(declare-function posframe-poshandler-point-top-left-corner "posframe")
(declare-function posframe-poshandler-point-bottom-left-corner "posframe")
(declare-function posframe-hidehandler-when-buffer-switch "posframe")

(defgroup org-appear-mathjax nil
  "Org MathJax previews that reveal source at point."
  :group 'org
  :prefix "org-appear-mathjax-")

(defvar org-appear-mathjax-mode)
(defvar org-appear-mathjax--objects)

(defun org-appear-mathjax--set-option (option value)
  "Set OPTION to VALUE and refresh buffers using its default."
  (set-default option value)
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and (bound-and-true-p org-appear-mathjax-mode)
                 (not (local-variable-p option)))
        (when (eq option 'org-appear-mathjax-edit-preview-style)
          (mapc #'org-appear-mathjax--clear-panel org-appear-mathjax--objects))
        (if (memq option '(org-appear-mathjax-macros
                           org-appear-mathjax-siunitx-compat))
            (org-appear-mathjax-refresh)
          (org-appear-mathjax--redisplay))))))

(defcustom org-appear-mathjax-edit-preview nil
  "Show a live preview while editing display math.
Nil renders when point leaves the formula.  Inline math always uses
plain-source editing.  See `org-appear-mathjax-edit-preview-style'."
  :type 'boolean :safe #'booleanp :group 'org-appear-mathjax
  :initialize #'custom-initialize-default :set #'org-appear-mathjax--set-option)

(defcustom org-appear-mathjax-edit-preview-style 'panel
  "Presentation used for live previews while editing display math.
`panel' shows source above a framed preview in the buffer.
`posframe' leaves the source untouched and shows a floating preview beside
it, falling back below the formula when there is insufficient room.
The latter requires the optional posframe package and a graphic display."
  :type '(choice (const :tag "In-buffer panel" panel)
                 (const :tag "Floating posframe" posframe))
  :group 'org-appear-mathjax
  :initialize #'custom-initialize-default :set #'org-appear-mathjax--set-option)

(defcustom org-appear-mathjax-delay 0.2
  "Idle seconds before reconciling edits and updating a live preview."
  :type 'number :group 'org-appear-mathjax)

(defcustom org-appear-mathjax-macros ""
  "MathJax macro definitions prepended independently to every formula."
  :type 'string :group 'org-appear-mathjax
  :initialize #'custom-initialize-default :set #'org-appear-mathjax--set-option)

(defcustom org-appear-mathjax-siunitx-compat nil
  "Whether to expand simple \\qty{NUMBER}{UNIT} expressions before rendering.
Plain numbers and scientific notation such as 5.67e-8 and e3 are supported.
This is not a complete implementation of the LaTeX siunitx package."
  :type 'boolean :safe #'booleanp :group 'org-appear-mathjax
  :initialize #'custom-initialize-default :set #'org-appear-mathjax--set-option)

(defcustom org-appear-mathjax-scale 1.0
  "Scale of previews relative to the source font's x-height."
  :type 'number :group 'org-appear-mathjax
  :initialize #'custom-initialize-default :set #'org-appear-mathjax--set-option)

(defcustom org-appear-mathjax-inline-ascent 'baseline
  "Vertical alignment of inline previews.
`baseline' aligns the mathematical baseline with surrounding text.
`center' vertically centers the image, matching Xenops image overlays."
  :type '(choice (const :tag "Mathematical baseline" baseline)
                 (const :tag "Image center" center))
  :group 'org-appear-mathjax
  :initialize #'custom-initialize-default :set #'org-appear-mathjax--set-option)

(defcustom org-appear-mathjax-center-display t
  "Center display formulas in reading mode."
  :type 'boolean :group 'org-appear-mathjax
  :initialize #'custom-initialize-default :set #'org-appear-mathjax--set-option)

(defcustom org-appear-mathjax-cache-directory
  (expand-file-name "emacs/org-appear-mathjax/"
                    (or (getenv "XDG_CACHE_HOME") "~/.cache/"))
  "Directory containing color-independent MathJax results."
  :type 'directory :group 'org-appear-mathjax)

(defcustom org-appear-mathjax-timeout 30
  "Maximum seconds to wait for a worker response."
  :type 'number :group 'org-appear-mathjax)

(defface org-appear-mathjax-source
  '((t :inherit default :extend t))
  "Background of source in a live editing preview, independent of `hl-line'."
  :group 'org-appear-mathjax)

(defface org-appear-mathjax-preview
  '((t :inherit default :extend t :box (:line-width (-1 . -1) :color "gray50")))
  "Border and background of a live editing preview."
  :group 'org-appear-mathjax)

(defvar-local org-appear-mathjax-preview-functions nil
  "Functions called with (OVERLAY IMAGE) when a preview changes.
IMAGE is nil on failure.  Consumers can reuse ordinary image display overlays.")

(defvar org-appear-mathjax--process nil)
(defvar org-appear-mathjax--cache (make-hash-table :test #'equal))
(defvar org-appear-mathjax--images (make-hash-table :test #'equal :weakness 'value))
(defvar org-appear-mathjax--pending (make-hash-table :test #'equal))
(defvar-local org-appear-mathjax--objects nil)
(defvar-local org-appear-mathjax--current nil)
(defvar-local org-appear-mathjax--timer nil)
(defvar-local org-appear-mathjax--dirty nil)
(defvar-local org-appear-mathjax--managed nil)

;;; Worker and content cache

(defconst org-appear-mathjax--javascript
  "'use strict';
const bundle = process.argv[1];
process.argv[2] = JSON.stringify({options: {enableAssistiveMml: false}});
const write = process.stdout.write.bind(process.stdout);
process.stdout.write = (chunk, ...args) => write(chunk + '\\n', ...args);
require(bundle);
MathJax.startup.promise.then(() => {
  const {startup, config} = MathJax;
  MathJax.tex2svg = (source, options) => {
    const document = MathJax._.mathjax.mathjax.document('', {
      ...config.options,
      InputJax: new startup.constructors.tex(config.tex),
      OutputJax: startup.output,
    });
    return document.convert(source, options);
  };
});"
  "Embedded worker shim: persistent code/fonts, isolated TeX state per request.")

(defun org-appear-mathjax--stop (process message)
  "Stop PROCESS and fail outstanding callbacks with MESSAGE."
  (let ((queue (process-get process 'queue)) (buffer (process-buffer process)))
    (process-put process 'queue nil)
    (process-put process 'tail nil)
    (when (eq process org-appear-mathjax--process)
      (setq org-appear-mathjax--process nil))
    (set-process-sentinel process #'ignore)
    (when (process-live-p process) (delete-process process))
    (when (buffer-live-p buffer) (kill-buffer buffer))
    (dolist (callback queue) (funcall callback (list (cons 'error message)) t))))

(defun org-appear-mathjax-stop ()
  "Stop the worker; the next uncached request starts it again."
  (interactive)
  (when org-appear-mathjax--process
    (org-appear-mathjax--stop org-appear-mathjax--process "MathJax worker stopped")))

(defun org-appear-mathjax--filter (process text)
  "Parse complete JSON lines from PROCESS's TEXT exactly once."
  (with-current-buffer (process-buffer process)
    (goto-char (point-max))
    (save-excursion (insert text))
    (while-let (((process-live-p process)) ((search-forward "\n" nil t))
                (end (point))
                (data (condition-case err
                          (save-restriction
                            (narrow-to-region (point-min) (1- end))
                            (goto-char (point-min))
                            (json-parse-buffer :object-type 'alist))
                        (json-error (org-appear-mathjax--stop process (error-message-string err)) nil))))
      (delete-region (point-min) end)
      (let ((queue (process-get process 'queue)))
        (process-put process 'queue (cdr queue))
        (unless (cdr queue) (process-put process 'tail nil))
        (funcall (car queue) data)))))

(defun org-appear-mathjax--send (formula display callback)
  "Send FORMULA in DISPLAY style; call CALLBACK with data and optional setup flag."
  (unless (process-live-p org-appear-mathjax--process)
    (unless (and (require 'mathjax nil t) (mathjax-available-p))
      (error "Install the GNU ELPA mathjax package and Node.js"))
    (let ((buffer (generate-new-buffer " *appear-mathjax*"))
          (bundle (expand-file-name "math2svg.js" (file-name-directory (symbol-file 'mathjax-render)))))
      (condition-case err
          (setq org-appear-mathjax--process
                (make-process
                 :name "appear-mathjax" :buffer buffer :noquery t
                 :connection-type 'pipe :coding 'utf-8-unix
                 :command (list "node" "-e" org-appear-mathjax--javascript bundle)
                 :filter #'org-appear-mathjax--filter
                 :sentinel (lambda (process event)
                             (when (memq (process-status process) '(exit signal))
                               (org-appear-mathjax--stop process event)))))
        (error (kill-buffer buffer) (signal (car err) (cdr err))))))
  (let* ((process org-appear-mathjax--process) (cell (list callback))
         (tail (process-get process 'tail)))
    (if tail (setcdr tail cell) (process-put process 'queue cell))
    (process-put process 'tail cell)
    (condition-case err
        (process-send-string process
                             (concat (json-serialize (list :math formula :format "tex"
                                                           :display (if display t :false) :em 16 :ex 8)) "\n"))
      (error (org-appear-mathjax--stop process (error-message-string err))))
    process))

(defun org-appear-mathjax--attribute (tag name)
  "Return double-quoted attribute NAME from SVG TAG."
  (when (string-match (concat "[[:space:]]" name "=\"\\([^\"]*\\)\"") tag)
    (match-string 1 tag)))

(defun org-appear-mathjax--normalize (svg display)
  "Return a color-independent cache entry for SVG in DISPLAY style."
  (unless (string-match "<svg\\(?:[[:space:]][^>]*\\)?>" svg)
    (error "MathJax returned no SVG"))
  (let* ((beg (match-beginning 0)) (end (match-end 0)) (tag (match-string 0 svg))
         (box (mapcar #'string-to-number (split-string (or (org-appear-mathjax--attribute tag "viewBox") ""))))
         (height-ex (string-to-number (or (org-appear-mathjax--attribute tag "height") "0")))
         (style (org-appear-mathjax--attribute tag "style"))
         (wide (and (null box) style (string-match "min-width: *\\([0-9.]+\\)ex" style)
                    (string-to-number (match-string 1 style))))
         (align (and style (string-match "vertical-align: *\\(-?[0-9.]+\\)ex" style)
                     (string-to-number (match-string 1 style)))))
    (unless (and (> height-ex 0) (or (= (length box) 4) wide))
      (error "MathJax returned invalid SVG dimensions"))
    (let ((width (if wide (* wide 4.42) (/ (nth 2 box) 100.0)))
          (height (if wide (* height-ex 4.42) (/ (nth 3 box) 100.0))))
      (when wide
        (setq tag (concat (substring tag 0 -1)
                          (format " viewBox=\"0 0 %.6f %.6f\">" (* wide 8) (* height-ex 8)))))
      (dolist (pair `(("width" . ,width) ("height" . ,height)))
        (setq tag (replace-regexp-in-string
                   (concat "[[:space:]]" (car pair) "=\"[^\"]*\"")
                   (format " %s=\"%.6fpt\"" (car pair) (cdr pair)) tag t t)))
      (list :svg (concat (substring svg 0 beg) tag (substring svg end))
            :width width :ex (/ height height-ex)
            :ascent (if display -1 (max 0 (min 100 (round (* 100 (+ 1 (/ (or align 0) height-ex)))))))))))

;;; Lightweight siunitx compatibility

(defun org-appear-mathjax--escaped-p (position)
  "Return non-nil when POSITION follows an odd run of backslashes."
  (save-excursion
    (goto-char position)
    (while (eq (char-before) ?\\) (backward-char))
    (cl-oddp (- position (point)))))

(defun org-appear-mathjax--braced-argument ()
  "Read a braced argument after its opening brace at point.
Return its contents and leave point after the closing brace, or return nil."
  (let ((beg (point)) (depth 1))
    (while (and (> depth 0) (not (eobp)))
      (let ((position (point)) (character (char-after)))
        (unless (org-appear-mathjax--escaped-p position)
          (cond ((eq character ?{) (setq depth (1+ depth)))
                ((eq character ?}) (setq depth (1- depth)))))
        (forward-char)))
    (when (= depth 0)
      (buffer-substring-no-properties beg (1- (point))))))

(defun org-appear-mathjax--expand-number (number)
  "Return TeX for NUMBER, expanding common siunitx scientific notation."
  (if (string-match
       "\\`\\([+-]?\\(?:[0-9]+\\(?:\\.[0-9]*\\)?\\|\\.[0-9]+\\)\\)?[eE]\\([+-]?[0-9]+\\)\\'"
       number)
      (let ((mantissa (match-string 1 number))
            (exponent (match-string 2 number)))
        (concat (if (or (null mantissa) (string-empty-p mantissa))
                    "10"
                  (concat mantissa "\\times10"))
                "^{" exponent "}"))
    number))

(defun org-appear-mathjax--expand-siunitx (body)
  "Expand simple \\qty{NUMBER}{UNIT} expressions in BODY."
  (with-temp-buffer
    (insert body)
    (goto-char (point-min))
    (while (re-search-forward "\\\\qty{" nil t)
      (let ((start (match-beginning 0)))
        (unless (org-appear-mathjax--escaped-p start)
          (let ((number (org-appear-mathjax--braced-argument)) unit)
            (when number
              (skip-chars-forward " \t\n")
              (when (eq (char-after) ?{)
                (forward-char)
                (setq unit (org-appear-mathjax--braced-argument))))
            (when (and number unit)
              (delete-region start (point))
              (insert (org-appear-mathjax--expand-number number)
                      "\\,\\mathrm{" unit "}"))))))
    (buffer-substring-no-properties (point-min) (point-max))))

(defun org-appear-mathjax--key (body display)
  "Return the content key for BODY, DISPLAY and this buffer's macros."
  (secure-hash 'sha1 (format "standalone-v1\0%s\0%S\0%s"
                             body display org-appear-mathjax-macros)))

(defun org-appear-mathjax--entry (key)
  "Return KEY's cached result, reading disk once when available."
  (or (gethash key org-appear-mathjax--cache)
      (let ((file (expand-file-name (concat key ".json") org-appear-mathjax-cache-directory)))
        (when (file-readable-p file)
          (condition-case nil
              (with-temp-buffer
                (insert-file-contents file)
                (puthash key (json-parse-buffer :object-type 'plist) org-appear-mathjax--cache))
            (json-error nil))))))

(defun org-appear-mathjax-render (body display callback)
  "Return cached BODY in DISPLAY style, or nil and call CALLBACK when ready.
Results are plists containing SVG geometry or an :error string.  Identical
pending requests share a compile.  Setup failures are not cached."
  (let* ((body (if org-appear-mathjax-siunitx-compat
                   (org-appear-mathjax--expand-siunitx body)
                 body))
         (key (org-appear-mathjax--key body display))
         (entry (org-appear-mathjax--entry key)))
    (if entry entry
      (let ((waiting (gethash key org-appear-mathjax--pending)))
        (puthash key (cons callback waiting) org-appear-mathjax--pending)
        (unless waiting
          (let ((directory org-appear-mathjax-cache-directory)
                (formula (concat org-appear-mathjax-macros "\n" body "\n"))
                done timer process)
            (cl-labels
                ((finish (data &optional setup)
                   (unless done
                     (setq done t)
                     (when timer (cancel-timer timer))
                     (let ((callbacks (gethash key org-appear-mathjax--pending)) result)
                       (remhash key org-appear-mathjax--pending)
                        (setq result
                              (condition-case err
                                  (if (alist-get 'error data)
                                      (list :error (alist-get 'error data))
                                    (org-appear-mathjax--normalize (alist-get 'svg data) display))
                                (error (setq setup t) (list :error (error-message-string err)))))
                        (unless setup
                          (puthash key result org-appear-mathjax--cache)
                          (condition-case err
                              (progn
                                (make-directory directory t)
                                (let ((coding-system-for-write 'utf-8-unix))
                                  (with-temp-file (expand-file-name (concat key ".json") directory)
                                    (insert (json-serialize result)))))
                            (file-error (message "MathJax cache: %s" (error-message-string err)))))
                       (dolist (ready callbacks)
                         (condition-case err (funcall ready result)
                           (error (message "MathJax callback: %s" (error-message-string err)))))))))
              (setq timer (run-at-time
                           org-appear-mathjax-timeout nil
                           (lambda ()
                             (if (process-live-p process)
                                 (org-appear-mathjax--stop process "MathJax worker timed out")
                               (finish '((error . "MathJax worker timed out")) t)))))
              (condition-case err
                  (setq process (org-appear-mathjax--send formula display #'finish))
                (error (run-at-time 0 nil #'finish (list (cons 'error (error-message-string err))) t)))))))
      nil)))

;;; Detection through Org's syntax parser

(defconst org-appear-mathjax--regexp
  "\\$\\|\\\\[([]\\|^[ \t]*\\\\begin{[A-Za-z0-9*]+}"
  "Regexp matching possible Org LaTeX fragment starts.")

(defun org-appear-mathjax--block (position)
  "Return the blank-line-delimited range around POSITION."
  (save-excursion
    (goto-char position)
    (cons (if (re-search-backward "\n[ \t]*\n" nil t) (match-end 0) (point-min))
          (progn (goto-char position)
                 (if (re-search-forward "\n[ \t]*\n" nil t)
                     (match-beginning 0)
                   (point-max))))))

(defun org-appear-mathjax--scan (beg end)
  "Return (KIND BEG END BODY-BEG BODY-END) records overlapping BEG..END.
Org's parser rejects delimiter-like text in source, example and comment blocks."
  (save-match-data
    (save-excursion
      (let ((start (car (org-appear-mathjax--block beg)))
            (limit (cdr (org-appear-mathjax--block end)))
            records)
        (goto-char start)
        (while (re-search-forward org-appear-mathjax--regexp limit t)
          (let* ((open (match-string-no-properties 0))
                 (context (org-element-context))
                 (type (org-element-type context)))
            (when (memq type '(latex-fragment latex-environment))
              (let* ((from (org-element-begin context))
                     (to (save-excursion
                           (goto-char (org-element-end context))
                           (skip-chars-backward " \r\t\n")
                           (point)))
                     (environment (eq type 'latex-environment))
                     (value (org-element-property :value context))
                     (delimiter (if (and (not environment)
                                         (string-match "\\`\\$\\$?" value))
                                    (match-string 0 value)
                                  open))
                     (kind (cond (environment 'environment)
                                 ((member delimiter '("$$" "\\[")) 'display)
                                 (t 'inline)))
                     (body-beg (if environment from (+ from (length delimiter))))
                     (body-end (if environment to (- to (length delimiter)))))
                (when (and (<= body-beg body-end) (< from end) (> to beg))
                  (push (list kind from to body-beg body-end) records))
                (goto-char to)))))
        (nreverse records)))))

(defun org-appear-mathjax-spans (beg end)
  "Return (KIND BEG END) math spans overlapping BEG..END."
  (mapcar (lambda (record) (seq-take record 3)) (org-appear-mathjax--scan beg end)))

(defun org-appear-mathjax-span-at (position)
  "Return the math span containing POSITION, including its closing boundary."
  (seq-find (lambda (span) (<= (nth 1 span) position (nth 2 span)))
            (org-appear-mathjax-spans (max (point-min) (1- position))
                                             (min (point-max) (1+ position)))))

(defun org-appear-mathjax--fontify (limit)
  "Protect math source from Org hiding/emphasis up to LIMIT."
  (let ((beg (point)))
    (with-silent-modifications
      (dolist (span (org-appear-mathjax-spans beg limit))
        (let ((start (max beg (nth 1 span))) (end (min limit (nth 2 span))))
          (when (< start end)
            (remove-text-properties start end '(invisible nil display nil))
            (put-text-property start end 'face 'org-latex-and-related))))))
  (goto-char limit)
  nil)

;;; Images and reveal

(defun org-appear-mathjax--image-ascent (entry)
  "Return the configured Emacs image ascent for cache ENTRY."
  (if (or (eq org-appear-mathjax-inline-ascent 'center)
          (< (plist-get entry :ascent) 0))
      'center
    (plist-get entry :ascent)))

(defun org-appear-mathjax--image (ov entry)
  "Return a theme/font matched image for OV's ready ENTRY."
  (when-let* ((svg (plist-get entry :svg))
              (window (get-buffer-window (current-buffer) t))
              ((display-images-p (window-frame window))))
    (let* ((position (overlay-start ov))
           (color (save-excursion
                    (goto-char position) (font-lock-ensure position (min (point-max) (1+ position)))
                    (apply #'format "#%02x%02x%02x"
                            (mapcar (lambda (v) (/ v 257))
                                    (color-values
                                     (or (face-foreground 'org-latex-and-related (window-frame window) t)
                                         (face-foreground 'default (window-frame window) t)))))))
           (font (or (font-at position window) (font-at 0 window "x")))
           (height (if font (aref (aref (font-get-glyphs font 0 1 "x") 0) 7)
                     (/ (frame-char-height (window-frame window)) 2.0)))
           (style (list (overlay-get ov 'org-appear-mathjax--key) color height
                        org-appear-mathjax-scale org-appear-mathjax-inline-ascent)))
      (or (gethash style org-appear-mathjax--images)
          (puthash style
                   (create-image (replace-regexp-in-string "currentColor" color svg t t) 'svg t
                                 :scale 1.0
                                 :width (max 1 (round (/ (* (plist-get entry :width) height
                                                           org-appear-mathjax-scale) (plist-get entry :ex))))
                                 :ascent (org-appear-mathjax--image-ascent entry))
                   org-appear-mathjax--images)))))

(defun org-appear-mathjax--editing-p (ov)
  "Return non-nil if OV's source is currently being revealed."
  (and (overlay-buffer ov)
       (<= (overlay-start ov) (point) (overlay-end ov))
       (or (bound-and-true-p isearch-mode) (not buffer-read-only))))

(defun org-appear-mathjax--at-point ()
  "Return this mode's overlay at point or its closing boundary."
  (or (seq-find (lambda (ov) (overlay-get ov 'org-appear-mathjax)) (overlays-at (point)))
      (and (> (point) (point-min))
           (seq-find (lambda (ov) (and (overlay-get ov 'org-appear-mathjax)
                                       (= (overlay-end ov) (point)))) (overlays-at (1- (point)))))))

(defun org-appear-mathjax-show-error ()
  "Show the current formula and its complete MathJax diagnostic."
  (interactive)
  (let* ((ov (org-appear-mathjax--at-point))
         (error (and ov (plist-get (overlay-get ov 'org-appear-mathjax--entry) :error))))
    (unless error (user-error "No MathJax error at point"))
    (with-help-window "*MathJax error*"
      (princ error) (princ "\n\n") (princ (overlay-get ov 'org-appear-mathjax--source)))))

(defun org-appear-mathjax--show-edit-preview (ov)
  "Show OV's live preview using the configured editing style."
  (if (eq org-appear-mathjax-edit-preview-style 'posframe)
      (org-appear-mathjax--show-posframe ov)
    (org-appear-mathjax--show-panel ov)))

(defun org-appear-mathjax--sync (ov)
  "Synchronize OV's source/image presentation without compiling."
  (when (overlay-buffer ov)
    (let* ((editing (org-appear-mathjax--editing-p ov))
           (modified (overlay-get ov 'org-appear-mathjax--modified))
           (image (overlay-get ov 'org-appear-mathjax--image))
           (error (plist-get (overlay-get ov 'org-appear-mathjax--entry) :error))
           (display (and (not editing) (not modified) image))
           (old (overlay-get ov 'display)))
      (overlay-put ov 'display display)
      (overlay-put ov 'before-string
                   (cond
                    ((and display org-appear-mathjax-center-display
                          (not (eq (overlay-get ov 'org-appear-mathjax--kind) 'inline)))
                     (propertize " " 'display `(space :align-to (- center (0.5 . ,image)))))
                    ((and (not editing) error (not modified)) (propertize "⚠ " 'face 'error 'help-echo error))))
      (if (and editing org-appear-mathjax-edit-preview
               (not (eq (overlay-get ov 'org-appear-mathjax--kind) 'inline))
               (save-excursion (goto-char (overlay-start ov)) (skip-chars-backward " \t")
                               (and (bolp) (progn (goto-char (overlay-end ov)) (skip-chars-forward " \t") (eolp)))))
          (org-appear-mathjax--show-edit-preview ov)
        (org-appear-mathjax--clear-panel ov))
      (when (and display (not (eq display old)))
        (run-hook-with-args 'org-appear-mathjax-preview-functions ov display)))))

(defun org-appear-mathjax--request (ov)
  "Request OV's current formula, respecting source-only editing."
  (when (and (overlay-buffer ov) (not (overlay-get ov 'org-appear-mathjax--pending))
             (get-buffer-window (current-buffer) t) (display-images-p)
             (or (not (org-appear-mathjax--editing-p ov)) org-appear-mathjax-edit-preview))
    (let ((buffer (current-buffer)) (token (list t))
          (source (overlay-get ov 'org-appear-mathjax--source)))
      (overlay-put ov 'org-appear-mathjax--pending token)
      (cl-labels
          ((ready (entry)
             (when (and (buffer-live-p buffer) (eq (overlay-buffer ov) buffer))
               (with-current-buffer buffer
                 (when (and org-appear-mathjax-mode
                            (eq token (overlay-get ov 'org-appear-mathjax--pending))
                            (equal source (buffer-substring-no-properties (overlay-start ov) (overlay-end ov))))
                   (overlay-put ov 'org-appear-mathjax--pending nil)
                   (overlay-put ov 'org-appear-mathjax--modified nil)
                   (overlay-put ov 'org-appear-mathjax--entry entry)
                   (overlay-put ov 'org-appear-mathjax--image (org-appear-mathjax--image ov entry))
                   (overlay-put ov 'help-echo (or (plist-get entry :error) source))
                   (org-appear-mathjax--sync ov)
                   (unless (overlay-get ov 'org-appear-mathjax--image)
                     (run-hook-with-args 'org-appear-mathjax-preview-functions ov nil)))))))
        (when-let* ((entry (org-appear-mathjax-render
                           (overlay-get ov 'org-appear-mathjax--body)
                           (not (eq (overlay-get ov 'org-appear-mathjax--kind) 'inline)) #'ready)))
          (ready entry))))))

(defun org-appear-mathjax--ensure (record &optional existing)
  "Update EXISTING or create a preview for RECORD, returning its overlay."
  (pcase-let* ((`(,kind ,beg ,end ,body-beg ,body-end) record)
               (body (buffer-substring-no-properties body-beg body-end))
               (source (buffer-substring-no-properties beg end))
               (key (org-appear-mathjax--key body (not (eq kind 'inline))))
               (ov (or existing
                       (seq-find (lambda (ov) (and (overlay-get ov 'org-appear-mathjax)
                                                   (= (overlay-start ov) beg))) (overlays-at beg))
                       (let ((new (make-overlay beg end nil t nil)))
                         (overlay-put new 'org-appear-mathjax t)
                         (overlay-put new 'evaporate t)
                         (overlay-put new 'priority 1)
                         (overlay-put new 'face '(:strike-through nil :underline nil :overline nil :weight normal :slant normal :box nil))
                         (overlay-put new 'modification-hooks '(org-appear-mathjax--modified))
                         (push new org-appear-mathjax--objects) new))))
    (unless (and (= end (overlay-end ov)) (equal key (overlay-get ov 'org-appear-mathjax--key)))
      (move-overlay ov beg end)
      (overlay-put ov 'org-appear-mathjax--pending nil)
      (overlay-put ov 'org-appear-mathjax--modified t)
      (overlay-put ov 'org-appear-mathjax--entry nil))
    (overlay-put ov 'org-appear-mathjax--source source)
    (overlay-put ov 'org-appear-mathjax--body body)
    (overlay-put ov 'org-appear-mathjax--kind kind)
    (overlay-put ov 'org-appear-mathjax--key key)
    ov))

(defun org-appear-mathjax--delete (ov)
  "Delete OV and its editing decoration."
  (org-appear-mathjax--clear-panel ov)
  (overlay-put ov 'org-appear-mathjax--pending nil)
  (delete-overlay ov))

(defun org-appear-mathjax--modified (ov after &optional beg end &rest _)
  "Flag OV as edited; BEG..END and AFTER identify structural line changes."
  (when (and (overlay-get ov 'org-appear-mathjax--rows) beg end)
    (cond
     ((and (not after) (<= beg (overlay-start ov)) (>= end (overlay-end ov)))
      (org-appear-mathjax--clear-panel ov))
     ((save-excursion (goto-char beg) (search-forward "\n" end t))
      (overlay-put ov 'org-appear-mathjax--rebuild t))))
  (when (and after (overlay-buffer ov))
    (overlay-put ov 'org-appear-mathjax--modified t)
    (overlay-put ov 'org-appear-mathjax--pending nil)
    (overlay-put ov 'org-appear-mathjax--entry nil)
    (org-appear-mathjax--sync ov)))

(defun org-appear-mathjax--reconcile (&optional full recompile)
  "Reconcile changed paragraphs, or the FULL buffer, optionally forcing RECOMPILE."
  (when (and org-appear-mathjax-mode (or full org-appear-mathjax--dirty))
    (when org-appear-mathjax--timer (cancel-timer org-appear-mathjax--timer))
    (setq org-appear-mathjax--timer nil)
    (without-restriction
      (let* ((dirty org-appear-mathjax--dirty)
             (beg (if full (point-min) (car (org-appear-mathjax--block (car dirty)))))
             (end (if full (point-max) (cdr (org-appear-mathjax--block (cdr dirty)))))
             (existing (make-hash-table :test #'eql)) objects)
        (when dirty (set-marker (car dirty) nil) (set-marker (cdr dirty) nil))
        (setq org-appear-mathjax--dirty nil)
        ;; A newly inserted blank line may split an old formula across paragraphs.
        (dolist (ov (overlays-in beg end))
          (when (overlay-get ov 'org-appear-mathjax)
            (setq beg (min beg (overlay-start ov)) end (max end (overlay-end ov)))))
        (setq beg (car (org-appear-mathjax--block beg))
              end (cdr (org-appear-mathjax--block end)))
        (dolist (ov org-appear-mathjax--objects)
          (cond
           ((not (overlay-buffer ov)) (org-appear-mathjax--delete ov))
           ((and (<= (overlay-start ov) end) (>= (overlay-end ov) beg))
            (puthash (overlay-start ov) ov existing))
           (t (push ov objects))))
        (when recompile (clrhash org-appear-mathjax--images))
        (dolist (record (org-appear-mathjax--scan beg end))
          (let* ((ov (org-appear-mathjax--ensure record (gethash (nth 1 record) existing)))
                 (key (overlay-get ov 'org-appear-mathjax--key)))
            (remhash (nth 1 record) existing)
            (push ov objects)
            (when recompile
              (remhash key org-appear-mathjax--cache)
              (let ((file (expand-file-name (concat key ".json") org-appear-mathjax-cache-directory)))
                (when (file-exists-p file) (delete-file file)))
              (overlay-put ov 'org-appear-mathjax--entry nil)
              (overlay-put ov 'org-appear-mathjax--pending nil))
            (if-let* ((entry (overlay-get ov 'org-appear-mathjax--entry)))
                (overlay-put ov 'org-appear-mathjax--image (org-appear-mathjax--image ov entry))
              (org-appear-mathjax--request ov))
            (org-appear-mathjax--sync ov)))
        (maphash (lambda (_ ov)
                   (if (and (org-appear-mathjax--editing-p ov)
                            (overlay-get ov 'org-appear-mathjax--modified))
                       (push ov objects)
                     (org-appear-mathjax--delete ov))) existing)
        (setq org-appear-mathjax--objects (nreverse objects))))))

(defun org-appear-mathjax-refresh (&optional recompile)
  "Reconcile all math previews in the current buffer.
With prefix RECOMPILE, invalidate this buffer's cached formulas first."
  (interactive "P")
  (org-appear-mathjax--reconcile t recompile))

(defun org-appear-mathjax--redisplay ()
  "Update preview presentation without rescanning unchanged source."
  (when org-appear-mathjax-mode
    (org-appear-mathjax--reconcile)
    (without-restriction
      (dolist (ov org-appear-mathjax--objects)
        (if-let* ((entry (overlay-get ov 'org-appear-mathjax--entry)))
            (overlay-put ov 'org-appear-mathjax--image (org-appear-mathjax--image ov entry))
          (org-appear-mathjax--request ov))
        (org-appear-mathjax--sync ov)))))

(defun org-appear-mathjax--post-command ()
  "Reveal at point and render the formula just left, without full-buffer scans."
  (when org-appear-mathjax-mode
    (let ((old org-appear-mathjax--current)
          (current (org-appear-mathjax--at-point)))
      (when (and (not current) org-appear-mathjax--dirty)
        (when-let* ((record (seq-find (lambda (record) (<= (nth 1 record) (point) (nth 2 record)))
                                     (org-appear-mathjax--scan
                                      (max (point-min) (1- (point))) (min (point-max) (1+ (point)))))))
          (setq current (org-appear-mathjax--ensure record))))
      (dolist (ov (delete-dups (delq nil (list old current))))
        (when (overlay-buffer ov)
          (when (and (not (org-appear-mathjax--editing-p ov))
                     (or (overlay-get ov 'org-appear-mathjax--modified)
                         (not (overlay-get ov 'org-appear-mathjax--entry))))
            (let ((record (seq-find (lambda (record) (= (nth 1 record) (overlay-start ov)))
                                    (org-appear-mathjax--scan (overlay-start ov) (overlay-end ov)))))
              (if record (org-appear-mathjax--request (org-appear-mathjax--ensure record))
                (org-appear-mathjax--delete ov))))
          (org-appear-mathjax--sync ov)))
      (setq org-appear-mathjax--current current))))

(defun org-appear-mathjax--changed (beg end &rest _)
  "Queue source changes between BEG and END for idle reconciliation."
  (setq beg (max (point-min) (1- beg)) end (min (point-max) (1+ end)))
  (if (consp org-appear-mathjax--dirty)
      (progn
        (set-marker (car org-appear-mathjax--dirty) (min beg (car org-appear-mathjax--dirty)))
        (set-marker (cdr org-appear-mathjax--dirty) (max end (cdr org-appear-mathjax--dirty))))
    (setq org-appear-mathjax--dirty (cons (copy-marker beg) (copy-marker end t))))
  (when org-appear-mathjax--timer (cancel-timer org-appear-mathjax--timer))
  (let ((buffer (current-buffer)))
    (setq org-appear-mathjax--timer
          (run-with-idle-timer org-appear-mathjax-delay nil
                              (lambda () (when (buffer-live-p buffer)
                                            (with-current-buffer buffer (org-appear-mathjax--reconcile))))))))

(defun org-appear-mathjax--appearance (&rest _)
  "Refresh active buffers from cached SVG after theme or font changes."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when org-appear-mathjax-mode
        (mapc #'org-appear-mathjax--clear-panel org-appear-mathjax--objects)
        (org-appear-mathjax--redisplay)))))

(defun org-appear-mathjax--window (window)
  "Refresh a buffer newly displayed in WINDOW."
  (with-current-buffer (window-buffer window)
    (when org-appear-mathjax-mode (org-appear-mathjax--redisplay))))

;;; Optional floating live preview

(defun org-appear-mathjax--posframe-available-p ()
  "Return non-nil when floating previews can use this display."
  (and (display-graphic-p) (require 'posframe nil t)))

(defun org-appear-mathjax--posframe-buffer-name ()
  "Return the floating preview buffer name for the current source buffer."
  (format " *org-appear-mathjax-preview:%s*" (buffer-name)))

(defun org-appear-mathjax--hide-posframe (ov)
  "Hide the floating preview owned by OV."
  (when-let* ((name (overlay-get ov 'org-appear-mathjax--posframe-buffer)))
    (when (fboundp 'posframe-hide)
      (posframe-hide name))
    (overlay-put ov 'org-appear-mathjax--posframe-buffer nil)))

(defun org-appear-mathjax--posframe-right-x (info)
  "Return INFO's unclamped right-side x coordinate, or nil if unavailable."
  (let* ((window (plist-get info :parent-window))
         (position (plist-get info :position))
         (position-info (and (integer-or-marker-p position)
                             (posn-at-point position window))))
    (when position-info
      (+ (car (window-inside-pixel-edges window))
         (- (or (car (posn-x-y position-info)) 0)
            (or (car (posn-object-x-y position-info)) 0))
         (or (plist-get info :x-pixel-offset) 0)))))

(defun org-appear-mathjax--poshandler (info)
  "Place INFO's posframe right of its formula, or below when space is tight."
  (let ((x (org-appear-mathjax--posframe-right-x info))
        (window (plist-get info :parent-window)))
    (if (and x (<= (+ x (or (plist-get info :posframe-width) 0))
                   (nth 2 (window-inside-pixel-edges window))))
        (cons x (cdr (org-appear-mathjax--posframe-point-top-left info)))
      (org-appear-mathjax--posframe-point-bottom-left info))))

(defun org-appear-mathjax--posframe-point-top-left (info)
  "Return the built-in top-left position for INFO."
  (posframe-poshandler-point-top-left-corner info))

(defun org-appear-mathjax--posframe-point-bottom-left (info)
  "Return the built-in bottom-left position for INFO."
  (posframe-poshandler-point-bottom-left-corner info))

(defun org-appear-mathjax--show-posframe (ov)
  "Show OV's live preview without changing its source presentation."
  (if (not (org-appear-mathjax--posframe-available-p))
      (org-appear-mathjax--hide-posframe ov)
    (let* ((name (org-appear-mathjax--posframe-buffer-name))
           (image (overlay-get ov 'org-appear-mathjax--image))
           (error (and (not (overlay-get ov 'org-appear-mathjax--modified))
                       (plist-get (overlay-get ov 'org-appear-mathjax--entry) :error)))
           (content
            (cond
             (image (let ((padded (copy-sequence image)))
                      (setf (image-property padded :margin) '(8 . 8))
                      (propertize " " 'display padded)))
             (error (propertize
                     (concat "MathJax: "
                             (truncate-string-to-width
                              (replace-regexp-in-string "[\n\r\t]+" " " error)
                              60 nil nil "…"))
                     'face 'error))
             (t (propertize "Rendering…" 'face 'shadow))))
           (box (face-attribute 'org-appear-mathjax-preview :box nil t))
           (border (or (and (listp box) (plist-get box :color))
                       (and (stringp box) box)
                       (face-foreground 'shadow nil t))))
      (overlay-put ov 'org-appear-mathjax--posframe-buffer name)
      (posframe-show name
                     :string content
                     :position (overlay-end ov)
                     :poshandler #'org-appear-mathjax--poshandler
                     :x-pixel-offset 12
                     :border-width 1
                     :border-color border
                     :background-color (face-attribute 'default :background nil t)
                     :foreground-color (face-attribute 'default :foreground nil t)
                     :accept-focus nil
                     :lines-truncate t
                     :hidehandler #'posframe-hidehandler-when-buffer-switch))))

;;; Optional source/preview frame

(defun org-appear-mathjax--clear-panel (ov)
  "Remove any in-buffer or floating preview owned by OV."
  (org-appear-mathjax--hide-posframe ov)
  (when (overlay-get ov 'org-appear-mathjax--rows)
    (mapc #'delete-overlay (overlay-get ov 'org-appear-mathjax--rows))
    (dolist (property '(org-appear-mathjax--rows org-appear-mathjax--last-row
                       org-appear-mathjax--preview-body org-appear-mathjax--status
                       org-appear-mathjax--shown-image org-appear-mathjax--rebuild))
      (overlay-put ov property nil))))

(defun org-appear-mathjax--source-rows (ov)
  "Create OV's source edges only initially or after newline changes."
  (when (or (not (overlay-get ov 'org-appear-mathjax--rows))
            (overlay-get ov 'org-appear-mathjax--rebuild))
    (mapc #'delete-overlay (overlay-get ov 'org-appear-mathjax--rows))
    (let* ((box (face-attribute 'org-appear-mathjax-preview :box nil t))
           (color (or (and (listp box) (plist-get box :color)) (and (stringp box) box)
                      (face-foreground 'shadow nil t)))
           (bar (propertize " " 'display '(space :width (1)) 'face `(:background ,color)))
           (tail (concat (propertize " " 'cursor t)
                         (propertize " " 'display '(space :align-to (- right (1)))) bar))
           (end (overlay-end ov)) rows)
      (save-excursion
        (goto-char (overlay-start ov)) (beginning-of-line)
        (let ((first t) (more t))
          (while more
            (let* ((beg (point)) (eol (line-end-position)) (row (make-overlay beg eol nil nil t))
                   (face (if first `((:overline ,color) org-appear-mathjax-source)
                           'org-appear-mathjax-source))
                   (prefix (or (get-char-property beg 'line-prefix) line-prefix))
                   (wrap (or (get-char-property beg 'wrap-prefix) wrap-prefix))
                   (border (concat bar " ")))
              (overlay-put row 'org-appear-mathjax--row t)
              (overlay-put row 'priority 2) (overlay-put row 'face face)
              (add-face-text-property 0 (length border) face t border)
              (dolist (pair `((line-prefix . ,prefix) (wrap-prefix . ,wrap)))
                (overlay-put row (car pair)
                             (if (not (cdr pair)) border
                               (concat (if (stringp (cdr pair)) (cdr pair)
                                         (propertize " " 'display (cdr pair))) border))))
              (let ((edge (if (= beg eol) (propertize (concat bar " " tail) 'line-prefix "" 'wrap-prefix "")
                            (copy-sequence tail))))
                (add-face-text-property 0 (length edge) face t edge)
                (overlay-put row 'org-appear-mathjax--tail edge)
                (overlay-put row 'after-string edge))
              (push row rows) (setq first nil)
              (if (>= eol end) (setq more nil) (forward-line 1))))))
      (overlay-put ov 'org-appear-mathjax--last-row (car rows))
      (overlay-put ov 'org-appear-mathjax--rows (nreverse rows))
      (overlay-put ov 'org-appear-mathjax--rebuild nil))))

(defun org-appear-mathjax--show-panel (ov)
  "Update OV's frame only when its image or status changes."
  (org-appear-mathjax--hide-posframe ov)
  (org-appear-mathjax--source-rows ov)
  (let* ((image (overlay-get ov 'org-appear-mathjax--image))
         (error (and (not (overlay-get ov 'org-appear-mathjax--modified))
                     (plist-get (overlay-get ov 'org-appear-mathjax--entry) :error)))
         (status (cond (image 'image) (error 'error) (t 'pending))))
    (unless (and (eq image (overlay-get ov 'org-appear-mathjax--shown-image))
                 (eq status (overlay-get ov 'org-appear-mathjax--status)))
      (let* ((row (overlay-get ov 'org-appear-mathjax--last-row))
             (tail (overlay-get row 'org-appear-mathjax--tail))
             (content
              (cond
               (image (let ((padded (copy-sequence image)))
                        (setf (image-property padded :margin) '(0 . 8))
                        (concat (propertize " " 'display `(space :align-to (- center (0.5 . ,padded))))
                                (propertize " " 'display padded))))
               (error (concat (propertize (truncate-string-to-width
                                          (replace-regexp-in-string "[\n\r\t]+" " " error) 72 nil nil "…") 'face 'error)
                              "  " (propertize
                                     (buttonize "Details" (lambda (_)
                                                           (when-let* ((buffer (overlay-buffer ov)))
                                                             (with-current-buffer buffer
                                                               (save-excursion (goto-char (overlay-start ov))
                                                                               (org-appear-mathjax-show-error))))))
                                     'face 'link)))
               (t (propertize "Waiting for a renderable formula…" 'face 'shadow))))
             (line (concat content tail)))
        (add-face-text-property 0 (length line) 'org-appear-mathjax-preview t line)
        (overlay-put ov 'org-appear-mathjax--preview-body
                     (propertize
                      (concat (propertize "\n" 'face '(:inherit default :box nil :extend t)) line
                              (and (= (save-excursion (goto-char (overlay-end ov)) (line-end-position)) (point-max)) "\n"))
                      'line-prefix (overlay-get row 'line-prefix)
                      'wrap-prefix (overlay-get row 'wrap-prefix)
                      'help-echo (lambda (_window _object _position)
                                   (or error (and image (overlay-get ov 'org-appear-mathjax--modified)
                                                  "Previous preview; waiting for the edited formula"))))))
      (overlay-put ov 'org-appear-mathjax--status status)
      (overlay-put ov 'org-appear-mathjax--shown-image image)))
  (let* ((row (overlay-get ov 'org-appear-mathjax--last-row))
         (body (overlay-get ov 'org-appear-mathjax--preview-body)))
    (unless (eq body (overlay-get row 'org-appear-mathjax--preview-body))
      (overlay-put row 'after-string (propertize (concat (overlay-get row 'org-appear-mathjax--tail) body)
                                               'help-echo (get-text-property 0 'help-echo body)))
      (overlay-put row 'org-appear-mathjax--preview-body body))))

;;; Mode lifecycle

(defun org-appear-mathjax--clone ()
  "Detach inherited preview state without deleting the base buffer's objects."
  (setq org-appear-mathjax--objects nil org-appear-mathjax--current nil
        org-appear-mathjax--timer nil org-appear-mathjax--dirty nil)
  (dolist (ov (overlays-in (point-min) (point-max)))
    (when (or (overlay-get ov 'org-appear-mathjax) (overlay-get ov 'org-appear-mathjax--row))
      (delete-overlay ov)))
  (org-appear-mathjax-refresh))

;;;###autoload
(define-minor-mode org-appear-mathjax-mode
  "Preview Org math with MathJax and reveal source at point."
  :lighter nil
  :group 'org-appear-mathjax
  (if org-appear-mathjax-mode
      (progn
        (unless (and (derived-mode-p 'org-mode)
                     (image-type-available-p 'svg)
                     (require 'mathjax nil t) (mathjax-available-p))
          (setq org-appear-mathjax-mode nil)
          (user-error "MathJax previews require org-mode, SVG support, the mathjax package and Node.js"))
        (font-lock-add-keywords nil '((org-appear-mathjax--fontify)) t)
        (dolist (property '(invisible display))
          (unless (memq property font-lock-extra-managed-props)
            (push property font-lock-extra-managed-props)
            (push property org-appear-mathjax--managed)))
        (add-hook 'post-command-hook #'org-appear-mathjax--post-command 90 t)
        (add-hook 'after-change-functions #'org-appear-mathjax--changed 90 t)
        (add-hook 'text-scale-mode-hook #'org-appear-mathjax--redisplay nil t)
        (add-hook 'window-buffer-change-functions #'org-appear-mathjax--window nil t)
        (add-hook 'clone-indirect-buffer-hook #'org-appear-mathjax--clone -90 t)
        (add-hook 'change-major-mode-hook #'org-appear-mathjax--disable nil t)
        (add-hook 'kill-buffer-hook #'org-appear-mathjax--disable nil t)
        (dolist (hook '(enable-theme-functions disable-theme-functions after-setting-font-hook))
          (add-hook hook #'org-appear-mathjax--appearance))
        (font-lock-flush)
        (org-appear-mathjax-refresh)
        (org-appear-mathjax--post-command))
    (when org-appear-mathjax--timer (cancel-timer org-appear-mathjax--timer))
    (mapc #'org-appear-mathjax--delete org-appear-mathjax--objects)
    (setq org-appear-mathjax--objects nil org-appear-mathjax--current nil
          org-appear-mathjax--timer nil)
    (when (consp org-appear-mathjax--dirty)
      (set-marker (car org-appear-mathjax--dirty) nil)
      (set-marker (cdr org-appear-mathjax--dirty) nil))
    (setq org-appear-mathjax--dirty nil)
    (font-lock-remove-keywords nil '((org-appear-mathjax--fontify)))
    (dolist (property org-appear-mathjax--managed)
      (setq font-lock-extra-managed-props (delq property font-lock-extra-managed-props)))
    (setq org-appear-mathjax--managed nil)
    (remove-hook 'post-command-hook #'org-appear-mathjax--post-command t)
    (remove-hook 'after-change-functions #'org-appear-mathjax--changed t)
    (remove-hook 'text-scale-mode-hook #'org-appear-mathjax--redisplay t)
    (remove-hook 'window-buffer-change-functions #'org-appear-mathjax--window t)
    (remove-hook 'clone-indirect-buffer-hook #'org-appear-mathjax--clone t)
    (remove-hook 'change-major-mode-hook #'org-appear-mathjax--disable t)
    (remove-hook 'kill-buffer-hook #'org-appear-mathjax--disable t)
    (unless (seq-some (lambda (buffer) (buffer-local-value 'org-appear-mathjax-mode buffer)) (buffer-list))
      (dolist (hook '(enable-theme-functions disable-theme-functions after-setting-font-hook))
        (remove-hook hook #'org-appear-mathjax--appearance)))
    (font-lock-flush)))

(defun org-appear-mathjax--disable ()
  "Disable previews before this buffer is discarded or changes major mode."
  (org-appear-mathjax-mode -1))

(provide 'org-appear-mathjax)
;;; org-appear-mathjax.el ends here
