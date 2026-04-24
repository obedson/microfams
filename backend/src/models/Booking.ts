import supabase from '../utils/supabase.js';

export interface Booking {
  id: string;
  property_id: string;
  farmer_id: string;
  start_date: string;
  end_date: string;
  total_amount: number;
  status: 'pending_payment' | 'pending' | 'confirmed' | 'cancelled' | 'completed';
  payment_status: 'pending' | 'paid' | 'failed';
  payment_reference?: string;
  payment_retry_count: number;
  payment_timeout_at?: string;
  notes?: string;
  rejection_reason?: string;
  cancelled_by?: string;
  cancelled_at?: string;
  created_at: string;
  updated_at: string;
}

export interface BookingFilters {
  status?: string[];
  payment_status?: string[];
  property_id?: string;
  date_from?: string;
  date_to?: string;
  search?: string;
  page: number;
  limit: number;
}

export interface PaginatedBookingResult {
  bookings: any[];
  pagination: {
    total: number;
    page: number;
    limit: number;
    total_pages: number;
  };
}

export class BookingModel {
  static async create(bookingData: Omit<Booking, 'id' | 'created_at' | 'updated_at'>): Promise<Booking> {
    const { data, error } = await supabase
      .from('bookings')
      .insert(bookingData)
      .select()
      .single();

    if (error) throw error;
    return data;
  }

  static async findById(id: string): Promise<Booking | null> {
    const { data, error } = await supabase
      .from('bookings')
      .select('*')
      .eq('id', id)
      .single();

    if (error) return null;
    return data;
  }

  static async findByIdWithDetails(id: string): Promise<any | null> {
    const { data, error } = await supabase
      .from('bookings')
      .select(`
        *,
        properties (
          id,
          title,
          city,
          lga,
          livestock_type,
          owner_id,
          users!properties_owner_id_fkey (
            id,
            name,
            email
          )
        ),
        users!bookings_farmer_id_fkey (
          id,
          name,
          email,
          phone
        )
      `)
      .eq('id', id)
      .single();

    if (error) return null;
    
    // Flatten the structure for easier access
    return {
      ...data,
      property_title: data.properties?.title,
      property_city: data.properties?.city,
      property_lga: data.properties?.lga,
      property_livestock_type: data.properties?.livestock_type,
      owner_id: data.properties?.users?.id,
      owner_name: data.properties?.users?.name,
      owner_email: data.properties?.users?.email,
      farmer_name: data.users?.name,
      farmer_email: data.users?.email,
      farmer_phone: data.users?.phone,
    };
  }

  static async findByFarmer(farmerId: string): Promise<Booking[]> {
    const { data, error } = await supabase
      .from('bookings')
      .select(`
        *,
        properties (
          title,
          city,
          lga,
          livestock_type,
          users!properties_owner_id_fkey (
            name,
            email,
            phone
          )
        )
      `)
      .eq('farmer_id', farmerId)
      .order('created_at', { ascending: false });

    if (error) throw error;
    return data || [];
  }

  static async findByOwner(
    ownerId: string, 
    status?: string, 
    propertyId?: string
  ): Promise<any[]> {
    let query = supabase
      .from('bookings')
      .select(`
        *,
        properties!inner (
          id,
          title,
          city,
          lga,
          livestock_type,
          owner_id
        ),
        users!bookings_farmer_id_fkey (
          id,
          name,
          email,
          phone
        )
      `)
      .eq('properties.owner_id', ownerId);

    if (status) {
      query = query.eq('status', status);
    }

    if (propertyId) {
      query = query.eq('property_id', propertyId);
    }

    query = query.order('created_at', { ascending: false });

    const { data, error } = await query;

    if (error) throw error;
    return data || [];
  }

  static async findByProperty(propertyId: string): Promise<Booking[]> {
    const { data, error } = await supabase
      .from('bookings')
      .select(`
        *,
        users!bookings_farmer_id_fkey (
          name,
          email,
          phone
        )
      `)
      .eq('property_id', propertyId)
      .order('created_at', { ascending: false });

    if (error) throw error;
    return data || [];
  }

  static async completePayment(
    id: string, 
    paymentReference: string
  ): Promise<void> {
    if (!paymentReference) {
      throw new Error('Payment reference is required to complete payment');
    }

    const { error } = await supabase
      .from('bookings')
      .update({ 
        payment_status: 'paid',
        status: 'confirmed',
        payment_reference: paymentReference,
        updated_at: new Date().toISOString() 
      })
      .eq('id', id);

    if (error) throw error;
  }

