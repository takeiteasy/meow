(in-package #:meow)

(defun %now ()
  (/ (get-internal-real-time) internal-time-units-per-second))

(defun %wait-until (lock cv predicate timeout)
  "With LOCK held, wait on CV until PREDICATE returns true or TIMEOUT seconds
pass (nil waits forever). Returns PREDICATE's value, or nil on timeout."
  (loop with deadline = (and timeout (+ (%now) timeout))
        for value = (funcall predicate)
        when value
          return value
        do (if deadline
               (let ((remaining (- deadline (%now))))
                 (when (<= remaining 0)
                   (return nil))
                 (bt2:condition-wait cv lock :timeout (float remaining 1d0)))
               (bt2:condition-wait cv lock))))

(defstruct (mailbox (:constructor make-mailbox ()))
  (lock (bt2:make-lock :name "mailbox") :read-only t)
  (cv (bt2:make-condition-variable) :read-only t)
  (head nil)
  (tail nil))

(defun mailbox-send (mailbox message)
  "Append MESSAGE to MAILBOX. Never blocks."
  (let ((cell (list message)))
    (bt2:with-lock-held ((mailbox-lock mailbox))
      (if (mailbox-tail mailbox)
          (setf (cdr (mailbox-tail mailbox)) cell)
          (setf (mailbox-head mailbox) cell))
      (setf (mailbox-tail mailbox) cell)
      (bt2:condition-notify (mailbox-cv mailbox))))
  message)

(defun mailbox-receive (mailbox &key timeout)
  "Pop the oldest message, waiting up to TIMEOUT seconds (nil waits forever).
Returns (values message t), or (values nil nil) on timeout."
  (bt2:with-lock-held ((mailbox-lock mailbox))
    (if (%wait-until (mailbox-lock mailbox) (mailbox-cv mailbox)
                     (lambda () (mailbox-head mailbox))
                     timeout)
        (let ((message (pop (mailbox-head mailbox))))
          (unless (mailbox-head mailbox)
            (setf (mailbox-tail mailbox) nil))
          (values message t))
        (values nil nil))))
