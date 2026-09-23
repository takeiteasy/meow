(defsystem "meow"
  :description "Mount Everything, Order Whenever: a plugin/service core."
  :author "George Watson"
  :license "GPLv3"
  :version "0.1.0"
  :depends-on ("bordeaux-threads" "alexandria" "closer-mop"
               "trivial-high-precision-timer")
  :serial t
  :components ((:file "package")
               (:file "clock")
               (:file "source")
               (:file "mailbox")
               (:file "process")
               (:file "call")
               (:file "registry")
               (:file "event")
               (:file "service")
               (:file "timer")
               (:file "context")
               (:file "suspend")
               (:file "agent")
               (:file "plugin")
               (:file "loader"))
  :in-order-to ((test-op (test-op "meow/tests"))))

(defsystem "meow/logger"
  :description "A logging service for meow."
  :author "George Watson"
  :license "GPLv3"
  :version "0.1.0"
  :depends-on ("meow")
  :components ((:file "logger"))
  :in-order-to ((test-op (test-op "meow/logger/tests"))))

(defsystem "meow/hmr"
  :description "A source-watching hot reloader for meow."
  :author "George Watson"
  :license "GPLv3"
  :version "0.1.0"
  :depends-on ("meow" "trivial-wait/notify")
  :components ((:file "hmr"))
  :in-order-to ((test-op (test-op "meow/hmr/tests"))))

(defsystem "meow/tests"
  :depends-on ("meow" "fiveam" "uiop")
  :pathname "tests/"
  :serial t
  :components ((:file "package")
               (:file "suite")
               (:file "condvar")
               (:file "mailbox")
               (:file "process")
               (:file "call")
               (:file "registry")
               (:file "service")
               (:file "effect")
               (:file "context")
               (:file "timer")
               (:file "suspend")
               (:file "agent")
               (:file "event")
               (:file "plugin")
               (:file "loader"))
  :perform (test-op (o c)
             (unless (symbol-call :fiveam :run! :meow)
               (error "meow tests failed"))))

(defsystem "meow/logger/tests"
  :depends-on ("meow/logger" "meow/tests")
  :pathname "tests/"
  :components ((:file "logger"))
  :perform (test-op (o c)
             (unless (symbol-call :fiveam :run! :meow/logger)
               (error "meow/logger tests failed"))))

(defsystem "meow/hmr/tests"
  :depends-on ("meow/hmr" "meow/tests" "uiop")
  :pathname "tests/"
  :components ((:file "hmr"))
  :perform (test-op (o c)
             (unless (symbol-call :fiveam :run! :meow/hmr)
               (error "meow/hmr tests failed"))))
