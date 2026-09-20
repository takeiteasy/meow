(in-package #:meow/tests)

(def-suite :meow/logger)
(in-suite :meow/logger)

(meow:defservice noisy (reporting) ())

(defmethod meow:handle ((s noisy) message)
  (destructuring-bind (level control &rest args) message
    (apply #'meow:log-message s level control args)
    :ok))

(defun start-logger (&rest initargs)
  "(values process logger stream) for a logger writing to a string."
  (let* ((stream (make-string-output-stream))
         (logger (apply #'make-instance 'meow:logger :stream stream initargs))
         (process (meow:start-service logger)))
    ;; READY, which registers the listeners, runs after START-SERVICE returns.
    (eventually (lambda () (meow:service-ready-p logger)))
    (values process logger stream)))

(defun logged (stream &optional (quiet 0.2))
  "Collect STREAM's lines until none arrive for QUIET seconds."
  (let ((text (with-output-to-string (out)
                (loop for chunk = (progn (sleep quiet)
                                         (get-output-stream-string stream))
                      while (plusp (length chunk))
                      do (write-string chunk out)))))
    (loop with text = (string-right-trim '(#\Newline) text)
          while (plusp (length text))
          for start = 0 then (1+ end)
          for end = (position #\Newline text :start start)
          collect (subseq text start end)
          while end)))

(defun quiet-p (stream)
  "True if STREAM stays empty."
  (sleep 0.3)
  (zerop (length (get-output-stream-string stream))))

(test records-at-or-above-the-level-are-written
  (with-fresh-registry ()
    (multiple-value-bind (p logger stream) (start-logger)
      (declare (ignore logger))
      (let ((n (start 'noisy :name :n)))
        (meow:call n '(:debug "quiet"))
        (is-true (quiet-p stream) "debug is below the default level")
        (meow:call n '(:info "hello ~a" 1))
        (meow:call n '(:warn "careful"))
        (meow:call n '(:error "broken"))
        (let ((lines (logged stream)))
          (is (= 3 (length lines)))
          (is (every (lambda (line) (search "N: " line)) lines)
              "each record names the service that logged it")
          (is (search "INFO  N: hello 1" (first lines)))
          (is (search "WARN  N: careful" (second lines)))
          (is (search "ERROR N: broken" (third lines))))
        (stop-and-join n))
      (stop-and-join p))))

(test the-level-can-be-lowered-to-debug
  (with-fresh-registry ()
    (multiple-value-bind (p logger stream) (start-logger :level :debug)
      (declare (ignore logger))
      (let ((n (start 'noisy :name :n)))
        (meow:call n '(:debug "loud"))
        (is (find-if (lambda (line) (search "DEBUG N: loud" line))
                     (logged stream)))
        (stop-and-join n))
      (stop-and-join p))))

(test lifecycle-is-logged-below-the-default-level
  (with-fresh-registry ()
    (multiple-value-bind (p logger stream) (start-logger)
      (declare (ignore logger))
      (let ((q (start 'provider :name :q)))
        (is-true (quiet-p stream) "lifecycle is quiet at the default level")
        (stop-and-join q))
      (stop-and-join p))))

(test lifecycle-is-logged-at-debug
  (with-fresh-registry ()
    (multiple-value-bind (p logger stream) (start-logger :level :debug)
      (declare (ignore p))
      (let ((q (start 'provider :name :q)))
        (is (find-if (lambda (line) (search "Q: starting -> waiting" line))
                     (logged stream)))
        (stop-and-join q)
        (is (find-if (lambda (line) (search "Q: stopping -> stopped" line))
                     (logged stream))))
      (stop-and-join (meow:service-process logger)))))

(test mounts-are-logged-for-the-whole-subtree
  (with-fresh-registry ()
    (let* ((stream (make-string-output-stream))
           (app (meow:start-service (make-instance 'meow:context :name :app)))
           (logger (meow:mount app 'meow:logger :stream stream :level :debug)))
      (logged stream)
      (let ((inner (meow:mount app 'meow:context :name :inner)))
        (meow:mount inner 'provider :name :q)
        (let ((lines (logged stream)))
          (is (find-if (lambda (line) (search "INNER: mounted" line)) lines))
          (is (find-if (lambda (line) (search "Q: mounted" line)) lines)
              "a grandchild's mount reaches a logger at the root"))
        (meow:unmount inner :q)
        (is (find-if (lambda (line) (search "Q: unmounted: shutdown" line))
                     (logged stream))))
      (stop-and-join app))))

(test a-teardown-failure-is-logged-as-an-error
  (with-fresh-registry ()
    (multiple-value-bind (p logger stream) (start-logger)
      (declare (ignore logger))
      (let ((e (start 'effectful :name :e)))
        (meow:call e :failing)
        (stop-and-join e)
        (drain)
        (is (search "ERROR E: teardown failed: disposer failed"
                    (first (logged stream)))))
      (stop-and-join p))))

(test the-previous-teardown-hook-is-restored
  (with-fresh-registry ()
    (let ((hook (lambda (condition source) (declare (ignore condition source)))))
      (setf meow:*teardown-error-hook* hook)
      (unwind-protect
           (let ((p (start-logger)))
             (is-true (eventually (lambda ()
                                    (not (eq hook meow:*teardown-error-hook*))))
                      "the logger claims the hook")
             (stop-and-join p)
             (is (eq hook meow:*teardown-error-hook*)))
        (setf meow:*teardown-error-hook* nil)))))

(test an-invalid-level-is-rejected
  (signals meow:invalid-config
    (make-instance 'meow:logger :level :verbose))
  (signals meow:invalid-config
    (make-instance 'meow:logger :stream :stdout)))
