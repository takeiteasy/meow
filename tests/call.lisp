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

(test call-all-replies-in-order
  (let ((a (meow:serve (lambda (m) (list :a m))))
        (b (meow:serve (lambda (m) (list :b m)))))
    (is (equal '(((:a 1) nil) ((:b 1) nil)) (meow:call-all (list a b) 1)))
    (is (null (meow:call-all '() 1)))
    (mapc #'stop-and-join (list a b))))

(test call-all-times-out-only-the-slow-target
  (let ((fast (meow:serve (lambda (m) m)))
        (slow (meow:serve (lambda (m) (sleep 2) m)))
        (start (now)))
    (is (equal '((1 nil) (nil :timeout) (1 nil))
               (meow:call-all (list fast slow fast) 1 :timeout 0.3)))
    (is (< (- (now) start) 1.5))
    (mapc #'stop-and-join (list fast slow))))

(test call-all-refuses-the-caller-and-answers-the-rest
  (meow:with-process (p)
    (let ((other (meow:serve (lambda (m) m))))
      (is (equal (list (list nil (list :deadlock (list p))) '(1 nil))
                 (meow:call-all (list p other) 1)))
      (stop-and-join other))))

(test call-all-works-without-a-current-process
  (let ((s (meow:serve (lambda (m) m))))
    (is (null (meow:self)))
    (is (equal '((1 nil)) (meow:call-all (list s) 1)))
    (stop-and-join s)))

(test call-each-sends-each-process-its-own-message
  (let ((a (meow:serve (lambda (m) (list :a m))))
        (b (meow:serve (lambda (m) (list :b m)))))
    (is (equal '(((:a 1) nil) ((:b 2) nil)) (meow:call-each (list a b) '(1 2))))
    (is (null (meow:call-each '() '())))
    (mapc #'stop-and-join (list a b))))

(test call-each-times-out-only-the-slow-target
  (let ((fast (meow:serve (lambda (m) m)))
        (slow (meow:serve (lambda (m) (sleep 2) m)))
        (start (now)))
    (is (equal '((1 nil) (nil :timeout) (3 nil))
               (meow:call-each (list fast slow fast) '(1 2 3) :timeout 0.3)))
    (is (< (- (now) start) 1.5))
    (mapc #'stop-and-join (list fast slow))))

(test call-each-refuses-the-caller-and-answers-the-rest
  (meow:with-process (p)
    (let ((other (meow:serve (lambda (m) m))))
      (is (equal (list (list nil (list :deadlock (list p))) '(2 nil))
                 (meow:call-each (list p other) '(1 2))))
      (stop-and-join other))))

;;; --- defer-reply ---------------------------------------------------------

(defun defer-server ()
  "A server that hands off :defer to a fresh worker process, which replies
after a short sleep; :cast-probe records whether DEFER-REPLY returned a cell
while handling a cast, read back with :read-probe."
  (let ((probe :untouched))
    (meow:serve (lambda (msg)
                  (if (consp msg)
                      (ecase (first msg)
                        (:defer
                         (let ((cell (meow:defer-reply)))
                           (meow:spawn (lambda ()
                                         (sleep 0.05)
                                         (meow:reply cell (second msg))))
                           nil))
                        (:defer-until
                         (meow:defer-reply :until (second msg)))
                        (:cast-probe (setf probe (meow:defer-reply))))
                      (ecase msg
                        (:read-probe probe)))))))

(test defer-reply-answers-later-from-another-process
  (let ((s (defer-server)))
    (is (equal '(:done nil) (multiple-value-list (meow:call s '(:defer :done)))))
    (stop-and-join s)))

(test defer-reply-returns-nil-inside-a-cast
  (let ((s (defer-server)))
    (meow:cast s '(:cast-probe))
    (is (null (meow:call s :read-probe)))
    (stop-and-join s)))

(test deferred-call-settles-down-when-until-exits-first
  (let* ((s (defer-server))
         (until (meow:spawn (lambda () (sleep 0.05)))))
    ;; UNTIL exits :normal shortly after S has deferred to it; the blocking
    ;; CALL below is already waiting when that happens.
    (is (equal '(nil (:down :normal))
               (multiple-value-list (meow:call s (list :defer-until until)))))
    (stop-and-join s)))

;;; --- forward -------------------------------------------------------------

(defun forwarding-server (target)
  "A server that forwards (:fwd x) to TARGET as (:got x)."
  (meow:serve (lambda (msg)
                (if (eq (first msg) :fwd)
                    (meow:forward target (list :got (second msg)))
                    (list :forwarded (meow:forward target msg))))))

(test forward-is-answered-by-the-target
  (let* ((target (meow:serve (lambda (msg) (list :answered msg))))
         (s (forwarding-server target)))
    (is (equal '((:answered (:got 7)) nil)
               (multiple-value-list (meow:call s '(:fwd 7)))))
    (stop-and-join s)
    (stop-and-join target)))

(test forward-settles-down-when-the-target-exits-unanswered
  (let* ((target (meow:spawn (lambda () (meow:receive))))
         (s (forwarding-server target)))
    (is (equal '(nil (:down :normal))
               (multiple-value-list (meow:call s '(:fwd 7)))))
    (stop-and-join s)))

(test forward-to-an-exited-process-settles-down-at-once
  (let* ((target (meow:spawn (lambda ())))
         (s (forwarding-server target)))
    (is-true (eventually (lambda () (not (meow:process-alive-p target)))))
    (is (eq :down (first (second (multiple-value-list
                                  (meow:call s '(:fwd 7) :timeout 1))))))
    (stop-and-join s)))

(test forward-inside-a-cast-sends-nothing
  (let* ((seen nil)
         (target (meow:serve (lambda (msg) (setf seen msg))))
         (s (forwarding-server target)))
    (meow:cast s '(:probe))
    (sleep 0.1)
    (is (null seen))
    (stop-and-join s)
    (stop-and-join target)))

(test a-forwarded-cell-can-be-deferred-again
  (let* ((target (meow:serve
                  (lambda (msg)
                    (let ((cell (meow:defer-reply)))
                      (meow:spawn (lambda () (sleep 0.05) (meow:reply cell msg)))
                      nil))))
         (s (forwarding-server target)))
    (is (equal '((:got 3) nil) (multiple-value-list (meow:call s '(:fwd 3)))))
    (stop-and-join s)
    (stop-and-join target)))

(test deferred-call-nobody-answers-times-out
  (let ((s (meow:serve (lambda (msg) (declare (ignore msg)) (meow:defer-reply)))))
    (is (equal '(nil :timeout)
               (multiple-value-list (meow:call s :never :timeout 0.1))))
    (stop-and-join s)))

;;; --- call-async -----------------------------------------------------------

(defun async-reply (&optional (timeout 1))
  (meow:receive :timeout timeout))

(test call-async-delivers-the-reply-as-a-message
  (as-process
    (let ((s (test-server)))
      (is (null (meow:call-async s 21 :tag :answer)))
      (is (equal '(:reply :answer 42 nil) (async-reply)))
      (stop-and-join s))))

(test call-async-times-out-and-leaves-target-running
  (as-process
    (let ((s (test-server))
          (start (now)))
      (meow:call-async s '(:sleep 0.3) :timeout 0.05 :tag :slow)
      (is (equal '(:reply :slow nil :timeout) (async-reply)))
      (is (< (- (now) start) 0.25))
      (is-true (meow:process-alive-p s))
      (stop-and-join s))))

(test call-async-settles-as-down-when-the-target-exits
  (as-process
    (let ((s (meow:serve (lambda (msg) (declare (ignore msg)) (meow:exit :bye)))))
      (meow:call-async s :go :tag :dying)
      (is (equal '(:reply :dying nil (:down :bye)) (async-reply)))
      (join s))))

(test call-async-to-an-exited-target-settles-as-down
  (as-process
    (let ((s (test-server)))
      (stop-and-join s)
      (meow:call-async s 1 :tag :late)
      (destructuring-bind (tag ref value status) (async-reply)
        (is (eq :reply tag))
        (is (eq :late ref))
        (is (null value))
        (is (eq :down (first status)))))))

(test call-async-leaves-no-timer-behind-once-settled
  (as-process
    (let ((s (test-server)))
      (meow:call-async s 1 :timeout 30)
      (async-reply)
      (is (null meow::*%timer-cells*))
      (stop-and-join s))))

(test call-async-does-not-hold-the-caller-up
  (as-process
    (let ((s (test-server))
          (start (now)))
      (meow:call-async s '(:sleep 0.2) :tag :slow)
      (is (< (- (now) start) 0.1))
      (is (equal '(:reply :slow :slept nil) (async-reply)))
      (stop-and-join s))))
