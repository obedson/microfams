import { Coordinate } from './mappingService.js';

export type SatelliteQuery = { location: Coordinate; capturedAt?: string };
export type SatelliteResult = {
  provider: string;
  sceneId: string;
  capturedAt: string;
  location: Coordinate;
  cloudCoverPercent: number;
  vegetationIndex: number;
  confidence: number;
  asset: { kind: 'metadata_only'; available: false };
  provenance: { source: string; generatedAt: string };
};

export interface SatelliteAdapter { inspect(query: SatelliteQuery): Promise<SatelliteResult>; }

export class DeterministicSatelliteAdapter implements SatelliteAdapter {
  async inspect(query: SatelliteQuery): Promise<SatelliteResult> {
    const capturedAt = query.capturedAt ?? new Date().toISOString();
    return {
      provider: 'deterministic-test',
      sceneId: `scene-${query.location.latitude.toFixed(4)}-${query.location.longitude.toFixed(4)}`,
      capturedAt,
      location: query.location,
      cloudCoverPercent: 0,
      vegetationIndex: 0.5,
      confidence: 0.5,
      asset: { kind: 'metadata_only', available: false },
      provenance: { source: 'deterministic-satellite-contract', generatedAt: capturedAt },
    };
  }
}

export class SatelliteService {
  constructor(private readonly adapter: SatelliteAdapter = new DeterministicSatelliteAdapter()) {}
  async inspect(query: SatelliteQuery) {
    const { latitude, longitude } = query.location;
    if (!Number.isFinite(latitude) || latitude < -90 || latitude > 90 ||
        !Number.isFinite(longitude) || longitude < -180 || longitude > 180) {
      throw new Error('SATELLITE_LOCATION_INVALID');
    }
    return this.adapter.inspect(query);
  }
}
export const satelliteService = new SatelliteService();
