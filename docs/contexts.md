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
| `(mount ctx class &rest initargs &key restart shutdown)` | Start a service of `class` and return its process. `shutdown` is how many seconds it gets to stop (default 5). Start errors, such as `already-registered`, are signalled in the caller. |
| `(unmount ctx child &key timeout)` | Stop `child`, a name or process, without restarting it, waiting up to `timeout` seconds (default its `shutdown`) for `dispose` and unregistration to finish. Returns `t`, `:timeout` if it is still running, or nil if `child` isn't mounted. |
| `(children ctx)` | `(name process restart)` for each child, in mount order. |
| `(reload ctx child &key timeout)` | Restart `child` with the same instance. See [hot reload](reload.md). |

Children use the context's registry and debug flag. A child's name is its
service name, or nil for an unregistered child such as a
[delegated agent](delegation.md).

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

## Intensity

A context allows up to `:intensity` restarts (default 5) within
`:period` seconds (default 10). The next restart after that stops the
context with reason `:restart-limit` instead. A restart whose start
signals an error counts toward the limit and is tried again, so a child
whose [config](config.md) no longer validates stops the context with
`:restart-limit`.

## Stopping

When a context stops for any reason, it stops its children in reverse
mount order and waits up to each one's `shutdown` seconds. Then it unwinds
its own [effects](effects.md), runs `dispose` and unregisters.

A child that misses its timeout, for example one stuck in `handle`, keeps
running unsupervised and stays registered until it exits. The context
reports it as a `stop-timeout` condition (with `stop-timeout-process` and
`stop-timeout-seconds`) through `*teardown-error-hook*`, or prints a
warning. `unmount` returns `:timeout` and `reload` signals `stop-timeout`
in the same case. A declared child that is still registered blocks its
context's restart, which then escalates to `:restart-limit`.

## Nesting

A context can be mounted like any other service:

```lisp
(mount *app* 'context :name :plugins :intensity 3)
```

If a nested context stops with `:restart-limit`, its parent treats that
like any other abnormal exit. A restarted context remounts its
[declared children](#declared-children); the rest are stopped and not
remounted.
