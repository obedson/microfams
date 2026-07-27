-- Journal-derived, reproducible customer and group statements.
CREATE OR REPLACE FUNCTION read_financial_statement(
  p_organization_id UUID,
  p_owner_type TEXT,
  p_owner_id UUID,
  p_currency TEXT,
  p_from DATE,
  p_to DATE,
  p_cutoff TIMESTAMPTZ,
  p_offset INTEGER,
  p_limit INTEGER
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_account financial_accounts%ROWTYPE;
  v_opening BIGINT;
  v_page_opening BIGINT;
  v_closing BIGINT;
  v_total BIGINT;
  v_lines JSONB;
BEGIN
  IF p_owner_type NOT IN ('user', 'group') OR p_from > p_to
    OR p_cutoff > NOW() OR p_offset < 0 OR p_limit NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'Invalid statement request';
  END IF;

  SELECT * INTO v_account
  FROM financial_accounts
  WHERE organization_id = p_organization_id
    AND owner_type = p_owner_type
    AND owner_id = p_owner_id
    AND currency = upper(p_currency)
    AND account_class = 'liability'
  ORDER BY created_at, id
  LIMIT 1;
  IF v_account.id IS NULL THEN RAISE EXCEPTION 'Statement account not found'; END IF;

  SELECT COALESCE(sum(CASE
    WHEN line.side = v_account.normal_side THEN line.amount_minor
    ELSE -line.amount_minor END), 0)::BIGINT
  INTO v_opening
  FROM journal_lines line
  JOIN journal_entries entry ON entry.id = line.journal_entry_id
  WHERE line.account_id = v_account.id
    AND entry.effective_date < p_from
    AND entry.posted_at <= p_cutoff;

  SELECT v_opening + COALESCE(sum(CASE
    WHEN preceding.side = v_account.normal_side THEN preceding.amount_minor
    ELSE -preceding.amount_minor END), 0)::BIGINT
  INTO v_page_opening
  FROM (
    SELECT line.side, line.amount_minor
    FROM journal_lines line
    JOIN journal_entries entry ON entry.id = line.journal_entry_id
    WHERE line.account_id = v_account.id
      AND entry.effective_date BETWEEN p_from AND p_to
      AND entry.posted_at <= p_cutoff
    ORDER BY entry.effective_date, entry.posted_at, line.line_number, line.id
    LIMIT p_offset
  ) preceding;

  SELECT v_opening + COALESCE(sum(CASE
    WHEN line.side = v_account.normal_side THEN line.amount_minor
    ELSE -line.amount_minor END), 0)::BIGINT
  INTO v_closing
  FROM journal_lines line
  JOIN journal_entries entry ON entry.id = line.journal_entry_id
  WHERE line.account_id = v_account.id
    AND entry.effective_date BETWEEN p_from AND p_to
    AND entry.posted_at <= p_cutoff;

  SELECT count(*) INTO v_total
  FROM journal_lines line
  JOIN journal_entries entry ON entry.id = line.journal_entry_id
  WHERE line.account_id = v_account.id
    AND entry.effective_date BETWEEN p_from AND p_to
    AND entry.posted_at <= p_cutoff;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', page.id,
    'journalEntryId', page.journal_entry_id,
    'effectiveDate', page.effective_date,
    'postedAt', page.posted_at,
    'description', page.description,
    'sourceDomain', page.source_domain,
    'sourceRecordId', page.source_record_id,
    'correlationId', page.correlation_id,
    'side', page.side,
    'amountMinor', page.amount_minor::TEXT,
    'memo', page.memo
  ) ORDER BY page.effective_date, page.posted_at, page.line_number, page.id), '[]'::JSONB)
  INTO v_lines
  FROM (
    SELECT line.*, entry.effective_date, entry.posted_at, entry.description,
      entry.source_domain, entry.source_record_id, entry.correlation_id
    FROM journal_lines line
    JOIN journal_entries entry ON entry.id = line.journal_entry_id
    WHERE line.account_id = v_account.id
      AND entry.effective_date BETWEEN p_from AND p_to
      AND entry.posted_at <= p_cutoff
    ORDER BY entry.effective_date, entry.posted_at, line.line_number, line.id
    OFFSET p_offset LIMIT p_limit
  ) page;

  RETURN jsonb_build_object(
    'account', jsonb_build_object(
      'id', v_account.id, 'name', v_account.name, 'currency', v_account.currency,
      'normalSide', v_account.normal_side
    ),
    'openingBalanceMinor', v_opening::TEXT,
    'pageOpeningBalanceMinor', v_page_opening::TEXT,
    'closingBalanceMinor', v_closing::TEXT,
    'lines', v_lines,
    'total', v_total
  );
END;
$$;

REVOKE ALL ON FUNCTION read_financial_statement(UUID, TEXT, UUID, TEXT, DATE, DATE, TIMESTAMPTZ, INTEGER, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION read_financial_statement(UUID, TEXT, UUID, TEXT, DATE, DATE, TIMESTAMPTZ, INTEGER, INTEGER) TO service_role;
