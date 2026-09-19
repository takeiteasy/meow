(defpackage #:meow
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria))
  (:export
   ;; processes
   #:process #:process-name #:process-thread #:process-alive-p
   #:process-exit-reason
   #:self #:spawn #:with-process #:exit #:send #:receive
   #:add-exit-hook #:remove-exit-hook #:*teardown-error-hook*
   ;; call / cast
   #:call #:cast #:reply #:stop #:serve
   ;; registry
   #:registry #:*registry* #:already-registered
   #:already-registered-name #:already-registered-owner
   #:register #:unregister #:lookup #:names #:await
   #:subscribe #:unsubscribe
   ;; services
   #:service #:defservice #:start-service
   #:service-name #:service-registry #:service-process #:service-ready-p
   #:service-dependencies #:dependency
   #:metadata #:ready #:dep-down #:handle #:dispose
   #:effect #:with-effect
   ;; config
   #:invalid-config #:invalid-config-service #:invalid-config-problems
   ;; failure model
   #:*debug-services* #:skip-message #:stop-service
   ;; contexts
   #:context #:context-intensity #:context-period
   #:mount #:unmount #:children #:reload
   #:stop-timeout #:stop-timeout-process #:stop-timeout-seconds
   ;; delegation
   #:agent #:agent-parent #:agent-ref #:delegate
   ;; events
   #:on #:emit #:emit-serial #:bail #:*event-timeout*))
