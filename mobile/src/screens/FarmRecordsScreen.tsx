import React, { useState, useEffect } from 'react';
import {
  View,
  Text,
  StyleSheet,
  FlatList,
  TouchableOpacity,
  ActivityIndicator,
  RefreshControl,
  Alert,
  Modal,
  TextInput,
} from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import apiClient from '../api/client';

export default function FarmRecordsScreen() {
  const [records, setRecords] = useState([]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [modalVisible, setModalVisible] = useState(false);
  const [editingRecord, setEditingRecord] = useState<any>(null);
  const [formData, setFormData] = useState({
    livestock_type: '',
    livestock_count: '',
    feed_consumption: '',
    mortality_count: '0',
    expenses: '',
    expense_category: '',
    notes: '',
    record_date: new Date().toISOString().split('T')[0],
  });

  const fetchRecords = async () => {
    try {
      const response = await apiClient.get('/farm-records');
      setRecords(response.data.data || response.data);
    } catch (error) {
      console.error('Error fetching records:', error);
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  };

  useEffect(() => {
    fetchRecords();
  }, []);

  const onRefresh = () => {
    setRefreshing(true);
    fetchRecords();
  };

  const openModal = (record?: any) => {
    if (record) {
      setEditingRecord(record);
      setFormData({
        livestock_type: record.livestock_type,
        livestock_count: record.livestock_count.toString(),
        feed_consumption: record.feed_consumption?.toString() || '0',
        mortality_count: record.mortality_count?.toString() || '0',
        expenses: record.expenses?.toString() || '0',
        expense_category: record.expense_category || '',
        notes: record.notes || '',
        record_date: record.record_date || new Date().toISOString().split('T')[0],
      });
    } else {
      setEditingRecord(null);
      setFormData({
        livestock_type: '',
        livestock_count: '',
        feed_consumption: '0',
        mortality_count: '0',
        expenses: '0',
        expense_category: '',
        notes: '',
        record_date: new Date().toISOString().split('T')[0],
      });
    }
    setModalVisible(true);
  };

  const handleSave = async () => {
    if (!formData.livestock_type || !formData.livestock_count) {
      Alert.alert('Error', 'Please fill in required fields');
      return;
    }

    try {
      const data = {
        livestock_type: formData.livestock_type,
        livestock_count: parseInt(formData.livestock_count),
        feed_consumption: parseFloat(formData.feed_consumption) || 0,
        mortality_count: parseInt(formData.mortality_count) || 0,
        expenses: parseFloat(formData.expenses) || 0,
        expense_category: formData.expense_category,
        notes: formData.notes,
        record_date: formData.record_date,
      };

      if (editingRecord) {
        await apiClient.put(`/farm-records/${editingRecord.id}`, data);
      } else {
        await apiClient.post('/farm-records', data);
      }

      setModalVisible(false);
      fetchRecords();
      Alert.alert('Success', `Record ${editingRecord ? 'updated' : 'created'} successfully`);
    } catch (error: any) {
      Alert.alert('Error', error.response?.data?.message || 'Failed to save record');
    }
  };

  const handleDelete = (id: string) => {
    Alert.alert(
      'Delete Record',
      'Are you sure you want to delete this record?',
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Delete',
          style: 'destructive',
          onPress: async () => {
            try {
              await apiClient.delete(`/farm-records/${id}`);
              fetchRecords();
              Alert.alert('Success', 'Record deleted');
            } catch (error) {
              Alert.alert('Error', 'Failed to delete record');
            }
          },
        },
      ]
    );
  };

  const renderRecord = ({ item }: any) => (
    <View style={styles.card}>
      <View style={styles.cardHeader}>
        <View style={styles.iconContainer}>
          <Ionicons name="paw" size={24} color="#10b981" />
        </View>
        <View style={styles.cardContent}>
          <Text style={styles.livestockType}>{item.livestock_type}</Text>
          <Text style={styles.count}>Count: {item.livestock_count}</Text>
          {item.feed_consumption > 0 && (
            <Text style={styles.detail}>Feed: {item.feed_consumption}kg</Text>
          )}
          {item.mortality_count > 0 && (
            <Text style={styles.detail}>Mortality: {item.mortality_count}</Text>
          )}
          {item.expenses > 0 && (
            <Text style={styles.expenses}>Expenses: ₦{item.expenses.toLocaleString()}</Text>
          )}
          {item.notes && <Text style={styles.notes}>{item.notes}</Text>}
          <Text style={styles.date}>
            {new Date(item.record_date || item.created_at).toLocaleDateString()}
          </Text>
        </View>
        <View style={styles.actions}>
          <TouchableOpacity onPress={() => openModal(item)} style={styles.actionButton}>
            <Ionicons name="create-outline" size={20} color="#10b981" />
          </TouchableOpacity>
          <TouchableOpacity onPress={() => handleDelete(item.id)} style={styles.actionButton}>
            <Ionicons name="trash-outline" size={20} color="#ef4444" />
          </TouchableOpacity>
        </View>
      </View>
    </View>
  );

  if (loading) {
    return (
      <View style={styles.center}>
        <ActivityIndicator size="large" color="#10b981" />
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <Text style={styles.headerTitle}>Farm Records</Text>
        <TouchableOpacity onPress={() => openModal()} style={styles.addButton}>
          <Ionicons name="add" size={24} color="#fff" />
        </TouchableOpacity>
      </View>

      <FlatList
        data={records}
        renderItem={renderRecord}
        keyExtractor={(item: any) => item.id}
        contentContainerStyle={styles.list}
        refreshControl={
          <RefreshControl refreshing={refreshing} onRefresh={onRefresh} />
        }
        ListEmptyComponent={
          <View style={styles.empty}>
            <Ionicons name="document-text-outline" size={64} color="#d1d5db" />
            <Text style={styles.emptyText}>No farm records yet</Text>
          </View>
        }
      />

      <Modal visible={modalVisible} animationType="slide" transparent>
        <View style={styles.modalOverlay}>
          <View style={styles.modalContent}>
            <View style={styles.modalHeader}>
              <Text style={styles.modalTitle}>
                {editingRecord ? 'Edit Record' : 'New Record'}
              </Text>
              <TouchableOpacity onPress={() => setModalVisible(false)}>
                <Ionicons name="close" size={24} color="#666" />
              </TouchableOpacity>
            </View>

            <Text style={styles.label}>Livestock Type *</Text>
            <View style={styles.pickerContainer}>
              {['Poultry', 'Cattle', 'Pig', 'Goat', 'Fish'].map((type) => (
                <TouchableOpacity
                  key={type}
                  style={[
                    styles.typeButton,
                    formData.livestock_type === type && styles.typeButtonActive
                  ]}
                  onPress={() => setFormData({ ...formData, livestock_type: type })}
                >
                  <Text style={[
                    styles.typeText,
                    formData.livestock_type === type && styles.typeTextActive
                  ]}>
                    {type}
                  </Text>
                </TouchableOpacity>
              ))}
            </View>

            <TextInput
              style={styles.input}
              placeholder="Record Date (YYYY-MM-DD) *"
              value={formData.record_date}
              onChangeText={(text) => setFormData({ ...formData, record_date: text })}
            />

            <TextInput
              style={styles.input}
              placeholder="Livestock Count *"
              value={formData.livestock_count}
              onChangeText={(text) => setFormData({ ...formData, livestock_count: text })}
              keyboardType="numeric"
            />

            <TextInput
              style={styles.input}
              placeholder="Feed Consumption (kg)"
              value={formData.feed_consumption}
              onChangeText={(text) => setFormData({ ...formData, feed_consumption: text })}
              keyboardType="decimal-pad"
            />

            <TextInput
              style={styles.input}
              placeholder="Mortality Count"
              value={formData.mortality_count}
              onChangeText={(text) => setFormData({ ...formData, mortality_count: text })}
              keyboardType="numeric"
            />

            <TextInput
              style={styles.input}
              placeholder="Expenses (₦)"
              value={formData.expenses}
              onChangeText={(text) => setFormData({ ...formData, expenses: text })}
              keyboardType="decimal-pad"
            />

            <TextInput
              style={styles.input}
              placeholder="Expense Category"
              value={formData.expense_category}
              onChangeText={(text) => setFormData({ ...formData, expense_category: text })}
            />

            <TextInput
              style={[styles.input, styles.textArea]}
              placeholder="Notes (optional)"
              value={formData.notes}
              onChangeText={(text) => setFormData({ ...formData, notes: text })}
              multiline
              numberOfLines={3}
            />

            <TouchableOpacity style={styles.saveButton} onPress={handleSave}>
              <Text style={styles.saveButtonText}>Save Record</Text>
            </TouchableOpacity>
          </View>
        </View>
      </Modal>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#f9fafb',
  },
  center: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
  },
  header: {
    backgroundColor: '#fff',
    padding: 20,
    paddingTop: 60,
    borderBottomWidth: 1,
    borderBottomColor: '#e5e7eb',
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
  },
  headerTitle: {
    fontSize: 24,
    fontWeight: 'bold',
  },
  addButton: {
    width: 40,
    height: 40,
    borderRadius: 20,
    backgroundColor: '#10b981',
    justifyContent: 'center',
    alignItems: 'center',
  },
  list: {
    padding: 16,
  },
  card: {
    backgroundColor: '#fff',
    borderRadius: 12,
    padding: 16,
    marginBottom: 12,
    elevation: 2,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.1,
    shadowRadius: 4,
  },
  cardHeader: {
    flexDirection: 'row',
    alignItems: 'flex-start',
  },
  iconContainer: {
    width: 48,
    height: 48,
    borderRadius: 24,
    backgroundColor: '#f0fdf4',
    justifyContent: 'center',
    alignItems: 'center',
    marginRight: 12,
  },
  cardContent: {
    flex: 1,
  },
  livestockType: {
    fontSize: 16,
    fontWeight: '600',
    marginBottom: 4,
    textTransform: 'capitalize',
  },
  count: {
    fontSize: 14,
    color: '#666',
    marginBottom: 4,
  },
  detail: {
    fontSize: 14,
    color: '#666',
    marginBottom: 2,
  },
  expenses: {
    fontSize: 14,
    fontWeight: '600',
    color: '#10b981',
    marginBottom: 4,
  },
  notes: {
    fontSize: 14,
    color: '#666',
    marginBottom: 4,
  },
  date: {
    fontSize: 12,
    color: '#9ca3af',
  },
  actions: {
    flexDirection: 'row',
    gap: 8,
  },
  actionButton: {
    padding: 8,
  },
  empty: {
    alignItems: 'center',
    marginTop: 60,
  },
  emptyText: {
    fontSize: 16,
    color: '#666',
    marginTop: 16,
  },
  modalOverlay: {
    flex: 1,
    backgroundColor: 'rgba(0,0,0,0.5)',
    justifyContent: 'flex-end',
  },
  modalContent: {
    backgroundColor: '#fff',
    borderTopLeftRadius: 20,
    borderTopRightRadius: 20,
    padding: 20,
    paddingBottom: 40,
    maxHeight: '90%',
  },
  modalHeader: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    marginBottom: 20,
  },
  modalTitle: {
    fontSize: 20,
    fontWeight: 'bold',
  },
  label: {
    fontSize: 14,
    fontWeight: '600',
    marginBottom: 8,
    color: '#374151',
  },
  pickerContainer: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 8,
    marginBottom: 16,
  },
  typeButton: {
    paddingHorizontal: 16,
    paddingVertical: 8,
    borderRadius: 20,
    borderWidth: 1,
    borderColor: '#d1d5db',
    backgroundColor: '#fff',
  },
  typeButtonActive: {
    backgroundColor: '#10b981',
    borderColor: '#10b981',
  },
  typeText: {
    fontSize: 14,
    color: '#6b7280',
  },
  typeTextActive: {
    color: '#fff',
    fontWeight: '600',
  },
  input: {
    borderWidth: 1,
    borderColor: '#ddd',
    borderRadius: 8,
    padding: 12,
    marginBottom: 16,
    fontSize: 16,
  },
  textArea: {
    height: 80,
    textAlignVertical: 'top',
  },
  saveButton: {
    backgroundColor: '#10b981',
    padding: 16,
    borderRadius: 8,
    alignItems: 'center',
  },
  saveButtonText: {
    color: '#fff',
    fontSize: 16,
    fontWeight: '600',
  },
});
