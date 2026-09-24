(in-package #:meow)

(defstruct (reply-cell (:constructor %make-reply-cell ()))
  (lock (bt2:make-lock :name "reply") :read-only t)
  (cv (bt2:make-condition-variable) :read-only t)
  (state :pending)
  (value nil)
  (caller nil)
  ;; Set by DEFER-REPLY's :UNTIL, so REPLY can drop the exit hook once the
  ;; cell is answered rather than leaking it for the process's lifetime.
  (defer-hook nil)
  (defer-process nil)
  ;; Set by CALL-ASYNC: run once, outside the lock, as the cell settles.
  (on-settle nil))

(defvar *%caller* nil
  "The process whose call is being handled, if any.")

(defvar *%current-cell* nil
  "The reply cell of the :call message %DISPATCH is delivering, or nil
during a :cast. DEFER-REPLY reads this.")

(defvar *%deferred-p* nil
  "True once DEFER-REPLY has been called while handling the current
message. %DISPATCH checks this instead of replying with HANDLE's return
value.")

(defun %settle (cell state value)
  "Fill CELL once; later settlements are ignored."
  (let ((on-settle (bt2:with-lock-held ((reply-cell-lock cell))
                     (when (eq (reply-cell-state cell) :pending)
                       (setf (reply-cell-state cell) state
                             (reply-cell-value cell) value)
                       (bt2:condition-notify (reply-cell-cv cell))
                       (reply-cell-on-settle cell)))))
    (when on-settle (funcall on-settle)))
  nil)

(defun reply (cell value)
  "Answer the CALL that sent CELL, as DEFER-REPLY returned it. Drops the
:UNTIL exit hook DEFER-REPLY may have added, if the cell hasn't already
settled some other way."
  (%settle cell :value value)
  (a:when-let ((hook (reply-cell-defer-hook cell)))
    (remove-exit-hook (reply-cell-defer-process cell) hook)))

(defun defer-reply (&key until)
  "Call inside HANDLE, while handling a :call, to answer it later with REPLY
instead of HANDLE's return value. Returns the call's reply cell for REPLY to
take; returns nil inside a :cast, which has no cell to defer.

UNTIL, a process, settles the cell as (:down reason) if UNTIL exits before
REPLY is called -- the same protection CALL gives its own callers, for a
reply that has been handed off to another process. Without UNTIL, a handler
that never replies leaves every waiting CALL to time out on its own."
  (a:when-let ((cell *%current-cell*))
    (setf *%deferred-p* t)
    (when until
      ;; A cell forwarded here may already carry an earlier process's hook.
      (a:when-let ((earlier (reply-cell-defer-hook cell)))
        (remove-exit-hook (reply-cell-defer-process cell) earlier)
        (setf (reply-cell-defer-hook cell) nil))
      (let ((hook (add-exit-hook until (lambda (process reason)
                                          (declare (ignore process))
                                          (%settle cell :down reason)))))
        (if hook
            (setf (reply-cell-defer-process cell) until
                  (reply-cell-defer-hook cell) hook)
            ;; UNTIL had already exited: settle now, the same as %SEND-CALL
            ;; does for a target that is already gone.
            (%settle cell :down (process-exit-reason until)))))
    cell))

(defun forward (process message)
  "Call inside HANDLE, while handling a :call, to hand the call on to PROCESS
as (:call cell MESSAGE): PROCESS answers the original caller directly, and
the cell settles as (:down reason) if PROCESS exits first, as DEFER-REPLY's
:UNTIL does. The caller is still recorded as waiting on this process, not
PROCESS. Returns true, or nil inside a :cast, which has no call to forward."
  (a:when-let ((cell (defer-reply :until process)))
    (when (%cell-pending-p cell)
      (send process (list :call cell message)))
    t))

(defstruct (pending-call (:constructor %make-pending-call (process)))
  process (cell (%make-reply-cell)) hook)

(defun %send-call (pending message)
  "Send MESSAGE to PENDING's process as (:call cell message) without waiting.
If it has already exited, nothing is sent and the cell is settled as :down."
  (let* ((process (pending-call-process pending))
         (cell (pending-call-cell pending))
         (hook (add-exit-hook process (lambda (process reason)
                                        (declare (ignore process))
                                        (%settle cell :down reason)))))
    (setf (reply-cell-caller cell) (self)
          (pending-call-hook pending) hook)
    (if hook
        (send process (list :call cell message))
        (%settle cell :down (process-exit-reason process)))
    pending))

(defun %cancel-call (pending)
  (a:when-let ((hook (pending-call-hook pending)))
    (remove-exit-hook (pending-call-process pending) hook)))

;;; TODO: one global lock and a graph walk per waiting call; keep per-process
;;; wait links if call rates matter.
(defvar *%wait-lock* (bt2:make-lock :name "wait graph"))

(defvar *%waits* (make-hash-table :test 'eq)
  "Each waiting process's pending calls.")

(defun %cell-pending-p (cell)
  (bt2:with-lock-held ((reply-cell-lock cell))
    (eq (reply-cell-state cell) :pending)))

(defun %pending-p (pending)
  (%cell-pending-p (pending-call-cell pending)))

(defun %wait-path (from to)
  "The processes from FROM to TO along unanswered calls, or nil. Call with
the wait lock held."
  (let ((seen '()))
    (labels ((walk (process)
               (cond ((eq process to) (list process))
                     ((not (member process seen))
                      (push process seen)
                      (loop for pending in (gethash process *%waits*)
                            for path = (and (%pending-p pending)
                                            (walk (pending-call-process pending)))
                            when path
                              return (cons process path))))))
      (walk from))))

(defun %add-waits (process pending)
  "Record PROCESS as waiting on PENDING. Call with the wait lock held."
  (when pending
    (setf (gethash process *%waits*)
          (append pending (gethash process *%waits*)))))

(defun %begin-calls (processes)
  "A pending call from the current process to each of PROCESSES, recorded as
what it waits on. A process that would close a wait cycle gets the cycle's
processes instead, and nil stays nil."
  (let ((self (self)))
    (bt2:with-lock-held (*%wait-lock*)
      (let ((calls (mapcar (lambda (process)
                             (when process
                               (or (and self (%wait-path process self))
                                   (%make-pending-call process))))
                           processes)))
        (when self
          (%add-waits self (remove-if-not #'pending-call-p calls)))
        calls))))

(defun %end-calls (calls)
  "Cancel pending CALLS and stop waiting on them."
  (let ((pending (remove-if-not #'pending-call-p calls))
        (self (self)))
    (mapc #'%cancel-call pending)
    (when self
      (bt2:with-lock-held (*%wait-lock*)
        (a:if-let ((left (set-difference (gethash self *%waits*) pending)))
          (setf (gethash self *%waits*) left)
          (remhash self *%waits*))))))

(defun %break-waits (process self)
  "Settle as deadlocks the calls that make PROCESS wait on SELF, which is
about to wait on PROCESS and so can't answer them. Call with the wait lock
held."
  (unless (eq process self)
    (loop for path = (%wait-path process self)
          while path
          do (let ((waiter (car (last path 2))))
               (dolist (pending (gethash waiter *%waits*))
                 (when (and (eq (pending-call-process pending) self)
                            (%pending-p pending))
                   (%settle (pending-call-cell pending) :deadlock
                            (cons self (butlast path)))))))))

(defun %call-waiting-on (process thunk)
  "Call THUNK with the current process recorded as waiting on PROCESS. Calls
that leave PROCESS waiting on it are settled as deadlocks first."
  (let ((waits (list (%make-pending-call process))))
    (a:when-let ((self (self)))
      (bt2:with-lock-held (*%wait-lock*)
        (%break-waits process self)
        (%add-waits self waits)))
    (unwind-protect (funcall thunk)
      (%end-calls waits))))

(defun %await-call (pending timeout)
  "Wait up to TIMEOUT seconds for PENDING's reply, with CALL's return values."
  (let ((cell (pending-call-cell pending)))
    (bt2:with-lock-held ((reply-cell-lock cell))
      (%wait-until (reply-cell-lock cell) (reply-cell-cv cell)
                   (lambda () (not (eq (reply-cell-state cell) :pending)))
                   timeout))
    (%cell-result cell)))

(defun %cell-result (cell)
  "CELL's state as CALL's two values."
  (ecase (reply-cell-state cell)
    (:value (values (reply-cell-value cell) nil))
    (:down (values nil (list :down (reply-cell-value cell))))
    (:error (values nil (list :error (reply-cell-value cell))))
    (:deadlock (values nil (list :deadlock (reply-cell-value cell))))
    ((:pending :timeout) (values nil :timeout))))

(defun call (process message &key (timeout 5))
  "Send MESSAGE to PROCESS as (:call cell message) and wait for the reply.
Returns (values reply nil), (values nil :timeout) after TIMEOUT seconds (nil
waits forever), (values nil (:down reason)) if PROCESS exits first, or
(values nil (:error condition)) if a service skipped the message. On timeout
PROCESS keeps running and its eventual reply is discarded. If PROCESS is
already waiting, directly or through others, on the caller, nothing is sent
and it returns (values nil (:deadlock processes)), the cycle from PROCESS to
the caller. A call that is waiting when PROCESS starts waiting on the caller
is broken the same way."
  (let ((calls '()))
    (unwind-protect
         (let ((pending (first (setf calls (%begin-calls (list process))))))
           (if (pending-call-p pending)
               (%await-call (%send-call pending message) timeout)
               (values nil (list :deadlock pending))))
      (%end-calls calls))))

(defun call-async (process message &key (timeout 5) tag)
  "Send MESSAGE to PROCESS as CALL does, without waiting. When the call
settles, (:REPLY TAG VALUE STATUS) is sent to the calling process, VALUE and
STATUS being CALL's two values. The wait has no thread: TIMEOUT (nil waits
forever) is a scheduled settle, and a PROCESS that exits first settles it as
(:down reason). Nothing waits on PROCESS, so a call that CALL would refuse as a
deadlock is sent, and (:deadlock ...) is never a status. Only callable from a
process."
  (let* ((caller (%require-self))
         (pending (%make-pending-call process))
         (cell (pending-call-cell pending))
         (cancel-timer nil))
    (setf (reply-cell-on-settle cell)
          (lambda ()
            (%cancel-call pending)
            (when cancel-timer (funcall cancel-timer))
            (multiple-value-bind (value status) (%cell-result cell)
              (send caller (list :reply tag value status)))))
    (when timeout
      (setf cancel-timer (schedule timeout (lambda () (%settle cell :timeout nil)))))
    (%send-call pending message)
    nil))

(defun call-each (processes messages &key (timeout 5))
  "CALL each of MESSAGES on the process at the same position in PROCESSES, all
at once and all waiting on one shared TIMEOUT. Returns a list, in PROCESSES'
order, of (reply status) -- CALL's two values for that process, status nil
when it answered. A process that would close a wait cycle, the caller itself
included, is (nil (:deadlock processes)) without anything sent."
  (assert (= (length processes) (length messages)))
  (let ((deadline (and timeout (+ (%now) timeout)))
        (calls '()))
    (unwind-protect
         (progn
           (setf calls (%begin-calls processes))
           (loop for call in calls
                 for message in messages
                 when (pending-call-p call)
                   do (%send-call call message))
           (mapcar (lambda (call)
                     (if (pending-call-p call)
                         (multiple-value-list
                          (%await-call call (and deadline (max 0 (- deadline (%now))))))
                         (list nil (list :deadlock call))))
                   calls))
      (%end-calls calls))))

(defun call-all (processes message &key (timeout 5))
  "CALL MESSAGE on every one of PROCESSES at once; see CALL-EACH."
  (call-each processes (make-list (length processes) :initial-element message)
             :timeout timeout))

(defun cast (process message)
  "Send MESSAGE to PROCESS as (:cast message) without waiting."
  (send process (list :cast message))
  nil)

(defun stop (process &optional (reason :shutdown))
  "Ask PROCESS to exit with REASON. Only processes started by SERVE honour it."
  (send process (list :stop reason))
  nil)

(defun %message-parts (message)
  "(values tag a b) if MESSAGE is a proper list of the length its tag needs,
else nil."
  (when (and (consp message)
             (a:proper-list-p message)
             (eql (length (rest message))
                  (getf '(:call 2 :cast 1 :stop 1 :registered 2 :unregistered 2)
                        (first message))))
    (values (first message) (second message) (third message))))

(defun serve (handler &key name)
  "Spawn a process that calls HANDLER with each call or cast message. A call's
reply is HANDLER's return value, unless HANDLER calls DEFER-REPLY and answers
it later with REPLY. Malformed messages are dropped."
  (spawn (lambda ()
           (loop (multiple-value-bind (tag a b) (%message-parts (receive))
                   (case tag
                     (:call (when (and (reply-cell-p a) (%cell-pending-p a))
                              (let ((*%current-cell* a) (*%deferred-p* nil))
                                (let ((result (funcall handler b)))
                                  (unless *%deferred-p* (reply a result))))))
                     (:cast (let ((*%current-cell* nil)) (funcall handler a)))
                     (:stop (exit a))))))
         :name name))
