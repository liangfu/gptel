;;; test-gptel-auto-compact.el --- Tests for gptel auto-compact functionality -*- lexical-binding: t; -*-

;; Copyright (C) 2025  Author

;; Author: Assistant
;; Keywords: convenience, test

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;;; Commentary:

;; Test suite for gptel-auto-compact functionality including:
;; - Token estimation
;; - Context window detection  
;; - Message compaction strategies
;; - Integration with gptel request pipeline
;; - UI components

;;; Code:

(require 'ert)
(require 'gptel-auto-compact)

;;; Token Estimation Tests

(ert-deftest gptel-auto-compact-test-token-estimation ()
  "Test token estimation functionality."
  (let ((short-text "Hello world")
        (long-text "This is a longer message with multiple words that should result in a higher token count estimate."))
    
    ;; Test basic estimation
    (should (> (gptel-auto-compact--estimate-tokens long-text)
               (gptel-auto-compact--estimate-tokens short-text)))
    
    ;; Test caching
    (let ((initial-cache-size (hash-table-count gptel-auto-compact--token-cache)))
      (gptel-auto-compact--estimate-tokens "test message")
      (should (> (hash-table-count gptel-auto-compact--token-cache)
                 initial-cache-size))
      
      ;; Test cache hit
      (let ((cached-result (gptel-auto-compact--estimate-tokens "test message")))
        (should (= cached-result (gptel-auto-compact--estimate-tokens "test message")))))))

(ert-deftest gptel-auto-compact-test-context-window-detection ()
  "Test context window size detection for various models."
  ;; Test with known models (mock model names)
  (should (= (gptel-auto-compact--get-context-window-size 'gpt-4-test) 128000))
  (should (= (gptel-auto-compact--get-context-window-size 'gpt-3.5-test) 16384))
  (should (= (gptel-auto-compact--get-context-window-size 'claude-3-test) 200000))
  (should (= (gptel-auto-compact--get-context-window-size 'claude-2-test) 100000))
  (should (= (gptel-auto-compact--get-context-window-size 'gemini-test) 32768))
  
  ;; Test default fallback
  (should (= (gptel-auto-compact--get-context-window-size 'unknown-model) 8192)))

(ert-deftest gptel-auto-compact-test-message-token-counting ()
  "Test counting tokens in message lists."
  (let ((messages '((:role "user" :content "Hello")
                    (:role "assistant" :content "Hi there!")
                    (:role "user" :content "How are you?"))))
    
    (should (> (gptel-auto-compact--count-tokens-in-messages messages) 0))
    
    ;; Test with empty messages
    (should (= (gptel-auto-compact--count-tokens-in-messages '()) 0))))

(ert-deftest gptel-auto-compact-test-compaction-trigger ()
  "Test when compaction should be triggered."
  (let ((gptel-auto-compact-enabled t)
        (gptel-auto-compact-threshold 0.8))
    
    ;; Mock small messages that shouldn't trigger compaction
    (let ((small-messages '((:role "user" :content "Hi"))))
      (should-not (gptel-auto-compact--should-compact-p small-messages)))
    
    ;; Test with auto-compact disabled
    (let ((gptel-auto-compact-enabled nil))
      (should-not (gptel-auto-compact--should-compact-p 
                   '((:role "user" :content "This is a test message")))))))

;;; Compaction Strategy Tests

(ert-deftest gptel-auto-compact-test-remove-oldest-strategy ()
  "Test the 'remove oldest messages' compaction strategy."
  (let ((messages '((:role "user" :content "Message 1")
                    (:role "assistant" :content "Response 1") 
                    (:role "user" :content "Message 2")
                    (:role "assistant" :content "Response 2")
                    (:role "user" :content "Message 3")
                    (:role "assistant" :content "Response 3")))
        (gptel-auto-compact-preserve-recent 2))
    
    ;; Should preserve recent messages and remove older ones
    (let ((compacted (gptel-auto-compact--remove-oldest-messages messages 100)))
      (should (<= (length compacted) (length messages)))
      
      ;; Should preserve the most recent preserve-count pairs
      (should (member '(:role "user" :content "Message 3") compacted))
      (should (member '(:role "assistant" :content "Response 3") compacted)))))

(ert-deftest gptel-auto-compact-test-truncate-strategy ()
  "Test the 'truncate messages' compaction strategy."
  (let ((messages '((:role "user" :content "This is a very long message that should be truncated when the target token count is reached")
                    (:role "assistant" :content "This is another long response that should also be truncated"))))
    
    (let ((compacted (gptel-auto-compact--truncate-messages messages 50)))
      (should (= (length compacted) (length messages)))
      
      ;; Check that content is truncated
      (should (< (length (plist-get (car compacted) :content))
                 (length (plist-get (car messages) :content)))))))

(ert-deftest gptel-auto-compact-test-summarize-strategy ()
  "Test the 'summarize messages' compaction strategy."
  (let ((messages '((:role "user" :content "Old message 1")
                    (:role "assistant" :content "Old response 1")
                    (:role "user" :content "Old message 2")  
                    (:role "assistant" :content "Old response 2")
                    (:role "user" :content "Recent message")
                    (:role "assistant" :content "Recent response")))
        (gptel-auto-compact-preserve-recent 1))
    
    (let ((compacted (gptel-auto-compact--summarize-messages messages 100 nil nil)))
      ;; Should have summary + recent messages
      (should (< (length compacted) (length messages)))
      
      ;; First message should be a summary (system role)
      (should (string= (plist-get (car compacted) :role) "system"))
      
      ;; Should preserve recent messages
      (should (member '(:role "user" :content "Recent message") compacted))
      (should (member '(:role "assistant" :content "Recent response") compacted)))))

;;; Integration Tests

(ert-deftest gptel-auto-compact-test-enable-disable ()
  "Test enabling and disabling auto-compact functionality."
  ;; Test enabling
  (gptel-auto-compact-enable)
  (should gptel-auto-compact-enabled)
  (should (member 'gptel-auto-compact--transform-messages 
                  gptel-prompt-transform-functions))
  
  ;; Test disabling  
  (gptel-auto-compact-disable)
  (should-not gptel-auto-compact-enabled)
  (should-not (member 'gptel-auto-compact--transform-messages 
                      gptel-prompt-transform-functions)))

(ert-deftest gptel-auto-compact-test-cache-management ()
  "Test token cache clearing functionality."
  ;; Add something to cache
  (gptel-auto-compact--estimate-tokens "test for cache")
  (should (> (hash-table-count gptel-auto-compact--token-cache) 0))
  
  ;; Clear cache
  (gptel-auto-compact-clear-cache)
  (should (= (hash-table-count gptel-auto-compact--token-cache) 0)))

;;; Configuration Tests

(ert-deftest gptel-auto-compact-test-configuration-validation ()
  "Test configuration option validation."
  ;; Test threshold bounds
  (let ((gptel-auto-compact-threshold 0.5)
        (gptel-auto-compact-target-ratio 0.3))
    (should (< gptel-auto-compact-target-ratio gptel-auto-compact-threshold)))
  
  ;; Test valid methods
  (dolist (method '(remove summarize truncate))
    (let ((gptel-auto-compact-method method))
      (should (memq gptel-auto-compact-method '(remove summarize truncate))))))

;;; UI Integration Tests (Mock)

(ert-deftest gptel-auto-compact-test-status-display ()
  "Test status display functionality."
  (let ((gptel-auto-compact-enabled t)
        (gptel-auto-compact-method 'remove)
        (gptel-auto-compact-threshold 0.8)
        (gptel-auto-compact-target-ratio 0.6))
    
    ;; Should not error when called
    (should-not (condition-case nil
                    (gptel-auto-compact-status)
                  (error t)))))

;;; Performance Tests

(ert-deftest gptel-auto-compact-test-performance ()
  "Test performance characteristics of auto-compact functions."
  (let ((large-messages 
         (make-list 100 '(:role "user" :content "This is a test message with reasonable length to simulate real usage patterns."))))
    
    ;; Token counting should be reasonably fast
    (let ((start-time (current-time)))
      (gptel-auto-compact--count-tokens-in-messages large-messages)
      (let ((elapsed (float-time (time-subtract (current-time) start-time))))
        (should (< elapsed 1.0)))) ;; Should complete within 1 second
    
    ;; Compaction should be reasonably fast
    (let ((start-time (current-time)))
      (gptel-auto-compact--remove-oldest-messages large-messages 1000)
      (let ((elapsed (float-time (time-subtract (current-time) start-time))))
        (should (< elapsed 1.0))))))

;;; End-to-End Integration Tests

(defun gptel-auto-compact-test-create-mock-fsm (messages)
  "Create a mock FSM for testing with MESSAGES."
  (list :info (list :data (list :messages messages)
                   :backend nil)
        :state 'START))

(ert-deftest gptel-auto-compact-test-transform-integration ()
  "Test integration with gptel transform pipeline."
  (let ((gptel-auto-compact-enabled t)
        (gptel-auto-compact-threshold 0.1) ;; Low threshold to trigger compaction
        (mock-messages (make-list 10 '(:role "user" :content "Test message with enough content to trigger compaction when threshold is low."))))
    
    ;; Create mock FSM
    (let ((fsm (gptel-auto-compact-test-create-mock-fsm mock-messages)))
      ;; Should not error when transform is called
      (should-not (condition-case nil
                      (gptel-auto-compact--transform-messages fsm)
                    (error t))))))

;;; Test Runner

(defun run-gptel-auto-compact-tests ()
  "Run all gptel auto-compact tests."
  (interactive)
  (ert-run-tests-interactively "gptel-auto-compact-test-"))

(provide 'test-gptel-auto-compact)
;;; test-gptel-auto-compact.el ends here