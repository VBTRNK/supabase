const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const root = path.resolve(__dirname, "..");
const blocked = [
  "supabase db push",
  "npx supabase db push --linked",
  "npx --yes supabase db push --include-all",
  "SUPABASE DB PUSH",
  "supabase.exe db reset --local",
  "npx supabase db reset --linked",
  "supabase secrets set KEY=example",
  "npx supabase secrets set --env-file .env.example",
  "supabase db push --dry-run=false",
  "supabase db push; supabase db push --dry-run",
  "supabase db push --dry-run && supabase db push",
  "supabase db push # --dry-run",
  "supabase db push; echo '--dry-run'"
];
const allowed = [
  "supabase migration list",
  "npx supabase migration list",
  "supabase db push --dry-run",
  "npx supabase db push --dry-run --include-all",
  "supabase db push --linked --dry-run",
  "SUPABASE DB PUSH --DRY-RUN",
  "supabase db push --dry-run; git status",
  "git status"
];
test("Supabase mutations are denied and read-only CLI operations remain usable", () => {
  for (const agent of ["codex", "claude"])
    for (const tool_name of ["Bash", "PowerShell", "exec_command", "functions.exec_command"])
      for (const command of [...blocked, ...allowed]) {
        const { evaluate } = require(path.join(root, `.${agent}/hooks/block-dangerous-commands.cjs`));
        const key = tool_name.includes("exec_command") ? "cmd" : "command";
        const result = evaluate(JSON.stringify({tool_name, tool_input:{[key]:command}}), agent);
        assert.equal(result?.hookSpecificOutput.permissionDecision ?? null,
          blocked.includes(command) ? "deny" : null, `${agent} ${tool_name}: ${command}`);
      }
});
test("both agent guard bodies match apart from their final launcher", () => {
  const guards = ["codex", "claude"].map(agent =>
    fs.readFileSync(path.join(root, `.${agent}/hooks/block-dangerous-commands.cjs`), "utf8")
      .replace(`run("${agent}");`, 'run("AGENT");'));
  assert.equal(guards[0], guards[1]);
});
