# Getting started

## Loading

MEOW loads through Quicklisp's local projects:

```sh
ln -s ~/git/meow ~/quicklisp/local-projects/meow
```

```lisp
(ql:quickload :meow)
```

Dependencies: `bordeaux-threads` (bt2 API) and `alexandria`.

## Tests

The suite uses FiveAM and runs through ASDF:

```lisp
(asdf:test-system :meow)
```

From the shell, `tests/test.sh` runs it on `sbcl` (default), `ecl` or
`ccl` and exits non-zero on failure:

```sh
tests/test.sh ecl
```