  static async updateStatus(
    id: string, 
    status: string, 
    rejectionReason?: string,
    cancelledBy?: string
  ): Promise<void> {
    const updateData: any = { 
      status, 
      updated_at: new Date().toISOString() 
    };
    
    if (rejectionReason) {
      updateData.rejection_reason = rejectionReason;
    }

    if (status === 'cancelled') {
      updateData.cancelled_at = new Date().toISOString();
      if (cancelledBy) {
        updateData.cancelled_by = cancelledBy;
      }
    }

    const { error } = await supabase
      .from('bookings')
      .update(updateData)
      .eq('id', id);

    if (error) throw error;
  }

  static async updatePaymentStatus(
    id: string, 
    paymentStatus: string, 
    paymentReference?: string
  ): Promise<void> {
    const updateData: any = { 
      payment_status: paymentStatus, 
      updated_at: new Date().toISOString() 
    };
    
    if (paymentReference) {
      updateData.payment_reference = paymentReference;
    }

    const { error } = await supabase
      .from('bookings')
      .update(updateData)
      .eq('id', id);

    if (error) throw error;
  }

  static async checkConflict(
    propertyId: string, 
    startDate: string, 
    endDate: string,
    excludeBookingId?: string
  ): Promise<boolean> {
    let query = supabase
      .from('bookings')
      .select('id')
      .eq('property_id', propertyId)
      .in('status', ['pending_payment', 'pending', 'confirmed'])
      .or(`and(start_date.lte.${endDate},end_date.gte.${startDate})`);

    if (excludeBookingId) {
      query = query.neq('id', excludeBookingId);
    }

    const { data, error } = await query;

    if (error) throw error;
    return (data?.length || 0) > 0;
  }

  static async getOwnerStats(ownerId: string): Promise<any> {
    // Get bookings
    const { data: bookings, error: bookingsError } = await supabase
      .from('bookings')
      .select(`
        id,
        status,
        payment_status,
        total_amount,
        properties!inner (
          owner_id
        )
      `)
      .eq('properties.owner_id', ownerId);

    if (bookingsError) {
      console.error('Bookings query error:', bookingsError);
      throw bookingsError;
    }

    // Get properties
    const { data: properties, error: propertiesError } = await supabase
      .from('properties')
      .select('id, is_active')
      .eq('owner_id', ownerId);

    if (propertiesError) {
      console.error('Properties query error:', propertiesError);
      throw propertiesError;
    }

    const stats = {
      total: bookings?.length || 0,
      pending: bookings?.filter(b => b.status === 'pending').length || 0,
      confirmed: bookings?.filter(b => b.status === 'confirmed').length || 0,
      completed: bookings?.filter(b => b.status === 'completed').length || 0,
      cancelled: bookings?.filter(b => b.status === 'cancelled').length || 0,
      totalRevenue: bookings
        ?.filter(b => b.payment_status === 'paid' && b.status !== 'cancelled')
        .reduce((sum, b) => sum + parseFloat(b.total_amount), 0) || 0,
      pendingRevenue: bookings
        ?.filter(b => (b.status === 'pending' || b.status === 'confirmed') && b.payment_status === 'paid')
        .reduce((sum, b) => sum + parseFloat(b.total_amount), 0) || 0,
      totalProperties: properties?.length || 0,
      activeProperties: properties?.filter(p => p.is_active).length || 0,
    };

    return stats;
  }

  static async getUpcomingBookings(ownerId: string, limit: number = 5): Promise<any[]> {
    const today = new Date().toISOString().split('T')[0];
    
    const { data, error } = await supabase
      .from('bookings')
      .select(`
        *,
        properties!inner (
          id,
          title,
          owner_id
        ),
        users!bookings_farmer_id_fkey (
          name,
          email,
          phone
        )
      `)
      .eq('properties.owner_id', ownerId)
      .eq('status', 'confirmed')
      .gte('start_date', today)
      .order('start_date', { ascending: true })
      .limit(limit);

    if (error) throw error;
    return data || [];
  }

  static async getBookedDates(propertyId: string): Promise<Array<{start_date: string, end_date: string}>> {
    const { data, error } = await supabase
      .from('bookings')
      .select('start_date, end_date')
      .eq('property_id', propertyId)
      .in('status', ['pending', 'confirmed', 'pending_payment']);

    if (error) throw error;
    return data || [];
  }

