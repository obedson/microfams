import '@testing-library/jest-dom';
import React from 'react';
import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import SuspendedAccountRecovery from './SuspendedAccountRecovery';
import { trustAPI } from '../services/trustAPI';
jest.mock('../services/trustAPI',()=>({trustAPI:{requestSuspendedRecovery:jest.fn(),inspectSuspendedRecovery:jest.fn(),submitSuspendedRecoveryAppeal:jest.fn()}}));
describe('SuspendedAccountRecovery',()=>{
 it('uses the same neutral response for a recovery request',async()=>{(trustAPI.requestSuspendedRecovery as jest.Mock).mockResolvedValue({});render(<MemoryRouter><SuspendedAccountRecovery/></MemoryRouter>);fireEvent.change(screen.getByLabelText('Email'),{target:{value:'user@example.test'}});fireEvent.click(screen.getByRole('button',{name:'Send recovery link'}));expect(await screen.findByRole('status')).toHaveTextContent('If the account is eligible');});
 it('inspects a token and submits one appeal',async()=>{(trustAPI.inspectSuspendedRecovery as jest.Mock).mockResolvedValue({caseId:'c1',suspended:true,expiresAt:new Date(Date.now()+60000).toISOString(),appealStatus:null});(trustAPI.submitSuspendedRecoveryAppeal as jest.Mock).mockResolvedValue({});render(<MemoryRouter initialEntries={['/trust/recovery?token='+ 'A'.repeat(43)]}><SuspendedAccountRecovery/></MemoryRouter>);await screen.findByText(/Your account is suspended/);fireEvent.change(screen.getByLabelText('Appeal statement'),{target:{value:'Material evidence was not considered.'}});fireEvent.click(screen.getByRole('button',{name:'Submit appeal'}));await waitFor(()=>expect(trustAPI.submitSuspendedRecoveryAppeal).toHaveBeenCalled());expect(await screen.findByRole('status')).toHaveTextContent('Appeal submitted');});
});