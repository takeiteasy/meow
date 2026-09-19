(in-package #:meow)

(defstruct (listener (:constructor make-listener (service process function)))
  service process function (active t))

(defstruct (delivery (:constructor make-delivery (listener args))
                     (:predicate %delivery-p))
  listener args)

(defvar *event-timeout* nil
  "Seconds EMIT-SERIAL and BAIL wait for each listener, and EMIT-PARALLEL
waits for all of them, or nil to wait forever.")

(defvar *event-scope* :down
  "Which listeners an event on a context reaches: :down for the context and
everything mounted under it, :up for the context, its ancestors and the
services mounted directly in any of them, or :both.")

(defun %deliver (delivery)
  "Run DELIVERY's listener unless it was released after being sent."
  (let ((listener (delivery-listener delivery)))
    (when (listener-active listener)
      (apply (listener-function listener) (delivery-args delivery)))))

(defun on (service event function)
  "Call FUNCTION on SERVICE's process whenever EVENT is emitted in its
scope. The listener is an effect of SERVICE. Returns a function that
removes it early. Only callable from SERVICE's process."
  (let ((registry (service-registry service))
        (listener (make-listener service (service-process service) function)))
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

(defun %within-p (service context)
  "True if SERVICE is CONTEXT or mounted somewhere under it."
  (loop for s = service then (service-context s)
        while s
        thereis (eq s context)))

;;; TODO: walks every listener's context chain per emit, O(listeners x depth);
;;; keep listener tables per context if emit rates matter.
(defun %listeners (target event)
  (let* ((registry (if (typep target 'registry)
                       target
                       (service-registry target)))
         (context (unless (typep target 'registry)
                    (%scope target)))
         (all (%with-registry-lock (registry)
                (copy-list (gethash event listeners)))))
    (if context
        (flet ((down (listener) (%within-p (listener-service listener) context))
               (up (listener)
                 (let ((service (listener-service listener)))
                   (or (%within-p context service)
                       (%within-p context (service-context service))))))
          (remove-if-not (ecase *event-scope*
                           (:down #'down)
                           (:up #'up)
                           (:both (lambda (listener)
                                    (or (down listener) (up listener)))))
                         all))
        all)))

(defun emit (target event &rest args)
  "Send EVENT with ARGS to every listener in TARGET's scope without waiting.
TARGET is a registry, a context, or a service, meaning the context it is
mounted in."
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
  (let ((deadline (and *event-timeout* (+ (%now) *event-timeout*)))
        (deliveries (mapcar (lambda (listener) (make-delivery listener args))
                            (%listeners target event)))
        (calls '()))
    (unwind-protect
         (progn
           (setf calls (mapcar (lambda (delivery)
                                 (let ((process (listener-process
                                                 (delivery-listener delivery))))
                                   (unless (eq process (self))
                                     (%start-call process delivery))))
                               deliveries))
           (let ((own (mapcar (lambda (delivery call)
                                (unless call (%deliver delivery)))
                              deliveries calls)))
             (mapcar (lambda (call value)
                       (if call
                           (multiple-value-bind (value status)
                               (%await-call call (and deadline
                                                      (max 0 (- deadline (%now)))))
                             (unless status value))
                           value))
                     calls own)))
      (mapc #'%cancel-call (remove nil calls)))))
