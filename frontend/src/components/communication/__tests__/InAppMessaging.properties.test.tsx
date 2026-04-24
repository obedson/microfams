import React from 'react';
import { render, screen, fireEvent, waitFor, act } from '@testing-library/react';
import '@testing-library/jest-dom';
import InAppMessaging from '../InAppMessaging';
import { communicationAPI } from '../../../services/communicationAPI';

// Mock the API
jest.mock('../../../services/communicationAPI', () => ({
  communicationAPI: {
    getBookingMessages: jest.fn(),
    sendMessage: jest.fn(),
    markMessageAsRead: jest.fn()
  }
}));

const mockMessages = [
  {
    id: 'msg-1',
    booking_id: 'booking-123',
    sender_id: 'user-1',
    recipient_id: 'user-2',
    content: 'Hello, I have a question about the property.',
    sent_at: '2024-01-15T10:00:00Z',
    read_at: '2024-01-15T10:05:00Z',
    sender: { id: 'user-1', name: 'John Farmer' },
    recipient: { id: 'user-2', name: 'Jane Owner' }
  },
  {
    id: 'msg-2',
    booking_id: 'booking-123',
    sender_id: 'user-2',
    recipient_id: 'user-1',
    content: 'Sure! What would you like to know?',
    sent_at: '2024-01-15T10:10:00Z',
    sender: { id: 'user-2', name: 'Jane Owner' },
    recipient: { id: 'user-1', name: 'John Farmer' }
  }
];

describe('InAppMessaging Properties Tests - Task 7.2', () => {
  const mockOnClose = jest.fn();

  beforeEach(() => {
    jest.clearAllMocks();
    (communicationAPI.getBookingMessages as jest.Mock).mockResolvedValue({
      success: true,
      messages: mockMessages
    });
    (communicationAPI.sendMessage as jest.Mock).mockResolvedValue({
      success: true,
      message: { id: 'msg-new', content: 'new' }
    });
    (communicationAPI.markMessageAsRead as jest.Mock).mockResolvedValue({
      success: true
    });
  });

  /**
   * Property 50: In-App Messaging Functionality
   * For any booking-related communication, messages should be sendable and receivable through the in-app messaging interface.
   * Validates: Requirements 8.6
   */
  test('Property 50: In-app messaging functionality works correctly', async () => {
    await act(async () => {
      render(
        <InAppMessaging
          bookingId="booking-123"
          currentUserId="user-1"
          currentUserName="John Farmer"
          recipientId="user-2"
          recipientName="Jane Owner"
          onClose={mockOnClose}
        />
      );
    });

    // Property: Message input is available
    const messageInput = screen.getByPlaceholderText('Type your message to Jane Owner...');
    expect(messageInput).toBeInTheDocument();

    // Property: Send button is available
    const sendButton = screen.getByText('Send');
    expect(sendButton).toBeInTheDocument();

    // Property: Send button is disabled when input is empty
    expect(sendButton).toBeDisabled();

    // Property: Messages can be sent through the interface
    fireEvent.change(messageInput, { target: { value: 'Test message' } });
    expect(sendButton).not.toBeDisabled();

    await act(async () => {
      fireEvent.click(sendButton);
    });
    
    expect(communicationAPI.sendMessage).toHaveBeenCalledWith(expect.objectContaining({
      content: 'Test message'
    }));

    // Property: Input is cleared after sending
    expect(messageInput).toHaveValue('');
  });

  /**
   * Property 51: Message History Linking
   * For any message sent through the system, it should be correctly linked to the specific booking and retrievable in message history.
   * Validates: Requirements 8.7
   */
  test('Property 51: Message history is correctly linked to specific booking', async () => {
    await act(async () => {
      render(
        <InAppMessaging
          bookingId="booking-123"
          currentUserId="user-1"
          currentUserName="John Farmer"
          recipientId="user-2"
          recipientName="Jane Owner"
          onClose={mockOnClose}
        />
      );
    });

    // Property: Messages for the specific booking are displayed
    await waitFor(() => {
      expect(screen.getByText('Hello, I have a question about the property.')).toBeInTheDocument();
      expect(screen.getByText('Sure! What would you like to know?')).toBeInTheDocument();
    });

    // Property: Messages are displayed with correct sender information
    expect(screen.getByText('John Farmer')).toBeInTheDocument();
    expect(screen.getByText('Jane Owner')).toBeInTheDocument();
  });

  /**
   * Additional Property: Message Status Display
   * For any message with read status, it should be displayed correctly.
   */
  test('Property: Message read status is displayed correctly', async () => {
    await act(async () => {
      render(
        <InAppMessaging
          bookingId="booking-123"
          currentUserId="user-1"
          currentUserName="John Farmer"
          recipientId="user-2"
          recipientName="Jane Owner"
          onClose={mockOnClose}
        />
      );
    });

    // Property: Read status is shown for read messages
    await waitFor(() => {
      expect(screen.getByText('Read')).toBeInTheDocument();
    });
  });

  /**
   * Additional Property: Empty Message History
   * For any booking with no messages, appropriate empty state should be displayed.
   */
  test('Property: Empty message history displays appropriate message', async () => {
    (communicationAPI.getBookingMessages as jest.Mock).mockResolvedValue({
      success: true,
      messages: []
    });

    await act(async () => {
      render(
        <InAppMessaging
          bookingId="booking-999"
          currentUserId="user-1"
          currentUserName="John Farmer"
          recipientId="user-2"
          recipientName="Jane Owner"
          onClose={mockOnClose}
        />
      );
    });

    // Property: Empty state message is displayed
    await waitFor(() => {
      expect(screen.getByText('No messages yet. Start the conversation!')).toBeInTheDocument();
    });
  });

  /**
   * Additional Property: Message Sending with Enter Key
   * For any message input, pressing Enter should send the message.
   */
  test('Property: Enter key sends message correctly', async () => {
    await act(async () => {
      render(
        <InAppMessaging
          bookingId="booking-123"
          currentUserId="user-1"
          currentUserName="John Farmer"
          recipientId="user-2"
          recipientName="Jane Owner"
          onClose={mockOnClose}
        />
      );
    });

    const messageInput = screen.getByPlaceholderText('Type your message to Jane Owner...');
    
    // Property: Enter key sends message
    fireEvent.change(messageInput, { target: { value: 'Enter key test' } });
    
    await act(async () => {
      fireEvent.keyDown(messageInput, { key: 'Enter', shiftKey: false });
    });
    
    expect(communicationAPI.sendMessage).toHaveBeenCalledWith(expect.objectContaining({
      content: 'Enter key test'
    }));
  });

  /**
   * Additional Property: Close Functionality
   * For any messaging interface, the close button should work correctly.
   */
  test('Property: Close button works correctly', async () => {
    await act(async () => {
      render(
        <InAppMessaging
          bookingId="booking-123"
          currentUserId="user-1"
          currentUserName="John Farmer"
          recipientId="user-2"
          recipientName="Jane Owner"
          onClose={mockOnClose}
        />
      );
    });

    // Property: Close button is available
    const closeButton = screen.getByText('×');
    expect(closeButton).toBeInTheDocument();

    // Property: Close button calls onClose handler
    fireEvent.click(closeButton);
    expect(mockOnClose).toHaveBeenCalledTimes(1);
  });
});
