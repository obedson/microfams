# Design Document: Platform Profile and Groups Enhancement

## Overview

This feature extends the Microfams platform across seven areas: a navbar redesign with a profile dropdown, a user profile page with picture upload, NIN identity verification via Interswitch, a revamped group creation eligibility system, a group admin dashboard, a group member dashboard, and platform admin tools for group admin role management. It also introduces a unified "Become a Member" onboarding wizard at `/become-a-member` that combines platform subscription payment and NIN verification into a single guided flow.

The design builds on the existing Express.js + TypeScript backend (Supabase/PostgreSQL, ESM modules) and React + TypeScript frontend (Zustand, React Query, Tailwind CSS). It reuses the existing `interswitchService` singleton for OAuth2 token management, the existing S3 client for file storage, and the existing Paystack verification utility for subscription payments.

---

## Architecture

The feature follows the existing layered architecture:

```
Frontend (React)
  └── pages / components
        └── API services (profileAPI.ts, groupAdminAPI.ts)
              └── apiClient (axios)

Backend (Express)
  └── routes (profile.ts, groupAdmin.ts, auth.ts additions)
        └── controllers (profileController.ts, groupAdminController.ts, authController.ts additions)
              └── services (ninService.ts, paystackService.ts, interswitchService.ts)
                    └── models (User.ts, Group.ts additions)
                          └── Supabase (PostgreSQL)
```

### Key Design Decisions

1. **NIN verification is a two-step flow** (verify → confirm) to allow the user to review Interswitch-returned data before it is persisted. This prevents accidental overwrites and gives the user a chance to abort.

2. **Profile picture upload uses AWS S3 directly** (via the existing `s3Client`) rather than Supabase Storage, consistent with the existing S3 configuration. The `imageService.ts` uses Supabase Storage for property images; profile pictures use S3 to keep concerns separate.

3. **`canCreateGroup()` is a pure function** over three boolean/count inputs, making it straightforward to test and reason about. The HTTP layer translates a `false` return into a 403 with a structured list of unmet conditions.

4. **Vote execution is synchronous** — when the threshold is reached on a `POST /api/groups/:id/members/:memberId/vote` call, the action (suspend/expel) is executed within the same transaction. This avoids a separate background job for a low-frequency operation.

5. **Subscription idempotency** is enforced by checking `subscription_reference` before writing. A duplicate reference returns 400 without modifying any data.

---

## Components and Interfaces

### Backend Components

#### `backend/src/services/ninService.ts`

Responsible for NIN verification via Interswitch and profile picture upload to S3.

```typescript
interface NINVerifyResult {
  full_name: string;
  date_of_birth: string; // ISO date string
  gender: string;
  address: string;
  phone: string;
}

class NINService {
  // Calls Interswitch NIN API, returns data without persisting
  async verifyNIN(nin: string, dateOfBirth: string): Promise<NINVerifyResult>

  // Persists NIN data and sets nin_verified = true
  async confirmNIN(userId: string, nin: string, data: NINVerifyResult): Promise<void>

  // Uploads profile picture to S3, returns HTTPS URL
  async uploadProfilePicture(userId: string, file: Express.Multer.File): Promise<string>
}
```

#### `backend/src/controllers/profileController.ts`

HTTP handlers for profile, NIN, subscription, and picture upload endpoints.

```typescript
// GET /api/auth/profile
getProfile(req, res): Promise<void>

// POST /api/auth/verify-nin
verifyNIN(req, res): Promise<void>

// POST /api/auth/confirm-nin
confirmNIN(req, res): Promise<void>

// POST /api/auth/upload-profile-picture
uploadProfilePicture(req, res): Promise<void>

// POST /api/auth/subscribe
subscribe(req, res): Promise<void>
```

#### `backend/src/controllers/groupAdminController.ts`

HTTP handlers for group admin dashboard and member action votes.

```typescript
// GET /api/groups/:id/admin/dashboard
getAdminDashboard(req, res): Promise<void>

// PUT /api/groups/:id
updateGroup(req, res): Promise<void>

// POST /api/groups/:id/members/:memberId/vote
castVote(req, res): Promise<void>

// GET /api/groups/:id/votes
getVotes(req, res): Promise<void>

// GET /api/groups/:id/member/dashboard
getMemberDashboard(req, res): Promise<void>
```

