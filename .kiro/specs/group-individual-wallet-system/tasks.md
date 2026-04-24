# Implementation Plan: Group & Individual Wallet System

## Overview

Implement the Hybrid Ledger wallet system using Interswitch for external money movement and Supabase RPC for internal atomic transfers. Follow the dependency order: migration → interswitchService → ledgerService → walletService → walletController → routes → index.ts → auth/group hooks → webhook → jobs → tests.

## Environment Variables Required

Add to `backend/.env` (document in `.env.example`):
- `INTERSWITCH_BASE_URL` — sandbox: `https://sandbox.interswitchng.com`, prod: `https://api.interswitchgroup.com`
- `INTERSWITCH_CLIENT_ID` — OAuth2 client ID from Interswitch dashboard
- `INTERSWITCH_CLIENT_SECRET` — OAuth2 client secret (never log or expose)
- `INTERSWITCH_WEBHOOK_SECRET` — HMAC-SHA512 signing secret for webhook verification
- `INTERSWITCH_TRANSFER_FEE` — flat fee per outbound transfer in **kobo** (e.g. `5000` = ₦50)

## Tasks

- [x] 1. Create database migration
  - [x] 1.1 Write `backend/migrations/create_wallet_system.sql`
    - Create `user_wallets` table with `id`, `user_id` (UNIQUE FK → users), `balance NUMERIC(15,2) DEFAULT 0 CHECK (balance >= 0)`, `status CHECK IN ('ACTIVE','SUSPENDED','FROZEN')`, `created_at`, `updated_at`
    - Create `wallet_transactions` table (append-only) with all columns from design: `wallet_id`, `source_id`, `destination_id`, `amount CHECK (amount > 0)`, `type`, `direction`, `status`, `reference`, `metadata JSONB`, `created_at`
    - Create `group_virtual_accounts` table with `group_id` (UNIQUE FK → groups), `nuban`, `bank_name`, `interswitch_ref`, `status CHECK IN ('PENDING','ACTIVE','FAILED')`, `retry_count DEFAULT 0`
    - Create `withdrawal_requests` table with `amount CHECK (amount >= 1000)`, `fee_amount`, `account_number`, `bank_code`, `account_name`, `status`, `interswitch_ref`, `internal_ref UNIQUE`, `failure_reason`
    - Create `group_withdrawal_requests` table with `group_id`, `requested_by`, `target_user_id`, `amount`, `status CHECK IN ('PENDING','APPROVED','FAILED','EXECUTED')`
    - Create `group_withdrawal_approvals` table with `UNIQUE(approval_request_id, voter_id)`
    - Add `group_fund_balance NUMERIC(15,2) DEFAULT 0 CHECK (group_fund_balance >= 0)` column to `groups` table (if not exists)
    - Create all indexes from design (idx_user_wallets_user_id, idx_wallet_txns_wallet_id, idx_wallet_txns_reference, idx_wallet_txns_created_at, idx_gva_group_id, idx_gva_nuban, idx_wr_user_id, idx_wr_status, idx_wr_created_at, idx_gwr_group_id, idx_gwr_status, idx_gwa_request_id)
    - Create RLS policy on `wallet_transactions` to block UPDATE and DELETE (immutability)
    - Create `atomic_wallet_credit(p_wallet_id, p_amount, p_type, p_reference, p_metadata)` RPC function — inserts `wallet_transactions` CREDIT row and increments `user_wallets.balance` in one transaction, returns new transaction UUID
    - Create `atomic_wallet_debit(p_wallet_id, p_amount, p_type, p_reference, p_metadata)` RPC function — checks balance >= amount, inserts DEBIT row and decrements balance atomically, raises exception if insufficient funds
    - Create `atomic_p2p_transfer(p_sender_wallet_id, p_recipient_wallet_id, p_amount, p_reference)` RPC function — debits sender and credits recipient in one transaction, returns JSONB with both transaction IDs
    - Create `atomic_group_transfer(p_group_id, p_recipient_wallet_id, p_amount, p_reference, p_approval_request_id)` RPC function — debits `groups.group_fund_balance`, credits `user_wallets.balance`, inserts two `wallet_transactions` rows, updates `group_withdrawal_requests.status = 'EXECUTED'`, all in one transaction
    - _Requirements: 3.3, 4.4, 4.6, 4.7, 5.5, 6.5, 6.6, 8.1, 8.2, 8.3, 8.4_

