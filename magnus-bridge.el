;;; magnus-bridge.el --- Chat with your Magnus agents from your phone -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Hrishikesh S

;; Author: Hrishikesh S
;; URL: https://github.com/hrishikeshs/magnus-bridge
;; Version: 0.3.0
;; Package-Requires: ((emacs "28.1") (magnus "0.5"))
;; Keywords: tools, processes, convenience

;; This file is not part of GNU Emacs.

;;; Commentary:

;; magnus-bridge lets you talk to your Magnus-managed Claude Code agents
;; from your phone.  It runs a small HTTP server inside Emacs, bound to
;; 127.0.0.1, serving a chat PWA and a JSON API.  Expose it to your
;; personal devices with Tailscale:
;;
;;   tailscale serve --bg <port>
;;
;; which gives you a tailnet-only HTTPS URL — no third party ever
;; intermediates your messages.
;;
;; Quick start:
;;   M-x magnus-bridge-start        ; start the server
;;   M-x magnus-bridge-setup-tailscale  ; expose via tailscale serve
;;   M-x magnus-bridge-pair         ; show a one-time pairing code
;;   ...open the URL on your phone, enter the code, add to home screen.
;;
;; Security model (defense in depth):
;;   1. The server only binds 127.0.0.1 — the tailnet is the perimeter.
;;   2. Requests must carry a Tailscale identity header matching
;;      `magnus-bridge-allowed-logins' (injected by `tailscale serve').
;;   3. API access requires a per-device token, obtained by typing a
;;      one-time pairing code that is only ever displayed inside Emacs.
;;   4. The approve endpoint accepts a tiny whitelist of keys and only
;;      for instances that Magnus attention has flagged.
;;   5. Every request is written to an audit log.
;;   6. `magnus-bridge-lockdown' severs everything instantly.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'url-util)

;; Magnus integration is late-bound so the server core can be exercised
;; in batch tests against a stub.
(declare-function magnus-instances-active-list "magnus-instances")
(declare-function magnus-instances-get "magnus-instances" (id))
(declare-function magnus-instance-id "magnus-instances" (instance))
(declare-function magnus-instance-name "magnus-instances" (instance))
(declare-function magnus-instance-directory "magnus-instances" (instance))
(declare-function magnus-instance-status "magnus-instances" (instance))
(declare-function magnus-instance-buffer "magnus-instances" (instance))
(declare-function magnus-health-get "magnus-health" (instance))
(declare-function magnus-coord-nudge-agent "magnus-coord" (instance message &optional source))
(declare-function magnus-attention--tail-text "magnus-attention")
(declare-function magnus-instance-session-id "magnus-instances" (instance))
(declare-function magnus-process--session-jsonl-path "magnus-process" (directory session-id))
(declare-function vterm-send-string "vterm" (string &optional paste-p))
(declare-function vterm-send-return "vterm")
(declare-function vterm-send-escape "vterm")

(defvar magnus-attention-queue)
(defvar magnus-attention-auto-approve-patterns)
(defvar magnus-coord-file)

;;; Customization

(defgroup magnus-bridge nil
  "Talk to your Magnus agents from your phone."
  :group 'magnus
  :prefix "magnus-bridge-")

(defcustom magnus-bridge-port 8377
  "Local port the bridge HTTP server listens on (127.0.0.1 only)."
  :type 'integer)

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

(defcustom magnus-bridge-history-size 500
  "Number of events kept for reconnecting clients."
  :type 'integer)

(defcustom magnus-bridge-user-mention "hrishi"
  "Mention name agents use to message you (without the @)."
  :type 'string)

(defcustom magnus-bridge-max-message-length 4000
  "Maximum accepted length for an inbound chat message."
  :type 'integer)

(defcustom magnus-bridge-attachments-directory
  (expand-file-name "magnus-bridge-attachments" user-emacs-directory)
  "Directory where photos sent from the phone are stored for agents."
  :type 'directory)

(defcustom magnus-bridge-max-upload-bytes (* 20 1024 1024)
  "Maximum accepted HTTP request body size in bytes."
  :type 'integer)

(defcustom magnus-bridge-mention-poll-interval 10
  "Seconds between scans of coordination files for user mentions."
  :type 'integer)

(defcustom magnus-bridge-reply-window 900
  "Seconds to relay an agent's replies after you message it.
After a message from the phone, the agent's visible output (the text
it prints in its Claude Code terminal) is streamed back for this many
seconds.  Thinking traces and tool internals are never relayed — use
sift or the JSONL on a real screen for those."
  :type 'integer)

(defcustom magnus-bridge-reply-poll-interval 3
  "Seconds between checks for new agent output while a reply watch is active."
  :type 'integer)

(defcustom magnus-bridge-patterns-file
  (expand-file-name "magnus-bridge-patterns.eld" user-emacs-directory)
  "File persisting auto-approve patterns learned from the phone."
  :type 'file)

(defconst magnus-bridge-version "0.3.0")

(defconst magnus-bridge--approve-keys '("1" "2" "3" "y" "n" "esc")
  "The only key sequences the approve endpoint will deliver.")

;;; State

(defvar magnus-bridge--server nil
  "The listening network process, or nil.")

(defvar magnus-bridge--sse-clients nil
  "List of processes subscribed to /api/events.")

(defvar magnus-bridge--events nil
  "Recent events, newest first, capped at `magnus-bridge-history-size'.")

