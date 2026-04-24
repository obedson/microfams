import React, { useState, useEffect } from 'react';
import { View, Text, FlatList, TouchableOpacity, StyleSheet } from 'react-native';
import { useRoute } from '@react-navigation/native';
import axios from 'axios';
import { API_URL } from '../api/client';
import { useAuthStore } from '../store/authStore';

export default function ContributionDashboardScreen() {
  const [cycle, setCycle] = useState(null);
  const [contributions, setContributions] = useState([]);
  const [loading, setLoading] = useState(true);
  const route = useRoute();
  const { token } = useAuthStore();
  const { groupId } = route.params;

  useEffect(() => {
    fetchContributions();
  }, []);

  const fetchContributions = async () => {
    try {
      const { data } = await axios.get(
        `${API_URL}/contributions/group/${groupId}/current`,
        { headers: { Authorization: `Bearer ${token}` } }
      );
      setCycle(data.cycle);
      setContributions(data.contributions);
    } catch (error) {
      console.error('Error:', error);
    } finally {
      setLoading(false);
    }
  };

  const renderContribution = ({ item }) => (
    <View style={styles.card}>
      <Text style={styles.name}>{item.user_name}</Text>
      <View style={styles.row}>
        <Text style={styles.amount}>₦{item.amount_due?.toLocaleString()}</Text>
        <View style={[styles.badge, item.status === 'paid' && styles.badgePaid]}>
          <Text style={styles.badgeText}>{item.status}</Text>
        </View>
      </View>
    </View>
  );

  if (loading) return <View style={styles.center}><Text>Loading...</Text></View>;

  return (
    <View style={styles.container}>
      {cycle && (
        <View style={styles.header}>
          <Text style={styles.title}>
            {new Date(cycle.cycle_year, cycle.cycle_month - 1).toLocaleDateString('en-US', { month: 'long', year: 'numeric' })}
          </Text>
          <Text style={styles.subtitle}>Due: {new Date(cycle.due_date).toLocaleDateString()}</Text>
        </View>
      )}
      <FlatList
        data={contributions}
        renderItem={renderContribution}
        keyExtractor={(item) => item.id}
        contentContainerStyle={styles.list}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#f5f5f5' },
  center: { flex: 1, justifyContent: 'center', alignItems: 'center' },
  header: { backgroundColor: 'white', padding: 20, borderBottomWidth: 1, borderBottomColor: '#e5e5e5' },
  title: { fontSize: 20, fontWeight: 'bold' },
  subtitle: { fontSize: 14, color: '#666', marginTop: 4 },
  list: { padding: 16 },
  card: { backgroundColor: 'white', padding: 16, borderRadius: 8, marginBottom: 12 },
  name: { fontSize: 16, fontWeight: '600', marginBottom: 8 },
  row: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  amount: { fontSize: 18, fontWeight: 'bold', color: '#10b981' },
  badge: { paddingHorizontal: 12, paddingVertical: 4, borderRadius: 12, backgroundColor: '#fbbf24' },
  badgePaid: { backgroundColor: '#10b981' },
  badgeText: { color: 'white', fontSize: 12, fontWeight: 'bold', textTransform: 'uppercase' },
});
