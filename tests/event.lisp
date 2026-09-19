(in-package #:meow/tests)

(def-suite :meow/event :in :meow)
(in-suite :meow/event)

(meow:defservice listening (reporting)
  ((releases :initform '() :accessor releases)))

(defun listen-for (s event &key result delay)
  "Listen for EVENT, reporting (name :heard args own-process-p). RESULT :crash
signals an error; otherwise it is the listener's value."
  (meow:on s event (lambda (&rest args)
                     (report s :heard args
                             (eq (meow:self) (meow:service-process s)))
                     (when delay (sleep delay))
                     (if (eq result :crash)
                         (error "listener crashed")
                         result))))

(defmethod meow:handle ((s listening) message)
  (destructuring-bind (tag &rest args) message
    (ecase tag
      (:on (push (cons (first args) (apply #'listen-for s args)) (releases s))
       :ok)
      (:release (funcall (cdr (assoc (first args) (releases s)))) :ok)
      (:release-queued
       (meow:emit s (first args))
       (funcall (cdr (assoc (first args) (releases s))))
       :ok)
      (:emit-serial (apply #'meow:emit-serial s args) :ok)
      (:emit-parallel (apply #'meow:emit-parallel s args))
      (:context-name (let ((context (meow:service-context s)))
                       (and context (meow:service-name context))))
      (:emit-in-context
       (let ((meow:*event-scope* (first args)))
         (apply #'meow:emit-parallel (meow:service-context s) (rest args))))
      (:relay (destructuring-bind (event emitter) args
                (meow:on s event (lambda () (funcall emitter s))))
       :ok)
      (:bail (apply #'meow:bail s args)))))

(defun start-listener (name &rest on-args)
  (let ((p (start 'listening :name name)))
    (meow:call p (list* :on on-args))
    p))

(defun listener-count (registry)
  (hash-table-count (slot-value registry 'meow::listeners)))

(test listener-runs-on-its-own-process
  (with-fresh-registry (r)
    (let ((p (start-listener :a :ping)))
      (is (null (meow:emit r :ping 1 2)))
      (is (equal '((:a :heard (1 2) t)) (drain)))
      (stop-and-join p))))

(test emit-reaches-every-listener-without-waiting
  (with-fresh-registry (r)
    (let ((a (start-listener :a :ping :delay 0.5))
          (b (start-listener :b :ping :delay 0.5))
          (start (now)))
      (meow:emit r :ping)
      (is (< (- (now) start) 0.25))
      (is (null (set-exclusive-or '((:a :heard () t) (:b :heard () t))
                                  (drain 1)
                                  :test #'equal)))
      (stop-and-join a)
      (stop-and-join b))))

(test emit-serial-runs-in-registration-order
  (with-fresh-registry (r)
    (let* ((a (start-listener :a :ping :delay 0.1))
           (b (start-listener :b :ping))
           (c (start-listener :c :ping)))
      (is (null (meow:emit-serial r :ping :x)))
      (is (equal '((:a :heard (:x) t) (:b :heard (:x) t) (:c :heard (:x) t))
                 (drain)))
      (mapc #'stop-and-join (list a b c)))))

(test bail-returns-first-non-nil
  (with-fresh-registry (r)
    (let* ((a (start-listener :a :ask))
           (b (start-listener :b :ask :result :b))
           (c (start-listener :c :ask :result :c)))
      (is (eq :b (meow:bail r :ask)))
      (is (equal '((:a :heard () t) (:b :heard () t)) (drain)))
      (is (null (meow:bail r :unheard)))
      (mapc #'stop-and-join (list a b c)))))

(test stopping-removes-listeners
  (with-fresh-registry (r)
    (let ((p (start-listener :a :ping)))
      (is (= 1 (listener-count r)))
      (stop-and-join p)
      (drain)
      (is (zerop (listener-count r)))
      (meow:emit r :ping)
      (is (null (meow:bail r :ping)))
      (is (null (drain))))))

(test release-removes-listener-early
  (with-fresh-registry (r)
    (let ((p (start-listener :a :ping)))
      (meow:call p '(:release :ping))
      (is (zerop (listener-count r)))
      (meow:emit r :ping)
      (is (null (drain)))
      (stop-and-join p))))

(test queued-delivery-after-release-is-ignored
  (with-fresh-registry ()
    (let ((p (start-listener :a :ping)))
      (meow:call p '(:release-queued :ping))
      (is (null (drain)))
      (stop-and-join p))))

(test on-requires-own-process
  (with-fresh-registry (r)
    (multiple-value-bind (p service) (start 'listening :name :a)
      (signals error (meow:on service :ping (lambda ())))
      (is (zerop (listener-count r)))
      (stop-and-join p))))

(test waiting-emit-to-self-runs-directly
  (with-fresh-registry ()
    (let ((p (start-listener :a :ask :result :mine)))
      (is (eq :mine (meow:call p '(:bail :ask))))
      (is (eq :ok (meow:call p '(:emit-serial :ask 1))))
      (is (equal '((:a :heard () t) (:a :heard (1) t)) (drain)))
      (stop-and-join p))))

(test crashed-listener-is-skipped
  (with-fresh-registry (r)
    (let ((a (start-listener :a :ask :result :crash))
          (b (start-listener :b :ask :result :b)))
      (is (eq :b (meow:bail r :ask)))
      (join a)
      (is (eq :error (first (meow:process-exit-reason a))))
      (is (= 1 (listener-count r)))
      (stop-and-join b))))

(test timed-out-listener-is-skipped
  (with-fresh-registry (r)
    (let ((a (start-listener :a :ask :result :slow :delay 1))
          (b (start-listener :b :ask :result :b))
          (start (now)))
      (is (eq :b (let ((meow:*event-timeout* 0.2))
                   (meow:bail r :ask))))
      (is (< (- (now) start) 0.8))
      (stop-and-join a)
      (stop-and-join b))))

(test registries-are-isolated
  (with-fresh-registry ()
    (let ((p (start-listener :a :ping))
          (other (make-instance 'meow:registry)))
      (meow:emit other :ping)
      (is (null (meow:bail other :ping)))
      (is (null (drain)))
      (stop-and-join p))))

(test emit-parallel-waits-for-all-at-once
  (with-fresh-registry (r)
    (let ((a (start-listener :a :ask :result :a :delay 0.5))
          (b (start-listener :b :ask :result :b :delay 0.5))
          (start (now)))
      (is (equal '(:a :b) (meow:emit-parallel r :ask)))
      (is (< (- (now) start) 0.8))
      (is (null (meow:emit-parallel r :unheard)))
      (stop-and-join a)
      (stop-and-join b))))

(test emit-parallel-shares-one-deadline
  (with-fresh-registry (r)
    (let ((a (start-listener :a :ask :result :a :delay 1))
          (b (start-listener :b :ask :result :b :delay 1))
          (start (now)))
      (is (equal '(nil nil) (let ((meow:*event-timeout* 0.2))
                              (meow:emit-parallel r :ask))))
      (is (< (- (now) start) 0.5))
      (stop-and-join a)
      (stop-and-join b))))

(test emit-parallel-to-self-runs-directly
  (with-fresh-registry ()
    (let ((a (start-listener :a :ask :result :mine))
          (b (start-listener :b :ask :result :b)))
      (is (equal '(:mine :b) (meow:call a '(:emit-parallel :ask))))
      (stop-and-join a)
      (stop-and-join b))))

(test emit-parallel-crashed-listener-gives-nil
  (with-fresh-registry (r)
    (let ((a (start-listener :a :ask :result :crash))
          (b (start-listener :b :ask :result :b)))
      (is (equal '(nil :b) (meow:emit-parallel r :ask)))
      (join a)
      (stop-and-join b))))

(defun mount-listener (context name)
  "Mount a listener on CONTEXT, a process, that answers :ping with NAME."
  (let ((p (meow:mount context 'listening :name name :reporter (meow:self))))
    (meow:call p (list :on :ping :result name))
    p))

(defmacro with-event-tree ((&optional (app (gensym))) &body body)
  "APP is the service of the tree app{ :a inner{ :b deep{ :c } } }, beside
other{ :d } and an unmounted :top, each listening for :ping."
  `(with-fresh-registry ()
     (let* ((,app (make-instance 'meow:context :name :app))
            (app-process (meow:start-service ,app))
            (other (meow:start-service (make-instance 'meow:context :name :other))))
       (declare (ignorable ,app))
       (mount-listener app-process :a)
       (let* ((inner (meow:mount app-process 'meow:context :name :inner))
              (deep (progn (mount-listener inner :b)
                           (meow:mount inner 'meow:context :name :deep))))
         (mount-listener deep :c))
       (mount-listener other :d)
       (start-listener :top :ping :result :top)
       (unwind-protect (progn ,@body)
         (stop-and-join (meow:lookup :top))
         (stop-and-join other)
         (stop-and-join app-process)))))

(defun emit-from (name scope)
  "Results of emit-parallel :ping on NAME's context with SCOPE."
  (meow:call (meow:lookup name) (list :emit-in-context scope :ping)))

(test events-cross-an-isolating-context
  (with-fresh-registry (r)
    (let* ((iso (make-instance 'meow:context :name :iso :isolate '(:a)))
           (p (meow:start-service iso)))
      (mount-listener p :a)
      (is (equal '(:a) (meow:emit-parallel r :ping)))
      (is (equal '(:a) (meow:emit-parallel iso :ping)))
      (stop-and-join p))))

(test service-context-links-mounted-services
  (with-event-tree (app)
    (is (null (meow:service-context app)))
    (is (eq :app (meow:call (meow:lookup :a) '(:context-name))))
    (is (eq :deep (meow:call (meow:lookup :c) '(:context-name))))
    (is (null (meow:call (meow:lookup :top) '(:context-name))))
    (is (equal '(:a :b :c :d :top) (meow:emit-parallel meow:*registry* :ping)))))

(test context-target-reaches-its-subtree
  (with-event-tree (app)
    (is (equal '(:a :b :c) (meow:emit-parallel app :ping)))
    (is (equal '(:b :c) (emit-from :b :down)))
    (is (equal '(:c) (emit-from :c :down)))))

(test service-target-means-its-context
  (with-event-tree ()
    (is (equal '(:b :c) (meow:call (meow:lookup :b) '(:emit-parallel :ping))))
    (is (equal '(:d) (meow:call (meow:lookup :d) '(:emit-parallel :ping))))
    (is (equal '(:a :b :c :d :top)
               (meow:call (meow:lookup :top) '(:emit-parallel :ping))))))

(test up-scope-bubbles-through-ancestors
  (with-event-tree ()
    (is (equal '(:a :b) (emit-from :b :up)))
    (is (equal '(:a :b :c) (emit-from :c :up)))
    (is (equal '(:a) (emit-from :a :up)))))

(test both-scope-reaches-up-and-down
  (with-event-tree (app)
    (is (equal '(:a :b :c) (emit-from :b :both)))
    (signals error (let ((meow:*event-scope* :sideways))
                     (meow:emit-parallel app :ping)))))

;;; Deadlock detection

(test mutual-emit-parallel-is-refused
  (with-fresh-registry ()
    (let ((x (start-listener :x :e2 :result :x))
          (y (start 'listening :name :y))
          (start (now)))
      (meow:call y (list :relay :e1 (lambda (s) (meow:emit-parallel s :e2))))
      (is (equal '((nil)) (meow:call x '(:emit-parallel :e1))))
      (is (< (- (now) start) 1))
      (is (null (drain)) "x's listener is not sent the event")
      (stop-and-join x)
      (stop-and-join y))))

(test cycle-through-a-context-tree-is-refused
  (with-fresh-registry ()
    (let* ((app (meow:start-service (make-instance 'meow:context :name :app)))
           (x (meow:mount app 'listening :name :x :reporter (meow:self)))
           (inner (meow:mount app 'meow:context :name :inner))
           (y (meow:mount inner 'listening :name :y))
           (start (now)))
      (meow:call x '(:on :e2 :result :x))
      (meow:call y (list :relay :e1
                         (lambda (s)
                           (let ((meow:*event-scope* :up))
                             (meow:emit-serial s :e2)))))
      (is (null (meow:call x '(:bail :e1))))
      (is (< (- (now) start) 1))
      (is (null (drain)))
      (stop-and-join app))))
