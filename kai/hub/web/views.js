// The public views: the node's projects and, for each, its overview, files,
// changes, diffs and the evolution of a change.
import {h} from './vue.js'
import {api, apiRaw, roleIn, state} from './api.js'
import {DiffView, errorBox, fileDiff, frame, href, link, navigate, short, size, useLoad, when} from './ui.js'
import {detailDecode, summaryDecode} from './preview.js'

// A project's title and tabs above one of its views.
export function projectHead(p, active) {
    const base = `/p/${p.id}`
    const tabs = [['overview', base, 'Overview'], ['tree', `${base}/tree`, 'Files'], ['changes', `${base}/changes`, 'Changes']]
    if (roleIn(p.org)) tabs.push(['stacks', `${base}/stacks`, 'Stacks'], ['proposals', `${base}/proposals`, 'Proposals'], ['org', `/org/${p.org}`, 'Org'])
    return h('header', {class: 'project'}, [
        h('h1', [link(base, p.name || short(p.id)), p.public ? null : h('span', {class: 'badge'}, 'private')]),
        h('nav', {class: 'tabs'}, tabs.map(([key, target, label]) => link(target, label, {class: key === active ? 'active' : ''}))),
    ])
}

export function loadProject(id) {
    return api(`/api/projects/${id}`)
}

// A view of a project: its head, then what body makes of the project and data.
export function projectView(props, active, fetcher, body) {
    const load = useLoad(async () => {
        const project = await loadProject(props.params.project)
        return {project, data: fetcher ? await fetcher(project) : null}
    })
    return () => frame(load, ({project, data}) => [projectHead(project, active), body(project, data, load)])
}

function revisionPicker(project, current, target) {
    const names = project.bookmarks.map(b => b.name)
    const value = current || project.main || ''
    const options = names.map(n => h('option', {value: n, selected: n === value}, n))
    if (value && !names.includes(value)) options.unshift(h('option', {value, selected: true}, short(value)))
    return h('label', {class: 'picker'}, ['Revision ', h('select', {onChange: e => navigate(target(e.target.value))}, options)])
}

function crumbs(project, rev, path) {
    const parts = path ? path.split('/') : []
    const out = [link(href(`/p/${project.id}/tree`, {rev}), project.name || 'root')]
    parts.forEach((name, i) => {
        out.push(' / ')
        const sub = parts.slice(0, i + 1).join('/')
        out.push(i === parts.length - 1 ? h('strong', name) : link(href(`/p/${project.id}/tree`, {rev, path: sub}), name))
    })
    return h('p', {class: 'crumbs'}, out)
}

export const Home = {
    props: ['params', 'query'],
    setup() {
        const load = useLoad(() => api('/api/projects'))
        return () => [
            h('h1', 'Projects'),
            state.node ? h('p', {class: 'quiet'}, `Node ${short(state.node.device)} · ${state.node.modes.join(', ')} · ${state.node.orgs} org${state.node.orgs === 1 ? '' : 's'}`) : null,
            frame(load, d => d.projects.length === 0
                ? h('p', {class: 'quiet'}, 'This node serves no project yet.')
                : h('ul', {class: 'list'}, d.projects.map(p => h('li', [
                    link(`/p/${p.id}`, p.name || short(p.id)), ' ', p.public ? null : h('span', {class: 'badge'}, 'private'),
                ])))),
            state.session?.orgs.length ? [h('h2', 'Your orgs'), h('ul', {class: 'list'}, state.session.orgs.map(o => h('li', [link(`/org/${o.org}`, o.name || short(o.org)), ` · ${o.role}`])))] : null,
        ]
    },
}

export const Overview = {
    props: ['params', 'query'],
    setup(props) {
        return projectView(props, 'overview', null, p => [
            h('h2', 'Bookmarks'),
            p.bookmarks.length === 0 ? h('p', {class: 'quiet'}, 'No bookmark yet.') : h('table', {class: 'grid'}, h('tbody', p.bookmarks.map(b => h('tr', [
                h('td', link(href(`/p/${p.id}/tree`, {rev: b.name}), b.name)),
                h('td', link(`/p/${p.id}/change/${b.revision}`, h('code', short(b.revision)))),
                h('td', {class: 'quiet'}, b.landed ? 'landed' : `${short(b.device)} · ${when(b.time)}`),
                h('td', link(href(`/p/${p.id}/changes`, {rev: b.name}), 'changes')),
            ])))),
            p.readme ? [h('h2', p.readme.path), h('pre', {class: 'readme'}, p.readme.text), p.readme.truncated ? h('p', {class: 'quiet'}, 'The README goes on past what the node shows.') : null] : null,
        ])
    },
}

