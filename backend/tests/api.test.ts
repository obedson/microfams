import request from 'supertest';
import app from '../src/index';

describe('API Endpoints', () => {
  describe('Health Check', () => {
    it('should return OK status', async () => {
      const response = await request(app)
        .get('/health')
        .expect(200);

      expect(response.body.status).toBe('OK');
      expect(response.body.timestamp).toBeDefined();
    });
  });

  describe('Auth Endpoints', () => {
    const testUser = {
      email: `test-api-${Date.now()}@example.com`,
      password: 'password123',
      name: 'Test API User',
      role: 'farmer'
    };

    it('should register a new user', async () => {
      const response = await request(app)
        .post('/api/auth/register')
        .send(testUser)
        .expect(201);

      expect(response.body.success).toBe(true);
      expect(response.body.data.user.email).toBe(testUser.email);
      expect(response.body.data.token).toBeDefined();
    });

    it('should not register user with invalid email', async () => {
      const response = await request(app)
        .post('/api/auth/register')
        .send({ ...testUser, email: 'invalid-email' })
        .expect(400);

      expect(response.body.success).toBe(false);
    });

    it('should login with valid credentials', async () => {
      // First register
      await request(app)
        .post('/api/auth/register')
        .send(testUser);

      // Then login
      const response = await request(app)
        .post('/api/auth/login')
        .send({
          email: testUser.email,
          password: testUser.password
        })
        .expect(200);

      expect(response.body.success).toBe(true);
      expect(response.body.data.token).toBeDefined();
    });
  });

  describe('Error Handling', () => {
    it('should return 404 for non-existent routes', async () => {
      const response = await request(app)
        .get('/api/non-existent')
        .expect(404);

      expect(response.body.success).toBe(false);
    });

    it('should return 404 for unknown nested API routes', async () => {
      const response = await request(app)
        .get('/api/contributions/non-existent/path')
        .expect(404);

      expect(response.body.success).toBe(false);
    });

    it('should keep known contribution routes protected', async () => {
      const response = await request(app)
        .get('/api/groups/test-id/contributions/settings')
        .expect(401);

      expect(response.body).toEqual({
        success: false,
        error: 'Access token required'
      });
    });

    it('protects atomic booking reservation creation', async () => {
      await request(app)
        .post('/api/bookings')
        .set('Idempotency-Key', 'booking-api-contract-1')
        .send({
          property_id: '00000000-0000-4000-8000-000000000201',
          start_date: '2030-01-01',
          end_date: '2030-01-31'
        })
        .expect(401);
    });
    it('protects booking cancellation and refund review commands', async () => {
      await request(app)
        .put('/api/bookings/00000000-0000-4000-8000-000000000201/status')
        .set('Idempotency-Key', 'booking-lifecycle-api-contract')
        .send({ status: 'confirmed' })
        .expect(401);
      await request(app)
        .put('/api/bookings/00000000-0000-4000-8000-000000000201/cancel')
        .send({ reason: 'Change of plans' })
        .expect(401);
      await request(app)
        .post('/api/bookings/cancellations/00000000-0000-4000-8000-000000000202/refund-proposals')
        .send({ amount_minor: 10000, reason: 'Unused service' })
        .expect(401);
      await request(app)
        .post('/api/bookings/refund-approvals/00000000-0000-4000-8000-000000000203/decision')
        .send({ approve: true, reason: 'Independent approval' })
        .expect(401);
    });
  });
});
