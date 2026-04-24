import request from 'supertest';
import express from 'express';
import communicationRoutes from '../routes/communications.js';

// Mock Supabase
jest.mock('../utils/supabase.js', () => ({
  supabase: {
    from: jest.fn()
  }
}));

// Mock logger
jest.mock('../utils/logger.js', () => ({
  logger: {
    error: jest.fn(),
    info: jest.fn()
  }
}));

// Mock auth middleware
jest.mock('../middleware/auth.js', () => ({
  authenticateToken: (req: any, res: any, next: any) => {
    // Extract user from Authorization header for testing
    const authHeader = req.headers['authorization'];
    if (authHeader && authHeader.startsWith('Bearer ')) {
      const token = authHeader.split(' ')[1];
      if (token === 'farmer-token') {
        req.user = { id: 'user-1', role: 'farmer' };
      } else if (token === 'owner-token') {
        req.user = { id: 'user-2', role: 'property_owner' };
      } else if (token === 'unauthorized-token') {
        req.user = { id: 'user-3', role: 'farmer' };
      } else {
        return res.status(403).json({ error: 'Invalid token' });
      }
    } else {
      return res.status(401).json({ error: 'Access token required' });
    }
    next();
  }
}));

import { supabase } from '../utils/supabase.js';

// Create test app
const createTestApp = () => {
  const app = express();
  app.use(express.json());
  app.use('/api/communications', communicationRoutes);
  return app;
};

// Mock data
const mockBooking = {
  id: 'booking-123',
  farmer_id: 'user-1',
  properties: {
    owner_id: 'user-2'
  },
  status: 'confirmed'
};