  static async findByFarmerWithFilters(farmerId: string, filters: BookingFilters): Promise<PaginatedBookingResult> {
    let query = supabase
      .from('bookings')
      .select(`
        *,
        properties (
          title,
          city,
          lga,
          livestock_type,
          owner_id,
          users!properties_owner_id_fkey (
            name,
            email,
            phone
          )
        )
      `, { count: 'exact' })
      .eq('farmer_id', farmerId);

    // Apply filters
    if (filters.status && filters.status.length > 0) {
      query = query.in('status', filters.status);
    }

    if (filters.payment_status && filters.payment_status.length > 0) {
      query = query.in('payment_status', filters.payment_status);
    }

    if (filters.property_id) {
      query = query.eq('property_id', filters.property_id);
    }

    if (filters.date_from) {
      query = query.gte('start_date', filters.date_from);
    }

    if (filters.date_to) {
      query = query.lte('end_date', filters.date_to);
    }

    if (filters.search) {
      // Search in property title or booking reference (id)
      query = query.or(`properties.title.ilike.%${filters.search}%,id.ilike.%${filters.search}%`);
    }

    // Apply pagination
    const offset = (filters.page - 1) * filters.limit;
    query = query
      .order('created_at', { ascending: false })
      .range(offset, offset + filters.limit - 1);

    const { data, error, count } = await query;

    if (error) throw error;

    return {
      bookings: data || [],
      pagination: {
        total: count || 0,
        page: filters.page,
        limit: filters.limit,
        total_pages: Math.ceil((count || 0) / filters.limit)
      }
    };
  }

  static async findByOwnerWithFilters(ownerId: string, filters: BookingFilters): Promise<PaginatedBookingResult> {
    let query = supabase
      .from('bookings')
      .select(`
        *,
        properties!inner (
          id,
          title,
          city,
          lga,
          livestock_type,
          owner_id
        ),
        users!bookings_farmer_id_fkey (
          id,
          name,
          email,
          phone
        )
      `, { count: 'exact' })
      .eq('properties.owner_id', ownerId);

    // Apply filters
    if (filters.status && filters.status.length > 0) {
      query = query.in('status', filters.status);
    }

    if (filters.payment_status && filters.payment_status.length > 0) {
      query = query.in('payment_status', filters.payment_status);
    }

    if (filters.property_id) {
      query = query.eq('property_id', filters.property_id);
    }

    if (filters.date_from) {
      query = query.gte('start_date', filters.date_from);
    }

    if (filters.date_to) {
      query = query.lte('end_date', filters.date_to);
    }

    if (filters.search) {
      // Search in farmer name or booking reference (id)
      query = query.or(`users.name.ilike.%${filters.search}%,id.ilike.%${filters.search}%`);
    }

    // Apply pagination
    const offset = (filters.page - 1) * filters.limit;
    query = query
      .order('created_at', { ascending: false })
      .range(offset, offset + filters.limit - 1);

    const { data, error, count } = await query;

    if (error) throw error;

    return {
      bookings: data || [],
      pagination: {
        total: count || 0,
        page: filters.page,
        limit: filters.limit,
        total_pages: Math.ceil((count || 0) / filters.limit)
      }
    };
  }

  static async updatePaymentRetry(id: string, newPaymentReference: string): Promise<void> {
    // First get current retry count
    const { data: currentBooking, error: fetchError } = await supabase
      .from('bookings')
      .select('payment_retry_count')
      .eq('id', id)
      .single();

    if (fetchError) throw fetchError;

    const newRetryCount = (currentBooking?.payment_retry_count || 0) + 1;

    const { error } = await supabase
      .from('bookings')
      .update({
        payment_reference: newPaymentReference,
        payment_retry_count: newRetryCount,
        payment_status: 'pending',
        updated_at: new Date().toISOString()
      })
      .eq('id', id);

    if (error) throw error;
  }

  static async updatePaymentTimeout(id: string, timeoutAt: Date): Promise<void> {
    const { error } = await supabase
      .from('bookings')
      .update({
        payment_timeout_at: timeoutAt.toISOString(),
        updated_at: new Date().toISOString()
      })
      .eq('id', id);

    if (error) throw error;
  }

  static async getBookingHistory(id: string): Promise<any> {
    // Get booking status history
    const { data: statusHistory, error: statusError } = await supabase
      .from('booking_status_history')
      .select(`
        *,
        users (name)
      `)
      .eq('booking_id', id)
      .order('created_at', { ascending: true });

    if (statusError) throw statusError;

    // Get audit logs related to this booking
    const { data: auditLogs, error: auditError } = await supabase
      .from('audit_logs')
      .select(`
        *,
        users (name)
      `)
      .eq('resource_type', 'booking')
      .eq('resource_id', id)
      .order('created_at', { ascending: true });

    if (auditError) throw auditError;

    return {
      status_history: statusHistory || [],
      audit_logs: auditLogs || []
    };
  }
}
