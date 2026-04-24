import { describe, it, expect } from '@jest/globals';
import { supabase } from '../utils/supabase.js';

describe('Receipt System - Database Only Tests', () => {
  let testReceiptId: string;

  describe('Property 52: Receipt Generation on Payment', () => {
    it('should create receipt record in database', async () => {
      const paymentRef = 'test_ref_' + Date.now();
      
      const { data: receipt, error } = await supabase
        .from('payment_receipts')
        .insert({
          booking_id: '83517c07-8cfe-464d-b84f-797c5386d8b6', // Real booking ID with paid status
          payment_reference: paymentRef,
          amount: 50000,
          currency: 'NGN',
          qr_code: `FARMLE-RECEIPT:${paymentRef}:83517c07-8cfe-464d-b84f-797c5386d8b6`
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
          booking_id: '83517c07-8cfe-464d-b84f-797c5386d8b6',
          payment_reference: 'test_auto_number',
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
  });
});
