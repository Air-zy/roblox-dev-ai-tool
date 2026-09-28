// Run the real Luau modules and their regressions without a Studio session.
// The small Roblox shim covers Instance trees and editor buffers; it does not
// claim to test engine undo, Studio UI, or network requests.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import printfCases from './printf-cases.mjs';
import shellCases from './shell-cases.mjs';
import awkCases from './awk-cases.mjs';

const root = path.resolve(import.meta.dirname, '..');
const binary = process.argv[2] || 'luau';
const modules = {};
function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const file = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(file);
    else if (/\.lua$/.test(file)) modules[path.relative(root, file).replaceAll('\\', '/').replace(/\.lua$/, '')] = fs.readFileSync(file, 'utf8');
  }
}
walk(path.join(root, 'main'));
walk(path.join(root, 'tests'));
function literal(source) {
  let equals = '=';
  while (source.includes(`]${equals}]`)) equals += '=';
  return `[${equals}[${source}]${equals}]`;
}
const bash = process.argv[3] || 'C:/Program Files/Git/bin/bash.exe';
if (!fs.existsSync(bash)) throw new Error('Bash is required for printf differential tests; pass its path as the third argument.');
// Luau long strings cannot encode NUL or an initial newline losslessly.
const luaString = value => '"' + [...Buffer.from(value)].map(byte => `\\${String(byte).padStart(3, '0')}`).join('') + '"';
const vectors = printfCases.map(args => {
  // OS argv cannot contain NUL; that one vector is covered by the Luau tests.
  if (args.some(arg => arg.includes('\0'))) return null;
  const answer = spawnSync(bash, ['--noprofile', '--norc', '-c', 'mapfile -d "" -t args; printf "${args[@]}"'], {
    input: Buffer.from(args.join('\0') + '\0'), timeout: 10000,
    env: { ...process.env, LC_ALL: 'C' },
  });
  if (answer.error) throw answer.error;
  return `{ args = { ${['printf', ...args].map(luaString).join(', ')} }, out = ${luaString(answer.stdout)}, failed = ${answer.status !== 0} }`;
}).filter(Boolean);
modules['tests/PrintfOracle'] = `return { ${vectors.join(',\n')} }`;
const languageVectors = shellCases.map(source => {
  const answer = spawnSync(bash, ['--noprofile', '--norc'], {
    input: Buffer.from(source), timeout: 10000, env: { ...process.env, LC_ALL: 'C' },
  });
  if (answer.error || answer.status === null || answer.stderr.length) {
    throw new Error(`Bash language oracle failed: ${source}\n${answer.error || answer.stderr}`);
  }
  return `{ source = ${luaString(source)}, out = ${luaString(answer.stdout.toString('utf8').replace(/\n$/, ''))}, code = ${answer.status} }`;
});
modules['tests/ShellOracle'] = `return { ${languageVectors.join(',\n')} }`;
// gawk ships with Git for Windows beside that bash, and is the awk the vectors
// were chosen against. Each case gets its own directory holding its files. The
// argv goes through a NUL-separated file for the same reason printf's does: a
// Windows command line reaching MSYS is re-parsed, which eats backslashes and
// brace-expands `/x{2,3}/` into two arguments.
const awkVectors = awkCases.map(c => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'awk-case-'));
  for (const [name, text] of Object.entries(c.files || {})) fs.writeFileSync(path.join(dir, name), text);
  fs.writeFileSync(path.join(dir, '.argv'), [...(c.args || []), c.p, ...(c.ops || [])].map(arg => arg + '\0').join(''));
  fs.writeFileSync(path.join(dir, '.stdin'), c.in ?? '');
  const answer = spawnSync(bash, ['--noprofile', '--norc', '-c', 'mapfile -d "" -t args < .argv; exec -a awk gawk "${args[@]}" < .stdin'], {
    cwd: dir, timeout: 10000, env: { ...process.env, LC_ALL: 'C' },
  });
  fs.rmSync(dir, { recursive: true, force: true });
  if (answer.error || answer.status === null) throw new Error(`gawk oracle failed: ${c.p}\n${answer.error || answer.stderr}`);
  const flags = [...(c.args || [])];
  let fieldSep = 'nil';
  const assigns = [];
  while (flags.length) {
    const flag = flags.shift();
    if (flag === '-F') fieldSep = luaString(flags.shift());
    else if (flag === '-v') assigns.push(luaString(flags.shift()));
  }
  const files = Object.entries(c.files || {}).map(([name, text]) => `[${luaString(name)}] = ${luaString(text)}`);
  return `{ program = ${luaString(c.p)}, fs = ${fieldSep}, assigns = { ${assigns.join(', ')} }, ` +
    `operands = { ${(c.ops || []).map(luaString).join(', ')} }, stdin = ${c.in === undefined ? 'nil' : luaString(c.in)}, ` +
    `files = { ${files.join(', ')} }, out = ${luaString(answer.stdout)}, code = ${answer.status} }`;
});
modules['tests/AwkOracle'] = `return { ${awkVectors.join(',\n')} }`;
const sources = Object.entries(modules).map(([name, source]) => `[${JSON.stringify(name)}] = ${literal(source)}`).join(',\n');
const runner = `local sources = {\n${sources}\n}
local base = getfenv()
local shim = assert(loadstring(sources['tests/RobloxShim'], '@tests/RobloxShim.lua'))()
local cache = {}
local function node(name)
  return setmetatable({ path = name }, {
    __index = function(self, key)
      if key == 'Parent' then return node(self.path:match('^(.*)/[^/]+$') or '') end
      if key == 'Name' then return self.path:match('[^/]+$') end
      if key == 'WaitForChild' then return function(_, child) return node((self.path == '' and '' or self.path .. '/') .. child) end end
      if key == 'GetChildren' then return function()
        local children = {}
        for name in pairs(sources) do
          if name:match('^(.*)/[^/]+$') == self.path then children[#children+1] = node(name) end
        end
        return children
      end end
      if key == 'IsA' then return function(_, class) return class == 'ModuleScript' end end
    end
  })
end
local loadModule
function loadModule(scriptNode)
  local name = scriptNode.path
  if cache[name] then return cache[name] end
  assert(sources[name], 'missing module ' .. name)
  local chunk = assert(loadstring(sources[name], '@' .. name .. '.lua'))
  local environment = setmetatable({ script = scriptNode, require = loadModule }, { __index = function(_, key)
    if shim[key] ~= nil then return shim[key] end
    return base[key]
  end })
  setfenv(chunk, environment)
  local value = chunk()
  cache[name] = value
  return value
end
local builtins = loadModule(node('main/fs/ShellBuiltins'))
for index, vector in ipairs(loadModule(node('tests/PrintfOracle'))) do
  local out, err, code = builtins.printf(vector.args)
  assert(out == vector.out and ((code or 0) ~= 0) == vector.failed,
    string.format('Bash printf vector %d (%s): expected %q / error=%s, got %q / %s', index,
      table.concat(vector.args, ' | '), vector.out, tostring(vector.failed), out, tostring(err)))
end
print('Bash printf differential checks: ${vectors.length} passed')
local Awk = loadModule(node('main/text/Awk'))
local awkFailures = {}
for index, vector in ipairs(loadModule(node('tests/AwkOracle'))) do
  local files = vector.files
  local out, err, code = Awk.run({ program = vector.program, fs = vector.fs, assigns = vector.assigns,
    operands = vector.operands, stdin = vector.stdin, environ = { HOME = '/' },
    read = function(name) if files[name] then return files[name] end return nil, 'no such file' end,
    write = function(name, text, append) files[name] = (append and files[name] or '') .. text end })
  if out ~= vector.out or code ~= vector.code then
    awkFailures[#awkFailures + 1] = string.format('gawk vector %d (%s): expected %q / %d, got %q / %d %s',
      index, vector.program, vector.out, vector.code, out, code, err)
  end
end
for _, failure in ipairs(awkFailures) do print(failure) end
assert(#awkFailures == 0, #awkFailures .. ' gawk vectors failed')
print('gawk differential checks: ${awkVectors.length} passed')
local Terminal, Shell = loadModule(node('main/fs/Terminal')), loadModule(node('main/fs/Shell'))
for index, vector in ipairs(loadModule(node('tests/ShellOracle'))) do
  local terminal = Terminal.new(shim.game)
  local out = Shell.run(terminal, vector.source)
  local code = terminal.shellState.status
  assert(out == vector.out and code == vector.code,
    string.format('Bash shell vector %d (%s): expected %q / %d, got %q / %d',
      index, vector.source, vector.out, vector.code, out, code))
end
print('Bash shell differential checks: ${languageVectors.length} passed')
loadModule(node('tests/CopyBuffers'))(Terminal, shim)
print('Copy editor-buffer and rollback checks: passed')
local ok, err = Shell.selfTest(Terminal.new(shim.game))
assert(ok, 'Shell.selfTest: ' .. tostring(err))
assert(shim.changes.recordings > 0, 'mutations bypassed the undo wrapper')
print('Shell.selfTest passed, including TODO regressions (engine-only Git checks skip without EncodingService)')
`;
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'roblox-shell-tests-'));
const file = path.join(temp, 'run.luau');
fs.writeFileSync(file, runner);
const result = spawnSync(binary, [file], { encoding: 'utf8', timeout: 120000 });
process.stdout.write(result.stdout || '');
process.stderr.write(result.stderr || '');
if (result.error) console.error(result.error.message);
// The generated bundle is left in the named temporary directory for diagnosis.
if (result.status !== 0) console.error(`Test bundle: ${file}`);
process.exitCode = result.status ?? 1;
