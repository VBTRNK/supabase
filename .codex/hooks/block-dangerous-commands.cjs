#!/usr/bin/env node
// Safety hook (PreToolUse): denies a short list of destructive shell commands
// before they run. Claude loads it from .claude/settings.json; .codex/hooks/
// holds Codex's copy, identical except for the agent name in the last line.
// Keep the two in sync.
//
// Self-contained: never load policy from agent-editable application scripts.
// Runtime coverage still requires an actual probe; rules are not owner consent.
// CommonJS (.cjs), so a later `"type": "module"` in package.json can't break it.
const fs = require("node:fs");

const dangers = [
  // Anchored to a command position (start, after a separator, a quote or
  // sudo/xargs/...), so `docker run --rm` and `git rm -r --cached` still run.
  [
    /(?:^|[;&|({\n`"']|\b(?:sudo|xargs|exec|env|command|nohup|time|then|do|else)\s)\s*(?:\S*[\\/])?rm(?:\.exe)?\s(?:[^\n;&|]*\s)?-{1,2}[a-z]*[rf]/i,
    "recursive or forced delete",
  ],
  [/\bgit\s+push\b[^\n]*(?:--force\b|--force-with-lease\b|\s-f\b)/i, "force push"],
  [/\bgit\s+push\b[^\n]*(?:--delete\b|\s:[A-Za-z0-9._/-]+)/i, "remote branch deletion"],
  [/\bgit\s+reset\s+--hard\b/i, "hard reset"],
  [/\bgit\s+clean\s+-\S*f/i, "forced git clean"],
  [/\bgit\s+checkout\s+(--\s|\.$|\.\s)/i, "broad checkout discard"],
  [
    /\b(?:curl|wget|iwr|irm|invoke-webrequest|invoke-restmethod)\b[^\n]*\|[^\n]*\b(?:sh|bash|pwsh|powershell|python|node|iex)\b/i,
    "download piped into interpreter",
  ],
  [
    /\biex\b[^\n]*\biwr\b|\biwr\b[^\n]*\|[^\n]*\biex\b|\binvoke-expression\b[^\n]*\binvoke-webrequest\b/i,
    "download executed directly",
  ],
  [
    /\bremove-item\b[^\n]*-recurse[^\n]*-force|\bremove-item\b[^\n]*-force[^\n]*-recurse/i,
    "forced recursive PowerShell deletion",
  ],
  // Force-deleting a branch can lose unmerged commits; `git branch -d` (which
  // refuses unmerged branches) stays allowed. Case-sensitive on purpose.
  [/\bgit\s+branch\b[^\n;&|]*\s-[a-zA-Z]*D/, "forced branch deletion"],
  [
    /\bgit\s+branch\b(?=[^\n;&|]*\s(?:-[a-zA-Z]*d|--delete\b))(?=[^\n;&|]*\s(?:-[a-zA-Z]*f|--force\b))/,
    "forced branch deletion",
  ],
];

function decision(value, reason) {
  return {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: value,
      permissionDecisionReason: reason,
    },
  };
}
function evaluate(raw, agent) {
  if (agent !== "codex" && agent !== "claude")
    return decision("deny", "Unsupported agent; no approval can be inferred.");
  let payload;
  try {
    payload = JSON.parse(raw);
  } catch {
    return decision("deny", "Safety payload is unreadable; no consent can be inferred.");
  }
  const supported = ["Bash", "PowerShell", "exec_command", "functions.exec_command"];
  if (!payload || !supported.includes(payload.tool_name))
    return decision(
      "deny",
      "Unsupported safety tool name; coverage must be established before proceeding.",
    );
  const input = payload.tool_input;
  const command = input?.command ?? input?.cmd;
  if (typeof command !== "string" || !command.trim())
    return decision("deny", "Missing shell command; fail closed.");
  for (const [pattern, reason] of dangers)
    if (pattern.test(command))
      return decision(
        "deny",
        "Repository safety policy blocks " + reason + ". A wrapper is not an exception.",
      );
  return null;
}

function run(agent) {
  let result;
  try {
    result = evaluate(fs.readFileSync(0, "utf8"), agent);
  } catch {
    result = decision("deny", "Safety check could not read its input; fail closed.");
  }
  if (result) process.stdout.write(JSON.stringify(result));
}
module.exports = { evaluate, run };
if (require.main === module) run("codex");
