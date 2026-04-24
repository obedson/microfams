# Implementation Plan: Platform Profile and Groups Enhancement

## Overview

Implement the platform profile, NIN verification, group creation overhaul, group admin/member dashboards, and admin role management. The plan follows the layered architecture: database → backend services/models → controllers/routes → frontend services → frontend pages/components.

## Tasks

- [x] 1. Database migration
  - Create `backend/migrations/add_profile_nin_subscription.sql` with all new `users` columns (`nin_number`, `nin_verified`, `nin_full_name`, `nin_date_of_birth`, `nin_gender`, `nin_address`, `nin_phone`, `profile_picture_url`, `is_platform_subscriber`, `subscription_paid_at`, `subscription_reference`), the `chk_nin_verified_has_number` CHECK constraint, and the `group_member_action_votes` table with its UNIQUE constraint and index
  - _Requirements: 8.1, 8.2, 8.3, 8.4_

- [x] 2. Update `frontend/src/store/authStore.ts` User type
  - Add `profile_picture_url?: string | null`, `nin_verified?: boolean`, `is_platform_subscriber?: boolean` to the `User` interface
  - _Requirements: 1.3, 3.11, 4.1_

- [x] 3. Implement `backend/src/services/ninService.ts`
  - [x] 3.1 Implement `NINService.verifyNIN(nin, dateOfBirth)` — call Interswitch NIN API via existing `interswitchService`, return `NINVerifyResult` without persisting; throw on API error
    - _Requirements: 3.1, 3.2, 3.3_
  - [x] 3.2 Implement `NINService.confirmNIN(userId, nin, data)` — write all six NIN fields and set `nin_verified = true`; enforce 409 if already verified or NIN already taken
    - _Requirements: 3.4, 3.5, 3.6_
  - [x] 3.3 Implement `NINService.uploadProfilePicture(userId, file)` — validate MIME type and size, upload to S3 via existing `s3Client`, update `profile_picture_url`, return HTTPS URL
    - _Requirements: 9.1, 9.2, 9.3, 9.4, 9.5, 2.4, 2.5_

- [x] 4. Update `backend/src/models/Group.ts`
  - [x] 4.1 Rewrite `canCreateGroup(userId)` to return `{ canCreate: boolean; conditions: { nin_verified, is_platform_subscriber, paid_invitees } }` — query `users` for `nin_verified` and `is_platform_subscriber`, count `referred_by = userId AND is_platform_subscriber = true`; admins always get `canCreate: true`
    - _Requirements: 4.1, 4.2_
  - [x] 4.2 Implement `castMemberActionVote({ groupId, actionType, targetMemberId, voterId })` — insert into `group_member_action_votes` (409 on duplicate), count active members, compute threshold `ceil(2/3 × N)`, execute suspend/expel if threshold reached, return `{ voteCount, threshold, executed }`
    - _Requirements: 5.8, 5.9_

- [x] 5. Implement `backend/src/controllers/profileController.ts`
  - [x] 5.1 `getProfile` — query `users` for all profile fields including masked NIN (last 4 digits); protected by `authenticateToken`
    - _Requirements: 2.1, 2.6, 2.7, 2.8, 2.9, 2.10_
  - [x] 5.2 `verifyNIN` — validate `{ nin, date_of_birth }` (both required, NIN 11 digits), call `NINService.verifyNIN`, return result without persisting; 422 on Interswitch error
    - _Requirements: 3.1, 3.2, 3.3, 10.12_
  - [x] 5.3 `confirmNIN` — call `NINService.confirmNIN`; 409 if already verified or NIN taken
    - _Requirements: 3.4, 3.5, 3.6_
  - [x] 5.4 `uploadProfilePicture` — call `NINService.uploadProfilePicture` with multer file; return new URL
    - _Requirements: 9.1, 9.2, 9.3_
  - [x] 5.5 `subscribe` — validate Paystack reference, check `subscription_reference` uniqueness (400 if duplicate), verify via `paystackService`, set `is_platform_subscriber = true`, `subscription_paid_at`, `subscription_reference`
    - _Requirements: 4.3, 4.4_

- [x] 6. Implement `backend/src/routes/profile.ts` and wire into `backend/src/routes/auth.ts`
  - Create `profile.ts` with routes: `GET /profile`, `POST /verify-nin`, `POST /confirm-nin`, `POST /upload-profile-picture` (multer middleware), `POST /subscribe` — all protected by `authenticateToken`
  - Register these routes in `backend/src/routes/auth.ts` (import and mount the profile router)
  - _Requirements: 2.1, 3.1, 3.4, 9.1, 4.3_

