(in-package #:meow)

(defvar *debug-services* t
  "When true, an unhandled error in a service enters the debugger; otherwise
the service stops. START-SERVICE captures the value.")

(defclass service ()
  ((name :initarg :name :initform nil :reader service-name)
   (registry :initform nil :reader service-registry)
   (context :initform nil :reader service-context)
   (process :initform nil :reader service-process)
   (debug :initform nil)
   (deps :initform '())
   (effects :initform '())
   (status :initform :waiting)))

(defgeneric service-dependencies (service)
  (:documentation "Names SERVICE waits for before READY.")
  (:method ((service service)) '()))

(defgeneric metadata (service)
  (:documentation "A plist published as SERVICE's registration props.")
  (:method ((service service)) '()))

(defgeneric ready (service)
  (:documentation "Called once every dependency is registered.")
  (:method ((service service)) nil))

(defgeneric dep-down (service name reason)
  (:documentation "Called when dependency NAME leaves a ready SERVICE.")
  (:method ((service service) name reason)
    (declare (ignore name reason))
    nil))

(defgeneric handle (service message)
  (:documentation "Handle a call or cast MESSAGE. The value answers a call.")
  (:method ((service service) message)
    (declare (ignore message))
    nil))

(defgeneric dispose (service reason)
  (:documentation "Called when SERVICE stops, before it is unregistered.")
  (:method ((service service) reason)
    (declare (ignore reason))
    nil))

(defgeneric update-config (service old new)
  (:documentation "Called on SERVICE's process by UPDATE with its OLD and NEW
initargs, before its slots change. Return true to have NEW applied in place;
nil reloads SERVICE instead.")
  (:method ((service service) old new)
    (declare (ignore old new))
    nil))

(define-condition invalid-config (error)
  ((service :initarg :service :reader invalid-config-service)
   (problems :initarg :problems :reader invalid-config-problems))
  (:report (lambda (condition stream)
             (format stream "Invalid config for ~s:~{~%  ~a~}"
                     (class-name (class-of (invalid-config-service condition)))
                     (invalid-config-problems condition)))))

(defgeneric %config-problems (service)
  (:documentation "Problems found by :VALIDATE functions, superclasses first.")
  (:method-combination append :most-specific-last)
  (:method append ((service service)) '()))

;;; TODO: class slots are walked on every make-instance; cache per class if
;;; mount rates matter.
(defun %type-problems (service)
  (loop for slot in (c2mop:class-slots (class-of service))
        for name = (c2mop:slot-definition-name slot)
        for type = (c2mop:slot-definition-type slot)
        unless (or (eq type t)
                   (not (slot-boundp service name))
                   (typep (slot-value service name) type))
          collect (format nil "~(~a~): ~s is not of type ~s"
                          name (slot-value service name) type)))

(defun %validate (service)
  "Signal INVALID-CONFIG unless every typed slot holds a value of its type
and the :VALIDATE functions find no problems."
  (a:when-let ((problems (or (%type-problems service)
                             (%config-problems service))))
    (error 'invalid-config :service service :problems problems)))

;;; Not SHARED-INITIALIZE, which UPDATE-INSTANCE-FOR-REDEFINED-CLASS also
;;; calls on a live service's thread.
(defmethod initialize-instance :after ((service service) &key)
  (%validate service))

(defmethod reinitialize-instance :after ((service service) &key)
  (%validate service))

(defun %remove-option-method (function qualifiers class-name)
  "Remove the method a DEFSERVICE option defined, once the option is gone."
  (let* ((function (fdefinition function))
         (method (find-method function qualifiers (list (find-class class-name))
                              nil)))
    (when method
      (remove-method function method))))

(defmacro defservice (name direct-superclasses direct-slots &rest options)
  "Define a service class. Options are DEFCLASS options plus
(:depends-on name...), (:name registration-name), which defaults to NAME,
and (:validate function), which takes the instance and returns a list of
problem strings."
  (flet ((option (key) (assoc key options)))
    (let ((initargs (rest (option :default-initargs))))
      `(progn
         (defclass ,name (,@direct-superclasses service)
           ,direct-slots
           (:default-initargs
            ,@initargs
            ,@(unless (nth-value 2 (get-properties initargs '(:name)))
                `(:name ',(if (option :name) (second (option :name)) name))))
           ,@(remove-if (lambda (option)
                          (member (first option)
                                  '(:depends-on :name :validate
                                    :default-initargs)))
                        options))
         ,(if (option :depends-on)
              `(defmethod service-dependencies ((service ,name))
                 ',(rest (option :depends-on)))
              `(%remove-option-method 'service-dependencies '() ',name))
         ,(if (option :validate)
              `(defmethod %config-problems append ((service ,name))
                 (funcall #',(second (option :validate)) service))
              `(%remove-option-method '%config-problems '(append) ',name))
         (find-class ',name)))))

(defun service-ready-p (service)
  (eq (slot-value service 'status) :ready))

(defun dependency (service name)
  "The current process of dependency NAME, or nil."
  (cdr (assoc name (slot-value service 'deps) :test #'equal)))

(defun %maybe-ready (service)
  (with-slots (deps status) service
    (when (and (eq status :waiting)
               (every (lambda (name) (assoc name deps :test #'equal))
                      (service-dependencies service)))
      (setf status :ready)
      (ready service))))

(defun %dep-up (service name process)
  (when (member name (service-dependencies service) :test #'equal)
    (with-slots (deps) service
      (setf deps (acons name process
                        (remove name deps :key #'car :test #'equal))))
    (%maybe-ready service)))

(defun %dep-lost (service name reason)
  (with-slots (deps status) service
    (when (assoc name deps :test #'equal)
      (setf deps (remove name deps :key #'car :test #'equal))
      (when (eq status :ready)
        (setf status :waiting)
        (dep-down service name reason)))))

(defun %require-own-process (service)
  (unless (eq (self) (service-process service))
    (error "~a can only be used from its own process." service)))

(defun %release (service cell)
  (%require-own-process service)
  (with-slots (effects) service
    (when (member cell effects :test #'eq)
      (a:deletef effects cell :test #'eq)
      (funcall (car cell)))))

(defun effect (service acquire)
  "Call ACQUIRE, which returns a disposer or nil. The disposer runs when
SERVICE stops, in reverse order of acquisition and before DISPOSE. Returns a
function that runs the disposer early. Only callable from SERVICE's process."
  (%require-own-process service)
  (when (eq (slot-value service 'status) :stopped)
    (error "~a is stopping." service))
  (a:if-let ((disposer (funcall acquire)))
    (let ((cell (list disposer)))
      (push cell (slot-value service 'effects))
      (lambda () (%release service cell)))
    (constantly nil)))

(defmacro with-effect ((var service init-form) &body cleanup)
  "Acquire INIT-FORM as an effect of SERVICE. CLEANUP, with VAR bound to the
resource, is its disposer. Returns the resource and the release function."
  (a:with-gensyms (resource release)
    `(let* ((,resource nil)
            (,release (effect ,service
                             (lambda ()
                               (let ((,var ,init-form))
                                 (setf ,resource ,var)
                                 (lambda () ,@cleanup))))))
       (values ,resource ,release))))

(defun %reset (service)
  "Clear the runtime state of a stopped SERVICE so it can be started again."
  (with-slots (process deps effects status) service
    (setf process nil
          deps '()
          effects '()
          status :waiting)))

(defgeneric %teardown (service reason)
  (:documentation "Unwind SERVICE's effects, then DISPOSE."))

(defmethod %teardown ((service service) reason)
  (with-slots (effects status) service
    (setf status :stopped)
    (loop while effects
          do (let ((disposer (car (pop effects))))
               (handler-case (funcall disposer)
                 (error (e) (%teardown-failed e service))))))
  (dispose service reason))

(defgeneric %startup (service)
  (:documentation "Called on SERVICE's process once it is registered, before
START-SERVICE returns. An error fails the start.")
  (:method ((service service)) nil))

(defun %init-service (service)
  "Register SERVICE, unless its name is nil, and subscribe to its
dependencies, then run %STARTUP. The teardown hook is added first so it
runs before the registry's unregister hook."
  (let* ((process (self))
         (registry (service-registry service))
         (hook (add-exit-hook process (lambda (process reason)
                                        (declare (ignore process))
                                        (%teardown service reason)))))
    (setf (slot-value service 'process) process)
    (handler-bind ((error (lambda (e)
                            (declare (ignore e))
                            (remove-exit-hook process hook))))
      (when (service-name service)
        (register (service-name service) process
                  :props (metadata service) :registry registry)))
    (dolist (name (service-dependencies service))
      (subscribe name :registry registry))
    (%startup service)))

(defun skip-message (&optional condition)
  "Invoke the SKIP-MESSAGE restart: drop the message being handled and keep
the service running. A skipped call returns (values nil (:error condition))."
  (a:when-let ((restart (find-restart 'skip-message condition)))
    (invoke-restart restart condition)))

(defun stop-service (&optional condition)
  "Invoke the STOP-SERVICE restart: exit with (:error condition)."
  (a:when-let ((restart (find-restart 'stop-service condition)))
    (invoke-restart restart condition)))

(defun %guard (service message function)
  "Call FUNCTION, handling MESSAGE, with the service restarts established.
An unhandled error enters the debugger or stops SERVICE."
  (let ((failure nil))
    (restart-case
        (handler-bind ((error (lambda (c)
                                (setf failure c)
                                (if (slot-value service 'debug)
                                    (invoke-debugger c)
                                    (stop-service c)))))
          (funcall function))
      (skip-message (&optional (condition failure))
        :report "Drop the message and keep the service running."
        (multiple-value-bind (tag cell) (%message-parts message)
          (when (and (eq tag :call) (reply-cell-p cell))
            (%settle cell :error condition))))
      (stop-service (&optional (condition failure))
        :report "Stop the service."
        (exit (list :error condition))))))

(defun %apply-config (service old new)
  "T if UPDATE-CONFIG applied NEW in place, nil if it declined, or the error
it signalled."
  (handler-case (when (update-config service old new)
                  (apply #'reinitialize-instance service new)
                  t)
    (error (e) e)))

(defun %handle (service message)
  (cond ((%delivery-p message) (%deliver message))
        ((and (a:proper-list-p message) (eq (first message) '%update-config))
         (apply #'%apply-config service (rest message)))
        (t (handle service message))))

(defgeneric %dispatch (service message))

(defmethod %dispatch ((service service) message)
  (multiple-value-bind (tag a b) (%message-parts message)
    (case tag
      (:call (when (and (reply-cell-p a) (%cell-pending-p a))
               (let ((*%caller* (reply-cell-caller a)))
                 (reply a (%handle service b)))))
      (:cast (%handle service a))
      (:stop (exit a))
      (:registered (%dep-up service a b))
      (:unregistered (%dep-lost service a b)))))

(defun %service-loop (service)
  (%guard service nil (lambda () (%maybe-ready service)))
  (loop (let ((message (receive)))
          (%guard service message (lambda () (%dispatch service message))))))

(defun start-service (service &key (registry *registry*)
                                   (debug *debug-services*))
  "Run SERVICE in a new process. Returns once it is registered and
subscribed. A service named nil is not registered. Signals
ALREADY-REGISTERED if its name is taken."
  (setf (slot-value service 'registry) registry
        (slot-value service 'debug) debug)
  (let* ((started (bt2:make-semaphore :name "service start"))
         (failure nil)
         (process (spawn (lambda ()
                           (handler-case (%init-service service)
                             (error (e)
                               (setf failure e)
                               (bt2:signal-semaphore started)
                               (exit (list :error e))))
                           (bt2:signal-semaphore started)
                           (%service-loop service))
                         :name (service-name service))))
    (bt2:wait-on-semaphore started)
    (when failure
      (bt2:join-thread (process-thread process))
      (error failure))
    process))