- [x] 2. Implement `interswitchService.ts`
  - [x] 2.1 Create `backend/src/services/interswitchService.ts` with OAuth2 token management
    - Implement `TokenCache` interface with `accessToken` and `expiresAt` (Unix ms minus 60s buffer)
    - Implement `getAccessToken()`: POST to `${INTERSWITCH_BASE_URL}/passport/oauth/token` with `grant_type=client_credentials`, cache result, return cached token if not expired
    - If Passport API errors, throw typed `InterswitchAuthError` with timestamp in message; never log the client secret
    - All HTTP calls use `axios` with TLS (enforced by HTTPS base URL); set `Content-Type: application/json` and `Authorization: Bearer <token>` headers
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 11.3_
  - [x] 2.2 Implement `provisionVirtualAccount(groupId, groupName)` method
    - POST to Interswitch Virtual Accounts API endpoint; include `groupId` as customer reference
    - Return `{ nuban, bankName, interswitchRef }`; on failure throw with error details for caller to handle retry logic
    - _Requirements: 2.1, 2.2, 2.3_
  - [x] 2.3 Implement `nameEnquiry(accountNumber, bankCode)` method
    - GET Interswitch Name Enquiry API; return `{ accountName, bankCode }` on success
    - On invalid account, throw typed error with bank's error message for propagation to client
    - _Requirements: 5.1, 5.2_
  - [x] 2.4 Implement `singleTransfer(params)` method
    - POST to Interswitch Single Transfer API with `accountNumber`, `bankCode`, `amount` (kobo), `reference`, `narration`
    - Return `{ transferRef, status: 'PENDING' | 'SUCCESS' | 'FAILED' }`
    - _Requirements: 5.7_
  - [x] 2.5 Implement `queryTransactionStatus(reference)` method
    - GET Interswitch Transaction Search API by reference
    - Return `{ status, amount }`; on API error log and rethrow for cron caller to handle
    - _Requirements: 5.11_
  - [x] 2.6 Implement `verifyWebhookSignature(payload, signature)` method
    - Compute `HMAC-SHA512` of raw payload string using `INTERSWITCH_WEBHOOK_SECRET`
    - Return `true` if computed hex equals provided signature, `false` otherwise
    - _Requirements: 3.1, 11.5_

- [x] 3. Implement `ledgerService.ts`
  - [x] 3.1 Create `backend/src/services/ledgerService.ts` with credit and debit methods
    - Implement `creditWallet(params)`: call `supabase.rpc('atomic_wallet_credit', {...})`, return `WalletTransaction`; throw `LedgerTransactionError` on RPC failure
    - Implement `debitWallet(params)`: call `supabase.rpc('atomic_wallet_debit', {...})`; if RPC raises insufficient-funds exception, throw `InsufficientFundsError` (400); other failures throw `LedgerTransactionError` (500)
    - Define and export `InsufficientFundsError` and `LedgerTransactionError` typed error classes
    - _Requirements: 8.1, 8.2, 8.3, 4.5, 5.5, 6.4_
  - [x] 3.2 Implement `atomicP2PTransfer(params)` method
    - Call `supabase.rpc('atomic_p2p_transfer', {...})`; parse returned JSONB into `{ debitTx, creditTx }`
    - On RPC failure, PostgreSQL rolls back atomically; throw `LedgerTransactionError`
    - _Requirements: 4.4, 6.5, 6.6, 6.7, 8.3_
  - [x] 3.3 Implement `atomicGroupTransfer(params)` method
    - Call `supabase.rpc('atomic_group_transfer', {...})`; parse returned JSONB
    - On RPC failure throw `LedgerTransactionError`; caller sets `group_withdrawal_requests.status = 'FAILED'`
    - _Requirements: 4.4, 4.6, 4.7, 8.3_

