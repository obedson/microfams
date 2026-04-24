# Requirements Document

## Introduction

This document specifies the requirements for the **Platform Profile and Groups Enhancement** feature on Microfams — an agricultural investment and management platform. The enhancement covers seven areas: navbar redesign with a profile dropdown, a user profile page with picture upload, NIN (National Identification Number) identity verification via Interswitch, a revamped group creation eligibility system, a group admin dashboard, a group member dashboard, and platform admin tools for group admin role management.

These features collectively introduce identity verification as a prerequisite for financial and group activities, replace the existing 10-referral group creation gate with a three-condition eligibility model, and provide richer management interfaces for group administrators and members.

---

## Glossary

- **System**: The Microfams platform (backend API + frontend React application) as a whole.
- **Auth_Service**: The backend authentication and user management service (`authController`, `UserModel`).
- **Profile_Page**: The frontend page at `/profile` where authenticated users view and edit their profile.
- **NIN_Service**: The backend service responsible for calling the Interswitch NIN Verification API and persisting verified identity data.
- **Interswitch_Service**: The existing `interswitchService` singleton that manages OAuth2 token lifecycle and Interswitch API calls.
- **Group_Service**: The backend service and model layer responsible for group creation, membership, and eligibility checks (`GroupModel`).
- **Group_Admin_Dashboard**: The frontend page at `/groups/:id/admin` accessible only to the group creator or platform admin.
- **Group_Member_Dashboard**: The frontend page at `/groups/:id/member` accessible to any paid member of the group.
- **Admin_Dashboard**: The existing platform admin frontend page accessible to users with role `admin`.
- **Navbar**: The `Header` component rendered on every page of the frontend application.
- **Profile_Dropdown**: The dropdown menu that appears when an authenticated user clicks the profile icon in the Navbar.
- **NIN**: National Identification Number — an 11-digit government-issued identifier used for identity verification in Nigeria.
- **NIN_Verified_User**: A user whose `nin_verified` field is `true` in the `users` table.
- **Platform_Subscriber**: A user whose `is_platform_subscriber` field is `true` in the `users` table, indicating they have paid the platform subscription fee.
- **Paid_Invitee**: A user who registered using a specific user's referral code AND whose `is_platform_subscriber` is `true`.
- **S3**: The AWS S3 bucket already configured in `backend/src/config/s3.ts`, used for storing profile pictures.
- **Paystack**: The existing payment processor used for bookings, group entry fees, and platform subscription payments.
- **Vote_Threshold**: The minimum number of affirmative votes required to execute a suspend or expel action, equal to `ceil(2/3 × active_member_count)`.
- **Contribution_Cycle**: A time-bounded period during which group members are expected to make a defined contribution to the group fund.

---

## Requirements

### Requirement 1: Navbar Redesign and Profile Dropdown

**User Story:** As a user, I want a clean navbar with a profile icon dropdown so that I can quickly access key sections of the platform without cluttering the header.

#### Acceptance Criteria

1. THE Navbar SHALL remove the "Welcome, {name}" greeting text and the standalone Logout button from the authenticated desktop and mobile views.
2. WHEN a guest user views the Navbar, THE Navbar SHALL display a Register button and SHALL NOT display a Login button directly in the navbar.
3. WHEN an authenticated user views the Navbar, THE Navbar SHALL display a circular profile icon showing the user's profile picture if one exists, or the user's initials if no profile picture has been uploaded.
4. WHEN an authenticated user clicks the profile icon, THE Profile_Dropdown SHALL open and display the following items in order: a non-clickable header showing the user's name and email, a link to `/profile` labelled "Profile", a link to `/reset-password` labelled "Change Password", a link to `/wallet` labelled "Wallet", a link to `/messages` labelled "Messages", a link to `/dashboard` labelled "Dashboard", and a Logout button.
5. WHEN the Profile_Dropdown is open and the user clicks outside the dropdown area, THE Profile_Dropdown SHALL close.
6. WHEN the Profile_Dropdown is open and the user presses the Escape key, THE Profile_Dropdown SHALL close.
7. WHILE the Profile_Dropdown is open on a mobile viewport, THE Profile_Dropdown SHALL exhibit the same items and close behaviors as on desktop.
8. WHEN an authenticated user clicks the Logout item in the Profile_Dropdown, THE Auth_Service SHALL clear the user's session and THE Navbar SHALL redirect the user to the home page.

