-- AC-01 reproducible, journal-derived organization trial balance.
SET search_path=public,extensions;

CREATE OR REPLACE FUNCTION read_accounting_trial_balance(
 p_organization UUID,p_actor UUID,p_currency TEXT,p_from DATE,p_to DATE,p_cutoff TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE period accounting_periods; accounts JSONB; cur TEXT:=upper(p_currency);
 total_period_debit BIGINT; total_period_credit BIGINT; total_closing_debit BIGINT; total_closing_credit BIGINT;
BEGIN
 IF NOT has_financial_permission(p_organization,p_actor,'financial.accounting.read') THEN
  RAISE EXCEPTION 'ACCOUNTING_TRIAL_BALANCE_PERMISSION_DENIED';
 END IF;
 IF cur IS NULL OR cur!~'^[A-Z]{3}$' OR p_from IS NULL OR p_to IS NULL OR p_from>p_to
  OR p_cutoff IS NULL OR p_cutoff>clock_timestamp() THEN
  RAISE EXCEPTION 'ACCOUNTING_TRIAL_BALANCE_REQUEST_INVALID';
 END IF;
 SELECT * INTO period FROM accounting_periods
  WHERE organization_id=p_organization AND p_from>=starts_on AND p_to<=ends_on
  ORDER BY starts_on DESC LIMIT 1;
 IF period.id IS NULL THEN RAISE EXCEPTION 'ACCOUNTING_TRIAL_BALANCE_PERIOD_REQUIRED'; END IF;

 WITH movements AS (
  SELECT account.id,account.code,account.name,account.account_class,account.normal_side,account.owner_type,account.owner_id,account.is_control,account.status,
   COALESCE(sum(line.amount_minor) FILTER(WHERE entry.effective_date<p_from AND line.side='debit'),0)::BIGINT opening_debit,
   COALESCE(sum(line.amount_minor) FILTER(WHERE entry.effective_date<p_from AND line.side='credit'),0)::BIGINT opening_credit,
   COALESCE(sum(line.amount_minor) FILTER(WHERE entry.effective_date BETWEEN p_from AND p_to AND line.side='debit'),0)::BIGINT period_debit,
   COALESCE(sum(line.amount_minor) FILTER(WHERE entry.effective_date BETWEEN p_from AND p_to AND line.side='credit'),0)::BIGINT period_credit
  FROM financial_accounts account
  LEFT JOIN journal_lines line ON line.account_id=account.id AND line.organization_id=p_organization AND line.currency=cur
  LEFT JOIN journal_entries entry ON entry.id=line.journal_entry_id AND entry.organization_id=p_organization
   AND entry.currency=cur AND entry.effective_date<=p_to AND entry.posted_at<=p_cutoff
  WHERE account.organization_id=p_organization AND account.currency=cur AND account.created_at<=p_cutoff
  GROUP BY account.id
 ), balances AS (
  SELECT *,GREATEST(opening_debit-opening_credit,0) opening_balance_debit,
   GREATEST(opening_credit-opening_debit,0) opening_balance_credit,
   GREATEST(opening_debit+period_debit-opening_credit-period_credit,0) closing_debit,
   GREATEST(opening_credit+period_credit-opening_debit-period_debit,0) closing_credit
  FROM movements
 )
 SELECT COALESCE(jsonb_agg(jsonb_build_object(
   'accountId',id,'code',code,'name',name,'accountClass',account_class,'normalSide',normal_side,
   'ownerType',owner_type,'ownerId',owner_id,'isControl',is_control,'status',status,
   'openingDebitMinor',opening_balance_debit::TEXT,'openingCreditMinor',opening_balance_credit::TEXT,
   'periodDebitMinor',period_debit::TEXT,'periodCreditMinor',period_credit::TEXT,
   'closingDebitMinor',closing_debit::TEXT,'closingCreditMinor',closing_credit::TEXT
  ) ORDER BY CASE account_class WHEN 'asset' THEN 1 WHEN 'liability' THEN 2 WHEN 'equity' THEN 3 WHEN 'revenue' THEN 4 ELSE 5 END,code),'[]'::JSONB),
  COALESCE(sum(period_debit),0)::BIGINT,COALESCE(sum(period_credit),0)::BIGINT,
  COALESCE(sum(closing_debit),0)::BIGINT,COALESCE(sum(closing_credit),0)::BIGINT
 INTO accounts,total_period_debit,total_period_credit,total_closing_debit,total_closing_credit FROM balances;
 IF total_period_debit<>total_period_credit OR total_closing_debit<>total_closing_credit THEN
  RAISE EXCEPTION 'ACCOUNTING_TRIAL_BALANCE_UNBALANCED';
 END IF;
 RETURN jsonb_build_object(
  'organizationId',p_organization,'currency',cur,'from',p_from,'to',p_to,'cutoff',p_cutoff,
  'period',jsonb_build_object('id',period.id,'name',period.name,'status',period.status,'startsOn',period.starts_on,'endsOn',period.ends_on),
  'accounts',accounts,'totals',jsonb_build_object(
   'periodDebitMinor',total_period_debit::TEXT,'periodCreditMinor',total_period_credit::TEXT,
   'closingDebitMinor',total_closing_debit::TEXT,'closingCreditMinor',total_closing_credit::TEXT));
END $$;
REVOKE ALL ON FUNCTION read_accounting_trial_balance(UUID,UUID,TEXT,DATE,DATE,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION read_accounting_trial_balance(UUID,UUID,TEXT,DATE,DATE,TIMESTAMPTZ) TO service_role;
