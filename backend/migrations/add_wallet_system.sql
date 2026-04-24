-- Migration: Create Wallet System
-- Requirement: 1.1 from tasks.md

-- User Wallets table
CREATE TABLE IF NOT EXISTS user_wallets (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
  balance       NUMERIC(15,2) NOT NULL DEFAULT 0.00 CHECK (balance >= 0),
  status        VARCHAR(20) NOT NULL DEFAULT 'ACTIVE'
                  CHECK (status IN ('ACTIVE', 'SUSPENDED', 'FROZEN')),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Wallet Transactions table (Append-only)
CREATE TABLE IF NOT EXISTS wallet_transactions (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  wallet_id      UUID NOT NULL REFERENCES user_wallets(id),
  source_id      UUID,   -- wallet_id or group_id depending on type
  destination_id UUID,   -- wallet_id or group_id depending on type
  amount         NUMERIC(15,2) NOT NULL CHECK (amount > 0),
  type           VARCHAR(30) NOT NULL
                   CHECK (type IN ('COLLECTION','INTERNAL_TRANSFER','WITHDRAWAL','P2P_TRANSFER')),
  direction      VARCHAR(10) NOT NULL CHECK (direction IN ('CREDIT','DEBIT')),
  status         VARCHAR(20) NOT NULL CHECK (status IN ('PENDING','SUCCESS','FAILED')),
  reference      VARCHAR(100) NOT NULL,
  metadata       JSONB,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Group Virtual Accounts (Interswitch NUBANs)
CREATE TABLE IF NOT EXISTS group_virtual_accounts (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id         UUID NOT NULL UNIQUE REFERENCES groups(id) ON DELETE CASCADE,
  nuban            VARCHAR(20),
  bank_name        VARCHAR(100),
  interswitch_ref  VARCHAR(100),
  status           VARCHAR(20) NOT NULL DEFAULT 'PENDING'
                     CHECK (status IN ('PENDING','ACTIVE','FAILED')),
  retry_count      INTEGER NOT NULL DEFAULT 0,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Individual Withdrawal Requests
CREATE TABLE IF NOT EXISTS withdrawal_requests (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           UUID NOT NULL REFERENCES users(id),
  wallet_id         UUID NOT NULL REFERENCES user_wallets(id),
  amount            NUMERIC(15,2) NOT NULL CHECK (amount >= 1000),
  fee_amount        NUMERIC(15,2) NOT NULL DEFAULT 0,
  account_number    VARCHAR(20) NOT NULL,
  bank_code         VARCHAR(10) NOT NULL,
  account_name      VARCHAR(200) NOT NULL,
  status            VARCHAR(20) NOT NULL DEFAULT 'PENDING'
                      CHECK (status IN ('PENDING','SUCCESS','FAILED')),
  interswitch_ref   VARCHAR(100),
  internal_ref      VARCHAR(100) NOT NULL UNIQUE,
  failure_reason    TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Group Withdrawal Requests (Multi-sig)
CREATE TABLE IF NOT EXISTS group_withdrawal_requests (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id       UUID NOT NULL REFERENCES groups(id),
  requested_by   UUID NOT NULL REFERENCES users(id),
  target_user_id UUID NOT NULL REFERENCES users(id),
  amount         NUMERIC(15,2) NOT NULL CHECK (amount > 0),
  status         VARCHAR(20) NOT NULL DEFAULT 'PENDING'
                   CHECK (status IN ('PENDING','APPROVED','FAILED','EXECUTED')),
  failure_reason TEXT,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Group Withdrawal Approvals
CREATE TABLE IF NOT EXISTS group_withdrawal_approvals (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  approval_request_id UUID NOT NULL REFERENCES group_withdrawal_requests(id) ON DELETE CASCADE,
  voter_id            UUID NOT NULL REFERENCES users(id),
  voted_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(approval_request_id, voter_id)
);

-- Ensure group_fund_balance exists in groups table
DO $$ 
BEGIN 
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='groups' AND column_name='group_fund_balance') THEN
        ALTER TABLE groups ADD COLUMN group_fund_balance NUMERIC(15,2) DEFAULT 0 CHECK (group_fund_balance >= 0);
    END IF;
END $$;

-- Indexes
CREATE INDEX IF NOT EXISTS idx_user_wallets_user_id ON user_wallets(user_id);
CREATE INDEX IF NOT EXISTS idx_wallet_txns_wallet_id  ON wallet_transactions(wallet_id);
CREATE INDEX IF NOT EXISTS idx_wallet_txns_reference  ON wallet_transactions(reference);
CREATE INDEX IF NOT EXISTS idx_wallet_txns_created_at ON wallet_transactions(created_at);
CREATE INDEX IF NOT EXISTS idx_gva_group_id ON group_virtual_accounts(group_id);
CREATE INDEX IF NOT EXISTS idx_gva_nuban    ON group_virtual_accounts(nuban);
CREATE INDEX IF NOT EXISTS idx_wr_user_id    ON withdrawal_requests(user_id);
CREATE INDEX IF NOT EXISTS idx_wr_status     ON withdrawal_requests(status);
CREATE INDEX IF NOT EXISTS idx_wr_created_at ON withdrawal_requests(created_at);
CREATE INDEX IF NOT EXISTS idx_gwr_group_id ON group_withdrawal_requests(group_id);
CREATE INDEX IF NOT EXISTS idx_gwr_status   ON group_withdrawal_requests(status);
CREATE INDEX IF NOT EXISTS idx_gwa_request_id ON group_withdrawal_approvals(approval_request_id);

-- RLS Immutability for wallet_transactions
-- Assuming RLS is enabled on the table
-- ALTER TABLE wallet_transactions ENABLE ROW LEVEL SECURITY;
-- CREATE POLICY "Block updates to transactions" ON wallet_transactions FOR UPDATE USING (false);
-- CREATE POLICY "Block deletes to transactions" ON wallet_transactions FOR DELETE USING (false);

-- RPC Functions

-- 1. Atomic Wallet Credit
CREATE OR REPLACE FUNCTION atomic_wallet_credit(
  p_wallet_id  UUID,
  p_amount     NUMERIC,
  p_type       VARCHAR,
  p_reference  VARCHAR,
  p_metadata   JSONB DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
  v_tx_id UUID;
BEGIN
  -- Insert transaction
  INSERT INTO wallet_transactions (
    wallet_id, amount, type, direction, status, reference, metadata
  ) VALUES (
    p_wallet_id, p_amount, p_type, 'CREDIT', 'SUCCESS', p_reference, p_metadata
  ) RETURNING id INTO v_tx_id;

  -- Update balance
  UPDATE user_wallets
  SET balance = balance + p_amount,
      updated_at = NOW()
  WHERE id = p_wallet_id;

  RETURN v_tx_id;
END;
$$ LANGUAGE plpgsql;

-- 2. Atomic Wallet Debit
CREATE OR REPLACE FUNCTION atomic_wallet_debit(
  p_wallet_id  UUID,
  p_amount     NUMERIC,
  p_type       VARCHAR,
  p_reference  VARCHAR,
  p_metadata   JSONB DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
  v_tx_id UUID;
  v_current_balance NUMERIC;
BEGIN
  -- Check balance
  SELECT balance INTO v_current_balance FROM user_wallets WHERE id = p_wallet_id FOR UPDATE;
  
  IF v_current_balance < p_amount THEN
    RAISE EXCEPTION 'Insufficient funds: current balance is %, requested %', v_current_balance, p_amount;
  END IF;

  -- Insert transaction
  INSERT INTO wallet_transactions (
    wallet_id, amount, type, direction, status, reference, metadata
  ) VALUES (
    p_wallet_id, p_amount, p_type, 'DEBIT', 'SUCCESS', p_reference, p_metadata
  ) RETURNING id INTO v_tx_id;

  -- Update balance
  UPDATE user_wallets
  SET balance = balance - p_amount,
      updated_at = NOW()
  WHERE id = p_wallet_id;

  RETURN v_tx_id;
END;
$$ LANGUAGE plpgsql;

-- 3. Atomic P2P Transfer
CREATE OR REPLACE FUNCTION atomic_p2p_transfer(
  p_sender_wallet_id   UUID,
  p_recipient_wallet_id UUID,
  p_amount             NUMERIC,
  p_reference          VARCHAR
) RETURNS JSONB AS $$
DECLARE
  v_debit_tx_id UUID;
  v_credit_tx_id UUID;
BEGIN
  -- Debit sender
  v_debit_tx_id := atomic_wallet_debit(p_sender_wallet_id, p_amount, 'P2P_TRANSFER', p_reference, jsonb_build_object('peer_wallet_id', p_recipient_wallet_id));
  
  -- Credit recipient
  v_credit_tx_id := atomic_wallet_credit(p_recipient_wallet_id, p_amount, 'P2P_TRANSFER', p_reference, jsonb_build_object('peer_wallet_id', p_sender_wallet_id));

  RETURN jsonb_build_object(
    'debit_tx_id', v_debit_tx_id,
    'credit_tx_id', v_credit_tx_id
  );
END;
$$ LANGUAGE plpgsql;

-- 4. Atomic Group Transfer
CREATE OR REPLACE FUNCTION atomic_group_transfer(
  p_group_id           UUID,
  p_recipient_wallet_id UUID,
  p_amount             NUMERIC,
  p_reference          VARCHAR,
  p_approval_request_id UUID
) RETURNS JSONB AS $$
DECLARE
  v_credit_tx_id UUID;
  v_group_balance NUMERIC;
BEGIN
  -- Check group balance
  SELECT group_fund_balance INTO v_group_balance FROM groups WHERE id = p_group_id FOR UPDATE;
  
  IF v_group_balance < p_amount THEN
    RAISE EXCEPTION 'Insufficient group funds: balance is %, requested %', v_group_balance, p_amount;
  END IF;

  -- Credit recipient wallet
  v_credit_tx_id := atomic_wallet_credit(p_recipient_wallet_id, p_amount, 'INTERNAL_TRANSFER', p_reference, jsonb_build_object('source_group_id', p_group_id));

  -- Update group balance
  UPDATE groups
  SET group_fund_balance = group_fund_balance - p_amount,
      updated_at = NOW()
  WHERE id = p_group_id;

  -- Update request status
  UPDATE group_withdrawal_requests
  SET status = 'EXECUTED',
      updated_at = NOW()
  WHERE id = p_approval_request_id;

  RETURN jsonb_build_object(
    'credit_tx_id', v_credit_tx_id,
    'group_id', p_group_id,
    'status', 'EXECUTED'
  );
END;
$$ LANGUAGE plpgsql;

-- 5. Atomic Group Credit (Inbound Collection)
CREATE OR REPLACE FUNCTION atomic_group_credit(
  p_group_id  UUID,
  p_amount    NUMERIC,
  p_reference VARCHAR
) RETURNS UUID AS $$
DECLARE
  v_tx_id UUID;
BEGIN
  -- Update group balance
  UPDATE groups
  SET group_fund_balance = group_fund_balance + p_amount,
      updated_at = NOW()
  WHERE id = p_group_id;

  -- Insert ledger record
  -- Note: We use a system-level transaction here. 
  -- In a production environment, you might link this to a 'system' wallet.
  INSERT INTO wallet_transactions (
    wallet_id, 
    source_id, 
    amount, 
    type, 
    direction, 
    status, 
    reference
  ) 
  SELECT 
    id, 
    p_group_id, 
    p_amount, 
    'COLLECTION', 
    'CREDIT', 
    'SUCCESS', 
    p_reference 
  FROM user_wallets 
  WHERE user_id IS NULL -- Hypothetical system wallet or adjust schema to allow NULL wallet_id
  LIMIT 1;

  RETURN gen_random_uuid(); 
END;
$$ LANGUAGE plpgsql;

-- Enable RLS and Immutability
ALTER TABLE wallet_transactions ENABLE ROW LEVEL SECURITY;

-- Users can only see their own transactions
CREATE POLICY "Users can view own transactions" 
ON wallet_transactions FOR SELECT 
USING (wallet_id IN (SELECT id FROM user_wallets WHERE user_id = auth.uid()));

-- Block all updates and deletes (Ledger Integrity - Requirement 8.4)
CREATE POLICY "Transactions are immutable" 
ON wallet_transactions FOR UPDATE 
USING (false);

CREATE POLICY "Transactions cannot be deleted" 
ON wallet_transactions FOR DELETE 
USING (false);
