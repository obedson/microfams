import React from 'react';
import { View, Text, StyleSheet } from 'react-native';
import { Ionicons } from '@expo/vector-icons';

interface Step {
  key: string;
  label: string;
  icon: string;
  status: 'completed' | 'current' | 'failed' | 'cancelled' | 'upcoming';
}

interface BookingStatusTimelineProps {
  status: string;
  paymentStatus: string;
}

const BookingStatusTimeline: React.FC<BookingStatusTimelineProps> = ({ status, paymentStatus }) => {
  const getTimelineSteps = (): Step[] => {
    const steps: Step[] = [
      { key: 'created', label: 'Created', icon: 'time-outline', status: 'upcoming' },
      { key: 'payment', label: 'Payment', icon: 'cash-outline', status: 'upcoming' },
      { key: 'pending', label: 'Pending', icon: 'alert-circle-outline', status: 'upcoming' },
      { key: 'confirmed', label: 'Confirmed', icon: 'checkmark-circle-outline', status: 'upcoming' },
      { key: 'completed', label: 'Completed', icon: 'checkmark-done-outline', status: 'upcoming' }
    ];

    return steps.map((step, index) => {
      let stepStatus: Step['status'] = 'upcoming';
      
      if (status === 'cancelled') {
        stepStatus = index === 0 ? 'completed' : 'cancelled';
      } else if (step.key === 'created') {
        stepStatus = 'completed';
      } else if (step.key === 'payment') {
        stepStatus = paymentStatus === 'paid' ? 'completed' : 
                    paymentStatus === 'failed' ? 'failed' :
                    status === 'pending_payment' ? 'current' : 'upcoming';
      } else if (step.key === 'pending') {
        stepStatus = status === 'pending' ? 'current' :
                    ['confirmed', 'completed'].includes(status) ? 'completed' : 'upcoming';
      } else if (step.key === 'confirmed') {
        stepStatus = status === 'confirmed' ? 'current' :
                    status === 'completed' ? 'completed' : 'upcoming';
      } else if (step.key === 'completed') {
        stepStatus = status === 'completed' ? 'completed' : 'upcoming';
      }

      return { ...step, status: stepStatus };
    });
  };

  const steps = getTimelineSteps();

  return (
    <View style={styles.container}>
      {steps.map((step, index) => {
        const isLast = index === steps.length - 1;
        const iconColor = 
          step.status === 'completed' ? '#10b981' :
          step.status === 'current' ? '#3b82f6' :
          step.status === 'failed' ? '#ef4444' :
          step.status === 'cancelled' ? '#9ca3af' :
          '#d1d5db';

        return (
          <View key={step.key} style={styles.stepContainer}>
            <View style={styles.iconWrapper}>
              <View style={[styles.iconCircle, { borderColor: iconColor }]}>
                <Ionicons 
                  name={step.status === 'cancelled' ? 'close-circle-outline' : step.icon as any} 
                  size={16} 
                  color={iconColor} 
                />
              </View>
              <Text style={[styles.stepLabel, { color: iconColor, fontWeight: step.status === 'current' ? 'bold' : 'normal' }]}>
                {step.label}
              </Text>
            </View>
            {!isLast && (
              <View style={[styles.line, { backgroundColor: step.status === 'completed' ? '#10b981' : '#d1d5db' }]} />
            )}
          </View>
        );
      })}
    </View>
  );
};

const styles = StyleSheet.create({
  container: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    justifyContent: 'space-between',
    paddingVertical: 10,
    width: '100%',
  },
  stepContainer: {
    flexDirection: 'row',
    alignItems: 'center',
    flex: 1,
  },
  iconWrapper: {
    alignItems: 'center',
    zIndex: 1,
  },
  iconCircle: {
    width: 32,
    height: 32,
    borderRadius: 16,
    borderWidth: 2,
    backgroundColor: '#fff',
    justifyContent: 'center',
    alignItems: 'center',
  },
  stepLabel: {
    fontSize: 10,
    marginTop: 4,
    textAlign: 'center',
    position: 'absolute',
    top: 32,
    width: 60,
  },
  line: {
    flex: 1,
    height: 2,
    marginTop: -20, // Align with center of circle
    marginHorizontal: -10,
  },
});

export default BookingStatusTimeline;
