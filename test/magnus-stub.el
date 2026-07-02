;;; magnus-stub.el --- Minimal magnus API stub for bridge tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Just enough of magnus's API to exercise magnus-bridge in batch mode
;; without vterm.  Records agent-bound messages in `magnus-stub-sent'.

;;; Code:

(require 'cl-lib)

(cl-defstruct (magnus-instance (:constructor magnus-instance--create))
  id name directory buffer status)

(defvar magnus-stub-sent nil
  "List of (ID . MESSAGE) delivered via the stubbed nudge.")

(defvar magnus-attention-queue nil)
(defvar magnus-coord-file ".magnus-coord.md")

(defvar magnus-stub-instances
  (list (magnus-instance--create
         :id "stub-1" :name "test-fox"
         :directory temporary-file-directory :status 'running)))

(defun magnus-instances-active-list () magnus-stub-instances)

(defun magnus-instances-get (id)
  (cl-find id magnus-stub-instances :key #'magnus-instance-id :test #'equal))

(defun magnus-coord-nudge-agent (instance message &optional _source)
  (push (cons (magnus-instance-id instance) message) magnus-stub-sent))

(defun magnus-health-get (_instance) 'ok)

(defun magnus-attention--tail-text () "stub prompt tail")

(defun magnus-attention-request (_instance) nil)
(defun magnus-attention-release (_instance) nil)

(provide 'magnus)
(provide 'magnus-stub)

;;; magnus-stub.el ends here
