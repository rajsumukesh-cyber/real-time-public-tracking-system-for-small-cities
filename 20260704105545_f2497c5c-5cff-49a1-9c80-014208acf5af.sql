
-- Extend notification_type with driver-dispatch value
ALTER TYPE public.notification_type ADD VALUE IF NOT EXISTS 'sos_dispatch';
ALTER TYPE public.sos_status ADD VALUE IF NOT EXISTS 'escalated';

-- Preferences
CREATE TABLE IF NOT EXISTS public.notification_preferences (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  sos boolean NOT NULL DEFAULT true,
  delay boolean NOT NULL DEFAULT true,
  route_change boolean NOT NULL DEFAULT true,
  arrival boolean NOT NULL DEFAULT true,
  push_enabled boolean NOT NULL DEFAULT false,
  favorites_only boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE ON public.notification_preferences TO authenticated;
GRANT ALL ON public.notification_preferences TO service_role;
ALTER TABLE public.notification_preferences ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users read own prefs" ON public.notification_preferences
  FOR SELECT TO authenticated USING (user_id = auth.uid());
CREATE POLICY "Users upsert own prefs" ON public.notification_preferences
  FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid());
CREATE POLICY "Users update own prefs" ON public.notification_preferences
  FOR UPDATE TO authenticated USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());
CREATE TRIGGER notif_prefs_updated BEFORE UPDATE ON public.notification_preferences
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

-- Extend new-user trigger to seed prefs
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _role public.app_role;
BEGIN
  INSERT INTO public.profiles (id, full_name, email, phone)
  VALUES (NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'full_name', NEW.raw_user_meta_data->>'name', split_part(NEW.email, '@', 1)),
    NEW.email, NEW.raw_user_meta_data->>'phone')
  ON CONFLICT (id) DO NOTHING;

  _role := COALESCE((NEW.raw_user_meta_data->>'role')::public.app_role, 'passenger'::public.app_role);
  IF _role = 'admin' THEN _role := 'passenger'; END IF;
  INSERT INTO public.user_roles (user_id, role) VALUES (NEW.id, _role) ON CONFLICT DO NOTHING;

  INSERT INTO public.notification_preferences (user_id) VALUES (NEW.id) ON CONFLICT DO NOTHING;
  RETURN NEW;
END $$;

-- Backfill prefs for existing users
INSERT INTO public.notification_preferences (user_id)
SELECT id FROM auth.users ON CONFLICT DO NOTHING;

-- Audit log
CREATE TABLE IF NOT EXISTS public.sos_audit_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sos_id uuid NOT NULL REFERENCES public.sos_events(id) ON DELETE CASCADE,
  action text NOT NULL,
  actor_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  from_status public.sos_status,
  to_status public.sos_status,
  note text,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.sos_audit_log TO authenticated;
