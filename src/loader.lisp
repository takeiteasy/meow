(in-package #:meow)

(defvar *%read-problem* nil
  "The problem reading a loader's file, while the loader is initialized.")

(defun %read-specs (file package)
  "The one form in FILE, read as data in PACKAGE."
  (with-open-file (stream file)
    (let ((*read-eval* nil)
          (*package* package)
          (eof '#:eof))
      (let ((specs (read stream nil eof)))
        (when (eq specs eof)
          (error "~a is empty." file))
        (unless (eq eof (read stream nil eof))
          (error "~a holds more than one form." file))
        specs))))

(defun %spec-key (spec)
  "The identity SPEC's entry is diffed under, or nil if it has none."
  (%initarg-name (first spec) (rest spec)))

(defun %spec-shape-p (spec)
  (and (consp spec) (symbolp (first spec)) (a:proper-list-p spec)
       (evenp (length (rest spec)))))

(defun %key-problems (specs)
  "Problems with the classes and keys of SPECS, which %SPEC-PROBLEMS has
already reported on the shape of."
  (let ((keys '()))
    (loop for spec in specs
          when (and (%spec-shape-p spec) (first spec))
            append (cond ((not (find-class (first spec) nil))
                          (list (format nil "children: there is no class ~s"
                                        (first spec))))
                         ((not (%spec-key spec))
                          (list (format nil "children: ~s needs a :name"
                                        spec)))
                         ((member (%spec-key spec) keys :test #'equal)
                          (list (format nil "children: ~s is named ~s twice"
                                        (first spec) (%spec-key spec))))
                         (t (push (%spec-key spec) keys) '())))))

(defun %loader-problems (loader)
  (with-slots (file package) loader
    (append (cond (*%read-problem* (list (format nil "file: ~a" *%read-problem*)))
                  ((null file) (list "file: no file was given")))
            (unless (find-package package)
              (list (format nil "package: there is no package ~s" package)))
            (%key-problems (slot-value loader 'specs)))))

(defservice loader (context)
  ((file :initarg :file :initform nil :type (or null string pathname))
   (interval :initarg :interval :initform 1 :type (real 0))
   ;; Not *PACKAGE*: the instance is made on the context's thread, whose
   ;; package is not the one the caller was reading in.
   (package :initarg :package :initform (find-package '#:cl-user)
            :type (or package symbol string))
   (stamp :initform nil))
  (:validate %loader-problems))

(defun %with-file-specs (loader initargs continue)
  "Call CONTINUE with INITARGS and the specs in LOADER's file as :CHILDREN,
reporting a file that cannot be read as a config problem rather than here."
  (let ((file (getf initargs :file (and (slot-boundp loader 'file)
                                        (slot-value loader 'file))))
        (package (or (getf initargs :package
                           (and (slot-boundp loader 'package)
                                (slot-value loader 'package)))
                     (find-package '#:cl-user)))
        (*%read-problem* nil))
    (let ((specs (when file
                   (handler-case (%read-specs file (find-package package))
                     (error (e) (setf *%read-problem* e) '())))))
      (apply continue :children specs initargs))))

;;; The file is read here, not in an :AFTER method: validation is an :AFTER
;;; method on SERVICE, so it would run first and see no children.
(defmethod initialize-instance :around ((loader loader) &rest initargs)
  (%with-file-specs loader initargs
                    (lambda (&rest args) (apply #'call-next-method loader args))))

(defmethod reinitialize-instance :around ((loader loader) &rest initargs)
  (%with-file-specs loader initargs
                    (lambda (&rest args) (apply #'call-next-method loader args))))

(defun %spec-args (spec)
  "SPEC's initargs, without its mount options."
  (apply #'a:remove-from-plist (rest spec)
         (%plist-keys (%mount-options (rest spec)))))

(defun %apply-spec (loader child spec)
  "Apply SPEC's initargs to CHILD, in place if it keeps every initarg it has
and its process accepts them, otherwise by restarting it with a fresh
instance. Returns (:ok process) or (:error condition)."
  (handler-case
      (let* ((args (%spec-args spec))
             (config (%config loader (child-class child) args)))
        (%set-mount-options child (%mount-options (rest spec)))
        (if (equal config (child-config child))
            (list :ok (child-process child))
            (progn
              (apply #'make-instance (child-class child) config)
              (if (subsetp (%plist-keys (child-config child))
                           (%plist-keys config))
                  (%apply-update loader child (child-config child) config args)
                  (progn (setf (child-initargs child) args)
                         (%replace-child loader child))))))
    (error (e) (list :error e))))

;;; TODO: a change inside a nested entry reaches it as changed :children,
;;; which reloads that context whole; see #53 for diffing it in place.
(defun %apply-specs (loader specs)
  "Mount, unmount and update LOADER's children so its subtree matches SPECS.
Returns (values report errors), the report naming what changed."
  (let ((old (slot-value loader 'specs))
        (mounted '()) (updated '()) (unmounted '()) (errors '()))
    (flet ((note (result key list)
             (if (eq (first result) :error)
                 (push (second result) errors)
                 (push key list))
             list))
      (dolist (spec old)
        (let ((key (%spec-key spec)))
          (unless (find key specs :key #'%spec-key :test #'equal)
            (%unmount loader key nil)
            (push key unmounted))))
      (dolist (spec specs)
        (let* ((key (%spec-key spec))
               (child (%find-child loader key))
               (previous (find key old :key #'%spec-key :test #'equal)))
          (cond ((and child (eq (child-class child) (first spec)))
                 (unless (equal (rest spec) (rest previous))
                   (setf updated (note (%apply-spec loader child spec)
                                       key updated))))
                (t
                 (when child
                   (%unmount loader key nil))
                 (setf mounted (note (%mount loader (first spec) (rest spec))
                                     key mounted))))))
      (setf (slot-value loader 'specs) specs)
      (values (list :mounted (nreverse mounted)
                    :updated (nreverse updated)
                    :unmounted (nreverse unmounted))
              (nreverse errors)))))

(defun %load (loader)
  "Read LOADER's file and apply it. Returns the report, or nil if the file
cannot be read or its entries don't validate."
  (with-slots (file package stamp) loader
    (setf stamp (%stamp file))
    (handler-case
        (let ((specs (%read-specs file (find-package package))))
          (a:when-let ((problems (append (%spec-problems specs)
                                         (%key-problems specs))))
            (error 'invalid-config :service loader :problems problems))
          (multiple-value-bind (report errors) (%apply-specs loader specs)
            (dolist (e errors)
              (warn "Applying ~a failed: ~a" file e))
            (when (or (getf report :mounted) (getf report :updated)
                      (getf report :unmounted))
              (let ((*event-scope* :up))
                (emit loader :meow/loaded file report)))
            report))
      (error (e)
        (warn "Loading ~a failed: ~a" file e)
        nil))))

(defun %poll (loader)
  (with-slots (file stamp) loader
    (let ((new (%stamp file)))
      (unless (or (null new) (equal new stamp))
        (%load loader)))))

(defmethod ready ((loader loader))
  (with-slots (file interval stamp) loader
    (setf stamp (%stamp file))
    (repeat loader interval (lambda () (%poll loader)) :label :load)))

(defmethod handle ((loader loader) message)
  (if (eq message :load)
      (%load loader)
      (call-next-method)))
