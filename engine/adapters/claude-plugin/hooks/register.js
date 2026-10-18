// Intelligence sync status for Claude Code.
//
// `intelligence sync` renders this file from the engine's claude-plugin
// template when targets.claude.plugin is true (decision 0022). It is a Claude
// Code mod: a hooks module with no Node.js APIs, reaching the project only
// through the mods API `$`. It asks `intelligence sync --check` whether the
// generated output is current when a session starts and every five minutes,
// shows the answer in one line above the prompt while a check runs or
// something needs attention, and runs `intelligence sync` from a button there
// or the /intelligence command. It registers no tool and never submits a
// prompt: it informs the person, never Claude.

// A cold `sync --check` renders the project in a private copy, which takes
// minutes on Git Bash; a warm one answers from its record in seconds. The
// timeout stays just under the interval, so a slow check is waited for rather
// than reported as a failure. A tick never starts a check while one of ours is
// pending; one abandoned at the timeout can still finish beside the next.
const CHECK_EVERY_MS = 300000
const CHECK_TIMEOUT_MS = 290000
// `$.process.run` allows ten minutes at most, which a full sync may need: it
// first waits for any check holding the project lock (decision 0022).
const SYNC_TIMEOUT_MS = 600000
// Another command holding the project lock is asked again this soon, not at
// the next five-minute tick.
const RETRY_MS = 15000
// The spinner Claude Code draws while it works.
const FRAMES = ['·', '✢', '✳', '✶', '✻', '✽', '✻', '✶', '✳', '✢']
const FRAME_MS = 120
// The CLI's refusal when another command holds the project lock.
const LOCK_REFUSAL = /another intelligence sync is (running|starting)/
// The CLI's warning when the project was stamped by a newer CLI than itself.
const CLI_BEHIND = /newer than this CLI's engine/

// What the last check found. `status` is one of unknown (no verdict yet), ok,
// stale, error, missing-cli or old-cli; `busy` is true while a sync started
// from here is running.
const state = { status: 'unknown', detail: '', checkedAt: null, busy: false }
// A check already in flight answers the next caller too, so a timer tick and
// a /intelligence check never run two CLI processes side by side.
let pendingCheck = null
let retry = null
let ticker = null
let frame = 0
// The terminal and the Desktop app draw the band above the prompt; elsewhere,
// such as the VS Code extension, the status line under the prompt carries the
// text. The footer under the prompt is Claude Code's own and stays untouched.
let band = false

// The CLI reports its result as one `IS_STATUS=<status> IS_DETAIL=<text>`
// line; everything else on stdout is progress.
function parseStatus(stdout) {
  const match = /^IS_STATUS=(\S+)(?: IS_DETAIL=(.*))?$/m.exec(stdout || '')
  return { status: match ? match[1] : '', detail: match && match[2] ? match[2].trim() : '' }
}

function firstLine(text) {
  const line = (text || '').split(/\r?\n/).find((l) => l.trim() !== '')
  return line ? line.trim() : ''
}

// A failing CLI prints its progress before the reason, so the first line is
// often a banner: prefer the line that says what went wrong.
function reasonLine(text) {
  const line = (text || '').split(/\r?\n/).find((l) => /^\s*ERROR:/.test(l))
  return line ? line.trim().replace(/^ERROR:\s*/, '') : firstLine(text)
}

function errorMessage(err) {
  return String(err && err.message ? err.message : err)
}

function clock(date) {
  const hh = String(date.getHours()).padStart(2, '0')
  const mm = String(date.getMinutes()).padStart(2, '0')
  return hh + ':' + mm
}

function setState(status, detail) {
  state.status = status
  state.detail = detail || ''
  state.checkedAt = new Date()
}

function animating() {
  return state.busy || state.status === 'unknown'
}

