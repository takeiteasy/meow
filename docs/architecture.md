# Architecture

MEOW is a Cordis-style plugin/service core for Common Lisp. It contains no
application-specific code.

## Layering

```
┌───────────────────────────────────────────┐
│ agent supervisor (delegation)             │  planned
│ hot reload · config · events · effects    │  planned
│ context · service · supervisor            │  planned
├───────────────────────────────────────────┤
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
- Threads are never killed. Processes stop cooperatively.

## Implementations

SBCL and ECL are first class and run in CI. CCL is expected to work but is
not tested in CI.
