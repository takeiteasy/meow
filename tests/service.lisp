(in-package #:meow/tests)

;;; Ported from patchbay_service_tests and nyaa's demo provider/consumer
;;; pair. Services report (name event ...) to the test process.

(def-suite :meow/service :in :meow)
(in-suite :meow/service)

(defclass reporting ()
  ((reporter :initarg :reporter :initform nil :reader reporter)))

(meow:defservice provider (reporting) ())

(meow:defservice consumer (reporting)
  ()
  (:depends-on provider))

(meow:defservice renamed-provider (provider)
  ()
  (:name :echo))

(defun report (service &rest event)
  (when (reporter service)
    (meow:send (reporter service) (list* (meow:service-name service) event))))

(defmethod meow:metadata ((s provider))
  '(:kind :tool))

(defmethod meow:ready ((s provider))
  (report s :ready))

(defmethod meow:ready ((s consumer))
  (report s :ready (meow:dependency s 'provider)))

(defmethod meow:dep-down ((s consumer) name reason)
  (report s :dep-down name reason))

(defmethod meow:dispose ((s reporting) reason)
  (report s :disposed reason
          (meow:lookup (meow:service-name s)
                       :registry (meow:service-registry s))))

(defmethod meow:handle ((s provider) message)
  (if (consp message)
      (ecase (first message)
        (:echo (second message))
        (:sleep (sleep (second message)) :slept))
      (ecase message
        (:ping :pong)
        (:boom (error "boom")))))

(defun start (class &rest initargs)
  (let ((service (apply #'make-instance class :reporter (meow:self) initargs)))
    (values (meow:start-service service) service)))

(defun drain (&optional (quiet 0.2))
  "Collect messages until none arrive for QUIET seconds."
  (loop for (message received) = (multiple-value-list
                                   (meow:receive :timeout quiet))
        while received
        collect message))

(defun has (message messages)
  (member message messages :test #'equal))

(test defservice-options
  (let ((s (make-instance 'renamed-provider)))
    (is (eq :echo (meow:service-name s)))
    (is (null (meow:service-dependencies s)))
    (is (equal '(provider)
               (meow:service-dependencies (make-instance 'consumer))))
    (is (eq 'provider (meow:service-name (make-instance 'provider))))))

(test provider-without-dependencies-becomes-ready
  (with-fresh-registry ()
    (let ((p (start 'provider)))
      (is (equal '(provider :ready) (meow:receive :timeout 1)))
      (stop-and-join p))))

(test consumer-mounted-before-provider-becomes-ready
  (with-fresh-registry ()
    (multiple-value-bind (c consumer) (start 'consumer)
      (is (null (drain 0.1)) "not ready without its dependency")
      (is (not (meow:service-ready-p consumer)))
      (let* ((p (start 'provider))
             (messages (drain)))
        (is (has (list 'consumer :ready p) messages))
        (is (has '(provider :ready) messages))
        (is-true (meow:service-ready-p consumer))
        (stop-and-join c)
        (stop-and-join p)))))

(test provider-mounted-before-consumer-becomes-ready
  (with-fresh-registry ()
    (let ((p (start 'provider)))
      (is (equal '(provider :ready) (meow:receive :timeout 1)))
      (let ((c (start 'consumer)))
        (is (equal (list 'consumer :ready p) (meow:receive :timeout 1)))
        (stop-and-join c)
        (stop-and-join p)))))

(test provider-exit-triggers-dep-down-then-re-ready
  (with-fresh-registry ()
    (multiple-value-bind (c consumer) (start 'consumer)
      (let ((p (start 'provider)))
        (drain)
        (meow:stop p :killed)
        (join p)
        (let ((messages (drain)))
          (is (has '(consumer :dep-down provider :killed) messages))
          (is (has (list 'provider :disposed :killed p) messages)))
        (is (null (meow:dependency consumer 'provider)))
        (let* ((p2 (start 'provider))
               (messages (drain)))
          (is (has (list 'consumer :ready p2) messages))
          (is (eq p2 (meow:dependency consumer 'provider)))
          (stop-and-join p2))
        (stop-and-join c)))))

(test stop-disposes-then-unregisters
  (with-fresh-registry ()
    (let ((c (start 'consumer)))
      (stop-and-join c)
      (is (equal (list 'consumer :disposed :shutdown c)
                 (meow:receive :timeout 1))
          "still registered while disposing")
      (is (null (meow:lookup 'consumer))))))

(test metadata-is-published-as-props
  (with-fresh-registry ()
    (let ((p (start 'provider)))
      (is (equal '(:kind :tool) (nth-value 1 (meow:lookup 'provider))))
      (stop-and-join p))))

(test call-reaches-handle
  (with-fresh-registry ()
    (let ((p (start 'provider)))
      (is (eq :pong (meow:call p :ping)))
      (is (eq :x (meow:call p '(:echo :x))))
      (stop-and-join p))))

(test stray-messages-are-ignored
  (with-fresh-registry ()
    (let ((p (start 'provider)))
      (dolist (message '(:atom (1 2 3 4) (:a . :b) (:registered)))
        (meow:send p message))
      (is (eq :pong (meow:call p :ping)))
      (stop-and-join p))))

(test call-timeout-leaves-service-running
  (with-fresh-registry ()
    (let ((p (start 'provider)))
      (is (equal '(nil :timeout)
                 (multiple-value-list (meow:call p '(:sleep 0.3) :timeout 0.05))))
      (is (eq :x (meow:call p '(:echo :x))))
      (stop-and-join p))))

(test handle-error-stops-and-disposes
  (with-fresh-registry ()
    (let ((p (start 'provider)))
      (drain)
      (multiple-value-bind (value status) (meow:call p :boom)
        (is (null value))
        (is (eq :down (first status)))
        (is (eq :error (first (second status)))))
      (join p)
      (destructuring-bind (name event reason owner) (meow:receive :timeout 1)
        (is (eq 'provider name))
        (is (eq :disposed event))
        (is (eq :error (first reason)))
        (is (eq p owner)))
      (is (null (meow:lookup 'provider))))))

(test duplicate-name-signals-in-caller
  (with-fresh-registry ()
    (let ((p (start 'provider))
          (duplicate (make-instance 'provider :reporter (meow:self))))
      (drain)
      (handler-case (progn (meow:start-service duplicate)
                           (fail "no condition signalled"))
        (meow:already-registered (c)
          (is (eq p (meow:already-registered-owner c)))))
      (is (not (meow:process-alive-p (meow:service-process duplicate))))
      (is (null (drain 0.1)) "a service that never registered is not disposed")
      (is (eq p (meow:lookup 'provider)))
      (stop-and-join p))))

(test service-uses-its-own-registry
  (with-fresh-registry ()
    (let* ((registry (make-instance 'meow:registry))
           (c (meow:start-service (make-instance 'consumer :reporter (meow:self))
                                  :registry registry))
           (p (meow:start-service (make-instance 'provider :reporter (meow:self))
                                  :registry registry)))
      (is (has (list 'consumer :ready p) (drain)))
      (is (null (meow:names)))
      (is (null (set-exclusive-or '(consumer provider)
                                  (meow:names :registry registry))))
      (stop-and-join c)
      (stop-and-join p))))
