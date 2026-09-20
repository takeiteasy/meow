(in-package #:meow)

(defun %plugin-problems (plugin)
  (unless (slot-value plugin 'fn)
    (list "function: no function was given")))

(defservice function-plugin ()
  ((fn :initarg :function :initform nil :type (or function symbol))
   (dependencies :initarg :depends-on :initform '() :type list)
   (release :initform nil))
  (:default-initargs :name nil)
  (:validate %plugin-problems))

(defmethod service-dependencies ((plugin function-plugin))
  (slot-value plugin 'dependencies))

(defun %release-run (plugin)
  "Release the effects of PLUGIN's last run, if it has run."
  (with-slots (release) plugin
    (when release
      (funcall (shiftf release nil)))))

(defmethod ready ((plugin function-plugin))
  (%release-run plugin)
  (with-slots (fn release) plugin
    (setf release (nth-value 1 (with-effect-scope (plugin)
                                 (funcall fn plugin))))))

(defmethod dep-down ((plugin function-plugin) name reason)
  (declare (ignore name reason))
  (%release-run plugin))

(defun mount-function (context function &rest options
                       &key depends-on name restart shutdown backoff
                            backoff-max)
  "Mount FUNCTION on CONTEXT as a service of its own and return its process.
FUNCTION is called with the service once every name in DEPENDS-ON is
registered, and again whenever one of them comes back. NAME registers the
plugin; without it, it is unregistered. The mount options work as they do
for MOUNT."
  (declare (ignore restart shutdown backoff backoff-max))
  (apply #'mount context 'function-plugin
         :function function :depends-on depends-on :name name
         (a:remove-from-plist options :depends-on :name)))
