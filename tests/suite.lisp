(in-package #:meow/tests)

(def-suite :meow)
(in-suite :meow)

(test system-loads
  (is (find-package '#:meow)))
