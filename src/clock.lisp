(in-package #:meow)

(defvar *clock* (thpt:make-precision-timer)
  "The monotonic clock every deadline in MEOW is measured against.")

(defun %now ()
  "Seconds on *CLOCK*. Only differences between two readings mean anything."
  (thpt:sec *clock* (thpt:now *clock*)))
