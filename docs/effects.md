# Effects

An effect ties a resource to a [service](services.md)'s lifetime. When
the service stops for any reason, it releases the resource.

```lisp
(defmethod ready ((s logger))
  (effect s (lambda ()
              (let ((stream (open "app.log" :direction :output
                                            :if-exists :append
                                            :if-does-not-exist :create)))
                (setf (log-stream s) stream)
                (lambda () (close stream))))))
```

`(effect service acquire &key label)` calls `acquire`, which returns a
disposer (a function of no arguments) or nil. If `acquire` signals, nothing
is recorded. `label` names the effect for [listing](#listing).

`with-effect` binds the resource, and its body is the disposer. It returns
the resource and the release function.

```lisp
(defmethod ready ((s logger))
  (setf (log-stream s)
        (with-effect (stream s (open "app.log" :direction :output
                                               :if-exists :append
                                               :if-does-not-exist :create)
                             :label :log-file)
          (close stream))))
```

## Unwinding

When a service stops, its disposers run in reverse order of acquisition,
and then `dispose` runs. A disposer that signals an error is passed to
`*teardown-error-hook*` (see [processes](processes.md#exit-hooks)), and the
rest still run.

## Early release

`effect` returns a function that runs the disposer immediately and removes
it, so it doesn't run again at stop. Calling that function more than once
has no further effect.

```lisp
(let ((release (effect s #'acquire-lock)))
  ...
  (funcall release))
```

## Scopes

`with-effect-scope` collects the effects acquired in its body, so they can
be released as a group later. It returns the body's value and a release
function.

```lisp
(defmethod ready ((s watcher))
  (setf (scope-release s)
        (nth-value 1 (with-effect-scope (s)
                       (on s :tick (lambda () (poll s)))))))

(defmethod dep-down ((s watcher) name reason)
  (declare (ignore name reason))
  (funcall (scope-release s)))
```

Scopes nest, and releasing an outer one also releases the effects acquired
in the scopes inside it. Releasing again has no further effect, and
whatever a scope still holds when the service stops unwinds with the rest.

This is what a [function plugin](plugins.md) uses to re-run cleanly after a
dependency comes back.

## Listing

`(effects target)` returns the labels of a service's live effects, oldest
first, with nil for an unlabelled one, so the count is the number of effects
held. `target` is a service or its process; from another process it is a
`call`, so the service answers it between messages.

```lisp
(effects *logger*)
; => ((:on :meow/log) (:on :meow/status) (:on :meow/mount)
;     (:on :meow/unmount) nil)
```

[Listeners](events.md) are labelled `(:on event)` and
[timers](timers.md) `(:after seconds)` or `(:repeat seconds)`, unless they
are given a `:label` of their own. A context waiting out a
[restart delay](contexts.md#backoff) holds one labelled `(:restart name)`.

## Rules

`effect` and its release function can only be called from the service's
own process, for example in `metadata`, `ready`, `handle` or `dep-down`.
Once the service is stopping, `effect` signals an error.
