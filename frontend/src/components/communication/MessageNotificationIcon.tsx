import React, { useState, useEffect } from 'react';
import { Mail } from 'lucide-react';
import { useNavigate } from 'react-router-dom';
import { communicationAPI } from '../../services/communicationAPI';

interface MessageNotificationIconProps {
  currentUserId: string;
}

const MessageNotificationIcon: React.FC<MessageNotificationIconProps> = ({ currentUserId }) => {
  const [unreadCount, setUnreadCount] = useState(0);
  const navigate = useNavigate();

  useEffect(() => {
    const fetchUnreadCount = async () => {
      try {
        const response = await communicationAPI.getUnreadMessages();
        setUnreadCount(response.messages.length);
      } catch (error) {
        console.error('Failed to fetch unread count:', error);
      }
    };

    fetchUnreadCount();
    const interval = setInterval(fetchUnreadCount, 30000); // Check every 30 seconds

    return () => clearInterval(interval);
  }, [currentUserId]);

  const handleClick = () => {
    navigate('/messages');
  };

  return (
    <button 
      onClick={handleClick}
      className="relative p-2 hover:bg-gray-100 rounded-lg transition-colors"
      title="Messages"
    >
      <Mail size={20} className="text-gray-600" />
      {unreadCount > 0 && (
        <span className="absolute -top-1 -right-1 bg-red-500 text-white text-xs rounded-full h-5 w-5 flex items-center justify-center font-medium">
          {unreadCount > 9 ? '9+' : unreadCount}
        </span>
      )}
    </button>
  );
};

export default MessageNotificationIcon;
