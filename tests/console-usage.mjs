// Run with: node tests/console-usage.mjs <path-to-luau>
// Exercise production auth modules and the Usage panel's state transitions with
// controlled clocks and HTTP responses. This does not verify Roblox's rendering or network.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const root = path.resolve(import.meta.dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
function section(source, start, end) {
  const first = source.indexOf(start);
  const last = source.indexOf(end, first + start.length);
  if (first < 0 || last < 0) throw new Error(`Missing production section: ${start}`);
  return source.slice(first, last);
}
const main = read('main.lua');
const claude = read('main/agent/providers/AnthropicAuth.lua')
  .replace('local Pkce = require(script.Parent:WaitForChild("Pkce"))', 'local Pkce = {}');
const openai = read('main/agent/providers/OpenAIAuth.lua');
const source = `
local clockNow = 100
local os = {clock = function() return clockNow end, time = function() return 2000000000 end}
local checked = 0
local function equal(actual, expected)
 checked += 1
 assert(actual == expected, tostring(actual) .. " != " .. tostring(expected))
end
local function near(actual, expected)
 checked += 1
 assert(math.abs(actual - expected) < 0.0000001)
end
local function plugin()
 local settings = {}
 return {GetSetting = function(_, key) return settings[key] end,
  SetSetting = function(_, key, value) settings[key] = value end}
end
local payload = {five_hour = {utilization = 0.5, resets_at = "2033-05-18T04:00:00Z"}}
local httpCalls = 0
local httpResponse = {StatusCode = 200, Body = "fixture"}
local onRequest
local HttpService = {
 JSONEncode = function() return "{}" end,
 JSONDecode = function() return payload end,
 RequestAsync = function(_, options)
  httpCalls += 1
  assert(options.Method == "GET")
  if onRequest then return onRequest(options) end
  return httpResponse
 end,
}
local game = {GetService = function() return HttpService end}
local DateTime = {fromUniversalTime = function() return {UnixTimestamp = 2000001000} end}
local function loadClaude()
${claude}
end
local function loadOpenAI()
${openai}
end
local Claude = loadClaude()
local claudePlugin = plugin()
Claude.Initialize(claudePlugin)
local function signIn()
 claudePlugin:SetSetting("claude_access_token", "fixture-access")
 claudePlugin:SetSetting("claude_refresh_token", "fixture-refresh")
 claudePlugin:SetSetting("claude_expires_at", 2000003600)
end
signIn()
-- The endpoint reports percentages: 0.5 is half a percent, not half the window.
local rows, err = Claude.fetchUsage()
equal(err, nil)
near(rows[1].bar, 0.005)
local revision = Claude.getUsageRevision()
Claude.logout()
equal(Claude.getUsageRevision(), revision + 1)
signIn()

-- A plan fetched for the previous account must not be cached for the next one.
payload = {organization = {organization_type = "claude_max"}}
onRequest = function() coroutine.yield(); return httpResponse end
local planThread = coroutine.create(function() return Claude.fetchPlan() end)
assert(coroutine.resume(planThread))
Claude.logout()
signIn()
local _, stalePlan = coroutine.resume(planThread)
equal(stalePlan, nil)
onRequest = nil
equal(Claude.fetchPlan(), "Max")

local OpenAI = loadOpenAI()
local openaiPlugin = plugin()
OpenAI.Initialize(openaiPlugin)
local function signInOpenAI()
 openaiPlugin:SetSetting("openai_chatgpt_access_token", "fixture-openai-access")
 openaiPlugin:SetSetting("openai_chatgpt_refresh_token", "fixture-openai-refresh")
 openaiPlugin:SetSetting("openai_chatgpt_expires_at", 2000003600)
 openaiPlugin:SetSetting("openai_chatgpt_account_id", "account-fixture")
 openaiPlugin:SetSetting("openai_chatgpt_fedramp", true)
end
signInOpenAI()
payload = {plan_type = "plus", account_id = "account-fixture", rate_limit = {
 primary_window = {used_percent = 40, reset_at = 2000001000, limit_window_seconds = 18000},
 secondary_window = {used_percent = 6, reset_at = 2000600000, limit_window_seconds = 604800}}}
onRequest = function(options)
 equal(options.Url, "https://chatgpt.com/backend-api/wham/usage")
 equal(options.Headers["ChatGPT-Account-ID"], "account-fixture")
 equal(options.Headers["X-OpenAI-Fedramp"], "true")
 return httpResponse
end
rows, err = OpenAI.fetchUsage()
equal(err, nil)
equal(rows[1].value, "Plus")
near(rows[2].bar, 0.4)
-- Logging out while a request yields must not persist the old account's plan.
onRequest = function() coroutine.yield(); return httpResponse end
local staleRows, staleError
local fetchThread = coroutine.create(function() staleRows, staleError = OpenAI.fetchUsage() end)
assert(coroutine.resume(fetchThread))
OpenAI.logout()
signInOpenAI()
assert(coroutine.resume(fetchThread))
equal(staleRows, nil)
equal(staleError, "usage: account changed during refresh")
equal(openaiPlugin:GetSetting("openai_chatgpt_plan_type"), "")
onRequest = nil

-- The panel cache and async completion guards. task.spawn runs immediately up
-- to the first yield, as Roblox's does; runNext resumes the oldest request.
local queue = {}
local task = {spawn = function(fn)
 local thread = coroutine.create(fn)
 assert(coroutine.resume(thread))
 if coroutine.status(thread) ~= "dead" then queue[#queue + 1] = thread end
end}
local function runNext() assert(coroutine.resume(table.remove(queue, 1))) end
local function fakeAuth(name)
 local auth = {revision = 0, calls = 0}
 auth.isLoggedIn = function() return true end
 auth.getUsageRevision = function() return auth.revision end
 auth.fetchUsage = function() auth.calls += 1; coroutine.yield(); return {{label = name, value = name}}, nil end
 auth.fetchPlan = function() coroutine.yield(); return name end
 return auth
end
local a, b = fakeAuth("A"), fakeAuth("B")
local Provider = {auth = a}
local refreshSettings = function() end
${section(main, 'local usageWindows:', '-- One colour per breakdown')}
local refreshPlan
${section(main, 'refreshPlan = function()', '-- Sessions drawer')}
-- A provider switch mid-request: the old result must not land or clear the new flag.
refreshUsage()
Provider.auth = b
refreshUsage()
equal(usageWindows, nil)
runNext()
equal(usageInFlight, true)
equal(usageWindows, nil)
runNext()
equal(usageWindows[1].label, "B")
equal(usageInFlight, false)
refreshUsage()
equal(#queue, 0)
refreshUsage(true)
runNext()
equal(b.calls, 2)
-- A re-login on the same provider is a new owner too.
refreshUsage(true)
b.revision += 1
refreshUsage(true)
equal(usageWindows, nil)
runNext()
equal(usageInFlight, true)
runNext()
equal(usageWindows[1].label, "B")
-- A failure keeps the last bars and starts a cooldown even Refresh respects.
local lastRows = usageWindows
b.fetchUsage = function() b.calls += 1; return nil, "usage: rate limited" end
refreshUsage(true)
equal(usageWindows, lastRows)
equal(usageError, "usage: rate limited")
equal(usageInFlight, false)
local calls = b.calls
refreshUsage(true)
equal(b.calls, calls)
clockNow += 60
b.fetchUsage = function() error("fixture failure") end
refreshUsage(true)
equal(usageWindows, lastRows)
equal(usageInFlight, false)
refreshUsage(true)
equal(#queue, 0)
-- The cooldown belonged to B's account, not to A's.
Provider.auth = a
refreshUsage(true)
runNext()
equal(usageWindows[1].label, "A")
refreshPlan()
Provider.auth = b
refreshPlan()
runNext()
equal(planName, nil)
runNext()
equal(planName, "B")
print(checked .. " console usage checks passed")
`;
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'roblox-console-usage-'));
const filename = path.join(directory, 'checks.luau');
try {
  fs.writeFileSync(filename, source);
  const result = spawnSync(process.argv[2] || 'luau', [filename], { encoding: 'utf8', timeout: 10000 });
  if (result.error) throw result.error;
  process.stdout.write(result.stdout || '');
  process.stderr.write(result.stderr || '');
  process.exitCode = result.status ?? 1;
} finally {
  fs.unlinkSync(filename);
  fs.rmdirSync(directory);
}