- [x] 4. Implement `walletService.ts`
  - [x] 4.1 Create `backend/src/services/walletService.ts` — provisioning methods
    - Implement `provisionUserWallet(userId)`: insert into `user_wallets` with `ON CONFLICT (user_id) DO NOTHING`, then select and return the record (idempotent)
    - Implement `provisionGroupNuban(groupId, groupName)`: check `group_virtual_accounts` for existing ACTIVE record first (return early if found); call `interswitchService.provisionVirtualAccount()`; insert into `group_virtual_accounts` with status `ACTIVE`; on failure insert with status `PENDING` and `retry_count = 0`
    - Implement `retryNubanProvisioning(groupId)`: fetch PENDING record, call `provisionVirtualAccount()`, update to ACTIVE or increment `retry_count`; stop retrying after `retry_count >= 3`
    - _Requirements: 2.1, 2.2, 2.3, 2.5, 7.1, 7.2, 7.3_
  - [x] 4.2 Implement balance and history methods
    - Implement `getWalletWithHistory(userId, page, limit)`: fetch `user_wallets` record (create if missing per Req 7.3), fetch paginated `wallet_transactions` ordered by `created_at DESC`
    - Implement `getGroupWallet(groupId, requestingUserId)`: verify requester is a paid group member; return `groups.group_fund_balance`, `group_virtual_accounts` NUBAN details, and recent transactions
    - _Requirements: 2.4, 7.4, 10.1, 10.3_
  - [x] 4.3 Implement P2P transfer method
    - Implement `initiateP2PTransfer(senderId, recipientId, amount)`:
      1. Validate `amount >= 100` (min ₦100), throw 400 if not
      2. Verify recipient exists and has ACTIVE wallet; throw 400 if not
      3. Call `check24hrP2PLimit(senderId, amount)`; throw 429 if exceeded
      4. Call `ledgerService.atomicP2PTransfer()`
      5. Insert audit log entry with `userId`, `ip` (passed as param), action `P2P_TRANSFER`
      6. Send in-app notification to both sender and recipient (use existing `notificationService`)
    - _Requirements: 6.1, 6.2, 6.3, 6.4, 6.5, 6.6, 6.7, 6.8, 6.9, 11.2_
  - [x] 4.4 Implement two-step individual withdrawal methods
    - Implement `previewWithdrawal(userId, accountNumber, bankCode, amount)`:
      1. Validate `amount >= 1000`; throw 400 if not
      2. Call `check24hrWithdrawalLimit(userId, amount)`; throw 429 if exceeded
      3. Call `interswitchService.nameEnquiry(accountNumber, bankCode)`; propagate error on failure
      4. Read `INTERSWITCH_TRANSFER_FEE` from env (default `5000` kobo = ₦50)
      5. Verify wallet balance >= amount + fee; throw `InsufficientFundsError` if not
      6. Generate signed `preview_token` (JWT or UUID stored in cache with 5-min TTL) containing `{ userId, accountNumber, bankCode, amount, fee, accountName }`
      7. Return `{ accountName, fee, previewToken }`
    - Implement `confirmWithdrawal(userId, previewToken)`:
      1. Validate and decode `preview_token`; throw 400 if expired or invalid
      2. Call `ledgerService.debitWallet()` for `amount + fee` with type `WITHDRAWAL`
      3. Insert `withdrawal_requests` record with status `PENDING`
      4. Call `interswitchService.singleTransfer()`; store returned `transferRef` on the request record
      5. Insert audit log entry
      6. Return `WithdrawalRequest` with status `PENDING`
    - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 5.7, 11.1, 11.2_
  - [x] 4.5 Implement withdrawal webhook and status methods
    - Implement `handleWithdrawalWebhook(interswitchRef, status)`:
      - Find `withdrawal_requests` by `interswitch_ref`; if not found log warning and return
      - If `status = 'SUCCESS'`: update request to `SUCCESS`, insert `wallet_transactions` WITHDRAWAL SUCCESS record
      - If `status = 'FAILED'`: call `ledgerService.creditWallet()` to reverse `amount + fee`, update request to `FAILED`, notify user
    - Implement `check24hrWithdrawalLimit(userId, amount)`: sum WITHDRAWAL debits in last 24hr from `wallet_transactions`; throw if sum + amount > 100000 (₦100,000)
    - Implement `check24hrP2PLimit(userId, amount)`: sum P2P_TRANSFER debits in last 24hr; throw if sum + amount > 50000 (₦50,000)
    - _Requirements: 5.8, 5.9, 5.4, 6.3, 11.2_
  - [x] 4.6 Implement group withdrawal (multi-sig) methods
    - Implement `initiateGroupWithdrawal(groupId, requestedBy, amount, targetUserId)`:
      1. Verify `requestedBy` is a paid member of `groupId`
      2. Verify `targetUserId` has an ACTIVE wallet
      3. Insert `group_withdrawal_requests` with status `PENDING`
      4. Notify all active group members and Group_Admin via `notificationService`
      5. Insert audit log entry
    - Implement `castApprovalVote(requestId, voterId)`:
      1. Fetch request; reject if not PENDING
      2. Verify `voterId` is an active member of the request's group
      3. Insert into `group_withdrawal_approvals` (UNIQUE constraint prevents double-vote)
      4. Count total approvals; fetch active member count
      5. Check threshold: Group_Admin has voted AND total_approvals >= ceil(2/3 * active_members)
      6. If threshold met: call `ledgerService.atomicGroupTransfer()`; on failure set request to FAILED
      7. Return `{ approved: boolean, voteCount, threshold, status }`
    - Implement `getGroupWithdrawalRequest(requestId)`: return request with approval list
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 4.7, 4.8, 11.2_
  - [x] 4.7 Implement webhook ingress and grace period methods
    - Implement `handleInterswitchWebhook(payload, signature)`:
      1. Call `interswitchService.verifyWebhookSignature()`; throw 400 if invalid
      2. Parse payload; extract `nuban` and `amount` and `reference`
      3. Check `wallet_transactions` for existing `reference` (idempotency); return early if found
      4. Look up `group_virtual_accounts` by `nuban`; log warning and return if not found
      5. Call `ledgerService.creditWallet()` on the group (update `groups.group_fund_balance`)
      6. Notify Group_Admin of credited amount and new balance
    - Implement `handleGracePeriodExpiry(userId)`:
      1. Fetch user's outstanding penalties from `member_contributions`
      2. Deduct penalties via `ledgerService.debitWallet()` if balance allows
      3. If remaining balance > 0 and user has a primary group: call `ledgerService.atomicGroupTransfer()` back to group
      4. If no group membership: flag balance for Platform_Admin review (insert audit log with action `GRACE_PERIOD_MANUAL_REVIEW`)
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 9.2, 9.3, 9.4, 9.5_