#### `backend/src/models/Group.ts` (additions)

```typescript
// Updated eligibility check — all 3 conditions
static async canCreateGroup(userId: string): Promise<{
  canCreate: boolean;
  conditions: {
    nin_verified: boolean;
    is_platform_subscriber: boolean;
    paid_invitees: number; // count
  };
}>

// Cast or initiate a vote; returns updated vote count and whether action was executed
static async castMemberActionVote(params: {
  groupId: string;
  actionType: 'suspend' | 'expel';
  targetMemberId: string;
  voterId: string;
}): Promise<{ voteCount: number; threshold: number; executed: boolean }>
```

### Frontend Components

#### `frontend/src/components/ProfileDropdown.tsx`

A self-contained component that renders the circular avatar button and the dropdown menu. Manages its own open/close state. Closes on outside click (via `useEffect` + document listener) and on Escape key.

```typescript
interface ProfileDropdownProps {
  user: User; // from authStore
}
```

#### `frontend/src/pages/Profile.tsx`

Displays profile info, avatar upload, NIN status banner, and editable fields (phone, email). Uses React Query to fetch `/api/auth/profile`.

#### `frontend/src/pages/VerifyNIN.tsx`

Two-step form: step 1 collects the 11-digit NIN and calls `POST /api/auth/verify-nin`; step 2 shows the returned data for confirmation and calls `POST /api/auth/confirm-nin`.

#### `frontend/src/pages/BecomeAMember.tsx`

A 6-step onboarding wizard at `/become-a-member` (authenticated users only). Step state is managed locally with `useState`. Steps in order:

1. **Pay Membership Fee** — renders a Paystack payment button; on success calls `POST /api/auth/subscribe` with the payment reference.
2. **Payment Confirmed** — success screen, auto-advances or user clicks "Continue".
3. **Enter NIN & Date of Birth** — form collecting 11-digit NIN and DOB; calls `POST /api/auth/verify-nin` with both fields.
4. **NIN Verified** — displays returned NIN data for user confirmation; calls `POST /api/auth/confirm-nin` on confirm.
5. **Record Updated** — updates the auth store (`is_platform_subscriber = true`, `nin_verified = true`).
6. **Access Granted** — success screen with a button to navigate to the dashboard or group creation page.

Navigation to a later step is blocked until the current step completes. If the user is already `is_platform_subscriber = true` on mount, the wizard starts at Step 3. If the user is already `nin_verified = true` on mount, they are redirected to the dashboard.

#### `frontend/src/pages/GroupAdminDashboard.tsx`

Fetches `/api/groups/:id/admin/dashboard`. Displays group stats, member list with vote initiation buttons, current cycle status, fund balance, and group edit form.

#### `frontend/src/pages/GroupMemberDashboard.tsx`

Fetches `/api/groups/:id/member/dashboard`. Displays read-only group info, personal membership details, current cycle payment status, fund balance, and member name list.

#### `frontend/src/services/profileAPI.ts`

```typescript
export const profileAPI = {
  getProfile(): Promise<UserProfile>
  verifyNIN(nin: string, dateOfBirth: string): Promise<NINVerifyResult>
  confirmNIN(data: NINConfirmPayload): Promise<void>
  uploadProfilePicture(file: File): Promise<{ url: string }>
  subscribe(paymentReference: string): Promise<void>
}
```

#### `frontend/src/services/groupAdminAPI.ts`

```typescript
export const groupAdminAPI = {
  getAdminDashboard(groupId: string): Promise<AdminDashboardData>
  updateGroup(groupId: string, data: GroupUpdatePayload): Promise<void>
  castVote(groupId: string, memberId: string, actionType: 'suspend' | 'expel'): Promise<VoteResult>
  getVotes(groupId: string): Promise<Vote[]>
  getMemberDashboard(groupId: string): Promise<MemberDashboardData>
}
```

---

## Data Models

### Database Schema Additions (`add_profile_nin_subscription.sql`)

