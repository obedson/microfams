import { createClient } from '@supabase/supabase-js';

const supabase = createClient(
  process.env.SUPABASE_URL!,
  process.env.SUPABASE_SERVICE_KEY!
);

async function createReceiptSchema() {
  console.log('Creating payment_receipts table...');
  
  const { error } = await supabase.rpc('exec_sql', {
    sql: `
      -- New receipt records table (for PDF receipt generation)
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

      -- Function to generate unique receipt numbers
      CREATE OR REPLACE FUNCTION generate_receipt_number() RETURNS TEXT AS $$
      DECLARE
          receipt_num TEXT;
          counter INTEGER := 1;
      BEGIN
          LOOP
              receipt_num := 'RCP-' || TO_CHAR(NOW(), 'YYYYMMDD') || '-' || LPAD(counter::TEXT, 4, '0');
              
              IF NOT EXISTS (SELECT 1 FROM payment_receipts WHERE receipt_number = receipt_num) THEN
                  RETURN receipt_num;
              END IF;
              
              counter := counter + 1;
          END LOOP;
      END;
      $$ LANGUAGE plpgsql;

      -- Trigger to auto-generate receipt numbers
      CREATE OR REPLACE FUNCTION auto_generate_receipt_number() RETURNS TRIGGER AS $$
      BEGIN
          IF NEW.receipt_number IS NULL THEN
              NEW.receipt_number := generate_receipt_number();
          END IF;
          RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER receipt_number_trigger
          BEFORE INSERT ON payment_receipts
          FOR EACH ROW
          EXECUTE FUNCTION auto_generate_receipt_number();
    `
  });

  if (error) {
    console.error('Error creating schema:', error);
  } else {
    console.log('✅ Receipt schema created successfully');
  }
}

createReceiptSchema();
