(in-package #:meow)

;;; SUSPEND / RESUME (~takeiteasy/meow#64): park every process in a context
;;; tree without running DISPOSE or unregistering anything, so a caller --
;;; nyaa's image generations (~takeiteasy/nyaa#48) -- can fork with only its
;;; own thread alive and pick every service back up afterwards over the same
;;; instances, mailboxes, registrations, dependencies and effects.
;;;
;;; Every process parks cooperatively: SUSPEND sends a control message
;;; (%SUSPEND, service.lisp) that a process only acts on between messages of
;;; its own, at the top of %SERVICE-LOOP, never bt:interrupt-thread -- so
;;; nothing is cut off mid-handler or mid-call. A slow handler therefore
;;; delays suspend rather than being torn, the same trade-off
;;; checkpoint.lisp's own walk makes (~takeiteasy/nyaa#51).
;;;
;;; The tree is found through %CHILDREN-SERVICES and %SERVICE-SELF
;;; (context.lisp, service.lisp), both answered over an ordinary call, so
;;; nothing is ever read off another thread's slots directly -- unlike
;;; %REBASE, deliberately not needed: %NOW (clock.lisp) is monotonic across
;;; a save-lisp-and-die reload, checked by hand against the running
;;; implementation, so a deadline computed before a suspend still means the
;;; same wall-clock time after RESUME, with no rebasing required.

(define-condition suspend-timeout (error)
  ((pending :initarg :pending :reader suspend-timeout-pending))
  (:report (lambda (condition stream)
             (format stream "~d process~:p did not park in time: ~{~a~^, ~}"
                     (length (suspend-timeout-pending condition))
                     (mapcar #'second (suspend-timeout-pending condition))))))

(defstruct (suspension (:constructor %make-suspension (entries)))
  "ENTRIES: every process this SUSPEND parked, as (process service),
deepest descendant first. Opaque outside this file; pass it to RESUME."
  entries)

(define-condition %enumeration-timeout (error)
  ((process :initarg :process :reader %enumeration-timeout-process))
  (:documentation "Internal to SUSPEND: %TREE-ENTRIES's own walk didn't
finish by its deadline. Never escapes SUSPEND -- caught there and turned
into SUSPEND-TIMEOUT."))

(defun %bounded-call (process message deadline)
  "MESSAGE to PROCESS, bounded by DEADLINE (an %NOW reading), like CALL but
signalling %ENUMERATION-TIMEOUT instead of returning a status. A process
busy in a long handler delays %TREE-ENTRIES exactly as it delays the
%SUSPEND acks that follow -- both share PROCESS's one mailbox -- so this
keeps enumeration itself inside SUSPEND's own TIMEOUT budget rather than
CALL's unbounded default."
  (multiple-value-bind (reply status) (call process message :timeout (max 0 (- deadline (%now))))
    (when status (error '%enumeration-timeout :process process))
    reply))

(defun %tree-entries (process deadline)
  "PROCESS and its descendants, deepest first, as (process service) pairs.
Found entirely through %BOUNDED-CALL: %CHILDREN-SERVICES answers nil for a
leaf service (the base %TREE-CHILDREN method's fallback), so recursing into
one just stops there."
  (let ((service (%bounded-call process (list '%service-self) deadline)))
    (append (loop for entry in (%bounded-call process (list '%children-services) deadline)
                  append (%tree-entries (getf entry :process) deadline))
            (list (list process service)))))

;;; TODO: acks are awaited one at a time against a shared deadline, so a
;;; process that never acks starves the timeout budget of every entry
;;; checked after it, even ones that parked immediately -- a known ceiling,
;;; acceptable since a timeout here is already the unusual path (a wedged
;;; handler). Upgrade path: wait on every ack concurrently (a per-ack thread,
;;; or a single counting semaphore plus a per-process liveness probe) if
;;; that imprecision ever matters. Tracked in ~takeiteasy/meow#65.

(defun %await-acks (pairs deadline)
  "PAIRS, each (entry . ack), split into (values parked pending) by whether
ack was signalled by DEADLINE, an %NOW reading."
  (let ((parked '()) (pending '()))
    (dolist (pair pairs)
      (if (bt2:wait-on-semaphore (cdr pair) :timeout (max 0 (- deadline (%now))))
          (push (car pair) parked)
          (push (car pair) pending)))
    (values (nreverse parked) (nreverse pending))))

(defun %resume-entries (entries)
  "Respawn a fresh thread over each (process service) in ENTRIES, running
%RESUME-SERVICE-LOOP -- RESUME-SERVICE then the ordinary loop, no
%INIT-SERVICE, since registration, dependencies and effects are all still
live from before the suspend."
  (dolist (entry entries)
    (destructuring-bind (process service) entry
      (%respawn process (lambda () (%resume-service-loop service))))))

(defun suspend (context &key (timeout 5))
  "Park every process under CONTEXT's process, and CONTEXT itself,
cooperatively. Stops the shared timer thread once every process has
parked. Returns a SUSPENSION for RESUME.

Signals SUSPEND-TIMEOUT, having already resumed whatever did park, if any
process does not park within TIMEOUT seconds (default 5) of being asked. A
process that acks after SUSPEND-TIMEOUT is signalled parks anyway -- its ack
can't be un-sent -- and is left running rather than tracked, since nothing
here can un-suspend just that one later. Call RESUME on a *fresh* SUSPEND
once the underlying cause (a wedged handler) is resolved."
  (let ((deadline (+ (%now) timeout)))
    (handler-case
        (let* ((entries (%tree-entries context deadline))
               (pairs (mapcar (lambda (entry)
                                (cons entry (bt2:make-semaphore :name "suspend ack")))
                              entries)))
          (dolist (pair pairs)
            (send (first (car pair)) (list '%suspend (cdr pair))))
          (multiple-value-bind (parked pending) (%await-acks pairs deadline)
            (if pending
                (progn (%resume-entries parked)
                       (error 'suspend-timeout :pending pending))
                (progn
                  (%timer-suspend)
                  (%make-suspension parked)))))
      (%enumeration-timeout (c)
        ;; Nothing was ever asked to park -- enumeration itself didn't
        ;; finish -- so there is nothing to resume; PENDING just names the
        ;; unresponsive process, with no SERVICE (never fetched).
        (error 'suspend-timeout
               :pending (list (list (%enumeration-timeout-process c) nil)))))))

(defun resume (suspension)
  "Undo SUSPEND: respawn every process it parked over the same instance,
then restart the timer thread."
  (%resume-entries (suspension-entries suspension))
  (%timer-resume)
  nil)
