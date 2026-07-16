-- Repair existing installations where group credits changed the balance but
-- could not create a wallet_transactions row because wallet_id was mandatory.

ALTER TABLE wallet_transactions ADD COLUMN IF NOT EXISTS group_id UUID REFERENCES groups(id);
ALTER TABLE wallet_transactions ALTER COLUMN wallet_id DROP NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'wallet_transactions_single_ledger_owner'
      AND conrelid = 'wallet_transactions'::regclass
  ) THEN
    ALTER TABLE wallet_transactions
      ADD CONSTRAINT wallet_transactions_single_ledger_owner
      CHECK (num_nonnulls(wallet_id, group_id) = 1);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_wallet_txns_group_id ON wallet_transactions(group_id);

CREATE OR REPLACE FUNCTION atomic_group_credit(
  p_group_id UUID,
  p_amount NUMERIC,
  p_reference VARCHAR
) RETURNS UUID AS $$
DECLARE
  v_tx_id UUID;
BEGIN
  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'Credit amount must be positive';
  END IF;

  UPDATE groups
  SET group_fund_balance = group_fund_balance + p_amount,
      updated_at = NOW()
  WHERE id = p_group_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Group not found';
  END IF;

  INSERT INTO wallet_transactions (
    group_id, source_id, amount, type, direction, status, reference
  ) VALUES (
    p_group_id, p_group_id, p_amount, 'COLLECTION', 'CREDIT', 'SUCCESS', p_reference
  ) RETURNING id INTO v_tx_id;

  RETURN v_tx_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION atomic_group_transfer(
  p_group_id UUID,
  p_recipient_wallet_id UUID,
  p_amount NUMERIC,
  p_reference VARCHAR,
  p_approval_request_id UUID
) RETURNS JSONB AS $$
DECLARE
  v_credit_tx_id UUID;
  v_group_balance NUMERIC;
BEGIN
  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'Transfer amount must be positive';
  END IF;

  SELECT group_fund_balance INTO v_group_balance
  FROM groups WHERE id = p_group_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Group not found';
  END IF;

  IF v_group_balance < p_amount THEN
    RAISE EXCEPTION 'Insufficient group funds: balance is %, requested %', v_group_balance, p_amount;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM group_consensus_requests
    WHERE id = p_approval_request_id
      AND group_id = p_group_id
      AND status = 'APPROVED'
      AND amount = p_amount
  ) THEN
    RAISE EXCEPTION 'Approved consensus request does not match transfer';
  END IF;

  v_credit_tx_id := atomic_wallet_credit(
    p_recipient_wallet_id,
    p_amount,
    'INTERNAL_TRANSFER',
    p_reference,
    jsonb_build_object('source_group_id', p_group_id)
  );

  UPDATE groups
  SET group_fund_balance = group_fund_balance - p_amount,
      updated_at = NOW()
  WHERE id = p_group_id;

  UPDATE group_consensus_requests
  SET status = 'EXECUTED', updated_at = NOW()
  WHERE id = p_approval_request_id;

  RETURN jsonb_build_object(
    'credit_tx_id', v_credit_tx_id,
    'group_id', p_group_id,
    'status', 'EXECUTED'
  );
END;
$$ LANGUAGE plpgsql;

DROP POLICY IF EXISTS "Group members can view group transactions" ON wallet_transactions;
CREATE POLICY "Group members can view group transactions"
ON wallet_transactions FOR SELECT
USING (
  group_id IN (
    SELECT group_id FROM group_members
    WHERE user_id = auth.uid() AND is_active = TRUE
  )
);
