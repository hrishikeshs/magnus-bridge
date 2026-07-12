EMACS ?= emacs

.PHONY: compile checkdoc test integration verify clean

compile:
	$(EMACS) -Q --batch -L . \
	  --eval '(setq load-prefer-newer t byte-compile-error-on-warn t)' \
	  -f batch-byte-compile magnus-bridge.el

checkdoc:
	$(EMACS) -Q --batch -L . \
	  --eval '(checkdoc-file "magnus-bridge.el")'

test:
	$(EMACS) -Q --batch -L . \
	  --eval '(setq load-prefer-newer t)' \
	  -l test/magnus-bridge-test.el -f ert-run-tests-batch-and-exit

integration:
	./test/bridge-integration.sh

verify: compile checkdoc test

clean:
	rm -f *.elc
