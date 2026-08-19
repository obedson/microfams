-- AC-02 reproducible, journal-derived organization income statement.
SET search_path=public,extensions;
CREATE OR REPLACE FUNCTION read_accounting_income_statement(
 p_organization UUID,p_actor UUID,p_currency TEXT,p_from DATE,p_to DATE,p_cutoff TIMESTAMPTZ DEFAULT NOW()) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE period accounting_periods; lines JSONB; revenue_total BIGINT; expense_total BIGINT; cur TEXT:=upper(p_currency);
BEGIN
 IF NOT has_financial_permission(p_organization,p_actor,'financial.accounting.read') THEN RAISE EXCEPTION 'ACCOUNTING_INCOME_STATEMENT_PERMISSION_DENIED'; END IF;
 IF cur IS NULL OR cur!~'^[A-Z]{3}$' OR p_from IS NULL OR p_to IS NULL OR p_from>p_to OR p_cutoff IS NULL OR p_cutoff>clock_timestamp() THEN RAISE EXCEPTION 'ACCOUNTING_INCOME_STATEMENT_REQUEST_INVALID'; END IF;
 SELECT * INTO period FROM accounting_periods WHERE organization_id=p_organization AND p_from>=starts_on AND p_to<=ends_on ORDER BY starts_on DESC LIMIT 1;
 IF period.id IS NULL THEN RAISE EXCEPTION 'ACCOUNTING_INCOME_STATEMENT_PERIOD_REQUIRED'; END IF;
 WITH movements AS (
  SELECT account.id,account.code,account.name,account.account_class,account.normal_side,account.owner_type,account.owner_id,account.is_control,account.status,
   COALESCE(sum(line.amount_minor) FILTER(WHERE line.side='debit'),0)::BIGINT debits,
   COALESCE(sum(line.amount_minor) FILTER(WHERE line.side='credit'),0)::BIGINT credits
  FROM financial_accounts account LEFT JOIN journal_lines line ON line.account_id=account.id AND line.organization_id=p_organization AND line.currency=cur
  LEFT JOIN journal_entries entry ON entry.id=line.journal_entry_id AND entry.organization_id=p_organization AND entry.currency=cur AND entry.effective_date BETWEEN p_from AND p_to AND entry.posted_at<=p_cutoff
  WHERE account.organization_id=p_organization AND account.currency=cur AND account.account_class IN('revenue','expense') AND account.created_at<=p_cutoff GROUP BY account.id
 ), classified AS (
  SELECT *,CASE WHEN account_class='revenue' THEN credits-debits ELSE debits-credits END::BIGINT amount FROM movements
 )
 SELECT COALESCE(jsonb_agg(jsonb_build_object('accountId',id,'code',code,'name',name,'accountClass',account_class,'normalSide',normal_side,'ownerType',owner_type,'ownerId',owner_id,'isControl',is_control,'status',status,'amountMinor',amount::TEXT) ORDER BY account_class,code),'[]'::JSONB),COALESCE(sum(amount) FILTER(WHERE account_class='revenue'),0)::BIGINT,COALESCE(sum(amount) FILTER(WHERE account_class='expense'),0)::BIGINT INTO lines,revenue_total,expense_total FROM classified WHERE amount<>0;
 RETURN jsonb_build_object('organizationId',p_organization,'currency',cur,'from',p_from,'to',p_to,'cutoff',p_cutoff,'period',jsonb_build_object('id',period.id,'name',period.name,'status',period.status,'startsOn',period.starts_on,'endsOn',period.ends_on),'revenue',lines,'totalRevenueMinor',revenue_total::TEXT,'totalExpenseMinor',expense_total::TEXT,'netIncomeMinor',(revenue_total-expense_total)::TEXT);
END $$;
REVOKE ALL ON FUNCTION read_accounting_income_statement(UUID,UUID,TEXT,DATE,DATE,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION read_accounting_income_statement(UUID,UUID,TEXT,DATE,DATE,TIMESTAMPTZ) TO service_role;
