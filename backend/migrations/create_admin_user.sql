-- Create admin user or update existing user to admin
-- Option 1: Update existing user to admin
UPDATE users 
SET role = 'admin' 
WHERE email = 'your-email@example.com';

-- Option 2: Check current roles
SELECT id, email, name, role FROM users;

-- Option 3: Create new admin user (if needed)
-- First register normally, then run:
-- UPDATE users SET role = 'admin' WHERE email = 'admin@example.com';
