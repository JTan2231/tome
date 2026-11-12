# AGENTS.md

Do not overcomplicate or overarchitect things.

## Testing

Smoke tests are prohibited. Keep testing to a minimum. Add or run only the
focused tests needed to verify the changed behavior.

## Design walkthroughs

- Interpret “walk me through a proposed design” and similar wording as a
  high-level, exploratory design discussion unless the user asks for exact
  terms, implementation readiness, or implementation. Identify the intended
  outcome, likely systems of concern, authority boundaries, broad information
  and control flow, important tradeoffs, and open questions. Prefer installed
  contracts and public product documentation; do not inspect implementation
  code merely to add detail.
- At this stage, a system contract means the externally meaningful promise at
  a boundary: supported capabilities and interfaces; available data and its
  semantics, identity, units, completeness, and freshness; ownership and
  authority; lifecycle, consistency, failure, and recovery behavior; access and
  privacy; compatibility; and material operational limits. A database schema is
  useful evidence about stored shape and enforced invariants, but is not by
  itself a complete contract or necessarily a supported integration surface.
