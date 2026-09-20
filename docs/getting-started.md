# Getting started

## Loading

MEOW loads through Quicklisp's local projects:

```sh
ln -s ~/git/meow ~/quicklisp/local-projects/meow
```

```lisp
(ql:quickload :meow)
```

Dependencies: `bordeaux-threads` (bt2 API), `alexandria` and `closer-mop`
from Quicklisp, plus two that need local projects of their own:

```sh
git clone https://github.com/takeiteasy/trivial-high-precision-timer \
    ~/quicklisp/local-projects/trivial-high-precision-timer
git clone https://github.com/takeiteasy/trivial-wait \
    ~/quicklisp/local-projects/trivial-wait
```

The [logger](logger.md) and the source [watcher](hmr.md) load separately,
as `meow/logger` and `meow/hmr`. Everything else, including the config-file
[loader](loader.md), is in `meow` itself. `meow/hmr` watches through
`trivial-wait`; `meow` itself is portable Common Lisp.

## Tests

The suite uses FiveAM and runs through ASDF:

```lisp
(asdf:test-system :meow)
```

Each subsystem has a suite of its own: `meow/logger` and `meow/hmr`.

From the shell, `tests/test.sh` runs it on `sbcl` (default), `ecl` or
`ccl` and exits non-zero on failure:

```sh
tests/test.sh ecl
```

SBCL and ECL run in CI on every push; the `ccl` workflow runs CCL on
demand.
