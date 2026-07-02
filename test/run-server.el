;;; run-server.el --- Boot magnus-bridge against the stub for smoke tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Usage: emacs -Q --batch -L . -L test -l magnus-stub -l magnus-bridge \
;;          -l test/run-server.el
;; Writes the pairing code to $MB_TEST_DIR/pair-code and serves until killed.

;;; Code:

(let ((dir (or (getenv "MB_TEST_DIR") temporary-file-directory)))
  (setq magnus-bridge-require-tailscale-identity nil
        magnus-bridge-port 8399
        magnus-bridge-token-file (expand-file-name "tokens.eld" dir)
        magnus-bridge-audit-file (expand-file-name "audit.log" dir)
        magnus-bridge-patterns-file (expand-file-name "patterns.eld" dir)
        magnus-bridge-reply-poll-interval 1)
  (magnus-bridge-start)
  (with-temp-file (expand-file-name "pair-code" dir)
    (insert (magnus-bridge-pair)))
  (message "test server ready")
  (while t (accept-process-output nil 0.2)))

;;; run-server.el ends here
