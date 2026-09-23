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
;;;
;;; SUSPEND returns only once every parked thread has actually exited
;;; (BT:JOIN-THREAD, below): an ack fires just before its thread's own
;;; unwind reaches the OS, so a caller about to fork right after SUSPEND
;;; returns needs that guarantee, not just PROCESS-ALIVE-P staying true.

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
one just stops there. A child that isn't PROCESS-ALIVE-P -- one waiting out
a restart backoff -- is skipped: there is no thread to park, and the
context's own pending restart timer brings it back after RESUME the same
as it would have anyway."
  (let ((service (%bounded-call process (list '%service-self) deadline)))
    (append (loop for entry in (%bounded-call process (list '%children-services) deadline)
                  for child = (getf entry :process)
                  when (process-alive-p child)
                    append (%tree-entries child deadline))
            (list (list process service)))))

;;; TODO: acks are awaited one at a time against a shared deadline, so a
;;; process that never acks starves the timeout budget of every entry
;;; checked after it, even ones that parked immediately -- a known ceiling,
;;; acceptable since a timeout here is already the unusual path (a wedged
;;; handler). Upgrade path: wait on every ack concurrently (a per-ack thread,
;;; or a single counting semaphore plus a per-process liveness probe) if
;;; that imprecision ever matters. Tracked in ~takeiteasy/meow#65.

(defun %await-acks (asks deadline)
  "ASKS, each (entry cell ack thread), split into (values parked pending)
by whether ACK was signalled by DEADLINE, an %NOW reading. A timed-out ASK
still might park a moment later -- %SUSPEND-CELL-CANCEL (process.lisp)
makes that race safe: it either withdraws the request before the process
gets to it (final state :cancelled, so PENDING) or finds the process
already claimed it (final state :parked, so PARKED after all, exactly as
if the ack itself had merely been slow to observe)."
  (let ((parked '()) (pending '()))
    (dolist (ask asks)
      (destructuring-bind (entry cell ack thread) ask
        (declare (ignore thread))
        (if (bt2:wait-on-semaphore ack :timeout (max 0 (- deadline (%now))))
            (push entry parked)
            (ecase (%suspend-cell-cancel cell)
              (:cancelled (push entry pending))
              (:parked (push entry parked))))))
    (values (nreverse parked) (nreverse pending))))

(defun %join-parked (asks parked)
  "BT:JOIN-THREAD every ASKS entry that ended up in PARKED, so SUSPEND
never returns success while a thread it parked is still mid-unwind."
  (dolist (ask asks)
    (when (member (first ask) parked :test #'eq)
      (ignore-errors (bt:join-thread (fourth ask))))))

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
cooperatively. Returns only once every parked thread has actually exited
(BT:JOIN-THREAD), and stops the shared timer thread. Returns a SUSPENSION
for RESUME.

Signals SUSPEND-TIMEOUT, having already resumed whatever did park, if any
process does not park within TIMEOUT seconds (default 5). A process whose
ack lost the timeout race is withdrawn before it can park
(%SUSPEND-CELL-CANCEL) -- nothing here is ever left parked but untracked.
Call RESUME on a *fresh* SUSPEND once the underlying cause (a wedged
handler) is resolved."
  (let ((deadline (+ (%now) timeout)))
    (handler-case
        (let* ((entries (%tree-entries context deadline))
               (asks (mapcar (lambda (entry)
                              (list entry (%make-suspend-cell) (bt2:make-semaphore :name "suspend ack")
                                    (process-thread (first entry))))
                             entries)))
          (dolist (ask asks)
            (send (first (first ask)) (list '%suspend (second ask) (third ask))))
          (multiple-value-bind (parked pending) (%await-acks asks deadline)
            (%join-parked asks parked)
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
