(in-package #:meow)

(deftype %restart-type () '(member :permanent :transient :temporary))

(deftype %shutdown-type () '(or (real 0) (eql :infinity)))

(defun %spec-problems (specs)
  (loop for spec in specs
        for problem = (cond ((not (and (consp spec) (symbolp (first spec))
                                       (a:proper-list-p spec)
                                       (evenp (length (rest spec)))))
                             "is not (class &rest initargs)")
                            ((not (typep (getf (rest spec) :restart :transient)
                                         '%restart-type))
                             "has an invalid :restart")
                            ((not (typep (getf (rest spec) :shutdown 5)
                                         '%shutdown-type))
                             "has an invalid :shutdown")
                            ((not (typep (getf (rest spec) :backoff)
                                         '(or null (real 0))))
                             "has an invalid :backoff")
                            ((not (typep (getf (rest spec) :backoff-max)
                                         '(or null (real 0))))
                             "has an invalid :backoff-max"))
        when problem
          collect (format nil "children: ~s ~a" spec problem)))

(defun %spec-shape-p (spec)
  (and (consp spec) (symbolp (first spec)) (a:proper-list-p spec)
       (evenp (length (rest spec)))))

(defun %spec-key (spec)
  "The identity SPEC's entry is diffed under, or nil if it has none."
  (%initarg-name (first spec) (rest spec)))

(defun %key-problems (specs)
  "Problems with the classes and keys of SPECS, which %SPEC-PROBLEMS has
already reported on the shape of."
  (let ((keys '()))
    (loop for spec in specs
          when (and (%spec-shape-p spec) (first spec))
            append (cond ((not (find-class (first spec) nil))
                          (list (format nil "children: there is no class ~s"
                                        (first spec))))
                         ((not (%spec-key spec))
                          (list (format nil "children: ~s needs a :name"
                                        spec)))
                         ((member (%spec-key spec) keys :test #'equal)
                          (list (format nil "children: ~s is named ~s twice"
                                        (first spec) (%spec-key spec))))
                         (t (push (%spec-key spec) keys) '())))))

(defun %intercept-problems (context)
  (loop for entry in (slot-value context 'intercept)
        unless (and (consp entry) (symbolp (first entry))
                    (a:proper-list-p entry)
                    (evenp (length (rest entry)))
                    (null (%mount-options (rest entry))))
          collect (format nil "intercept: ~s is not (class-or-name &rest initargs)"
                          entry)))

(defun %context-problems (context)
  (append (%spec-problems (slot-value context 'specs))
          (%intercept-problems context)))

(defservice context ()
  ((intensity :initarg :intensity :initform 5 :type (integer 0)
              :reader context-intensity)
   (period :initarg :period :initform 10 :type (real 0)
           :reader context-period)
   (restart-delay :initarg :restart-delay :initform 0 :type (real 0))
   (restart-delay-max :initarg :restart-delay-max :initform nil
                      :type (or null (real 0)))
   (specs :initarg :children :initform '() :type list)
   (isolate :initarg :isolate :initform '() :type list)
   (intercept :initarg :intercept :initform '() :type list)
   (scope :initform nil :reader context-registry)
   (children :initform '())
   (restarts :initform '()))
  (:validate %context-problems))

(defstruct (child (:constructor make-child (class initargs restart shutdown
                                            backoff backoff-max)))
  class initargs restart shutdown backoff backoff-max
  name process service config (restarts '()) pending cancel)

(define-condition stop-timeout (error)
  ((process :initarg :process :reader stop-timeout-process)
   (seconds :initarg :seconds :reader stop-timeout-seconds))
  (:report (lambda (condition stream)
             (format stream "~a did not stop within ~a seconds and is still ~
running."
                     (stop-timeout-process condition)
                     (stop-timeout-seconds condition)))))

(defgeneric %scope (service)
  (:documentation "The context an event emitted on SERVICE is scoped to, or
nil for its whole registry.")
  (:method ((service service)) (service-context service))
  (:method ((context context)) context))

(defun %context-call (context message)
  (multiple-value-bind (reply status) (call context message :timeout nil)
    (when status
      (error "Context ~a failed: ~s" context status))
    reply))

(defun mount (context class &rest initargs
              &key restart shutdown backoff backoff-max &allow-other-keys)
  "Start a service of CLASS with INITARGS under CONTEXT and return its
process. RESTART is :permanent, :transient (default) or :temporary. SHUTDOWN
is how many seconds it gets to stop (default 5) before it is killed, or
:infinity to wait for it without killing it.
BACKOFF and BACKOFF-MAX override the context's :restart-delay and
:restart-delay-max."
  (declare (ignore restart shutdown backoff backoff-max))
  (destructuring-bind (status value)
      (%context-call context (list '%mount class initargs))
    (if (eq status :ok)
        value
        (error value))))

(defun unmount (context child &key timeout)
  "Stop CHILD of CONTEXT, a name or process, without restarting it, waiting
up to TIMEOUT seconds (default its shutdown, :infinity for no limit) for
it to exit before killing it. Returns t, :killed, :timeout if it is still running after being killed,
or nil if CHILD is not mounted. A child can't unmount itself: that would
deadlock, so an error is signalled instead."
  (check-type timeout (or null %shutdown-type))
  (let ((result (%context-call context (list '%unmount child timeout))))
    (if (typep result 'error)
        (error result)
        result)))

(defun children (context)
  "A plist (:name :process :restart :state :restart-in :class) for each child,
in mount order. STATE is :restarting while the child waits out its restart
delay, with RESTART-IN the seconds left, and :running otherwise."
  (%context-call context (list '%children)))

(defun child-spec (context child)
  "What CHILD of CONTEXT, a name or process, was mounted with, as a plist
(:class :initargs :restart :shutdown :backoff :backoff-max), or nil if CHILD
is not mounted. INITARGS is as given to MOUNT or updated since, without the
mount options and before any intercept; it may hold a credential, which is why
CHILDREN leaves it out."
  (%context-call context (list '%child-spec child)))

(defun reload (context child &key timeout)
  "Stop CHILD of CONTEXT, a name or process, with reason :reload, then
reinitialize its instance with the initargs it was mounted with and start it
again. Returns the new process, or nil if CHILD is not mounted. If it fails
to stop within TIMEOUT seconds (default its shutdown, :infinity for no
limit), which signals
STOP-TIMEOUT, or to start, it is removed and the error is signalled. A child
can't reload itself: that would deadlock, so an error is signalled instead."
  (check-type timeout (or null %shutdown-type))
  (a:when-let ((result (%context-call context (list '%reload child timeout))))
    (destructuring-bind (status value) result
      (if (eq status :ok)
          value
          (error value)))))

(defun update (context child &rest initargs)
  "Merge INITARGS into the initargs CHILD of CONTEXT, a name or process, was
mounted with, and use them for its restarts and reloads. :RESTART, :SHUTDOWN,
:BACKOFF and :BACKOFF-MAX replace its mount options. Changed initargs are
validated, then passed to UPDATE-CONFIG on the child's process; unless it
returns true, the child is reloaded. Returns the child's process, or nil if
CHILD is not mounted. INVALID-CONFIG and reload errors are signalled here."
  (let ((options (%mount-options initargs)))
    (apply #'%check-mount-options options)
    (a:when-let ((result (%context-call
                          context
                          (list '%update child
                                (apply #'a:remove-from-plist initargs
                                       (%plist-keys options))
                                options))))
      (destructuring-bind (status value) result
        (if (eq status :ok)
            value
            (error value))))))

(defun intercept (context head &rest initargs)
  "Set CONTEXT's intercept for HEAD, a class or service name, to INITARGS, or
remove it if there are none. Matching children are updated as by UPDATE;
nested contexts update theirs shortly after. INVALID-CONFIG for a child is
signalled here and changes nothing. Other errors are signalled after the
remaining children are updated, with the intercept kept."
  (destructuring-bind (status value)
      (%context-call context (list '%intercept head initargs))
    (if (eq status :ok)
        value
        (error value))))

(defun %join-exited (process)
  "BT:JOIN-THREAD PROCESS's thread, once its exit hooks have already run --
the thread has nothing left to do but unwind, so this returns almost at
once. Ensures %STOP-AND-WAIT never reports a process gone while a fork
right after it would still see its thread (~takeiteasy/nyaa#72)."
  (ignore-errors (bt:join-thread (process-thread process))))

(defun %stop-and-wait (process timeout &optional (reason :shutdown))
  "Stop PROCESS and wait up to TIMEOUT seconds for its exit hooks to run,
then kill it and wait as long again. A TIMEOUT of :infinity waits without
killing. Returns t, :killed, or nil if it is still running. Calls from
PROCESS to the waiting process meanwhile return (:deadlock ...)."
  ;; Hooks run in the order added, so this one fires after dispose and
  ;; unregistration.
  (let ((done (bt2:make-semaphore :name "exit")))
    (if (add-exit-hook process (lambda (process reason)
                                 (declare (ignore process reason))
                                 (bt2:signal-semaphore done)))
        (%call-waiting-on
         process
         (lambda ()
           (stop process reason)
           (cond ((eq timeout :infinity) (bt2:wait-on-semaphore done) (%join-exited process) t)
                 ((bt2:wait-on-semaphore done :timeout timeout) (%join-exited process) t)
                 ;; The interrupt can leave shared state inconsistent, and
                 ;; can't reach a process already in its exit hooks.
                 (t (kill process)
                    (when (bt2:wait-on-semaphore done :timeout timeout)
                      (%join-exited process)
                      (if (eq (process-exit-reason process) :killed) :killed t))))))
        t)))

(defun stop-and-wait (process &key (reason :shutdown) (timeout 5))
  "STOP PROCESS and don't return until its thread has actually exited (or
TIMEOUT seconds, default 5, pass and it is killed instead) -- unlike STOP,
which only sends the request. TIMEOUT :infinity waits without killing.
Returns t, :killed, or :timeout if it is still running. For a context, this
implies every child's thread is gone too, the same guarantee M:SUSPEND
already gives a caller about to fork (~takeiteasy/nyaa#72): STOP alone
leaves teardown running in the background, so a fork right after it can
still see the exiting thread."
  (let ((result (%stop-and-wait process timeout reason)))
    (if (null result) :timeout result)))

(defun %run-child (context child)
  "Start CHILD's instance. Its exit comes back to CONTEXT as a message."
  (let* ((self (self))
         (service (child-service child))
         (process (start-service service
                                 :registry (context-registry context)
                                 :debug (slot-value context 'debug))))
    (%cancel-pending child)
    (setf (child-name child) (service-name service)
          (child-process child) process)
    ;; :up so an observer anywhere above CONTEXT sees the whole subtree, as
    ;; well as one mounted beside the child.
    (flet ((announce (event &rest args)
             (let ((*event-scope* :up))
               (apply #'emit context event (child-name child) process args))))
      (announce :meow/mount)
      (flet ((gone (reason)
               (announce :meow/unmount reason)
               (cast self (list '%child-exit child process reason))))
        (unless (add-exit-hook process (lambda (process reason)
                                         (declare (ignore process))
                                         (gone reason)))
          (gone (process-exit-reason process)))))
    process))

(defun %plist-keys (plist)
  (loop for key in plist by #'cddr collect key))

(defun %merge (plist defaults)
  "PLIST, then the keys of DEFAULTS it lacks."
  (append plist (apply #'a:remove-from-plist defaults (%plist-keys plist))))

(defun %initarg-name (class initargs)
  "The service name an instance of CLASS made with INITARGS would have."
  (multiple-value-bind (key value tail) (get-properties initargs '(:name))
    (declare (ignore key))
    (if tail
        value
        (let ((class (if (symbolp class) (find-class class) class)))
          (c2mop:ensure-finalized class)
          (a:when-let ((default (find :name (c2mop:class-default-initargs class)
                                      :key #'first)))
            (funcall (third default)))))))

(defun %intercepted-p (head class name)
  (or (and name (equal head name))
      (a:when-let ((head-class (find-class head nil)))
        (subtypep class head-class))))

;;; TODO: ancestors' intercepts are read from this context's thread without
;;; a lock; pass them down with each refresh if that race matters.
(defun %config (context class initargs)
  "INITARGS for a CLASS child of CONTEXT, merged over the matching intercepts
of CONTEXT and its ancestors. Nearer contexts and later entries win."
  (let ((name (%initarg-name class initargs)))
    (loop for c = context then (service-context c)
          while c
          do (loop for (head . intercepted) in (reverse (slot-value c 'intercept))
                   when (%intercepted-p head class name)
                     do (setf initargs (%merge initargs intercepted))))
    initargs))

(defun %child-config (context child)
  (%config context (child-class child) (child-initargs child)))

(defun %start-child (context child)
  "Start CHILD with a fresh instance from its spec."
  (let* ((config (%child-config context child))
         (service (apply #'make-instance (child-class child) config)))
    (setf (slot-value service 'context) context
          (slot-value service 'child) child
          (child-service child) service
          (child-config child) config))
  (%run-child context child))

(defun %mount-options (args)
  "The mount options in ARGS, each once."
  (loop for key in '(:restart :shutdown :backoff :backoff-max)
        for tail = (nth-value 2 (get-properties args (list key)))
        when tail
          append (list key (second tail))))

(defun %check-mount-options (&key (restart :transient) (shutdown 5)
                               backoff backoff-max)
  (check-type restart %restart-type)
  (check-type shutdown %shutdown-type)
  (check-type backoff (or null (real 0)))
  (check-type backoff-max (or null (real 0))))

(defun %add-child (context class args)
  "Start a child from mount ARGS and add it to CONTEXT. Returns its process."
  (let ((options (%mount-options args)))
    (apply #'%check-mount-options options)
    (let* ((child (make-child class
                              (apply #'a:remove-from-plist args
                                     (%plist-keys options))
                              (getf options :restart :transient)
                              (getf options :shutdown 5)
                              (getf options :backoff)
                              (getf options :backoff-max)))
           (process (%start-child context child)))
      (a:appendf (slot-value context 'children) (list child))
      process)))

(defun %mount (context class args)
  (handler-case (list :ok (%add-child context class args))
    (error (e) (list :error e))))

(defmethod %startup ((context context))
  (with-slots (isolate scope) context
    (setf scope (if isolate
                    (make-instance 'registry :parent (service-registry context)
                                             :isolated isolate)
                    (service-registry context))))
  (loop for (class . args) in (slot-value context 'specs)
        do (%add-child context class args)))

(defun %find-child (context target)
  (when target
    (find target (slot-value context 'children)
          :key (if (typep target 'process) #'child-process #'child-name)
          :test #'equal)))

(defun %self-stop-error (verb process)
  (make-condition 'simple-error
                  :format-control "~a ~a from itself would deadlock"
                  :format-arguments (list verb process)))

(defun %unmount (context target timeout)
  (with-slots (children) context
    (a:when-let ((child (%find-child context target)))
      (when (and *%caller* (eq (child-process child) *%caller*))
        (return-from %unmount (%self-stop-error "Unmounting" *%caller*)))
      (%cancel-pending child)
      (a:deletef children child)
      (or (%stop-and-wait (child-process child)
                          (or timeout (child-shutdown child)))
          :timeout))))

(defun %reload-child (context child timeout)
  (handler-case
      (let ((service (child-service child))
            (timeout (or timeout (child-shutdown child))))
        (unless (%stop-and-wait (child-process child) timeout :reload)
          (error 'stop-timeout :process (child-process child)
                               :seconds timeout))
        (%reset service)
        (apply #'reinitialize-instance service
               (setf (child-config child) (%child-config context child)))
        (list :ok (%run-child context child)))
    (error (e)
      (a:deletef (slot-value context 'children) child)
      (list :error e))))

(defun %reload (context target timeout)
  (a:when-let ((child (%find-child context target)))
    (if (and *%caller* (eq (child-process child) *%caller*))
        (list :error (%self-stop-error "Reloading" *%caller*))
        (%reload-child context child timeout))))

(defun %set-mount-options (child options)
  (loop for (key value) on options by #'cddr
        do (ecase key
             (:restart (setf (child-restart child) value))
             (:shutdown (setf (child-shutdown child) value))
             (:backoff (setf (child-backoff child) value))
             (:backoff-max (setf (child-backoff-max child) value)))))

(defun %apply-update (context child old new initargs)
  "Store INITARGS and the config NEW for CHILD once its process applies NEW
over OLD, or reload it if it declines. A child that is not running just
stores them."
  (let* ((process (child-process child))
         (shutdown (child-shutdown child))
         (timeout (unless (eq shutdown :infinity) shutdown)))
    (flet ((store ()
             (setf (child-initargs child) initargs
                   (child-config child) new)
             (list :ok process)))
      (if (not (process-alive-p process))
          (store)
          (multiple-value-bind (applied status)
              (call process (list '%update-config old new) :timeout timeout)
            (case (if (consp status) (first status) status)
              ((nil :timeout)
               (when (typep applied 'error)
                 (return-from %apply-update (list :error applied)))
               (store)
               (if applied
                   (list :ok process)
                   (%reload-child context child nil)))
              (:down (store))
              (:deadlock
               (list :error (make-condition
                             'simple-error
                             :format-control "Updating ~a would deadlock: ~{~a~^ -> ~}"
                             :format-arguments (list process (second status)))))
              (t (list :error (second status)))))))))

(defun %update (context target initargs options)
  (a:when-let ((child (%find-child context target)))
    (handler-case
        (let* ((merged (%merge initargs (child-initargs child)))
               (new (%config context (child-class child) merged)))
          ;; TODO: a probe instance reruns initialize-instance side effects
          ;; and validates initforms, not live state; validate a copy of the
          ;; live instance if that matters.
          (when initargs
            (apply #'make-instance (child-class child) new))
          (%set-mount-options child options)
          (if initargs
              (%apply-update context child (child-config child) new merged)
              (list :ok (child-process child))))
      (error (e) (list :error e)))))

(defun %replace-child (context child)
  "Restart CHILD with a fresh instance, so initargs it lost revert to their
defaults. It is removed if that fails."
  (handler-case
      (let ((timeout (child-shutdown child)))
        (unless (%stop-and-wait (child-process child) timeout :reload)
          (error 'stop-timeout :process (child-process child)
                               :seconds timeout))
        (list :ok (%start-child context child)))
    (error (e)
      (a:deletef (slot-value context 'children) child)
      (list :error e))))

(defun %spec-args (spec)
  "SPEC's initargs, without its mount options."
  (apply #'a:remove-from-plist (rest spec)
         (%plist-keys (%mount-options (rest spec)))))

(defun %apply-spec (context child spec)
  "Apply SPEC's initargs to CHILD, in place if it keeps every initarg it has
and its process accepts them, otherwise by restarting it with a fresh
instance. Returns (:ok process) or (:error condition)."
  (handler-case
      (let* ((args (%spec-args spec))
             (config (%config context (child-class child) args)))
        (%set-mount-options child (%mount-options (rest spec)))
        (if (equal config (child-config child))
            (list :ok (child-process child))
            (progn
              (apply #'make-instance (child-class child) config)
              (if (subsetp (%plist-keys (child-config child))
                           (%plist-keys config))
                  (%apply-update context child (child-config child) config args)
                  (progn (setf (child-initargs child) args)
                         (%replace-child context child))))))
    (error (e) (list :error e))))

(defun %apply-children (context old new)
  "Mount, unmount and update CONTEXT's children so its subtree matches NEW,
the specs it held OLD. Returns (values report errors), the report naming
what changed."
  (let ((mounted '()) (updated '()) (unmounted '()) (errors '()))
    (flet ((note (result key list)
             (if (eq (first result) :error)
                 (push (second result) errors)
                 (push key list))
             list))
      (dolist (spec old)
        (let ((key (%spec-key spec)))
          (unless (find key new :key #'%spec-key :test #'equal)
            (%unmount context key nil)
            (push key unmounted))))
      (dolist (spec new)
        (let* ((key (%spec-key spec))
               (child (%find-child context key))
               (previous (find key old :key #'%spec-key :test #'equal)))
          (cond ((and child (eq (child-class child) (first spec)))
                 (unless (equal (rest spec) (rest previous))
                   (setf updated (note (%apply-spec context child spec)
                                       key updated))))
                (t
                 (when child
                   (%unmount context key nil))
                 (setf mounted (note (%mount context (first spec) (rest spec))
                                     key mounted))))))
      (setf (slot-value context 'specs) new)
      (values (list :mounted (nreverse mounted)
                    :updated (nreverse updated)
                    :unmounted (nreverse unmounted))
              (nreverse errors)))))

(defun %adoptable-p (old new)
  "True when a :CHILDREN change from OLD to NEW can be diffed: every entry
on both sides has a name of its own to be matched under."
  (or (equal old new)
      (not (or (%key-problems old) (%key-problems new)))))

(defun %changed-configs (context)
  "(child . config) for each running child whose intercepted config changed."
  (loop for child in (slot-value context 'children)
        for config = (%child-config context child)
        when (and (process-alive-p (child-process child))
                  (not (equal config (child-config child))))
          collect (cons child config)))

(defun %refresh (context)
  "Apply changed intercepts to CONTEXT's children, in place or by reloading
them, and have nested contexts do the same. Returns the errors."
  (let ((errors '()))
    (loop for (child . new) in (%changed-configs context)
          for old = (child-config child)
          for result = (handler-case
                           (progn
                             (apply #'make-instance (child-class child) new)
                             (if (subsetp (%plist-keys old) (%plist-keys new))
                                 (%apply-update context child old new
                                                (child-initargs child))
                                 (%replace-child context child)))
                         (error (e) (list :error e)))
          when (eq (first result) :error)
            do (push (second result) errors))
    (dolist (child (slot-value context 'children))
      (when (typep (child-service child) 'context)
        (cast (child-process child) '(%refresh))))
    (nreverse errors)))

(defun %set-intercept (context intercept)
  "Replace CONTEXT's intercepts and apply them. Signals INVALID-CONFIG,
changing nothing, if they or a child's new config don't validate. Returns
the errors from applying them."
  (with-slots ((current intercept)) context
    (let ((previous current))
      (setf current intercept)
      (handler-bind ((error (lambda (e)
                              (declare (ignore e))
                              (setf current previous))))
        (a:when-let ((problems (%intercept-problems context)))
          (error 'invalid-config :service context :problems problems))
        (loop for (child . config) in (%changed-configs context)
              do (apply #'make-instance (child-class child) config)))))
  (%refresh context))

(defun %intercept (context head initargs)
  (handler-case
      (let* ((others (remove head (slot-value context 'intercept)
                             :key #'first :test #'equal))
             (errors (%set-intercept context
                                     (if initargs
                                         (append others (list (cons head initargs)))
                                         others))))
        (if errors
            (list :error (first errors))
            (list :ok t)))
    (error (e) (list :error e))))

(defun %warn-errors (context errors)
  (dolist (e errors)
    (warn "Applying config under ~a failed: ~a" context e)))

(defmethod update-config ((context context) old new)
  (when (and (equal (a:remove-from-plist old :intercept :children)
                    (a:remove-from-plist new :intercept :children))
             (%adoptable-p (getf old :children) (getf new :children)))
    ;; Intercepts first, so a child mounted below sees them as it starts.
    (unless (equal (getf old :intercept) (getf new :intercept))
      (%warn-errors context (%set-intercept context (getf new :intercept))))
    (unless (equal (getf old :children) (getf new :children))
      (%warn-errors context (nth-value 1 (%apply-children
                                          context (getf old :children)
                                          (getf new :children)))))
    t))

(defun %restart-p (restart reason)
  (ecase restart
    (:permanent t)
    (:transient (not (member reason '(:normal :shutdown))))
    (:temporary nil)))

(defun will-restart-p (service reason)
  "True if SERVICE's context will restart it after it exits with REASON: it is
still mounted and either it is being reloaded or its current :restart policy
asks for one. Meant for DISPOSE,
to tell an exit that ends the service from one that is followed by a fresh
instance. A service not mounted on a context answers nil."
  (let ((child (slot-value service 'child))
        (context (service-context service)))
    (and child
         (member child (slot-value context 'children))
         (or (eq reason :reload)
             (%restart-p (child-restart child) reason))
         t)))

(defun %note-restart (context)
  "Record a restart, exiting with :restart-limit when more than intensity
restarts fall within period seconds."
  (with-slots (intensity period restarts) context
    (let ((now (%now)))
      (setf restarts (cons now (remove-if (lambda (time) (> (- now time) period))
                                          restarts)))
      (when (> (length restarts) intensity)
        (exit :restart-limit)))))

(defun %restart-delay (context child)
  "Record a restart of CHILD and return how long to wait before it: the base
delay, doubled for each earlier restart within period up to the max if set."
  (with-slots (period restart-delay restart-delay-max) context
    (let* ((now (%now))
           (base (or (child-backoff child) restart-delay))
           (max (or (child-backoff-max child) restart-delay-max))
           (count (length (setf (child-restarts child)
                                (cons now (remove-if (lambda (time)
                                                       (> (- now time) period))
                                                     (child-restarts child)))))))
      (if max
          (min max (* base (expt 2 (1- count))))
          base))))

(defun %cancel-pending (child)
  "Drop CHILD's pending restart, if it has one."
  (setf (child-pending child) nil)
  (a:when-let ((cancel (shiftf (child-cancel child) nil)))
    (funcall cancel)))

(defun %schedule-start (context child delay)
  "Start CHILD on CONTEXT's process after DELAY seconds. The wait is an
effect of CONTEXT, so a stopped context drops it."
  (%cancel-pending child)
  (let ((token (setf (child-pending child) (list (+ (%now) delay)))))
    (setf (child-cancel child)
          (after context delay
                 (lambda () (%delayed-start context child token))
                 :label (list :restart (child-name child))))))

(defun %try-start (context child)
  (handler-case (%start-child context child)
    (error () nil)))

(defun %restart-child (context child)
  "Restart CHILD after its backoff delay, without blocking CONTEXT."
  (loop (%note-restart context)
        (let ((delay (%restart-delay context child)))
          (unless (zerop delay)
            (return (%schedule-start context child delay)))
          (when (%try-start context child)
            (return)))))

(defun %delayed-start (context child token)
  "Start CHILD unless it was removed or started since TOKEN was scheduled."
  (when (and (member child (slot-value context 'children))
             (eq token (child-pending child)))
    (unless (%try-start context child)
      (%restart-child context child))))

(defun %child-exit (context child process reason)
  "Handle an exit of CHILD, ignoring one from a process it has replaced."
  (with-slots (children) context
    (when (and (member child children)
               (eq process (child-process child)))
      (if (%restart-p (child-restart child) reason)
          (%restart-child context child)
          (progn (%cancel-pending child)
                 (a:deletef children child))))))

(defun %child-info (child)
  (let ((pending (child-pending child)))
    (list :name (child-name child)
          :process (child-process child)
          :restart (child-restart child)
          :state (if pending :restarting :running)
          :restart-in (and pending
                           (float (max 0 (- (first pending) (%now))) 1.0))
          :class (child-class child))))

(defun %child-spec (context target)
  (a:when-let ((child (%find-child context target)))
    (list :class (child-class child)
          :initargs (copy-list (child-initargs child))
          :restart (child-restart child)
          :shutdown (child-shutdown child)
          :backoff (child-backoff child)
          :backoff-max (child-backoff-max child))))

(defmethod %tree-children ((context context))
  (mapcar (lambda (child)
            (list :process (child-process child) :service (child-service child)))
          (slot-value context 'children)))

(defmethod handle ((context context) message)
  (multiple-value-bind (tag a b c)
      (when (a:proper-list-p message)
        (values-list message))
    (case tag
      (%mount (%mount context a b))
      (%unmount (%unmount context a b))
      (%children (mapcar #'%child-info (slot-value context 'children)))
      (%child-spec (%child-spec context a))
      (%reload (%reload context a b))
      (%update (%update context a b c))
      (%intercept (%intercept context a b))
      (%refresh (%warn-errors context (%refresh context)))
      (%child-exit (%child-exit context a b c))
      (t (call-next-method)))))

(defmethod %teardown :before ((context context) reason)
  (declare (ignore reason))
  (with-slots (children restarts) context
    (dolist (child (reverse children))
      (let ((process (child-process child))
            (seconds (child-shutdown child)))
        (unless (%stop-and-wait process seconds)
          (%teardown-failed (make-condition 'stop-timeout :process process
                                                          :seconds seconds)
                            context))))
    (setf children '()
          restarts '())))
