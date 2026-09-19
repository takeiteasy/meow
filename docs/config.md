# Config

A [service](services.md)'s config is its slots. Give a slot a `:type` and
meow checks it. Add a `:validate` function to check the config as a whole.

```lisp
(defun check-port (s)
  (when (< (port s) 1024)
    (list "port must be at least 1024")))

(defservice server ()
  ((host :initarg :host :initform "localhost" :type string)
   (port :initarg :port :initform 8080 :type integer :reader port))
  (:validate check-port))
```

## Validation

The config is checked after `make-instance` and `reinitialize-instance`,
so a bad config never reaches `start-service`, `mount` or `reload`.

1. Every bound slot with a `:type` is checked with `typep`.
2. If every slot type checks out, each `:validate` function runs.
   Superclass validators run first.

A `:validate` function takes the instance and returns a list of problem
strings. It returns nil if the config is valid. It can be a function name
or a lambda.

## invalid-config

If there are problems, `invalid-config` is signalled with all of them:

```lisp
(mount *app* 'server :host 1 :port "80")
;; Invalid config for SERVER:
;;   host: 1 is not of type STRING
;;   port: "80" is not of type INTEGER
```

| Reader | Value |
|---|---|
| `(invalid-config-service c)` | The instance that failed validation. |
| `(invalid-config-problems c)` | A list of problem strings. |
