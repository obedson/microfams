-- GT-03A: immutable proposals, voter snapshots, append-only votes, and decisions.
SET search_path = public, extensions;

CREATE TABLE IF NOT EXISTS group_proposals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  proposal_type TEXT NOT NULL CHECK (proposal_type IN (
    'constitution_amendment','membership_action','office_appointment','office_removal',
    'treasury_disbursement','contribution_rule','project','committee_mandate',
    'shared_asset_action','document_publication','group_closure','ordinary'
  )),
  proposer_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  constitution_id UUID NOT NULL REFERENCES group_constitutions(id) ON DELETE RESTRICT,
  public_summary TEXT NOT NULL CHECK (length(trim(public_summary)) BETWEEN 10 AND 500),
  private_evidence_refs JSONB NOT NULL DEFAULT '[]'::JSONB CHECK (jsonb_typeof(private_evidence_refs)='array'),
  execution_payload JSONB NOT NULL DEFAULT '{}'::JSONB CHECK (jsonb_typeof(execution_payload)='object'),
  conflict_user_ids UUID[] NOT NULL DEFAULT '{}',
  state TEXT NOT NULL DEFAULT 'draft' CHECK (state IN (
    'draft','open','approved','rejected','expired','cancelled','executing','executed','execution_failed'
  )),
  state_version INTEGER NOT NULL DEFAULT 1 CHECK (state_version>0),
  opens_at TIMESTAMPTZ NOT NULL,
  closes_at TIMESTAMPTZ NOT NULL,
  opened_at TIMESTAMPTZ,
  decided_at TIMESTAMPTZ,
  result JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (closes_at>opens_at),
  CHECK (result IS NULL OR jsonb_typeof(result)='object')
);
CREATE INDEX IF NOT EXISTS idx_group_proposals_tenant ON group_proposals(organization_id,group_id,state,closes_at);

CREATE TABLE IF NOT EXISTS group_voting_snapshots (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  proposal_id UUID NOT NULL UNIQUE REFERENCES group_proposals(id) ON DELETE RESTRICT,
  constitution_id UUID NOT NULL REFERENCES group_constitutions(id) ON DELETE RESTRICT,
  rule_kind TEXT NOT NULL CHECK (rule_kind IN ('ordinary','special','discipline','treasury')),
  eligible_count INTEGER NOT NULL CHECK (eligible_count>=0),
  excluded_count INTEGER NOT NULL CHECK (excluded_count>=0),
  quorum_bps INTEGER NOT NULL CHECK (quorum_bps BETWEEN 1 AND 10000),
  quorum_count INTEGER NOT NULL CHECK (quorum_count>=0),
  approval_bps INTEGER NOT NULL CHECK (approval_bps BETWEEN 1 AND 10000),
  approval_count INTEGER,
  approval_rule TEXT NOT NULL CHECK (approval_rule IN ('majority_non_abstaining','eligible_threshold')),
  vote_change_allowed BOOLEAN NOT NULL,
  created_at TIMESTAMPTZ NOT NULL
);
CREATE TABLE IF NOT EXISTS group_voter_snapshot_members (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  proposal_id UUID NOT NULL REFERENCES group_proposals(id) ON DELETE RESTRICT,
  snapshot_id UUID NOT NULL REFERENCES group_voting_snapshots(id) ON DELETE RESTRICT,
  member_id UUID NOT NULL REFERENCES group_members(id) ON DELETE RESTRICT,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  eligible BOOLEAN NOT NULL,
  exclusion_reason TEXT,
  created_at TIMESTAMPTZ NOT NULL,
  UNIQUE(snapshot_id,user_id),
  CHECK (eligible=(exclusion_reason IS NULL))
);
CREATE INDEX IF NOT EXISTS idx_group_voter_snapshot_eligible ON group_voter_snapshot_members(snapshot_id,eligible,user_id);

CREATE TABLE IF NOT EXISTS group_vote_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  proposal_id UUID NOT NULL REFERENCES group_proposals(id) ON DELETE RESTRICT,
  snapshot_id UUID NOT NULL REFERENCES group_voting_snapshots(id) ON DELETE RESTRICT,
  voter_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  choice TEXT NOT NULL CHECK (choice IN ('approve','reject','abstain')),
  sequence INTEGER NOT NULL CHECK (sequence>0),
  supersedes_vote_id UUID REFERENCES group_vote_history(id) ON DELETE RESTRICT,
  is_current BOOLEAN NOT NULL DEFAULT TRUE,
  cast_at TIMESTAMPTZ NOT NULL,
  UNIQUE(proposal_id,voter_id,sequence)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_group_current_vote ON group_vote_history(proposal_id,voter_id) WHERE is_current;

