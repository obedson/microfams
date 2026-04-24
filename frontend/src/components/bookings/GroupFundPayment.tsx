import React, { useState, useEffect } from 'react';
import { contributionAPI, GroupFund, GroupDiscount } from '../../services/contributionAPI';
import { Users, Info, CheckCircle2, AlertCircle } from 'lucide-react';
import toast from 'react-hot-toast';

interface GroupFundPaymentProps {
  bookingId: string;
  bookingAmount: number;
  onSuccess: () => void;
}

const GroupFundPayment: React.FC<GroupFundPaymentProps> = ({ bookingId, bookingAmount, onSuccess }) => {
  const [groups, setGroups] = useState<GroupFund[]>([]);
  const [selectedGroup, setSelectedGroup] = useState<string>('');
  const [discountInfo, setDiscountInfo] = useState<GroupDiscount | null>(null);
  const [loading, setLoading] = useState(true);
  const [processing, setProcessing] = useState(false);

  useEffect(() => {
    const fetchGroups = async () => {
      try {
        const data = await contributionAPI.getUserGroupFunds();
        setGroups(data);
      } catch (error) {
        console.error('Error fetching group funds:', error);
      } finally {
        setLoading(false);
      }
    };

    fetchGroups();
  }, []);

  useEffect(() => {
    if (selectedGroup) {
      const fetchDiscount = async () => {
        try {
          const info = await contributionAPI.calculateGroupDiscount(selectedGroup, bookingAmount);
          setDiscountInfo(info);
        } catch (error) {
          console.error('Error calculating discount:', error);
        }
      };
      fetchDiscount();
    } else {
      setDiscountInfo(null);
    }
  }, [selectedGroup, bookingAmount]);

  const handlePayment = async () => {
    if (!selectedGroup || !discountInfo) return;

    if (!discountInfo.can_afford) {
      toast.error('Insufficient group funds');
      return;
    }

    setProcessing(true);
    try {
      await contributionAPI.payWithGroupFunds(bookingId, selectedGroup, discountInfo.discounted_amount);
      toast.success('Payment successful using group funds!');
      onSuccess();
    } catch (error: any) {
      toast.error(error.message || 'Payment failed');
    } finally {
      setProcessing(false);
    }
  };

  if (loading) return <div className="animate-pulse h-24 bg-gray-50 rounded-lg"></div>;
  if (groups.length === 0) return null;

  return (
    <div className="bg-primary-50/50 border border-primary-100 rounded-xl p-6 mt-6">
      <div className="flex items-center gap-2 mb-4">
        <Users className="text-primary-600" size={20} />
        <h4 className="font-bold text-gray-900 text-sm uppercase tracking-wider">Pay with Group Funds</h4>
      </div>

      <div className="space-y-4">
        <div>
          <label className="block text-xs font-bold text-gray-500 mb-1.5 uppercase">Select Contribution Group</label>
          <select
            value={selectedGroup}
            onChange={(e) => setSelectedGroup(e.target.value)}
            className="w-full bg-white border border-gray-200 rounded-lg px-3 py-2 text-sm focus:ring-2 focus:ring-primary-500 outline-none"
          >
            <option value="">Choose a group...</option>
            {groups.map((group) => (
              <option key={group.group_id} value={group.group_id}>
                {group.group_name} (Balance: ₦{group.available_balance.toLocaleString()})
              </option>
            ))}
          </select>
        </div>

        {discountInfo && (
          <div className="bg-white border border-primary-100 rounded-lg p-4 space-y-3">
            <div className="flex justify-between text-sm">
              <span className="text-gray-500">Original Price</span>
              <span className="text-gray-900 font-medium">₦{discountInfo.original_amount.toLocaleString()}</span>
            </div>
            <div className="flex justify-between text-sm">
              <span className="text-green-600 flex items-center gap-1">
                <CheckCircle2 size={14} /> Group Discount ({discountInfo.discount_rate}%)
              </span>
              <span className="text-green-600 font-bold">- ₦{discountInfo.saving.toLocaleString()}</span>
            </div>
            <div className="pt-3 border-t border-gray-100 flex justify-between items-center">
              <span className="text-base font-bold text-gray-900">Final Amount</span>
              <span className="text-xl font-black text-primary-600">₦{discountInfo.discounted_amount.toLocaleString()}</span>
            </div>

            {!discountInfo.can_afford && (
              <div className="flex items-start gap-2 p-2.5 bg-red-50 text-red-700 rounded-lg text-xs leading-relaxed">
                <AlertCircle size={14} className="mt-0.5 flex-shrink-0" />
                <p>The selected group fund balance is insufficient for this payment.</p>
              </div>
            )}

            <button
              onClick={handlePayment}
              disabled={processing || !discountInfo.can_afford}
              className={`w-full py-3 rounded-lg font-bold text-sm transition-all shadow-sm flex items-center justify-center gap-2 ${
                processing || !discountInfo.can_afford
                  ? 'bg-gray-200 text-gray-400 cursor-not-allowed'
                  : 'bg-primary-600 text-white hover:bg-primary-700 active:scale-[0.98]'
              }`}
            >
              {processing ? 'Processing...' : `Confirm Payment from Group Funds`}
            </button>
          </div>
        )}

        {!selectedGroup && (
          <div className="flex items-start gap-2 text-[11px] text-gray-500 bg-white/50 p-3 rounded-lg border border-primary-100/50">
            <Info size={14} className="mt-0.5 flex-shrink-0" />
            <p>Using group funds may provide exclusive discounts up to 10% on your farm property bookings.</p>
          </div>
        )}
      </div>
    </div>
  );
};

export default GroupFundPayment;
