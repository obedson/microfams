import React, { useState } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { ShoppingBag, Clock, CheckCircle, XCircle, Truck } from 'lucide-react';
import { marketplaceApi } from '../api/marketplace';
import { LoadingSpinner } from '../components/Loading';
import toast from 'react-hot-toast';

const statusConfig = {
  pending: { icon: Clock, color: 'text-yellow-600', bg: 'bg-yellow-50' },
  confirmed: { icon: ShoppingBag, color: 'text-blue-600', bg: 'bg-blue-50' },
  shipped: { icon: Truck, color: 'text-purple-600', bg: 'bg-purple-50' },
  delivered: { icon: CheckCircle, color: 'text-green-600', bg: 'bg-green-50' },
  cancelled: { icon: XCircle, color: 'text-red-600', bg: 'bg-red-50' },
};

export default function MySales() {
  const queryClient = useQueryClient();
  const [filter, setFilter] = useState('all');
  
  const { data, isLoading } = useQuery({
    queryKey: ['my-sales'],
    queryFn: marketplaceApi.getMySales
  });

  const updateStatusMutation = useMutation({
    mutationFn: ({ orderId, status }: { orderId: string; status: string }) =>
      marketplaceApi.updateOrderStatus(orderId, status),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['my-sales'] });
      toast.success('Order status updated');
    },
    onError: (error: any) => {
      toast.error(error.message || 'Failed to update status');
    }
  });

  if (isLoading) {
    return (
      <div className="flex justify-center items-center min-h-screen">
        <LoadingSpinner size="lg" />
      </div>
    );
  }

  const orders = data?.data || [];
  const filteredOrders = filter === 'all' ? orders : orders.filter((o: any) => o.status === filter);

  return (
    <div className="max-w-7xl mx-auto px-4 py-8">
      <div className="flex justify-between items-center mb-8">
        <h1 className="text-3xl font-bold">My Sales</h1>
        <select
          value={filter}
          onChange={(e) => setFilter(e.target.value)}
          className="border rounded-lg px-4 py-2"
        >
          <option value="all">All Orders</option>
          <option value="pending">Pending</option>
          <option value="confirmed">Confirmed</option>
          <option value="shipped">Shipped</option>
          <option value="delivered">Delivered</option>
        </select>
      </div>

      {filteredOrders.length === 0 ? (
        <div className="text-center py-12 bg-white rounded-lg shadow">
          <ShoppingBag size={64} className="mx-auto text-gray-400 mb-4" />
          <p className="text-gray-600">No sales yet.</p>
        </div>
      ) : (
        <div className="space-y-4">
          {filteredOrders.map((order: any) => {
            const status = statusConfig[order.status as keyof typeof statusConfig] || statusConfig.pending;
            const StatusIcon = status.icon;

            return (
              <div key={order.id} className="bg-white rounded-lg shadow p-6">
                <div className="flex justify-between items-start mb-4">
                  <div className="flex-1">
                    <div className="flex items-center gap-3 mb-2">
                      <h3 className="text-xl font-semibold">{order.marketplace_products?.name}</h3>
                      <span className={`flex items-center gap-1 px-3 py-1 rounded-full text-sm ${status.bg} ${status.color}`}>
                        <StatusIcon size={16} />
                        {order.status}
                      </span>
                    </div>
                    <p className="text-sm text-gray-500">
                      Order placed: {new Date(order.created_at).toLocaleDateString()}
                    </p>
                  </div>
                  <div className="text-right">
                    <p className="text-2xl font-bold text-green-600">
                      ₦{order.total_amount.toLocaleString()}
                    </p>
                    <p className="text-sm text-gray-500">Qty: {order.quantity}</p>
                  </div>
                </div>

                <div className="border-t pt-4 mt-4">
                  <h4 className="font-semibold mb-2">Customer Details</h4>
                  <p className="text-gray-600">{order.delivery_address}</p>
                  <p className="text-gray-600">Phone: {order.phone}</p>
                </div>

                {order.status === 'pending' && (
                  <div className="border-t pt-4 mt-4 flex gap-3">
                    <button
                      onClick={() => updateStatusMutation.mutate({ orderId: order.id, status: 'confirmed' })}
                      className="flex-1 bg-blue-600 text-white px-4 py-2 rounded-lg hover:bg-blue-700"
                      disabled={updateStatusMutation.isPending}
                    >
                      Accept Order
                    </button>
                    <button
                      onClick={() => updateStatusMutation.mutate({ orderId: order.id, status: 'cancelled' })}
                      className="flex-1 bg-red-600 text-white px-4 py-2 rounded-lg hover:bg-red-700"
                      disabled={updateStatusMutation.isPending}
                    >
                      Cancel
                    </button>
                  </div>
                )}

                {order.status === 'confirmed' && (
                  <div className="border-t pt-4 mt-4">
                    <button
                      onClick={() => updateStatusMutation.mutate({ orderId: order.id, status: 'shipped' })}
                      className="w-full bg-purple-600 text-white px-4 py-2 rounded-lg hover:bg-purple-700"
                      disabled={updateStatusMutation.isPending}
                    >
                      Mark as Shipped
                    </button>
                  </div>
                )}

                {order.status === 'shipped' && (
                  <div className="border-t pt-4 mt-4">
                    <button
                      onClick={() => updateStatusMutation.mutate({ orderId: order.id, status: 'delivered' })}
                      className="w-full bg-green-600 text-white px-4 py-2 rounded-lg hover:bg-green-700"
                      disabled={updateStatusMutation.isPending}
                    >
                      Mark as Delivered
                    </button>
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
