// The views for members: stacks, proposals and their review, the org and
// the node. Every write is an entry signed by the user (passkey.js).
import {h, reactive, ref} from './vue.js'
import {api, roleIn, state} from './api.js'
import {write} from './passkey.js'
import {person, projectHead, projectView, loadProject} from './views.js'
import {button, DiffView, errorBox, fileDiff, frame, href, link, short, size, useAction, useLoad, when} from './ui.js'

export const Stacks = {
    props: ['params', 'query'],
    setup(props) {
        return projectView(props, 'stacks', p => api(`/api/projects/${p.id}/stacks`), (p, d) => d.stacks.length === 0
            ? h('p', {class: 'quiet'}, 'No device has published a bookmark of this project.')
            : h('ul', {class: 'list'}, d.stacks.map(s => h('li', [
                h('strong', s.label),
                h('div', {class: 'quiet'}, [link(`/p/${p.id}/change/${s.revision}`, h('code', short(s.revision))), ` · ${when(s.time)}`]),
                s.changes.length === 0 ? h('p', {class: 'quiet'}, 'Nothing above what landed.') : h('ol', {class: 'stack'}, s.changes.map(c => h('li', [
                    link(`/p/${p.id}/change/${c.revision}`, c.summary || '(no description)'), ' ', h('code', {class: 'quiet'}, short(c.change)),
                ]))),
            ]))))
    },
}

export const Proposals = {
    props: ['params', 'query'],
    setup(props) {
        return projectView(props, 'proposals', p => api(`/api/projects/${p.id}/proposals`), (p, d) => d.proposals.length === 0
            ? h('p', {class: 'quiet'}, 'No proposals: open one with mirai kai proposal open <target>.')
            : h('ul', {class: 'list'}, d.proposals.map(x => h('li', [
                link(`/proposal/${x.id}`, x.title || '(no title)'), ' ', h('span', {class: `badge ${x.status}`}, x.status),
                h('div', {class: 'quiet'}, `into ${x.target} · by ${x.opener_name || short(x.opener)} · ${x.approvals} approval${x.approvals === 1 ? '' : 's'} · ${x.comments} comment${x.comments === 1 ? '' : 's'}`),
            ]))))
    },
}

// A box to write a comment in; send(text) posts it.
const Composer = {
    props: ['label', 'send', 'cancel'],
    setup(props) {
        const text = ref('')
        const action = useAction(async () => {
            if (!text.value.trim()) throw new Error('write something first')
            await props.send(text.value)
            text.value = ''
        })
        return () => h('div', {class: 'composer'}, [
            h('textarea', {rows: 3, value: text.value, placeholder: props.label, 'aria-label': props.label, onInput: e => text.value = e.target.value}),
            h('div', {class: 'row'}, [
                button(action.busy ? 'Signing…' : 'Comment', action),
                props.cancel ? h('button', {type: 'button', class: 'link', onClick: props.cancel}, 'Cancel') : null,
            ]),
            errorBox(action.error),
        ])
    },
}

const VERDICT_TEXT = {approve: 'approved', changes: 'requested changes', withdraw: 'withdrew'}

function where(c) {
    if (!c.path) return ''
    return c.anchor.kind === 'lines' ? `${c.path}:${c.anchor.line}${c.anchor.lines > 1 ? `-${c.anchor.line + c.anchor.lines - 1}` : ''}` : c.path
}

// A comment and its replies; reply(c) opens a composer under it.
function thread(c, all, ui) {
    const replies = all.filter(r => r.reply_to === c.id)
    return h('div', {class: ['comment', c.outdated ? 'outdated' : '']}, [
        h('div', {class: 'quiet'}, [
            h('strong', c.author_name || short(c.author)), ` · ${when(c.time)}`,
            c.outdated ? [' · ', h('span', {class: 'badge warn'}, 'outdated'), ` ${where(c)}`] : '',
        ]),
        h('p', {class: 'text'}, c.text),
        ui.replying === c.id
            ? h(Composer, {label: 'Reply', send: text => ui.reply(c, text), cancel: () => ui.replying = ''})
            : h('button', {type: 'button', class: 'link', onClick: () => ui.replying = c.id}, 'Reply'),
        replies.length ? h('div', {class: 'replies'}, replies.map(r => thread(r, all, ui))) : null,
    ])
}

// The comments a thread starts from: those that answer none still shown.
function roots(list, all) {
    const ids = new Set(all.map(c => c.id))
    return list.filter(c => !c.reply_to || !ids.has(c.reply_to))
}

