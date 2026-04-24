import React from 'react';
import { useQuery } from '@tanstack/react-query';
import { useNavigate } from 'react-router-dom';
import { Package, Clock, CheckCircle, XCircle, Truck } from 'lucide-react';
import { marketplaceApi } from '../api/marketplace';
import { LoadingSpinner } from '../components/Loading';

const statusConfig = {
  pending: { icon: Clock, color: 'text-yellow-600', bg: 'bg-yellow-50', label: 'Pending' },
  processing: { icon: Package, color: 'text-blue-600', bg: 'bg-blue-50', label: 'Processing' },
  shipped: { icon: Truck, color: 'text-purple-600', bg: 'bg-purple-50', label: 'Shipped' },
  delivered: { icon: CheckCircle, color: 'text-green-600', bg: 'bg-green-50', label: 'Delivered' },
  cancelled: { icon: XCircle, color: 'text-red-600', bg: 'bg-red-50', label: 'Cancelled' },
};

export default function MyOrders() {
  const navigate = useNavigate();
  
  const { data, isLoading } = useQuery({
    queryKey: ['my-orders'],
    queryFn: marketplaceApi.getMyOrders
  });

  if (isLoading) {
    return (
      <div className="flex justify-center items-center min-h-screen">
        <LoadingSpinner size="lg" />
      </div>
    );
  }

  const orders = data?.data || [];

  return (
    <div className="max-w-7xl mx-auto px-4 py-8">
      <h1 className="text-3xl font-bold mb-8">My Orders</h1>

      {orders.length === 0 ? (
        <div className="text-center py-12 bg-white rounded-lg shadow">
          <Package size={64} className="mx-auto text-gray-400 mb-4" />
          <p className="text-gray-600 mb-4">You haven't placed any orders yet.</p>
          <button
            onClick={() => navigate('/marketplace')}
            className="bg-green-600 text-white px-6 py-2 rounded-lg hover:bg-green-700"
          >
            Browse Marketplace
          </button>
        </div>
      ) : (
        <div className="space-y-4">
          {orders.map((order: any) => {
            const status = statusConfig[order.status as keyof typeof statusConfig] || statusConfig.pending;
            const StatusIcon = status.icon;

            return (
              <div key={order.id} className="bg-white rounded-lg shadow p-6">
                <div className="flex justify-between items-start mb-4">
                  <div className="flex-1">
                    <div className="flex items-center gap-3 mb-2">
                      <h3 className="text-xl font-semibold">{order.marketplace_products?.name || 'Product'}</h3>
                      <span className={`flex items-center gap-1 px-3 py-1 rounded-full text-sm ${status.bg} ${status.color}`}>
                        <StatusIcon size={16} />
                        {status.label}
                      </span>
                    </div>
                    <p className="text-gray-600">Order ID: {order.id.slice(0, 8)}</p>
                    <p className="text-sm text-gray-500">
                      Placed on {new Date(order.created_at).toLocaleDateString()}
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
                  <h4 className="font-semibold mb-2">Delivery Information</h4>
                  <p className="text-gray-600">{order.delivery_address}</p>
                  <p className="text-gray-600">Phone: {order.phone}</p>
                </div>

                {order.marketplace_products && (
                  <div className="border-t pt-4 mt-4">
                    <h4 className="font-semibold mb-2">Seller Information</h4>
                    <p className="text-gray-600">
                      Seller: {order.marketplace_products.users?.name || 'N/A'}
                    </p>
                    {order.marketplace_products.users?.phone && (
                      <p className="text-gray-600">
                        Phone: {order.marketplace_products.users.phone}
                      </p>
                    )}
                    {order.marketplace_products.users?.email && (
                      <p className="text-gray-600">
                        Email: {order.marketplace_products.users.email}
                      </p>
                    )}
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
