# Plugins

A plugin is a plain function mounted on a [context](contexts.md) as a
service of its own, for work that doesn't need a class of its state.

```lisp
(mount-function *app* (lambda (s)
                        (on s :request (lambda (r) (handle-request s r)))
                        (effect s #'open-socket :label :socket))
                :depends-on '(store))
```

`(mount-function ctx function &key depends-on name restart shutdown backoff
backoff-max)` returns the plugin's process. The mount options work as they
do for [`mount`](contexts.md#api).

`function` is called with the service once every name in `depends-on` is
registered, so it can use `effect`, `on`, `dependency`, `call` and the
[logger](logger.md) as any service does. It runs on its own process, and
its return value is ignored.

## Re-running

A plugin's function runs again whenever a dependency that left comes back.
The function's [effects](effects.md) are collected as a
[scope](effects.md#scopes) and released when the dependency drops, so a
listener it registers is registered once per run rather than stacking up.

Effects acquired outside the function, such as in a `dispose` method, are
untouched by a re-run and unwind when the plugin stops.

## Names

A plugin is unregistered unless `:name` is given, so several can be mounted
without colliding. Named or not, it is a child of its context and shows up
in `children`.

## Reloading

Pass a symbol rather than a closure for a plugin that should pick up
recompiled code: a [reload](reload.md) applies the mount initargs again, so
a symbol is looked up afresh while a closure is the one captured at mount.

```lisp
(defun cache-plugin (s)
  (effect s #'open-cache :label :cache))

(mount-function *app* 'cache-plugin :name :cache)
```

## When to use a service instead

Reach for [`defservice`](services.md) when the unit needs slots that
[config](config.md) validates, a `handle` method to answer calls, or
`dispose` to do more than release its effects.
