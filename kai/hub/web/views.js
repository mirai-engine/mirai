// The public views: the node's projects and, for each, its overview, files,
// changes, diffs and the evolution of a change.
import {html} from './dom.js'
import {api, apiRaw, app, roleIn} from './api.js'
import {ago, badge, diffView, empty, fileDiff, hash, href, icon, loaded, navigate, plural, short, size, when} from './ui.js'
import {detailDecode, summaryDecode} from './preview.js'

// A project's name and tabs above one of its views.
export function projectHead(p, tab) {
    const base = `/p/${p.id}`
    const tabs = [['overview', base, 'Overview'], ['tree', `${base}/tree`, 'Files'], ['changes', `${base}/changes`, 'Changes']]
    if (roleIn(p.org)) tabs.push(['stacks', `${base}/stacks`, 'Stacks'], ['proposals', `${base}/proposals`, 'Proposals'], ['org', `/org/${p.org}`, 'Org'])
    return html`<header class="project-head">
        <h1><a href=${base}>${p.name || short(p.id)}</a>${p.public ? null : html`<span class="badge private">${icon('lock')}private</span>`}</h1>
        <nav class="tabs" aria-label="Project">${tabs.map(([key, target, label]) =>
            html`<a href=${target} class=${key === tab ? 'active' : null} aria-current=${key === tab ? 'page' : null}>${label}</a>`)}</nav>
    </header>`
}

export function loadProject(id) {
    return api(`/api/projects/${id}`)
}

// A view of a project: its head, then what body makes of the project and of
// what fetch answers for it.
export function projectPage(id, tab, fetch, body) {
    return loaded(async () => {
        const project = await loadProject(id)
        return {project, data: fetch ? await fetch(project) : null}
    }, ({project, data}, view) => [projectHead(project, tab), body(project, data, view)]).node
}

function revisionPicker(project, current, target) {
    const names = project.bookmarks.map(b => b.name)
    const value = current || project.main || ''
    const options = names.map(n => html`<option value=${n} ?selected=${n === value}>${n}</option>`)
    if (value && !names.includes(value)) options.unshift(html`<option value=${value} selected>${short(value)}</option>`)
    return html`<label class="picker" title="Revision">${icon('bookmark')}<select aria-label="Revision" @change=${e => navigate(target(e.target.value))}>${options}</select></label>`
}

function crumbs(project, rev, path) {
    const parts = path ? path.split('/') : []
    const at = i => href(`/p/${project.id}/tree`, {rev, path: parts.slice(0, i + 1).join('/')})
    return html`<nav class="crumbs" aria-label="Path">
        <a href=${href(`/p/${project.id}/tree`, {rev})}>${project.name || 'root'}</a>
        ${parts.map((name, i) => [html`<span class="sep">/</span>`, i === parts.length - 1 ? html`<strong>${name}</strong>` : html`<a href=${at(i)}>${name}</a>`])}
    </nav>`
}

export function Home() {
    const node = app.node
    const orgs = app.session?.orgs ?? []
    const projects = loaded(() => api('/api/projects'), d => d.projects.length === 0
        ? empty('No projects yet', 'This node serves no project. Publish one with mirai kai.')
        : html`<ul class="cards">${d.projects.map(p => html`<li><a class="card" href=${`/p/${p.id}`}>
            <span class="card-title">${icon(p.public ? 'folder' : 'lock')}${p.name || short(p.id)}</span>
            <span class="quiet">${p.public ? 'Public' : 'Private'} · ${hash(p.id)}</span>
        </a></li>`)}</ul>`)
    return html`<div class="page">
        <header class="page-head">
            <h1>Projects</h1>
            <p class="quiet">Node ${hash(node.device)} · ${node.modes.join(', ')} · ${plural(node.orgs, 'org')}</p>
        </header>
        ${projects.node}
        ${orgs.length ? html`<section>
            <h2>Your orgs</h2>
            <ul class="cards">${orgs.map(o => html`<li><a class="card" href=${`/org/${o.org}`}>
                <span class="card-title">${o.name || short(o.org)}</span><span class="quiet">${o.role}</span>
            </a></li>`)}</ul>
        </section>` : null}
    </div>`
}

