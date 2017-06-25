;;; unrepl.el --- Clojure unrepl client              -*- lexical-binding: t; -*-

;; Copyright (C) 2017  Arne Brasseur

;; Author: Arne Brasseur <arne@arnebrasseur.net>
;; Keywords: tools, lisp, comm
;; Package-Requires: ((clojure-mode "") (dash "") (let-alist "") (peg "0.6") (edn ""))

;; This program is free software; you can redistribute it and/or modify it under
;; the terms of the Mozilla Public License Version 2.0

;; This program is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
;; FOR A PARTICULAR PURPOSE. See the GNU General Public License for more
;; details.

;; You should have received a copy of the Mozilla Public License along with this
;; program. If not, see <https://www.mozilla.org/media/MPL/2.0/index.txt>.

;;; Commentary:

;; A client for the unrepl protocol, for interactive Clojure development

;;; Code:

(require 'let-alist)
(require 'clojure-mode)
(require 'dash)
(require 'ansi-color)

(require 'unrepl-reader)
(require 'unrepl-writer)

(defvar unrepl-blob-path
  (expand-file-name "blob.clj" (file-name-directory load-file-name))
  "Path to the unrepl 'upgrade blob', created with `lein unrepl-make-blob'.")

(defvar-local unrepl-input-start-mark nil)
(defvar-local unrepl-prompt-end-mark nil)
(defvar-local unrepl-hello-payload nil)
(defvar-local unrepl-buffer-type nil)

(defvar unrepl-connections nil
  "List of unrepl connection objects")

(defvar-local unrepl-connection nil
  "Connection used by the current buffer. An alist of process, repl-buffer, output-buffer, position, eval-handlers.")

;; borrowed from CIDER
(defun unrepl-defun-at-point (&optional bounds)
  "Return the text of the top level sexp at point.
If BOUNDS is non-nil, return a list of its starting and ending position
instead."
  (save-excursion
    (save-match-data
      (end-of-defun)
      (let ((end (point)))
        (clojure-backward-logical-sexp 1)
        (funcall (if bounds #'list #'buffer-substring-no-properties)
                 (point) end)))))

;; borrowed from CIDER
(defun unrepl-last-sexp (&optional bounds)
  "Return the sexp preceding the point.
If BOUNDS is non-nil, return a list of its starting and ending position
instead."
  (apply (if bounds #'list #'buffer-substring-no-properties)
         (save-excursion
           (clojure-backward-logical-sexp 1)
           (list (point)
                 (progn (clojure-forward-logical-sexp 1)
                        (skip-chars-forward "[:blank:]")
                        (when (looking-at-p "\n") (forward-char 1))
                        (point))))))

(defun unrepl--read-blob ()
  (with-temp-buffer
    (insert-file-contents unrepl-blob-path)
    (buffer-string)))

(defun unrepl--insert-with-face (str face)
  (put-text-property 0 (length str) 'face face str)
  (insert str))

(defun unrepl--history-idx (key value)
  (let* ((conn (unrepl--connection))
         (history (cdr (assq 'history conn))))
    (seq-position history value
                  (lambda (x y)
                    (eq (cdr (assq key x)) y)))))

(defun unrepl--history-by (key value)
  (seq-elt (cdr (assq 'history (unrepl--connection)))
           (unrepl--history-idx key value)))

(cl-defmethod (setf unrepl--history-by) (cmd key value)
  (setf (seq-elt (cdr (assq 'history (unrepl--connection)))
                 (unrepl--history-idx key value))
        cmd))

(defun unrepl--handle-hello (payload)
  (setq unrepl-hello-payload payload))

(defun unrepl--handle-prompt (payload)
  (when (not (eq (current-column) 0))
    (unrepl--insert-with-face "%" 'custom-set)
    (insert "\n"))
  (unrepl--insert-prompt
   (symbol-name
    (third (gethash 'clojure.core/*ns* payload)))))

(defun unrepl--handle-out (payload)
  (if (eq (current-column) 0)
      (unrepl--insert-with-face "#_out| " 'font-lock-constant-face))
  (insert (ansi-color-apply payload)))

(defun unrepl--handle-err (payload)
  (if (eq (current-column) 0)
      (unrepl--insert-with-face "#_err| " 'font-lock-warning-face))
  (insert (ansi-color-apply payload)))

;; [:read {:from [2 1], :to [3 1], :offset 8, :len 8} 2]
(defun unrepl--handle-read (form)
  (seq-let [_ pos-info id] form
    (let* ((offset (gethash :offset pos-info)))
      (push (cons 'id id) (unrepl--history-by 'position offset)))))

;; [:started-eval {:actions {:interrupt (unrepl.replG__1801/interrupt! :session2160 2), :background (unrepl.replG__1801/background! :session2160 2)}} 2]
(defun unrepl--handle-started-eval (payload))

;; [:eval #_result 14 #_id 2]
(defun unrepl--handle-eval (form)
  (seq-let [_ result id] form
    (push (cons 'result result) (unrepl--history-by 'id id))
    (funcall (cdr (assq 'handler (unrepl--history-by 'id id))) result))

  ;; (when (not (eq (current-column) 0))
  ;;   ;; taken out because when evaluating forms from the repl it would show up
  ;;   ;; for no good reason
  ;;   ;; (unrepl--insert-with-face "%" 'custom-set)
  ;;   (insert "\n"))
  ;;(unrepl--write payload)
  ;;(insert "\n")
  )

(defun unrepl--handle-bye (payload))

(defun unrepl--handle-log (payload))

(defun unrepl--handle-exception (payload)
  (if (not (eq (current-column) 0))
      (insert "\n"))
  (unrepl--insert-with-face "#_exception| " 'font-lock-warning-face)
  (insert (gethash :cause (gethash :ex payload))))

(defun unrepl-edn-handler (form)
  ;;(message (concat "->" (prin1-to-string form)))
  (let-alist (unrepl--connection)
    (with-current-buffer .repl-buffer
      (let ((tag (elt form 0))
            (payload (elt form 1)))
        (case tag
          (:unrepl/hello (unrepl--handle-hello payload))
          (:prompt (unrepl--handle-prompt payload))
          (:read (unrepl--handle-read form))
          (:started-eval (unrepl--handle-started-eval form))
          (:eval (unrepl--handle-eval form))
          (:out (unrepl--handle-out payload))
          (:err (unrepl--handle-err payload))
          (:bye (unrepl--handle-bye payload))
          (:log (unrepl--handle-log payload))
          (:exception (unrepl--handle-exception payload)))))))

(defun unrepl-handle-output (proc string)
  (let-alist (unrepl--connection)
    (with-current-buffer .output-buffer
      (goto-char (point-max))
      (let ((orig-point (point)))
        (insert string)
        (goto-char orig-point)
        ;;(message (prin1-to-string (list :ok orig-point (eq orig-point 0) string)))

        (when (eq orig-point 1)
          (right-char 7)
          (process-send-string .process (unrepl--read-blob))
          ;; (search-forward "[:unrepl/hello")
          ;; (left-char (length "[:unrepl/hello"))
          )

        (let ((form (unrepl--edn-read)))
          ;;(prin1 (list "=>" form))
          (while form
            (unrepl-edn-handler form)
            (setq form (unrepl--edn-read))))))))

(defun unrepl-process-sentinel (proc event)
  ;;(message (concat "EVT->" (prin1-to-string event)))
  )

(defun unrepl--insert-prompt (namespace)
  (goto-char (point-max))
  (if (not (eq (current-column) 0))
      (insert "\n"))
  (let ((prompt-start (point)))
    (insert (concat namespace "=> "))
    (setq unrepl-input-start-mark (point))
    (setq unrepl-prompt-end-mark (point))
    (add-text-properties prompt-start (point)
                         '(font-lock-face font-lock-keyword-face
                           read-only t
                           intangible t
                           front-sticky t
                           rear-nonsticky t))))


(defun unrepl--connection ()
  ;; TODO make this smarter, so buffers find the most suitable connection based
  ;; on path/project
  (or unrepl-connection (first unrepl-connections)))



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Commands and Modes

(defun unrepl-repl-return ()
  (interactive)
  (when (eq (point) (line-end-position))
    (let-alist (unrepl--connection)
      (message "before")
      (let ((inhibit-read-only t))
        (add-text-properties unrepl-prompt-end-mark (point-max)
                             '(read-only t
                               front-sticky t
                               rear-nonsticky t)))
      (message "after")
      (insert "\n")
      (message "newline")
      (let ((cmd (buffer-substring-no-properties unrepl-input-start-mark (point-max))))
        (setq unrepl-input-start-mark (point))
        (unrepl-eval cmd #'unrepl--write)))))

(defun unrepl-eval (form handler)
  (message "Eval %S" form)
  (let* ((connection (unrepl--connection))
         (position   (assq 'position connection))
         (history    (assq 'history connection))
         (process    (assq 'process connection)))
    (push `((position . ,(cdr position))
            (form . ,form)
            (handler . ,handler))
          (cdr history))
    (process-send-string (cdr process) form)
    (setcdr position (+ (length form) (cdr position)))))

(defun unrepl-connect (host-port)
  (interactive "MSocket repl host/port: ")

  (let* ((host-port (s-split ":" host-port))
         (host-given? (= (length host-port) 2))
         (host (if host-given?
                   (first host-port)
                 "localhost"))
         (port (string-to-number
                (if host-given?
                    (second host-port)
                  (first host-port))))
         (output-buffer-name (if unrepl-connections
                                 (concat "*unrepl-output<" (number-to-string (1+ (length unrepl-connections))) ">*")
                               "*unrepl-output*"))
         (repl-buffer-name (if unrepl-connections
                               (concat "*unrepl-repl<" (number-to-string (1+ (length unrepl-connections))) ">*")
                             "*unrepl-repl*")))

    (when (get-buffer output-buffer-name)
      (kill-buffer output-buffer-name))

    (let* ((process (make-network-process
                     :name "unrepl"
                     :buffer output-buffer-name
                     :host host
                     :service port
                     :filter #'unrepl-handle-output
                     :sentinel #'unrepl-process-sentinel))
           (repl-buffer (get-buffer-create repl-buffer-name))
           (output-buffer (get-buffer output-buffer-name))
           (connection `((process . ,process)
                         (repl-buffer . ,repl-buffer)
                         (output-buffer . ,output-buffer)
                         (position . 0)
                         (history . nil))))

      (with-current-buffer output-buffer
        (setq unrepl-connection connection)
        (setq unrepl-buffer-type 'process))

      (with-current-buffer repl-buffer
        (unrepl-repl-mode)
        (setq unrepl-connection connection)
        (setq unrepl-buffer-type 'repl))

      (push connection unrepl-connections)
      (switch-to-buffer repl-buffer))))

(defun unrepl-eval-last-sexp ()
  (interactive)
  (let-alist (unrepl--connection)
    (process-send-string .process (concat (unrepl-last-sexp) "\n"))))

(defun unrepl-eval-defun ()
  (interactive)
  (let-alist (unrepl--connection)
    (process-send-string .process (concat (unrepl-defun-at-point) "\n"))))

(defun unrepl-close-all ()
  (interactive)
  (-map (lambda (conn)
          (let-alist conn
            (kill-buffer .repl-buffer)
            (kill-buffer .output-buffer)))
        unrepl-connections)
  (setq unrepl-connections nil))

(defvar unrepl-repl-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'unrepl-repl-return)
    map))

(define-derived-mode unrepl-repl-mode fundamental-mode "Unrepl")

(defvar unrepl-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-x C-e") #'unrepl-eval-last-sexp)
    map))

;;;###autoload
(define-minor-mode unrepl-mode
  "Minor mode to get evaluation capabilities in source buffers."
  nil
  " UN"
  unrepl-mode-map)


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Hooks

(defun unrepl--kill-buffer-hook-handler ()
  "Clean up when closing either the repl or the output/process
buffer. Close the other buffer, and remove the connection from
the list."
  (when (or (eq unrepl-buffer-type 'repl) (eq unrepl-buffer-type 'process))
    (let-alist (unrepl--connection)
      (delete-process .process)
      (setq unrepl-connections (-remove (lambda (conn)
                                          (eq conn (unrepl--connection)))
                                        unrepl-connections))
      (if (eq unrepl-buffer-type 'repl)
          (with-current-buffer .output-buffer
            (setq unrepl-buffer-type nil)
            (kill-buffer .output-buffer))
        (with-current-buffer .repl-buffer
          (setq unrepl-buffer-type nil)
          (kill-buffer .repl-buffer))))))

(add-hook 'kill-buffer-hook 'unrepl--kill-buffer-hook-handler)

(provide 'unrepl)
;;; unrepl.el ends here
