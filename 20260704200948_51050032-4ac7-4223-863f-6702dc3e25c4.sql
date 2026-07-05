
CREATE TABLE public.access_audit_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  actor_role text,
  module text NOT NULL,
  action text NOT NULL,
  target_driver_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  target_vehicle_id uuid REFERENCES public.vehicles(id) ON DELETE SET NULL,
  details jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_access_audit_created_at ON public.access_audit_log (created_at DESC);
CREATE INDEX idx_access_audit_actor ON public.access_audit_log (actor_id);
CREATE INDEX idx_access_audit_driver ON public.access_audit_log (target_driver_id);

GRANT SELECT, INSERT ON public.access_audit_log TO authenticated;
GRANT ALL ON public.access_audit_log TO service_role;

ALTER TABLE public.access_audit_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users_insert_own_audit"
  ON public.access_audit_log
  FOR INSERT
  TO authenticated
  WITH CHECK (actor_id = auth.uid());

CREATE POLICY "users_read_own_audit"
  ON public.access_audit_log
  FOR SELECT
  TO authenticated
  USING (actor_id = auth.uid());

CREATE POLICY "admins_read_all_audit"
  ON public.access_audit_log
  FOR SELECT
  TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
  ));
