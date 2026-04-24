import React from 'react';
import { View, Text, StyleSheet, TouchableOpacity } from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import BookingStatusTimeline from './BookingStatusTimeline';

interface BookingCardProps {
  booking: any;
  onPress?: () => void;
  onCancel?: () => void;
  onRetryPayment?: () => void;
}

const BookingCard: React.FC<BookingCardProps> = ({ 
  booking, 
  onPress,
  onCancel,
  onRetryPayment
}) => {
  const getStatusColor = (status: string) => {
    switch (status) {
      case 'confirmed': return '#10b981';
      case 'pending': return '#f59e0b';
      case 'pending_payment': return '#f97316';
      case 'cancelled': return '#ef4444';
      case 'completed': return '#3b82f6';
      default: return '#6b7280';
    }
  };

  const getPaymentStatusColor = (status: string) => {
    switch (status) {
      case 'paid': return '#10b981';
      case 'pending': return '#f59e0b';
      case 'failed': return '#ef4444';
      default: return '#6b7280';
    }
  };

  const formatDate = (dateString: string) => {
    return new Date(dateString).toLocaleDateString('en-US', {
      month: 'short',
      day: 'numeric',
      year: 'numeric'
    });
  };

  const reference = booking.id?.slice(-8)?.toUpperCase() || 'UNKNOWN';

  return (
    <TouchableOpacity style={styles.card} onPress={onPress} activeOpacity={0.7}>
      <View style={styles.header}>
        <View style={styles.titleContainer}>
          <Text style={styles.propertyTitle} numberOfLines={1}>
            {booking.properties?.title || 'Farm Property'}
          </Text>
          <Text style={styles.reference}>#{reference}</Text>
        </View>
        <Text style={styles.amount}>₦{booking.total_amount?.toLocaleString()}</Text>
      </View>

      <View style={styles.badges}>
        <View style={[styles.badge, { backgroundColor: getStatusColor(booking.status) + '20' }]}>
          <Text style={[styles.badgeText, { color: getStatusColor(booking.status) }]}>
            {booking.status?.replace('_', ' ')}
          </Text>
        </View>
        <View style={[styles.badge, { backgroundColor: getPaymentStatusColor(booking.payment_status) + '20' }]}>
          <Text style={[styles.badgeText, { color: getPaymentStatusColor(booking.payment_status) }]}>
            {booking.payment_status}
          </Text>
        </View>
      </View>

      <View style={styles.timelineContainer}>
        <BookingStatusTimeline status={booking.status} paymentStatus={booking.payment_status} />
      </View>

      <View style={styles.details}>
        <View style={styles.detailRow}>
          <Ionicons name="calendar-outline" size={14} color="#6b7280" />
          <Text style={styles.detailText}>
            {formatDate(booking.start_date)} - {formatDate(booking.end_date)}
          </Text>
        </View>
        <View style={styles.detailRow}>
          <Ionicons name="location-outline" size={14} color="#6b7280" />
          <Text style={styles.detailText}>
            {booking.properties?.city}, {booking.properties?.lga}
          </Text>
        </View>
      </View>

      {(onCancel || onRetryPayment) && (
        <View style={styles.actions}>
          {booking.status === 'pending_payment' && booking.payment_status !== 'paid' && onRetryPayment && (
            <TouchableOpacity style={styles.retryButton} onPress={onRetryPayment}>
              <Ionicons name="card-outline" size={16} color="#fff" />
              <Text style={styles.buttonText}>Complete Payment</Text>
            </TouchableOpacity>
          )}
          {(booking.status === 'pending' || booking.status === 'confirmed') && onCancel && (
            <TouchableOpacity style={styles.cancelButton} onPress={onCancel}>
              <Text style={styles.cancelButtonText}>Cancel Booking</Text>
            </TouchableOpacity>
          )}
        </View>
      )}
    </TouchableOpacity>
  );
};

const styles = StyleSheet.create({
  card: {
    backgroundColor: '#fff',
    borderRadius: 12,
    padding: 16,
    marginBottom: 16,
    borderWidth: 1,
    borderColor: '#e5e7eb',
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 1 },
    shadowOpacity: 0.05,
    shadowRadius: 2,
    elevation: 2,
  },
  header: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'flex-start',
    marginBottom: 12,
  },
  titleContainer: {
    flex: 1,
  },
  propertyTitle: {
    fontSize: 16,
    fontWeight: 'bold',
    color: '#111827',
  },
  reference: {
    fontSize: 12,
    color: '#6b7280',
    fontFamily: 'monospace',
    marginTop: 2,
  },
  amount: {
    fontSize: 18,
    fontWeight: 'bold',
    color: '#10b981',
  },
  badges: {
    flexDirection: 'row',
    gap: 8,
    marginBottom: 16,
  },
  badge: {
    paddingHorizontal: 8,
    paddingVertical: 4,
    borderRadius: 6,
  },
  badgeText: {
    fontSize: 10,
    fontWeight: 'bold',
    textTransform: 'uppercase',
  },
  timelineContainer: {
    paddingBottom: 40, // Space for labels
    marginBottom: 8,
  },
  details: {
    gap: 8,
    marginBottom: 16,
  },
  detailRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
  },
  detailText: {
    fontSize: 13,
    color: '#4b5563',
  },
  actions: {
    flexDirection: 'row',
    gap: 12,
    borderTopWidth: 1,
    borderTopColor: '#f3f4f6',
    paddingTop: 16,
  },
  retryButton: {
    backgroundColor: '#10b981',
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    paddingHorizontal: 16,
    paddingVertical: 8,
    borderRadius: 8,
  },
  buttonText: {
    color: '#fff',
    fontSize: 14,
    fontWeight: '600',
  },
  cancelButton: {
    paddingHorizontal: 16,
    paddingVertical: 8,
    borderRadius: 8,
    borderWidth: 1,
    borderColor: '#ef4444',
  },
  cancelButtonText: {
    color: '#ef4444',
    fontSize: 14,
    fontWeight: '600',
  },
});

export default BookingCard;