```sql
-- Add new columns to users table
ALTER TABLE users
  ADD COLUMN IF NOT EXISTS nin_number        VARCHAR(11) UNIQUE,
  ADD COLUMN IF NOT EXISTS nin_verified      BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS nin_full_name     VARCHAR(255),
  ADD COLUMN IF NOT EXISTS nin_date_of_birth DATE,
  ADD COLUMN IF NOT EXISTS nin_gender        VARCHAR(10),
  ADD COLUMN IF NOT EXISTS nin_address       TEXT,
  ADD COLUMN IF NOT EXISTS nin_phone         VARCHAR(20),
  ADD COLUMN IF NOT EXISTS profile_picture_url TEXT,
  ADD COLUMN IF NOT EXISTS is_platform_subscriber BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS subscription_paid_at   TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS subscription_reference VARCHAR(100);

-- Enforce: verified users must have a valid NIN
ALTER TABLE users
  ADD CONSTRAINT chk_nin_verified_has_number
    CHECK (nin_verified = FALSE OR (nin_number IS NOT NULL AND char_length(nin_number) = 11));

-- Vote tracking table
CREATE TABLE IF NOT EXISTS group_member_action_votes (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id         UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  action_type      VARCHAR(20) NOT NULL CHECK (action_type IN ('suspend', 'expel')),
  target_member_id UUID NOT NULL REFERENCES users(id),
  voter_id         UUID NOT NULL REFERENCES users(id),
  voted_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (group_id, action_type, target_member_id, voter_id)
);

CREATE INDEX IF NOT EXISTS idx_votes_group_action_target
  ON group_member_action_votes (group_id, action_type, target_member_id);
```

### Updated TypeScript Types

#### `frontend/src/store/authStore.ts` — User interface additions

```typescript
interface User {
  id: string;
  email: string;
  name: string;
  role: 'farmer' | 'owner' | 'admin';
  referral_code?: string;
  paid_referrals_count?: number;
  // New fields
  profile_picture_url?: string | null;
  nin_verified?: boolean;
  is_platform_subscriber?: boolean;
}
```

#### Backend response types

```typescript
// GET /api/auth/profile response
interface UserProfile {
  id: string;
  email: string;
  name: string;
  role: string;
  phone: string | null;
  referral_code: string;
  paid_referrals_count: number;
  profile_picture_url: string | null;
  nin_verified: boolean;
  nin_full_name: string | null;
  nin_date_of_birth: string | null;
  nin_gender: string | null;
  nin_address: string | null;
  nin_number_masked: string | null; // last 4 digits only, e.g. "***1234"
  is_platform_subscriber: boolean;
  subscription_paid_at: string | null;
  created_at: string;
}

// GET /api/groups/:id/admin/dashboard response
interface AdminDashboardData {
  group: GroupDetails;
  stats: {
    total_members: number;
    active_members: number;
    suspended_members: number;
    expelled_members: number;
    total_contributions: number;
  };
  fund: {
    balance: number;
    nuban: string | null;
    bank_name: string | null;
    recent_transactions: WalletTransaction[];
  };
  current_cycle: ContributionCycleStatus | null;
  members: MemberWithStatus[];
  pending_votes: VoteWithCount[];
}

// GET /api/groups/:id/member/dashboard response
interface MemberDashboardData {
  group: { name: string; description: string; category: string; state: string; lga: string };
  membership: {
    join_date: string;
    member_status: string;
    total_contributions: number;
  };
  current_cycle: {
    cycle_period: string;
    amount_due: number;
    payment_status: string;
    deadline_date: string;
    is_late: boolean;
  } | null;
  fund_balance: number;
  member_names: string[];
}
```

---

## Correctness Properties

*A property is a characteristic or behavior that should hold true across all valid executions of a system — essentially, a formal statement about what the system should do. Properties serve as the bridge between human-readable specifications and machine-verifiable correctness guarantees.*

### Property 1: Avatar display fallback

*For any* authenticated user, the profile avatar component should render the user's `profile_picture_url` as an `<img>` src when the field is non-null and non-empty, and should render the user's initials (derived from `name`) when `profile_picture_url` is null or empty.

**Validates: Requirements 1.3, 2.2**

---

### Property 2: Profile picture upload round-trip

*For any* valid image file (JPEG, PNG, or WebP, ≤ 5 MB), uploading via `POST /api/auth/upload-profile-picture` should succeed, and the `profile_picture_url` returned in the response and subsequently returned by `GET /api/auth/profile` should be a valid HTTPS URL whose hostname matches the platform's configured S3 bucket domain.

