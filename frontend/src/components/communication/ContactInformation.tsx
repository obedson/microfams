import React from 'react';

interface ContactInfo {
  name: string;
  email?: string;
  phone?: string;
  role: 'farmer' | 'owner';
}

interface ContactInformationProps {
  farmerInfo: ContactInfo;
  ownerInfo: ContactInfo;
  bookingStatus: 'pending_payment' | 'pending' | 'confirmed' | 'cancelled' | 'completed';
  currentUserRole: 'farmer' | 'owner';
}

const ContactInformation: React.FC<ContactInformationProps> = ({
  farmerInfo,
  ownerInfo,
  bookingStatus,
  currentUserRole
}) => {
  // Property 48: Phone Contact Display
  // For any booking where contact information is available, phone contact links should be displayed
  const shouldShowContactInfo = bookingStatus === 'confirmed' || bookingStatus === 'pending';

  if (!shouldShowContactInfo) {
    return null;
  }

  const contactToShow = currentUserRole === 'farmer' ? ownerInfo : farmerInfo;
  const contactLabel = currentUserRole === 'farmer' ? 'Property Owner Contact' : 'Farmer Contact';

  return (
    <div className="contact-information">
      <h4>{contactLabel}</h4>
      
      <div className="contact-details">
        <div className="contact-name">
          <strong>{contactToShow.name}</strong>
        </div>
        
        {contactToShow.email && (
          <div className="contact-item">
            <span className="contact-label">Email:</span>
            <a 
              href={`mailto:${contactToShow.email}`}
              className="contact-link email"
            >
              {contactToShow.email}
            </a>
          </div>
        )}
        
        {contactToShow.phone && (
          <div className="contact-item">
            <span className="contact-label">Phone:</span>
            <a 
              href={`tel:${contactToShow.phone}`}
              className="contact-link phone"
            >
              {contactToShow.phone}
            </a>
          </div>
        )}
      </div>
    </div>
  );
};

export default ContactInformation;
