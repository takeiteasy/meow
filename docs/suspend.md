# Suspend and resume

`suspend` parks every process in a context tree without running `dispose`
or unregistering anything; `resume` picks them all back up over the same
instances. Unlike [reload](reload.md), which replaces an instance and its
process, nothing here is rebuilt.

```lisp
(defvar *susp* (suspend *app*))
;; every process under *app* has no thread now; *app* itself is one of them
(resume *susp*)
;; the same instances, still registered, still holding their state
```

This exists so a caller can get every meow thread out of the way --
`fork(2)` and SBCL's `save-lisp-and-die` both refuse to run otherwise --
without losing anything a restart would: registrations, dependency
subscriptions, effects, and instance state.

## `suspend`

`(suspend context &key (timeout 5))` walks `context`'s whole tree,
`context` included, and asks each process to park: a control message it
only acts on between messages of its own, never `bt:interrupt-thread`, so
nothing is cut off mid-handler or mid-call. A process that is busy stays
busy; suspend just waits, the same trade-off a [context stopping a
child](contexts.md#stopping) already makes. The shared timer thread stops
once every process has parked. `suspend` doesn't return until every parked
thread has actually exited -- an ack fires just before its own thread's
unwind reaches the OS, so `suspend` joins each one rather than trusting
the ack alone. Returns an opaque suspension for `resume`.

`process-alive-p` stays true throughout -- parking is not an exit, so no
exit hook runs and nothing is unregistered.

## `resume`

`(resume suspension)` respawns a fresh thread over each parked process,
running its ordinary service loop again with no re-initialisation:
registration, dependency subscriptions and effects are all still exactly
as they were, because they were never touched. The timer thread restarts
if anything is still pending. Mail sent to a parked process while it was
parked is delivered once it resumes, in order, same as any other message
queued for a process that's momentarily busy.

## `suspend-timeout`

If a process doesn't park within `timeout` seconds, `suspend` withdraws its
request -- a process that is still busy when the timeout lapses can never
park for it after the fact, so nothing is ever left parked but
untracked -- resumes whatever did park, and signals `suspend-timeout`.
`(suspend-timeout-pending condition)` lists the processes that didn't, as
`(process service)` pairs (`service` is nil if the timeout happened while
still walking the tree, so that process's instance was never fetched).

```lisp
(handler-case (suspend *app* :timeout 1)
  (suspend-timeout (c)
    (format t "still busy: ~a~%" (suspend-timeout-pending c))))
```

## `suspend-service` / `resume-service`

A service whose [effects](effects.md) hold a resource that a forked child
inheriting it would break -- typically a thread of its own -- specialises
these to release and reacquire it around the park:

```lisp
(defmethod meow:suspend-service ((service some-service))
  (%release-the-resource service))

(defmethod meow:resume-service ((service some-service))
  (%reacquire-the-resource service))
```

Both default to doing nothing. `suspend-service` runs on the service's own
process right before it parks; `resume-service` right after it resumes,
before the ordinary loop starts taking messages again.

The [hmr watcher](hmr.md)'s native file-notify thread is exactly this
case, and does not yet specialise either method
([#66](https://todo.sr.ht/~takeiteasy/meow/66)) -- a tree that mounts it
still has that thread alive after `suspend`.

## Limitations

- Enumerating the tree and waiting for each ack share one `timeout` budget,
  but acks are awaited one process at a time against that shared deadline
  -- a process that never acks starves the budget left for every entry
  checked after it, even ones that parked immediately. Acceptable since a
  timeout here is already the unusual path.
  ([#65](https://todo.sr.ht/~takeiteasy/meow/65))
- No clock rebasing is needed: `%now` is monotonic across a
  `save-lisp-and-die` reload, so a pending [timer](timers.md) deadline
  computed before a suspend still means the same wall-clock time after
  resume.
