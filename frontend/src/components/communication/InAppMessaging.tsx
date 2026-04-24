import React, { useState, useEffect } from 'react';
import { communicationAPI, Message } from '../../services/communicationAPI';

interface InAppMessagingProps {
  bookingId: string;
  currentUserId: string;
  currentUserName: string;
  recipientId: string;
  recipientName: string;
  onClose: () => void;
}

const InAppMessaging: React.FC<InAppMessagingProps> = ({
  bookingId,
  currentUserId,
  currentUserName,
  recipientId,
  recipientName,
  onClose
}) => {
  const [messages, setMessages] = useState<Message[]>([]);
  const [newMessage, setNewMessage] = useState('');
  const [selectedFile, setSelectedFile] = useState<File | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Fetch messages on component mount
  useEffect(() => {
    fetchMessages();
  }, [bookingId]);

  const fetchMessages = async () => {
    try {
      setLoading(true);
      const response = await communicationAPI.getBookingMessages(bookingId);
      setMessages(response.messages);
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load messages');
    } finally {
      setLoading(false);
    }
  };

  const handleSendMessage = async () => {
    if (!newMessage.trim() && !selectedFile) return;

    try {
      setLoading(true);
      let mediaUrl = '';
      let mediaType = '';

      // Upload file if selected
      if (selectedFile) {
        const uploadResponse = await communicationAPI.uploadMedia(selectedFile);
        mediaUrl = uploadResponse.url;
        mediaType = selectedFile.type.startsWith('image/') ? 'image' : 
                   selectedFile.type.startsWith('video/') ? 'video' : 'file';
      }

      await communicationAPI.sendMessage({
        booking_id: bookingId,
        recipient_id: recipientId,
        content: newMessage.trim(),
        message_type: mediaUrl ? mediaType : 'text',
        media_url: mediaUrl,
        media_type: mediaType
      });
      
      setNewMessage('');
      setSelectedFile(null);
      await fetchMessages(); // Refresh messages
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to send message');
    } finally {
      setLoading(false);
    }
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      handleSendMessage();
    }
  };

  const handleFileSelect = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (file) {
      // Check file size (max 10MB)
      if (file.size > 10 * 1024 * 1024) {
        setError('File size must be less than 10MB');
        return;
      }
      setSelectedFile(file);
      setError(null);
    }
  };

  const renderMessage = (message: Message) => {
    const isOwn = message.sender_id === currentUserId;
    
    return (
      <div key={message.id} className={`message ${isOwn ? 'sent' : 'received'}`}>
        <div className="message-content">
          {message.media_url && (
            <div className="message-media">
              {message.media_type === 'image' && (
                <img 
                  src={message.media_url} 
                  alt="Shared image" 
                  className="max-w-xs rounded-lg cursor-pointer"
                  onClick={() => window.open(message.media_url, '_blank')}
                />
              )}
              {message.media_type === 'video' && (
                <video 
                  src={message.media_url} 
                  controls 
                  className="max-w-xs rounded-lg"
                />
              )}
            </div>
          )}
          {message.content && (
            <div className="message-text">{message.content}</div>
          )}
          <div className="message-meta">
            <span className="sender">{message.sender.name}</span>
            <span className="timestamp">
              {new Date(message.sent_at).toLocaleString()}
            </span>
            {message.read_at && <span className="read-status">Read</span>}
          </div>
        </div>
      </div>
    );
  };

  const markAsRead = async (messageId: string) => {
    try {
      await communicationAPI.markMessageAsRead(messageId);
      // Refresh messages to update read status
      await fetchMessages();
    } catch (err) {
      console.error('Failed to mark message as read:', err);
    }
  };

  // Mark unread messages as read when viewing
  useEffect(() => {
    const unreadMessages = messages.filter(
      msg => msg.recipient_id === currentUserId && !msg.read_at
    );
    
    unreadMessages.forEach(msg => {
      markAsRead(msg.id);
    });
  }, [messages, currentUserId]);

  return (
    <div className="in-app-messaging">
      <div className="messaging-header">
        <h3>Message with {recipientName}</h3>
        <button onClick={onClose} className="close-button">×</button>
      </div>

      {error && (
        <div className="error-message">
          {error}
        </div>
      )}

      <div className="message-history">
        {loading && messages.length === 0 ? (
          <div className="loading">Loading messages...</div>
        ) : messages.length === 0 ? (
          <div className="no-messages">No messages yet. Start the conversation!</div>
        ) : (
          messages.map(renderMessage)
        )}
      </div>

      <div className="message-input-container">
        {selectedFile && (
          <div className="selected-file">
            <span>{selectedFile.name}</span>
            <button onClick={() => setSelectedFile(null)}>×</button>
          </div>
        )}
        <div className="input-row">
          <textarea
            value={newMessage}
            onChange={(e) => setNewMessage(e.target.value)}
            onKeyDown={handleKeyDown}
            placeholder={`Type your message to ${recipientName}...`}
            className="message-input"
            rows={3}
            disabled={loading}
          />
          <div className="input-actions">
            <input
              type="file"
              id="file-input"
              accept="image/*,video/*"
              onChange={handleFileSelect}
              style={{ display: 'none' }}
            />
            <button
              type="button"
              onClick={() => document.getElementById('file-input')?.click()}
              className="attach-button"
              title="Attach image or video"
            >
              📎
            </button>
            <button 
              onClick={handleSendMessage}
              disabled={(!newMessage.trim() && !selectedFile) || loading}
              className="send-button"
            >
              {loading ? 'Sending...' : 'Send'}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
};

export default InAppMessaging;
