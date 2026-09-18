# meow

**M**ount **E**verything, **O**rder **W**henever

A Cordis-style plugin/service core for Common Lisp, in early development.
So far it provides processes (a thread plus a mailbox) with call/cast, a
name registry with subscribe and await, and CLOS services that wait for
their dependencies in any mount order. Contexts, supervision and the rest
are planned. Runs on SBCL and ECL.

## Docs

- [Getting started](docs/getting-started.md)
- [Architecture](docs/architecture.md)
- [Processes](docs/processes.md)
- [Registry](docs/registry.md)
- [Services](docs/services.md)

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
