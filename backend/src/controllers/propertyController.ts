import { Request, Response } from 'express';
import { PropertyModel } from '../models/Property.js';
import { uploadToSupabase } from '../utils/upload.js';
import { supabase } from '../utils/supabase.js';
import Joi from 'joi';

const propertySchema = Joi.object({
  title: Joi.string().min(3).required(),
  description: Joi.string().required(),
  livestock_type: Joi.string().valid('poultry', 'pig', 'cattle', 'fishery', 'goat', 'rabbit', 'other').required(),
  space_type: Joi.string().valid('empty_land', 'equipped_house', 'empty_house').required(),
  size: Joi.number().positive().required(),
  size_unit: Joi.string().valid('m2', 'units').required(),
  city: Joi.string().required(),
  lga: Joi.string().required(),
  price_per_month: Joi.number().positive().required(),
  available_from: Joi.date().required(),
  available_to: Joi.date().greater(Joi.ref('available_from')).required(),
  amenities: Joi.array().items(Joi.string()).default([]),
  images: Joi.array().items(Joi.string()).default([])
});

export const createProperty = async (req: Request, res: Response) => {
  try {
    const { error, value } = propertySchema.validate(req.body);
    if (error) {
      return res.status(400).json({ success: false, error: error.details[0].message });
    }

    const property = await PropertyModel.create({
      ...value,
      owner_id: (req as any).user.id,
      is_active: true
    });

    res.status(201).json({ success: true, data: property });
  } catch (error) {
    res.status(500).json({ success: false, error: 'Failed to create property' });
  }
};

export const getProperties = async (req: Request, res: Response) => {
  try {
    const filters = {
      livestock_type: req.query.livestock_type as string,
      city: req.query.city as string,
      min_price: req.query.min_price ? Number(req.query.min_price) : undefined,
      max_price: req.query.max_price ? Number(req.query.max_price) : undefined,
    };

    const properties = await PropertyModel.findAll(filters);
    res.json({ success: true, data: properties });
  } catch (error) {
    res.status(500).json({ success: false, error: 'Failed to fetch properties' });
  }
};

export const getProperty = async (req: Request, res: Response) => {
  try {
    const property = await PropertyModel.findById(req.params.id);
    if (!property) {
      return res.status(404).json({ success: false, error: 'Property not found' });
    }
    res.json({ success: true, data: property });
  } catch (error) {
    res.status(500).json({ success: false, error: 'Failed to fetch property' });
  }
};

export const updateProperty = async (req: Request, res: Response) => {
  try {
    const { id } = req.params;
    let updates = { ...req.body };
    
    // Convert string values to proper types
    if (updates.size) updates.size = parseFloat(updates.size);
    if (updates.price_per_month) updates.price_per_month = parseFloat(updates.price_per_month);
    if (updates.amenities && typeof updates.amenities === 'string') {
      updates.amenities = JSON.parse(updates.amenities);
    }
    
    // Handle new image uploads
    if (req.files && Array.isArray(req.files)) {
      const newImages: string[] = [];
      for (const file of req.files) {
        const imageUrl = await uploadToSupabase(file, 'properties');
        newImages.push(imageUrl);
      }
      
      // Get existing images and append new ones
      const existingProperty = await PropertyModel.findById(id);
      if (!existingProperty) {
        return res.status(404).json({ success: false, error: 'Property not found' });
      }
      
      const existingImages = existingProperty?.images || [];
      updates.images = [...existingImages, ...newImages];
    }
    
    const property = await PropertyModel.update(id, updates);
    if (!property) {
      return res.status(404).json({ success: false, error: 'Property not found or update failed' });
    }
    
    res.json({ success: true, data: property });
  } catch (error) {
    console.error('Update property error:', error);
    res.status(500).json({ success: false, error: 'Failed to update property' });
  }
};

export const deleteProperty = async (req: Request, res: Response) => {
  try {
    const { data: bookings } = await supabase
      .from('bookings')
      .select('id')
      .eq('property_id', req.params.id)
      .limit(1);

    if (bookings && bookings.length > 0) {
      return res.status(400).json({ 
        success: false, 
        error: 'Cannot delete property with existing bookings' 
      });
    }

    const success = await PropertyModel.delete(req.params.id);
    if (!success) {
      return res.status(404).json({ success: false, error: 'Property not found' });
    }
    res.json({ success: true, message: 'Property deleted' });
  } catch (error) {
    res.status(500).json({ success: false, error: 'Failed to delete property' });
  }
};

export const uploadImages = async (req: Request, res: Response) => {
  try {
    const files = req.files as Express.Multer.File[];
    if (!files || files.length === 0) {
      return res.status(400).json({ success: false, error: 'No images provided' });
    }

    const property = await PropertyModel.findById(req.params.id);
    if (!property) {
      return res.status(404).json({ success: false, error: 'Property not found' });
    }

    const imageUrls = await Promise.all(
      files.map(file => uploadToSupabase(file, 'properties'))
    );

    const updatedProperty = await PropertyModel.update(req.params.id, {
      images: [...property.images, ...imageUrls]
    });

    res.json({ success: true, data: { images: imageUrls, property: updatedProperty } });
  } catch (error) {
    res.status(500).json({ success: false, error: 'Failed to upload images' });
  }
};


export const deleteImage = async (req: Request, res: Response) => {
  try {
    const { id } = req.params;
    const { imageUrl } = req.body;

    const property = await PropertyModel.findById(id);
    if (!property) {
      return res.status(404).json({ success: false, error: 'Property not found' });
    }

    const updatedImages = property.images.filter((img: string) => img !== imageUrl);
    const updatedProperty = await PropertyModel.update(id, { images: updatedImages });

    res.json({ success: true, data: updatedProperty });
  } catch (error) {
    res.status(500).json({ success: false, error: 'Failed to delete image' });
  }
};

export const updateImageOrder = async (req: Request, res: Response) => {
  try {
    const { id } = req.params;
    const { images } = req.body;

    if (!Array.isArray(images)) {
      return res.status(400).json({ success: false, error: 'Images must be an array' });
    }

    const updatedProperty = await PropertyModel.update(id, { images });
    res.json({ success: true, data: updatedProperty });
  } catch (error) {
    res.status(500).json({ success: false, error: 'Failed to update image order' });
  }
};
