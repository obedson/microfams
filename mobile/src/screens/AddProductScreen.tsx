import React, { useState } from 'react';
import {
  View,
  Text,
  StyleSheet,
  ScrollView,
  TextInput,
  TouchableOpacity,
  Alert,
  ActivityIndicator,
} from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import * as ImagePicker from 'expo-image-picker';
import apiClient from '../api/client';

export default function AddProductScreen({ navigation, route }: any) {
  const { product } = route.params || {};
  const isEditing = !!product;
  const [loading, setLoading] = useState(false);
  const [formData, setFormData] = useState({
    name: product?.name || '',
    category: product?.category || 'feed',
    description: product?.description || '',
    price: product?.price?.toString() || '',
    unit: product?.unit || 'bag',
    stock_quantity: product?.stock_quantity?.toString() || '',
    minimum_order: product?.minimum_order?.toString() || '1',
    location: product?.location || '',
  });
  const [images, setImages] = useState<string[]>(product?.images || []);

  const categories = ['feed', 'equipment', 'health', 'seeds', 'tools'];
  const units = ['bag', 'unit', 'kg', 'bottle', 'box', 'piece'];

  const pickImage = async () => {
    const result = await ImagePicker.launchImageLibraryAsync({
      mediaTypes: ImagePicker.MediaTypeOptions.Images,
      allowsMultipleSelection: true,
      quality: 0.8,
    });

    if (!result.canceled) {
      setImages([...images, ...result.assets.map(asset => asset.uri)]);
    }
  };

  const handleSubmit = async () => {
    if (!formData.name || !formData.price || !formData.stock_quantity) {
      Alert.alert('Error', 'Please fill in all required fields');
      return;
    }

    setLoading(true);
    try {
      const formDataToSend = new FormData();
      
      // Add form fields
      Object.entries({
        ...formData,
        price: parseFloat(formData.price),
        stock_quantity: parseInt(formData.stock_quantity),
        minimum_order: parseInt(formData.minimum_order),
      }).forEach(([key, value]) => {
        formDataToSend.append(key, value.toString());
      });

      // Add images
      images.forEach((imageUri, index) => {
        formDataToSend.append('images', {
          uri: imageUri,
          type: 'image/jpeg',
          name: `image_${index}.jpg`,
        } as any);
      });

      if (isEditing) {
        await apiClient.put(`/products/${product.id}`, formDataToSend, {
          headers: {
            'Content-Type': 'multipart/form-data',
          },
        });
        Alert.alert('Success', 'Product updated successfully', [
          { text: 'OK', onPress: () => navigation.goBack() }
        ]);
      } else {
        await apiClient.post('/products', formDataToSend, {
          headers: {
            'Content-Type': 'multipart/form-data',
          },
        });
        Alert.alert('Success', 'Product added successfully', [
          { text: 'OK', onPress: () => navigation.goBack() }
        ]);
      }
    } catch (error: any) {
      Alert.alert('Error', error.response?.data?.error || `Failed to ${isEditing ? 'update' : 'add'} product`);
    } finally {
      setLoading(false);
    }
  };

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <TouchableOpacity onPress={() => navigation.goBack()}>
          <Ionicons name="close" size={24} color="#111" />
        </TouchableOpacity>
        <Text style={styles.headerTitle}>{isEditing ? 'Edit Product' : 'Add Product'}</Text>
        <View style={{ width: 24 }} />
      </View>

      <ScrollView style={styles.content}>
        <Text style={styles.label}>Product Name *</Text>
        <TextInput
          style={styles.input}
          placeholder="e.g., Chicken Feed - 25kg"
          value={formData.name}
          onChangeText={(text) => setFormData({ ...formData, name: text })}
        />

        <Text style={styles.label}>Category *</Text>
        <View style={styles.categoryGrid}>
          {categories.map((cat) => (
            <TouchableOpacity
              key={cat}
              style={[
                styles.categoryButton,
                formData.category === cat && styles.categoryButtonActive
              ]}
              onPress={() => setFormData({ ...formData, category: cat })}
            >
              <Text style={[
                styles.categoryText,
                formData.category === cat && styles.categoryTextActive
              ]}>
                {cat}
              </Text>
            </TouchableOpacity>
          ))}
        </View>

        <Text style={styles.label}>Description</Text>
        <TextInput
          style={[styles.input, styles.textArea]}
          placeholder="Product description"
          value={formData.description}
          onChangeText={(text) => setFormData({ ...formData, description: text })}
          multiline
          numberOfLines={4}
        />

        <View style={styles.row}>
          <View style={styles.halfWidth}>
            <Text style={styles.label}>Price (₦) *</Text>
            <TextInput
              style={styles.input}
              placeholder="0"
              value={formData.price}
              onChangeText={(text) => setFormData({ ...formData, price: text })}
              keyboardType="numeric"
            />
          </View>

          <View style={styles.halfWidth}>
            <Text style={styles.label}>Unit *</Text>
            <View style={styles.pickerContainer}>
              {units.map((unit) => (
                <TouchableOpacity
                  key={unit}
                  style={[
                    styles.unitButton,
                    formData.unit === unit && styles.unitButtonActive
                  ]}
                  onPress={() => setFormData({ ...formData, unit })}
                >
                  <Text style={[
                    styles.unitText,
                    formData.unit === unit && styles.unitTextActive
                  ]}>
                    {unit}
                  </Text>
                </TouchableOpacity>
              ))}
            </View>
          </View>
        </View>

        <View style={styles.row}>
          <View style={styles.halfWidth}>
            <Text style={styles.label}>Stock Quantity *</Text>
            <TextInput
              style={styles.input}
              placeholder="0"
              value={formData.stock_quantity}
              onChangeText={(text) => setFormData({ ...formData, stock_quantity: text })}
              keyboardType="numeric"
            />
          </View>

          <View style={styles.halfWidth}>
            <Text style={styles.label}>Min. Order</Text>
            <TextInput
              style={styles.input}
              placeholder="1"
              value={formData.minimum_order}
              onChangeText={(text) => setFormData({ ...formData, minimum_order: text })}
              keyboardType="numeric"
            />
          </View>
        </View>

        <Text style={styles.label}>Location</Text>
        <TextInput
          style={styles.input}
          placeholder="e.g., Lagos"
          value={formData.location}
          onChangeText={(text) => setFormData({ ...formData, location: text })}
        />

        <Text style={styles.label}>Product Images</Text>
        <TouchableOpacity style={styles.imageButton} onPress={pickImage}>
          <Ionicons name="camera" size={24} color="#10b981" />
          <Text style={styles.imageButtonText}>Add Images ({images.length}/5)</Text>
        </TouchableOpacity>
      </ScrollView>

      <View style={styles.footer}>
        <TouchableOpacity
          style={[styles.submitButton, loading && styles.submitButtonDisabled]}
          onPress={handleSubmit}
          disabled={loading}
        >
          {loading ? (
            <ActivityIndicator color="#fff" />
          ) : (
            <Text style={styles.submitButtonText}>{isEditing ? 'Update Product' : 'Add Product'}</Text>
          )}
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
  header: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    padding: 20,
    paddingTop: 60,
    borderBottomWidth: 1,
    borderBottomColor: '#e5e7eb',
  },
  headerTitle: {
    fontSize: 18,
    fontWeight: '600',
  },
  content: {
    flex: 1,
    padding: 20,
  },
  label: {
    fontSize: 14,
    fontWeight: '600',
    marginBottom: 8,
    color: '#374151',
  },
  input: {
    borderWidth: 1,
    borderColor: '#d1d5db',
    borderRadius: 8,
    padding: 12,
    fontSize: 16,
    marginBottom: 16,
  },
  textArea: {
    height: 100,
    textAlignVertical: 'top',
  },
  categoryGrid: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 8,
    marginBottom: 16,
  },
  categoryButton: {
    paddingHorizontal: 16,
    paddingVertical: 8,
    borderRadius: 20,
    borderWidth: 1,
    borderColor: '#d1d5db',
    backgroundColor: '#fff',
  },
  categoryButtonActive: {
    backgroundColor: '#10b981',
    borderColor: '#10b981',
  },
  categoryText: {
    fontSize: 14,
    color: '#6b7280',
    textTransform: 'capitalize',
  },
  categoryTextActive: {
    color: '#fff',
    fontWeight: '600',
  },
  row: {
    flexDirection: 'row',
    gap: 12,
  },
  halfWidth: {
    flex: 1,
  },
  pickerContainer: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 6,
    marginBottom: 16,
  },
  unitButton: {
    paddingHorizontal: 12,
    paddingVertical: 6,
    borderRadius: 12,
    borderWidth: 1,
    borderColor: '#d1d5db',
    backgroundColor: '#fff',
  },
  unitButtonActive: {
    backgroundColor: '#10b981',
    borderColor: '#10b981',
  },
  unitText: {
    fontSize: 12,
    color: '#6b7280',
  },
  unitTextActive: {
    color: '#fff',
    fontWeight: '600',
  },
  footer: {
    padding: 16,
    borderTopWidth: 1,
    borderTopColor: '#e5e7eb',
  },
  submitButton: {
    backgroundColor: '#10b981',
    padding: 16,
    borderRadius: 8,
    alignItems: 'center',
  },
  submitButtonDisabled: {
    opacity: 0.6,
  },
  submitButtonText: {
    color: '#fff',
    fontSize: 16,
    fontWeight: '600',
  },
  imageButton: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    borderWidth: 2,
    borderColor: '#10b981',
    borderStyle: 'dashed',
    borderRadius: 8,
    padding: 20,
    marginBottom: 16,
  },
  imageButtonText: {
    marginLeft: 8,
    color: '#10b981',
    fontSize: 16,
    fontWeight: '500',
  },
});
