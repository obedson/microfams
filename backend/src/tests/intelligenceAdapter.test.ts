import { DeterministicMappingAdapter, MappingService } from '../domains/intelligence/mappingService.js';
import { DeterministicSatelliteAdapter, SatelliteService } from '../domains/intelligence/satelliteService.js';

test('mapping returns provider-neutral deterministic evidence', async () => {
  await expect(new MappingService(new DeterministicMappingAdapter()).resolve({ latitude: 6.52, longitude: 3.37 }, '2026-08-26T00:00:00.000Z'))
    .resolves.toMatchObject({ provider: 'deterministic-test', displayName: 'Coordinate 6.5200, 3.3700', provenance: { source: 'deterministic-map-contract' } });
});
test('mapping rejects invalid coordinates', async () => {
  await expect(new MappingService().resolve({ latitude: 91, longitude: 0 })).rejects.toThrow('MAPPING_LOCATION_INVALID');
});
test('satellite returns metadata-only deterministic evidence', async () => {
  await expect(new SatelliteService(new DeterministicSatelliteAdapter()).inspect({ location: { latitude: 9.08, longitude: 7.49 }, capturedAt: '2026-08-26T00:00:00.000Z' }))
    .resolves.toMatchObject({ provider: 'deterministic-test', asset: { available: false }, provenance: { source: 'deterministic-satellite-contract' } });
});
test('satellite rejects invalid coordinates', async () => {
  await expect(new SatelliteService().inspect({ location: { latitude: 0, longitude: 181 } })).rejects.toThrow('SATELLITE_LOCATION_INVALID');
});