(defvar magnus-bridge--event-counter 0
  "Monotonic id assigned to events.")

(defvar magnus-bridge--tokens nil
  "Alist of (TOKEN . PLIST) for paired devices.")

(defvar magnus-bridge--pairing nil
  "Active pairing code as (CODE . EXPIRY-FLOAT-TIME), or nil.")

(defvar magnus-bridge--heartbeat-timer nil)
(defvar magnus-bridge--mention-timer nil)
(defvar magnus-bridge--reply-timer nil)

(defvar magnus-bridge--reply-watches nil
  "Alist of (INSTANCE-ID . PLIST) for active reply watches.
The plist has :file, :offset (bytes already relayed) and :until
\(float-time deadline).")

(defvar magnus-bridge--learned-patterns nil
  "Auto-approve patterns learned from the phone (persisted separately).")

(defvar magnus-bridge--seen-mentions (make-hash-table :test 'equal)
  "Hash of directory -> list of md5 hashes of already-relayed mention lines.")

;;; Small utilities

(defun magnus-bridge--random-hex (nbytes)
  "Return NBYTES of cryptographically random data as a hex string.
Prefers openssl; falls back to Emacs `random'."
  (let ((out (ignore-errors
               (with-temp-buffer
                 (when (zerop (call-process "openssl" nil t nil
                                            "rand" "-hex"
                                            (number-to-string nbytes)))
                   (string-trim (buffer-string)))))))
    (if (and out (= (length out) (* 2 nbytes)))
        out
      (progn
        (random t)
        (mapconcat (lambda (_) (format "%02x" (random 256)))
                   (make-list nbytes 0) "")))))

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

;;; Tokens and pairing

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

;;; Events

(defun magnus-bridge--emit (type &rest fields)
  "Record and broadcast an event of TYPE with plist FIELDS."
  (let* ((event `((id . ,(cl-incf magnus-bridge--event-counter))
                  (ts . ,(magnus-bridge--now))
                  (type . ,type)
                  ,@(cl-loop for (k v) on fields by #'cddr
                             collect (cons (intern (substring (symbol-name k) 1))
                                           (or v ""))))))
    (push event magnus-bridge--events)
    (when (> (length magnus-bridge--events) magnus-bridge-history-size)
      (setcdr (nthcdr (1- magnus-bridge-history-size) magnus-bridge--events) nil))
    (magnus-bridge--broadcast event)
    event))

