// Drives the Claude Code plugin's hooks module (decision 0022) against a fake
// host: scripted `intelligence sync --check` answers go in, and the band above
// the prompt, the status line, the toasts and the /intelligence replies come
// out. verify.sh runs it in the plugin gate wherever node is on PATH.
//
//   node cli/tests/plugin-hooks.mjs [repo-root]
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const root = process.argv[2] || fileURLToPath(new URL('../..', import.meta.url))
const source = readFileSync(root + '/engine/adapters/claude-plugin/hooks/register.js', 'utf8')

// The module keeps its state in module scope, as one load in Claude Code
// does, so every case loads a fresh copy. A data: URL is ESM on every node,
// whatever the nearest package.json says about .js files.
let loads = 0
async function load() {
  loads += 1
  const url = 'data:text/javascript,' + encodeURIComponent(source + '\n// load ' + loads)
  return (await import(url)).register
}

const element = (type) => (props) => ({ type, ...props })
const elements = { Box: element('Box'), Text: element('Text'), Button: element('Button') }

// What the terminal shows for a tree: Text as written, a plain Button as
// `<hotkey>: <label>`, siblings two columns apart.
function shown(node) {
  if (typeof node === 'string') return node
  if (node.type === 'Button') return (node.hotkey ? node.hotkey + ': ' : '') + node.label
  return (node.children || []).map(shown).join(node.type === 'Box' ? '  ' : '')
}

function colored(node) {
  if (typeof node === 'string') return false
  return Boolean(node.color) || (node.children || []).some(colored)
}

// Lets every promise the module left running settle.
const settle = () => new Promise((resolve) => setImmediate(resolve))

// session(answers, surface) — a loaded module in a started session whose
// process.run answers each call with the next scripted result.
async function session(answers, surface = 'terminal') {
  const register = await load()
  const hooks = {}
  register((event, matcher, hook) => {
    hooks[event] = hook || matcher
  })
  const host = { toasts: [], statuses: [], runs: [] }
  const $ = {
    session: { root: async () => '/project', surfaces: async () => [surface] },
    process: {
      run: async (argv) => {
        host.runs.push(argv.join(' '))
        const answer = answers.shift()
        if (answer instanceof Error) throw answer
        return typeof answer === 'function' ? answer() : answer
      },
    },
    clock: { every: () => ({ cancel() {} }), after: () => ({ cancel() {} }) },
    ui: {
      toast: (text) => host.toasts.push(text),
      status: (text) => host.statuses.push(text),
      invalidate() {},
      log() {},
      resolve: () => elements,
    },
    command: { register: async () => {} },
    fs: { exists: async () => false },
  }
  const ENGINE = { drawnBy: 'engine' }
  host.band = async () => {
    const tree = await hooks['ui.render']($, { component: 'AbovePrompt', surface }, async () => ENGINE)
    return tree === ENGINE ? null : tree
  }
  host.command = async (args) => (await hooks['command.run']($, { args })).text
  await hooks['session.start']($, {}, async () => undefined)
  await settle()
  return host
}

const verdict = (exitCode, status, stderr = '') => ({ exitCode, stdout: 'IS_STATUS=' + status + '\n', stderr })
const WARNING = "WARNING: project schema 0.29.0 is newer than this CLI's engine 0.28.0 — the project uses a newer CLI; update it: intelligence upgrade\n"
const REFUSAL = {
  exitCode: 4,
  stdout: 'IS_STATUS=ahead-of-engine IS_DETAIL=stamp=1.0.0 engine=0.28.0\n',
  stderr: '  ERROR: project stamped 1.0.0 but this engine is 0.28.0 — a newer major schema; refusing.\n',
}

const cases = {
  async 'a check in flight turns a dim spinner beside the product name'() {
    let answer
    const host = await session([() => new Promise((resolve) => { answer = resolve })])
    const band = await host.band()
    assert.match(shown(band), /^\S Checking Intelligence…$/)
    assert.equal(band.children[0].dimColor, true)
    answer(verdict(0, 'ok'))
  },

  async 'up to date draws nothing'() {
    const host = await session([verdict(0, 'ok')])
    assert.equal(await host.band(), null)
    assert.deepEqual(host.toasts, [])
  },

  async 'a needed sync is one plain sentence and a hotkey, in no color'() {
    const host = await session([verdict(2, 'out-of-date')])
    const band = await host.band()
    assert.equal(shown(band), 'Intelligence needs a sync  1: Sync now')
    assert.equal(colored(band), false)
    assert.equal(band.children[0].dimColor, false)
  },

  async 'a CLI behind by a minor keeps the verdict and the sync, and says so once'() {
    const host = await session([verdict(2, 'out-of-date', WARNING), verdict(2, 'out-of-date', WARNING)])
    assert.equal(shown(await host.band()), 'Intelligence needs a sync  1: Sync now')
    await host.command('check')
    assert.equal(host.toasts.length, 1)
    assert.match(host.toasts[0], /^This project uses a newer Intelligence CLI; upgrade when ready: intelligence upgrade$/)
  },

  async 'a CLI behind by a major draws nothing, says so once and runs no sync'() {
    const host = await session([REFUSAL, REFUSAL])
    assert.equal(await host.band(), null)
    await host.command('check')
    assert.deepEqual(host.toasts, ['This project needs a newer Intelligence CLI to sync: intelligence upgrade'])
    const runs = host.runs.length
    assert.match(await host.command('sync'), /^Intelligence sync not run/)
    assert.equal(host.runs.length, runs)
    assert.match(await host.command(''), /intelligence upgrade/)
  },

  async 'where no band draws, a CLI behind by a major leaves the status line empty'() {
    const host = await session([REFUSAL], 'vscode')
    assert.equal(host.statuses.at(-1), undefined)
  },

  async 'where no band draws, the status line carries the verdict'() {
    const host = await session([verdict(2, 'out-of-date')], 'vscode')
    assert.match(host.statuses.at(-1), /^sync needed — run \/intelligence sync/)
  },

  async 'a missing CLI is one dim sentence'() {
    const host = await session([new Error('failed to start: intelligence')])
    const band = await host.band()
    assert.equal(shown(band), 'Intelligence CLI not found on PATH')
    assert.equal(band.children[0].dimColor, true)
  },

  async 'a failed check names where the reason is, in no color'() {
    const host = await session([{ exitCode: 1, stdout: '', stderr: 'ERROR: manifest unreadable\n' }])
    const band = await host.band()
    assert.equal(shown(band), 'Intelligence check failed  /intelligence shows why')
    assert.equal(colored(band), false)
    assert.match(await host.command(''), /manifest unreadable/)
  },

  async 'a sync from the band reports with the product name'() {
    const host = await session([verdict(2, 'out-of-date'), verdict(0, 'ok'), verdict(0, 'ok')])
    assert.match(await host.command('sync'), /^Intelligence sync finished — up to date/)
    assert.equal(host.toasts.at(-1), 'Intelligence sync finished')
    assert.equal(await host.band(), null)
  },
}

let failed = 0
for (const [name, run] of Object.entries(cases)) {
  try {
    await run()
    console.log('ok: ' + name)
  } catch (err) {
    failed += 1
    console.log('FAIL: ' + name + '\n  ' + String(err && err.message ? err.message : err).replace(/\n/g, '\n  '))
  }
}
if (failed > 0) process.exit(1)
console.log('PLUGIN-HOOKS: ALL OK')
