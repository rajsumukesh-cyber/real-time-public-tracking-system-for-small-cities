
-- ENUMS
DO $$ BEGIN
  CREATE TYPE public.sos_severity AS ENUM ('low','medium','high','critical');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE public.sos_status AS ENUM ('active','acknowledged','resolved','cancelled');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE public.notification_type AS ENUM ('sos','arrival','delay','route_change','info');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- SOS EVENTS
CREATE TABLE IF NOT EXISTS public.sos_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  driver_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  vehicle_id uuid REFERENCES public.vehicles(id) ON DELETE SET NULL,
  trip_id uuid REFERENCES public.trips(id) ON DELETE SET NULL,
  route_id uuid REFERENCES public.routes(id) ON DELETE SET NULL,
  lat numeric(10,7),
  lng numeric(10,7),
  message text,
  severity public.sos_severity NOT NULL DEFAULT 'high',
  status public.sos_status NOT NULL DEFAULT 'active',
  acknowledged_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  acknowledged_at timestamptz,
  resolved_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE ON public.sos_events TO authenticated;
GRANT ALL ON public.sos_events TO service_role;
ALTER TABLE public.sos_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Drivers create own sos" ON public.sos_events
  FOR INSERT TO authenticated WITH CHECK (driver_id = auth.uid());
CREATE POLICY "Drivers view own sos" ON public.sos_events
  FOR SELECT TO authenticated USING (driver_id = auth.uid());
CREATE POLICY "Admins manage sos" ON public.sos_events
  FOR ALL TO authenticated
  USING (public.has_role(auth.uid(), 'admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Passengers see active sos" ON public.sos_events
  FOR SELECT TO authenticated USING (status IN ('active','acknowledged'));

CREATE TRIGGER sos_events_updated BEFORE UPDATE ON public.sos_events
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

-- NOTIFICATIONS
CREATE TABLE IF NOT EXISTS public.notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  type public.notification_type NOT NULL DEFAULT 'info',
  title text NOT NULL,
  body text,
  vehicle_id uuid REFERENCES public.vehicles(id) ON DELETE CASCADE,
  route_id uuid REFERENCES public.routes(id) ON DELETE CASCADE,
  sos_id uuid REFERENCES public.sos_events(id) ON DELETE CASCADE,
  read boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.notifications TO authenticated;
GRANT ALL ON public.notifications TO service_role;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users read own notifications" ON public.notifications
  FOR SELECT TO authenticated USING (user_id = auth.uid());
CREATE POLICY "Users update own notifications" ON public.notifications
  FOR UPDATE TO authenticated USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());
CREATE POLICY "Users delete own notifications" ON public.notifications
  FOR DELETE TO authenticated USING (user_id = auth.uid());
CREATE POLICY "Admins insert notifications" ON public.notifications
  FOR INSERT TO authenticated WITH CHECK (public.has_role(auth.uid(), 'admin'));

CREATE INDEX IF NOT EXISTS notifications_user_created_idx
  ON public.notifications (user_id, created_at DESC);

-- FANOUT: on SOS insert, notify admins + passengers who favorited the route
CREATE OR REPLACE FUNCTION public.fanout_sos_notification()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  _vnum text;
  _rnum text;
BEGIN
  SELECT vehicle_number INTO _vnum FROM public.vehicles WHERE id = NEW.vehicle_id;
  SELECT route_number INTO _rnum FROM public.routes WHERE id = NEW.route_id;

  -- Notify all admins
  INSERT INTO public.notifications (user_id, type, title, body, vehicle_id, route_id, sos_id)
  SELECT ur.user_id, 'sos',
    'Emergency: ' || COALESCE(_vnum,'vehicle'),
    COALESCE(NEW.message,'Driver triggered SOS') ||
      CASE WHEN _rnum IS NOT NULL THEN ' · Route ' || _rnum ELSE '' END,
    NEW.vehicle_id, NEW.route_id, NEW.id
  FROM public.user_roles ur WHERE ur.role = 'admin';

  -- Notify passengers who favorited this route
  IF NEW.route_id IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, type, title, body, vehicle_id, route_id, sos_id)
    SELECT fr.user_id, 'sos',
      'Alert on route ' || COALESCE(_rnum,''),
      'Vehicle ' || COALESCE(_vnum,'') || ' reported an emergency.',
      NEW.vehicle_id, NEW.route_id, NEW.id
    FROM public.favorite_routes fr WHERE fr.route_id = NEW.route_id;
  END IF;

  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS sos_fanout ON public.sos_events;
CREATE TRIGGER sos_fanout AFTER INSERT ON public.sos_events
  FOR EACH ROW EXECUTE FUNCTION public.fanout_sos_notification();

-- Realtime
ALTER PUBLICATION supabase_realtime ADD TABLE public.sos_events;
ALTER PUBLICATION supabase_realtime ADD TABLE public.notifications;
