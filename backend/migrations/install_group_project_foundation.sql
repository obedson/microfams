-- GT-08A governed group project foundation
SET search_path=public,extensions;
CREATE TABLE IF NOT EXISTS group_projects (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL REFERENCES organizations(id),
 group_id UUID NOT NULL REFERENCES groups(id), constitution_id UUID NOT NULL REFERENCES group_constitutions(id),
 project_key TEXT NOT NULL CHECK(project_key ~ '^[a-z][a-z0-9_]{2,63}$'), title TEXT NOT NULL,
 purpose TEXT NOT NULL, owner_user_id UUID NOT NULL REFERENCES users(id), responsible_committee_id UUID REFERENCES group_committees(id),
 starts_on DATE NOT NULL, ends_on DATE NOT NULL CHECK(ends_on>=starts_on),
 funding_sources JSONB NOT NULL CHECK(jsonb_typeof(funding_sources)='array'), restricted_fund_rules JSONB NOT NULL DEFAULT '[]' CHECK(jsonb_typeof(restricted_fund_rules)='array'),
 outcome_measures JSONB NOT NULL DEFAULT '[]' CHECK(jsonb_typeof(outcome_measures)='array'),
 state TEXT NOT NULL DEFAULT 'draft' CHECK(state IN('draft','proposed','approved','active','paused','completed','cancelled','closed')),
 proposal_id UUID UNIQUE REFERENCES group_proposals(id), current_budget_version_id UUID, created_by UUID NOT NULL REFERENCES users(id),
 idempotency_key TEXT NOT NULL, approved_by UUID REFERENCES users(id), approved_at TIMESTAMPTZ, activated_at TIMESTAMPTZ,
 created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
 UNIQUE(organization_id,group_id,project_key), UNIQUE(organization_id,idempotency_key)
);
CREATE TABLE IF NOT EXISTS group_project_budget_versions (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL REFERENCES organizations(id), group_id UUID NOT NULL REFERENCES groups(id),
 project_id UUID NOT NULL REFERENCES group_projects(id), version INTEGER NOT NULL CHECK(version>0),
 state TEXT NOT NULL DEFAULT 'draft' CHECK(state IN('draft','approved','superseded')), currency TEXT NOT NULL CHECK(currency ~ '^[A-Z]{3}$'),
 total_minor BIGINT NOT NULL CHECK(total_minor>=0), budget_lines JSONB NOT NULL CHECK(jsonb_typeof(budget_lines)='array'),
 proposal_id UUID REFERENCES group_proposals(id), created_by UUID NOT NULL REFERENCES users(id), approved_by UUID REFERENCES users(id), approved_at TIMESTAMPTZ,
 created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), UNIQUE(project_id,version), CHECK((state='approved')=(approved_at IS NOT NULL))
);
ALTER TABLE group_projects DROP CONSTRAINT IF EXISTS group_projects_current_budget_version_id_fkey;
ALTER TABLE group_projects ADD CONSTRAINT group_projects_current_budget_version_id_fkey FOREIGN KEY(current_budget_version_id) REFERENCES group_project_budget_versions(id);
CREATE TABLE IF NOT EXISTS group_project_milestones (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL REFERENCES organizations(id), group_id UUID NOT NULL REFERENCES groups(id),
 project_id UUID NOT NULL REFERENCES group_projects(id), sequence INTEGER NOT NULL, title TEXT NOT NULL, description TEXT NOT NULL, due_on DATE NOT NULL,
 outcome_measure JSONB NOT NULL DEFAULT '{}', state TEXT NOT NULL DEFAULT 'planned', created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), UNIQUE(project_id,sequence)
);
CREATE TABLE IF NOT EXISTS group_project_events (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL REFERENCES organizations(id), group_id UUID NOT NULL REFERENCES groups(id),
 project_id UUID NOT NULL REFERENCES group_projects(id), actor_id UUID REFERENCES users(id), event_type TEXT NOT NULL, from_state TEXT, to_state TEXT,
 proposal_id UUID REFERENCES group_proposals(id), budget_version_id UUID REFERENCES group_project_budget_versions(id), correlation_id UUID NOT NULL,
 evidence JSONB NOT NULL DEFAULT '{}', occurred_at TIMESTAMPTZ NOT NULL, UNIQUE(organization_id,correlation_id)
);
CREATE OR REPLACE FUNCTION protect_group_project_evidence() RETURNS TRIGGER LANGUAGE plpgsql AS $$ BEGIN
 IF current_setting('microfams.group_project_engine',TRUE)='on' THEN RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END; END IF;
 RAISE EXCEPTION 'GROUP_PROJECT_ENGINE_REQUIRED'; END $$;
