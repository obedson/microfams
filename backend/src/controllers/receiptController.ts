import { Request, Response } from 'express';
import { supabase } from '../utils/supabase.js';
import { ReceiptService } from '../services/receiptService.js';
import { logger } from '../utils/logger.js';

const receiptService = new ReceiptService();

export const generateReceipt = async (req: Request, res: Response) => {
  const startTime = Date.now();
  const requestId = `req_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
  
  try {
    const { bookingId } = req.params;
    const { payment_reference, force } = req.body;
    const userId = (req as any).user.id;

    logger.info('Receipt generation started', {
      requestId,
      bookingId,
      payment_reference,
      userId,
      force,
      timestamp: new Date().toISOString()
    });

    if (!payment_reference) {
      // Try to get payment reference from booking if not provided
      const { data: booking } = await supabase
        .from('bookings')
        .select('payment_reference')
        .eq('id', bookingId)
        .single();
      
      if (!booking?.payment_reference) {
        logger.warn('Receipt generation failed - missing payment reference', {
          requestId,
          bookingId,
          userId
        });
        return res.status(400).json({ 
          error: 'Payment reference is required',
          requestId 
        });
      }
    }

    const receipt = await receiptService.generateReceipt(bookingId, payment_reference, force);

    if (!receipt) {
      logger.error('Receipt generation failed - service returned null', {
        requestId,
        bookingId,
        payment_reference
      });
      return res.status(500).json({ 
        error: 'Failed to generate receipt',
        requestId 
      });
    }

    logger.info('Receipt generated successfully', {
      requestId,
      receiptId: receipt.id,
      receipt_number: receipt.receipt_number,
      processingTime: Date.now() - startTime
    });

    res.json({
      success: true,
      receipt,
      requestId
    });

  } catch (error) {
    logger.error('Receipt generation error', {
      requestId,
      error: error instanceof Error ? error.message : 'Unknown error',
      stack: error instanceof Error ? error.stack : undefined,
      processingTime: Date.now() - startTime
    });
    
    res.status(500).json({ 
      error: 'Internal server error',
      requestId 
    });
  }
};

export const downloadReceipt = async (req: Request, res: Response) => {
  const startTime = Date.now();
  const requestId = `download_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
  
  try {
    const { bookingId } = req.params;
    const userId = (req as any).user.id;

    logger.info('Receipt download started', {
      requestId,
      bookingId,
      userId,
      userAgent: req.headers['user-agent'],
      ip: req.ip
    });

    // Verify user authorization and get booking status/reference
    const { data: booking, error: bookingError } = await supabase
      .from('bookings')
      .select('farmer_id, payment_status, payment_reference, properties(owner_id)')
      .eq('id', bookingId)
      .single();

    if (bookingError || !booking) {
      logger.warn('Receipt download failed - booking not found', {
        requestId,
        bookingId,
        error: bookingError,
        userId
      });
      return res.status(404).json({ 
        error: 'Booking not found',
        requestId 
      });
    }

    if (booking.farmer_id !== userId && (booking.properties as any)?.owner_id !== userId) {
      logger.warn('Receipt download failed - unauthorized', {
        requestId,
        bookingId,
        userId,
        farmer_id: booking.farmer_id,
        owner_id: (booking.properties as any)?.owner_id
      });
      return res.status(403).json({ 
        error: 'Access denied',
        requestId 
      });
    }

    if (booking.payment_status !== 'paid') {
      return res.status(400).json({
        error: 'Receipt only available for paid bookings. Current status: ' + booking.payment_status,
        requestId
      });
    }

    // Get receipt
    let { data: receipt, error: receiptError } = await supabase
      .from('payment_receipts')
      .select('*')
      .eq('booking_id', bookingId)
      .single();

    // If receipt doesn't exist but booking is paid, generate it automatically (Requirement 9.7)
    if (receiptError || !receipt) {
      if (!booking.payment_reference) {
        return res.status(400).json({
          error: 'Cannot generate receipt: Missing payment reference in booking.',
          requestId
        });
      }

      logger.info('Receipt not found for paid booking - generating automatically', {
        requestId,
        bookingId,
        payment_reference: booking.payment_reference
      });

      receipt = await receiptService.generateReceipt(bookingId, booking.payment_reference);
      
      if (!receipt) {
        return res.status(500).json({
          error: 'Failed to generate receipt. Please try again later.',
          requestId
        });
      }
    }

    // Generate simple text receipt for development if PDF is missing
    if (!receipt.pdf_url) {
      logger.info('PDF not found - generating text receipt', {
        requestId,
        receiptId: receipt.id,
        receipt_number: receipt.receipt_number
      });

      const textReceipt = `
MICROFARMS RECEIPT
==================
Receipt #: ${receipt.receipt_number}
Booking ID: ${bookingId}
Payment Reference: ${receipt.payment_reference}
Amount: ₦${receipt.amount.toLocaleString()}
Currency: ${receipt.currency}
Date: ${new Date(receipt.generated_at).toLocaleDateString()}
QR Code: ${receipt.qr_code || 'N/A'}

This is a development receipt.
For production, PDF generation will be enabled.

Generated: ${new Date().toLocaleString()}
Request ID: ${requestId}
      `;
      
      logger.info('Text receipt generated successfully', {
        requestId,
        receiptId: receipt.id,
        processingTime: Date.now() - startTime
      });

      res.setHeader('Content-Type', 'text/plain');
      res.setHeader('Content-Disposition', `attachment; filename="receipt-${receipt.receipt_number}.txt"`);
      return res.send(textReceipt);
    }

    // Log successful PDF download
    logger.info('Receipt PDF download successful', {
      requestId,
      receiptId: receipt.id,
      receipt_number: receipt.receipt_number,
      pdf_url: receipt.pdf_url,
      processingTime: Date.now() - startTime
    });

    // Generate a pre-signed URL (expires in 5 min) so the browser downloads directly from S3
    const { GetObjectCommand } = await import('@aws-sdk/client-s3');
    const { getSignedUrl } = await import('@aws-sdk/s3-request-presigner');
    const s3Client = (await import('../config/s3.js')).default;

    const key = receipt.pdf_url.split('.amazonaws.com/')[1];
    const signedUrl = await getSignedUrl(
      s3Client,
      new GetObjectCommand({
        Bucket: process.env.AWS_S3_BUCKET!,
        Key: key,
        ResponseContentDisposition: `attachment; filename="${receipt.receipt_number}.pdf"`,
      }),
      { expiresIn: 300 }
    );

    res.setHeader('Cache-Control', 'no-store');
    res.json({ success: true, url: signedUrl, filename: `${receipt.receipt_number}.pdf` });

  } catch (error) {
    logger.error('Receipt download error', {
      requestId,
      bookingId: req.params.bookingId,
      error: error instanceof Error ? error.message : 'Unknown error',
      stack: error instanceof Error ? error.stack : undefined,
      processingTime: Date.now() - startTime
    });
    
    res.status(500).json({ 
      error: 'Internal server error',
      requestId 
    });
  }
};
