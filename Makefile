EMACS ?= emacs

.PHONY: compile checkdoc test icons clean

compile:
	$(EMACS) -Q --batch -L . -L test -l magnus-stub \
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
