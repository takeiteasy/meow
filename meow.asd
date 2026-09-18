(defsystem "meow"
  :description "Mount Everything, Order Whenever: a plugin/service core."
  :author "George Watson"
  :license "GPLv3"
  :version "0.1.0"
  :depends-on ("bordeaux-threads" "alexandria")
  :pathname "src/"
  :serial t
  :components ((:file "package")
               (:file "mailbox")
               (:file "process")
               (:file "call")
               (:file "registry"))
  :in-order-to ((test-op (test-op "meow/tests"))))

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
               (:file "registry"))
  :perform (test-op (o c)
             (unless (symbol-call :fiveam :run! :meow)
               (error "meow tests failed"))))
