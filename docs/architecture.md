# Architecture

MEOW is a Cordis-style plugin/service core for Common Lisp. It contains no
application-specific code.

## Layering

```
┌───────────────────────────────────────────┐
│ hot reload · config                       │  planned
├───────────────────────────────────────────┤
│ events                                    │  built
│ effects · delegation (agents)             │  built
│ context · supervisor                      │  built
│ service                                   │  built
│ registry                                  │  built
│ process · mailbox · call/cast             │  built
├───────────────────────────────────────────┤
│ bordeaux-threads (bt2) · alexandria       │
└───────────────────────────────────────────┘
```

## Concurrency

- A [process](processes.md) is one thread looping over its mailbox.
- The [registry](registry.md) is a lock-protected data structure, not a
  process, so it cannot crash on its own.
- A [service](services.md) is a process that registers itself and waits
  for its dependencies.
- A [context](contexts.md) is a service that supervises other services.
- An [effect](effects.md) is a resource released when its service stops.
- An [agent](delegation.md) is a service delegated to a context by a
  parent process, which it reports back to when it finishes or exits.
- An [event](events.md) listener runs on its own service's process and is
  removed when that service stops.
- Threads are never killed. Processes stop cooperatively.

## Implementations

SBCL and ECL are first class and run in CI. CCL is expected to work but is
not tested in CI.
