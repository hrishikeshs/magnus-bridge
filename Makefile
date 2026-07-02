EMACS ?= emacs

.PHONY: compile checkdoc test icons clean

# Never compile with the test stub loaded: cl-defstruct accessors are
# inlined to slot offsets at compile time, and the stub's layout differs
# from the real magnus-instance struct.
compile:
	$(EMACS) -Q --batch -L . \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile magnus-bridge.el

checkdoc:
	$(EMACS) -Q --batch \
	  --eval '(checkdoc-file "magnus-bridge.el")'

test: compile
	./test/smoke.sh

icons:
	python3 scripts/gen_icons.py

clean:
	rm -f *.elc
