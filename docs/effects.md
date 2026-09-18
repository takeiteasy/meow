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

`(effect service acquire)` calls `acquire`, which returns a disposer (a
function of no arguments) or nil. If `acquire` signals, nothing is
recorded.

## Unwinding

When a service stops, its disposers run in reverse order of acquisition,
and then `dispose` runs. A disposer that signals an error is printed as a
warning, and the rest still run.

## Early release

`effect` returns a function that runs the disposer immediately and removes
it, so it doesn't run again at stop. Calling that function more than once
has no further effect.

```lisp
(let ((release (effect s #'acquire-lock)))
  ...
  (funcall release))
```

## Rules

`effect` and its release function can only be called from the service's
own process, for example in `metadata`, `ready`, `handle` or `dep-down`.
Once the service is stopping, `effect` signals an error.
