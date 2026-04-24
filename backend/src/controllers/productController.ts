import { Request, Response } from 'express';
import { supabase } from '../utils/supabase.js';
import { uploadToSupabase } from '../utils/upload.js';
import { AuthenticatedRequest } from '../types/index.js';
import { MarketplaceService } from '../services/marketplaceService.js';

export const getProducts = async (req: Request, res: Response) => {
  try {
    const { category, location } = req.query;
    
    let query = supabase
      .from('marketplace_products')
      .select('*, users(name, phone)')
      .order('created_at', { ascending: false });

    if (category) query = query.eq('category', category);
    if (location) query = query.ilike('location', `%${location}%`);

    const { data, error } = await query;
    if (error) throw error;
    
    res.json(data);
  } catch (error) {
    res.status(500).json({ error: 'Failed to fetch products' });
  }
};

export const getRecommendations = async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user?.id;
    if (!userId) return res.status(401).json({ error: 'Unauthorized' });

    const recommendations = await MarketplaceService.getRecommendedProducts(userId);
    res.json(recommendations);
  } catch (error) {
    res.status(500).json({ error: 'Failed to fetch recommendations' });
  }
};

export const calculateBulkDiscount = async (req: Request, res: Response) => {
  try {
    const { id: productId } = req.params;
    const { quantity } = req.query;
    
    const result = await MarketplaceService.calculateBulkDiscount(
      productId, 
      parseInt(quantity as string) || 1
    );
    res.json(result);
  } catch (error: any) {
    res.status(400).json({ error: error.message });
  }
};

export const getProduct = async (req: Request, res: Response) => {
  try {
    const { id } = req.params;
    const { data, error } = await supabase
      .from('marketplace_products')
      .select('*, users(name, phone)')
      .eq('id', id)
      .single();

    if (error) throw error;
    res.json(data);
  } catch (error) {
    res.status(500).json({ error: 'Product not found' });
  }
};

export const createProduct = async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { name, category, description, price, unit, stock_quantity, minimum_order, location } = req.body;
    
    // Handle image uploads to Supabase Storage
    const images: string[] = [];
    if (req.files && Array.isArray(req.files)) {
      for (const file of req.files) {
        try {
          const imageUrl = await uploadToSupabase(file, 'products');
          images.push(imageUrl);
        } catch (uploadError) {
          console.error('Image upload failed:', uploadError);
        }
      }
    }
    
    const { data, error } = await supabase
      .from('marketplace_products')
      .insert({
        supplier_id: req.user?.id,
        name,
        category,
        description,
        price: parseFloat(price),
        stock_quantity: parseInt(stock_quantity),
        unit: unit || 'kg',
        minimum_order: parseInt(minimum_order) || 1,
        location: location || null,
        images: images,
        image_url: images[0] || null
      })
      .select()
      .single();

    if (error) throw error;
    res.status(201).json(data);
  } catch (error) {
    console.error('Product creation error:', error);
    res.status(500).json({ error: 'Failed to create product' });
  }
};

export const updateProduct = async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { id } = req.params;
    const { name, category, description, price, unit, stock_quantity, minimum_order, location } = req.body;
    
    const parsedPrice = parseFloat(price);
    const parsedStock = parseInt(stock_quantity);
    const parsedMinOrder = parseInt(minimum_order);
    
    if (!name) {
      return res.status(400).json({ error: 'Product name is required' });
    }
    
    if (isNaN(parsedPrice) || parsedPrice <= 0) {
      return res.status(400).json({ error: 'Valid price greater than 0 is required' });
    }
    
    if (isNaN(parsedStock) || parsedStock < 0) {
      return res.status(400).json({ error: 'Valid stock quantity (0 or more) is required' });
    }
    
    const updates: any = {
      name,
      category: category || null,
      description: description || null,
      price: parsedPrice,
      stock_quantity: parsedStock,
      unit: unit || 'kg',
      minimum_order: isNaN(parsedMinOrder) ? 1 : parsedMinOrder,
      location: location || null
    };
    
    // Handle image uploads if present
    if (req.files && Array.isArray(req.files) && req.files.length > 0) {
      try {
        const imageUrl = await uploadToSupabase(req.files[0], 'products');
        
        // Get existing images
        const { data: existing } = await supabase
          .from('marketplace_products')
          .select('images')
          .eq('id', id)
          .single();
        
        const existingImages = existing?.images || [];
        updates.images = [imageUrl, ...existingImages];
        updates.image_url = imageUrl;
      } catch (uploadError) {
        console.error('Image upload failed:', uploadError);
      }
    }
    
    const { data, error } = await supabase
      .from('marketplace_products')
      .update(updates)
      .eq('id', id)
      .eq('supplier_id', req.user?.id)
      .select()
      .single();

    if (error) {
      console.error('Supabase update error:', error);
      throw error;
    }
    
    res.json(data);
  } catch (error) {
    console.error('Update product error:', error);
    res.status(500).json({ error: 'Failed to update product' });
  }
};

export const deleteProduct = async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { id } = req.params;
    
    const { error } = await supabase
      .from('marketplace_products')
      .delete()
      .eq('id', id)
      .eq('supplier_id', req.user?.id);

    if (error) throw error;
    res.json({ message: 'Product deleted successfully' });
  } catch (error) {
    res.status(500).json({ error: 'Failed to delete product' });
  }
};
