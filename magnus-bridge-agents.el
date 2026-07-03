;;; magnus-bridge-agents.el --- Magnus agent integration for magnus-bridge -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Hrishikesh S
;; Author: Hrishikesh S
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; The Magnus-facing half: roster, message delivery via coord nudges,
;; reply streaming (only the text blocks an agent prints in its
;; terminal -- thinking and tool internals never leave the machine),
;; attention events, @mention scanning, and taught auto-approve
;; patterns.  All magnus functions are late-bound so the server can be
;; exercised against a stub in batch tests.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'magnus-bridge-auth)
(require 'magnus-bridge-events)

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

(defcustom magnus-bridge-user-mention (user-login-name)
  "Mention name agents use to message you (without the @).
Agents writing @<this-name> in the coordination Log reach your phone.
Defaults to your login name; set it to whatever your agents call you."
  :type 'string
  :group 'magnus-bridge)

(defcustom magnus-bridge-max-message-length 4000
  "Maximum accepted length for an inbound chat message."
  :type 'integer
  :group 'magnus-bridge)

(defcustom magnus-bridge-mention-poll-interval 10
  "Seconds between scans of coordination files for user mentions."
  :type 'integer
  :group 'magnus-bridge)

(defcustom magnus-bridge-reply-window 900
  "Seconds to relay an agent's replies after you message it.
After a message from the phone, the agent's visible output (the text
it prints in its Claude Code terminal) is streamed back for this many
seconds.  Thinking traces and tool internals are never relayed — use
sift or the JSONL on a real screen for those."
  :type 'integer
  :group 'magnus-bridge)

(defcustom magnus-bridge-reply-poll-interval 3
  "Seconds between checks for new agent output while a reply watch is active."
  :type 'integer
  :group 'magnus-bridge)

(defcustom magnus-bridge-patterns-file
  (expand-file-name "magnus-bridge-patterns.eld" user-emacs-directory)
  "File persisting auto-approve patterns learned from the phone."
  :type 'file
  :group 'magnus-bridge)

(defconst magnus-bridge--approve-keys '("1" "2" "3" "y" "n" "esc")
  "The only key sequences the approve endpoint will deliver.")

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
     (format "%s (phone)" magnus-bridge-user-mention))
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
        (let* ((before (plist-get watch :offset))
               (texts (magnus-bridge--read-new-texts watch))
               (advanced (> (plist-get watch :offset) before)))
          (dolist (text texts)
            (magnus-bridge--emit "reply"
                                 :agent id
                                 :name (magnus-instance-name instance)
                                 :text text))
          ;; Session file grew but produced no visible text: the agent
          ;; is thinking or running tools — i.e. typing.
          (when (and advanced (null texts))
            (magnus-bridge--broadcast-transient
             "typing"
             :agent id
             :name (magnus-instance-name instance))))))))

(defun magnus-bridge--read-new-texts (watch)
  "Read new complete JSONL lines for WATCH; return the agent's text blocks.
Advances WATCH's :offset past the lines consumed."
  (let ((file (plist-get watch :file))
        (offset (plist-get watch :offset))
        (texts nil))
    (when (and file (file-readable-p file))
      (let* ((full-size (or (file-attribute-size (file-attributes file)) 0))
             ;; Cap each poll's read; a partial tail line simply waits
             ;; for the next poll, so large bursts drain incrementally.
             (size (min full-size (+ offset (* 256 1024)))))
        (when (> size offset)
          (with-temp-buffer
            (insert-file-contents file nil offset size)
            (goto-char (point-max))
            ;; A single line larger than the cap would never contain a
            ;; newline and stall the watch — take the full range then.
            (when (and (< size full-size)
                       (not (save-excursion (search-backward "\n" nil t))))
              (erase-buffer)
              (insert-file-contents file nil offset full-size)
              (goto-char (point-max)))
            ;; Only consume complete lines; a partial tail stays for next poll.
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

(provide 'magnus-bridge-agents)

;;; magnus-bridge-agents.el ends here
