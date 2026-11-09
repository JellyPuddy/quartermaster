export const meta = {
  name: 'delegate-build',
  description: 'Build, review and integrate a delegate-build plan: tasks launch as their prerequisites are reviewed',
  phases: [
    { title: 'Explore', detail: 'opt-in: one read-only explorer maps the code into exploration.md' },
    { title: 'Build', detail: 'one builder per task, continued when it hands back at its budget' },
    { title: 'Review', detail: 'a fresh reviewer per built task' },
    { title: 'Integrate', detail: 'one integrator over every reviewed task' },
    { title: 'Gaps', detail: 'check proposed integration gaps; build those the integrator found' },
    { title: 'Spec', detail: 'one read-only agent checks the integrated branch against every plan decision' },
    { title: 'Build review', detail: 'one read-only agent reviews the whole integrated diff, beside the spec pass' },
  ],
}

// args: {
//   helpersDir:  absolute path of this skill's helpers/ directory
//   planFile:    absolute path of the plan: the numbered decisions every agent works from; its
//                directory is the run directory
//   boardUrl:    the status board's URL (rows already seeded, one per task id)
//   answersDir:  absolute directory where the orchestrator writes answers to blocked questions
//   base:        required starting ref for tasks without prerequisites: a sha resolved once by the
//                orchestrator after its one `git fetch origin`, or a local branch (follow-up runs)
//   model:       optional model for every agent
//   maxContinuations: extra builders per task after a budget handback (default 2)
//   integration: how the integrator lands the branches (e.g. 'one branch, commits cherry-picked in order')
//   integrationChecks: cross-task checks the integrator runs (e.g. 'the full suite')
//   tasks: [{ id, title, brief, dependsOn: [ids] }]   brief: the task with the decisions it rests on
//   integrateId: board row id of the integrator (default 'integrate'), seeded like a task row.
//                With one reviewed task and no integrationChecks (the light path) the integrator
//                and the spec and whole-build review passes are skipped and that task's reviewed branch is the result.
//   explore:     optional: what to map. One read-only explorer writes <run dir>/exploration.md
//                before any builder starts, and every later prompt points at it.
//   exploreId:   board row id of the explorer (default 'explore'), seeded like a task row when
//                explore is set.
//   queueFile:   optional absolute path of a JSON array of extra tasks (same shape) the orchestrator
//                may append to mid-run; read after each task settles. Omitted = no queue checks.
//   maxSpawns:   integration gaps built automatically per run, mid-run and post-integration
//                combined (default 2); proposals past it are reported as follow-ups
// }

if (!args.base) throw new Error('args.base is required: git fetch origin once, then pass git rev-parse origin/main')
const BASE = args.base
const RUN_DIR = args.planFile.replace(/\/[^/]*$/, '')
const MAX_CONT = args.maxContinuations ?? 2
const MAX_SPAWNS = args.maxSpawns ?? 2
const INTEGRATE_ID = args.integrateId || 'integrate'
const EXPLORE_ID = args.exploreId || 'explore'
const OPTS = { isolation: 'worktree', ...(args.model ? { model: args.model } : {}) }
const H = args.helpersDir

