(in-package #:meow/tests)

;;; bt2 timed condition-wait is what every call timeout rests on.

(def-suite :meow/condvar :in :meow)
(in-suite :meow/condvar)

(defun lock-held-elsewhere-p (lock)
  "True when another thread cannot take LOCK right now."
  (let ((acquired nil))
    (bt2:join-thread
     (bt2:make-thread (lambda ()
                        (when (bt2:acquire-lock lock :wait nil)
                          (setf acquired t)
                          (bt2:release-lock lock)))))
    (not acquired)))

(defun wait-for (lock cv predicate timeout)
  "Deadline loop that tolerates spurious wakeups. Call with LOCK held."
  (loop with deadline = (+ (now) timeout)
        until (funcall predicate)
        do (let ((remaining (- deadline (now))))
             (when (<= remaining 0)
               (return nil))
             (bt2:condition-wait cv lock :timeout remaining))
        finally (return t)))

(test timed-wait-expires
  (let ((lock (bt2:make-lock))
        (cv (bt2:make-condition-variable)))
    (bt2:with-lock-held (lock)
      (let* ((start (now))
             (result (bt2:condition-wait cv lock :timeout 0.2))
             (elapsed (- (now) start)))
        (is (null result))
        (is (<= 0.19 elapsed 1.0) "elapsed ~,3fs" elapsed)
        (is (lock-held-elsewhere-p lock))))))

(test timed-wait-expires-repeatedly
  (let ((lock (bt2:make-lock))
        (cv (bt2:make-condition-variable)))
    (bt2:with-lock-held (lock)
      (let ((elapsed (loop repeat 20
                           collect (let ((start (now)))
                                     (bt2:condition-wait cv lock :timeout 0.01)
                                     (- (now) start)))))
        (is (every (lambda (e) (<= 0.009 e 0.5)) elapsed)
            "elapsed ~a" elapsed)
        (is (lock-held-elsewhere-p lock))))))

(test notify-wakes-before-timeout
  (let* ((lock (bt2:make-lock))
         (cv (bt2:make-condition-variable))
         (flag nil)
         (waiter (bt2:make-thread
                  (lambda ()
                    (bt2:with-lock-held (lock)
                      (let ((start (now)))
                        (list (wait-for lock cv (lambda () flag) 5)
                              (- (now) start))))))))
    (sleep 0.05)
    (bt2:with-lock-held (lock)
      (setf flag t)
      (bt2:condition-notify cv))
    (destructuring-bind (woke elapsed) (bt2:join-thread waiter)
      (is-true woke)
      (is (< elapsed 1) "elapsed ~,3fs" elapsed))))

(test deadline-survives-spurious-wakeups
  (let* ((lock (bt2:make-lock))
         (cv (bt2:make-condition-variable))
         (stop nil)
         (noise (bt2:make-thread
                 (lambda ()
                   (loop until stop
                         do (bt2:with-lock-held (lock)
                              (bt2:condition-broadcast cv))
                            (sleep 0.01))))))
    (unwind-protect
         (bt2:with-lock-held (lock)
           (let* ((start (now))
                  (result (wait-for lock cv (constantly nil) 0.3))
                  (elapsed (- (now) start)))
             (is (null result))
             (is (<= 0.29 elapsed 1.5) "elapsed ~,3fs" elapsed)))
      (setf stop t)
      (bt2:join-thread noise))))
