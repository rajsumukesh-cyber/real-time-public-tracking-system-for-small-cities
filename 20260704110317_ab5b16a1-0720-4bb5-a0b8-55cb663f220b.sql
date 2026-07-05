
-- profiles: restrict to owner
DROP POLICY IF EXISTS "Profiles readable by all authed" ON public.profiles;
CREATE POLICY "Users view own profile" ON public.profiles FOR SELECT TO authenticated USING (auth.uid() = id);
CREATE POLICY "Admins view all profiles" ON public.profiles FOR SELECT TO authenticated USING (public.has_role(auth.uid(), 'admin'::public.app_role));

-- routes: restrict to authenticated
DROP POLICY IF EXISTS "Routes public read" ON public.routes;
CREATE POLICY "Routes readable by authenticated" ON public.routes FOR SELECT TO authenticated USING (true);
REVOKE SELECT ON public.routes FROM anon;

-- vehicles: restrict to authenticated
DROP POLICY IF EXISTS "Vehicles public read" ON public.vehicles;
CREATE POLICY "Vehicles readable by authenticated" ON public.vehicles FOR SELECT TO authenticated USING (true);
REVOKE SELECT ON public.vehicles FROM anon;

-- trips: restrict to authenticated
DROP POLICY IF EXISTS "Trips public read" ON public.trips;
CREATE POLICY "Trips readable by authenticated" ON public.trips FOR SELECT TO authenticated USING (true);
REVOKE SELECT ON public.trips FROM anon;

-- sos_events: remove broad passenger visibility. Passengers who favorited the route get notifications via the notifications table.
DROP POLICY IF EXISTS "Passengers see active sos" ON public.sos_events;
CREATE POLICY "Dispatched drivers view sos" ON public.sos_events FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.sos_escalations e WHERE e.sos_id = sos_events.id AND e.driver_id = auth.uid()));

-- Revoke EXECUTE on client-callable SECURITY DEFINER function
REVOKE EXECUTE ON FUNCTION public.escalate_stale_sos() FROM PUBLIC, anon, authenticated;
