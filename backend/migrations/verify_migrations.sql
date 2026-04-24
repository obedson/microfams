-- Database Migration Verification Script
-- Run this in Supabase SQL Editor to check if all migrations have been applied

-- Check if groups table has contribution fields
SELECT 
  column_name, 
  data_type,
  is_nullable
FROM information_schema.columns
WHERE table_name = 'groups'
  AND column_name IN (
    'contribution_enabled',
    'contribution_amount',
    'payment_day',
    'grace_period_days',
    'late_penalty_amount',
    'late_penalty_type',
    'auto_suspend_after',
    'auto_expel_after'
  )
ORDER BY column_name;

-- Expected: 8 rows

-- Check if group_members table has required fields
SELECT 
  column_name, 
  data_type,
  is_nullable
FROM information_schema.columns
WHERE table_name = 'group_members'
  AND column_name IN (
    'member_status',
    'missed_payments_count'
  )
ORDER BY column_name;

-- Expected: 2 rows

-- Check if contribution_cycles table exists
SELECT EXISTS (
  SELECT FROM information_schema.tables 
  WHERE table_name = 'contribution_cycles'
) as contribution_cycles_exists;

-- Expected: true

-- Check if member_contributions table exists
SELECT EXISTS (
  SELECT FROM information_schema.tables 
  WHERE table_name = 'member_contributions'
) as member_contributions_exists;

-- Expected: true

-- Check if users table has referral fields
SELECT 
  column_name, 
  data_type,
  is_nullable
FROM information_schema.columns
WHERE table_name = 'users'
  AND column_name IN (
    'referral_code',
    'referred_by',
    'paid_referrals_count'
  )
ORDER BY column_name;

-- Expected: 3 rows

-- Check if states and lgas tables exist
SELECT 
  table_name
FROM information_schema.tables
WHERE table_name IN ('states', 'lgas')
ORDER BY table_name;

-- Expected: 2 rows

-- Summary query
SELECT 
  'groups' as table_name,
  COUNT(*) FILTER (WHERE column_name IN (
    'contribution_enabled', 'contribution_amount', 'payment_day',
    'grace_period_days', 'late_penalty_amount', 'late_penalty_type',
    'auto_suspend_after', 'auto_expel_after'
  )) as required_columns
FROM information_schema.columns
WHERE table_name = 'groups'

UNION ALL

SELECT 
  'group_members',
  COUNT(*) FILTER (WHERE column_name IN ('member_status', 'missed_payments_count'))
FROM information_schema.columns
WHERE table_name = 'group_members'

UNION ALL

SELECT 
  'users',
  COUNT(*) FILTER (WHERE column_name IN ('referral_code', 'referred_by', 'paid_referrals_count'))
FROM information_schema.columns
WHERE table_name = 'users'

UNION ALL

SELECT 
  'contribution_cycles',
  CASE WHEN EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'contribution_cycles') THEN 1 ELSE 0 END
FROM information_schema.tables
LIMIT 1

UNION ALL

SELECT 
  'member_contributions',
  CASE WHEN EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'member_contributions') THEN 1 ELSE 0 END
FROM information_schema.tables
LIMIT 1;

-- Expected results:
-- groups: 8
-- group_members: 2
-- users: 3
-- contribution_cycles: 1
-- member_contributions: 1