- [x] 5. Implement `walletController.ts`
  - [x] 5.1 Create `backend/src/controllers/walletController.ts` — individual wallet handlers
    - Implement `getWallet`: call `walletService.getWalletWithHistory(req.user.id, page, limit)`; return 200 with wallet and transactions
    - Implement `getTransaction`: fetch single `wallet_transactions` row by ID; verify it belongs to `req.user.id`; return 200 or 404
    - Implement `initiateP2P`: validate body with Joi (`recipientId: UUID`, `amount: number min 100`); call `walletService.initiateP2PTransfer()`; pass `req.ip` for audit log; return 200
    - Implement `previewWithdrawal`: validate body (`accountNumber`, `bankCode`, `amount`); call `walletService.previewWithdrawal()`; return 200 with `{ accountName, fee, previewToken }`
    - Implement `confirmWithdrawal`: validate body (`previewToken`); call `walletService.confirmWithdrawal()`; return 202 with `{ withdrawalId, status: 'PENDING' }`
    - Implement `getWithdrawalStatus`: fetch `withdrawal_requests` by ID; verify ownership; return status and `interswitch_ref` if PENDING
    - _Requirements: 5.6, 5.10, 6.1, 7.4, 10.1, 10.2, 10.3, 11.1, 11.4_
  - [x] 5.2 Implement group wallet handlers
    - Implement `getGroupWallet`: call `walletService.getGroupWallet(req.params.id, req.user.id)`; return 200
    - Implement `initiateGroupWithdrawal`: validate body (`amount`, `targetUserId`); call `walletService.initiateGroupWithdrawal()`; return 201 with `{ requestId }`
    - Implement `castApprovalVote`: call `walletService.castApprovalVote(req.params.requestId, req.user.id)`; return 200 with vote result
    - Implement `getGroupWithdrawalRequest`: call `walletService.getGroupWithdrawalRequest(req.params.requestId)`; return 200
    - _Requirements: 4.1, 4.2, 4.3, 10.4_
  - [x] 5.3 Implement Interswitch webhook handler
    - Implement `interswitchWebhook`: extract raw body string and `x-interswitch-signature` header; call `walletService.handleInterswitchWebhook()`; return 200 on success, 400 on invalid signature, 500 on DB error (Interswitch will retry)
    - Must respond within 5 seconds — no synchronous heavy work; offload if needed
    - _Requirements: 3.1, 3.2, 3.4, 3.5_

