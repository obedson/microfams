-- GT-07A: reproducible, journal-derived group treasury statements.
SET search_path=public,extensions;

CREATE OR REPLACE FUNCTION read_group_treasury_statement(
  p_organization_id UUID,p_group_id UUID,p_actor_id UUID,p_currency TEXT,
  p_from DATE,p_to DATE,p_cutoff TIMESTAMPTZ,p_offset INTEGER,p_limit INTEGER
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE account_row financial_accounts; opening_minor BIGINT; page_opening_minor BIGINT;
  closing_minor BIGINT; reserved_minor BIGINT; total_count BIGINT; lines JSONB;
  classifications JSONB; account_id UUID;
BEGIN
  p_currency:=upper(p_currency);
  IF p_currency!~'^[A-Z]{3}$' OR p_from IS NULL OR p_to IS NULL OR p_from>p_to
    OR p_cutoff IS NULL OR p_cutoff>clock_timestamp() OR p_offset<0
    OR p_limit NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'GROUP_TREASURY_STATEMENT_INVALID';
  END IF;
  IF NOT EXISTS(
    SELECT 1 FROM groups WHERE id=p_group_id AND organization_id=p_organization_id
  ) THEN RAISE EXCEPTION 'GROUP_TREASURY_STATEMENT_NOT_FOUND'; END IF;
  IF NOT EXISTS(
    SELECT 1 FROM group_members WHERE organization_id=p_organization_id
      AND group_id=p_group_id AND user_id=p_actor_id AND status='active'
      AND is_active AND payment_status='paid'
  ) THEN RAISE EXCEPTION 'GROUP_TREASURY_STATEMENT_NOT_AUTHORIZED'; END IF;

  account_id:=group_treasury_account_id(p_organization_id,p_group_id);
  SELECT * INTO account_row FROM financial_accounts
  WHERE id=account_id AND organization_id=p_organization_id AND currency=p_currency;
  IF account_row.id IS NULL THEN RAISE EXCEPTION 'GROUP_TREASURY_STATEMENT_NOT_FOUND'; END IF;

  SELECT COALESCE(sum(CASE WHEN line.side=account_row.normal_side
    THEN line.amount_minor ELSE -line.amount_minor END),0)::BIGINT
  INTO opening_minor
  FROM journal_lines line JOIN journal_entries entry ON entry.id=line.journal_entry_id
  WHERE line.organization_id=p_organization_id AND line.account_id=account_id
    AND entry.effective_date<p_from AND entry.posted_at<=p_cutoff;

  WITH preceding AS (
    SELECT line.side,line.amount_minor
    FROM journal_lines line JOIN journal_entries entry ON entry.id=line.journal_entry_id
    WHERE line.organization_id=p_organization_id AND line.account_id=account_id
      AND entry.effective_date BETWEEN p_from AND p_to AND entry.posted_at<=p_cutoff
    ORDER BY entry.effective_date,entry.posted_at,line.line_number,line.id LIMIT p_offset
  ) SELECT opening_minor+COALESCE(sum(CASE WHEN side=account_row.normal_side
      THEN amount_minor ELSE -amount_minor END),0)::BIGINT
    INTO page_opening_minor FROM preceding;

  SELECT opening_minor+COALESCE(sum(CASE WHEN line.side=account_row.normal_side
      THEN line.amount_minor ELSE -line.amount_minor END),0)::BIGINT,count(*)
  INTO closing_minor,total_count
  FROM journal_lines line JOIN journal_entries entry ON entry.id=line.journal_entry_id
  WHERE line.organization_id=p_organization_id AND line.account_id=account_id
    AND entry.effective_date BETWEEN p_from AND p_to AND entry.posted_at<=p_cutoff;

  SELECT COALESCE(sum(reservation.amount_minor),0)::BIGINT INTO reserved_minor
  FROM group_treasury_reservations reservation
  WHERE reservation.organization_id=p_organization_id AND reservation.group_id=p_group_id
    AND reservation.currency=p_currency AND reservation.created_at<=p_cutoff
    AND (reservation.consumed_at IS NULL OR reservation.consumed_at>p_cutoff)
    AND (reservation.released_at IS NULL OR reservation.released_at>p_cutoff)
    AND (reservation.expired_at IS NULL OR reservation.expired_at>p_cutoff);

  SELECT COALESCE(jsonb_object_agg(ownership,amount_minor),'{}'::JSONB)
  INTO classifications FROM (
    SELECT allocation.ownership,
      COALESCE(sum(allocation.amount_minor),0)::BIGINT::TEXT amount_minor
    FROM group_contribution_allocations allocation
    WHERE allocation.organization_id=p_organization_id AND allocation.group_id=p_group_id
      AND allocation.currency=p_currency AND allocation.allocated_at<=p_cutoff
      AND (allocation.reversed_at IS NULL OR allocation.reversed_at>p_cutoff)
    GROUP BY allocation.ownership
  ) classified;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',page.id,'journalEntryId',page.journal_entry_id,
    'effectiveDate',page.effective_date,'postedAt',page.posted_at,
    'description',page.description,'sourceDomain',page.source_domain,
    'side',page.side,'amountMinor',page.amount_minor::TEXT,'memo',page.memo
  ) ORDER BY page.effective_date,page.posted_at,page.line_number,page.id),'[]'::JSONB)
  INTO lines FROM (
    SELECT line.*,entry.effective_date,entry.posted_at,entry.description,
      entry.source_domain,entry.source_record_id,entry.correlation_id
    FROM journal_lines line JOIN journal_entries entry ON entry.id=line.journal_entry_id
    WHERE line.organization_id=p_organization_id AND line.account_id=account_id
      AND entry.effective_date BETWEEN p_from AND p_to AND entry.posted_at<=p_cutoff
    ORDER BY entry.effective_date,entry.posted_at,line.line_number,line.id
    OFFSET p_offset LIMIT p_limit
  ) page;

  RETURN jsonb_build_object(
    'groupId',p_group_id,'currency',p_currency,
    'account',jsonb_build_object('id',account_row.id,'code',account_row.code,
      'name',account_row.name,'normalSide',account_row.normal_side),
    'period',jsonb_build_object('from',p_from,'to',p_to,'cutoff',p_cutoff),
    'openingBalanceMinor',opening_minor::TEXT,
    'pageOpeningBalanceMinor',page_opening_minor::TEXT,
    'closingBalanceMinor',closing_minor::TEXT,
    'reservedMinor',reserved_minor::TEXT,
    'availableMinor',GREATEST(closing_minor-reserved_minor,0)::TEXT,
    'fundClassificationMinor',classifications,
    'lines',lines,'total',total_count
  );
END $$;

REVOKE ALL ON FUNCTION read_group_treasury_statement(UUID,UUID,UUID,TEXT,DATE,DATE,TIMESTAMPTZ,INTEGER,INTEGER) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION read_group_treasury_statement(UUID,UUID,UUID,TEXT,DATE,DATE,TIMESTAMPTZ,INTEGER,INTEGER) TO service_role;
