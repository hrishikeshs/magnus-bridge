;;; magnus-bridge-auth.el --- Identity, pairing, tokens and audit for magnus-bridge -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Hrishikesh S
;; Author: Hrishikesh S
;; Assisted-by: Claude Code:claude-fable-5
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; The trust layer: Tailscale identity checks, one-time pairing codes
;; (displayed only inside Emacs), per-device tokens, and the audit log.
;; Lowest layer of the package; owns the customization group.

;;; Code:

(require 'cl-lib)
(require 'json)


(defconst magnus-bridge-version "0.7.0")

(defgroup magnus-bridge nil
  "Talk to your Magnus agents from your phone."
  :group 'magnus
  :prefix "magnus-bridge-")

(defcustom magnus-bridge-allowed-logins nil
  "Tailscale logins allowed to reach the bridge.
A list of login strings (e.g. \"you@example.com\") checked against the
Tailscale-User-Login header injected by `tailscale serve'.  When nil,
any tailnet identity is accepted (the pairing token is still required
for the API)."
  :type '(repeat string))

(defcustom magnus-bridge-require-tailscale-identity t
  "When non-nil, reject requests lacking a Tailscale identity header.
Disable only for local development and testing."
  :type 'boolean)

(defcustom magnus-bridge-token-file
  (expand-file-name "magnus-bridge-tokens.eld" user-emacs-directory)
  "File persisting paired device tokens (created with mode 0600)."
  :type 'file)

(defcustom magnus-bridge-audit-file
  (expand-file-name "magnus-bridge-audit.log" user-emacs-directory)
  "File receiving one line per bridge request."
  :type 'file)

(defvar magnus-bridge--tokens nil
  "Alist of (TOKEN . PLIST) for paired devices.")

(defvar magnus-bridge--pairing nil
  "Active pairing code as (CODE . EXPIRY-FLOAT-TIME), or nil.")

(defun magnus-bridge--random-hex (nbytes)
  "Return NBYTES of cryptographically random data as a hex string.
Prefers openssl.  The fallback uses Emacs' `random', which is
time-seeded and NOT cryptographically strong — acceptable for a
2-minute single-use pairing code, weak for a year-long device token.
In practice any machine running Emacs + Tailscale has openssl; the
fallback warns loudly on the off chance it ever fires."
  (let ((out (ignore-errors
               (with-temp-buffer
                 (when (zerop (call-process "openssl" nil t nil
                                            "rand" "-hex"
                                            (number-to-string nbytes)))
                   (string-trim (buffer-string)))))))
    (if (and out (= (length out) (* 2 nbytes)))
        out
      (message "Magnus bridge WARNING: openssl unavailable — falling back to a weak PRNG for secrets")
      (random t)
      (mapconcat (lambda (_) (format "%02x" (random 256)))
                 (make-list nbytes 0) ""))))

(defun magnus-bridge--now ()
  "Current UTC timestamp string."
  (format-time-string "%FT%TZ" nil t))

(defun magnus-bridge--jget (obj key)
  "Get KEY (a string) from parsed JSON OBJ regardless of key type."
  (or (cdr (assoc key obj))
      (cdr (assq (intern key) obj))))

(defun magnus-bridge--audit (action detail &optional identity)
  "Append ACTION with DETAIL and IDENTITY to the audit log."
  (let ((line (format "%s\t%s\t%s\t%s\n"
                      (magnus-bridge--now)
                      (or identity "-")
                      action
                      (replace-regexp-in-string "[\n\t]" " " (or detail "")))))
    (ignore-errors
      ;; write-region with VISIT of 0: append without echo-area noise.
      (write-region line nil magnus-bridge-audit-file 'append 0)
      (set-file-modes magnus-bridge-audit-file #o600))))

(defun magnus-bridge--load-tokens ()
  "Load persisted device tokens."
  (setq magnus-bridge--tokens
        (when (file-readable-p magnus-bridge-token-file)
          (ignore-errors
            (with-temp-buffer
              (insert-file-contents magnus-bridge-token-file)
              (read (current-buffer)))))))

(defun magnus-bridge--save-tokens ()
  "Persist device tokens with restrictive permissions."
  (with-temp-file magnus-bridge-token-file
    (let ((print-length nil) (print-level nil))
      (prin1 magnus-bridge--tokens (current-buffer))))
  (set-file-modes magnus-bridge-token-file #o600))

;;;###autoload
(defun magnus-bridge-pair ()
  "Generate a one-time pairing code, valid for two minutes.
Type this code into the pairing screen on your phone.  The code is
displayed only inside Emacs, which is what makes it a trustworthy
second factor."
  (interactive)
  (let ((code (format "%06d" (string-to-number
                              (magnus-bridge--random-hex 3) 16))))
    (setq magnus-bridge--pairing
          (cons (substring code -6) (+ (float-time) 120)))
    (magnus-bridge--audit "pair-code-issued" nil)
    (message "Magnus bridge pairing code: %s  (valid 2 minutes)"
             (car magnus-bridge--pairing))
    (car magnus-bridge--pairing)))

(defun magnus-bridge--try-pair (code device)
  "Redeem pairing CODE for DEVICE.  Return a fresh token or nil."
  (when (and magnus-bridge--pairing
             (stringp code)
             (string= code (car magnus-bridge--pairing))
             (< (float-time) (cdr magnus-bridge--pairing)))
    (setq magnus-bridge--pairing nil)   ; single use
    (let ((token (magnus-bridge--random-hex 32)))
      (push (cons token (list :device (or device "unknown")
                              :created (magnus-bridge--now)))
            magnus-bridge--tokens)
      (magnus-bridge--save-tokens)
      token)))

(defun magnus-bridge--token-valid-p (token)
  "Return the device plist if TOKEN is a paired device token."
  (and (stringp token) (cdr (assoc token magnus-bridge--tokens))))

;;;###autoload
(defun magnus-bridge-revoke-all-devices ()
  "Revoke every paired device token."
  (interactive)
  (setq magnus-bridge--tokens nil)
  (magnus-bridge--save-tokens)
  (magnus-bridge--audit "revoke-all" nil)
  (message "Magnus bridge: all device tokens revoked."))

(defun magnus-bridge--parse-cookies (header)
  "Parse a Cookie HEADER into an alist."
  (when header
    (mapcar (lambda (pair)
              (let ((eq-pos (string-search "=" pair)))
                (if eq-pos
                    (cons (string-trim (substring pair 0 eq-pos))
                          (string-trim (substring pair (1+ eq-pos))))
                  (cons (string-trim pair) ""))))
            (split-string header ";" t))))

(defun magnus-bridge--request-token (headers)
  "Extract the device token from HEADERS (cookie or bearer)."
  (or (cdr (assoc "mb_token"
                  (magnus-bridge--parse-cookies
                   (cdr (assoc "cookie" headers)))))
      (let ((auth (cdr (assoc "authorization" headers))))
        (when (and auth (string-prefix-p "Bearer " auth))
          (substring auth 7)))))

(defun magnus-bridge--identity (headers)
  "Return the Tailscale identity in HEADERS, checking the allowlist.
Returns the login string, the symbol `anonymous' when identity is not
required, or nil when the request must be rejected."
  (let ((login (cdr (assoc "tailscale-user-login" headers))))
    (cond
     ((and login magnus-bridge-allowed-logins)
      (when (member login magnus-bridge-allowed-logins) login))
     (login login)
     ((not magnus-bridge-require-tailscale-identity) 'anonymous)
     (t nil))))

;;;###autoload
(defun magnus-bridge-audit ()
  "Open the bridge audit log."
  (interactive)
  (find-file magnus-bridge-audit-file))

(provide 'magnus-bridge-auth)

;;; magnus-bridge-auth.el ends here
