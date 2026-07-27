import { describe, it, expect } from '@jest/globals';
import { supabase } from '../utils/supabase.js';

describe('Receipt System - Database Only Tests', () => {
  let bookingId: string;
  let propertyId: string;
  let testUserId: string;
  let testReceiptId: string;
  let organizationId: string;
  const suffix = `${Date.now()}-${Math.random().toString(16).slice(2)}`;

  beforeAll(async () => {
    const { data: user, error: userError } = await supabase.from('users').insert({
      email: `receipt-owner-${suffix}@example.test`, password: 'not-a-real-password',
      name: 'Receipt Owner', role: 'owner'
    }).select('id').single();
    if (userError || !user) throw userError ?? new Error('Failed to create receipt owner');
    testUserId = user.id;
    organizationId = user.id;

    const { data: property, error: propertyError } = await supabase.from('properties').insert({
      owner_id: testUserId, title: 'Receipt Test Property', description: 'Receipt integration fixture',
      livestock_type: 'poultry', space_type: 'equipped_house', size: 10, size_unit: 'units',
      city: 'Test City', lga: 'Test LGA', price_per_month: 1000,
      available_from: '2026-01-01', available_to: '2026-12-31', is_active: true
    }).select('id').single();
    if (propertyError || !property) throw propertyError ?? new Error('Failed to create receipt property');
    propertyId = property.id;

    const { data: booking, error: bookingError } = await supabase.from('bookings').insert({
      property_id: propertyId, farmer_id: testUserId, start_date: '2026-07-01', end_date: '2026-07-02',
      total_amount: 50000, status: 'confirmed', payment_status: 'paid'
    }).select('id, organization_id').single();
    if (bookingError || !booking) throw bookingError ?? new Error('Failed to create receipt booking');
    bookingId = booking.id;
    organizationId = booking.organization_id;
  });

  describe('Property 52: Receipt Generation on Payment', () => {
    it('should create receipt record in database', async () => {
      const paymentRef = 'test_ref_' + Date.now();
      
      const { data: receipt, error } = await supabase
        .from('payment_receipts')
        .insert({
          booking_id: bookingId, // Real booking ID with paid status
          organization_id: organizationId,
          payment_reference: paymentRef,
          amount: 50000,
          currency: 'NGN',
          qr_code: `FARMLE-RECEIPT:${paymentRef}:${bookingId}`
        })
        .select()
        .single();

      expect(error).toBeNull();
      expect(receipt).toBeTruthy();
      expect(receipt?.payment_reference).toBe(paymentRef);
      expect(receipt?.receipt_number).toMatch(/^RCP-\d{8}-\d{4}$/);
      
      testReceiptId = receipt?.id;
    }, 10000); // Increase timeout
  });

  describe('Property 53: Receipt Content Completeness', () => {
    it('should include all required fields', async () => {
      if (!testReceiptId) return;

      const { data: receipt } = await supabase
        .from('payment_receipts')
        .select('*')
        .eq('id', testReceiptId)
        .single();

      expect(receipt).toHaveProperty('booking_id');
      expect(receipt).toHaveProperty('amount');
      expect(receipt).toHaveProperty('payment_reference');
      expect(receipt).toHaveProperty('generated_at');
      expect(receipt).toHaveProperty('currency', 'NGN');
    });
  });

  describe('Property 56: Receipt QR Code Inclusion', () => {
    it('should include QR code data', async () => {
      if (!testReceiptId) return;

      const { data: receipt } = await supabase
        .from('payment_receipts')
        .select('qr_code')
        .eq('id', testReceiptId)
        .single();

      expect(receipt?.qr_code).toBeTruthy();
      expect(receipt?.qr_code).toContain('FARMLE-RECEIPT');
    });
  });

  describe('Database Schema Validation', () => {
    it('should handle receipt number generation', async () => {
      // Test that receipt numbers are generated automatically
      const { data: receipt, error } = await supabase
        .from('payment_receipts')
        .insert({
          booking_id: bookingId,
          organization_id: organizationId,
          payment_reference: `test_auto_number_${suffix}`,
          amount: 25000,
          currency: 'NGN'
        })
        .select()
        .single();

      expect(error).toBeNull();
      expect(receipt?.receipt_number).toMatch(/^RCP-\d{8}-\d{4}$/);
      
      // Cleanup
      if (receipt?.id) {
        await supabase.from('payment_receipts').delete().eq('id', receipt.id);
      }
    });
  });

  // Cleanup
  afterAll(async () => {
    if (testReceiptId) {
      await supabase.from('payment_receipts').delete().eq('id', testReceiptId);
    }
    if (bookingId) {
      await supabase.from('payment_receipts').delete().eq('booking_id', bookingId);
      await supabase.from('bookings').delete().eq('id', bookingId);
    }
    if (propertyId) {
      await supabase.from('properties').delete().eq('id', propertyId);
    }
    if (testUserId) {
      await supabase.from('users').delete().eq('id', testUserId);
    }
  });
});
