# Booking foundation recovery

For atomic booking creation and reservation holds, preserve the immutable pricing snapshot and booking state-transition history. Payouts, refunds, and disputes remain separate state machines with their own idempotency and audit evidence.

During an incident, suspend new booking creation or provider submission with the relevant feature flag. Recover pending holds, payouts, refunds, or disputes through their approved commands. Never delete or directly mutate booking records, pricing snapshots, settlement journals, or dispute decisions. Confirm tenant isolation and reconciliation before restoring service.
