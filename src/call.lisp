(in-package #:meow)

(defstruct (reply-cell (:constructor %make-reply-cell ()))
  (lock (bt2:make-lock :name "reply") :read-only t)
  (cv (bt2:make-condition-variable) :read-only t)
  (state :pending)
  (value nil))

(defun %settle (cell state value)
  "Fill CELL once; later settlements are ignored."
  (bt2:with-lock-held ((reply-cell-lock cell))
    (when (eq (reply-cell-state cell) :pending)
      (setf (reply-cell-state cell) state
            (reply-cell-value cell) value)
      (bt2:condition-notify (reply-cell-cv cell))))
  nil)

(defun reply (cell value)
  "Answer the CALL that sent CELL."
  (%settle cell :value value))

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
    (setf (pending-call-hook pending) hook)
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

(defun %pending-p (pending)
  (let ((cell (pending-call-cell pending)))
    (bt2:with-lock-held ((reply-cell-lock cell))
      (eq (reply-cell-state cell) :pending))))

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

(defun %call-waiting-on (process thunk)
  "Call THUNK with the current process recorded as waiting on PROCESS."
  (let ((waits (list (%make-pending-call process))))
    (a:when-let ((self (self)))
      (bt2:with-lock-held (*%wait-lock*)
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
    (ecase (reply-cell-state cell)
      (:value (values (reply-cell-value cell) nil))
      (:down (values nil (list :down (reply-cell-value cell))))
      (:error (values nil (list :error (reply-cell-value cell))))
      (:pending (values nil :timeout)))))

(defun call (process message &key (timeout 5))
  "Send MESSAGE to PROCESS as (:call cell message) and wait for the reply.
Returns (values reply nil), (values nil :timeout) after TIMEOUT seconds (nil
waits forever), (values nil (:down reason)) if PROCESS exits first, or
(values nil (:error condition)) if a service skipped the message. On timeout
PROCESS keeps running and its eventual reply is discarded. If PROCESS is
already waiting, directly or through others, on the caller, nothing is sent
and it returns (values nil (:deadlock processes)), the cycle from PROCESS to
the caller."
  (let ((calls '()))
    (unwind-protect
         (let ((pending (first (setf calls (%begin-calls (list process))))))
           (if (pending-call-p pending)
               (%await-call (%send-call pending message) timeout)
               (values nil (list :deadlock pending))))
      (%end-calls calls))))

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
reply is HANDLER's return value. Malformed messages are dropped."
  (spawn (lambda ()
           (loop (multiple-value-bind (tag a b) (%message-parts (receive))
                   (case tag
                     (:call (when (reply-cell-p a)
                              (reply a (funcall handler b))))
                     (:cast (funcall handler a))
                     (:stop (exit a))))))
         :name name))
