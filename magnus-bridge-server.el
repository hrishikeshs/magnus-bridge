;;; magnus-bridge-server.el --- Minimal HTTP/1.1 server for magnus-bridge -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Hrishikesh S
;; Author: Hrishikesh S
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A hand-rolled HTTP server on make-network-process, bound to
;; 127.0.0.1 only.  Accumulates requests in process properties,
;; enforces the body-size cap, and hands complete requests to the
;; router in magnus-bridge-api.el (late-bound to avoid a require
;; cycle).

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'magnus-bridge-auth)

(declare-function magnus-bridge--dispatch "magnus-bridge-api")

(defcustom magnus-bridge-max-upload-bytes (* 20 1024 1024)
  "Maximum accepted HTTP request body size in bytes."
  :type 'integer
  :group 'magnus-bridge)

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
(provide 'magnus-bridge-server)

;;; magnus-bridge-server.el ends here
