export type AssistantQuery = { question: string; citations?: string[] };
export type AssistantAnswer = { answer: string; citations: string[]; requiresConfirmation: boolean; provider: string };
export class AssistantService { async answer(query: AssistantQuery): Promise<AssistantAnswer> { if (!query.question?.trim()) throw new Error('ASSISTANT_QUESTION_REQUIRED'); return { answer: 'I can provide guidance from approved Micro Fams records, but no actionable operation was requested.', citations: query.citations ?? [], requiresConfirmation: true, provider: 'deterministic-test' }; } }
export const assistantService = new AssistantService();
