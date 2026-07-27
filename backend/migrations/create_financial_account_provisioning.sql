-- FC-02 canonical tenant account purposes and controlled provisioning.
CREATE TABLE financial_account_purpose_rules (
  purpose TEXT PRIMARY KEY,
  account_class TEXT NOT NULL CHECK (account_class IN ('asset','liability','equity','revenue','expense')),
  normal_side TEXT NOT NULL CHECK (normal_side IN ('debit','credit')),
  allowed_owner_types TEXT[] NOT NULL,
  is_control BOOLEAN NOT NULL
);
INSERT INTO financial_account_purpose_rules VALUES
('operating_cash','asset','debit',ARRAY['organization','system'],TRUE),
('provider_clearing','asset','debit',ARRAY['provider'],TRUE),
('settlement_receivable','asset','debit',ARRAY['provider','system'],TRUE),
('loan_principal_receivable','asset','debit',ARRAY['loan_contract'],TRUE),
('individual_wallet_funds','liability','credit',ARRAY['user'],TRUE),
('group_wallet_funds','liability','credit',ARRAY['group'],TRUE),
('pending_payout','liability','credit',ARRAY['user','group','system'],TRUE),
('escrow_funds_held','liability','credit',ARRAY['escrow_contract'],TRUE),
('savings_principal','liability','credit',ARRAY['savings_contract'],TRUE),
('savings_accrued_return','liability','credit',ARRAY['savings_contract'],TRUE),
('investor_subscriptions_payable','liability','credit',ARRAY['investment_contract'],TRUE),
('investor_redemptions_payable','liability','credit',ARRAY['investment_contract'],TRUE),
('dividends_payable','liability','credit',ARRAY['organization','group','system'],TRUE),
('platform_fee_revenue','revenue','credit',ARRAY['organization','system'],FALSE),
('provider_processing_fee','expense','debit',ARRAY['provider','system'],FALSE),
('credit_loss_writeoff','expense','debit',ARRAY['organization','system'],FALSE),
('opening_balance_equity','equity','credit',ARRAY['organization'],TRUE),
('retained_surplus','equity','credit',ARRAY['organization'],TRUE);

ALTER TABLE financial_accounts
  ADD COLUMN purpose TEXT REFERENCES financial_account_purpose_rules(purpose),
  ADD COLUMN effective_from DATE NOT NULL DEFAULT CURRENT_DATE,
  ADD COLUMN effective_until DATE,
  ADD COLUMN provisioning_key TEXT,
  ADD COLUMN provisioning_hash VARCHAR(64),
  ADD CONSTRAINT financial_account_effective_dates CHECK (effective_until IS NULL OR effective_until >= effective_from),
  ADD CONSTRAINT financial_account_provisioning_evidence CHECK (
    (provisioning_key IS NULL AND provisioning_hash IS NULL)
    OR (length(provisioning_key) BETWEEN 8 AND 160 AND provisioning_hash ~ '^[a-f0-9]{64}$')
  );
CREATE UNIQUE INDEX uq_financial_account_provisioning_key
  ON financial_accounts(organization_id,provisioning_key) WHERE provisioning_key IS NOT NULL;
CREATE UNIQUE INDEX uq_active_financial_account_purpose
  ON financial_accounts(organization_id,purpose,owner_type,COALESCE(owner_id,'00000000-0000-0000-0000-000000000000'::UUID),currency)
  WHERE purpose IS NOT NULL AND effective_until IS NULL;

UPDATE organization_memberships SET permissions=ARRAY(
  SELECT DISTINCT p FROM unnest(permissions||ARRAY['financial.accounts.manage']) p
) WHERE role='owner';

