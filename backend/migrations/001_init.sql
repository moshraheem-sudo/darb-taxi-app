CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS postgis;

CREATE TABLE IF NOT EXISTS schema_migrations (
  version VARCHAR(64) PRIMARY KEY,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  full_name VARCHAR(120) NOT NULL,
  phone VARCHAR(24) NOT NULL UNIQUE,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  passenger_rating NUMERIC(3,2) NOT NULL DEFAULT 5.00 CHECK (passenger_rating BETWEEN 1.00 AND 5.00),
  passenger_total_trips INT NOT NULL DEFAULT 0 CHECK (passenger_total_trips >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS user_roles (
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role VARCHAR(20) NOT NULL CHECK (role IN ('passenger', 'captain', 'admin')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, role)
);

CREATE TABLE IF NOT EXISTS otp_verifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  phone VARCHAR(24) NOT NULL,
  role VARCHAR(20) NOT NULL CHECK (role IN ('passenger', 'captain', 'admin')),
  code_hash TEXT NOT NULL,
  attempts INT NOT NULL DEFAULT 0,
  expires_at TIMESTAMPTZ NOT NULL,
  consumed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_otp_phone_active
  ON otp_verifications (phone, created_at DESC)
  WHERE consumed_at IS NULL;

CREATE TABLE IF NOT EXISTS refresh_tokens (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL UNIQUE,
  expires_at TIMESTAMPTZ NOT NULL,
  revoked_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS device_tokens (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  fcm_token TEXT NOT NULL UNIQUE,
  platform VARCHAR(16) NOT NULL DEFAULT 'android',
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS captains (
  user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  approval_status VARCHAR(20) NOT NULL DEFAULT 'unsubmitted'
    CHECK (approval_status IN ('unsubmitted', 'pending', 'approved', 'rejected')),
  is_online BOOLEAN NOT NULL DEFAULT FALSE,
  current_location GEOGRAPHY(Point, 4326),
  heading DOUBLE PRECISION NOT NULL DEFAULT 0,
  location_updated_at TIMESTAMPTZ,
  rating NUMERIC(3,2) NOT NULL DEFAULT 4.90 CHECK (rating BETWEEN 1.00 AND 5.00),
  total_trips INT NOT NULL DEFAULT 0 CHECK (total_trips >= 0),
  total_earnings_iqd BIGINT NOT NULL DEFAULT 0 CHECK (total_earnings_iqd >= 0),
  approved_at TIMESTAMPTZ,
  approved_by UUID REFERENCES users(id)
);

CREATE INDEX IF NOT EXISTS idx_captains_online_geo
  ON captains USING GIST (current_location)
  WHERE is_online = TRUE AND approval_status = 'approved';

CREATE TABLE IF NOT EXISTS vehicles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  captain_id UUID NOT NULL REFERENCES captains(user_id) ON DELETE CASCADE,
  model VARCHAR(100) NOT NULL,
  color VARCHAR(50) NOT NULL DEFAULT '',
  plate_number VARCHAR(32) NOT NULL UNIQUE,
  tier VARCHAR(20) NOT NULL DEFAULT 'saver' CHECK (tier IN ('saver', 'plus', 'box')),
  year INT CHECK (year BETWEEN 1990 AND 2035),
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_vehicles_one_active_per_captain
  ON vehicles (captain_id)
  WHERE is_active = TRUE;

CREATE TABLE IF NOT EXISTS captain_documents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  captain_id UUID NOT NULL REFERENCES captains(user_id) ON DELETE CASCADE,
  doc_type VARCHAR(32) NOT NULL CHECK (doc_type IN ('nationalId', 'driverLicense', 'vehicleReg', 'carPhoto')),
  storage_key TEXT NOT NULL,
  mime_type VARCHAR(64) NOT NULL,
  review_status VARCHAR(20) NOT NULL DEFAULT 'pending'
    CHECK (review_status IN ('pending', 'approved', 'rejected')),
  rejection_reason TEXT,
  reviewed_by UUID REFERENCES users(id),
  reviewed_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (captain_id, doc_type)
);

CREATE TABLE IF NOT EXISTS promo_codes (
  code VARCHAR(32) PRIMARY KEY,
  discount_iqd INT NOT NULL CHECK (discount_iqd > 0),
  max_uses INT,
  used_count INT NOT NULL DEFAULT 0,
  expires_at TIMESTAMPTZ,
  is_active BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS rides (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  passenger_id UUID NOT NULL REFERENCES users(id),
  captain_id UUID REFERENCES captains(user_id),
  vehicle_id UUID REFERENCES vehicles(id),
  status VARCHAR(20) NOT NULL DEFAULT 'searching'
    CHECK (status IN ('searching', 'accepted', 'arrived', 'in_progress', 'completed', 'cancelled')),
  version INT NOT NULL DEFAULT 1,
  idempotency_key VARCHAR(64) UNIQUE,

  origin_point GEOGRAPHY(Point, 4326) NOT NULL,
  origin_name TEXT NOT NULL,
  destination_point GEOGRAPHY(Point, 4326) NOT NULL,
  destination_name TEXT NOT NULL,
  second_destination_point GEOGRAPHY(Point, 4326),
  second_destination_name TEXT,

  stop_wait_minutes INT NOT NULL DEFAULT 0 CHECK (stop_wait_minutes >= 0),
  round_trip BOOLEAN NOT NULL DEFAULT FALSE,
  service_category VARCHAR(20) NOT NULL DEFAULT 'taxi' CHECK (service_category IN ('taxi', 'box')),
  selected_tier VARCHAR(20) NOT NULL DEFAULT 'saver' CHECK (selected_tier IN ('saver', 'plus', 'box')),

  distance_km NUMERIC(7,2) NOT NULL DEFAULT 0,
  duration_min NUMERIC(6,1) NOT NULL DEFAULT 0,
  fare_iqd INT NOT NULL CHECK (fare_iqd >= 0),
  promo_code VARCHAR(32) REFERENCES promo_codes(code),
  discount_iqd INT NOT NULL DEFAULT 0 CHECK (discount_iqd >= 0),
  final_fare_iqd INT NOT NULL CHECK (final_fare_iqd >= 0),

  cancelled_by VARCHAR(20) CHECK (cancelled_by IN ('passenger', 'captain', 'admin', 'system')),
  cancel_reason TEXT,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  accepted_at TIMESTAMPTZ,
  arrived_at TIMESTAMPTZ,
  started_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  cancelled_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_rides_passenger_created
  ON rides (passenger_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_rides_captain_created
  ON rides (captain_id, created_at DESC)
  WHERE captain_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_rides_searching
  ON rides (created_at DESC)
  WHERE status = 'searching';
CREATE UNIQUE INDEX IF NOT EXISTS idx_rides_one_active_captain
  ON rides (captain_id)
  WHERE captain_id IS NOT NULL AND status IN ('accepted', 'arrived', 'in_progress');

CREATE TABLE IF NOT EXISTS ride_dispatch_attempts (
  ride_id UUID NOT NULL REFERENCES rides(id) ON DELETE CASCADE,
  captain_id UUID NOT NULL REFERENCES captains(user_id) ON DELETE CASCADE,
  distance_meters INT NOT NULL,
  response VARCHAR(20) NOT NULL DEFAULT 'sent'
    CHECK (response IN ('sent', 'accepted', 'rejected', 'expired', 'claimed_by_other')),
  sent_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  responded_at TIMESTAMPTZ,
  PRIMARY KEY (ride_id, captain_id)
);

CREATE TABLE IF NOT EXISTS ride_events (
  id BIGSERIAL PRIMARY KEY,
  ride_id UUID NOT NULL REFERENCES rides(id) ON DELETE CASCADE,
  from_status VARCHAR(20),
  to_status VARCHAR(20) NOT NULL,
  actor_id UUID REFERENCES users(id),
  actor_role VARCHAR(20),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS ride_payments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ride_id UUID NOT NULL UNIQUE REFERENCES rides(id) ON DELETE CASCADE,
  gross_fare_iqd INT NOT NULL,
  platform_commission_iqd INT NOT NULL DEFAULT 0,
  captain_net_iqd INT NOT NULL,
  payment_method VARCHAR(20) NOT NULL DEFAULT 'cash',
  settled_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS ride_ratings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ride_id UUID NOT NULL REFERENCES rides(id) ON DELETE CASCADE,
  rater_id UUID NOT NULL REFERENCES users(id),
  ratee_id UUID NOT NULL REFERENCES users(id),
  rater_role VARCHAR(20) NOT NULL CHECK (rater_role IN ('passenger', 'captain')),
  stars SMALLINT NOT NULL CHECK (stars BETWEEN 1 AND 5),
  comment TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (ride_id, rater_id)
);
