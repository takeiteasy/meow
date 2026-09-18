# Architecture

MEOW is a Cordis-style plugin/service core for Common Lisp: contexts,
services with mount-order-independent dependency injection, a registry,
effects, events, config, hot reload and sub-agent supervision. It contains
no application-specific code.

## Layering

```
┌───────────────────────────────────────────┐
│ agent supervisor (delegation)             │
│ hot reload · config · events · effects    │
│ context · service · registry · supervisor │
│ process · mailbox · call/cast             │
├───────────────────────────────────────────┤
│ bordeaux-threads (bt2) · alexandria       │
└───────────────────────────────────────────┘
```

## Concurrency

- Every running service is a [process](processes.md): one thread looping
  over its mailbox.
- The registry is a lock-protected data structure, not a
  process, so it cannot crash on its own.
- Threads are never killed. Cancellation is cooperative. Work that needs a
  hard kill belongs in a separate OS process.

## Failure model

- Inside a service, errors are ordinary conditions and restarts.
- At the service boundary, a one-for-one supervisor applies a restart policy
  (`:permanent`, `:transient` or `:temporary`) with OTP-style restart
  intensity, and escalates by stopping its context.
- A context is a supervisor plus a registry entry. Nested contexts are
  services whose class is `context`.

## Implementations

SBCL and ECL are first class and run in CI. CCL is expected to work but is
not tested in CI.
