import React, { useState, useEffect } from 'react';
import axios from 'axios';
import toast from 'react-hot-toast';
import { LoadingSpinner } from '../components/Loading';

const API_URL = process.env.REACT_APP_API_URL || 'http://localhost:3001/api';

interface AuditLog {
  id: string;
  created_at: string;
  action: string;
  resource_type: string;
  ip_address: string;
  users?: { name: string; email: string };
}

export default function AuditLogs() {
  const [logs, setLogs] = useState<AuditLog[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    fetchLogs();
  }, []);

  const fetchLogs = async () => {
    try {
      const token = localStorage.getItem('token');
      const { data } = await axios.get(`${API_URL}/admin/audit-logs`, {
        headers: { Authorization: `Bearer ${token}` }
      });
      setLogs(data);
    } catch (error) {
      toast.error('Failed to load audit logs');
    } finally {
      setLoading(false);
    }
  };

  if (loading) return <LoadingSpinner size="lg" />;

  return (
    <div className="max-w-7xl mx-auto px-4 py-8">
      <h1 className="text-3xl font-bold mb-8">Audit Logs</h1>

      <div className="bg-white rounded-lg shadow overflow-hidden">
        <table className="min-w-full divide-y divide-gray-200">
          <thead className="bg-gray-50">
            <tr>
              <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">Time</th>
              <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">User</th>
              <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">Action</th>
              <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">Resource</th>
              <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">IP</th>
            </tr>
          </thead>
          <tbody className="bg-white divide-y divide-gray-200">
            {logs.map((log) => (
              <tr key={log.id}>
                <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                  {new Date(log.created_at).toLocaleString()}
                </td>
                <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-900">
                  {log.users?.name || 'System'}
                </td>
                <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-900">
                  {log.action}
                </td>
                <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                  {log.resource_type}
                </td>
                <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                  {log.ip_address}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
