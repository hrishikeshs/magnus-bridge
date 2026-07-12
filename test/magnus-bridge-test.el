;;; magnus-bridge-test.el --- Tests for the bridge thin client -*- lexical-binding: t; -*-

;;; Commentary:
;; Batch-runnable ert tests for magnus-bridge.el.  The single HTTP
;; primitive is stubbed (`magnus-bridge--request-function'), so no
;; network, no daemon and no vterm are needed: requests are captured and
;; the test drives their callbacks by hand, exercising the protocol logic
;; (dedup, key whitelist, text self-guard, 410 re-hello + backoff reset,
;; the generation guard, lifecycle re-hello, provider filtering,
;; index-based id mapping, and missing/old-daemon failures) deterministically.
;;
;; Run:  emacs -Q --batch -L . -l test/magnus-bridge-test.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'magnus-bridge)

;; Bound so the self-guard tests can toggle it; the client reads it via `boundp'.
(defvar magnus-attention-queue nil)

;;; Stub plumbing -----------------------------------------------------------

(defvar mbct--requests nil
  "Captured (METHOD PATH BODY CALLBACK) requests, oldest first.")
(defvar mbct--typed nil
  "Captured (BUFFER STRING KIND) type calls, newest first.")
(defvar mbct--roster nil
  "Roster the stub roster-function returns.")
(defvar mbct--buffers nil
  "Buffers created for a test, killed on teardown.")
(defvar mbct--daemon-file nil
  "Temp lockfile path for a test.")

(defun mbct--stub-request (method path body callback)
  "Capture METHOD PATH BODY CALLBACK instead of performing a request."
  (setq mbct--requests
        (append mbct--requests (list (list method path body callback)))))

(defun mbct--stub-roster ()
  "Return the roster the test set in `mbct--roster'."
  mbct--roster)

(defun mbct--stub-type (buffer string kind)
  "Record a type call of STRING as KIND into BUFFER."
  (push (list buffer string kind) mbct--typed))

(defun mbct--find (path-substring)
  "Return the oldest pending request whose path contain PATH-SUBSTRING."
  (cl-find path-substring mbct--requests
           :key (lambda (r) (nth 1 r))
           :test (lambda (sub p) (string-match-p (regexp-quote sub) p))))

(defun mbct--respond (path-substring code body)
  "Pop the oldest request matching PATH-SUBSTRING; run its callback CODE BODY."
  (let* ((req (mbct--find path-substring)))
    (should req)
    (setq mbct--requests (delq req mbct--requests))
    (funcall (nth 3 req) code body)))

(defun mbct--hello-ok (contacts-spec &optional lease ttl)
  "Answer a pending hello 200 with LEASE and TTL.
CONTACTS-SPEC is a list of (ID . NAME) the daemon returns in order."
  (mbct--respond
   "hello" 200
   (list (cons 'agents (mapcar (lambda (c)
                                 (list (cons 'id (car c)) (cons 'name (cdr c))))
                               contacts-spec))
         (cons 'lease (or lease "L1"))
         (cons 'ttl_s (or ttl 30)))))

(defun mbct--agent (id name &optional provider session-id)
  "Return a hostable ID/NAME agent for PROVIDER with a fresh buffer."
  (let ((buf (generate-new-buffer (generate-new-buffer-name
                                   (concat "mbct-" id)))))
    (push buf mbct--buffers)
    (list :instance-id id :name name :directory "/tmp"
          :session-id (or session-id (concat "sess-" id))
          :provider (or provider 'claude) :buffer buf)))

(defun mbct--deliv (id contact text key)
  "Build a delivery alist (ID CONTACT TEXT KEY) in the client's parsed shape."
  (append (list (cons 'id id) (cons 'contact contact))
          (and text (list (cons 'text text)))
          (and key (list (cons 'key key)))))

(defun mbct--reset ()
  "Return the client and the test plumbing to a clean slate."
  (when magnus-bridge--attest-timer
    (cancel-timer magnus-bridge--attest-timer))
  (setq magnus-bridge--connected nil
        magnus-bridge-mode nil
        magnus-bridge--attest-timer nil
        magnus-bridge--lease nil
        magnus-bridge--contacts nil
        magnus-bridge--seen nil
        magnus-bridge--skip-warned nil
        magnus-bridge--typed-count 0
        magnus-bridge--backoff magnus-bridge--backoff-min
        ;; Bump the generation so any stray timer/callback from a prior test
        ;; self-discards even if it somehow fires.
        magnus-bridge--generation (1+ magnus-bridge--generation)
        mbct--requests nil
        mbct--typed nil
        mbct--roster nil
        magnus-attention-queue nil)
  (dolist (b mbct--buffers) (when (buffer-live-p b) (kill-buffer b)))
  (setq mbct--buffers nil))

(defmacro mbct-deftest (name &rest body)
  "Define ert test NAME with stubs bound and a clean slate around BODY."
  (declare (indent 1))
  `(ert-deftest ,name ()
     (mbct--reset)
     (setq mbct--daemon-file (make-temp-file "mbct-daemon" nil ".json"))
     (with-temp-file mbct--daemon-file
       (insert "{\"port\": 12345, \"token\": \"deadbeeftoken\"}"))
     (let ((magnus-bridge-daemon-file mbct--daemon-file)
           (magnus-bridge--request-function #'mbct--stub-request)
           (magnus-bridge-roster-function #'mbct--stub-roster)
           (magnus-bridge-type-function #'mbct--stub-type))
       (unwind-protect (progn ,@body)
         (when (and mbct--daemon-file (file-exists-p mbct--daemon-file))
           (delete-file mbct--daemon-file))
         (mbct--reset)))))

;;; Tests -------------------------------------------------------------------

(mbct-deftest magnus-bridge-test-default-roster-carries-provider
  ;; Provider identity must survive the Magnus adapter boundary; otherwise a
  ;; Codex TUI could be mistaken for a Claude terminal before filtering.
  (cl-letf (((symbol-function 'magnus-instances-active-list)
             (lambda () '(fake-instance)))
            ((symbol-function 'magnus-instance-id) (lambda (_instance) "i1"))
            ((symbol-function 'magnus-instance-name) (lambda (_instance) "deer"))
            ((symbol-function 'magnus-instance-directory)
             (lambda (_instance) "/tmp"))
            ((symbol-function 'magnus-instance-session-id)
             (lambda (_instance) "session"))
            ((symbol-function 'magnus-instance-provider)
             (lambda (_instance) 'codex))
            ((symbol-function 'magnus-instance-buffer)
             (lambda (_instance) nil)))
    (should (eq 'codex
                (plist-get (car (magnus-bridge--default-roster)) :provider)))))

(mbct-deftest magnus-bridge-test-id-dedup
  ;; Same id twice -> typed once; a fresh id (a redelivery after a daemon-side
  ;; timeout) -> typed again.
  (let ((agent (mbct--agent "i1" "wolf")))
    (setq magnus-bridge--contacts
          (list (list :id "c1" :name "wolf" :instance-id "i1"
                      :buffer (plist-get agent :buffer)))))
  (should (equal '("d1")
                 (magnus-bridge--process-deliveries
                  (list (mbct--deliv "d1" "c1" "hello" nil)))))
  (should (= 1 (length mbct--typed)))
  (should (null (magnus-bridge--process-deliveries
                 (list (mbct--deliv "d1" "c1" "hello" nil)))))
  (should (= 1 (length mbct--typed)))
  (should (equal '("d2")
                 (magnus-bridge--process-deliveries
                  (list (mbct--deliv "d2" "c1" "hello" nil)))))
  (should (= 2 (length mbct--typed))))

(mbct-deftest magnus-bridge-test-key-whitelist
  ;; A whitelisted key is typed and acked; a bad key is never typed nor acked.
  ;; (Defense in depth: remote.go's SendKey refuses non-whitelisted keys before
  ;; ever parking one, so a compliant daemon cannot even send "q" — the client
  ;; guards anyway.)
  (let ((agent (mbct--agent "i1" "wolf")))
    (setq magnus-bridge--contacts
          (list (list :id "c1" :instance-id "i1"
                      :buffer (plist-get agent :buffer)))))
  (should (equal '("k1")
                 (magnus-bridge--process-deliveries
                  (list (mbct--deliv "k1" "c1" nil "1")))))
  (should (string= "1" (nth 1 (car mbct--typed))))
  (should (eq 'key (nth 2 (car mbct--typed))))
  (should (null (magnus-bridge--process-deliveries
                 (list (mbct--deliv "k2" "c1" nil "q")))))
  (should (= 1 (length mbct--typed)))
  (should (equal '("k3")
                 (magnus-bridge--process-deliveries
                  (list (mbct--deliv "k3" "c1" nil "esc")))))
  (should (eq 'escape (nth 2 (car mbct--typed)))))

(mbct-deftest magnus-bridge-test-text-self-guard
  ;; Attention-flagged NOW -> no type, no ack; unflagged -> typed + acked.
  (let ((agent (mbct--agent "i1" "wolf")))
    (setq magnus-bridge--contacts
          (list (list :id "c1" :instance-id "i1"
                      :buffer (plist-get agent :buffer)))))
  (setq magnus-attention-queue '("i1"))
  (should (null (magnus-bridge--process-deliveries
                 (list (mbct--deliv "t1" "c1" "hello" nil)))))
  (should (= 0 (length mbct--typed)))
  (setq magnus-attention-queue nil)
  (should (equal '("t2")
                 (magnus-bridge--process-deliveries
                  (list (mbct--deliv "t2" "c1" "hello" nil)))))
  (should (= 1 (length mbct--typed))))

(mbct-deftest magnus-bridge-test-410-rehello-backoff
  ;; 410 anywhere -> drop lease, re-hello with growing backoff; a successful
  ;; hello resets the backoff to the minimum.
  (setq mbct--roster (list (mbct--agent "i1" "wolf")))
  (magnus-bridge-mode 1)
  (should (mbct--find "hello"))
  (mbct--hello-ok '(("c1" . "wolf")))
  (should (string= "L1" magnus-bridge--lease))
  (should (= magnus-bridge--backoff-min magnus-bridge--backoff))
  (should (mbct--find "mail"))
  (mbct--respond "mail" 410 nil)
  (should (null magnus-bridge--lease))
  (should (= 4 magnus-bridge--backoff))
  ;; simulate the scheduled retry firing
  (magnus-bridge--hello)
  (should (mbct--find "hello"))
  (mbct--hello-ok '(("c1" . "wolf")) "L2")
  (should (string= "L2" magnus-bridge--lease))
  (should (= magnus-bridge--backoff-min magnus-bridge--backoff)))

(mbct-deftest magnus-bridge-test-generation-guard
  ;; A callback captured before a disconnect is stale and must be a no-op.
  (setq mbct--roster (list (mbct--agent "i1" "wolf")))
  (magnus-bridge-mode 1)
  (mbct--hello-ok '(("c1" . "wolf")))
  (let ((mail-req (mbct--find "mail")))
    (should mail-req)
    (magnus-bridge-mode -1)
    (funcall (nth 3 mail-req) 200
             (list (cons 'deliveries (list (mbct--deliv "d1" "c1" "hi" nil)))))
    (should (= 0 (length mbct--typed)))
    (should (null (mbct--find "ack")))))

(mbct-deftest magnus-bridge-test-roster-change-rehello
  ;; When the live instance set diverges from what we hold a lease for, re-hello.
  (setq mbct--roster (list (mbct--agent "i1" "wolf")))
  (magnus-bridge-mode 1)
  (mbct--hello-ok '(("c1" . "wolf")))
  (let ((gen magnus-bridge--generation))
    (setq mbct--roster (list (mbct--agent "i2" "fox")))
    (magnus-bridge--attest-tick gen)
    (let ((hello (mbct--find "hello")))
      (should hello)
      (let ((agents (plist-get (nth 2 hello) :agents)))
        (should (= 1 (length agents)))
        (should (string= "fox" (plist-get (aref agents 0) :name)))))))

(mbct-deftest magnus-bridge-test-buffer-replacement-rehello
  ;; Archive/resurrection preserves the Magnus UUID but replaces its buffer.
  ;; The client must re-hello rather than attest the dead original forever.
  (setq mbct--roster (list (mbct--agent "i1" "wolf")))
  (magnus-bridge-mode 1)
  (mbct--hello-ok '(("c1" . "wolf")))
  (let ((gen magnus-bridge--generation))
    (setq mbct--roster (list (mbct--agent "i1" "wolf")))
    (magnus-bridge--attest-tick gen)
    (should (mbct--find "hello"))))

(mbct-deftest magnus-bridge-test-session-change-rehello
  ;; A resumed Claude process may rotate its session ID under the same UUID.
  ;; Bridge tails the session named at hello, so the changed ID must re-register.
  (setq mbct--roster (list (mbct--agent "i1" "wolf" 'claude "session-1")))
  (magnus-bridge-mode 1)
  (mbct--hello-ok '(("c1" . "wolf")))
  (let* ((gen magnus-bridge--generation)
         (same-buffer (plist-get (car mbct--roster) :buffer)))
    (setq mbct--roster
          (list (list :instance-id "i1" :name "wolf" :directory "/tmp"
                      :session-id "session-2" :provider 'claude
                      :buffer same-buffer)))
    (magnus-bridge--attest-tick gen)
    (let ((hello (mbct--find "hello")))
      (should hello)
      (should (equal "session-2"
                     (plist-get (aref (plist-get (nth 2 hello) :agents) 0)
                                :session_id))))))

(mbct-deftest magnus-bridge-test-codex-is-not-registered-as-claude-v1
  ;; Magnus owns Codex's native TUI; terminal-v1 Bridge cannot safely tail its
  ;; rollout or translate its approvals.  A Claude peer remains hostable.
  (setq mbct--roster (list (mbct--agent "c1" "wise-deer" 'codex)
                           (mbct--agent "a1" "quick-wolf" 'claude)))
  (magnus-bridge-mode 1)
  (let* ((hello (mbct--find "hello"))
         (agents (plist-get (nth 2 hello) :agents)))
    (should (= 1 (length agents)))
    (should (equal "quick-wolf" (plist-get (aref agents 0) :name)))))

(mbct-deftest magnus-bridge-test-old-daemon-disables-mode
  ;; A 404 is a deterministic capability mismatch, not a transient outage.
  (setq mbct--roster (list (mbct--agent "i1" "wolf")))
  (magnus-bridge-mode 1)
  (mbct--respond "hello" 404 nil)
  (should-not magnus-bridge-mode)
  (should-not magnus-bridge--connected)
  (should-not magnus-bridge--lease))

(mbct-deftest magnus-bridge-test-index-mapping-suffixed
  ;; Two agents ask for the same name; the daemon suffixes the second.  The
  ;; client must map returned agents to instances BY INDEX, never by name.
  (setq mbct--roster (list (mbct--agent "i1" "marvin") (mbct--agent "i2" "marvin")))
  (magnus-bridge-mode 1)
  (mbct--hello-ok '(("cA" . "marvin") ("cB" . "marvin-2")))
  (should (string= "i1" (plist-get (magnus-bridge--contact-agent "cA")
                                   :instance-id)))
  (should (string= "i2" (plist-get (magnus-bridge--contact-agent "cB")
                                   :instance-id))))

(mbct-deftest magnus-bridge-test-deliver-ack-repoll
  ;; An unflagged text delivery is typed, acked with exactly its id, and the
  ;; client immediately re-polls.
  (setq mbct--roster (list (mbct--agent "i1" "wolf")))
  (magnus-bridge-mode 1)
  (mbct--hello-ok '(("c1" . "wolf")))
  (mbct--respond
   "mail" 200
   (list (cons 'deliveries (list (mbct--deliv "d1" "c1" "[From Hrishi]: hi" nil)))))
  (should (= 1 (length mbct--typed)))
  (should (string= "[From Hrishi]: hi" (nth 1 (car mbct--typed))))
  (let ((ack (mbct--find "ack")))
    (should ack)
    (should (equal ["d1"] (plist-get (nth 2 ack) :ids))))
  (should (mbct--find "mail")))

(mbct-deftest magnus-bridge-test-daemon-file-missing
  ;; A missing lockfile is a clean user-error, not a backtrace.
  (let ((magnus-bridge-daemon-file
         (expand-file-name "mbct-nonexistent-xyz.json" temporary-file-directory)))
    (when (file-exists-p magnus-bridge-daemon-file)
      (delete-file magnus-bridge-daemon-file))
    (should-error (magnus-bridge-mode 1) :type 'user-error)
    (should-not magnus-bridge-mode)))

(mbct-deftest magnus-bridge-test-unibyte-request-parts
  ;; Every string handed to url.el must come out unibyte: a multibyte part
  ;; anywhere in the assembled request re-poisons the encoded body and url-http
  ;; rejects it ("Multibyte text in HTTP request") — found live when the first
  ;; attested screen tail carrying a real dialog's ❯ killed the heartbeat.
  (let ((coerced (magnus-bridge--unibyte "a❯b")))
    (should-not (multibyte-string-p coerced))
    (should (= 5 (string-bytes coerced))))   ; a + 3-byte ❯ + b
  (let ((ascii (magnus-bridge--unibyte
                (encode-coding-string "plain" 'utf-8))))
    (should-not (multibyte-string-p ascii))
    (should (string= "plain" ascii))))

(mbct-deftest magnus-bridge-test-mail-401-rehello
  ;; A restarted daemon mints a fresh lockfile token, so every request 401s.
  ;; The mail loop must treat that like a dead lease — drop it and re-hello
  ;; with backoff — never hot-loop the long-poll on an instant refusal.
  (setq mbct--roster (list (mbct--agent "i1" "wolf")))
  (magnus-bridge-mode 1)
  (mbct--hello-ok '(("c1" . "wolf")))
  (should (string= "L1" magnus-bridge--lease))
  (mbct--respond "mail" 401 nil)
  (should (null magnus-bridge--lease))
  (should (= 4 magnus-bridge--backoff)))

(mbct-deftest magnus-bridge-test-lockfile-rotation-heals
  ;; Each hello re-reads the lockfile, so a re-hello after a daemon restart
  ;; knocks with the NEW token and port — the client self-heals without the
  ;; user touching Emacs.
  (setq mbct--roster (list (mbct--agent "i1" "wolf")))
  (magnus-bridge-mode 1)
  (mbct--hello-ok '(("c1" . "wolf")))
  (should (= 12345 magnus-bridge--port))
  (with-temp-file mbct--daemon-file
    (insert "{\"port\": 23456, \"token\": \"freshtoken\"}"))
  ;; Simulate the scheduled retry firing after a failure.
  (magnus-bridge--hello)
  (should (= 23456 magnus-bridge--port))
  (should (string= "freshtoken" magnus-bridge--token))
  (should (mbct--find "hello")))

(provide 'magnus-bridge-test)

;;; magnus-bridge-test.el ends here
