# Requirements Document

## Introduction

This document defines the requirements for the Group & Individual Wallet System on the Microfams platform. The system introduces a Hybrid Ledger model: real-world money movements (inbound collections and outbound bank transfers) are handled via the Interswitch API ecosystem, while internal movements (group-to-user, user-to-user) are handled as atomic database ledger transactions with no external fees.

The wallet system coexists with the existing Paystack integration. Paystack continues to handle bookings, group entry fees, and contribution payments. Interswitch handles all new wallet flows described in this document.

The system is being designed ahead of Interswitch onboarding and must be implementable against the Interswitch sandbox environment first.

Implementation SHALL begin against the Interswitch sandbox environment. All Interswitch API base URLs and credentials SHALL be configurable via environment variables to allow switching between sandbox and production without code changes. Production credentials SHALL only be used after Interswitch approval and security review.

---

## Glossary

- **Wallet_System**: The overall group and individual wallet feature described in this document.
- **Group_Wallet**: The ledger balance associated with a group, funded via its Virtual NUBAN. Stored in the `groups.group_fund_balance` column and tracked in `wallet_transactions`.
- **User_Wallet**: The individual ledger balance for a platform user. Stored in the `user_wallets` table.
- **Virtual_NUBAN**: A static, unique Nigerian Uniform Bank Account Number assigned to a group via the Interswitch Virtual Accounts API, used to receive inbound bank transfers.
- **Interswitch_Service**: The backend service responsible for all communication with the Interswitch API ecosystem (Passport, Virtual Accounts, Name Enquiry, Single Transfer, Transaction Status APIs).
- **Ledger_Service**: The backend service responsible for all internal atomic balance movements between Group_Wallet and User_Wallet records.
- **Withdrawal_Request**: A record representing a user's request to transfer funds from their User_Wallet to an external bank account.
- **Approval_Request**: A record representing a pending group withdrawal that requires multi-party approval before execution.
- **Name_Enquiry**: The process of validating a destination bank account number and bank code via the Interswitch Name Enquiry API before initiating a transfer.
- **Merchant_Pool**: The platform's Interswitch-managed settlement account from which outbound bank transfers are funded.
- **P2P_Transfer**: A peer-to-peer internal ledger transfer between two User_Wallets on the platform.
- **Grace_Period**: A configurable period (in days) during which a suspended or deleted user may withdraw their User_Wallet balance before it is returned to the group.
- **Group_Admin**: A group member with the `owner` role within a group.
- **Platform_Admin**: A user with the `admin` role on the Microfams platform.

---

## Requirements

### Requirement 1: Interswitch Authentication

**User Story:** As a backend service, I want to obtain and cache a valid Interswitch OAuth2 access token, so that all Interswitch API calls are authenticated without redundant token requests.

#### Acceptance Criteria

1. THE Interswitch_Service SHALL obtain an access token from the Interswitch Passport API using the platform's client credentials (client ID and client secret).
2. THE Interswitch_Service SHALL cache the access token in memory until its expiry time minus a 60-second buffer.
3. WHEN a cached token is within 60 seconds of expiry, THE Interswitch_Service SHALL proactively refresh the token before the next API call.
4. IF the Passport API returns an error, THEN THE Interswitch_Service SHALL log the error with a timestamp and throw a typed authentication error to the calling service.
5. THE Interswitch_Service SHALL transmit all API requests over TLS 1.2 or higher.

---

### Requirement 2: Virtual NUBAN Assignment on Group Creation

**User Story:** As a group creator, I want my group to automatically receive a unique Virtual NUBAN at creation time, so that members can immediately fund the group wallet via bank transfer.

#### Acceptance Criteria