CREATE TABLE IF NOT EXISTS group_proposal_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  proposal_id UUID NOT NULL REFERENCES group_proposals(id) ON DELETE RESTRICT,
  actor_id UUID REFERENCES users(id) ON DELETE SET NULL,
  event_type TEXT NOT NULL CHECK (event_type ~ '^[A-Z][A-Z0-9_]{2,63}$'),
  from_state TEXT,
  to_state TEXT,
  resource_id UUID,
  correlation_id UUID NOT NULL,
  evidence JSONB NOT NULL DEFAULT '{}'::JSONB CHECK (jsonb_typeof(evidence)='object'),
  occurred_at TIMESTAMPTZ NOT NULL,
  UNIQUE(organization_id,correlation_id)
);

CREATE OR REPLACE FUNCTION protect_group_proposal_evidence() RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$
BEGIN
  IF current_setting('microfams.group_proposal_engine',TRUE)='on' THEN RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END; END IF;
  RAISE EXCEPTION 'GROUP_PROPOSAL_ENGINE_REQUIRED';
END $$;
DO $$ DECLARE t TEXT; BEGIN FOREACH t IN ARRAY ARRAY['group_proposals','group_voting_snapshots','group_voter_snapshot_members','group_vote_history','group_proposal_events'] LOOP
  EXECUTE format('DROP TRIGGER IF EXISTS protect_group_proposal_evidence ON %I',t);
  EXECUTE format('CREATE TRIGGER protect_group_proposal_evidence BEFORE INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION protect_group_proposal_evidence()',t);
END LOOP; END $$;

