(in-package #:meow/tests)

(def-suite :meow)
(in-suite :meow)

(defun now ()
  (/ (get-internal-real-time) internal-time-units-per-second))

(defun join (process)
  (bt2:join-thread (meow:process-thread process))
  process)

(test system-loads
  (is (find-package '#:meow)))
