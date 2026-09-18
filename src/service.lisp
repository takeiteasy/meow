(in-package #:meow)

(defclass service ()
  ((name :initarg :name :initform nil :reader service-name)
   (registry :initform nil :reader service-registry)
   (process :initform nil :reader service-process)
   (deps :initform '())
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

(defmacro defservice (name direct-superclasses direct-slots &rest options)
  "Define a service class. Options are DEFCLASS options plus
(:depends-on name...) and (:name registration-name), which defaults to NAME."
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
                                  '(:depends-on :name :default-initargs)))
                        options))
         ,@(when (option :depends-on)
             `((defmethod service-dependencies ((service ,name))
                 ',(rest (option :depends-on)))))
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

(defun %init-service (service)
  "Register SERVICE and subscribe to its dependencies. The dispose hook is
added first so it runs before the registry's unregister hook."
  (let* ((process (self))
         (registry (service-registry service))
         (hook (add-exit-hook process (lambda (process reason)
                                        (declare (ignore process))
                                        (dispose service reason)))))
    (setf (slot-value service 'process) process)
    (handler-bind ((error (lambda (e)
                            (declare (ignore e))
                            (remove-exit-hook process hook))))
      (register (service-name service) process
                :props (metadata service) :registry registry))
    (dolist (name (service-dependencies service))
      (subscribe name :registry registry))))

;;; TODO: an error in HANDLE stops the service; add skip-message and
;;; stop-service restarts once supervisors exist.
(defun %service-loop (service)
  (%maybe-ready service)
  (loop for message = (receive)
        do (when (and (consp message) (a:proper-list-p message))
             (let ((a (second message))
                   (b (third message)))
               (case (first message)
                 (:call (reply a (handle service b)))
                 (:cast (handle service a))
                 (:stop (exit a))
                 (:registered (%dep-up service a b))
                 (:unregistered (%dep-lost service a b)))))))

(defun start-service (service &key (registry *registry*))
  "Run SERVICE in a new process. Returns once it is registered and
subscribed. Signals ALREADY-REGISTERED if its name is taken."
  (setf (slot-value service 'registry) registry)
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
