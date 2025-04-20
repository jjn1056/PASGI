You are helping implement a reference server for PASGI — a Perl-native asynchronous server interface inspired by Python's ASGI.

Start by reading the PASGI protocol documentation in `/docs` and `/docs/specs`.

Then, follow the implementation plan in `IMPLEMENTATION.md`.

Use:
- Modern Perl (v5.36+) with method signatures
- IO::Async for the event loop
- Future and Future::AsyncAwait for async control flow
- UNIX domain sockets for communication between the main server and worker processes

You must support:
- HTTP/1.1
- HTTP/2
- WebSockets (with PASGI-compliant lifecycle)
- Server-Sent Events (SSE) as a first-class citizen
- A worker architecture that offloads PASGI app handling

Write clean, idiomatic Perl. You may use any high-quality CPAN modules compatible with async architecture.

Include:
- A complete test suite using `Test2::V0`
- CLI launcher
- POD documentation
- Example applications: HTTP hello, SSE stream, WebSocket chat

Only generate code that conforms to the PASGI spec in `/docs` and `/docs/specs`.


