# Events

Services can listen for named events and emit them to each other. Each
[registry](registry.md) has its own event bus, shared with its scoped
registries, and an event can be [scoped](#scope) to part of a context
tree.

```lisp
(defmethod ready ((s logger))
  (on s :request (lambda (path status)
                   (format (log-stream s) "~a ~a~%" path status))))

(emit *registry* :request "/index" 200)
```

## API

| Call | Purpose |
|---|---|
| `(on service event function &key prepend)` | Call `function` with the emitted args whenever `event` is emitted. Returns a function that removes the listener. |
| `(once service event function &key prepend)` | As `on`, but the listener is removed before its first delivery runs. |
| `(emit target event &rest args)` | Send to every listener without waiting. Returns nil. |
| `(emit-serial target event &rest args)` | Call each listener in registration order, waiting for each one. Returns nil. |
| `(emit-parallel target event &rest args)` | Send to every listener at once and wait for all of them. Returns their values in registration order. |
| `(bail target event &rest args)` | Call listeners in order until one returns non-nil, and return that value. Returns nil if none does. |
| `(waterfall target event inner &rest args)` | Run the listeners as a chain wrapped around `inner`. Returns what the chain returns. |

Events compare with `equal`. The emitter can be any thread.

Listeners run in registration order. `:prepend` puts one in front of those
already registered for that event, so a later `:prepend` runs before an
earlier one.

## Scope

`target` decides which listeners an event reaches:

| `target` | Reaches |
|---|---|
| a registry | every listener on it |
| a [context](contexts.md) | listeners chosen by `*event-scope*` |
| any other service | as its context (`service-context`), or its registry if it isn't mounted |

`*event-scope*` applies to context targets:

| `*event-scope*` | Reaches |
|---|---|
| `:down` (default) | the context and everything mounted under it, at any depth |
| `:up` | the context, its ancestors, and services mounted directly in any of them |
| `:both` | either |

```lisp
;; app{ a, inner{ b, deep{ c } } }
(emit inner :reload)                  ; b, c
(let ((*event-scope* :up))
  (emit inner :changed))              ; a, b
```

## Delivery

A listener runs on its own service's process, between that service's other
messages, so it can use the service's state without locks. An error in a
listener is handled like an error in `handle` (see the
[failure model](services.md#failure-model)).

`emit-serial` and `bail` wait up to `*event-timeout*` seconds for each
listener (default nil, which waits forever); `emit-parallel` waits that long
for all of them together. A listener that exits, skips the delivery or times
out counts as returning nil. So does one whose process is already waiting
on the emitter, a [deadlock](processes.md#deadlocks), and it isn't sent the
event. A timed-out listener still runs, but its result is discarded. A service that emits an event it
listens for itself runs its own listener directly.

## Waterfall

`waterfall` runs the listeners as a middleware chain around work the emitter
supplies. Each listener is called with the args plus a `next` function, and the
innermost `next` calls `inner`.

```lisp
(meow:on s :request (lambda (path next)
                      (let ((start (get-internal-real-time)))
                        (prog1 (funcall next path)
                          (record-timing path start)))))

(waterfall *registry* :request #'serve "/index")
```

`next` with no arguments keeps the current ones; with arguments it replaces them
for the rest of the chain and for `inner`. A listener that returns without
calling `next` ends the chain, `inner` never runs, and its value is what
`waterfall` returns.

A listener that cannot have run is skipped and the chain continues, so `inner`
still runs: one released before its delivery arrived, and one whose process is
already waiting on the caller. A listener that times out, errors or exits has
already started, may have run the rest of the chain, and so ends it with nil
rather than being retried.

`inner` runs on the innermost listener's process, or on the emitter's when there
are no listeners. `*event-timeout*` bounds each hop, and a hop covers everything
inside it, so the outermost listener's timeout is the budget for the whole chain.

## Lifetime

A listener is an [effect](effects.md) of its service, so it is removed when
the service stops. Calling the function that `on` returned removes it early.
Deliveries that are already queued when it is removed are dropped.

`once` removes its listener *before* running it, so an event the function
emits itself does not reach it again, and it is gone even if the function
fails. A second delivery already queued behind the first is dropped.

## Core events

The `meow/` prefix is reserved for events the core emits.

| Event | Target | Args |
|---|---|---|
| `:meow/status` | the service's root registry | `name process old new`. See [lifecycle](services.md#lifecycle). |
| `:meow/mount` | the context | `name process`. See [mount events](contexts.md#mount-events). |
| `:meow/unmount` | the context | `name process reason`. |

## Rules

`on` can only be called from the service's own process, for example in
`ready` or `handle`.
