# Architecture

MEOW is a Cordis-style plugin/service core for Common Lisp. It contains no
application-specific code.

## Layering

```
┌───────────────────────────────────────────┐
│ hot reload · config                       │  built
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
- A service's [config](config.md) is validated when the instance is
  built.
- [Reload](reload.md) restarts a context's child in a new process, keeping
  its instance.
- An [event](events.md) listener runs on its own service's process and is
  removed when that service stops. Events reach a whole registry or part of
  a context tree.
- A `call` or waiting emit that would close a cycle of processes waiting
  on each other [fails](processes.md#deadlocks) instead of deadlocking.
- Processes stop cooperatively. A context interrupts a child's thread only
  to [kill](contexts.md#stopping) one that misses its shutdown, unless the
  child opts out with `:shutdown :infinity`.

## Implementations

SBCL and ECL are first class and run in CI. CCL is expected to work but is
not tested in CI.
