# Isolation

A [context](contexts.md) with `:isolate` gives its subtree its own
instance of the listed service names.

```lisp
(start-service (make-instance 'provider))            ; the app's provider
(mount *app* 'context :name :sandbox
                      :isolate '(provider)
                      :children '((provider) (consumer)))
;; consumer depends on the sandbox's provider, not the app's
```

## Resolution

Inside the subtree, an isolated name refers only to the service
registered there under that name. `lookup`, `await`, `subscribe` and
`:depends-on` never fall back to the outer one: until an inner provider
is mounted, the name is simply not registered. Registering it inside
doesn't clash with or replace the outer service.

Every other name resolves outward as usual. Nested contexts can isolate
the same name again; the nearest one wins.

## Registry

Children of an isolating context use a scoped [registry](registry.md),
`(context-registry ctx)`, whose parent is the context's own registry.
Pass it as `:registry` to reach the subtree's names from outside:

```lisp
(lookup 'provider :registry (context-registry sandbox))
```

A context that isolates nothing gives its children its own registry. The
context itself registers outside its scope, and gets a fresh one each
time it starts. Isolation only affects names: the [event](events.md) bus
is shared with the root registry.