1. WHEN a new group is successfully created, THE Wallet_System SHALL call the Interswitch Virtual Accounts API to provision a static Virtual NUBAN for that group.
2. THE Wallet_System SHALL store the assigned Virtual NUBAN, the Interswitch virtual account reference, and the associated group ID in the `group_virtual_accounts` table.
3. IF the Virtual Accounts API call fails during group creation, THEN THE Wallet_System SHALL log the failure, mark the group's NUBAN status as `PENDING`, and retry provisioning up to 3 times with exponential backoff.
4. THE Wallet_System SHALL expose the group's Virtual NUBAN and bank name to authenticated group members via the group details endpoint.
5. THE Wallet_System SHALL assign exactly one static Virtual NUBAN per group and SHALL NOT reassign or replace it after successful provisioning.

---

### Requirement 3: Group Wallet Funding via Inbound Bank Transfer

**User Story:** As a group member, I want funds I transfer to the group's Virtual NUBAN to be automatically credited to the group wallet, so that the group balance reflects real-world deposits without manual intervention.

#### Acceptance Criteria

1. WHEN Interswitch sends a webhook notification for a successful inbound transfer to a Virtual NUBAN, THE Wallet_System SHALL verify the webhook signature using the Interswitch-provided HMAC secret before processing.
2. IF the webhook signature is invalid, THEN THE Wallet_System SHALL return HTTP 400 and log the rejected event without modifying any balance.
3. WHEN a verified inbound transfer webhook is received, THE Wallet_System SHALL atomically credit the Group_Wallet balance and insert a `wallet_transactions` record with type `COLLECTION` and status `SUCCESS`.
4. THE Wallet_System SHALL respond to Interswitch webhook calls with HTTP 200 within 5 seconds of receipt to prevent retry storms.
5. IF a webhook event with the same Interswitch transaction reference has already been processed, THEN THE Wallet_System SHALL return HTTP 200 without modifying any balance (idempotent processing).
6. WHEN a group wallet is credited, THE Wallet_System SHALL send an in-app notification to the Group_Admin identifying the credited amount and the new group balance.

---

### Requirement 4: Group-to-Individual Wallet Withdrawal (Internal Transfer)

**User Story:** As a group member, I want to withdraw my share from the group wallet into my personal wallet, so that I can access my funds independently without incurring transfer fees.

#### Acceptance Criteria

1. WHEN a group member initiates a group withdrawal, THE Wallet_System SHALL create an Approval_Request record with status `PENDING` and notify all active group members and the Group_Admin.
2. THE Wallet_System SHALL require approval from the Group_Admin AND at least 2/3 of active group members (rounded up) before executing the withdrawal.
3. WHILE an Approval_Request is in `PENDING` status, THE Wallet_System SHALL accept approval votes from eligible group members and record each vote with the voter's user ID and timestamp.
4. WHEN the required approval threshold is met, THE Ledger_Service SHALL atomically debit the Group_Wallet and credit the target User_Wallet in a single database transaction.
5. IF the Group_Wallet balance is less than the requested withdrawal amount at the time of execution, THEN THE Wallet_System SHALL reject the withdrawal, set the Approval_Request status to `FAILED`, and notify the Group_Admin.
6. THE Ledger_Service SHALL insert a `wallet_transactions` record with type `INTERNAL_TRANSFER` and status `SUCCESS` upon successful execution.
7. IF the atomic database transaction fails, THEN THE Ledger_Service SHALL roll back all balance changes and set the Approval_Request status to `FAILED`.
8. THE Wallet_System SHALL NOT call any external Interswitch API for group-to-individual internal transfers.

---

### Requirement 5: Individual Wallet-to-Bank Withdrawal (Outward Transfer)

**User Story:** As a platform user, I want to withdraw funds from my personal wallet to my bank account, so that I can access real money in my bank.

#### Acceptance Criteria

