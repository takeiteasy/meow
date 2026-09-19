(in-package #:meow/tests)

;;; Ported from patchbay_service_recovery_tests, using the provider/consumer
;;; fixtures from the service tests.

(def-suite :meow/context :in :meow)
(in-suite :meow/context)

(defun start-context (&rest initargs)
  (meow:start-service (apply #'make-instance 'meow:context :name :ctx initargs)))

(defun child-process (context name)
  (second (assoc name (meow:children context) :test #'equal)))

(defun eventually (function &optional (timeout 2))
  "Poll FUNCTION until it returns true or TIMEOUT seconds pass."
  (loop with deadline = (+ (now) timeout)
        for value = (funcall function)
        until (or value (> (now) deadline))
        do (sleep 0.01)
        finally (return value)))

(defun restarted (context name old)
  (eventually (lambda ()
                (let ((process (child-process context name)))
                  (and process (not (eq process old))
                       (meow:process-alive-p process) process)))))

(test relationships-self-heal-after-child-crash
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (p (meow:mount ctx 'provider :reporter (meow:self))))
      (meow:mount ctx 'consumer :reporter (meow:self))
      (is (has (list 'consumer :ready p) (drain)))
      (meow:call p :boom)
      (let ((p2 (restarted ctx 'provider p))
            (messages (drain)))
        (is-true p2)
        (is (find-if (lambda (m)
                       (and (eql 4 (length m))
                            (equal '(consumer :dep-down provider) (subseq m 0 3))
                            (eq :error (first (fourth m)))))
                     messages))
        (is (has (list 'consumer :ready p2) messages))
        (is (eq :pong (meow:call p2 :ping))))
      (stop-and-join ctx))))

(test unmount-is-prompt-and-runs-disposer
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (p (meow:mount ctx 'provider :reporter (meow:self)))
           (start (progn (drain) (now))))
      (is-true (meow:unmount ctx 'provider))
      (is (< (- (now) start) 1))
      (is (equal (list 'provider :disposed :shutdown p) (meow:receive :timeout 1)))
      (is (null (meow:lookup 'provider)))
      (is (null (meow:children ctx)))
      (is (null (meow:unmount ctx 'provider)))
      (stop-and-join ctx))))

(test restart-types
  (loop for (restart reason restarts-p)
          in '((:permanent :normal t) (:permanent :killed t)
               (:transient :normal nil) (:transient :shutdown nil)
               (:transient :killed t)
               (:temporary :killed nil))
        do (with-fresh-registry ()
             (let* ((ctx (start-context))
                    (p (meow:mount ctx 'provider :restart restart)))
               (is (equal (list (list 'provider p restart)) (meow:children ctx)))
               (meow:stop p reason)
               (if restarts-p
                   (is-true (restarted ctx 'provider p) "~s ~s" restart reason)
                   (is-true (eventually (lambda () (null (meow:children ctx))))
                            "~s ~s" restart reason))
               (stop-and-join ctx)))))

(test restart-limit-stops-context-and-children
  (with-fresh-registry ()
    (let* ((ctx (start-context :intensity 2))
           (p (meow:mount ctx 'provider :restart :permanent)))
      (dotimes (i 2)
        (meow:stop p :killed)
        (setf p (restarted ctx 'provider p)))
      (meow:stop p :killed)
      (join ctx)
      (is (eq :restart-limit (meow:process-exit-reason ctx)))
      (is-false (meow:process-alive-p p))
      (is (null (meow:names))))))

(test nested-context-escalates-to-parent
  (with-fresh-registry ()
    (let* ((root (start-context))
           (inner (meow:mount root 'meow:context
                              :name :inner :intensity 0
                              :children '((provider :restart :permanent))))
           (p (child-process inner 'provider)))
      (meow:mount inner 'consumer)
      (meow:stop p :killed)
      (let ((inner2 (restarted root :inner inner)))
        (is-true inner2)
        (is (eq :restart-limit (meow:process-exit-reason inner)))
        (is (equal '(provider) (mapcar #'first (meow:children inner2)))
            "declared children are rebuilt, mounted ones are not")
        (is (meow:process-alive-p (meow:lookup 'provider))))
      (stop-and-join root))))

(test mount-errors-signal-in-caller
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (p (meow:mount ctx 'provider)))
      (signals meow:already-registered (meow:mount ctx 'provider))
      (signals type-error (meow:mount ctx 'provider :restart :sometimes))
      (is (equal (list (list 'provider p :transient)) (meow:children ctx)))
      (stop-and-join ctx))))

(test stopping-context-stops-children-in-reverse-order
  (with-fresh-registry ()
    (let ((ctx (start-context)))
      (meow:mount ctx 'provider :reporter (meow:self))
      (meow:mount ctx 'consumer :reporter (meow:self))
      (drain)
      (stop-and-join ctx)
      (is (equal '(consumer provider)
                 (loop for (name event) in (drain)
                       when (eq event :disposed)
                         collect name)))
      (is (null (meow:names))))))

(test mount-with-invalid-config-signals-in-caller
  (with-fresh-registry ()
    (let ((ctx (start-context)))
      (signals meow:invalid-config (meow:mount ctx 'configured :port 80))
      (signals meow:invalid-config (meow:mount ctx 'meow:context :intensity -1))
      (is (null (meow:children ctx)))
      (stop-and-join ctx))))

(meow:defservice counter (reporting)
  ((count :initform 0 :accessor counter-count)))

(defmethod meow:ready ((s counter))
  (incf (counter-count s))
  (meow:effect s (lambda () (lambda () (report s :released))))
  (report s :ready (counter-count s)))

(defmethod meow:handle ((s counter) message)
  (declare (ignore message))
  s)

(test reload-restarts-same-instance-in-new-process
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (p (meow:mount ctx 'counter :reporter (meow:self) :restart :permanent))
           (instance (meow:call p :self)))
      (is (equal '(counter :ready 1) (meow:receive :timeout 1)))
      (let ((p2 (meow:reload ctx 'counter))
            (messages (drain)))
        (is (not (eq p p2)))
        (is (eq :reload (meow:process-exit-reason p)))
        (is (eq instance (meow:call p2 :self)))
        (is (equal (list '(counter :released)
                         (list 'counter :disposed :reload p)
                         '(counter :ready 2))
                   messages)
            "effects unwind, dispose, then ready with state kept")
        (is (eq p2 (meow:lookup 'counter)) "name survives reload")
        (is (equal (list (list 'counter p2 :permanent)) (meow:children ctx))
            "the old exit is not treated as a crash")
        (is (meow:process-alive-p (meow:reload ctx p2)) "reload by process")
        (is (null (meow:reload ctx 'missing))))
      (stop-and-join ctx))))

(test reload-sends-dep-down-then-ready-to-dependants
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (p (meow:mount ctx 'provider :reporter (meow:self))))
      (meow:mount ctx 'consumer :reporter (meow:self))
      (drain)
      (let* ((p2 (meow:reload ctx 'provider))
             (messages (drain)))
        (is (has '(consumer :dep-down provider :reload) messages))
        (is (has (list 'consumer :ready p2) messages))
        (is (not (has (list 'consumer :ready p) messages))))
      (stop-and-join ctx))))

(defclass versioned (reporting) ())

(defmethod meow:ready ((s versioned))
  (when (slot-exists-p s 'version)
    (report s :ready (slot-value s 'version))))

(defun define-reloadable (&rest options)
  (eval `(meow:defservice reloadable (versioned)
           ,(when (member :v2 options) '((version :initform :v2)))
           ,@(when (member :rejected options)
               '((:validate (lambda (s) (declare (ignore s)) '("rejected"))))))))

(test reload-picks-up-redefined-class
  (with-fresh-registry ()
    (define-reloadable)
    (let* ((ctx (start-context))
           (p (meow:mount ctx 'reloadable :reporter (meow:self))))
      (is (null (drain)))
      (define-reloadable :v2)
      (meow:reload ctx p)
      (is (has '(reloadable :ready :v2) (drain))
          "an added slot gets its initform on the live instance")
      (define-reloadable :v2 :rejected)
      (signals meow:invalid-config (meow:reload ctx 'reloadable))
      (is (null (meow:children ctx)))
      (is (null (meow:lookup 'reloadable)))
      (stop-and-join ctx))))

(test reloaded-context-rebuilds-declared-children
  (with-fresh-registry ()
    (let* ((root (start-context))
           (inner (meow:mount root 'meow:context :name :inner
                                                 :children '((provider)))))
      (meow:mount inner 'consumer)
      (let* ((p (child-process inner 'provider))
             (inner2 (meow:reload root :inner))
             (p2 (child-process inner2 'provider)))
        (is (equal '(provider) (mapcar #'first (meow:children inner2))))
        (is (not (eq p p2)))
        (is (eq p2 (meow:lookup 'provider)))
        (is (null (meow:lookup 'consumer))))
      (stop-and-join root))))

(meow:defservice plugins (meow:context)
  ()
  (:default-initargs :children '((provider :restart :permanent :shutdown 1)
                                 (consumer))))

(test declared-children-are-up-when-started
  (with-fresh-registry ()
    (let ((ctx (meow:start-service (make-instance 'plugins))))
      (is (equal '((provider :permanent) (consumer :transient))
                 (mapcar (lambda (child) (list (first child) (third child)))
                         (meow:children ctx))))
      (is (eq (child-process ctx 'provider) (meow:lookup 'provider)))
      (stop-and-join ctx)
      (is (null (meow:names))))))

(test invalid-child-specs-signal-invalid-config
  (dolist (children '(provider (provider :restart) ((provider :restart :sometimes))
                      (("provider")) ((provider :shutdown -1))))
    (signals meow:invalid-config
      (make-instance 'meow:context :children children))))

(test failing-declared-child-fails-context-start
  (with-fresh-registry ()
    (signals meow:invalid-config
      (start-context :children '((provider) (configured :port 80))))
    (is (null (meow:names)) "children started before the failure are stopped")))

(defun stuck-child (context &rest initargs)
  "Mount a provider and keep it busy for half a second."
  (let ((p (apply #'meow:mount context 'provider initargs)))
    (meow:cast p '(:sleep 0.5))
    p))

(test unmount-reports-a-child-that-misses-its-timeout
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (p (stuck-child ctx)))
      (is (eq :timeout (meow:unmount ctx 'provider :timeout 0.05)))
      (is (null (meow:children ctx)))
      (is (eq p (meow:lookup 'provider)) "still registered until it exits")
      (join p)
      (stop-and-join ctx))))

(test reload-signals-stop-timeout
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (p (stuck-child ctx :shutdown 0.05)))
      (handler-case (progn (meow:reload ctx 'provider) (fail "no error"))
        (meow:stop-timeout (e)
          (is (eq p (meow:stop-timeout-process e)))
          (is (= 0.05 (meow:stop-timeout-seconds e)))))
      (is (null (meow:children ctx)))
      (join p)
      (stop-and-join ctx))))

(test teardown-reports-children-that-miss-their-shutdown
  (with-fresh-registry ()
    (let* ((reports '())
           (ctx (start-context))
           (p (stuck-child ctx :shutdown 0.05)))
      (setf meow:*teardown-error-hook*
            (lambda (condition source)
              (push (list (type-of condition) (meow:service-process source))
                    reports)))
      (unwind-protect (stop-and-join ctx)
        (setf meow:*teardown-error-hook* nil))
      (is (equal (list (list 'meow:stop-timeout ctx)) reports))
      (join p))))
