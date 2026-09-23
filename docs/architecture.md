# Architecture

MEOW is a Cordis-style plugin/service core for Common Lisp. It contains no
application-specific code.

## Layering

```
┌────────────────────────────────────────────┐
│ hot reload · source watching · config      │  built
│ events · timers                            │  built
│ effects · delegation (agents)              │  built
│ context · supervisor                       │  built
│ service                                    │  built
│ registry                                   │  built
│ process · mailbox · call/cast              │  built
├────────────────────────────────────────────┤
│ bordeaux-threads · alexandria · closer-mop │
│ trivial-high-precision-timer · trivial-wait│
└────────────────────────────────────────────┘
```

## Concurrency

- A [process](processes.md) is one thread looping over its mailbox.
- The [registry](registry.md) is a lock-protected data structure, not a
  process, so it cannot crash on its own.
- A [service](services.md) is a process that registers itself and waits
  for its dependencies.
- A [context](contexts.md) is a service that supervises other services.
  It can [isolate](isolation.md) names so its subtree has its own
  instances, and [intercept](intercept.md) config for it.
- An [effect](effects.md) is a resource released when its service stops.
  Effects can be labelled, listed, and grouped in a scope released on its
  own.
- A [plugin](plugins.md) is a function mounted as a service, re-run when a
  dependency comes back.
- An [agent](delegation.md) is a service delegated to a context by a
  parent process, which it reports back to when it finishes or exits.
- A service's [config](config.md) is validated when the instance is
  built. A [loader](loader.md) takes a subtree's config from a file and
  applies the difference as the file changes.
- [Reload](reload.md) restarts a context's child in a new process, keeping
  its instance. A [watcher](hmr.md) does that for a subtree whenever a
  source file changes.
- A [timer](timers.md) runs a function on its service's process later, once
  or on a period, and is cancelled when the service stops. One thread
  schedules them all, including a context's restart backoff.
- An [event](events.md) listener runs on its own service's process and is
  removed when that service stops. Events reach a whole registry or part of
  a context tree.
- A `call` or waiting emit that would close a cycle of processes waiting
  on each other [fails](processes.md#deadlocks) instead of deadlocking.
- Processes stop cooperatively. A context interrupts a child's thread only
  to [kill](contexts.md#stopping) one that misses its shutdown, unless the
  child opts out with `:shutdown :infinity`.
- [`suspend`](suspend.md) parks a whole tree's threads without stopping
  any of it, for `resume` to pick back up over the same instances -- so a
  caller can get every thread meow owns out of the way, for a fork or a
  saved image, without losing state a restart would.

## Implementations

SBCL and ECL are first class and run in CI on every push. CCL is supported
and runs in CI on demand, through the `ccl` workflow.
