# meow

**M**ount **E**verything, **O**rder **W**henever

A plugin and service core for Common Lisp, modelled on
[Cordis](https://github.com/cordiverse/cordis). Services are CLOS
instances running as processes. They register by name, wait for their
dependencies so they can be mounted in any order, and run under contexts
that supervise, restart, reconfigure and hot reload them. Contexts can
give their subtree its own instances of a service or override its
config. Services talk through call/cast and an event bus, and tie
resources to their lifetime as effects.

Runs on SBCL and ECL.

## Docs

- [Getting started](docs/getting-started.md)
- [Architecture](docs/architecture.md)
- [Processes](docs/processes.md)
- [Registry](docs/registry.md)
- [Services](docs/services.md)
- [Plugins](docs/plugins.md)
- [Contexts](docs/contexts.md)
- [Effects](docs/effects.md)
- [Delegation](docs/delegation.md)
- [Events](docs/events.md)
- [Timers](docs/timers.md)
- [Config](docs/config.md)
- [Hot reload](docs/reload.md)
- [Watching sources](docs/hmr.md)
- [Updating config](docs/update.md)
- [Isolation](docs/isolation.md)
- [Intercepts](docs/intercept.md)
- [Logger](docs/logger.md)

## License

```
meow
Copyright (C) 2026 George Watson

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program. If not, see <https://www.gnu.org/licenses/>.
```
