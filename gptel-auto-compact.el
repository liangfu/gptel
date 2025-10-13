;;; gptel-auto-compact.el --- Auto-compact context for gptel  -*- lexical-binding: t; -*-

;; Copyright (C) 2025  Karthik Chikmagalur

;; Author: Karthik Chikmagalur <karthikchikmagalur@gmail.com>
;; Keywords: convenience

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Auto-compact context functionality for gptel.  This module provides
;; intelligent context window management by automatically removing or
;; summarizing older messages when the conversation approaches token limits.

;;; Code:

(require 'cl-lib)
(require 'gptel-request)

(defgroup gptel-auto-compact nil
  "Auto-compact context for gptel."
  :group 'gptel)

;;; User options

(defcustom gptel-auto-compact-enabled nil
  "Enable automatic context compaction when approaching token limits.

When enabled, gptel will automatically manage the conversation context
by removing or summarizing older messages when the total token count
approaches the model's context window limit."
  :type 'boolean
  :group 'gptel-auto-compact)

(defcustom gptel-auto-compact-threshold 0.8
  "Threshold ratio for triggering auto-compaction.

When the estimated token count exceeds this fraction of the model's
context window, auto-compaction will be triggered.  Value should be
between 0.0 and 1.0."
  :type 'float
  :group 'gptel-auto-compact)

(defcustom gptel-auto-compact-target-ratio 0.6
  "Target ratio after compaction.

Auto-compaction will aim to reduce the context to this fraction
of the model's context window.  Value should be between 0.0 and 1.0,
and less than `gptel-auto-compact-threshold'."
  :type 'float
  :group 'gptel-auto-compact)

(defcustom gptel-auto-compact-method 'remove
  "Method to use for context compaction.

- `remove': Remove oldest messages from the conversation
- `summarize': Summarize older messages into a compact summary
- `truncate': Truncate individual messages to fit within limits"
  :type '(choice (const :tag "Remove oldest messages" remove)
                 (const :tag "Summarize older messages" summarize)  
                 (const :tag "Truncate messages" truncate))
  :group 'gptel-auto-compact)

(defcustom gptel-auto-compact-preserve-recent 3
  "Number of recent message pairs to preserve during compaction.

This ensures the most recent conversation context is always maintained."
  :type 'integer
  :group 'gptel-auto-compact)

(defcustom gptel-auto-compact-summarize-prompt
  "Please provide a concise summary of the following conversation history, preserving key context and decisions:"
  "Prompt used when summarizing conversation history.

This prompt is sent to the LLM along with the conversation history
that needs to be summarized."
  :type 'string
  :group 'gptel-auto-compact)

;;; Token estimation

(defvar gptel-auto-compact--token-cache (make-hash-table :test 'equal)
  "Cache for token count estimates.")

(defun gptel-auto-compact--estimate-tokens (text)
  "Estimate the number of tokens in TEXT.

This provides a rough approximation based on word count and character count.
The estimate errs on the side of overestimation to be conservative."
  (if-let ((cached (gethash text gptel-auto-compact--token-cache)))
      cached
    (let* ((word-count (length (split-string text)))
           (char-count (length text))
           ;; Rough approximation: 1 token ≈ 0.75 words or 4 characters
           (word-tokens (* word-count 1.33))
           (char-tokens (/ char-count 4.0))
           (estimated (ceiling (max word-tokens char-tokens))))
      (puthash text estimated gptel-auto-compact--token-cache)
      estimated)))

(defun gptel-auto-compact--get-context-window-size (&optional model backend)
  "Get the context window size for MODEL on BACKEND.

Returns the context window size in tokens, or a default estimate if unknown."
  (let ((model (or model gptel-model))
        (backend (or backend gptel-backend)))
    (or (get model :context-window)
        ;; Default estimates for common models
        (let ((model-name (gptel--model-name model)))
          (cond
           ((string-match-p "gpt-4" model-name) 128000)
           ((string-match-p "gpt-3.5" model-name) 16384)
           ((string-match-p "claude-3\\|claude.*sonnet\\|claude-4" model-name) 200000)
           ((string-match-p "claude-2" model-name) 100000)
           ((string-match-p "gemini" model-name) 32768)
           (t 8192)))))) ; Conservative default
;;; Message analysis and compaction

(defun gptel-auto-compact--count-tokens-in-messages (messages)
  "Count total estimated tokens in MESSAGES list."
  (cl-reduce #'+ messages
             :key (lambda (msg)
                    (gptel-auto-compact--estimate-tokens
                     (plist-get msg :content)))))

(defun gptel-auto-compact--should-compact-p (messages &optional model backend)
  "Check if MESSAGES should be compacted based on token count."
  (when gptel-auto-compact-enabled
    (let* ((token-count (gptel-auto-compact--count-tokens-in-messages messages))
           (context-window (gptel-auto-compact--get-context-window-size model backend))
           (threshold (* gptel-auto-compact-threshold context-window)))
      (> token-count threshold))))

(defun gptel-auto-compact--remove-oldest-messages (messages target-tokens)
  "Remove oldest messages from MESSAGES to reach TARGET-TOKENS.

Preserves the most recent `gptel-auto-compact-preserve-recent' message pairs."
  (let* ((preserve-count (* 2 gptel-auto-compact-preserve-recent))
         (recent-messages (last messages preserve-count))
         (older-messages (butlast messages preserve-count))
         (current-tokens (gptel-auto-compact--count-tokens-in-messages messages))
         (tokens-to-remove (- current-tokens target-tokens))
         (result recent-messages))
    
    ;; Remove messages from oldest until we reach target
    (while (and older-messages (> tokens-to-remove 0))
      (let* ((msg (car (last older-messages)))
             (msg-tokens (gptel-auto-compact--estimate-tokens
                         (plist-get msg :content))))
        (setq older-messages (butlast older-messages)
              tokens-to-remove (- tokens-to-remove msg-tokens))))
    
    ;; Add back remaining older messages
    (append older-messages result)))

(defun gptel-auto-compact--truncate-messages (messages target-tokens)
  "Truncate individual messages in MESSAGES to reach TARGET-TOKENS."
  (let* ((current-tokens (gptel-auto-compact--count-tokens-in-messages messages))
         (reduction-ratio (/ (float target-tokens) current-tokens)))
    (mapcar (lambda (msg)
              (let* ((content (plist-get msg :content))
                     (target-length (ceiling (* (length content) reduction-ratio)))
                     (truncated (if (> (length content) target-length)
                                    (concat (substring content 0 target-length) "...")
                                  content)))
                (plist-put (copy-sequence msg) :content truncated)))
            messages)))

(defun gptel-auto-compact--summarize-messages (messages target-tokens model backend)
  "Summarize older messages in MESSAGES to reach TARGET-TOKENS."
  (let* ((preserve-count (* 2 gptel-auto-compact-preserve-recent))
         (recent-messages (last messages preserve-count))
         (older-messages (butlast messages preserve-count)))
    
    (if (null older-messages)
        messages
      ;; Create summary of older messages
      (let* ((conversation-text 
              (mapconcat 
               (lambda (msg)
                 (format "%s: %s"
                         (plist-get msg :role)
                         (plist-get msg :content)))
               older-messages "\n\n"))
             (summary-prompt 
              (format "%s\n\n%s" gptel-auto-compact-summarize-prompt conversation-text))
             ;; For now, create a simple summary placeholder
             ;; TODO: Implement actual LLM-based summarization
             (summary (format "[Summary of %d previous messages: %s...]"
                             (length older-messages)
                             (substring conversation-text 0 (min 200 (length conversation-text))))))
        
        ;; Return summary message plus recent messages
        (cons (list :role "system" :content summary) recent-messages)))))

(defun gptel-auto-compact--compact-messages (messages &optional model backend)
  "Compact MESSAGES based on current settings."
  (let* ((context-window (gptel-auto-compact--get-context-window-size model backend))
         (target-tokens (* gptel-auto-compact-target-ratio context-window)))
    
    (pcase gptel-auto-compact-method
      ('remove (gptel-auto-compact--remove-oldest-messages messages target-tokens))
      ('truncate (gptel-auto-compact--truncate-messages messages target-tokens))
      ('summarize (gptel-auto-compact--summarize-messages messages target-tokens model backend))
      (_ messages))))

;;; Integration with gptel request system

(defun gptel-auto-compact--transform-messages (fsm)
  "Transform function for auto-compacting messages in FSM."
  (when gptel-auto-compact-enabled
    (let* ((info (gptel-fsm-info fsm))
           (data (plist-get info :data))
           (messages (plist-get data :messages))
           (model (plist-get data :model))
           (backend (plist-get info :backend)))
      
      (when (and messages (gptel-auto-compact--should-compact-p messages model backend))
        (message "Auto-compacting conversation context...")
        (let ((compacted-messages (gptel-auto-compact--compact-messages messages model backend)))
          (plist-put data :messages compacted-messages)
          (message "Context compacted from %d to %d messages"
                   (length messages) (length compacted-messages)))))))

;;; Setup and teardown

(defun gptel-auto-compact-enable ()
  "Enable auto-compact functionality."
  (interactive)
  (setq gptel-auto-compact-enabled t)
  (add-hook 'gptel-prompt-transform-functions 
            #'gptel-auto-compact--transform-messages)
  (message "gptel auto-compact enabled"))

(defun gptel-auto-compact-disable ()
  "Disable auto-compact functionality."
  (interactive)
  (setq gptel-auto-compact-enabled nil)
  (remove-hook 'gptel-prompt-transform-functions 
               #'gptel-auto-compact--transform-messages)
  (message "gptel auto-compact disabled"))

(defun gptel-auto-compact-status ()
  "Show current auto-compact status and settings."
  (interactive)
  (message "Auto-compact: %s, Method: %s, Threshold: %.1f%%, Target: %.1f%%"
           (if gptel-auto-compact-enabled "enabled" "disabled")
           gptel-auto-compact-method
           (* gptel-auto-compact-threshold 100)
           (* gptel-auto-compact-target-ratio 100))
  nil)

(defun gptel-auto-compact-clear-cache ()
  "Clear the token estimation cache."
  (interactive)
  (clrhash gptel-auto-compact--token-cache)
  (message "Token estimation cache cleared"))

;;; Statistics and debugging

(defun gptel-auto-compact-show-stats ()
  "Show statistics about current conversation context."
  (interactive)
  (if-let* ((messages (and (bound-and-true-p gptel-mode)
                          (gptel--create-prompt))))
      (let* ((token-count (gptel-auto-compact--count-tokens-in-messages messages))
             (context-window (gptel-auto-compact--get-context-window-size))
             (usage-ratio (/ (float token-count) context-window))
             (message-count (length messages)))
        (message "Context stats: %d messages, ~%d tokens (%.1f%% of %d token window)"
                 message-count token-count (* usage-ratio 100) context-window))
    (message "Not in a gptel conversation buffer")))

(provide 'gptel-auto-compact)
;;; gptel-auto-compact.el ends here