- [x] 6. Create wallet routes and register in app
  - [x] 6.1 Create `backend/src/routes/wallet.ts`
    - Apply dedicated rate limiter: `rateLimit({ windowMs: 15*60*1000, max: 10, keyGenerator: (req) => req.user?.id })` to all wallet mutation routes
    - Register individual routes (all require `authenticateToken`):
      - `GET /` → `getWallet`
      - `GET /transactions/:id` → `getTransaction`
      - `POST /p2p` → `initiateP2P`
      - `POST /withdraw` → `previewWithdrawal`
      - `POST /withdraw/confirm` → `confirmWithdrawal`
      - `GET /withdraw/:id/status` → `getWithdrawalStatus`
    - Register group wallet routes (all require `authenticateToken`):
      - `GET /groups/:id/wallet` → `getGroupWallet`
      - `POST /groups/:id/withdraw` → `initiateGroupWithdrawal`
      - `POST /groups/:id/withdraw/:requestId/approve` → `castApprovalVote`
      - `GET /groups/:id/withdraw/:requestId` → `getGroupWithdrawalRequest`
    - Wrap all handlers with `asyncHandler`
    - _Requirements: 11.4_
  - [x] 6.2 Register Interswitch webhook route in `backend/src/routes/webhooks.ts`
    - Add `router.post('/interswitch', interswitchWebhook)` — raw body already handled by `express.raw` middleware in `index.ts`
    - Import `interswitchWebhook` from `walletController.ts`
    - _Requirements: 3.1_
  - [x] 6.3 Register wallet routes in `backend/src/index.ts`
    - Import `walletRoutes` from `./routes/wallet.js`
    - Add `app.use('/api/wallet', walletRoutes)` after existing route registrations
    - Import and call `startWalletJobs()` alongside existing cron job calls (production only)
    - _Requirements: 7.4_

- [x] 7. Hook wallet provisioning into existing user and group creation flows
  - [x] 7.1 Modify `backend/src/controllers/authController.ts` — add wallet provisioning after user creation
    - Import `WalletService` from `../services/walletService.js`
    - In the `register` handler, after `UserModel.create(value)` succeeds, call `walletService.provisionUserWallet(user.id)` in a try/catch — log failure but do NOT fail the registration response (wallet can be created on first use per Req 7.3)
    - _Requirements: 7.1, 7.2_
  - [x] 7.2 Modify `backend/src/models/Group.ts` — add NUBAN provisioning after group creation
    - Import `WalletService` from `../services/walletService.js`
    - In `createWithPayment`, after the group is successfully fetched, call `walletService.provisionGroupNuban(group.id, group.name)` in a try/catch — log failure but do NOT fail the group creation response (NUBAN will be retried by cron per Req 2.3)
    - _Requirements: 2.1, 2.2, 2.3_

