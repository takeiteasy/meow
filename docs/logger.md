# Logger

A logging [service](services.md) that writes records from anywhere on a
[registry](registry.md), plus [lifecycle](services.md#lifecycle) changes and
teardown failures. It ships as the separate `meow/logger` system.

```lisp
(asdf:load-system "meow/logger")

(mount *app* 'logger :level :debug)

(defmethod ready ((s worker))
  (log-info s "listening on ~a" (port s)))
```

## Levels

`:debug`, `:info`, `:warn`, `:error`, least to most severe. A record is
written when its level is at or above the logger's `level`, which defaults
to `:info`.

| Call | |
|---|---|
| `(log-debug service control &rest args)` | |
| `(log-info service control &rest args)` | |
| `(log-warn service control &rest args)` | |
| `(log-error service control &rest args)` | |
| `(log-message service level control &rest args)` | The same, with the level as an argument. |

`control` and `args` are a `format` control string and its arguments. The
message is formatted where it is logged, so a record never carries a live
object to the logger's process. The record is tagged with `service`'s name.

## Initargs

| Initarg | Default | |
|---|---|---|
| `:stream` | `*error-output*` | Where records are written. |
| `:level` | `:info` | The lowest level kept. |
| `:lifecycle` | `:debug` | The level lifecycle records are logged at. |

`logger-level` and `logger-lifecycle` are settable from the logger's own
process; `logger-stream` is read-only.

## What it logs

Besides `:meow/log` records, a logger reports:

- Every `:meow/status` change, at its `lifecycle` level.
- Every `:meow/mount` and `:meow/unmount` in its subtree, at the same level.
- Teardown failures, at `:error`.

Status changes reach a logger anywhere on the registry. Mount events are
scoped to a context's tree, so **mount a logger in the context whose tree it
should observe** — one started on its own with `start-service` sees status
records but no mounts. See [mount events](contexts.md#mount-events).

Lifecycle defaults to `:debug` so a crash-looping child does not flood the
log at the default level.

## Teardown failures

While a logger runs it owns
[`*teardown-error-hook*`](processes.md#exit-hooks), so a failing disposer or
exit hook becomes an `:error` record instead of a printed warning. It
restores the previous value when it stops. With more than one logger, the
last to start owns the hook.

## Without a logger

`log-info` and friends emit `:meow/log` on the registry's
[event bus](events.md). With no logger mounted the record goes nowhere, so
logging is safe to call whether or not one is running, and several loggers
can watch the same registry.