export function Overview({params}) {
    return projectPage(params.project, 'overview', null, p => html`<div class="split">
        <div class="main-column">${p.readme ? html`<article class="box">
            <header class="box-head">${icon('file')}<strong>${p.readme.path}</strong></header>
            <pre class="prose">${p.readme.text}</pre>
            ${p.readme.truncated ? html`<p class="quiet pad">The README goes on past what the node shows.</p>` : null}
        </article>` : empty('No README', 'Add a README.md at the root and it shows here.')}</div>
        <aside class="side-column">
            <h2 class="side-title">Bookmarks</h2>
            ${p.bookmarks.length === 0 ? empty('No bookmarks yet') : html`<ul class="box rows">${p.bookmarks.map(b => html`<li class="item">
                <div class="item-main">
                    <a href=${href(`/p/${p.id}/tree`, {rev: b.name})}><strong>${b.name}</strong></a>
                    ${b.landed ? badge('landed') : null}
                </div>
                <div class="meta">${hash(b.revision, `/p/${p.id}/change/${b.revision}`)}
                    ${b.landed ? null : html`<span>${hash(b.device)} · ${ago(b.time)}</span>`}
                    <a href=${href(`/p/${p.id}/changes`, {rev: b.name})}>History</a></div>
            </li>`)}</ul>`}
        </aside>
    </div>`)
}

const byFolderThenName = (a, b) => (b.kind === 'folder') - (a.kind === 'folder') || a.name.localeCompare(b.name)

export function Tree({params, query}) {
    const {rev, path = ''} = query
    return projectPage(params.project, 'tree', p => api(href(`/api/projects/${p.id}/tree`, {rev, path})), (p, d) => html`<section class="box">
        <header class="box-head toolbar">${revisionPicker(p, rev, r => href(`/p/${p.id}/tree`, {rev: r, path}))}${crumbs(p, rev, d.path)}</header>
        ${d.entries.length === 0 ? empty('Empty folder') : html`<ul class="rows files">${[...d.entries].sort(byFolderThenName).map(e => {
            const full = d.path ? `${d.path}/${e.name}` : e.name
            const folder = e.kind === 'folder'
            return html`<li class="item file-row">
                <a href=${href(`/p/${p.id}/${folder ? 'tree' : 'file'}`, {rev, path: full})}>${icon(folder ? 'folder' : 'file')}<span>${e.name}</span></a>
                ${e.conflicts || e.kind === 'conflict' ? badge('conflict') : e.kind === 'executable' ? badge('executable', 'neutral') : null}
                <span class="quiet size">${folder ? plural(e.files, 'file') : size(e.size)}</span>
            </li>`
        })}</ul>`}
    </section>`)
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
    if (preview?.state === 'fetching') return html`<p class="waiting pad"><span class="spinner" aria-hidden="true"></span>The node is fetching the summary of this asset from its peers: reload in a moment.</p>`
    if (!preview?.summary) return null
    return html`<div class="preview">
        ${preview.thumbnail ? html`<img class="thumb" src=${href(`/api/projects/${p.id}/thumbnail`, {rev, path})} alt=${path}>` : null}
        <dl class="facts">
            <dt>Kind</dt><dd>${preview.summary.kind}</dd>
            ${preview.summary.facts.map(f => [html`<dt>${f.label}</dt>`, html`<dd>${f.value}</dd>`])}
        </dl>
    </div>`
}

function fileBody(p, rev, path, f) {
    const raw = href(`/api/projects/${p.id}/file`, {rev, path})
    const download = html`<a class="button" href=${raw}>Download</a>`
    const shown = previewBox(p, rev, path, f.preview)
    if (f.large) return [shown, html`<p class="quiet pad">${f.large}</p>`]
    if (f.image) return html`<div class="image-frame"><img class="shown" src=${f.image} alt=${path}></div>`
    if (f.binary !== undefined) return shown ? [shown, html`<p class="pad">${download}</p>`] : html`<div class="pad">
        <p class="quiet">Binary file, ${size(f.binary)}. Its first bytes:</p>
        <pre class="bytes">${Array.from(f.head, b => b.toString(16).padStart(2, '0')).join(' ')}</pre>
        <p>${download}</p>
    </div>`
    const lines = f.text.endsWith('\n') ? f.text.slice(0, -1).split('\n') : f.text.split('\n')
    return html`<div class="scroll"><table class="code"><tbody>${lines.map((t, i) =>
        html`<tr><td class="num">${i + 1}</td><td class="text">${t}</td></tr>`)}</tbody></table></div>`
}

