(in-package #:meow/tests)

(def-suite :meow/timer :in :meow)
(in-suite :meow/timer)

(meow:defservice ticker (reporting)
  ((cancel :initform nil :accessor cancel)))

(defmethod meow:handle ((s ticker) message)
  (destructuring-bind (tag &optional a b)
      (if (consp message) message (list message))
    (ecase tag
      (:after (setf (cancel s)
                    (meow:after s a (lambda ()
                                      (report s :fired (meow:self) (now)))))
       :ok)
      (:repeat (setf (cancel s) (meow:repeat s a (lambda () (report s :tick))))
       :ok)
      (:slow (setf (cancel s)
                   (meow:repeat s a (lambda ()
                                      (report s :tick (now))
                                      (sleep b))))
       :ok)
      (:labelled (meow:after s a (constantly nil) :label :named) :ok)
      (:boom (meow:after s a (lambda () (error "boom"))) :ok)
      (:cancel (funcall (cancel s)) :ok)
      (:effects (meow:effects s))
      (:ping :pong))))

(test after-fires-once-on-the-service-process
  (with-fresh-registry ()
    (multiple-value-bind (p service) (start 'ticker)
      (let ((started (now)))
        (meow:call p '(:after 0.1))
        (destructuring-bind (name event process at) (meow:receive :timeout 1)
          (is (eq 'ticker name))
          (is (eq :fired event))
          (is (eq process (meow:service-process service))
              "the function runs on the service's own process")
          (is-true (waited-p 0.1 (- at started)))))
      (is (null (drain 0.2)) "it does not fire again")
      (stop-and-join p))))

(test after-releases-its-effect-once-it-has-fired
  (with-fresh-registry ()
    (let ((p (start 'ticker)))
      (meow:call p '(:after 0.05))
      (is (equal '((:after 0.05)) (meow:call p :effects)))
      (meow:receive :timeout 1)
      (is (null (meow:call p :effects)))
      (stop-and-join p))))

(test repeat-fires-until-it-is-cancelled
  (with-fresh-registry ()
    (let ((p (start 'ticker)))
      (meow:call p '(:repeat 0.05))
      (is (equal '((:repeat 0.05)) (meow:call p :effects)))
      (is (equal '(ticker :tick) (meow:receive :timeout 1)))
      (is (equal '(ticker :tick) (meow:receive :timeout 1)))
      (meow:call p :cancel)
      (is (null (meow:call p :effects)))
      (drain 0.1)
      (is (null (drain 0.2)) "cancelling stops the ticks")
      (stop-and-join p))))

(test repeat-waits-for-a-slow-function-before-the-next-tick
  (with-fresh-registry ()
    (let ((p (start 'ticker)))
      ;; A 0.01 period with a 0.15 body: ticks are spaced by the body, not
      ;; queued up in the mailbox.
      (meow:call p '(:slow 0.01 0.15))
      (let ((times (loop repeat 3 collect (third (meow:receive :timeout 2)))))
        (is-true (loop for (a b) on times while b
                       always (waited-p 0.15 (- b a)))))
      (stop-and-join p))))

(test a-cancelled-after-never-fires
  (with-fresh-registry ()
    (let ((p (start 'ticker)))
      (meow:call p '(:after 0.1))
      (meow:call p :cancel)
      (is (null (meow:call p :effects)))
      (is (null (drain 0.2)))
      (stop-and-join p))))

(test stopping-the-service-cancels-its-timers
  (with-fresh-registry ()
    (let ((p (start 'ticker)))
      (meow:call p '(:after 0.1))
      (meow:call p '(:repeat 0.05))
      (stop-and-join p)
      (is (null (remove :disposed (drain 0.3) :key #'second))
          "nothing fires after the service has stopped"))))

(test a-timer-label-can-be-given
  (with-fresh-registry ()
    (let ((p (start 'ticker)))
      (meow:call p '(:labelled 1))
      (is (equal '(:named) (meow:call p :effects)))
      (stop-and-join p))))

(test an-error-in-a-timer-function-stops-the-service
  (with-fresh-registry ()
    (let ((p (start 'ticker)))
      (meow:call p '(:boom 0.05))
      (join p)
      (is (equal :error (first (meow:process-exit-reason p)))))))

(test a-timer-cannot-be-set-from-another-process
  (with-fresh-registry ()
    (multiple-value-bind (p service) (start 'ticker)
      (signals error (meow:after service 0.1 (constantly nil)))
      (signals error (meow:repeat service 0.1 (constantly nil)))
      (stop-and-join p))))

(test the-timer-thread-stops-once-nothing-is-pending
  (with-fresh-registry ()
    (let ((p (start 'ticker)))
      (meow:call p '(:after 0.05))
      (meow:receive :timeout 1)
      (stop-and-join p))
    (is-true (eventually (lambda () (null meow::*%timer-thread*))))
    (is (null meow::*%timer-cells*))))
