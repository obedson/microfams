import rateLimit from 'express-rate-limit';

// General API rate limiter
export const apiLimiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  max: 100, // 100 requests per window
  message: 'Too many requests, please try again later.',
  standardHeaders: true,
  legacyHeaders: false,
});

// Strict limiter for booking creation
export const bookingLimiter = rateLimit({
  windowMs: 60 * 60 * 1000, // 1 hour
  max: 10, // 10 bookings per hour
  message: 'Too many booking attempts. Please try again later.',
  standardHeaders: true,
  legacyHeaders: false,
});

// Payment initialization limiter
export const paymentLimiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  max: 20, // 20 payment attempts per window
  message: 'Too many payment attempts. Please try again later.',
  standardHeaders: true,
  legacyHeaders: false,
});
