(in-package #:meow/tests)

;;; Ported from patchbay_service_recovery_tests, using the provider/consumer
;;; fixtures from the service tests.

(def-suite :meow/context :in :meow)
(in-suite :meow/context)

(defun start-context (&rest initargs)
  (meow:start-service (apply #'make-instance 'meow:context :name :ctx initargs)))

(defun child-summary (context)
  "(name process restart) for each child of CONTEXT."
  (mapcar (lambda (child)
            (list (getf child :name) (getf child :process) (getf child :restart)))
          (meow:children context)))

(defun child-process (context name)
  (second (assoc name (child-summary context) :test #'equal)))

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
               (is (equal (list (list 'provider p restart)) (child-summary ctx)))
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
        (is (equal '(provider) (mapcar #'first (child-summary inner2)))
            "declared children are rebuilt, mounted ones are not")
        (is (meow:process-alive-p (meow:lookup 'provider))))
      (stop-and-join root))))

(test mount-errors-signal-in-caller
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (p (meow:mount ctx 'provider)))
      (signals meow:already-registered (meow:mount ctx 'provider))
      (signals type-error (meow:mount ctx 'provider :restart :sometimes))
      (is (equal (list (list 'provider p :transient)) (child-summary ctx)))
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
      (signals meow:invalid-config
        (meow:mount ctx 'meow:context :restart-delay -1))
      (signals type-error (meow:mount ctx 'provider :backoff -1))
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
        (is (equal (list (list 'counter p2 :permanent)) (child-summary ctx))
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
        (is (equal '(provider) (mapcar #'first (child-summary inner2))))
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
                         (child-summary ctx))))
      (is (eq (child-process ctx 'provider) (meow:lookup 'provider)))
      (stop-and-join ctx)
      (is (null (meow:names))))))

(test invalid-child-specs-signal-invalid-config
  (dolist (children '(provider ((provider :restart)) ((provider :restart :sometimes))
                      (("provider")) ((provider :shutdown -1))
                      ((provider :shutdown :forever))
                      ((provider :backoff -1))
                      ((provider :backoff-max :soon))))
    (signals meow:invalid-config
      (make-instance 'meow:context :children children))))

(test failing-declared-child-fails-context-start
  (with-fresh-registry ()
    (signals meow:invalid-config
      (start-context :children '((provider) (configured :port 80))))
    (is (null (meow:names)) "children started before the failure are stopped")))

;;; Stopping and kill escalation

(defun stuck-child (context &rest initargs)
  "Mount a provider and keep it busy in handle for half a second."
  (let ((p (apply #'meow:mount context 'provider initargs)))
    (meow:cast p '(:sleep 0.5))
    p))

(meow:defservice stubborn (reporting) ())

(defmethod meow:dispose :before ((s stubborn) reason)
  (declare (ignore reason))
  (sleep 0.5))

(test unmount-kills-a-child-that-misses-its-timeout
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (p (stuck-child ctx :reporter (meow:self)))
           (start (progn (drain) (now))))
      (is (eq :killed (meow:unmount ctx 'provider :timeout 0.05)))
      (is (< (- (now) start) 0.4))
      (is (eq :killed (meow:process-exit-reason p)))
      (is (equal (list 'provider :disposed :killed p) (meow:receive :timeout 1)))
      (is (null (meow:lookup 'provider)))
      (is (null (meow:children ctx)))
      (stop-and-join ctx))))

(test unmount-reports-a-child-stuck-in-dispose
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (p (meow:mount ctx 'stubborn)))
      (is (eq :timeout (meow:unmount ctx 'stubborn :timeout 0.05)))
      (is (null (meow:children ctx)))
      (is (eq p (meow:lookup 'stubborn)) "still registered until it exits")
      (join p)
      (is (eq :shutdown (meow:process-exit-reason p)))
      (stop-and-join ctx))))

(test reload-kills-a-stuck-child
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (p (stuck-child ctx :shutdown 0.05))
           (p2 (meow:reload ctx 'provider)))
      (is (eq :killed (meow:process-exit-reason p)))
      (is (eq :pong (meow:call p2 :ping)))
      (is (eq p2 (meow:lookup 'provider)))
      (stop-and-join ctx))))

(test reload-signals-stop-timeout
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (p (meow:mount ctx 'stubborn :shutdown 0.05)))
      (handler-case (progn (meow:reload ctx 'stubborn) (fail "no error"))
        (meow:stop-timeout (e)
          (is (eq p (meow:stop-timeout-process e)))
          (is (= 0.05 (meow:stop-timeout-seconds e)))))
      (is (null (meow:children ctx)))
      (join p)
      (stop-and-join ctx))))

(defmacro with-teardown-reports ((var) &body body)
  "Run BODY with VAR collecting (condition-type process) teardown reports."
  `(let ((,var '()))
     (setf meow:*teardown-error-hook*
           (lambda (condition source)
             (push (list (type-of condition) (meow:service-process source))
                   ,var)))
     (unwind-protect (progn ,@body)
       (setf meow:*teardown-error-hook* nil))))

(test teardown-kills-stuck-children
  (with-fresh-registry ()
    (with-teardown-reports (reports)
      (let* ((ctx (start-context))
             (p (stuck-child ctx :shutdown 0.05)))
        (stop-and-join ctx)
        (is (null reports))
        (is (eq :killed (meow:process-exit-reason p)))
        (is (null (meow:names)))))))

(test teardown-reports-children-that-miss-their-shutdown
  (with-fresh-registry ()
    (with-teardown-reports (reports)
      (let* ((ctx (start-context))
             (p (meow:mount ctx 'stubborn :shutdown 0.05)))
        (stop-and-join ctx)
        (is (equal (list (list 'meow:stop-timeout ctx)) reports))
        (join p)))))

(test unmount-waits-for-an-infinite-shutdown
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (p (meow:mount ctx 'provider :shutdown :infinity))
           (start (now)))
      (meow:cast p '(:sleep 0.3))
      (is (eq t (meow:unmount ctx 'provider)))
      (is (<= 0.3 (- (now) start)))
      (is (eq :shutdown (meow:process-exit-reason p)))
      (stop-and-join ctx))))

(test unmount-timeout-still-kills-an-infinite-shutdown
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (p (stuck-child ctx :shutdown :infinity)))
      (is (eq :killed (meow:unmount ctx 'provider :timeout 0.05)))
      (is (eq :killed (meow:process-exit-reason p)))
      (stop-and-join ctx))))

(test invalid-stop-timeouts-signal-in-caller
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (p (meow:mount ctx 'provider)))
      (signals type-error (meow:unmount ctx 'provider :timeout :infinite))
      (signals type-error (meow:reload ctx 'provider :timeout -1))
      (is (meow:process-alive-p ctx))
      (is (eq p (child-process ctx 'provider)))
      (stop-and-join ctx))))

(test teardown-waits-for-an-infinite-shutdown
  (with-fresh-registry ()
    (with-teardown-reports (reports)
      (let* ((ctx (start-context))
             (p (stuck-child ctx :shutdown :infinity)))
        (stop-and-join ctx)
        (is (null reports))
        (is (eq :shutdown (meow:process-exit-reason p)))))))

(test stuck-declared-child-does-not-block-context-restart
  (with-fresh-registry ()
    (let* ((root (start-context))
           (inner (meow:mount root 'meow:context
                              :name :inner :restart :permanent
                              :children '((provider :shutdown 0.05)))))
      (meow:cast (child-process inner 'provider) '(:sleep 0.5))
      (meow:stop inner :killed)
      (let ((inner2 (restarted root :inner inner)))
        (is-true inner2)
        (is (eq :pong (meow:call (child-process inner2 'provider) :ping))))
      (is (null (drain 0.5)) "the killed provider sends nothing more")
      (stop-and-join root))))

;;; Restart backoff

(defun restart-times (context name count)
  "Kill NAME COUNT times, returning the seconds each restart took."
  (loop repeat count
        collect (let ((p (child-process context name))
                      (start (now)))
                  (meow:stop p :killed)
                  (restarted context name p)
                  (- (now) start))))

(test restart-delay-is-fixed-without-a-max
  (with-fresh-registry ()
    (let* ((ctx (start-context :restart-delay 0.2))
           (p (meow:mount ctx 'provider :restart :permanent))
           (start (now)))
      (meow:stop p :killed)
      (sleep 0.1)
      (is (eq p (child-process ctx 'provider)) "the mailbox is not blocked")
      (is-true (restarted ctx 'provider p))
      (is (<= 0.2 (- (now) start)))
      (is (every (lambda (time) (<= 0.2 time 0.35))
                 (restart-times ctx 'provider 2)))
      (stop-and-join ctx))))

(test restart-delay-doubles-up-to-max
  (with-fresh-registry ()
    (let ((ctx (start-context :restart-delay 0.05 :restart-delay-max 0.2
                              :intensity 10)))
      (meow:mount ctx 'provider :restart :permanent)
      (is (every #'<= '(0.05 0.1 0.2 0.2)
                 (restart-times ctx 'provider 4)))
      (stop-and-join ctx))))

(test child-restart-delay-overrides-context
  (with-fresh-registry ()
    (let ((ctx (start-context :restart-delay 1)))
      (meow:mount ctx 'provider :restart :permanent :backoff 0)
      (meow:mount ctx 'consumer :restart :permanent :backoff 0.1
                                :backoff-max 0.1)
      (is (every (lambda (time) (< time 0.1))
                 (restart-times ctx 'provider 2)))
      (is (every (lambda (time) (<= 0.1 time 0.9))
                 (restart-times ctx 'consumer 2)))
      (stop-and-join ctx))))

(test children-shows-a-pending-restart
  (with-fresh-registry ()
    (let* ((ctx (start-context :restart-delay 0.3))
           (p (meow:mount ctx 'provider :restart :permanent)))
      (is (equal (list :name 'provider :process p :restart :permanent
                       :state :running :restart-in nil)
                 (first (meow:children ctx))))
      (meow:stop p :killed)
      (let ((child (eventually (lambda ()
                                 (let ((child (first (meow:children ctx))))
                                   (and (eq :restarting (getf child :state))
                                        child))))))
        (is (eq p (getf child :process)))
        (is (< 0 (getf child :restart-in) 0.3001)))
      (let ((p2 (restarted ctx 'provider p)))
        (is (equal (list :state :running :restart-in nil)
                   (last (first (meow:children ctx)) 4)))
        (is-true p2))
      (stop-and-join ctx))))

(test unmount-cancels-a-pending-restart
  (with-fresh-registry ()
    (let* ((ctx (start-context :restart-delay 0.1))
           (p (meow:mount ctx 'provider :restart :permanent)))
      (meow:stop p :killed)
      (join p)
      (is-true (meow:unmount ctx 'provider))
      (sleep 0.2)
      (is (null (meow:children ctx)))
      (is (null (meow:lookup 'provider)))
      (stop-and-join ctx))))

(test failed-restart-is-retried-after-the-delay
  (with-fresh-registry ()
    (let* ((ctx (start-context :restart-delay 0.1))
           (p (meow:mount ctx 'provider :restart :permanent)))
      (meow:stop p :killed)
      (join p)
      (meow:register 'provider (meow:self))
      (sleep 0.25)
      (is (eq p (child-process ctx 'provider)) "start failed and was retried")
      (is (meow:process-alive-p ctx))
      (meow:unregister 'provider)
      (let ((p2 (restarted ctx 'provider p)))
        (is-true p2)
        (is (eq p2 (meow:lookup 'provider))))
      (stop-and-join ctx))))

(test failed-restarts-without-delay-reach-the-limit
  (with-fresh-registry ()
    (define-reloadable)
    (let* ((ctx (start-context :intensity 50))
           (p (meow:mount ctx 'reloadable :restart :permanent)))
      (define-reloadable :rejected)
      (meow:stop p :killed)
      (join ctx)
      (is (eq :restart-limit (meow:process-exit-reason ctx))))
    (define-reloadable)))

(meow:defservice tunable (reporting)
  ((level :initarg :level :initform 1 :type integer :reader level)))

(defmethod meow:ready ((s tunable))
  (report s :ready (level s)))

(defmethod meow:handle ((s tunable) message)
  (if (eq message :update-self)
      (handler-case (meow:update (meow:service-process (meow:service-context s))
                                 (meow:service-name s) :level 9)
        (error (e) e))
      (level s)))

(meow:defservice live-tunable (tunable) ())

(defmethod meow:update-config ((s live-tunable) old new)
  (report s :update (getf old :level) (getf new :level))
  t)

(test update-reloads-with-merged-initargs
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (p (meow:mount ctx 'tunable :reporter (meow:self) :level 1
                                       :restart :permanent)))
      (drain)
      (let ((p2 (meow:update ctx 'tunable :level 2)))
        (is (not (eq p p2)))
        (is (eq :reload (meow:process-exit-reason p)))
        (is (has '(tunable :ready 2) (drain)) "reporter is kept")
        (is (= 2 (meow:call (meow:reload ctx p2) :level)) "reload keeps it")
        (let ((p3 (meow:lookup 'tunable)))
          (meow:stop p3 :killed)
          (is (= 2 (meow:call (restarted ctx 'tunable p3) :level))
              "restart keeps it")))
      (is (null (meow:update ctx 'missing :level 3)))
      (stop-and-join ctx))))

(test update-config-applies-in-place
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (p (meow:mount ctx 'live-tunable :reporter (meow:self) :level 1)))
      (drain)
      (is (eq p (meow:update ctx 'live-tunable :level 2)))
      (is (equal '((live-tunable :update 1 2)) (drain)))
      (is (= 2 (meow:call p :level)))
      (is (= 2 (meow:call (meow:reload ctx p) :level)))
      (stop-and-join ctx))))

(test update-rejects-invalid-config-in-caller
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (p (meow:mount ctx 'tunable :level 1)))
      (signals meow:invalid-config (meow:update ctx 'tunable :level "high"))
      (signals type-error (meow:update ctx 'tunable :shutdown -1))
      (is (eq p (child-process ctx 'tunable)))
      (is (meow:process-alive-p p))
      (is (= 1 (meow:call (meow:reload ctx p) :level)) "nothing was stored")
      (is (meow:process-alive-p ctx))
      (stop-and-join ctx))))

(test update-mount-options-keeps-process
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (p (meow:mount ctx 'tunable)))
      (is (eq p (meow:update ctx p :restart :temporary)))
      (is (equal (list (list 'tunable p :temporary)) (child-summary ctx)))
      (stop-and-join ctx))))

(test update-while-restarting-is-used-by-the-restart
  (with-fresh-registry ()
    (let* ((ctx (start-context :restart-delay 0.3))
           (p (meow:mount ctx 'tunable :reporter (meow:self)
                                       :restart :permanent)))
      (drain)
      (meow:stop p :killed)
      (eventually (lambda ()
                    (eq :restarting (getf (first (meow:children ctx)) :state))))
      (meow:update ctx 'tunable :level 5)
      (is (= 5 (meow:call (restarted ctx 'tunable p) :level)))
      (stop-and-join ctx))))

(meow:defservice broken-tunable (tunable) ())

(defmethod meow:update-config ((s broken-tunable) old new)
  (declare (ignore old new))
  (error "can't apply"))

(test update-config-error-signals-in-caller
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (p (meow:mount ctx 'broken-tunable :level 1)))
      (signals simple-error (meow:update ctx 'broken-tunable :level 2))
      (is (eq p (child-process ctx 'broken-tunable)))
      (is (= 1 (meow:call p :level)))
      (is (= 1 (meow:call (meow:reload ctx p) :level)) "nothing was stored")
      (stop-and-join ctx))))

(test update-from-the-child-itself-is-refused
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (p (meow:mount ctx 'tunable)))
      (is (typep (meow:call p :update-self) 'error))
      (is (eq p (child-process ctx 'tunable)))
      (is (= 1 (meow:call p :level)))
      (stop-and-join ctx))))

(defun start-isolating (&rest initargs)
  "A context's instance and process."
  (let ((ctx (apply #'make-instance 'meow:context :name :ctx initargs)))
    (values ctx (meow:start-service ctx))))

(test isolated-service-coexists-with-outer
  (with-fresh-registry ()
    (let ((outer (meow:start-service (make-instance 'provider))))
      (multiple-value-bind (ctx cp) (start-isolating :isolate '(provider))
        (let ((inner (meow:mount cp 'provider)))
          (meow:mount cp 'consumer :reporter (meow:self))
          (is (not (eq outer inner)))
          (is (eq outer (meow:lookup 'provider)))
          (is (eq inner (meow:lookup 'provider
                                     :registry (meow:context-registry ctx))))
          (is (has (list 'consumer :ready inner) (drain))))
        (stop-and-join cp))
      (stop-and-join outer))))

(test isolated-name-does-not-fall-back-to-outer
  (with-fresh-registry ()
    (let ((outer (meow:start-service (make-instance 'provider))))
      (multiple-value-bind (ctx cp) (start-isolating :isolate '(provider))
        (declare (ignore ctx))
        (meow:mount cp 'consumer :reporter (meow:self))
        (is (null (drain)))
        (let ((inner (meow:mount cp 'provider)))
          (is (has (list 'consumer :ready inner) (drain))))
        (stop-and-join cp))
      (stop-and-join outer))))

(test other-names-resolve-outward
  (with-fresh-registry ()
    (let ((outer (meow:start-service (make-instance 'provider))))
      (multiple-value-bind (ctx cp) (start-isolating :isolate '(other))
        (declare (ignore ctx))
        (meow:mount cp 'consumer :reporter (meow:self))
        (is (has (list 'consumer :ready outer) (drain)))
        (stop-and-join cp))
      (stop-and-join outer))))

(test nested-isolation-resolves-to-nearest
  (with-fresh-registry ()
    (multiple-value-bind (ctx cp) (start-isolating :isolate '(provider))
      (let* ((mid (meow:mount cp 'provider))
             (inner (meow:mount cp 'meow:context
                                :name :inner :isolate '(provider consumer)
                                :children `((provider)
                                            (consumer :reporter ,(meow:self)))))
             (deep (child-process inner 'provider)))
        (is (has (list 'consumer :ready deep) (drain)))
        (is (not (eq mid deep)))
        (is (eq mid (meow:lookup 'provider :registry (meow:context-registry ctx))))
        (is (null (meow:lookup 'provider)) "nothing reaches the root")
        (is (null (meow:lookup 'consumer)))
        (let ((inner2 (meow:reload cp inner)))
          (is (has (list 'consumer :ready (child-process inner2 'provider))
                   (drain))
              "a reloaded context gets a fresh scope")))
      (stop-and-join cp))))
