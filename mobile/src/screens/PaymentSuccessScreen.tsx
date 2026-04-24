import React from 'react';
import { View, Text, StyleSheet, TouchableOpacity } from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import { useCartStore } from '../store/cartStore';

export default function PaymentSuccessScreen({ navigation }: any) {
  const clearCart = useCartStore((state) => state.clearCart);

  const handleContinue = () => {
    clearCart();
    navigation.navigate('Main', { screen: 'Dashboard' });
  };

  return (
    <View style={styles.container}>
      <Ionicons name="checkmark-circle" size={100} color="#10b981" />
      <Text style={styles.title}>Payment Successful!</Text>
      <Text style={styles.message}>Your order has been placed successfully</Text>
      <TouchableOpacity style={styles.button} onPress={handleContinue}>
        <Text style={styles.buttonText}>Continue Shopping</Text>
      </TouchableOpacity>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
    padding: 20,
    backgroundColor: '#fff',
  },
  title: {
    fontSize: 24,
    fontWeight: 'bold',
    marginTop: 20,
    marginBottom: 10,
  },
  message: {
    fontSize: 16,
    color: '#666',
    textAlign: 'center',
    marginBottom: 30,
  },
  button: {
    backgroundColor: '#10b981',
    paddingHorizontal: 32,
    paddingVertical: 16,
    borderRadius: 8,
  },
  buttonText: {
    color: '#fff',
    fontSize: 16,
    fontWeight: '600',
  },
});
