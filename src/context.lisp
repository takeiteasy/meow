(in-package #:meow)

;;; TODO: restarts happen immediately, with no backoff; add a delay if a
;;; flapping child can starve its context.
;;; TODO: a restarted context starts empty; declare child specs on the
;;; context class if a subtree should be rebuilt on restart.

(defservice context ()
  ((intensity :initarg :intensity :initform 5 :type (integer 0)
              :reader context-intensity)
   (period :initarg :period :initform 10 :type (real 0)
           :reader context-period)
   (children :initform '())
   (restarts :initform '())))

(defstruct (child (:constructor make-child (class initargs restart)))
  class initargs restart name process service)

(defun %context-call (context message)
  (multiple-value-bind (reply status) (call context message :timeout nil)
    (when status
      (error "Context ~a failed: ~s" context status))
    reply))

(defun mount (context class &rest initargs &key (restart :transient)
                                             &allow-other-keys)
  "Start a service of CLASS with INITARGS under CONTEXT and return its
process. RESTART is :permanent, :transient or :temporary."
  (check-type restart (member :permanent :transient :temporary))
  (destructuring-bind (status value)
      (%context-call context (list '%mount class
                                   (a:remove-from-plist initargs :restart)
                                   restart))
    (if (eq status :ok)
        value
        (error value))))

(defun unmount (context child &key (timeout 5))
  "Stop CHILD of CONTEXT, a name or process, without restarting it, waiting
up to TIMEOUT seconds for it to exit. Returns t, or nil if CHILD is not
mounted."
  (%context-call context (list '%unmount child timeout)))

(defun children (context)
  "A list of (name process restart) for each child, in mount order."
  (%context-call context (list '%children)))

(defun reload (context child &key (timeout 5))
  "Stop CHILD of CONTEXT, a name or process, with reason :reload, then
reinitialize its instance with the initargs it was mounted with and start it
again. Returns the new process, or nil if CHILD is not mounted. If it fails
to stop within TIMEOUT seconds or to start, it is removed and the error is
signalled."
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
          ;; TODO: a child that misses the timeout keeps running unsupervised.
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

(defun %mount (context class initargs restart)
  (handler-case
      (let* ((child (make-child class initargs restart))
             (process (%start-child context child)))
        (a:appendf (slot-value context 'children) (list child))
        (list :ok process))
    (error (e) (list :error e))))

(defun %find-child (context target)
  (when target
    (find target (slot-value context 'children)
          :key (if (typep target 'process) #'child-process #'child-name)
          :test #'equal)))

(defun %unmount (context target timeout)
  (with-slots (children) context
    (a:when-let ((child (%find-child context target)))
      (a:deletef children child)
      (%stop-and-wait (child-process child) timeout)
      t)))

(defun %reload (context target timeout)
  (a:when-let ((child (%find-child context target)))
    (handler-case
        (let ((service (child-service child)))
          (unless (%stop-and-wait (child-process child) timeout :reload)
            (error "~a did not stop within ~a seconds." (child-process child)
                   timeout))
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
      (%mount (%mount context a b c))
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
      (%stop-and-wait (child-process child) 5))
    (setf children '()
          restarts '())))
