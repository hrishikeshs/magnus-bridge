EMACS ?= emacs

.PHONY: compile checkdoc test test-client integration icons clean

# Never compile with the test stub loaded: cl-defstruct accessors are
# inlined to slot offsets at compile time, and the stub's layout differs
# from the real magnus-instance struct.
compile:
	$(EMACS) -Q --batch -L . \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile magnus-bridge*.el

checkdoc:
	$(EMACS) -Q --batch \
	  --eval '(dolist (f (directory-files "." nil "magnus-bridge.*\\.el$")) (checkdoc-file f))'

test: compile
	./test/smoke.sh

# Thin-client (magnus-bridge-client.el) unit tests: ert, HTTP layer stubbed,
# no daemon or vterm needed.
test-client:
	$(EMACS) -Q --batch -L . -l test/magnus-bridge-client-test.el \
	  -f ert-run-tests-batch-and-exit

# Thin-client end-to-end against a scratch bridge daemon; a clean skip when the
# bridge repo or its toolchain is unavailable.
integration:
	./test/bridge-integration.sh

icons:
	python3 scripts/gen_icons.py

clean:
	rm -f *.elc
