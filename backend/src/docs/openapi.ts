export const openApiSpec = {
  openapi: '3.0.3',
  info: {
    title: 'Darb Taxi Backend API',
    version: '1.0.0',
    description:
      'REST API & Socket.IO specification for Darb Taxi (Passenger, Captain, Admin).\n\n' +
      '## Socket.IO Events\n' +
      '- `captain:location` (Client -> Server): `{ lat, lng, heading, ride_id? }`\n' +
      '- `driver:location_update` (Server -> Passenger): `{ lat, lng, heading, ride_id }`\n' +
      '- `ride:new_request` (Server -> Captain): `RideDto`\n' +
      '- `ride:claimed` (Server -> Captains): `{ ride_id }`\n' +
      '- `ride:status_changed` (Server -> Ride Room): `RideDto`\n' +
      '- `ride:sync` (Client -> Server): `{ ride_id? }`',
  },
  servers: [{ url: 'http://localhost:3000', description: 'Local Development' }],
  components: {
    securitySchemes: {
      bearerAuth: {
        type: 'http',
        scheme: 'bearer',
        bearerFormat: 'JWT',
      },
    },
  },
  paths: {
    '/health': {
      get: { summary: 'Health check', responses: { 200: { description: 'OK' } } },
    },
    '/auth/otp/request': {
      post: {
        summary: 'Request OTP code',
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object',
                required: ['phone', 'role'],
                properties: {
                  full_name: { type: 'string' },
                  phone: { type: 'string' },
                  role: { type: 'string', enum: ['passenger', 'captain', 'admin'] },
                },
              },
            },
          },
        },
        responses: { 200: { description: 'OTP issued' } },
      },
    },
    '/auth/otp/verify': {
      post: {
        summary: 'Verify OTP and issue JWT access + refresh tokens',
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object',
                required: ['phone', 'code', 'role'],
                properties: {
                  phone: { type: 'string' },
                  code: { type: 'string' },
                  role: { type: 'string', enum: ['passenger', 'captain', 'admin'] },
                },
              },
            },
          },
        },
        responses: { 200: { description: 'Authenticated' }, 401: { description: 'Invalid OTP' } },
      },
    },
    '/auth/token/refresh': {
      post: {
        summary: 'Rotate refresh token and issue new access token',
        responses: { 200: { description: 'New tokens' }, 401: { description: 'Invalid token' } },
      },
    },
    '/notifications/fcm-token': {
      post: {
        summary: 'Register device FCM token',
        security: [{ bearerAuth: [] }],
        responses: { 200: { description: 'Registered' } },
      },
    },
    '/captain/profile': {
      get: {
        summary: 'Get captain profile & documents',
        security: [{ bearerAuth: [] }],
        responses: { 200: { description: 'CaptainProfile' } },
      },
      post: {
        summary: 'Update captain & vehicle profile',
        security: [{ bearerAuth: [] }],
        responses: { 200: { description: 'Updated CaptainProfile' } },
      },
    },
    '/captain/documents': {
      post: {
        summary: 'Upload captain verification document (multipart/form-data)',
        security: [{ bearerAuth: [] }],
        responses: { 200: { description: 'Uploaded' } },
      },
    },
    '/captain/availability': {
      post: {
        summary: 'Toggle online availability (requires approved status)',
        security: [{ bearerAuth: [] }],
        responses: { 200: { description: 'Updated' }, 403: { description: 'Not approved' } },
      },
    },
    '/captain/location': {
      post: {
        summary: 'Update captain GPS coordinates',
        security: [{ bearerAuth: [] }],
        responses: { 204: { description: 'Updated' } },
      },
    },
    '/captain/rides': {
      get: {
        summary: 'List completed captain rides',
        security: [{ bearerAuth: [] }],
        responses: { 200: { description: 'Ride history' } },
      },
    },
    '/admin/captains/pending': {
      get: {
        summary: 'List captains pending approval (Admin only)',
        security: [{ bearerAuth: [] }],
        responses: { 200: { description: 'Pending captains' }, 403: { description: 'Forbidden' } },
      },
    },
    '/admin/captains/{id}/approval': {
      patch: {
        summary: 'Approve or reject a captain (Admin only)',
        security: [{ bearerAuth: [] }],
        parameters: [{ name: 'id', in: 'path', required: true, schema: { type: 'string' } }],
        responses: { 200: { description: 'Updated' } },
      },
    },
    '/rides': {
      post: {
        summary: 'Create ride request (supports Idempotency-Key) and dispatch via PostGIS + Socket.IO + FCM',
        security: [{ bearerAuth: [] }],
        responses: { 201: { description: 'Created & dispatched' }, 200: { description: 'Deduplicated' } },
      },
    },
    '/rides/active': {
      get: {
        summary: 'Get active ride for current user (reconnection sync)',
        security: [{ bearerAuth: [] }],
        responses: { 200: { description: 'Active ride or null' } },
      },
    },
    '/rides/{rideId}/accept': {
      post: {
        summary: 'Atomically accept a searching ride (409 Conflict if already claimed)',
        security: [{ bearerAuth: [] }],
        parameters: [{ name: 'rideId', in: 'path', required: true, schema: { type: 'string' } }],
        responses: { 200: { description: 'Accepted' }, 409: { description: 'Already claimed' } },
      },
    },
    '/rides/{rideId}/reject': {
      post: {
        summary: 'Reject a dispatched ride request',
        security: [{ bearerAuth: [] }],
        parameters: [{ name: 'rideId', in: 'path', required: true, schema: { type: 'string' } }],
        responses: { 204: { description: 'Rejected' } },
      },
    },
    '/rides/{rideId}/status': {
      patch: {
        summary: 'Transition ride status (arrived, in_progress, completed, cancelled)',
        security: [{ bearerAuth: [] }],
        parameters: [{ name: 'rideId', in: 'path', required: true, schema: { type: 'string' } }],
        responses: { 200: { description: 'Updated' }, 400: { description: 'Invalid transition' } },
      },
    },
    '/rides/{rideId}/rate': {
      post: {
        summary: 'Rate completed ride',
        security: [{ bearerAuth: [] }],
        parameters: [{ name: 'rideId', in: 'path', required: true, schema: { type: 'string' } }],
        responses: { 201: { description: 'Rated' } },
      },
    },
    '/passenger/rides': {
      get: {
        summary: 'List passenger ride history',
        security: [{ bearerAuth: [] }],
        responses: { 200: { description: 'Ride history' } },
      },
    },
  },
};
