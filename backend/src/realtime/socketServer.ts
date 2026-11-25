import http from 'node:http';
import { Server as SocketIOServer, Socket } from 'socket.io';
import { z } from 'zod';
import { IDbStore, RideDto } from '../db/types';
import { AuthService } from '../services/authService';
import { logger } from '../config/logger';

const locationSchema = z.object({
  lat: z.number().min(-90).max(90),
  lng: z.number().min(-180).max(180),
  heading: z.number().optional().default(0),
  ride_id: z.string().optional(),
});

export class RealtimeGateway {
  public readonly io: SocketIOServer;

  constructor(
    httpServer: http.Server,
    corsOrigin: string,
    private readonly authService: AuthService,
    private readonly store: IDbStore,
  ) {
    this.io = new SocketIOServer(httpServer, {
      cors: { origin: corsOrigin === '*' ? true : corsOrigin.split(',') },
    });

    this.io.use((socket, next) => {
      const token = socket.handshake.auth?.token;
      if (typeof token !== 'string' || !token.trim()) {
        return next(new Error('Unauthorized: missing token'));
      }
      try {
        const claims = this.authService.verifyAccessToken(token.trim());
        socket.data.auth = claims;
        return next();
      } catch {
        return next(new Error('Unauthorized: invalid token'));
      }
    });

    this.io.on('connection', (socket) => this.handleConnection(socket));
  }

  private async handleConnection(socket: Socket) {
    const auth = socket.data.auth as { sub: string; role: string };
    socket.join(`user:${auth.sub}`);
    if (auth.role === 'captain') {
      socket.join('captains:online');
    }

    const activeRide = await this.store
      .getActiveRideForUser(auth.sub, auth.role as 'passenger' | 'captain')
      .catch(() => null);
    if (activeRide) {
      socket.join(`ride:${activeRide.ride_id}`);
    }

    socket.on('captain:location', async (raw) => {
      if (auth.role !== 'captain') return;
      const parsed = locationSchema.safeParse(raw);
      if (!parsed.success) return;
      await this.store
        .updateCaptainLocation({
          captainId: auth.sub,
          lat: parsed.data.lat,
          lng: parsed.data.lng,
          heading: parsed.data.heading,
        })
        .catch((err) => logger.warn({ err }, 'Failed captain:location update'));

      if (parsed.data.ride_id) {
        this.io.to(`ride:${parsed.data.ride_id}`).emit('driver:location_update', {
          lat: parsed.data.lat,
          lng: parsed.data.lng,
          heading: parsed.data.heading,
          ride_id: parsed.data.ride_id,
        });
      }
    });

    socket.on('ride:sync', async (raw) => {
      const rideId =
        raw && typeof raw === 'object' && typeof raw.ride_id === 'string'
          ? raw.ride_id
          : undefined;
      const ride = rideId
        ? await this.store.getRideById(rideId)
        : await this.store.getActiveRideForUser(
            auth.sub,
            auth.role as 'passenger' | 'captain',
          );
      if (
        ride &&
        (ride.passenger_id === auth.sub || ride.captain_id === auth.sub)
      ) {
        socket.join(`ride:${ride.ride_id}`);
        socket.emit('ride:status_changed', ride);
      }
    });
  }

  emitNewRideToCaptain(captainId: string, ride: RideDto) {
    this.io.to(`user:${captainId}`).emit('ride:new_request', ride);
  }

  emitRideClaimed(rideId: string) {
    this.io.to('captains:online').emit('ride:claimed', { ride_id: rideId });
  }

  emitRideStatusChanged(ride: RideDto) {
    this.io.in(`user:${ride.passenger_id}`).socketsJoin(`ride:${ride.ride_id}`);
    if (ride.captain_id) {
      this.io.in(`user:${ride.captain_id}`).socketsJoin(`ride:${ride.ride_id}`);
    }
    this.io.to(`ride:${ride.ride_id}`).emit('ride:status_changed', ride);
    this.io.to(`user:${ride.passenger_id}`).emit('ride:status_changed', ride);
    if (ride.captain_id) {
      this.io.to(`user:${ride.captain_id}`).emit('ride:status_changed', ride);
    }
  }
}