const COMMIT = { type: 'object', properties: { sha: { type: 'string' }, subject: { type: 'string' } }, required: ['sha', 'subject'] }
const FOLLOW_UPS = { type: 'array', description: 'proposed tasks beyond yours, per Follow-ups in BRIEF_RULES.md; usually empty', items: { type: 'object', properties: {
  title: { type: 'string' },
  why: { type: 'string' },
  decision: { type: 'string', description: 'the plan decision number(s) it serves, or "none"' },
  brief: { type: 'string', description: 'a self-contained draft brief: the task and the decisions it rests on' },
  dependsOn: { type: 'array', items: { type: 'string' }, description: 'task ids whose code it needs' },
  kind: { type: 'string', enum: ['gap', 'follow-up'] },
}, required: ['title', 'why', 'decision', 'brief', 'dependsOn', 'kind'] } }
const BUILDER = {
  type: 'object',
  properties: {
    finished: { type: 'boolean', description: 'false when you handed back at your tool-call budget with work left' },
    branch: { type: 'string', description: 'your worktree branch (git branch --show-current)' },
    start: { type: 'string', description: 'sha your work starts from: HEAD right after setting up your starting point' },
    commits: { type: 'array', items: COMMIT, description: 'oldest first' },
    green: { type: 'boolean', description: 'verification green on your last commit' },
    verdict: { type: 'string', description: 'one line, e.g. "12 tests added, green"; no command output' },
    removedGuards: { type: 'array', items: { type: 'object', properties: { what: { type: 'string' }, why: { type: 'string' } }, required: ['what', 'why'] } },
    remaining: { type: 'string', description: 'when not finished: what is left, and what the next builder needs to know' },
    followUps: FOLLOW_UPS,
  },
  required: ['finished', 'branch', 'start', 'commits', 'green', 'verdict', 'removedGuards', 'remaining', 'followUps'],
}
const REVIEWER = {
  type: 'object',
  properties: {
    branch: { type: 'string', description: 'your worktree branch' },
    commits: { type: 'array', items: COMMIT, description: 'every commit in start..HEAD, oldest first' },
    findings: { type: 'array', items: { type: 'object', properties: {
      finding: { type: 'string' }, resolution: { type: 'string', enum: ['fixed', 'deliberate'] }, reason: { type: 'string' },
      decision: { type: 'string', description: 'for deliberate: the plan decision number behind it' },
    }, required: ['finding', 'resolution', 'reason'] } },
    conflicts: { type: 'array', description: 'plan decisions that contradict the repo\'s coding standards; usually empty', items: { type: 'object', properties: {
      decision: { type: 'string' }, standard: { type: 'string', description: 'the rule and where it lives' }, handling: { type: 'string', description: 'what you did meanwhile' },
    }, required: ['decision', 'standard', 'handling'] } },
    green: { type: 'boolean' },
    verdict: { type: 'string' },
    followUps: { ...FOLLOW_UPS, description: "the builder's proposals you endorse (edited as needed) plus your own; the rest are dropped" },
  },
  required: ['branch', 'commits', 'findings', 'conflicts', 'green', 'verdict', 'followUps'],
}
const INTEGRATOR = {
  type: 'object',
  properties: {
    branch: { type: 'string' },
    tip: { type: 'string', description: 'git rev-parse HEAD of your branch as you hand back' },
    commits: { type: 'array', items: COMMIT },
    green: { type: 'boolean' },
    verdict: { type: 'string', description: 'one line, naming any wiring commit you added yourself' },
    layers: { type: 'array', description: 'when the landing convention names several branches (a stack): per branch, bottom first, the sha its tip goes to; otherwise empty', items: { type: 'object', properties: {
      name: { type: 'string' }, sha: { type: 'string' },
    }, required: ['name', 'sha'] } },
    keep: { type: 'array', description: 'gitignored outputs the plan wants kept (renders, screenshots); usually empty', items: { type: 'object', properties: {
      path: { type: 'string', description: 'absolute path in your worktree' }, regenerate: { type: 'string', description: 'the command that recreates it' },
    }, required: ['path', 'regenerate'] } },
    followUps: FOLLOW_UPS,
  },
  required: ['branch', 'tip', 'commits', 'green', 'verdict', 'layers', 'keep', 'followUps'],
}

const commitList = cs => cs.map(c => `${c.sha.slice(0, 9)} ${c.subject}`).join('; ')

