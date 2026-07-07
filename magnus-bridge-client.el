;;; magnus-bridge-client.el --- Thin-client transport for the bridge daemon -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Hrishikesh S
;; Author: Hrishikesh S
;; Assisted-by: Claude Code:claude-opus-4-8
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; magnus-bridge can run in two shapes.  The legacy shape (the rest of
;; this package) is a self-contained HTTP server plus PWA living inside
;; Emacs.  This file adds the OTHER shape: a THIN CLIENT of the separate
;; "bridge" daemon (a Go switchboard).  One daemon, one phone app, N
;; environments — Emacs becomes just one more place agents can live.
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
;; The design mirrors magnus-bridge-agents.el: every Magnus and vterm
;; function is late-bound (`declare-function' + `defvar'), so this file
;; loads and its logic runs under `emacs -Q' with stubs — no Magnus, no
;; vterm required to exercise or test it.  Three seams are injectable:
;; the roster gatherer, the vterm typist, and the single HTTP primitive.
;;
;; Two safety rules are load-bearing and commented at their sites:
;;   * The SELF-GUARD (see `magnus-bridge-client--dispatch'): never type a
;;     text delivery into an agent that is showing a permission dialog
;;     right now.  This is the client's half of bridge's C2/C4 "never type
;;     into an open dialog" guarantee, vterm edition.
;;   * The GENERATION GUARD (see `magnus-bridge-client--generation'):
;;     every timer and async callback captures a generation at spawn and
;;     self-discards when it is stale, so a disconnect or a re-hello can
;;     never leave a zombie drain loop or double a live one.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'url)

;; Late-bound Magnus API (default roster gatherer only) — exactly the
;; magnus-bridge-agents.el convention, so this file compiles and runs -Q.
(declare-function magnus-instances-active-list "magnus-instances")
(declare-function magnus-instance-id "magnus-instances" (instance))
(declare-function magnus-instance-name "magnus-instances" (instance))
(declare-function magnus-instance-directory "magnus-instances" (instance))
(declare-function magnus-instance-session-id "magnus-instances" (instance))
(declare-function magnus-instance-buffer "magnus-instances" (instance))

;; Late-bound vterm API (default typist only).
(declare-function vterm-send-string "vterm" (string &optional paste-p))
(declare-function vterm-send-return "vterm")
(declare-function vterm-send-escape "vterm")

;; Magnus's attention set — the advisory "is a dialog open" signal.  Only
;; ever read through `boundp', so an unbound value simply means "not open".
(defvar magnus-attention-queue)

(defgroup magnus-bridge-client nil
  "Host Magnus agents as a remote transport client of the bridge daemon."
  :group 'magnus-bridge
  :prefix "magnus-bridge-client-")

;;; Customization -----------------------------------------------------------

(defcustom magnus-bridge-client-daemon-file "~/.bridge/daemon.json"
  "Path to the bridge daemon lockfile holding its port and local token.
The daemon writes this on start; the client reads it on connect."
  :type 'file
  :group 'magnus-bridge-client)

(defcustom magnus-bridge-client-flavor "emacs"
  "Environment label this client reports to the daemon on hello.
Surfaced beside each hosted agent as its transport flavor so the phone
can tell where the agent actually lives."
  :type 'string
  :group 'magnus-bridge-client)

(defcustom magnus-bridge-client-mail-wait 25
  "Seconds to hold each drain long-poll open before it returns empty.
The daemon clamps this to its own maximum; the attest heartbeat, not the
poll, keeps the lease fresh, so a long wait is safe."
  :type 'integer
  :group 'magnus-bridge-client)

;;; Injectable seams --------------------------------------------------------

(defvar magnus-bridge-client-roster-function
  'magnus-bridge-client--default-roster
  "Function returning the agents this client should host.
Called with no arguments; returns a list of plists, each with keys
:instance-id :name :directory :session-id :buffer.  The default gathers
live Magnus instances.  Tests rebind it.")

(defvar magnus-bridge-client-type-function
  'magnus-bridge-client--default-type
  "Function that types one delivery into an agent's buffer.
Called with (BUFFER STRING KIND); KIND is `text', `key' or `escape'.
The default drives vterm.  Tests rebind it.")

(defvar magnus-bridge-client--request-function
  'magnus-bridge-client--http-request
  "The ONE function that performs HTTP against the daemon.
Called with (METHOD PATH BODY CALLBACK); BODY is an alist/plist or nil.
CALLBACK is invoked asynchronously with (CODE BODY-ALIST): CODE is the
integer HTTP status, or nil on a connection failure.  Tests rebind this
to drive the client without a network.")

;;; Fixed limits ------------------------------------------------------------

(defconst magnus-bridge-client--approve-keys '("1" "2" "3" "y" "n" "esc")
  "The only keystrokes a key delivery may carry.
Mirrors `magnus-bridge--approve-keys' and the daemon's own approve
whitelist; enforced client-side as defense in depth.")

(defconst magnus-bridge-client--max-agents 8
  "Most agents one hello may register (the daemon's own cap).")

(defconst magnus-bridge-client--seen-cap 256
  "How many recent delivery ids the dedup ring remembers.")

(defconst magnus-bridge-client--tail-bytes 4096
  "How many trailing characters of an agent buffer to attest as screen tail.")

(defconst magnus-bridge-client--backoff-min 2
  "Initial re-hello backoff, in seconds.")

(defconst magnus-bridge-client--backoff-max 30
  "Maximum re-hello backoff, in seconds.")

(defconst magnus-bridge-client--idle-redrain 2
  "Seconds to wait before re-polling when only un-typable mail is parked.
Keeps a self-guarded or unknown-contact delivery from hot-looping the
long-poll while the daemon's ack timeout redelivers it under a fresh id.")

;;; Mutable state -----------------------------------------------------------

(defvar magnus-bridge-client--connected nil
  "Non-nil while the client is meant to be hosting agents.")

(defvar magnus-bridge-client--port nil
  "Daemon TCP port read from the lockfile.")

(defvar magnus-bridge-client--token nil
  "Daemon local-trust token read from the lockfile.")

(defvar magnus-bridge-client--lease nil
  "Current lease token, or nil between hellos.")

(defvar magnus-bridge-client--ttl 30
  "Lease TTL in seconds most recently reported by the daemon.")

(defvar magnus-bridge-client--lease-since 0.0
  "`float-time' when the current lease was granted.")

(defvar magnus-bridge-client--generation 0
  "Monotonic epoch bumped on every connect, disconnect and re-hello.
Every timer and async callback captures this at spawn and self-discards
when it no longer matches — the guard against zombie or doubled loops.")

(defvar magnus-bridge-client--attest-timer nil
  "Repeating attest heartbeat timer, or nil.")

(defvar magnus-bridge-client--contacts nil
  "Hosted agents as plists with keys :id :name :instance-id :buffer.
Built by index from the hello response, so a daemon-suffixed name never
mis-maps to the wrong instance.")

(defvar magnus-bridge-client--seen nil
  "Ring of recently-typed delivery ids, newest first, capped for dedup.")

(defvar magnus-bridge-client--backoff magnus-bridge-client--backoff-min
  "Current re-hello backoff in seconds; reset to the minimum on success.")

(defvar magnus-bridge-client--skip-warned nil
  "Instance ids already warned about as unhostable, to warn only once.")

(defvar magnus-bridge-client--typed-count 0
  "How many deliveries this client has typed since connect.")

;;; Lockfile ----------------------------------------------------------------

(defun magnus-bridge-client--read-daemon ()
  "Return (:port N :token S) from the daemon lockfile.
Signal a `user-error' if the file is missing or unparseable."
  (let ((file (expand-file-name magnus-bridge-client-daemon-file)))
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
        (user-error
         "Bridge daemon not found — is it running? (bridge install-daemon)"))))

;;; HTTP --------------------------------------------------------------------

(defun magnus-bridge-client--request (method path body callback)
  "Dispatch METHOD PATH BODY to `magnus-bridge-client--request-function'.
CALLBACK is invoked with (CODE BODY-ALIST); see that variable."
  (funcall magnus-bridge-client--request-function method path body callback))

(defun magnus-bridge-client--parse-http (status)
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

(defun magnus-bridge-client--unibyte (s)
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

(defun magnus-bridge-client--http-request (method path body callback)
  "Perform METHOD to PATH on the daemon with BODY, asynchronously.
BODY is an alist/plist serialized to JSON, or nil.  Invoke CALLBACK with
\(CODE BODY-ALIST).  This is the only function that touches the network;
nothing here ever blocks Emacs, and every string handed to url.el goes
through `magnus-bridge-client--unibyte' (see its docstring for why)."
  (let* ((url (magnus-bridge-client--unibyte
               (format "http://127.0.0.1:%d%s" magnus-bridge-client--port path)))
         (url-request-method method)
         (url-request-extra-headers
          (append (list (cons "Authorization"
                              (magnus-bridge-client--unibyte
                               (concat "Bearer " magnus-bridge-client--token))))
                  (and body '(("Content-Type" . "application/json")))))
         (url-request-data
          (and body (magnus-bridge-client--unibyte
                     (encode-coding-string (json-serialize body) 'utf-8)))))
    (condition-case _err
        (url-retrieve
         url
         (lambda (status)
           (let ((buf (current-buffer))
                 (parsed (magnus-bridge-client--parse-http status)))
             (unwind-protect
                 (funcall callback (car parsed) (cdr parsed))
               (when (buffer-live-p buf) (kill-buffer buf)))))
         nil t t)
      ;; A malformed URL or an immediately-unroutable host signals here;
      ;; surface it as a connection failure so the caller backs off.
      (error (funcall callback nil nil)))))

;;; Roster ------------------------------------------------------------------

(defun magnus-bridge-client--default-roster ()
  "Gather live Magnus instances as hostable-agent plists.
Each plist carries :instance-id :name :directory :session-id :buffer."
  (when (fboundp 'magnus-instances-active-list)
    (mapcar
     (lambda (inst)
       (list :instance-id (magnus-instance-id inst)
             :name (magnus-instance-name inst)
             :directory (magnus-instance-directory inst)
             :session-id (and (fboundp 'magnus-instance-session-id)
                              (magnus-instance-session-id inst))
             :buffer (magnus-instance-buffer inst)))
     (magnus-instances-active-list))))

(defun magnus-bridge-client--hostable-p (agent)
  "Return non-nil if AGENT has the session id and directory the daemon tails."
  (let ((sid (plist-get agent :session-id))
        (dir (plist-get agent :directory)))
    (and (stringp sid) (not (string-empty-p sid))
         (stringp dir) (not (string-empty-p dir)))))

(defun magnus-bridge-client--hostable-roster ()
  "Return the filtered roster, capped at `magnus-bridge-client--max-agents'.
No user-visible messaging happens here; it is called every attest tick."
  (let ((ok (cl-remove-if-not #'magnus-bridge-client--hostable-p
                              (funcall magnus-bridge-client-roster-function))))
    (if (> (length ok) magnus-bridge-client--max-agents)
        (cl-subseq ok 0 magnus-bridge-client--max-agents)
      ok)))

(defun magnus-bridge-client--live-id-set ()
  "Return the sorted instance ids of the current hostable roster."
  (sort (mapcar (lambda (a) (plist-get a :instance-id))
                (magnus-bridge-client--hostable-roster))
        #'string<))

(defun magnus-bridge-client--hosted-id-set ()
  "Return the sorted instance ids this client currently hosts."
  (sort (mapcar (lambda (a) (plist-get a :instance-id))
                magnus-bridge-client--contacts)
        #'string<))

;;; Generation / teardown ---------------------------------------------------

(defun magnus-bridge-client--invalidate ()
  "Bump the generation and tear down live loops.
Any in-flight timer or async callback captured the old generation and so
becomes a no-op; the attest timer is cancelled and the lease dropped."
  (cl-incf magnus-bridge-client--generation)
  (when magnus-bridge-client--attest-timer
    (cancel-timer magnus-bridge-client--attest-timer)
    (setq magnus-bridge-client--attest-timer nil))
  (setq magnus-bridge-client--lease nil))

(defun magnus-bridge-client--schedule-retry (gen)
  "Schedule a re-hello after the current backoff, then grow the backoff.
Guarded by GEN: if the client disconnects or re-hellos meanwhile, the
retry self-discards."
  (let ((delay magnus-bridge-client--backoff))
    (setq magnus-bridge-client--backoff
          (min magnus-bridge-client--backoff-max
               (* 2 magnus-bridge-client--backoff)))
    (run-with-timer
     delay nil
     (lambda ()
       (when (and magnus-bridge-client--connected
                  (= gen magnus-bridge-client--generation))
         (magnus-bridge-client--hello))))))

(defun magnus-bridge-client--fail-rehello ()
  "React to a dead lease or a connection error: drop and re-hello with backoff.
Bumps the generation immediately so every in-flight loop stops, then
schedules the re-hello."
  (let ((delay magnus-bridge-client--backoff))
    (magnus-bridge-client--invalidate)
    (setq magnus-bridge-client--backoff
          (min magnus-bridge-client--backoff-max
               (* 2 magnus-bridge-client--backoff)))
    (let ((gen magnus-bridge-client--generation))
      (run-with-timer
       delay nil
       (lambda ()
         (when (and magnus-bridge-client--connected
                    (= gen magnus-bridge-client--generation))
           (magnus-bridge-client--hello)))))))

;;; Hello -------------------------------------------------------------------

(defun magnus-bridge-client--hello ()
  "Register the current hostable roster and request a lease.
Warns once per unhostable instance, caps the roster, and on an empty
roster simply retries on the backoff clock so agents can appear later."
  (magnus-bridge-client--invalidate)
  ;; Re-read the lockfile on every attempt: the daemon mints a fresh token
  ;; (and may move ports) each boot, so a re-hello after a daemon restart
  ;; must not keep knocking with yesterday's key.  Tolerant on purpose — an
  ;; unreadable file keeps the current values and the backoff clock knocks
  ;; again; `user-error' only belongs to the interactive connect.
  (let ((daemon (ignore-errors (magnus-bridge-client--read-daemon))))
    (when daemon
      (setq magnus-bridge-client--port (plist-get daemon :port)
            magnus-bridge-client--token (plist-get daemon :token))))
  (let* ((gen magnus-bridge-client--generation)
         (all (funcall magnus-bridge-client-roster-function))
         (ok (cl-remove-if-not #'magnus-bridge-client--hostable-p all)))
    (dolist (a all)
      (unless (magnus-bridge-client--hostable-p a)
        (let ((id (plist-get a :instance-id)))
          (unless (member id magnus-bridge-client--skip-warned)
            (push id magnus-bridge-client--skip-warned)
            (message "magnus-bridge-client: skipping %s (no session-id/directory to tail)"
                     (or (plist-get a :name) id))))))
    (when (> (length ok) magnus-bridge-client--max-agents)
      (message "magnus-bridge-client: %d agents hostable, hosting the first %d"
               (length ok) magnus-bridge-client--max-agents)
      (setq ok (cl-subseq ok 0 magnus-bridge-client--max-agents)))
    (if (null ok)
        (progn
          (message "magnus-bridge-client: no hostable Magnus agents yet")
          (magnus-bridge-client--schedule-retry gen))
      (let ((agents (vconcat
                     (mapcar (lambda (a)
                               (list :name (plist-get a :name)
                                     :directory (plist-get a :directory)
                                     :session_id (plist-get a :session-id)))
                             ok))))
        (magnus-bridge-client--request
         "POST" "/local/transport/hello"
         (list :transport magnus-bridge-client-flavor :agents agents)
         (lambda (code body)
           (magnus-bridge-client--on-hello gen ok code body)))))))

(defun magnus-bridge-client--on-hello (gen ok code body)
  "Handle the hello response for GEN.
OK is the roster list posted, in request order; CODE and BODY are the
result.  Maps the returned agents BY INDEX onto OK, so a suffixed name
never binds to the wrong instance."
  (when (= gen magnus-bridge-client--generation)
    (let ((lease (and (alist-get 'lease body) (alist-get 'lease body))))
      (if (and (eql code 200) lease)
          (progn
            (setq magnus-bridge-client--contacts
                  (cl-loop for agent in ok
                           for resp in (alist-get 'agents body)
                           collect (list :id (alist-get 'id resp)
                                         :name (alist-get 'name resp)
                                         :instance-id (plist-get agent :instance-id)
                                         :buffer (plist-get agent :buffer)))
                  magnus-bridge-client--lease lease
                  magnus-bridge-client--ttl (or (alist-get 'ttl_s body) 30)
                  magnus-bridge-client--lease-since (float-time)
                  magnus-bridge-client--backoff magnus-bridge-client--backoff-min)
            (magnus-bridge-client--start-attest gen)
            (magnus-bridge-client--drain gen)
            (message "magnus-bridge-client: connected, hosting %d agent%s (ttl %ds)"
                     (length magnus-bridge-client--contacts)
                     (if (= 1 (length magnus-bridge-client--contacts)) "" "s")
                     magnus-bridge-client--ttl))
        (magnus-bridge-client--schedule-retry gen)))))

;;; Attest ------------------------------------------------------------------

(defun magnus-bridge-client--start-attest (gen)
  "Start the repeating attest heartbeat for GEN."
  (let ((interval (max 2 (min 10 (/ magnus-bridge-client--ttl 3)))))
    (setq magnus-bridge-client--attest-timer
          (run-with-timer
           interval interval
           (lambda () (magnus-bridge-client--attest-tick gen))))))

(defun magnus-bridge-client--flagged-p (instance-id)
  "Return non-nil if INSTANCE-ID is in Magnus's attention queue right now."
  (and (boundp 'magnus-attention-queue)
       (member instance-id magnus-attention-queue)
       t))

(defun magnus-bridge-client--screen-tail (buffer)
  "Return the trailing screen text of BUFFER, or \"\" if it is dead."
  (if (buffer-live-p buffer)
      (with-current-buffer buffer
        (buffer-substring-no-properties
         (max (point-min) (- (point-max) magnus-bridge-client--tail-bytes))
         (point-max)))
    ""))

(defun magnus-bridge-client--attest-tick (gen)
  "One heartbeat for GEN: re-hello on roster change, else attest state."
  (when (and magnus-bridge-client--connected
             (= gen magnus-bridge-client--generation))
    (if (not (equal (magnus-bridge-client--live-id-set)
                    (magnus-bridge-client--hosted-id-set)))
        ;; The live set diverged from what we hold a lease for.  Re-hello:
        ;; the new lease covers the new set, and agents dropped from it go
        ;; offline daemon-side as the old lease dies — the designed
        ;; lifecycle, since the protocol has no goodbye verb.
        (magnus-bridge-client--hello)
      (magnus-bridge-client--post-attest gen))))

(defun magnus-bridge-client--post-attest (gen)
  "Attest each hosted agent's ready/prompt/screen state for GEN."
  (when magnus-bridge-client--lease
    (let ((states
           (vconcat
            (mapcar
             (lambda (agent)
               (let* ((buffer (plist-get agent :buffer))
                      (iid (plist-get agent :instance-id))
                      (flagged (magnus-bridge-client--flagged-p iid))
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
                       :screen_tail (magnus-bridge-client--screen-tail buffer))))
             magnus-bridge-client--contacts))))
      (magnus-bridge-client--request
       "POST" "/local/transport/attest"
       (list :lease magnus-bridge-client--lease :states states)
       (lambda (code body)
         (magnus-bridge-client--on-attest gen code body))))))

(defun magnus-bridge-client--on-attest (gen code body)
  "Handle the attest response CODE with BODY for GEN.
A 410 or a connection error re-hellos with backoff; a 200 resets the
backoff and refreshes the TTL from BODY."
  (when (= gen magnus-bridge-client--generation)
    (if (eql code 200)
        (progn
          (setq magnus-bridge-client--backoff magnus-bridge-client--backoff-min)
          (let ((ttl (alist-get 'ttl_s body)))
            (when ttl (setq magnus-bridge-client--ttl ttl))))
      ;; ANY non-200 — 410, a connection error, or a 401 from a daemon that
      ;; restarted and minted a fresh lockfile token — means this lease (or
      ;; this token) is not working.  Re-hello with backoff: it re-reads the
      ;; lockfile, so a daemon restart heals without the user touching Emacs.
      ;; Leaving 401 a no-op here would strand the client attesting a dead
      ;; lease with yesterday's key forever.
      (magnus-bridge-client--fail-rehello))))

;;; Drain + ack -------------------------------------------------------------

(defun magnus-bridge-client--drain (gen)
  "Long-poll the daemon mailbox for GEN and process each response.
Self-perpetuating: each response re-arms the next poll unless the
generation has moved on."
  (when (and magnus-bridge-client--connected
             (= gen magnus-bridge-client--generation)
             magnus-bridge-client--lease)
    (magnus-bridge-client--request
     "GET"
     (format "/local/transport/mail?lease=%s&wait=%d"
             magnus-bridge-client--lease magnus-bridge-client-mail-wait)
     nil
     (lambda (code body)
       (magnus-bridge-client--on-mail gen code body)))))

(defun magnus-bridge-client--on-mail (gen code body)
  "Handle mail response CODE with BODY for GEN: type, ack, re-poll.
BODY carries the parked deliveries; only new ones are typed and acked."
  (when (= gen magnus-bridge-client--generation)
    (if (eql code 200)
        (progn
          (setq magnus-bridge-client--backoff magnus-bridge-client--backoff-min)
          (let* ((deliveries (alist-get 'deliveries body))
                 (typed (magnus-bridge-client--process-deliveries deliveries)))
            (when typed (magnus-bridge-client--ack typed gen))
            (if (and deliveries (null typed))
                ;; Only un-typable mail is parked (self-guarded, or for a dead
                ;; or unknown buffer).  Don't hot-loop the long-poll — let the
                ;; daemon's ack timeout redeliver under a fresh id.
                (run-with-timer
                 magnus-bridge-client--idle-redrain nil
                 (lambda () (magnus-bridge-client--drain gen)))
              (magnus-bridge-client--drain gen))))
      ;; ANY non-200: 410 and connection errors mean the lease is dead, and a
      ;; 401 means a restarted daemon no longer honors our token.  All of them
      ;; re-hello with backoff — re-polling immediately instead would hot-loop
      ;; the long-poll at localhost speed against a daemon that answers
      ;; instantly with the same refusal.
      (magnus-bridge-client--fail-rehello))))

(defun magnus-bridge-client--contact-agent (contact-id)
  "Return the hosted-agent plist for daemon CONTACT-ID, or nil."
  (cl-find contact-id magnus-bridge-client--contacts
           :key (lambda (a) (plist-get a :id)) :test #'equal))

(defun magnus-bridge-client--process-deliveries (deliveries)
  "Type each new delivery in DELIVERIES; return the ids actually typed.
Dedups by id against the seen ring (a fresh id after a daemon-side
timeout is a genuine redelivery and is typed again).  Only ids we truly
typed are returned, so `--ack' confirms exactly those."
  (let ((to-ack nil))
    (dolist (d deliveries)
      (let ((id (alist-get 'id d)))
        (when (and id (not (magnus-bridge-client--seen-p id)))
          (let ((agent (magnus-bridge-client--contact-agent
                        (alist-get 'contact d))))
            (when (and agent
                       (magnus-bridge-client--dispatch
                        agent (alist-get 'text d) (alist-get 'key d)))
              (magnus-bridge-client--mark-seen id)
              (cl-incf magnus-bridge-client--typed-count)
              (push id to-ack))))))
    (nreverse to-ack)))

(defun magnus-bridge-client--dispatch (agent text key)
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
       ((not (member key magnus-bridge-client--approve-keys))
        (message "magnus-bridge-client: refusing non-whitelisted key %S" key)
        nil)
       ((string= key "esc")
        (magnus-bridge-client--type buffer "" 'escape) t)
       (t (magnus-bridge-client--type buffer key 'key) t)))
     ((and (stringp text) (not (string-empty-p text)))
      (if (magnus-bridge-client--flagged-p iid)
          nil
        (magnus-bridge-client--type buffer text 'text) t))
     (t nil))))

(defun magnus-bridge-client--type (buffer string kind)
  "Type STRING into BUFFER as KIND via `magnus-bridge-client-type-function'."
  (funcall magnus-bridge-client-type-function buffer string kind))

(defun magnus-bridge-client--default-type (buffer string kind)
  "Type STRING into BUFFER's vterm per KIND (`text', `key' or `escape').
Mirrors `magnus-bridge--approve': escape sends escape; anything else
sends the string then a return."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (if (eq kind 'escape)
          (vterm-send-escape)
        (vterm-send-string string)
        (vterm-send-return)))))

(defun magnus-bridge-client--ack (ids gen)
  "Acknowledge delivery IDS for GEN (fire-and-forget; ack is idempotent)."
  (when (and (= gen magnus-bridge-client--generation)
             magnus-bridge-client--lease ids)
    (magnus-bridge-client--request
     "POST" "/local/transport/ack"
     (list :lease magnus-bridge-client--lease :ids (vconcat ids))
     (lambda (_code _body) nil))))

;;; Seen ring ---------------------------------------------------------------

(defun magnus-bridge-client--seen-p (id)
  "Return non-nil if delivery ID has already been typed."
  (and (member id magnus-bridge-client--seen) t))

(defun magnus-bridge-client--mark-seen (id)
  "Record delivery ID as typed, evicting the oldest past the ring cap."
  (push id magnus-bridge-client--seen)
  (when (> (length magnus-bridge-client--seen)
           magnus-bridge-client--seen-cap)
    (setcdr (nthcdr (1- magnus-bridge-client--seen-cap)
                    magnus-bridge-client--seen)
            nil)))

;;; Entry points ------------------------------------------------------------

;;;###autoload
(defun magnus-bridge-client-connect ()
  "Connect Emacs to the bridge daemon and host its live Magnus agents.
Reads the daemon lockfile, registers the roster, and starts the attest
heartbeat and delivery drain loop."
  (interactive)
  (when magnus-bridge-client--connected
    (user-error "Bridge client already connected — disconnect first"))
  (let ((daemon (magnus-bridge-client--read-daemon)))
    (setq magnus-bridge-client--port (plist-get daemon :port)
          magnus-bridge-client--token (plist-get daemon :token)
          magnus-bridge-client--connected t
          magnus-bridge-client--contacts nil
          magnus-bridge-client--seen nil
          magnus-bridge-client--skip-warned nil
          magnus-bridge-client--typed-count 0
          magnus-bridge-client--backoff magnus-bridge-client--backoff-min)
    (magnus-bridge-client--hello)
    (message "magnus-bridge-client: connecting to 127.0.0.1:%d…"
             magnus-bridge-client--port)))

;;;###autoload
(defun magnus-bridge-client-disconnect ()
  "Disconnect from the bridge daemon.
Hosted agents go offline daemon-side as their lease expires — there is
no goodbye verb; a dropped client is byte-for-byte an offline contact."
  (interactive)
  (unless magnus-bridge-client--connected
    (user-error "Bridge client is not connected"))
  (magnus-bridge-client--invalidate)
  (setq magnus-bridge-client--connected nil
        magnus-bridge-client--contacts nil)
  (message "magnus-bridge-client: disconnected (agents expire with the lease)"))

;;;###autoload
(defun magnus-bridge-client-status ()
  "Report the client's connection, lease age, hosted agents and deliveries."
  (interactive)
  (if (not magnus-bridge-client--connected)
      (message "magnus-bridge-client: disconnected")
    (message "magnus-bridge-client: connected · lease %s · hosting %d agent%s · %d deliveries typed"
             (if magnus-bridge-client--lease
                 (format "%ds old"
                         (round (- (float-time)
                                   magnus-bridge-client--lease-since)))
               "pending")
             (length magnus-bridge-client--contacts)
             (if (= 1 (length magnus-bridge-client--contacts)) "" "s")
             magnus-bridge-client--typed-count)))

(provide 'magnus-bridge-client)

;;; magnus-bridge-client.el ends here