describe('Communication Backend Services - Task 7.1 Properties', () => {
  let app: express.Application;

  beforeEach(() => {
    app = createTestApp();
    jest.clearAllMocks();
  });

  /**
   * Property: Message Sending Authorization
   * For any message sending request, only booking participants should be able to send messages.
   * Validates: Requirements 8.1, 8.2
   */
  test('Property: Message sending requires booking participation', async () => {
    // Mock booking lookup and message insertion
    const mockFrom = jest.fn();
    (supabase.from as jest.Mock) = mockFrom;

    mockFrom.mockImplementation((table: string) => {
      if (table === 'bookings') {
        return {
          select: jest.fn().mockReturnValue({
            eq: jest.fn().mockReturnValue({
              single: jest.fn().mockResolvedValue({
                data: mockBooking,
                error: null
              })
            })
          })
        };
      }
      if (table === 'booking_communications') {
        return {
          insert: jest.fn().mockReturnValue({
            select: jest.fn().mockReturnValue({
              single: jest.fn().mockResolvedValue({
                data: {
                  id: 'msg-1',
                  booking_id: 'booking-123',
                  sender_id: 'user-1',
                  recipient_id: 'user-2',
                  content: 'Test message',
                  sent_at: new Date().toISOString()
                },
                error: null
              })
            })
          })
        };
      }
    });

    // Property: Farmer can send message to owner
    const response1 = await request(app)
      .post('/api/communications/send')
      .set('Authorization', 'Bearer farmer-token')
      .send({
        booking_id: 'booking-123',
        recipient_id: 'user-2',
        content: 'Hello, I have a question about the property.'
      });

    expect(response1.status).toBe(201);
    expect(response1.body.success).toBe(true);
  });

  /**
   * Property: Message History Booking Linkage
   * For any message retrieval request, only messages linked to the specific booking should be returned.
   * Validates: Requirements 8.7
   */
  test('Property: Message history is correctly linked to booking', async () => {
    const mockMessages = [
      {
        id: 'msg-1',
        booking_id: 'booking-123',
        sender_id: 'user-1',
        recipient_id: 'user-2',
        content: 'Test message 1',
        sent_at: new Date().toISOString()
      }
    ];

    const mockFrom = jest.fn();
    (supabase.from as jest.Mock) = mockFrom;

    mockFrom.mockImplementation((table: string) => {
      if (table === 'bookings') {
        return {
          select: jest.fn().mockReturnValue({
            eq: jest.fn().mockReturnValue({
              single: jest.fn().mockResolvedValue({
                data: mockBooking,
                error: null
              })
            })
          })
        };
      }
      if (table === 'booking_communications') {
        return {
          select: jest.fn().mockReturnValue({
            eq: jest.fn().mockReturnValue({
              order: jest.fn().mockResolvedValue({
                data: mockMessages,
                error: null
              })
            })
          })
        };
      }
    });

    // Property: Messages are retrieved for specific booking only
    const response = await request(app)
      .get('/api/communications/booking/booking-123')
      .set('Authorization', 'Bearer farmer-token');

    expect(response.status).toBe(200);
    expect(response.body.success).toBe(true);
    expect(response.body.messages).toHaveLength(1);
    expect(response.body.messages[0].booking_id).toBe('booking-123');
  });

  /**
   * Property: Access Control Enforcement
   * For any communication endpoint, access should be denied to users not involved in the booking.
   * Validates: Requirements 8.1, 8.2
   */
  test('Property: Access control prevents unauthorized message access', async () => {
    const mockFrom = jest.fn();
    (supabase.from as jest.Mock) = mockFrom;

    mockFrom.mockReturnValue({
      select: jest.fn().mockReturnValue({
        eq: jest.fn().mockReturnValue({
          single: jest.fn().mockResolvedValue({
            data: mockBooking,
            error: null
          })
        })
      })
    });

    // Property: Unauthorized user cannot send messages
    const response1 = await request(app)
      .post('/api/communications/send')
      .set('Authorization', 'Bearer unauthorized-token')
      .send({
        booking_id: 'booking-123',
        recipient_id: 'user-2',
        content: 'Unauthorized message'
      });

    expect(response1.status).toBe(403);
    expect(response1.body.error).toBe('Access denied');
  });

  /**
   * Property: Input Validation
   * For any message sending request, required fields must be validated.
   * Validates: Requirements 8.6
   */
  test('Property: Input validation prevents invalid message creation', async () => {
    // Property: Missing booking_id
    const response1 = await request(app)
      .post('/api/communications/send')
      .set('Authorization', 'Bearer farmer-token')
      .send({
        recipient_id: 'user-2',
        content: 'Test message'
      });

    expect(response1.status).toBe(400);
    expect(response1.body.error).toBe('Missing required fields');

    // Property: Missing content
    const response2 = await request(app)
      .post('/api/communications/send')
      .set('Authorization', 'Bearer farmer-token')
      .send({
        booking_id: 'booking-123',
        recipient_id: 'user-2'
      });

    expect(response2.status).toBe(400);
    expect(response2.body.error).toBe('Missing required fields');
  });

  /**
   * Property: Message Read Status Tracking
   * For any message read operation, only the recipient should be able to mark messages as read.
   * Validates: Requirements 8.6, 8.7
   */
  test('Property: Message read status is properly controlled', async () => {
    const mockMessage = {
      id: 'msg-1',
      recipient_id: 'user-2',
      read_at: null
    };

    const mockFrom = jest.fn();
    (supabase.from as jest.Mock) = mockFrom;

    mockFrom.mockReturnValue({
      select: jest.fn().mockReturnValue({
        eq: jest.fn().mockReturnValue({
          single: jest.fn().mockResolvedValue({
            data: mockMessage,
            error: null
          })
        })
      }),
      update: jest.fn().mockReturnValue({
        eq: jest.fn().mockResolvedValue({
          error: null
        })
      })
    });

    // Property: Recipient can mark message as read
    const response1 = await request(app)
      .put('/api/communications/message/msg-1/read')
      .set('Authorization', 'Bearer owner-token');

    expect(response1.status).toBe(200);
    expect(response1.body.success).toBe(true);

    // Property: Non-recipient cannot mark message as read
    const response2 = await request(app)
      .put('/api/communications/message/msg-1/read')
      .set('Authorization', 'Bearer farmer-token');

    expect(response2.status).toBe(403);
    expect(response2.body.error).toBe('Access denied');
  });
});
