(defsystem "meow"
  :description "Mount Everything, Order Whenever: a plugin/service core."
  :author "George Watson"
  :license "GPLv3"
  :version "0.1.0"
  :depends-on ("bordeaux-threads" "alexandria" "closer-mop")
  :pathname "src/"
  :serial t
  :components ((:file "package")
               (:file "mailbox")
               (:file "process")
               (:file "call")
               (:file "registry")
               (:file "event")
               (:file "service")
               (:file "context")
               (:file "agent")
               (:file "plugin"))
  :in-order-to ((test-op (test-op "meow/tests"))))

(defsystem "meow/logger"
  :description "A logging service for meow."
  :author "George Watson"
  :license "GPLv3"
  :version "0.1.0"
  :depends-on ("meow")
  :pathname "src/"
  :components ((:file "logger"))
  :in-order-to ((test-op (test-op "meow/logger/tests"))))

(defsystem "meow/tests"
  :depends-on ("meow" "fiveam")
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
               (:file "agent")
               (:file "event")
               (:file "plugin"))
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
