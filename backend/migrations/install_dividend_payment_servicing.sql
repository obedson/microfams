-- DIV-04 internal wallet credit servicing for approved dividend payables.
SET search_path=public,extensions;
ALTER TABLE dividend_distributions ADD COLUMN paid_by UUID REFERENCES users(id) ON DELETE SET NULL,ADD COLUMN paid_at TIMESTAMPTZ,ADD COLUMN payment_journal_ids JSONB CHECK(payment_journal_ids IS NULL OR jsonb_typeof(payment_journal_ids)='array'),
 ADD CONSTRAINT dividend_distribution_paid_evidence CHECK((state IN('calculated','reviewed','approved','payable') AND paid_by IS NULL AND paid_at IS NULL AND payment_journal_ids IS NULL) OR (state IN('paying','paid','corrected') AND paid_by IS NOT NULL AND paid_at IS NOT NULL AND payment_journal_ids IS NOT NULL));
ALTER TABLE dividend_distribution_events DROP CONSTRAINT dividend_distribution_events_event_type_check;
ALTER TABLE dividend_distribution_events ADD CONSTRAINT dividend_distribution_events_event_type_check CHECK(event_type IN('DISTRIBUTION_REVIEWED','DISTRIBUTION_APPROVED','DISTRIBUTION_PAYABLE_RECOGNIZED','DISTRIBUTION_PAID'));
CREATE OR REPLACE FUNCTION protect_dividend_snapshot() RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$
BEGIN
 IF TG_TABLE_NAME='dividend_entitlements' THEN RAISE EXCEPTION 'DIVIDEND_SNAPSHOT_IMMUTABLE'; END IF;
 IF TG_TABLE_NAME='dividend_distributions' AND TG_OP='UPDATE' AND current_setting('microfams.dividend_engine',TRUE)='on'
  AND (OLD.state='calculated' AND NEW.state='reviewed' OR OLD.state='reviewed' AND NEW.state='approved' OR OLD.state='approved' AND NEW.state='payable' AND NEW.payable_journal_entry_id IS NOT NULL AND NEW.payable_recognized_by IS NOT NULL AND NEW.payable_recognized_at IS NOT NULL OR OLD.state='payable' AND NEW.state='paid' AND NEW.paid_by IS NOT NULL AND NEW.paid_at IS NOT NULL AND NEW.payment_journal_ids IS NOT NULL)
  AND (to_jsonb(OLD)-ARRAY['state','reviewed_by','reviewed_at','review_reason','approved_by','approved_at','payable_journal_entry_id','payable_recognized_by','payable_recognized_at','paid_by','paid_at','payment_journal_ids'])=(to_jsonb(NEW)-ARRAY['state','reviewed_by','reviewed_at','review_reason','approved_by','approved_at','payable_journal_entry_id','payable_recognized_by','payable_recognized_at','paid_by','paid_at','payment_journal_ids']) THEN RETURN NEW; END IF;
 RAISE EXCEPTION 'DIVIDEND_SNAPSHOT_IMMUTABLE';
END $$;
CREATE OR REPLACE FUNCTION pay_dividend_distribution(p_organization UUID,p_actor UUID,p_distribution UUID,p_effective_date DATE,p_correlation UUID,p_at TIMESTAMPTZ DEFAULT NOW()) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE distribution dividend_distributions; payable financial_accounts; entitlement RECORD; wallet financial_accounts; journal UUID; journal_ids JSONB:='[]'::JSONB; amount BIGINT:=0;
BEGIN
 IF NOT has_financial_permission(p_organization,p_actor,'financial.accounting.post') THEN RAISE EXCEPTION 'DIVIDEND_PAYMENT_PERMISSION_DENIED'; END IF;
 IF p_effective_date IS NULL OR p_correlation IS NULL OR p_at IS NULL OR p_at>clock_timestamp() THEN RAISE EXCEPTION 'DIVIDEND_PAYMENT_REQUEST_INVALID'; END IF;
 SELECT * INTO distribution FROM dividend_distributions WHERE id=p_distribution AND organization_id=p_organization FOR UPDATE;
 IF distribution.id IS NULL OR distribution.state NOT IN('payable','paid') THEN RAISE EXCEPTION 'DIVIDEND_PAYMENT_STATE_INVALID'; END IF;
 IF distribution.state='paid' THEN RETURN jsonb_build_object('distributionId',distribution.id,'state',distribution.state,'journalEntryIds',distribution.payment_journal_ids); END IF;
 IF p_effective_date<distribution.payment_date THEN RAISE EXCEPTION 'DIVIDEND_PAYMENT_DATE_INVALID'; END IF;
 SELECT * INTO payable FROM financial_accounts WHERE organization_id=p_organization AND currency=distribution.currency AND purpose='dividends_payable' AND owner_type IN('organization','system') AND owner_id IS NULL AND status='active' LIMIT 1;
 IF payable.id IS NULL THEN RAISE EXCEPTION 'DIVIDEND_PAYMENT_ACCOUNT_INVALID'; END IF;
 IF NOT EXISTS(SELECT 1 FROM accounting_periods WHERE organization_id=p_organization AND status='open' AND p_effective_date BETWEEN starts_on AND ends_on) THEN RAISE EXCEPTION 'DIVIDEND_PAYMENT_PERIOD_INVALID'; END IF;
 FOR entitlement IN SELECT * FROM dividend_entitlements WHERE distribution_id=distribution.id ORDER BY member_id LOOP
  SELECT * INTO wallet FROM financial_accounts WHERE organization_id=p_organization AND owner_type='user' AND owner_id=entitlement.member_id AND currency=distribution.currency AND purpose='individual_wallet_funds' AND status='active' ORDER BY effective_from DESC,created_at DESC LIMIT 1;
  IF wallet.id IS NULL THEN RAISE EXCEPTION 'DIVIDEND_PAYMENT_WALLET_INVALID'; END IF;
  journal:=post_financial_journal(p_organization,distribution.currency,p_effective_date,'dividend.payment',entitlement.id::TEXT,'dividend-payment-'||entitlement.id::TEXT,encode(digest(entitlement.id::TEXT,'sha256'),'hex'),p_correlation,'Credit dividend entitlement',p_actor,jsonb_build_array(jsonb_build_object('account_id',payable.id,'line_number',1,'side','debit','amount_minor',entitlement.gross_minor),jsonb_build_object('account_id',wallet.id,'line_number',2,'side','credit','amount_minor',entitlement.gross_minor)));
  journal_ids:=journal_ids||jsonb_build_array(journal); amount:=amount+entitlement.gross_minor;
 END LOOP;
 PERFORM set_config('microfams.dividend_engine','on',TRUE); UPDATE dividend_distributions SET state='paid',paid_by=p_actor,paid_at=p_at,payment_journal_ids=journal_ids WHERE id=distribution.id;
 INSERT INTO dividend_distribution_events(organization_id,distribution_id,actor_id,event_type,from_state,to_state,evidence,occurred_at) VALUES(p_organization,distribution.id,p_actor,'DISTRIBUTION_PAID','payable','paid',jsonb_build_object('journal_entry_ids',journal_ids,'paid_minor',amount),p_at);
 RETURN jsonb_build_object('distributionId',distribution.id,'state','paid','journalEntryIds',journal_ids,'paidMinor',amount::TEXT);
END $$;
REVOKE ALL ON FUNCTION pay_dividend_distribution(UUID,UUID,UUID,DATE,UUID,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION pay_dividend_distribution(UUID,UUID,UUID,DATE,UUID,TIMESTAMPTZ) TO service_role;