CREATE OR REPLACE FUNCTION provision_financial_account(
  p_organization UUID,p_actor UUID,p_code TEXT,p_name TEXT,p_purpose TEXT,p_currency TEXT,
  p_owner_type TEXT,p_owner_id UUID,p_effective_from DATE,p_key TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE rule financial_account_purpose_rules; old financial_accounts; account financial_accounts; h TEXT; currency TEXT:=upper(p_currency);
BEGIN
 IF NOT has_financial_permission(p_organization,p_actor,'financial.accounts.manage') THEN RAISE EXCEPTION 'Missing financial.accounts.manage permission'; END IF;
 SELECT * INTO rule FROM financial_account_purpose_rules WHERE purpose=p_purpose;
 IF rule.purpose IS NULL THEN RAISE EXCEPTION 'Financial account purpose is invalid'; END IF;
 IF NOT p_owner_type=ANY(rule.allowed_owner_types) THEN RAISE EXCEPTION 'Owner type is not allowed for this account purpose'; END IF;
 IF (p_owner_type IN ('organization','system') AND p_owner_id IS NOT NULL) OR (p_owner_type NOT IN ('organization','system') AND p_owner_id IS NULL) THEN RAISE EXCEPTION 'Account owner identity is invalid'; END IF;
 IF p_code IS NULL OR p_code !~ '^[A-Z0-9][A-Z0-9._-]{1,39}$' THEN RAISE EXCEPTION 'Financial account code is invalid'; END IF;
 IF p_name IS NULL OR length(btrim(p_name)) NOT BETWEEN 2 AND 160 THEN RAISE EXCEPTION 'Financial account name is invalid'; END IF;
 IF currency IS NULL OR currency !~ '^[A-Z]{3}$' THEN RAISE EXCEPTION 'Currency must be a three-letter ISO code'; END IF;
 IF p_effective_from IS NULL THEN RAISE EXCEPTION 'Effective date is required'; END IF;
 IF p_key IS NULL OR length(p_key) NOT BETWEEN 8 AND 160 THEN RAISE EXCEPTION 'Provisioning idempotency key is invalid'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',p_organization::TEXT,p_actor::TEXT,p_code,btrim(p_name),p_purpose,currency,p_owner_type,COALESCE(p_owner_id::TEXT,''),p_effective_from::TEXT),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':account-provision:'||p_key,0));
 SELECT * INTO old FROM financial_accounts WHERE organization_id=p_organization AND provisioning_key=p_key;
 IF old.id IS NOT NULL THEN IF old.provisioning_hash<>h THEN RAISE EXCEPTION 'Provisioning key reused with different account facts'; END IF; RETURN to_jsonb(old); END IF;
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,owner_id,is_control,created_by,purpose,effective_from,provisioning_key,provisioning_hash)
 VALUES(p_organization,p_code,btrim(p_name),rule.account_class,rule.normal_side,currency,p_owner_type,p_owner_id,rule.is_control,p_actor,p_purpose,p_effective_from,p_key,h)
 RETURNING * INTO account;
 INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value)
 VALUES(p_organization,p_actor,'FINANCIAL_ACCOUNT_PROVISIONED','financial_account',account.id::TEXT,
 jsonb_build_object('purpose',account.purpose,'code',account.code,'currency',account.currency,'owner_type',account.owner_type,'owner_id',account.owner_id,'effective_from',account.effective_from));
 RETURN to_jsonb(account);
END $$;

REVOKE ALL ON financial_account_purpose_rules FROM anon,authenticated;
GRANT SELECT ON financial_account_purpose_rules TO service_role;
REVOKE INSERT,UPDATE,DELETE ON financial_account_purpose_rules FROM service_role;
REVOKE INSERT,UPDATE,DELETE ON financial_accounts FROM service_role;
REVOKE ALL ON FUNCTION provision_financial_account(UUID,UUID,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,DATE,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION provision_financial_account(UUID,UUID,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,DATE,TEXT) TO service_role;
DO $$ BEGIN
 IF has_table_privilege('service_role','financial_accounts','INSERT') OR has_table_privilege('service_role','financial_accounts','UPDATE') OR has_table_privilege('service_role','financial_accounts','DELETE') THEN RAISE EXCEPTION 'service_role can directly mutate financial accounts'; END IF;
END $$;
