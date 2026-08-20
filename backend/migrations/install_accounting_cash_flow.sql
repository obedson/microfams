-- AC-04 reproducible, journal-derived organization cash-flow report.
SET search_path=public,extensions;
CREATE OR REPLACE FUNCTION read_accounting_cash_flow(p_organization UUID,p_actor UUID,p_currency TEXT,p_from DATE,p_to DATE,p_cutoff TIMESTAMPTZ DEFAULT NOW()) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE period accounting_periods; rows JSONB; operating_total BIGINT; investing_total BIGINT; financing_total BIGINT; unclassified_total BIGINT; net_total BIGINT; direct_total BIGINT; cur TEXT:=upper(p_currency);
BEGIN
 IF NOT has_financial_permission(p_organization,p_actor,'financial.accounting.read') THEN RAISE EXCEPTION 'ACCOUNTING_CASH_FLOW_PERMISSION_DENIED'; END IF;
 IF cur IS NULL OR cur!~'^[A-Z]{3}$' OR p_from IS NULL OR p_to IS NULL OR p_from>p_to OR p_cutoff IS NULL OR p_cutoff>clock_timestamp() THEN RAISE EXCEPTION 'ACCOUNTING_CASH_FLOW_REQUEST_INVALID'; END IF;
 SELECT * INTO period FROM accounting_periods WHERE organization_id=p_organization AND p_from>=starts_on AND p_to<=ends_on ORDER BY starts_on DESC LIMIT 1;
 IF period.id IS NULL THEN RAISE EXCEPTION 'ACCOUNTING_CASH_FLOW_PERIOD_REQUIRED'; END IF;
 WITH movements AS (
  SELECT entry.id journal_entry_id,entry.effective_date,entry.source_domain,entry.description,COALESCE(sum(CASE WHEN line.side='debit' THEN line.amount_minor ELSE -line.amount_minor END) FILTER(WHERE account.purpose='operating_cash'),0)::BIGINT amount
  FROM journal_entries entry JOIN journal_lines line ON line.journal_entry_id=entry.id AND line.organization_id=p_organization AND line.currency=cur
  JOIN financial_accounts account ON account.id=line.account_id AND account.organization_id=p_organization AND account.currency=cur
  WHERE entry.organization_id=p_organization AND entry.currency=cur AND entry.status='posted' AND entry.effective_date BETWEEN p_from AND p_to AND entry.posted_at<=p_cutoff AND entry.created_at<=p_cutoff
  GROUP BY entry.id
 ), classified AS (
  SELECT *,CASE WHEN source_domain LIKE 'investment.%' OR source_domain LIKE 'group_asset.%' OR source_domain LIKE 'asset.%' THEN 'investing'
    WHEN source_domain LIKE 'loan.%' OR source_domain LIKE 'capital.%' OR source_domain LIKE 'dividend.%' THEN 'financing'
    WHEN source_domain LIKE 'savings.%' OR source_domain LIKE 'booking.%' OR source_domain LIKE 'payment.%' OR source_domain LIKE 'treasury.%' THEN 'operating'
    ELSE 'unclassified' END AS domain FROM movements WHERE amount<>0
 )
 SELECT COALESCE(jsonb_agg(jsonb_build_object('journalEntryId',journal_entry_id,'effectiveDate',effective_date,'sourceDomain',source_domain,'description',description,'domain',domain,'amountMinor',amount::TEXT) ORDER BY effective_date,journal_entry_id),'[]'::JSONB),COALESCE(sum(amount) FILTER(WHERE domain='operating'),0)::BIGINT,COALESCE(sum(amount) FILTER(WHERE domain='investing'),0)::BIGINT,COALESCE(sum(amount) FILTER(WHERE domain='financing'),0)::BIGINT,COALESCE(sum(amount) FILTER(WHERE domain='unclassified'),0)::BIGINT,COALESCE(sum(amount),0)::BIGINT
 INTO rows,operating_total,investing_total,financing_total,unclassified_total,net_total FROM classified;
 SELECT COALESCE(sum(CASE WHEN line.side='debit' THEN line.amount_minor ELSE -line.amount_minor END),0)::BIGINT INTO direct_total
 FROM journal_entries entry JOIN journal_lines line ON line.journal_entry_id=entry.id AND line.organization_id=p_organization AND line.currency=cur
 JOIN financial_accounts account ON account.id=line.account_id AND account.organization_id=p_organization AND account.currency=cur AND account.purpose='operating_cash'
 WHERE entry.organization_id=p_organization AND entry.currency=cur AND entry.status='posted' AND entry.effective_date BETWEEN p_from AND p_to AND entry.posted_at<=p_cutoff AND entry.created_at<=p_cutoff;
 IF net_total<>operating_total+investing_total+financing_total+unclassified_total OR net_total<>direct_total THEN RAISE EXCEPTION 'ACCOUNTING_CASH_FLOW_UNRECONCILED'; END IF;
 RETURN jsonb_build_object('organizationId',p_organization,'currency',cur,'from',p_from,'to',p_to,'cutoff',p_cutoff,'period',jsonb_build_object('id',period.id,'name',period.name,'status',period.status,'startsOn',period.starts_on,'endsOn',period.ends_on),'movements',rows,'operatingCashFlowMinor',operating_total::TEXT,'investingCashFlowMinor',investing_total::TEXT,'financingCashFlowMinor',financing_total::TEXT,'unclassifiedCashFlowMinor',unclassified_total::TEXT,'netChangeInCashMinor',net_total::TEXT);
END $$;
REVOKE ALL ON FUNCTION read_accounting_cash_flow(UUID,UUID,TEXT,DATE,DATE,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION read_accounting_cash_flow(UUID,UUID,TEXT,DATE,DATE,TIMESTAMPTZ) TO service_role;