GRANT ALL ON public.sos_audit_log TO service_role;
ALTER TABLE public.sos_audit_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Admins read audit" ON public.sos_audit_log
  FOR SELECT TO authenticated USING (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Drivers read own sos audit" ON public.sos_audit_log
  FOR SELECT TO authenticated USING (
    EXISTS (SELECT 1 FROM public.sos_events s WHERE s.id = sos_audit_log.sos_id AND s.driver_id = auth.uid())
  );

-- Trigger: capture SOS lifecycle
CREATE OR REPLACE FUNCTION public.log_sos_action()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO public.sos_audit_log (sos_id, action, actor_id, to_status, note)
    VALUES (NEW.id, 'created', NEW.driver_id, NEW.status, NEW.message);
    RETURN NEW;
  ELSIF TG_OP = 'UPDATE' AND NEW.status IS DISTINCT FROM OLD.status THEN
    INSERT INTO public.sos_audit_log (sos_id, action, actor_id, from_status, to_status)
    VALUES (NEW.id, NEW.status::text, COALESCE(NEW.acknowledged_by, auth.uid()), OLD.status, NEW.status);
  END IF;
  RETURN NEW;
END $$;
REVOKE EXECUTE ON FUNCTION public.log_sos_action() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS sos_audit_ins ON public.sos_events;
DROP TRIGGER IF EXISTS sos_audit_upd ON public.sos_events;
CREATE TRIGGER sos_audit_ins AFTER INSERT ON public.sos_events
  FOR EACH ROW EXECUTE FUNCTION public.log_sos_action();
CREATE TRIGGER sos_audit_upd AFTER UPDATE OF status ON public.sos_events
  FOR EACH ROW EXECUTE FUNCTION public.log_sos_action();

-- Escalations
CREATE TABLE IF NOT EXISTS public.sos_escalations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sos_id uuid NOT NULL REFERENCES public.sos_events(id) ON DELETE CASCADE,
  driver_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  vehicle_id uuid REFERENCES public.vehicles(id) ON DELETE SET NULL,
  distance_km numeric(8,3),
  notified_at timestamptz NOT NULL DEFAULT now(),
  responded_at timestamptz,
  response text,
  UNIQUE (sos_id, driver_id)
);
GRANT SELECT, INSERT, UPDATE ON public.sos_escalations TO authenticated;
GRANT ALL ON public.sos_escalations TO service_role;
ALTER TABLE public.sos_escalations ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Admins manage escalations" ON public.sos_escalations
  FOR ALL TO authenticated
  USING (public.has_role(auth.uid(), 'admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Driver reads own dispatches" ON public.sos_escalations
  FOR SELECT TO authenticated USING (driver_id = auth.uid());
CREATE POLICY "Driver responds to own dispatches" ON public.sos_escalations
  FOR UPDATE TO authenticated USING (driver_id = auth.uid()) WITH CHECK (driver_id = auth.uid());

-- Replace fanout: honors prefs + dispatches nearest N drivers
CREATE OR REPLACE FUNCTION public.fanout_sos_notification()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  _vnum text;
  _rnum text;
  _rec record;
BEGIN
  SELECT vehicle_number INTO _vnum FROM public.vehicles WHERE id = NEW.vehicle_id;
  SELECT route_number INTO _rnum FROM public.routes WHERE id = NEW.route_id;

  -- Admins (respecting prefs)
  INSERT INTO public.notifications (user_id, type, title, body, vehicle_id, route_id, sos_id)
  SELECT ur.user_id, 'sos',
    'Emergency: ' || COALESCE(_vnum,'vehicle'),
    COALESCE(NEW.message,'Driver triggered SOS') ||
      CASE WHEN _rnum IS NOT NULL THEN ' · Route ' || _rnum ELSE '' END,
    NEW.vehicle_id, NEW.route_id, NEW.id
  FROM public.user_roles ur
  LEFT JOIN public.notification_preferences np ON np.user_id = ur.user_id
  WHERE ur.role = 'admin' AND COALESCE(np.sos, true);

  -- Passengers who favorited this route (respecting prefs)
  IF NEW.route_id IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, type, title, body, vehicle_id, route_id, sos_id)
    SELECT fr.user_id, 'sos',
      'Alert on route ' || COALESCE(_rnum,''),
      'Vehicle ' || COALESCE(_vnum,'') || ' reported an emergency.',
      NEW.vehicle_id, NEW.route_id, NEW.id
    FROM public.favorite_routes fr
    LEFT JOIN public.notification_preferences np ON np.user_id = fr.user_id
    WHERE fr.route_id = NEW.route_id AND COALESCE(np.sos, true);
  END IF;

  -- Dispatch nearest 3 active drivers (excluding the reporting driver)
  IF NEW.lat IS NOT NULL AND NEW.lng IS NOT NULL THEN
    FOR _rec IN
      SELECT v.id AS vehicle_id, v.driver_id,
        (6371 * acos(
          LEAST(1.0, GREATEST(-1.0,
            cos(radians(NEW.lat)) * cos(radians(v.current_lat)) *
            cos(radians(v.current_lng) - radians(NEW.lng)) +
            sin(radians(NEW.lat)) * sin(radians(v.current_lat))
          ))
        )) AS dist_km
      FROM public.vehicles v
      WHERE v.driver_id IS NOT NULL
        AND v.driver_id <> NEW.driver_id
        AND v.current_lat IS NOT NULL AND v.current_lng IS NOT NULL
        AND v.status IN ('online','on_trip')
      ORDER BY dist_km ASC
      LIMIT 3
    LOOP
      INSERT INTO public.sos_escalations (sos_id, driver_id, vehicle_id, distance_km)
      VALUES (NEW.id, _rec.driver_id, _rec.vehicle_id, _rec.dist_km)
      ON CONFLICT DO NOTHING;

      INSERT INTO public.notifications (user_id, type, title, body, vehicle_id, route_id, sos_id)
      SELECT _rec.driver_id, 'sos_dispatch',
        'Nearby SOS · ' || round(_rec.dist_km::numeric, 1) || ' km',
        'Vehicle ' || COALESCE(_vnum,'') || ' needs assistance.' ,
        NEW.vehicle_id, NEW.route_id, NEW.id
      FROM public.notification_preferences np
      WHERE np.user_id = _rec.driver_id AND COALESCE(np.sos, true)
      UNION ALL
      SELECT _rec.driver_id, 'sos_dispatch',
        'Nearby SOS · ' || round(_rec.dist_km::numeric, 1) || ' km',
        'Vehicle ' || COALESCE(_vnum,'') || ' needs assistance.' ,
        NEW.vehicle_id, NEW.route_id, NEW.id
      WHERE NOT EXISTS (SELECT 1 FROM public.notification_preferences WHERE user_id = _rec.driver_id);
    END LOOP;
  END IF;

  RETURN NEW;
END $$;
REVOKE EXECUTE ON FUNCTION public.fanout_sos_notification() FROM PUBLIC, anon, authenticated;

-- Escalate stale SOS: helper callable by admins/drivers to bump status
CREATE OR REPLACE FUNCTION public.escalate_stale_sos()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n integer;
BEGIN
  WITH bumped AS (
    UPDATE public.sos_events
    SET status = 'escalated'
    WHERE status = 'active'
      AND created_at < now() - interval '60 seconds'
      AND NOT EXISTS (
        SELECT 1 FROM public.sos_escalations e
        WHERE e.sos_id = sos_events.id AND e.responded_at IS NOT NULL
      )
    RETURNING 1
  )
  SELECT count(*) INTO n FROM bumped;
  RETURN n;
END $$;
REVOKE EXECUTE ON FUNCTION public.escalate_stale_sos() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.escalate_stale_sos() TO authenticated;

-- Realtime for new tables
ALTER PUBLICATION supabase_realtime ADD TABLE public.sos_escalations;
ALTER PUBLICATION supabase_realtime ADD TABLE public.sos_audit_log;