// Opt-in: one shared map of the code, so parallel builders in the same unfamiliar area skip
// re-exploring it. Read-only on the repo; it runs in the main checkout, no worktree.
const explored = args.explore ? await agent(`You map the code for a delegate-build run before its builders start, so they and their reviewers share one map instead of each exploring alone. What to map: ${args.explore}

Read the plan's decisions in ${args.planFile}. The run's tasks:
${args.tasks.map(t => `- ${t.id}: ${t.title}\n  ${t.brief}`).join('\n')}

Report progress on the board as ${H}/STATUS_ADDENDUM.md describes, with board ${args.boardUrl}, task id "${EXPLORE_ID}", start status "running" and final status "done"; never block: an open question goes into exploration.md as one.

Write ${RUN_DIR}/exploration.md: the entry points; per task, the key files and functions it will touch (path:line); the conventions and gotchas you found. Change nothing in the repo; that file and your board row are your only writes. Reply with one line once it is written.`, { label: 'explore', phase: 'Explore', ...(args.model ? { model: args.model } : {}) }) : null
if (args.explore && !explored) log(`explorer died: agents explore on their own; set board row ${EXPLORE_ID} to blocked`)

const common = (taskId, start, final, row) => `
Before anything else, read and follow ${H}/BRIEF_RULES.md (your worktree, commits, waiting, budget, blocked questions, follow-ups) and read the plan's decisions in ${args.planFile}.${explored ? ` Then read ${RUN_DIR}/exploration.md, a map of the code made for this run, before exploring yourself; add nothing to it.` : ''}
${taskId ? `Report progress on the board as ${H}/STATUS_ADDENDUM.md describes, with board ${args.boardUrl}, task id "${taskId}", start status "${start}" and final status "${final}".${row ? ` Your row may not exist yet: create it as its New row section describes, with title ${JSON.stringify(row.title)}, note ${JSON.stringify(row.note)}, dependsOn ${JSON.stringify(row.dependsOn)} and proposer row "${row.proposer}".` : ''}
` : ''}Blocked questions: answers directory ${args.answersDir}, your question id "${taskId || 'integration'}".`

const VERIFY = `Verification: run the project's tests, typecheck and lint for what you changed, and fix failures. Hand back a verdict ("12 tests added, green"), not command output. Run as well any verification the repo's CLAUDE.md requires for what you touched.`

function startSteps(refs) {
  const [first, ...rest] = refs
  return `Your worktree starts on whatever the main checkout had checked out, so first point it at your starting point: \`git reset --hard ${first}\` (a fresh worktree has nothing to lose)${rest.map(r => `, then \`git merge --no-edit ${r}\``).join('')}. Record \`git rev-parse HEAD\` right after that as your start.`
}

function builderPrompt(task, refs, prev, n) {
  const cont = prev ? `
You continue an earlier builder of this task, which handed back at its tool-call budget. Its handback:
- commits so far: ${commitList(prev.commits) || 'none'}
- left to do: ${prev.remaining}
- guards it removed: ${prev.removedGuards.map(g => `${g.what} (${g.why})`).join('; ') || 'none'}
Start from its branch: \`git reset --hard ${prev.branch}\`, and report its start (${prev.start}) as yours.` : `
${startSteps(refs)}`
  return `You are the builder${n ? ` (continuation ${n})` : ''} of task "${task.id}": ${task.title}.

${task.brief}
${cont}

${VERIFY}

Hand back every condition, scope, \`order\` or validation guard you removed, each with why it could go. If you reach your tool-call budget, finish the commit you are on and hand back with finished: false.
${common(task.id, 'running', 'review', task.row)}`
}

const proposalList = ps => ps.map((p, i) => `${i + 1}. [${p.kind}] ${p.title} (decision ${p.decision}; needs ${p.dependsOn.join(', ') || 'nothing'}): ${p.why}\n   Brief: ${p.brief}`).join('\n')

