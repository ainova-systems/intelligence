#!/usr/bin/env node
'use strict';
// Thin launcher for the intelligence CLI. All logic lives in bash (cli/ and
// engine/ inside this package); this shim only finds a usable bash and execs
// the dispatcher with stdio passed through. It never rewrites paths — Git
// Bash accepts forward-slash Windows paths, and the engine re-normalizes.

const { spawnSync, execSync } = require('child_process');
const path = require('path');
const fs = require('fs');

function isWslStub(p) {
  // System32\bash.exe is the WSL launcher: a Linux userland that cannot see
  // this package's files the way Git Bash can. Never pick it.
  return /system32[\\/]+bash\.exe$/i.test(p);
}

function findBash() {
  const override = process.env.INTELLIGENCE_BASH;
  if (override && fs.existsSync(override)) return override;
  if (process.platform !== 'win32') return 'bash';

  const candidates = [];
  try {
    const git = execSync('where git', { encoding: 'utf8' }).split(/\r?\n/)[0].trim();
    if (git) {
      // <git-root>\cmd\git.exe (or \bin\git.exe) → <git-root>\bin\bash.exe
      candidates.push(path.join(path.dirname(git), '..', 'bin', 'bash.exe'));
      candidates.push(path.join(path.dirname(git), '..', 'usr', 'bin', 'bash.exe'));
    }
  } catch (_) { /* git not on PATH — fall through to the fixed locations */ }
  candidates.push(
    'C:\\Program Files\\Git\\bin\\bash.exe',
    'C:\\Program Files (x86)\\Git\\bin\\bash.exe'
  );
  for (const c of candidates) {
    if (!isWslStub(c) && fs.existsSync(c)) return c;
  }
  try {
    const found = execSync('where bash', { encoding: 'utf8' })
      .split(/\r?\n/).map((s) => s.trim()).filter((s) => s && !isWslStub(s));
    if (found.length > 0) return found[0];
  } catch (_) { /* no bash anywhere */ }
  console.error('intelligence: bash not found. Install Git for Windows (https://git-scm.com) — its bash is all this CLI needs.');
  process.exit(1);
}

const cli = path.join(__dirname, '..', 'cli', 'intelligence').replace(/\\/g, '/');
const pkg = require(path.join(__dirname, '..', 'package.json'));

const result = spawnSync(findBash(), [cli].concat(process.argv.slice(2)), {
  stdio: 'inherit',
  env: Object.assign({}, process.env, { INTELLIGENCE_NPM_VERSION: pkg.version }),
});
if (result.error) {
  console.error('intelligence: failed to launch bash: ' + result.error.message);
  process.exit(1);
}
process.exit(result.status === null ? 1 : result.status);
