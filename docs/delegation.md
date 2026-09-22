# Delegation

An agent is a short-lived [service](services.md) that a process hands a
task to. It runs on a [context](contexts.md), is never restarted, and
reports back to the process that delegated it (its parent).

## Defining

Subclass `agent` and specialise `handle` (and `dispose` if needed).
Returning `(values :done result)` from `handle` finishes the agent.

```lisp
(defclass summariser (agent)
  ((items :initform '() :accessor items)))

(defmethod handle ((a summariser) message)
  (ecase (first message)
    (:add (push (second message) (items a)) :ok)
    (:finish (values :done (summarise (items a))))))
```

List mixins before `agent`, as with any service, so their methods take
precedence over the `service` defaults.

## Delegating

```lisp
(defvar *agent* (delegate *app* 'summariser :ref :job-1))
(cast *agent* '(:add "text"))
(cast *agent* '(:finish))
(receive)   ; => (:agent-done :job-1 #<process> "summary")
```

`(delegate ctx class &rest initargs &key ref name)` must be called from a
process, which becomes the parent. It mounts the agent on `ctx` as a
`:temporary` child and returns its process. Other initargs go to
`make-instance`.

## Messages to the parent

Each agent sends its parent exactly one of these:

| Message | Sent when |
|---|---|
| `(:agent-done ref agent result)` | `handle` returned `(values :done result)`. The agent then exits with reason `:done`. |
| `(:agent-down ref reason)` | The agent exited any other way: it crashed, was stopped, or its context stopped. |

`ref` is the value passed to `delegate` (default nil), so a parent can tell
concurrent agents apart. When the agent finishes on a `call`, the call
returns `result`.

A plain process reads these off `receive`, as the example above does. A
[service](services.md) parent gets them delivered to its own `handle`, the
same way it gets `:call` and `:cast`:

```lisp
(defmethod handle ((s orchestrator) message)
  (case (first message)
    (:agent-done (bind-result (second message) (fourth message)))
    (:agent-down (retry (second message)))
    ...))
```

## Names

Agents are unregistered by default. Pass `:name` to register one for its
lifetime. A name that is already taken signals `already-registered` in the
caller.

## Stopping

`(unmount ctx agent)` stops an agent by its process, runs `dispose`, and
sends the parent `(:agent-down ref :shutdown)`.
