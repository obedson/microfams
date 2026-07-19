-- Keep database-level tenant isolation enabled; the backend service role bypasses RLS.
ALTER TABLE courses ENABLE ROW LEVEL SECURITY;

-- Drop any existing policies
DROP POLICY IF EXISTS "Public read courses" ON courses;
DROP POLICY IF EXISTS "Authenticated update courses" ON courses;
DROP POLICY IF EXISTS "Authenticated create courses" ON courses;
DROP POLICY IF EXISTS "Authenticated delete courses" ON courses;
