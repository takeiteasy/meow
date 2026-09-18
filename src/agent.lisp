(in-package #:meow)

(defservice agent ()
  ((parent :initarg :parent :reader agent-parent)
   (ref :initarg :ref :initform nil :reader agent-ref)
   (done :initform nil))
  (:default-initargs :name nil))

(defmethod handle :around ((agent agent) message)
  (declare (ignore message))
  (multiple-value-bind (value result) (call-next-method)
    (if (eq value :done)
        (progn (setf (slot-value agent 'done) (list result))
               result)
        value)))

(defmethod %dispatch :after ((agent agent) message)
  (declare (ignore message))
  (a:when-let ((done (slot-value agent 'done)))
    (send (agent-parent agent)
          (list :agent-done (agent-ref agent) (self) (first done)))
    (exit :done)))

(defun delegate (context class &rest initargs &key ref name &allow-other-keys)
  "Mount an agent of CLASS on CONTEXT as a :temporary child, with the caller
as its parent, and return its process. The parent gets (:agent-done ref
agent result) when the agent finishes, or (:agent-down ref reason) if it
exits any other way. NAME, if given, registers the agent."
  (let* ((parent (%require-self))
         (process (apply #'mount context class
                         :restart :temporary :name name :parent parent :ref ref
                         (a:remove-from-plist initargs :ref :name :restart)))
         (down (lambda (process reason)
                 (declare (ignore process))
                 (unless (eq reason :done)
                   (send parent (list :agent-down ref reason))))))
    (unless (add-exit-hook process down)
      (funcall down process (process-exit-reason process)))
    process))
