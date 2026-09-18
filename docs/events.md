# Events

Services can listen for named events and emit them to each other. Each
[registry](registry.md) has its own event bus.

```lisp
(defmethod ready ((s logger))
  (on s :request (lambda (path status)
                   (format (log-stream s) "~a ~a~%" path status))))

(emit *registry* :request "/index" 200)
```

## API

| Call | Purpose |
|---|---|
| `(on service event function)` | Call `function` with the emitted args whenever `event` is emitted. Returns a function that removes the listener. |
| `(emit target event &rest args)` | Send to every listener without waiting. Returns nil. |
| `(emit-serial target event &rest args)` | Call each listener in registration order, waiting for each one. Returns nil. |
| `(bail target event &rest args)` | Call listeners in order until one returns non-nil, and return that value. Returns nil if none does. |

`target` is a registry, or a service, which means the registry that
service uses. Events compare with `equal`. The emitter can be any thread.

## Delivery

A listener runs on its own service's process, between that service's other
messages, so it can use the service's state without locks. An error in a
listener is handled like an error in `handle` (see the
[failure model](services.md#failure-model)).

`emit-serial` and `bail` wait with no timeout. A listener that exits or
skips the delivery counts as returning nil. A service that emits an event it
listens for itself runs its own listener directly.

## Lifetime

A listener is an [effect](effects.md) of its service, so it is removed when
the service stops. Calling the function that `on` returned removes it early.
Deliveries that are already queued when it is removed are dropped.

## Rules

`on` can only be called from the service's own process, for example in
`ready` or `handle`. Two services that `emit-serial` or `bail` to each other
at the same time deadlock, just as with `call`.
