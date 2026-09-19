(in-package #:meow/tests)

;;; Ported from patchbay_service_recovery_tests, using the provider/consumer
;;; fixtures from the service tests.

(def-suite :meow/context :in :meow)
(in-suite :meow/context)

(defun start-context (&rest initargs)
  (meow:start-service (apply #'make-instance 'meow:context :name :ctx initargs)))

(defun child-process (context name)
  (second (assoc name (meow:children context) :test #'equal)))

(defun eventually (function &optional (timeout 2))
  "Poll FUNCTION until it returns true or TIMEOUT seconds pass."
  (loop with deadline = (+ (now) timeout)
        for value = (funcall function)
        until (or value (> (now) deadline))
        do (sleep 0.01)
        finally (return value)))

(defun restarted (context name old)
  (eventually (lambda ()
                (let ((process (child-process context name)))
                  (and process (not (eq process old))
                       (meow:process-alive-p process) process)))))

(test relationships-self-heal-after-child-crash
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (p (meow:mount ctx 'provider :reporter (meow:self))))
      (meow:mount ctx 'consumer :reporter (meow:self))
      (is (has (list 'consumer :ready p) (drain)))
      (meow:call p :boom)
      (let ((p2 (restarted ctx 'provider p))
            (messages (drain)))
        (is-true p2)
        (is (find-if (lambda (m)
                       (and (eql 4 (length m))
                            (equal '(consumer :dep-down provider) (subseq m 0 3))
                            (eq :error (first (fourth m)))))
                     messages))
        (is (has (list 'consumer :ready p2) messages))
        (is (eq :pong (meow:call p2 :ping))))
      (stop-and-join ctx))))

(test unmount-is-prompt-and-runs-disposer
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (p (meow:mount ctx 'provider :reporter (meow:self)))
           (start (progn (drain) (now))))
      (is-true (meow:unmount ctx 'provider))
      (is (< (- (now) start) 1))
      (is (equal (list 'provider :disposed :shutdown p) (meow:receive :timeout 1)))
      (is (null (meow:lookup 'provider)))
      (is (null (meow:children ctx)))
      (is (null (meow:unmount ctx 'provider)))
      (stop-and-join ctx))))

(test restart-types
  (loop for (restart reason restarts-p)
          in '((:permanent :normal t) (:permanent :killed t)
               (:transient :normal nil) (:transient :shutdown nil)
               (:transient :killed t)
               (:temporary :killed nil))
        do (with-fresh-registry ()
             (let* ((ctx (start-context))
                    (p (meow:mount ctx 'provider :restart restart)))
               (is (equal (list (list 'provider p restart)) (meow:children ctx)))
               (meow:stop p reason)
               (if restarts-p
                   (is-true (restarted ctx 'provider p) "~s ~s" restart reason)
                   (is-true (eventually (lambda () (null (meow:children ctx))))
                            "~s ~s" restart reason))
               (stop-and-join ctx)))))

(test restart-limit-stops-context-and-children
  (with-fresh-registry ()
    (let* ((ctx (start-context :intensity 2))
           (p (meow:mount ctx 'provider :restart :permanent)))
      (dotimes (i 2)
        (meow:stop p :killed)
        (setf p (restarted ctx 'provider p)))
      (meow:stop p :killed)
      (join ctx)
      (is (eq :restart-limit (meow:process-exit-reason ctx)))
      (is-false (meow:process-alive-p p))
      (is (null (meow:names))))))

(test nested-context-escalates-to-parent
  (with-fresh-registry ()
    (let* ((root (start-context))
           (inner (meow:mount root 'meow:context :name :inner :intensity 0))
           (p (meow:mount inner 'provider :restart :permanent)))
      (meow:stop p :killed)
      (let ((inner2 (restarted root :inner inner)))
        (is-true inner2)
        (is (eq :restart-limit (meow:process-exit-reason inner)))
        (is (null (meow:children inner2)) "a restarted context starts empty"))
      (stop-and-join root))))

(test mount-errors-signal-in-caller
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (p (meow:mount ctx 'provider)))
      (signals meow:already-registered (meow:mount ctx 'provider))
      (signals type-error (meow:mount ctx 'provider :restart :sometimes))
      (is (equal (list (list 'provider p :transient)) (meow:children ctx)))
      (stop-and-join ctx))))

(test stopping-context-stops-children-in-reverse-order
  (with-fresh-registry ()
    (let ((ctx (start-context)))
      (meow:mount ctx 'provider :reporter (meow:self))
      (meow:mount ctx 'consumer :reporter (meow:self))
      (drain)
      (stop-and-join ctx)
      (is (equal '(consumer provider)
                 (loop for (name event) in (drain)
                       when (eq event :disposed)
                         collect name)))
      (is (null (meow:names))))))
