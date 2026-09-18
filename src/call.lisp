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

(defun call (process message &key (timeout 5))
  "Send MESSAGE to PROCESS as (:call cell message) and wait for the reply.
Returns (values reply nil), (values nil :timeout) after TIMEOUT seconds (nil
waits forever), or (values nil (:down reason)) if PROCESS exits first. On
timeout PROCESS keeps running and its eventual reply is discarded."
  (let* ((cell (%make-reply-cell))
         (hook (add-exit-hook process (lambda (process reason)
                                        (declare (ignore process))
                                        (%settle cell :down reason)))))
    (unless hook
      (return-from call
        (values nil (list :down (process-exit-reason process)))))
    (unwind-protect
         (progn
           (send process (list :call cell message))
           (bt2:with-lock-held ((reply-cell-lock cell))
             (%wait-until (reply-cell-lock cell) (reply-cell-cv cell)
                          (lambda () (not (eq (reply-cell-state cell) :pending)))
                          timeout))
           (ecase (reply-cell-state cell)
             (:value (values (reply-cell-value cell) nil))
             (:down (values nil (list :down (reply-cell-value cell))))
             (:pending (values nil :timeout))))
      (remove-exit-hook process hook))))

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
