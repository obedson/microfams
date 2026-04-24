import React, { useState, useEffect } from 'react';
import { useParams, useNavigate, Link } from 'react-router-dom';
import { Package, MapPin, User, ShoppingCart, ArrowLeft, Edit } from 'lucide-react';
import { marketplaceApi } from '../api/marketplace';
import { useAuthStore } from '../store/authStore';
import { Product } from '../types/marketplace';

const ProductDetail: React.FC = () => {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const { isAuthenticated, user } = useAuthStore();
  const [product, setProduct] = useState<Product | null>(null);
  const [loading, setLoading] = useState(true);
  const [quantity, setQuantity] = useState(1);
  const [orderLoading, setOrderLoading] = useState(false);

  const isOwner = user && product && product.supplier_id === user.id;

  useEffect(() => {
    const fetchProduct = async () => {
      try {
        const data = await marketplaceApi.getProduct(id!);
        setProduct(data);
      } catch (error) {
        console.error('Failed to fetch product:', error);
      } finally {
        setLoading(false);
      }
    };

    fetchProduct();
  }, [id]);

  const handleOrder = async () => {
    if (!isAuthenticated) {
      navigate('/login');
      return;
    }

    setOrderLoading(true);
    try {
      const response = await marketplaceApi.createOrder({
        product_id: id,
        quantity,
        delivery_address: 'Default address',
        phone: '1234567890'
      });
      
      // Redirect to payment
      if (response.success && response.order) {
        const paymentResponse = await fetch(`${process.env.REACT_APP_API_URL || 'http://localhost:3000/api'}/payments/orders/${response.order.id}/pay`, {
          method: 'POST',
          headers: {
            'Authorization': `Bearer ${localStorage.getItem('token')}`,
            'Content-Type': 'application/json'
          }
        });
        
        const paymentData = await paymentResponse.json();
        
        if (paymentData.success && paymentData.authorization_url) {
          // Redirect to Paystack
          window.location.href = paymentData.authorization_url;
        } else {
          alert('Order created but payment initialization failed');
          navigate('/marketplace/my-orders');
        }
      }
    } catch (error: any) {
      alert(error.message || 'Failed to place order');
    } finally {
      setOrderLoading(false);
    }
  };

  if (loading) return <div className="p-8">Loading product...</div>;
  if (!product) return <div className="p-8">Product not found</div>;

  const totalPrice = product.price * quantity;

  return (
    <div className="container mx-auto px-4 py-8 max-w-6xl">
      <button
        onClick={() => navigate('/marketplace')}
        className="flex items-center text-gray-600 hover:text-green-600 mb-6"
      >
        <ArrowLeft size={20} className="mr-2" />
        Back to Marketplace
      </button>

      <div className="grid md:grid-cols-2 gap-8">
        {/* Product Images */}
        <div>
          <div className="bg-gray-200 rounded-lg h-96 mb-4">
            {product.images.length > 0 ? (
              <img
                src={product.images[0]}
                alt={product.name}
                className="w-full h-full object-cover rounded-lg"
                onError={(e) => {
                  const target = e.target as HTMLImageElement;
                  target.style.display = 'none';
                  target.parentElement!.innerHTML = `
                    <div class="w-full h-full flex items-center justify-center">
                      <svg class="text-gray-400" width="96" height="96" fill="currentColor" viewBox="0 0 24 24">
                        <path d="M20 6h-2.18l-1.41-1.41A2 2 0 0 0 15 4H9a2 2 0 0 0-1.41.59L6.18 6H4a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2zM12 17a5 5 0 1 1 0-10 5 5 0 0 1 0 10zm0-8a3 3 0 1 0 0 6 3 3 0 0 0 0-6z"/>
                      </svg>
                    </div>
                  `;
                }}
              />
            ) : (
              <div className="w-full h-full flex items-center justify-center">
                <Package className="text-gray-400" size={96} />
              </div>
            )}
          </div>

          {/* Additional Images */}
          {product.images.length > 1 && (
            <div className="grid grid-cols-4 gap-2">
              {product.images.slice(1, 5).map((image: string, index: number) => (
                <div key={index} className="h-20 bg-gray-200 rounded">
                  <img
                    src={image}
                    alt={`${product.name} ${index + 2}`}
                    className="w-full h-full object-cover rounded"
                  />
                </div>
              ))}
            </div>
          )}
        </div>

        {/* Product Info */}
        <div className="space-y-6">
          <div>
            <span className="bg-blue-100 text-blue-800 px-3 py-1 rounded-full text-sm">
              {product.category}
            </span>
            <h1 className="text-3xl font-bold mt-4 mb-2">{product.name}</h1>
            <p className="text-gray-600">{product.description}</p>
          </div>

          <div className="space-y-3">
            <div className="flex justify-between">
              <span className="text-gray-600">Price:</span>
              <span className="text-2xl font-bold text-green-600">
                ₦{product.price.toLocaleString()}/{product.unit}
              </span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-600">Stock Available:</span>
              <span>{product.stock_quantity} {product.unit}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-600">Minimum Order:</span>
              <span>{product.minimum_order} {product.unit}</span>
            </div>
            <div className="flex items-center justify-between">
              <span className="text-gray-600">Location:</span>
              <div className="flex items-center">
                <MapPin size={16} className="mr-1" />
                <span>{product.location}</span>
              </div>
            </div>
          </div>

          {/* Supplier Info */}
          {product.users && (
            <div className="border-t pt-4">
              <div className="flex items-center">
                <User size={20} className="mr-2 text-gray-600" />
                <div>
                  <p className="font-medium">Supplier: {product.users.name}</p>
                  {product.users.phone && (
                    <p className="text-sm text-gray-600">Phone: {product.users.phone}</p>
                  )}
                </div>
              </div>
            </div>
          )}

          {/* Supplier Actions */}
          {isOwner && (
            <div className="border-t pt-6">
              <h3 className="font-medium mb-4">Supplier Actions</h3>
              <div className="flex gap-4">
                <Link
                  to={`/marketplace/products/${id}/edit`}
                  className="bg-blue-600 text-white px-4 py-2 rounded-lg hover:bg-blue-700 flex items-center"
                >
                  <Edit size={16} className="mr-2" />
                  Edit Product
                </Link>
              </div>
            </div>
          )}

          {/* Order Section */}
          {!isOwner && (
            <div className="border-t pt-6">
              <div className="space-y-4">
                <div>
                  <label className="block text-sm font-medium mb-2">Quantity</label>
                  <input
                    type="number"
                    min={product.minimum_order}
                    max={product.stock_quantity}
                    value={quantity}
                    onChange={(e) => setQuantity(parseInt(e.target.value))}
                    className="w-full p-3 border rounded-lg"
                  />
                </div>

                <div className="bg-gray-50 p-4 rounded-lg">
                  <div className="flex justify-between items-center">
                    <span className="text-lg font-medium">Total:</span>
                    <span className="text-2xl font-bold text-green-600">
                      ₦{totalPrice.toLocaleString()}
                    </span>
                  </div>
                </div>

                <button
                  onClick={handleOrder}
                  disabled={orderLoading || quantity < product.minimum_order}
                  className="w-full bg-green-600 text-white py-3 rounded-lg hover:bg-green-700 disabled:opacity-50 flex items-center justify-center"
                >
                  <ShoppingCart size={20} className="mr-2" />
                  {orderLoading ? 'Placing Order...' : 'Place Order'}
                </button>

                {!isAuthenticated && (
                  <p className="text-sm text-gray-600 text-center">
                    Please <button onClick={() => navigate('/login')} className="text-green-600 underline">login</button> to place an order
                  </p>
                )}
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
};

export default ProductDetail;
