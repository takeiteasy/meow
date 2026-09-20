(in-package #:meow/tests)

(def-suite :meow/plugin :in :meow)
(in-suite :meow/plugin)

(defun plugin-reporter (reporter)
  "A plugin function reporting each run, with a listener and an effect of its
own so a re-run shows whether the last run was released."
  (lambda (s)
    (meow:send reporter (list :run (meow:self) (meow:dependency s 'provider)))
    (meow:on s :ping (lambda () (meow:send reporter '(:heard))))
    (meow:effect s (lambda () (lambda () (meow:send reporter '(:released))))
                 :label :resource)))

(defun start-plugin (context function &rest options)
  (apply #'meow:mount-function context function options))

(test a-plugin-runs-on-its-own-process
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (me (meow:self))
           (p (start-plugin ctx (lambda (s)
                                  (meow:send me
                                             (list :run (meow:self)
                                                   (meow:service-name
                                                    (meow:service-context s))))))))
      (is (equal (list (list :run p :ctx)) (drain)))
      (stop-and-join ctx))))

(test a-plugin-waits-for-its-dependencies
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (p (start-plugin ctx (plugin-reporter (meow:self))
                            :depends-on '(provider))))
      (is (null (drain)))
      (let ((provider (meow:mount ctx 'provider :reporter (meow:self))))
        (is (has (list :run p provider) (drain))))
      (stop-and-join ctx))))

(test a-flap-re-runs-the-function-without-stacking-listeners
  (with-fresh-registry (r)
    (let* ((ctx (start-context))
           (provider (meow:mount ctx 'provider :restart :temporary))
           (p (start-plugin ctx (plugin-reporter (meow:self))
                            :depends-on '(provider))))
      (is (has (list :run p provider) (drain)))
      (meow:unmount ctx provider)
      (is (has '(:released) (drain)))
      (let ((again (meow:mount ctx 'provider)))
        (is (has (list :run p again) (drain))))
      (meow:emit r :ping)
      (is (equal '((:heard)) (drain)))
      (stop-and-join ctx))))

(test a-plugin-releases-its-effects-when-it-stops
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (p (start-plugin ctx (plugin-reporter (meow:self)))))
      (is (equal (list :run p nil) (first (drain))))
      (is (equal '((:on :ping) :resource) (meow:effects p)))
      (meow:unmount ctx p)
      (is (equal '((:released)) (drain)))
      (stop-and-join ctx))))

(test a-plugin-is-unregistered-unless-named
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (p (start-plugin ctx (constantly nil)))
           (named (start-plugin ctx (constantly nil) :name :worker)))
      (is (eq named (meow:lookup :worker)))
      (is (equal '(:worker) (remove :ctx (meow:names))))
      (is (equal '(nil :worker) (mapcar (lambda (child) (getf child :name))
                                        (meow:children ctx))))
      (is-true (meow:process-alive-p p))
      (stop-and-join ctx))))

(defvar *plugin-runs* nil)

(defun counting-plugin (service)
  (declare (ignore service))
  (push :first *plugin-runs*))

(test a-plugin-named-by-symbol-picks-up-a-redefinition
  (with-fresh-registry ()
    (let ((ctx (start-context)))
      (setf *plugin-runs* '())
      (start-plugin ctx 'counting-plugin :name :counter)
      (is (equal '(:first) *plugin-runs*))
      (unwind-protect
           (progn
             (setf (fdefinition 'counting-plugin)
                   (lambda (service) (declare (ignore service))
                     (push :second *plugin-runs*)))
             (meow:reload ctx :counter)
             (is (equal '(:second :first) *plugin-runs*)))
        (setf (fdefinition 'counting-plugin)
              (lambda (service) (declare (ignore service))
                (push :first *plugin-runs*))))
      (stop-and-join ctx))))

(test a-permanent-plugin-restarts
  (with-fresh-registry ()
    (let* ((ctx (start-context))
           (me (meow:self))
           (p (start-plugin ctx (lambda (s) (declare (ignore s))
                                  (meow:send me (list :run (meow:self))))
                            :restart :permanent)))
      (is (equal (list (list :run p)) (drain)))
      (meow:stop p)
      (let ((messages (drain 1)))
        (is (eql 1 (length messages)))
        (is (not (eq p (second (first messages))))))
      (stop-and-join ctx))))

(test a-plugin-runs-without-a-context
  (with-fresh-registry ()
    (let* ((me (meow:self))
           (p (meow:start-service
               (make-instance 'meow:function-plugin
                              :function (lambda (s) (declare (ignore s))
                                          (meow:send me :ran))))))
      (is (equal '(:ran) (drain)))
      (stop-and-join p))))

(test a-plugin-without-a-function-does-not-validate
  (signals meow:invalid-config (make-instance 'meow:function-plugin)))
