# MiSTer FTP contributor and agent guide

## Verify the task before editing
- Inspect current main and existing open PRs, not just the suggestion's line number or snippet.
- If the referenced code is absent/already fixed, report the current commit and close as stale/no-op. Do not invent a replacement task, recreate deleted code, or ask for clarification solely to keep a stale suggestion alive.
- Search existing tests before proposing more. Do not create duplicate PRs (download optional guards in PRs #1/#7 were duplicates; upload already guards its plan).

## Platform and validation
- This is a macOS 15+ Swift Package using AppKit, SwiftUI, Darwin, Security and CryptoKit. Use a macOS runner with Swift 6 or newer.
- Run `swift test` and `swift build -c release --product MiSTerFTP`. GitHub's macOS build and tests job is the merge gate.
- Linux/Jules cannot validate this app by changing Package.swift, removing production targets, inserting portability shims or committing scratch scripts. Leave the platform manifest intact. State the limitation and rely on the macOS PR workflow.
- Tests using MISTER_FTP_TEST_HOST deliberately write only a unique /tmp folder on an explicitly selected MiSTer. Never set that variable or touch real-device files without authorization. Ordinary CI runs deterministic tests and skips those live tests.
- Keep temporary experiments outside the repository. Report actual test output, not manual review as a passing test.

## FTP safety and performance
- MiSTer FPGA is a local-LAN appliance, commonly using its default ProFTPD server/settings. Defaults are intentional compatibility, not a generic remote-server vulnerability to fix without context.
- FTPConnection is synchronous and not thread-safe. FTPSession uses one serial DispatchQueue and one control connection. Wrapping calls on that same session in a task group adds no network parallelism and queues work that can outlive cancellation.
- Preserve one command/one reply and fail-fast deletion. Do not pipeline DELE/RMD: commands sent after a failing command may still delete files; unread replies can desynchronize the session.
- A protocol or concurrency optimization needs representative MiSTer timings, bounded independent sessions if appropriate, and deterministic tests for command/reply ordering, mid-operation failure, 421/reconnect, cancellation with no later commands, cleanup and a follow-up command. Without evidence retain the intentional serial implementation.

## Updates and concurrency
- Do not mechanically use Task.detached to move blocking I/O: it loses structured cancellation and still uses the cooperative executor. Inspect isolation and measure first.
- Preserve cancellation checkpoints around update preparation and immediately before app replacement. A cancelled update must not install.
- Test Foundation URL behavior on macOS: spaces may be percent-encoded; loopback hosts are case-insensitive and URL.host and URLComponents.host differ in IPv6 bracket handling. Keep HTTPS and local-only test transport restrictions strict.
- Keep normalized AppVersion prefix comparisons covered (1 < 1.0.1 and 1.2 < 1.2.0.1).

## Delivery scope
- Work on a branch and open a PR. Merge only after the macOS check passes.
- No version bump, signed release publication, device transfer, or /Applications replacement unless separately requested.
