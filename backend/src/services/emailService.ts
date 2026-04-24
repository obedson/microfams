import * as brevo from '@getbrevo/brevo';

const apiInstance = new brevo.TransactionalEmailsApi();

// Only initialize if API key exists
if (process.env.BREVO_API_KEY) {
  apiInstance.setApiKey(brevo.TransactionalEmailsApiApiKeys.apiKey, process.env.BREVO_API_KEY);
} else {
  console.warn('⚠️  BREVO_API_KEY not configured - emails will be logged only');
}

export const sendPasswordResetEmail = async (email: string, resetToken: string) => {
  const resetUrl = `${process.env.FRONTEND_URL || 'http://localhost:3001'}/reset-password?token=${resetToken}`;
  
  if (!process.env.BREVO_API_KEY) {
    console.log(`[Email skipped] Password reset to: ${email}`);
    return;
  }

  const sendSmtpEmail = new brevo.SendSmtpEmail();
  sendSmtpEmail.to = [{ email }];
  sendSmtpEmail.sender = { 
    email: process.env.FROM_EMAIL || 'obedsonfield@gmail.com',
    name: 'Micro Fams'
  };
  sendSmtpEmail.subject = 'Reset Your Password';
  sendSmtpEmail.htmlContent = `
    <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
      <h2>Reset Your Password</h2>
      <p>You requested to reset your password. Click the button below to reset it:</p>
      <a href="${resetUrl}" style="background-color: #10b981; color: white; padding: 12px 24px; text-decoration: none; border-radius: 6px; display: inline-block; margin: 20px 0;">
        Reset Password
      </a>
      <p>If the button doesn't work, copy and paste this link into your browser:</p>
      <p><a href="${resetUrl}">${resetUrl}</a></p>
      <p>This link will expire in 1 hour.</p>
      <p>If you didn't request this, please ignore this email.</p>
    </div>
  `;

  try {
    await apiInstance.sendTransacEmail(sendSmtpEmail);
    console.log(`✅ Password reset email sent to: ${email}`);
  } catch (error: any) {
    console.error('❌ Email sending failed:', error?.response?.body || error.message);
    // Don't throw - just log
  }
};

