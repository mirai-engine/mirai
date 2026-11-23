// The views for members: stacks, proposals and their review, the
// organization and the server's status. Every write is signed by the
// person's passkey (passkey.js).
import {el, html, mount} from './dom.js'
import {api, app, refreshProjects, refreshSession, roleIn} from './api.js'
import {addThisNode, land, makeProject, write} from './passkey.js'
import {diffLoad, diffSection, filesReview, forgetProject, loadProject, projectCrumbs, projectHead, projectPage} from './views.js'
import {
    action, ago, avatar, badge, cell, confirmDialog, copyField, diffModeSwitch, diffView, empty, fileDiff, hash, href, icon, loaded,
    markdown, meter, navigate, once, person, plural, setPage, short, size, skeleton, technical, toast,
} from './ui.js'

// --- Stacks ---

export function Stacks({params}) {
    return projectPage(params.project, 'stacks', p => api(`/api/projects/${p.id}/stacks`), (p, d) => d.stacks.length === 0
        ? empty('No work in progress', 'When someone publishes changes from their computer that have not landed yet, their stack shows here.')
        : html`<div class="intro quiet">Work in progress on each computer: the changes above what landed.</div>
        <ul class="stack-cards">${d.stacks.map(s => html`<li class="surface">
            <header class="stack-head">${avatar(s.handle, s.user)}<div><strong>${s.handle}</strong><span class="quiet">${icon('laptop')}${s.device_name || 'a computer'} · ${icon('branch')}${s.bookmark}</span></div>
                <span class="toolbar-end quiet">${ago(s.time)}</span></header>
            ${s.changes.length === 0 ? html`<p class="quiet pad">Nothing above what landed.</p>` : html`<ol class="change-list compact">${s.changes.map(c => html`<li class="change-row">
                ${avatar(c.author_name || s.handle, c.author || s.user)}
                <div class="change-main"><a class="change-title" href=${`/p/${p.id}/change/${c.revision}`}>${c.summary || 'No description'}</a>
                    <span class="quiet">${c.author_name || s.handle}${c.written ? [' · ', ago(c.written)] : null}</span></div>
            </li>`)}</ol>`}
        </li>`)}</ul>`, {title: 'Stacks'})
}

// --- Proposals ---

const PROPOSAL_ICON = {open: 'branch', closed: 'x-circle', landed: 'check-circle'}

export function Proposals({params, query}) {
    const show = query.status || 'open'
    return projectPage(params.project, 'proposals', p => api(`/api/projects/${p.id}/proposals`), (p, d) => {
        const by = status => d.proposals.filter(x => x.status === status)
        const list = by(show)
        return html`<div class="segmented tabs-like" role="tablist">${['open', 'landed', 'closed'].map(status =>
            html`<a role="tab" href=${href(`/p/${p.id}/proposals`, {status: status === 'open' ? undefined : status})} class=${status === show ? 'active' : null}
                aria-selected=${status === show ? 'true' : 'false'}>${icon(PROPOSAL_ICON[status])}<span>${status[0].toUpperCase() + status.slice(1)}</span><span class="count">${by(status).length}</span></a>`)}</div>
        ${list.length === 0 ? empty(show === 'open' ? 'No open proposals' : `No ${show} proposals`, show === 'open' ? 'Open one from your computer with mirai kai proposal open <target>, or from the Kai tab of the editor.' : null)
            : html`<ul class="surface proposal-list">${list.map(x => html`<li>
                <span class=${`proposal-icon ${x.status}`}>${icon(PROPOSAL_ICON[x.status])}</span>
                <div class="change-main"><a class="change-title" href=${`/proposal/${x.id}`}>${x.title || 'Untitled proposal'}</a>
                    <span class="quiet">into <code>${x.target}</code> · opened by ${x.opener_name || 'someone'}</span></div>
                <span class="proposal-counts tabular">${x.approvals ? html`<span title=${plural(x.approvals, 'approval')}>${icon('check')}${x.approvals}</span>` : null}
                    ${x.comments ? html`<span title=${plural(x.comments, 'comment')}>${icon('comment')}${x.comments}</span>` : null}</span>
            </li>`)}</ul>`}`
    }, {title: 'Proposals'})
}

