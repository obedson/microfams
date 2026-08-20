-- DIV-03 approved distribution payable recognition; payment execution remains disabled.
SET search_path=public,extensions;
ALTER TABLE dividend_distributions ADD COLUMN payable_journal_entry_id UUID UNIQUE REFERENCES journal_entries(id),ADD COLUMN payable_recognized_by UUID REFERENCES users(id) ON DELETE SET NULL,ADD COLUMN payable_recognized_at TIMESTAMPTZ,
 ADD CONSTRAINT dividend_distribution_payable_evidence CHECK((state IN('calculated','reviewed','approved') AND payable_journal_entry_id IS NULL AND payable_recognized_by IS NULL AND payable_recognized_at IS NULL) OR (state IN('payable','paying','paid','corrected') AND payable_journal_entry_id IS NOT NULL AND payable_recognized_by IS NOT NULL AND payable_recognized_at IS NOT NULL));
ALTER TABLE dividend_distribution_events DROP CONSTRAINT dividend_distribution_events_event_type_check;
ALTER TABLE dividend_distribution_events ADD CONSTRAINT dividend_distribution_events_event_type_check CHECK(event_type IN('DISTRIBUTION_REVIEWED','DISTRIBUTION_APPROVED','DISTRIBUTION_PAYABLE_RECOGNIZED'));
CREATE OR REPLACE FUNCTION protect_dividend_snapshot() RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$
BEGIN
 IF TG_TABLE_NAME='dividend_entitlements' THEN RAISE EXCEPTION 'DIVIDEND_SNAPSHOT_IMMUTABLE'; END IF;
 IF TG_TABLE_NAME='dividend_distributions' AND TG_OP='UPDATE' AND current_setting('microfams.dividend_engine',TRUE)='on'
  AND (OLD.state='calculated' AND NEW.state='reviewed' OR OLD.state='reviewed' AND NEW.state='approved' OR OLD.state='approved' AND NEW.state='payable' AND NEW.payable_journal_entry_id IS NOT NULL AND NEW.payable_recognized_by IS NOT NULL AND NEW.payable_recognized_at IS NOT NULL)
  AND (to_jsonb(OLD)-ARRAY['state','reviewed_by','reviewed_at','review_reason','approved_by','approved_at','payable_journal_entry_id','payable_recognized_by','payable_recognized_at'])=(to_jsonb(NEW)-ARRAY['state','reviewed_by','reviewed_at','review_reason','approved_by','approved_at','payable_journal_entry_id','payable_recognized_by','payable_recognized_at']) THEN RETURN NEW; END IF;
 RAISE EXCEPTION 'DIVIDEND_SNAPSHOT_IMMUTABLE';
END $$;
CREATE OR REPLACE FUNCTION recognize_dividend_payable(p_organization UUID,p_actor UUID,p_distribution UUID,p_retained_surplus_account UUID,p_dividends_payable_account UUID,p_effective_date DATE,p_idempotency_key TEXT,p_correlation UUID,p_at TIMESTAMPTZ DEFAULT NOW()) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE distribution dividend_distributions; retained financial_accounts; payable financial_accounts; journal UUID; h TEXT;
BEGIN
 IF NOT has_financial_permission(p_organization,p_actor,'financial.accounting.post') THEN RAISE EXCEPTION 'DIVIDEND_PAYABLE_PERMISSION_DENIED'; END IF;
 IF p_effective_date IS NULL OR p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 160 OR p_correlation IS NULL OR p_at IS NULL OR p_at>clock_timestamp() THEN RAISE EXCEPTION 'DIVIDEND_PAYABLE_REQUEST_INVALID'; END IF;
 SELECT * INTO distribution FROM dividend_distributions WHERE id=p_distribution AND organization_id=p_organization FOR UPDATE;
 IF distribution.id IS NULL OR distribution.state NOT IN('approved','payable') THEN RAISE EXCEPTION 'DIVIDEND_PAYABLE_STATE_INVALID'; END IF;
 IF distribution.state='payable' THEN RETURN distribution.payable_journal_entry_id; END IF;
 IF NOT EXISTS(SELECT 1 FROM accounting_periods WHERE organization_id=p_organization AND status='open' AND p_effective_date BETWEEN starts_on AND ends_on) THEN RAISE EXCEPTION 'DIVIDEND_PAYABLE_PERIOD_INVALID'; END IF;
 SELECT * INTO retained FROM financial_accounts WHERE id=p_retained_surplus_account AND organization_id=p_organization AND currency=distribution.currency AND purpose='retained_surplus' AND owner_type='organization' AND owner_id IS NULL AND status='active';
 SELECT * INTO payable FROM financial_accounts WHERE id=p_dividends_payable_account AND organization_id=p_organization AND currency=distribution.currency AND purpose='dividends_payable' AND owner_type IN('organization','system') AND owner_id IS NULL AND status='active';
 IF retained.id IS NULL OR payable.id IS NULL OR retained.id=payable.id THEN RAISE EXCEPTION 'DIVIDEND_PAYABLE_ACCOUNT_INVALID'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',p_organization,p_distribution,p_retained_surplus_account,p_dividends_payable_account,p_effective_date,distribution.allocated_minor),'UTF8'),'sha256'),'hex');
 journal:=post_financial_journal(p_organization,distribution.currency,p_effective_date,'dividend.payable',distribution.id::TEXT,p_idempotency_key,h,p_correlation,'Recognize approved dividend payable',p_actor,jsonb_build_array(jsonb_build_object('account_id',retained.id,'line_number',1,'side','debit','amount_minor',distribution.allocated_minor),jsonb_build_object('account_id',payable.id,'line_number',2,'side','credit','amount_minor',distribution.allocated_minor)));
 PERFORM set_config('microfams.dividend_engine','on',TRUE); UPDATE dividend_distributions SET state='payable',payable_journal_entry_id=journal,payable_recognized_by=p_actor,payable_recognized_at=p_at WHERE id=distribution.id;
 INSERT INTO dividend_distribution_events(organization_id,distribution_id,actor_id,event_type,from_state,to_state,evidence,occurred_at) VALUES(p_organization,distribution.id,p_actor,'DISTRIBUTION_PAYABLE_RECOGNIZED','approved','payable',jsonb_build_object('journal_entry_id',journal,'recognized_minor',distribution.allocated_minor,'rounding_residual_minor',distribution.rounding_residual_minor),p_at);
 RETURN journal;
END $$;
REVOKE ALL ON FUNCTION recognize_dividend_payable(UUID,UUID,UUID,UUID,UUID,DATE,TEXT,UUID,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION recognize_dividend_payable(UUID,UUID,UUID,UUID,UUID,DATE,TEXT,UUID,TIMESTAMPTZ) TO service_role;
