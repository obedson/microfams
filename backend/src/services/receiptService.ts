import puppeteer from 'puppeteer';
import QRCode from 'qrcode';
import { supabase } from '../utils/supabase.js';
import { logger } from '../utils/logger.js';
import { PaymentReceipt } from '../models/Receipt.js';
import { sendEmail } from './emailService.js';

export class ReceiptService {
  
  async generateReceipt(bookingId: string, paymentReference: string, force: boolean = false): Promise<PaymentReceipt | null> {
    try {
      // Check if receipt already exists and not forced
      if (!force) {
        const { data: existingReceipt } = await supabase
          .from('payment_receipts')
          .select('*')
          .eq('booking_id', bookingId)
          .eq('payment_reference', paymentReference)
          .single();

        if (existingReceipt) {
          return existingReceipt;
        }
      }

      // Get booking details with farmer and owner information
      const { data: booking, error: bookingError } = await supabase
        .from('bookings')
        .select(`
          *,
          properties (title, city, lga, owner_id, users!properties_owner_id_fkey (name, email, phone)),
          users!bookings_farmer_id_fkey (name, email, phone)
        `)
        .eq('id', bookingId)
        .single();

      if (bookingError || !booking) {
        logger.error('Booking not found for receipt generation:', bookingError);
        return null;
      }

      // Generate QR code data
      const qrData = `MICROFAMS-RECEIPT:${paymentReference}:${bookingId}`;
      const qrCodeDataURL = await QRCode.toDataURL(qrData);

      let receipt;
      if (force) {
        // If forcing, we might want to update the existing one or delete it first
        // For simplicity, we'll try to get the existing receipt ID
        const { data: existing } = await supabase
          .from('payment_receipts')
          .select('id, receipt_number')
          .eq('booking_id', bookingId)
          .single();

        if (existing) {
          const { data: updated, error: updateError } = await supabase
            .from('payment_receipts')
            .update({
              payment_reference: paymentReference,
              amount: booking.total_amount,
              qr_code: qrData,
              generated_at: new Date().toISOString()
            })
            .eq('id', existing.id)
            .select()
            .single();
          
          if (updateError) throw updateError;
          receipt = updated;
        }
      }

      if (!receipt) {
        // Create new receipt record
        const { data: newReceipt, error: receiptError } = await supabase
          .from('payment_receipts')
          .insert({
            booking_id: bookingId,
            payment_reference: paymentReference,
            amount: booking.total_amount,
            currency: 'NGN',
            qr_code: qrData
          })
          .select()
          .single();

        if (receiptError) {
          logger.error('Error creating receipt record:', receiptError);
          return null;
        }
        receipt = newReceipt;
      }

      // Generate PDF
      const pdfBuffer = await this.generatePDF(booking, receipt, qrCodeDataURL);
      
      // Upload PDF to S3
      const pdfUrl = await this.uploadPDF(pdfBuffer, receipt.receipt_number);

      // Update receipt with PDF URL
      const { data: updatedReceipt, error: updateError } = await supabase
        .from('payment_receipts')
        .update({ pdf_url: pdfUrl })
        .eq('id', receipt.id)
        .select()
        .single();

      if (updateError) {
        logger.error('Error updating receipt PDF URL:', updateError);
        return receipt;
      }

      // Automatically email the receipt (Requirement 9.6)
      await this.sendReceiptEmail(booking, updatedReceipt);

      return updatedReceipt;

    } catch (error) {
      logger.error('Receipt generation error:', error);
      return null;
    }
  }

  private async sendReceiptEmail(booking: any, receipt: any) {
    const farmerName = booking.users?.name || 'Farmer';
    const farmerEmail = booking.users?.email;

    if (!farmerEmail) {
      logger.warn('No farmer email found for sending receipt');
      return;
    }

    try {
      await sendEmail({
        to: farmerEmail,
        subject: `Payment Receipt - ${receipt.receipt_number}`,
        template: 'payment-receipt',
        data: {
          farmerName: farmerName,
          propertyTitle: booking.properties?.title || 'Property',
          amount: receipt.amount,
          receiptNumber: receipt.receipt_number,
          paymentReference: receipt.payment_reference,
          pdfUrl: receipt.pdf_url
        }
      });
      logger.info(`Receipt email sent to ${farmerEmail}`);
    } catch (error) {
      logger.error('Failed to send receipt email:', error);
    }
  }

