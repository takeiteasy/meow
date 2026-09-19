# Contexts

A context is a [service](services.md) that supervises other services. It
registers under its own name, starts children on request, and restarts
them when they exit. It is one-for-one: a child's exit only affects that
child.

```lisp
(defvar *app* (start-service (make-instance 'context :name :app)))
(mount *app* 'provider :restart :permanent)
(mount *app* 'consumer :reporter *reporter*)
(children *app*)   ; => ((provider #<process> :permanent) (consumer #<process> :transient))
(unmount *app* 'consumer)
(stop *app*)
```

## API

| Call | Purpose |
|---|---|
| `(mount ctx class &rest initargs &key restart)` | Start a service of `class` and return its process. Start errors, such as `already-registered`, are signalled in the caller. |
| `(unmount ctx child &key (timeout 5))` | Stop `child`, a name or process, without restarting it, waiting for `dispose` and unregistration to finish. Returns `t`, or nil if `child` isn't mounted. |
| `(children ctx)` | `(name process restart)` for each child, in mount order. |
| `(reload ctx child &key (timeout 5))` | Restart `child` with the same instance. See [hot reload](reload.md). |

Children use the context's registry and debug flag. A child's name is its
service name, or nil for an unregistered child such as a
[delegated agent](delegation.md).

## Restarts

A restart makes a fresh instance from `class` and `initargs`.

| `:restart` | Restarted when the child exits with |
|---|---|
| `:permanent` | any reason |
| `:transient` (default) | anything except `:normal` or `:shutdown` |
| `:temporary` | never |

A child that exits and isn't restarted is removed from `children`.

## Intensity

A context allows up to `:intensity` restarts (default 5) within
`:period` seconds (default 10). The next restart after that stops the
context with reason `:restart-limit` instead. A restart whose start
signals an error counts toward the limit and is tried again, so a child
whose [config](config.md) no longer validates stops the context with
`:restart-limit`.

## Stopping

When a context stops for any reason, it stops its children in reverse
mount order and waits up to 5 seconds for each one. Then it unwinds its own
[effects](effects.md), runs `dispose` and unregisters.

## Nesting

A context can be mounted like any other service:

```lisp
(mount *app* 'context :name :plugins :intensity 3)
```

If a nested context stops with `:restart-limit`, its parent treats that
like any other abnormal exit. A restarted context starts with no children;
the ones it had are stopped and not remounted.
