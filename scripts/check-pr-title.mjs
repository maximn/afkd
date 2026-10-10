#!/usr/bin/env node
// Lints a pull request title as a conventional commit.
//
// The repo squash-merges, so the PR title *is* the commit message on main --
// and release-please reads those messages to decide the next version and to
// write the changelog. A title it cannot parse is a change that silently never
// ships: `@conventional-commits/parser` throws on anything before the type, so
// the commit is dropped, and a release whose every commit was dropped is not
// cut at all.
//
// That is not hypothetical here. Every commit on main before this check was
// gitmoji-first (`🔒 fix: ...`), which parses as typeless -- all twenty of
// them. The convention is now type-first with the emoji in the subject
// (`fix: 🔒 ...`), which keeps both conventions and parses.
//
// The accepted types are read from release-please-config.json rather than
// listed here, so "a type this accepts" and "a type release-please knows what
// to do with" cannot drift apart.
//
// Run it by hand with `PR_TITLE='fix: 🔒 ...' node scripts/check-pr-title.mjs`;
// CI runs it on every PR, including when only the title is edited.

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const CONFIG = 'release-please-config.json'

export function allowedTypes(config) {
  const sections = Object.values(config.packages ?? {})
    .flatMap((pkg) => pkg['changelog-sections'] ?? [])
    .concat(config['changelog-sections'] ?? [])
  return [...new Set(sections.map((s) => s.type))]
}

export function check(title, types) {
  const problems = []
  const list = types.join(', ')

  if (typeof title !== 'string' || title.trim() === '') {
    problems.push({
      what: 'the title is empty',
      fix: `write it as '<type>: <subject>', type one of: ${list}`,
    })
    return problems
  }

  // Deliberately before the shape check, so the one mistake this repo has
  // actually made gets the message that names it rather than a generic one.
  if (!/^[a-z]/.test(title)) {
    problems.push({
      what: 'the title does not start with a conventional-commit type',
      fix: 'the type comes first and the gitmoji goes after the colon: ' +
        "'fix: 🔒 ...', not '🔒 fix: ...' -- the parser release-please uses " +
        'throws on anything before the type, and the commit is dropped',
    })
    return problems
  }

  const m = /^(?<type>[a-z]+)(?:\((?<scope>[a-z0-9][a-z0-9._-]*)\))?(?<breaking>!)?: (?<subject>.*)$/
    .exec(title)
  if (!m) {
    problems.push({
      what: 'the title is not a conventional commit',
      fix: `write it as '<type>[(scope)][!]: <subject>', type one of: ${list}`,
    })
    return problems
  }

  const { type, subject } = m.groups
  if (!types.includes(type)) {
    problems.push({
      what: `'${type}' is not a type this repo releases on`,
      fix: `use one of: ${list}` +
        (type === 'feature' ? " -- 'feat', not 'feature'" : ''),
    })
  }
  if (subject.trim() === '') {
    problems.push({ what: 'the subject is empty', fix: 'say what changed after the colon' })
  }
  if (/\.$/.test(subject)) {
    problems.push({ what: 'the subject ends with a full stop', fix: 'drop it -- it lands in the changelog verbatim' })
  }

  return problems
}

// --- CLI -------------------------------------------------------------------
if (process.argv[1] && import.meta.url.endsWith(process.argv[1].split('/').pop())) {
  const root = join(dirname(fileURLToPath(import.meta.url)), '..')
  const types = allowedTypes(JSON.parse(readFileSync(join(root, CONFIG), 'utf8')))
  // Read from the environment, never from argv or an interpolated run: block.
  // A PR title is attacker-controlled text, and `${{ ... }}` splicing it into
  // a shell command is the template-injection hole #25 and #29 both closed.
  const title = process.env.PR_TITLE
  const problems = check(title, types)
  if (problems.length === 0) {
    console.log(`✓ ${JSON.stringify(title)} parses as a conventional commit`)
    process.exit(0)
  }
  console.error(`✗ pull request title: ${JSON.stringify(title ?? null)}\n`)
  for (const p of problems) {
    console.error(`  ${p.what}`)
    console.error(`  → ${p.fix}\n`)
  }
  console.error('The title becomes the commit on main, and release-please reads it.')
  console.error('See "Commits" in CONTRIBUTING.md.')
  process.exit(1)
}
