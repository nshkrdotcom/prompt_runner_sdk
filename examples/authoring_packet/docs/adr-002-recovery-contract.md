# ADR 002: Recovery Contract

## Status

Accepted

## Decision

- completion is determined by deterministic verification, not provider success
- retries are policy-driven and bounded
- repair is allowed when the verifier shows unmet work after partial progress

## Consequences

- every prompt should declare a `verify:` contract
- checklists are generated from that contract and are not the source of truth