**Validates: Requirements 2.4, 9.2, 9.3, 9.4**

---

### Property 3: Profile picture overwrite

*For any* user who already has a non-null `profile_picture_url`, uploading a new valid image should replace the stored URL with the new S3 URL, leaving no reference to the previous URL in the user's profile record.

**Validates: Requirements 9.5**

---

### Property 4: Upload file validation

*For any* file whose MIME type is not in `{image/jpeg, image/png, image/webp}` or whose size exceeds 5 MB, `POST /api/auth/upload-profile-picture` should return HTTP 400 and the user's `profile_picture_url` should remain unchanged.

**Validates: Requirements 2.5**

---

### Property 5: NIN verify does not persist

*For any* user with `nin_verified = false`, calling `POST /api/auth/verify-nin` with a valid NIN (even one that Interswitch resolves successfully) should leave `nin_verified = false` and all `nin_*` fields null in the database.

**Validates: Requirements 3.2**

---

### Property 6: NIN verify error isolation

*For any* NIN that causes the Interswitch API to return an error, `POST /api/auth/verify-nin` should return HTTP 422 and the calling user's record should be identical before and after the call.

**Validates: Requirements 3.3**

---

### Property 7: NIN confirm round-trip

*For any* user with `nin_verified = false`, calling `POST /api/auth/confirm-nin` with valid NIN data should result in `nin_verified = true`, all six NIN fields (`nin_number`, `nin_full_name`, `nin_date_of_birth`, `nin_gender`, `nin_address`, `nin_phone`) being non-null, and `GET /api/auth/profile` reflecting those values.

**Validates: Requirements 3.4**

---

### Property 8: NIN immutability

*For any* user with `nin_verified = true`, (a) calling `POST /api/auth/confirm-nin` again should return HTTP 409, and (b) any user-facing endpoint that attempts to update `nin_number`, `nin_full_name`, `nin_date_of_birth`, `nin_gender`, `nin_address`, or `nin_number` should return HTTP 403, leaving all NIN fields unchanged.

**Validates: Requirements 3.5, 3.7**

---

### Property 9: NIN uniqueness invariant

*For any* two distinct users, it should be impossible for both to have the same non-null `nin_number`. Attempting to confirm a NIN that is already associated with another verified user should return HTTP 409 and leave the requesting user's `nin_verified = false`.

**Validates: Requirements 3.6, 8.3**

---

### Property 10: NIN verified users have valid NIN number

*For all* users in the system where `nin_verified = true`, `nin_number` must be non-null and exactly 11 characters in length.

**Validates: Requirements 8.4**

---

### Property 11: NIN gate for group operations

*For any* user with `nin_verified = false`, both `POST /api/groups` (create) and `POST /api/groups/:id/join` should return HTTP 403 with a message directing the user to verify their NIN, and no group or membership record should be created.

**Validates: Requirements 3.8, 3.9**

---

### Property 12: canCreateGroup three-condition gate

*For any* non-admin user, `canCreateGroup()` should return `true` if and only if all three of the following hold: `nin_verified = true`, `is_platform_subscriber = true`, and the count of users where `referred_by = user.id AND is_platform_subscriber = true` is ≥ 2. If any single condition is false, the function must return `false`. Admin users always receive `true` regardless of the three conditions.

**Validates: Requirements 4.1, 4.2**

---

### Property 13: Subscription success sets flag

*For any* valid, unused Paystack payment reference, calling `POST /api/auth/subscribe` should set `is_platform_subscriber = true`, `subscription_paid_at` to a non-null timestamp, and `subscription_reference` to the provided reference on the calling user's record.

**Validates: Requirements 4.3**

---

### Property 14: Subscription idempotency and failure isolation

*For any* Paystack reference that is either invalid or already stored as `subscription_reference` on any user record, `POST /api/auth/subscribe` should return HTTP 400 and the calling user's `is_platform_subscriber` should remain unchanged.

**Validates: Requirements 4.4**

---

### Property 15: Vote threshold triggers action

*For any* group with N active members, when the count of distinct affirmative votes for a given `(group_id, action_type, target_member_id)` tuple reaches `ceil(2/3 × N)`, the target member's `member_status` should be automatically updated to `suspended` (for action_type `suspend`) or `expelled` (for action_type `expel`) within the same request that cast the threshold vote.

