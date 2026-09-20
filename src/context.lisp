(in-package #:meow)

(deftype %restart-type () '(member :permanent :transient :temporary))

(deftype %shutdown-type () '(or (real 0) (eql :infinity)))

(defun %spec-problems (context)
  (loop for spec in (slot-value context 'specs)
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

(defun %intercept-problems (context)
  (loop for entry in (slot-value context 'intercept)
        unless (and (consp entry) (symbolp (first entry))
                    (a:proper-list-p entry)
                    (evenp (length (rest entry)))
                    (null (%mount-options (rest entry))))
          collect (format nil "intercept: ~s is not (class-or-name &rest initargs)"
                          entry)))

(defun %context-problems (context)
  (append (%spec-problems context) (%intercept-problems context)))

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
  name process service config (restarts '()) pending)

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
  "A plist (:name :process :restart :state :restart-in) for each child, in
mount order. STATE is :restarting while the child waits out its restart
delay, with RESTART-IN the seconds left, and :running otherwise."
  (%context-call context (list '%children)))

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
           (cond ((eq timeout :infinity) (bt2:wait-on-semaphore done) t)
                 ((bt2:wait-on-semaphore done :timeout timeout) t)
                 ;; The interrupt can leave shared state inconsistent, and
                 ;; can't reach a process already in its exit hooks.
                 (t (%kill process)
                    (when (bt2:wait-on-semaphore done :timeout timeout)
                      (if (eq (process-exit-reason process) :killed) :killed t))))))
        t)))

(defun %run-child (context child)
  "Start CHILD's instance. Its exit comes back to CONTEXT as a message."
  (let* ((self (self))
         (service (child-service child))
         (process (start-service service
                                 :registry (context-registry context)
                                 :debug (slot-value context 'debug))))
    (setf (child-name child) (service-name service)
          (child-process child) process
          (child-pending child) nil)
    (unless (add-exit-hook process (lambda (process reason)
                                     (cast self (list '%child-exit child
                                                      process reason))))
      (cast self (list '%child-exit child process
                       (process-exit-reason process))))
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
      (when (eq (child-process child) *%caller*)
        (return-from %unmount (%self-stop-error "Unmounting" *%caller*)))
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
    (if (eq (child-process child) *%caller*)
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
    (warn "Applying intercepts under ~a failed: ~a" context e)))

(defmethod update-config ((context context) old new)
  (when (equal (a:remove-from-plist old :intercept)
               (a:remove-from-plist new :intercept))
    (%warn-errors context (%set-intercept context (getf new :intercept)))
    t))

(defun %restart-p (restart reason)
  (ecase restart
    (:permanent t)
    (:transient (not (member reason '(:normal :shutdown))))
    (:temporary nil)))

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

;;; TODO: one sleeping thread per pending restart, which outlives a stopped
;;; context; use a shared timer if restart counts grow.
(defun %schedule-start (child delay)
  "Cast %DELAYED-START for CHILD to the current process after DELAY seconds."
  (let ((self (self))
        (token (setf (child-pending child) (list (+ (%now) delay)))))
    (bt2:make-thread (lambda ()
                       (sleep delay)
                       (cast self (list '%delayed-start child token)))
                     :name "meow restart delay")))

(defun %try-start (context child)
  (handler-case (%start-child context child)
    (error () nil)))

(defun %restart-child (context child)
  "Restart CHILD after its backoff delay, without blocking CONTEXT."
  (loop (%note-restart context)
        (let ((delay (%restart-delay context child)))
          (unless (zerop delay)
            (return (%schedule-start child delay)))
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
          (a:deletef children child)))))

(defun %child-info (child)
  (let ((pending (child-pending child)))
    (list :name (child-name child)
          :process (child-process child)
          :restart (child-restart child)
          :state (if pending :restarting :running)
          :restart-in (and pending
                           (float (max 0 (- (first pending) (%now))) 1.0)))))

(defmethod handle ((context context) message)
  (multiple-value-bind (tag a b c)
      (when (a:proper-list-p message)
        (values-list message))
    (case tag
      (%mount (%mount context a b))
      (%unmount (%unmount context a b))
      (%children (mapcar #'%child-info (slot-value context 'children)))
      (%reload (%reload context a b))
      (%update (%update context a b c))
      (%intercept (%intercept context a b))
      (%refresh (%warn-errors context (%refresh context)))
      (%child-exit (%child-exit context a b c))
      (%delayed-start (%delayed-start context a b))
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
