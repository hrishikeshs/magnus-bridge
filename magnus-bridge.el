;;; magnus-bridge.el --- Put Magnus agents on Bridge -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Hrishikesh S
;; Author: Hrishikesh S
;; Assisted-by: Claude Code:claude-opus-4-8
;; Assisted-by: OpenAI Codex:gpt-5
;; Version: 0.8.0
;; Package-Requires: ((emacs "28.1") (magnus "0.5"))
;; Keywords: tools, processes, convenience
;; URL: https://github.com/hrishikeshs/magnus-bridge
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; magnus-bridge hosts Magnus-managed Claude Code agents on the separate
;; bridge daemon.  The daemon owns the phone app, identity, history,
;; delivery, and prompt semantics; this package only adapts live Magnus
;; vterms to its remote transport.  One daemon, one phone app, N
;; environments — Emacs is one place agents can live.
;;
;; The daemon owns a pluggable transport layer (see the sibling repo's
;; docs/transports.md).  A "remote" transport lets any local process
;; register agents it hosts and answer, from continuously-attested state,
;; the five questions the daemon asks of a transport: is the agent alive,
;; is it safe to type, deliver a line, capture the screen, send a key.
;; The daemon never reaches into Emacs; Emacs reaches into the daemon
;; over four localhost endpoints, authenticated by the daemon's lockfile
;; token (~/.bridge/daemon.json):
;;
;;   POST /local/transport/hello   register hosted agents, get a lease
;;   POST /local/transport/attest  heartbeat: ready / prompt / screen tail
;;   GET  /local/transport/mail    long-poll for parked deliveries
;;   POST /local/transport/ack     confirm the lines we typed
;;
;; Every Magnus and vterm function is late-bound (`declare-function' plus
;; `defvar'), so the transport logic runs under `emacs -Q' with stubs.
;; Three seams are injectable:
;; the roster gatherer, the vterm typist, and the single HTTP primitive.
;;
;; Two safety rules are load-bearing and commented at their sites:
;;   * The SELF-GUARD (see `magnus-bridge--dispatch'): never type a
;;     text delivery into an agent that is showing a permission dialog
;;     right now.  This is the client's half of bridge's C2/C4 "never type
;;     into an open dialog" guarantee, vterm edition.
;;   * The GENERATION GUARD (see `magnus-bridge--generation'):
;;     every timer and async callback captures a generation at spawn and
;;     self-discards when it is stale, so a disconnect or a re-hello can
;;     never leave a zombie drain loop or double a live one.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'url)

;; Late-bound Magnus API (default roster gatherer only), so this file
;; compiles and its transport logic runs under `emacs -Q' with stubs.
(declare-function magnus-instances-active-list "magnus-instances")
(declare-function magnus-instance-id "magnus-instances" (instance))
(declare-function magnus-instance-name "magnus-instances" (instance))
(declare-function magnus-instance-directory "magnus-instances" (instance))
(declare-function magnus-instance-session-id "magnus-instances" (instance))
(declare-function magnus-instance-buffer "magnus-instances" (instance))
(declare-function magnus-instance-provider "magnus-instances" (instance))

;; Late-bound vterm API (default typist only).
(declare-function vterm-send-string "vterm" (string &optional paste-p))
(declare-function vterm-send-return "vterm")
(declare-function vterm-send-escape "vterm")

;; Magnus's attention set — the advisory "is a dialog open" signal.  Only
;; ever read through `boundp', so an unbound value simply means "not open".
(defvar magnus-attention-queue)

(defgroup magnus-bridge nil
  "Host Magnus agents as a remote transport client of the bridge daemon."
  :group 'tools
  :prefix "magnus-bridge-")

;;; Customization -----------------------------------------------------------

(defcustom magnus-bridge-daemon-file "~/.bridge/daemon.json"
  "Path to the bridge daemon lockfile holding its port and local token.
The daemon writes this on start; the client reads it on connect."
  :type 'file
  :group 'magnus-bridge)

(defcustom magnus-bridge-flavor "emacs"
  "Environment label this client reports to the daemon on hello.
Surfaced beside each hosted agent as its transport flavor so the phone
can tell where the agent actually lives."
  :type 'string
  :group 'magnus-bridge)

(defcustom magnus-bridge-mail-wait 25
  "Seconds to hold each drain long-poll open before it returns empty.
The daemon clamps this to its own maximum; the attest heartbeat, not the
poll, keeps the lease fresh, so a long wait is safe."
  :type 'integer
  :group 'magnus-bridge)

;;; Injectable seams --------------------------------------------------------

(defvar magnus-bridge-roster-function
  'magnus-bridge--default-roster
  "Function returning the agents this client should host.
Called with no arguments; returns a list of plists, each with keys
:instance-id :name :directory :session-id :provider :buffer.  The default
gathers live Magnus instances.  Tests rebind it.")

(defvar magnus-bridge-type-function
  'magnus-bridge--default-type
  "Function that types one delivery into an agent's buffer.
Called with (BUFFER STRING KIND); KIND is `text', `key' or `escape'.
The default drives vterm.  Tests rebind it.")

(defvar magnus-bridge--request-function
  'magnus-bridge--http-request
  "The ONE function that performs HTTP against the daemon.
Called with (METHOD PATH BODY CALLBACK); BODY is an alist/plist or nil.
CALLBACK is invoked asynchronously with (CODE BODY-ALIST): CODE is the
integer HTTP status, or nil on a connection failure.  Tests rebind this
to drive the client without a network.")

;;; Fixed limits ------------------------------------------------------------

(defconst magnus-bridge--approve-keys '("1" "2" "3" "y" "n" "esc")
  "The only keystrokes a key delivery may carry.
Mirrors the daemon's approve whitelist; enforced client-side as defense
in depth.")

(defconst magnus-bridge--max-agents 8
  "Most agents one hello may register (the daemon's own cap).")

(defconst magnus-bridge--seen-cap 256
  "How many recent delivery ids the dedup ring remembers.")

(defconst magnus-bridge--tail-bytes 4096
  "How many trailing characters to attest before the daemon's byte clamp.")

(defconst magnus-bridge--backoff-min 2
  "Initial re-hello backoff, in seconds.")

(defconst magnus-bridge--backoff-max 30
  "Maximum re-hello backoff, in seconds.")

(defconst magnus-bridge--idle-redrain 2
  "Seconds to wait before re-polling when only un-typable mail is parked.
Keeps a self-guarded or unknown-contact delivery from hot-looping the
long-poll while the daemon's ack timeout redelivers it under a fresh id.")

;;; Mutable state -----------------------------------------------------------

(defvar magnus-bridge--connected nil
  "Non-nil while the client is meant to be hosting agents.")

(defvar magnus-bridge-mode nil
  "Non-nil when Magnus agents are hosted on the bridge daemon.")

(defvar magnus-bridge--port nil
  "Daemon TCP port read from the lockfile.")

(defvar magnus-bridge--token nil
  "Daemon local-trust token read from the lockfile.")

(defvar magnus-bridge--lease nil
  "Current lease token, or nil between hellos.")

(defvar magnus-bridge--ttl 30
  "Lease TTL in seconds most recently reported by the daemon.")

(defvar magnus-bridge--lease-since 0.0
  "`float-time' when the current lease was granted.")

(defvar magnus-bridge--generation 0
  "Monotonic epoch bumped on every connect, disconnect and re-hello.
Every timer and async callback captures this at spawn and self-discards
when it no longer matches — the guard against zombie or doubled loops.")

(defvar magnus-bridge--attest-timer nil
  "Repeating attest heartbeat timer, or nil.")

(defvar magnus-bridge--contacts nil
  "Hosted agents as plists with daemon identity and Magnus signature.
Built by index from the hello response, so a daemon-suffixed name never
mis-maps to the wrong instance.")

(defvar magnus-bridge--seen nil
  "Ring of recently-typed delivery ids, newest first, capped for dedup.")

(defvar magnus-bridge--backoff magnus-bridge--backoff-min
  "Current re-hello backoff in seconds; reset to the minimum on success.")

(defvar magnus-bridge--skip-warned nil
  "Instance ids already warned about as unhostable, to warn only once.")

(defvar magnus-bridge--typed-count 0
  "How many deliveries this client has typed since connect.")

;;; Lockfile ----------------------------------------------------------------

(defun magnus-bridge--read-daemon ()
  "Return (:port N :token S) from the daemon lockfile.
Signal a `user-error' if the file is missing or unparseable."
  (let ((file (expand-file-name magnus-bridge-daemon-file)))
    (or (and (file-readable-p file)
             (ignore-errors
               (let* ((json (with-temp-buffer
                              (insert-file-contents file)
                              (json-parse-buffer :object-type 'alist)))
                      (port (alist-get 'port json))
                      (token (alist-get 'token json)))
                 (and (integerp port)
                      (stringp token) (not (string-empty-p token))
                      (list :port port :token token)))))
        (user-error "Bridge daemon not found; run `bridge install-daemon'"))))

;;; HTTP --------------------------------------------------------------------

(defun magnus-bridge--request (method path body callback)
  "Dispatch METHOD PATH BODY to `magnus-bridge--request-function'.
CALLBACK is invoked with (CODE BODY-ALIST); see that variable."
  (funcall magnus-bridge--request-function method path body callback))

(defun magnus-bridge--parse-http (status)
  "Parse the `url-retrieve' response in the current buffer.
STATUS is url-retrieve's status plist.  Return a cons (CODE . BODY):
CODE is the integer HTTP status or nil on a connection error, and BODY
is the parsed JSON as an alist (arrays as lists) or nil."
  (if (plist-get status :error)
      (cons nil nil)
    (let ((code nil) (body nil))
      (goto-char (point-min))
      (when (looking-at "HTTP/[0-9.]+ +\\([0-9]+\\)")
        (setq code (string-to-number (match-string 1))))
      (when (re-search-forward "\r?\n\r?\n" nil t)
        (let ((raw (buffer-substring-no-properties (point) (point-max))))
          (setq body (ignore-errors
                       (json-parse-string
                        (decode-coding-string raw 'utf-8)
                        :object-type 'alist :array-type 'list)))))
      (cons code body))))

(defun magnus-bridge--unibyte (s)
  "Return S as a UTF-8 unibyte string; url.el needs every request part unibyte.
url-http concats method, path, header values and body into ONE request
string.  A single multibyte part anywhere — and strings that came out of
`json-parse-buffer' (the lockfile token, the lease) are multibyte even
when pure ASCII — flips the whole concat to multibyte, re-poisoning the
already-encoded body: its UTF-8 high bytes become eight-bit chars,
`string-bytes' no longer equals `length', and url-http rejects the
request with \"Multibyte text in HTTP request\".  All-ASCII requests
slip through, which is exactly why this only bites when a screen tail
carries a real dialog — every Claude Code dialog contains ❯ by
definition, so without this coercion the attest heartbeat dies the
moment an agent most needs it."
  (if (multibyte-string-p s) (encode-coding-string s 'utf-8) s))

(defun magnus-bridge--http-request (method path body callback)
  "Perform METHOD to PATH on the daemon with BODY, asynchronously.
BODY is an alist/plist serialized to JSON, or nil.  Invoke CALLBACK with
\(CODE BODY-ALIST).  This is the only function that touches the network;
nothing here ever blocks Emacs, and every string handed to url.el goes
through `magnus-bridge--unibyte' (see its docstring for why)."
  (let* ((url (magnus-bridge--unibyte
               (format "http://127.0.0.1:%d%s" magnus-bridge--port path)))
         (url-request-method method)
         (url-request-extra-headers
          (append (list (cons "Authorization"
                              (magnus-bridge--unibyte
                               (concat "Bearer " magnus-bridge--token))))
                  (and body '(("Content-Type" . "application/json")))))
         (url-request-data
          (and body (magnus-bridge--unibyte
                     (encode-coding-string (json-serialize body) 'utf-8)))))
    (condition-case _err
        (url-retrieve
         url
         (lambda (status)
           (let ((buf (current-buffer))
                 (parsed (magnus-bridge--parse-http status)))
             (unwind-protect
                 (funcall callback (car parsed) (cdr parsed))
               (when (buffer-live-p buf) (kill-buffer buf)))))
         nil t t)
      ;; A malformed URL or an immediately-unroutable host signals here;
      ;; surface it as a connection failure so the caller backs off.
      (error (funcall callback nil nil)))))

;;; Roster ------------------------------------------------------------------

(defun magnus-bridge--default-roster ()
  "Gather live Magnus instances as hostable-agent plists.
Each plist carries identity, provider, session, directory, and buffer."
  (when (fboundp 'magnus-instances-active-list)
    (mapcar
     (lambda (inst)
       (list :instance-id (magnus-instance-id inst)
             :name (magnus-instance-name inst)
             :directory (magnus-instance-directory inst)
             :session-id (and (fboundp 'magnus-instance-session-id)
                              (magnus-instance-session-id inst))
             :provider (if (fboundp 'magnus-instance-provider)
                           (or (magnus-instance-provider inst) 'claude)
                         'claude)
             :buffer (magnus-instance-buffer inst)))
     (magnus-instances-active-list))))

(defun magnus-bridge--hostable-p (agent)
  "Return non-nil when AGENT is safe to host over terminal protocol v1."
  (let ((sid (plist-get agent :session-id))
        (dir (plist-get agent :directory))
        (provider (or (plist-get agent :provider) 'claude)))
    (and (eq provider 'claude)
         (stringp sid) (not (string-empty-p sid))
         (stringp dir) (not (string-empty-p dir)))))

(defun magnus-bridge--unhostable-reason (agent)
  "Return a concise reason AGENT cannot use terminal protocol v1."
  (let ((provider (or (plist-get agent :provider) 'claude)))
    (cond
     ((not (eq provider 'claude))
      (format "provider `%s' needs a semantic transport" provider))
     ((not (and (stringp (plist-get agent :session-id))
                (not (string-empty-p (plist-get agent :session-id)))))
      "no session ID")
     (t "no directory"))))

(defun magnus-bridge--hostable-roster ()
  "Return the filtered roster, capped at `magnus-bridge--max-agents'.
No user-visible messaging happens here; it is called every attest tick."
  (let ((ok (cl-remove-if-not #'magnus-bridge--hostable-p
                              (funcall magnus-bridge-roster-function))))
    (if (> (length ok) magnus-bridge--max-agents)
        (cl-subseq ok 0 magnus-bridge--max-agents)
      ok)))

(defun magnus-bridge--agent-signature (agent)
  "Return the lifecycle fields that identify AGENT's current host."
  (list (plist-get agent :instance-id)
        (plist-get agent :provider)
        (plist-get agent :name)
        (plist-get agent :directory)
        (plist-get agent :session-id)
        (plist-get agent :buffer)))

(defun magnus-bridge--live-signatures ()
  "Return sorted lifecycle signatures for the current hostable roster."
  (sort (mapcar #'magnus-bridge--agent-signature
                (magnus-bridge--hostable-roster))
        (lambda (first second) (string< (car first) (car second)))))

(defun magnus-bridge--hosted-signatures ()
  "Return sorted lifecycle signatures this client currently hosts."
  (sort (mapcar (lambda (a) (plist-get a :signature))
                magnus-bridge--contacts)
        (lambda (first second) (string< (car first) (car second)))))

;;; Generation / teardown ---------------------------------------------------

(defun magnus-bridge--invalidate ()
  "Bump the generation and tear down live loops.
Any in-flight timer or async callback captured the old generation and so
becomes a no-op; the attest timer is cancelled and the lease dropped."
  (cl-incf magnus-bridge--generation)
  (when magnus-bridge--attest-timer
    (cancel-timer magnus-bridge--attest-timer)
    (setq magnus-bridge--attest-timer nil))
  (setq magnus-bridge--lease nil))

(defun magnus-bridge--schedule-retry (gen)
  "Schedule a re-hello after the current backoff, then grow the backoff.
Guarded by GEN: if the client disconnects or re-hellos meanwhile, the
retry self-discards."
  (let ((delay magnus-bridge--backoff))
    (setq magnus-bridge--backoff
          (min magnus-bridge--backoff-max
               (* 2 magnus-bridge--backoff)))
    (run-with-timer
     delay nil
     (lambda ()
       (when (and magnus-bridge--connected
                  (= gen magnus-bridge--generation))
         (magnus-bridge--hello))))))

(defun magnus-bridge--fail-rehello ()
  "React to a dead lease or a connection error: drop and re-hello with backoff.
Bumps the generation immediately so every in-flight loop stops, then
schedules the re-hello."
  (let ((delay magnus-bridge--backoff))
    (magnus-bridge--invalidate)
    (setq magnus-bridge--backoff
          (min magnus-bridge--backoff-max
               (* 2 magnus-bridge--backoff)))
    (let ((gen magnus-bridge--generation))
      (run-with-timer
       delay nil
       (lambda ()
         (when (and magnus-bridge--connected
                    (= gen magnus-bridge--generation))
           (magnus-bridge--hello)))))))

;;; Hello -------------------------------------------------------------------

(defun magnus-bridge--hello ()
  "Register the current hostable roster and request a lease.
Warns once per unhostable instance, caps the roster, and on an empty
roster simply retries on the backoff clock so agents can appear later."
  (magnus-bridge--invalidate)
  ;; Re-read the lockfile on every attempt: the daemon mints a fresh token
  ;; (and may move ports) each boot, so a re-hello after a daemon restart
  ;; must not keep knocking with yesterday's key.  Tolerant on purpose — an
  ;; unreadable file keeps the current values and the backoff clock knocks
  ;; again; `user-error' only belongs to the interactive connect.
  (let ((daemon (ignore-errors (magnus-bridge--read-daemon))))
    (when daemon
      (setq magnus-bridge--port (plist-get daemon :port)
            magnus-bridge--token (plist-get daemon :token))))
  (let* ((gen magnus-bridge--generation)
         (all (funcall magnus-bridge-roster-function))
         (ok (cl-remove-if-not #'magnus-bridge--hostable-p all)))
    (dolist (a all)
      (unless (magnus-bridge--hostable-p a)
        (let ((id (plist-get a :instance-id)))
          (unless (member id magnus-bridge--skip-warned)
            (push id magnus-bridge--skip-warned)
            (message "magnus-bridge: skipping %s (%s)"
                     (or (plist-get a :name) id)
                     (magnus-bridge--unhostable-reason a))))))
    (when (> (length ok) magnus-bridge--max-agents)
      (message "magnus-bridge: %d agents hostable, hosting the first %d"
               (length ok) magnus-bridge--max-agents)
      (setq ok (cl-subseq ok 0 magnus-bridge--max-agents)))
    (if (null ok)
        (progn
          (message "magnus-bridge: no hostable Magnus agents yet")
          (magnus-bridge--schedule-retry gen))
      (let ((agents (vconcat
                     (mapcar (lambda (a)
                               (list :name (plist-get a :name)
                                     :directory (plist-get a :directory)
                                     :session_id (plist-get a :session-id)))
                             ok))))
        (magnus-bridge--request
         "POST" "/local/transport/hello"
         (list :transport magnus-bridge-flavor :agents agents)
         (lambda (code body)
           (magnus-bridge--on-hello gen ok code body)))))))

(defun magnus-bridge--on-hello (gen ok code body)
  "Handle the hello response for GEN.
OK is the roster list posted, in request order; CODE and BODY are the
result.  Maps the returned agents BY INDEX onto OK, so a suffixed name
never binds to the wrong instance."
  (when (= gen magnus-bridge--generation)
    (let ((lease (and (alist-get 'lease body) (alist-get 'lease body))))
      (if (and (eql code 200) lease)
          (progn
            (setq magnus-bridge--contacts
                  (cl-loop for agent in ok
                           for resp in (alist-get 'agents body)
                           collect (list :id (alist-get 'id resp)
                                         :name (alist-get 'name resp)
                                         :instance-id
                                         (plist-get agent :instance-id)
                                         :buffer (plist-get agent :buffer)
                                         :signature
                                         (magnus-bridge--agent-signature
                                          agent)))
                  magnus-bridge--lease lease
                  magnus-bridge--ttl (or (alist-get 'ttl_s body) 30)
                  magnus-bridge--lease-since (float-time)
                  magnus-bridge--backoff magnus-bridge--backoff-min)
            (magnus-bridge--start-attest gen)
            (magnus-bridge--drain gen)
            (message "magnus-bridge: connected, hosting %d agent%s (ttl %ds)"
                     (length magnus-bridge--contacts)
                     (if (= 1 (length magnus-bridge--contacts)) "" "s")
                     magnus-bridge--ttl))
        (if (eql code 404)
            (progn
              (magnus-bridge--invalidate)
              (setq magnus-bridge--connected nil
                    magnus-bridge-mode nil)
              (message "magnus-bridge: update bridge for remote transport"))
          (magnus-bridge--schedule-retry gen))))))

;;; Attest ------------------------------------------------------------------

(defun magnus-bridge--start-attest (gen)
  "Start the repeating attest heartbeat for GEN."
  (let ((interval (max 2 (min 10 (/ magnus-bridge--ttl 3)))))
    (setq magnus-bridge--attest-timer
          (run-with-timer
           interval interval
           (lambda () (magnus-bridge--attest-tick gen))))))

(defun magnus-bridge--flagged-p (instance-id)
  "Return non-nil if INSTANCE-ID is in Magnus's attention queue right now."
  (and (boundp 'magnus-attention-queue)
       (member instance-id magnus-attention-queue)
       t))

(defun magnus-bridge--screen-tail (buffer)
  "Return the trailing screen text of BUFFER, or \"\" if it is dead."
  (if (buffer-live-p buffer)
      (with-current-buffer buffer
        (buffer-substring-no-properties
         (max (point-min) (- (point-max) magnus-bridge--tail-bytes))
         (point-max)))
    ""))

(defun magnus-bridge--attest-tick (gen)
  "One heartbeat for GEN: re-hello on roster change, else attest state."
  (when (and magnus-bridge--connected
             (= gen magnus-bridge--generation))
    (if (not (equal (magnus-bridge--live-signatures)
                    (magnus-bridge--hosted-signatures)))
        ;; The live set diverged from what we hold a lease for.  Re-hello:
        ;; the new lease covers the new set, and agents dropped from it go
        ;; offline daemon-side as the old lease dies — the designed
        ;; lifecycle, since the protocol has no goodbye verb.
        (magnus-bridge--hello)
      (magnus-bridge--post-attest gen))))

(defun magnus-bridge--post-attest (gen)
  "Attest each hosted agent's ready/prompt/screen state for GEN."
  (when magnus-bridge--lease
    (let ((states
           (vconcat
            (mapcar
             (lambda (agent)
               (let* ((buffer (plist-get agent :buffer))
                      (iid (plist-get agent :instance-id))
                      (flagged (magnus-bridge--flagged-p iid))
                      ;; Ready = a live vterm we are NOT holding for input.
                      ;; prompt_open is advisory: the daemon judges the tail
                      ;; itself with its own detector, so we never try to
                      ;; recognise a dialog in elisp — we just hand it the
                      ;; screen and our attention flag.
                      (ready (and (buffer-live-p buffer)
                                  (process-live-p (get-buffer-process buffer))
                                  (not flagged))))
                 (list :id (plist-get agent :id)
                       :ready (if ready t :false)
                       :prompt_open (if flagged t :false)
                       :screen_tail (magnus-bridge--screen-tail buffer))))
             magnus-bridge--contacts))))
      (magnus-bridge--request
       "POST" "/local/transport/attest"
       (list :lease magnus-bridge--lease :states states)
       (lambda (code body)
         (magnus-bridge--on-attest gen code body))))))

(defun magnus-bridge--on-attest (gen code body)
  "Handle the attest response CODE with BODY for GEN.
A 410 or a connection error re-hellos with backoff; a 200 resets the
backoff and refreshes the TTL from BODY."
  (when (= gen magnus-bridge--generation)
    (if (eql code 200)
        (progn
          (setq magnus-bridge--backoff magnus-bridge--backoff-min)
          (let ((ttl (alist-get 'ttl_s body)))
            (when ttl (setq magnus-bridge--ttl ttl))))
      ;; ANY non-200 — 410, a connection error, or a 401 from a daemon that
      ;; restarted and minted a fresh lockfile token — means this lease (or
      ;; this token) is not working.  Re-hello with backoff: it re-reads the
      ;; lockfile, so a daemon restart heals without the user touching Emacs.
      ;; Leaving 401 a no-op here would strand the client attesting a dead
      ;; lease with yesterday's key forever.
      (magnus-bridge--fail-rehello))))

;;; Drain + ack -------------------------------------------------------------

(defun magnus-bridge--drain (gen)
  "Long-poll the daemon mailbox for GEN and process each response.
Self-perpetuating: each response re-arms the next poll unless the
generation has moved on."
  (when (and magnus-bridge--connected
             (= gen magnus-bridge--generation)
             magnus-bridge--lease)
    (magnus-bridge--request
     "GET"
     (format "/local/transport/mail?lease=%s&wait=%d"
             magnus-bridge--lease magnus-bridge-mail-wait)
     nil
     (lambda (code body)
       (magnus-bridge--on-mail gen code body)))))

(defun magnus-bridge--on-mail (gen code body)
  "Handle mail response CODE with BODY for GEN: type, ack, re-poll.
BODY carries the parked deliveries; only new ones are typed and acked."
  (when (= gen magnus-bridge--generation)
    (if (eql code 200)
        (progn
          (setq magnus-bridge--backoff magnus-bridge--backoff-min)
          (let* ((deliveries (alist-get 'deliveries body))
                 (typed (magnus-bridge--process-deliveries deliveries)))
            (when typed (magnus-bridge--ack typed gen))
            (if (and deliveries (null typed))
                ;; Only un-typable mail is parked (self-guarded, or for a
                ;; dead/unknown buffer).  Don't hot-loop the long-poll; let the
                ;; daemon's ack timeout redeliver under a fresh id.
                (run-with-timer
                 magnus-bridge--idle-redrain nil
                 (lambda () (magnus-bridge--drain gen)))
              (magnus-bridge--drain gen))))
      ;; ANY non-200: 410 and connection errors mean the lease is dead, and a
      ;; 401 means a restarted daemon no longer honors our token.  All of them
      ;; re-hello with backoff; an immediate re-poll would otherwise hot-loop
      ;; the long-poll at localhost speed against a daemon that answers
      ;; instantly with the same refusal.
      (magnus-bridge--fail-rehello))))

(defun magnus-bridge--contact-agent (contact-id)
  "Return the hosted-agent plist for daemon CONTACT-ID, or nil."
  (cl-find contact-id magnus-bridge--contacts
           :key (lambda (a) (plist-get a :id)) :test #'equal))

(defun magnus-bridge--process-deliveries (deliveries)
  "Type each new delivery in DELIVERIES; return the ids actually typed.
Dedups by id against the seen ring (a fresh id after a daemon-side
timeout is a genuine redelivery and is typed again).  Only ids we truly
typed are returned, so `--ack' confirms exactly those."
  (let ((to-ack nil))
    (dolist (d deliveries)
      (let ((id (alist-get 'id d)))
        (when (and id (not (magnus-bridge--seen-p id)))
          (let ((agent (magnus-bridge--contact-agent
                        (alist-get 'contact d))))
            (when (and agent
                       (magnus-bridge--dispatch
                        agent (alist-get 'text d) (alist-get 'key d)))
              (magnus-bridge--mark-seen id)
              (cl-incf magnus-bridge--typed-count)
              (push id to-ack))))))
    (nreverse to-ack)))

(defun magnus-bridge--dispatch (agent text key)
  "Type one delivery for AGENT.  Return non-nil only if something was typed.
A KEY delivery is checked against the approve whitelist (defense in depth
— the daemon already refuses others).  A TEXT delivery is SELF-GUARDED:
if the agent is attention-flagged right now, do NOT type and do NOT ack.
That is the client's half of bridge's never-type-into-an-open-dialog
guarantee (the C2/C4 critical, vterm edition): the parked line times out
daemon-side, the durable mailbox retries later, and our next attest hands
the daemon the dialog tail so it raises a phone card instead of typing."
  (let ((buffer (plist-get agent :buffer))
        (iid (plist-get agent :instance-id)))
    (cond
     ((not (buffer-live-p buffer)) nil)
     ((and (stringp key) (not (string-empty-p key)))
      (cond
       ((not (member key magnus-bridge--approve-keys))
        (message "magnus-bridge: refusing non-whitelisted key %S" key)
        nil)
       ((string= key "esc")
        (magnus-bridge--type buffer "" 'escape) t)
       (t (magnus-bridge--type buffer key 'key) t)))
     ((and (stringp text) (not (string-empty-p text)))
      (if (magnus-bridge--flagged-p iid)
          nil
        (magnus-bridge--type buffer text 'text) t))
     (t nil))))

(defun magnus-bridge--type (buffer string kind)
  "Type STRING into BUFFER as KIND via `magnus-bridge-type-function'."
  (funcall magnus-bridge-type-function buffer string kind))

(defun magnus-bridge--default-type (buffer string kind)
  "Type STRING into BUFFER's vterm per KIND (`text', `key' or `escape').
Escape sends a terminal escape; anything else sends STRING then return."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (if (eq kind 'escape)
          (vterm-send-escape)
        (vterm-send-string string)
        (vterm-send-return)))))

(defun magnus-bridge--ack (ids gen)
  "Acknowledge delivery IDS for GEN (fire-and-forget; ack is idempotent)."
  (when (and (= gen magnus-bridge--generation)
             magnus-bridge--lease ids)
    (magnus-bridge--request
     "POST" "/local/transport/ack"
     (list :lease magnus-bridge--lease :ids (vconcat ids))
     (lambda (_code _body) nil))))

;;; Seen ring ---------------------------------------------------------------

(defun magnus-bridge--seen-p (id)
  "Return non-nil if delivery ID has already been typed."
  (and (member id magnus-bridge--seen) t))

(defun magnus-bridge--mark-seen (id)
  "Record delivery ID as typed, evicting the oldest past the ring cap."
  (push id magnus-bridge--seen)
  (when (> (length magnus-bridge--seen)
           magnus-bridge--seen-cap)
    (setcdr (nthcdr (1- magnus-bridge--seen-cap)
                    magnus-bridge--seen)
            nil)))

;;; Entry points ------------------------------------------------------------

(defun magnus-bridge--connect ()
  "Connect Emacs to the bridge daemon and host live Magnus agents.
Reads the daemon lockfile, registers the roster, and starts the attest
heartbeat and delivery drain loop."
  (when magnus-bridge--connected
    (user-error "Magnus bridge is already connected"))
  (let ((daemon (magnus-bridge--read-daemon)))
    (setq magnus-bridge--port (plist-get daemon :port)
          magnus-bridge--token (plist-get daemon :token)
          magnus-bridge--connected t
          magnus-bridge--contacts nil
          magnus-bridge--seen nil
          magnus-bridge--skip-warned nil
          magnus-bridge--typed-count 0
          magnus-bridge--backoff magnus-bridge--backoff-min)
    (magnus-bridge--hello)
    (message "magnus-bridge: connecting to 127.0.0.1:%d…"
             magnus-bridge--port)))

(defun magnus-bridge--disconnect ()
  "Disconnect from the bridge daemon.
Hosted agents go offline daemon-side as their lease expires — there is
no goodbye verb; a dropped client is byte-for-byte an offline contact."
  (when magnus-bridge--connected
    (magnus-bridge--invalidate)
    (setq magnus-bridge--connected nil
          magnus-bridge--contacts nil)
    (message "magnus-bridge: disconnected (agents expire with the lease)")))

;;;###autoload
(define-minor-mode magnus-bridge-mode
  "Globally host live Magnus Claude agents on the bridge daemon.

The bridge daemon must already be running.  Enable with
`bridge install-daemon' or `bridge serve'; pairing, exposure, and
lockdown remain responsibilities of the `bridge' command-line tool."
  :global t
  :group 'magnus-bridge
  (if magnus-bridge-mode
      (condition-case err
          (magnus-bridge--connect)
        (error
         (setq magnus-bridge-mode nil)
         (signal (car err) (cdr err))))
    (magnus-bridge--disconnect)))

;;;###autoload
(defun magnus-bridge-status ()
  "Report the client's connection, lease age, hosted agents and deliveries."
  (interactive)
  (if (not magnus-bridge--connected)
      (message "magnus-bridge: disconnected")
    (message (concat "magnus-bridge: connected · lease %s · hosting %d "
                     "agent%s · %d deliveries typed")
             (if magnus-bridge--lease
                 (format "%ds old"
                         (round (- (float-time)
                                   magnus-bridge--lease-since)))
               "pending")
             (length magnus-bridge--contacts)
             (if (= 1 (length magnus-bridge--contacts)) "" "s")
             magnus-bridge--typed-count)))

(provide 'magnus-bridge)

;;; magnus-bridge.el ends here
