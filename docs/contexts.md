# Contexts

A context is a [service](services.md) that supervises other services. It
registers under its own name, starts children on request, and restarts
them when they exit. It is one-for-one: a child's exit only affects that
child.

```lisp
(defvar *app* (start-service (make-instance 'context :name :app)))
(mount *app* 'provider :restart :permanent)
(mount *app* 'consumer :reporter *reporter*)
(children *app*)
; => ((:name provider :process #<process> :restart :permanent
;     :state :running :restart-in nil)
;     (:name consumer ...))
(unmount *app* 'consumer)
(stop *app*)
```

## API

| Call | Purpose |
|---|---|
| `(mount ctx class &rest initargs &key restart shutdown backoff backoff-max)` | Start a service of `class` and return its process. `shutdown` is how many seconds it gets to stop (default 5), or `:infinity`. See [stopping](#stopping). `backoff` and `backoff-max` override the context's [restart delay](#backoff). Start errors, such as `already-registered`, are signalled in the caller. |
| `(unmount ctx child &key timeout)` | Stop `child`, a name or process, without restarting it, waiting `timeout` seconds (default its `shutdown`, or `:infinity`). See [stopping](#stopping). Returns `t`, `:killed`, `:timeout` if it is still running, or nil if `child` isn't mounted. Signals an error if `child` is the caller. |
| `(children ctx)` | A plist `(:name :process :restart :state :restart-in :class)` for each child, in mount order. See [backoff](#backoff) for `:state`. |
| `(reload ctx child &key timeout)` | Restart `child` with the same instance, or nil if `child` isn't mounted. Signals an error if `child` is the caller. See [hot reload](reload.md). |
| `(update ctx child &rest initargs)` | Change `child`'s initargs and mount options while it runs. See [updating config](update.md). |
| `(intercept ctx head &rest initargs)` | Set config for matching children in the subtree. See [intercepts](intercept.md). |
| `(context-registry ctx)` | The registry its children use. See [isolation](isolation.md). |

Children use the context's registry, or a scoped one if it
[isolates](isolation.md) names, and its debug flag, and their
`service-context` is the context. [Events](events.md#scope) can be scoped
to a context's subtree or its ancestors. A child's name is its
service name, or nil for an unregistered child such as a
[delegated agent](delegation.md).

## Mount events

A context announces each child on itself with `:up` scope, so the context,
its ancestors, and services mounted directly in any of them hear it. An
observer mounted at the root therefore sees the whole tree, and one mounted
beside the child sees its siblings.

| Event | Args |
|---|---|
| `:meow/mount` | `name process` |
| `:meow/unmount` | `name process reason` |

`:meow/mount` is emitted once the child is registered and running, so the
child's own first `:meow/status` events may already have been emitted.
`:meow/unmount` follows the child's `:stopped`, for every reason it stops.
A restart or a [reload](reload.md) is an unmount followed by a mount with a
new process.

Declared children are mounted during the context's own `:starting`, so
their events precede the context's first `:meow/status`.

## Declared children

The `:children` initarg lists specs, each `(class &rest initargs)` as
passed to `mount`. They are mounted, in order, before `start-service`
returns, and again whenever the context is restarted or
[reloaded](reload.md). Children added later with `mount` are not rebuilt.

```lisp
(defservice plugins (context) ()
  (:default-initargs :children '((provider :restart :permanent)
                                 (consumer))))

(mount *app* 'context :name :tools :children '((provider)))
```

If a declared child fails to start, the context's start fails with that
error. Malformed specs signal `invalid-config`.

## Restarts

A restart makes a fresh instance from `class` and `initargs`.

| `:restart` | Restarted when the child exits with |
|---|---|
| `:permanent` | any reason |
| `:transient` (default) | anything except `:normal` or `:shutdown` |
| `:temporary` | never |

A child that exits and isn't restarted is removed from `children`. The
exit of a [reloaded](reload.md) child's old process is ignored.

## Backoff

A context waits `:restart-delay` seconds (default 0) before each
restart. With `:restart-delay-max` set, the delay doubles for each
earlier restart of that child within `:period`, up to that maximum. A
child's `:backoff` and `:backoff-max` override both.

```lisp
(start-service (make-instance 'context :name :app
                                       :restart-delay 0.1
                                       :restart-delay-max 5))
(mount *app* 'flaky :restart :permanent :backoff 1)
```

The context keeps handling messages while it waits. Meanwhile `children`
lists the exited process with `:state :restarting` and `:restart-in` set
to the seconds left. Otherwise `:state` is `:running` and `:restart-in` is
nil; use `process-alive-p` to check liveness, since an exit may not have
been handled yet. A child unmounted or reloaded in the meantime isn't
restarted.

## Intensity

A context allows up to `:intensity` restarts (default 5) within
`:period` seconds (default 10). The next restart after that stops the
context with reason `:restart-limit` instead. A restart whose start
signals an error counts toward the limit and is tried again after the
next delay, so a child whose [config](config.md) no longer validates
stops the context with `:restart-limit`.

## Stopping

When a context stops for any reason, it stops its children in reverse
mount order and waits up to each one's `shutdown` seconds. Then it unwinds
its own [effects](effects.md), runs `dispose` and unregisters.

A child that misses its timeout, for example one stuck in `handle`, is
killed: its thread is interrupted to exit with `:killed`, which still
unwinds its effects, runs `dispose` and unregisters it. `unmount` returns
`:killed` in that case. The interrupt can land anywhere, so state the
child shared with other threads may be left inconsistent.

A child mounted with `:shutdown :infinity` is never killed: its context
waits for it as long as it takes. An explicit `unmount` or `reload`
`:timeout` still kills it once that passes. While the context waits, it
handles no other messages. A child that never stops blocks its
context's shutdown for good, and a parent context can't kill a context
that is already stopping, so after its own `shutdown` the parent reports
a `stop-timeout` and leaves both running unsupervised.

The kill can't reach a child that is already exiting, such as one stuck
in `dispose`. If it is still running `shutdown` seconds after the kill,
it is left running unsupervised and stays registered until it exits. The
context reports it as a `stop-timeout` condition (with
`stop-timeout-process` and `stop-timeout-seconds`) through
`*teardown-error-hook*`, or prints a warning. `unmount` returns `:timeout`
and `reload` signals `stop-timeout` in the same case. A declared child
that is still registered blocks its context's restart, which then
escalates to `:restart-limit`.

While a context waits for a child to stop, calls from that child to the
context return [`(:deadlock processes)`](processes.md#deadlocks) at once,
whether the child makes them while stopping, for example from `dispose`, or
was already waiting on an unanswered one. A call made through another
service that waits on the context is broken the same way. Context functions
such as `children` signal an error instead of returning a status.

A child can't unmount or reload itself: both would deadlock, so `unmount`
and `reload` signal an error instead.

## Nesting

A context can be mounted like any other service:

```lisp
(mount *app* 'context :name :plugins :intensity 3)
```

If a nested context stops with `:restart-limit`, its parent treats that
like any other abnormal exit. A restarted context remounts its
[declared children](#declared-children); the rest are stopped and not
remounted.
