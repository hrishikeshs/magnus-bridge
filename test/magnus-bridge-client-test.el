;;; magnus-bridge-client-test.el --- Tests for the bridge thin client -*- lexical-binding: t; -*-

;;; Commentary:
;; Batch-runnable ert tests for magnus-bridge-client.el.  The single HTTP
;; primitive is stubbed (`magnus-bridge-client--request-function'), so no
;; network, no daemon and no vterm are needed: requests are captured and
;; the test drives their callbacks by hand, exercising the protocol logic
;; (dedup, key whitelist, text self-guard, 410 re-hello + backoff reset,
;; the generation guard, roster-change re-hello, index-based id mapping,
;; and the missing-lockfile user-error) deterministically.
;;
;; Run:  emacs -Q --batch -L . -l test/magnus-bridge-client-test.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'magnus-bridge-client)

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

(defun mbct--agent (id name)
  "Return a hostable-agent plist for ID/NAME with a fresh live buffer."
  (let ((buf (generate-new-buffer (concat "mbct-" id))))
    (push buf mbct--buffers)
    (list :instance-id id :name name :directory "/tmp"
          :session-id (concat "sess-" id) :buffer buf)))

(defun mbct--deliv (id contact text key)
  "Build a delivery alist (ID CONTACT TEXT KEY) in the client's parsed shape."
  (append (list (cons 'id id) (cons 'contact contact))
          (and text (list (cons 'text text)))
          (and key (list (cons 'key key)))))

(defun mbct--reset ()
  "Return the client and the test plumbing to a clean slate."
  (when magnus-bridge-client--attest-timer
    (cancel-timer magnus-bridge-client--attest-timer))
  (setq magnus-bridge-client--connected nil
        magnus-bridge-client--attest-timer nil
        magnus-bridge-client--lease nil
        magnus-bridge-client--contacts nil
        magnus-bridge-client--seen nil
        magnus-bridge-client--skip-warned nil
        magnus-bridge-client--typed-count 0
        magnus-bridge-client--backoff magnus-bridge-client--backoff-min
        ;; Bump the generation so any stray timer/callback from a prior test
        ;; self-discards even if it somehow fires.
        magnus-bridge-client--generation (1+ magnus-bridge-client--generation)
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
     (let ((magnus-bridge-client-daemon-file mbct--daemon-file)
           (magnus-bridge-client--request-function #'mbct--stub-request)
           (magnus-bridge-client-roster-function #'mbct--stub-roster)
           (magnus-bridge-client-type-function #'mbct--stub-type))
       (unwind-protect (progn ,@body)
         (when (and mbct--daemon-file (file-exists-p mbct--daemon-file))
           (delete-file mbct--daemon-file))
         (mbct--reset)))))

;;; Tests -------------------------------------------------------------------

(mbct-deftest magnus-bridge-client-test-id-dedup
  ;; Same id twice -> typed once; a fresh id (a redelivery after a daemon-side
  ;; timeout) -> typed again.
  (let ((agent (mbct--agent "i1" "wolf")))
    (setq magnus-bridge-client--contacts
          (list (list :id "c1" :name "wolf" :instance-id "i1"
                      :buffer (plist-get agent :buffer)))))
  (should (equal '("d1")
                 (magnus-bridge-client--process-deliveries
                  (list (mbct--deliv "d1" "c1" "hello" nil)))))
  (should (= 1 (length mbct--typed)))
  (should (null (magnus-bridge-client--process-deliveries
                 (list (mbct--deliv "d1" "c1" "hello" nil)))))
  (should (= 1 (length mbct--typed)))
  (should (equal '("d2")
                 (magnus-bridge-client--process-deliveries
                  (list (mbct--deliv "d2" "c1" "hello" nil)))))
  (should (= 2 (length mbct--typed))))

(mbct-deftest magnus-bridge-client-test-key-whitelist
  ;; A whitelisted key is typed and acked; a bad key is never typed nor acked.
  ;; (Defense in depth: remote.go's SendKey refuses non-whitelisted keys before
  ;; ever parking one, so a compliant daemon cannot even send "q" — the client
  ;; guards anyway.)
  (let ((agent (mbct--agent "i1" "wolf")))
    (setq magnus-bridge-client--contacts
          (list (list :id "c1" :instance-id "i1"
                      :buffer (plist-get agent :buffer)))))
  (should (equal '("k1")
                 (magnus-bridge-client--process-deliveries
                  (list (mbct--deliv "k1" "c1" nil "1")))))
  (should (string= "1" (nth 1 (car mbct--typed))))
  (should (eq 'key (nth 2 (car mbct--typed))))
  (should (null (magnus-bridge-client--process-deliveries
                 (list (mbct--deliv "k2" "c1" nil "q")))))
  (should (= 1 (length mbct--typed)))
  (should (equal '("k3")
                 (magnus-bridge-client--process-deliveries
                  (list (mbct--deliv "k3" "c1" nil "esc")))))
  (should (eq 'escape (nth 2 (car mbct--typed)))))

(mbct-deftest magnus-bridge-client-test-text-self-guard
  ;; Attention-flagged NOW -> no type, no ack; unflagged -> typed + acked.
  (let ((agent (mbct--agent "i1" "wolf")))
    (setq magnus-bridge-client--contacts
          (list (list :id "c1" :instance-id "i1"
                      :buffer (plist-get agent :buffer)))))
  (setq magnus-attention-queue '("i1"))
  (should (null (magnus-bridge-client--process-deliveries
                 (list (mbct--deliv "t1" "c1" "hello" nil)))))
  (should (= 0 (length mbct--typed)))
  (setq magnus-attention-queue nil)
  (should (equal '("t2")
                 (magnus-bridge-client--process-deliveries
                  (list (mbct--deliv "t2" "c1" "hello" nil)))))
  (should (= 1 (length mbct--typed))))

(mbct-deftest magnus-bridge-client-test-410-rehello-backoff
  ;; 410 anywhere -> drop lease, re-hello with growing backoff; a successful
  ;; hello resets the backoff to the minimum.
  (setq mbct--roster (list (mbct--agent "i1" "wolf")))
  (magnus-bridge-client-connect)
  (should (mbct--find "hello"))
  (mbct--hello-ok '(("c1" . "wolf")))
  (should (string= "L1" magnus-bridge-client--lease))
  (should (= magnus-bridge-client--backoff-min magnus-bridge-client--backoff))
  (should (mbct--find "mail"))
  (mbct--respond "mail" 410 nil)
  (should (null magnus-bridge-client--lease))
  (should (= 4 magnus-bridge-client--backoff))
  ;; simulate the scheduled retry firing
  (magnus-bridge-client--hello)
  (should (mbct--find "hello"))
  (mbct--hello-ok '(("c1" . "wolf")) "L2")
  (should (string= "L2" magnus-bridge-client--lease))
  (should (= magnus-bridge-client--backoff-min magnus-bridge-client--backoff)))

(mbct-deftest magnus-bridge-client-test-generation-guard
  ;; A callback captured before a disconnect is stale and must be a no-op.
  (setq mbct--roster (list (mbct--agent "i1" "wolf")))
  (magnus-bridge-client-connect)
  (mbct--hello-ok '(("c1" . "wolf")))
  (let ((mail-req (mbct--find "mail")))
    (should mail-req)
    (magnus-bridge-client-disconnect)
    (funcall (nth 3 mail-req) 200
             (list (cons 'deliveries (list (mbct--deliv "d1" "c1" "hi" nil)))))
    (should (= 0 (length mbct--typed)))
    (should (null (mbct--find "ack")))))

(mbct-deftest magnus-bridge-client-test-roster-change-rehello
  ;; When the live instance set diverges from what we hold a lease for, re-hello.
  (setq mbct--roster (list (mbct--agent "i1" "wolf")))
  (magnus-bridge-client-connect)
  (mbct--hello-ok '(("c1" . "wolf")))
  (let ((gen magnus-bridge-client--generation))
    (setq mbct--roster (list (mbct--agent "i2" "fox")))
    (magnus-bridge-client--attest-tick gen)
    (let ((hello (mbct--find "hello")))
      (should hello)
      (let ((agents (plist-get (nth 2 hello) :agents)))
        (should (= 1 (length agents)))
        (should (string= "fox" (plist-get (aref agents 0) :name)))))))

(mbct-deftest magnus-bridge-client-test-index-mapping-suffixed
  ;; Two agents ask for the same name; the daemon suffixes the second.  The
  ;; client must map returned agents to instances BY INDEX, never by name.
  (setq mbct--roster (list (mbct--agent "i1" "marvin") (mbct--agent "i2" "marvin")))
  (magnus-bridge-client-connect)
  (mbct--hello-ok '(("cA" . "marvin") ("cB" . "marvin-2")))
  (should (string= "i1" (plist-get (magnus-bridge-client--contact-agent "cA")
                                   :instance-id)))
  (should (string= "i2" (plist-get (magnus-bridge-client--contact-agent "cB")
                                   :instance-id))))

(mbct-deftest magnus-bridge-client-test-deliver-ack-repoll
  ;; An unflagged text delivery is typed, acked with exactly its id, and the
  ;; client immediately re-polls.
  (setq mbct--roster (list (mbct--agent "i1" "wolf")))
  (magnus-bridge-client-connect)
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

(mbct-deftest magnus-bridge-client-test-daemon-file-missing
  ;; A missing lockfile is a clean user-error, not a backtrace.
  (let ((magnus-bridge-client-daemon-file
         (expand-file-name "mbct-nonexistent-xyz.json" temporary-file-directory)))
    (when (file-exists-p magnus-bridge-client-daemon-file)
      (delete-file magnus-bridge-client-daemon-file))
    (should-error (magnus-bridge-client-connect) :type 'user-error)))

(mbct-deftest magnus-bridge-client-test-unibyte-request-parts
  ;; Every string handed to url.el must come out unibyte: a multibyte part
  ;; anywhere in the assembled request re-poisons the encoded body and url-http
  ;; rejects it ("Multibyte text in HTTP request") — found live when the first
  ;; attested screen tail carrying a real dialog's ❯ killed the heartbeat.
  (let ((coerced (magnus-bridge-client--unibyte "a❯b")))
    (should-not (multibyte-string-p coerced))
    (should (= 5 (string-bytes coerced))))   ; a + 3-byte ❯ + b
  (let ((ascii (magnus-bridge-client--unibyte
                (encode-coding-string "plain" 'utf-8))))
    (should-not (multibyte-string-p ascii))
    (should (string= "plain" ascii))))

(mbct-deftest magnus-bridge-client-test-mail-401-rehello
  ;; A restarted daemon mints a fresh lockfile token, so every request 401s.
  ;; The mail loop must treat that like a dead lease — drop it and re-hello
  ;; with backoff — never hot-loop the long-poll on an instant refusal.
  (setq mbct--roster (list (mbct--agent "i1" "wolf")))
  (magnus-bridge-client-connect)
  (mbct--hello-ok '(("c1" . "wolf")))
  (should (string= "L1" magnus-bridge-client--lease))
  (mbct--respond "mail" 401 nil)
  (should (null magnus-bridge-client--lease))
  (should (= 4 magnus-bridge-client--backoff)))

(mbct-deftest magnus-bridge-client-test-lockfile-rotation-heals
  ;; Each hello re-reads the lockfile, so a re-hello after a daemon restart
  ;; knocks with the NEW token and port — the client self-heals without the
  ;; user touching Emacs.
  (setq mbct--roster (list (mbct--agent "i1" "wolf")))
  (magnus-bridge-client-connect)
  (mbct--hello-ok '(("c1" . "wolf")))
  (should (= 12345 magnus-bridge-client--port))
  (with-temp-file mbct--daemon-file
    (insert "{\"port\": 23456, \"token\": \"freshtoken\"}"))
  ;; Simulate the scheduled retry firing after a failure.
  (magnus-bridge-client--hello)
  (should (= 23456 magnus-bridge-client--port))
  (should (string= "freshtoken" magnus-bridge-client--token))
  (should (mbct--find "hello")))

(provide 'magnus-bridge-client-test)

;;; magnus-bridge-client-test.el ends here
