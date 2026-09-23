# Timers

`after` and `repeat` run a function on a [service](services.md)'s own
process later. Both are [effects](effects.md), so a timer is cancelled when
the service stops.

```lisp
(defmethod ready ((s poller))
  (repeat s 30 (lambda () (refresh s)) :label :refresh)
  (after s 5 (lambda () (log-info s "still here"))))
```

| Call | |
|---|---|
| `(after service seconds function &key label)` | Call `function` once, `seconds` from now. |
| `(repeat service seconds function &key label)` | Call `function` every `seconds`, starting `seconds` from now. |

Both return a function that cancels the timer.

```lisp
(let ((cancel (repeat s 1 #'tick)))
  ...
  (funcall cancel))
```

## Running

`function` runs on the service's process, between messages, under the service's
[failure model](services.md#failure-model), so an error in it stops the
service as one in `handle` does.

`repeat` schedules the next call once `function` returns, so a function that
takes longer than the period delays the next call rather than queueing them
up. The period is the gap between calls, not a fixed rate.

`after` releases its effect when it fires, so a spent timer is gone from
[`effects`](effects.md#listing).

## Labels

A timer is labelled `(:after seconds)` or `(:repeat seconds)` unless `label`
says otherwise.

```lisp
(effects *poller*)
; => (:refresh (:after 5))
```

## Rules

`after` and `repeat` can only be called from the service's own process, and
signal an error once it is stopping, as `effect` does.

One thread runs every timer in the image, including the delays a
[context](contexts.md#backoff) waits out before restarting a child. It only
enqueues: the function itself runs on the service's process, so cancelling a
timer cannot race the call. The thread starts with the first pending timer
and exits when the last one is gone -- or when [`suspend`](suspend.md)
stops it early, leaving pending deadlines untouched for `resume` to pick
back up.
