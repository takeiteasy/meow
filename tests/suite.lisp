(in-package #:meow/tests)

(def-suite :meow)
(in-suite :meow)

(defun now ()
  (/ (get-internal-real-time) internal-time-units-per-second))

(defun waited-p (seconds elapsed)
  "True if ELAPSED covers a wait of SECONDS, allowing a clock tick short."
  (<= (- seconds 0.01) elapsed))

(defun join (process)
  (bt2:join-thread (meow:process-thread process))
  process)

(test system-loads
  (is (find-package '#:meow)))
