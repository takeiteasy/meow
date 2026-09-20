(defpackage #:meow
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:thpt #:trivial-high-precision-timer))
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
   #:service-name #:service-registry #:service-context #:service-process #:service-ready-p #:service-status
   #:service-dependencies #:dependency
   #:metadata #:ready #:dep-down #:handle #:dispose #:update-config
   #:effect #:with-effect #:with-effect-scope #:effects
   #:after #:repeat
   ;; plugins
   #:function-plugin #:mount-function
   ;; config
   #:invalid-config #:invalid-config-service #:invalid-config-problems
   ;; failure model
   #:*debug-services* #:skip-message #:stop-service
   ;; contexts
   #:context #:context-intensity #:context-period #:context-registry
   #:mount #:unmount #:children #:reload #:update #:intercept
   #:stop-timeout #:stop-timeout-process #:stop-timeout-seconds
   ;; config file loader
   #:loader
   ;; delegation
   #:agent #:agent-parent #:agent-ref #:delegate
   ;; events
   #:on #:once #:emit #:emit-serial #:emit-parallel #:bail #:waterfall
   #:*event-timeout* #:*event-scope*
   ;; hot reload (meow/hmr)
   #:watcher
   ;; logger (meow/logger)
   #:logger #:logger-stream #:logger-level #:logger-lifecycle #:log-level
   #:log-message #:log-debug #:log-info #:log-warn #:log-error))