// A form to write a comment in; send(text) posts it, cancel closes it.
function composer(label, send, cancel, button = 'Comment') {
    const submit = action(async event => {
        const form = event.target
        const text = form.elements.text.value
        if (!text.trim()) throw new Error('write something first')
        await send(text)
        form.reset()
    })
    return html`<form class="composer" @submit=${submit}>
        <textarea name="text" rows="3" placeholder=${label} aria-label=${label}></textarea>
        <div class="composer-foot"><span class="quiet small-text">${icon('code')}Markdown works · signed with your passkey</span>
            <div class="actions">
                ${cancel ? html`<button type="button" class="ghost small" @click=${cancel}>Cancel</button>` : null}
                <button type="submit" class="primary small">${button}</button>
            </div></div>
    </form>`
}

const VERDICT_TEXT = {approve: 'Approved', changes: 'Requested changes', withdraw: 'Withdrew their verdict'}
const VERDICT_ICON = {approve: 'check-circle', changes: 'x-circle', withdraw: 'dot'}
const CHECK_ICON = {passed: 'check-circle', failed: 'x-circle', pending: 'dot'}

function where(c) {
    if (!c.path) return ''
    return c.anchor.kind === 'lines' ? `${c.path}:${c.anchor.line}${c.anchor.lines > 1 ? `–${c.anchor.line + c.anchor.lines - 1}` : ''}` : c.path
}

// The comments a thread starts from: those that answer none still shown.
function roots(list, all) {
    const ids = new Set(all.map(c => c.id))
    return list.filter(c => !c.reply_to || !ids.has(c.reply_to))
}

const WHOLE = -1