- [x] 7. Update `backend/src/routes/groups.ts` — add NIN gate
  - In `POST /` (create group): call updated `canCreateGroup()`; if `canCreate = false`, return 403 with structured `conditions` object
  - In `POST /:id/join`: check `nin_verified` on the requesting user; return 403 with NIN message if false
  - Update `GET /can-create` response to return the new `{ canCreate, conditions }` shape
  - _Requirements: 3.8, 3.9, 4.7_

- [x] 8. Implement `backend/src/controllers/groupAdminController.ts`
  - [x] 8.1 `getAdminDashboard` — verify caller is group owner or platform admin (403 otherwise); query group details, stats, fund balance/NUBAN/recent transactions, current cycle, member list with statuses, pending votes
    - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 5.7_
  - [x] 8.2 `updateGroup` — allow editing name, description, category, `max_members`; block `contribution_amount` edit when active cycle exists
    - _Requirements: 5.10, 5.11_
  - [x] 8.3 `castVote` — call `GroupModel.castMemberActionVote`; 409 on duplicate vote, 400 on self-vote
    - _Requirements: 5.8, 5.9_
  - [x] 8.4 `getVotes` — return all pending votes with counts for the group
    - _Requirements: 5.6_
  - [x] 8.5 `getMemberDashboard` — verify caller is a paid member (403 otherwise); return read-only group info, membership details, current cycle payment status, fund balance, member names only
    - _Requirements: 6.1, 6.2, 6.3, 6.4, 6.5, 6.6, 6.7_

- [x] 9. Implement `backend/src/routes/groupAdmin.ts` and register in `backend/src/index.ts`
  - Routes: `GET /groups/:id/admin/dashboard`, `PUT /groups/:id`, `POST /groups/:id/members/:memberId/vote`, `GET /groups/:id/votes`, `GET /groups/:id/member/dashboard` — all protected by `authenticateToken`
  - Register `groupAdminRoutes` in `backend/src/index.ts` under `/api`
  - _Requirements: 5.1, 5.8, 6.1_

- [x] 10. Update `backend/src/routes/admin.ts` — group admin role management
  - Add `PUT /groups/:groupId/admin` — verify `newAdminUserId` is a paid member, swap roles in `group_members` (new user → `owner`, previous owner → `member`)
  - Add `DELETE /groups/:groupId/admin` — set current owner's role to `member`; 404 if no owner exists
  - Both routes already covered by `requireRole(['admin'])` middleware at router level
  - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5, 7.6_

- [x] 11. Checkpoint — backend complete
  - Ensure all tests pass, ask the user if questions arise.

- [x] 12. Implement `frontend/src/services/profileAPI.ts`
  - Implement `getProfile()`, `verifyNIN(nin, dateOfBirth)`, `confirmNIN(data)`, `uploadProfilePicture(file)`, `subscribe(paymentReference)` using `apiClient`
  - _Requirements: 2.1, 3.1, 3.4, 9.1, 4.3_

- [x] 13. Implement `frontend/src/services/groupAdminAPI.ts`
  - Implement `getAdminDashboard(groupId)`, `updateGroup(groupId, data)`, `castVote(groupId, memberId, actionType)`, `getVotes(groupId)`, `getMemberDashboard(groupId)` using `apiClient`
  - _Requirements: 5.1, 5.8, 6.1_

- [x] 14. Implement `frontend/src/components/ProfileDropdown.tsx`
  - Circular avatar button: show `<img>` from `profile_picture_url` if set, else render initials from `user.name`
  - Dropdown items in order: name/email header (non-clickable), Profile, Change Password, Wallet, Messages, Dashboard, Logout
  - Close on outside click (`useEffect` + document listener) and Escape key
  - _Requirements: 1.3, 1.4, 1.5, 1.6, 1.7, 1.8_

- [x] 15. Update `frontend/src/components/Header.tsx`
  - Remove "Welcome, {name}" greeting and standalone Logout button from authenticated desktop and mobile views
  - Replace with `<ProfileDropdown user={user} />` for authenticated users
  - For guest users: show Register button only (remove Login from navbar per requirement 1.2)
  - _Requirements: 1.1, 1.2, 1.3_

- [x] 16. Implement `frontend/src/pages/Profile.tsx`
  - Fetch profile via `profileAPI.getProfile()` with React Query
  - Circular avatar with click-to-upload (file picker restricted to JPEG/PNG/WebP); call `profileAPI.uploadProfilePicture()` on selection
  - NIN-locked read-only fields when `nin_verified = true`; yellow banner with `/verify-nin` link when false; green "Verified ✓" badge when true
  - Editable phone and email fields
  - Read-only Account Info section (role, created_at, referral_code)
  - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 2.8, 2.9, 2.10_