CREATE OR REPLACE FUNCTION create_group_proposal(
 p_organization_id UUID,p_group_id UUID,p_actor_id UUID,p_proposal_type TEXT,
 p_public_summary TEXT,p_private_evidence_refs JSONB,p_execution_payload JSONB,
 p_conflict_user_ids UUID[],p_opens_at TIMESTAMPTZ,p_closes_at TIMESTAMPTZ,
 p_correlation_id UUID,p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE g groups; pid UUID; setting TEXT;
BEGIN
 IF p_proposal_type NOT IN ('constitution_amendment','membership_action','office_appointment','office_removal','treasury_disbursement','contribution_rule','project','committee_mandate','shared_asset_action','document_publication','group_closure','ordinary') OR length(trim(COALESCE(p_public_summary,''))) NOT BETWEEN 10 AND 500 OR jsonb_typeof(p_private_evidence_refs)<>'array' OR jsonb_typeof(p_execution_payload)<>'object' OR p_opens_at<p_occurred_at OR p_closes_at<=p_opens_at OR p_correlation_id IS NULL THEN RAISE EXCEPTION 'GROUP_PROPOSAL_COMMAND_INVALID'; END IF;
 SELECT proposal_id INTO pid FROM group_proposal_events WHERE organization_id=p_organization_id AND correlation_id=p_correlation_id; IF FOUND THEN RETURN pid; END IF;
 SELECT * INTO g FROM groups WHERE id=p_group_id AND organization_id=p_organization_id AND lifecycle_state='active'; IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_NOT_ACCEPTING_PROPOSALS'; END IF;
 IF g.current_constitution_id IS NULL OR NOT EXISTS(SELECT 1 FROM group_constitutions WHERE id=g.current_constitution_id AND organization_id=p_organization_id AND group_id=p_group_id AND status='effective') THEN RAISE EXCEPTION 'GROUP_EFFECTIVE_CONSTITUTION_REQUIRED'; END IF;
 IF NOT EXISTS(SELECT 1 FROM group_members WHERE organization_id=p_organization_id AND group_id=p_group_id AND user_id=p_actor_id AND status='active' AND is_active AND payment_status='paid') THEN RAISE EXCEPTION 'GROUP_PROPOSER_NOT_ELIGIBLE'; END IF;
 setting:=current_setting('microfams.group_proposal_engine',TRUE);PERFORM set_config('microfams.group_proposal_engine','on',TRUE);
 INSERT INTO group_proposals(organization_id,group_id,proposal_type,proposer_id,constitution_id,public_summary,private_evidence_refs,execution_payload,conflict_user_ids,opens_at,closes_at,created_at,updated_at) VALUES(p_organization_id,p_group_id,p_proposal_type,p_actor_id,g.current_constitution_id,trim(p_public_summary),p_private_evidence_refs,p_execution_payload,COALESCE(p_conflict_user_ids,'{}'),p_opens_at,p_closes_at,p_occurred_at,p_occurred_at) RETURNING id INTO pid;
 INSERT INTO group_proposal_events(organization_id,group_id,proposal_id,actor_id,event_type,to_state,resource_id,correlation_id,occurred_at) VALUES(p_organization_id,p_group_id,pid,p_actor_id,'PROPOSAL_CREATED','draft',pid,p_correlation_id,p_occurred_at);
 PERFORM set_config('microfams.group_proposal_engine',COALESCE(setting,''),TRUE);RETURN pid;
END $$;

CREATE OR REPLACE FUNCTION open_group_proposal(
 p_organization_id UUID,p_group_id UUID,p_actor_id UUID,p_proposal_id UUID,
 p_expected_version INTEGER,p_correlation_id UUID,p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE p group_proposals; rules JSONB; sid UUID; eligible_count INTEGER; excluded_count INTEGER; qb INTEGER; ab INTEGER; qcount INTEGER; acount INTEGER; kind TEXT; arule TEXT; setting TEXT;
BEGIN
 SELECT resource_id INTO sid FROM group_proposal_events WHERE organization_id=p_organization_id AND correlation_id=p_correlation_id;IF FOUND THEN RETURN sid;END IF;
 PERFORM assert_group_governance_actor(p_organization_id,p_group_id,p_actor_id);
 SELECT * INTO p FROM group_proposals WHERE id=p_proposal_id AND organization_id=p_organization_id AND group_id=p_group_id FOR UPDATE;IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_PROPOSAL_NOT_FOUND';END IF;
 IF p.state<>'draft' OR p.state_version<>p_expected_version THEN RAISE EXCEPTION 'GROUP_PROPOSAL_VERSION_CONFLICT';END IF;
 IF p_occurred_at<p.opens_at OR p_occurred_at>p.closes_at THEN RAISE EXCEPTION 'GROUP_PROPOSAL_WINDOW_INVALID';END IF;
 SELECT c.rules INTO rules FROM group_constitutions c WHERE c.id=p.constitution_id AND c.status='effective';IF rules IS NULL THEN RAISE EXCEPTION 'GROUP_EFFECTIVE_CONSTITUTION_REQUIRED';END IF;
 kind:=CASE WHEN p.proposal_type IN('constitution_amendment','group_closure') THEN 'special' WHEN p.proposal_type='membership_action' AND p.execution_payload->>'action' IN('suspend','expel') THEN 'discipline' WHEN p.proposal_type='treasury_disbursement' THEN 'treasury' ELSE 'ordinary' END;
 qb:=CASE WHEN kind='ordinary' THEN (rules->>'ordinary_quorum_bps')::INTEGER ELSE GREATEST(6667,(rules->>'special_quorum_bps')::INTEGER) END;
 ab:=CASE WHEN kind='ordinary' THEN (rules->>'ordinary_approval_bps')::INTEGER ELSE GREATEST(6667,(rules->>'special_approval_bps')::INTEGER) END;
 arule:=CASE WHEN kind='ordinary' THEN 'majority_non_abstaining' ELSE 'eligible_threshold' END;
 SELECT count(*) FILTER(WHERE NOT(user_id=ANY(p.conflict_user_ids))),count(*) FILTER(WHERE user_id=ANY(p.conflict_user_ids)) INTO eligible_count,excluded_count FROM group_members WHERE organization_id=p_organization_id AND group_id=p_group_id AND status='active' AND is_active AND payment_status='paid';
 IF eligible_count=0 THEN RAISE EXCEPTION 'GROUP_PROPOSAL_NO_ELIGIBLE_VOTERS';END IF;
 qcount:=CEIL(eligible_count*qb/10000.0)::INTEGER;acount:=CASE WHEN arule='eligible_threshold' THEN CEIL(eligible_count*ab/10000.0)::INTEGER ELSE NULL END;
 setting:=current_setting('microfams.group_proposal_engine',TRUE);PERFORM set_config('microfams.group_proposal_engine','on',TRUE);
 INSERT INTO group_voting_snapshots(organization_id,group_id,proposal_id,constitution_id,rule_kind,eligible_count,excluded_count,quorum_bps,quorum_count,approval_bps,approval_count,approval_rule,vote_change_allowed,created_at) VALUES(p_organization_id,p_group_id,p.id,p.constitution_id,kind,eligible_count,excluded_count,qb,qcount,ab,acount,arule,COALESCE((rules->>'vote_change_allowed')::BOOLEAN,FALSE),p_occurred_at) RETURNING id INTO sid;
 INSERT INTO group_voter_snapshot_members(organization_id,group_id,proposal_id,snapshot_id,member_id,user_id,eligible,exclusion_reason,created_at) SELECT p_organization_id,p_group_id,p.id,sid,id,user_id,NOT(user_id=ANY(p.conflict_user_ids)),CASE WHEN user_id=ANY(p.conflict_user_ids) THEN 'DIRECT_CONFLICT' END,p_occurred_at FROM group_members WHERE organization_id=p_organization_id AND group_id=p_group_id AND status='active' AND is_active AND payment_status='paid';
 UPDATE group_proposals SET state='open',state_version=state_version+1,opened_at=p_occurred_at,updated_at=p_occurred_at WHERE id=p.id;
 INSERT INTO group_proposal_events(organization_id,group_id,proposal_id,actor_id,event_type,from_state,to_state,resource_id,correlation_id,evidence,occurred_at) VALUES(p_organization_id,p_group_id,p.id,p_actor_id,'PROPOSAL_OPENED','draft','open',sid,p_correlation_id,jsonb_build_object('eligible_count',eligible_count,'excluded_count',excluded_count,'quorum_count',qcount,'approval_count',acount,'approval_rule',arule),p_occurred_at);
 PERFORM set_config('microfams.group_proposal_engine',COALESCE(setting,''),TRUE);RETURN sid;
END $$;

CREATE OR REPLACE FUNCTION cast_group_proposal_vote(
 p_organization_id UUID,p_group_id UUID,p_actor_id UUID,p_proposal_id UUID,p_choice TEXT,
 p_correlation_id UUID,p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE p group_proposals;s group_voting_snapshots;prior group_vote_history;vid UUID;setting TEXT;
BEGIN
 IF p_choice NOT IN('approve','reject','abstain') OR p_correlation_id IS NULL THEN RAISE EXCEPTION 'GROUP_VOTE_COMMAND_INVALID';END IF;
 SELECT resource_id INTO vid FROM group_proposal_events WHERE organization_id=p_organization_id AND correlation_id=p_correlation_id;IF FOUND THEN RETURN vid;END IF;
 SELECT * INTO p FROM group_proposals WHERE id=p_proposal_id AND organization_id=p_organization_id AND group_id=p_group_id FOR UPDATE;IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_PROPOSAL_NOT_FOUND';END IF;
 IF p.state<>'open' OR p_occurred_at<p.opens_at OR p_occurred_at>p.closes_at THEN RAISE EXCEPTION 'GROUP_PROPOSAL_NOT_OPEN';END IF;
 SELECT * INTO s FROM group_voting_snapshots WHERE proposal_id=p.id;
 IF NOT EXISTS(SELECT 1 FROM group_voter_snapshot_members WHERE snapshot_id=s.id AND user_id=p_actor_id AND eligible) THEN RAISE EXCEPTION 'GROUP_VOTER_NOT_ELIGIBLE';END IF;
 SELECT * INTO prior FROM group_vote_history WHERE proposal_id=p.id AND voter_id=p_actor_id AND is_current FOR UPDATE;
 IF FOUND AND NOT s.vote_change_allowed THEN RAISE EXCEPTION 'GROUP_VOTE_ALREADY_FINAL';END IF;
 setting:=current_setting('microfams.group_proposal_engine',TRUE);PERFORM set_config('microfams.group_proposal_engine','on',TRUE);
 IF prior.id IS NOT NULL THEN UPDATE group_vote_history SET is_current=FALSE WHERE id=prior.id;END IF;
 INSERT INTO group_vote_history(organization_id,group_id,proposal_id,snapshot_id,voter_id,choice,sequence,supersedes_vote_id,is_current,cast_at) VALUES(p_organization_id,p_group_id,p.id,s.id,p_actor_id,p_choice,COALESCE(prior.sequence,0)+1,prior.id,TRUE,p_occurred_at) RETURNING id INTO vid;
 INSERT INTO group_proposal_events(organization_id,group_id,proposal_id,actor_id,event_type,resource_id,correlation_id,evidence,occurred_at) VALUES(p_organization_id,p_group_id,p.id,p_actor_id,'VOTE_CAST',vid,p_correlation_id,jsonb_build_object('choice',p_choice,'sequence',COALESCE(prior.sequence,0)+1),p_occurred_at);
 PERFORM set_config('microfams.group_proposal_engine',COALESCE(setting,''),TRUE);RETURN vid;
END $$;

CREATE OR REPLACE FUNCTION close_group_proposal(
 p_organization_id UUID,p_group_id UUID,p_actor_id UUID,p_proposal_id UUID,p_expected_version INTEGER,
 p_correlation_id UUID,p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS group_proposals LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE p group_proposals;s group_voting_snapshots;approvals INTEGER;rejections INTEGER;abstentions INTEGER;participation INTEGER;target TEXT;setting TEXT;
BEGIN
 SELECT gp.* INTO p FROM group_proposal_events e JOIN group_proposals gp ON gp.id=e.proposal_id WHERE e.organization_id=p_organization_id AND e.correlation_id=p_correlation_id;IF FOUND THEN RETURN p;END IF;
 PERFORM assert_group_governance_actor(p_organization_id,p_group_id,p_actor_id);
 SELECT * INTO p FROM group_proposals WHERE id=p_proposal_id AND organization_id=p_organization_id AND group_id=p_group_id FOR UPDATE;IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_PROPOSAL_NOT_FOUND';END IF;
 IF p.state<>'open' OR p.state_version<>p_expected_version THEN RAISE EXCEPTION 'GROUP_PROPOSAL_VERSION_CONFLICT';END IF;
 IF p_occurred_at<p.closes_at THEN RAISE EXCEPTION 'GROUP_PROPOSAL_VOTING_STILL_OPEN';END IF;
 SELECT * INTO s FROM group_voting_snapshots WHERE proposal_id=p.id;
 SELECT count(*)FILTER(WHERE choice='approve'),count(*)FILTER(WHERE choice='reject'),count(*)FILTER(WHERE choice='abstain'),count(*) INTO approvals,rejections,abstentions,participation FROM group_vote_history WHERE proposal_id=p.id AND is_current;
 target:=CASE WHEN participation<s.quorum_count THEN 'expired' WHEN s.approval_rule='majority_non_abstaining' AND approvals>rejections THEN 'approved' WHEN s.approval_rule='eligible_threshold' AND approvals>=s.approval_count THEN 'approved' ELSE 'rejected' END;
 setting:=current_setting('microfams.group_proposal_engine',TRUE);PERFORM set_config('microfams.group_proposal_engine','on',TRUE);
 UPDATE group_proposals SET state=target,state_version=state_version+1,decided_at=p_occurred_at,result=jsonb_build_object('eligible_count',s.eligible_count,'quorum_count',s.quorum_count,'participation',participation,'approvals',approvals,'rejections',rejections,'abstentions',abstentions,'approval_rule',s.approval_rule,'approval_count',s.approval_count),updated_at=p_occurred_at WHERE id=p.id RETURNING * INTO p;
 INSERT INTO group_proposal_events(organization_id,group_id,proposal_id,actor_id,event_type,from_state,to_state,resource_id,correlation_id,evidence,occurred_at) VALUES(p_organization_id,p_group_id,p.id,p_actor_id,'PROPOSAL_DECIDED','open',target,p.id,p_correlation_id,p.result,p_occurred_at);
 PERFORM set_config('microfams.group_proposal_engine',COALESCE(setting,''),TRUE);RETURN p;
END $$;

CREATE OR REPLACE FUNCTION cancel_group_proposal(
 p_organization_id UUID,p_group_id UUID,p_actor_id UUID,p_proposal_id UUID,
 p_expected_version INTEGER,p_reason_code TEXT,p_correlation_id UUID,
 p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS group_proposals LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE p group_proposals;prior_state TEXT;setting TEXT;
BEGIN
 SELECT gp.* INTO p FROM group_proposal_events e JOIN group_proposals gp ON gp.id=e.proposal_id WHERE e.organization_id=p_organization_id AND e.correlation_id=p_correlation_id;IF FOUND THEN RETURN p;END IF;
 IF p_reason_code !~ '^[A-Z][A-Z0-9_]{2,63}$' OR p_correlation_id IS NULL THEN RAISE EXCEPTION 'GROUP_PROPOSAL_COMMAND_INVALID';END IF;
 PERFORM assert_group_governance_actor(p_organization_id,p_group_id,p_actor_id);
 SELECT * INTO p FROM group_proposals WHERE id=p_proposal_id AND organization_id=p_organization_id AND group_id=p_group_id FOR UPDATE;IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_PROPOSAL_NOT_FOUND';END IF;
 IF p.state NOT IN('draft','open') OR p.state_version<>p_expected_version THEN RAISE EXCEPTION 'GROUP_PROPOSAL_VERSION_CONFLICT';END IF;
 prior_state:=p.state;
 setting:=current_setting('microfams.group_proposal_engine',TRUE);PERFORM set_config('microfams.group_proposal_engine','on',TRUE);
 UPDATE group_proposals SET state='cancelled',state_version=state_version+1,decided_at=p_occurred_at,result=jsonb_build_object('reason_code',p_reason_code),updated_at=p_occurred_at WHERE id=p.id RETURNING * INTO p;
 INSERT INTO group_proposal_events(organization_id,group_id,proposal_id,actor_id,event_type,from_state,to_state,resource_id,correlation_id,evidence,occurred_at) VALUES(p_organization_id,p_group_id,p.id,p_actor_id,'PROPOSAL_CANCELLED',prior_state,'cancelled',p.id,p_correlation_id,p.result,p_occurred_at);
 PERFORM set_config('microfams.group_proposal_engine',COALESCE(setting,''),TRUE);RETURN p;
END $$;

UPDATE organization_memberships SET permissions=ARRAY(SELECT DISTINCT x FROM unnest(COALESCE(permissions,'{}')||ARRAY['groups.proposals.manage','groups.votes.cast'])x) WHERE role IN('owner','admin');
DO $$ DECLARE t TEXT;BEGIN FOREACH t IN ARRAY ARRAY['group_proposals','group_voting_snapshots','group_voter_snapshot_members','group_vote_history','group_proposal_events'] LOOP EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY',t);EXECUTE format('DROP POLICY IF EXISTS tenant_read ON %I',t);EXECUTE format('CREATE POLICY tenant_read ON %I FOR SELECT USING(has_active_organization_membership(organization_id))',t);EXECUTE format('REVOKE ALL ON %I FROM PUBLIC,anon,authenticated',t);EXECUTE format('GRANT SELECT ON %I TO service_role',t);EXECUTE format('REVOKE INSERT,UPDATE,DELETE ON %I FROM service_role',t);END LOOP;END $$;
REVOKE ALL ON FUNCTION create_group_proposal(UUID,UUID,UUID,TEXT,TEXT,JSONB,JSONB,UUID[],TIMESTAMPTZ,TIMESTAMPTZ,UUID,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION open_group_proposal(UUID,UUID,UUID,UUID,INTEGER,UUID,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION cast_group_proposal_vote(UUID,UUID,UUID,UUID,TEXT,UUID,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION close_group_proposal(UUID,UUID,UUID,UUID,INTEGER,UUID,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION cancel_group_proposal(UUID,UUID,UUID,UUID,INTEGER,TEXT,UUID,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION create_group_proposal(UUID,UUID,UUID,TEXT,TEXT,JSONB,JSONB,UUID[],TIMESTAMPTZ,TIMESTAMPTZ,UUID,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION open_group_proposal(UUID,UUID,UUID,UUID,INTEGER,UUID,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION cast_group_proposal_vote(UUID,UUID,UUID,UUID,TEXT,UUID,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION close_group_proposal(UUID,UUID,UUID,UUID,INTEGER,UUID,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION cancel_group_proposal(UUID,UUID,UUID,UUID,INTEGER,TEXT,UUID,TIMESTAMPTZ) TO service_role;
