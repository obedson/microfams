export interface PaymentReceipt {
  id: string;
  booking_id: string;
  payment_reference: string;
  receipt_number: string;
  amount: number;
  currency: string;
  generated_at: string;
  pdf_url?: string;
  qr_code?: string;
}