export function Proposal({params}) {
    const id = params.proposal
    // What the person is doing on the page, kept across draws: the change of
    // the stack shown (WHOLE for all of it), the comment replied to, the lines
    // picked and unfolded in each file, and every composer, so its text survives a reload.
    let selected = 0
    let replying = ''
    const picks = new Map()
    const unfolded = new Map()
    const composers = new Map()
    const cells = new Map()
    const kept = (key, make) => composers.get(key) ?? composers.set(key, make()).get(key)

    const page = loaded(async () => {
        const x = await api(`/api/proposals/${id}`)
        return {x, project: await loadProject(x.project).get()}
    }, ({x, project}) => {
        setPage({title: x.title || 'Proposal', crumbs: [...projectCrumbs(project), {label: 'Proposals', href: `/p/${project.id}/proposals`}, {label: x.title || 'Proposal'}]})
        if (selected !== WHOLE) selected = Math.min(selected, Math.max(0, x.stack.length - 1))
        const general = roots(x.comments.filter(c => !c.change && !c.outdated), x.comments)
        const outdated = roots(x.comments.filter(c => c.outdated), x.comments)
        return html`<div class="proposal">
            ${projectHead(project, 'proposals')}
            <div class="project-body">
                <header class="proposal-head">
                    <h2 class="title">${x.title || 'Untitled proposal'}</h2>
                    <div class="byline">${statusBadge(x.status)}${person(x.opener_name, x.opener)}
                        <span class="quiet">wants to land ${plural(x.stack.length, 'change')} into <code>${x.target}</code></span></div>
                </header>
                <div class="split">
                    <div class="main-column">
                        ${x.text ? html`<article class="surface pad">${markdown(x.text)}</article>` : null}
                        <section class="conversation">
                            <h3>Conversation <span class="count">${general.length}</span></h3>
                            ${general.length ? general.map(c => thread(c, x.comments)) : html`<p class="quiet">No comments on the proposal as a whole yet.</p>`}
                            ${x.status === 'open' ? kept('proposal', () => composer('Leave a comment on the whole proposal', text => comment({}, text))) : null}
                        </section>
                    </div>
                    <aside class="side-column">${reviewers(x)}${checks(x)}${closing(x)}</aside>
                </div>
                <section class="stack-section">
                    <div class="section-head"><h2>Changes <span class="count">${x.stack.length}</span></h2>${diffModeSwitch()}</div>
                    ${x.stack.length === 0 ? empty('No changes yet', 'The proposal has no stack to review yet.') : [
                        html`<nav class="stack-steps" aria-label="Changes of the stack">
                            ${x.stack.length > 1 ? html`<button type="button" class=${selected === WHOLE ? 'active' : null} aria-pressed=${selected === WHOLE ? 'true' : 'false'} @click=${() => select(WHOLE)}>
                                ${icon('stack')}<span class="label">Whole stack</span></button>` : null}
                            ${x.stack.map((s, i) => html`<button type="button" class=${i === selected ? 'active' : null} aria-pressed=${i === selected ? 'true' : 'false'} @click=${() => select(i)}>
                                <span class="step tabular">${i + 1}</span><span class="label">${s.summary || short(s.change)}</span>${commentCount(x, s)}</button>`)}
                        </nav>`,
                        selected === WHOLE ? wholeStack(x) : stackChange(x, x.stack[selected]),
                    ]}
                </section>
                ${outdated.length ? html`<section class="conversation"><h3>Outdated comments</h3><p class="quiet">Their lines changed since they were written.</p>${outdated.map(c => thread(c, x.comments))}</section>` : null}
            </div>
            ${reviewBar(x, project)}
        </div>`
    }, {skeleton: 'page'})

    const reload = () => page.reload()
    const act = async (entry, prompt) => {
        await write({log: id, ...entry}, prompt)
        await reload()
    }
    const comment = async (on, text) => {
        await act({type: 'proposal_comment', text, change: on.change, path: on.path, anchor: on.anchor}, {text: 'Sign your comment'})
        toast('Comment posted')
    }
    const reply = async (c, text) => {
        const on = c.outdated || !c.change ? {} : {change: c.change, path: c.path, anchor: {kind: c.anchor.kind, line: c.anchor.line, lines: c.anchor.lines}}
        composers.delete(`reply:${c.id}`)
        replying = ''
        await act({type: 'proposal_comment', text, reply_to: c.id, ...on}, {text: 'Sign your reply'})
        toast('Reply posted')
    }
    const select = i => {
        selected = i
        page.draw()
    }
    const openReply = c => {
        replying = c
        page.draw()
        page.node.querySelector(`[data-reply="${c}"] textarea`)?.focus()
    }

    function statusBadge(status) {
        return html`<span class=${`badge status ${status}`}>${icon(PROPOSAL_ICON[status])}${status[0].toUpperCase() + status.slice(1)}</span>`
    }

    // A comment and its replies.
    function thread(c, all) {
        const replies = all.filter(r => r.reply_to === c.id)
        const writing = replying === c.id
            ? html`<div data-reply=${c.id}>${kept(`reply:${c.id}`, () => composer('Reply', text => reply(c, text), () => openReply(''), 'Reply'))}</div>`
            : html`<button type="button" class="link small" @click=${() => openReply(c.id)}>Reply</button>`
        return html`<article class=${c.outdated ? 'comment outdated' : 'comment'}>
            ${avatar(c.author_name || '?', c.author)}
            <div class="comment-body">
                <header class="comment-head"><strong>${c.author_name || 'Someone'}</strong>${ago(c.time)}
                    ${c.outdated ? [badge('outdated', 'warn'), html`<code class="quiet">${where(c)}</code>`] : null}</header>
                <div class="comment-text">${markdown(c.text)}</div>
                ${writing}
                ${replies.length ? html`<div class="replies">${replies.map(r => thread(r, all))}</div>` : null}
            </div>
        </article>`
    }

    function commentCount(x, s) {
        const n = x.comments.filter(c => c.change === s.change && !c.outdated).length
        return n ? html`<span class="comments" title=${plural(n, 'comment')}>${icon('comment')}${n}</span>` : null
    }

    function reviewers(x) {
        const need = x.policy?.approvals ?? 0
        return html`<section class="side-block">
            <h3 class="side-title">Reviewers</h3>
            ${need ? html`<p class="requirement tabular">${x.approvals >= need ? icon('check-circle') : icon('dot')}${x.approvals} of ${need} approval${need === 1 ? '' : 's'} needed</p>` : null}
            ${x.verdicts.length === 0 ? html`<p class="quiet">No reviews yet.</p>` : html`<ul class="plain-list">${x.verdicts.map(v => html`<li class=${`verdict ${v.verdict}`}>
                ${avatar(v.name || '?', v.user)}<div><strong>${v.name || 'Someone'}</strong><span class="verdict-text">${icon(VERDICT_ICON[v.verdict])}${VERDICT_TEXT[v.verdict]}</span>
                ${v.current ? null : html`<span class="quiet small-text">on an earlier revision</span>`}</div>
            </li>`)}</ul>`}
        </section>`
    }

    function checks(x) {
        const required = x.policy?.checks ?? []
        const names = [...new Set([...required, ...x.checks.map(c => c.name)])]
        if (names.length === 0) return null
        return html`<section class="side-block"><h3 class="side-title">Checks</h3><ul class="plain-list">${names.map(name => {
            const c = x.checks.find(k => k.name === name)
            const state = c?.state ?? 'missing'
            return html`<li class=${`check ${state}`}>${icon(CHECK_ICON[state] ?? 'dot')}<span>${name}</span>
                ${required.includes(name) ? html`<span class="quiet small-text">required</span>` : null}${badge(state === 'missing' ? 'not run' : state, state)}</li>`
        })}</ul></section>`
    }

    function closing(x) {
        const set = (type, done) => action(() => act({type}, {text: type === 'proposal_close' ? 'Close the proposal' : 'Reopen the proposal'}), done)
        if (x.status === 'open') return html`<button type="button" class="ghost wide" @click=${set('proposal_close', 'Proposal closed')}>${icon('x-circle')}Close proposal</button>`
        if (x.status === 'closed') return html`<button type="button" class="wide" @click=${set('proposal_reopen', 'Proposal reopened')}>Reopen proposal</button>`
        return null
    }

    // The sticky bar of what a reviewer does: approve, ask for changes, land.
    function reviewBar(x, project) {
        if (x.status === 'landed') return html`<div class="review-bar landed">${icon('check-circle')}<strong>Landed into <code>${x.target}</code></strong></div>`
        if (x.status === 'closed') return html`<div class="review-bar closed">${icon('x-circle')}<strong>This proposal is closed</strong></div>`
        const mine = x.verdicts.find(v => v.user === app.session?.user && v.current)
        const give = (verdict, done) => action(() => act({type: 'proposal_verdict', verdict, revision: x.revision},
            {text: verdict === 'approve' ? 'Approve the final revision' : verdict === 'changes' ? 'Request changes' : 'Withdraw your verdict'}), done)
        const landIt = action(async () => {
            const steps = x.landing ? ['mark the proposal landed: the target moved already'] : [`move ${x.target} to the final revision of the proposal`, 'mark the proposal landed']
            const ok = await confirmDialog({title: `Land into ${x.target}`, text: `Your passkey confirms ${steps.length === 1 ? 'one step' : 'two steps'}, one prompt each:`, steps, confirm: 'Land proposal'})
            if (!ok) return
            forgetProject(project.id)
            const fresh = await api(`/api/projects/${project.id}`)
            await land(x, fresh)
            forgetProject(project.id)
            await reload()
            toast(`Landed into ${x.target}`)
        })
        const ready = !x.blocked
        return html`<div class=${`review-bar ${ready ? 'ready' : 'blocked'}`}>
            <div class="review-state">${ready ? icon('check-circle') : icon('alert')}
                <div><strong>${x.landing ? 'Landing started: finish it' : ready ? 'Ready to land' : 'Not ready to land'}</strong>
                    ${ready ? html`<span>${x.policy ? 'Every rule of the target is met.' : 'The target has no review rules.'}</span>` : html`<span>${x.blocked.text}</span>`}</div></div>
            <div class="actions">
                ${mine && mine.verdict !== 'withdraw' ? html`<button type="button" class="ghost small" @click=${give('withdraw', 'Verdict withdrawn')}>Withdraw</button>` : null}
                <button type="button" class=${mine?.verdict === 'changes' ? 'active-changes' : null} @click=${give('changes', 'Changes requested')}>${icon('x-circle')}Request changes</button>
                <button type="button" class=${mine?.verdict === 'approve' ? 'active-approve' : null} @click=${give('approve', 'Approved')}>${icon('check-circle')}Approve</button>
                ${x.can_land ? html`<button type="button" class="primary" ?disabled=${!ready} title=${ready ? 'Land the proposal on its target' : x.blocked.text} @click=${landIt}>${icon('rocket')}${x.landing ? 'Finish landing' : 'Land proposal'}</button>` : null}
            </div>
        </div>`
    }

    // One change of the stack: its description and the diff of each file.
    function stackChange(x, item) {
        return loaded(() => once(cells, `change:${item.revision}`, () => api(`/api/projects/${x.project}/changes/${item.revision}`)), c => [
            c.description.includes('\n') ? html`<div class="surface pad change-text">${markdown(c.description.split('\n').slice(1).join('\n').trim())}</div>` : null,
            c.files.length === 0 ? empty('No files changed') : filesReview({files: c.files, key: `${x.id}:${item.revision}`, section: (f, sink) => stackFile(x, item, c.parents[0], f, sink)}),
        ]).node
    }

    // The whole stack as one diff: from the parent of its first change to its last.
    function wholeStack(x) {
        const top = x.stack[x.stack.length - 1].revision
        return loaded(() => once(cells, `whole:${top}`, async () => {
            const changes = await Promise.all(x.stack.map(s => once(cells, `change:${s.revision}`, () => api(`/api/projects/${x.project}/changes/${s.revision}`)).get()))
            const base = changes[0].parents[0]
            const files = new Map()
            for (const c of changes) for (const f of c.files) {
                const had = files.get(f.path)
                files.set(f.path, {path: f.path, status: had ? had.status === 'added' && f.status !== 'removed' ? 'added' : f.status === 'removed' && had.status === 'added' ? null : f.status === 'removed' ? 'removed' : 'modified' : f.status})
            }
            return {base, files: [...files.values()].filter(f => f.status).sort((a, b) => a.path.localeCompare(b.path))}
        }), w => w.files.length === 0 ? empty('No files changed') : filesReview({
            files: w.files, key: `${x.id}:whole:${top}`,
            extra: html`<p class="notice">${icon('stack')}<span>Every change of the stack together. Pick one change above to comment on its lines.</span></p>`,
            section: (f, sink) => diffSection(f, sink, {load: () => once(cells, `diff:${w.base}:${top}:${f.path}`, () => w.base ? fileDiff(x.project, w.base, top, f.path) : fileDiff(x.project, '', top, f.path))}),
        })).node
    }

    // A file of a change of the stack with its comments, where the + of a
    // line opens a composer on it (shift for a range). It draws itself alone.
    function stackFile(x, item, parent, file, sink) {
        const key = `${item.change}:${file.path}`
        const pick = picks.get(key) ?? picks.set(key, {line: 0, lines: 0, file: false}).get(key)
        const open = unfolded.get(key) ?? unfolded.set(key, new Set()).get(key)
        const target = href(`/p/${x.project}/diff`, {from: parent, to: item.revision, path: file.path})
        const send = text => {
            const anchor = pick.file ? {kind: 'file'} : {kind: 'lines', line: pick.line, lines: pick.lines}
            Object.assign(pick, {line: 0, lines: 0, file: false})
            return comment({change: item.change, path: file.path, anchor}, text)
        }
        let redraw = () => {}
        const clear = () => {
            Object.assign(pick, {line: 0, lines: 0, file: false})
            redraw()
        }
        // The composer outlives the section, so what it calls must too.
        const writer = () => kept(`pick:${key}`, () => composer('Comment on the lines picked', send, clear))
        const onFile = () => {
            Object.assign(pick, {line: 0, lines: 0, file: true})
            redraw()
        }
        const mine = roots(x.comments.filter(c => c.change === item.change && c.path === file.path && !c.outdated), x.comments)
        const n = mine.length
        return diffSection(file, sink, {
            load: () => once(cells, `diff:${parent}:${item.revision}:${file.path}`, () => diffLoad({id: x.project}, parent, item.revision, file.path)),
            links: [n ? html`<span class="comments" title=${plural(n, 'comment')}>${icon('comment')}${n}</span>` : null,
                html`<button type="button" class="button small ghost" @click=${onFile}>${icon('comment')}Comment on file</button>`,
                html`<a class="button small ghost" href=${target}>Open</a>`],
            body: (d, draw) => {
                redraw = draw
                const choose = (line, event) => {
                    if (event.shiftKey && pick.line) {
                        const first = Math.min(pick.line, line), last = Math.max(pick.line + pick.lines - 1, line)
                        Object.assign(pick, {line: first, lines: last - first + 1, file: false})
                    } else {
                        Object.assign(pick, {line, lines: 1, file: false})
                    }
                    draw()
                    requestAnimationFrame(() => document.querySelector(`[data-pick="${CSS.escape(key)}"] textarea`)?.focus())
                }
                const last = c => c.anchor.line + Math.max(1, c.anchor.lines) - 1
                const onLines = mine.filter(c => c.anchor.kind === 'lines')
                const keep = new Set(onLines.flatMap(c => Array.from({length: Math.max(1, c.anchor.lines)}, (_, k) => c.anchor.line + k)))
                const end = pick.line + pick.lines - 1
                for (let k = pick.line; pick.line && k <= end; k++) keep.add(k)
                const after = line => {
                    const here = onLines.filter(c => last(c) === line).map(c => thread(c, x.comments))
                    if (pick.line && line === end) here.push(html`<div class="picked-for" data-pick=${key}>
                        <p class="quiet small-text">Comment on ${pick.lines > 1 ? `lines ${pick.line}–${end}` : `line ${end}`}</p>${writer()}</div>`)
                    return here.length ? html`<div class="inline-comments">${here}</div>` : null
                }
                return [
                    mine.filter(c => c.anchor.kind !== 'lines').map(c => html`<div class="pad file-comment">${thread(c, x.comments)}</div>`),
                    pick.file ? html`<div class="pad"><p class="quiet small-text">Comment on ${file.path}</p>${writer()}</div>` : null,
                    diffView(d, {pick: x.status === 'open' ? choose : null, after, keep, open, selected: pick.line ? pick : null}),
                ]
            },
        })
    }

    return page.node
}