**Validates: Requirements 5.9**

---

### Property 16: Vote record creation

*For any* valid call to `POST /api/groups/:id/members/:memberId/vote` by an active group member who has not previously voted on the same action for the same target, a new row should be inserted into `group_member_action_votes` with the correct `group_id`, `action_type`, `target_member_id`, and `voter_id`.

**Validates: Requirements 5.8**

---

### Property 17: Group admin dashboard access control

*For any* authenticated user who is neither the group owner (role `owner` in `group_members`) nor a platform admin, `GET /api/groups/:id/admin/dashboard` should return HTTP 403 and no group data should be disclosed.

**Validates: Requirements 5.1**

---

### Property 18: Group member dashboard access control

*For any* user who is not a paid member (`payment_status = 'paid'`) of the group, `GET /api/groups/:id/member/dashboard` should return HTTP 403.

**Validates: Requirements 6.1**

---

### Property 19: Admin role reassignment

*For any* group and any paid member of that group, calling `PUT /api/admin/groups/:groupId/admin` with `newAdminUserId` set to that member's ID should result in: the new user having `role = 'owner'` in `group_members`, and the previous owner (if any) having `role = 'member'`. No other `group_members` rows should be modified.

**Validates: Requirements 7.2**

---

### Property 20: Admin role removal

*For any* group that has exactly one member with `role = 'owner'`, calling `DELETE /api/admin/groups/:groupId/admin` should result in that member's role being set to `'member'`, leaving the group with zero owner-role members.

**Validates: Requirements 7.4**

---

### Property 21: Admin management endpoint protection

*For any* caller whose JWT role is not `admin`, both `PUT /api/admin/groups/:groupId/admin` and `DELETE /api/admin/groups/:groupId/admin` should return HTTP 403 and no `group_members` records should be modified.

**Validates: Requirements 7.6**

---

### Property 22: Become a Member wizard step ordering

*For any* user navigating the `/become-a-member` wizard, step N+1 must not be reachable without step N having been successfully completed. Specifically: the wizard component's step state must only advance when the current step's async operation resolves successfully, and any attempt to render a later step while an earlier step is incomplete (e.g., `is_platform_subscriber = false` before Step 3, or `nin_verified = false` before Step 5) must result in the wizard remaining on or redirecting back to the appropriate incomplete step.

**Validates: Requirements 10.8, 10.9, 10.10**

---

## Error Handling

### NIN Verification Errors

| Scenario | HTTP Status | Response |
|---|---|---|
| NIN not 11 digits | 400 | `{ error: "NIN must be exactly 11 digits" }` |
| Interswitch API error | 422 | `{ error: "<Interswitch error message>" }` |
| NIN already verified (confirm) | 409 | `{ error: "NIN already verified for this account" }` |
| NIN belongs to another user | 409 | `{ error: "This NIN is already associated with another account" }` |
| Attempt to update NIN fields when verified | 403 | `{ error: "NIN fields are immutable once verified" }` |

### Profile Picture Upload Errors

| Scenario | HTTP Status | Response |
|---|---|---|
| Invalid MIME type | 400 | `{ error: "Invalid file type. Only JPEG, PNG, and WebP are allowed." }` |
| File exceeds 5 MB | 400 | `{ error: "File too large. Maximum size is 5MB." }` |
| S3 upload failure | 500 | `{ error: "Failed to upload profile picture" }` |

### Subscription Errors

| Scenario | HTTP Status | Response |
|---|---|---|
| Invalid Paystack reference | 400 | `{ error: "Payment verification failed" }` |
| Reference already used | 400 | `{ error: "This payment reference has already been used" }` |

### Group Admin / Vote Errors

| Scenario | HTTP Status | Response |
|---|---|---|
| Non-owner/non-admin accessing admin dashboard | 403 | `{ error: "Access denied: group admin only" }` |
| Non-paid-member accessing member dashboard | 403 | `{ error: "Access denied: paid members only" }` |
| Duplicate vote | 409 | `{ error: "You have already voted on this action" }` |
| Voting on own expulsion/suspension | 400 | `{ error: "You cannot vote on an action targeting yourself" }` |
| newAdminUserId not a paid member | 400 | `{ error: "Target user is not a paid member of this group" }` |
| DELETE admin when no admin exists | 404 | `{ error: "No admin found for this group" }` |

