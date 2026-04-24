import React, { useState, useEffect } from 'react';
import { communicationAPI, Message } from '../../services/communicationAPI';

interface UnreadMessagesProps {
  currentUserId: string;
  onMessageClick?: (message: Message) => void;
  onClose?: () => void;
}

const UnreadMessages: React.FC<UnreadMessagesProps> = ({
  currentUserId,
  onMessageClick,
  onClose
}) => {
  const [unreadMessages, setUnreadMessages] = useState<Message[]>([]);
  const [unreadCount, setUnreadCount] = useState(0);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    fetchUnreadMessages();
    
    // Poll for new messages every 30 seconds
    const interval = setInterval(fetchUnreadMessages, 30000);
    return () => clearInterval(interval);
  }, []);

  const fetchUnreadMessages = async () => {
    try {
      setLoading(true);
      const response = await communicationAPI.getUnreadMessages();
      setUnreadMessages(response.messages);
      setUnreadCount(response.unread_count);
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load unread messages');
    } finally {
      setLoading(false);
    }
  };

  const handleMarkAsRead = async (messageId: string) => {
    try {
      await communicationAPI.markMessageAsRead(messageId);
      await fetchUnreadMessages(); // Refresh the list
    } catch (err) {
      console.error('Failed to mark message as read:', err);
    }
  };

  if (loading && unreadMessages.length === 0) {
    return <div className="unread-messages loading">Loading messages...</div>;
  }

  if (error) {
    return <div className="unread-messages error">Error: {error}</div>;
  }

  if (unreadCount === 0) {
    return null; // Don't show component if no unread messages
  }

  return (
    <div className="unread-messages">
      <div className="unread-header">
        <h4>Unread Messages ({unreadCount})</h4>
        {onClose && (
          <button onClick={onClose} className="close-button">×</button>
        )}
      </div>
      
      <div className="unread-list">
        {unreadMessages.map((message) => (
          <div 
            key={message.id} 
            className="unread-message-item"
            onClick={() => onMessageClick?.(message)}
          >
            <div className="message-preview">
              <div className="sender-info">
                <strong>{message.sender.name}</strong>
                <span className="message-time">
                  {new Date(message.sent_at).toLocaleString()}
                </span>
              </div>
              <div className="message-content">
                {message.content.length > 100 
                  ? `${message.content.substring(0, 100)}...` 
                  : message.content
                }
              </div>
              <div className="booking-info">
                Booking: {message.booking_id}
              </div>
            </div>
            
            <button 
              className="mark-read-btn"
              onClick={(e) => {
                e.stopPropagation();
                handleMarkAsRead(message.id);
              }}
            >
              Mark as Read
            </button>
          </div>
        ))}
      </div>
    </div>
  );
};

export default UnreadMessages;
