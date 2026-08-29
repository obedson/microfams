# Booking reservation lifecycle recovery

Atomic reservation creation records the booking hold, expected availability, immutable pricing snapshot, acting organization, correlation ID, and idempotency key. Approval and completion transitions are monotonic and cannot be replayed into a second payout or refund.

Cancellation and refund commands preserve the original booking and pricing evidence. Operators monitor expired holds, rejected transitions, pending refunds, and duplicate requests. Disable new booking acquisition when necessary, but continue servicing existing holds and refunds through governed commands. Never delete or directly edit booking, hold, pricing, refund, or settlement records. Reconcile before restoring service.