// The band's line: one short phrase, with Claude Code's spinner while a check
// or a sync has not answered yet.
function label() {
  if (state.busy) return FRAMES[frame] + ' intelligence: syncing'
  switch (state.status) {
    case 'ok':
      return 'intelligence: ✓ synced'
    case 'stale':
      return 'intelligence: sync needed'
    case 'missing-cli':
      return 'intelligence: CLI not found'
    case 'old-cli':
      return 'intelligence: update the CLI'
    case 'error':
      return 'intelligence: check failed'
    default:
      return FRAMES[frame] + ' intelligence: checking'
  }
}

// The full sentence: the /intelligence reply, and the status line where no
// band draws. Claude Code prefixes a status line with the plugin's name.
function statusText() {
  if (state.busy) return 'syncing…'
  const at = state.checkedAt ? ' · ' + clock(state.checkedAt) : ''
  switch (state.status) {
    case 'ok':
      return 'up to date' + at
    case 'stale':
      return 'sync needed — run /intelligence sync' + at
    case 'missing-cli':
      return 'CLI not found on PATH'
    case 'old-cli':
      return 'the intelligence CLI on PATH is older than this project — run: intelligence upgrade'
    case 'error':
      return 'check failed: ' + state.detail + at
    default:
      return 'checking…'
  }
}

// Every state change redraws the band above the prompt; the spinner turns only
// while something is pending.
function show($) {
  if (animating() && !ticker) {
    ticker = $.clock.every(FRAME_MS, () => {
      frame = (frame + 1) % FRAMES.length
      $.ui.invalidate('ui.render')
    })
  } else if (!animating() && ticker) {
    ticker.cancel()
    ticker = null
  }
  $.ui.status(band ? undefined : statusText())
  $.ui.invalidate('ui.render')
}

// Ask again soon after a command that held the project lock; the verdict
// shown meanwhile is the last one, never a guess.
function retrySoon($) {
  if (retry) return
  retry = $.clock.after(RETRY_MS, () => {
    retry = null
    check($)
  })
}

async function check($) {
  if (state.busy) return
  if (pendingCheck) return pendingCheck
  pendingCheck = runCheck($).finally(() => {
    pendingCheck = null
  })
  return pendingCheck
}

async function runCheck($) {
  let result
  let cwd = ''
  try {
    // The project root, not the shell's cwd: a session started in a
    // subdirectory still checks the project the plugin was rendered for.
    cwd = await $.session.root()
    result = await $.process.run(['intelligence', 'sync', '--check'], { cwd, timeoutMs: CHECK_TIMEOUT_MS })
  } catch (err) {
    // The call rejects when the program cannot start or outlives its
    // timeout; the result arrives whatever the exit code otherwise.
    const message = errorMessage(err)
    if (/failed to start/i.test(message)) setState('missing-cli', message)
    else if (await lockHeld($, cwd)) retrySoon($)
    else setState('error', message)
    show($)
    return
  }
  const parsed = parseStatus(result.stdout)
  // An older CLI renders this project with its own engine, so its verdict
  // says nothing about what this project's CLI would write, and its sync
  // would drop this plugin: say so instead of offering one.
  if (CLI_BEHIND.test(result.stderr || '')) setState('old-cli', reasonLine(result.stderr))
  // Exit 0 is up to date and 2 is `out-of-date`, the only verdicts sync
  // --check gives; anything else is the CLI refusing to answer.
  else if (result.exitCode === 0) setState('ok', parsed.detail)
  else if (result.exitCode === 2) setState('stale', parsed.detail || 'sync needed')
  // Another holder of the project lock — someone's sync, or another
  // session's check — is not a fault: the last verdict stays, and the check
  // asks again shortly instead of queueing ahead of a waiting sync.
  else if (LOCK_REFUSAL.test(result.stderr || '')) retrySoon($)
  else setState('error', parsed.detail || reasonLine(result.stderr) || 'exit ' + result.exitCode)
  show($)
}

// A check cut off at its timeout behind another command, or still finishing
// on its own, leaves the project lock in place: that is a command still
// running, not a failed check. The process the timeout abandoned keeps running.
async function lockHeld($, root) {
  if (!root) return false
  try {
    return await $.fs.exists(root + '/.intelligence/sync.lock')
  } catch {
    return false
  }
}

