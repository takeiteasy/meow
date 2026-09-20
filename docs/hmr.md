# Watching sources

`watcher` is a [service](services.md) that recompiles changed source files
and [reloads](reload.md) the children holding classes those files define. It
ships as the separate `meow/hmr` system.

```lisp
(asdf:load-system "meow/hmr")

(mount *app* 'watcher :interval 0.5)
```

Mount it wherever the subtree it should reload starts: it reloads children
of its own [context](contexts.md) and of every context under it.

## What it watches

Without `:files`, every file a `defservice` was compiled from. `defservice`
records that file, so no configuration is needed.

`:files` replaces that set with pathnames of your own. A directory stands
for every `.lisp` file under it.

```lisp
(mount *app* 'watcher :files '(#p"src/services/"))
```

A file counts as changed when its contents change, not when its timestamp
moves, so saving a file unchanged reloads nothing.

## What it reloads

A changed file is recompiled and loaded, then every child whose class that
file defines, or that inherits from one, is reloaded. Contexts are reloaded
before what is mounted under them; reloading a context remounts its
[declared children](contexts.md#declared-children), so its subtree is left
alone.

The watcher never reloads itself.

A file that fails to compile is reported as a warning and left until it
changes again. A child that fails to reload is reported the same way, and
the rest still reload.

After a scan that reloaded something, the watcher emits
[`:meow/reloaded`](events.md#core-events) with the files and the names.

## Initargs

| Initarg | Default | |
|---|---|---|
| `:files` | every recorded `defservice` source | Files and directories to watch. |
| `:interval` | `1` | Seconds between scans. |
| `:compile` | `t` | Compile before loading, rather than loading the source. |

## Scanning on demand

`(call watcher :scan)` scans immediately and returns the names it reloaded.