export const Tree = {
    props: ['params', 'query'],
    setup(props) {
        const {rev, path = ''} = props.query
        return projectView(props, 'tree', p => api(href(`/api/projects/${p.id}/tree`, {rev, path})), (p, d) => [
            revisionPicker(p, rev, r => href(`/p/${p.id}/tree`, {rev: r, path})),
            crumbs(p, rev, d.path),
            h('table', {class: 'grid'}, h('tbody', [...d.entries].sort((a, b) => (b.kind === 'folder') - (a.kind === 'folder') || a.name.localeCompare(b.name)).map(e => {
                const full = d.path ? `${d.path}/${e.name}` : e.name
                const folder = e.kind === 'folder'
                return h('tr', [
                    h('td', link(href(`/p/${p.id}/${folder ? 'tree' : 'file'}`, {rev, path: full}), folder ? `${e.name}/` : e.name)),
                    h('td', {class: 'quiet'}, folder ? `${e.files} file${e.files === 1 ? '' : 's'}` : size(e.size)),
                    h('td', e.conflicts || e.kind === 'conflict' ? h('span', {class: 'badge warn'}, 'conflict') : e.kind === 'executable' ? h('span', {class: 'badge'}, 'executable') : null),
                ])
            }))),
        ])
    },
}

const IMAGES = [
    ['image/png', [0x89, 0x50, 0x4e, 0x47]], ['image/jpeg', [0xff, 0xd8, 0xff]], ['image/gif', [0x47, 0x49, 0x46, 0x38]],
    ['image/webp', [0x52, 0x49, 0x46, 0x46]], ['image/bmp', [0x42, 0x4d]],
]

function imageType(bytes) {
    for (const [type, magic] of IMAGES) {
        if (magic.every((b, i) => bytes[i] === b) && (type !== 'image/webp' || String.fromCharCode(...bytes.slice(8, 12)) === 'WEBP')) return type
    }
    return ''
}

function dataUrl(type, bytes) {
    let text = ''
    for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
    return `data:${type};base64,${btoa(text)}`
}

// What peers published of an asset: its summary and whether a thumbnail is
// here; null when the node has none.
async function previewLoad(p, rev, path) {
    try {
        const d = await api(href(`/api/projects/${p.id}/summary`, {rev, path}))
        return {state: d.state, summary: d.state === 'found' ? summaryDecode(d.summary) : null, thumbnail: d.thumbnail === 'found'}
    } catch {
        return null
    }
}

async function fileLoad(p, rev, path) {
    const preview = previewLoad(p, rev, path)
    let r
    try {
        r = await apiRaw(href(`/api/projects/${p.id}/file`, {rev, path}))
    } catch (error) {
        if (error.status === 413) return {large: error.message, preview: await preview}
        throw error
    }
    if (r.headers.get('content-type')?.startsWith('text/plain')) return {text: await r.text(), preview: await preview}
    const bytes = new Uint8Array(await r.arrayBuffer())
    const type = imageType(bytes)
    return type ? {image: dataUrl(type, bytes), size: bytes.length} : {binary: bytes.length, head: bytes.slice(0, 64), preview: await preview}
}

// The summary of an asset beside its thumbnail, as peers published them.
function previewBox(p, rev, path, preview) {
    if (!preview) return null
    if (preview.state === 'fetching') return h('p', {class: 'quiet'}, 'The node is fetching the summary of this asset from its peers: reload in a moment.')
    if (!preview.summary) return null
    return h('div', {class: 'preview'}, [
        preview.thumbnail ? h('img', {class: 'thumb', src: href(`/api/projects/${p.id}/thumbnail`, {rev, path}), alt: path}) : null,
        h('dl', {class: 'facts'}, [
            h('dt', 'Kind'), h('dd', preview.summary.kind),
            preview.summary.facts.map(f => [h('dt', f.label), h('dd', f.value)]),
        ]),
    ])
}

