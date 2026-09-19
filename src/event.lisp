(in-package #:meow)

(defstruct (listener (:constructor make-listener (process function)))
  process function (active t))

(defstruct (delivery (:constructor make-delivery (listener args))
                     (:predicate %delivery-p))
  listener args)

(defvar *event-timeout* nil
  "Seconds EMIT-SERIAL and BAIL wait for each listener, and EMIT-PARALLEL
waits for all of them, or nil to wait forever.")

(defun %deliver (delivery)
  "Run DELIVERY's listener unless it was released after being sent."
  (let ((listener (delivery-listener delivery)))
    (when (listener-active listener)
      (apply (listener-function listener) (delivery-args delivery)))))

(defun on (service event function)
  "Call FUNCTION on SERVICE's process whenever EVENT is emitted on its
registry. The listener is an effect of SERVICE. Returns a function that
removes it early. Only callable from SERVICE's process."
  (let ((registry (service-registry service))
        (listener (make-listener (service-process service) function)))
    (effect service
            (lambda ()
              (%with-registry-lock (registry)
                (a:appendf (gethash event listeners) (list listener)))
              (lambda ()
                (setf (listener-active listener) nil)
                (%with-registry-lock (registry)
                  (a:deletef (gethash event listeners) listener)
                  (unless (gethash event listeners)
                    (remhash event listeners))))))))

(defun %listeners (target event)
  (let ((registry (if (typep target 'registry)
                      target
                      (service-registry target))))
    (%with-registry-lock (registry)
      (copy-list (gethash event listeners)))))

(defun emit (target event &rest args)
  "Send EVENT with ARGS to every listener on TARGET, a service or registry,
without waiting."
  (dolist (listener (%listeners target event))
    (cast (listener-process listener) (make-delivery listener args))))

(defun %deliver-and-wait (listener args)
  "LISTENER's result, or nil if it exited, skipped the delivery or timed out."
  (let ((delivery (make-delivery listener args))
        (process (listener-process listener)))
    (if (eq process (self))
        (%deliver delivery)
        (multiple-value-bind (value status) (call process delivery :timeout *event-timeout*)
          (unless status value)))))

(defun emit-serial (target event &rest args)
  "Call each listener for EVENT on TARGET in registration order, waiting for
each to finish."
  (dolist (listener (%listeners target event))
    (%deliver-and-wait listener args)))

(defun bail (target event &rest args)
  "Call listeners for EVENT on TARGET in order until one returns non-nil, and
return that value."
  (dolist (listener (%listeners target event))
    (a:when-let ((value (%deliver-and-wait listener args)))
      (return value))))

(defun emit-parallel (target event &rest args)
  "Send EVENT with ARGS to every listener on TARGET at once, wait for all of
them, and return their values in registration order."
  (let* ((deadline (and *event-timeout* (+ (%now) *event-timeout*)))
         (pending '()))
    (unwind-protect
         (let ((started (mapcar (lambda (listener)
                                  (let ((delivery (make-delivery listener args))
                                        (process (listener-process listener)))
                                    (if (eq process (self))
                                        delivery
                                        (car (push (%start-call process delivery)
                                                   pending)))))
                                (%listeners target event))))
           (mapcar (lambda (started)
                     (if (consp started)
                         (first started)
                         (multiple-value-bind (value status)
                             (%await-call started
                                          (and deadline
                                               (max 0 (- deadline (%now)))))
                           (unless status value))))
                   ;; A listener on the emitter's own process runs while the
                   ;; others do.
                   (mapcar (lambda (started)
                             (if (%delivery-p started)
                                 (list (%deliver started))
                                 started))
                           started)))
      (mapc #'%cancel-call pending))))