// --- Organization ---

const ROLES = ['reader', 'writer', 'admin']
const ROLE_TEXT = {reader: 'Reads the projects', writer: 'Writes, reviews and lands', admin: 'Manages members and projects', owner: 'Owns the organization'}
const MODE_TEXT = {relay: 'Relays connections', seed: 'Keeps a copy for the team', ddc: 'Keeps the build cache'}

export function Org({params}) {
    const id = params.org
    const page = loaded(async () => {
        const [members, ddc] = await Promise.all([api(`/api/orgs/${id}/members`), api(`/api/orgs/${id}/ddc`).catch(() => null), refreshSession()])
        return {members, ddc}
    }, ({members: m, ddc}) => {
        const role = roleIn(id)
        const admin = role === 'admin' || role === 'owner'
        const mine = app.session?.orgs.find(o => o.org === id)
        const projects = (app.projects ?? []).filter(p => p.org === id)
        setPage({title: m.name || 'Organization', crumbs: [{label: m.name || 'Organization', href: `/org/${id}`}]})
        return html`<div class="page">
            <header class="profile">${avatar(m.name || '?', m.org, true)}
                <div><h1>${m.name || 'Organization'}</h1>
                    <p class="quiet">${plural(m.members.length, 'member')} · ${plural(projects.length, 'project')} · you are ${role === 'admin' || role === 'owner' ? 'an' : 'a'} ${role || 'visitor'}</p></div>
            </header>
            ${mine?.hosted ? hosting(mine, admin) : null}
            <section class="section">
                <div class="section-head"><h2>Projects</h2></div>
                ${projects.length === 0 ? empty('No projects yet', admin ? 'A project starts empty here; its files come from your computer.' : 'An admin of the organization makes its projects.') : html`<ul class="surface plain-rows">${projects.map(p => html`<li>
                    <a href=${`/p/${p.id}`}>${avatar(p.name || '?', p.id)}<strong>${p.name || short(p.id)}</strong></a>${p.public ? badge('public', 'neutral') : html`<span class="badge private">${icon('lock')}Private</span>`}</li>`)}</ul>`}
                ${admin && app.session?.passkey ? html`<form class="inline-form new-project" @submit=${newProject}>
                    <input name="name" class="grow" placeholder="New project's name" aria-label="Project name" maxlength="64" autocomplete="off">
                    <label class="checkbox"><input type="checkbox" name="public"> Anyone can read it</label>
                    <button type="submit" class="primary">${icon('plus')}Create project</button>
                </form>` : null}
            </section>
            <section class="section">
                <div class="section-head"><h2>Members <span class="count">${m.members.length}</span></h2></div>
                <ul class="surface member-list">${m.members.map(x => member(x, admin, m.owner))}</ul>
                ${admin ? html`<div class="card-panel add-member">
                    <h3>${icon('users')}Add a member</h3>
                    <p class="quiet">Ask them to sign in here, open <strong>Account</strong> and copy their user ID, then paste it below.</p>
                    <form class="inline-form" @submit=${add}>
                        <input name="user" class="grow mono" placeholder="Their user ID (64 characters)" aria-label="User ID" autocomplete="off" spellcheck="false">
                        <select name="role" aria-label="Role">${ROLES.map(r => html`<option value=${r} ?selected=${r === 'writer'}>${r[0].toUpperCase() + r.slice(1)}</option>`)}</select>
                        <button type="submit" class="primary">Add member</button>
                    </form>
                </div>` : null}
            </section>
            <section class="section">
                <div class="section-head"><h2>Servers</h2></div>
                <p class="quiet">Always-on machines that keep the organization for its members.</p>
                ${m.nodes.length === 0 ? html`<p class="quiet">No server keeps this organization yet: your computers sync among themselves.</p>` : html`<ul class="surface plain-rows">${m.nodes.map(n => html`<li>
                    ${icon('server')}<div><strong>${n.key === app.node.device ? 'This server' : `Server ${short(n.key)}`}</strong>
                    <span class="quiet">${n.modes.map(x => MODE_TEXT[x] ?? x).join(' · ')}</span></div></li>`)}</ul>`}
            </section>
            ${ddc && !mine?.hosted ? buildCache(ddc) : null}
            ${technical([['Organization ID', m.org], ['Owner', m.owner]])}
        </div>`
    }, {skeleton: 'page'})
    const newProject = action(async event => {
        const name = event.target.elements.name.value.trim()
        if (!name) throw new Error("give the project a name: 1 to 64 characters")
        const ok = await confirmDialog({title: `Create ${name}`, text: 'Your passkey signs two things, one prompt each:', steps: ['the new project', 'that it belongs to this organization']})
        if (!ok) return
        const made = await makeProject(id, name, event.target.elements.public.checked)
        toast(`${name} is ready: publish its files from your computer`)
        navigate(`/p/${made}`)
    })
    const serve = action(async () => {
        await addThisNode(id)
        await page.reload()
    }, 'This server now keeps the organization')

    // What this server keeps of an org it hosts, and how a computer works on it.
    function hosting(o, admin) {
        return html`<section class="card-panel">
            <div class="panel-head"><h2>${icon('server')}Kept on this server</h2>${meter(o.bytes, o.quota, 'Storage used')}</div>
            ${o.full ? html`<div class="notice warn">${icon('alert')}<p>The storage for this organization is full: the server takes nothing more it publishes, while your computers still sync among themselves. Move the organization to a server of your own: run mirai kai serve on a machine you keep and pair it with mirai kai pair offer node --org ${id}.</p></div>` : null}
            ${o.served ? null : html`<div class="notice warn">${icon('alert')}<div><strong>Your computers cannot find this server yet</strong>
                <p>The organization does not name it. Add it so its members reach it.</p>
                ${admin && app.session?.passkey ? html`<div class="actions"><button type="button" class="primary small" @click=${serve}>Add this server</button></div>` : null}</div></div>`}
            <h3>Work on it from your computer</h3>
            <p class="quiet">On a computer linked to your account, this command takes the organization; then mirai kai init &lt;project&gt; --project &lt;folder&gt; makes a folder a workspace of one of its projects.</p>
            ${copyField(`mirai kai web join ${app.node.origin}`, {label: 'Command to run on your computer'})}
        </section>`
    }
    const act = async (entry, prompt) => {
        await write({log: id, ...entry}, prompt)
        await page.reload()
    }
    const add = action(event => act({type: 'member_add', user: event.target.elements.user.value.trim(), role: event.target.elements.role.value}, {text: 'Add the member'}), 'Member added')

    function member(x, admin, owner) {
        const isOwner = x.role === 'owner' || x.user === owner
        const devices = (x.devices || []).filter(d => !d.revoked)
        const passkeys = (x.passkeys || []).filter(k => !k.revoked).length
        const setRole = action(async event => {
            const value = event.currentTarget.closest('li').querySelector('select').value
            await act({type: 'role_set', user: x.user, role: value}, {text: `Make ${x.name || 'them'} ${value === 'admin' ? 'an' : 'a'} ${value}`})
        }, 'Role saved')
        const remove = action(async () => {
            const ok = await confirmDialog({title: `Remove ${x.name || 'this member'}?`, text: 'They lose access to the private projects of the organization. What they signed before stays.', confirm: 'Remove', tone: 'danger'})
            if (ok) await act({type: 'member_remove', user: x.user}, {text: `Remove ${x.name || 'the member'}`})
        })
        const choose = event => {
            event.target.closest('li').querySelector('.set-role').hidden = event.target.value === x.role
        }
        return html`<li class="member">
            ${avatar(x.name || '?', x.user)}
            <div class="member-main">
                <strong>${x.name || 'Unknown member'}${x.user === app.session?.user ? html`<span class="quiet"> (you)</span>` : null}</strong>
                <span class="quiet member-devices">${devices.length ? devices.map(d => html`<span class="chip">${icon('laptop')}${d.name && d.name !== short(d.key) ? d.name : 'Computer'}</span>`) : html`<span>No computer linked</span>`}
                    ${passkeys ? html`<span class="chip">${icon('key')}${plural(passkeys, 'passkey')}</span>` : null}</span>
                ${technical([['User ID', x.user], ...devices.map(d => [`Device ${d.name || ''}`.trim(), d.key])])}
            </div>
            <div class="member-role">
                ${admin && !isOwner ? [html`<select aria-label=${`Role of ${x.name || 'the member'}`} @change=${choose}>${ROLES.map(r => html`<option value=${r} ?selected=${r === x.role}>${r[0].toUpperCase() + r.slice(1)}</option>`)}</select>`,
                    html`<button type="button" class="small primary set-role" hidden @click=${setRole}>Save</button>`,
                    html`<button type="button" class="icon-button danger" title="Remove from the organization" aria-label=${`Remove ${x.name || 'the member'}`} @click=${remove}>${icon('cross')}</button>`]
                    : html`<span class="role" title=${ROLE_TEXT[x.role] ?? ''}>${badge(isOwner ? 'owner' : x.role, 'neutral')}</span>`}
            </div>
        </li>`
    }
    return page.node
}

