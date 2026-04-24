import React, { useState, useEffect } from 'react';
import { useAuthStore } from '../store/authStore';
import { communicationAPI, Message } from '../services/communicationAPI';
import { InAppMessaging } from '../components/communication';
import { ArrowLeft, Mail, MailOpen } from 'lucide-react';

const MessagesPage: React.FC = () => {
  const { user } = useAuthStore();
  const [conversations, setConversations] = useState<any[]>([]);
  const [selectedConversation, setSelectedConversation] = useState<any>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (user) {
      fetchConversations();
    }
  }, [user]);

  const fetchConversations = async () => {
    try {
      setLoading(true);
      const response = await communicationAPI.getAllUserMessages();
      
      // Group messages by booking_id to create conversations
      const conversationMap = new Map();
      
      response.messages.forEach((message: Message) => {
        const bookingId = message.booking_id;
        if (!conversationMap.has(bookingId)) {
          conversationMap.set(bookingId, {
            bookingId,
            lastMessage: message,
            participant: message.sender_id === user?.id ? message.recipient : message.sender,
            unreadCount: 0
          });
        }
        
        const conversation = conversationMap.get(bookingId);
        if (message.sent_at > conversation.lastMessage.sent_at) {
          conversation.lastMessage = message;
        }
        
        if (!message.read_at && message.recipient_id === user?.id) {
          conversation.unreadCount++;
        }
      });
      
      setConversations(Array.from(conversationMap.values()));
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load conversations');
    } finally {
      setLoading(false);
    }
  };

  const handleConversationClick = (conversation: any) => {
    setSelectedConversation(conversation);
  };

  const handleBackToList = () => {
    setSelectedConversation(null);
    fetchConversations(); // Refresh to update unread counts
  };

  if (!user) {
    return <div className="container py-8">Please log in to view messages.</div>;
  }

  if (loading) {
    return <div className="container py-8">Loading messages...</div>;
  }

  if (error) {
    return <div className="container py-8 text-red-600">Error: {error}</div>;
  }

  return (
    <div className="container py-8">
      <div className="max-w-4xl mx-auto">
        {selectedConversation ? (
          <div className="bg-white rounded-lg shadow-sm border">
            <div className="p-4 border-b flex items-center gap-4">
              <button
                onClick={handleBackToList}
                className="p-2 hover:bg-gray-100 rounded-lg"
              >
                <ArrowLeft size={20} />
              </button>
              <h2 className="text-xl font-semibold">
                Conversation with {selectedConversation.participant.name}
              </h2>
            </div>
            <div className="h-96">
              <InAppMessaging
                bookingId={selectedConversation.bookingId}
                currentUserId={user.id}
                currentUserName={user.name}
                recipientId={selectedConversation.participant.id}
                recipientName={selectedConversation.participant.name}
                onClose={handleBackToList}
              />
            </div>
          </div>
        ) : (
          <div className="bg-white rounded-lg shadow-sm border">
            <div className="p-6 border-b">
              <h1 className="text-2xl font-bold">Messages</h1>
              <p className="text-gray-600 mt-1">View and manage your conversations</p>
            </div>
            
            <div className="divide-y">
              {conversations.length === 0 ? (
                <div className="p-8 text-center text-gray-500">
                  <Mail size={48} className="mx-auto mb-4 text-gray-300" />
                  <p>No messages yet</p>
                </div>
              ) : (
                conversations.map((conversation) => (
                  <div
                    key={conversation.bookingId}
                    onClick={() => handleConversationClick(conversation)}
                    className="p-4 hover:bg-gray-50 cursor-pointer flex items-center gap-4"
                  >
                    <div className="flex-shrink-0">
                      {conversation.unreadCount > 0 ? (
                        <Mail size={24} className="text-blue-600" />
                      ) : (
                        <MailOpen size={24} className="text-gray-400" />
                      )}
                    </div>
                    
                    <div className="flex-1 min-w-0">
                      <div className="flex items-center justify-between">
                        <h3 className="font-medium text-gray-900">
                          {conversation.participant.name}
                        </h3>
                        <span className="text-sm text-gray-500">
                          {new Date(conversation.lastMessage.sent_at).toLocaleDateString()}
                        </span>
                      </div>
                      
                      <p className="text-sm text-gray-600 truncate mt-1">
                        {conversation.lastMessage.content}
                      </p>
                      
                      <p className="text-xs text-gray-400 mt-1">
                        Booking: {conversation.bookingId.slice(-8).toUpperCase()}
                      </p>
                    </div>
                    
                    {conversation.unreadCount > 0 && (
                      <div className="flex-shrink-0">
                        <span className="bg-red-500 text-white text-xs rounded-full h-5 w-5 flex items-center justify-center">
                          {conversation.unreadCount}
                        </span>
                      </div>
                    )}
                  </div>
                ))
              )}
            </div>
          </div>
        )}
      </div>
    </div>
  );
};

export default MessagesPage;