export const FileView = {
    props: ['params', 'query'],
    setup(props) {
        const {rev, path = ''} = props.query
        const raw = href(`/api/projects/${props.params.project}/file`, {rev, path})
        return projectView(props, 'tree', p => fileLoad(p, rev, path), (p, f) => {
            let body
            const shown = previewBox(p, rev, path, f.preview)
            if (f.large) body = [shown, h('p', {class: 'quiet'}, f.large)]
            else if (f.image) body = [h('p', {class: 'quiet'}, `Image, ${size(f.size)}`), h('img', {class: 'shown', src: f.image, alt: path})]
            else if (f.binary !== undefined) {
                body = shown ? [shown, h('p', h('a', {href: raw}, 'Download'))] : [
                    h('p', {class: 'quiet'}, `Binary file, ${size(f.binary)}. Its first bytes:`),
                    h('pre', {class: 'bytes'}, Array.from(f.head, b => b.toString(16).padStart(2, '0')).join(' ')),
                    h('p', h('a', {href: raw}, 'Download')),
                ]
            } else {
                const lines = f.text.endsWith('\n') ? f.text.slice(0, -1).split('\n') : f.text.split('\n')
                body = h('div', {class: 'scroll'}, h('table', {class: 'code'}, h('tbody', lines.map((t, i) => h('tr', [h('td', {class: 'num'}, i + 1), h('td', {class: 'text'}, t)])))))
            }
            return [revisionPicker(p, rev, r => href(`/p/${p.id}/file`, {rev: r, path})), crumbs(p, rev, path), body]
        })
    },
}

export const Changes = {
    props: ['params', 'query'],
    setup(props) {
        const {rev} = props.query
        const page = Number(props.query.page || 0)
        return projectView(props, 'changes', p => api(href(`/api/projects/${p.id}/changes`, {rev, page: page || undefined})), (p, d) => [
            revisionPicker(p, rev, r => href(`/p/${p.id}/changes`, {rev: r})),
            d.changes.length === 0 ? h('p', {class: 'quiet'}, 'No changes on this page.') : h('ul', {class: 'list changes'}, d.changes.map(c => h('li', [
                link(`/p/${p.id}/change/${c.revision}`, c.summary || '(no description)'),
                h('div', {class: 'quiet'}, [h('code', short(c.change)), ` · ${short(c.author)} · ${when(c.written)}`]),
            ]))),
            h('nav', {class: 'pages'}, [
                page > 0 ? link(href(`/p/${p.id}/changes`, {rev, page: page - 1 || undefined}), '← Newer') : null,
                d.more ? link(href(`/p/${p.id}/changes`, {rev, page: page + 1}), 'Older →') : null,
            ]),
        ])
    },
}

// What a change attaches, by type: "turn × 2".
function attachedText(list) {
    const counts = new Map()
    for (const a of list) counts.set(a.type, (counts.get(a.type) || 0) + 1)
    return [...counts].map(([type, n]) => n > 1 ? `${type} × ${n}` : type).join(', ')
}

export function person(name, key) {
    return name ? [name, ' ', h('code', {class: 'quiet'}, short(key))] : h('code', short(key))
}

export const Change = {
    props: ['params', 'query'],
    setup(props) {
        const revision = props.params.revision
        return projectView(props, 'changes', p => api(`/api/projects/${p.id}/changes/${revision}`), (p, c) => [
            h('h2', (c.description.split('\n')[0]) || '(no description)'),
            c.description.includes('\n') ? h('pre', {class: 'readme'}, c.description) : null,
            h('dl', {class: 'facts'}, [
                h('dt', 'Change'), h('dd', link(`/p/${p.id}/evolution/${c.change}`, h('code', c.change))),
                h('dt', 'Revision'), h('dd', h('code', c.revision)),
                h('dt', 'Author'), h('dd', person(c.author_name, c.author)),
                c.coauthors.length ? [h('dt', 'Co-authors'), h('dd', c.coauthors.map((a, i) => [i ? ', ' : '', person(a.name, a.key)]))] : null,
                h('dt', 'Created'), h('dd', when(c.created)),
                h('dt', 'Written'), h('dd', when(c.written)),
                c.attachments?.length ? [h('dt', 'Attached'), h('dd', attachedText(c.attachments))] : null,
                h('dt', 'Parents'), h('dd', c.parents.length ? c.parents.map((r, i) => [i ? ', ' : '', link(`/p/${p.id}/change/${r}`, h('code', short(r)))]) : 'none'),
            ]),
            h('h2', 'Files'),
            c.files_complete ? null : errorBox('Some files of this change are not on this node yet.'),
            c.files.length === 0 ? h('p', {class: 'quiet'}, 'No file changes.') : h('table', {class: 'grid'}, h('tbody', c.files.map(f => h('tr', [
                h('td', h('span', {class: `badge ${f.status}`}, f.status)),
                h('td', link(href(`/p/${p.id}/diff`, {from: c.parents[0], to: c.revision, path: f.path}), f.path)),
                h('td', {class: 'quiet'}, f.after ? size(f.after.size) : ''),
            ])))),
        ])
    },
}

