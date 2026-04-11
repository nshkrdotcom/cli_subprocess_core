# Recovery Envelope

`cli_subprocess_core` normalizes provider, runtime, transport, and protocol
failures into a shared recovery envelope before those failures move upward into
ASM or higher runtimes.

This guide describes the contract owned here.

## Why It Exists

Provider CLIs are inconsistent about failure labels:

- capacity errors may arrive as runtime failures
- auth/config/runtime claims are often flaky or mislabeled
- transport failures can masquerade as provider exits

`cli_subprocess_core` does not decide packet/job policy, but it does decide the
normalized facts that upper layers need in order to make good policy
decisions.

## Envelope Shape

The recovery envelope is attached under `metadata["recovery"]` on structured
payload errors and under `runtime_failure.recovery` on runtime-failure
metadata.

Current keys:

- `origin`
- `class`
- `retryable?`
- `repairable?`
- `resumeable?`
- `local_deterministic?`
- `remote_claim?`
- `severity`
- `phase`
- `provider_code`
- `suggested_delay_ms`
- `suggested_max_attempts`

## Current Class Vocabulary

- `cli_missing`
- `cwd_missing`
- `transport_invalid_options`
- `transport_unsupported`
- `buffer_overflow`
- `transport_disconnect`
- `transport_timeout`
- `protocol_error`
- `provider_auth_claim`
- `provider_config_claim`
- `provider_rate_limit`
- `provider_runtime_claim`
- `approval_denied`
- `guardrail_blocked`
- `user_cancelled`

`cli_subprocess_core` may expand this set over time, but it should not emit
ambiguous, provider-specific class names when a shared class already exists.

## Ownership Boundary

`cli_subprocess_core` owns:

- provider-profile parsing and normalization
- transport/protocol failure normalization
- honest lower-layer recoverability facts

`cli_subprocess_core` does not own:

- packet/job retry budgets
- repair prompting
- verifier-driven completion
- workflow-level terminal/fail-open policy

Those belong in higher runtimes such as `agent_session_manager` and
`prompt_runner_sdk`.

## Design Intent

The key design rule is:

- normalize facts here
- decide policy above

That keeps provider and transport semantics close to the runtime that actually
observed them, while letting upper layers remain provider-agnostic.
