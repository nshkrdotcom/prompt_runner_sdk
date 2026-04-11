# ADR 001: Runtime Boundaries

## Status

Accepted

## Decision

- Prompt Runner owns packet orchestration and verifier-owned completion.
- Agent Session Manager owns provider session lifecycle and event delivery.
- Provider-specific behavior should stay below Prompt Runner wherever possible.

## Consequences

- prompts should reference the repo outputs they need, not internal provider SDK
  details
- verification contracts should be authored in Prompt Runner packet files
