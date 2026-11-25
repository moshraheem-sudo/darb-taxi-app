export type UserRole = 'passenger' | 'captain' | 'admin';

export type CaptainApprovalStatus =
  | 'unsubmitted'
  | 'pending'
  | 'approved'
  | 'rejected';

export type RideDispatchStatus =
  | 'searching'
  | 'accepted'
  | 'arrived'
  | 'in_progress'
  | 'completed'
  | 'cancelled';

export type DocType = 'nationalId' | 'driverLicense' | 'vehicleReg' | 'carPhoto';

export class RideStateMachine {
  private static readonly allowed: Record<RideDispatchStatus, Set<RideDispatchStatus>> = {
    searching: new Set(['accepted', 'cancelled']),
    accepted: new Set(['arrived', 'cancelled']),
    arrived: new Set(['in_progress', 'cancelled']),
    in_progress: new Set(['completed', 'cancelled']),
    completed: new Set(),
    cancelled: new Set(),
  };

  static canTransition(from: RideDispatchStatus, to: RideDispatchStatus): boolean {
    return this.allowed[from]?.has(to) ?? false;
  }

  static isTerminal(status: RideDispatchStatus): boolean {
    return status === 'completed' || status === 'cancelled';
  }
}

export function haversineKm(
  lat1: number,
  lng1: number,
  lat2: number,
  lng2: number,
): number {
  const toRad = (deg: number) => (deg * Math.PI) / 180;
  const R = 6371;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

/**
 * Server-authoritative fare calculation matching Darb tiers (IQD).
 */
export function calculateServerFareIqd(params: {
  distanceKm: number;
  selectedTier: 'saver' | 'plus' | 'box';
  stopWaitMinutes: number;
  roundTrip: boolean;
  discountIqd?: number;
}): { fareIqd: number; discountIqd: number; finalFareIqd: number } {
  const base = params.selectedTier === 'plus' ? 1500 : params.selectedTier === 'box' ? 2000 : 1000;
  const perKm = params.selectedTier === 'plus' ? 450 : 350;
  const distanceCost = Math.max(0, params.distanceKm) * perKm;
  const waitCost = Math.max(0, params.stopWaitMinutes) * 100;
  const multiplier = params.roundTrip ? 1.85 : 1;
  const rawFare = Math.round((base + distanceCost + waitCost) * multiplier / 250) * 250;
  const fareIqd = Math.max(base, rawFare);
  const discountIqd = Math.min(fareIqd, Math.max(0, params.discountIqd ?? 0));
  return {
    fareIqd,
    discountIqd,
    finalFareIqd: Math.max(0, fareIqd - discountIqd),
  };
}
