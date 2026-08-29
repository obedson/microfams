# Booking reservation rollback

If an atomic booking reservation or owner transition is degraded, stop new acquisition with the backend booking flag. Existing holds, cancellations, refunds, and completions remain visible and are recovered by their idempotent commands.

Preserve immutable pricing snapshots and audit evidence. Release or cancel only through the approved reservation lifecycle command, then verify availability, payout, refund, and tenant reconciliation. Direct database edits and deletion are prohibited.
