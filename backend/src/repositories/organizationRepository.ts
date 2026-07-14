import { supabase } from '../utils/supabase.js';
import { SupabaseTenantRepository } from './tenantRepository.js';
import {
  CreateOrganizationInput,
  OrganizationBranding,
  OrganizationRepository,
} from '../services/organizationService.js';

interface BrandingRow {
  display_name: string | null;
  logo_url: string | null;
  primary_color: string | null;
  secondary_color: string | null;
  support_email: string | null;
  support_phone: string | null;
  custom_domain: string | null;
}

const mapBranding = (row: BrandingRow): OrganizationBranding => ({
  displayName: row.display_name,
  logoUrl: row.logo_url,
  primaryColor: row.primary_color,
  secondaryColor: row.secondary_color,
  supportEmail: row.support_email,
  supportPhone: row.support_phone,
  customDomain: row.custom_domain,
});

export class SupabaseOrganizationRepository extends SupabaseTenantRepository implements OrganizationRepository {
  async create(userId: string, input: CreateOrganizationInput) {
    const { data: organizationId, error } = await supabase.rpc('create_organization', {
      p_user_id: userId,
      p_name: input.name,
      p_legal_name: input.legalName ?? null,
      p_slug: input.slug,
      p_type: input.type,
      p_jurisdiction: input.jurisdiction,
      p_default_currency: input.defaultCurrency,
      p_timezone: input.timezone,
    });
    if (error) throw error;

    const membership = await this.findActiveMembership(userId, organizationId as string);
    if (!membership) throw new Error('Organization created without an owner membership.');
    return membership;
  }

  async getBranding(organizationId: string): Promise<OrganizationBranding | null> {
    const { data, error } = await supabase
      .from('organization_branding')
      .select('display_name, logo_url, primary_color, secondary_color, support_email, support_phone, custom_domain')
      .eq('organization_id', organizationId)
      .maybeSingle();
    if (error) throw error;
    return data ? mapBranding(data as BrandingRow) : null;
  }

  async updateBranding(
    organizationId: string,
    userId: string,
    branding: Partial<OrganizationBranding>,
  ): Promise<OrganizationBranding> {
    const { data, error } = await supabase
      .from('organization_branding')
      .upsert({
        organization_id: organizationId,
        display_name: branding.displayName,
        logo_url: branding.logoUrl,
        primary_color: branding.primaryColor,
        secondary_color: branding.secondaryColor,
        support_email: branding.supportEmail,
        support_phone: branding.supportPhone,
        custom_domain: branding.customDomain,
        updated_by: userId,
        updated_at: new Date().toISOString(),
      }, { onConflict: 'organization_id' })
      .select('display_name, logo_url, primary_color, secondary_color, support_email, support_phone, custom_domain')
      .single();
    if (error) throw error;
    return mapBranding(data as BrandingRow);
  }
}
