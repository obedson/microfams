import { supabase } from '../src/config/database.js';

async function createReceiptTable() {
  console.log('Creating payment_receipts table...');
  
  // Create the table using raw SQL
  const createTableSQL = `
    CREATE TABLE IF NOT EXISTS payment_receipts (
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
    
    CREATE INDEX IF NOT EXISTS idx_receipts_booking ON payment_receipts(booking_id);
    CREATE INDEX IF NOT EXISTS idx_receipts_payment_ref ON payment_receipts(payment_reference);
    CREATE UNIQUE INDEX IF NOT EXISTS idx_receipts_number ON payment_receipts(receipt_number);
  `;

  try {
    const { error } = await supabase.rpc('exec_sql', { sql: createTableSQL });
    
    if (error) {
      console.error('Error creating table:', error);
    } else {
      console.log('✅ Payment receipts table created successfully');
    }
  } catch (err) {
    console.error('Error:', err);
  }
}

createReceiptTable();
