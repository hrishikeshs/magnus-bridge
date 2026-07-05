;;; magnus-bridge-events.el --- Event log, SSE broadcast and durable history for magnus-bridge -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Hrishikesh S
;; Author: Hrishikesh S
;; Assisted-by: Claude Code:claude-fable-5
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Every conversation item is an event: assigned a monotonic id,
;; broadcast to SSE clients, kept in memory and appended to a history
;; file so chats survive both page refreshes and Emacs restarts.
;; Transient events (typing) are broadcast without ids and never stored.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'magnus-bridge-auth)

(defcustom magnus-bridge-history-size 500
  "Number of events kept for reconnecting clients."
  :type 'integer
  :group 'magnus-bridge)

(defcustom magnus-bridge-history-file
  (expand-file-name "magnus-bridge-history.jsonl" user-emacs-directory)
  "File persisting chat history across Emacs restarts (mode 0600)."
  :type 'file
  :group 'magnus-bridge)

(defvar magnus-bridge--sse-clients nil
  "List of processes subscribed to /api/events.")

(defvar magnus-bridge--events nil
  "Recent events, newest first, capped at `magnus-bridge-history-size'.")

(defvar magnus-bridge--event-counter 0
  "Monotonic id assigned to events.")

(defvar magnus-bridge--heartbeat-timer nil)

(defvar magnus-bridge--history-appends 0
  "Lines appended to the history file since the last compaction.")

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
    (ignore-errors
      (write-region (concat (json-serialize event) "\n") nil
                    magnus-bridge-history-file 'append 0)
      (set-file-modes magnus-bridge-history-file #o600)
      ;; Compact periodically, not only at startup: Emacs sessions here
      ;; run for weeks, so the file would otherwise grow unbounded.
      (when (> (cl-incf magnus-bridge--history-appends)
               (* 2 magnus-bridge-history-size))
        (magnus-bridge--compact-history)))
    (magnus-bridge--broadcast event)
    event))

(defun magnus-bridge--compact-history ()
  "Rewrite the history file from the in-memory event list."
  (with-temp-file magnus-bridge-history-file
    (dolist (event (reverse magnus-bridge--events))
      (insert (json-serialize event) "\n")))
  (set-file-modes magnus-bridge-history-file #o600)
  (setq magnus-bridge--history-appends 0))

(defun magnus-bridge--load-history ()
  "Restore persisted events so history survives Emacs restarts.
Loads only when the in-memory history is empty, keeps the newest
`magnus-bridge-history-size' events, and compacts the file when it
has grown far past what is retained."
  (when (and (null magnus-bridge--events)
             (file-readable-p magnus-bridge-history-file))
    (with-temp-buffer
      (insert-file-contents magnus-bridge-history-file)
      (goto-char (point-min))
      (while (not (eobp))
        (let ((line (buffer-substring-no-properties
                     (point) (line-end-position))))
          (when-let ((event (magnus-bridge--parse-event line)))
            (push event magnus-bridge--events)))
        (forward-line 1)))
    (when (> (length magnus-bridge--events) magnus-bridge-history-size)
      (setcdr (nthcdr (1- magnus-bridge-history-size) magnus-bridge--events) nil))
    (dolist (event magnus-bridge--events)
      (setq magnus-bridge--event-counter
            (max magnus-bridge--event-counter (or (alist-get 'id event) 0))))
    (when (> (or (file-attribute-size
                  (file-attributes magnus-bridge-history-file)) 0)
             (* 2 1024 1024))
      (magnus-bridge--compact-history))))

(defun magnus-bridge--parse-event (line)
  "Parse a persisted event LINE, normalizing keys back to symbols."
  (when-let ((parsed (and (not (string-empty-p line))
                          (ignore-errors
                            (json-parse-string line :object-type 'alist)))))
    (mapcar (lambda (pair)
              (cons (if (stringp (car pair)) (intern (car pair)) (car pair))
                    (cdr pair)))
            parsed)))

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

(defun magnus-bridge--broadcast-transient (type &rest fields)
  "Broadcast an ephemeral event of TYPE with plist FIELDS.
Transient events are pushed to live clients but never stored, and the
SSE frame carries no id so reconnect cursors are unaffected."
  (let* ((event `((type . ,type)
                  ,@(cl-loop for (k v) on fields by #'cddr
                             collect (cons (intern (substring (symbol-name k) 1))
                                           (or v "")))))
         (frame (format "data: %s\n\n" (json-serialize event)))
         (dead nil))
    (dolist (client magnus-bridge--sse-clients)
      (condition-case nil
          (process-send-string client frame)
        (error (push client dead))))
    (dolist (client dead)
      (setq magnus-bridge--sse-clients
            (delq client magnus-bridge--sse-clients)))))

(defun magnus-bridge--events-since (since)
  "Return events with id greater than SINCE, oldest first.
Uses non-destructive `reverse': `cl-remove-if-not' may share structure
with `magnus-bridge--events', and reversing shared cells in place
destroys the history it is supposed to be reading."
  (reverse (cl-remove-if-not
            (lambda (e) (> (alist-get 'id e) since))
            magnus-bridge--events)))

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

(provide 'magnus-bridge-events)

;;; magnus-bridge-events.el ends here