---

### Requirement 2: Profile Page

**User Story:** As an authenticated user, I want a dedicated profile page so that I can view my account details, upload a profile picture, and understand my verification status.

#### Acceptance Criteria

1. THE Profile_Page SHALL be accessible only to authenticated users; unauthenticated requests to `/profile` SHALL redirect to the login page.
2. THE Profile_Page SHALL display a circular avatar that shows the user's profile picture if `profile_picture_url` is set, or the user's initials otherwise.
3. WHEN a user clicks the avatar on the Profile_Page, THE Profile_Page SHALL open a file picker restricted to image file types (JPEG, PNG, WebP).
4. WHEN a user selects a valid image file, THE Auth_Service SHALL upload the image to S3 via `POST /api/auth/upload-profile-picture` and SHALL update the `profile_picture_url` field on the user's record.
5. IF the uploaded file exceeds 5 MB or is not an accepted image type, THEN THE Auth_Service SHALL return a 400 error with a descriptive message and SHALL NOT update `profile_picture_url`.
6. THE Profile_Page SHALL display the following NIN-locked fields as read-only when `nin_verified` is `true`: full name (`nin_full_name`), date of birth (`nin_date_of_birth`), gender (`nin_gender`), address (`nin_address`), and NIN number masked to show only the last 4 digits.
7. THE Profile_Page SHALL display the following editable fields: phone number and email address.
8. WHEN `nin_verified` is `false`, THE Profile_Page SHALL display a yellow verification banner with the text "Your profile is not fully verified" and a link to `/verify-nin`.
9. WHEN `nin_verified` is `true`, THE Profile_Page SHALL display a green "Verified ✓" badge in place of the yellow banner.
10. THE Profile_Page SHALL display the user's role, account creation date, and referral code in a read-only Account Info section.

---

### Requirement 3: NIN Verification Flow

**User Story:** As a user, I want to verify my identity using my NIN so that I can unlock group features and financial transactions on the platform.

#### Acceptance Criteria

1. THE NIN_Service SHALL expose `POST /api/auth/verify-nin` which accepts `{ nin: string, date_of_birth: string }` (NIN must be 11 digits, date_of_birth in ISO format), calls the Interswitch NIN Verification API using the token managed by Interswitch_Service with both fields for cross-validation, and returns the NIN-pulled data (full_name, date_of_birth, gender, address, phone) for user confirmation. Requests missing either field SHALL be rejected with a 400 error.
2. WHEN the Interswitch NIN Verification API returns a successful response, THE NIN_Service SHALL return the NIN data to the frontend without persisting it yet.
3. IF the Interswitch NIN Verification API returns an error, THEN THE NIN_Service SHALL return a 422 response containing the error message from Interswitch and SHALL NOT modify any user record.
4. THE NIN_Service SHALL expose `POST /api/auth/confirm-nin` which accepts the confirmed NIN data, saves `nin_number`, `nin_full_name`, `nin_date_of_birth`, `nin_gender`, `nin_address`, `nin_phone` to the `users` table, and sets `nin_verified = true`.
5. WHEN `nin_verified` is already `true` for a user, THE NIN_Service SHALL reject any subsequent call to `POST /api/auth/confirm-nin` for that user with a 409 error.
6. THE System SHALL enforce that `nin_number` is unique across all users; IF a NIN is already associated with another verified account, THEN THE NIN_Service SHALL return a 409 error and SHALL NOT set `nin_verified = true`.
7. WHEN `nin_verified` is `true`, THE Auth_Service SHALL treat `nin_full_name`, `nin_date_of_birth`, `nin_gender`, `nin_address`, and `nin_number` as immutable; any attempt to update these fields via user-facing endpoints SHALL be rejected with a 403 error.
8. WHEN a user attempts to create a group and `nin_verified` is `false`, THE Group_Service SHALL reject the request with a 403 error and a message directing the user to verify their NIN.
9. WHEN a user attempts to join a group and `nin_verified` is `false`, THE Group_Service SHALL reject the request with a 403 error and a message directing the user to verify their NIN.
10. WHEN a user attempts a wallet financial transaction and `nin_verified` is `false`, THE System SHALL display a "Verify your identity to unlock this feature" message and SHALL NOT process the transaction.
11. WHEN an authenticated user with `nin_verified = false` or `is_platform_subscriber = false` views the Dashboard, THE System SHALL display a "Become a Member" button that redirects to `/become-a-member`.
12. THE NIN verification step in the Become a Member wizard SHALL accept both NIN (11 digits) AND date of birth as inputs, and SHALL pass both to the Interswitch NIN Verification API for cross-validation.

