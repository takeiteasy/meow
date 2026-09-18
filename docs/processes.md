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

Threads are never killed. A process only stops by returning, calling
`exit`, or failing.

## Exit hooks

`(add-exit-hook p fn)` calls `(funcall fn p reason)` after `p` exits, and
returns a token for `remove-exit-hook`. If `p` has already exited it returns
nil and never calls `fn`.

On exit, a process is marked dead first and its hooks run afterwards, with
no lock held.

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

Wire format for processes that run their own `receive` loop:
`(:call cell msg)`, answered with `(reply cell value)`; `(:cast msg)`; and
`(:stop reason)`, which `serve` loops honour.
