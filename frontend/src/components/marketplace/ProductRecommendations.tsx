import React, { useState, useEffect } from 'react';
import { Link } from 'react-router-dom';
import { productAPI, Product } from '../../services/productAPI';
import { ShoppingBag, MapPin, Tag, ChevronRight } from 'lucide-react';

const ProductRecommendations: React.FC = () => {
  const [recommendations, setRecommendations] = useState<Product[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const fetchRecommendations = async () => {
      try {
        const data = await productAPI.getRecommendations();
        // The API returns { success: true, data: [...] } for some routes, or just [...] for others
        // Let's handle both based on common patterns in this project
        setRecommendations(Array.isArray(data) ? data : (data as any).data || []);
      } catch (error) {
        console.error('Error fetching recommended products:', error);
      } finally {
        setLoading(false);
      }
    };

    fetchRecommendations();
  }, []);

  if (loading) {
    return <div className="animate-pulse h-48 bg-white rounded-xl border border-gray-100 p-6"></div>;
  }

  if (recommendations.length === 0) {
    return null;
  }

  return (
    <div className="bg-white rounded-xl shadow-sm border border-gray-100 p-6">
      <div className="flex items-center justify-between mb-6">
        <div>
          <h3 className="text-lg font-bold text-gray-900">Essential Gear</h3>
          <p className="text-sm text-gray-500">Based on your upcoming farm visits</p>
        </div>
        <Link 
          to="/marketplace" 
          className="text-primary-600 hover:text-primary-700 text-sm font-semibold flex items-center gap-1"
        >
          Explore all <ChevronRight size={16} />
        </Link>
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
        {recommendations.slice(0, 3).map((product) => (
          <div key={product.id} className="border border-gray-100 rounded-lg overflow-hidden hover:shadow-md transition-shadow group">
            <div className="aspect-square bg-gray-50 relative overflow-hidden">
              {product.image_url ? (
                <img 
                  src={product.image_url} 
                  alt={product.name}
                  className="w-full h-full object-cover group-hover:scale-105 transition-transform duration-300"
                />
              ) : (
                <div className="w-full h-full flex items-center justify-center text-gray-300">
                  <ShoppingBag size={48} />
                </div>
              )}
              {product.bulk_discount_rate && (
                <div className="absolute top-2 left-2 bg-red-500 text-white text-[10px] font-bold px-2 py-1 rounded uppercase">
                  Bulk Sale: {product.bulk_discount_rate}% OFF
                </div>
              )}
            </div>
            <div className="p-3">
              <h4 className="font-semibold text-gray-900 text-sm truncate">{product.name}</h4>
              <p className="text-primary-600 font-bold text-base mt-1">₦{product.price.toLocaleString()}</p>
              
              <div className="flex items-center gap-3 mt-3 text-[11px] text-gray-500">
                <span className="flex items-center gap-1 truncate max-w-[100px]">
                  <MapPin size={12} /> {product.location || 'Nationwide'}
                </span>
                <span className="flex items-center gap-1">
                  <Tag size={12} /> {product.category}
                </span>
              </div>

              <Link 
                to={`/product/${product.id}`}
                className="block w-full mt-3 text-center py-2 bg-gray-50 hover:bg-primary-50 text-gray-700 hover:text-primary-700 text-xs font-bold rounded-lg transition-colors"
              >
                View Details
              </Link>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
};

export default ProductRecommendations;