function fileSize(f) {
    if (f.text !== undefined) return `${plural(f.text.split('\n').length - (f.text.endsWith('\n') ? 1 : 0), 'line')}`
    if (f.image) return `Image · ${size(f.size)}`
    if (f.binary !== undefined) return size(f.binary)
    return ''
}

export function FileView({params, query}) {
    const {rev, path = ''} = query
    return projectPage(params.project, 'tree', p => fileLoad(p, rev, path), (p, f) => html`<section class="box">
        <header class="box-head toolbar">
            ${revisionPicker(p, rev, r => href(`/p/${p.id}/file`, {rev: r, path}))}${crumbs(p, rev, path)}
            <span class="toolbar-end quiet">${fileSize(f)}<a href=${href(`/api/projects/${p.id}/file`, {rev, path})}>Raw</a></span>
        </header>
        ${fileBody(p, rev, path, f)}
    </section>`)
}

function changeRow(p, c) {
    return html`<li class="item">
        <div class="item-main"><a href=${`/p/${p.id}/change/${c.revision}`}><strong>${c.summary || '(no description)'}</strong></a></div>
        <div class="meta">${hash(c.change)}<span>${hash(c.author)}</span>${ago(c.written)}</div>
    </li>`
}

export function Changes({params, query}) {
    const {rev} = query
    const page = Number(query.page || 0)
    const at = n => href(`/p/${params.project}/changes`, {rev, page: n || undefined})
    return projectPage(params.project, 'changes', p => api(href(`/api/projects/${p.id}/changes`, {rev, page: page || undefined})), (p, d) => html`<section class="box">
        <header class="box-head toolbar">${revisionPicker(p, rev, r => href(`/p/${p.id}/changes`, {rev: r}))}</header>
        ${d.changes.length === 0 ? empty('No changes on this page') : html`<ul class="rows">${d.changes.map(c => changeRow(p, c))}</ul>`}
    </section>
    <nav class="pager">
        ${page > 0 ? html`<a class="button" href=${at(page - 1)}>← Newer</a>` : html`<span></span>`}
        ${d.more ? html`<a class="button" href=${at(page + 1)}>Older →</a>` : null}
    </nav>`)
}

// What a change attaches, by type: "turn × 2".
function attachedText(list) {
    const counts = new Map()
    for (const a of list) counts.set(a.type, (counts.get(a.type) || 0) + 1)
    return [...counts].map(([type, n]) => n > 1 ? `${type} × ${n}` : type).join(', ')
}

export function person(name, key) {
    return name ? html`<span class="person">${name} ${hash(key)}</span>` : hash(key)
}

const joined = (list, item) => list.map((x, i) => [i ? ', ' : '', item(x)])

// A file of a change, with its status, linked to its diff.
export function fileRow(f, target) {
    return html`<li class="item file-row">
        ${badge(f.status)}<a href=${target}><span>${f.path}</span></a><span class="quiet size">${f.after ? size(f.after.size) : ''}</span>
    </li>`
}

