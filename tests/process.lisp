(in-package #:meow/tests)

(def-suite :meow/process :in :meow)
(in-suite :meow/process)

(test normal-exit
  (let ((p (join (meow:spawn (lambda () 42)))))
    (is-false (meow:process-alive-p p))
    (is (eq :normal (meow:process-exit-reason p)))))

(test error-exit
  (let ((p (join (meow:spawn (lambda () (error "boom"))))))
    (destructuring-bind (tag condition) (meow:process-exit-reason p)
      (is (eq :error tag))
      (is (typep condition 'simple-error)))))

(test explicit-exit
  (let ((p (join (meow:spawn (lambda () (meow:exit :bye) :unreached)))))
    (is (eq :bye (meow:process-exit-reason p)))))

(test self-is-the-process
  (let* ((seen nil)
         (p (join (meow:spawn (lambda () (setf seen (meow:self)))))))
    (is (eq p seen))))

(test send-and-receive-between-processes
  (meow:with-process (me)
    (let ((echo (meow:spawn (lambda ()
                              (destructuring-bind (from msg) (meow:receive)
                                (meow:send from (list :echo msg)))))))
      (meow:send echo (list me :hi))
      (is (equal '(:echo :hi) (meow:receive :timeout 2)))
      (join echo))))

(test send-to-exited-process-is-dropped
  (let ((p (join (meow:spawn (lambda ())))))
    (meow:send p :late)
    (is (null (meow::mailbox-head (meow::process-mailbox p))))))

(test exit-hook-runs-after-death
  (let* ((gate (bt2:make-semaphore))
         (seen nil)
         (p (meow:spawn (lambda () (bt2:wait-on-semaphore gate) (meow:exit :done)))))
    (meow:add-exit-hook p (lambda (proc reason)
                            (setf seen (list (meow:process-alive-p proc) reason))))
    (bt2:signal-semaphore gate)
    (join p)
    (is (equal '(nil :done) seen))))

(test failing-exit-hook-does-not-skip-others
  (let* ((gate (bt2:make-semaphore))
         (seen nil)
         (p (meow:spawn (lambda () (bt2:wait-on-semaphore gate)))))
    (meow:add-exit-hook p (lambda (&rest args)
                            (declare (ignore args))
                            (error "hook failed")))
    (meow:add-exit-hook p (lambda (&rest args)
                            (declare (ignore args))
                            (setf seen t)))
    (let ((*error-output* (make-broadcast-stream)))
      (bt2:signal-semaphore gate)
      (finishes (join p)))
    (is-true seen)))

(test exit-hook-on-dead-process-is-refused
  (let* ((called nil)
         (p (join (meow:spawn (lambda ())))))
    (is (null (meow:add-exit-hook p (lambda (&rest args)
                                      (declare (ignore args))
                                      (setf called t)))))
    (is-false called)))

(test removed-exit-hook-does-not-run
  (let* ((gate (bt2:make-semaphore))
         (called nil)
         (p (meow:spawn (lambda () (bt2:wait-on-semaphore gate))))
         (token (meow:add-exit-hook p (lambda (&rest args)
                                        (declare (ignore args))
                                        (setf called t)))))
    (meow:remove-exit-hook p token)
    (bt2:signal-semaphore gate)
    (join p)
    (is-false called)))

(test with-process-returns-values-and-propagates-errors
  (is (equal '(1 2) (multiple-value-list (meow:with-process (p) (values 1 2)))))
  (let ((process nil))
    (signals simple-error
      (meow:with-process (p)
        (setf process p)
        (error "boom")))
    (is (eq :error (first (meow:process-exit-reason process))))))

(test teardown-error-hook-sees-failing-exit-hook
  (let* ((gate (bt2:make-semaphore))
         (seen nil)
         (p (meow:spawn (lambda () (bt2:wait-on-semaphore gate)))))
    (meow:add-exit-hook p (lambda (&rest args)
                            (declare (ignore args))
                            (error "hook failed")))
    (setf meow:*teardown-error-hook*
          (lambda (condition source) (setf seen (list condition source))))
    (unwind-protect
         (progn (bt2:signal-semaphore gate)
                (join p))
      (setf meow:*teardown-error-hook* nil))
    (is (typep (first seen) 'error))
    (is (eq p (second seen)))))

(test failing-teardown-error-hook-falls-back-to-printing
  (let* ((gate (bt2:make-semaphore))
         (seen nil)
         (p (meow:spawn (lambda () (bt2:wait-on-semaphore gate)))))
    (meow:add-exit-hook p (lambda (&rest args)
                            (declare (ignore args))
                            (error "hook failed")))
    (meow:add-exit-hook p (lambda (&rest args)
                            (declare (ignore args))
                            (setf seen t)))
    (setf meow:*teardown-error-hook*
          (lambda (&rest args) (declare (ignore args)) (error "hook hook failed")))
    (unwind-protect
         (progn (bt2:signal-semaphore gate)
                (finishes (join p)))
      (setf meow:*teardown-error-hook* nil))
    (is-true seen)))