const emailTemplates = {
  'new-booking': (data: any) => `
    <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
      <h2>New Booking Request</h2>
      <p>You have received a new booking request for your property:</p>
      <div style="background-color: #f3f4f6; padding: 20px; border-radius: 8px; margin: 20px 0;">
        <p><strong>Property:</strong> ${data.propertyTitle}</p>
        <p><strong>Farmer:</strong> ${data.farmerName}</p>
        <p><strong>Check-in:</strong> ${new Date(data.startDate).toLocaleDateString()}</p>
        <p><strong>Check-out:</strong> ${new Date(data.endDate).toLocaleDateString()}</p>
        <p><strong>Amount:</strong> ₦${data.amount.toLocaleString()}</p>
      </div>
      <p>Please log in to your dashboard to review and respond to this booking request.</p>
      <a href="${process.env.FRONTEND_URL}/dashboard" style="background-color: #10b981; color: white; padding: 12px 24px; text-decoration: none; border-radius: 6px; display: inline-block; margin: 20px 0;">
        View Booking
      </a>
    </div>
  `,
  'booking-status-update': (data: any) => `
    <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
      <h2>Booking ${data.status === 'confirmed' ? 'Confirmed' : 'Update'}</h2>
      <p>Your booking for <strong>${data.propertyTitle}</strong> has been ${data.status}.</p>
      <div style="background-color: #f3f4f6; padding: 20px; border-radius: 8px; margin: 20px 0;">
        <p><strong>Status:</strong> <span style="color: ${data.status === 'confirmed' ? '#10b981' : '#ef4444'}; text-transform: uppercase;">${data.status}</span></p>
        <p><strong>Check-in:</strong> ${new Date(data.startDate).toLocaleDateString()}</p>
        <p><strong>Check-out:</strong> ${new Date(data.endDate).toLocaleDateString()}</p>
        ${data.rejectionReason ? `<p><strong>Reason:</strong> ${data.rejectionReason}</p>` : ''}
      </div>
      ${data.status === 'confirmed' ? '<p>Please proceed with payment to complete your booking.</p>' : ''}
      <a href="${process.env.FRONTEND_URL}/my-bookings" style="background-color: #10b981; color: white; padding: 12px 24px; text-decoration: none; border-radius: 6px; display: inline-block; margin: 20px 0;">
        View Booking
      </a>
    </div>
  `,
  'booking-cancelled': (data: any) => `
    <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
      <h2>Booking Cancelled</h2>
      <p>A booking for <strong>${data.propertyTitle}</strong> has been cancelled by the ${data.cancelledBy}.</p>
      <div style="background-color: #f3f4f6; padding: 20px; border-radius: 8px; margin: 20px 0;">
        <p><strong>Check-in:</strong> ${new Date(data.startDate).toLocaleDateString()}</p>
        <p><strong>Check-out:</strong> ${new Date(data.endDate).toLocaleDateString()}</p>
        ${data.reason ? `<p><strong>Reason:</strong> ${data.reason}</p>` : ''}
      </div>
      <a href="${process.env.FRONTEND_URL}/dashboard" style="background-color: #10b981; color: white; padding: 12px 24px; text-decoration: none; border-radius: 6px; display: inline-block; margin: 20px 0;">
        Go to Dashboard
      </a>
    </div>
  `,
  'payment-receipt': (data: any) => `
    <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; border: 1px solid #e5e7eb; border-radius: 12px; overflow: hidden;">
      <div style="background-color: #22c55e; color: white; padding: 30px; text-align: center;">
        <h1 style="margin: 0; font-size: 28px;">Payment Successful!</h1>
        <p style="margin: 10px 0 0 0; opacity: 0.9;">Thank you for your booking on Micro Fams</p>
      </div>
      <div style="padding: 30px;">
        <h2 style="color: #374151; margin-top: 0;">Receipt #${data.receiptNumber}</h2>
        <p>Hello ${data.farmerName},</p>
        <p>Your payment for <strong>${data.propertyTitle}</strong> has been successfully processed. Attached to this email is your official digital receipt.</p>
        
        <div style="background-color: #f9fafb; padding: 20px; border-radius: 8px; margin: 25px 0; border: 1px solid #f3f4f6;">
          <div style="margin-bottom: 10px; display: flex; justify-content: space-between;">
            <span style="color: #6b7280;">Amount Paid:</span>
            <span style="font-weight: bold; color: #111827;">₦${data.amount.toLocaleString()}</span>
          </div>
          <div style="margin-bottom: 10px; display: flex; justify-content: space-between;">
            <span style="color: #6b7280;">Payment Ref:</span>
            <span style="font-family: monospace; color: #111827;">${data.paymentReference}</span>
          </div>
          <div style="display: flex; justify-content: space-between;">
            <span style="color: #6b7280;">Date:</span>
            <span style="color: #111827;">${new Date().toLocaleDateString()}</span>
          </div>
        </div>

        <div style="text-align: center; margin: 30px 0;">
          <a href="${data.pdfUrl}" style="background-color: #22c55e; color: white; padding: 14px 28px; text-decoration: none; border-radius: 8px; font-weight: bold; display: inline-block;">
            Download PDF Receipt
          </a>
        </div>

        <p style="color: #6b7280; font-size: 14px; line-height: 1.5;">
          You can also access this receipt anytime by logging into your <a href="${process.env.FRONTEND_URL}/my-bookings" style="color: #22c55e; text-decoration: none;">Micro Fams Dashboard</a>.
        </p>
      </div>
      <div style="background-color: #f3f4f6; padding: 20px; text-align: center; color: #9ca3af; font-size: 12px;">
        <p style="margin: 0;">&copy; ${new Date().getFullYear()} Micro Fams Platform. All rights reserved.</p>
        <p style="margin: 5px 0 0 0;">Ensuring food security through technology.</p>
      </div>
    </div>
  `
};

export const sendEmail = async ({ 
  to, 
  subject, 
  html, 
  template, 
  data 
}: { 
  to: string; 
  subject: string; 
  html?: string;
  template?: string;
  data?: any;
}) => {
  // Skip email if API key not configured
  if (!process.env.BREVO_API_KEY) {
    console.log(`[Email skipped] To: ${to}, Subject: ${subject}`);
    return;
  }

  const sendSmtpEmail = new brevo.SendSmtpEmail();
  sendSmtpEmail.to = [{ email: to }];
  sendSmtpEmail.sender = { 
    email: process.env.FROM_EMAIL || 'obedsonfield@gmail.com',
    name: 'Micro Fams'
  };
  sendSmtpEmail.subject = subject;
  
  // Use template if provided, otherwise use html
  if (template && emailTemplates[template as keyof typeof emailTemplates]) {
    sendSmtpEmail.htmlContent = emailTemplates[template as keyof typeof emailTemplates](data);
  } else {
    sendSmtpEmail.htmlContent = html || '';
  }

  try {
    await apiInstance.sendTransacEmail(sendSmtpEmail);
    console.log(`✅ Email sent to: ${to} - ${subject}`);
  } catch (error: any) {
    console.error('❌ Email sending failed:', error?.response?.body || error.message);
    // Don't throw - just log the error
  }
};