1. WHEN a user initiates a wallet-to-bank withdrawal, THE Wallet_System SHALL first call the Interswitch Name Enquiry API to validate the destination account number and bank code.
2. IF the Name Enquiry API returns an invalid or unresolvable account, THEN THE Wallet_System SHALL reject the withdrawal request and return the bank's error message to the user without debiting the User_Wallet.
3. THE Wallet_System SHALL enforce a minimum withdrawal amount of ₦1,000.
4. THE Wallet_System SHALL enforce a maximum cumulative withdrawal of ₦100,000 per user within any rolling 24-hour window.
5. WHEN a valid withdrawal request is submitted, THE Wallet_System SHALL create a Withdrawal_Request record with status `PENDING` and deduct the withdrawal amount plus the applicable Interswitch transfer fee from the User_Wallet balance.
6. THE Wallet_System SHALL display the Interswitch transfer fee to the user before they confirm the withdrawal.
7. WHEN a Withdrawal_Request is in `PENDING` status, THE Interswitch_Service SHALL call the Interswitch Single Transfer API to initiate the payout from the Merchant_Pool to the user's bank account.
8. WHEN Interswitch sends a webhook or callback confirming transfer `SUCCESS`, THE Wallet_System SHALL update the Withdrawal_Request status to `SUCCESS` and insert a `wallet_transactions` record with type `WITHDRAWAL` and status `SUCCESS`.
9. IF Interswitch sends a webhook or callback confirming transfer `FAILED`, THEN THE Wallet_System SHALL reverse the deducted amount back to the User_Wallet, update the Withdrawal_Request status to `FAILED`, and notify the user.
10. WHILE a Withdrawal_Request is in `PENDING` status, THE Wallet_System SHALL allow the user to query the transfer status via the Transaction Status API endpoint.
11. IF a Withdrawal_Request remains in `PENDING` status for more than 24 hours without a terminal webhook, THEN THE Wallet_System SHALL automatically query the Interswitch Transaction Search API and update the Withdrawal_Request status based on the result.

---

### Requirement 6: P2P Wallet Transfer

**User Story:** As a platform user, I want to instantly transfer funds from my wallet to another user's wallet, so that I can pay or share money with anyone on the platform.

#### Acceptance Criteria

1. WHEN a user initiates a P2P transfer, THE Wallet_System SHALL verify that the destination user exists and has an active User_Wallet on the platform.
2. THE Wallet_System SHALL enforce a minimum P2P transfer amount of ₦100.
3. THE Wallet_System SHALL enforce a maximum cumulative outbound P2P transfer of ₦50,000 per user within any rolling 24-hour window (CBN tier-1 KYC limit).
4. IF the sender's User_Wallet balance is less than the transfer amount, THEN THE Wallet_System SHALL reject the transfer and return an insufficient funds error.
5. WHEN all validations pass, THE Ledger_Service SHALL atomically debit the sender's User_Wallet and credit the recipient's User_Wallet in a single database transaction.
6. THE Ledger_Service SHALL insert a `wallet_transactions` record for both the debit and credit legs with type `P2P_TRANSFER` and status `SUCCESS`.
7. IF the atomic database transaction fails, THEN THE Ledger_Service SHALL roll back all balance changes and return an error to the user.
8. THE Wallet_System SHALL NOT call any external Interswitch API for P2P transfers.
9. WHEN a P2P transfer completes, THE Wallet_System SHALL send an in-app notification to both the sender and the recipient with the transfer amount and updated balances.

---

### Requirement 7: User Wallet Provisioning

**User Story:** As a new platform user, I want a personal wallet to be automatically created for me, so that I can receive internal transfers and initiate withdrawals without a separate setup step.

#### Acceptance Criteria

1. WHEN a new user account is successfully created, THE Wallet_System SHALL automatically create a `user_wallets` record for that user with an initial balance of ₦0.00.
2. THE Wallet_System SHALL ensure each user has exactly one User_Wallet record (one-to-one relationship with the `users` table).
3. IF a User_Wallet record does not exist for an existing user (migration scenario), THEN THE Wallet_System SHALL create the missing record on the user's first wallet-related action.
4. THE Wallet_System SHALL expose the authenticated user's current wallet balance and a paginated transaction history via a dedicated wallet endpoint.

---

### Requirement 8: Wallet Transaction Ledger Integrity

**User Story:** As a platform operator, I want every balance movement to be recorded in an immutable ledger, so that I can audit all fund flows and reconcile balances at any time.

