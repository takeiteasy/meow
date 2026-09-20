# Updating config

`update` changes a mounted child's [config](config.md) while it runs.

```lisp
(mount *app* 'server :port 8080)
(update *app* 'server :port 9090)   ; => process
```

`(update ctx child &rest initargs)` takes a name or a process. The new
initargs are merged over the ones the child was mounted with, and the
result is used by later [restarts](contexts.md#restarts) and
[reloads](reload.md). Both win over [intercepts](intercept.md). It returns the child's process, or nil if `child`
isn't mounted. The process may have exited if the child is waiting to
restart.

`:restart`, `:shutdown`, `:backoff` and `:backoff-max` replace the child's
mount options and take effect without touching the child.

## Steps

1. The merged initargs are validated on a fresh instance. A bad config
   signals `invalid-config` in the caller and changes nothing.
2. `(update-config service old new)` is called on the child's process,
   with the old and new initarg plists, intercepts included, before any
   slot changes.
3. If it returns true, `new` is applied to the instance in place and the
   same process keeps running. Otherwise the child is
   [reloaded](reload.md) and `update` returns the new process.

```lisp
(defmethod update-config ((s server) old new)
  (declare (ignore old))
  (rebind-socket s (getf new :port))
  t)
```

`update-config` defaults to nil. An error in it, or in applying `new`, is
signalled in the caller, stores nothing and leaves the child running. If
`update-config` doesn't answer within the child's `shutdown` seconds, the
child is reloaded. With `:shutdown :infinity` the context waits for it,
handling no other messages.

A child waiting to restart, or one that exits before answering, just
stores the new initargs, and its restart uses them. A child can't update
itself: that would deadlock, so `update` signals an error instead.

## Contexts

A [context](contexts.md) applies `:intercept` and `:children` in place.
Intercepts are applied first, so a child mounted by the same change sees
them as it starts. See [adopting children](contexts.md#adopting-children).