- [x] 8. Implement cron jobs in `backend/src/jobs/walletJobs.ts`
  - [x] 8.1 Create `backend/src/jobs/walletJobs.ts` with pending withdrawal timeout job
    - Schedule with `node-cron` every hour: `cron.schedule('0 * * * *', ...)`
    - Query `withdrawal_requests` where `status = 'PENDING'` and `created_at < NOW() - INTERVAL '24 hours'`
    - For each: call `interswitchService.queryTransactionStatus(interswitch_ref)` and call `walletService.handleWithdrawalWebhook()` with the result
    - On `queryTransactionStatus` error: log and skip (retry next cycle)
    - _Requirements: 5.11_
  - [x] 8.2 Implement grace period expiry job
    - Schedule with `node-cron` daily at 02:00: `cron.schedule('0 2 * * *', ...)`
    - Query `users` joined with `user_wallets` where `account_status IN ('suspended','deleted')` and `grace_period_ends_at < NOW()` and `user_wallets.balance > 0`
    - For each: call `walletService.handleGracePeriodExpiry(userId)`
    - Export `startWalletJobs()` function that schedules both jobs
    - _Requirements: 9.3, 9.4, 9.5_
  - [x] 8.3 Implement NUBAN retry job
    - Schedule with `node-cron` every 5 minutes: `cron.schedule('*/5 * * * *', ...)`
    - Query `group_virtual_accounts` where `status = 'PENDING'` and `retry_count < 3`
    - For each: call `walletService.retryNubanProvisioning(groupId)` with exponential backoff check (`retry_count` determines delay: 1min, 2min, 4min since last attempt using `updated_at`)
    - _Requirements: 2.3_

- [x] 9. Checkpoint — verify integration compiles and routes are reachable
  - Ensure all TypeScript files compile without errors (`tsc --noEmit`)
  - Ensure all new routes appear in the Express router (check with a quick GET /api/wallet returning 401 for unauthenticated)
  - Ensure all tests pass, ask the user if questions arise.

