import React, { useState, useEffect } from 'react';
import { View, Text, ScrollView, TouchableOpacity, StyleSheet, Alert } from 'react-native';
import { useRoute } from '@react-navigation/native';
import axios from 'axios';
import { API_URL } from '../api/client';
import { useAuthStore } from '../store/authStore';

export default function GroupDetailScreen() {
  const [group, setGroup] = useState(null);
  const [loading, setLoading] = useState(true);
  const route = useRoute();
  const { token } = useAuthStore();
  const { id } = route.params;

  useEffect(() => {
    fetchGroup();
  }, []);

  const fetchGroup = async () => {
    try {
      const { data } = await axios.get(`${API_URL}/groups/${id}`);
      setGroup(data);
    } catch (error) {
      Alert.alert('Error', 'Failed to load group');
    } finally {
      setLoading(false);
    }
  };

  const handleJoin = async () => {
    try {
      const { data } = await axios.post(
        `${API_URL}/groups/${id}/join`,
        {},
        { headers: { Authorization: `Bearer ${token}` } }
      );
      Alert.alert('Success', 'Payment initiated. Complete payment to join.');
    } catch (error) {
      Alert.alert('Error', error.response?.data?.error || 'Failed to join group');
    }
  };

  if (loading) return <View style={styles.center}><Text>Loading...</Text></View>;
  if (!group) return <View style={styles.center}><Text>Group not found</Text></View>;

  return (
    <ScrollView style={styles.container}>
      <View style={styles.header}>
        <Text style={styles.name}>{group.name}</Text>
        <Text style={styles.category}>{group.category}</Text>
      </View>

      <View style={styles.section}>
        <Text style={styles.label}>Description</Text>
        <Text style={styles.text}>{group.description}</Text>
      </View>

      <View style={styles.section}>
        <Text style={styles.label}>Location</Text>
        <Text style={styles.text}>{group.state_name}, {group.lga_name}</Text>
      </View>

      <View style={styles.stats}>
        <View style={styles.stat}>
          <Text style={styles.statValue}>{group.member_count}</Text>
          <Text style={styles.statLabel}>Members</Text>
        </View>
        <View style={styles.stat}>
          <Text style={styles.statValue}>₦{group.entry_fee?.toLocaleString()}</Text>
          <Text style={styles.statLabel}>Entry Fee</Text>
        </View>
      </View>

      <TouchableOpacity style={styles.button} onPress={handleJoin}>
        <Text style={styles.buttonText}>Join Group</Text>
      </TouchableOpacity>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: 'white' },
  center: { flex: 1, justifyContent: 'center', alignItems: 'center' },
  header: { padding: 20, borderBottomWidth: 1, borderBottomColor: '#e5e5e5' },
  name: { fontSize: 24, fontWeight: 'bold', marginBottom: 8 },
  category: { fontSize: 14, color: '#10b981', textTransform: 'uppercase' },
  section: { padding: 20, borderBottomWidth: 1, borderBottomColor: '#e5e5e5' },
  label: { fontSize: 12, color: '#666', marginBottom: 8, textTransform: 'uppercase' },
  text: { fontSize: 16, color: '#333' },
  stats: { flexDirection: 'row', padding: 20 },
  stat: { flex: 1, alignItems: 'center' },
  statValue: { fontSize: 24, fontWeight: 'bold', color: '#10b981' },
  statLabel: { fontSize: 12, color: '#666', marginTop: 4 },
  button: { margin: 20, backgroundColor: '#10b981', padding: 16, borderRadius: 8, alignItems: 'center' },
  buttonText: { color: 'white', fontSize: 16, fontWeight: 'bold' },
});