---

### Requirement 4: Group Creation Overhaul

**User Story:** As a platform member, I want clear and fair eligibility criteria for creating a group so that group creators are verified, committed platform members.

#### Acceptance Criteria

1. THE Group_Service SHALL update `canCreateGroup()` so that a non-admin user is eligible to create a group if and only if all three of the following conditions are true: `nin_verified = true`, `is_platform_subscriber = true`, and the count of users where `referred_by = user.id AND is_platform_subscriber = true` is greater than or equal to 2.
2. WHEN a user with role `admin` calls `canCreateGroup()`, THE Group_Service SHALL return `true` regardless of NIN or subscription status.
3. THE Auth_Service SHALL expose `POST /api/auth/subscribe` which accepts a Paystack payment reference, verifies the payment via the existing Paystack verification utility, and on success sets `is_platform_subscriber = true`, `subscription_paid_at` to the current timestamp, and `subscription_reference` to the provided reference.
4. IF the Paystack payment reference provided to `POST /api/auth/subscribe` is invalid or already used, THEN THE Auth_Service SHALL return a 400 error and SHALL NOT set `is_platform_subscriber = true`.
5. THE Group_Creation_Page SHALL display an eligibility checklist showing the status (met/not met) of each of the three conditions: NIN verified, platform subscriber, and at least 2 paid invitees.
6. WHEN a condition in the eligibility checklist is not met, THE Group_Creation_Page SHALL display a link to the relevant action: `/verify-nin` for NIN verification, the subscription payment flow for platform subscription, and the referral page for paid invitees.
7. WHEN `canCreateGroup()` returns `false` for a non-admin user, THE Group_Service SHALL reject the group creation request with a 403 error listing which conditions are unmet.
8. THE System SHALL NOT break existing Paystack group entry fee payment flows during the transition to the new eligibility model.

---

### Requirement 5: Group Admin Dashboard

**User Story:** As a group creator or admin, I want a dedicated admin dashboard for my group so that I can manage members, monitor contributions, and oversee group finances.

#### Acceptance Criteria

1. THE Group_Admin_Dashboard SHALL be accessible only to the group creator (role `owner` in `group_members`) or a platform admin; any other authenticated user requesting `/groups/:id/admin` SHALL receive a 403 response.
2. THE Group_Admin_Dashboard SHALL display group overview information: name, description, category, location (state and LGA), member count, and creation date.
3. THE Group_Admin_Dashboard SHALL display group statistics: total members, active members, suspended members, expelled members, and total contributions collected.
4. THE Group_Admin_Dashboard SHALL display the current group fund balance, the group's Virtual NUBAN (from `group_virtual_accounts`), and the 5 most recent group fund transactions.
5. THE Group_Admin_Dashboard SHALL display the current Contribution_Cycle status including: cycle period, collected amount vs expected amount, deadline date, and a list of members who have and have not paid for the current cycle.
6. THE Group_Admin_Dashboard SHALL display all pending group withdrawal requests with their current vote counts.
7. THE Group_Admin_Dashboard SHALL display a full member list with each member's name, `member_status` (active/suspended/expelled), contribution payment status for the current cycle, and join date.
8. WHEN a group admin clicks "Initiate Suspend Vote" or "Initiate Expel Vote" for a member, THE Group_Service SHALL create a vote record in `group_member_action_votes` and SHALL notify all active group members.
9. WHEN the count of affirmative votes in `group_member_action_votes` for a given action reaches the Vote_Threshold, THE Group_Service SHALL automatically execute the action (update `member_status` to `suspended` or `expelled`).
10. THE Group_Admin_Dashboard SHALL provide a form to edit group name, description, category, and `max_members`.
11. WHEN a Contribution_Cycle is active, THE Group_Admin_Dashboard SHALL disable editing of `contribution_amount` and SHALL display a message indicating that contribution amount cannot be changed during an active cycle.
12. THE Group_Admin_Dashboard SHALL display a "Create Contribution Cycle" button that is disabled when an active Contribution_Cycle already exists for the group.

