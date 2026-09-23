(in-package #:meow/tests)

;;; SUSPEND / RESUME (~takeiteasy/meow#64).

(def-suite :meow/suspend :in :meow)
(in-suite :meow/suspend)

(test suspend-parks-every-thread-but-process-alive-p-stays-true
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (p (meow:mount ctx 'provider :reporter (meow:self))))
      (drain)
      (let ((susp (meow:suspend ctx)))
        ;; PROCESS-ALIVE-P is unaffected -- that's the point, so RESUME can
        ;; respawn over the same instance -- but the underlying thread
        ;; really is gone. Each ack fires just before its thread's own
        ;; unwind reaches the OS, so JOIN-THREAD (blocking, portable, same
        ;; as suite.lisp's JOIN) rather than an instantaneous
        ;; THREAD-ALIVE-P check -- ECL's own bookkeeping lags a beat behind
        ;; the ack.
        (is (meow:process-alive-p p))
        (is (meow:process-alive-p ctx))
        (bt:join-thread (meow:process-thread p))
        (bt:join-thread (meow:process-thread ctx))
        (meow:resume susp))
      (is (eq :pong (meow:call p :ping)))
      (stop-and-join ctx))))

(test resume-answers-over-the-same-process-and-registration
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (p (meow:mount ctx 'provider :reporter (meow:self))))
      (drain)
      (let ((susp (meow:suspend ctx)))
        (meow:resume susp))
      (is (eq p (meow:lookup 'provider)))
      (is (eq :pong (meow:call p :ping)))
      (stop-and-join ctx))))

(test resume-runs-no-dispose-or-status-change
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (p (meow:mount ctx 'provider :reporter (meow:self))))
      (drain)
      (let ((susp (meow:suspend ctx)))
        (meow:resume susp))
      ;; DISPOSE reports (provider :disposed reason ...); nothing of the
      ;; sort was sent across the suspend/resume
      (is (null (drain)))
      (stop-and-join ctx))))

(test resume-delivers-mail-queued-while-suspended
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (p (meow:mount ctx 'provider :reporter (meow:self))))
      (drain)
      (let ((susp (meow:suspend ctx)))
        ;; queued while parked -- dropped only if the process were dead,
        ;; which SUSPEND deliberately leaves it not being
        (meow:cast p (list :echo :queued))
        (meow:resume susp))
      (is (eq :pong (meow:call p :ping)))
      (stop-and-join ctx))))

(test nested-contexts-all-park-and-resume
  (with-fresh-registry ()
    (let* ((root (start-context))
           (inner (meow:mount root 'meow:context :name :inner))
           (p (meow:mount inner 'provider :reporter (meow:self))))
      (drain)
      (let ((susp (meow:suspend root)))
        (is (meow:process-alive-p inner))
        (is (meow:process-alive-p p))
        (meow:resume susp))
      (is (eq p (meow:lookup 'provider)))
      (is (eq :pong (meow:call p :ping)))
      (stop-and-join root))))

(test suspend-stops-the-timer-thread-and-resume-restarts-it
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (p (meow:mount ctx 'provider :reporter (meow:self)))
           (fired (bt2:make-semaphore))
           ;; MEOW::%TIMER-ADD directly, bypassing AFTER's own-process check
           ;; (an ordinary effect), since this only needs a pending cell --
           ;; not a service that owns it.
           (cell (meow::%make-timer-cell p (lambda () (bt2:signal-semaphore fired)) nil)))
      (drain)
      (setf (meow::timer-cell-release cell) (constantly nil)
            (meow::timer-cell-deadline cell) (+ (meow::%now) 0.3))
      (meow::%timer-add cell)
      (is (null (bt2:wait-on-semaphore fired :timeout 0)))
      (let ((susp (meow:suspend ctx)))
        (is-false meow::*%timer-thread*)
        (meow:resume susp))
      (is-true (bt2:wait-on-semaphore fired :timeout 1))
      (stop-and-join ctx))))

(test a-busy-handler-times-out-suspend-and-resumes-everyone
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (p (meow:mount ctx 'provider :reporter (meow:self))))
      (drain)
      (meow:cast p (list :sleep 0.4))
      (sleep 0.05)
      (signals meow:suspend-timeout (meow:suspend ctx :timeout 0.1))
      (sleep 0.5)
      (is (eq :pong (meow:call p :ping)))
      (stop-and-join ctx))))

(test suspend-timeout-reports-the-processes-that-did-not-park
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (p (meow:mount ctx 'provider :reporter (meow:self))))
      (drain)
      (meow:cast p (list :sleep 0.4))
      (sleep 0.05)
      (handler-case (progn (meow:suspend ctx :timeout 0.1) (fail "should have signalled"))
        (meow:suspend-timeout (c)
          (is (find p (meow:suspend-timeout-pending c) :key #'first))))
      (sleep 0.5)
      (stop-and-join ctx))))
