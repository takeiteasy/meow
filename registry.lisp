(in-package #:meow)

;;; Lock order: registry, then process (exit hooks), then mailbox (sends).
;;; Exit hooks run with no process lock held, so taking the registry lock
;;; from one is safe.

(defclass registry ()
  ((lock :initform (bt2:make-lock :name "registry") :reader registry-lock)
   (cv :initform (bt2:make-condition-variable) :reader registry-cv)
   (entries :initform (make-hash-table :test 'equal))
   (subscribers :initform (make-hash-table :test 'equal))
   (subscriber-hooks :initform (make-hash-table :test 'eq))
   (listeners :initform (make-hash-table :test 'equal))
   (parent :initarg :parent :initform nil)
   (isolated :initarg :isolated :initform '())))

(defvar *registry* (make-instance 'registry))

(defstruct (entry (:constructor make-entry (process props hook)))
  process props hook)

(define-condition already-registered (error)
  ((name :initarg :name :reader already-registered-name)
   (owner :initarg :owner :reader already-registered-owner))
  (:report (lambda (c stream)
             (format stream "~s is already registered to ~a."
                     (already-registered-name c)
                     (already-registered-owner c)))))

(defun %owner (registry name)
  "The registry up REGISTRY's chain that holds NAME: the first isolating it,
or the root."
  (loop for r = registry then (slot-value r 'parent)
        when (or (null (slot-value r 'parent))
                 (member name (slot-value r 'isolated) :test #'equal))
          return r))

(defun %root (registry)
  (loop for r = registry then (slot-value r 'parent)
        unless (slot-value r 'parent) return r))

(defmacro %with-registry-lock ((registry) &body body)
  `(bt2:with-lock-held ((registry-lock ,registry))
     (with-slots (entries subscribers subscriber-hooks listeners) ,registry
       ,@body)))

(defun %notify (registry name message)
  (dolist (subscriber (gethash name (slot-value registry 'subscribers)))
    (send subscriber message)))

(defun register (name process &key props (registry *registry*))
  "Register PROCESS under NAME with PROPS, a plist. Signals
ALREADY-REGISTERED if a live process holds NAME. Returns t, or
(values nil :noproc) if PROCESS has already exited."
  (let ((registry (%owner registry name))
        (owner nil))
    (%with-registry-lock (registry)
      (let ((existing (gethash name entries)))
        (if (and existing (process-alive-p (entry-process existing)))
            (setf owner (entry-process existing))
            (let ((hook (add-exit-hook process
                                       (lambda (process reason)
                                         (%unregister-if-owner registry name
                                                               process reason)))))
              (unless hook
                (return-from register (values nil :noproc)))
              (setf (gethash name entries) (make-entry process props hook))
              (%notify registry name (list :registered name process))
              (bt2:condition-broadcast (registry-cv registry))))))
    (when owner
      (error 'already-registered :name name :owner owner))
    t))

(defun %remove-entry (registry name reason)
  (with-slots (entries) registry
    (remhash name entries)
    (%notify registry name (list :unregistered name reason))))

(defun unregister (name &key (registry *registry*))
  "Remove NAME. Subscribers get (:unregistered name :unregistered)."
  (setf registry (%owner registry name))
  (%with-registry-lock (registry)
    (a:when-let ((entry (gethash name entries)))
      (remove-exit-hook (entry-process entry) (entry-hook entry))
      (%remove-entry registry name :unregistered)
      t)))

(defun %unregister-if-owner (registry name process reason)
  "Exit-hook cleanup. A newer registration of NAME is left alone."
  (%with-registry-lock (registry)
    (let ((entry (gethash name entries)))
      (when (and entry (eq (entry-process entry) process))
        (%remove-entry registry name reason)))))

(defun lookup (name &key (registry *registry*))
  "Returns (values process props), or nil if NAME is not registered."
  (setf registry (%owner registry name))
  (%with-registry-lock (registry)
    (a:when-let ((entry (gethash name entries)))
      (values (entry-process entry) (entry-props entry)))))

(defun names (&key (registry *registry*))
  (let ((own (%with-registry-lock (registry)
               (a:hash-table-keys entries))))
    (a:if-let ((parent (slot-value registry 'parent)))
      (append own (remove-if (lambda (name)
                               (member name (slot-value registry 'isolated)
                                       :test #'equal))
                             (names :registry parent)))
      own)))

(defun await (name &key timeout (registry *registry*))
  "Wait for NAME to be registered. Returns its process, or (values nil
:timeout) after TIMEOUT seconds (nil waits forever)."
  (setf registry (%owner registry name))
  (%with-registry-lock (registry)
    (or (%wait-until (registry-lock registry) (registry-cv registry)
                     (lambda ()
                       (a:when-let ((entry (gethash name entries)))
                         (entry-process entry)))
                     timeout)
        (values nil :timeout))))

(defun subscribe (name &key (process (%require-self)) (registry *registry*))
  "Send PROCESS (:registered name owner) and (:unregistered name reason) for
NAME. If NAME is already registered, the first message is sent before this
returns. Returns nil if PROCESS has already exited."
  (setf registry (%owner registry name))
  (%with-registry-lock (registry)
    (unless (gethash process subscriber-hooks)
      (let ((hook (add-exit-hook process
                                 (lambda (process reason)
                                   (declare (ignore reason))
                                   (%drop-subscriber registry process)))))
        (unless hook
          (return-from subscribe nil))
        (setf (gethash process subscriber-hooks) hook)))
    (pushnew process (gethash name subscribers))
    (a:when-let ((entry (gethash name entries)))
      (send process (list :registered name (entry-process entry))))
    t))

(defun unsubscribe (name &key (process (%require-self)) (registry *registry*))
  (setf registry (%owner registry name))
  (%with-registry-lock (registry)
    (let ((remaining (remove process (gethash name subscribers))))
      (if remaining
          (setf (gethash name subscribers) remaining)
          (remhash name subscribers)))
    (unless (loop for subs being the hash-values of subscribers
                  thereis (member process subs))
      (a:when-let ((hook (gethash process subscriber-hooks)))
        (remove-exit-hook process hook)
        (remhash process subscriber-hooks))))
  nil)

(defun %drop-subscriber (registry process)
  (%with-registry-lock (registry)
    (loop for name in (a:hash-table-keys subscribers)
          for remaining = (remove process (gethash name subscribers))
          do (if remaining
                 (setf (gethash name subscribers) remaining)
                 (remhash name subscribers)))
    (remhash process subscriber-hooks)))
