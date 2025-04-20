# 🧠 PASGI Reference Server: Implementation Guide for Codex

This document contains the complete specification for building a reference implementation of the PASGI server. It is meant for both human developers and Codex-compatible AI systems. Be sure to read **all PASGI specs in `/docs` and `/docs/specs`** before starting.

---

## ✅ Functional Requirements

### 1. HTTP Support
- Full support for **HTTP/1.1** and **HTTP/2**
- Correct handling of:
  - Keep-alive
  - Chunked encoding
  - Header parsing
  - Pipelining

### 2. WebSocket Support
- Implement the PASGI WebSocket lifecycle:
  - `websocket.connect`
  - `websocket.receive`
  - `websocket.send`
  - `websocket.disconnect`
- Include a **multi-user chat** example using WebSockets

### 3. SSE (Server-Sent Events)
- Implement PASGI-compliant SSE lifecycle
- SSE must be a **first-class feature**
- Include a working demo app that streams periodic events

### 4. Worker Model
- Use **UNIX domain sockets** for IPC between the main server and workers
- Workers should be subprocesses managed by the main server
- Event loop should be powered by **IO::Async**
- Use **Futures** and **Futures::AsyncAwait** for async logic

### 5. PASGI Application Protocol
- Application receives a PASGI environment hashref and returns a `Future`
- Must follow the PASGI spec from `/docs`
- Conform to permitted data types, event names, and lifecycle flow

---

## 🧪 Testing Requirements

- Include a full test suite using `Test2::V0` (or another modern Perl test library)
- Write unit tests for:
  - Header parsing
  - Worker queue logic
  - HTTP parser state machine
- Write integration tests for:
  - HTTP/1.1
  - HTTP/2
  - WebSocket
  - SSE
- Simulate real clients where possible
- Test both valid and malformed scenarios

---

## 🧰 Technical Stack & Language

- Perl v5.36+ with **method signatures**
- **IO::Async** for event loop
- **Futures** and **Futures::AsyncAwait** for async code
- **UNIX sockets** for worker delegation
- Adhere to PASGI's strict type rules:
  - UTF-8 flagged scalars only for text
  - Binary scalars allowed for payloads
  - No `NaN`, `Inf`, or other non-portable float values
  - Only valid UTF-8 string keys in hashrefs
- You **may use any high-quality CPAN modules** as long as they:
  - Are compatible with IO::Async
  - Fit with PASGI goals and async architecture

---

## 📦 Deliverables

- Complete working PASGI server implementation in `/lib`
- Organized module layout (suggested):
  - `PASGI::Server`
  - `PASGI::Worker`
  - `PASGI::Protocol::HTTP11`
  - `PASGI::Protocol::HTTP2`
  - `PASGI::Protocol::WebSocket`
  - `PASGI::Protocol::SSE`
- Include example applications in `/examples`:
  - HTTP Hello World
  - WebSocket multi-user chat
  - SSE ticker or stream
- CLI script to launch server with options:
  - Number of workers
  - Socket path
  - Log level
- `cpanfile` or `Makefile.PL` with all dependencies
- POD docs for every module

---

## 📚 Important

- ✅ You **must read and comply with the PASGI spec in `/docs` and `/docs/specs`**
- ❌ Do not guess protocol semantics — use canonical definitions
- ✅ Reference Python ASGI where appropriate, but adapt it idiomatically to Perl
- ✅ You are building a usable reference for other developers

---

Happy hacking!


