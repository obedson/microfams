# Member account statement operations

AC-06 is tenant scoped and cutoff reproducible. Members may read their own active account; privileged accounting readers may request another active member. The database function enforces this authorization, pagination bounds, and journal-only derivation.

Record the member, currency, date range, page offset, page size, and UTC cutoff for reproducibility. Disable new statement reads with the accounting-read feature flag. Never mutate statement rows; correct financial errors through compensating journal postings and rerun the original request.
