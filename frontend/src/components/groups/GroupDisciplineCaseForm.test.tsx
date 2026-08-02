import React from 'react';
import { fireEvent, render, screen } from '@testing-library/react';
import '@testing-library/jest-dom';
import GroupDisciplineCaseForm from './GroupDisciplineCaseForm';

describe('GroupDisciplineCaseForm', () => {
  it('collects notice, evidence, voting schedule, and appeal terms without a direct action', () => {
    const onSubmit = jest.fn();
    render(<GroupDisciplineCaseForm memberName="Ada Farmer" onCancel={jest.fn()} onSubmit={onSubmit} />);
    expect(screen.getByText(/time to respond before voting opens/i)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /suspend member/i })).not.toBeInTheDocument();
    fireEvent.change(screen.getByLabelText(/Notice shown/i), {
      target: { value: 'The member may respond to this documented allegation before voting opens.' },
    });
    fireEvent.change(screen.getByLabelText(/Private evidence/i), {
      target: { value: 'evidence://case/one\nevidence://case/two' },
    });
    fireEvent.submit(screen.getByRole('form', { name: /Discipline review/i }));
    expect(onSubmit).toHaveBeenCalledWith(expect.objectContaining({
      proposedAction: 'suspend',
      privateEvidenceRefs: ['evidence://case/one', 'evidence://case/two'],
      appealWindowDays: 30,
    }));
  });
});