---

### Requirement 6: Group Member Dashboard

**User Story:** As a paid group member, I want a member dashboard for my group so that I can track my contributions, see the group fund balance, and stay informed about upcoming deadlines.

#### Acceptance Criteria

1. THE Group_Member_Dashboard SHALL be accessible only to users who are paid members (`payment_status = 'paid'`) of the group; unauthenticated users or non-members requesting `/groups/:id/member` SHALL receive a 403 response.
2. THE Group_Member_Dashboard SHALL display read-only group information: name, description, category, and location.
3. THE Group_Member_Dashboard SHALL display the authenticated user's membership details: join date, `member_status`, and total contributions made (`total_contributions`).
4. THE Group_Member_Dashboard SHALL display the current Contribution_Cycle details for the authenticated user: the user's payment status for the current cycle, the amount due, the deadline date, and any applicable late penalty.
5. THE Group_Member_Dashboard SHALL display the current group fund balance as a read-only value.
6. THE Group_Member_Dashboard SHALL display a list of member names only, without exposing any financial details of other members.
7. THE Group_Member_Dashboard SHALL display a prominent upcoming deadline section showing the next contribution deadline date.

---

### Requirement 7: Platform Admin — Group Admin Role Management

**User Story:** As a platform admin, I want to manage group admin roles so that I can reassign or remove group admins when necessary.

#### Acceptance Criteria

1. THE Admin_Dashboard SHALL include a "Group Management" section listing all groups with their current admin user's name and email.
2. THE Auth_Service SHALL expose `PUT /api/admin/groups/:groupId/admin` which accepts `{ newAdminUserId: string }`, verifies the target user is a paid member of the group, and updates the `role` field in `group_members` to `owner` for the new admin while setting the previous admin's role to `member`.
3. IF the `newAdminUserId` provided to `PUT /api/admin/groups/:groupId/admin` is not a paid member of the group, THEN THE Auth_Service SHALL return a 400 error and SHALL NOT modify any `group_members` records.
4. THE Auth_Service SHALL expose `DELETE /api/admin/groups/:groupId/admin` which sets the current group admin's role in `group_members` to `member`, leaving the group without a designated admin.
5. WHEN `DELETE /api/admin/groups/:groupId/admin` is called and no admin exists for the group, THE Auth_Service SHALL return a 404 error.
6. Both `PUT /api/admin/groups/:groupId/admin` and `DELETE /api/admin/groups/:groupId/admin` SHALL be protected by the `requireRole(['admin'])` middleware and SHALL return 403 for non-admin callers.

---

### Requirement 8: Database Schema Additions

**User Story:** As a developer, I want the database schema extended with the necessary fields and tables so that all new features have the required data storage.

#### Acceptance Criteria

