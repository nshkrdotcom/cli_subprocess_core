# Testing And Conformance

`CliSubprocessCore` sits on the boundary between subprocess ownership and
provider-specific parsing, so it needs both low-level transport tests and
higher-level conformance tests. This guide describes the expected test layers
for the repo and for downstream custom profiles.

## Testing Layers

The repo is structured around four layers of confidence:

- pure data tests for commands, events, payloads, runtime state, and option
  validation
- raw transport tests for startup, IO, buffering, stderr dispatch, interrupt,
  close, and force-close behavior
- provider profile tests for command construction and stdout/stderr fixture
  decoding
- session tests that prove the runtime emits normalized, sequenced
  `CliSubprocessCore.Event` values from mock CLIs

Each layer should stay focused. Transport tests should not assert provider
semantics, and provider profile tests should not re-test raw subprocess
ownership.

## Raw Transport Edge Cases

The transport suite should cover at least these scenarios:

- large stdout lines that fit within the configured buffer
- oversized stdout fragments that emit a structured overflow error and recover
  at the next newline
- stderr-only flows where subscribers and the stderr ring buffer still receive
  data
- interrupt and close races that must not hang callers
- subscriber churn, including unsubscribe and monitor-based cleanup
- post-exit flush behavior for queued stdout lines and trailing fragments

The current suite exercises those cases through shell fixtures created inside
the test process.

## Provider Profile Tests

Provider profile tests should stay deterministic and fixture-driven:

- keep provider stdout fixtures in `test/fixtures/provider_profiles/*.jsonl`
- assert emitted `CliSubprocessCore.Event.kind` values and payload structs
- verify provider session id extraction when the source CLI exposes one
- verify command construction for required inputs and common option flags

These tests are the fastest way to catch schema drift in provider CLI output.

## Session Integration Tests

Session tests should verify behavior that only exists once transport and
profiles are combined:

- `:run_started` is emitted first
- runtime sequences are monotonic and gap-free
- provider metadata is preserved on emitted events
- stderr is normalized into `:stderr` events
- terminal success and failure become `:result` or `:error`
- subscriber management behaves correctly while the session is live

Use small mock shell scripts instead of real provider binaries so the tests
stay hermetic and fast.

## Conformance Checklist For New Profiles

Before treating a profile as first-party quality, confirm that it:

- implements `CliSubprocessCore.ProviderProfile`
- returns a valid `CliSubprocessCore.Command` from `build_invocation/1`
- emits only normalized `CliSubprocessCore.Payload.*` structs
- preserves provider-native data in `event.raw` when useful for debugging
- sets `provider_session_id` when the CLI exposes a stable session identifier
- emits a single terminal `:result` on success and `:error` on failure
- behaves correctly under interrupt, stderr-only, and partial-line exit cases

That checklist is intentionally stricter than "the parser seems to work." The
goal is a stable shared runtime surface, not one-off provider adapters.

## Repo-Local Quality Gate

The full repo gate is:

```bash
mix format --check-formatted
mix test
mix credo --strict
mix dialyzer
mix docs
```

Expected result:

- no formatting drift
- no compilation warnings
- no failing tests
- no Credo issues
- no Dialyzer findings
- successful documentation generation

When changing transport or session behavior, rerun the full gate rather than
only the targeted tests. Those layers are shared by every provider profile.
