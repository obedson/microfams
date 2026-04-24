import { createClient } from '@supabase/supabase-js';
import dotenv from 'dotenv';

dotenv.config();

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY
);

async function createReceiptTable() {
  console.log('Creating payment_receipts table...');
  
  try {
    // Create table directly using SQL
    const { error } = await supabase
      .from('payment_receipts')
      .select('*')
      .limit(1);

    if (error && error.code === 'PGRST116') {
      // Table doesn't exist, create it via raw SQL
      const { error: createError } = await supabase.rpc('exec_sql', {
        sql: `
          CREATE TABLE payment_receipts (
              id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
              booking_id UUID REFERENCES bookings(id) ON DELETE CASCADE,
              payment_reference VARCHAR(255) NOT NULL,
              receipt_number VARCHAR(100) UNIQUE NOT NULL,
              amount DECIMAL(10,2) NOT NULL,
              currency VARCHAR(3) DEFAULT 'NGN',
              pdf_url TEXT,
              qr_code_data TEXT,
              created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
              updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
          );
          
          CREATE INDEX idx_receipts_booking ON payment_receipts(booking_id);
          CREATE INDEX idx_receipts_payment_ref ON payment_receipts(payment_reference);
          CREATE UNIQUE INDEX idx_receipts_number ON payment_receipts(receipt_number);
        `
      });

      if (createError) {
        console.error('Error:', createError);
      } else {
        console.log('✅ Payment receipts table created successfully');
      }
    } else {
      console.log('✅ Payment receipts table already exists');
    }
  } catch (err) {
    console.error('Error:', err);
  }
}

createReceiptTable();
