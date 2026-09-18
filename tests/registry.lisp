(in-package #:meow/tests)

;;; Ported from patchbay_registry_tests. Each test binds a fresh registry.

(def-suite :meow/registry :in :meow)
(in-suite :meow/registry)

(defmacro with-fresh-registry ((&optional (var (gensym))) &body body)
  `(let* ((,var (make-instance 'meow:registry))
          (meow:*registry* ,var))
     (declare (ignorable ,var))
     (meow:with-process (me)
       ,@body)))

(defun parked-process ()
  "A process that exits with the first message it receives: (:error) makes it
fail, anything else is used as the exit reason."
  (meow:spawn (lambda ()
                (let ((message (meow:receive)))
                  (if (eq message :error)
                      (error "boom")
                      (meow:exit message))))))

(defun registry-table-empty-p (registry slot)
  (zerop (hash-table-count (slot-value registry slot))))

(test register-lookup-unregister-roundtrip
  (with-fresh-registry ()
    (is-true (meow:register :svc (meow:self) :props '(:k :v)))
    (is (equal (list (meow:self) '(:k :v))
               (multiple-value-list (meow:lookup :svc))))
    (is (equal '(:svc) (meow:names)))
    (is-true (meow:unregister :svc))
    (is (null (meow:lookup :svc)))))

(test duplicate-registration-of-live-process-signals
  (with-fresh-registry ()
    (meow:register :svc (meow:self))
    (handler-case (progn (meow:register :svc (meow:self))
                         (fail "no condition signalled"))
      (meow:already-registered (c)
        (is (eq :svc (meow:already-registered-name c)))
        (is (eq (meow:self) (meow:already-registered-owner c)))))))

(test register-of-exited-process-is-noproc
  (with-fresh-registry ()
    (let ((p (join (meow:spawn (lambda ())))))
      (is (equal '(nil :noproc) (multiple-value-list (meow:register :svc p))))
      (is (null (meow:names))))))

(test await-returns-immediately-when-present
  (with-fresh-registry ()
    (meow:register :svc (meow:self))
    (is (eq (meow:self) (meow:await :svc :timeout 1)))))

(test await-times-out
  (with-fresh-registry ()
    (let ((start (now)))
      (is (equal '(nil :timeout)
                 (multiple-value-list (meow:await :nope :timeout 0.1))))
      (is (<= 0.09 (- (now) start) 1)))))

(test await-wakes-on-later-registration
  (with-fresh-registry (registry)
    (let ((p (parked-process)))
      (bt2:make-thread (lambda ()
                         (sleep 0.05)
                         (meow:register :svc p :registry registry)))
      (is (eq p (meow:await :svc :timeout 5)))
      (meow:send p :normal)
      (join p))))

(test subscribe-replays-existing-registration
  (with-fresh-registry ()
    (meow:register :svc (meow:self))
    (meow:subscribe :svc)
    (is (equal (list :registered :svc (meow:self))
               (meow:receive :timeout 0)))))

(test subscribe-to-absent-name-waits-for-registration
  (with-fresh-registry ()
    (meow:subscribe :svc)
    (is (null (nth-value 1 (meow:receive :timeout 0.1))))
    (meow:register :svc (meow:self))
    (is (equal (list :registered :svc (meow:self))
               (meow:receive :timeout 1)))))

(test subscriber-exit-drops-its-subscriptions
  (with-fresh-registry (registry)
    (join (meow:spawn (lambda ()
                        (meow:subscribe :a :registry registry)
                        (meow:subscribe :b :registry registry))))
    (is (registry-table-empty-p registry 'meow::subscribers))
    (is (registry-table-empty-p registry 'meow::subscriber-hooks))))

(test unsubscribe-stops-notifications
  (with-fresh-registry (registry)
    (meow:subscribe :svc)
    (meow:unsubscribe :svc)
    (meow:register :svc (meow:self))
    (is (null (nth-value 1 (meow:receive :timeout 0.1))))
    (is (registry-table-empty-p registry 'meow::subscriber-hooks))))

(test registrant-exit-unregisters-and-notifies
  ;; Subscribe first so the only :registered message is the real one.
  (with-fresh-registry ()
    (meow:subscribe :svc)
    (let ((p (parked-process)))
      (meow:register :svc p)
      (is (equal (list :registered :svc p) (meow:receive :timeout 1)))
      (meow:send p :error)
      (destructuring-bind (tag name reason) (meow:receive :timeout 1)
        (is (eq :unregistered tag))
        (is (eq :svc name))
        (is (eq :error (first reason))))
      (is (null (meow:lookup :svc))))))

(test re-registration-survives-stale-exit-cleanup
  ;; The old process is dead but its registry cleanup has not run yet when
  ;; the replacement registers. The late cleanup must leave the new
  ;; registration alone.
  (with-fresh-registry ()
    (let* ((reached (bt2:make-semaphore))
           (gate (bt2:make-semaphore))
           (old (parked-process))
           (new (parked-process)))
      ;; Hooks run in the order they were added: this one stalls old's exit
      ;; before the registry's cleanup hook runs.
      (meow:add-exit-hook old (lambda (process reason)
                                (declare (ignore process reason))
                                (bt2:signal-semaphore reached)
                                (bt2:wait-on-semaphore gate)))
      (meow:register :svc old)
      (meow:subscribe :svc)
      (is (equal (list :registered :svc old) (meow:receive :timeout 1)))
      (meow:send old :killed)
      (bt2:wait-on-semaphore reached)
      (is-true (meow:register :svc new))
      (is (equal (list :registered :svc new) (meow:receive :timeout 1)))
      (bt2:signal-semaphore gate)
      (join old)
      (is (eq new (meow:lookup :svc)))
      (is (= 1 (length (slot-value new 'meow::exit-hooks))))
      (is (null (nth-value 1 (meow:receive :timeout 0.2)))
          "no :unregistered for the live replacement")
      (meow:send new :normal)
      (join new))))