DO $$ DECLARE t TEXT; BEGIN FOREACH t IN ARRAY ARRAY['group_projects','group_project_budget_versions','group_project_milestones','group_project_events'] LOOP
 EXECUTE format('DROP TRIGGER IF EXISTS protect_group_project_evidence ON %I',t);
 EXECUTE format('CREATE TRIGGER protect_group_project_evidence BEFORE INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION protect_group_project_evidence()',t); END LOOP; END $$;
CREATE OR REPLACE FUNCTION group_project_actor_permitted(o UUID,g UUID,a UUID) RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER AS $$
 SELECT EXISTS(SELECT 1 FROM organization_memberships m WHERE m.organization_id=o AND m.user_id=a AND m.status='active' AND (m.role='owner' OR m.permissions @> ARRAY['groups.projects.manage'])); $$;
ALTER TABLE group_projects ENABLE ROW LEVEL SECURITY; ALTER TABLE group_project_budget_versions ENABLE ROW LEVEL SECURITY; ALTER TABLE group_project_milestones ENABLE ROW LEVEL SECURITY; ALTER TABLE group_project_events ENABLE ROW LEVEL SECURITY;
DO $$ DECLARE t TEXT; BEGIN FOREACH t IN ARRAY ARRAY['group_projects','group_project_budget_versions','group_project_milestones','group_project_events'] LOOP
 EXECUTE format('CREATE POLICY tenant_read ON %I FOR SELECT USING(has_active_organization_membership(organization_id))',t); EXECUTE format('REVOKE ALL ON %I FROM PUBLIC,anon,authenticated',t); EXECUTE format('GRANT SELECT ON %I TO service_role',t); END LOOP; END $$;
UPDATE organization_memberships SET permissions=ARRAY(SELECT DISTINCT permission FROM unnest(permissions||ARRAY['groups.projects.manage']) permission) WHERE role IN('owner','admin') OR permissions @> ARRAY['groups.governance.manage'];
CREATE OR REPLACE FUNCTION create_group_project(o UUID,g UUID,a UUID,k TEXT,t TEXT,purpose_text TEXT,owner_id UUID,committee_id UUID,start_date DATE,end_date DATE,sources JSONB,rules JSONB,outcomes JSONB,currency_code TEXT,total BIGINT,lines JSONB,milestones JSONB,idem TEXT,corr UUID,at_time TIMESTAMPTZ DEFAULT NOW()) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE project_id UUID; budget_id UUID; BEGIN
 IF NOT group_project_actor_permitted(o,g,a) THEN RAISE EXCEPTION 'GROUP_PROJECT_PERMISSION_DENIED'; END IF;
 IF NOT EXISTS(SELECT 1 FROM groups WHERE id=g AND organization_id=o AND lifecycle_state='active') THEN RAISE EXCEPTION 'GROUP_PROJECT_ACTIVE_GROUP_REQUIRED'; END IF;
 IF jsonb_typeof(lines)<>'array' OR jsonb_typeof(sources)<>'array' OR total<0 OR start_date>end_date THEN RAISE EXCEPTION 'GROUP_PROJECT_COMMAND_INVALID'; END IF;
 PERFORM set_config('microfams.group_project_engine','on',TRUE); INSERT INTO group_projects(organization_id,group_id,constitution_id,project_key,title,purpose,owner_user_id,responsible_committee_id,starts_on,ends_on,funding_sources,restricted_fund_rules,outcome_measures,created_by,idempotency_key) SELECT o,g,current_constitution_id,k,t,purpose_text,owner_id,committee_id,start_date,end_date,sources,rules,outcomes,a,idem FROM groups WHERE id=g RETURNING id INTO project_id;
 INSERT INTO group_project_budget_versions(organization_id,group_id,project_id,version,currency,total_minor,budget_lines,created_by) VALUES(o,g,project_id,1,currency_code,total,lines,a) RETURNING id INTO budget_id;
 PERFORM set_config('microfams.group_project_engine','on',TRUE); UPDATE group_projects SET current_budget_version_id=budget_id WHERE id=project_id;
 INSERT INTO group_project_events(organization_id,group_id,project_id,actor_id,event_type,to_state,budget_version_id,correlation_id,occurred_at) VALUES(o,g,project_id,a,'PROJECT_CREATED','draft',budget_id,corr,at_time);
 PERFORM set_config('microfams.group_project_engine','',TRUE); RETURN project_id;