// One file of a change of the stack, with its comments and a composer on
// the lines picked.
const StackFile = {
    props: ['project', 'parent', 'item', 'file', 'comments', 'ui'],
    setup(props) {
        const load = useLoad(() => fileDiff(props.project, props.parent, props.item.revision, props.file.path))
        const pick = reactive({line: 0, lines: 0, file: false})
        const choose = (line, e) => {
            if (e.shiftKey && pick.line) {
                const first = Math.min(pick.line, line), last = Math.max(pick.line + pick.lines - 1, line)
                pick.line = first
                pick.lines = last - first + 1
            } else {
                pick.line = line
                pick.lines = 1
            }
            pick.file = false
        }
        const clear = () => Object.assign(pick, {line: 0, lines: 0, file: false})
        const send = anchor => text => props.ui.comment({change: props.item.change, path: props.file.path, anchor}, text).then(clear)
        return () => {
            const mine = props.comments.filter(c => c.change === props.item.change && c.path === props.file.path && !c.outdated)
            const tops = roots(mine, props.comments)
            const onFile = tops.filter(c => c.anchor.kind !== 'lines')
            const last = c => c.anchor.line + Math.max(1, c.anchor.lines) - 1
            const onLines = tops.filter(c => c.anchor.kind === 'lines')
            const keep = new Set(onLines.map(last))
            if (pick.line) keep.add(pick.line + pick.lines - 1)
            const after = n => {
                const here = onLines.filter(c => last(c) === n).map(c => thread(c, props.comments, props.ui))
                if (pick.line && n === pick.line + pick.lines - 1) {
                    here.push(h(Composer, {label: `Comment on line${pick.lines > 1 ? `s ${pick.line}-${n}` : ` ${n}`}`, send: send({kind: 'lines', line: pick.line, lines: pick.lines}), cancel: clear}))
                }
                return here.length ? here : null
            }
            return h('section', {class: 'file'}, [
                h('header', [
                    h('span', {class: `badge ${props.file.status}`}, props.file.status), ' ',
                    link(href(`/p/${props.project}/diff`, {from: props.parent, to: props.item.revision, path: props.file.path}), props.file.path),
                    h('button', {type: 'button', class: 'link', onClick: () => Object.assign(pick, {line: 0, lines: 0, file: true})}, 'Comment on file'),
                ]),
                onFile.map(c => thread(c, props.comments, props.ui)),
                pick.file ? h(Composer, {label: `Comment on ${props.file.path}`, send: send({kind: 'file'}), cancel: clear}) : null,
                frame(load, d => h(DiffView, {diff: d, pick: choose, after, keep, selected: pick.line ? pick : null})),
            ])
        }
    },
}

const StackChange = {
    props: ['project', 'item', 'comments', 'ui'],
    setup(props) {
        const load = useLoad(() => api(`/api/projects/${props.project}/changes/${props.item.revision}`))
        return () => frame(load, c => [
            c.description ? h('pre', {class: 'readme'}, c.description) : null,
            c.files.length === 0 ? h('p', {class: 'quiet'}, 'No file changes.') : null,
            c.files.map(f => h(StackFile, {key: f.path, project: props.project, parent: c.parents[0], item: props.item, file: f, comments: props.comments, ui: props.ui})),
        ])
    },
}

