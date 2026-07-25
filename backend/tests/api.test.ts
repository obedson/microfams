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
  });
});
