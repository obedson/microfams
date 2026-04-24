import React from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useNavigate } from 'react-router-dom';
import { Package, Plus, Edit, Trash2 } from 'lucide-react';
import { marketplaceApi } from '../api/marketplace';
import { LoadingSpinner } from '../components/Loading';
import toast from 'react-hot-toast';

export default function MyMarketplaceProducts() {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  
  const { data, isLoading } = useQuery({
    queryKey: ['my-marketplace-products'],
    queryFn: marketplaceApi.getMyProducts
  });

  const deleteMutation = useMutation({
    mutationFn: marketplaceApi.deleteProduct,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['my-marketplace-products'] });
      toast.success('Product deleted successfully');
    },
    onError: (error: any) => {
      toast.error(error.message || 'Failed to delete product');
    }
  });

  const handleDelete = (productId: string, productName: string) => {
    if (window.confirm(`Are you sure you want to delete "${productName}"?`)) {
      deleteMutation.mutate(productId);
    }
  };

  if (isLoading) {
    return (
      <div className="flex justify-center items-center min-h-screen">
        <LoadingSpinner size="lg" />
      </div>
    );
  }

  const products = data?.data || [];

  return (
    <div className="max-w-7xl mx-auto px-4 py-8">
      <div className="flex justify-between items-center mb-8">
        <h1 className="text-3xl font-bold">My Products</h1>
        <button
          onClick={() => navigate('/marketplace/add-product')}
          className="bg-green-600 text-white px-6 py-2 rounded-lg hover:bg-green-700 flex items-center gap-2"
        >
          <Plus size={20} />
          Add Product
        </button>
      </div>

      {products.length === 0 ? (
        <div className="text-center py-12 bg-white rounded-lg shadow">
          <Package size={64} className="mx-auto text-gray-400 mb-4" />
          <p className="text-gray-600 mb-4">You haven't listed any products yet.</p>
          <button
            onClick={() => navigate('/marketplace/add-product')}
            className="bg-green-600 text-white px-6 py-2 rounded-lg hover:bg-green-700"
          >
            List Your First Product
          </button>
        </div>
      ) : (
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
          {products.map((product: any) => (
            <div key={product.id} className="bg-white rounded-lg shadow overflow-hidden">
              {product.images?.[0] && (
                <img
                  src={product.images[0]}
                  alt={product.name}
                  className="w-full h-48 object-cover"
                />
              )}
              <div className="p-4">
                <h3 className="text-xl font-semibold mb-2">{product.name}</h3>
                <p className="text-gray-600 text-sm mb-2 line-clamp-2">{product.description}</p>
                <div className="flex justify-between items-center mb-4">
                  <p className="text-2xl font-bold text-green-600">
                    ₦{product.price.toLocaleString()}
                  </p>
                  <p className="text-sm text-gray-500">
                    Stock: {product.stock_quantity || 0}
                  </p>
                </div>
                
                <div className="flex gap-2">
                  <button
                    onClick={() => navigate(`/marketplace/products/${product.id}/edit`)}
                    className="flex-1 bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 flex items-center justify-center gap-2"
                  >
                    <Edit size={16} />
                    Edit
                  </button>
                  <button
                    onClick={() => handleDelete(product.id, product.name)}
                    disabled={deleteMutation.isPending}
                    className="flex-1 bg-red-600 text-white px-4 py-2 rounded hover:bg-red-700 flex items-center justify-center gap-2"
                  >
                    <Trash2 size={16} />
                    Delete
                  </button>
                </div>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
