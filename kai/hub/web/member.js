// The views for members: stacks, proposals and their review, the org and
// the node. Every write is an entry signed by the user (passkey.js).
import {html, mount} from './dom.js'
import {api, app, roleIn} from './api.js'
import {write} from './passkey.js'
import {diffHead, fileRow, loadProject, person, projectHead, projectPage} from './views.js'
import {action, ago, badge, diffView, empty, fileDiff, hash, href, icon, loaded, plural, short, size} from './ui.js'

export function Stacks({params}) {
    return projectPage(params.project, 'stacks', p => api(`/api/projects/${p.id}/stacks`), (p, d) => d.stacks.length === 0
        ? empty('No stacks', 'No device has published a bookmark of this project.')
        : html`<ul class="stacks">${d.stacks.map(s => html`<li class="box">
            <header class="box-head">${icon('bookmark')}<strong>${s.label}</strong>
                <span class="toolbar-end meta">${hash(s.revision, `/p/${p.id}/change/${s.revision}`)}${ago(s.time)}</span></header>
            ${s.changes.length === 0 ? html`<p class="quiet pad">Nothing above what landed.</p>` : html`<ol class="rows">${s.changes.map(c => html`<li class="item">
                <div class="item-main"><a href=${`/p/${p.id}/change/${c.revision}`}>${c.summary || '(no description)'}</a></div>
                <div class="meta">${hash(c.change)}</div>
            </li>`)}</ol>`}
        </li>`)}</ul>`)
}

export function Proposals({params}) {
    return projectPage(params.project, 'proposals', p => api(`/api/projects/${p.id}/proposals`), (p, d) => d.proposals.length === 0
        ? empty('No proposals', 'Open one with mirai kai proposal open <target>.')
        : html`<ul class="box rows">${d.proposals.map(x => html`<li class="item">
            <div class="item-main"><a href=${`/proposal/${x.id}`}><strong>${x.title || '(no title)'}</strong></a>${badge(x.status)}</div>
            <div class="meta"><span>into <code>${x.target}</code></span><span>by ${x.opener_name || short(x.opener)}</span>
                <span>${plural(x.approvals, 'approval')}</span><span>${icon('comment')}${x.comments}</span></div>
        </li>`)}</ul>`)
}

// A form to write a comment in; send(text) posts it, cancel closes it.
function composer(label, send, cancel) {
    const submit = action(async event => {
        const form = event.target
        const text = form.elements.text.value
        if (!text.trim()) throw new Error('write something first')
        await send(text)
        form.reset()
    })
    return html`<form class="composer" @submit=${submit}>
        <textarea name="text" rows="3" placeholder=${label} aria-label=${label}></textarea>
        <div class="actions">
            ${cancel ? html`<button type="button" class="ghost" @click=${cancel}>Cancel</button>` : null}
            <button type="submit" class="primary">Comment</button>
        </div>
    </form>`
}

const VERDICT_TEXT = {approve: 'approved', changes: 'requested changes', withdraw: 'withdrew'}
const VERDICT_ICON = {approve: 'check', changes: 'cross', withdraw: 'dot'}
const CHECK_ICON = {passed: 'check', failed: 'cross', pending: 'dot'}

function where(c) {
    if (!c.path) return ''
    return c.anchor.kind === 'lines' ? `${c.path}:${c.anchor.line}${c.anchor.lines > 1 ? `-${c.anchor.line + c.anchor.lines - 1}` : ''}` : c.path
}

// The comments a thread starts from: those that answer none still shown.
function roots(list, all) {
    const ids = new Set(all.map(c => c.id))
    return list.filter(c => !c.reply_to || !ids.has(c.reply_to))
}

