(in-package #:meow/tests)

(def-suite :meow/hmr)
(in-suite :meow/hmr)

(defvar *sources* nil
  "The temporary directory a watcher test writes its sources to.")

(defmacro with-sources ((&rest classes) &body body)
  "Run BODY with *SOURCES* a fresh directory, then remove it and forget
CLASSES, so one test's sources aren't watched by the next."
  `(let ((*sources* (uiop:ensure-directory-pathname
                     (merge-pathnames (symbol-name (gensym "meow-hmr-"))
                                      (uiop:temporary-directory)))))
     (ensure-directories-exist *sources*)
     (unwind-protect (progn ,@body)
       (dolist (class ',classes)
         (remhash class meow::*%service-sources*))
       (uiop:delete-directory-tree *sources* :validate t
                                             :if-does-not-exist :ignore))))

(defun write-source (name &rest forms)
  "Write FORMS to NAME's file under *SOURCES* and return its path."
  (let ((path (merge-pathnames (format nil "~(~a~).lisp" name) *sources*)))
    (with-open-file (stream path :direction :output :if-exists :supersede)
      (format stream "(in-package #:meow/tests)~%")
      (dolist (form forms)
        (format stream "~s~%" form)))
    path))

(defun load-source (path)
  "Load PATH so DEFSERVICE records it as a source."
  (load path :verbose nil :print nil))

(defun answering (class value)
  "A service CLASS whose HANDLE answers VALUE."
  (values `(meow:defservice ,class () ())
          `(defmethod meow:handle ((s ,class) message)
             (declare (ignore message))
             ,value)))

(defun watch (context &rest initargs)
  "Mount a watcher that only scans when it is asked to, loading sources
rather than compiling them. The defaults go last, since the first of a
repeated initarg wins."
  (apply #'meow:mount context 'meow:watcher
         (append initargs '(:interval 10 :compile nil))))

(defun watched-process (context name)
  (getf (find name (meow:children context)
              :key (lambda (child) (getf child :name)))
        :process))

(test a-changed-source-reloads-the-children-holding-its-class
  (with-sources (reloaded)
    (let ((path (multiple-value-call #'write-source
                  'reloaded (answering 'reloaded 1))))
      (load-source path)
      (with-fresh-registry ()
        (let* ((ctx (start-context))
               (w (watch ctx :files (list path)))
               (p (meow:mount ctx 'reloaded)))
          (is (eql 1 (meow:call p :ask)))
          (multiple-value-call #'write-source 'reloaded (answering 'reloaded 2))
          (is (equal '(reloaded) (meow:call w :scan)))
          (let ((new (watched-process ctx 'reloaded)))
            (is (not (eq new p)) "the child runs in a new process")
            (is (eql 2 (meow:call new :ask))))
          (stop-and-join ctx))))))

(test a-changed-source-is-recompiled-when-compile-is-on
  (with-sources (compiled)
    (let ((path (multiple-value-call #'write-source
                  'compiled (answering 'compiled 1))))
      (load-source path)
      (with-fresh-registry ()
        (let* ((ctx (start-context))
               (w (watch ctx :files (list path) :compile t))
               (p (meow:mount ctx 'compiled)))
          (multiple-value-call #'write-source 'compiled (answering 'compiled 2))
          (is (equal '(compiled) (meow:call w :scan :timeout 60)))
          (is (eql 2 (meow:call (watched-process ctx 'compiled) :ask)))
          (is (not (eq p (watched-process ctx 'compiled))))
          (stop-and-join ctx))))))

(test an-unchanged-source-is-not-reloaded
  (with-sources (steady)
    (let ((path (multiple-value-call #'write-source
                  'steady (answering 'steady 1))))
      (load-source path)
      (with-fresh-registry ()
        (let* ((ctx (start-context))
               (w (watch ctx :files (list path)))
               (p (meow:mount ctx 'steady)))
          (is (null (meow:call w :scan)))
          (is (eq p (watched-process ctx 'steady)))
          (stop-and-join ctx))))))

(test a-change-within-the-same-second-is-still-seen
  (with-sources (samesecond)
    (let ((path (multiple-value-call #'write-source
                  'samesecond (answering 'samesecond 1))))
      (load-source path)
      (with-fresh-registry ()
        (let* ((ctx (start-context))
               (w (watch ctx :files (list path))))
          (meow:mount ctx 'samesecond)
          ;; Same length and same write second: only the contents differ, so
          ;; FILE-WRITE-DATE alone would miss this.
          (multiple-value-call #'write-source
            'samesecond (answering 'samesecond 2))
          (is (equal '(samesecond) (meow:call w :scan)))
          (stop-and-join ctx))))))

(test the-watcher-does-not-reload-itself
  (with-sources (own-watcher)
    (let ((path (write-source 'own-watcher
                              '(meow:defservice own-watcher (meow:watcher) ()))))
      (load-source path)
      (with-fresh-registry ()
        (let* ((ctx (start-context))
               (w (meow:mount ctx 'own-watcher :interval 10 :compile nil
                                               :files (list path))))
          (write-source 'own-watcher
                        '(meow:defservice own-watcher (meow:watcher)
                          ((version :initform 2))))
          (is (null (meow:call w :scan)) "reloading itself would deadlock")
          (is (eq w (watched-process ctx 'own-watcher)))
          (stop-and-join ctx))))))

(test a-source-that-fails-to-load-leaves-the-watcher-running
  (with-sources (broken)
    (let ((path (multiple-value-call #'write-source
                  'broken (answering 'broken 1))))
      (load-source path)
      (with-fresh-registry ()
        (let* ((ctx (start-context))
               (w (watch ctx :files (list path)))
               (p (meow:mount ctx 'broken)))
          (with-open-file (stream path :direction :output :if-exists :supersede)
            (format stream "(in-package #:meow/tests)~%(defun ~%"))
          (is (null (handler-bind ((warning #'muffle-warning))
                      (meow:call w :scan))))
          (is-true (meow:process-alive-p w) "the watcher is still running")
          (is (eq p (watched-process ctx 'broken)))
          (stop-and-join ctx))))))

(test a-stale-context-is-reloaded-whole-and-its-subtree-left-alone
  (with-sources (outer inner)
    (let ((outer (write-source 'outer
                               '(meow:defservice outer (meow:context)
                                 ((version :initform 1)))))
          (inner (multiple-value-call #'write-source
                   'inner (answering 'inner 1))))
      (load-source inner)
      (load-source outer)
      (with-fresh-registry ()
        (let* ((ctx (start-context))
               (w (watch ctx :files (list outer inner)))
               (nested (meow:mount ctx 'outer :name :nested
                                              :children '((inner)))))
          (is (eql 1 (meow:call (watched-process nested 'inner) :ask)))
          (write-source 'outer '(meow:defservice outer (meow:context)
                                 ((version :initform 2))))
          (multiple-value-call #'write-source 'inner (answering 'inner 2))
          ;; Reloading the context remounts inner, so inner is not reloaded
          ;; again through a process that no longer exists.
          (is (equal '(:nested) (meow:call w :scan)))
          (let ((new (watched-process ctx :nested)))
            (is (not (eq new nested)))
            (is (eql 2 (meow:call (watched-process new 'inner) :ask))))
          (stop-and-join ctx))))))

(test the-poll-interval-scans-on-its-own
  (with-sources (polled)
    (let ((path (multiple-value-call #'write-source
                  'polled (answering 'polled 1))))
      (load-source path)
      (with-fresh-registry ()
        (let ((ctx (start-context)))
          (meow:mount ctx 'meow:watcher :files (list path)
                                        :interval 0.05 :compile nil)
          (let ((p (meow:mount ctx 'polled)))
            (multiple-value-call #'write-source 'polled (answering 'polled 2))
            (is-true (eventually
                      (lambda ()
                        (let ((new (watched-process ctx 'polled)))
                          (and new (not (eq new p)))))
                      10))
            (is (eql 2 (meow:call (watched-process ctx 'polled) :ask))))
          (stop-and-join ctx))))))
