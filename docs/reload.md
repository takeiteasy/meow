# Hot reload

`reload` restarts a [context](contexts.md)'s child with the same instance,
so it picks up recompiled code while keeping its state.

```lisp
;; edit and recompile server.lisp, then:
(reload *app* 'server)   ; => new process
```

`(reload ctx child &key timeout)` takes a name or a process. It returns
the new process, or nil if `child` isn't mounted. `timeout` defaults to the
child's `shutdown`; `:infinity` waits without killing.

## Steps

1. The child is stopped with reason `:reload`. Its [effects](effects.md)
   unwind, `dispose` runs, and its name is unregistered, so dependants get
   `dep-down` with `:reload`.
2. The instance is re-initialised with `reinitialize-instance` and the
   initargs it was mounted with, which [validates](config.md) it.
3. It starts in a new process. `ready` runs again once its dependencies
   are present.

A child that misses `timeout` is [killed](contexts.md#stopping) and the
reload goes ahead. If it still hasn't stopped `timeout` seconds after the
kill, or fails to start, it is removed from the context and the error is
signalled in the caller. A missed kill signals `stop-timeout`, and the old
process keeps running until it exits. A killed child exits with `:killed`
rather than `:reload`, and its dependants see that reason in `dep-down`.

## What survives

Only the initargs passed to `mount` are applied again. Every other slot
keeps its value, including runtime state set in `ready` or `handle`.
Anything the old process held as an effect has been released.

A reloaded context remounts its
[declared children](contexts.md#declared-children); the rest are not
remounted.

## Class redefinition

Recompiling a `defservice` updates live instances through CLOS. Added
slots get their initforms, and removed slots are dropped. Specialise
`update-instance-for-redefined-class` to migrate state. Removing
`:depends-on` or `:validate` from a `defservice` removes them from the
class.

Processes that held the old process object see it as exited. Look the
service up by name to get the new one.