(defun magnus-bridge--broadcast (event)
  "Send EVENT to all connected SSE clients."
  (let ((frame (format "id: %d\ndata: %s\n\n"
                       (alist-get 'id event)
                       (json-serialize event)))
        (dead nil))
    (dolist (client magnus-bridge--sse-clients)
      (condition-case nil
          (process-send-string client frame)
        (error (push client dead))))
    (dolist (client dead)
      (setq magnus-bridge--sse-clients (delq client magnus-bridge--sse-clients))
      (ignore-errors (delete-process client)))))

(defun magnus-bridge--events-since (since)
  "Return events with id greater than SINCE, oldest first."
  (nreverse (cl-remove-if-not
             (lambda (e) (> (alist-get 'id e) since))
             magnus-bridge--events)))

;;; Magnus integration

(defun magnus-bridge--roster ()
  "Return the agent roster as a vector of alists."
  (vconcat
   (mapcar
    (lambda (instance)
      `((id . ,(magnus-instance-id instance))
        (name . ,(magnus-instance-name instance))
        (directory . ,(abbreviate-file-name
                       (or (magnus-instance-directory instance) "")))
        (status . ,(symbol-name (magnus-instance-status instance)))
        (health . ,(symbol-name (or (ignore-errors (magnus-health-get instance))
                                    'unknown)))
        (attention . ,(if (and (boundp 'magnus-attention-queue)
                               (member (magnus-instance-id instance)
                                       magnus-attention-queue))
                          t :false))))
    (magnus-instances-active-list))))

(defun magnus-bridge--send-to-agent (id text)
  "Deliver TEXT to the agent with instance ID.
Returns the instance name, or signals an error."
  (let ((instance (magnus-instances-get id)))
    (unless instance (error "No such agent"))
    (magnus-coord-nudge-agent
     instance
     (string-trim (replace-regexp-in-string "[\n\r]+" " " text))
     "Hrishi (phone)")
    (magnus-bridge--watch-replies instance)
    (magnus-instance-name instance)))

(defun magnus-bridge--prompt-tail (instance)
  "Return the trailing prompt text of INSTANCE's buffer, or nil."
  (when-let ((buffer (magnus-instance-buffer instance)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (ignore-errors (magnus-attention--tail-text))))))

(defun magnus-bridge--approve (id key)
  "Send whitelisted KEY to the attention-flagged instance ID."
  (unless (member key magnus-bridge--approve-keys)
    (error "Key not allowed"))
  (unless (and (boundp 'magnus-attention-queue)
               (member id magnus-attention-queue))
    (error "Agent is not waiting for input"))
  (let* ((instance (magnus-instances-get id))
         (buffer (and instance (magnus-instance-buffer instance))))
    (unless (and buffer (buffer-live-p buffer))
      (error "Agent buffer is gone"))
    (with-current-buffer buffer
      (if (string= key "esc")
          (vterm-send-escape)
        (vterm-send-string key)
        (vterm-send-return)))
    (magnus-instance-name instance)))

(defun magnus-bridge--on-attention-request (instance)
  "Emit an attention event for INSTANCE (advice on attention request)."
  (magnus-bridge--emit "attention"
                       :agent (magnus-instance-id instance)
                       :name (magnus-instance-name instance)
                       :text (or (magnus-bridge--prompt-tail instance) "")))

(defun magnus-bridge--on-attention-release (instance)
  "Emit an attention-clear event for INSTANCE."
  (magnus-bridge--emit "attention-clear"
                       :agent (magnus-instance-id instance)
                       :name (magnus-instance-name instance)))

;;; Reply streaming (agent -> phone)
;;
;; After the phone messages an agent, that agent's visible output — the
;; `text' blocks of its session JSONL, i.e. exactly what Claude Code
;; prints in the vterm — is relayed back for `magnus-bridge-reply-window'
;; seconds.  Thinking and tool internals are intentionally not relayed.

(defun magnus-bridge--session-file (instance)
  "Return the session JSONL path for INSTANCE, or nil."
  (when-let ((directory (magnus-instance-directory instance))
             (session-id (and (fboundp 'magnus-instance-session-id)
                              (magnus-instance-session-id instance))))
    (cond
     ((fboundp 'magnus-process--session-jsonl-path)
      (magnus-process--session-jsonl-path directory session-id))
     (t
      (expand-file-name
       (concat session-id ".jsonl")
       (expand-file-name
        (replace-regexp-in-string
         "[^A-Za-z0-9-]" "-" (directory-file-name (expand-file-name directory)))
        "~/.claude/projects/"))))))

(defun magnus-bridge--watch-replies (instance)
  "Start or extend the reply watch for INSTANCE."
  (when-let ((file (ignore-errors (magnus-bridge--session-file instance))))
    (let* ((id (magnus-instance-id instance))
           (existing (alist-get id magnus-bridge--reply-watches nil nil #'equal))
           (size (or (file-attribute-size (file-attributes file)) 0)))
      (setf (alist-get id magnus-bridge--reply-watches nil nil #'equal)
            (list :file file
                  :offset (if existing (plist-get existing :offset) size)
                  :until (+ (float-time) magnus-bridge-reply-window))))))

(defun magnus-bridge--poll-replies ()
  "Relay new visible output for every watched agent; expire old watches."
  (setq magnus-bridge--reply-watches
        (cl-remove-if (lambda (entry)
                        (< (plist-get (cdr entry) :until) (float-time)))
                      magnus-bridge--reply-watches))
  (dolist (entry magnus-bridge--reply-watches)
    (let* ((id (car entry))
           (watch (cdr entry))
           (instance (magnus-instances-get id)))
      (when instance
        (dolist (text (magnus-bridge--read-new-texts watch))
          (magnus-bridge--emit "reply"
                               :agent id
                               :name (magnus-instance-name instance)
                               :text text))))))

(defun magnus-bridge--read-new-texts (watch)
  "Read new complete JSONL lines for WATCH; return the agent's text blocks.
Advances WATCH's :offset past the lines consumed."
  (let ((file (plist-get watch :file))
        (offset (plist-get watch :offset))
        (texts nil))
    (when (and file (file-readable-p file))
      (let ((size (or (file-attribute-size (file-attributes file)) 0)))
        (when (> size offset)
          (with-temp-buffer
            (insert-file-contents file nil offset size)
            ;; Only consume complete lines; a partial tail stays for next poll.
            (goto-char (point-max))
            (when (search-backward "\n" nil t)
              (let ((consumed (buffer-substring-no-properties (point-min) (1+ (point)))))
                (plist-put watch :offset (+ offset (string-bytes consumed)))
                (dolist (line (split-string consumed "\n" t))
                  (when-let ((text (magnus-bridge--entry-text line)))
                    (push text texts)))))))))
    (nreverse texts)))

(defun magnus-bridge--entry-text (line)
  "Return the visible text of JSONL LINE if it is an assistant text block."
  (when-let ((entry (ignore-errors (json-parse-string line :object-type 'alist))))
    (when (equal (magnus-bridge--jget entry "type") "assistant")
      (let* ((message (magnus-bridge--jget entry "message"))
             (content (magnus-bridge--jget message "content"))
             (parts nil))
        (when (vectorp content)
          (dotimes (i (length content))
            (let ((block (aref content i)))
              (when (equal (magnus-bridge--jget block "type") "text")
                (push (magnus-bridge--jget block "text") parts)))))
        (let ((text (string-trim (string-join (nreverse parts) "\n"))))
          (unless (string-empty-p text) text))))))

;;; Auto-approve patterns (taught from the phone)

(defun magnus-bridge--load-patterns ()
  "Load learned patterns and merge them into the magnus allowlist."
  (setq magnus-bridge--learned-patterns
        (when (file-readable-p magnus-bridge-patterns-file)
          (ignore-errors
            (with-temp-buffer
              (insert-file-contents magnus-bridge-patterns-file)
              (read (current-buffer))))))
  (when (boundp 'magnus-attention-auto-approve-patterns)
    (dolist (pattern magnus-bridge--learned-patterns)
      (add-to-list 'magnus-attention-auto-approve-patterns pattern))))

(defun magnus-bridge--save-patterns ()
  "Persist learned patterns with restrictive permissions."
  (with-temp-file magnus-bridge-patterns-file
    (let ((print-length nil) (print-level nil))
      (prin1 magnus-bridge--learned-patterns (current-buffer))))
  (set-file-modes magnus-bridge-patterns-file #o600))

(defun magnus-bridge--pattern-add (pattern)
  "Learn PATTERN for auto-approval.  Return nil if invalid."
  (when (and (stringp pattern)
             (>= (length (string-trim pattern)) 6) ; no trivially-broad patterns
             (< (length pattern) 200))
    (let ((pattern (string-trim pattern)))
      (add-to-list 'magnus-bridge--learned-patterns pattern)
      (when (boundp 'magnus-attention-auto-approve-patterns)
        (add-to-list 'magnus-attention-auto-approve-patterns pattern))
      (magnus-bridge--save-patterns)
      pattern)))

(defun magnus-bridge--pattern-remove (pattern)
  "Forget learned PATTERN.  Only phone-learned patterns can be removed."
  (when (member pattern magnus-bridge--learned-patterns)
    (setq magnus-bridge--learned-patterns
          (delete pattern magnus-bridge--learned-patterns))
    (when (boundp 'magnus-attention-auto-approve-patterns)
      (setq magnus-attention-auto-approve-patterns
            (delete pattern magnus-attention-auto-approve-patterns)))
    (magnus-bridge--save-patterns)
    t))

(defun magnus-bridge--on-auto-approve (orig instance)
  "Call ORIG with INSTANCE, surfacing auto-approvals in the phone feed."
  (let ((approved (funcall orig instance)))
    (when approved
      (magnus-bridge--emit
       "auto-approved"
       :agent (magnus-instance-id instance)
       :name (magnus-instance-name instance)
       :text (or (magnus-bridge--prompt-tail instance) "")))
    approved))

;;; Mention watching (agent -> phone)

(defun magnus-bridge--coord-files ()
  "Return the coordination files for all active instance directories."
  (let ((coord (if (boundp 'magnus-coord-file) magnus-coord-file
                 ".magnus-coord.md")))
    (delete-dups
     (delq nil
           (mapcar (lambda (instance)
                     (when-let ((dir (magnus-instance-directory instance)))
                       (expand-file-name coord dir)))
                   (magnus-instances-active-list))))))

(defun magnus-bridge--mention-lines (file)
  "Return lines of FILE mentioning the bridge user."
  (when (file-readable-p file)
    (let ((re (format "@%s\\b" (regexp-quote magnus-bridge-user-mention))))
      (with-temp-buffer
        (insert-file-contents file)
        (cl-remove-if-not
         (lambda (line) (string-match-p re line))
         (split-string (buffer-string) "\n" t))))))

(defun magnus-bridge--guess-agent (line)
  "Guess which active agent wrote LINE, returning (ID . NAME) or nil."
  (cl-loop for instance in (magnus-instances-active-list)
           for name = (magnus-instance-name instance)
           when (and name (string-match-p (regexp-quote name) line))
           return (cons (magnus-instance-id instance) name)))

(defun magnus-bridge--scan-mentions (&optional prime)
  "Scan coordination files for new user mentions.
With PRIME non-nil, record current mentions without emitting events, so
starting the bridge does not replay history."
  (dolist (file (magnus-bridge--coord-files))
    (let ((seen (gethash file magnus-bridge--seen-mentions)))
      (dolist (line (magnus-bridge--mention-lines file))
        (let ((hash (md5 line)))
          (unless (member hash seen)
            (push hash seen)
            (unless prime
              (let ((agent (magnus-bridge--guess-agent line)))
                (magnus-bridge--emit "mention"
                                     :agent (car agent)
                                     :name (or (cdr agent) "crew")
                                     :text (string-trim line)))))))
      (puthash file seen magnus-bridge--seen-mentions))))

;;; HTTP plumbing

(defconst magnus-bridge--content-types
  '(("html" . "text/html; charset=utf-8")
    ("css" . "text/css; charset=utf-8")
    ("js" . "text/javascript; charset=utf-8")
    ("json" . "application/json")
    ("webmanifest" . "application/manifest+json")
    ("png" . "image/png")
    ("svg" . "image/svg+xml")))

(defun magnus-bridge--pwa-directory ()
  "Directory holding the bundled PWA assets."
  (expand-file-name
   "pwa" (file-name-directory
          (or (locate-library "magnus-bridge") load-file-name
              buffer-file-name))))

(defun magnus-bridge--respond (proc status headers body &optional keep-open)
  "Write an HTTP response to PROC with STATUS, HEADERS and BODY.
The connection is closed unless KEEP-OPEN is non-nil."
  (let ((payload (if (multibyte-string-p body)
                     (encode-coding-string body 'utf-8)
                   body)))
    (condition-case nil
        (progn
          (process-send-string
           proc
           (concat (format "HTTP/1.1 %s\r\n" status)
                   (mapconcat (lambda (h) (format "%s: %s\r\n" (car h) (cdr h)))
                              headers "")
                   (unless keep-open
                     (format "Content-Length: %d\r\nConnection: close\r\n"
                             (string-bytes payload)))
                   "\r\n"))
          (unless (string-empty-p payload)
            (process-send-string proc payload))
          (unless keep-open
            (delete-process proc)))
      (error (ignore-errors (delete-process proc))))))

(defun magnus-bridge--respond-json (proc status object)
  "Send OBJECT to PROC as a JSON response with HTTP STATUS."
  (magnus-bridge--respond
   proc status
   '(("Content-Type" . "application/json")
     ("Cache-Control" . "no-store"))
   (json-serialize object)))

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

;;; Connection handling

(cl-defun magnus-bridge--filter (proc chunk)
  "Accumulate CHUNK for PROC and dispatch when a full request arrived."
  (let ((buffered (concat (or (process-get proc 'mb-buffer) "") chunk)))
    (process-put proc 'mb-buffer buffered)
    (when-let ((header-end (string-search "\r\n\r\n" buffered)))
      (let* ((head (substring buffered 0 header-end))
             (lines (split-string head "\r\n"))
             (request-line (split-string (car lines) " "))
             (headers (mapcar (lambda (line)
                                (let ((colon (string-search ":" line)))
                                  (cons (downcase (substring line 0 colon))
                                        (string-trim (substring line (1+ colon))))))
                              (cl-remove-if-not
                               (lambda (l) (string-search ":" l))
                               (cdr lines))))
             (content-length (string-to-number
                              (or (cdr (assoc "content-length" headers)) "0")))
             (body-start (+ header-end 4)))
        (when (> content-length magnus-bridge-max-upload-bytes)
          (process-put proc 'mb-buffer nil)
          (magnus-bridge--respond-json proc "413 Payload Too Large"
                                       '((error . "too-large")))
          (cl-return-from magnus-bridge--filter))
        (when (>= (- (string-bytes buffered) body-start) content-length)
          (process-put proc 'mb-buffer nil)
          (magnus-bridge--dispatch
           proc
           (nth 0 request-line)
           (nth 1 request-line)
           headers
           (decode-coding-string
            (substring buffered body-start (+ body-start content-length))
            'utf-8)))))))

(defun magnus-bridge--sentinel (proc _event)
  "Drop PROC from the SSE client list when it dies."
  (unless (process-live-p proc)
    (setq magnus-bridge--sse-clients
          (delq proc magnus-bridge--sse-clients))))

;;; Routing

(defun magnus-bridge--dispatch (proc method target headers body)
  "Route METHOD TARGET with HEADERS and BODY arriving on PROC."
  (let* ((parts (split-string (or target "/") "?"))
         (path (car parts))
         (query (when (cadr parts) (url-parse-query-string (cadr parts))))
         (identity (magnus-bridge--identity headers)))
    (cond
     ;; Perimeter: no acceptable tailnet identity -> drop.
     ((null identity)
      (magnus-bridge--audit "rejected-identity" path)
      (magnus-bridge--respond-json proc "403 Forbidden"
                                   '((error . "forbidden"))))
     ;; Static assets and the app shell need no device token: the
     ;; pairing screen itself lives there.  The tailnet identity check
     ;; above still applies.
     ((and (string= method "GET") (not (string-prefix-p "/api/" path)))
      (magnus-bridge--serve-static proc path))
     ((and (string= method "POST") (string= path "/api/pair"))
      (magnus-bridge--handle-pair proc body identity))
     ;; Everything under /api requires a paired device.
     ((not (magnus-bridge--token-valid-p
            (magnus-bridge--request-token headers)))
      (magnus-bridge--audit "rejected-token" path
                            (and (stringp identity) identity))
      (magnus-bridge--respond-json proc "401 Unauthorized"
                                   '((error . "pair-required"))))
     ((and (string= method "GET") (string= path "/api/events"))
      (magnus-bridge--handle-events proc headers query))
     ((and (string= method "GET") (string= path "/api/status"))
      (magnus-bridge--respond-json
       proc "200 OK"
       `((agents . ,(magnus-bridge--roster))
         (version . ,magnus-bridge-version))))
     ((and (string= method "GET") (string= path "/api/history"))
      (let ((since (string-to-number
                    (or (cadr (assoc "since" query)) "0"))))
        (magnus-bridge--respond-json
         proc "200 OK"
         `((events . ,(vconcat (magnus-bridge--events-since since)))))))
     ((and (string= method "POST") (string= path "/api/send"))
      (magnus-bridge--handle-send proc body identity))
     ((and (string= method "POST") (string= path "/api/upload"))
      (magnus-bridge--handle-upload proc body identity))
     ((and (string= method "POST") (string= path "/api/approve"))
      (magnus-bridge--handle-approve proc body identity))
     ((and (string= method "GET") (string= path "/api/patterns"))
      (magnus-bridge--respond-json
       proc "200 OK"
       `((learned . ,(vconcat magnus-bridge--learned-patterns))
         (builtin . ,(vconcat
                      (if (boundp 'magnus-attention-auto-approve-patterns)
                          (cl-set-difference magnus-attention-auto-approve-patterns
                                             magnus-bridge--learned-patterns
                                             :test #'equal)
                        nil))))))
     ((and (string= method "POST") (string= path "/api/patterns"))
      (magnus-bridge--handle-patterns proc body identity))
     (t
      (magnus-bridge--respond-json proc "404 Not Found"
                                   '((error . "not-found")))))))

(defun magnus-bridge--serve-static (proc path)
  "Serve PATH from the bundled PWA directory to PROC."
  (let* ((relative (if (string= path "/") "index.html"
                     (substring path 1)))
         (root (file-truename (magnus-bridge--pwa-directory)))
         (file (ignore-errors
                 (file-truename (expand-file-name relative root)))))
    (if (and file
             (string-prefix-p (file-name-as-directory root) file)
             (file-regular-p file))
        (let ((type (or (cdr (assoc (file-name-extension file)
                                    magnus-bridge--content-types))
                        "application/octet-stream")))
          (magnus-bridge--respond
           proc "200 OK"
           `(("Content-Type" . ,type)
             ("Cache-Control" . "no-cache"))
           (with-temp-buffer
             (set-buffer-multibyte nil)
             (insert-file-contents-literally file)
             (buffer-string))))
      (magnus-bridge--respond proc "404 Not Found"
                              '(("Content-Type" . "text/plain"))
                              "not found"))))

(defun magnus-bridge--handle-pair (proc body identity)
  "Handle a pairing attempt with BODY from IDENTITY on PROC."
  (let* ((parsed (ignore-errors (json-parse-string body :object-type 'alist)))
         (code (magnus-bridge--jget parsed "code"))
         (device (magnus-bridge--jget parsed "device"))
         (token (magnus-bridge--try-pair code device)))
    (if token
        (progn
          (magnus-bridge--audit "paired" device
                                (and (stringp identity) identity))
          (magnus-bridge--respond
           proc "200 OK"
           `(("Content-Type" . "application/json")
             ("Set-Cookie"
              . ,(format
                  "mb_token=%s; Path=/; Max-Age=31536000; HttpOnly; Secure; SameSite=Strict"
                  token)))
           (json-serialize '((ok . t)))))
      (magnus-bridge--audit "pair-failed" nil
                            (and (stringp identity) identity))
      (magnus-bridge--respond-json proc "403 Forbidden"
                                   '((error . "bad-code"))))))

(defun magnus-bridge--handle-events (proc headers query)
  "Subscribe PROC to the event stream.
Resumes from the Last-Event-ID in HEADERS or a `since' in QUERY."
  (let ((since (string-to-number
                (or (cdr (assoc "last-event-id" headers))
                    (cadr (assoc "since" query))
                    "0"))))
    (magnus-bridge--respond
     proc "200 OK"
     '(("Content-Type" . "text/event-stream")
       ("Cache-Control" . "no-store")
       ("X-Accel-Buffering" . "no"))
     "" t)
    (push proc magnus-bridge--sse-clients)
    (set-process-sentinel proc #'magnus-bridge--sentinel)
    (dolist (event (magnus-bridge--events-since since))
      (condition-case nil
          (process-send-string
           proc (format "id: %d\ndata: %s\n\n"
                        (alist-get 'id event)
                        (json-serialize event)))
        (error nil)))))

(defun magnus-bridge--handle-send (proc body identity)
  "Handle a chat message in BODY from IDENTITY on PROC."
  (let* ((parsed (ignore-errors (json-parse-string body :object-type 'alist)))
         (agent (magnus-bridge--jget parsed "agent"))
         (text (magnus-bridge--jget parsed "text")))
    (cond
     ((or (not (stringp text)) (string-empty-p (string-trim text)))
      (magnus-bridge--respond-json proc "400 Bad Request"
                                   '((error . "empty"))))
     ((> (length text) magnus-bridge-max-message-length)
      (magnus-bridge--respond-json proc "400 Bad Request"
                                   '((error . "too-long"))))
     (t
      (condition-case err
          (let ((name (magnus-bridge--send-to-agent agent text)))
            (magnus-bridge--audit "send" (format "%s: %s" name text)
                                  (and (stringp identity) identity))
            (magnus-bridge--emit "sent" :agent agent :name name :text text)
            (magnus-bridge--respond-json proc "200 OK" '((ok . t))))
        (error
         (magnus-bridge--respond-json
          proc "400 Bad Request"
          `((error . ,(error-message-string err))))))))))

(defun magnus-bridge--handle-approve (proc body identity)
  "Handle a permission approval in BODY from IDENTITY on PROC."
  (let* ((parsed (ignore-errors (json-parse-string body :object-type 'alist)))
         (agent (magnus-bridge--jget parsed "agent"))
         (key (magnus-bridge--jget parsed "key")))
    (condition-case err
        (let ((name (magnus-bridge--approve agent key)))
          (magnus-bridge--audit "approve" (format "%s <- %s" name key)
                                (and (stringp identity) identity))
          (magnus-bridge--emit "approved" :agent agent :name name :text key)
          (magnus-bridge--respond-json proc "200 OK" '((ok . t))))
      (error
       (magnus-bridge--audit "approve-denied"
                             (format "%s <- %s: %s" agent key
                                     (error-message-string err))
                             (and (stringp identity) identity))
       (magnus-bridge--respond-json
        proc "400 Bad Request"
        `((error . ,(error-message-string err))))))))

(defun magnus-bridge--handle-upload (proc body identity)
  "Handle a photo upload in BODY from IDENTITY on PROC.
The image is saved on this machine and the agent is pointed at the
path — Claude Code agents can Read image files directly.  The server
chooses the filename; client names are never trusted."
  (let* ((parsed (ignore-errors (json-parse-string body :object-type 'alist)))
         (agent (magnus-bridge--jget parsed "agent"))
         (text (or (magnus-bridge--jget parsed "text") ""))
         (image (magnus-bridge--jget parsed "image"))
         (data (and (stringp image)
                    (ignore-errors (base64-decode-string image)))))
    (cond
     ((or (null data) (< (length data) 100))
      (magnus-bridge--respond-json proc "400 Bad Request"
                                   '((error . "bad-image"))))
     (t
      (condition-case err
          (let* ((file (expand-file-name
                        (format-time-string "photo-%Y%m%d-%H%M%S%3N.jpg" nil t)
                        magnus-bridge-attachments-directory))
                 (message-text
                  (format "%s [photo saved at %s — use the Read tool to view it]"
                          (string-trim text) file)))
            (make-directory magnus-bridge-attachments-directory t)
            (let ((coding-system-for-write 'no-conversion))
              (write-region data nil file nil 0))
            (set-file-modes file #o600)
            (let ((name (magnus-bridge--send-to-agent agent message-text)))
              (magnus-bridge--audit "upload"
                                    (format "%s <- %s (%d bytes)"
                                            name file (length data))
                                    (and (stringp identity) identity))
              (magnus-bridge--emit "sent" :agent agent :name name
                                   :text (concat (string-trim text) " 📷 photo"))
              (magnus-bridge--respond-json proc "200 OK" '((ok . t)))))
        (error
         (magnus-bridge--respond-json
          proc "400 Bad Request"
          `((error . ,(error-message-string err))))))))))

(defun magnus-bridge--handle-patterns (proc body identity)
  "Handle a pattern add/remove request in BODY from IDENTITY on PROC.
Patterns are security-relevant standing permissions, so every change is
audited loudly and only phone-learned patterns can be removed."
  (let* ((parsed (ignore-errors (json-parse-string body :object-type 'alist)))
         (action (magnus-bridge--jget parsed "action"))
         (pattern (magnus-bridge--jget parsed "pattern")))
    (cond
     ((and (equal action "add") (magnus-bridge--pattern-add pattern))
      (magnus-bridge--audit "pattern-learned" pattern
                            (and (stringp identity) identity))
      (magnus-bridge--emit "pattern-learned" :text (string-trim pattern))
      (message "Magnus bridge: phone taught auto-approve pattern %S"
               (string-trim pattern))
      (magnus-bridge--respond-json proc "200 OK" '((ok . t))))
     ((and (equal action "remove") (magnus-bridge--pattern-remove pattern))
      (magnus-bridge--audit "pattern-removed" pattern
                            (and (stringp identity) identity))
      (magnus-bridge--emit "pattern-removed" :text pattern)
      (magnus-bridge--respond-json proc "200 OK" '((ok . t))))
     (t
      (magnus-bridge--audit "pattern-rejected"
                            (format "%s %s" action pattern)
                            (and (stringp identity) identity))
      (magnus-bridge--respond-json proc "400 Bad Request"
                                   '((error . "bad-pattern")))))))

;;; Lifecycle

(defun magnus-bridge--heartbeat ()
  "Keep SSE connections alive and prune the dead."
  (let ((dead nil))
    (dolist (client magnus-bridge--sse-clients)
      (condition-case nil
          (process-send-string client ": hb\n\n")
        (error (push client dead))))
    (dolist (client dead)
      (setq magnus-bridge--sse-clients
            (delq client magnus-bridge--sse-clients)))))

;;;###autoload
(defun magnus-bridge-start ()
  "Start the bridge server on 127.0.0.1."
  (interactive)
  (when magnus-bridge--server
    (user-error "Magnus bridge is already running"))
  (magnus-bridge--load-tokens)
  (setq magnus-bridge--server
        (make-network-process
         :name "magnus-bridge"
         :server t
         :host "127.0.0.1"
         :service magnus-bridge-port
         :family 'ipv4
         :coding 'binary
         :filter #'magnus-bridge--filter
         :noquery t))
  (setq magnus-bridge--heartbeat-timer
        (run-with-timer 25 25 #'magnus-bridge--heartbeat))
  (magnus-bridge--load-patterns)
  (when (featurep 'magnus)
    (advice-add 'magnus-attention-request :after
                #'magnus-bridge--on-attention-request)
    (advice-add 'magnus-attention-release :after
                #'magnus-bridge--on-attention-release)
    (when (fboundp 'magnus-attention--try-auto-approve)
      (advice-add 'magnus-attention--try-auto-approve :around
                  #'magnus-bridge--on-auto-approve))
    (magnus-bridge--scan-mentions 'prime)
    (setq magnus-bridge--mention-timer
          (run-with-timer magnus-bridge-mention-poll-interval
                          magnus-bridge-mention-poll-interval
                          #'magnus-bridge--scan-mentions))
    (setq magnus-bridge--reply-timer
          (run-with-timer magnus-bridge-reply-poll-interval
                          magnus-bridge-reply-poll-interval
                          #'magnus-bridge--poll-replies)))
  (magnus-bridge--audit "start" (format "port %d" magnus-bridge-port))
  (message "Magnus bridge listening on 127.0.0.1:%d — run M-x magnus-bridge-setup-tailscale to expose it"
           magnus-bridge-port))

;;;###autoload
(defun magnus-bridge-stop ()
  "Stop the bridge server and disconnect all clients."
  (interactive)
  (when magnus-bridge--heartbeat-timer
    (cancel-timer magnus-bridge--heartbeat-timer)
    (setq magnus-bridge--heartbeat-timer nil))
  (when magnus-bridge--mention-timer
    (cancel-timer magnus-bridge--mention-timer)
    (setq magnus-bridge--mention-timer nil))
  (when magnus-bridge--reply-timer
    (cancel-timer magnus-bridge--reply-timer)
    (setq magnus-bridge--reply-timer nil))
  (setq magnus-bridge--reply-watches nil)
  (advice-remove 'magnus-attention-request
                 #'magnus-bridge--on-attention-request)
  (advice-remove 'magnus-attention-release
                 #'magnus-bridge--on-attention-release)
  (advice-remove 'magnus-attention--try-auto-approve
                 #'magnus-bridge--on-auto-approve)
  (dolist (client magnus-bridge--sse-clients)
    (ignore-errors (delete-process client)))
  (setq magnus-bridge--sse-clients nil)
  (when magnus-bridge--server
    (delete-process magnus-bridge--server)
    (setq magnus-bridge--server nil))
  (magnus-bridge--audit "stop" nil)
  (message "Magnus bridge stopped."))

;;;###autoload
(defun magnus-bridge-lockdown ()
  "Emergency stop: kill the server and revoke every device token."
  (interactive)
  (magnus-bridge-stop)
  (magnus-bridge-revoke-all-devices)
  (magnus-bridge--audit "lockdown" nil)
  (message "Magnus bridge LOCKDOWN: server stopped, all devices revoked."))

;;; Tailscale setup

(defun magnus-bridge--tailscale-cli ()
  "Locate the tailscale CLI, or nil."
  (or (executable-find "tailscale")
      (let ((app "/Applications/Tailscale.app/Contents/MacOS/Tailscale"))
        (and (file-executable-p app) app))))

;;;###autoload
(defun magnus-bridge-setup-tailscale ()
  "Expose the bridge on your tailnet via `tailscale serve'.
Prints the HTTPS URL to open on your phone."
  (interactive)
  (let ((cli (magnus-bridge--tailscale-cli)))
    (unless cli
      (user-error "Tailscale CLI not found — install from https://tailscale.com/download"))
    (with-temp-buffer
      (let ((exit (call-process cli nil t nil "serve" "--bg"
                                (number-to-string magnus-bridge-port))))
        (if (zerop exit)
            (let ((url (magnus-bridge--tailscale-url cli)))
              (magnus-bridge--audit "tailscale-serve" url)
              (message "Magnus bridge is live on your tailnet: %s" url))
          (user-error "Tailscale serve failed: %s"
                      (string-trim (buffer-string))))))))

(defun magnus-bridge--tailscale-url (cli)
  "Return the HTTPS URL of this machine on the tailnet using CLI."
  (with-temp-buffer
    (if (zerop (call-process cli nil t nil "status" "--json"))
        (let* ((status (json-parse-string (buffer-string)
                                          :object-type 'alist))
               (self (magnus-bridge--jget status "Self"))
               (dns (magnus-bridge--jget self "DNSName")))
          (format "https://%s" (string-remove-suffix "." (or dns "?"))))
      "https://<your-machine>.<tailnet>.ts.net")))

;;;###autoload
(defun magnus-bridge-audit ()
  "Open the bridge audit log."
  (interactive)
  (find-file magnus-bridge-audit-file))

(provide 'magnus-bridge)

;;; magnus-bridge.el ends here