export const Proposal = {
    props: ['params', 'query'],
    setup(props) {
        const id = props.params.proposal
        const load = useLoad(async () => {
            const x = await api(`/api/proposals/${id}`)
            return {x, project: await loadProject(x.project)}
        })
        const selected = ref(0)
        const act = async entry => {
            await write({log: id, ...entry})
            await load.reload()
        }
        const ui = reactive({
            replying: '',
            comment: (anchor, text) => act({type: 'proposal_comment', text, change: anchor.change, path: anchor.path, anchor: anchor.anchor}),
            reply: async (c, text) => {
                const on = c.outdated || !c.change ? {} : {change: c.change, path: c.path, anchor: {kind: c.anchor.kind, line: c.anchor.line, lines: c.anchor.lines}}
                await act({type: 'proposal_comment', text, reply_to: c.id, ...on})
                ui.replying = ''
            },
        })
        const verdict = useAction(v => act({type: 'proposal_verdict', verdict: v, revision: load.data.x.revision}))
        const status = useAction(type => act({type}))
        return () => frame(load, ({x, project}) => {
            const item = x.stack[Math.min(selected.value, x.stack.length - 1)]
            const general = roots(x.comments.filter(c => !c.change && !c.outdated), x.comments)
            const outdated = roots(x.comments.filter(c => c.outdated), x.comments)
            const mine = x.verdicts.find(v => v.user === state.session?.user)
            return [
                projectHead(project, 'proposals'),
                h('h2', [x.title || '(no title)', ' ', h('span', {class: `badge ${x.status}`}, x.status)]),
                h('p', {class: 'quiet'}, [`into ${x.target} · opened by `, person(x.opener_name, x.opener)]),
                x.text ? h('pre', {class: 'readme'}, x.text) : null,
                x.blocked ? h('p', {class: 'blocked'}, ['Landing is blocked: ', x.blocked.text]) : h('p', {class: 'ready'}, 'Ready to land.'),
                h('section', {class: 'verdicts'}, [
                    h('h3', `Verdicts · ${x.approvals} approval${x.approvals === 1 ? '' : 's'}`),
                    x.verdicts.length === 0 ? h('p', {class: 'quiet'}, 'None yet.') : h('ul', {class: 'list'}, x.verdicts.map(v => h('li', [
                        h('strong', v.name || short(v.user)), ` ${VERDICT_TEXT[v.verdict]} `, h('code', short(v.revision)),
                        v.current ? null : h('span', {class: 'badge warn'}, 'earlier stack'),
                    ]))),
                    x.status === 'open' ? h('div', {class: 'row'}, [
                        button('Approve', verdict, {args: ['approve']}),
                        button('Request changes', verdict, {args: ['changes']}),
                        mine && mine.verdict !== 'withdraw' ? button('Withdraw my verdict', verdict, {args: ['withdraw'], class: 'quiet'}) : null,
                    ]) : null,
                    errorBox(verdict.error),
                ]),
                x.checks.length ? h('section', [h('h3', 'Checks'), h('ul', {class: 'list'}, x.checks.map(c => h('li', [c.name, ' ', h('span', {class: `badge ${c.state}`}, c.state)])))]) : null,
                h('section', [
                    h('h3', 'Conversation'),
                    general.map(c => thread(c, x.comments, ui)),
                    h(Composer, {label: 'Comment on the proposal', send: text => ui.comment({}, text)}),
                ]),
                h('section', [
                    h('h3', `Stack · ${x.stack.length} change${x.stack.length === 1 ? '' : 's'}`),
                    x.stack.length === 0 ? h('p', {class: 'quiet'}, 'No stack yet.') : h('nav', {class: 'tabs stack'}, x.stack.map((s, i) => h('button', {
                        type: 'button', class: s === item ? 'active' : '', onClick: () => selected.value = i,
                    }, s.summary || short(s.change)))),
                    item ? h(StackChange, {key: item.revision, project: x.project, item, comments: x.comments, ui}) : null,
                ]),
                outdated.length ? h('section', [h('h3', 'Outdated comments'), outdated.map(c => thread(c, x.comments, ui))]) : null,
                h('div', {class: 'row'}, [
                    x.status === 'open' ? button('Close the proposal', status, {args: ['proposal_close'], class: 'quiet'}) : null,
                    x.status === 'closed' ? button('Reopen the proposal', status, {args: ['proposal_reopen']}) : null,
                ]),
                errorBox(status.error),
            ]
        })
    },
}

const ROLES = ['reader', 'writer', 'admin']

