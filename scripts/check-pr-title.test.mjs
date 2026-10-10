#!/usr/bin/env node
// Tests for check-pr-title.mjs. The same rule as check-pins.test.mjs: a guard
// that cannot fail is false confidence, so every rule gets a title that breaks
// it in a plausible way -- plus the titles this repo and its bots actually
// produce, which have to keep passing.
//
// Run with `node scripts/check-pr-title.test.mjs`; CI runs it alongside the
// check.

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { allowedTypes, check } from './check-pr-title.mjs'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const CONFIG = JSON.parse(readFileSync(join(root, 'release-please-config.json'), 'utf8'))
const TYPES = allowedTypes(CONFIG)

let failed = 0

const accepts = (title) => {
  const problems = check(title, TYPES)
  if (problems.length === 0) return console.log(`  ✓ accepts ${JSON.stringify(title)}`)
  failed++
  console.error(`  ✗ accepts ${JSON.stringify(title)}`)
  console.error(`      unexpected: ${problems.map((p) => p.what).join(' | ')}`)
}

const rejects = (title, expect) => {
  const problems = check(title, TYPES)
  if (problems.some((p) => p.what.includes(expect))) {
    return console.log(`  ✓ rejects ${JSON.stringify(title)}`)
  }
  failed++
  console.error(`  ✗ rejects ${JSON.stringify(title)}`)
  console.error(`      expected a problem containing: ${expect}`)
  console.error(`      got: ${problems.map((p) => p.what).join(' | ') || '(none)'}`)
}

console.log('check-pr-title:')

// The config has to carry types at all, or every case below passes vacuously.
if (TYPES.length === 0) {
  failed++
  console.error('  ✗ release-please-config.json declares no changelog-sections')
} else {
  console.log(`  ✓ ${TYPES.length} types read from release-please-config.json: ${TYPES.join(', ')}`)
}

// The titles the repo and its bots really produce.
accepts('feat: ✨ support JetBrains remote development')
accepts('fix: 🔒 quote the values spliced into the ntfy hook')
accepts('build(deps): ⬆️ update image toolchain')
accepts('chore(deps): update github actions')
accepts('chore(main): release 0.1.0')
accepts('feat!: drop SYS_ADMIN and /dev/fuse')
accepts('refactor(entrypoint)!: write settings.json under a umask')

// The convention this repo is moving away from, and the one mistake every
// commit on main before v0.1.0 makes. It gets its own message.
rejects('🔒 fix: quote the values spliced into the ntfy hook',
  'does not start with a conventional-commit type')
rejects('⬆️ chore: bump herdr to 0.9.1',
  'does not start with a conventional-commit type')

// Renovate's titles before `semanticCommits: enabled`, and GitHub's default
// revert title -- all typeless, all silently dropped by the parser.
rejects('Update image toolchain', 'does not start with a conventional-commit type')
rejects('Pin dependencies', 'does not start with a conventional-commit type')
rejects('Revert "feat: ✨ support JetBrains remote development"',
  'does not start with a conventional-commit type')

rejects('', 'the title is empty')
rejects('fix quote the hook values', 'not a conventional commit')
rejects('fix:no space after the colon', 'not a conventional commit')
rejects('feature: ✨ add the ch helper', 'is not a type this repo releases on')
rejects('wip: still thinking', 'is not a type this repo releases on')
rejects('fix:', 'not a conventional commit')
rejects('fix: ', 'the subject is empty')
rejects('fix: 🔒 quote the hook values.', 'ends with a full stop')

// Every type the table in CONTRIBUTING.md names has to be one the checker
// accepts, or the docs assert a convention the gate rejects.
const contributing = readFileSync(join(root, 'CONTRIBUTING.md'), 'utf8')
const commitsSection = contributing.slice(contributing.indexOf('## Commits'))
const examples = (/```\n([\s\S]*?)```/.exec(commitsSection)?.[1] ?? '')
  .split('\n')
  .filter((l) => l.trim())
if (examples.length === 0) {
  failed++
  console.error("  ✗ CONTRIBUTING.md's Commits section has no example block to check")
}
for (const example of examples) accepts(example)

const documented = [...commitsSection.matchAll(/^\| `(\w+)`((?: `\w+`)*) \|/gm)]
  .flatMap((m) => [m[1], ...m[2].split('`').filter((s) => /^\w+$/.test(s))])
for (const type of documented) {
  if (TYPES.includes(type)) continue
  failed++
  console.error(`  ✗ CONTRIBUTING.md documents type '${type}', which the checker rejects`)
}
if (documented.length) console.log(`  ✓ ${documented.length} types documented in CONTRIBUTING.md are all accepted`)

console.log(failed === 0 ? '\nall passed' : `\n${failed} failed`)
process.exit(failed === 0 ? 0 : 1)
