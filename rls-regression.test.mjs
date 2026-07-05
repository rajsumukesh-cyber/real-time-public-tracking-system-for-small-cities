#!/usr/bin/env node
/**
 * RLS regression suite.
 *
 * Verifies that each core table (profiles, routes, vehicles, trips,
 * sos_events) enforces the intended visibility for anon, authenticated
 * passenger, driver, and admin roles.
 *
 * Requires:
 *   SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY  — always
 *   SUPABASE_SERVICE_ROLE_KEY               — optional; skips role-scoped
 *                                             checks when absent (CI without
 *                                             service key still runs the anon
 *                                             matrix).
 *
 * Run:  node scripts/rls-regression.test.mjs
 */
import { createClient } from "@supabase/supabase-js";

const URL = process.env.SUPABASE_URL;
const ANON = process.env.SUPABASE_PUBLISHABLE_KEY;
const SERVICE = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!URL || !ANON) {
  console.error("Missing SUPABASE_URL / SUPABASE_PUBLISHABLE_KEY");
  process.exit(2);
}

let failed = 0;
const results = [];

function record(name, ok, detail = "") {
  results.push({ name, ok, detail });
  if (!ok) failed++;
  console.log(`  ${ok ? "✓" : "✗"} ${name}${detail ? "  — " + detail : ""}`);
}

function anonClient() {
  return createClient(URL, ANON, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

async function assertBlocked(client, table, label) {
  const { data, error } = await client.from(table).select("*").limit(1);
  // "blocked" = either an error, or an empty array (RLS filtered).
  const ok = !!error || (Array.isArray(data) && data.length === 0);
  record(`${label}: ${table} read blocked`, ok, error?.message ?? "");
}

async function runAnonMatrix() {
  console.log("\n[anon] — publishable key, no session");
  const c = anonClient();
  for (const t of ["profiles", "routes", "vehicles", "trips", "sos_events"]) {
    await assertBlocked(c, t, "anon");
  }
}

async function makeUserClient(email, password, meta) {
  if (!SERVICE) return null;
  const admin = createClient(URL, SERVICE, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  // Idempotent create via admin.
  const { data: created, error: cErr } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: meta,
  });
  if (cErr && !/already/i.test(cErr.message)) throw cErr;
  const userId =
    created?.user?.id ??
    (await admin.auth.admin
      .listUsers({ page: 1, perPage: 200 })
      .then((r) => r.data.users.find((u) => u.email === email)?.id));
  if (!userId) throw new Error(`Could not resolve user id for ${email}`);

  // Elevate to admin role if requested.
  if (meta.role === "admin") {
    await admin
      .from("user_roles")
      .upsert({ user_id: userId, role: "admin" }, { onConflict: "user_id,role" });
  }

  const c = createClient(URL, ANON, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { error: sErr } = await c.auth.signInWithPassword({ email, password });
  if (sErr) throw sErr;
  return { client: c, userId };
}

async function runAuthedMatrix() {
  if (!SERVICE) {
    console.log("\n[skip] Authed matrix — no SUPABASE_SERVICE_ROLE_KEY provided");
    return;
  }
  const stamp = Date.now();
  const passenger = await makeUserClient(
    `rls-passenger-${stamp}@example.test`,
    "Password!12345",
    { role: "passenger", full_name: "Test Passenger" },
  );
  const driver = await makeUserClient(
    `rls-driver-${stamp}@example.test`,
    "Password!12345",
    { role: "driver", full_name: "Test Driver" },
  );
  const admin = await makeUserClient(
    `rls-admin-${stamp}@example.test`,
    "Password!12345",
    { role: "admin", full_name: "Test Admin" },
  );

  // Signed-in users may read routes / vehicles / trips.
  for (const [label, { client }] of [
    ["passenger", passenger],
    ["driver", driver],
    ["admin", admin],
  ]) {
    for (const t of ["routes", "vehicles", "trips"]) {
      const { error } = await client.from(t).select("id").limit(1);
      record(`${label}: ${t} read allowed`, !error, error?.message ?? "");
    }
  }

  // Profile: user sees own row only (not siblings).
  {
    const { data: mine, error: e1 } = await passenger.client
      .from("profiles")
      .select("id")
      .eq("id", passenger.userId)
      .maybeSingle();
    record("passenger: reads own profile", !e1 && mine?.id === passenger.userId);

    const { data: others } = await passenger.client
      .from("profiles")
      .select("id")
      .neq("id", passenger.userId);
    record(
      "passenger: cannot read other profiles",
      Array.isArray(others) && others.length === 0,
    );
  }

  // Admin can read all profiles.
  {
    const { data, error } = await admin.client.from("profiles").select("id").limit(5);
    record("admin: reads all profiles", !error && (data?.length ?? 0) >= 1);
  }

  // Passenger cannot see raw sos_events (delivered via notifications table instead).
  {
    const { data } = await passenger.client.from("sos_events").select("id").limit(1);
    record(
      "passenger: sos_events not visible",
      Array.isArray(data) && data.length === 0,
    );
  }
}

console.log("RLS regression suite");
await runAnonMatrix();
await runAuthedMatrix();

console.log(
  `\n${failed === 0 ? "✓ all" : "✗ " + failed + " failed of"} ${results.length} checks`,
);
process.exit(failed === 0 ? 0 : 1);
