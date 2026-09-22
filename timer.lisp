(in-package #:meow)

(defstruct (timer-cell (:constructor %make-timer-cell (process function period)))
  process function period deadline release (active t))

(defvar *%timer-lock* (bt2:make-lock :name "meow timer"))
(defvar *%timer-cv* (bt2:make-condition-variable))

(defvar *%timer-cells* '()
  "The pending cells, soonest deadline first.")

(defvar *%timer-thread* nil
  "The thread firing timers, or nil while nothing is pending.")

(defun %timer-due ()
  "The cells that have come due, waiting for the soonest one. Nil once
nothing is pending, which ends the timer thread."
  (bt2:with-lock-held (*%timer-lock*)
    (loop for now = (%now)
          for due = (loop while (and *%timer-cells*
                                     (<= (timer-cell-deadline (first *%timer-cells*))
                                         now))
                          collect (pop *%timer-cells*))
          when due
            return due
          do (if *%timer-cells*
                 (bt2:condition-wait
                  *%timer-cv* *%timer-lock*
                  :timeout (float (- (timer-cell-deadline (first *%timer-cells*))
                                     now)
                                  1d0))
                 (return (setf *%timer-thread* nil))))))

(defun %timer-loop ()
  "Cast each due cell to its own process. The cell is only ever enqueued
here; it runs where it can be cancelled safely."
  (loop for due = (%timer-due)
        while due
        do (dolist (cell due)
             (cast (timer-cell-process cell) (list '%timer-fire cell)))))

(defun %timer-add (cell)
  "Queue CELL, starting the timer thread if it is not running."
  (bt2:with-lock-held (*%timer-lock*)
    (setf *%timer-cells* (merge 'list *%timer-cells* (list cell) #'<
                                :key #'timer-cell-deadline))
    (bt2:condition-notify *%timer-cv*)
    (unless *%timer-thread*
      (setf *%timer-thread* (bt:make-thread #'%timer-loop :name "meow timer")))))

(defun %timer-remove (cell)
  (bt2:with-lock-held (*%timer-lock*)
    (a:deletef *%timer-cells* cell :test #'eq)
    (bt2:condition-notify *%timer-cv*)))

(defun %timer-fire (cell)
  "Run CELL's function, then re-arm it or drop it. Runs on the service's own
process, so a cancellation cannot race the call."
  (when (timer-cell-active cell)
    (if (timer-cell-period cell)
        (progn
          (funcall (timer-cell-function cell))
          (when (timer-cell-active cell)
            (setf (timer-cell-deadline cell) (+ (%now) (timer-cell-period cell)))
            (%timer-add cell)))
        (progn
          ;; Released first, so a function that stops the service doesn't
          ;; leave the spent timer to unwind with the rest.
          (funcall (timer-cell-release cell))
          (funcall (timer-cell-function cell))))))

(defun %timer (service seconds function period label)
  (check-type seconds (real 0))
  (let* ((cell (%make-timer-cell (service-process service) function period))
         (release (effect service
                          (lambda ()
                            (setf (timer-cell-deadline cell) (+ (%now) seconds))
                            (%timer-add cell)
                            (lambda ()
                              (setf (timer-cell-active cell) nil)
                              (%timer-remove cell)))
                          :label label)))
    (setf (timer-cell-release cell) release)
    release))

(defun after (service seconds function &key label)
  "Call FUNCTION on SERVICE's process once, SECONDS from now. It is an effect
of SERVICE, labelled (:AFTER SECONDS) unless LABEL says otherwise, and is
released once it fires. Returns a function that cancels it. Only callable
from SERVICE's process."
  (%timer service seconds function nil (or label (list :after seconds))))

(defun repeat (service seconds function &key label)
  "Call FUNCTION on SERVICE's process every SECONDS, starting SECONDS from
now. The next call is scheduled once FUNCTION returns, so a slow FUNCTION
delays the next one rather than queueing them. It is an effect of SERVICE,
labelled (:REPEAT SECONDS) unless LABEL says otherwise. Returns a function
that cancels it. Only callable from SERVICE's process."
  (%timer service seconds function seconds (or label (list :repeat seconds))))
