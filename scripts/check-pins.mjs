#!/usr/bin/env node
// Enforces the invariant the Dockerfile relies on: nothing enters the image
// unpinned, and every pin is one Renovate can actually see.
//
// This exists because the invariant was quietly broken for five months. The
// herdr ARG carried a `# renovate:` comment since #6, but Renovate's built-in
// dockerfile manager only reads FROM lines, so nothing was tracking it and the
// bump in #8 had to be typed by hand. A pin nobody updates is worse than no
// pin at all - same staleness, now frozen in git behind a comment claiming
// otherwise. Rule 3 below is the one that would have caught that.
//
// Run it by hand with `node scripts/check-pins.mjs`; CI runs it on every PR.
// `check()` is exported as a pure function so check-pins.test.mjs can feed it
// broken Dockerfiles without touching disk.
//
// Pins come in two shapes: `ARG <NAME>_VERSION=` for anything that tags its
// releases, and `ARG <NAME>_REF=` for a repo that does not - oh-my-zsh ships no
// tags at all, so a commit is the only thing there is to pin. Both are held to
// the same rules; only the datasource and the Renovate manager differ.
//
// Escape hatch: put `# pin-check: ignore - <reason>` on the line directly
// above a RUN to exempt that block from the fetch rules. Used for artifacts
// that genuinely have no version, like an apt keyring.

import { readFileSync } from 'node:fs'

// Their next word is a value, not a package. An option missing from this list
// has its value reported as an unpinned package, so a gap fails loud rather
// than letting something through.
const NPM_OPTIONS_WITH_VALUE = new Set([
  '-C', '--prefix', '--cache', '--registry', '--tag', '--location', '--omit', '--include',
])

