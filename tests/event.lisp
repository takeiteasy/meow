(in-package #:meow/tests)

(def-suite :meow/event :in :meow)
(in-suite :meow/event)

(meow:defservice listening (reporting)
  ((releases :initform '() :accessor releases)))

(defun listen-for (s event &key result delay prepend once)
  "Listen for EVENT, reporting (name :heard args own-process-p). RESULT :crash
signals an error; otherwise it is the listener's value."
  (funcall (if once #'meow:once #'meow:on)
           s event
           (lambda (&rest args)
             (report s :heard args
                     (eq (meow:self) (meow:service-process s)))
             (when delay (sleep delay))
             (if (eq result :crash)
                 (error "listener crashed")
                 result))
           :prepend prepend))

(defun link-for (s event &key tag result delay before)
  "Listen for EVENT as a waterfall link, reporting (name :link args). Calls
NEXT with TAG appended, or returns RESULT without calling it if one is given.
BEFORE runs first; DELAY sleeps after the rest of the chain has returned."
  (meow:on s event
           (lambda (&rest args)
             (let ((next (car (last args)))
                   (args (butlast args)))
               (report s :link args)
               (when before (funcall before))
               (prog1 (if result
                          result
                          (apply next (append args (and tag (list tag)))))
                 (when delay (sleep delay)))))))

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
      (:relay-once (destructuring-bind (event emitter) args
                     (meow:once s event (lambda ()
                                          (report s :relayed)
                                          (funcall emitter s))))
       :ok)
      (:bail (apply #'meow:bail s args))
      (:link (push (cons (first args) (apply #'link-for s args)) (releases s))
       :ok)
      (:waterfall (destructuring-bind (event &rest rest) args
                    (apply #'meow:waterfall s event
                           (lambda (&rest inner) (list* :inner inner))
                           rest))))))

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

;;; Waterfall

(defun start-link (name &rest link-args)
  (let ((p (start 'listening :name name)))
    (meow:call p (list* :link link-args))
    p))

(test waterfall-runs-listeners-as-a-chain
  (with-fresh-registry (r)
    (let ((a (start-link :a :step :tag :a))
          (b (start-link :b :step :tag :b))
          (inner '()))
      (is (eq :done (meow:waterfall r :step
                                    (lambda (&rest args)
                                      (setf inner args)
                                      :done)
                                    1)))
      (is (equal '(1 :a :b) inner) "each link's args reach the next and inner")
      (is (equal '((:a :link (1)) (:b :link (1 :a))) (drain)))
      (stop-and-join a)
      (stop-and-join b))))

(test waterfall-without-listeners-calls-inner-on-the-emitter
  (with-fresh-registry (r)
    (let ((process nil))
      (is (eq :done (meow:waterfall r :step
                                    (lambda (x)
                                      (is (eql 1 x))
                                      (setf process (meow:self))
                                      :done)
                                    1)))
      (is (eq (meow:self) process)))))

(test waterfall-link-that-skips-next-ends-the-chain
  (with-fresh-registry (r)
    (let ((a (start-link :a :step :result :stopped))
          (b (start-link :b :step :tag :b))
          (ran nil))
      (is (eq :stopped (meow:waterfall r :step (lambda (&rest args)
                                                 (declare (ignore args))
                                                 (setf ran t))
                                       1)))
      (is (null ran) "inner is not reached")
      (is (equal '((:a :link (1))) (drain)) "later links are not reached")
      (stop-and-join a)
      (stop-and-join b))))

(test waterfall-skips-a-link-released-mid-chain
  (with-fresh-registry (r)
    (let* ((later nil)
           (a (start-link :a :step :tag :a
                          :before (lambda () (meow:call later '(:release :step)))))
           (b (setf later (start-link :b :step :tag :b))))
      (is (equal '(:inner 1 :a)
                 (meow:waterfall r :step (lambda (&rest args) (list* :inner args))
                                 1))
          "the released link is skipped and inner still runs")
      (is (equal '((:a :link (1))) (drain)))
      (stop-and-join a)
      (stop-and-join b))))

(test waterfall-inner-runs-once-when-an-outer-link-times-out
  (with-fresh-registry (r)
    (let* ((meow:*event-timeout* 0.1)
           (runs 0)
           (a (start-link :a :step :tag :a :delay 0.5))
           (start (now)))
      (is (null (meow:waterfall r :step (lambda (&rest args)
                                          (declare (ignore args))
                                          (incf runs))
                                1))
          "a timed-out link ends the chain")
      (is (waited-p 0.1 (- (now) start)))
      (is (< (- (now) start) 0.5) "the emitter does not wait for the link")
      (is (eql 1 runs) "inner is not run a second time")
      (sleep 0.5)
      (stop-and-join a))))

;;; Deadlock detection

(test waterfall-chain-is-not-a-deadlock
  (with-fresh-registry (r)
    (let ((a (start-link :a :step :tag :a))
          (b (start-link :b :step :tag :b))
          (c (start-link :c :step :tag :c)))
      (is (equal '(:inner 1 :a :b :c)
                 (meow:waterfall r :step (lambda (&rest args) (list* :inner args))
                                 1)))
      (is (null (waits-on a (meow:self))) "the chain leaves no wait edge behind")
      (stop-and-join a)
      (stop-and-join b)
      (stop-and-join c))))

(test waterfall-link-back-to-the-emitter-is-refused
  (with-fresh-registry ()
    (let* ((y (start-link :y :step :tag :y))
           (x (start 'listening :name :x))
           (start (now)))
      (meow:call x '(:link :step :tag :x))
      (is (equal '(:inner 1 :y) (meow:call x '(:waterfall :step 1)))
          "the link on the emitter's own process is skipped, not deadlocked")
      (is (< (- (now) start) 1))
      (is (equal '((:y :link (1))) (drain)))
      (stop-and-join x)
      (stop-and-join y))))

;;; Core events

(defun start-watcher (name &rest events)
  "A listener reporting every delivery of EVENTS."
  (let ((p (start 'listening :name name)))
    (dolist (event events p)
      (meow:call p (list :on event)))))

(defun heard (name messages)
  "The args of each delivery NAME reported."
  (loop for (who tag args) in messages
        when (and (eq who name) (eq tag :heard))
          collect args))

(test status-events-follow-a-service-through-its-life
  (with-fresh-registry ()
    (let ((w (start-watcher :w :meow/status)))
      (multiple-value-bind (p s) (start 'provider :name :p)
        (declare (ignore s))
        (stop-and-join p)
        (is (equal (list (list :p p :starting :waiting)
                         (list :p p :waiting :ready)
                         (list :p p :ready :stopping)
                         (list :p p :stopping :stopped))
                   (remove :p (heard :w (drain)) :key #'first :test-not #'eq))))
      (stop-and-join w))))

(test a-waiting-service-is-announced-when-its-dependency-goes
  (with-fresh-registry ()
    (let ((w (start-watcher :w :meow/status))
          (provider (start 'provider :name 'provider))
          (consumer (start 'consumer :name :c)))
      (stop-and-join provider)
      (is (has (list :c consumer :ready :waiting) (heard :w (drain))))
      (stop-and-join consumer)
      (stop-and-join w))))

(test mount-and-unmount-are-announced-on-the-context
  (with-fresh-registry ()
    (let* ((app (meow:start-service (make-instance 'meow:context :name :app)))
           (w (meow:mount app 'listening :name :w :reporter (meow:self))))
      (meow:call w '(:on :meow/mount))
      (meow:call w '(:on :meow/unmount))
      (let ((p (meow:mount app 'provider :name :p)))
        (is (equal (list (list :p p)) (heard :w (drain))))
        (meow:unmount app :p)
        (is (equal (list (list :p p :shutdown)) (heard :w (drain)))))
      (stop-and-join app))))

(test reload-announces-an-unmount-then-a-mount
  (with-fresh-registry ()
    (let* ((app (meow:start-service (make-instance 'meow:context :name :app)))
           (w (meow:mount app 'listening :name :w :reporter (meow:self))))
      (meow:call w '(:on :meow/mount))
      (meow:call w '(:on :meow/unmount))
      (meow:call w '(:on :meow/status))
      (let* ((old (meow:mount app 'provider :name :p))
             (new (progn (drain) (meow:reload app :p)))
             ;; :waiting -> :ready races the mount: it is emitted by the child
             ;; once it is running, the mount by the context once START-SERVICE
             ;; has returned.
             (events (remove (list :p new :waiting :ready)
                             (remove :p (heard :w (drain))
                                     :key #'first :test-not #'eq)
                             :test #'equal)))
        (is (equal (list (list :p old :ready :stopping)
                         (list :p old :stopping :stopped)
                         (list :p old :reload)
                         (list :p nil :stopped :starting)
                         (list :p new :starting :waiting)
                         (list :p new))
                   events))
        (stop-and-join app)))))

;;; Registration order and one-shot listeners

(test prepend-puts-a-listener-first
  (with-fresh-registry (r)
    (let ((a (start-listener :a :ping))
          (b (start-listener :b :ping :prepend t))
          (c (start-listener :c :ping)))
      (meow:emit-serial r :ping)
      (is (equal '(:b :a :c) (mapcar #'first (drain))))
      (mapc #'stop-and-join (list a b c)))))

(test once-is-removed-after-its-first-delivery
  (with-fresh-registry (r)
    (let ((p (start-listener :a :ping :once t)))
      (is (= 1 (listener-count r)))
      (meow:emit-serial r :ping 1)
      (is (equal '((:a :heard (1) t)) (drain)))
      (is (zerop (listener-count r)) "the listener removes itself")
      (meow:emit-serial r :ping 2)
      (is (null (drain)))
      (stop-and-join p))))

(test once-is-removed-before-it-runs
  (with-fresh-registry (r)
    (let ((p (start 'listening :name :a)))
      ;; The listener emits the event it is listening for; it must not
      ;; deliver to itself again.
      (meow:call p (list :relay-once :ping (lambda (s) (meow:emit-serial s :ping))))
      (meow:emit-serial r :ping)
      (is (equal '((:a :relayed)) (drain)))
      (is (zerop (listener-count r)))
      (stop-and-join p))))

(test a-queued-delivery-to-a-spent-once-listener-is-dropped
  (with-fresh-registry (r)
    (let ((p (start-listener :a :ping :once t :delay 0.3)))
      (meow:emit r :ping 1)
      (meow:emit r :ping 2)
      (is (equal '((:a :heard (1) t)) (drain 0.5)))
      (is (null (meow:emit-parallel r :ping)) "no listener is left")
      (stop-and-join p))))

(test mount-events-reach-an-observer-above-the-context
  (with-fresh-registry ()
    (let* ((app (meow:start-service (make-instance 'meow:context :name :app)))
           (w (meow:mount app 'listening :name :w :reporter (meow:self)))
           (inner (meow:mount app 'meow:context :name :inner)))
      (meow:call w '(:on :meow/mount))
      (meow:call w '(:on :meow/unmount))
      (let ((deep (meow:mount inner 'meow:context :name :deep)))
        (is (equal (list (list :deep deep)) (heard :w (drain)))
            "a grandchild's mount reaches the root observer")
        (let ((p (meow:mount deep 'provider :name :p)))
          (is (equal (list (list :p p)) (heard :w (drain))))
          (meow:unmount deep :p)
          (is (equal (list (list :p p :shutdown)) (heard :w (drain))))))
      (stop-and-join app))))