function reviewerPrompt(task, b, guards, proposals) {
  return `You are the reviewer of task "${task.id}": ${task.title}. The task, as its builder got it:

${task.brief}

The builder's handback: ${b.verdict}. Commits: ${commitList(b.commits)}.
Guards it removed: ${guards.map(g => `${g.what} (${g.why})`).join('; ') || 'none'}.

1. Bring its work into your worktree: \`git reset --hard ${b.branch}\` (a fresh worktree has nothing to lose). The task's own commits are \`${b.start}..HEAD\`; anything before ${b.start} is base or prerequisite work, already reviewed.
2. Check \`${b.start}..HEAD\` against the repo's standards. Use the review skills and checks the repo's CLAUDE.md (or AGENTS.md, or its instruction docs) names, pointed at the range; otherwise read its CLAUDE.md and the docs pages covering the touched code, and check the diff against their rules.
3. Check the diff against the plan, quoting the plan line for each finding: (a) a decision missing or only partly done, (b) behaviour no decision asked for (scope creep), (c) an implementation that looks wrong. Check it against each removed guard too.
4. Commit your fixes and re-run the verification. A fix that adds behaviour outside the plan gets its own commit, or becomes a follow-up; the task's commits keep only the task. Re-run a browser smoke test only when your own fix commits touch UI; otherwise the builder's smoke verdict stands. ${VERIFY}

Name every finding as fixed, or as deliberate with the plan decision number behind it in \`decision\`. Before calling local handling deliberate, look at how sibling callers of the same helper handle it. A deliberate finding with no decision behind it goes in \`followUps\` as kind follow-up instead. A plan decision that contradicts the repo's coding standards goes in \`conflicts\`, for the user to settle.

Follow-ups the builder proposed: ${proposals.length ? `\n${proposalList(proposals)}` : 'none'}.
Your \`followUps\` is the list that counts: the builder's proposals you endorse, edited as needed, plus your own, per Follow-ups in BRIEF_RULES.md. A proposal you leave out is dropped. A bug inside this task is a finding, not a follow-up.
${common(task.id, 'reviewing', 'done', task.row)}`
}

const byId = Object.fromEntries(args.tasks.map(t => [t.id, t]))
const runs = {}
const reviewedOrder = []

// One task from its starting refs: builder, continuations at the budget, then a fresh reviewer.
// followUps on the result is the reviewer's list; the builders' proposals only reach the reviewer.
async function buildAndReview(task, refs, phases = { build: 'Build', review: 'Review' }) {
  const id = task.id
  let b = null, prev = null
  const guards = [], proposals = []
  for (let n = 0; n <= MAX_CONT; n++) {
    b = await agent(builderPrompt(task, refs, prev, n), { ...OPTS, label: n ? `build:${id}#${n + 1}` : `build:${id}`, phase: phases.build, schema: BUILDER })
    if (!b) return { id, status: 'failed', reason: 'builder died' }
    if (prev) b.commits = [...prev.commits, ...b.commits]
    guards.push(...b.removedGuards)
    proposals.push(...(b.followUps || []))
    if (b.finished) break
    log(`${id}: builder handed back at its budget (${b.remaining.slice(0, 80)})`)
    prev = b
  }
  if (!b.finished) return { id, status: 'incomplete', reason: `still unfinished after ${MAX_CONT} continuations`, branch: b.branch, left: b.remaining }

  const r = await agent(reviewerPrompt(task, b, guards, proposals), { ...OPTS, label: `review:${id}`, phase: phases.review, schema: REVIEWER })
  if (!r) return { id, status: 'failed', reason: 'reviewer died', branch: b.branch }
  if (!r.green) return { id, status: 'failed', reason: `review not green: ${r.verdict}`, branch: r.branch, conflicts: r.conflicts, followUps: r.followUps }
  return { id, status: 'reviewed', branch: r.branch, start: b.start, commits: r.commits, verdict: r.verdict, findings: r.findings, conflicts: r.conflicts, removedGuards: guards, followUps: r.followUps }
}

function run(id) {
  return runs[id] ??= (async () => {
    const task = byId[id]
    if (task.dependsOn?.length) log(`${id}: queued, waiting for ${task.dependsOn.join(', ')} to be reviewed`)
    const deps = await Promise.all((task.dependsOn || []).map(run))
    const bad = deps.filter(d => d.status !== 'reviewed')
    if (bad.length) return { id, status: 'skipped', reason: `prerequisite ${bad.map(d => `${d.id} (${d.status})`).join(', ')}` }

    const r = await buildAndReview(task, deps.length ? deps.map(d => d.branch) : [BASE])
    if (r.status === 'reviewed') reviewedOrder.push(id)
    return r
  })()
}

