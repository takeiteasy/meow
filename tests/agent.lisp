(in-package #:meow/tests)

(def-suite :meow/agent :in :meow)
(in-suite :meow/agent)

(defclass echo-agent (reporting meow:agent) ())
(defclass crash-agent (meow:agent) ())
(defclass silent-agent (meow:agent) ())

;;; A service parent, rather than the plain processes every other test in
;;; this file uses, so DELEGATE's reports are shown reaching HANDLE.

(meow:defservice agent-parent (reporting) ())

(defmethod meow:handle ((s agent-parent) message)
  (case (first message)
    (:delegate (meow:delegate (meow:service-process (meow:service-context s))
                              (second message) :ref (third message)))
    ((:agent-done :agent-down) (report s (first message) (rest message)))))

(defmethod meow:handle ((agent echo-agent) message)
  (ecase (first message)
    (:echo (second message))
    (:done (values :done (second message)))))

(defmethod meow:handle ((agent crash-agent) message)
  (error "crash ~s" message))

(defun terminal-p (message)
  (member (first message) '(:agent-done :agent-down)))

(test agent-is-unregistered-and-answers-calls
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (a (meow:delegate ctx 'echo-agent)))
      (is (eq :hi (meow:call a '(:echo :hi))))
      (is (equal '(:ctx) (meow:names)))
      (is (equal (list (list nil a :temporary)) (child-summary ctx)))
      (stop-and-join ctx))))

(test done-by-cast-notifies-parent-and-stops
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (a (meow:delegate ctx 'echo-agent :ref :r1)))
      (meow:cast a '(:done 42))
      (join a)
      (is (eq :done (meow:process-exit-reason a)))
      (is (equal (list (list :agent-done :r1 a 42))
                 (remove-if-not #'terminal-p (drain))))
      (is-true (eventually (lambda () (null (meow:children ctx)))))
      (stop-and-join ctx))))

(test done-by-call-replies-with-result
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (a (meow:delegate ctx 'echo-agent :ref :r1)))
      (is (eql 42 (meow:call a '(:done 42))))
      (join a)
      (is (equal (list (list :agent-done :r1 a 42))
                 (remove-if-not #'terminal-p (drain))))
      (stop-and-join ctx))))

(test crash-sends-agent-down-and-is-not-restarted
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (a (meow:delegate ctx 'crash-agent :ref :r1)))
      (meow:cast a :anything)
      (let ((message (meow:receive :timeout 1)))
        (is (eq :agent-down (first message)))
        (is (eq :r1 (second message)))
        (is (eq :error (first (third message)))))
      (is-true (eventually (lambda () (null (meow:children ctx)))))
      (is-true (meow:process-alive-p ctx))
      (stop-and-join ctx))))

(test unmount-by-process-runs-disposer
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (a (meow:delegate ctx 'echo-agent :ref :r1 :reporter (meow:self))))
      (is-true (meow:unmount ctx a))
      (let ((messages (drain)))
        (is (has (list nil :disposed :shutdown nil) messages))
        (is (has (list :agent-down :r1 :shutdown) messages)))
      (is (null (meow:unmount ctx a)))
      (is (null (meow:unmount ctx nil)))
      (stop-and-join ctx))))

(test stopping-context-stops-silent-agent
  (with-fresh-registry ()
    (let ((ctx (start-context)))
      (meow:delegate ctx 'silent-agent :ref :r1)
      (is (null (meow:call (second (first (child-summary ctx))) :hello)))
      (stop-and-join ctx)
      (is (equal (list (list :agent-down :r1 :shutdown)) (drain))))))

(test named-agent-registers-and-rejects-duplicates
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (a (meow:delegate ctx 'echo-agent :name :worker)))
      (is (eq a (meow:lookup :worker)))
      (signals meow:already-registered
        (meow:delegate ctx 'silent-agent :name :worker))
      (meow:cast a '(:done nil))
      (join a)
      (is (null (meow:lookup :worker)))
      (is (has (list :agent-done nil a nil) (drain)))
      (stop-and-join ctx))))

(test concurrent-delegations-are-told-apart-by-ref
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (a (meow:delegate ctx 'echo-agent :ref 1))
           (b (meow:delegate ctx 'echo-agent :ref 2)))
      (meow:cast b '(:done :b))
      (meow:cast a '(:done :a))
      (join a)
      (join b)
      (is (equal (list (list :agent-done 1 a :a) (list :agent-done 2 b :b))
                 (sort (remove-if-not #'terminal-p (drain)) #'< :key #'second)))
      (stop-and-join ctx))))

(test a-service-parent-receives-agent-done-in-handle
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (p (meow:mount ctx 'agent-parent :reporter (meow:self)))
           (a (meow:call p '(:delegate echo-agent :r1))))
      (meow:cast a '(:done 42))
      (is (has (list 'agent-parent :agent-done (list :r1 a 42)) (drain)))
      (stop-and-join ctx))))

(test a-service-parent-receives-agent-down-in-handle
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (p (meow:mount ctx 'agent-parent :reporter (meow:self)))
           (a (meow:call p '(:delegate crash-agent :r2))))
      (meow:cast a :anything)
      (let ((messages (drain)))
        (is (find-if (lambda (m)
                       (and (equal '(agent-parent :agent-down) (subseq m 0 2))
                            (eq :r2 (first (third m)))
                            (eq :error (first (second (third m))))))
                     messages)))
      (stop-and-join ctx))))

(test a-message-matching-neither-report-shape-is-still-dropped
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (p (meow:mount ctx 'agent-parent :reporter (meow:self))))
      (meow:send p '(:agent-almost :r3))
      (meow:send p :agent-done)
      (is (null (drain)))
      (stop-and-join ctx))))

(test delegate-requires-a-process
  (with-fresh-registry ()
    (let ((ctx (start-context)))
      (is (eq :error (bt2:join-thread
                      (bt2:make-thread
                       (lambda ()
                         (handler-case (meow:delegate ctx 'echo-agent)
                           (error () :error)))))))
      (is (null (meow:children ctx)))
      (stop-and-join ctx))))
