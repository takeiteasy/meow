(in-package #:meow)

;;; TODO: one thread per process; move to a shared dispatcher if process
;;; counts reach the hundreds.

(defvar *self* nil
  "The process the current thread is running as.")

(defclass process ()
  ((name :initarg :name :initform nil :reader process-name)
   (thread :initarg :thread :initform nil :accessor process-thread)
   (mailbox :initform (make-mailbox) :reader process-mailbox)
   (lock :initform (bt2:make-lock :name "process") :reader process-lock)
   (alive-p :initform t :reader process-alive-p)
   (exit-reason :initform nil :reader process-exit-reason)
   (exit-hooks :initform '())))

(defmethod print-object ((process process) stream)
  (print-unreadable-object (process stream :type t :identity t)
    (format stream "~@[~s ~]~:[exited ~s~;alive~]"
            (process-name process)
            (process-alive-p process)
            (process-exit-reason process))))

(defun self ()
  *self*)

(defun %require-self ()
  (or *self* (error "Not running inside a process.")))

(defun add-exit-hook (process function)
  "Call FUNCTION with PROCESS and its exit reason when it exits. Returns a
token for REMOVE-EXIT-HOOK, or nil (without calling FUNCTION) if PROCESS has
already exited."
  (bt2:with-lock-held ((process-lock process))
    (when (process-alive-p process)
      (let ((token (list function)))
        (push token (slot-value process 'exit-hooks))
        token))))

(defun remove-exit-hook (process token)
  (bt2:with-lock-held ((process-lock process))
    (a:deletef (slot-value process 'exit-hooks) token :test #'eq))
  nil)

(defvar *teardown-error-hook* nil
  "When non-nil, a function called with the condition and the process or
service when an exit hook or disposer fails. Otherwise a warning is printed.
Read from its global value, since teardown runs on the exiting thread.")

(defun %teardown-failed (condition source)
  "Report a failed exit hook or disposer without signalling, which would
unwind a bt2 thread. Falls back to printing if the hook itself fails."
  (unless (and *teardown-error-hook*
               (ignore-errors (funcall *teardown-error-hook* condition source) t))
    (format *error-output* "~&WARNING: Teardown of ~a failed: ~a~%"
            source condition)))

(defun %exit (process reason)
  "Mark PROCESS dead, then run its exit hooks with no process lock held."
  (let ((hooks (bt2:with-lock-held ((process-lock process))
                 (when (process-alive-p process)
                   (setf (slot-value process 'alive-p) nil
                         (slot-value process 'exit-reason) reason)
                   (shiftf (slot-value process 'exit-hooks) '())))))
    (dolist (hook (reverse hooks))
      (handler-case (funcall (car hook) process reason)
        (error (e)
          (%teardown-failed e process))))))

(defvar *%running* nil
  "The process whose body is running on this thread and can still exit.")

(defun %run (process function)
  "Run FUNCTION as PROCESS and return its values. The exit reason is :normal
on return, the value passed to EXIT, (:error condition) on an unhandled
error, or :aborted on any other non-local exit. %SUSPEND-SELF (below)
unwinds the same way but through a reason %RUN recognises specially:
PROCESS stays alive and no exit hook runs, so %RESPAWN can run FUNCTION
again over the same instance as if nothing happened."
  (let ((*self* process)
        (reason :aborted)
        (results '()))
    (unwind-protect
         (handler-bind ((error (lambda (e) (setf reason (list :error e)))))
           (setf reason (catch '%exit
                          (let ((*%running* process))
                            (setf results (multiple-value-list (funcall function))))
                          :normal)))
      (unless (eq reason '%suspended) (%exit process reason)))
    (values-list results)))

(defun exit (&optional (reason :normal))
  "End the current process with REASON."
  (%require-self)
  (throw '%exit reason))

(defun %suspend-self ()
  "End the current thread without exiting the process: no exit hook runs,
PROCESS-ALIVE-P stays true, and the mailbox and every registration survive
for %RESPAWN to pick back up. The primitive M:SUSPEND (suspend.lisp, a
different, exported name -- this one is internal) sends every process in a
tree to call on itself; never call directly."
  (%require-self)
  (throw '%exit '%suspended))

;;; A %SUSPEND-CELL closes the race an ack semaphore alone can't: SUSPEND
;;; timing out and a process finally getting to its queued %SUSPEND message
;;; can land at the same moment. Without a way to withdraw the request, a
;;; process that parks just after SUSPEND gives up on it is never
;;; respawned -- alive-p stays true forever, so nothing ever notices. The
;;; cell makes "may this process still park for this request" and "record
;;; that it did" one atomic decision, so SUSPEND's timeout path always
;;; knows, for certain, whether that process parked or was turned away.

(defstruct (suspend-cell (:constructor %make-suspend-cell ()))
  (lock (bt2:make-lock :name "suspend cell"))
  (state :pending))

(defun %suspend-cell-try-park (cell)
  "T and CELL moved to :parked, if it was still :pending; nil (CELL
untouched, already :cancelled) otherwise. Called from the process about to
park."
  (bt2:with-lock-held ((suspend-cell-lock cell))
    (when (eq (suspend-cell-state cell) :pending)
      (setf (suspend-cell-state cell) :parked)
      t)))

(defun %suspend-cell-cancel (cell)
  "CELL's final state: :cancelled if it was still :pending (so the process
will see :cancelled and drop the request, never parking for it), or
:parked if it beat this call to it. Called from SUSPEND on a timeout."
  (bt2:with-lock-held ((suspend-cell-lock cell))
    (when (eq (suspend-cell-state cell) :pending)
      (setf (suspend-cell-state cell) :cancelled))
    (suspend-cell-state cell)))

(defun %kill (process)
  "Interrupt PROCESS's thread to exit with :killed. Does nothing once it is
already exiting, so its exit hooks still run."
  (ignore-errors
   (bt:interrupt-thread (process-thread process)
                        (lambda ()
                          (when (eq *%running* process)
                            (exit :killed))))))

;;; Threads are apiv1 (bt:), not apiv2 (bt2:): apiv2's thread wrapper table
;;; leaks an entry per thread on ECL, wedging a lock elsewhere in the image
;;; once enough of them pile up. Locks and condition variables stay on bt2.
(defun spawn (function &key name)
  "Run FUNCTION in a new thread as a new process."
  (let ((process (make-instance 'process :name name)))
    (setf (process-thread process)
          (bt:make-thread (lambda ()
                            (handler-case (%run process function)
                              (error () nil)))
                          :name (format nil "meow ~(~a~)" (or name "process"))))
    process))

(defun %respawn (process function)
  "Spawn a fresh thread over PROCESS, already alive from a SUSPEND, running
FUNCTION -- the resume half of SUSPEND/SPAWN, same thread creation, no new
instance."
  (setf (process-thread process)
        (bt:make-thread (lambda ()
                          (handler-case (%run process function)
                            (error () nil)))
                        :name (format nil "meow ~(~a~)"
                                      (or (process-name process) "process")))))

(defun %call-with-process (function name)
  (let ((process (make-instance 'process :name name
                                         :thread (bt:current-thread))))
    (%run process (lambda () (funcall function process)))))

(defmacro with-process ((var &key name) &body body)
  "Run BODY as a process on the current thread, with VAR bound to it. Errors
propagate as usual."
  `(%call-with-process (lambda (,var)
                         (declare (ignorable ,var))
                         ,@body)
                       ,name))

(defun send (process message)
  "Deliver MESSAGE to PROCESS. Never blocks; messages to exited processes are
dropped silently."
  (when (process-alive-p process)
    (mailbox-send (process-mailbox process) message))
  message)

(defun receive (&key timeout)
  "Take the next message for the current process. Returns (values message t),
or (values nil nil) after TIMEOUT seconds (nil waits forever)."
  (mailbox-receive (process-mailbox (%require-self)) :timeout timeout))
