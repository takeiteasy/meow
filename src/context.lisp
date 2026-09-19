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

(defservice context ()
  ((intensity :initarg :intensity :initform 5 :type (integer 0)
              :reader context-intensity)
   (period :initarg :period :initform 10 :type (real 0)
           :reader context-period)
   (restart-delay :initarg :restart-delay :initform 0 :type (real 0))
   (restart-delay-max :initarg :restart-delay-max :initform nil
                      :type (or null (real 0)))
   (specs :initarg :children :initform '() :type list)
   (children :initform '())
   (restarts :initform '()))
  (:validate %spec-problems))

(defstruct (child (:constructor make-child (class initargs restart shutdown
                                            backoff backoff-max)))
  class initargs restart shutdown backoff backoff-max
  name process service (restarts '()) pending)

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
or nil if CHILD is not mounted."
  (%context-call context (list '%unmount child timeout)))

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
STOP-TIMEOUT, or to start, it is removed and the error is signalled."
  (a:when-let ((result (%context-call context (list '%reload child timeout))))
    (destructuring-bind (status value) result
      (if (eq status :ok)
          value
          (error value)))))

(defun %stop-and-wait (process timeout &optional (reason :shutdown))
  "Stop PROCESS and wait up to TIMEOUT seconds for its exit hooks to run,
then kill it and wait as long again. A TIMEOUT of :infinity waits without
killing. Returns t, :killed, or nil if it is still running."
  ;; Hooks run in the order added, so this one fires after dispose and
  ;; unregistration.
  (let ((done (bt2:make-semaphore :name "exit")))
    (if (add-exit-hook process (lambda (process reason)
                                 (declare (ignore process reason))
                                 (bt2:signal-semaphore done)))
        (progn
          (stop process reason)
          (cond ((eq timeout :infinity) (bt2:wait-on-semaphore done) t)
                ((bt2:wait-on-semaphore done :timeout timeout) t)
                ;; The interrupt can leave shared state inconsistent, and
                ;; can't reach a process already in its exit hooks.
                (t (%kill process)
                   (when (bt2:wait-on-semaphore done :timeout timeout)
                     (if (eq (process-exit-reason process) :killed) :killed t)))))
        t)))

(defun %run-child (context child)
  "Start CHILD's instance. Its exit comes back to CONTEXT as a message."
  (let* ((self (self))
         (service (child-service child))
         (process (start-service service
                                 :registry (service-registry context)
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

(defun %start-child (context child)
  "Start CHILD with a fresh instance from its spec."
  (let ((service (apply #'make-instance (child-class child)
                        (child-initargs child))))
    (setf (slot-value service 'context) context
          (child-service child) service))
  (%run-child context child))

(defun %add-child (context class args)
  "Start a child from mount ARGS and add it to CONTEXT. Returns its process."
  (destructuring-bind (&key (restart :transient) (shutdown 5)
                         backoff backoff-max &allow-other-keys)
      args
    (check-type restart %restart-type)
    (check-type shutdown %shutdown-type)
    (check-type backoff (or null (real 0)))
    (check-type backoff-max (or null (real 0)))
    (let* ((child (make-child class
                              (a:remove-from-plist args :restart :shutdown
                                                   :backoff :backoff-max)
                              restart shutdown backoff backoff-max))
           (process (%start-child context child)))
      (a:appendf (slot-value context 'children) (list child))
      process)))

(defun %mount (context class args)
  (handler-case (list :ok (%add-child context class args))
    (error (e) (list :error e))))

(defmethod %startup ((context context))
  (loop for (class . args) in (slot-value context 'specs)
        do (%add-child context class args)))

(defun %find-child (context target)
  (when target
    (find target (slot-value context 'children)
          :key (if (typep target 'process) #'child-process #'child-name)
          :test #'equal)))

(defun %unmount (context target timeout)
  (with-slots (children) context
    (a:when-let ((child (%find-child context target)))
      (a:deletef children child)
      (or (%stop-and-wait (child-process child)
                          (or timeout (child-shutdown child)))
          :timeout))))

(defun %reload (context target timeout)
  (a:when-let ((child (%find-child context target)))
    (handler-case
        (let ((service (child-service child))
              (timeout (or timeout (child-shutdown child))))
          (unless (%stop-and-wait (child-process child) timeout :reload)
            (error 'stop-timeout :process (child-process child)
                                 :seconds timeout))
          (%reset service)
          (apply #'reinitialize-instance service (child-initargs child))
          (list :ok (%run-child context child)))
      (error (e)
        (a:deletef (slot-value context 'children) child)
        (list :error e)))))

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
          :restart-in (and pending (max 0 (- (first pending) (%now)))))))

(defmethod handle ((context context) message)
  (multiple-value-bind (tag a b c)
      (when (a:proper-list-p message)
        (values-list message))
    (case tag
      (%mount (%mount context a b))
      (%unmount (%unmount context a b))
      (%children (mapcar #'%child-info (slot-value context 'children)))
      (%reload (%reload context a b))
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
