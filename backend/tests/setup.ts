import dotenv from 'dotenv';

dotenv.config({ path: '.env.test' });

process.env.NODE_ENV = 'test';
process.env.SUPABASE_URL ??= 'http://127.0.0.1:54321';
process.env.SUPABASE_SERVICE_KEY ??= 'test-service-role-key';
process.env.JWT_SECRET ??= 'test-jwt-secret-do-not-use-outside-tests';
process.env.JWT_REFRESH_SECRET ??= 'test-refresh-secret-do-not-use-outside-tests';
process.env.INTERSWITCH_CLIENT_ID ??= 'test-client-id';
process.env.INTERSWITCH_CLIENT_SECRET ??= 'test-client-secret';
process.env.INTERSWITCH_WEBHOOK_SECRET ??= 'test-webhook-secret';
process.env.PAYSTACK_SECRET_KEY ??= 'sk_test_not-a-real-key';
