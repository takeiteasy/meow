(in-package #:meow)

;;; Native filesystem events. The only entry points are %WATCH-SUPPORTED-P
;;; and %WATCH; everything else here is one backend's plumbing.

#+darwin
(progn
  (defconstant +evfilt-vnode+ -4)
  (defconstant +evfilt-user+ -10)
  (defconstant +ev-add+ #x0001)
  (defconstant +ev-enable+ #x0004)
  (defconstant +ev-clear+ #x0020)
  (defconstant +note-trigger+ #x01000000)
  (defconstant +note-vnode+ #x0000006f
    "DELETE, WRITE, EXTEND, ATTRIB, LINK, RENAME and REVOKE together.")
  (defconstant +o-evtonly+ #x8000
    "Open for events alone, so a watched file doesn't pin its volume.")

  (cffi:defcstruct kevent
    (ident :uintptr)
    (filter :int16)
    (flags :uint16)
    (fflags :uint32)
    (data :intptr)
    (udata :pointer))

  (cffi:defcstruct timespec
    (seconds :long)
    (nanoseconds :long))

  (cffi:defcfun ("kqueue" %kqueue) :int)

  (cffi:defcfun ("kevent" %kevent) :int
    (queue :int) (changes :pointer) (change-count :int)
    (events :pointer) (event-count :int) (timeout :pointer))

  (cffi:defcfun ("open" %open) :int (path :string) (flags :int))

  (cffi:defcfun ("close" %close) :int (descriptor :int))

  (defun %set-kevent (event identity interest action notes)
    (cffi:with-foreign-slots ((ident filter flags fflags data udata)
                              event (:struct kevent))
      (setf ident identity filter interest flags action fflags notes
            data 0 udata (cffi:null-pointer)))
    event)

  (defun %kevent-add (queue ident filter fflags)
    "Register interest in IDENT and return whether the queue took it."
    (cffi:with-foreign-object (event '(:struct kevent))
      (%set-kevent event ident filter (logior +ev-add+ +ev-clear+) fflags)
      (not (minusp (%kevent queue event 1 (cffi:null-pointer) 0
                            (cffi:null-pointer))))))

  (defun %kevent-wake (queue)
    "Trigger the user event the loop also waits on, so it returns at once."
    (cffi:with-foreign-object (event '(:struct kevent))
      (%set-kevent event 0 +evfilt-user+ +ev-enable+ +note-trigger+)
      (%kevent queue event 1 (cffi:null-pointer) 0 (cffi:null-pointer))))

  (defun %watch-targets (paths)
    "PATHS and the directories holding them: an editor that saves by writing
a new file and renaming it over the old one only touches the directory."
    (remove-duplicates
     (loop for path in paths
           collect (namestring path)
           collect (namestring (make-pathname :name nil :type nil
                                              :defaults path)))
     :test #'string=))

  (defun %watch-loop (queue callback running)
    (cffi:with-foreign-objects ((events '(:struct kevent) 8)
                                (timeout '(:struct timespec)))
      (setf (cffi:foreign-slot-value timeout '(:struct timespec) 'seconds) 1
            (cffi:foreign-slot-value timeout '(:struct timespec) 'nanoseconds) 0)
      (loop while (car running)
            for count = (%kevent queue (cffi:null-pointer) 0 events 8 timeout)
            when (and (plusp count) (car running))
              do (funcall callback)))))

(defun %watch-supported-p ()
  "Whether this platform has a native filesystem event backend."
  #+darwin t
  #-darwin nil)

(defun %watch (paths callback)
  "Call CALLBACK on a thread of its own whenever one of PATHS changes.
Returns a function that ends the watch, or nil if it cannot be opened."
  (declare (ignorable paths callback))
  #+darwin
  (let ((queue (%kqueue)))
    (unless (minusp queue)
      (let ((descriptors (loop for target in (%watch-targets paths)
                               for descriptor = (%open target +o-evtonly+)
                               unless (minusp descriptor)
                                 collect descriptor)))
        (%kevent-add queue 0 +evfilt-user+ 0)
        (dolist (descriptor descriptors)
          (%kevent-add queue descriptor +evfilt-vnode+ +note-vnode+))
        (let* ((running (list t))
               (thread (bt2:make-thread
                        (lambda () (%watch-loop queue callback running))
                        :name "meow watch")))
          (lambda ()
            (setf (car running) nil)
            (%kevent-wake queue)
            (ignore-errors (bt2:join-thread thread))
            (mapc #'%close descriptors)
            (%close queue)
            nil))))))
