(in-package #:meow/tests)

(def-suite :meow)
(in-suite :meow)

(defun now ()
  (/ (get-internal-real-time) internal-time-units-per-second))

(defmacro as-process (&body body)
  "Run BODY as a process, for tests that call or receive outside a service."
  `(meow:with-process (%process)
     %process
     ,@body))

(defun waited-p (seconds elapsed)
  "True if ELAPSED covers a wait of SECONDS, allowing a clock tick short."
  (<= (- seconds 0.01) elapsed))

(defun join (process)
  (bt:join-thread (meow:process-thread process))
  process)

(test system-loads
  (is (find-package '#:meow)))