// Proposed tasks. Only a reviewer's or an integrator's list reaches here. A proposal labelled
// gap is classified by a cheap checker, never by its proposer; only a checked gap within the
// cap is built, everything else is reported. A checker that fails or answers unclearly
// leaves a follow-up: nothing is ever built on a failure.
const followUps = []
const spawned = []
let spawns = 0
const CHECK = { type: 'object', properties: { verdict: { type: 'string', enum: ['gap', 'duplicate', 'follow-up'] }, reason: { type: 'string' } }, required: ['verdict', 'reason'] }

function report(p, proposer, reason) {
  followUps.push({ title: p.title, why: p.why, decision: p.decision, brief: p.brief, dependsOn: p.dependsOn || [], proposer, reason })
}

function checkerPrompt(p, proposer) {
  return `Classify one task proposed during a delegate-build run. Read the plan's numbered decisions in ${args.planFile}, and the Follow-ups paragraph of ${H}/BRIEF_RULES.md for what an integration gap is.

The run's tasks:
${Object.values(byId).map(t => `- ${t.id}: ${t.title}\n  ${t.brief}`).join('\n')}

The proposal, from "${proposer}":
${proposalList([p])}

Verdict "gap" when it is an integration gap that no listed task owns; "duplicate" when a listed task already owns this work; "follow-up" for anything else, including when you are unsure. Reason: one line. Read only; change nothing.`
}

async function triage(proposals, proposer, depthLimited) {
  const gaps = []
  for (const p of proposals || []) {
    if (p.kind !== 'gap') report(p, proposer, 'labelled follow-up')
    else if (depthLimited) report(p, proposer, 'depth limit')
    else if (spawns >= MAX_SPAWNS) report(p, proposer, 'cap reached')
    else gaps.push(p)
  }
  const verdicts = await parallel(gaps.map((p, i) => () =>
    agent(checkerPrompt(p, proposer), { label: `check:${proposer}#${i + 1}`, phase: 'Gaps', model: 'sonnet', effort: 'low', schema: CHECK })))
  const accepted = []
  gaps.forEach((p, i) => {
    const v = verdicts[i]
    if (v?.verdict === 'duplicate') return report(p, proposer, `checker: duplicate, ${v.reason}`)
    if (v?.verdict !== 'gap') return report(p, proposer, v?.reason ? `checker: ${v.reason}` : 'checker gave no clear verdict')
    if (spawns >= MAX_SPAWNS) return report(p, proposer, 'cap reached')
    spawns++
    accepted.push({ p, reason: v.reason })
  })
  return accepted
}

// A spawned task's board row is created by its own agents (STATUS_ADDENDUM's New row).
function gapTask(proposer, p, reason, dependsOn) {
  let n = 1
  while (byId[`${proposer}-gap-${n}`]) n++
  const id = `${proposer}-gap-${n}`
  const title = `↳ ${p.title}`
  const task = { id, title, brief: p.brief, dependsOn, spawnedBy: proposer, row: { title, note: `spawned by ${proposer}: ${reason}`, dependsOn, proposer } }
  byId[id] = task
  spawned.push({ id, proposer, reason })
  log(`gap: spawned ${id} from ${proposer} (${reason})`)
  return task
}

// Mid-run: a spawned gap joins the graph like a queued task, after its proposer. Depth 1:
// a spawned task's own gaps are reported, never built.
async function spawnGaps(r) {
  try {
    if (!r.followUps?.length) return
    if (r.status !== 'reviewed') return r.followUps.forEach(p => report(p, r.id, `proposer ${r.status}`))
    for (const { p, reason } of await triage(r.followUps, r.id, !!byId[r.id].spawnedBy)) {
      const deps = [r.id, ...p.dependsOn.filter(d => byId[d] && d !== r.id)]
      track(gapTask(r.id, p, reason, deps).id)
    }
  } catch (e) {
    log(`follow-ups of ${r.id} not handled: ${e.message}`)
  }
}

