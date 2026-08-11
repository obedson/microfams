-- SAV-05 contract: member statements are journal-derived and reproducible;
-- tenant finance reconciliation exposes evidence/journal variance without
-- permitting cross-tenant reads or mutating financial state.
SET search_path=public,extensions;

DO $$
DECLARE
  org_id UUID:='00000000-0000-4000-8000-000000000101';
  finance_actor UUID:='00000000-0000-4000-8000-000000000101';
  enrolment_id UUID; member_id UUID; principal_account UUID; expense_account UUID;
  outsider_id UUID; late_withdrawal UUID; adjustment_journal UUID;
  period_start DATE:=CURRENT_DATE-40; cutoff_at TIMESTAMPTZ;
  statement JSONB; statement_page JSONB; reconciliation JSONB; item JSONB;
  failed BOOLEAN:=FALSE;
BEGIN
  SELECT enrolment.id,enrolment.member_id,enrolment.principal_account_id
  INTO enrolment_id,member_id,principal_account
  FROM savings_enrolments enrolment JOIN savings_products product
    ON product.id=enrolment.product_id AND product.organization_id=enrolment.organization_id
  WHERE enrolment.organization_id=org_id AND product.code='SAV.SAV04.FEE';
  IF enrolment_id IS NULL THEN RAISE EXCEPTION 'SAV05: statement fixture is unavailable'; END IF;

  cutoff_at:=clock_timestamp();
  statement:=read_member_savings_statement(
    org_id,member_id,enrolment_id,period_start,CURRENT_DATE,cutoff_at,0,100);
  IF statement#>>'{openingBalances,totalMinor}'<>'0'
    OR statement#>>'{closingBalances,principalMinor}'<>'50000'
    OR statement#>>'{closingBalances,accruedReturnMinor}'<>'0'
    OR statement#>>'{closingBalances,totalMinor}'<>'50000'
    OR (statement->>'total')::INTEGER<>2
  THEN RAISE EXCEPTION 'SAV05: journal-derived statement totals are incorrect: %',statement; END IF;
  IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(statement->'lines') line
      WHERE line->>'sourceDomain'='savings.contribution' AND line->>'component'='principal'
        AND line->>'side'='credit' AND line->>'amountMinor'='100000')
    OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(statement->'lines') line
      WHERE line->>'sourceDomain'='savings.withdrawal' AND line->>'component'='principal'
        AND line->>'side'='debit' AND line->>'amountMinor'='50000'
        AND line#>>'{details,feeMinor}'='500')
  THEN RAISE EXCEPTION 'SAV05: statement evidence is incomplete: %',statement; END IF;

  statement_page:=read_member_savings_statement(
    org_id,member_id,enrolment_id,period_start,CURRENT_DATE,cutoff_at,1,1);
  IF statement_page#>>'{pageOpeningBalances,totalMinor}'<>'100000'
    OR jsonb_array_length(statement_page->'lines')<>1
    OR statement_page->'lines'->0->>'side'<>'debit'
  THEN RAISE EXCEPTION 'SAV05: statement pagination did not preserve its running opening balance: %',statement_page; END IF;

  -- A tenant finance actor may inspect the member control statement, while an
  -- unrelated actor cannot read or reconcile this tenant.
  PERFORM read_member_savings_statement(
    org_id,finance_actor,enrolment_id,period_start,CURRENT_DATE,cutoff_at,0,10);
  INSERT INTO users(email,password,name,role) VALUES(
    'sav05-outsider-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test',
    'test','SAV05 Outsider','farmer') RETURNING id INTO outsider_id;
  failed:=FALSE;
  BEGIN
    PERFORM read_member_savings_statement(
      org_id,outsider_id,enrolment_id,period_start,CURRENT_DATE,cutoff_at,0,10);
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%not available%' THEN failed:=TRUE; END IF; END;
  IF NOT failed THEN RAISE EXCEPTION 'SAV05: outsider read another tenant member statement'; END IF;
  failed:=FALSE;
  BEGIN
    PERFORM read_savings_reconciliation(org_id,outsider_id,'NGN',cutoff_at,24,0,100);
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%permission%' THEN failed:=TRUE; END IF; END;
  IF NOT failed THEN RAISE EXCEPTION 'SAV05: outsider ran tenant savings reconciliation'; END IF;

  -- An unresolved request older than the configured threshold is visible as a
  -- late servicing item but does not alter the journal-derived balance.
  late_withdrawal:=(request_savings_withdrawal(
    org_id,member_id,enrolment_id,10000,'sav05-late-withdrawal-request-001',
    '00000000-0000-4000-8000-000000000b01',NOW()-INTERVAL '2 days')->>'id')::UUID;
  IF late_withdrawal IS NULL THEN RAISE EXCEPTION 'SAV05: late servicing fixture was not created'; END IF;

  -- Post a deliberately unpaired savings adjustment. The statement must show
  -- the immutable journal, and reconciliation must expose (not hide) variance.
  SELECT id INTO expense_account FROM financial_accounts
  WHERE organization_id=org_id AND purpose='savings_return_expense' AND currency='NGN'
    AND status='active' ORDER BY created_at LIMIT 1;
  IF expense_account IS NULL THEN RAISE EXCEPTION 'SAV05: reconciliation offset account is unavailable'; END IF;
  adjustment_journal:=post_financial_journal(
    org_id,'NGN',CURRENT_DATE,'savings.adjustment',enrolment_id::TEXT,
    'sav05-unpaired-adjustment-001',repeat('f',64),
    '00000000-0000-4000-8000-000000000b02','SAV05 deliberate reconciliation variance',finance_actor,
    jsonb_build_array(
      jsonb_build_object('account_id',expense_account,'line_number',1,'side','debit','amount_minor',7,'memo','Test variance offset'),
      jsonb_build_object('account_id',principal_account,'line_number',2,'side','credit','amount_minor',7,'memo','Unpaired savings adjustment')));
  IF adjustment_journal IS NULL THEN RAISE EXCEPTION 'SAV05: variance journal was not posted'; END IF;

  cutoff_at:=clock_timestamp();
  statement:=read_member_savings_statement(
    org_id,member_id,enrolment_id,period_start,CURRENT_DATE,cutoff_at,0,100);
  IF statement#>>'{closingBalances,totalMinor}'<>'50007'
    OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(statement->'lines') line
      WHERE line->>'journalEntryId'=adjustment_journal::TEXT
        AND line#>>'{details,type}'='journal_adjustment')
  THEN RAISE EXCEPTION 'SAV05: statement did not derive the adjustment from the journal: %',statement; END IF;

  reconciliation:=read_savings_reconciliation(org_id,finance_actor,'NGN',cutoff_at,24,0,100);
  SELECT value INTO item FROM jsonb_array_elements(reconciliation->'items')
  WHERE value->>'enrolmentId'=enrolment_id::TEXT;
  IF item IS NULL OR item->>'principalVarianceMinor'<>'7'
    OR NOT(item->'issues' ? 'unmatched') OR NOT(item->'issues' ? 'amount_mismatch')
    OR NOT(item->'issues' ? 'late') OR (item->>'pendingWithdrawalMinor')::BIGINT<10000
  THEN RAISE EXCEPTION 'SAV05: reconciliation classifications are incomplete: %',item; END IF;
  IF (reconciliation#>>'{summary,unmatchedCount}')::INTEGER<1
    OR (reconciliation#>>'{summary,amountMismatchCount}')::INTEGER<1
    OR (reconciliation#>>'{summary,lateCount}')::INTEGER<1
    OR reconciliation#>>'{summary,unexplainedVarianceMinor}'<>'7'
  THEN RAISE EXCEPTION 'SAV05: reconciliation control totals are incorrect: %',reconciliation; END IF;
  IF reconciliation IS DISTINCT FROM read_savings_reconciliation(
      org_id,finance_actor,'NGN',cutoff_at,24,0,100)
  THEN RAISE EXCEPTION 'SAV05: reconciliation read was not reproducible at its cutoff'; END IF;
END $$;
