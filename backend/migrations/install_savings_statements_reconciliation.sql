-- SAV-05: journal-derived member savings statements and tenant finance
-- reconciliation controls. These read-only servicing functions remain available
-- independently of flags that create new savings exposure.

SET search_path=public,extensions;

CREATE OR REPLACE FUNCTION read_member_savings_statement(
  p_organization UUID,
  p_actor UUID,
  p_enrolment UUID,
  p_from DATE,
  p_to DATE,
  p_cutoff TIMESTAMPTZ,
  p_offset INTEGER,
  p_limit INTEGER
) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
DECLARE
  v_enrolment savings_enrolments;
  v_product savings_products;
  v_open_principal BIGINT;
  v_open_return BIGINT;
  v_page_principal BIGINT;
  v_page_return BIGINT;
  v_close_principal BIGINT;
  v_close_return BIGINT;
  v_total BIGINT;
  v_lines JSONB;
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_from>p_to OR p_cutoff IS NULL OR p_cutoff>clock_timestamp()
    OR p_offset IS NULL OR p_offset<0 OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100
  THEN RAISE EXCEPTION 'Savings statement request is invalid'; END IF;

  SELECT * INTO v_enrolment FROM savings_enrolments
  WHERE id=p_enrolment AND organization_id=p_organization;
  IF v_enrolment.id IS NULL THEN RAISE EXCEPTION 'Savings enrolment not found'; END IF;
  IF NOT (
      v_enrolment.member_id=p_actor
      AND EXISTS(SELECT 1 FROM organization_memberships
        WHERE organization_id=p_organization AND user_id=p_actor AND status='active')
    ) AND NOT has_financial_permission(p_organization,p_actor,'financial.reconciliation.manual')
  THEN RAISE EXCEPTION 'Savings statement is not available to this actor'; END IF;
  SELECT * INTO v_product FROM savings_products
  WHERE id=v_enrolment.product_id AND organization_id=p_organization;

  SELECT
    COALESCE(sum(CASE WHEN line.account_id=v_enrolment.principal_account_id
      THEN CASE line.side WHEN 'credit' THEN line.amount_minor ELSE -line.amount_minor END ELSE 0 END),0)::BIGINT,
    COALESCE(sum(CASE WHEN line.account_id=v_enrolment.accrued_return_account_id
      THEN CASE line.side WHEN 'credit' THEN line.amount_minor ELSE -line.amount_minor END ELSE 0 END),0)::BIGINT
  INTO v_open_principal,v_open_return
  FROM journal_lines line JOIN journal_entries entry ON entry.id=line.journal_entry_id
  WHERE line.organization_id=p_organization
    AND line.account_id IN(v_enrolment.principal_account_id,v_enrolment.accrued_return_account_id)
    AND entry.effective_date<p_from AND entry.posted_at<=p_cutoff;

  WITH preceding AS (
    SELECT line.account_id,line.side,line.amount_minor
    FROM journal_lines line JOIN journal_entries entry ON entry.id=line.journal_entry_id
    WHERE line.organization_id=p_organization
      AND line.account_id IN(v_enrolment.principal_account_id,v_enrolment.accrued_return_account_id)
      AND entry.effective_date BETWEEN p_from AND p_to AND entry.posted_at<=p_cutoff
    ORDER BY entry.effective_date,entry.posted_at,line.line_number,line.id
    LIMIT p_offset
  )
  SELECT
    v_open_principal+COALESCE(sum(CASE WHEN account_id=v_enrolment.principal_account_id
      THEN CASE side WHEN 'credit' THEN amount_minor ELSE -amount_minor END ELSE 0 END),0)::BIGINT,
    v_open_return+COALESCE(sum(CASE WHEN account_id=v_enrolment.accrued_return_account_id
      THEN CASE side WHEN 'credit' THEN amount_minor ELSE -amount_minor END ELSE 0 END),0)::BIGINT
  INTO v_page_principal,v_page_return FROM preceding;

  SELECT
    v_open_principal+COALESCE(sum(CASE WHEN line.account_id=v_enrolment.principal_account_id
      THEN CASE line.side WHEN 'credit' THEN line.amount_minor ELSE -line.amount_minor END ELSE 0 END),0)::BIGINT,
    v_open_return+COALESCE(sum(CASE WHEN line.account_id=v_enrolment.accrued_return_account_id
      THEN CASE line.side WHEN 'credit' THEN line.amount_minor ELSE -line.amount_minor END ELSE 0 END),0)::BIGINT,
    count(*)
  INTO v_close_principal,v_close_return,v_total
  FROM journal_lines line JOIN journal_entries entry ON entry.id=line.journal_entry_id
  WHERE line.organization_id=p_organization
    AND line.account_id IN(v_enrolment.principal_account_id,v_enrolment.accrued_return_account_id)
    AND entry.effective_date BETWEEN p_from AND p_to AND entry.posted_at<=p_cutoff;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',page.id,
    'journalEntryId',page.journal_entry_id,
    'effectiveDate',page.effective_date,
    'postedAt',page.posted_at,
    'journalStatus',page.journal_status,
    'description',page.description,
    'sourceDomain',page.source_domain,
    'sourceRecordId',page.source_record_id,
    'correlationId',page.correlation_id,
    'component',CASE page.account_id
      WHEN v_enrolment.principal_account_id THEN 'principal' ELSE 'accrued_return' END,
    'side',page.side,
    'amountMinor',page.amount_minor::TEXT,
    'memo',page.memo,
    'details',CASE page.source_domain
      WHEN 'savings.contribution' THEN COALESCE((SELECT jsonb_build_object(
        'type','contribution','method',contribution.method,'scheduledFor',contribution.scheduled_for,
        'contributedAt',contribution.contributed_at)
        FROM savings_contributions contribution
        WHERE contribution.organization_id=p_organization
          AND contribution.journal_entry_id=page.journal_entry_id),'{}'::JSONB)
      WHEN 'savings.accrual' THEN COALESCE((SELECT jsonb_build_object(
        'type','return_accrual','periodStart',batch.period_start,'periodEnd',batch.period_end,
        'formulaVersion',item.formula_version,'annualRateBasisPoints',item.annual_rate_basis_points,
        'dayCountConvention',item.day_count_convention)
        FROM savings_accrual_batches batch JOIN savings_accrual_items item
          ON item.batch_id=batch.id AND item.organization_id=batch.organization_id
        WHERE batch.organization_id=p_organization AND batch.journal_entry_id=page.journal_entry_id
          AND item.enrolment_id=p_enrolment),'{}'::JSONB)
      WHEN 'savings.withdrawal' THEN COALESCE((SELECT jsonb_build_object(
        'type','withdrawal','requestedMinor',withdrawal.requested_minor::TEXT,
        'netPayoutMinor',withdrawal.net_payout_minor::TEXT,'feeMinor',withdrawal.fee_minor::TEXT,
        'returnForfeitedMinor',withdrawal.return_forfeited_minor::TEXT,
        'isEarly',withdrawal.is_early,'settledAt',withdrawal.settled_at)
        FROM savings_withdrawals withdrawal
        WHERE withdrawal.organization_id=p_organization
          AND withdrawal.journal_entry_id=page.journal_entry_id),'{}'::JSONB)
      ELSE jsonb_build_object('type','journal_adjustment')
    END
  ) ORDER BY page.effective_date,page.posted_at,page.line_number,page.id),'[]'::JSONB)
  INTO v_lines FROM (
    SELECT line.*,entry.effective_date,entry.posted_at,entry.status journal_status,
      entry.description,entry.source_domain,entry.source_record_id,entry.correlation_id
    FROM journal_lines line JOIN journal_entries entry ON entry.id=line.journal_entry_id
    WHERE line.organization_id=p_organization
      AND line.account_id IN(v_enrolment.principal_account_id,v_enrolment.accrued_return_account_id)
      AND entry.effective_date BETWEEN p_from AND p_to AND entry.posted_at<=p_cutoff
    ORDER BY entry.effective_date,entry.posted_at,line.line_number,line.id
    OFFSET p_offset LIMIT p_limit
  ) page;

  RETURN jsonb_build_object(
    'enrolment',jsonb_build_object(
      'id',v_enrolment.id,'productId',v_enrolment.product_id,'productName',v_product.name,
      'memberId',v_enrolment.member_id,'state',v_enrolment.state,'currency',v_enrolment.currency,
      'targetMinor',CASE WHEN v_enrolment.target_minor IS NULL THEN NULL ELSE v_enrolment.target_minor::TEXT END,
      'lockExpiresAt',v_enrolment.lock_expires_at,
      'acceptedDisclosureVersion',v_enrolment.accepted_disclosure_version),
    'openingBalances',jsonb_build_object(
      'principalMinor',v_open_principal::TEXT,'accruedReturnMinor',v_open_return::TEXT,
      'totalMinor',(v_open_principal+v_open_return)::TEXT),
    'pageOpeningBalances',jsonb_build_object(
      'principalMinor',v_page_principal::TEXT,'accruedReturnMinor',v_page_return::TEXT,
      'totalMinor',(v_page_principal+v_page_return)::TEXT),
    'closingBalances',jsonb_build_object(
      'principalMinor',v_close_principal::TEXT,'accruedReturnMinor',v_close_return::TEXT,
      'totalMinor',(v_close_principal+v_close_return)::TEXT),
    'lines',v_lines,'total',v_total
  );
