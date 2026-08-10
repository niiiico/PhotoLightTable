# ADR 004 — The Photos albums are the durable record; rebuild rather than reconcile

- **Date:** 2026-07-30
- **Status:** Accepted
- **Supersedes:** the two-way sync mechanism added earlier the same day

## Context

[ADR 001](adr-001-ratings-outside-photos.md) puts verdicts in this app's store
and mirrors them into Photos albums. That creates two copies of the same facts,
and they drifted: albums edited in Photos.app did not come back, and events
created here did not survive a fresh install.

Three mechanisms were built to keep them in step, each more elaborate than the
last:

1. two-way sync against a stored baseline snapshot,
2. sync plans computed in the store and reconciled at startup,
3. change notifications, to avoid re-snapshotting on every library change.

Each fixed the case in front of it and added state that could itself go stale.
The drift kept reappearing somewhere else.

The framing was wrong. The two stores were being treated as **peers to
reconcile**, when they are not peers: Photos is the library, and this app's
store is a projection of it plus the data PhotoKit cannot hold.

## Decision

The LightTable folder in Photos is the **durable record**. The app can read it
back and rebuild events, picks and rejects from what is there.

- Reading Photos is the recovery path *and* how a fresh install adopts work
  already done — the same code path, not two.
- Writing stays one-directional and debounced, as in ADR 001.
- Reconciliation logic between the two stores is not extended. When they
  disagree, the answer is to re-derive from Photos.

## Consequences

- The app's store can be deleted, lost, or started fresh on another machine
  without losing picks, rejects or events. It cannot lose colour labels, which
  have no album to be recovered from — that asymmetry is real and accepted.
- A rebuild is coarse where reconciliation was fine-grained: it restores what
  the albums say, and anything the albums cannot express is not restored.
- Adoption is deliberately narrow — the app reads *its own* folder structure,
  not arbitrary albums, so it never guesses that some unrelated album means
  "picked".
- New drift bugs should be answered by asking why the rebuild did not cover the
  case, before adding a mechanism to keep the two in step. That is the trap this
  ADR exists to record.
