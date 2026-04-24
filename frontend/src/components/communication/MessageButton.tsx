import React, { useState } from 'react';
import InAppMessaging from './InAppMessaging';

interface MessageButtonProps {
  userType: 'farmer' | 'owner';
  bookingStatus: 'pending_payment' | 'pending' | 'confirmed' | 'cancelled' | 'completed';
  bookingId: string;
  currentUserId: string;
  currentUserName: string;
  recipientId: string;
  recipientName: string;
  recipientEmail?: string;
  recipientPhone?: string;
  bookingReference: string;
  propertyName: string;
  onMessageClick?: () => void;
}

const MessageButton: React.FC<MessageButtonProps> = ({
  userType,
  bookingStatus,
  bookingId,
  currentUserId,
  currentUserName,
  recipientId,
  recipientName,
  recipientEmail,
  recipientPhone,
  bookingReference,
  propertyName,
  onMessageClick
}) => {
  const [showMessaging, setShowMessaging] = useState(false);

  // Property 45: Message Button Availability for Farmers
  const shouldShowMessageOwnerButton = userType === 'farmer' && 
    (bookingStatus === 'confirmed' || bookingStatus === 'pending');

  // Property 46: Message Button Availability for Owners  
  const shouldShowMessageFarmerButton = userType === 'owner' && 
    (bookingStatus === 'pending_payment' || bookingStatus === 'pending' || bookingStatus === 'confirmed');

  const shouldShowButton = shouldShowMessageOwnerButton || shouldShowMessageFarmerButton;

  if (!shouldShowButton) {
    return null;
  }

  // Property 47: Email Client Integration
  const handleEmailClick = () => {
    if (recipientEmail) {
      const subject = `Booking ${bookingReference} - ${propertyName}`;
      const mailtoLink = `mailto:${recipientEmail}?subject=${encodeURIComponent(subject)}`;
      window.location.href = mailtoLink;
    }
  };

  // Property 48: Phone Contact Display
  const handlePhoneClick = () => {
    if (recipientPhone) {
      window.location.href = `tel:${recipientPhone}`;
    }
  };

  const handleMessageClick = () => {
    onMessageClick?.();
    setShowMessaging(true);
  };

  const buttonText = userType === 'farmer' ? 'Message Owner' : 'Message Farmer';

  return (
    <>
      <div className="message-button-container">
        <button 
          onClick={handleMessageClick}
          className="message-button primary"
        >
          {buttonText}
        </button>
        
        {/* Contact Information Display */}
        <div className="contact-options">
          {recipientEmail && (
            <button 
              onClick={handleEmailClick}
              className="contact-button email"
              title={`Email ${recipientName}`}
            >
              📧 Email
            </button>
          )}
          
          {recipientPhone && (
            <button 
              onClick={handlePhoneClick}
              className="contact-button phone"
              title={`Call ${recipientName}`}
            >
              📞 Call
            </button>
          )}
        </div>
      </div>

      {/* In-App Messaging Modal */}
      {showMessaging && (
        <div className="messaging-modal-overlay">
          <div className="messaging-modal">
            <InAppMessaging
              bookingId={bookingId}
              currentUserId={currentUserId}
              currentUserName={currentUserName}
              recipientId={recipientId}
              recipientName={recipientName}
              onClose={() => setShowMessaging(false)}
            />
          </div>
        </div>
      )}
    </>
  );
};

export default MessageButton;
