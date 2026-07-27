\set ON_ERROR_STOP on

BEGIN;

INSERT INTO users(id, email, password, name, role) VALUES
  ('60000000-0000-4000-8000-000000000001', 'statement-owner@example.test', 'synthetic', 'Statement Owner', 'farmer');
INSERT INTO organizations(id, name, slug, type, created_by) VALUES
  ('60000000-0000-4000-8000-000000000010', 'Statement Tenant', 'statement-tenant', 'farm_business', '60000000-0000-4000-8000-000000000001'),
  ('60000000-0000-4000-8000-000000000110', 'Other Statement Tenant', 'other-statement-tenant', 'cooperative', '60000000-0000-4000-8000-000000000001');
INSERT INTO organization_memberships(organization_id, user_id, role, status) VALUES
  ('60000000-0000-4000-8000-000000000010', '60000000-0000-4000-8000-000000000001', 'owner', 'active'),
  ('60000000-0000-4000-8000-000000000110', '60000000-0000-4000-8000-000000000001', 'owner', 'active');
INSERT INTO accounting_periods(organization_id, name, starts_on, ends_on) VALUES
  ('60000000-0000-4000-8000-000000000010', '2026', '2026-01-01', '2026-12-31'),
  ('60000000-0000-4000-8000-000000000110', '2026', '2026-01-01', '2026-12-31');
INSERT INTO financial_accounts(
  id, organization_id, code, name, account_class, normal_side, currency, owner_type, owner_id
) VALUES
  ('60000000-0000-4000-8000-000000000020', '60000000-0000-4000-8000-000000000010',
    'WALLET.TEST', 'Statement wallet', 'liability', 'credit', 'NGN', 'user',
    '60000000-0000-4000-8000-000000000001'),
  ('60000000-0000-4000-8000-000000000021', '60000000-0000-4000-8000-000000000010',
    'CLEARING.TEST', 'Statement clearing', 'asset', 'debit', 'NGN', 'system', NULL),
  ('60000000-0000-4000-8000-000000000022', '60000000-0000-4000-8000-000000000010',
    'GROUP.TEST', 'Group statement wallet', 'liability', 'credit', 'NGN', 'group',
    '60000000-0000-4000-8000-000000000002'),
  ('60000000-0000-4000-8000-000000000120', '60000000-0000-4000-8000-000000000110',
    'WALLET.OTHER', 'Other tenant wallet', 'liability', 'credit', 'NGN', 'user',
    '60000000-0000-4000-8000-000000000001'),
  ('60000000-0000-4000-8000-000000000121', '60000000-0000-4000-8000-000000000110',
    'CLEARING.OTHER', 'Other tenant clearing', 'asset', 'debit', 'NGN', 'system', NULL);

SELECT post_financial_journal(
  '60000000-0000-4000-8000-000000000010', 'NGN', '2026-06-30', 'statement.test',
  'opening', 'statement-opening', repeat('a', 64), '60000000-0000-4000-8000-000000000030',
  'Opening funding', '60000000-0000-4000-8000-000000000001',
  '[{"account_id":"60000000-0000-4000-8000-000000000021","line_number":1,"side":"debit","amount_minor":10000},{"account_id":"60000000-0000-4000-8000-000000000020","line_number":2,"side":"credit","amount_minor":10000}]'
);
SELECT post_financial_journal(
  '60000000-0000-4000-8000-000000000010', 'NGN', '2026-07-01', 'statement.test',
  'credit', 'statement-credit', repeat('b', 64), '60000000-0000-4000-8000-000000000031',
  'Period funding', '60000000-0000-4000-8000-000000000001',
  '[{"account_id":"60000000-0000-4000-8000-000000000021","line_number":1,"side":"debit","amount_minor":2500},{"account_id":"60000000-0000-4000-8000-000000000020","line_number":2,"side":"credit","amount_minor":2500}]'
);
SELECT post_financial_journal(
  '60000000-0000-4000-8000-000000000010', 'NGN', '2026-07-02', 'statement.test',
  'debit', 'statement-debit', repeat('c', 64), '60000000-0000-4000-8000-000000000032',
  'Period transfer', '60000000-0000-4000-8000-000000000001',
  '[{"account_id":"60000000-0000-4000-8000-000000000020","line_number":1,"side":"debit","amount_minor":1000},{"account_id":"60000000-0000-4000-8000-000000000021","line_number":2,"side":"credit","amount_minor":1000}]'
);

SELECT post_financial_journal(
  '60000000-0000-4000-8000-000000000010', 'NGN', '2026-07-03', 'statement.test',
  'group-credit', 'statement-group-credit', repeat('d', 64), '60000000-0000-4000-8000-000000000033',
  'Group funding', '60000000-0000-4000-8000-000000000001',
  '[{"account_id":"60000000-0000-4000-8000-000000000021","line_number":1,"side":"debit","amount_minor":3000},{"account_id":"60000000-0000-4000-8000-000000000022","line_number":2,"side":"credit","amount_minor":3000}]'
);
SELECT post_financial_journal(
  '60000000-0000-4000-8000-000000000110', 'NGN', '2026-07-01', 'statement.test',
  'other-credit', 'statement-other-credit', repeat('e', 64), '60000000-0000-4000-8000-000000000130',
  'Other tenant funding', '60000000-0000-4000-8000-000000000001',
  '[{"account_id":"60000000-0000-4000-8000-000000000121","line_number":1,"side":"debit","amount_minor":9999},{"account_id":"60000000-0000-4000-8000-000000000120","line_number":2,"side":"credit","amount_minor":9999}]'
);

DO $$
DECLARE result JSONB;
BEGIN
  result := read_financial_statement(
    '60000000-0000-4000-8000-000000000010', 'user',
    '60000000-0000-4000-8000-000000000001', 'NGN',
    '2026-07-01', '2026-07-31', NOW(), 1, 1
  );
  IF result->>'openingBalanceMinor' <> '10000'
    OR result->>'pageOpeningBalanceMinor' <> '12500'
    OR result->>'closingBalanceMinor' <> '11500'
    OR result->>'total' <> '2'
    OR jsonb_array_length(result->'lines') <> 1
    OR result->'lines'->0->>'description' <> 'Period transfer' THEN
    RAISE EXCEPTION 'Journal statement totals, ordering, or pagination are incorrect: %', result;
  END IF;
END $$;


DO $$
DECLARE group_result JSONB; other_result JSONB;
BEGIN
  group_result := read_financial_statement(
    '60000000-0000-4000-8000-000000000010', 'group',
    '60000000-0000-4000-8000-000000000002', 'NGN',
    '2026-07-01', '2026-07-31', NOW(), 0, 25
  );
  other_result := read_financial_statement(
    '60000000-0000-4000-8000-000000000110', 'user',
    '60000000-0000-4000-8000-000000000001', 'NGN',
    '2026-07-01', '2026-07-31', NOW(), 0, 25
  );
  IF group_result->>'closingBalanceMinor' <> '3000' OR group_result->>'total' <> '1' THEN
    RAISE EXCEPTION 'Group statement is not owner-type isolated: %', group_result;
  END IF;
  IF other_result->>'closingBalanceMinor' <> '9999' OR other_result->>'total' <> '1' THEN
    RAISE EXCEPTION 'Statement is not tenant-isolated: %', other_result;
  END IF;
END $$;
DO $$
BEGIN
  IF has_function_privilege(
    'authenticated',
    'read_financial_statement(uuid,text,uuid,text,date,date,timestamptz,integer,integer)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'authenticated clients must not execute the statement function directly';
  END IF;
END $$;

ROLLBACK;