- [x] 10. Write property-based tests
  - [x] 10.1 Create `backend/src/tests/wallet-properties.test.ts` — scaffold file with imports and jest/fast-check setup
    - Import `fc` from `fast-check`, import service mocks/stubs
    - All properties use `numRuns: 100`
    - Tag format above each `it()`: `// Feature: group-individual-wallet-system, Property N: <text>`
    - _Requirements: 8.5, 3.5, 3.1, 4.4, 4.2, 5.4, 6.3, 4.5, 5.3, 7.1, 2.5, 11.2, 11.6, 5.9, 9.2_
  - [x]* 10.2 Write Property 1: Ledger Balance Invariant
    - // Feature: group-individual-wallet-system, Property 1: Ledger Balance Invariant
    - Generate random sequences of credit/debit amounts via `fc.array(fc.record({ direction: fc.constantFrom('CREDIT','DEBIT'), amount: fc.integer({ min: 1, max: 100000 }) }))`, compute expected balance, verify it equals sum(credits) - sum(debits)
    - **Validates: Requirements 8.5**
  - [x]* 10.3 Write Property 2: Webhook Idempotency
    - // Feature: group-individual-wallet-system, Property 2: Webhook Idempotency
    - Generate `fc.record({ reference: fc.uuid(), amount: fc.integer({ min: 100, max: 1000000 }) })`; process webhook twice; assert balance and transaction count unchanged after second call
    - **Validates: Requirements 3.5**
  - [x]* 10.4 Write Property 3: Webhook HMAC Validation
    - // Feature: group-individual-wallet-system, Property 3: Webhook HMAC Validation
    - Generate `fc.tuple(fc.string(), fc.boolean())` for (payload, useValidSig); compute valid HMAC when `useValidSig=true`, use random string otherwise; assert 400 + no balance change on invalid, credit on valid
    - **Validates: Requirements 3.1, 3.2, 3.3**
  - [x]* 10.5 Write Property 4: Internal Transfer Atomicity
    - // Feature: group-individual-wallet-system, Property 4: Internal Transfer Atomicity
    - Generate `fc.integer({ min: 100, max: 50000 })` for transfer amount; mock RPC to fail mid-transfer; assert both sender and recipient balances unchanged
    - **Validates: Requirements 4.4, 4.7, 6.5, 6.7, 8.3**
  - [x]* 10.6 Write Property 5: Approval Threshold Invariant
    - // Feature: group-individual-wallet-system, Property 5: Approval Threshold Invariant
    - Generate `fc.integer({ min: 1, max: 50 })` for active member count; generate vote counts below/at/above `ceil(2/3 * count)`; assert transfer executes only when admin voted AND count >= threshold
    - **Validates: Requirements 4.2**
  - [x]* 10.7 Write Property 6: 24-Hour Withdrawal Limit
    - // Feature: group-individual-wallet-system, Property 6: 24-Hour Withdrawal Limit
    - Generate `fc.array(fc.integer({ min: 1000, max: 50000 }))` as prior withdrawals; generate a new withdrawal amount; assert rejection when cumulative sum > 100000
    - **Validates: Requirements 5.4**
  - [x]* 10.8 Write Property 7: 24-Hour P2P Limit
    - // Feature: group-individual-wallet-system, Property 7: 24-Hour P2P Limit
    - Generate `fc.array(fc.integer({ min: 100, max: 25000 }))` as prior P2P transfers; assert rejection when cumulative sum > 50000
    - **Validates: Requirements 6.3**
  - [x]* 10.9 Write Property 8: Insufficient Funds Rejection
    - // Feature: group-individual-wallet-system, Property 8: Insufficient Funds Rejection
    - Generate `fc.tuple(fc.integer({ min: 0, max: 99999 }), fc.integer({ min: 1, max: 100000 }))` as (balance, amount) where amount > balance; assert rejection and balance unchanged
    - **Validates: Requirements 4.5, 5.5, 6.4**
  - [x]* 10.10 Write Property 9: Input Validation Rejection
    - // Feature: group-individual-wallet-system, Property 9: Input Validation Rejection
    - Generate `fc.oneof(fc.integer({ max: -1 }), fc.constant(0), fc.constant(999))` for invalid amounts; assert 4xx response and no external API call
    - **Validates: Requirements 5.3, 6.2, 11.1**
  - [x]* 10.11 Write Property 10: Wallet Provisioning Uniqueness
    - // Feature: group-individual-wallet-system, Property 10: Wallet Provisioning Uniqueness
    - Generate `fc.uuid()` for userId; call `provisionUserWallet()` 2–5 times; assert exactly one `user_wallets` record exists with balance 0 and status ACTIVE
    - **Validates: Requirements 7.1, 7.2**
  - [x]* 10.12 Write Property 11: NUBAN Uniqueness and Immutability
    - // Feature: group-individual-wallet-system, Property 11: NUBAN Uniqueness and Immutability
    - Generate `fc.uuid()` for groupId; call `provisionGroupNuban()` multiple times; assert at most one ACTIVE record and NUBAN value unchanged after first success
    - **Validates: Requirements 2.5**
  - [x]* 10.13 Write Property 12: Audit Log Completeness
    - // Feature: group-individual-wallet-system, Property 12: Audit Log Completeness
    - Generate `fc.record({ userId: fc.uuid(), action: fc.constantFrom('P2P_TRANSFER','WITHDRAWAL','GROUP_TRANSFER'), amount: fc.integer({ min: 100 }) })`; execute operation; assert `audit_logs` row exists with matching userId, ip, and action
    - **Validates: Requirements 11.2**
  - [x]* 10.14 Write Property 13: Admin Role Enforcement
    - // Feature: group-individual-wallet-system, Property 13: Admin Role Enforcement
    - Generate `fc.constantFrom('farmer','owner')` for JWT role; call admin-only endpoints; assert HTTP 403 and no data modification
    - **Validates: Requirements 11.6**
  - [x]* 10.15 Write Property 14: Withdrawal Reversal on Failure
    - // Feature: group-individual-wallet-system, Property 14: Withdrawal Reversal on Failure
    - Generate `fc.integer({ min: 1000, max: 100000 })` for withdrawal amount; record balance before debit; simulate FAILED webhook; assert balance restored to exact pre-withdrawal value
    - **Validates: Requirements 5.9**
  - [x]* 10.16 Write Property 15: Suspended User Inbound Block
    - // Feature: group-individual-wallet-system, Property 15: Suspended User Inbound Block
    - Generate `fc.record({ senderId: fc.uuid(), recipientId: fc.uuid(), amount: fc.integer({ min: 100 }) })` where recipient wallet status is SUSPENDED; assert rejection before any balance change
    - **Validates: Requirements 9.2**