export function Change({params}) {
    const revision = params.revision
    return projectPage(params.project, 'changes', p => api(`/api/projects/${p.id}/changes/${revision}`), (p, c) => {
        const [title, ...rest] = c.description.split('\n')
        const body = rest.join('\n').trim()
        return html`<div class="page">
            <header class="page-head">
                <h2 class="title">${title || '(no description)'}</h2>
                ${body ? html`<pre class="prose">${body}</pre>` : null}
            </header>
            <dl class="facts box pad">
                <dt>Change</dt><dd>${hash(c.change, `/p/${p.id}/evolution/${c.change}`)} <a href=${`/p/${p.id}/evolution/${c.change}`}>Evolution</a></dd>
                <dt>Revision</dt><dd>${hash(c.revision)}</dd>
                <dt>Author</dt><dd>${person(c.author_name, c.author)}</dd>
                ${c.coauthors.length ? [html`<dt>Co-authors</dt>`, html`<dd>${joined(c.coauthors, a => person(a.name, a.key))}</dd>`] : null}
                <dt>Created</dt><dd>${when(c.created)}</dd>
                <dt>Written</dt><dd>${when(c.written)}</dd>
                ${c.attachments?.length ? [html`<dt>Attached</dt>`, html`<dd>${attachedText(c.attachments)}</dd>`] : null}
                <dt>Parents</dt><dd>${c.parents.length ? joined(c.parents, r => hash(r, `/p/${p.id}/change/${r}`)) : 'none'}</dd>
            </dl>
            <section>
                <h2>Files <span class="count">${c.files.length}</span></h2>
                ${c.files_complete ? null : html`<div class="notice warn">${icon('alert')}<p>Some files of this change are not on this node yet.</p></div>`}
                ${c.files.length === 0 ? empty('No file changes') : html`<ul class="box rows">${c.files.map(f =>
                    fileRow(f, href(`/p/${p.id}/diff`, {from: c.parents[0], to: c.revision, path: f.path})))}</ul>`}
            </section>
        </div>`
    })
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
    return html`<div>
        <p class="pad stat"><span class="added">+${d.added}</span><span class="removed">−${d.removed}</span><span class="changed">~${d.changed}</span> entities</p>
        <div class="scroll"><table class="diff asset"><tbody>${d.rows.map(r =>
            html`<tr class=${MARKS[r.mark]}><td class="name">${r.name}</td><td class="sign">${r.mark}</td><td class="text">${r.text}</td></tr>`)}</tbody></table></div>
        ${d.cut ? html`<p class="quiet pad">${plural(d.cut, 'more row')} not shown.</p>` : null}
    </div>`
}

// The head of a file's diff: its path, what it adds and removes, and links.
export function diffHead(d, path, links) {
    return html`<header class="box-head file-head">
        ${icon('file')}<strong class="path">${path}</strong>
        ${d.lines.length ? html`<span class="stat"><span class="added">+${d.added}</span><span class="removed">−${d.removed}</span></span>` : null}
        <span class="toolbar-end">${links}</span>
    </header>`
}

export function Diff({params, query}) {
    const {from, to, path} = query
    return projectPage(params.project, 'changes', p => diffLoad(p, from, to, path), (p, d) => html`<div class="page">
        <p class="quiet range">${from ? hash(from, `/p/${p.id}/change/${from}`) : 'nothing'} → ${hash(to, `/p/${p.id}/change/${to}`)}</p>
        <section class="box diff-box">
            ${diffHead(d, path, html`<a href=${href(`/p/${p.id}/file`, {rev: to, path})}>View file</a>`)}
            ${d.asset ? assetDetail(d.asset) : null}
            ${d.assetState === 'fetching' ? html`<p class="waiting pad"><span class="spinner" aria-hidden="true"></span>The node is fetching what peers recorded of this change: reload in a moment.</p>` : null}
            ${diffView(d)}
        </section>
    </div>`)
}

function interdiff(p, d) {
    if (d.files.length === 0) return html`<p class="quiet">Same content as the revision before.</p>`
    return html`<p class="interdiff"><span class="quiet">Since the revision before:</span> ${joined(d.files, f =>
        html`<a href=${href(`/p/${p.id}/diff`, {from: d.from, to: d.to, path: f.path})}>${f.path}</a>`)}</p>`
}

export function Evolution({params}) {
    return projectPage(params.project, 'changes', p => api(`/api/projects/${p.id}/evolution/${params.change}`), (p, e) => html`<div class="page">
        <header class="page-head"><h2 class="title">Evolution of ${hash(e.change)}</h2>
            <p class="quiet">${plural(e.revisions.length, 'revision')} of one change, oldest first.</p></header>
        <ol class="timeline">${e.revisions.map((r, i) => html`<li>
            <a href=${`/p/${p.id}/change/${r.revision}`}><strong>${r.summary || '(no description)'}</strong></a>
            <div class="meta">${hash(r.revision)}<span>${hash(r.author)}</span>${ago(r.written)}<span>${plural(r.files.length, 'file')}</span></div>
            ${e.interdiffs[i - 1] ? interdiff(p, e.interdiffs[i - 1]) : null}
        </li>`)}</ol>
    </div>`)
}
