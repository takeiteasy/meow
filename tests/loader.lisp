(in-package #:meow/tests)

(def-suite :meow/loader :in :meow)
(in-suite :meow/loader)

(defvar *config* nil
  "The temporary config file a loader test writes.")

(defvar *ran* '()
  "What a function entry saw when it ran. Set rather than bound: the entry
runs on a process of its own, which sees the global value.")

(meow:defservice tuned ()
  ((level :initarg :level :initform 0 :type integer)))

(defmethod meow:update-config ((s tuned) old new)
  (declare (ignore old new))
  t)

(defmethod meow:handle ((s tuned) message)
  (declare (ignore message))
  (slot-value s 'level))

(defun loader-tick (plugin)
  (push (meow:lookup 'provider :registry (meow:service-registry plugin)) *ran*))

(defmacro with-config (&body body)
  "Run BODY with *CONFIG* a fresh file name, then remove it."
  `(let ((*config* (merge-pathnames (format nil "~(~a~).lisp"
                                            (gensym "meow-loader-"))
                                    (uiop:temporary-directory))))
     (unwind-protect (progn ,@body)
       (uiop:delete-file-if-exists *config*))))

(defun write-config (specs)
  "Write SPECS to *CONFIG*, readable in this package."
  (with-open-file (stream *config* :direction :output :if-exists :supersede)
    (format stream "~s~%" specs)))

(defun load-config (context &rest initargs)
  "Mount a loader over *CONFIG* that only reads when it is asked to."
  (apply #'meow:mount context 'meow:loader
         (append initargs (list :file (namestring *config*)
                                :package '#:meow/tests
                                :interval 10))))

(defun mounted-names (context)
  (mapcar (lambda (child) (getf child :name)) (meow:children context)))

(defun mounted-class (context name)
  (getf (find name (meow:children context)
              :key (lambda (child) (getf child :name)))
        :class))

(test the-file-is-mounted-as-a-tree
  (with-config
    (write-config '((tuned :level 1)
                    (meow:context :name :nested :children ((provider)))))
    (with-fresh-registry ()
      (let ((ctx (start-context)))
        (let ((loader (load-config ctx)))
          (is (equal '(tuned :nested) (mounted-names loader)))
          (is (eql 1 (meow:call (child-process loader 'tuned) :ask)))
          (is (equal '(provider)
                     (mounted-names (child-process loader :nested)))))
        (stop-and-join ctx)))))

(test a-new-entry-is-mounted-and-a-removed-one-unmounted
  (with-config
    (write-config '((tuned :level 1)))
    (with-fresh-registry ()
      (let* ((ctx (start-context))
             (loader (load-config ctx)))
        (write-config '((tuned :level 1) (provider)))
        (is (equal '(:mounted (provider) :updated nil :unmounted nil)
                   (meow:call loader :load)))
        (is (equal '(tuned provider) (mounted-names loader)))
        (write-config '((provider)))
        (is (equal '(:mounted nil :updated nil :unmounted (tuned))
                   (meow:call loader :load)))
        (is (equal '(provider) (mounted-names loader)))
        (stop-and-join ctx)))))

(test a-changed-initarg-is-applied-in-place-when-the-child-accepts-it
  (with-config
    (write-config '((tuned :level 1)))
    (with-fresh-registry ()
      (let* ((ctx (start-context))
             (loader (load-config ctx))
             (p (child-process loader 'tuned)))
        (write-config '((tuned :level 2)))
        (is (equal '(:mounted nil :updated (tuned) :unmounted nil)
                   (meow:call loader :load)))
        (is (eq p (child-process loader 'tuned)))
        (is (eql 2 (meow:call p :ask)))
        (stop-and-join ctx)))))

(test a-changed-initarg-reloads-a-child-that-declines-it
  (with-config
    (write-config '((tunable :level 1)))
    (with-fresh-registry ()
      (let* ((ctx (start-context))
             (loader (load-config ctx))
             (p (child-process loader 'tunable)))
        (write-config '((tunable :level 2)))
        (is (equal '(tunable) (getf (meow:call loader :load) :updated)))
        (let ((new (child-process loader 'tunable)))
          (is (not (eq p new)))
          (is (eql 2 (meow:call new :ask))))
        (stop-and-join ctx)))))

(test a-dropped-initarg-reverts-to-its-default
  (with-config
    (write-config '((tuned :level 5)))
    (with-fresh-registry ()
      (let* ((ctx (start-context))
             (loader (load-config ctx))
             (p (child-process loader 'tuned)))
        (write-config '((tuned)))
        (is (equal '(tuned) (getf (meow:call loader :load) :updated)))
        (let ((new (child-process loader 'tuned)))
          (is (not (eq p new)) "a dropped initarg needs a fresh instance")
          (is (eql 0 (meow:call new :ask))))
        (stop-and-join ctx)))))

(test a-changed-class-replaces-the-child
  (with-config
    (write-config '((tuned :name :thing :level 1)))
    (with-fresh-registry ()
      (let* ((ctx (start-context))
             (loader (load-config ctx))
             (p (child-process loader :thing)))
        (write-config '((tunable :name :thing :level 1)))
        (is (equal '(:mounted (:thing) :updated nil :unmounted nil)
                   (meow:call loader :load)))
        (is (not (eq p (child-process loader :thing))))
        (is (eq 'tunable (mounted-class loader :thing)))
        (stop-and-join ctx)))))

(test a-mount-option-is-applied-without-touching-the-child
  (with-config
    (write-config '((tuned :level 1)))
    (with-fresh-registry ()
      (let* ((ctx (start-context))
             (loader (load-config ctx))
             (p (child-process loader 'tuned)))
        (write-config '((tuned :level 1 :restart :permanent)))
        (meow:call loader :load)
        (is (eq p (child-process loader 'tuned)))
        (is (equal '(tuned :permanent)
                   (list (getf (first (meow:children loader)) :name)
                         (getf (first (meow:children loader)) :restart))))
        (stop-and-join ctx)))))

(test a-function-entry-runs-once-its-dependencies-are-up
  (with-config
    (write-config '((meow:function-plugin :function loader-tick :name :tick
                     :depends-on (provider))
                    (provider)))
    (setf *ran* '())
    (with-fresh-registry ()
      (let* ((ctx (start-context))
             (loader (load-config ctx)))
        (is-true (eventually (lambda () *ran*)))
        (is (eq (child-process loader 'provider) (first *ran*))
            "it ran with its dependency registered")
        (stop-and-join ctx)))))

(test a-file-that-cannot-be-read-leaves-the-tree-running
  (with-config
    (write-config '((tuned :level 1)))
    (with-fresh-registry ()
      (let* ((ctx (start-context))
             (loader (load-config ctx))
             (p (child-process loader 'tuned)))
        (with-open-file (stream *config* :direction :output
                                         :if-exists :supersede)
          (format stream "((tuned~%"))
        ;; The warning comes from the loader's own process, not this one.
        (is (null (meow:call loader :load)))
        (is-true (meow:process-alive-p loader) "the loader is still running")
        (is (eq p (child-process loader 'tuned)))
        (stop-and-join ctx)))))

(test an-invalid-file-is-refused-when-the-loader-is-mounted
  (with-fresh-registry ()
    (let ((ctx (start-context)))
      (with-config
        (write-config '((no-such-service :level 1)))
        (signals meow:invalid-config (load-config ctx)))
      (with-config
        (write-config '((tuned :name :twice) (tunable :name :twice)))
        (signals meow:invalid-config (load-config ctx)))
      (with-config
        (write-config '((meow:function-plugin :function loader-tick)))
        (signals meow:invalid-config (load-config ctx))
        "a function entry has no name of its own")
      (with-config
        (signals meow:invalid-config (load-config ctx))
        "the file does not exist")
      (stop-and-join ctx))))

(test a-reload-reads-the-file-again
  (with-config
    (write-config '((tuned :level 1)))
    (with-fresh-registry ()
      (let* ((ctx (start-context))
             (loader (load-config ctx)))
        (write-config '((tuned :level 3) (provider)))
        (let ((new (meow:reload ctx loader)))
          (is (equal '(tuned provider) (mounted-names new)))
          (is (eql 3 (meow:call (child-process new 'tuned) :ask))))
        (stop-and-join ctx)))))

(test the-poll-interval-applies-a-change-on-its-own
  (with-config
    (write-config '((tuned :level 1)))
    (with-fresh-registry ()
      (let* ((ctx (start-context))
             (loader (load-config ctx :interval 0.05)))
        (write-config '((tuned :level 1) (provider)))
        (is-true (eventually (lambda () (child-process loader 'provider)) 10))
        (stop-and-join ctx)))))