### Group Creation Eligibility Errors

When `canCreateGroup()` returns `false`, the API returns:

```json
{
  "error": "Group creation eligibility not met",
  "conditions": {
    "nin_verified": false,
    "is_platform_subscriber": true,
    "paid_invitees_met": false,
    "paid_invitees_count": 1
  }
}
```

---

## Testing Strategy

### Dual Testing Approach

Both unit tests and property-based tests are required. Unit tests cover specific examples, integration points, and edge cases. Property-based tests verify universal correctness across randomized inputs.

### Property-Based Testing

The project already uses **fast-check** (`"fast-check": "^4.6.0"` in `backend/package.json`). All property tests use fast-check arbitraries and run a minimum of **100 iterations** per property.

Each property test is tagged with a comment in the format:
`// Feature: platform-profile-and-groups-enhancement, Property N: <property_text>`

**Property test file:** `backend/src/tests/profile-groups-properties.test.ts`

Property tests to implement:

| Property | Test Description | fast-check Arbitraries |
|---|---|---|
| P1 | Avatar display fallback | `fc.record({ name: fc.string(), profile_picture_url: fc.option(fc.webUrl()) })` |
| P4 | Upload file validation | `fc.record({ mimetype: fc.string(), size: fc.integer() })` |
| P5 | NIN verify non-persistence | `fc.string({ minLength: 11, maxLength: 11 })` with mocked Interswitch |
| P8 | NIN immutability | `fc.record({ nin_number: fc.string({ minLength: 11, maxLength: 11 }) })` |
| P9 | NIN uniqueness | `fc.tuple(fc.uuid(), fc.uuid())` (two distinct user IDs) |
| P10 | NIN verified invariant | `fc.array(fc.record({ nin_verified: fc.boolean(), nin_number: fc.option(fc.string()) }))` |
| P11 | NIN gate | `fc.record({ nin_verified: fc.constant(false) })` |
| P12 | canCreateGroup gate | `fc.record({ nin_verified: fc.boolean(), is_platform_subscriber: fc.boolean(), paid_invitees: fc.integer({ min: 0, max: 10 }) })` |
| P14 | Subscription idempotency | `fc.string()` (random reference strings) |
| P15 | Vote threshold | `fc.integer({ min: 1, max: 50 })` (active member count N) |
| P17 | Admin dashboard access | `fc.record({ role: fc.constantFrom('farmer', 'owner', 'member') })` |
| P18 | Member dashboard access | `fc.record({ payment_status: fc.constantFrom('pending', 'failed') })` |
| P21 | Admin endpoint protection | `fc.record({ role: fc.constantFrom('farmer', 'owner') })` |
| P22 | Become a Member wizard step ordering | `fc.record({ is_platform_subscriber: fc.boolean(), nin_verified: fc.boolean(), step: fc.integer({ min: 1, max: 6 }) })` |

### Unit Tests

**Unit test file:** `backend/src/tests/profile-groups.test.ts`

Focus areas:
- `NINService.verifyNIN()` — mocked Interswitch call, correct field mapping
- `NINService.confirmNIN()` — DB write, nin_verified flag set
- `NINService.uploadProfilePicture()` — mocked S3 PutObject, URL format
- `GroupModel.canCreateGroup()` — all 8 combinations of the 3 boolean conditions
- `GroupModel.castMemberActionVote()` — threshold calculation for various N values
- `profileController.subscribe()` — Paystack mock success and failure paths
- `groupAdminController.getAdminDashboard()` — access control middleware integration
- Admin role reassignment and removal — correct role swaps in `group_members`

### Frontend Tests

- `ProfileDropdown` — renders initials when no picture, renders `<img>` when picture exists, closes on outside click, closes on Escape
- `VerifyNIN` — two-step form state transitions
- `BecomeAMember` — wizard step progression blocked without completing current step, skips payment steps when already subscribed, redirects when already verified
- `CreateGroup` eligibility checklist — correct condition rendering for all 8 combinations
- `GroupAdminDashboard` — vote button visibility, threshold display
