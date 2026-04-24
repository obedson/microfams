import { Request, Response } from 'express';
import { supabase } from '../utils/supabase.js';
import { logger } from '../utils/logger.js';

export const sendMessage = async (req: Request, res: Response) => {
  try {
    const { booking_id, recipient_id, content, message_type = 'general', media_url, media_type } = req.body;
    
    // Input validation
    if (!booking_id || !recipient_id || (!content?.trim() && !media_url)) {
      return res.status(400).json({ error: 'Missing required fields' });
    }
    
    // Authorization: Verify user is part of the booking
    const { data: booking, error: bookingError } = await supabase
      .from('bookings')
      .select(`
        farmer_id,
        properties (
          owner_id
        )
      `)
      .eq('id', booking_id)
      .single();
      
    if (bookingError || !booking) {
      return res.status(404).json({ error: 'Booking not found' });
    }
    
    const propertyOwnerId = (booking.properties as any)?.owner_id;
    if ((req as any).user.id !== booking.farmer_id && (req as any).user.id !== propertyOwnerId) {
      return res.status(403).json({ error: 'Access denied' });
    }
    
    // Verify recipient is the other party in the booking
    if (recipient_id !== booking.farmer_id && recipient_id !== propertyOwnerId) {
      return res.status(400).json({ error: 'Invalid recipient' });
    }
    
    if (recipient_id === (req as any).user.id) {
      return res.status(400).json({ error: 'Cannot send message to yourself' });
    }
    
    // Insert message
    const { data, error } = await supabase
      .from('booking_communications')
      .insert({
        booking_id,
        sender_id: (req as any).user.id,
        recipient_id,
        content: content?.trim() || '',
        message_type: 'general', // Use 'general' for all message types
        media_url,
        media_type
      })
      .select(`
        id,
        booking_id,
        sender_id,
        recipient_id,
        content,
        message_type,
        media_url,
        media_type,
        sent_at,
        sender:users!sender_id(id, name),
        recipient:users!recipient_id(id, name)
      `)
      .single();
      
    if (error) {
      logger.error('Send message error:', error);
      return res.status(500).json({ error: 'Failed to send message' });
    }
    
    res.status(201).json({ success: true, message: data });
  } catch (error) {
    logger.error('Send message error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
};

export const getBookingMessages = async (req: Request, res: Response) => {
  try {
    const { booking_id } = req.params;
    
    // Authorization: Verify user is part of the booking
    const { data: booking, error: bookingError } = await supabase
      .from('bookings')
      .select(`
        farmer_id,
        properties (
          owner_id
        )
      `)
      .eq('id', booking_id)
      .single();
      
    if (bookingError || !booking) {
      return res.status(404).json({ error: 'Booking not found' });
    }
    
    const propertyOwnerId = (booking.properties as any)?.owner_id;
    if ((req as any).user.id !== booking.farmer_id && (req as any).user.id !== propertyOwnerId) {
      return res.status(403).json({ error: 'Access denied' });
    }
    
    // Get messages for this booking
    const { data: messages, error } = await supabase
      .from('booking_communications')
      .select(`
        id,
        booking_id,
        sender_id,
        recipient_id,
        content,
        message_type,
        media_url,
        media_type,
        sent_at,
        read_at,
        sender:users!sender_id(id, name),
        recipient:users!recipient_id(id, name)
      `)
      .eq('booking_id', booking_id)
      .order('sent_at', { ascending: true });
      
    if (error) {
      logger.error('Get messages error:', error);
      return res.status(500).json({ error: 'Failed to retrieve messages' });
    }
    
    res.json({ success: true, messages: messages || [] });
  } catch (error) {
    logger.error('Get booking messages error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
};

export const markMessageAsRead = async (req: Request, res: Response) => {
  try {
    const { message_id } = req.params;
    
    // Verify user is the recipient
    const { data: message, error: messageError } = await supabase
      .from('booking_communications')
      .select('recipient_id, read_at')
      .eq('id', message_id)
      .single();
      
    if (messageError || !message) {
      return res.status(404).json({ error: 'Message not found' });
    }
    
    if (message.recipient_id !== (req as any).user.id) {
      return res.status(403).json({ error: 'Access denied' });
    }
    
    if (message.read_at) {
      return res.json({ success: true, message: 'Message already read' });
    }
    
    // Mark as read
    const { error } = await supabase
      .from('booking_communications')
      .update({ read_at: new Date().toISOString() })
      .eq('id', message_id);
      
    if (error) {
      logger.error('Mark message read error:', error);
      return res.status(500).json({ error: 'Failed to mark message as read' });
    }
    
    res.json({ success: true, message: 'Message marked as read' });
  } catch (error) {
    logger.error('Mark message as read error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
};

export const getUnreadMessages = async (req: Request, res: Response) => {
  try {
    // Get unread messages for current user
    const { data: messages, error } = await supabase
      .from('booking_communications')
      .select(`
        id,
        booking_id,
        sender_id,
        content,
        message_type,
        sent_at,
        sender:users!sender_id(id, name),
        booking:bookings(id)
      `)
      .eq('recipient_id', (req as any).user.id)
      .is('read_at', null)
      .order('sent_at', { ascending: false });
      
    if (error) {
      logger.error('Get unread messages error:', error);
      return res.status(500).json({ error: 'Failed to retrieve unread messages' });
    }
    
    res.json({ 
      success: true, 
      unread_count: messages?.length || 0,
      messages: messages || [] 
    });
  } catch (error) {
    logger.error('Get unread messages error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
};

export const getAllUserMessages = async (req: Request, res: Response) => {
  try {
    const { data: messages, error } = await supabase
      .from('booking_communications')
      .select(`
        id,
        booking_id,
        sender_id,
        recipient_id,
        content,
        message_type,
        media_url,
        media_type,
        sent_at,
        read_at,
        sender:users!sender_id(id, name),
        recipient:users!recipient_id(id, name)
      `)
      .or(`sender_id.eq.${(req as any).user.id},recipient_id.eq.${(req as any).user.id}`)
      .order('sent_at', { ascending: false });

    if (error) {
      logger.error('Get all user messages error:', error);
      return res.status(500).json({ error: 'Failed to get messages' });
    }

    res.json({ 
      success: true, 
      messages: messages || [] 
    });
  } catch (error) {
    logger.error('Get all user messages error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
};