- [x] 17. Implement `frontend/src/pages/VerifyNIN.tsx`
  - Step 1: form collecting 11-digit NIN and date of birth; call `profileAPI.verifyNIN(nin, dob)` on submit
  - Step 2: display returned NIN data for confirmation; call `profileAPI.confirmNIN(data)` on confirm; update auth store `nin_verified = true`
  - _Requirements: 3.1, 3.2, 3.4, 10.12_

- [x] 18. Implement `frontend/src/pages/BecomeAMember.tsx` (6-step wizard)
  - On mount: if `nin_verified = true` redirect to dashboard; if `is_platform_subscriber = true` skip to Step 3
  - Step 1: Paystack payment button; on success call `profileAPI.subscribe(ref)`, advance to Step 2
  - Step 2: Payment Confirmed — auto-advance or "Continue" button
  - Step 3: NIN + DOB form; call `profileAPI.verifyNIN(nin, dob)`, advance to Step 4
  - Step 4: NIN data confirmation; call `profileAPI.confirmNIN(data)`, advance to Step 5
  - Step 5: Record Updated — update auth store (`is_platform_subscriber = true`, `nin_verified = true`), advance to Step 6
  - Step 6: Access Granted — button to navigate to dashboard or `/create-group`
  - Block forward navigation until current step's async operation resolves successfully
  - _Requirements: 10.1, 10.2, 10.3, 10.4, 10.5, 10.6, 10.7, 10.8, 10.9, 10.10_

- [x] 19. Implement `frontend/src/pages/GroupAdminDashboard.tsx`
  - Fetch via `groupAdminAPI.getAdminDashboard(groupId)` with React Query
  - Display group overview, stats, fund balance/NUBAN/recent transactions, current cycle status, pending votes, full member list with status and vote buttons
  - "Initiate Suspend Vote" / "Initiate Expel Vote" buttons call `groupAdminAPI.castVote()`
  - Group edit form (name, description, category, max_members); disable contribution_amount when active cycle
  - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 5.7, 5.8, 5.10, 5.11, 5.12_

- [x] 20. Implement `frontend/src/pages/GroupMemberDashboard.tsx`
  - Fetch via `groupAdminAPI.getMemberDashboard(groupId)` with React Query
  - Display read-only group info, membership details (join date, status, total contributions), current cycle payment status and deadline, fund balance, member names list
  - _Requirements: 6.1, 6.2, 6.3, 6.4, 6.5, 6.6, 6.7_

- [x] 21. Update `frontend/src/pages/Dashboard.tsx`
  - Add "Become a Member" button (links to `/become-a-member`) visible when `!user.is_platform_subscriber || !user.nin_verified`
  - _Requirements: 3.11, 10.11_

- [x] 22. Update `frontend/src/pages/CreateGroup.tsx`
  - Replace the 10-referral eligibility block with a three-condition checklist showing NIN verified, platform subscriber, and ≥ 2 paid invitees (met/not met)
  - Each unmet condition shows a link: `/verify-nin`, `/become-a-member`, `/referrals`
  - Use the new `conditions` shape from `GET /groups/can-create`
  - _Requirements: 4.5, 4.6, 4.7, 10.11_

- [x] 23. Update `frontend/src/pages/Groups.tsx`, `frontend/src/pages/GroupDetail.tsx`, and `frontend/src/pages/Wallet.tsx`
  - Groups.tsx: add "Become a Member" CTA for users where `!is_platform_subscriber || !nin_verified`
  - GroupDetail.tsx: add "Become a Member" CTA for non-members
  - Wallet.tsx: add NIN verification gate — show "Verify your identity to unlock this feature" message and block financial transactions when `nin_verified = false`
  - _Requirements: 3.10, 10.11_

- [x] 24. Update `frontend/src/App.tsx` — add new routes
  - Add protected routes: `/profile` → `<Profile />`, `/verify-nin` → `<VerifyNIN />`, `/become-a-member` → `<BecomeAMember />`, `/groups/:id/admin` → `<GroupAdminDashboard />`, `/groups/:id/member` → `<GroupMemberDashboard />`
  - Import all new page components
  - _Requirements: 2.1, 3.1, 10.1, 5.1, 6.1_

- [x] 25. Checkpoint — frontend complete
  - Ensure all tests pass, ask the user if questions arise.

