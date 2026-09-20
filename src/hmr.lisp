(in-package #:meow)

;;; TODO: reads every watched file each interval; use native filesystem
;;; events (kqueue, inotify) if watch sets grow.

(defservice watcher ()
  ((files :initarg :files :initform '() :type list)
   (interval :initarg :interval :initform 1 :type (real 0))
   (compilep :initarg :compile :initform t :type boolean)
   (stamps :initform (make-hash-table :test #'equal))))

(defun %expand-source (path)
  "PATH itself, or every .lisp file under it if it names a directory."
  (let ((path (pathname path)))
    (if (or (pathname-name path) (pathname-type path))
        (list path)
        (directory (merge-pathnames "**/*.lisp" path)))))

(defun %truename (path)
  "PATH resolved, so a watched file and a recorded source name it the same
way. Symlinked directories, such as /tmp on macOS, would not match otherwise."
  (or (ignore-errors (truename path)) (pathname path)))

(defun %watched-files (watcher)
  (remove-duplicates
   (mapcar #'%truename
           (a:if-let ((files (slot-value watcher 'files)))
             (mapcan #'%expand-source files)
             (a:hash-table-values *%service-sources*)))
   :test #'equal))

(defun %stamp (file)
  "A key for FILE's contents, or nil if it cannot be read. FILE-WRITE-DATE
has one-second resolution, too coarse for an edit made while the watcher
runs, so this reads the file."
  (ignore-errors
   (with-open-file (stream file)
     (let* ((buffer (make-string (file-length stream)))
            (count (read-sequence buffer stream)))
       (cons count (sxhash (subseq buffer 0 count)))))))

(defun %changed-files (watcher)
  "The watched files whose stamp moved since the last scan, recording the new
stamps. Every file is new on the first call."
  (with-slots (stamps) watcher
    (loop for file in (%watched-files watcher)
          for key = (namestring file)
          for stamp = (%stamp file)
          when (and stamp (not (equal stamp (gethash key stamps))))
            collect file
          do (if stamp
                 (setf (gethash key stamps) stamp)
                 (remhash key stamps)))))

(defun %load-source (watcher file)
  "Recompile and load FILE. Returns t, or nil after reporting a failure."
  (handler-case
      (progn (if (slot-value watcher 'compilep)
                 (multiple-value-bind (fasl warnings failure)
                     (compile-file file :verbose nil :print nil)
                   (declare (ignore warnings))
                   (unless fasl
                     (error "~a did not compile." file))
                   (when failure
                     (warn "~a compiled with warnings." file))
                   (load fasl :verbose nil :print nil))
                 (load file :verbose nil :print nil))
             t)
    (error (e)
      (warn "Loading ~a failed: ~a" file e)
      nil)))

;;; TODO: a changed file leaves every child whose class it defines, or that
;;; inherits from one, stale; track per-class redefinition if that reloads
;;; more than it needs to.
(defun %source-classes (file)
  "The service classes recorded as defined in FILE."
  (loop for class being the hash-keys of *%service-sources*
          using (hash-value source)
        when (equal (%truename source) file)
          collect class))

(defun %stale-p (class changed)
  (some (lambda (redefined) (subtypep class redefined)) changed))

(defun %reload-stale (context child)
  "Reload CHILD of CONTEXT, reporting a failure rather than signalling it.
Returns the name reloaded, in a list, or none."
  (handler-case (when (reload context (getf child :process))
                  (list (getf child :name)))
    (error (e)
      (warn "Reloading ~a failed: ~a" (getf child :name) e)
      '())))

(defun %reload-under (watcher context changed)
  "Reload the stale children of CONTEXT, outermost first. A context that is
itself stale is reloaded whole, which remounts its declared children, so its
subtree is left alone. Returns the names reloaded."
  (loop for child in (children context)
        for class = (getf child :class)
        unless (eq (getf child :process) (service-process watcher))
          append (cond ((%stale-p class changed) (%reload-stale context child))
                       ((subtypep class 'context)
                        (%reload-under watcher (getf child :process) changed)))))

(defun %scan (watcher)
  "Reload the watched files that changed and the children they leave stale.
Returns the names reloaded."
  (a:when-let* ((changed (remove-if-not (lambda (file)
                                          (%load-source watcher file))
                                        (%changed-files watcher)))
                ;; Read after loading, so a service the change added counts.
                (classes (remove-duplicates (mapcan #'%source-classes changed)))
                (context (service-context watcher))
                (names (%reload-under watcher (service-process context)
                                      classes)))
    (let ((*event-scope* :up))
      (emit watcher :meow/reloaded changed names))
    names))

(defmethod ready ((watcher watcher))
  (%changed-files watcher)
  (repeat watcher (slot-value watcher 'interval)
          (lambda () (%scan watcher))
          :label :watch))

(defmethod handle ((watcher watcher) message)
  (if (eq message :scan)
      (%scan watcher)
      (call-next-method)))
