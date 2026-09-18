(defpackage #:meow
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria))
  (:export
   ;; processes
   #:process #:process-name #:process-thread #:process-alive-p
   #:process-exit-reason
   #:self #:spawn #:with-process #:exit #:send #:receive
   #:add-exit-hook #:remove-exit-hook
   ;; call / cast
   #:call #:cast #:reply #:stop #:serve))