// Tasks queued mid-run: the script can't read files, so after each task settles a cheap
// agent reads the queue file and the new entries join the graph like any other task.
const QUEUE_SCHEMA = { type: 'object', properties: { tasks: { type: 'array', items: { type: 'object', properties: { id: { type: 'string' }, title: { type: 'string' }, brief: { type: 'string' }, dependsOn: { type: 'array', items: { type: 'string' } } }, required: ['id', 'title', 'brief'] } } }, required: ['tasks'] }
const pending = new Set()
const rejected = new Set()
let queueCheck = Promise.resolve()
let checks = 0

function track(id) {
  const p = run(id)
  pending.add(p)
  p.then(r => {
    pending.delete(p)
    queueCheck = queueCheck.then(() => spawnGaps(r))
    if (args.queueFile) queueCheck = queueCheck.then(checkQueue)
  })
}

async function checkQueue() {
  const q = await agent(`Read the JSON file ${args.queueFile}: an array of tasks, each {id, title, brief, dependsOn}. Return every entry unchanged as {tasks: [...]}. If the file is missing or empty, return {tasks: []}. Do nothing else.`, { label: `queue#${++checks}`, phase: 'Build', model: 'haiku', effort: 'low', schema: QUEUE_SCHEMA })
  const fresh = (q?.tasks || []).filter(t => !byId[t.id] && !rejected.has(t.id))
  const known = id => byId[id] || fresh.some(t => t.id === id)
  for (const t of fresh) {
    const unknown = (t.dependsOn || []).filter(d => !known(d))
    if (unknown.length) { rejected.add(t.id); log(`queue: ${t.id} rejected, unknown prerequisite ${unknown.join(', ')}`) }
  }
  const accepted = fresh.filter(t => !rejected.has(t.id))
  accepted.forEach(t => { byId[t.id] = t })
  accepted.forEach(t => { log(`queue: added ${t.id}`); track(t.id) })
}

args.tasks.forEach(t => track(t.id))
if (args.queueFile) queueCheck = queueCheck.then(checkQueue)
// Done only when nothing runs and no queue check started after the last one we awaited.
while (true) {
  if (pending.size) await Promise.race(pending)
  const check = queueCheck
  await check
  if (!pending.size && check === queueCheck) break
}

const results = await Promise.all(Object.keys(byId).map(run))
const res = Object.fromEntries(results.map(r => [r.id, r]))

// Prerequisites before the tasks that call them, the rest in the order they were reviewed.
const order = []
while (order.length < reviewedOrder.length) {
  const next = reviewedOrder.find(id => !order.includes(id) && (byId[id].dependsOn || []).every(d => order.includes(d)))
  order.push(next)
}
const dropped = results.filter(r => r.status !== 'reviewed')
if (dropped.length) log(`Not integrated: ${dropped.map(r => `${r.id} (${r.status})`).join(', ')}`)

const ownCommits = ts => ts.map((r, i) => `${i + 1}. ${r.id}: commits ${r.start}..${r.branch}: ${commitList(r.commits)}`).join('\n')
const KEEP = 'In `keep`, name each gitignored output the plan wants kept (renders, screenshots) with the command that regenerates it.'

