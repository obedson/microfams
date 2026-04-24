-- Enable RLS on all tables
ALTER TABLE states ENABLE ROW LEVEL SECURITY;
ALTER TABLE lgas ENABLE ROW LEVEL SECURITY;
ALTER TABLE groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE contribution_cycles ENABLE ROW LEVEL SECURITY;
ALTER TABLE member_contributions ENABLE ROW LEVEL SECURITY;

-- Public read access for location data
CREATE POLICY "Public read states" ON states FOR SELECT USING (true);
CREATE POLICY "Public read lgas" ON lgas FOR SELECT USING (true);

-- Groups: Anyone can read, only authenticated can create
CREATE POLICY "Public read groups" ON groups FOR SELECT USING (true);
CREATE POLICY "Authenticated create groups" ON groups FOR INSERT 
  WITH CHECK (auth.uid() = creator_id);
CREATE POLICY "Creator update groups" ON groups FOR UPDATE 
  USING (auth.uid() = creator_id);

-- Group members: Members can read their own group
CREATE POLICY "Members read own group" ON group_members FOR SELECT 
  USING (user_id = auth.uid() OR group_id IN (
    SELECT group_id FROM group_members WHERE user_id = auth.uid()
  ));
CREATE POLICY "Authenticated join groups" ON group_members FOR INSERT 
  WITH CHECK (user_id = auth.uid());

-- Contribution cycles: Group members can read
CREATE POLICY "Members read cycles" ON contribution_cycles FOR SELECT 
  USING (group_id IN (
    SELECT group_id FROM group_members WHERE user_id = auth.uid()
  ));
CREATE POLICY "Creator create cycles" ON contribution_cycles FOR INSERT 
  WITH CHECK (group_id IN (
    SELECT id FROM groups WHERE creator_id = auth.uid()
  ));

-- Member contributions: Users can read their own
CREATE POLICY "Users read own contributions" ON member_contributions FOR SELECT 
  USING (member_id IN (
    SELECT id FROM group_members WHERE user_id = auth.uid()
  ));
CREATE POLICY "Users update own contributions" ON member_contributions FOR UPDATE 
  USING (member_id IN (
    SELECT id FROM group_members WHERE user_id = auth.uid()
  ));
