import React, { useState, useEffect } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { propertyAPI } from '../api/client';
import { X, Upload, GripVertical, Star } from 'lucide-react';

const EditProperty: React.FC = () => {
  const navigate = useNavigate();
  const { id } = useParams<{ id: string }>();
  const [formData, setFormData] = useState({
    title: '',
    description: '',
    livestock_type: '',
    space_type: '',
    size: 0,
    size_unit: 'm2',
    city: '',
    lga: '',
    price_per_month: 0,
    available_from: '',
    available_to: '',
    amenities: [] as string[]
  });
  const [currentImages, setCurrentImages] = useState<string[]>([]);
  const [newImages, setNewImages] = useState<File[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [draggedIndex, setDraggedIndex] = useState<number | null>(null);

  useEffect(() => {
    const fetchProperty = async () => {
      try {
        const response = await propertyAPI.getById(id!);
        const property = response.data.data;
        setFormData({
          title: property.title,
          description: property.description,
          livestock_type: property.livestock_type,
          space_type: property.space_type,
          size: property.size,
          size_unit: property.size_unit,
          city: property.city,
          lga: property.lga,
          price_per_month: property.price_per_month,
          available_from: property.available_from,
          available_to: property.available_to,
          amenities: property.amenities || []
        });
        setCurrentImages(property.images || []);
      } catch (error) {
        setError('Failed to load property');
      } finally {
        setLoading(false);
      }
    };

    fetchProperty();
  }, [id]);

  const handleDeleteImage = async (imageUrl: string) => {
    try {
      await propertyAPI.deleteImage(id!, imageUrl);
      setCurrentImages(currentImages.filter(img => img !== imageUrl));
    } catch (error: any) {
      const errorMessage = error.response?.data?.error || 'Failed to delete image';
      setError(errorMessage);
    }
  };

  const handleDragStart = (index: number) => {
    setDraggedIndex(index);
  };

  const handleDragOver = (e: React.DragEvent, index: number) => {
    e.preventDefault();
    if (draggedIndex === null || draggedIndex === index) return;

    const newImages = [...currentImages];
    const draggedImage = newImages[draggedIndex];
    newImages.splice(draggedIndex, 1);
    newImages.splice(index, 0, draggedImage);

    setCurrentImages(newImages);
    setDraggedIndex(index);
  };

  const handleDragEnd = async () => {
    if (draggedIndex !== null) {
      try {
        await propertyAPI.reorderImages(id!, currentImages);
      } catch (error: any) {
        const errorMessage = error.response?.data?.error || 'Failed to reorder images';
        setError(errorMessage);
      }
    }
    setDraggedIndex(null);
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setLoading(true);
    setError('');
    
    try {
      if (newImages.length > 0) {
        const updateData = new FormData();
        Object.entries(formData).forEach(([key, value]) => {
          if (Array.isArray(value)) {
            updateData.append(key, JSON.stringify(value));
          } else {
            updateData.append(key, value.toString());
          }
        });
        
        newImages.forEach((image) => {
          updateData.append('images', image);
        });
        
        await propertyAPI.update(id!, updateData);
      } else {
        await propertyAPI.update(id!, formData);
      }
      
      navigate(`/properties/${id}`);
    } catch (error: any) {
      const errorMessage = error.response?.data?.error || 'Failed to update property';
      setError(errorMessage);
    } finally {
      setLoading(false);
    }
  };

  if (loading) return <div className="p-8">Loading...</div>;

  return (
    <div className="container mx-auto px-4 py-8 max-w-4xl">
      <h1 className="text-3xl font-bold mb-8">Edit Property</h1>
      
      {error && (
        <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-6">
          {error}
        </div>
      )}
      
      <form onSubmit={handleSubmit} className="space-y-6">
        {/* Image Management Section */}
        <div className="bg-white p-6 rounded-lg border">
          <h2 className="text-xl font-semibold mb-4">Property Images</h2>
          
          {/* Current Images */}
          {currentImages.length > 0 && (
            <div className="mb-6">
              <div className="flex items-center gap-2 mb-3">
                <p className="text-sm text-gray-600">Current Images (Drag to reorder)</p>
                <Star size={16} className="text-yellow-500" />
                <span className="text-xs text-gray-500">First image is the main image</span>
              </div>
              <div className="grid grid-cols-2 md:grid-cols-3 gap-4">
                {currentImages.map((image, index) => (
                  <div
                    key={image}
                    draggable
                    onDragStart={() => handleDragStart(index)}
                    onDragOver={(e) => handleDragOver(e, index)}
                    onDragEnd={handleDragEnd}
                    className="relative group cursor-move border-2 border-gray-200 rounded-lg overflow-hidden hover:border-primary-500 transition-colors"
                  >
                    {index === 0 && (
                      <div className="absolute top-2 left-2 bg-yellow-500 text-white px-2 py-1 rounded text-xs font-semibold flex items-center gap-1 z-10">
                        <Star size={12} fill="white" />
                        Main
                      </div>
                    )}
                    <div className="absolute top-2 right-2 z-10">
                      <button
                        type="button"
                        onClick={() => handleDeleteImage(image)}
                        className="bg-red-500 text-white p-1.5 rounded-full hover:bg-red-600 transition-colors"
                      >
                        <X size={16} />
                      </button>
                    </div>
                    <div className="absolute bottom-2 left-2 bg-black bg-opacity-50 text-white p-1 rounded z-10">
                      <GripVertical size={16} />
                    </div>
                    <img
                      src={image}
                      alt={`Property ${index + 1}`}
                      className="w-full h-48 object-cover"
                    />
                  </div>
                ))}
              </div>
            </div>
          )}

          {/* Upload New Images */}
          <div>
            <label className="block text-sm font-medium mb-2">Add New Images</label>
            <div className="border-2 border-dashed border-gray-300 rounded-lg p-6 text-center hover:border-primary-500 transition-colors">
              <Upload size={32} className="mx-auto text-gray-400 mb-2" />
              <input
                type="file"
                multiple
                accept="image/*"
                className="hidden"
                id="image-upload"
                onChange={(e) => setNewImages(Array.from(e.target.files || []))}
              />
              <label htmlFor="image-upload" className="cursor-pointer">
                <span className="text-primary-600 hover:text-primary-700 font-medium">
                  Click to upload
                </span>
                <span className="text-gray-500"> or drag and drop</span>
              </label>
              <p className="text-xs text-gray-500 mt-1">PNG, JPG up to 5MB each</p>
            </div>
            {newImages.length > 0 && (
              <p className="text-sm text-green-600 mt-2">
                {newImages.length} new image(s) selected
              </p>
            )}
          </div>
        </div>

        {/* Form Fields */}
        <div className="bg-white p-6 rounded-lg border space-y-6">
          <div>
            <label className="block text-sm font-medium mb-2">Title</label>
            <input
              type="text"
              required
              className="w-full p-3 border rounded-lg"
              value={formData.title}
              onChange={(e) => setFormData({...formData, title: e.target.value})}
            />
          </div>

          <div>
            <label className="block text-sm font-medium mb-2">Description</label>
            <textarea
              required
              rows={4}
              className="w-full p-3 border rounded-lg"
              value={formData.description}
              onChange={(e) => setFormData({...formData, description: e.target.value})}
            />
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className="block text-sm font-medium mb-2">Livestock Type</label>
              <select
                required
                className="w-full p-3 border rounded-lg"
                value={formData.livestock_type}
                onChange={(e) => setFormData({...formData, livestock_type: e.target.value})}
              >
                <option value="">Select type</option>
                <option value="poultry">Poultry</option>
                <option value="pig">Pig</option>
                <option value="cattle">Cattle</option>
                <option value="fishery">Fishery</option>
                <option value="goat">Goat</option>
                <option value="rabbit">Rabbit</option>
                <option value="other">Other</option>
              </select>
            </div>

            <div>
              <label className="block text-sm font-medium mb-2">Space Type</label>
              <select
                required
                className="w-full p-3 border rounded-lg"
                value={formData.space_type}
                onChange={(e) => setFormData({...formData, space_type: e.target.value})}
              >
                <option value="">Select type</option>
                <option value="empty_land">Empty Land</option>
                <option value="equipped_house">Equipped House</option>
                <option value="empty_house">Empty House</option>
              </select>
            </div>
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className="block text-sm font-medium mb-2">Size</label>
              <input
                type="number"
                required
                min="1"
                className="w-full p-3 border rounded-lg"
                value={formData.size}
                onChange={(e) => setFormData({...formData, size: parseFloat(e.target.value)})}
              />
            </div>

            <div>
              <label className="block text-sm font-medium mb-2">Size Unit</label>
              <select
                className="w-full p-3 border rounded-lg"
                value={formData.size_unit}
                onChange={(e) => setFormData({...formData, size_unit: e.target.value})}
              >
                <option value="m2">Square Meters (m²)</option>
                <option value="units">Units</option>
              </select>
            </div>
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className="block text-sm font-medium mb-2">City</label>
              <input
                type="text"
                required
                className="w-full p-3 border rounded-lg"
                value={formData.city}
                onChange={(e) => setFormData({...formData, city: e.target.value})}
              />
            </div>

            <div>
              <label className="block text-sm font-medium mb-2">LGA</label>
              <input
                type="text"
                required
                className="w-full p-3 border rounded-lg"
                value={formData.lga}
                onChange={(e) => setFormData({...formData, lga: e.target.value})}
              />
            </div>
          </div>

          <div>
            <label className="block text-sm font-medium mb-2">Price per Month (₦)</label>
            <input
              type="number"
              required
              min="1"
              className="w-full p-3 border rounded-lg"
              value={formData.price_per_month}
              onChange={(e) => setFormData({...formData, price_per_month: parseFloat(e.target.value)})}
            />
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className="block text-sm font-medium mb-2">Available From</label>
              <input
                type="date"
                required
                className="w-full p-3 border rounded-lg"
                value={formData.available_from}
                onChange={(e) => setFormData({...formData, available_from: e.target.value})}
              />
            </div>

            <div>
              <label className="block text-sm font-medium mb-2">Available To</label>
              <input
                type="date"
                required
                className="w-full p-3 border rounded-lg"
                value={formData.available_to}
                onChange={(e) => setFormData({...formData, available_to: e.target.value})}
              />
            </div>
          </div>
        </div>

        <div className="flex gap-4">
          <button
            type="submit"
            disabled={loading}
            className="bg-green-600 text-white px-6 py-3 rounded-lg hover:bg-green-700 disabled:opacity-50"
          >
            {loading ? 'Updating...' : 'Update Property'}
          </button>
          <button
            type="button"
            onClick={() => navigate(`/properties/${id}`)}
            className="bg-gray-500 text-white px-6 py-3 rounded-lg hover:bg-gray-600"
          >
            Cancel
          </button>
        </div>
      </form>
    </div>
  );
};

export default EditProperty;
