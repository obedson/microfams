-- =============================================================================
-- MICRO FAMS REPUTATION & LENDING-READY ECOSYSTEM
-- =============================================================================
-- This migration implements the Agro Career Credit Score (ACCS), 
-- Group Wallets, and the Data Pipeline for Partner Lending.

-- =============================================================================
-- 1. EXTEND CORE TABLES (Users & Groups)
-- =============================================================================

-- Add Reputation & KYC fields to Users
ALTER TABLE users ADD COLUMN IF NOT EXISTS total_accs INTEGER DEFAULT 0;
ALTER TABLE users ADD COLUMN IF NOT EXISTS kyc_status VARCHAR(20) DEFAULT 'pending'; -- pending, verified, rejected
ALTER TABLE users ADD COLUMN IF NOT EXISTS is_pro_member BOOLEAN DEFAULT false;
ALTER TABLE users ADD COLUMN IF NOT EXISTS leader_guarantor_agreement BOOLEAN DEFAULT false;

-- Add Financial & Gating fields to Groups
ALTER TABLE groups ADD COLUMN IF NOT EXISTS group_rank VARCHAR(20) DEFAULT 'bronze';
ALTER TABLE groups ADD COLUMN IF NOT EXISTS entry_fee DECIMAL(12,2) DEFAULT 0;
ALTER TABLE groups ADD COLUMN IF NOT EXISTS status VARCHAR(20) DEFAULT 'pending_activation'; -- pending_activation, active, suspended
ALTER TABLE groups ADD COLUMN IF NOT EXISTS project_duration_days INTEGER DEFAULT 180; -- 6 months default
ALTER TABLE groups ADD COLUMN IF NOT EXISTS expires_at TIMESTAMP WITH TIME ZONE;

-- =============================================================================
-- 2. REPUTATION & CREDIT ENGINE (ACCS)
-- =============================================================================

-- The Credit Score Ledger (Immutable Audit Trail)
CREATE TABLE IF NOT EXISTS credit_score_ledger (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    action_type VARCHAR(50) NOT NULL, -- e.g., 'QUIZ_COMPLETED', 'LOAN_REPAYMENT', 'BOOKING_COMPLETED'
    points_delta INTEGER NOT NULL,
    previous_score INTEGER NOT NULL,
    new_score INTEGER NOT NULL,
    metadata JSONB, -- stores IDs like quiz_id, loan_id
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Daily Quizzes
CREATE TABLE IF NOT EXISTS daily_quizzes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title TEXT NOT NULL,
    questions JSONB NOT NULL, -- Array of Q&A
    target_date DATE UNIQUE,
    difficulty_multiplier DECIMAL(3,2) DEFAULT 1.0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Quiz Attempts with Anti-Gaming
CREATE TABLE IF NOT EXISTS user_quiz_attempts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    quiz_id UUID REFERENCES daily_quizzes(id) ON DELETE CASCADE,
    score_percentage INTEGER NOT NULL,
    time_spent_seconds INTEGER NOT NULL,
    is_validated BOOLEAN DEFAULT true, -- set to false if time_spent is suspiciously low
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(user_id, quiz_id)
);

-- =============================================================================
-- 3. GROUP WALLETS & FINANCIALS
-- =============================================================================

-- Group Wallets (For shared inputs and group rank advancement)
CREATE TABLE IF NOT EXISTS group_wallets (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id UUID REFERENCES groups(id) ON DELETE CASCADE UNIQUE,
    balance DECIMAL(15,2) DEFAULT 0,
    admin_fee_collected DECIMAL(15,2) DEFAULT 0,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Wallet Transactions
CREATE TABLE IF NOT EXISTS group_wallet_transactions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    wallet_id UUID REFERENCES group_wallets(id),
    user_id UUID REFERENCES users(id),
    amount DECIMAL(15,2) NOT NULL,
    transaction_type VARCHAR(50) NOT NULL, -- 'ENTRY_FEE', 'CONTRIBUTION', 'INPUT_PURCHASE', 'BOOKING'
    status VARCHAR(20) DEFAULT 'completed',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- =============================================================================
-- 4. LENDING & REPAYMENT SYSTEM (Data Pipeline)
-- =============================================================================

-- Loan Tracking (Data shared with partner banks)
CREATE TABLE IF NOT EXISTS loans (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id),
    group_id UUID REFERENCES groups(id),
    partner_name VARCHAR(100),
    principal_amount DECIMAL(15,2) NOT NULL,
    interest_rate DECIMAL(5,2) NOT NULL,
    total_repayable DECIMAL(15,2) NOT NULL,
    balance_remaining DECIMAL(15,2) NOT NULL,
    due_date TIMESTAMP WITH TIME ZONE NOT NULL,
    status VARCHAR(20) DEFAULT 'active', -- active, repaid, defaulted, grace_period
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Repayment Records (The Repay Loan Button Flow)
CREATE TABLE IF NOT EXISTS loan_repayments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    loan_id UUID REFERENCES loans(id),
    amount_paid DECIMAL(15,2) NOT NULL,
    payment_reference VARCHAR(100), -- Paystack/Bank Ref
    payment_method VARCHAR(50),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- =============================================================================
-- 5. AUTOMATION & TRIGGERS (The "Sidecar" Engine)
-- =============================================================================

-- Function to update User Total ACCS
CREATE OR REPLACE FUNCTION update_user_accs()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE users 
    SET total_accs = NEW.new_score
    WHERE id = NEW.user_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger: Whenever the ledger is updated, update the user's main score
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'tr_update_user_accs') THEN
        CREATE TRIGGER tr_update_user_accs
        AFTER INSERT ON credit_score_ledger
        FOR EACH ROW
        EXECUTE FUNCTION update_user_accs();
    END IF;
END $$;

-- Function to initialize Group Wallet on Group Creation
CREATE OR REPLACE FUNCTION initialize_group_wallet()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO group_wallets (group_id) 
    VALUES (NEW.id)
    ON CONFLICT (group_id) DO NOTHING;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger: Initialize wallet on group creation
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'tr_init_group_wallet') THEN
        CREATE TRIGGER tr_init_group_wallet
        AFTER INSERT ON groups
        FOR EACH ROW
        EXECUTE FUNCTION initialize_group_wallet();
    END IF;
END $$;

-- =============================================================================
-- 6. VIEWS FOR ADMIN DASHBOARD
-- =============================================================================

-- View to see "Lending Ready" Farmers
CREATE OR REPLACE VIEW lending_readiness_report AS
SELECT 
    u.id as user_id,
    u.name,
    u.total_accs,
    u.kyc_status,
    u.is_pro_member,
    CASE 
        WHEN u.total_accs >= 800 THEN 'Platinum (Interest-Free Ready)'
        WHEN u.total_accs >= 600 THEN 'Gold (Single-Digit Ready)'
        WHEN u.total_accs >= 400 THEN 'Silver (Micro-Grant Ready)'
        ELSE 'Bronze'
    END as lending_tier,
    ROUND((u.total_accs::decimal / 1000) * 100, 2) as readiness_percentage
FROM users u;