export const Org = {
    props: ['params', 'query'],
    setup(props) {
        const id = props.params.org
        const load = useLoad(async () => {
            const [members, ddc] = await Promise.all([api(`/api/orgs/${id}/members`), api(`/api/orgs/${id}/ddc`)])
            return {members, ddc}
        })
        const act = useAction(async entry => {
            await write({log: id, ...entry})
            await load.reload()
        })
        const add = reactive({user: '', role: 'writer'})
        const roles = reactive({})
        return () => frame(load, ({members: m, ddc}) => {
            const admin = ['admin', 'owner'].includes(roleIn(id))
            return [
                h('h1', m.name || short(m.org)),
                h('p', {class: 'quiet'}, ['Org ', h('code', short(m.org)), ` · your role: ${roleIn(id) || 'none'}`]),
                h('h2', 'Members'),
                h('div', {class: 'scroll'}, h('table', {class: 'grid'}, [
                    h('thead', h('tr', [h('th', 'Member'), h('th', 'Role'), h('th', 'Devices'), h('th', 'Passkeys'), admin ? h('th', '') : null])),
                    h('tbody', m.members.map(x => h('tr', [
                        h('td', person(x.name, x.user)),
                        h('td', admin && x.role !== 'owner'
                            ? h('select', {'aria-label': 'Role', onChange: e => roles[x.user] = e.target.value}, ROLES.map(r => h('option', {value: r, selected: (roles[x.user] || x.role) === r}, r)))
                            : x.role),
                        h('td', (x.devices || []).map(d => h('div', {class: d.revoked ? 'revoked' : ''}, [d.name === short(d.key) ? null : `${d.name} `, h('code', {class: 'quiet'}, short(d.key))]))),
                        h('td', (x.passkeys || []).map(k => h('div', {class: k.revoked ? 'revoked' : ''}, h('code', short(k.key))))),
                        admin ? h('td', x.role === 'owner' ? null : [
                            button('Set role', act, {args: [{type: 'role_set', user: x.user, role: roles[x.user] || x.role}], disabled: !roles[x.user] || roles[x.user] === x.role}),
                            button('Remove', act, {args: [{type: 'member_remove', user: x.user}], class: 'quiet'}),
                        ]) : null,
                    ]))),
                ])),
                admin ? h('form', {class: 'row', onSubmit: e => {
                    e.preventDefault()
                    act.run({type: 'member_add', user: add.user.trim(), role: add.role})
                }}, [
                    h('input', {placeholder: 'User id, 64 hex', 'aria-label': 'User id', value: add.user, onInput: e => add.user = e.target.value, class: 'grow'}),
                    h('select', {'aria-label': 'Role', onChange: e => add.role = e.target.value}, ROLES.map(r => h('option', {value: r, selected: add.role === r}, r))),
                    h('button', {type: 'submit', disabled: act.busy}, 'Add member'),
                ]) : null,
                errorBox(act.error),
                h('h2', 'Nodes'),
                m.nodes.length === 0 ? h('p', {class: 'quiet'}, 'No node is listed.') : h('ul', {class: 'list'}, m.nodes.map(n => h('li', [h('code', short(n.key)), ` · ${n.modes.join(', ')}`]))),
                h('h2', 'Derived data'),
                h('dl', {class: 'facts'}, [
                    ['Keys', ddc.keys], ['Records', ddc.records], ['Outputs here', ddc.whole], ['Outputs missing', ddc.missing],
                    ['Nondeterministic keys', ddc.nondeterministic], ['Lookups found', ddc.lookups_found], ['Lookups missing', ddc.lookups_missing],
                    ['Bytes', size(ddc.bytes)], ['Quota', ddc.quota ? size(ddc.quota) : 'none'],
                ].map(([k, v]) => [h('dt', k), h('dd', String(v))])),
            ]
        })
    },
}

export const NodeStats = {
    props: ['params', 'query'],
    setup() {
        const load = useLoad(() => api('/api/node/stats'))
        return () => [h('h1', 'Node'), frame(load, s => [
            h('h2', 'Peers'),
            s.peers.length === 0 ? h('p', {class: 'quiet'}, 'No peer is connected.') : h('div', {class: 'scroll'}, h('table', {class: 'grid'}, [
                h('thead', h('tr', ['Org', 'Peer', 'Class', 'Path', 'Node'].map(t => h('th', t)))),
                h('tbody', s.peers.map(p => h('tr', [h('td', h('code', short(p.org))), h('td', h('code', short(p.dh))), h('td', p.class), h('td', p.rung), h('td', p.node ? 'yes' : '')]))),
            ])),
            h('h2', 'Relay'),
            h('dl', {class: 'facts'}, [['Devices', s.relay.devices], ['Forwarded', s.relay.forwarded], ['Dropped', s.relay.dropped]].map(([k, v]) => [h('dt', k), h('dd', String(v))])),
            h('h2', 'Store'),
            h('dl', {class: 'facts'}, [['Size', s.store.bytes === undefined ? 'unknown' : size(s.store.bytes)], ['Packs', s.store.packs ?? 'unknown']].map(([k, v]) => [h('dt', k), h('dd', String(v))])),
            h('h2', 'Web'),
            h('dl', {class: 'facts'}, [['Requests', s.hub.requests], ['Refused', s.hub.refused], ['Connections', s.hub.connections], ['Sessions', s.hub.sessions]].map(([k, v]) => [h('dt', k), h('dd', String(v))])),
        ])]
    },
}