// Light path: one reviewed task and no cross-task checks has nothing to integrate; its
// reviewed branch, which starts on BASE, is the result.
let integration = null
const light = order.length === 1 && !args.integrationChecks
if (light) {
  const r = res[order[0]]
  integration = { branch: r.branch, tip: r.commits.at(-1)?.sha || r.branch, commits: r.commits, green: true, verdict: 'single task: its reviewed branch is the result', layers: [], keep: [], followUps: [] }
} else if (order.length) {
  integration = await agent(`You are the integrator of this build. Combine these reviewed tasks on your own worktree branch, on top of ${BASE}, in this order (prerequisites first). Your worktree branch is the result: work on it, create no other branch, and leave every other branch as it is. Each task's own commits:
${ownCommits(order.map(id => res[id]))}

A branch built on a prerequisite contains that prerequisite's commits before its own start sha; take each task's own commits only. How to combine them: ${args.integration || 'one branch with every task\'s commits, cherry-picked in the order above'}. When that names several branches (a stack), build every layer on your one branch and return \`layers\`: per branch name, bottom first, the sha its tip goes to; the orchestrator creates the branches. Tasks built in parallel can touch the same files: resolve those conflicts. Re-run the verification after each step, since a clean merge proves nothing about the combination. ${args.integrationChecks ? `Then run: ${args.integrationChecks}.` : ''} ${KEEP}

Integration gaps (Follow-ups in BRIEF_RULES.md): wire a small one yourself, as one small commit you would be comfortable leaving unreviewed, and name that commit in your verdict. Return anything larger in \`followUps\` with kind "gap" instead of building it; it is built and reviewed after you, on your branch.
${common(INTEGRATE_ID, 'running', 'done')}`, { ...OPTS, label: 'integrate', phase: 'Integrate', schema: INTEGRATOR })
}

// Post-integration gaps: built from the integrator's tip, reviewed, then appended by a short
// second integrator step. A failure there leaves the integrated branch at its pre-gap tip.
const postResults = []
let append = null
if (integration) {
  integration.finalBranch = integration.branch
  integration.finalTip = integration.tip
  const proposals = integration.followUps || []
  delete integration.followUps
  if (!integration.green) proposals.forEach(p => report(p, INTEGRATE_ID, 'integration not green'))
  else {
    const accepted = await triage(proposals, INTEGRATE_ID, false)
    const gaps = accepted.map(({ p, reason }) => gapTask(INTEGRATE_ID, p, reason, [INTEGRATE_ID]))
    const built = await parallel(gaps.map(t => () => buildAndReview(t, [integration.branch], { build: 'Gaps', review: 'Gaps' })))
    built.forEach((r, i) => {
      r = r || { id: gaps[i].id, status: 'failed', reason: 'build died' }
      postResults.push(r)
      ;(r.followUps || []).forEach(p => report(p, r.id, p.kind === 'gap' ? 'depth limit' : 'labelled follow-up'))
    })
    const good = postResults.filter(r => r.status === 'reviewed')
    if (good.length) {
      append = await agent(`You append reviewed gap tasks to this build's integrated branch. In your worktree: \`git reset --hard ${integration.branch}\` (tip ${integration.tip}), then cherry-pick each task's own commits in this order:
${ownCommits(good)}

Your worktree branch is the result: create no other branch, and leave every other branch as it is. Re-run the verification after each pick${args.integrationChecks ? `, then run: ${args.integrationChecks}` : ''}. Fix what the combination breaks with a small commit and name it in your verdict; when it stays red, hand back green: false. Leave \`layers\` empty. ${KEEP} Leave \`followUps\` empty unless something is clearly missing; nothing you propose is built in this run.
${common(INTEGRATE_ID, 'running', 'done')}`, { ...OPTS, label: 'integrate:gaps', phase: 'Gaps', schema: INTEGRATOR })
      ;(append?.followUps || []).forEach(p => report(p, INTEGRATE_ID, p.kind === 'gap' ? 'depth limit' : 'labelled follow-up'))
      if (append?.green) {
        integration.finalBranch = append.branch
        integration.finalTip = append.tip
        integration.keep = [...integration.keep, ...append.keep]
      }
      integration.gapAppend = append ? { branch: append.branch, tip: append.tip, commits: append.commits, green: append.green, verdict: append.verdict } : { green: false, verdict: 'append step died' }
    }
  }
}

