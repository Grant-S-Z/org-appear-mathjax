EMACS ?= emacs
PACKAGE = org-appear-mathjax.el
TEST = test/org-appear-mathjax-test.el
RUN_EMACS = $(EMACS) -Q --batch --eval "(progn (setq package-load-list '((org t) (mathjax t))) (package-initialize))" -L .

.PHONY: all check compile test checkdoc lint clean

all: check

check: compile test checkdoc

compile:
	$(RUN_EMACS) --eval "(setq byte-compile-error-on-warn t)" \
	  -f batch-byte-compile $(PACKAGE)

test:
	$(RUN_EMACS) -l $(TEST) -f ert-run-tests-batch-and-exit

checkdoc:
	$(EMACS) -Q --batch --eval \
	  "(progn (require 'checkdoc) (checkdoc-file \"$(PACKAGE)\"))"

lint:
	$(RUN_EMACS) --eval \
	  "(progn (package-activate 'package-lint) (require 'package-lint) (find-file \"$(PACKAGE)\") (package-lint-current-buffer))"

clean:
	rm -f *.elc test/*.elc
	rm -rf .test-cache .test-deps
