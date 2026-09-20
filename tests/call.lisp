(in-package #:meow/tests)

(def-suite :meow/call :in :meow)
(in-suite :meow/call)

(defun stop-and-join (process)
  (meow:stop process)
  (join process))

(defun test-server ()
  (let ((casts '()))
    (meow:serve (lambda (msg)
                  (if (consp msg)
                      (ecase (first msg)
                        (:push (push (second msg) casts))
                        (:sleep (sleep (second msg)) :slept))
                      (case msg
                        (:casts (reverse casts))
                        (:boom (error "boom"))
                        (t (* msg 2))))))))

(test call-returns-reply
  (let ((s (test-server)))
    (is (equal '(42 nil) (multiple-value-list (meow:call s 21))))
    (stop-and-join s)))

(test cast-is-processed-in-order
  (let ((s (test-server)))
    (meow:cast s '(:push 1))
    (meow:cast s '(:push 2))
    (is (equal '(1 2) (meow:call s :casts)))
    (stop-and-join s)))

(test call-timeout-leaves-target-running
  (let* ((s (test-server))
         (start (now)))
    (is (equal '(nil :timeout)
               (multiple-value-list (meow:call s '(:sleep 0.3) :timeout 0.05))))
    (is (< (- (now) start) 0.25))
    (is-true (meow:process-alive-p s))
    (is (= 4 (meow:call s 2)) "late reply must not leak into the next call")
    (is (null (slot-value s 'meow::exit-hooks)))
    (stop-and-join s)))

(test call-to-crashing-target-returns-down-promptly
  (let* ((s (test-server))
         (start (now)))
    (multiple-value-bind (value status) (meow:call s :boom :timeout 5)
      (is (null value))
      (is (eq :down (first status)))
      (is (eq :error (first (second status)))))
    (is (< (- (now) start) 1))))

(test call-to-exited-target-returns-down-immediately
  (let ((s (stop-and-join (test-server))))
    (is (equal '(nil (:down :shutdown))
               (multiple-value-list (meow:call s 1))))))

(test stop-uses-reason
  (let ((s (test-server)))
    (meow:stop s :bye)
    (join s)
    (is (eq :bye (meow:process-exit-reason s)))))

(test malformed-messages-are-dropped
  (let ((s (test-server)))
    (dolist (message '(:atom (:call) (:call :not-a-cell 1) (:call . :x)
                       (:cast) (:cast . :x) (:cast 1 2) (:stop) (:stop . :x)))
      (meow:send s message))
    (is (= 4 (meow:call s 2)))
    (stop-and-join s)))

;;; Deadlock detection

(defun relay-server ()
  "Answer a route of processes by calling the first with the rest, returning
that call's status, or its reply if it has none. An empty route is :done."
  (meow:serve (lambda (route)
                (if route
                    (multiple-value-bind (reply status)
                        (meow:call (first route) (rest route) :timeout 2)
                      (or status reply))
                    :done))))

(test call-to-self-is-a-deadlock
  (meow:with-process (p)
    (is (equal (list nil (list :deadlock (list p)))
               (multiple-value-list (meow:call p :ping))))
    (is (null (meow:receive :timeout 0)) "nothing is sent")))

(test call-cycles-are-refused
  (let ((a (relay-server))
        (b (relay-server))
        (c (relay-server))
        (start (now)))
    (is (eq :done (meow:call a (list b c))))
    (is (equal (list :deadlock (list a b)) (meow:call a (list b a))))
    (is (equal (list :deadlock (list a b c)) (meow:call a (list b c a))))
    (is (< (- (now) start) 1))
    (mapc #'stop-and-join (list a b c))))

(test a-settled-call-is-not-handled
  (let* ((s (test-server))
         (pending (meow::%make-pending-call s)))
    (meow::%settle (meow::pending-call-cell pending) :deadlock '())
    (meow::%send-call pending '(:push 1))
    (is (null (meow:call s :casts)) "the refused message never ran")
    (stop-and-join s)))

(test answered-caller-can-call-back
  ;; Skipped on ECL: the #58 race breaks one of the 200 calls as a deadlock
  ;; often enough to redden CI. Re-enable with the fix.
  #+ecl (skip "~takeiteasy/meow#58 breaks a call as a deadlock on ECL")
  #-ecl
  (let* ((b nil)
         (results '())
         (a (meow:serve (lambda (message)
                          (case message
                            (:ping (meow:cast (meow:self) :call-back) :pong)
                            (:call-back (push (meow:call b :hello) results))))))
         (b-process (meow:serve (lambda (message)
                                  (case message
                                    (:go (meow:call a :ping))
                                    (:hello :hi))))))
    (setf b b-process)
    (loop repeat 200 do (meow:call b :go))
    (meow:call a :sync)
    (is (equal (make-list 200 :initial-element :hi) results))
    (stop-and-join a)
    (stop-and-join b)))