export function Proposal({params}) {
    const id = params.proposal
    // What the person is doing on the page, kept across draws: the change of
    // the stack shown, the comment replied to, the lines picked and unfolded
    // in each file, and every composer, so its text survives a reload.
    let selected = 0
    let replying = ''
    const picks = new Map()
    const unfolded = new Map()
    const composers = new Map()
    const redraws = new Map()
    const cache = new Map()
    const once = (key, load) => cache.get(key) ?? cache.set(key, load()).get(key)
    const kept = (key, make) => composers.get(key) ?? composers.set(key, make()).get(key)

    const page = loaded(async () => {
        const x = await api(`/api/proposals/${id}`)
        return {x, project: await once(`project`, () => loadProject(x.project))}
    }, ({x, project}) => {
        const item = x.stack[Math.min(selected, x.stack.length - 1)]
        const general = roots(x.comments.filter(c => !c.change && !c.outdated), x.comments)
        const outdated = roots(x.comments.filter(c => c.outdated), x.comments)
        return html`<div class="page proposal">
            ${projectHead(project, 'proposals')}
            <header class="page-head">
                <div class="title-row"><h2 class="title">${x.title || '(no title)'}</h2>${badge(x.status)}</div>
                <p class="meta"><span>into <code>${x.target}</code></span><span>opened by ${person(x.opener_name, x.opener)}</span><span>${plural(x.comments.length, 'comment')}</span></p>
            </header>
            <div class="split">
                <div class="main-column">
                    ${x.text ? html`<div class="box"><pre class="prose">${x.text}</pre></div>` : null}
                    <section>
                        <h3>Conversation</h3>
                        ${general.length ? general.map(c => thread(c, x.comments)) : html`<p class="quiet">No comments on the proposal as a whole yet.</p>`}
                        ${kept('proposal', () => composer('Comment on the proposal', text => comment({}, text)))}
                    </section>
                </div>
                <aside class="side-column lead">${landing(x)}${verdicts(x)}${checks(x)}${closing(x)}</aside>
            </div>
            <section class="stack-section">
                <h3>Stack <span class="count">${x.stack.length}</span></h3>
                ${x.stack.length === 0 ? empty('No stack yet') : html`<nav class="segmented" aria-label="Changes of the stack">${x.stack.map((s, i) =>
                    html`<button type="button" class=${s === item ? 'active' : null} aria-pressed=${s === item ? 'true' : 'false'} @click=${() => select(i)}>
                        <span class="step">${i + 1}</span><span class="label">${s.summary || short(s.change)}</span>${commentCount(x, s)}</button>`)}</nav>`}
                ${item ? stackChange(x, item) : null}
            </section>
            ${outdated.length ? html`<section><h3>Outdated comments</h3>${outdated.map(c => thread(c, x.comments))}</section>` : null}
        </div>`
    })

    const reload = () => page.reload()
    const act = async entry => {
        await write({log: id, ...entry})
        await reload()
    }
    const comment = (on, text) => act({type: 'proposal_comment', text, change: on.change, path: on.path, anchor: on.anchor})
    const reply = async (c, text) => {
        const on = c.outdated || !c.change ? {} : {change: c.change, path: c.path, anchor: {kind: c.anchor.kind, line: c.anchor.line, lines: c.anchor.lines}}
        composers.delete(`reply:${c.id}`)
        replying = ''
        await act({type: 'proposal_comment', text, reply_to: c.id, ...on})
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

    // A comment and its replies.
    function thread(c, all) {
        const replies = all.filter(r => r.reply_to === c.id)
        const writing = replying === c.id
            ? html`<div data-reply=${c.id}>${kept(`reply:${c.id}`, () => composer('Reply', text => reply(c, text), () => openReply('')))}</div>`
            : html`<button type="button" class="link" @click=${() => openReply(c.id)}>Reply</button>`
        return html`<article class=${c.outdated ? 'comment outdated' : 'comment'}>
            <header class="comment-head"><span class="avatar" aria-hidden="true">${(c.author_name || '?')[0].toUpperCase()}</span>
                <strong>${c.author_name || short(c.author)}</strong>${ago(c.time)}
                ${c.outdated ? [badge('outdated', 'warn'), html`<code class="quiet">${where(c)}</code>`] : null}</header>
            <p class="comment-text">${c.text}</p>
            ${writing}
            ${replies.length ? html`<div class="replies">${replies.map(r => thread(r, all))}</div>` : null}
        </article>`
    }

    function commentCount(x, s) {
        const n = x.comments.filter(c => c.change === s.change && !c.outdated).length
        return n ? html`<span class="comments" title=${plural(n, 'comment')}>${icon('comment')}${n}</span>` : null
    }

    function landing(x) {
        return x.blocked
            ? html`<div class="notice warn">${icon('alert')}<div><strong>Landing is blocked</strong><p>${x.blocked.text}</p></div></div>`
            : html`<div class="notice ok">${icon('check')}<div><strong>Ready to land</strong></div></div>`
    }

    function verdicts(x) {
        const mine = x.verdicts.find(v => v.user === app.session?.user)
        const give = verdict => action(() => act({type: 'proposal_verdict', verdict, revision: x.revision}))
        return html`<section class="panel">
            <h3>Verdicts <span class="count">${plural(x.approvals, 'approval')}</span></h3>
            ${x.verdicts.length === 0 ? html`<p class="quiet">None yet.</p>` : html`<ul class="plain">${x.verdicts.map(v => html`<li class=${`verdict ${v.verdict}`}>
                ${icon(VERDICT_ICON[v.verdict])}<span><strong>${v.name || short(v.user)}</strong> ${VERDICT_TEXT[v.verdict]} ${hash(v.revision)}</span>
                ${v.current ? null : badge('earlier stack', 'warn')}
            </li>`)}</ul>`}
            ${x.status === 'open' ? html`<div class="actions">
                <button type="button" class="primary" @click=${give('approve')}>Approve</button>
                <button type="button" @click=${give('changes')}>Request changes</button>
                ${mine && mine.verdict !== 'withdraw' ? html`<button type="button" class="link" @click=${give('withdraw')}>Withdraw my verdict</button>` : null}
            </div>` : null}
        </section>`
    }

    function checks(x) {
        if (x.checks.length === 0) return null
        return html`<section class="panel"><h3>Checks</h3><ul class="plain">${x.checks.map(c =>
            html`<li class=${`check ${c.state}`}>${icon(CHECK_ICON[c.state])}<span>${c.name}</span>${badge(c.state)}</li>`)}</ul></section>`
    }

    function closing(x) {
        const set = type => action(() => act({type}))
        if (x.status === 'open') return html`<button type="button" class="ghost wide" @click=${set('proposal_close')}>Close the proposal</button>`
        if (x.status === 'closed') return html`<button type="button" class="wide" @click=${set('proposal_reopen')}>Reopen the proposal</button>`
        return null
    }

    // One change of the stack: its description and the diff of each file.
    function stackChange(x, item) {
        return loaded(() => once(`change:${item.revision}`, () => api(`/api/projects/${x.project}/changes/${item.revision}`)), c => [
            c.description ? html`<div class="box"><pre class="prose">${c.description}</pre></div>` : null,
            c.files.length === 0 ? empty('No file changes') : c.files.map(f => stackFile(x, item, c.parents[0], f)),
        ]).node
    }

    // A file of a change of the stack with its comments, where picking line
    // numbers opens a composer on those lines. It draws itself alone.
    function stackFile(x, item, parent, file) {
        const key = `${item.change}:${file.path}`
        const pick = picks.get(key) ?? picks.set(key, {line: 0, lines: 0, file: false}).get(key)
        const open = unfolded.get(key) ?? unfolded.set(key, new Set()).get(key)
        const diff = once(`diff:${parent}:${item.revision}:${file.path}`, () => fileDiff(x.project, parent, item.revision, file.path))
        const target = href(`/p/${x.project}/diff`, {from: parent, to: item.revision, path: file.path})
        const section = html`<section class="box file-box"></section>`
        const choose = (line, event) => {
            if (event.shiftKey && pick.line) {
                const first = Math.min(pick.line, line), last = Math.max(pick.line + pick.lines - 1, line)
                Object.assign(pick, {line: first, lines: last - first + 1, file: false})
            } else {
                Object.assign(pick, {line, lines: 1, file: false})
            }
            draw()
        }
        const clear = () => {
            Object.assign(pick, {line: 0, lines: 0, file: false})
            redraws.get(key)()
        }
        const onFile = () => {
            Object.assign(pick, {line: 0, lines: 0, file: true})
            draw()
        }
        const send = text => {
            const anchor = pick.file ? {kind: 'file'} : {kind: 'lines', line: pick.line, lines: pick.lines}
            Object.assign(pick, {line: 0, lines: 0, file: false})
            return comment({change: item.change, path: file.path, anchor}, text)
        }
        // The composer outlives this section, so what it calls must too.
        const writer = () => kept(`pick:${key}`, () => composer('Comment', send, clear))
        const draw = mount(section, () => {
            const mine = roots(x.comments.filter(c => c.change === item.change && c.path === file.path && !c.outdated), x.comments)
            const last = c => c.anchor.line + Math.max(1, c.anchor.lines) - 1
            const onLines = mine.filter(c => c.anchor.kind === 'lines')
            const keep = new Set(onLines.flatMap(c => Array.from({length: Math.max(1, c.anchor.lines)}, (_, k) => c.anchor.line + k)))
            const end = pick.line + pick.lines - 1
            for (let n = pick.line; pick.line && n <= end; n++) keep.add(n)
            const after = n => {
                const here = onLines.filter(c => last(c) === n).map(c => thread(c, x.comments))
                if (pick.line && n === end) here.push(html`<div class="picked-for">
                    <p class="quiet">Comment on ${pick.lines > 1 ? `lines ${pick.line}–${end}` : `line ${end}`}</p>${writer()}</div>`)
                return here.length ? html`<div class="inline-comments">${here}</div>` : null
            }
            return [
                loaded(() => diff, d => [
                    diffHead(d, file.path, [badge(file.status), html`<button type="button" class="link" @click=${onFile}>${icon('comment')}Comment on file</button>`,
                        html`<a href=${target}>Open</a>`]),
                    mine.filter(c => c.anchor.kind !== 'lines').map(c => html`<div class="pad">${thread(c, x.comments)}</div>`),
                    pick.file ? html`<div class="pad"><p class="quiet">Comment on ${file.path}</p>${writer()}</div>` : null,
                    diffView(d, {pick: choose, after, keep, open, selected: pick.line ? pick : null}),
                ]).node,
            ]
        })
        redraws.set(key, draw)
        return section
    }

    return page.node
}

const ROLES = ['reader', 'writer', 'admin']

export function Org({params}) {
    const id = params.org
    const page = loaded(async () => {
        const [members, ddc] = await Promise.all([api(`/api/orgs/${id}/members`), api(`/api/orgs/${id}/ddc`)])
        return {members, ddc}
    }, ({members: m, ddc}) => {
        const role = roleIn(id)
        const admin = role === 'admin' || role === 'owner'
        return html`<div class="page">
            <header class="page-head"><h1>${m.name || short(m.org)}</h1>
                <p class="meta"><span>Org ${hash(m.org)}</span><span>Your role: ${role || 'none'}</span></p></header>
            <section>
                <h2>Members <span class="count">${m.members.length}</span></h2>
                <div class="box scroll"><table class="grid">
                    <thead><tr><th>Member</th><th>Role</th><th>Devices</th><th>Passkeys</th>${admin ? html`<th></th>` : null}</tr></thead>
                    <tbody>${m.members.map(x => member(x, admin))}</tbody>
                </table></div>
                ${admin ? html`<form class="inline-form" @submit=${add}>
                    <input name="user" class="grow" placeholder="User id, 64 hex" aria-label="User id" autocomplete="off" spellcheck="false">
                    <select name="role" aria-label="Role">${ROLES.map(r => html`<option ?selected=${r === 'writer'}>${r}</option>`)}</select>
                    <button type="submit" class="primary">Add member</button>
                </form>` : null}
            </section>
            <section>
                <h2>Nodes</h2>
                ${m.nodes.length === 0 ? empty('No node is listed') : html`<ul class="box rows">${m.nodes.map(n =>
                    html`<li class="item"><div class="item-main">${hash(n.key)}</div><div class="meta">${n.modes.join(', ')}</div></li>`)}</ul>`}
            </section>
            <section>
                <h2>Derived data</h2>
                ${stats([['Keys', ddc.keys], ['Records', ddc.records], ['Outputs here', ddc.whole], ['Outputs missing', ddc.missing],
                    ['Nondeterministic keys', ddc.nondeterministic], ['Lookups found', ddc.lookups_found], ['Lookups missing', ddc.lookups_missing],
                    ['Bytes', size(ddc.bytes)], ['Quota', ddc.quota ? size(ddc.quota) : 'none']])}
            </section>
        </div>`
    })
    const act = async entry => {
        await write({log: id, ...entry})
        await page.reload()
    }
    const add = action(event => act({type: 'member_add', user: event.target.elements.user.value.trim(), role: event.target.elements.role.value}))

    function member(x, admin) {
        const owner = x.role === 'owner'
        const choose = event => event.target.closest('tr').querySelector('.set-role').disabled = event.target.value === x.role
        return html`<tr>
            <td>${person(x.name, x.user)}</td>
            <td>${admin && !owner ? html`<select aria-label="Role" @change=${choose}>${ROLES.map(r => html`<option ?selected=${r === x.role}>${r}</option>`)}</select>` : badge(x.role, 'neutral')}</td>
            <td>${(x.devices || []).map(d => html`<div class=${d.revoked ? 'revoked' : null}>${d.name === short(d.key) ? null : `${d.name} `}${hash(d.key)}</div>`)}</td>
            <td>${(x.passkeys || []).map(k => html`<div class=${k.revoked ? 'revoked' : null}>${hash(k.key)}</div>`)}</td>
            ${admin ? html`<td class="row-actions">${owner ? null : [
                html`<button type="button" class="set-role" disabled @click=${action(e => act({type: 'role_set', user: x.user, role: e.target.closest('tr').querySelector('select').value}))}>Set role</button>`,
                html`<button type="button" class="ghost" @click=${action(() => act({type: 'member_remove', user: x.user}))}>Remove</button>`,
            ]}</td>` : null}
        </tr>`
    }
    return page.node
}

// Figures as a grid of tiles.
function stats(pairs) {
    return html`<dl class="stats">${pairs.map(([k, v]) => html`<div><dt>${k}</dt><dd>${String(v)}</dd></div>`)}</dl>`
}

export function NodeStats() {
    return html`<div class="page">
        <header class="page-head"><h1>Node</h1></header>
        ${loaded(() => api('/api/node/stats'), s => [
            html`<section><h2>Peers <span class="count">${s.peers.length}</span></h2>${s.peers.length === 0 ? empty('No peer is connected') : html`<div class="box scroll"><table class="grid">
                <thead><tr><th>Org</th><th>Peer</th><th>Class</th><th>Path</th><th>Node</th></tr></thead>
                <tbody>${s.peers.map(p => html`<tr><td>${hash(p.org)}</td><td>${hash(p.dh)}</td><td>${p.class}</td><td>${p.rung}</td><td>${p.node ? 'yes' : ''}</td></tr>`)}</tbody>
            </table></div>`}</section>`,
            s.orgs.filter(o => o.behind > 0 || o.unfound > 0).map(o => o.behind > 0
                ? html`<div class="notice warn">${icon('alert')}<p>Org ${hash(o.org)} is behind: ${o.behind} entries of its logs that peers named are not here yet, and their writes wait until a peer gives them.</p></div>`
                : html`<div class="notice">${icon('dot')}<p>Org ${hash(o.org)} let go of ${o.unfound} entries peers named that never came.</p></div>`),
            html`<section><h2>Relay</h2>${stats([['Devices', s.relay.devices], ['Forwarded', s.relay.forwarded], ['Dropped', s.relay.dropped]])}</section>`,
            html`<section><h2>Store</h2>${stats([['Size', s.store.bytes === undefined ? 'unknown' : size(s.store.bytes)], ['Packs', s.store.packs ?? 'unknown']])}</section>`,
            html`<section><h2>Web</h2>${stats([['Requests', s.hub.requests], ['Refused', s.hub.refused], ['Connections', s.hub.connections], ['Sessions', s.hub.sessions]])}</section>`,
        ]).node}
    </div>`
}