// The line diff of a file, and of a binary one what peers recorded of the
// change of the asset it is.
async function diffLoad(p, from, to, path) {
    const d = await fileDiff(p.id, from, to, path)
    if (!d.binary) return d
    try {
        const a = await api(href(`/api/projects/${p.id}/asset-diff`, {from, to, path}))
        return {...d, asset: a.state === 'found' ? detailDecode(a.detail) : null, assetState: a.state}
    } catch {
        return d
    }
}

const MARKS = {'+': 'add', '-': 'remove', '~': 'change'}

// What a change did to an asset: its rows and fields, by entity.
function assetDetail(d) {
    return [
        h('p', {class: 'quiet'}, `Asset: +${d.added} −${d.removed} ~${d.changed}`),
        h('div', {class: 'scroll'}, h('table', {class: 'diff'}, h('tbody', d.rows.map(r => h('tr', {class: MARKS[r.mark]}, [
            h('td', {class: 'num'}, r.name),
            h('td', {class: 'text'}, `${r.mark} ${r.text}`),
        ]))))),
        d.cut ? h('p', {class: 'quiet'}, `${d.cut} more row${d.cut === 1 ? '' : 's'} not shown.`) : null,
    ]
}

export const Diff = {
    props: ['params', 'query'],
    setup(props) {
        const {from, to, path} = props.query
        return projectView(props, 'changes', p => diffLoad(p, from, to, path), (p, d) => [
            h('h2', path),
            h('p', {class: 'quiet'}, [
                from ? link(`/p/${p.id}/change/${from}`, h('code', short(from))) : 'nothing', ' → ', link(`/p/${p.id}/change/${to}`, h('code', short(to))),
                d.lines.length ? ` · +${d.added} −${d.removed}` : '',
                ' · ', link(href(`/p/${p.id}/file`, {rev: to, path}), 'file'),
            ]),
            d.asset ? assetDetail(d.asset) : null,
            d.assetState === 'fetching' ? h('p', {class: 'quiet'}, 'The node is fetching what peers recorded of this change: reload in a moment.') : null,
            h(DiffView, {diff: d}),
        ])
    },
}

export const Evolution = {
    props: ['params', 'query'],
    setup(props) {
        return projectView(props, 'changes', p => api(`/api/projects/${p.id}/evolution/${props.params.change}`), (p, e) => [
            h('h2', ['Evolution of ', h('code', short(e.change))]),
            h('ol', {class: 'list'}, e.revisions.map((r, i) => h('li', [
                link(`/p/${p.id}/change/${r.revision}`, r.summary || '(no description)'),
                h('div', {class: 'quiet'}, [h('code', short(r.revision)), ` · ${short(r.author)} · ${when(r.written)} · ${r.files.length} file${r.files.length === 1 ? '' : 's'}`]),
                e.interdiffs[i - 1] ? interdiff(p, e.interdiffs[i - 1]) : null,
            ]))),
        ])
    },
}

function interdiff(p, d) {
    if (d.files.length === 0) return h('p', {class: 'quiet'}, 'Same content as the revision before.')
    return h('div', {class: 'interdiff'}, [
        h('span', {class: 'quiet'}, 'Since the revision before: '),
        d.files.map((f, i) => [i ? ', ' : '', link(href(`/p/${p.id}/diff`, {from: d.from, to: d.to, path: f.path}), f.path)]),
    ])
}