async function runSync($) {
  if (state.busy) return
  if (state.status === 'old-cli') {
    $.ui.toast('update the intelligence CLI first: intelligence upgrade')
    return 'not run: ' + statusText()
  }
  state.busy = true
  show($)
  let outcome
  let cwd = ''
  try {
    // A check of ours still running holds the project lock; the CLI would
    // wait for it too, but waiting here keeps its late answer from landing
    // after the sync's own.
    if (pendingCheck) await pendingCheck
    cwd = await $.session.root()
    const result = await $.process.run(['intelligence', 'sync', '--compact'], { cwd, timeoutMs: SYNC_TIMEOUT_MS })
    if (result.exitCode === 0) {
      outcome = 'sync finished'
    } else {
      const reason = reasonLine(result.stderr) || parseStatus(result.stdout).detail || 'exit ' + result.exitCode
      outcome = 'sync failed: ' + reason
    }
  } catch (err) {
    // A sync past its timeout, which includes waiting for a check, keeps
    // running and holding the lock: it has not failed yet.
    if (!/failed to start/i.test(errorMessage(err)) && (await lockHeld($, cwd))) {
      outcome = 'sync is still running; the status updates when it ends'
    } else {
      outcome = 'sync could not run: ' + errorMessage(err)
    }
  }
  // The check, not the sync's own exit code, decides what the status shows:
  // it is the same judgement the next timer tick would make. Until it answers
  // the status is `checking`, so the band never offers `Sync now` again for
  // the verdict the sync just replaced.
  state.status = 'unknown'
  state.detail = ''
  state.busy = false
  show($)
  $.ui.toast(outcome)
  await check($)
  return outcome
}

export function register(on) {
  on('session.start', async ($, e, next) => {
    band = (await $.session.surfaces()).some((s) => s === 'terminal' || s === 'desktop')
    // The label shows at once, turning, while a cold first check can take
    // minutes.
    show($)
    // Neither the first check nor the timer is awaited: the session must
    // never wait on the CLI.
    check($)
    $.clock.every(CHECK_EVERY_MS, () => check($))
    // Registered last and guarded: a taken name throws, and a hook that
    // throws is skipped from that line on.
    try {
      await $.command.register({
        name: 'intelligence',
        description: 'Show Intelligence sync status or run sync',
        argumentHint: '[sync|check]',
        immediate: true,
      })
    } catch (err) {
      $.ui.log('/intelligence not registered: ' + errorMessage(err), { to: 'debug' })
    }
    return next(e)
  })

  on('command.run', { command: 'intelligence' }, async ($, e) => {
    const args = (e.args || '').trim()
    if (args === 'sync') {
      if (state.busy) return { text: 'a sync started from here is still running' }
      const outcome = await runSync($)
      return { text: outcome + ' — ' + statusText() }
    }
    if (args === 'check') {
      await check($)
      return { text: statusText() }
    }
    if (args === '') {
      const detail = state.detail && state.status !== 'ok' ? ' (' + state.detail + ')' : ''
      return { text: statusText() + detail }
    }
    return { text: 'usage: /intelligence [sync|check]' }
  })

  // The band above the prompt, where Claude Code draws nothing of its own,
  // carries the status while there is something to wait for or act on, and
  // is gone while the project is up to date.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (state.status === 'ok' && !state.busy) return next(e)
    const { Box, Text, Button } = $.ui.resolve(e)
    const color = state.status === 'error' || state.status === 'old-cli' ? 'red' : state.status === 'stale' ? 'yellow' : undefined
    const children = [Text({ color, dimColor: animating(), children: [label()] })]
    // A digit hotkey on the band also fires from an empty prompt, typed and
    // left for a moment; a letter would need the band focused first. Plain,
    // because only a plain button shows its hotkey in the terminal.
    if (state.status === 'stale' && !state.busy) {
      children.push(Button({ key: 'sync', label: 'Sync now', hotkey: '1', plain: true, onPress: () => runSync($) }))
    }
    return Box({ flexDirection: 'row', columnGap: 2, children })
  })
}