// The build cache a server keeps for an org, in words.
function buildCache(d) {
    const rows = [['Cached results', d.keys], ['Results kept here', d.whole], ['Results missing here', d.missing],
        ['Results that differ between builds', d.nondeterministic], ['Lookups answered', d.lookups_found], ['Lookups missed', d.lookups_missing]]
    return html`<details class="section build-cache">
        <summary><h2>Build cache</h2><span class="quiet">${d.quota ? meter(d.bytes, d.quota, 'Build cache used') : size(d.bytes)}</span></summary>
        <p class="quiet">What this server keeps of your builds, so a computer that cooks the same input takes the result instead of cooking it again.</p>
        <dl class="facts">${rows.map(([k, v]) => [html`<dt>${k}</dt>`, html`<dd class="tabular">${Number(v).toLocaleString()}</dd>`])}</dl>
        ${d.nondeterministic ? html`<p class="notice warn">${icon('alert')}<span>Some inputs gave different results on different computers: their cook is not deterministic.</span></p>` : null}
    </details>`
}

// --- Server status ---

// Figures as tiles, for operators.
function stats(pairs) {
    return html`<dl class="stats">${pairs.map(([k, v]) => html`<div><dt>${k}</dt><dd class="tabular">${typeof v === 'number' ? v.toLocaleString() : String(v)}</dd></div>`)}</dl>`
}

