CREATE POLICY "Driver inserts own vehicle"
ON public.vehicles
FOR INSERT
TO authenticated
WITH CHECK (driver_id = auth.uid());