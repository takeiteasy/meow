# Services

A service is a CLOS instance running as a [process](processes.md). It
registers under a name and waits for the services it depends on, so
services can be started in any order.

## Defining

```lisp
(defservice consumer ()
  ((reporter :initarg :reporter :reader reporter))
  (:depends-on provider)
  (:name consumer))
```

`defservice` takes the same arguments as `defclass`, plus two options:

- `(:depends-on name...)`: names to wait for. Subclasses inherit them.
- `(:name name)`: the registration name. Defaults to the class name. It can
  also be set per instance with the `:name` initarg. A service named nil is
  not registered.

Names compare with `equal`, so `foo::provider` and `bar::provider` are
different names.

## Protocol

Specialise any of these generic functions. Each has a no-op default.

| Generic function | Called |
|---|---|
| `(metadata s)` | At registration. Returns a plist that is published as the registration props. |
| `(ready s)` | When every dependency is registered. It fires again after a lost dependency comes back. |
| `(dep-down s name reason)` | When dependency `name` leaves a ready service. |
| `(handle s message)` | For each `call` or `cast`. The return value is the reply to a `call`. |
| `(dispose s reason)` | When the service stops for any reason, before it is unregistered. |

`(dependency s name)` returns a dependency's current process.
`(service-ready-p s)` returns true when every dependency is present.

## Running

```lisp
(defvar *p* (start-service (make-instance 'provider)))
(call *p* :ping)
(stop *p*)
```

`(start-service s &key registry debug)` returns the process once the
service is registered (unless its name is nil) and subscribed. It signals
`already-registered` if the name is taken. `ready` always runs later, on
the service's own process.

The service keeps the registry and debug flag it was started with.
`registry` defaults to the caller's `*registry*` and `debug` to
`*debug-services*`.

To have a service restarted when it fails, mount it on a
[context](contexts.md) instead.

`call`, `cast` and `stop` work as they do for `serve`.

## Failure model

Every message, as well as `ready` and `dep-down`, runs with two restarts
available:

| Restart | Effect |
|---|---|
| `skip-message` | Drop the message and keep running. A skipped `call` returns `(values nil (:error condition))`. |
| `stop-service` | Stop with exit reason `(:error condition)`. |

`(skip-message c)` and `(stop-service c)` invoke them, so a handler inside
`handle` can pick one. An error that nothing handles enters the debugger if
the service was started with `debug` true (the default), and otherwise
invokes `stop-service`.

```lisp
(setf meow:*debug-services* nil)   ; production: failed services stop
```

## Stopping

A service stops when it is sent `stop`, calls `exit`, or takes the
`stop-service` restart. Then:

1. `dispose` runs with the exit reason.
2. The name, if any, is unregistered, and dependants get `dep-down` with that same
   reason.
