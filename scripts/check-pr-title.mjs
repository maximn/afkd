#!/usr/bin/env node
// Lints a pull request title as a conventional commit.
//
// The repo squash-merges, so the PR title *is* the commit message on main, and
// main's history is the record of what shipped: every merge is deployed. A
// typed title says at a glance whether a commit changed the image (`build`),
// the box's behaviour (`feat`, `fix`) or neither (`ci`, `docs`, `chore`).
//
// The type goes first and the gitmoji after the colon (`fix: 🔒 ...`). Every
// commit on main before this check was gitmoji-first (`🔒 fix: ...`), which
// conventional-commit parsers read as typeless.
//
// Run it by hand with `PR_TITLE='fix: 🔒 ...' node scripts/check-pr-title.mjs`;
// CI runs it on every PR, including when only the title is edited.

export const TYPES = ['feat', 'fix', 'perf', 'build', 'revert', 'docs', 'style', 'refactor', 'test', 'ci', 'chore']

export function check(title, types = TYPES) {
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
        "'fix: 🔒 ...', not '🔒 fix: ...' -- a conventional-commit parser " +
        'reads anything before the type as a commit with no type at all',
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
      what: `'${type}' is not a type this repo uses`,
      fix: `use one of: ${list}` +
        (type === 'feature' ? " -- 'feat', not 'feature'" : ''),
    })
  }
  if (subject.trim() === '') {
    problems.push({ what: 'the subject is empty', fix: 'say what changed after the colon' })
  }
  if (/\.$/.test(subject)) {
    problems.push({ what: 'the subject ends with a full stop', fix: 'drop it -- it lands in the history verbatim' })
  }

  return problems
}

// --- CLI -------------------------------------------------------------------
if (process.argv[1] && import.meta.url.endsWith(process.argv[1].split('/').pop())) {
  // Read from the environment, never from argv or an interpolated run: block.
  // A PR title is attacker-controlled text, and `${{ ... }}` splicing it into
  // a shell command is the template-injection hole #25 and #29 both closed.
  const title = process.env.PR_TITLE
  const problems = check(title)
  if (problems.length === 0) {
    console.log(`✓ ${JSON.stringify(title)} parses as a conventional commit`)
    process.exit(0)
  }
  console.error(`✗ pull request title: ${JSON.stringify(title ?? null)}\n`)
  for (const p of problems) {
    console.error(`  ${p.what}`)
    console.error(`  → ${p.fix}\n`)
  }
  console.error('The title becomes the commit on main.')
  console.error('See "Commits" in CONTRIBUTING.md.')
  process.exit(1)
}
