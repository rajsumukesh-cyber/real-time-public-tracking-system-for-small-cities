#!/usr/bin/env node
/**
 * CI security gate.
 *
 * Verifies structural RLS invariants on the connected Postgres database and
 * compares any findings against `scripts/security-baseline.json`. New findings
 * (not present in the baseline) cause a non-zero exit and fail the build.
 *
 * Env:
 *   PG* (PGHOST/PGUSER/PGPASSWORD/PGDATABASE/PGPORT) — required
 *   ALLOW_NEW_FINDINGS=1 — record diagnostics but do not fail (bootstrap only)
 */
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { Client } from "pg";

const __dirname = dirname(fileURLToPath(import.meta.url));
const BASELINE_PATH = join(__dirname, "security-baseline.json");

/** Tables that store user-owned or otherwise sensitive rows. */
const SENSITIVE_TABLES = [
  "profiles",
  "user_roles",
  "notifications",
  "notification_preferences",
  "favorite_routes",
  "sos_events",
  "sos_audit_log",
  "sos_escalations",
  "trips",
  "vehicles",
  "routes",
];

/** RPCs that must NOT be callable by anon/authenticated. */
const RESTRICTED_FUNCTIONS = ["public.escalate_stale_sos()"];

async function main() {
  const client = new Client();
  await client.connect();
  const findings = [];

  // 1. RLS enabled on every public table.
  const { rows: tables } = await client.query(`
    select c.relname as table, c.relrowsecurity as rls
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r'
  `);
  for (const t of tables) {
    if (!t.rls) {
      findings.push({
        id: `rls_disabled:${t.table}`,
        severity: "high",
        message: `RLS is disabled on public.${t.table}`,
      });
    }
  }

  // 2. Every sensitive table must have at least one policy.
  const { rows: policies } = await client.query(`
    select schemaname, tablename, policyname, roles, cmd, qual
    from pg_policies where schemaname = 'public'
  `);
  for (const table of SENSITIVE_TABLES) {
    const has = policies.some((p) => p.tablename === table);
    if (!has) {
      findings.push({
        id: `no_policy:${table}`,
        severity: "high",
        message: `public.${table} has RLS but no policies (all reads/writes denied — or worse, unintended)`,
      });
    }
  }

  // 3. No policy on a sensitive table may grant to the {anon} role.
  for (const p of policies) {
    if (!SENSITIVE_TABLES.includes(p.tablename)) continue;
    const roles = Array.isArray(p.roles) ? p.roles : [];
    if (roles.includes("anon")) {
      findings.push({
        id: `anon_policy:${p.tablename}:${p.policyname}`,
        severity: "high",
        message: `Policy "${p.policyname}" on public.${p.tablename} targets the anon role`,
      });
    }
  }

  // 4. Anon must not hold table-level privileges on sensitive tables.
  const { rows: grants } = await client.query(
    `
    select table_name, privilege_type
    from information_schema.role_table_grants
    where grantee = 'anon' and table_schema = 'public'
      and table_name = any($1)
  `,
    [SENSITIVE_TABLES],
  );
  for (const g of grants) {
    findings.push({
      id: `anon_grant:${g.table_name}:${g.privilege_type}`,
      severity: "medium",
      message: `Role anon has ${g.privilege_type} on public.${g.table_name}`,
    });
  }

  // 5. Restricted RPCs must not be executable by anon/authenticated.
  for (const fn of RESTRICTED_FUNCTIONS) {
    const { rows } = await client.query(
      `select has_function_privilege($1, $2, 'EXECUTE') as can`,
      ["authenticated", fn],
    );
    if (rows[0]?.can) {
      findings.push({
        id: `rpc_exec:${fn}:authenticated`,
        severity: "high",
        message: `Role authenticated can EXECUTE ${fn}`,
      });
    }
    const { rows: anonRows } = await client.query(
      `select has_function_privilege($1, $2, 'EXECUTE') as can`,
      ["anon", fn],
    );
    if (anonRows[0]?.can) {
      findings.push({
        id: `rpc_exec:${fn}:anon`,
        severity: "high",
        message: `Role anon can EXECUTE ${fn}`,
      });
    }
  }

  await client.end();

  const baseline = existsSync(BASELINE_PATH)
    ? new Set(JSON.parse(readFileSync(BASELINE_PATH, "utf8")).acknowledged ?? [])
    : new Set();

  const fresh = findings.filter((f) => !baseline.has(f.id));

  console.log(`\nSecurity scan: ${findings.length} finding(s), ${fresh.length} new.\n`);
  for (const f of findings) {
    const tag = baseline.has(f.id) ? "known" : "NEW  ";
    console.log(`  [${tag}] (${f.severity}) ${f.id} — ${f.message}`);
  }

  if (fresh.length > 0 && process.env.ALLOW_NEW_FINDINGS !== "1") {
    console.error(
      `\n✗ ${fresh.length} new security finding(s). ` +
        `Fix them, or acknowledge in scripts/security-baseline.json.\n`,
    );
    process.exit(1);
  }
  console.log("\n✓ No new security findings.\n");
}

main().catch((err) => {
  console.error("security-check failed:", err);
  process.exit(2);
});