1. THE System SHALL add the following nullable columns to the `users` table: `nin_number VARCHAR(11) UNIQUE`, `nin_verified BOOLEAN DEFAULT FALSE`, `nin_full_name VARCHAR(255)`, `nin_date_of_birth DATE`, `nin_gender VARCHAR(10)`, `nin_address TEXT`, `nin_phone VARCHAR(20)`, `profile_picture_url TEXT`, `is_platform_subscriber BOOLEAN DEFAULT FALSE`, `subscription_paid_at TIMESTAMPTZ`, `subscription_reference VARCHAR(100)`.
2. THE System SHALL create a `group_member_action_votes` table with columns: `id UUID PRIMARY KEY DEFAULT gen_random_uuid()`, `group_id UUID NOT NULL REFERENCES groups(id)`, `action_type VARCHAR(20) NOT NULL` (values: `suspend`, `expel`), `target_member_id UUID NOT NULL REFERENCES users(id)`, `voter_id UUID NOT NULL REFERENCES users(id)`, `voted_at TIMESTAMPTZ NOT NULL DEFAULT now()`, and a UNIQUE constraint on `(group_id, action_type, target_member_id, voter_id)` to prevent duplicate votes.
3. THE System SHALL enforce a database-level UNIQUE constraint on `users.nin_number` so that no two rows can share the same non-null NIN value.
4. FOR ALL users where `nin_verified = true`, THE System SHALL guarantee that `nin_number` is non-null and exactly 11 characters in length.

---

### Requirement 10: Become a Member Onboarding Wizard

**User Story:** As a non-member user, I want a guided multi-step onboarding flow so that I can pay my membership fee and verify my identity in one seamless journey.

#### Acceptance Criteria

1. THE System SHALL provide a multi-step wizard at `/become-a-member` (protected route, authenticated users only).
2. THE wizard SHALL consist of the following steps in order: (1) Pay Membership Fee, (2) Payment Confirmed, (3) Enter NIN & Date of Birth, (4) NIN Verified, (5) Record Updated, (6) Access Granted.
3. WHEN a user completes Step 1 (Pay Membership Fee) with a valid Paystack payment reference, THE System SHALL call `POST /api/auth/subscribe` and advance to Step 2.
4. WHEN a user completes Step 3 (Enter NIN & Date of Birth) and submits, THE System SHALL call `POST /api/auth/verify-nin` with both `nin` and `date_of_birth`, display the returned NIN data for confirmation, and advance to Step 4.
5. WHEN a user confirms the NIN data in Step 4, THE System SHALL call `POST /api/auth/confirm-nin` and advance to Step 5.
6. WHEN Step 5 (Record Updated) is reached, THE System SHALL update the user's auth store with `is_platform_subscriber = true` and `nin_verified = true`.
7. WHEN Step 6 (Access Granted) is reached, THE System SHALL display a success message and provide a button to navigate to the dashboard or group creation page.
8. THE wizard SHALL prevent navigation to a later step without completing the current step.
9. IF a user who is already `is_platform_subscriber = true` navigates to `/become-a-member`, THE System SHALL skip Step 1 and Step 2 and start at Step 3.
10. IF a user who is already `nin_verified = true` navigates to `/become-a-member`, THE System SHALL redirect them to the dashboard with a message that they are already a verified member.
11. THE "Become a Member" CTA button SHALL appear on: the Dashboard (for non-subscriber or non-verified users), the Groups listing page, the GroupDetail page (for non-members), the CreateGroup eligibility checklist, and the Wallet page (for non-verified users).
12. THE `POST /api/auth/verify-nin` endpoint SHALL require both `nin` (11 digits) AND `date_of_birth` fields, and SHALL pass both to the Interswitch NIN API for cross-validation. Requests missing either field SHALL be rejected with a 400 error.

---

### Requirement 9: Profile Picture Upload

**User Story:** As a user, I want to upload a profile picture so that my avatar is personalised across the platform.

#### Acceptance Criteria

1. THE Auth_Service SHALL expose `POST /api/auth/upload-profile-picture` as a multipart/form-data endpoint protected by `authenticateToken`.
2. WHEN a valid image file (JPEG, PNG, or WebP) of 5 MB or less is uploaded, THE Auth_Service SHALL store the file in the platform's S3 bucket and SHALL update `profile_picture_url` on the user's record with the resulting S3 URL.
3. WHEN `profile_picture_url` is updated, THE Auth_Service SHALL return the new URL in the response so the frontend can update the displayed avatar without a full page reload.
4. FOR ALL successful profile picture uploads, the stored `profile_picture_url` SHALL be a valid HTTPS URL belonging to the platform's configured S3 bucket domain.
5. IF a user uploads a new profile picture when one already exists, THEN THE Auth_Service SHALL overwrite the existing `profile_picture_url` with the new S3 URL.
