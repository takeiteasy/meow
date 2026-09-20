# Config files

`loader` is a [context](contexts.md) whose children come from a file instead
of an initarg. It mounts the tree the file describes and, as the file
changes, applies the difference: new entries are mounted, removed ones
unmounted, and changed ones [updated](update.md).

```lisp
(mount *app* 'loader :file "app.meow" :package :my-app)
```

## The file

One form: the list of specs [`:children`](contexts.md#declared-children)
takes, each `(class &rest initargs)` as passed to `mount`.

```lisp
((server :host "localhost" :port 8080)
 (plugins :children ((provider)
                     (consumer :retries 3)))
 (function-plugin :function handle-tick
                  :name :tick
                  :depends-on (server)))
```

It is read as data, with `*read-eval*` nil, so it holds no code. Symbols
read in `:package`, which is `common-lisp-user` unless you name your own.
A [function entry](plugins.md) is a `function-plugin` whose `:function`
names a function.

Every entry needs a name to be diffed under: its `:name`, or the one its
class defaults to. Names have to be distinct. A file that doesn't exist,
holds more than one form, names a class that isn't defined or repeats a
name is an [invalid config](config.md#invalid-config) for the loader, so
mounting it signals `invalid-config` and starts nothing.

## Initargs

| Initarg | Default | |
|---|---|---|
| `:file` | | The config file. Required. |
| `:package` | `common-lisp-user` | The package the file's symbols read in. |
| `:interval` | `1` | Seconds between polls. |

## Applying a change

An entry counts as changed when its contents change, not when the file's
timestamp moves.

| Entry | |
|---|---|
| new name | mounted |
| name gone | unmounted |
| same name, another class | unmounted and mounted again |
| mount options only | applied without touching the child |
| changed initargs | [updated](update.md), so the child can keep running |
| an initarg dropped | restarted with a fresh instance, so it reverts to its default |

Unlike `update`, the entry's initargs replace the child's rather than
merging into them: the file says what the child's config is.

A change inside a nested entry reaches that entry as changed `:children`,
which the nested context [adopts](contexts.md#adopting-children) the same
way, so what the change did not name keeps running.

An entry that fails to mount or update is reported as a warning and the
rest are still applied; it is tried again the next time the file changes. A file that cannot be read or doesn't validate is
reported the same way and leaves the tree as it is.

After a change, the loader emits
[`:meow/loaded`](events.md#core-events) with the file and the report.

## Loading on demand

`(call loader :load)` reads the file immediately and returns what changed:

```lisp
(call loader :load)
; => (:mounted (:tick) :updated (server) :unmounted ())
```

Restarting or [reloading](reload.md) a loader reads the file again.