#### Acceptance Criteria

1. THE Wallet_System SHALL record every balance movement — COLLECTION, INTERNAL_TRANSFER, WITHDRAWAL, P2P_TRANSFER — as a row in the `wallet_transactions` table before the corresponding balance update is committed.
2. THE Wallet_System SHALL store `source_id`, `destination_id`, `amount`, `type`, `status`, `reference`, and `created_at` on every `wallet_transactions` record.
3. THE Ledger_Service SHALL execute all balance updates and ledger inserts within a single atomic database transaction so that a partial failure leaves no orphaned records.
4. THE Wallet_System SHALL NOT allow direct modification of `wallet_transactions` records after insertion; corrections SHALL be made via compensating transactions.
5. FOR ALL completed wallet transactions, the sum of all credits minus the sum of all debits for a given wallet SHALL equal the current wallet balance (ledger balance invariant).

---

### Requirement 9: Suspended or Deleted User Wallet Handling

**User Story:** As a platform operator, I want suspended or deleted users to be notified and given a grace period to withdraw their wallet balance, so that user funds are not lost and outstanding obligations are settled fairly.

#### Acceptance Criteria

1. WHEN a user account is suspended or deletion is initiated, THE Wallet_System SHALL send the user a notification stating the 30-day grace period end date and the current User_Wallet balance.
2. WHILE a user account is in the 30-day grace period, THE Wallet_System SHALL allow the user to initiate wallet-to-bank withdrawals but SHALL block all inbound transfers (P2P and group-to-individual) to that wallet.
3. THE Wallet_System SHALL deduct any outstanding penalties owed by the user (as recorded in `member_contributions`) from the User_Wallet balance before the 30-day grace period expires.
4. WHEN the 30-day grace period expires and a non-zero balance remains, THE Ledger_Service SHALL automatically transfer the remaining User_Wallet balance back to the Group_Wallet of the user's primary group and insert a `wallet_transactions` record with type `INTERNAL_TRANSFER`.
5. IF the user has no group membership at grace period expiry, THEN THE Wallet_System SHALL flag the remaining balance for manual Platform_Admin review rather than auto-transferring.

---

### Requirement 10: Transaction Status Query

**User Story:** As a platform user, I want to check the current status of any of my pending transactions, so that I know whether my withdrawal or transfer has been processed.

#### Acceptance Criteria

1. THE Wallet_System SHALL provide an authenticated endpoint that returns the current status and details of a transaction given its `transaction_id`.
2. WHEN a Withdrawal_Request status is `PENDING`, THE Wallet_System SHALL include the Interswitch transfer reference in the response so the user can track it externally.
3. THE Wallet_System SHALL return transaction status from the local `wallet_transactions` table without calling the Interswitch API on every query.
4. WHEN a Platform_Admin queries a transaction, THE Wallet_System SHALL return the full transaction record including internal metadata and Interswitch references.

---

### Requirement 11: Security and Compliance

**User Story:** As a platform operator, I want all wallet operations to be secured and auditable, so that the system meets financial compliance standards and protects user funds.

#### Acceptance Criteria

1. THE Wallet_System SHALL validate and sanitize all user-supplied inputs (account numbers, amounts, user IDs) before processing any wallet operation.
2. THE Wallet_System SHALL record every wallet operation (initiation, approval, execution, failure) in the existing `audit_logs` table with the acting user's ID, IP address, and action type.
3. THE Interswitch_Service SHALL store the Interswitch client secret exclusively in environment variables and SHALL NOT log or expose it in API responses or error messages.
4. THE Wallet_System SHALL apply rate limiting of 10 withdrawal or transfer requests per user per 15-minute window.
5. WHEN an Interswitch webhook is received, THE Wallet_System SHALL verify the HMAC signature before processing, as specified in Requirement 3.1.
6. THE Wallet_System SHALL restrict wallet administration endpoints (balance adjustments, manual status overrides) to users with the `admin` role.
