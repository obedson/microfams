-- DIV-02 maker-checker review and approval; no payable recognition or payment.
SET search_path=public,extensions;
ALTER TABLE dividend_distributions ADD COLUMN reviewed_by UUID REFERENCES users(id) ON DELETE SET NULL,ADD COLUMN reviewed_at TIMESTAMPTZ,ADD COLUMN review_reason TEXT CHECK(review_reason IS NULL OR length(btrim(review_reason)) BETWEEN 8 AND 500),ADD COLUMN approved_by UUID REFERENCES users(id) ON DELETE SET NULL,ADD COLUMN approved_at TIMESTAMPTZ,
 ADD CONSTRAINT dividend_distribution_review_evidence CHECK((state='calculated' AND reviewed_by IS NULL AND reviewed_at IS NULL AND review_reason IS NULL AND approved_by IS NULL AND approved_at IS NULL) OR (state='reviewed' AND reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL AND review_reason IS NOT NULL AND approved_by IS NULL AND approved_at IS NULL) OR (state IN('approved','payable','paying','paid','corrected') AND reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL AND review_reason IS NOT NULL AND approved_by IS NOT NULL AND approved_at IS NOT NULL AND approved_by<>reviewed_by AND approved_by<>created_by AND reviewed_by<>created_by));
CREATE TABLE dividend_distribution_events(id UUID PRIMARY KEY DEFAULT gen_random_uuid(),organization_id UUID NOT NULL REFERENCES organizations(id),distribution_id UUID NOT NULL REFERENCES dividend_distributions(id) ON DELETE RESTRICT,actor_id UUID REFERENCES users(id) ON DELETE SET NULL,event_type TEXT NOT NULL CHECK(event_type IN('DISTRIBUTION_REVIEWED','DISTRIBUTION_APPROVED')),from_state TEXT NOT NULL,to_state TEXT NOT NULL,evidence JSONB NOT NULL CHECK(jsonb_typeof(evidence)='object'),occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW());
CREATE OR REPLACE FUNCTION protect_dividend_snapshot() RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$
BEGIN
 IF TG_TABLE_NAME='dividend_entitlements' THEN RAISE EXCEPTION 'DIVIDEND_SNAPSHOT_IMMUTABLE'; END IF;
 IF TG_TABLE_NAME='dividend_distributions' AND TG_OP='UPDATE' AND current_setting('microfams.dividend_engine',TRUE)='on' AND (OLD.state='calculated' AND NEW.state='reviewed' OR OLD.state='reviewed' AND NEW.state='approved') AND (to_jsonb(OLD)-ARRAY['state','reviewed_by','reviewed_at','review_reason','approved_by','approved_at'])=(to_jsonb(NEW)-ARRAY['state','reviewed_by','reviewed_at','review_reason','approved_by','approved_at']) THEN RETURN NEW; END IF;
 RAISE EXCEPTION 'DIVIDEND_SNAPSHOT_IMMUTABLE';
END $$;
CREATE OR REPLACE FUNCTION protect_dividend_distribution_event() RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$ BEGIN RAISE EXCEPTION 'DIVIDEND_EVENT_IMMUTABLE'; END $$;
CREATE TRIGGER dividend_distribution_events_immutable BEFORE UPDATE OR DELETE ON dividend_distribution_events FOR EACH ROW EXECUTE FUNCTION protect_dividend_distribution_event();
CREATE OR REPLACE FUNCTION review_dividend_distribution(p_organization UUID,p_actor UUID,p_distribution UUID,p_reason TEXT,p_at TIMESTAMPTZ DEFAULT NOW()) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE distribution dividend_distributions;
BEGIN
 IF NOT has_financial_permission(p_organization,p_actor,'financial.accounting.post') THEN RAISE EXCEPTION 'DIVIDEND_REVIEW_PERMISSION_DENIED'; END IF;
 IF p_reason IS NULL OR length(btrim(p_reason)) NOT BETWEEN 8 AND 500 OR p_at IS NULL OR p_at>clock_timestamp() THEN RAISE EXCEPTION 'DIVIDEND_REVIEW_REQUEST_INVALID'; END IF;
 SELECT * INTO distribution FROM dividend_distributions WHERE id=p_distribution AND organization_id=p_organization FOR UPDATE;
 IF distribution.id IS NULL OR distribution.state<>'calculated' OR distribution.created_by=p_actor THEN RAISE EXCEPTION 'DIVIDEND_REVIEW_STATE_INVALID'; END IF;
 PERFORM set_config('microfams.dividend_engine','on',TRUE); UPDATE dividend_distributions SET state='reviewed',reviewed_by=p_actor,reviewed_at=p_at,review_reason=btrim(p_reason) WHERE id=p_distribution;
 INSERT INTO dividend_distribution_events(organization_id,distribution_id,actor_id,event_type,from_state,to_state,evidence,occurred_at) VALUES(p_organization,p_distribution,p_actor,'DISTRIBUTION_REVIEWED','calculated','reviewed',jsonb_build_object('reason',btrim(p_reason)),p_at);
 RETURN p_distribution;
END $$;
CREATE OR REPLACE FUNCTION approve_dividend_distribution(p_organization UUID,p_actor UUID,p_distribution UUID,p_at TIMESTAMPTZ DEFAULT NOW()) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE distribution dividend_distributions;
BEGIN
 IF NOT has_financial_permission(p_organization,p_actor,'financial.rules.approve') THEN RAISE EXCEPTION 'DIVIDEND_APPROVAL_PERMISSION_DENIED'; END IF;
 IF p_at IS NULL OR p_at>clock_timestamp() THEN RAISE EXCEPTION 'DIVIDEND_APPROVAL_REQUEST_INVALID'; END IF;
 SELECT * INTO distribution FROM dividend_distributions WHERE id=p_distribution AND organization_id=p_organization FOR UPDATE;
 IF distribution.id IS NULL OR distribution.state<>'reviewed' OR distribution.created_by=p_actor OR distribution.reviewed_by=p_actor THEN RAISE EXCEPTION 'DIVIDEND_APPROVAL_STATE_INVALID'; END IF;
 PERFORM set_config('microfams.dividend_engine','on',TRUE); UPDATE dividend_distributions SET state='approved',approved_by=p_actor,approved_at=p_at WHERE id=p_distribution;
 INSERT INTO dividend_distribution_events(organization_id,distribution_id,actor_id,event_type,from_state,to_state,evidence,occurred_at) VALUES(p_organization,p_distribution,p_actor,'DISTRIBUTION_APPROVED','reviewed','approved',jsonb_build_object('reviewed_by',distribution.reviewed_by,'reviewed_at',distribution.reviewed_at),p_at);
 RETURN p_distribution;
END $$;
REVOKE ALL ON dividend_distribution_events FROM PUBLIC,anon,authenticated,service_role; GRANT SELECT ON dividend_distribution_events TO service_role;
REVOKE ALL ON FUNCTION review_dividend_distribution(UUID,UUID,UUID,TEXT,TIMESTAMPTZ),approve_dividend_distribution(UUID,UUID,UUID,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION review_dividend_distribution(UUID,UUID,UUID,TEXT,TIMESTAMPTZ),approve_dividend_distribution(UUID,UUID,UUID,TIMESTAMPTZ) TO service_role;
