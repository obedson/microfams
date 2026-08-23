# Dividend entitlement operations

The entitlement calculation is tenant scoped, idempotent, journal-independent, and immutable after creation. It only creates a calculated snapshot; review, approval, payable recognition, and payment are separate workflows. Disable new calculations with the accounting posting feature flag. Correct mistakes through a new governed distribution key; never edit snapshot rows.