END $$;

CREATE OR REPLACE FUNCTION read_savings_reconciliation(
  p_organization UUID,
  p_actor UUID,
  p_currency TEXT,
  p_cutoff TIMESTAMPTZ,
  p_stale_after_hours INTEGER,
  p_offset INTEGER,
  p_limit INTEGER
) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
DECLARE v_result JSONB;
BEGIN
  p_currency:=upper(p_currency);
  IF p_currency IS NULL OR p_currency!~'^[A-Z]{3}$' OR p_cutoff IS NULL OR p_cutoff>clock_timestamp()
    OR p_stale_after_hours IS NULL OR p_stale_after_hours NOT BETWEEN 1 AND 720
    OR p_offset IS NULL OR p_offset<0 OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100
  THEN RAISE EXCEPTION 'Savings reconciliation request is invalid'; END IF;
  IF NOT has_financial_permission(p_organization,p_actor,'financial.reconciliation.manual') THEN
    RAISE EXCEPTION 'Missing financial.reconciliation.manual permission';
  END IF;

  WITH base AS (
    SELECT enrolment.id enrolment_id,enrolment.member_id,enrolment.product_id,product.name product_name,
      enrolment.principal_account_id,enrolment.accrued_return_account_id,enrolment.state,
      COALESCE((SELECT sum(CASE line.side WHEN 'credit' THEN line.amount_minor ELSE -line.amount_minor END)
        FROM journal_lines line JOIN journal_entries entry ON entry.id=line.journal_entry_id
        WHERE line.organization_id=p_organization AND line.account_id=enrolment.principal_account_id
          AND entry.posted_at<=p_cutoff AND entry.effective_date<=p_cutoff::DATE),0)::BIGINT principal_journal_minor,
      COALESCE((SELECT sum(CASE line.side WHEN 'credit' THEN line.amount_minor ELSE -line.amount_minor END)
        FROM journal_lines line JOIN journal_entries entry ON entry.id=line.journal_entry_id
        WHERE line.organization_id=p_organization AND line.account_id=enrolment.accrued_return_account_id
          AND entry.posted_at<=p_cutoff AND entry.effective_date<=p_cutoff::DATE),0)::BIGINT return_journal_minor,
      COALESCE((SELECT sum(contribution.amount_minor) FROM savings_contributions contribution
        WHERE contribution.organization_id=p_organization AND contribution.enrolment_id=enrolment.id
          AND contribution.contributed_at<=p_cutoff),0)::BIGINT contribution_minor,
      COALESCE((SELECT sum(item.accrued_minor) FROM savings_accrual_items item
        JOIN savings_accrual_batches batch ON batch.id=item.batch_id AND batch.organization_id=item.organization_id
        WHERE item.organization_id=p_organization AND item.enrolment_id=enrolment.id
          AND batch.state='posted' AND batch.posted_at<=p_cutoff),0)::BIGINT posted_return_minor,
      COALESCE((SELECT sum(withdrawal.principal_withdrawn_minor) FROM savings_withdrawals withdrawal
        WHERE withdrawal.organization_id=p_organization AND withdrawal.enrolment_id=enrolment.id
          AND withdrawal.state='settled' AND withdrawal.settled_at<=p_cutoff),0)::BIGINT principal_withdrawn_minor,
      COALESCE((SELECT sum(withdrawal.return_withdrawn_minor+withdrawal.return_forfeited_minor)
        FROM savings_withdrawals withdrawal
        WHERE withdrawal.organization_id=p_organization AND withdrawal.enrolment_id=enrolment.id
          AND withdrawal.state='settled' AND withdrawal.settled_at<=p_cutoff),0)::BIGINT return_consumed_minor,
      COALESCE((SELECT sum(withdrawal.principal_withdrawn_minor+withdrawal.return_withdrawn_minor
          +withdrawal.return_forfeited_minor) FROM savings_withdrawals withdrawal
        WHERE withdrawal.organization_id=p_organization AND withdrawal.enrolment_id=enrolment.id
          AND withdrawal.state='pending_approval' AND withdrawal.created_at<=p_cutoff),0)::BIGINT pending_withdrawal_minor,
      (SELECT count(*) FROM savings_withdrawals withdrawal
        WHERE withdrawal.organization_id=p_organization AND withdrawal.enrolment_id=enrolment.id
          AND withdrawal.state='pending_approval'
          AND withdrawal.created_at<=p_cutoff-make_interval(hours=>p_stale_after_hours))
      +(SELECT count(*) FROM savings_accrual_items item JOIN savings_accrual_batches batch
          ON batch.id=item.batch_id AND batch.organization_id=item.organization_id
        WHERE item.organization_id=p_organization AND item.enrolment_id=enrolment.id
          AND batch.state='pending_approval'
          AND batch.created_at<=p_cutoff-make_interval(hours=>p_stale_after_hours))
      +(SELECT count(*) FROM savings_standing_order_attempts attempt JOIN savings_standing_orders standing_order
          ON standing_order.id=attempt.standing_order_id AND standing_order.organization_id=attempt.organization_id
        WHERE attempt.organization_id=p_organization AND standing_order.enrolment_id=enrolment.id
          AND attempt.state='processing'
          AND attempt.attempted_at<=p_cutoff-make_interval(hours=>p_stale_after_hours)) AS late_items,
      (SELECT count(*) FROM savings_contributions contribution
        WHERE contribution.organization_id=p_organization AND contribution.enrolment_id=enrolment.id
          AND contribution.contributed_at<=p_cutoff AND NOT EXISTS(
            SELECT 1 FROM journal_entries entry JOIN journal_lines line ON line.journal_entry_id=entry.id
            WHERE entry.id=contribution.journal_entry_id AND entry.organization_id=p_organization
              AND entry.source_domain='savings.contribution' AND entry.source_record_id=enrolment.id::TEXT
              AND line.account_id=enrolment.principal_account_id AND line.side='credit'))
      +(SELECT count(*) FROM savings_accrual_items item JOIN savings_accrual_batches batch
          ON batch.id=item.batch_id AND batch.organization_id=item.organization_id
        WHERE item.organization_id=p_organization AND item.enrolment_id=enrolment.id
          AND batch.state='posted' AND batch.posted_at<=p_cutoff AND NOT EXISTS(
            SELECT 1 FROM journal_entries entry JOIN journal_lines line ON line.journal_entry_id=entry.id
            WHERE entry.id=batch.journal_entry_id AND entry.organization_id=p_organization
              AND entry.source_domain='savings.accrual' AND entry.source_record_id=batch.id::TEXT
              AND line.account_id=enrolment.accrued_return_account_id AND line.side='credit'))
      +(SELECT count(*) FROM savings_withdrawals withdrawal
        WHERE withdrawal.organization_id=p_organization AND withdrawal.enrolment_id=enrolment.id
          AND withdrawal.state='settled' AND withdrawal.settled_at<=p_cutoff AND NOT EXISTS(
            SELECT 1 FROM journal_entries entry JOIN journal_lines line ON line.journal_entry_id=entry.id
            WHERE entry.id=withdrawal.journal_entry_id AND entry.organization_id=p_organization
              AND entry.source_domain='savings.withdrawal' AND entry.source_record_id=withdrawal.id::TEXT
              AND line.account_id IN(enrolment.principal_account_id,enrolment.accrued_return_account_id)
              AND line.side='debit'))
      +(SELECT count(*) FROM journal_lines line JOIN journal_entries entry ON entry.id=line.journal_entry_id
        WHERE line.organization_id=p_organization
          AND line.account_id IN(enrolment.principal_account_id,enrolment.accrued_return_account_id)
          AND entry.posted_at<=p_cutoff AND entry.effective_date<=p_cutoff::DATE AND NOT(
            (entry.source_domain='savings.contribution' AND EXISTS(SELECT 1 FROM savings_contributions contribution
              WHERE contribution.organization_id=p_organization AND contribution.enrolment_id=enrolment.id
                AND contribution.journal_entry_id=entry.id))
            OR(entry.source_domain='savings.accrual' AND EXISTS(SELECT 1 FROM savings_accrual_items item
              JOIN savings_accrual_batches batch ON batch.id=item.batch_id AND batch.organization_id=item.organization_id
              WHERE item.organization_id=p_organization AND item.enrolment_id=enrolment.id
                AND batch.journal_entry_id=entry.id))
            OR(entry.source_domain='savings.withdrawal' AND EXISTS(SELECT 1 FROM savings_withdrawals withdrawal
              WHERE withdrawal.organization_id=p_organization AND withdrawal.enrolment_id=enrolment.id
                AND withdrawal.journal_entry_id=entry.id))
          )) AS unmatched_items,
      (SELECT count(*) FROM savings_contributions contribution
        WHERE contribution.organization_id=p_organization AND contribution.enrolment_id=enrolment.id
          AND contribution.contributed_at<=p_cutoff AND 1<(
            SELECT count(*) FROM journal_lines line WHERE line.journal_entry_id=contribution.journal_entry_id
              AND line.account_id=enrolment.principal_account_id AND line.side='credit'))
      +(SELECT count(*) FROM savings_accrual_items item JOIN savings_accrual_batches batch
          ON batch.id=item.batch_id AND batch.organization_id=item.organization_id
        WHERE item.organization_id=p_organization AND item.enrolment_id=enrolment.id
          AND batch.state='posted' AND batch.posted_at<=p_cutoff AND 1<(
            SELECT count(*) FROM journal_lines line WHERE line.journal_entry_id=batch.journal_entry_id
              AND line.account_id=enrolment.accrued_return_account_id AND line.side='credit'))
      +(SELECT count(*) FROM savings_withdrawals withdrawal
        WHERE withdrawal.organization_id=p_organization AND withdrawal.enrolment_id=enrolment.id
          AND withdrawal.state='settled' AND withdrawal.settled_at<=p_cutoff AND(
            1<(SELECT count(*) FROM journal_lines line WHERE line.journal_entry_id=withdrawal.journal_entry_id
              AND line.account_id=enrolment.principal_account_id AND line.side='debit')
            OR 1<(SELECT count(*) FROM journal_lines line WHERE line.journal_entry_id=withdrawal.journal_entry_id
              AND line.account_id=enrolment.accrued_return_account_id AND line.side='debit'))) AS duplicate_items,
      (SELECT count(*) FROM savings_contributions contribution
        WHERE contribution.organization_id=p_organization AND contribution.enrolment_id=enrolment.id
          AND contribution.contributed_at<=p_cutoff AND contribution.amount_minor<>(
            SELECT COALESCE(sum(line.amount_minor),0) FROM journal_lines line
            WHERE line.journal_entry_id=contribution.journal_entry_id
              AND line.account_id=enrolment.principal_account_id AND line.side='credit'))
      +(SELECT count(*) FROM savings_accrual_items item JOIN savings_accrual_batches batch
          ON batch.id=item.batch_id AND batch.organization_id=item.organization_id
        WHERE item.organization_id=p_organization AND item.enrolment_id=enrolment.id
          AND batch.state='posted' AND batch.posted_at<=p_cutoff AND item.accrued_minor<>(
            SELECT COALESCE(sum(line.amount_minor),0) FROM journal_lines line
            WHERE line.journal_entry_id=batch.journal_entry_id
              AND line.account_id=enrolment.accrued_return_account_id AND line.side='credit'))
      +(SELECT count(*) FROM savings_withdrawals withdrawal
        WHERE withdrawal.organization_id=p_organization AND withdrawal.enrolment_id=enrolment.id
          AND withdrawal.state='settled' AND withdrawal.settled_at<=p_cutoff AND
          withdrawal.principal_withdrawn_minor<>(SELECT COALESCE(sum(line.amount_minor),0) FROM journal_lines line
            WHERE line.journal_entry_id=withdrawal.journal_entry_id
              AND line.account_id=enrolment.principal_account_id AND line.side='debit'))
      +(SELECT count(*) FROM savings_withdrawals withdrawal
        WHERE withdrawal.organization_id=p_organization AND withdrawal.enrolment_id=enrolment.id
          AND withdrawal.state='settled' AND withdrawal.settled_at<=p_cutoff AND
          withdrawal.return_withdrawn_minor+withdrawal.return_forfeited_minor<>(
            SELECT COALESCE(sum(line.amount_minor),0) FROM journal_lines line
            WHERE line.journal_entry_id=withdrawal.journal_entry_id
              AND line.account_id=enrolment.accrued_return_account_id AND line.side='debit')) AS mismatched_items
    FROM savings_enrolments enrolment JOIN savings_products product
      ON product.id=enrolment.product_id AND product.organization_id=enrolment.organization_id
    WHERE enrolment.organization_id=p_organization AND enrolment.currency=p_currency
      AND enrolment.created_at<=p_cutoff
  ), metrics AS (
    SELECT base.*,
      contribution_minor-principal_withdrawn_minor expected_principal_minor,
      posted_return_minor-return_consumed_minor expected_return_minor,
      principal_journal_minor-(contribution_minor-principal_withdrawn_minor) principal_variance_minor,
      return_journal_minor-(posted_return_minor-return_consumed_minor) return_variance_minor
    FROM base
  ), classified AS (
    SELECT metrics.*,
      array_remove(ARRAY[
        CASE WHEN unmatched_items>0 THEN 'unmatched' END,
        CASE WHEN duplicate_items>0 THEN 'duplicate' END,
        CASE WHEN mismatched_items>0 OR principal_variance_minor<>0 OR return_variance_minor<>0
          THEN 'amount_mismatch' END,
        CASE WHEN late_items>0 THEN 'late' END
      ],NULL) issues
    FROM metrics
  ), page AS (
    SELECT * FROM classified ORDER BY product_name,enrolment_id OFFSET p_offset LIMIT p_limit
  )
  SELECT jsonb_build_object(
    'organizationId',p_organization,'currency',p_currency,'cutoff',p_cutoff,
    'staleAfterHours',p_stale_after_hours,
    'summary',jsonb_build_object(
      'enrolmentCount',(SELECT count(*) FROM classified),
      'matchedCount',(SELECT count(*) FROM classified WHERE cardinality(issues)=0),
      'unmatchedCount',(SELECT count(*) FROM classified WHERE 'unmatched'=ANY(issues)),
      'duplicateCount',(SELECT count(*) FROM classified WHERE 'duplicate'=ANY(issues)),
      'amountMismatchCount',(SELECT count(*) FROM classified WHERE 'amount_mismatch'=ANY(issues)),
      'lateCount',(SELECT count(*) FROM classified WHERE 'late'=ANY(issues)),
      'expectedLiabilityMinor',COALESCE((SELECT sum(expected_principal_minor+expected_return_minor) FROM classified),0)::TEXT,
      'journalLiabilityMinor',COALESCE((SELECT sum(principal_journal_minor+return_journal_minor) FROM classified),0)::TEXT,
      'unexplainedVarianceMinor',COALESCE((SELECT sum(principal_variance_minor+return_variance_minor) FROM classified),0)::TEXT,
      'pendingWithdrawalMinor',COALESCE((SELECT sum(pending_withdrawal_minor) FROM classified),0)::TEXT),
    'items',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'enrolmentId',enrolment_id,'memberId',member_id,'productId',product_id,'productName',product_name,
      'state',state,'classification',CASE WHEN cardinality(issues)=0 THEN 'matched' ELSE issues[1] END,
      'issues',to_jsonb(issues),'contributionMinor',contribution_minor::TEXT,
      'postedReturnMinor',posted_return_minor::TEXT,'principalWithdrawnMinor',principal_withdrawn_minor::TEXT,
      'returnConsumedMinor',return_consumed_minor::TEXT,'pendingWithdrawalMinor',pending_withdrawal_minor::TEXT,
      'expectedPrincipalMinor',expected_principal_minor::TEXT,'principalJournalMinor',principal_journal_minor::TEXT,
      'principalVarianceMinor',principal_variance_minor::TEXT,'expectedReturnMinor',expected_return_minor::TEXT,
      'returnJournalMinor',return_journal_minor::TEXT,'returnVarianceMinor',return_variance_minor::TEXT,
      'unmatchedItems',unmatched_items,'duplicateItems',duplicate_items,
      'amountMismatchItems',mismatched_items,'lateItems',late_items
    ) ORDER BY product_name,enrolment_id) FROM page),'[]'::JSONB),
    'pagination',jsonb_build_object(
      'offset',p_offset,'limit',p_limit,'total',(SELECT count(*) FROM classified))
  ) INTO v_result;
  RETURN v_result;
END $$;

REVOKE ALL ON FUNCTION read_member_savings_statement(UUID,UUID,UUID,DATE,DATE,TIMESTAMPTZ,INTEGER,INTEGER)
  FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION read_savings_reconciliation(UUID,UUID,TEXT,TIMESTAMPTZ,INTEGER,INTEGER,INTEGER)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION read_member_savings_statement(UUID,UUID,UUID,DATE,DATE,TIMESTAMPTZ,INTEGER,INTEGER)
  TO service_role;
GRANT EXECUTE ON FUNCTION read_savings_reconciliation(UUID,UUID,TEXT,TIMESTAMPTZ,INTEGER,INTEGER,INTEGER)
  TO service_role;