  private async generatePDF(booking: any, receipt: any, qrCodeDataURL: string): Promise<Uint8Array> {
    const browser = await puppeteer.launch({ headless: true });
    const page = await browser.newPage();

    const html = `
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="utf-8">
        <style>
          body { font-family: Arial, sans-serif; margin: 0; padding: 20px; }
          .header { text-align: center; border-bottom: 2px solid #22c55e; padding-bottom: 20px; margin-bottom: 30px; }
          .logo { color: #22c55e; font-size: 32px; font-weight: bold; }
          .receipt-title { color: #374151; font-size: 24px; margin: 10px 0; }
          .receipt-number { color: #6b7280; font-size: 14px; }
          .content { display: flex; justify-content: space-between; margin-bottom: 30px; }
          .section { flex: 1; margin-right: 20px; }
          .section h3 { color: #374151; border-bottom: 1px solid #e5e7eb; padding-bottom: 5px; }
          .field { margin: 8px 0; }
          .label { font-weight: bold; color: #6b7280; }
          .value { color: #374151; }
          .amount { text-align: center; background: #f0fdf4; padding: 20px; border-radius: 8px; margin: 20px 0; }
          .amount-value { font-size: 36px; font-weight: bold; color: #22c55e; }
          .qr-section { text-align: center; margin-top: 30px; }
          .footer { text-align: center; margin-top: 40px; padding-top: 20px; border-top: 1px solid #e5e7eb; color: #6b7280; font-size: 12px; }
        </style>
      </head>
      <body>
        <div class="header">
          <div class="logo">🌾 MICRO FAMS</div>
          <div class="receipt-title">Payment Receipt</div>
          <div class="receipt-number">Receipt #${receipt.receipt_number}</div>
        </div>

        <div class="content">
          <div class="section">
            <h3>Booking Details</h3>
            <div class="field">
              <span class="label">Property:</span>
              <span class="value">${booking.properties?.title || 'N/A'}</span>
            </div>
            <div class="field">
              <span class="label">Location:</span>
              <span class="value">${booking.properties?.city}, ${booking.properties?.lga}</span>
            </div>
            <div class="field">
              <span class="label">Check-in:</span>
              <span class="value">${new Date(booking.start_date).toLocaleDateString()}</span>
            </div>
            <div class="field">
              <span class="label">Check-out:</span>
              <span class="value">${new Date(booking.end_date).toLocaleDateString()}</span>
            </div>
          </div>

          <div class="section">
            <h3>Payment Information</h3>
            <div class="field">
              <span class="label">Reference:</span>
              <span class="value">${receipt.payment_reference}</span>
            </div>
            <div class="field">
              <span class="label">Date:</span>
              <span class="value">${new Date(receipt.generated_at).toLocaleDateString()}</span>
            </div>
            <div class="field">
              <span class="label">Method:</span>
              <span class="value">Paystack</span>
            </div>
            <div class="field">
              <span class="label">Status:</span>
              <span class="value">Paid</span>
            </div>
          </div>
        </div>

        <div class="amount">
          <div>Total Amount Paid</div>
          <div class="amount-value">₦${booking.total_amount?.toLocaleString()}</div>
        </div>

        <div class="qr-section">
          <p>Scan QR code for verification:</p>
          <img src="${qrCodeDataURL}" alt="QR Code" style="width: 120px; height: 120px;">
        </div>

        <div class="footer">
          <p>This is an official receipt from Micro Fams Platform</p>
          <p>Generated on ${new Date().toLocaleString()}</p>
          <p>For support, contact: support@microfams.com</p>
        </div>
      </body>
      </html>
    `;

    await page.setContent(html);
    const pdfBuffer = await page.pdf({
      format: 'A4',
      printBackground: true,
      margin: { top: '20px', bottom: '20px', left: '20px', right: '20px' }
    });

    await browser.close();
    return pdfBuffer;
  }

  private async uploadPDF(pdfBuffer: Uint8Array, receiptNumber: string): Promise<string> {
    const { PutObjectCommand } = await import('@aws-sdk/client-s3');
    const s3Client = (await import('../config/s3.js')).default;

    const fileName = `receipts/${receiptNumber}.pdf`;
    
    await s3Client.send(new PutObjectCommand({
      Bucket: process.env.AWS_S3_BUCKET!,
      Key: fileName,
      Body: pdfBuffer,
      ContentType: 'application/pdf',
      ContentDisposition: `attachment; filename="${receiptNumber}.pdf"`,
    }));
    
    return `https://${process.env.AWS_S3_BUCKET}.s3.${process.env.AWS_REGION}.amazonaws.com/${fileName}`;
  }
}
