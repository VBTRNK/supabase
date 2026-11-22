const assert = require("node:assert/strict");
const cp = require("node:child_process");
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
test("Antigravity mutations are denied and read-only CLI operations defer to its policy", () => {
  const { evaluate } = require(path.join(root, ".agents/hooks/block-dangerous-commands.cjs"));
  for (const command of [...blocked, ...allowed]) {
    const payload = JSON.stringify({
      toolCall: {
        name: "run_command",
        args: { CommandLine: command },
      },
    });
    const result = evaluate(payload, "antigravity");
    const expected = blocked.includes(command) ? "deny" : undefined;
    assert.equal(result?.decision, expected, `antigravity run_command: ${command}`);
    if (!blocked.includes(command)) assert.equal(result, null, `antigravity run_command: ${command}`);
  }
});
test("all agent guard bodies match apart from their final launcher", () => {
  const guards = [
    { dir: ".codex", agent: "codex" },
    { dir: ".claude", agent: "claude" },
    { dir: ".agents", agent: "antigravity" },
  ].map(({ dir, agent }) =>
    fs.readFileSync(path.join(root, `${dir}/hooks/block-dangerous-commands.cjs`), "utf8")
      .replace(`run("${agent}");`, 'run("AGENT");'));
  assert.equal(guards[0], guards[1]);
  assert.equal(guards[0], guards[2]);
});
test("registered .agents/hooks.json command runs from .agents and denies dangerous and malformed payloads", () => {
  const hooksConfig = JSON.parse(fs.readFileSync(path.join(root, ".agents/hooks.json"), "utf8"));
  const command = hooksConfig["safety-gate"]?.PreToolUse?.[0]?.hooks?.[0]?.command;
  assert.ok(command, "command exists in .agents/hooks.json");

  // Dangerous payload (e.g. git reset --hard)
  const denyPayload = JSON.stringify({
    toolCall: {
      name: "run_command",
      args: { CommandLine: "git reset --hard" },
    },
  });
  const res1 = cp.spawnSync(command, {
    shell: true,
    cwd: path.join(root, ".agents"),
    input: denyPayload,
    encoding: "utf8",
  });
  assert.equal(res1.status, 0, `process exit status: ${res1.stderr}`);
  const out1 = JSON.parse(res1.stdout);
  assert.equal(out1.decision, "deny", `deny payload output: ${res1.stdout}`);
  assert.match(out1.reason, /hard reset/i);

  // Malformed payload
  const res2 = cp.spawnSync(command, {
    shell: true,
    cwd: path.join(root, ".agents"),
    input: "not valid json {{{",
    encoding: "utf8",
  });
  assert.equal(res2.status, 0, `process exit status: ${res2.stderr}`);
  const out2 = JSON.parse(res2.stdout);
  assert.equal(out2.decision, "deny", `malformed payload output: ${res2.stdout}`);
  assert.match(out2.reason, /unreadable/i);

  // Safe / unmatched payload: no output, so the agent's own policy decides
  const safePayload = JSON.stringify({
    toolCall: {
      name: "run_command",
      args: { CommandLine: "git status" },
    },
  });
  const res3 = cp.spawnSync(command, {
    shell: true,
    cwd: path.join(root, ".agents"),
    input: safePayload,
    encoding: "utf8",
  });
  assert.equal(res3.status, 0, `process exit status: ${res3.stderr}`);
  assert.equal(res3.stdout, "", "safe payload defers to the permission policy");
});
