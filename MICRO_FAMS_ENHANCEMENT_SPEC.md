# Enhancement Specification: Micro Fams Reputation & Lending-Ready Ecosystem

## 1. Executive Summary
The **Micro Fams** platform is evolving from a rental marketplace into a **data-driven financial gateway**. By implementing the **Agro Career Credit Score (ACCS)**, the platform will quantify farmer competence, reliability, and engagement. This score serves as the primary underwriting metric for **Micro Fams Grants**, **Partner Grants**, and **Interest-Free/Single-Digit Micro-Lending**.

---

## 2. The Agro Career Credit Score (ACCS) Engine
The ACCS is a dynamic, weighted algorithm that aggregates data from across the ecosystem.

### A. Core Weighting Logic
| Action Category | Weight | Logic |
| :--- | :--- | :--- |
| **Financial Reliability** | High (40%) | Timely bookings, group contributions, and marketplace purchases. |
| **Technical Competence** | High (30%) | Course completions (internal/external) and Daily Quiz scores. |
| **Network Growth** | Medium (20%) | Successful referral of paid members and group leadership. |
| **Platform Engagement** | Low (10%) | Watching videos, social media sharing, and task completion. |

### B. The "Lending-Ready" Audit Trail
To ensure the score is acceptable to banking partners, every point change will be recorded in an **immutable `credit_score_ledger`**.
*   **Fields:** `user_id`, `action_type`, `points_delta`, `previous_score`, `new_score`, `metadata` (e.g., `quiz_id` or `booking_id`), `timestamp`.

---

## 3. Subscription & Group Gating Logic
We are introducing a **Premium Membership Layer** to increase platform commitment and revenue.

### A. Revised Group Creation Workflow
The `POST /api/groups` endpoint will now be protected by a **Validation Pipeline**:
1.  **Paid Membership Check:** Verify the user has an active `pro` status.
2.  **Creation Fee Verification:** Verify a one-time `group_creation_fee` transaction linked to the user.
3.  **Referral Validation:** Query the `referrals` table to ensure at least **one (1)** referred user has upgraded to a paid membership.

### B. Group-Based Tasks
Groups can now be assigned "Shared Tasks" (e.g., "Complete a group-wide safety module").
*   **Social Collateral:** If the task is completed by all members, everyone receives a **1.5x ACCS multiplier**. If one fails, the bonus is void, encouraging peer-to-peer accountability.

---

## 4. Task & Quiz Engine
### A. Daily Quiz Functionality
*   **The "Daily Streak":** Farmers receive a daily notification for a 5-question technical quiz.
*   **Scoring:** Points are awarded for **Accuracy** + **Consistency** (Streaks).
*   **Admin Tools:** A new Admin Interface to upload quiz banks categorized by livestock type (e.g., Poultry, Fishery).

### B. External Course Embedding
*   **Integration:** Use of **Deep-Link Proxying**. Micro Fams generates a unique URL for the external platform (e.g., Coursera, FAO Training).
*   **Verification:** Users submit a **"Proof of Completion"** (Certificate upload). Admin approval triggers the ACCS boost.

### C. Engagement Tasks
*   **Video Tasks:** Tracking `watch_time` via the frontend (using YouTube/Vimeo API callbacks) to ensure the video was actually viewed.
*   **Social Sharing:** Integration with the **Web Share API**. The system tracks the "intent to share" and validates back-links where possible.

---

## 5. Technical Implementation (Non-Breaking)

### A. Database Schema Additions
```sql
-- Track Paid Memberships
CREATE TABLE IF NOT EXISTS user_subscriptions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id),
    plan_type VARCHAR(20) DEFAULT 'pro',
    status VARCHAR(20) DEFAULT 'active',
    starts_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    expires_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- The Credit Score Ledger (Bank-Grade Auditing)
CREATE TABLE IF NOT EXISTS credit_score_ledger (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id),
    action_type VARCHAR(50) NOT NULL,
    points_delta INTEGER NOT NULL,
    metadata JSONB,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Daily Quizzes & Tasks
CREATE TABLE IF NOT EXISTS daily_quizzes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title TEXT,
    questions JSONB NOT NULL, -- Array of Q&A
    target_date DATE UNIQUE,
    livestock_category VARCHAR(50)
);
```

### B. Backend Architecture (Event-Driven)
We will implement a **`ScoreListener`**. 
*   Existing services (Booking, Payment, Courses) will remain untouched but will emit an event upon completion.
*   The `ScoreListener` will catch these events and update the `credit_score_ledger` and the `users.total_accs` field asynchronously. This prevents any latency in the core booking/payment flow.

---

## 6. Strategic Road Map (Phase 1)
1.  **Identity Update:** Global find-and-replace to update all UI/API references from "Farmle" to **"Micro Fams"**.
2.  **Membership Gate:** Deploy the `requirePaidMembership` middleware to the Group Creation routes.
3.  **ACCS V1:** Launch the Credit Ledger and begin tracking points for existing Bookings and Purchases (Backdated).
4.  **Quiz Launch:** Deploy the Daily Quiz engine to start building the "Technical Competence" data points.
