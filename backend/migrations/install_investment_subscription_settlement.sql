-- INV-04: bind pending subscription intents to verified provider settlements.
SET search_path=public,extensions;

ALTER TABLE investment_subscription_intents DROP CONSTRAINT investment_subscription_intents_state_check;
ALTER TABLE investment_subscription_intents ADD CONSTRAINT investment_subscription_intents_state_check CHECK(state IN ('pending','settled','cancelled','expired'));

CREATE TABLE investment_subscription_settlements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL,
  subscription_id UUID NOT NULL, settlement_id UUID NOT NULL, amount_minor BIGINT NOT NULL CHECK(amount_minor>0), currency VARCHAR(3) NOT NULL CHECK(currency~'^[A-Z]{3}$'),
  idempotency_key TEXT NOT NULL CHECK(length(idempotency_key) BETWEEN 8 AND 160), request_hash VARCHAR(64) NOT NULL CHECK(request_hash~'^[a-f0-9]{64}$'), correlation_id UUID NOT NULL, settled_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL, FOREIGN KEY(subscription_id,organization_id) REFERENCES investment_subscription_intents(id,organization_id), FOREIGN KEY(settlement_id) REFERENCES settlements(id), UNIQUE(organization_id,subscription_id), UNIQUE(settlement_id), UNIQUE(organization_id,idempotency_key)
);

UPDATE organization_memberships
SET permissions=ARRAY(SELECT DISTINCT permission FROM unnest(COALESCE(permissions,'{}')||ARRAY['financial.investments.service_existing']) permission)
WHERE role='owner';

CREATE OR REPLACE FUNCTION protect_investment_subscription_settlement() RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$
BEGIN IF current_setting('microfams.investment_subscription_engine',TRUE)<>'on' THEN RAISE EXCEPTION 'Investment subscription settlement evidence is immutable outside the engine'; END IF; RETURN COALESCE(NEW,OLD); END $$;
CREATE TRIGGER investment_subscription_settlements_engine_only BEFORE INSERT OR UPDATE OR DELETE ON investment_subscription_settlements FOR EACH ROW EXECUTE FUNCTION protect_investment_subscription_settlement();

CREATE OR REPLACE FUNCTION settle_investment_subscription(p_organization UUID,p_actor UUID,p_subscription UUID,p_settlement UUID,p_correlation UUID,p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE i investment_subscription_intents; s settlements; e investment_subscription_settlements; h TEXT;
BEGIN
 IF NOT has_financial_permission(p_organization,p_actor,'financial.investments.service_existing') THEN RAISE EXCEPTION 'Missing financial.investments.service_existing permission'; END IF;
 IF p_subscription IS NULL OR p_settlement IS NULL OR p_correlation IS NULL OR length(COALESCE(p_idempotency_key,'')) NOT BETWEEN 8 AND 160 OR p_at IS NULL THEN RAISE EXCEPTION 'Investment subscription settlement command is invalid'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',p_organization,p_actor,p_subscription,p_settlement,p_correlation,p_idempotency_key),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':investment-subscription-settlement:'||p_idempotency_key,0));
 SELECT * INTO e FROM investment_subscription_settlements WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
 IF e.id IS NOT NULL THEN IF e.request_hash<>h THEN RAISE EXCEPTION 'Idempotency key reused with different investment settlement facts'; END IF; SELECT * INTO i FROM investment_subscription_intents WHERE id=e.subscription_id AND organization_id=p_organization; RETURN jsonb_build_object('subscription',to_jsonb(i),'settlement',to_jsonb(e)); END IF;
 SELECT * INTO i FROM investment_subscription_intents WHERE id=p_subscription AND organization_id=p_organization FOR UPDATE;
 SELECT * INTO s FROM settlements WHERE id=p_settlement AND organization_id=p_organization FOR SHARE;
 IF i.id IS NULL OR i.state<>'pending' THEN RAISE EXCEPTION 'Investment subscription is not pending'; END IF;
 IF s.id IS NULL OR s.state NOT IN ('posted','reconciled') OR s.journal_entry_id IS NULL OR s.currency<>i.currency OR s.gross_amount_minor<>i.requested_amount_minor THEN RAISE EXCEPTION 'Provider settlement does not match subscription'; END IF;
 PERFORM set_config('microfams.investment_subscription_engine','on',TRUE);
 UPDATE investment_subscription_intents SET state='settled' WHERE id=i.id RETURNING * INTO i;
 INSERT INTO investment_subscription_settlements(organization_id,subscription_id,settlement_id,amount_minor,currency,idempotency_key,request_hash,correlation_id,settled_at,created_at) VALUES(p_organization,i.id,s.id,s.gross_amount_minor,s.currency,p_idempotency_key,h,p_correlation,p_at,p_at) RETURNING * INTO e;
 INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at) VALUES(p_organization,p_actor,'INVESTMENT_SUBSCRIPTION_SETTLED','investment_subscription_intent',i.id::TEXT,jsonb_build_object('settlement_id',s.id,'journal_entry_id',s.journal_entry_id,'amount_minor',s.gross_amount_minor,'state','settled'),p_at);
 RETURN jsonb_build_object('subscription',to_jsonb(i),'settlement',to_jsonb(e));
END $$;

ALTER TABLE investment_subscription_settlements ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON investment_subscription_settlements FROM anon,authenticated; REVOKE INSERT,UPDATE,DELETE ON investment_subscription_settlements FROM service_role; GRANT SELECT ON investment_subscription_settlements TO service_role;
REVOKE ALL ON FUNCTION settle_investment_subscription(UUID,UUID,UUID,UUID,UUID,TEXT,TIMESTAMPTZ) FROM PUBLIC; GRANT EXECUTE ON FUNCTION settle_investment_subscription(UUID,UUID,UUID,UUID,UUID,TEXT,TIMESTAMPTZ) TO service_role;
