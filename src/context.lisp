(in-package #:meow)

;;; TODO: restarts happen immediately, with no backoff; add a delay if a
;;; flapping child can starve its context.

(deftype %restart-type () '(member :permanent :transient :temporary))

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
                                         '(real 0)))
                             "has an invalid :shutdown"))
        when problem
          collect (format nil "children: ~s ~a" spec problem)))

(defservice context ()
  ((intensity :initarg :intensity :initform 5 :type (integer 0)
              :reader context-intensity)
   (period :initarg :period :initform 10 :type (real 0)
           :reader context-period)
   (specs :initarg :children :initform '() :type list)
   (children :initform '())
   (restarts :initform '()))
  (:validate %spec-problems))

(defstruct (child (:constructor make-child (class initargs restart shutdown)))
  class initargs restart shutdown name process service)

(define-condition stop-timeout (error)
  ((process :initarg :process :reader stop-timeout-process)
   (seconds :initarg :seconds :reader stop-timeout-seconds))
  (:report (lambda (condition stream)
             (format stream "~a did not stop within ~a seconds and is still ~
running."
                     (stop-timeout-process condition)
                     (stop-timeout-seconds condition)))))

(defun %context-call (context message)
  (multiple-value-bind (reply status) (call context message :timeout nil)
    (when status
      (error "Context ~a failed: ~s" context status))
    reply))

(defun mount (context class &rest initargs &key restart shutdown
                                             &allow-other-keys)
  "Start a service of CLASS with INITARGS under CONTEXT and return its
process. RESTART is :permanent, :transient (default) or :temporary. SHUTDOWN
is how many seconds it gets to stop (default 5)."
  (declare (ignore restart shutdown))
  (destructuring-bind (status value)
      (%context-call context (list '%mount class initargs))
    (if (eq status :ok)
        value
        (error value))))

(defun unmount (context child &key timeout)
  "Stop CHILD of CONTEXT, a name or process, without restarting it, waiting
up to TIMEOUT seconds (default its shutdown) for it to exit. Returns t,
:timeout if it is still running, or nil if CHILD is not mounted."
  (%context-call context (list '%unmount child timeout)))

(defun children (context)
  "A list of (name process restart) for each child, in mount order."
  (%context-call context (list '%children)))

(defun reload (context child &key timeout)
  "Stop CHILD of CONTEXT, a name or process, with reason :reload, then
reinitialize its instance with the initargs it was mounted with and start it
again. Returns the new process, or nil if CHILD is not mounted. If it fails
to stop within TIMEOUT seconds (default its shutdown), which signals
STOP-TIMEOUT, or to start, it is removed and the error is signalled."
  (a:when-let ((result (%context-call context (list '%reload child timeout))))
    (destructuring-bind (status value) result
      (if (eq status :ok)
          value
          (error value)))))

(defun %stop-and-wait (process timeout &optional (reason :shutdown))
  "Stop PROCESS and wait up to TIMEOUT seconds for its exit hooks to run.
Returns true if they did."
  ;; Hooks run in the order added, so this one fires after dispose and
  ;; unregistration.
  (let ((done (bt2:make-semaphore :name "exit")))
    (if (add-exit-hook process (lambda (process reason)
                                 (declare (ignore process reason))
                                 (bt2:signal-semaphore done)))
        (progn
          (stop process reason)
          ;; TODO: a process that misses the timeout keeps running; add kill
          ;; escalation if stuck children must be reclaimed.
          (bt2:wait-on-semaphore done :timeout timeout))
        t)))

(defun %run-child (context child)
  "Start CHILD's instance. Its exit comes back to CONTEXT as a message."
  (let* ((self (self))
         (service (child-service child))
         (process (start-service service
                                 :registry (service-registry context)
                                 :debug (slot-value context 'debug))))
    (setf (child-name child) (service-name service)
          (child-process child) process)
    (unless (add-exit-hook process (lambda (process reason)
                                     (cast self (list '%child-exit child
                                                      process reason))))
      (cast self (list '%child-exit child process
                       (process-exit-reason process))))
    process))

(defun %start-child (context child)
  "Start CHILD with a fresh instance from its spec."
  (setf (child-service child) (apply #'make-instance (child-class child)
                                     (child-initargs child)))
  (%run-child context child))

(defun %add-child (context class args)
  "Start a child from mount ARGS and add it to CONTEXT. Returns its process."
  (destructuring-bind (&key (restart :transient) (shutdown 5)
                       &allow-other-keys)
      args
    (check-type restart %restart-type)
    (check-type shutdown (real 0))
    (let* ((child (make-child class (a:remove-from-plist args :restart :shutdown)
                              restart shutdown))
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
      (if (%stop-and-wait (child-process child)
                          (or timeout (child-shutdown child)))
          t
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

(defun %child-exit (context child process reason)
  "Handle an exit of CHILD, ignoring one from a process it has replaced."
  (with-slots (children) context
    (when (and (member child children)
               (eq process (child-process child)))
      (if (%restart-p (child-restart child) reason)
          (loop (%note-restart context)
                (handler-case (return (%start-child context child))
                  (error () nil)))
          (a:deletef children child)))))

(defmethod handle ((context context) message)
  (multiple-value-bind (tag a b c)
      (when (a:proper-list-p message)
        (values-list message))
    (case tag
      (%mount (%mount context a b))
      (%unmount (%unmount context a b))
      (%children (mapcar (lambda (child)
                           (list (child-name child) (child-process child)
                                 (child-restart child)))
                         (slot-value context 'children)))
      (%reload (%reload context a b))
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
