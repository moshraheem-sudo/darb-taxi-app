import { IDbStore, RideDto } from '../db/types';
import { RealtimeGateway } from '../realtime/socketServer';
import { IFcmService } from './fcmService';

export class DispatchService {
  constructor(
    private readonly store: IDbStore,
    private readonly realtime: RealtimeGateway,
    private readonly fcm: IFcmService,
  ) {}

  /**
   * Finds nearest eligible captains via PostGIS (expanding radius 3km -> 6km -> 10km)
   * and dispatches the ride via both Socket.IO and FCM push notifications.
   */
  async dispatchRideToNearbyCaptains(ride: RideDto): Promise<number> {
    const radii = [3000, 6000, 10000];
    let totalSent = 0;

    for (const radiusMeters of radii) {
      const matches = await this.store.findNearbyEligibleCaptains({
        rideId: ride.ride_id,
        originLat: ride.origin_lat,
        originLng: ride.origin_lng,
        tier: ride.selected_tier,
        radiusMeters,
        limit: 5,
      });

      if (matches.length === 0) continue;

      await this.store.recordDispatchAttempts(ride.ride_id, matches);

      for (const m of matches) {
        this.realtime.emitNewRideToCaptain(m.captainId, ride);
        if (m.fcmTokens.length > 0) {
          await this.fcm.sendPush({
            tokens: m.fcmTokens,
            title: `طلب رحلة جديد (${ride.final_fare_iqd} د.ع)`,
            body: `${ride.origin_name} -> ${ride.destination_name}`,
            data: {
              type: 'ride_request',
              ride_id: ride.ride_id,
              fare_iqd: String(ride.final_fare_iqd),
            },
            highPriority: true,
          });
        }
      }

      totalSent += matches.length;
      if (totalSent > 0) break;
    }

    return totalSent;
  }
}