- [x] 26. Write property-based tests in `backend/src/tests/profile-groups-properties.test.ts`
  - [x] 26.1 Write property test for P1: Avatar display fallback
    - **Property 1: Avatar display fallback**
    - **Validates: Requirements 1.3, 2.2**
    - Use `fc.record({ name: fc.string({ minLength: 1 }), profile_picture_url: fc.option(fc.webUrl()) })`; assert initials rendered when URL null/empty, `<img>` src set when URL present
  - [x] 26.2 Write property test for P4: Upload file validation
    - **Property 4: Upload file validation**
    - **Validates: Requirements 2.5**
    - Use `fc.record({ mimetype: fc.string(), size: fc.integer() })`; assert 400 returned and `profile_picture_url` unchanged for invalid MIME or size > 5 MB
  - [x] 26.3 Write property test for P5: NIN verify does not persist
    - **Property 5: NIN verify non-persistence**
    - **Validates: Requirements 3.2**
    - Use `fc.string({ minLength: 11, maxLength: 11 })`; mock Interswitch; assert `nin_verified` remains false and all `nin_*` fields null after `verifyNIN`
  - [x] 26.4 Write property test for P8: NIN immutability
    - **Property 8: NIN immutability**
    - **Validates: Requirements 3.5, 3.7**
    - Use `fc.record({ nin_number: fc.string({ minLength: 11, maxLength: 11 }) })`; assert `confirmNIN` returns 409 and NIN fields unchanged when `nin_verified = true`
  - [x] 26.5 Write property test for P9: NIN uniqueness invariant
    - **Property 9: NIN uniqueness invariant**
    - **Validates: Requirements 3.6, 8.3**
    - Use `fc.tuple(fc.uuid(), fc.uuid())`; assert second user's `confirmNIN` returns 409 when NIN already taken
  - [x] 26.6 Write property test for P10: NIN verified invariant
    - **Property 10: NIN verified users have valid NIN number**
    - **Validates: Requirements 8.4**
    - Use `fc.array(fc.record({ nin_verified: fc.boolean(), nin_number: fc.option(fc.string()) }))`; assert all records with `nin_verified = true` have `nin_number` of length 11
  - [x] 26.7 Write property test for P11: NIN gate for group operations
    - **Property 11: NIN gate for group operations**
    - **Validates: Requirements 3.8, 3.9**
    - Use `fc.record({ nin_verified: fc.constant(false) })`; assert both create and join group return 403 and no records created
  - [x] 26.8 Write property test for P12: canCreateGroup three-condition gate
    - **Property 12: canCreateGroup three-condition gate**
    - **Validates: Requirements 4.1, 4.2**
    - Use `fc.record({ nin_verified: fc.boolean(), is_platform_subscriber: fc.boolean(), paid_invitees: fc.integer({ min: 0, max: 10 }) })`; assert `canCreate` is true iff all three conditions met; admin always true
  - [x] 26.9 Write property test for P14: Subscription idempotency
    - **Property 14: Subscription idempotency and failure isolation**
    - **Validates: Requirements 4.4**
    - Use `fc.string()`; assert duplicate or invalid reference returns 400 and `is_platform_subscriber` unchanged
  - [x] 26.10 Write property test for P15: Vote threshold triggers action
    - **Property 15: Vote threshold triggers action**
    - **Validates: Requirements 5.9**
    - Use `fc.integer({ min: 1, max: 50 })`; assert member status updated to suspended/expelled exactly when vote count reaches `ceil(2/3 × N)`
  - [x] 26.11 Write property test for P17: Group admin dashboard access control
    - **Property 17: Group admin dashboard access control**
    - **Validates: Requirements 5.1**
    - Use `fc.record({ role: fc.constantFrom('farmer', 'owner', 'member') })`; assert non-owner/non-admin callers receive 403
  - [x] 26.12 Write property test for P18: Group member dashboard access control
    - **Property 18: Group member dashboard access control**
    - **Validates: Requirements 6.1**
    - Use `fc.record({ payment_status: fc.constantFrom('pending', 'failed') })`; assert non-paid-member callers receive 403
  - [x] 26.13 Write property test for P21: Admin management endpoint protection
    - **Property 21: Admin management endpoint protection**
    - **Validates: Requirements 7.6**
    - Use `fc.record({ role: fc.constantFrom('farmer', 'owner') })`; assert non-admin callers receive 403 and no `group_members` records modified
  - [x] 26.14 Write property test for P22: Become a Member wizard step ordering
    - **Property 22: Become a Member wizard step ordering**
    - **Validates: Requirements 10.8, 10.9, 10.10**
    - Use `fc.record({ is_platform_subscriber: fc.boolean(), nin_verified: fc.boolean(), step: fc.integer({ min: 1, max: 6 }) })`; assert wizard step state only advances on successful async completion and redirects correctly based on existing subscription/verification status

- [x] 27. Final checkpoint — Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- Tasks marked with `*` are optional and can be skipped for faster MVP
- Each task references specific requirements for traceability
- Property tests use `numRuns: 100` per property and are tagged `// Feature: platform-profile-and-groups-enhancement, Property N: <text>`
- All backend files use ESM `.js` imports per existing project convention
- The `interswitchService` singleton is reused for NIN API OAuth2 token management
- The existing `s3Client` from `backend/src/config/s3.ts` is used for profile picture uploads
- The existing `paystackService` is used for subscription payment verification
