import { useState, useEffect } from 'react';
import axios from 'axios';

export default function ContributionHistory() {
  const [history, setHistory] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    fetchHistory();
  }, []);

  const fetchHistory = async () => {
    try {
      const { data } = await axios.get('/api/contributions/my-history');
      setHistory(data);
    } catch (error) {
      console.error('Error fetching history:', error);
    } finally {
      setLoading(false);
    }
  };

  const getStatusColor = (status: string) => {
    switch (status) {
      case 'paid': return 'bg-green-100 text-green-800';
      case 'late': return 'bg-yellow-100 text-yellow-800';
      case 'overdue': return 'bg-red-100 text-red-800';
      default: return 'bg-gray-100 text-gray-800';
    }
  };

  if (loading) return <div className="p-8">Loading...</div>;

  return (
    <div className="max-w-6xl mx-auto p-6">
      <h1 className="text-2xl font-bold mb-6">Contribution History</h1>

      {history.length === 0 ? (
        <div className="bg-white rounded-lg shadow p-8 text-center text-gray-500">
          No contribution history found
        </div>
      ) : (
        <div className="bg-white rounded-lg shadow overflow-hidden">
          <table className="min-w-full divide-y divide-gray-200">
            <thead className="bg-gray-50">
              <tr>
                <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">Group</th>
                <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">Period</th>
                <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">Amount</th>
                <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">Penalty</th>
                <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">Status</th>
                <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">Paid Date</th>
              </tr>
            </thead>
            <tbody className="bg-white divide-y divide-gray-200">
              {history.map((item) => (
                <tr key={item.id}>
                  <td className="px-6 py-4 whitespace-nowrap">
                    {item.cycle.group.name}
                  </td>
                  <td className="px-6 py-4 whitespace-nowrap">
                    {item.cycle.cycle_month}/{item.cycle.cycle_year}
                  </td>
                  <td className="px-6 py-4 whitespace-nowrap">
                    ₦{item.expected_amount.toLocaleString()}
                  </td>
                  <td className="px-6 py-4 whitespace-nowrap">
                    {item.penalty_amount > 0 ? `₦${item.penalty_amount.toLocaleString()}` : '-'}
                  </td>
                  <td className="px-6 py-4 whitespace-nowrap">
                    <span className={`px-2 py-1 text-xs rounded-full ${getStatusColor(item.payment_status)}`}>
                      {item.payment_status}
                    </span>
                  </td>
                  <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                    {item.paid_at ? new Date(item.paid_at).toLocaleDateString() : '-'}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
