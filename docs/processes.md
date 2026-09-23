# Processes

A process is a thread with a mailbox. Services run as processes.

## Lifecycle

| Function | Purpose |
|---|---|
| `(spawn fn &key name)` | Run `fn` in a new thread as a new process. |
| `(with-process (var &key name) body...)` | Run `body` as a process on the current thread. Errors propagate. |
| `(self)` | The current process, or nil outside one. |
| `(exit &optional reason)` | End the current process. |
| `(process-alive-p p)`, `(process-exit-reason p)` | Status. |

Exit reasons:

- `:normal`: the function returned.
- The value passed to `exit`.
- `(:error condition)`: an unhandled error.
- `:aborted`: any other non-local exit.

A process stops by returning, calling `exit`, or failing. The only
exception is a [context](contexts.md#stopping) killing a child that misses
its shutdown -- or [`suspend`](suspend.md) ending a process's thread
without stopping it at all, for `resume` to pick back up.

## Exit hooks

`(add-exit-hook p fn)` calls `(funcall fn p reason)` after `p` exits, and
returns a token for `remove-exit-hook`. If `p` has already exited it returns
nil and never calls `fn`.

On exit, a process is marked dead first and its hooks run afterwards, with
no lock held.

A hook that signals an error doesn't stop the others. The error is passed
to `*teardown-error-hook*`, a function of `(condition source)`, where
`source` is the process (or, for a failing [effect](effects.md), the
service). With no hook set, or if the hook itself fails, a warning is
printed. Set it globally with `setf`, since hooks run on the exiting
process's thread.

```lisp
(setf meow:*teardown-error-hook*
      (lambda (condition source) (format t "~a: ~a~%" source condition)))
```

A running [logger](logger.md) claims the hook and turns these into `:error`
records.

## Messages

- `(send p msg)` never blocks. Messages to an exited process are dropped.
- `(receive &key timeout)` returns `(values msg t)`, or `(values nil nil)`
  on timeout. A nil timeout waits forever.

## Call and cast

```lisp
(defvar *doubler* (serve (lambda (n) (* n 2))))
(call *doubler* 21)   ; => 42, nil
(cast *doubler* 1)    ; => nil, no reply
(stop *doubler*)      ; exits with :shutdown
```

`(call p msg &key (timeout 5))` returns:

| Result | Meaning |
|---|---|
| `(values reply nil)` | Answered. |
| `(values nil :timeout)` | No answer in time. `p` keeps running and its late reply is discarded. |
| `(values nil (:down reason))` | `p` exited before answering, or had already exited. |
| `(values nil (:error condition))` | A [service](services.md#failure-model) skipped the message after an error. |
| `(values nil (:deadlock processes))` | `p` is waiting on the caller, directly or through others. Nothing was sent, or a call already waiting was broken. |

`(call-all processes msg &key (timeout 5))` calls every process at once and
waits for all of them against the one timeout, so a slow process does not
delay the others. It returns a list, in the order of `processes`, of
`(reply status)`: `call`'s two values for each. A process that would close a
wait cycle, the caller itself included, is `(nil (:deadlock processes))`
straight away.

## Deadlocks

Each process waiting in `call` or a waiting [emit](events.md) is recorded
as waiting on its targets, and a [context](contexts.md#stopping) stopping a
child as waiting on that child. A call that would close a cycle, such as two
services calling each other, or a process calling itself, fails at once
with `(:deadlock processes)`. `processes` lists the cycle from `p` to the
caller. The other calls in the cycle keep waiting and are answered once
the refused caller moves on.

A wait that starts after the cycle's other calls, such as a context
stopping a child that is already calling it, breaks them instead: each
call into the new waiter returns `(:deadlock processes)`, and `serve` and
service loops drop the message it sent instead of handling it later.

Wire format for processes that run their own `receive` loop:
`(:call cell msg)`, answered with `(reply cell value)`; `(:cast msg)`; and
`(:stop reason)`, which `serve` loops honour. `serve` drops messages that
don't match these shapes.
