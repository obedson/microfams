import React, { useState } from 'react';
import {
  View,
  Text,
  StyleSheet,
  ScrollView,
  TextInput,
  TouchableOpacity,
  Alert,
} from 'react-native';
import { useCartStore } from '../store/cartStore';
import apiClient from '../api/client';

export default function CheckoutScreen({ navigation }: any) {
  const { items, getTotal, clearCart } = useCartStore();
  const [loading, setLoading] = useState(false);
  const [formData, setFormData] = useState({
    name: '',
    phone: '',
    address: '',
    notes: '',
  });

  const handlePlaceOrder = async () => {
    if (!formData.name || !formData.phone || !formData.address) {
      Alert.alert('Error', 'Please fill in all required fields');
      return;
    }

    setLoading(true);
    try {
      // Create orders first
      const orderData = {
        items: items.map(item => ({
          product_id: item.id,
          quantity: item.quantity,
          price: item.price,
        })),
        total: getTotal(),
        delivery_info: formData,
      };

      const orderResponse = await apiClient.post('/orders', orderData);
      
      // Initialize Paystack payment
      const paymentData = {
        amount: getTotal(),
        email: formData.phone + '@agrocareer.com', // Use phone as email fallback
        orders: orderResponse.data.data,
      };

      const paymentResponse = await apiClient.post('/payments/initialize-order', paymentData);
      
      if (paymentResponse.data.success) {
        const { authorization_url, reference } = paymentResponse.data.data;
        
        // Navigate to payment screen
        navigation.navigate('Payment', {
          paymentUrl: authorization_url,
          reference: reference,
        });
      }
    } catch (error: any) {
      Alert.alert('Error', error.response?.data?.error || 'Failed to place order');
    } finally {
      setLoading(false);
    }
  };

  return (
    <ScrollView style={styles.container}>
      <View style={styles.section}>
        <Text style={styles.sectionTitle}>Delivery Information</Text>
        <TextInput
          style={styles.input}
          placeholder="Full Name *"
          value={formData.name}
          onChangeText={(text) => setFormData({ ...formData, name: text })}
        />
        <TextInput
          style={styles.input}
          placeholder="Phone Number *"
          value={formData.phone}
          onChangeText={(text) => setFormData({ ...formData, phone: text })}
          keyboardType="phone-pad"
        />
        <TextInput
          style={[styles.input, styles.textArea]}
          placeholder="Delivery Address *"
          value={formData.address}
          onChangeText={(text) => setFormData({ ...formData, address: text })}
          multiline
          numberOfLines={3}
        />
        <TextInput
          style={[styles.input, styles.textArea]}
          placeholder="Additional Notes (Optional)"
          value={formData.notes}
          onChangeText={(text) => setFormData({ ...formData, notes: text })}
          multiline
          numberOfLines={2}
        />
      </View>

      <View style={styles.section}>
        <Text style={styles.sectionTitle}>Order Summary</Text>
        {items.map((item) => (
          <View key={item.id} style={styles.orderItem}>
            <Text style={styles.itemName}>{item.name}</Text>
            <Text style={styles.itemDetail}>
              {item.quantity} x ₦{item.price.toLocaleString()}
            </Text>
            <Text style={styles.itemTotal}>
              ₦{(item.quantity * item.price).toLocaleString()}
            </Text>
          </View>
        ))}
        <View style={styles.totalRow}>
          <Text style={styles.totalLabel}>Total</Text>
          <Text style={styles.totalPrice}>₦{getTotal().toLocaleString()}</Text>
        </View>
      </View>

      <TouchableOpacity
        style={[styles.placeOrderButton, loading && styles.buttonDisabled]}
        onPress={handlePlaceOrder}
        disabled={loading}
      >
        <Text style={styles.placeOrderButtonText}>
          {loading ? 'Placing Order...' : 'Place Order'}
        </Text>
      </TouchableOpacity>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#fff',
  },
  section: {
    padding: 16,
    borderBottomWidth: 8,
    borderBottomColor: '#f3f4f6',
  },
  sectionTitle: {
    fontSize: 18,
    fontWeight: '600',
    marginBottom: 16,
  },
  input: {
    borderWidth: 1,
    borderColor: '#e5e7eb',
    borderRadius: 8,
    padding: 12,
    fontSize: 16,
    marginBottom: 12,
  },
  textArea: {
    height: 80,
    textAlignVertical: 'top',
  },
  orderItem: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    paddingVertical: 8,
    borderBottomWidth: 1,
    borderBottomColor: '#f3f4f6',
  },
  itemName: {
    flex: 2,
    fontSize: 14,
  },
  itemDetail: {
    flex: 1,
    fontSize: 14,
    color: '#666',
    textAlign: 'center',
  },
  itemTotal: {
    flex: 1,
    fontSize: 14,
    fontWeight: '600',
    textAlign: 'right',
  },
  totalRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    marginTop: 16,
    paddingTop: 16,
    borderTopWidth: 2,
    borderTopColor: '#e5e7eb',
  },
  totalLabel: {
    fontSize: 18,
    fontWeight: '600',
  },
  totalPrice: {
    fontSize: 24,
    fontWeight: 'bold',
    color: '#10b981',
  },
  placeOrderButton: {
    backgroundColor: '#10b981',
    margin: 16,
    padding: 16,
    borderRadius: 8,
    alignItems: 'center',
  },
  buttonDisabled: {
    opacity: 0.6,
  },
  placeOrderButtonText: {
    color: '#fff',
    fontSize: 16,
    fontWeight: '600',
  },
});
