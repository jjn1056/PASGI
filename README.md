# PASGI: Perl ASGI-Compatible Server

**PASGI** is a modern, asynchronous Perl implementation inspired by Python's [ASGI](https://asgi.readthedocs.io/) interface. It defines a standard for handling HTTP, HTTP/2, WebSockets, Server-Sent Events (SSE), and background tasks in a Perl-native async event loop environment.

The goal is to provide a minimal, extensible, and high-performance async interface between Perl web applications and web servers.

---

## 🔍 Overview
- **Async-first:** Built using `IO::Async`, `Future`, and `Future::AsyncAwait`
- **Modern Perl:** Uses method signatures and Perl 5.36+ features
- **Protocol-spec compliant:** See `/docs` and `/docs/specs` for the authoritative PASGI spec
- **Worker-based design:** Main server delegates work via UNIX domain sockets
- **Supports:** HTTP/1.1, HTTP/2, WebSockets, SSE, application workers

---

## 📁 Directory Structure
```
/
├── README.md             ← This file
├── IMPLEMENTATION.md     ← AI/Codex-compatible reference implementation spec
├── /docs                 ← PASGI protocol and data type spec
  ├── /docs/specs         ← additional PASGI protocol and data type spec
├── /lib                  ← Perl modules for PASGI reference server
├── /examples             ← Demo applications (HTTP, WebSocket, SSE)
├── /t                    ← Full test suite
```

---

## 🧠 For Contributors
If you're contributing to the PASGI reference implementation:

👉 **Start by reading [`IMPLEMENTATION.md`](./IMPLEMENTATION.md)**

That file includes:
- All functional and technical requirements
- Expected deliverables
- AI/Codex instructions
- Clarifications on allowed CPAN dependencies

Also be sure to read the official specification in the [`/docs`](./docs) and  [`/docs/specs`](./docs/specs) directories.

---

## 🤖 Codex Developers
Codex-based tools: Open `IMPLEMENTATION.md` to see the structured instruction set. Be sure to read the `/docs` and `/docs/specs` directory to fully understand the PASGI specification before generating any code.


