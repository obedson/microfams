-- INV-02 database contract: disclosure-bound pending intents without money or units.
SET search_path=public,extensions;
BEGIN;
DO $$
DECLARE
  org UUID; maker UUID; checker UUID; outsider UUID;
  product UUID; version_id UUID; intent_id UUID; replay_id UUID;
  result JSONB; facts JSONB; failed BOOLEAN; journal_count BIGINT;
  requested_at TIMESTAMPTZ := '2026-09-15T12:00:00Z';
BEGIN
  SELECT organization_id,user_id INTO org,maker
  FROM organization_memberships
  WHERE role='owner' AND status='active'
  ORDER BY created_at LIMIT 1;

  INSERT INTO users(email,password,name,role)
  VALUES('inv02-checker-'||gen_random_uuid()||'@example.test','test','INV-02 Checker','farmer')
  RETURNING id INTO checker;
  INSERT INTO organization_memberships(organization_id,user_id,role,permissions,status,joined_at)
  VALUES(org,checker,'finance_manager',ARRAY['financial.investments.configure'],'active',NOW());

  INSERT INTO users(email,password,name,role)
  VALUES('inv02-outsider-'||gen_random_uuid()||'@example.test','test','INV-02 Outsider','farmer')
  RETURNING id INTO outsider;

  facts:=jsonb_build_object(
    'issuerName','Farm Project Issuer',
    'operatorName','Licensed Investment Operator',
    'underlyingReference','farm-project-inv02',
    'fundingTargetMinor',10000000,
    'minimumSubscriptionMinor',100000,
    'maximumSubscriptionMinor',2000000,
    'offerOpensAt','2026-09-01T00:00:00Z',
    'offerClosesAt','2026-09-30T00:00:00Z',
    'unitMethod','fixed_unit_price',
    'unitPriceMinor',10000,
    'oversubscriptionPolicy','pro_rata',
    'fees','[]'::JSONB,
    'expectedReturnDisclosure','Expected returns are estimates and are not guaranteed.',
    'lossAllocationRule',jsonb_build_object('method','pro_rata_units'),
    'reportingSchedule',jsonb_build_object('frequency','quarterly'),
    'maturityAt','2027-09-30T00:00:00Z',
    'exitRules',jsonb_build_object('earlyExit',FALSE),
    'jurisdictionEligibility',jsonb_build_object(
      'countries',jsonb_build_array('NG'),
      'investorTypes',jsonb_build_array('individual')
    ),
    'riskDisclosureVersion','INV-02.1',
    'riskDisclosureHash',repeat('b',64),
    'conflictsDisclosure','The operator discloses all related-party interests.'
  );

  result:=create_investment_product_draft(
    org,maker,'INV.FARM.02','INV-02 farm expansion units','NGN',facts,
    'inv02-product-create','2026-08-13T18:00:00Z'
  );
  product:=(result->'product'->>'id')::UUID;
  PERFORM submit_investment_product(org,maker,product,1,'inv02-product-submit','2026-08-13T18:01:00Z');
  result:=approve_investment_product(org,checker,product,1,'inv02-product-approve','2026-08-13T18:02:00Z');
  version_id:=(result->'version'->>'id')::UUID;

  SELECT count(*) INTO journal_count FROM journal_entries WHERE organization_id=org;
  result:=create_investment_subscription_intent(
    org,maker,product,500000,'NG','individual','INV-02.1',repeat('b',64),
    '00000000-0000-4000-8000-000000000201','inv02-subscribe-001',requested_at
  );
  intent_id:=(result->'subscription'->>'id')::UUID;
  IF intent_id IS NULL
    OR result->'subscription'->>'state'<>'pending'
    OR (result->'subscription'->>'product_id')::UUID<>product
    OR (result->'subscription'->>'product_version_id')::UUID<>version_id
    OR result->'subscription'->>'accepted_risk_disclosure_version'<>'INV-02.1'
    OR result->'subscription'->>'accepted_risk_disclosure_hash'<>repeat('b',64)
  THEN RAISE EXCEPTION 'INV02: pending intent did not pin approved disclosure evidence'; END IF;

  replay_id:=(create_investment_subscription_intent(
    org,maker,product,500000,'NG','individual','INV-02.1',repeat('b',64),
    '00000000-0000-4000-8000-000000000201','inv02-subscribe-001',requested_at
  )->'subscription'->>'id')::UUID;
  IF replay_id<>intent_id THEN RAISE EXCEPTION 'INV02: idempotent replay created different evidence'; END IF;

  IF (SELECT count(*) FROM journal_entries WHERE organization_id=org)<>journal_count
    OR to_regclass('public.investment_units') IS NOT NULL
    OR to_regclass('public.investment_allocations') IS NOT NULL
  THEN RAISE EXCEPTION 'INV02: intent created forbidden money or allocation artifacts'; END IF;

  failed:=FALSE;
  BEGIN
    PERFORM create_investment_subscription_intent(org,maker,product,500000,'NG','individual','INV-02.1',repeat('c',64),'00000000-0000-4000-8000-000000000202','inv02-bad-disclosure',requested_at);
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%risk disclosure%' THEN failed:=TRUE; END IF; END;
  IF NOT failed THEN RAISE EXCEPTION 'INV02: wrong disclosure was accepted'; END IF;

  failed:=FALSE;
  BEGIN
    PERFORM create_investment_subscription_intent(org,maker,product,99999,'NG','individual','INV-02.1',repeat('b',64),'00000000-0000-4000-8000-000000000203','inv02-bad-amount',requested_at);
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%outside product limits%' THEN failed:=TRUE; END IF; END;
  IF NOT failed THEN RAISE EXCEPTION 'INV02: out-of-range amount was accepted'; END IF;

  failed:=FALSE;
  BEGIN
    PERFORM create_investment_subscription_intent(org,maker,product,500000,'GH','individual','INV-02.1',repeat('b',64),'00000000-0000-4000-8000-000000000204','inv02-bad-country',requested_at);
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%not eligible%' THEN failed:=TRUE; END IF; END;
  IF NOT failed THEN RAISE EXCEPTION 'INV02: wrong country was accepted'; END IF;

  failed:=FALSE;
  BEGIN
    PERFORM create_investment_subscription_intent(org,maker,product,500000,'NG','group','INV-02.1',repeat('b',64),'00000000-0000-4000-8000-000000000205','inv02-bad-type',requested_at);
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%not eligible%' THEN failed:=TRUE; END IF; END;
  IF NOT failed THEN RAISE EXCEPTION 'INV02: wrong investor type was accepted'; END IF;

  failed:=FALSE;
  BEGIN
    PERFORM create_investment_subscription_intent(org,outsider,product,500000,'NG','individual','INV-02.1',repeat('b',64),'00000000-0000-4000-8000-000000000206','inv02-outsider-001',requested_at);
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%Missing financial.investments.subscribe permission%' THEN failed:=TRUE; END IF; END;
  IF NOT failed THEN RAISE EXCEPTION 'INV02: outsider crossed tenant authorization'; END IF;

  IF has_table_privilege('service_role','public.investment_subscription_intents','INSERT')
    OR has_table_privilege('service_role','public.investment_subscription_intents','UPDATE')
    OR has_table_privilege('service_role','public.investment_subscription_intents','DELETE')
  THEN RAISE EXCEPTION 'INV02: service role can mutate intent evidence directly'; END IF;
END $$;
ROLLBACK;
SELECT 'investment subscription intent schema tests passed' AS result;
