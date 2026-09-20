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

(defvar +%skipped+ '#:skipped
  "What %DELIVER returns for a listener released before its delivery arrived.
It travels back through the reply cell, so it has to be a value rather than a
second return value.")

(defun %unskip (value)
  (unless (eq value +%skipped+) value))

(defun %deliver (delivery)
  "Run DELIVERY's listener, or return +%SKIPPED+ if it was released after
being sent."
  (let ((listener (delivery-listener delivery)))
    (if (listener-active listener)
        (apply (listener-function listener) (delivery-args delivery))
        +%skipped+)))

(defun on (service event function &key prepend)
  "Call FUNCTION on SERVICE's process whenever EVENT is emitted in its
scope. The listener runs after the ones already registered for EVENT, or
before them with PREPEND. It is an effect of SERVICE. Returns a function that
removes it early. Only callable from SERVICE's process."
  (let ((registry (%root (service-registry service)))
        (listener (make-listener service (service-process service) function)))
    (effect service
            (lambda ()
              (%with-registry-lock (registry)
                (if prepend
                    (push listener (gethash event listeners))
                    (a:appendf (gethash event listeners) (list listener))))
              (lambda ()
                (setf (listener-active listener) nil)
                (%with-registry-lock (registry)
                  (a:deletef (gethash event listeners) listener)
                  (unless (gethash event listeners)
                    (remhash event listeners))))))))

(defun once (service event function &key prepend)
  "Like ON, but the listener is removed before its first delivery runs, so
FUNCTION is called at most once."
  (let ((release nil))
    (setf release (on service event
                      (lambda (&rest args)
                        (funcall release)
                        (apply function args))
                      :prepend prepend))))

(defun %within-p (service context)
  "True if SERVICE is CONTEXT or mounted somewhere under it."
  (loop for s = service then (service-context s)
        while s
        thereis (eq s context)))

;;; TODO: walks every listener's context chain per emit, O(listeners x depth);
;;; keep listener tables per context if emit rates matter.
(defun %listeners (target event)
  (let* ((registry (%root (if (typep target 'registry)
                              target
                              (service-registry target))))
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

(defun %deliver-and-wait* (listener args)
  "(values result ran-p) for LISTENER. RAN-P is nil only when the listener
body cannot have started: it was released before the delivery arrived, or the
call would have closed a wait cycle and was never sent. One that times out,
errors or exits has already started."
  (let ((delivery (make-delivery listener args))
        (process (listener-process listener)))
    (flet ((ran (value) (values (%unskip value) (not (eq value +%skipped+)))))
      (if (eq process (self))
          (ran (%deliver delivery))
          (multiple-value-bind (value status)
              (call process delivery :timeout *event-timeout*)
            (cond ((null status) (ran value))
                  ((and (consp status) (eq (first status) :deadlock))
                   (values nil nil))
                  (t (values nil t))))))))

(defun %deliver-and-wait (listener args)
  "LISTENER's result, or nil if it exited, skipped the delivery or timed out."
  (values (%deliver-and-wait* listener args)))

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
           (setf calls (%begin-calls
                        (mapcar (lambda (delivery)
                                  (let ((process (listener-process
                                                  (delivery-listener delivery))))
                                    (unless (eq process (self))
                                      process)))
                                deliveries)))
           (mapc (lambda (call delivery)
                   (when (pending-call-p call)
                     (%send-call call delivery)))
                 calls deliveries)
           (let ((own (mapcar (lambda (delivery call)
                                (unless call (%unskip (%deliver delivery))))
                              deliveries calls)))
             (mapcar (lambda (call value)
                       (cond ((pending-call-p call)
                              (multiple-value-bind (value status)
                                  (%await-call call (and deadline
                                                         (max 0 (- deadline (%now)))))
                                (unless status (%unskip value))))
                             (call nil)
                             (t value)))
                     calls own)))
      (%end-calls calls))))

(defun %waterfall (listeners inner args)
  (if (null listeners)
      (apply inner args)
      (flet ((next (&rest next-args)
               (%waterfall (rest listeners) inner (or next-args args))))
        (multiple-value-bind (value ran)
            (%deliver-and-wait* (first listeners) (append args (list #'next)))
          (if ran
              value
              (%waterfall (rest listeners) inner args))))))

(defun waterfall (target event inner &rest args)
  "Run the listeners for EVENT on TARGET as a chain. Each is called with ARGS
and a NEXT function; NEXT runs the rest of the chain, and the innermost one
calls INNER with the args it has reached. NEXT without arguments keeps the
current ones. A listener that returns without calling NEXT ends the chain, and
its value is what WATERFALL returns. A listener that cannot have run is
skipped, so INNER still runs."
  (%waterfall (%listeners target event) inner args))
