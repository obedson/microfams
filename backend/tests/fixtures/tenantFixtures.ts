export type TestTenant = {
  organizationId: string;
  userId: string;
  membershipId: string;
  name: string;
  slug: string;
};

export const TEST_TENANTS: readonly [TestTenant, TestTenant] = [
  {
    organizationId: '11111111-1111-4111-8111-111111111111',
    userId: '11111111-1111-4111-8111-111111111112',
    membershipId: '11111111-1111-4111-8111-111111111113',
    name: 'Synthetic Cooperative Alpha',
    slug: 'synthetic-cooperative-alpha',
  },
  {
    organizationId: '22222222-2222-4222-8222-222222222222',
    userId: '22222222-2222-4222-8222-222222222223',
    membershipId: '22222222-2222-4222-8222-222222222224',
    name: 'Synthetic Cooperative Beta',
    slug: 'synthetic-cooperative-beta',
  },
] as const;

export const tenantFixture = (index: 0 | 1): TestTenant => TEST_TENANTS[index];

export const assertDistinctTenants = (): void => {
  const [first, second] = TEST_TENANTS;
  if (first.organizationId === second.organizationId || first.userId === second.userId) {
    throw new Error('Synthetic tenant fixtures must remain unrelated.');
  }
};