// Two read-only passes over the green integrated branch, side by side: the spec pass against the
// plan, the whole-build review against the repo's standards. Both only report, as follow-ups.
const appendGreen = !integration?.gapAppend || integration.gapAppend.green
if (integration?.green && appendGreen && !light) {
  const range = `${BASE}..${integration.finalTip}`
  const READ_ONLY = { ...(args.model ? { model: args.model } : {}), schema: { type: 'object', properties: { followUps: FOLLOW_UPS }, required: ['followUps'] } }
  const [spec, review] = await parallel([
    () => agent(`You check this build's integrated branch against its whole plan. Read every numbered decision in ${args.planFile}, then the diff \`git diff ${range}\` (and \`git log ${range}\`). For each decision, check: (a) missing or only partly done, (b) behaviour no decision asked for (scope creep), (c) an implementation that looks wrong. Read only: change nothing, commit nothing, run no tests.

Return each finding in \`followUps\` with kind "follow-up", \`decision\` its decision number ("none" for scope creep), \`why\` quoting the plan line and naming the file, \`brief\` a self-contained fix task, and \`dependsOn\` empty. An empty list means the branch meets the plan.`, { ...READ_ONLY, label: 'spec', phase: 'Spec' }),
    () => agent(`You review this build's whole integrated branch as one code review. Each task already had its own reviewer, who saw only that task's commits; you see them together: \`git diff ${range}\` and \`git log -p ${range}\`. Read the plan's decisions in ${args.planFile} first, so you can tell a deliberate choice from a miss.

Review the range with the repo's own review conventions: use the review skills and checks the repo's CLAUDE.md (or AGENTS.md, or its instruction docs) names, each pointed at the range; otherwise read its CLAUDE.md and the instruction docs covering the touched code, and check the range against their rules. Spend your attention on what a per-task reviewer could not see:
- the same logic built twice across tasks (a temporary adapter in one, the same code copied into a controller in the next);
- code one commit adds and a later commit reworks or removes, and each commit's message still matching what it does;
- naming of one concept that differs between tasks;
- each commit, and each layer of a stack, safe and green on its own;
- the shape of the final code as a whole.

First point your worktree at the tip: \`git reset --hard ${integration.finalTip}\` (a fresh worktree has nothing to lose). Then read only: change nothing, commit nothing. Return each finding in \`followUps\` with kind "follow-up", \`decision\` the plan decision it touches ("none" otherwise), \`why\` naming the files and commits, \`brief\` a self-contained fix task, and \`dependsOn\` empty. A choice a plan decision asked for is no finding. An empty list means the branch passes review.`, { ...OPTS, schema: READ_ONLY.schema, label: 'review:build', phase: 'Build review' }),
  ])
  if (spec) spec.followUps.forEach(p => report(p, 'spec', 'spec pass'))
  else log('spec pass died: the integrated branch went unchecked against the plan')
  if (review) review.followUps.forEach(p => report(p, 'review', 'whole-build review'))
  else log('whole-build review died: the integrated branch went unreviewed as a whole')
}

const tasks = [...results, ...postResults].map(({ followUps: _, ...r }) => r)
const status = Object.fromEntries(tasks.map(r => [r.id, r.status]))
for (const s of spawned) {
  s.status = status[s.id] || 'not run'
  if (byId[s.id].spawnedBy === INTEGRATE_ID && s.status === 'reviewed') s.status = append?.green ? 'integrated' : 'reviewed, not appended'
}

const notGreen = tasks.filter(r => r.status !== 'reviewed').map(r => `${r.id} ${r.status}`)
if (!integration) notGreen.push(order.length ? 'integrator died' : 'nothing integrated')
else if (!integration.green) notGreen.push('integration not green')
else if (integration.gapAppend && !integration.gapAppend.green) notGreen.push(`gap append not green: final branch left at its pre-gap tip ${integration.finalTip}`)

const conflicts = tasks.flatMap(r => (r.conflicts || []).map(c => ({ task: r.id, ...c })))

return { green: !notGreen.length, notGreen, conflicts, tasks, order, integration, spawned, followUps }