- [x] 11. Write unit tests
  - [x]* 11.1 Create `backend/src/tests/wallet.test.ts` — interswitchService unit tests
    - Test token caching: fresh token is reused on second call (no second HTTP request)
    - Test token refresh: expired token (mock `expiresAt` in past) triggers new fetch
    - Test `verifyWebhookSignature` with known HMAC-SHA512 vector (precomputed expected hash)
    - Test `verifyWebhookSignature` returns false for tampered payload
    - _Requirements: 1.2, 1.3, 3.1_
  - [x]* 11.2 Write unit tests for `walletService.previewWithdrawal`
    - Test fee is read from `INTERSWITCH_TRANSFER_FEE` env and included in response
    - Test rejection when `amount < 1000`
    - Test rejection when balance < amount + fee
    - Test that name enquiry error is propagated as 422 to caller
    - _Requirements: 5.1, 5.2, 5.3, 5.6_
  - [x]* 11.3 Write unit tests for `walletService.castApprovalVote` threshold logic
    - 1 member (admin only): threshold = 1, executes after admin votes
    - 2 members: threshold = ceil(2/3 * 2) = 2, requires both
    - 3 members: threshold = 2, admin + 1 other
    - 6 members: threshold = 4
    - 10 members: threshold = 7
    - _Requirements: 4.2_
  - [x]* 11.4 Write unit tests for `walletService.handleGracePeriodExpiry`
    - Test penalty deduction before transfer
    - Test transfer to primary group when membership exists
    - Test audit log flag when no group membership
    - _Requirements: 9.3, 9.4, 9.5_
  - [x]* 11.5 Write unit tests for webhook handler
    - Valid COLLECTION event credits group wallet and inserts transaction
    - Duplicate reference returns early with no balance change
    - Unknown NUBAN logs warning and returns without error
    - _Requirements: 3.3, 3.5, 3.6_
  - [x]* 11.6 Write unit tests for route authentication
    - Unauthenticated request to `GET /api/wallet` returns 401
    - Non-admin request to admin endpoint returns 403
    - _Requirements: 11.6_

- [x] 12. Write integration tests
  - [x]* 12.1 Create `backend/src/tests/wallet-integration.test.ts` — full withdrawal flow
    - Seed user with wallet balance; call `previewWithdrawal`; call `confirmWithdrawal`; simulate SUCCESS webhook; assert `withdrawal_requests.status = 'SUCCESS'` and `wallet_transactions` record exists
    - _Requirements: 5.1, 5.5, 5.7, 5.8_
  - [x]* 12.2 Write integration test for full P2P flow
    - Seed two users with wallets; call `initiateP2PTransfer`; assert sender balance decreased and recipient balance increased by exact amount; assert two `wallet_transactions` rows exist
    - _Requirements: 6.5, 6.6_
  - [x]* 12.3 Write integration test for group withdrawal multi-sig flow
    - Seed group with 3 members and group balance; initiate group withdrawal; cast votes until threshold met; assert `group_withdrawal_requests.status = 'EXECUTED'` and target user wallet credited
    - _Requirements: 4.2, 4.4, 4.6_
  - [x]* 12.4 Write integration test for NUBAN provisioning retry
    - Mock `interswitchService.provisionVirtualAccount` to fail on first call; assert `group_virtual_accounts.status = 'PENDING'`; mock success on retry; call `retryNubanProvisioning`; assert status = 'ACTIVE'
    - _Requirements: 2.3_

- [x] 13. Final checkpoint — ensure all tests pass
  - Run `jest --testPathPattern=wallet --runInBand` to execute all wallet test files
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- Tasks marked with `*` are optional and can be skipped for a faster MVP
- All amounts in `wallet_transactions` and `withdrawal_requests` are stored in **naira** (not kobo); `INTERSWITCH_TRANSFER_FEE` env var is in **kobo** and must be divided by 100 before storage
- The `preview_token` in the two-step withdrawal can be implemented as a short-lived JWT signed with `JWT_SECRET` or as a UUID key in a Redis/in-memory cache with 5-minute TTL
- Interswitch sandbox base URL: `https://sandbox.interswitchng.com`; production: `https://api.interswitchgroup.com`
- Property tests (tasks 10.2–10.16) are all optional (`*`) — they validate universal correctness but can be deferred
- Each property test must run with `numRuns: 100` via `fc.assert(fc.property(...), { numRuns: 100 })`
