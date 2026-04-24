import { useState, useEffect } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import axios from 'axios';

export default function MakeContribution() {
  const { contributionId } = useParams();
  const navigate = useNavigate();
  const [contribution, setContribution] = useState<any>(null);
  const [penalty, setPenalty] = useState(0);
  const [loading, setLoading] = useState(true);
  const [processing, setProcessing] = useState(false);

  useEffect(() => {
    fetchContribution();
  }, [contributionId]);

  const fetchContribution = async () => {
    try {
      const { data } = await axios.get(`/api/contributions/${contributionId}`);
      setContribution(data);
      
      const penaltyAmount = await calculatePenalty();
      setPenalty(penaltyAmount);
    } catch (error) {
      console.error('Error fetching contribution:', error);
    } finally {
      setLoading(false);
    }
  };

  const calculatePenalty = async () => {
    try {
      const { data } = await axios.get(`/api/contributions/${contributionId}/penalty`);
      return data.penalty || 0;
    } catch (error) {
      return 0;
    }
  };

  const handlePayment = async () => {
    setProcessing(true);
    try {
      const totalAmount = contribution.expected_amount + penalty;
      
      // Initialize Paystack payment
      const { data } = await axios.post('/api/payments/initialize', {
        amount: totalAmount * 100, // Convert to kobo
        email: contribution.member.user.email,
        metadata: {
          contribution_id: contributionId,
          type: 'contribution'
        }
      });

      // Redirect to Paystack
      window.location.href = data.authorization_url;
    } catch (error: any) {
      alert(error.response?.data?.error || 'Payment failed');
      setProcessing(false);
    }
  };

  if (loading) return <div className="p-8">Loading...</div>;
  if (!contribution) return <div className="p-8">Contribution not found</div>;

  const totalAmount = contribution.expected_amount + penalty;
  const isOverdue = new Date() > new Date(contribution.cycle.deadline_date);

  return (
    <div className="max-w-2xl mx-auto p-6">
      <h1 className="text-2xl font-bold mb-6">Make Contribution Payment</h1>

      <div className="bg-white rounded-lg shadow p-6 space-y-4">
        <div>
          <p className="text-sm text-gray-600">Group</p>
          <p className="font-semibold">{contribution.cycle.group.name}</p>
        </div>

        <div>
          <p className="text-sm text-gray-600">Cycle</p>
          <p className="font-semibold">
            {contribution.cycle.cycle_month}/{contribution.cycle.cycle_year}
          </p>
        </div>

        <div>
          <p className="text-sm text-gray-600">Deadline</p>
          <p className={`font-semibold ${isOverdue ? 'text-red-600' : ''}`}>
            {new Date(contribution.cycle.deadline_date).toLocaleDateString()}
            {isOverdue && ' (Overdue)'}
          </p>
        </div>

        <div className="border-t pt-4">
          <div className="flex justify-between mb-2">
            <span>Expected Amount</span>
            <span>₦{contribution.expected_amount.toLocaleString()}</span>
          </div>
          
          {penalty > 0 && (
            <div className="flex justify-between mb-2 text-red-600">
              <span>Late Penalty</span>
              <span>₦{penalty.toLocaleString()}</span>
            </div>
          )}

          <div className="flex justify-between font-bold text-lg border-t pt-2">
            <span>Total Amount</span>
            <span>₦{totalAmount.toLocaleString()}</span>
          </div>
        </div>

        <button
          onClick={handlePayment}
          disabled={processing || contribution.payment_status === 'paid'}
          className="w-full bg-green-600 text-white py-3 rounded-lg hover:bg-green-700 disabled:bg-gray-400"
        >
          {processing ? 'Processing...' : contribution.payment_status === 'paid' ? 'Already Paid' : 'Pay Now'}
        </button>

        <button
          onClick={() => navigate(-1)}
          className="w-full border border-gray-300 py-3 rounded-lg hover:bg-gray-50"
        >
          Cancel
        </button>
      </div>
    </div>
  );
}
