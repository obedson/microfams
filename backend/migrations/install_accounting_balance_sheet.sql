-- AC-03 reproducible, journal-derived organization balance sheet.
SET search_path=public,extensions;
CREATE OR REPLACE FUNCTION read_accounting_balance_sheet(
 p_organization UUID,p_actor UUID,p_currency TEXT,p_from DATE,p_to DATE,p_cutoff TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE period accounting_periods; accounts JSONB; cur TEXT:=upper(p_currency);
 total_assets BIGINT; total_liabilities BIGINT; total_equity BIGINT; net_income BIGINT;
BEGIN
 IF NOT has_financial_permission(p_organization,p_actor,'financial.accounting.read') THEN RAISE EXCEPTION 'ACCOUNTING_BALANCE_SHEET_PERMISSION_DENIED'; END IF;
 IF cur IS NULL OR cur!~'^[A-Z]{3}$' OR p_from IS NULL OR p_to IS NULL OR p_from>p_to OR p_cutoff IS NULL OR p_cutoff>clock_timestamp() THEN RAISE EXCEPTION 'ACCOUNTING_BALANCE_SHEET_REQUEST_INVALID'; END IF;
 SELECT * INTO period FROM accounting_periods WHERE organization_id=p_organization AND p_from>=starts_on AND p_to<=ends_on ORDER BY starts_on DESC LIMIT 1;
 IF period.id IS NULL THEN RAISE EXCEPTION 'ACCOUNTING_BALANCE_SHEET_PERIOD_REQUIRED'; END IF;
 WITH movements AS (
  SELECT account.id,account.code,account.name,account.account_class,account.normal_side,account.owner_type,account.owner_id,account.is_control,account.status,
   COALESCE(sum(line.amount_minor) FILTER(WHERE entry.id IS NOT NULL AND line.side='debit'),0)::BIGINT debits,
   COALESCE(sum(line.amount_minor) FILTER(WHERE entry.id IS NOT NULL AND line.side='credit'),0)::BIGINT credits
  FROM financial_accounts account
  LEFT JOIN journal_lines line ON line.account_id=account.id AND line.organization_id=p_organization AND line.currency=cur
  LEFT JOIN journal_entries entry ON entry.id=line.journal_entry_id AND entry.organization_id=p_organization AND entry.currency=cur AND entry.effective_date<=p_to AND entry.posted_at<=p_cutoff
  WHERE account.organization_id=p_organization AND account.currency=cur AND account.account_class IN('asset','liability','equity') AND account.created_at<=p_cutoff GROUP BY account.id
 ), classified AS (
  SELECT *,CASE WHEN account_class='asset' THEN debits-credits ELSE credits-debits END::BIGINT amount FROM movements
 ), earnings AS (
  SELECT COALESCE(sum(CASE WHEN account.account_class='revenue' AND line.side='credit' THEN line.amount_minor ELSE 0 END),0)
       - COALESCE(sum(CASE WHEN account.account_class='revenue' AND line.side='debit' THEN line.amount_minor ELSE 0 END),0)
       - COALESCE(sum(CASE WHEN account.account_class='expense' AND line.side='debit' THEN line.amount_minor ELSE 0 END),0)
       + COALESCE(sum(CASE WHEN account.account_class='expense' AND line.side='credit' THEN line.amount_minor ELSE 0 END),0) amount
  FROM financial_accounts account JOIN journal_lines line ON line.account_id=account.id AND line.organization_id=p_organization AND line.currency=cur
  JOIN journal_entries entry ON entry.id=line.journal_entry_id AND entry.organization_id=p_organization AND entry.currency=cur AND entry.effective_date BETWEEN period.starts_on AND p_to AND entry.posted_at<=p_cutoff
  WHERE account.organization_id=p_organization AND account.currency=cur AND account.account_class IN('revenue','expense')
 )
 SELECT COALESCE(jsonb_agg(jsonb_build_object('accountId',id,'code',code,'name',name,'accountClass',account_class,'normalSide',normal_side,'ownerType',owner_type,'ownerId',owner_id,'isControl',is_control,'status',status,'amountMinor',amount::TEXT) ORDER BY CASE account_class WHEN 'asset' THEN 1 WHEN 'liability' THEN 2 ELSE 3 END,code),'[]'::JSONB),
  COALESCE(sum(amount) FILTER(WHERE account_class='asset'),0)::BIGINT,COALESCE(sum(amount) FILTER(WHERE account_class='liability'),0)::BIGINT,COALESCE(sum(amount) FILTER(WHERE account_class='equity'),0)::BIGINT,(SELECT amount::BIGINT FROM earnings)
 INTO accounts,total_assets,total_liabilities,total_equity,net_income FROM classified;
 IF total_assets<>total_liabilities+total_equity+net_income THEN RAISE EXCEPTION 'ACCOUNTING_BALANCE_SHEET_UNBALANCED'; END IF;
 RETURN jsonb_build_object('organizationId',p_organization,'currency',cur,'from',p_from,'to',p_to,'asOf',p_to,'cutoff',p_cutoff,'period',jsonb_build_object('id',period.id,'name',period.name,'status',period.status,'startsOn',period.starts_on,'endsOn',period.ends_on),'accounts',accounts,'totalAssetsMinor',total_assets::TEXT,'totalLiabilitiesMinor',total_liabilities::TEXT,'totalEquityMinor',total_equity::TEXT,'currentPeriodNetIncomeMinor',net_income::TEXT,'totalLiabilitiesAndEquityMinor',(total_liabilities+total_equity+net_income)::TEXT);
END $$;
REVOKE ALL ON FUNCTION read_accounting_balance_sheet(UUID,UUID,TEXT,DATE,DATE,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION read_accounting_balance_sheet(UUID,UUID,TEXT,DATE,DATE,TIMESTAMPTZ) TO service_role;
