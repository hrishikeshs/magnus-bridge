;;; magnus-bridge.el --- Chat with your Magnus agents from your phone -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Hrishikesh S

;; Author: Hrishikesh S
;; URL: https://github.com/hrishikeshs/magnus-bridge
;; Version: 0.6.0
;; Package-Requires: ((emacs "28.1") (magnus "0.5"))
;; Keywords: tools, processes, convenience

;; This file is not part of GNU Emacs.

;; Permission is hereby granted, free of charge, to any person obtaining a copy
;; of this software and associated documentation files (the "Software"), to deal
;; in the Software without restriction, including without limitation the rights
;; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
;; copies of the Software, and to permit persons to whom the Software is
;; furnished to do so, subject to the following conditions:
;;
;; The above copyright notice and this permission notice shall be included in
;; all copies or substantial portions of the Software.
;;
;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
;; FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
;; IN THE SOFTWARE.

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
;;
;; The package is split by concern:
;;   magnus-bridge-auth.el    identity, pairing, tokens, audit
;;   magnus-bridge-events.el  event log, SSE, durable history
;;   magnus-bridge-agents.el  magnus integration, replies, patterns
;;   magnus-bridge-api.el     HTTP server, routing, PWA serving

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'url-util)
(require 'magnus-bridge-auth)
(require 'magnus-bridge-events)
(require 'magnus-bridge-agents)
(require 'magnus-bridge-api)

(defcustom magnus-bridge-port 8377
  "Local port the bridge HTTP server listens on (127.0.0.1 only)."
  :type 'integer
  :group 'magnus-bridge)

(defvar magnus-bridge--server nil
  "The listening network process, or nil.")

;;;###autoload
(defun magnus-bridge-start ()
  "Start the bridge server on 127.0.0.1."
  (interactive)
  (when magnus-bridge--server
    (user-error "Magnus bridge is already running"))
  (magnus-bridge--load-tokens)
  (magnus-bridge--load-history)
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

(provide 'magnus-bridge)

;;; magnus-bridge.el ends here
