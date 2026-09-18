(in-package #:meow/tests)

(def-suite :meow/effect :in :meow)
(in-suite :meow/effect)

(meow:defservice effectful (reporting)
  ((releases :initform '() :accessor releases)))

(meow:defservice effectful-context (reporting meow:context) ())

(defun acquire (service tag)
  (meow:effect service (lambda ()
                         (lambda () (report service :released tag)))))

(defmethod meow:handle ((s effectful) message)
  (destructuring-bind (tag &optional arg) (if (consp message) message (list message))
    (ecase tag
      (:acquire (push (cons arg (acquire s arg)) (releases s)) :ok)
      (:release (funcall (cdr (assoc arg (releases s)))) :ok)
      (:failing (meow:effect s (lambda () (lambda () (error "disposer failed"))))
       :ok)
      (:nil-effect (meow:effect s (constantly nil)) :ok)
      (:with (meow:with-effect (resource s arg)
               (report s :released resource)))
      (:boom (error "boom")))))

(defmethod meow:ready ((s effectful-context))
  (acquire s :context))

(test effects-unwind-lifo-before-dispose
  (with-fresh-registry ()
    (let ((p (start 'effectful)))
      (meow:call p '(:acquire 1))
      (meow:call p '(:acquire 2))
      (stop-and-join p)
      (is (equal (list '(effectful :released 2)
                       '(effectful :released 1)
                       (list 'effectful :disposed :shutdown p))
                 (drain))))))

(test effects-unwind-on-crash
  (with-fresh-registry ()
    (let ((p (start 'effectful)))
      (meow:call p '(:acquire 1))
      (meow:call p :boom)
      (join p)
      (let ((messages (drain)))
        (is (equal '(effectful :released 1) (first messages)))
        (is (eq :error (first (third (second messages)))))))))

(test early-release-runs-once
  (with-fresh-registry ()
    (let ((p (start 'effectful)))
      (meow:call p '(:acquire 1))
      (meow:call p '(:release 1))
      (is (equal '((effectful :released 1)) (drain)))
      (meow:call p '(:release 1))
      (is (null (drain)))
      (stop-and-join p)
      (is (equal (list (list 'effectful :disposed :shutdown p)) (drain))))))

(test nil-disposer-is-not-pushed
  (with-fresh-registry ()
    (multiple-value-bind (p service) (start 'effectful)
      (meow:call p :nil-effect)
      (is (null (slot-value service 'meow::effects)))
      (stop-and-join p))))

(test failing-disposer-does-not-stop-unwinding
  (with-fresh-registry ()
    (let ((p (start 'effectful)))
      (meow:call p '(:acquire 1))
      (meow:call p :failing)
      (meow:call p '(:acquire 2))
      (stop-and-join p)
      (is (equal (list '(effectful :released 2)
                       '(effectful :released 1)
                       (list 'effectful :disposed :shutdown p))
                 (drain))))))

(defmacro with-teardown-errors (&body body)
  "Run BODY with *TEARDOWN-ERROR-HOOK* sending (condition source) to the
current process."
  `(let ((me (meow:self)))
     (setf meow:*teardown-error-hook*
           (lambda (condition source) (meow:send me (list condition source))))
     (unwind-protect (progn ,@body)
       (setf meow:*teardown-error-hook* nil))))

(test teardown-error-hook-sees-failing-disposer
  (with-fresh-registry ()
    (multiple-value-bind (p service) (start 'effectful)
      (meow:call p :failing)
      (with-teardown-errors
        (stop-and-join p))
      (destructuring-bind ((condition source) disposed) (drain)
        (is (typep condition 'error))
        (is (eq service source))
        (is (equal (list 'effectful :disposed :shutdown p) disposed))))))

(test with-effect-binds-and-releases
  (with-fresh-registry ()
    (let ((p (start 'effectful)))
      (is (eq :res (meow:call p '(:with :res))))
      (stop-and-join p)
      (is (equal (list '(effectful :released :res)
                       (list 'effectful :disposed :shutdown p))
                 (drain))))))

(test effect-requires-own-process
  (with-fresh-registry ()
    (multiple-value-bind (p service) (start 'effectful)
      (let ((acquired nil))
        (signals error (meow:effect service (lambda () (setf acquired t) nil)))
        (is-false acquired))
      (stop-and-join p))))

(test context-stops-children-before-its-effects
  (with-fresh-registry ()
    (let* ((ctx (meow:start-service
                 (make-instance 'effectful-context :reporter (meow:self))))
           (p (meow:mount ctx 'provider :reporter (meow:self))))
      (drain)
      (stop-and-join ctx)
      (is (equal (list (list 'provider :disposed :shutdown p)
                       '(effectful-context :released :context)
                       (list 'effectful-context :disposed :shutdown ctx))
                 (drain))))))
