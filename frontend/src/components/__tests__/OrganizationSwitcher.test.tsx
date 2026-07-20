import React from 'react';
import { fireEvent, render, screen } from '@testing-library/react';
import OrganizationSwitcher from '../OrganizationSwitcher';
import { useOrganizationStore } from '../../store/organizationStore';

jest.mock('../../store/organizationStore');

const mockedStore = useOrganizationStore as unknown as jest.Mock;

describe('OrganizationSwitcher', () => {
  it('requires an explicit choice when a user belongs to multiple organizations', () => {
    const selectOrganization = jest.fn();
    mockedStore.mockReturnValue({
      memberships: [
        { organizationId: 'org-a', role: 'owner', organization: { name: 'Cooperative A' } },
        { organizationId: 'org-b', role: 'auditor', organization: { name: 'Programme B' } },
      ],
      activeOrganizationId: null,
      loading: false,
      error: null,
      loadOrganizations: jest.fn(),
      selectOrganization,
    });

    render(<OrganizationSwitcher />);
    const selector = screen.getByRole('combobox', { name: 'Active organization' });
    expect((selector as HTMLSelectElement).value).toBe('');
    fireEvent.change(selector, { target: { value: 'org-b' } });
    expect(selectOrganization).toHaveBeenCalledWith('org-b');
  });
});
