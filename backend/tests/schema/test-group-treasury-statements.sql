BEGIN;
DO $$
DECLARE definition TEXT;
BEGIN
  SELECT pg_get_functiondef('read_group_treasury_statement(UUID,UUID,UUID,TEXT,DATE,DATE,TIMESTAMPTZ,INTEGER,INTEGER)'::regprocedure) INTO definition;
  IF definition NOT LIKE '%journal_lines%' OR definition NOT LIKE '%entry.posted_at<=p_cutoff%'
    OR definition NOT LIKE '%reservation.created_at<=p_cutoff%'
    OR definition NOT LIKE '%GROUP_TREASURY_STATEMENT_NOT_AUTHORIZED%'
    OR definition LIKE '%group_fund_balance%' THEN
    RAISE EXCEPTION 'GT07A statement invariant is incomplete';
  END IF;
END $$;
SELECT 'group treasury statement schema tests passed' AS result;
ROLLBACK;
