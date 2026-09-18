# Registry

The registry maps names to [processes](processes.md). It lets a service be
mounted before its dependencies exist and be told when they appear. It is a
lock-protected data structure, not a process.

Every function takes `:registry`, which defaults to `*registry*`. The
binding is per thread: a spawned process does not inherit a rebinding.

## API

| Call | Returns |
|---|---|
| `(register name proc &key props)` | `t`, or `(values nil :noproc)` if `proc` has exited. Signals `already-registered` if a live process holds `name`. |
| `(unregister name)` | `t` if `name` was registered. |
| `(lookup name)` | `(values proc props)`, or nil. |
| `(names)` | Every registered name. |
| `(await name &key timeout)` | The process, or `(values nil :timeout)`. A nil timeout waits forever. |
| `(subscribe name &key process)` | `t`, or nil if `process` has exited. `process` defaults to `(self)`, which must exist. |
| `(unsubscribe name &key process)` | nil |

Names compare with `equal`. Props are a plist.

## Notifications

Subscribers receive these as mailbox messages:

```lisp
(:registered name proc)
(:unregistered name reason)
```

- `subscribe` sends `:registered` before it returns if `name` is already
  registered, so callers never need `lookup` first.
- When a registered process exits, its entry is removed and subscribers get
  its exit reason. The removal only happens if the entry still belongs to
  that process, so a replacement that registered in the meantime is kept.
- An exited subscriber's subscriptions are dropped.

## Lock order

registry, then process (exit hooks), then mailbox (sends). Exit hooks run
with no process lock held. New code must not take the registry lock while
holding a process or mailbox lock.

## Differences from patchbay

The registry cannot crash on its own, so there is no crash-recovery table.
`await` blocks the caller's own thread and keeps no state in the registry,
so a timed-out or exited waiter leaves nothing behind.
