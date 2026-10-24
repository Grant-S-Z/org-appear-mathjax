;;; org-appear-mathjax-test.el --- Tests for org-appear-mathjax -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Run `make test' from the repository root.  The Org and MathJax dependencies
;; must be installed in package.el's package directory.

;;; Code:
(require 'ert)
(require 'org)
(require 'org-appear-mathjax)

(defmacro org-appear-mathjax-test--with-buffer (content &rest body)
  "Create an Org buffer containing CONTENT, then evaluate BODY."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (org-mode)
     (insert ,content)
     (goto-char (point-min))
     ,@body))

(defun org-appear-mathjax-test--records ()
  "Return complete scan records for the current test buffer."
  (org-appear-mathjax--scan (point-min) (point-max)))

(ert-deftest org-appear-mathjax-test-detects-org-math ()
  "Recognize inline, display and environment math with correct bodies."
  (org-appear-mathjax-test--with-buffer
      "Inline $x+y$ and \\(a+b\\).\n\n$$c+d$$\n\n\\[e+f\\]\n\n\\begin{align*}\ng&=h\\\\\ni&=j\n\\end{align*}\n"
    (let ((records (org-appear-mathjax-test--records)))
      (should (equal (mapcar #'car records)
                     '(inline inline display display environment)))
      (should (equal
               (mapcar (lambda (record)
                         (buffer-substring-no-properties (nth 3 record) (nth 4 record)))
                       (butlast records))
               '("x+y" "a+b" "c+d" "e+f")))
      (should (string-prefix-p
               "\\begin{align*}"
               (buffer-substring-no-properties
                (nth 3 (car (last records)))
                (nth 4 (car (last records)))))))))

(ert-deftest org-appear-mathjax-test-ignores-non-math-org-blocks ()
  "Do not treat delimiter-like text in literal Org constructs as math."
  (org-appear-mathjax-test--with-buffer
      "#+begin_src latex\n$x$\n#+end_src\n\n#+begin_example\n\\(y\\)\n#+end_example\n\n#+begin_comment\n\\[z\\]\n#+end_comment\n\n# $comment$\n\nText $ok$.\n"
    (let ((records (org-appear-mathjax-test--records)))
      (should (= (length records) 1))
      (should (equal (buffer-substring-no-properties
                      (nth 3 (car records)) (nth 4 (car records)))
                     "ok")))))

(ert-deftest org-appear-mathjax-test-span-at-includes-closing-boundary ()
  "Find a formula at its opening, body and closing boundary."
  (org-appear-mathjax-test--with-buffer "A \\(x+y\\) B."
    (let* ((record (car (org-appear-mathjax-test--records)))
           (beg (nth 1 record))
           (end (nth 2 record)))
      (should (equal (org-appear-mathjax-span-at beg) (seq-take record 3)))
      (should (equal (org-appear-mathjax-span-at (1- end)) (seq-take record 3)))
      (should (equal (org-appear-mathjax-span-at end) (seq-take record 3)))
      (should-not (org-appear-mathjax-span-at (1+ end))))))

(ert-deftest org-appear-mathjax-test-point-controls-source-and-preview ()
  "Reveal source at point and restore the preview after leaving."
  (org-appear-mathjax-test--with-buffer "Before \\(x+y\\) after.\n"
    (unwind-protect
        (progn
          (org-appear-mathjax-mode 1)
          (should org-appear-mathjax-mode)
          (let ((ov (car org-appear-mathjax--objects)))
            (should ov)
            (overlay-put ov 'org-appear-mathjax--image 'preview-image)
            (overlay-put ov 'org-appear-mathjax--modified nil)
            (goto-char (point-min))
            (org-appear-mathjax--sync ov)
            (org-appear-mathjax--post-command)
            (should (eq (overlay-get ov 'display) 'preview-image))
            (search-forward "x+y")
            (backward-char)
            (org-appear-mathjax--post-command)
            (should-not (overlay-get ov 'display))
            (should (eq org-appear-mathjax--current ov))
            (goto-char (point-min))
            (org-appear-mathjax--post-command)
            (should (eq (overlay-get ov 'display) 'preview-image))
            (goto-char (overlay-end ov))
            (org-appear-mathjax--post-command)
            (should-not (overlay-get ov 'display))))
      (org-appear-mathjax-mode -1))))

(ert-deftest org-appear-mathjax-test-read-only-buffer-keeps-preview ()
  "Keep previews visible in read-only buffers, matching the Markdown mode."
  (org-appear-mathjax-test--with-buffer "\\(x+y\\)"
    (unwind-protect
        (progn
          (org-appear-mathjax-mode 1)
          (let ((ov (car org-appear-mathjax--objects)))
            (overlay-put ov 'org-appear-mathjax--image 'preview-image)
            (overlay-put ov 'org-appear-mathjax--modified nil)
            (setq buffer-read-only t)
            (goto-char (1+ (overlay-start ov)))
            (org-appear-mathjax--post-command)
            (should (eq (overlay-get ov 'display) 'preview-image))))
      (setq buffer-read-only nil)
      (org-appear-mathjax-mode -1))))

(ert-deftest org-appear-mathjax-test-edit-invalidates-and-reconciles ()
  "Editing reveals source immediately and reconciliation picks up new body text."
  (org-appear-mathjax-test--with-buffer "Before \\(x+y\\) after.\n"
    (unwind-protect
        (progn
          (org-appear-mathjax-mode 1)
          (let ((ov (car org-appear-mathjax--objects)))
            (overlay-put ov 'org-appear-mathjax--image 'preview-image)
            (overlay-put ov 'org-appear-mathjax--modified nil)
            (goto-char (point-min))
            (org-appear-mathjax--sync ov)
            (should (eq (overlay-get ov 'display) 'preview-image))
            (search-forward "x+y")
            (insert "z")
            (should (overlay-get ov 'org-appear-mathjax--modified))
            (should-not (overlay-get ov 'display))
            (should org-appear-mathjax--dirty)
            (org-appear-mathjax--reconcile)
            (should-not org-appear-mathjax--dirty)
            (should (equal (overlay-get ov 'org-appear-mathjax--body) "x+yz"))))
      (org-appear-mathjax-mode -1))))

(ert-deftest org-appear-mathjax-test-disable-cleans-local-state ()
  "Disabling the mode removes overlays and buffer-local hooks."
  (org-appear-mathjax-test--with-buffer "\\(x+y\\)"
    (org-appear-mathjax-mode 1)
    (should org-appear-mathjax--objects)
    (org-appear-mathjax-mode -1)
    (should-not org-appear-mathjax--objects)
    (should-not org-appear-mathjax--current)
    (should-not (memq #'org-appear-mathjax--post-command post-command-hook))
    (should-not (memq #'org-appear-mathjax--changed after-change-functions))
    (should-not (seq-some (lambda (ov) (overlay-get ov 'org-appear-mathjax))
                          (overlays-in (point-min) (point-max))))))

(ert-deftest org-appear-mathjax-test-rejects-non-org-buffer ()
  "Refuse to enable outside Org mode without leaving the minor mode active."
  (with-temp-buffer
    (should-error (org-appear-mathjax-mode 1) :type 'user-error)
    (should-not org-appear-mathjax-mode)))

(ert-deftest org-appear-mathjax-test-xenops-vertical-alignment-option ()
  "Support Xenops-style centered images without losing baseline mode."
  (let ((org-appear-mathjax-inline-ascent 'baseline))
    (should (= (org-appear-mathjax--image-ascent '(:ascent 83)) 83))
    (should (eq (org-appear-mathjax--image-ascent '(:ascent -1)) 'center)))
  (let ((org-appear-mathjax-inline-ascent 'center))
    (should (eq (org-appear-mathjax--image-ascent '(:ascent 83)) 'center))
    (should (eq (org-appear-mathjax--image-ascent '(:ascent -1)) 'center))))

(ert-deftest org-appear-mathjax-test-real-mathjax-svg-render ()
  "Render a real formula through Node and reuse its content cache."
  (let ((cache-directory (expand-file-name ".test-cache" default-directory))
        done result)
    (when (file-directory-p cache-directory)
      (delete-directory cache-directory t))
    (unwind-protect
        (let ((org-appear-mathjax-cache-directory cache-directory)
              (org-appear-mathjax-timeout 10))
          (org-appear-mathjax-render
           "x^2+y^2=z^2" nil (lambda (entry) (setq result entry done t)))
          (let ((deadline (+ (float-time) 15)))
            (while (and (not done) (< (float-time) deadline))
              (accept-process-output nil 0.05)))
          (should done)
          (should-not (plist-get result :error))
          (should (string-match-p "<svg" (plist-get result :svg)))
          (should (> (plist-get result :width) 0))
          (should (> (plist-get result :ex) 0))
          (should (equal (org-appear-mathjax-render "x^2+y^2=z^2" nil #'ignore)
                         result)))
      (org-appear-mathjax-stop)
      (when (file-directory-p cache-directory)
        (delete-directory cache-directory t)))))

(provide 'org-appear-mathjax-test)
;;; org-appear-mathjax-test.el ends here
