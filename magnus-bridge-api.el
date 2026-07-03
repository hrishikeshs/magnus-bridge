;;; magnus-bridge-api.el --- HTTP routing and API handlers for magnus-bridge -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Hrishikesh S
;; Author: Hrishikesh S
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; The routing table and every /api handler, plus static serving of
;; the bundled PWA (path-traversal safe).  Auth gates: Tailscale
;; identity first, then the per-device token for everything except
;; pairing and static assets.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'magnus-bridge-auth)
(require 'magnus-bridge-events)
(require 'magnus-bridge-agents)
(require 'magnus-bridge-server)

(defcustom magnus-bridge-attachments-directory
  (expand-file-name "magnus-bridge-attachments" user-emacs-directory)
  "Directory where photos sent from the phone are stored for agents."
  :type 'directory
  :group 'magnus-bridge)

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
(provide 'magnus-bridge-api)

;;; magnus-bridge-api.el ends here
