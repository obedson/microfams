-- Disable PostgREST access to tables (backend-only access)
-- This prevents direct API access, only your backend can query

-- Revoke public access
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon, authenticated;

-- Grant access only to service role (your backend)
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;

-- For sequences (auto-increment IDs)
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO service_role;