export function NodeStats() {
    setPage({title: 'Server status', crumbs: [{label: 'Server status'}]})
    const n = app.node
    return html`<div class="page">
        <header class="page-head"><h1>Server status</h1>
            <p class="lead">What this server runs and who it talks to. ${n.modes.map(m => MODE_TEXT[m] ?? m).join(' · ')}.</p></header>
        ${!app.session ? empty('Sign in to see the server', 'Its status is for members of the organizations it serves.', html`<a class="button primary" href="/signin">Sign in</a>`)
        : loaded(() => api('/api/node/stats'), s => [
            s.orgs.filter(o => o.behind > 0 || o.unfound > 0).map(o => o.behind > 0
                ? html`<div class="notice warn">${icon('alert')}<p>Organization ${hash(o.org)} is behind: ${plural(o.behind, 'update')} its computers announced have not arrived yet, and changes that need them wait.</p></div>`
                : html`<div class="notice">${icon('dot')}<p>Organization ${hash(o.org)} gave up on ${plural(o.unfound, 'update')} that never arrived.</p></div>`),
            html`<section class="section"><div class="section-head"><h2>Connected computers <span class="count">${s.peers.length}</span></h2></div>${s.peers.length === 0 ? html`<p class="quiet">No computer is connected now.</p>` : html`<div class="surface scroll"><table class="grid">
                <thead><tr><th>Organization</th><th>Computer</th><th>As</th><th>Path</th></tr></thead>
                <tbody>${s.peers.map(p => html`<tr><td>${hash(p.org)}</td><td>${hash(p.dh)}</td><td>${p.node ? 'server' : p.class}</td><td>${p.rung}</td></tr>`)}</tbody>
            </table></div>`}</section>`,
            html`<section class="section"><div class="section-head"><h2>Relay</h2></div>${stats([['Computers', s.relay.devices], ['Packets forwarded', s.relay.forwarded], ['Packets dropped', s.relay.dropped]])}</section>`,
            html`<section class="section"><div class="section-head"><h2>Storage</h2></div>${stats([['Size', s.store.bytes === undefined ? 'unknown' : size(s.store.bytes)], ['Packs', s.store.packs ?? 'unknown']])}</section>`,
            html`<section class="section"><div class="section-head"><h2>Web traffic</h2></div>${stats([['Requests', s.hub.requests], ['Refused', s.hub.refused], ['Connections', s.hub.connections], ['Sessions', s.hub.sessions]])}</section>`,
            technical([['Server key', n.device], ['Domain', n.rp_id]]),
        ], {skeleton: 'page'}).node}
    </div>`
}
