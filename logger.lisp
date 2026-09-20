(in-package #:meow)

(defparameter +log-levels+ '(:debug :info :warn :error)
  "Log levels, least to most severe.")

(deftype log-level () '(member :debug :info :warn :error))

(defun %level-at-least (level threshold)
  (>= (position level +log-levels+) (position threshold +log-levels+)))

;;; TODO: the message is formatted whether or not a logger is listening or
;;; would keep it; pass the control string and args through the event and
;;; format in the logger if log rates matter.
(defun log-message (service level control &rest args)
  "Emit CONTROL, formatted with ARGS, as a LEVEL record from SERVICE."
  (a:when-let ((registry (service-registry service)))
    (emit (%root registry) :meow/log level (service-name service)
          (apply #'format nil control args) (get-universal-time)))
  nil)

(macrolet ((define-level (name level)
             `(defun ,name (service control &rest args)
                ,(format nil "Log CONTROL, formatted with ARGS, at ~(~a~)."
                         level)
                (apply #'log-message service ,level control args))))
  (define-level log-debug :debug)
  (define-level log-info :info)
  (define-level log-warn :warn)
  (define-level log-error :error))

(defservice logger ()
  ((stream :initarg :stream :initform *error-output* :reader logger-stream
           :type stream)
   (level :initarg :level :initform :info :accessor logger-level
          :type log-level)
   (lifecycle :initarg :lifecycle :initform :debug :accessor logger-lifecycle
              :type log-level)))

(defun %log-time (universal-time)
  (multiple-value-bind (second minute hour date month year)
      (decode-universal-time universal-time)
    (format nil "~d-~2,'0d-~2,'0d ~2,'0d:~2,'0d:~2,'0d"
            year month date hour minute second)))

(defun %write-record (logger level name message time)
  (when (%level-at-least level (logger-level logger))
    (let ((stream (logger-stream logger)))
      (format stream "~&~a ~5a ~@[~a: ~]~a~%"
              (%log-time time) level name message)
      (finish-output stream))))

(defun %note (logger name control &rest args)
  (%write-record logger (logger-lifecycle logger) name
                 (apply #'format nil control args)
                 (get-universal-time)))

(defun %readable (reason)
  "REASON as it reads in a record: keywords lowercased, anything else as is."
  (if (keywordp reason) (string-downcase reason) reason))

(defun %source-name (source)
  "The name to log a teardown failure of SOURCE under."
  (typecase source
    (service (service-name source))
    (process (process-name source))))

(defun %claim-teardown-hook (logger)
  "Report teardown failures as log records for as long as LOGGER runs. The
hook is read globally and runs on the failing thread, so it only emits."
  (let ((registry (%root (service-registry logger)))
        (previous *teardown-error-hook*))
    (setf *teardown-error-hook*
          (lambda (condition source)
            (emit registry :meow/log :error (%source-name source)
                  (format nil "teardown failed: ~a" condition)
                  (get-universal-time))))
    (lambda () (setf *teardown-error-hook* previous))))

(defmethod ready ((s logger))
  (on s :meow/log (lambda (level name message time)
                    (%write-record s level name message time)))
  (on s :meow/status (lambda (name process old new)
                       (declare (ignore process))
                       (%note s name "~(~a~) -> ~(~a~)" old new)))
  (on s :meow/mount (lambda (name process)
                      (declare (ignore process))
                      (%note s name "mounted")))
  (on s :meow/unmount (lambda (name process reason)
                        (declare (ignore process))
                        (%note s name "unmounted: ~a" (%readable reason))))
  (effect s (lambda () (%claim-teardown-hook s))))
