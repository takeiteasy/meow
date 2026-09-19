# Intercepts

A [context](contexts.md)'s `:intercept` sets [config](config.md) for
matching children anywhere in its subtree.

```lisp
(mount *app* 'context :name :staging
                      :intercept '((server :port 9090)
                                   (:audit-log :level :debug))
                      :children '((server) (plugins)))
```

Each entry is `(class-or-name &rest initargs)`. It matches a child whose
class is, or inherits from, that class, or whose service name is that
name. Mount options such as `:restart` can't be intercepted.

## Precedence

A child's initargs are merged in this order, first wins:

1. the initargs it was mounted or [updated](update.md) with
2. intercepts of its own context, later entries first
3. intercepts of each ancestor context, nearest first
4. the class's defaults

Restarts and [reloads](reload.md) use the intercepts current at the
time.

## Changing intercepts

```lisp
(intercept *app* 'server :port 9191)   ; set or replace the entry
(intercept *app* 'server)              ; remove it
(update *app* :staging :intercept '((server :port 9090)))
```

`(intercept ctx head &rest initargs)` works on any context. `update` on a
mounted context replaces all its intercepts without restarting it.

Each affected child is then updated like [`update`](update.md) does:
`update-config` can apply the new initargs in place, otherwise it is
reloaded. A child that lost an initarg is restarted with a fresh instance
instead, so the slot returns to its default. Children of nested contexts
are updated shortly after the call returns.

If a direct child's new config doesn't validate, `invalid-config` is
signalled and nothing changes. `intercept` signals any other error after
updating the remaining children, keeping the new intercepts; `update`
and nested contexts print them as warnings.
