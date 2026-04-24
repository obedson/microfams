import React, { useState, useEffect } from 'react';
import {
  View,
  Text,
  StyleSheet,
  ScrollView,
  Image,
  TouchableOpacity,
  ActivityIndicator,
  Alert,
  FlatList,
  Dimensions,
} from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import apiClient from '../api/client';
import { useCartStore } from '../store/cartStore';
import { useAuthStore } from '../store/authStore';

export default function ProductDetailScreen({ route, navigation }: any) {
  const { id } = route.params;
  const [product, setProduct] = useState<any>(null);
  const [loading, setLoading] = useState(true);
  const [quantity, setQuantity] = useState(1);
  const [currentImageIndex, setCurrentImageIndex] = useState(0);
  const addItem = useCartStore((state) => state.addItem);
  const user = useAuthStore((state) => state.user);

  useEffect(() => {
    fetchProduct();
  }, []);

  const fetchProduct = async () => {
    try {
      const response = await apiClient.get(`/products/${id}`);
      const productData = response.data.data || response.data;
      console.log('Product data:', productData);
      console.log('Stock value:', productData.stock, 'Type:', typeof productData.stock);
      setProduct(productData);
    } catch (error) {
      console.error('Error fetching product:', error);
      Alert.alert('Error', 'Failed to load product details');
    } finally {
      setLoading(false);
    }
  };

  const handleAddToCart = () => {
    addItem({
      id: product.id,
      name: product.name,
      price: parseFloat(product.price),
      quantity: Number(quantity),
      images: product.images,
      stock_quantity: product.stock_quantity,
    });
    Alert.alert('Success', `Added ${quantity} item(s) to cart`, [
      { text: 'Continue Shopping', style: 'cancel' },
      { text: 'View Cart', onPress: () => navigation.navigate('Cart') },
    ]);
  };

  const renderImageItem = ({ item }: { item: string }) => (
    <Image
      source={{ uri: item || 'https://via.placeholder.com/400' }}
      style={styles.image}
    />
  );

  const images = product?.images?.length > 0 ? product.images : ['https://via.placeholder.com/400'];
  const isOwner = user?.id === product?.supplier_id;

  if (loading) {
    return (
      <View style={styles.center}>
        <ActivityIndicator size="large" color="#10b981" />
      </View>
    );
  }

  if (!product) {
    return (
      <View style={styles.center}>
        <Text>Product not found</Text>
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <ScrollView>
        <View style={styles.imageContainer}>
          <FlatList
            data={images}
            renderItem={renderImageItem}
            horizontal
            pagingEnabled
            showsHorizontalScrollIndicator={false}
            onMomentumScrollEnd={(event) => {
              const index = Math.round(event.nativeEvent.contentOffset.x / Dimensions.get('window').width);
              setCurrentImageIndex(index);
            }}
          />
          {images.length > 1 && (
            <View style={styles.imageIndicators}>
              {images.map((_, index) => (
                <View
                  key={index}
                  style={[
                    styles.indicator,
                    index === currentImageIndex && styles.activeIndicator
                  ]}
                />
              ))}
            </View>
          )}
        </View>
        <TouchableOpacity
          style={styles.backButton}
          onPress={() => navigation.goBack()}
        >
          <Ionicons name="arrow-back" size={24} color="#fff" />
        </TouchableOpacity>

        <View style={styles.content}>
          <View style={styles.categoryBadge}>
            <Text style={styles.categoryText}>{product.category}</Text>
          </View>

          <Text style={styles.title}>{product.name}</Text>
          <Text style={styles.price}>₦{parseFloat(product.price).toLocaleString()}</Text>

          <View style={styles.stockRow}>
            <Ionicons name="cube-outline" size={20} color="#10b981" />
            <Text style={styles.stock}>{product.stock_quantity || 0} in stock</Text>
          </View>

          <View style={styles.section}>
            <Text style={styles.sectionTitle}>Description</Text>
            <Text style={styles.description}>{product.description}</Text>
          </View>

          <View style={styles.quantitySection}>
            <Text style={styles.sectionTitle}>Quantity</Text>
            <View style={styles.quantityControls}>
              <TouchableOpacity
                style={styles.quantityButton}
                onPress={() => setQuantity(Math.max(1, Number(quantity) - 1))}
              >
                <Ionicons name="remove" size={20} color="#111" />
              </TouchableOpacity>
              <Text style={styles.quantityText}>{quantity}</Text>
              <TouchableOpacity
                style={styles.quantityButton}
                onPress={() => setQuantity(Math.min(Number(product.stock_quantity || 999), Number(quantity) + 1))}
              >
                <Ionicons name="add" size={20} color="#111" />
              </TouchableOpacity>
            </View>
          </View>
        </View>
      </ScrollView>

      <View style={styles.footer}>
        <View style={styles.totalSection}>
          <Text style={styles.totalLabel}>Total</Text>
          <Text style={styles.totalPrice}>₦{(parseFloat(product.price || 0) * Number(quantity)).toLocaleString()}</Text>
        </View>
        <View style={styles.buttonRow}>
          {isOwner && (
            <TouchableOpacity 
              style={styles.editButton} 
              onPress={() => navigation.navigate('AddProduct', { product })}
            >
              <Ionicons name="pencil" size={16} color="#10b981" />
              <Text style={styles.editButtonText}>Edit</Text>
            </TouchableOpacity>
          )}
          <TouchableOpacity style={[styles.addButton, isOwner && styles.addButtonFull]} onPress={handleAddToCart}>
            <Ionicons name="cart" size={20} color="#fff" />
            <Text style={styles.addButtonText}>Add to Cart</Text>
          </TouchableOpacity>
        </View>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#fff',
  },
  center: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
  },
  image: {
    width: Dimensions.get('window').width,
    height: 300,
    backgroundColor: '#e5e7eb',
  },
  imageContainer: {
    position: 'relative',
  },
  imageIndicators: {
    position: 'absolute',
    bottom: 16,
    left: 0,
    right: 0,
    flexDirection: 'row',
    justifyContent: 'center',
    gap: 8,
  },
  indicator: {
    width: 8,
    height: 8,
    borderRadius: 4,
    backgroundColor: 'rgba(255,255,255,0.5)',
  },
  activeIndicator: {
    backgroundColor: '#fff',
  },
  backButton: {
    position: 'absolute',
    top: 50,
    left: 16,
    width: 40,
    height: 40,
    borderRadius: 20,
    backgroundColor: 'rgba(0,0,0,0.5)',
    justifyContent: 'center',
    alignItems: 'center',
  },
  content: {
    padding: 20,
  },
  categoryBadge: {
    alignSelf: 'flex-start',
    backgroundColor: '#f0fdf4',
    paddingHorizontal: 12,
    paddingVertical: 6,
    borderRadius: 16,
    marginBottom: 12,
  },
  categoryText: {
    color: '#10b981',
    fontSize: 12,
    fontWeight: '600',
    textTransform: 'capitalize',
  },
  title: {
    fontSize: 24,
    fontWeight: 'bold',
    marginBottom: 8,
  },
  price: {
    fontSize: 28,
    fontWeight: 'bold',
    color: '#10b981',
    marginBottom: 16,
  },
  stockRow: {
    flexDirection: 'row',
    alignItems: 'center',
    marginBottom: 24,
  },
  stock: {
    fontSize: 16,
    color: '#666',
    marginLeft: 8,
  },
  section: {
    marginBottom: 24,
  },
  sectionTitle: {
    fontSize: 18,
    fontWeight: '600',
    marginBottom: 12,
  },
  description: {
    fontSize: 16,
    color: '#666',
    lineHeight: 24,
  },
  quantitySection: {
    marginBottom: 24,
  },
  quantityControls: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 16,
  },
  quantityButton: {
    width: 40,
    height: 40,
    borderRadius: 20,
    backgroundColor: '#f3f4f6',
    justifyContent: 'center',
    alignItems: 'center',
  },
  quantityText: {
    fontSize: 20,
    fontWeight: '600',
    minWidth: 40,
    textAlign: 'center',
  },
  footer: {
    padding: 16,
    borderTopWidth: 1,
    borderTopColor: '#e5e7eb',
    backgroundColor: '#fff',
  },
  totalSection: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    marginBottom: 12,
  },
  totalLabel: {
    fontSize: 16,
    color: '#666',
  },
  totalPrice: {
    fontSize: 20,
    fontWeight: 'bold',
  },
  buttonRow: {
    flexDirection: 'row',
    gap: 12,
  },
  editButton: {
    flex: 1,
    backgroundColor: '#f0fdf4',
    padding: 16,
    borderRadius: 8,
    flexDirection: 'row',
    justifyContent: 'center',
    alignItems: 'center',
    gap: 8,
    borderWidth: 1,
    borderColor: '#10b981',
  },
  editButtonText: {
    color: '#10b981',
    fontSize: 16,
    fontWeight: '600',
  },
  addButton: {
    flex: 2,
    backgroundColor: '#10b981',
    padding: 16,
    borderRadius: 8,
    flexDirection: 'row',
    justifyContent: 'center',
    alignItems: 'center',
    gap: 8,
  },
  addButtonFull: {
    flex: 1,
  },
  addButtonText: {
    color: '#fff',
    fontSize: 16,
    fontWeight: '600',
  },
});
