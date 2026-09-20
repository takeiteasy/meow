(in-package #:meow)

;;; TODO: reads every watched file each interval; use native filesystem
;;; events (kqueue, inotify) if watch sets grow.

(defservice watcher ()
  ((files :initarg :files :initform '() :type list)
   (interval :initarg :interval :initform 1 :type (real 0))
   (compilep :initarg :compile :initform t :type boolean)
   (stamps :initform (make-hash-table :test #'equal))
   (forms :initform (make-hash-table :test #'equal))))

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

(defun %source-classes (file)
  "The service classes recorded as defined in FILE."
  (loop for class being the hash-keys of *%service-sources*
          using (hash-value source)
        when (equal (%truename source) file)
          collect class))

(defun %read-forms (file)
  "The source text of each top-level form in FILE, paired with the form, or
nil if it cannot be read. IN-PACKAGE is followed as the read goes, so each
form reads in the package its file selected."
  (ignore-errors
   (let ((text (with-open-file (in file)
                 (let* ((buffer (make-string (file-length in)))
                        (count (read-sequence buffer in)))
                   (subseq buffer 0 count)))))
     (with-input-from-string (stream text)
       (let ((*read-eval* nil)
             (*package* *package*)
             (eof '#:eof))
         (loop for start = (file-position stream)
               for form = (read-preserving-whitespace stream nil eof)
               until (eq form eof)
               when (and (consp form) (eq (first form) 'in-package))
                 do (a:when-let ((package (find-package (second form))))
                      (setf *package* package))
               collect (cons (string-trim '(#\Space #\Tab #\Newline #\Return)
                                          (subseq text start
                                                  (file-position stream)))
                             form)))))))

(defun %method-classes (form)
  "The classes the lambda list of a DEFMETHOD FORM specialises on."
  (let ((tail (cddr form)))
    (loop until (listp (first tail))
          do (pop tail))
    (loop for parameter in (first tail)
          until (member parameter lambda-list-keywords)
          when (and (consp parameter) (symbolp (second parameter))
                    (find-class (second parameter) nil))
            collect (second parameter))))

(defun %form-classes (form)
  "The classes FORM defines or specialises on, or :ALL when what it affects
cannot be told from the form alone."
  (case (and (consp form) (first form))
    ((defservice defclass) (if (find-class (second form) nil)
                               (list (second form))
                               :all))
    (defmethod (or (ignore-errors (%method-classes form)) :all))
    (t :all)))

(defun %file-classes (watcher file)
  "The classes the change to FILE touched, recording its forms for the next
scan. :ALL stands for every class FILE defines, which is what a form that
cannot be attributed, or a file that cannot be read, leaves stale."
  (with-slots (forms) watcher
    (let* ((key (namestring file))
           (new (%read-forms file))
           (old (shiftf (gethash key forms) new)))
      (if (null new)
          :all
          (loop with touched = (nconc (set-difference new old :key #'car
                                                              :test #'string=)
                                      (set-difference old new :key #'car
                                                              :test #'string=))
                with classes = '()
                for (nil . form) in touched
                for attributed = (%form-classes form)
                when (eq attributed :all)
                  return :all
                do (setf classes (union attributed classes))
                finally (return classes))))))

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
  (a:when-let* ((touched (loop for file in (%changed-files watcher)
                               for classes = (%file-classes watcher file)
                               when (%load-source watcher file)
                                 collect (cons file classes)))
                ;; Read after loading, so a service the change added counts.
                (classes (remove-duplicates
                          (loop for (file . attributed) in touched
                                append (if (eq attributed :all)
                                           (%source-classes file)
                                           attributed))))
                (context (service-context watcher))
                (names (%reload-under watcher (service-process context)
                                      classes)))
    (let ((*event-scope* :up))
      (emit watcher :meow/reloaded (mapcar #'car touched) names))
    names))

(defmethod ready ((watcher watcher))
  (dolist (file (%changed-files watcher))
    (%file-classes watcher file))
  (repeat watcher (slot-value watcher 'interval)
          (lambda () (%scan watcher))
          :label :watch))

(defmethod handle ((watcher watcher) message)
  (if (eq message :scan)
      (%scan watcher)
      (call-next-method)))
