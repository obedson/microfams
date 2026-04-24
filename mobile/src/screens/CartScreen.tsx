import React from 'react';
import {
  View,
  Text,
  StyleSheet,
  FlatList,
  Image,
  TouchableOpacity,
} from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import { useCartStore } from '../store/cartStore';

export default function CartScreen({ navigation }: any) {
  const { items, removeItem, updateQuantity, getTotal } = useCartStore();

  if (items.length === 0) {
    return (
      <View style={styles.empty}>
        <Ionicons name="cart-outline" size={80} color="#ccc" />
        <Text style={styles.emptyText}>Your cart is empty</Text>
        <TouchableOpacity
          style={styles.shopButton}
          onPress={() => navigation.navigate('Marketplace')}
        >
          <Text style={styles.shopButtonText}>Start Shopping</Text>
        </TouchableOpacity>
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <FlatList
        data={items}
        keyExtractor={(item) => item.id}
        renderItem={({ item }) => (
          <View style={styles.item}>
            <Image
              source={{ uri: item.image_url || 'https://via.placeholder.com/80' }}
              style={styles.image}
            />
            <View style={styles.details}>
              <Text style={styles.name}>{item.name}</Text>
              <Text style={styles.price}>₦{item.price.toLocaleString()}</Text>
              <View style={styles.quantityControls}>
                <TouchableOpacity
                  style={styles.quantityButton}
                  onPress={() => updateQuantity(item.id, Math.max(1, item.quantity - 1))}
                >
                  <Ionicons name="remove" size={16} color="#111" />
                </TouchableOpacity>
                <Text style={styles.quantity}>{item.quantity}</Text>
                <TouchableOpacity
                  style={styles.quantityButton}
                  onPress={() => updateQuantity(item.id, Math.min(item.stock_quantity, item.quantity + 1))}
                >
                  <Ionicons name="add" size={16} color="#111" />
                </TouchableOpacity>
              </View>
            </View>
            <TouchableOpacity onPress={() => removeItem(item.id)}>
              <Ionicons name="trash-outline" size={24} color="#ef4444" />
            </TouchableOpacity>
          </View>
        )}
      />
      <View style={styles.footer}>
        <View style={styles.totalRow}>
          <Text style={styles.totalLabel}>Total</Text>
          <Text style={styles.totalPrice}>₦{getTotal().toLocaleString()}</Text>
        </View>
        <TouchableOpacity
          style={styles.checkoutButton}
          onPress={() => navigation.navigate('Checkout')}
        >
          <Text style={styles.checkoutButtonText}>Proceed to Checkout</Text>
        </TouchableOpacity>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#fff',
  },
  empty: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
    padding: 20,
  },
  emptyText: {
    fontSize: 18,
    color: '#666',
    marginTop: 16,
    marginBottom: 24,
  },
  shopButton: {
    backgroundColor: '#10b981',
    paddingHorizontal: 24,
    paddingVertical: 12,
    borderRadius: 8,
  },
  shopButtonText: {
    color: '#fff',
    fontSize: 16,
    fontWeight: '600',
  },
  item: {
    flexDirection: 'row',
    padding: 16,
    borderBottomWidth: 1,
    borderBottomColor: '#e5e7eb',
    alignItems: 'center',
  },
  image: {
    width: 80,
    height: 80,
    borderRadius: 8,
    backgroundColor: '#e5e7eb',
  },
  details: {
    flex: 1,
    marginLeft: 12,
  },
  name: {
    fontSize: 16,
    fontWeight: '600',
    marginBottom: 4,
  },
  price: {
    fontSize: 16,
    color: '#10b981',
    fontWeight: '600',
    marginBottom: 8,
  },
  quantityControls: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
  },
  quantityButton: {
    width: 28,
    height: 28,
    borderRadius: 14,
    backgroundColor: '#f3f4f6',
    justifyContent: 'center',
    alignItems: 'center',
  },
  quantity: {
    fontSize: 16,
    fontWeight: '600',
    minWidth: 30,
    textAlign: 'center',
  },
  footer: {
    padding: 16,
    borderTopWidth: 1,
    borderTopColor: '#e5e7eb',
  },
  totalRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    marginBottom: 16,
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
  checkoutButton: {
    backgroundColor: '#10b981',
    padding: 16,
    borderRadius: 8,
    alignItems: 'center',
  },
  checkoutButtonText: {
    color: '#fff',
    fontSize: 16,
    fontWeight: '600',
  },
});