export function check(src, renovateJson) {
  const problems = []
  const problem = (line, what, fix) => problems.push({ line, what, fix })
  const lines = src.split('\n')

  // --- parse into instructions, joining backslash continuations -------------
  // Each block keeps the physical line it starts on, so a failure points at
  // something you can actually open.
  const blocks = []
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]
    if (!line.trim() || line.trim().startsWith('#')) continue
    const start = i
    let text = line
    while (text.trimEnd().endsWith('\\') && i + 1 < lines.length) {
      const next = lines[++i]
      // Docker drops comment lines inside a continuation before it parses the
      // command, so a comment between two escaped lines is not an argument.
      // Joining it in would read every word of the prose as a package name.
      if (next.trim().startsWith('#')) continue
      text = text.trimEnd().slice(0, -1) + ' ' + next
    }
    // The comment directly above the block, if any - carries the ignore marker.
    let above = ''
    for (let j = start - 1; j >= 0; j--) {
      if (!lines[j].trim()) continue
      if (lines[j].trim().startsWith('#')) above = lines[j]
      break
    }
    blocks.push({ start: start + 1, text: text.replace(/\s+/g, ' ').trim(), above })
  }

  const nextCode = (from) => {
    for (let j = from; j < lines.length; j++) if (lines[j].trim()) return lines[j]
    return ''
  }
  const prevCode = (from) => {
    for (let j = from; j >= 0; j--) if (lines[j].trim()) return lines[j]
    return ''
  }

  // --- rule 1: every version ARG is annotated ------------------------------
  const declared = []
  lines.forEach((line, i) => {
    const m = /^ARG (\w+_(?:VERSION|REF))=/.exec(line)
    if (!m) return
    declared.push(m[1])
    if (!/^# renovate:/.test(prevCode(i - 1))) {
      problem(i + 1, `${m[1]} has no '# renovate:' annotation directly above it`,
        'add: # renovate: datasource=<ds> depName=<name>  (copy the shape from the ARGs above)')
    }
  })

  // --- rule 2: no annotation left dangling ---------------------------------
  lines.forEach((line, i) => {
    if (!/^# renovate:/.test(line)) return
    if (!/^ARG \w+_(?:VERSION|REF)=/.test(nextCode(i + 1))) {
      problem(i + 1, "'# renovate:' annotation is not followed by an ARG <NAME>_VERSION= or <NAME>_REF=",
        'move the annotation directly above its ARG, or delete it')
    }
  })

  // --- rule 3: renovate.json's own regex sees every pin --------------------
  // The real test. An annotation that is subtly malformed - wrong key order, a
  // stray double space - reads fine to a human and is silently invisible to
  // Renovate. Applying the configured regex is the only way to know it matched.
  const managers = (renovateJson.customManagers ?? []).filter((m) => m.customType === 'regex')
  if (managers.length === 0) {
    problem(1, 'renovate.json has no regex customManager, so no ARG pin is tracked',
      'restore the customManagers block')
  } else {
    // Every regex manager is applied, not just the first: version pins and
    // digest pins need separate managers, and a pin counts as tracked if any
    // one of them matches it.
    const seen = new Set()
    for (const pattern of managers.flatMap((m) => m.matchStrings)) {
      for (const m of src.matchAll(new RegExp(pattern, 'g'))) {
        const name = /ARG (\w+_(?:VERSION|REF))=/.exec(m[0])
        if (name) seen.add(name[1])
      }
    }
    for (const name of declared) {
      if (seen.has(name)) continue
      const at = lines.findIndex((l) => l.startsWith(`ARG ${name}=`)) + 1
      problem(at, `${name} is not matched by the regex in renovate.json - Renovate will never bump it`,
        'check the annotation against matchStrings: key order and single spaces matter')
    }
  }

  // --- rules 4-7: how things are fetched -----------------------------------
  // An image is pinned by tag *and* digest: the tag is what Renovate reads and
  // a human can, the digest is what makes it the same bytes on every build --
  // a tag can be re-pushed. The tag is looked for after the last `/`, so a
  // registry port (host:5000/img) does not pass for one.
  const stages = new Set()
  const checkImage = (start, kind, ref) => {
    const [nameTag, digest] = ref.split('@')
    const tag = nameTag.slice(nameTag.lastIndexOf('/') + 1).split(':')[1]
    if (!tag || tag === 'latest') {
      problem(start, `${kind} '${ref}' is untagged or :latest`,
        'pin an explicit version tag so Renovate can track it')
    } else if (!/^sha256:[0-9a-f]{64}$/.test(digest ?? '')) {
      problem(start, `${kind} '${ref}' has no digest`,
        'append @sha256:<index digest> (docker buildx imagetools inspect <ref>)')
    }
  }

  for (const { start, text, above } of blocks) {
    if (/^FROM /.test(text)) {
      const [, ref = '', as, stage] = text.split(/\s+/)
      checkImage(start, 'base image', ref)
      if (/^as$/i.test(as ?? '') && stage) stages.add(stage)
      continue
    }
    if (/^COPY /.test(text)) {
      const from = /--from=(\S+)/.exec(text)?.[1]
      if (from && !stages.has(from) && !/^\d+$/.test(from)) checkImage(start, 'COPY --from image', from)
      continue
    }
    if (!/^RUN /.test(text)) continue
    const ignored = /pin-check:\s*ignore/.test(above)

    // rule 4: global npm installs carry a version
    for (const [, args] of text.matchAll(/npm (?:install|i) (.+?)(?: && | ; |$)/g)) {
      if (!/(?:^| )(?:-g|--global|--location[= ]global)(?: |$)/.test(args)) continue
      const tokens = args.split(/\s+/)
      for (const [i, token] of tokens.entries()) {
        const pkg = token.replace(/["']/g, '')
        if (!pkg || pkg.startsWith('-') || NPM_OPTIONS_WITH_VALUE.has(tokens[i - 1])) continue
        // a scoped package carries a second @; a bare one needs any @
        const versioned = pkg.startsWith('@') ? pkg.lastIndexOf('@') > 0 : pkg.includes('@')
        if (!versioned) {
          problem(start, `npm package '${pkg}' is installed without a version`,
            'pin it to an ARG: "pkg@${PKG_VERSION}", with a # renovate: datasource=npm annotation')
        }
      }
    }

    // rule 5: an apt version pin comes from an annotated ARG. Most apt
    // packages are deliberately unpinned (Debian drops superseded versions),
    // so a pin is only ever an explicit choice -- and a literal one is a
    // version Renovate cannot see.
    const apt = /apt-get install (.+?)(?: && | ; |$)/.exec(text)
    if (apt) {
      for (const token of apt[1].split(/\s+/)) {
        const pkg = token.replace(/["']/g, '')
        if (pkg.startsWith('-') || !pkg.includes('=')) continue
        if (!/\$\{?\w*VERSION/.test(pkg)) {
          problem(start, `apt package '${pkg}' is pinned to a literal version`,
            'pin it to an ARG: "pkg=${PKG_VERSION}-<rev>", with a # renovate: annotation')
        }
      }
    }

    if (ignored) continue

    // rule 6: nothing resolves "latest" at build time
    if (/releases\/latest|\/latest\/download/.test(text)) {
      problem(start, 'fetches a "latest" release URL, so the image changes without a commit',
        'pin the version in an ARG and build the URL from it')
    }

    // rule 7: every download interpolates a pinned version. Matched as a
    // command (followed by a flag or URL) rather than bare, so the `curl \
    // wget \` package names in the apt block don't count as downloads.
    if (/\b(curl|wget)\s+(-|https?:)/.test(text) && !/\$\{?\w*(?:VERSION|REF)/.test(text)) {
      problem(start, 'downloads something without interpolating a *_VERSION or *_REF',
        'pin it to an annotated ARG, or mark the block: # pin-check: ignore - <reason>')
    }
  }

  problems.sort((a, b) => a.line - b.line)
  return { problems, declared }
}

// --- CLI -------------------------------------------------------------------
if (process.argv[1] && import.meta.url.endsWith(process.argv[1].split('/').pop())) {
  const { problems, declared } = check(
    readFileSync('Dockerfile', 'utf8'),
    JSON.parse(readFileSync('renovate.json', 'utf8')),
  )
  if (problems.length === 0) {
    console.log(`✓ ${declared.length} pinned dependencies, all annotated and tracked by Renovate`)
    process.exit(0)
  }
  console.error(`✗ ${problems.length} pinning problem(s) in Dockerfile:\n`)
  for (const p of problems) {
    console.error(`  Dockerfile:${p.line}  ${p.what}`)
    console.error(`  ${' '.repeat(String(p.line).length + 11)}  → ${p.fix}\n`)
  }
  process.exit(1)
}