END $$;
CREATE OR REPLACE FUNCTION submit_group_project(o UUID,g UUID,a UUID,project_id UUID,proposal_id UUID,corr UUID,at_time TIMESTAMPTZ DEFAULT NOW()) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
 IF NOT group_project_actor_permitted(o,g,a) THEN RAISE EXCEPTION 'GROUP_PROJECT_PERMISSION_DENIED'; END IF;
 IF NOT EXISTS(SELECT 1 FROM group_projects p JOIN group_proposals q ON q.id=proposal_id AND q.proposal_type='project' AND q.constitution_id=p.constitution_id AND q.execution_payload->>'project_key'=p.project_key WHERE p.id=project_id AND p.organization_id=o AND p.group_id=g AND p.state='draft') THEN RAISE EXCEPTION 'GROUP_PROJECT_PROPOSAL_INVALID'; END IF;
 PERFORM set_config('microfams.group_project_engine','on',TRUE); UPDATE group_projects SET state='proposed',proposal_id=proposal_id WHERE id=project_id; INSERT INTO group_project_events(organization_id,group_id,project_id,actor_id,event_type,from_state,to_state,proposal_id,correlation_id,occurred_at) VALUES(o,g,project_id,a,'PROJECT_SUBMITTED','draft','proposed',proposal_id,corr,at_time); RETURN project_id;
END $$;
CREATE OR REPLACE FUNCTION approve_group_project(o UUID,g UUID,a UUID,project_id UUID,corr UUID,at_time TIMESTAMPTZ DEFAULT NOW()) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
 IF NOT group_project_actor_permitted(o,g,a) THEN RAISE EXCEPTION 'GROUP_PROJECT_PERMISSION_DENIED'; END IF;
 IF NOT EXISTS(SELECT 1 FROM group_projects p JOIN group_proposals q ON q.id=p.proposal_id AND q.state='approved' WHERE p.id=project_id AND p.organization_id=o AND p.group_id=g AND p.state='proposed' AND p.created_by<>a AND q.proposer_id<>a) THEN RAISE EXCEPTION 'GROUP_PROJECT_APPROVAL_REQUIRED'; END IF;
 PERFORM set_config('microfams.group_project_engine','on',TRUE); UPDATE group_project_budget_versions SET state='approved',approved_by=a,approved_at=at_time WHERE group_project_budget_versions.project_id=approve_group_project.project_id AND state='draft'; UPDATE group_projects SET state='approved',approved_by=a,approved_at=at_time WHERE id=project_id; INSERT INTO group_project_events(organization_id,group_id,project_id,actor_id,event_type,from_state,to_state,correlation_id,occurred_at) VALUES(o,g,project_id,a,'PROJECT_APPROVED','proposed','approved',corr,at_time); RETURN project_id;
END $$;
CREATE OR REPLACE FUNCTION activate_group_project(o UUID,g UUID,a UUID,project_id UUID,corr UUID,at_time TIMESTAMPTZ DEFAULT NOW()) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
 IF NOT group_project_actor_permitted(o,g,a) THEN RAISE EXCEPTION 'GROUP_PROJECT_PERMISSION_DENIED'; END IF;
 IF NOT EXISTS(SELECT 1 FROM group_projects p JOIN group_project_budget_versions b ON b.id=p.current_budget_version_id AND b.state='approved' WHERE p.id=project_id AND p.organization_id=o AND p.group_id=g AND p.state='approved' AND at_time::date BETWEEN p.starts_on AND p.ends_on) THEN RAISE EXCEPTION 'GROUP_PROJECT_ACTIVATION_INVALID'; END IF;
 PERFORM set_config('microfams.group_project_engine','on',TRUE); UPDATE group_projects SET state='active',activated_at=at_time WHERE id=project_id; INSERT INTO group_project_events(organization_id,group_id,project_id,actor_id,event_type,from_state,to_state,correlation_id,occurred_at) VALUES(o,g,project_id,a,'PROJECT_ACTIVATED','approved','active',corr,at_time); RETURN project_id;
END $$;
REVOKE ALL ON FUNCTION create_group_project(UUID,UUID,UUID,TEXT,TEXT,TEXT,UUID,UUID,DATE,DATE,JSONB,JSONB,JSONB,TEXT,BIGINT,JSONB,JSONB,TEXT,UUID,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION submit_group_project(UUID,UUID,UUID,UUID,UUID,UUID,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION approve_group_project(UUID,UUID,UUID,UUID,UUID,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION activate_group_project(UUID,UUID,UUID,UUID,UUID,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION create_group_project(UUID,UUID,UUID,TEXT,TEXT,TEXT,UUID,UUID,DATE,DATE,JSONB,JSONB,JSONB,TEXT,BIGINT,JSONB,JSONB,TEXT,UUID,TIMESTAMPTZ),submit_group_project(UUID,UUID,UUID,UUID,UUID,UUID,TIMESTAMPTZ),approve_group_project(UUID,UUID,UUID,UUID,UUID,TIMESTAMPTZ),activate_group_project(UUID,UUID,UUID,UUID,UUID,TIMESTAMPTZ) TO service_role;
