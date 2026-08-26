export type Coordinate = { latitude: number; longitude: number };
export type MapBounds = { north: number; south: number; east: number; west: number };
export type MappingResult = {
  provider: string;
  center: Coordinate;
  bounds: MapBounds;
  displayName: string;
  confidence: number;
  provenance: { generatedAt: string; source: string };
};

export interface MappingAdapter {
  resolve(coordinate: Coordinate, at?: string): Promise<MappingResult>;
}

const validCoordinate = ({ latitude, longitude }: Coordinate) =>
  Number.isFinite(latitude) && latitude >= -90 && latitude <= 90 &&
  Number.isFinite(longitude) && longitude >= -180 && longitude <= 180;

export class DeterministicMappingAdapter implements MappingAdapter {
  async resolve(coordinate: Coordinate, at?: string): Promise<MappingResult> {
    return {
      provider: 'deterministic-test',
      center: coordinate,
      bounds: {
        north: coordinate.latitude + 0.01,
        south: coordinate.latitude - 0.01,
        east: coordinate.longitude + 0.01,
        west: coordinate.longitude - 0.01,
      },
      displayName: `Coordinate ${coordinate.latitude.toFixed(4)}, ${coordinate.longitude.toFixed(4)}`,
      confidence: 0.5,
      provenance: { generatedAt: at ?? new Date().toISOString(), source: 'deterministic-map-contract' },
    };
  }
}

export class MappingService {
  constructor(private readonly adapter: MappingAdapter = new DeterministicMappingAdapter()) {}
  async resolve(coordinate: Coordinate, at?: string) {
    if (!validCoordinate(coordinate)) throw new Error('MAPPING_LOCATION_INVALID');
    return this.adapter.resolve(coordinate, at);
  }
}
export const mappingService = new MappingService();
