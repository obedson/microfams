import { performance } from 'perf_hooks';
import { WeatherService } from '../domains/intelligence/weatherService.js';
import { AssistantService } from '../domains/intelligence/assistantService.js';

describe('V1 deterministic performance smoke', () => {
  it('completes 500 provider-neutral service operations within the CI budget', async () => {
    const weather = new WeatherService();
    const assistant = new AssistantService();
    const started = performance.now();
    for (let index = 0; index < 250; index += 1) {
      await weather.forecast({ latitude: 9.08, longitude: 7.49, at: '2026-08-26T00:00:00.000Z' });
      await assistant.answer({ question: 'status', citations: ['farm_records:1'] });
    }
    expect(performance.now() - started).toBeLessThan(1000);
  });
});
