-- Check if RLS is enabled and disable it for courses table
-- Since we're using service key on backend, RLS should be disabled
ALTER TABLE courses DISABLE ROW LEVEL SECURITY;

-- Drop any existing policies
DROP POLICY IF EXISTS "Public read courses" ON courses;
DROP POLICY IF EXISTS "Authenticated update courses" ON courses;
DROP POLICY IF EXISTS "Authenticated create courses" ON courses;
DROP POLICY IF EXISTS "Authenticated delete courses" ON courses;
