-- Safe local development seed data (no real user credentials or secrets)
INSERT INTO users (id, full_name, phone)
VALUES
  ('00000000-0000-0000-0000-000000000001', 'مشرف النظام التجريبي', '+9647700000001'),
  ('00000000-0000-0000-0000-000000000002', 'زبون تجريبي', '+9647700000002'),
  ('00000000-0000-0000-0000-000000000003', 'كابتن محمد التجريبي', '+9647700000003')
ON CONFLICT (phone) DO NOTHING;

INSERT INTO user_roles (user_id, role)
VALUES
  ('00000000-0000-0000-0000-000000000001', 'admin'),
  ('00000000-0000-0000-0000-000000000002', 'passenger'),
  ('00000000-0000-0000-0000-000000000003', 'captain')
ON CONFLICT DO NOTHING;

INSERT INTO captains (user_id, approval_status, is_online, current_location, location_updated_at, rating)
VALUES (
  '00000000-0000-0000-0000-000000000003',
  'approved',
  TRUE,
  ST_SetSRID(ST_MakePoint(45.8180, 32.5128), 4326)::geography,
  NOW(),
  4.95
)
ON CONFLICT (user_id) DO NOTHING;

INSERT INTO vehicles (captain_id, model, color, plate_number, tier, year, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000003',
  'Kia Optima',
  'أبيض',
  'واسط 12345 أ',
  'saver',
  2021,
  TRUE
)
ON CONFLICT (plate_number) DO NOTHING;

INSERT INTO promo_codes (code, discount_iqd, max_uses, is_active)
VALUES ('DARB500', 500, 1000, TRUE)
ON CONFLICT (code) DO NOTHING;
