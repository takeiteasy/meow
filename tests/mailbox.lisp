(in-package #:meow/tests)

(def-suite :meow/mailbox :in :meow)
(in-suite :meow/mailbox)

(test mailbox-is-fifo
  (let ((mb (meow::make-mailbox)))
    (dolist (m '(1 2 3))
      (meow::mailbox-send mb m))
    (is (equal '(1 2 3)
               (loop repeat 3 collect (meow::mailbox-receive mb :timeout 0))))))

(test mailbox-distinguishes-nil-from-timeout
  (let ((mb (meow::make-mailbox)))
    (meow::mailbox-send mb nil)
    (is (equal '(nil t) (multiple-value-list (meow::mailbox-receive mb :timeout 0))))
    (is (equal '(nil nil) (multiple-value-list (meow::mailbox-receive mb :timeout 0))))))

(test mailbox-receive-times-out
  (let ((mb (meow::make-mailbox))
        (start (now)))
    (is (null (nth-value 1 (meow::mailbox-receive mb :timeout 0.1))))
    (is (<= 0.09 (- (now) start) 1))))

(test mailbox-receive-wakes-on-send
  (let* ((mb (meow::make-mailbox))
         (receiver (bt2:make-thread
                    (lambda () (meow::mailbox-receive mb :timeout 5)))))
    (sleep 0.05)
    (meow::mailbox-send mb :hello)
    (is (eq :hello (bt2:join-thread receiver)))))
