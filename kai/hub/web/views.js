// The public views: home, and for each project its overview, files,
// changes, diffs and the revision history of a change.
import {el, html, mount} from './dom.js'
import {api, apiRaw, app, roleIn} from './api.js'
import {
    action, ago, avatar, badge, cell, codeView, once, diffModeSwitch, diffStat, diffView, empty, fileDiff, hash, href, icon,
    loaded, markdown, meter, navigate, person, plural, setPage, short, size, skeleton, technical, when,
} from './ui.js'
import {detailDecode, summaryDecode} from './preview.js'
import {authView, onboarding} from './account.js'

// --- Projects ---

const PROJECT_FRESH_MS = 15000
const projects = new Map() // id -> {cell, at}

// The overview of a project, kept a few seconds so moving between its tabs draws at once.
export function loadProject(id) {
    const kept = projects.get(id)
    if (kept && Date.now() - kept.at < PROJECT_FRESH_MS) return kept.cell
    const c = cell(() => api(`/api/projects/${id}`))
    projects.set(id, {cell: c, at: Date.now()})
    return c
}

export function forgetProject(id) {
    projects.delete(id)
}

const TABS = [['overview', '', 'Overview', 'home'], ['tree', '/tree', 'Files', 'folder'], ['changes', '/changes', 'Changes', 'change']]
const MEMBER_TABS = [['stacks', '/stacks', 'Stacks', 'stack'], ['proposals', '/proposals', 'Proposals', 'branch']]

// The crumbs of a project: its org, then the project.
export function projectCrumbs(p) {
    const org = p.org_name || 'Organization'
    return [{label: org, href: roleIn(p.org) ? `/org/${p.org}` : null}, {label: p.name || short(p.id), href: `/p/${p.id}`}]
}

// A project's name and tabs above one of its views.
export function projectHead(p, tab) {
    const base = `/p/${p.id}`
    const tabs = roleIn(p.org) ? [...TABS, ...MEMBER_TABS] : TABS
    return html`<header class="project-head">
        <div class="project-title">
            ${avatar(p.name || '?', p.id, true)}
            <div>
                <h1>${p.name || short(p.id)}</h1>
                <p class="quiet">${p.org_name || 'Organization'} · ${p.public ? 'Public project' : html`<span class="inline-icon">${icon('lock')}Private project</span>`}</p>
            </div>
        </div>
        <nav class="tabs" aria-label="Project">${tabs.map(([key, path, label, name]) =>
            html`<a href=${base + path} class=${key === tab ? 'active' : null} aria-current=${key === tab ? 'page' : null}>${icon(name)}<span>${label}</span></a>`)}</nav>
    </header>`
}

// A view of a project: its head, then what body makes of the project and of
// what fetch answers for it. title and crumbs(project, data) name the page.
export function projectPage(id, tab, fetch, body, {title, crumbs, shape = 'rows'} = {}) {
    const fetched = new Map()
    return loaded(() => {
        const project = loadProject(id)
        const ready = project.peek()
        if (ready && !fetch) return {peek: () => ({value: {project: ready.value, data: null}})}
        return (async () => {
            const p = await project.get()
            return {project: p, data: fetch ? await fetch(p, fetched) : null}
        })()
    }, ({project, data}, view) => {
        const label = typeof title === 'function' ? title(project, data) : title
        setPage({title: label, crumbs: [...projectCrumbs(project), ...(crumbs ? crumbs(project, data) : [{label}])]})
        return [projectHead(project, tab), html`<div class="project-body">${body(project, data, view)}</div>`]
    }, {skeleton: 'page'}).node
}

function revisionPicker(project, current, target) {
    const names = [...new Set(project.bookmarks.map(b => b.name))]
    const value = current || project.main || ''
    const options = names.map(n => html`<option value=${n} ?selected=${n === value}>${n}</option>`)
    if (value && !names.includes(value)) options.unshift(html`<option value=${value} selected>${short(value)}</option>`)
    return html`<label class="picker" title="Bookmark">${icon('branch')}<select aria-label="Bookmark" @change=${e => navigate(target(e.target.value))}>${options}</select>${icon('chevron-down')}</label>`
}

function pathCrumbs(project, rev, path) {
    const parts = path ? path.split('/') : []
    const at = i => href(`/p/${project.id}/tree`, {rev, path: parts.slice(0, i + 1).join('/')})
    return html`<nav class="path" aria-label="Path">
        <a href=${href(`/p/${project.id}/tree`, {rev})}>${project.name || 'root'}</a>
        ${parts.map((name, i) => [html`<span class="sep">/</span>`, i === parts.length - 1 ? html`<strong>${name}</strong>` : html`<a href=${at(i)}>${name}</a>`])}
    </nav>`
}

// --- Home ---

export function Home() {
    const root = el('div')
    const render = () => {
        const s = app.session
        const all = app.projects
        if (!s) {
            if (all === null) {
                setPage({title: 'KaiHub', crumbs: [{label: 'Home'}]})
                return html`<div class="page">${skeleton('page')}</div>`
            }
            if (all.length === 0) return authView('signin')
            setPage({title: 'Projects', crumbs: [{label: 'Projects'}]})
            return html`<div class="page">
                <header class="page-head">
                    <h1>Public projects</h1>
                    <p class="lead">Browse the public projects hosted on this server.</p>
                </header>
                <ul class="card-grid">${all.map(p => html`<li><a class="card project-card" href=${`/p/${p.id}`}>
                    <span class="card-head">${avatar(p.name || '?', p.id)}<span class="card-title">${p.name || short(p.id)}</span></span>
                    <span class="quiet">${p.org_name || 'Organization'}</span>
                </a></li>`)}</ul>
            </div>`
        }
        setPage({title: 'Home', crumbs: [{label: 'Home'}]})
        return html`<div class="page">
            <header class="page-head">
                <h1>Welcome back${s.name ? `, ${s.name.split(' ')[0]}` : ''}</h1>
                <p class="lead">Your projects, reviews and organizations in one place.</p>
            </header>
            ${onboarding(s)}
            <section class="section">
                <div class="section-head"><h2>Projects</h2></div>
                ${all === null ? skeleton('rows') : all.length === 0
                    ? empty('No projects yet', 'Make an organization and its first project, then publish files to it from your computer.',
                        html`<a class="button primary" href="/account">${icon('plus')}Get started</a>`)
                    : html`<ul class="card-grid">${all.map(p => html`<li><a class="card project-card" href=${`/p/${p.id}`}>
                        <span class="card-head">${avatar(p.name || '?', p.id)}<span class="card-title">${p.name || short(p.id)}</span>
                            ${p.public ? null : html`<span class="badge private">${icon('lock')}Private</span>`}</span>
                        <span class="quiet">${p.org_name || 'Organization'}</span>
                    </a></li>`)}</ul>`}
            </section>
            ${s.orgs.length ? html`<section class="section">
                <div class="section-head"><h2>Your organizations</h2></div>
                <ul class="card-grid">${s.orgs.map(o => html`<li><a class="card" href=${`/org/${o.org}`}>
                    <span class="card-head">${avatar(o.name || '?', o.org)}<span class="card-title">${o.name || 'Organization'}</span>${badge(o.role, 'neutral')}</span>
                    ${o.hosted ? meter(o.bytes, o.quota, 'Storage used') : html`<span class="quiet">Kept by your own server</span>`}
                </a></li>`)}</ul>
            </section>` : null}
        </div>`
    }
    const draw = mount(root, render)
    const stop = app.watch('projects', () => root.isConnected ? draw() : stop())
    return root
}

// --- Overview ---

// A README's relative link as a page of this project: a file, or a folder.
function readmeLink(p, base) {
    return target => {
        if (target.startsWith('#')) return target
        if (target.startsWith('/')) return target
        const [path, fragment] = target.split('#')
        const parts = (base ? base.split('/') : [])
        for (const part of path.split('/')) {
            if (part === '..') parts.pop()
            else if (part && part !== '.') parts.push(part)
        }
        const full = parts.join('/')
        return href(`/p/${p.id}/${path.endsWith('/') ? 'tree' : 'file'}`, {path: full}) + (fragment ? `#${fragment}` : '')
    }
}

export function Overview({params}) {
    return projectPage(params.project, 'overview', p => api(href(`/api/projects/${p.id}/changes`, {limit: 5})).catch(() => ({changes: []})), (p, recent) => {
        const folder = p.readme?.path.includes('/') ? p.readme.path.slice(0, p.readme.path.lastIndexOf('/')) : ''
        const landed = p.bookmarks.filter(b => b.landed)
        const work = p.bookmarks.filter(b => !b.landed)
        return html`<div class="split">
            <div class="main-column">${p.readme ? html`<article class="readme">
                <header class="readme-head">${icon('file')}<span>${p.readme.path}</span></header>
                ${markdown(p.readme.text, {resolve: readmeLink(p, folder)})}
                ${p.readme.truncated ? html`<p class="quiet">The README goes on past what the server shows. <a href=${href(`/p/${p.id}/file`, {path: p.readme.path})}>Open the whole file</a></p>` : null}
            </article>` : empty('No README yet', 'Add a README.md at the root of the project and it shows here.')}</div>
            <aside class="side-column">
                <section class="side-block">
                    <h2 class="side-title">Bookmarks</h2>
                    ${p.bookmarks.length === 0 ? html`<p class="quiet">Nothing is published yet.</p>` : html`<ul class="plain-list">${[...landed, ...work].map(b => html`<li class="bookmark">
                        <a href=${href(`/p/${p.id}/tree`, {rev: b.name})}>${icon('branch')}<strong>${b.name}</strong></a>
                        <span class="quiet">${b.landed ? 'shared' : html`<span>${b.device_name ? `on ${b.owner_name ? `${b.owner_name}'s ` : ''}${b.device_name}` : 'a device'} · ${ago(b.time)}</span>`}</span>
                    </li>`)}</ul>`}
                </section>
                <section class="side-block">
                    <h2 class="side-title">Recent changes</h2>
                    ${recent.changes.length === 0 ? html`<p class="quiet">No changes yet.</p>` : html`<ul class="plain-list">${recent.changes.map(c => html`<li class="mini-change">
                        ${avatar(c.author_name || '?', c.author)}<div><a href=${`/p/${p.id}/change/${c.revision}`}>${c.summary || 'No description'}</a>
                        <span class="quiet">${c.author_name || 'Someone'} · ${ago(c.written)}</span></div>
                    </li>`)}</ul>`}
                    <a class="more-link" href=${`/p/${p.id}/changes`}>All changes${icon('arrow-right')}</a>
                </section>
            </aside>
        </div>`
    }, {title: 'Overview', crumbs: () => []})
}

// --- Files ---

const byFolderThenName = (a, b) => (b.kind === 'folder') - (a.kind === 'folder') || a.name.localeCompare(b.name)

export function Tree({params, query}) {
    const {rev, path = ''} = query
    return projectPage(params.project, 'tree', p => api(href(`/api/projects/${p.id}/tree`, {rev, path})), (p, d) => html`<section class="surface">
        <header class="toolbar">${revisionPicker(p, rev, r => href(`/p/${p.id}/tree`, {rev: r, path}))}${pathCrumbs(p, rev, d.path)}</header>
        ${d.entries.length === 0 ? empty('This folder is empty') : html`<ul class="file-list">${d.path ? html`<li>
            <a href=${href(`/p/${p.id}/tree`, {rev, path: d.path.split('/').slice(0, -1).join('/')})}>${icon('folder')}<span>..</span></a></li>` : null}
            ${[...d.entries].sort(byFolderThenName).map(e => {
                const full = d.path ? `${d.path}/${e.name}` : e.name
                const folder = e.kind === 'folder'
                return html`<li>
                    <a href=${href(`/p/${p.id}/${folder ? 'tree' : 'file'}`, {rev, path: full})}>${icon(folder ? 'folder' : 'file')}<span>${e.name}</span></a>
                    ${e.conflicts || e.kind === 'conflict' ? badge('conflict', 'bad') : e.kind === 'executable' ? badge('executable', 'neutral') : null}
                    <span class="quiet tabular">${folder ? plural(e.files, 'file') : size(e.size)}</span>
                </li>`
            })}</ul>`}
    </section>`, {title: (p, d) => d.path ? d.path.split('/').pop() : 'Files', crumbs: (p, d) => [{label: 'Files', href: `/p/${p.id}/tree`}, ...(d.path ? [{label: d.path}] : [])]})
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
// here; null when the server has none.
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
    if (preview?.state === 'fetching') return html`<p class="notice">${icon('dot')}<span>The server is fetching what this asset is from your team's computers. Reload in a moment.</span></p>`
    if (!preview?.summary) return null
    return html`<div class="preview">
        ${preview.thumbnail ? html`<img class="thumb" src=${href(`/api/projects/${p.id}/thumbnail`, {rev, path})} alt=${path}>` : null}
        <dl class="facts">
            <dt>Kind</dt><dd>${preview.summary.kind}</dd>
            ${preview.summary.facts.map(f => [html`<dt>${f.label}</dt>`, html`<dd>${f.value}</dd>`])}
        </dl>
    </div>`
}

const isMarkdown = path => /\.(md|markdown)$/i.test(path)

function fileBody(p, rev, path, f, rendered) {
    const raw = href(`/api/projects/${p.id}/file`, {rev, path})
    const download = html`<a class="button" href=${raw} download>${icon('download')}Download</a>`
    const shown = previewBox(p, rev, path, f.preview)
    if (f.large) return [shown, html`<div class="pad">${empty('This file is too large to show here', f.large, download)}</div>`]
    if (f.image) return html`<div class="image-frame"><img class="shown" src=${f.image} alt=${path}></div>`
    if (f.binary !== undefined) return shown ? [shown, html`<p class="pad">${download}</p>`] : html`<div class="pad">
        <p class="quiet">Binary file, ${size(f.binary)}. Its first bytes:</p>
        <pre class="bytes">${Array.from(f.head, b => b.toString(16).padStart(2, '0')).join(' ')}</pre>
        <p>${download}</p>
    </div>`
    if (rendered) return html`<div class="pad">${markdown(f.text, {resolve: readmeLink(p, path.includes('/') ? path.slice(0, path.lastIndexOf('/')) : '')})}</div>`
    return codeView(f.text, path, raw)
}

function fileSize(f) {
    if (f.text !== undefined) return plural(f.text.split('\n').length - (f.text.endsWith('\n') ? 1 : 0), 'line')
    if (f.image) return `Image · ${size(f.size)}`
    if (f.binary !== undefined) return size(f.binary)
    return ''
}

export function FileView({params, query}) {
    const {rev, path = ''} = query
    let rendered = isMarkdown(path)
    return projectPage(params.project, 'tree', p => fileLoad(p, rev, path), (p, f, view) => {
        const raw = href(`/api/projects/${p.id}/file`, {rev, path})
        const toggle = value => () => {
            rendered = value
            view.draw()
        }
        return html`<section class="surface">
            <header class="toolbar">${revisionPicker(p, rev, r => href(`/p/${p.id}/file`, {rev: r, path}))}${pathCrumbs(p, rev, path)}</header>
            <div class="file-head">
                ${icon('file-code')}<strong>${path.split('/').pop()}</strong><span class="quiet tabular">${fileSize(f)}</span>
                <span class="toolbar-end">
                    ${f.text !== undefined && isMarkdown(path) ? html`<div class="segmented small" role="group" aria-label="View">
                        <button type="button" class=${rendered ? 'active' : null} @click=${toggle(true)}>${icon('eye')}<span>Preview</span></button>
                        <button type="button" class=${rendered ? null : 'active'} @click=${toggle(false)}>${icon('code')}<span>Code</span></button></div>` : null}
                    <a class="button small ghost" href=${raw} target="_blank" rel="noopener">${icon('external')}Raw</a>
                    <a class="button small ghost" href=${raw} download>${icon('download')}Download</a>
                </span>
            </div>
            ${fileBody(p, rev, path, f, rendered)}
        </section>`
    }, {title: path.split('/').pop() || 'File', crumbs: p => [{label: 'Files', href: `/p/${p.id}/tree`}, {label: path}]})
}

// --- Changes ---

function changeRow(p, c) {
    return html`<li class="change-row">
        ${avatar(c.author_name || '?', c.author)}
        <div class="change-main">
            <a href=${`/p/${p.id}/change/${c.revision}`} class="change-title">${c.summary || 'No description'}</a>
            <span class="quiet">${c.author_name || 'Someone'} · ${ago(c.written)}</span>
        </div>
        ${hash(c.change, `/p/${p.id}/change/${c.revision}`)}
    </li>`
}

export function Changes({params, query}) {
    const {rev} = query
    const page = Number(query.page || 0)
    const at = n => href(`/p/${params.project}/changes`, {rev, page: n || undefined})
    return projectPage(params.project, 'changes', p => api(href(`/api/projects/${p.id}/changes`, {rev, page: page || undefined})), (p, d) => html`<section class="surface">
        <header class="toolbar">${revisionPicker(p, rev, r => href(`/p/${p.id}/changes`, {rev: r}))}<span class="quiet toolbar-end">Newest first</span></header>
        ${d.changes.length === 0 ? empty('No changes here yet') : html`<ul class="change-list">${d.changes.map(c => changeRow(p, c))}</ul>`}
    </section>
    <nav class="pager">
        ${page > 0 ? html`<a class="button" href=${at(page - 1)}>Newer</a>` : html`<span></span>`}
        ${d.more ? html`<a class="button" href=${at(page + 1)}>Older${icon('arrow-right')}</a>` : null}
    </nav>`, {title: 'Changes'})
}

// What a change attaches, by type: "turn × 2".
function attachedText(list) {
    const counts = new Map()
    for (const a of list) counts.set(a.type, (counts.get(a.type) || 0) + 1)
    return [...counts].map(([type, n]) => n > 1 ? `${type} × ${n}` : type).join(', ')
}

const STATUS = {added: ['A', 'Added'], removed: ['D', 'Deleted'], modified: ['M', 'Modified'], conflict: ['C', 'Conflict']}

export function statusDot(status) {
    const [letter, label] = STATUS[status] ?? ['?', status]
    return html`<span class=${`status-dot ${status}`} title=${label} aria-label=${label}>${letter}</span>`
}

function viewedKey(key) {
    return `kai-viewed:${key}`
}

function viewedRead(key) {
    try {
        return new Set(JSON.parse(sessionStorage.getItem(viewedKey(key)) || '[]'))
    } catch {
        return new Set()
    }
}

function viewedWrite(key, set) {
    try {
        sessionStorage.setItem(viewedKey(key), JSON.stringify([...set]))
    } catch {}
}

// Files of a review: a sidebar of every file with its status, +/- once its
// diff is known and whether it was viewed, beside a section per file that
// section(file, sink) draws. sink.counts(d) tells the sidebar the diff's
// lines. key names what is reviewed, for the files viewed.
export function filesReview({files, key, section, extra = null}) {
    const viewed = viewedRead(key)
    const anchor = path => `file-${encodeURIComponent(path).replace(/[^\w-]/g, '_')}`
    const stats = new Map()
    const items = new Map()
    const tree = el('ul', 'review-tree')
    const sections = []
    const mark = (path, on) => {
        if (on) viewed.add(path)
        else viewed.delete(path)
        viewedWrite(key, viewed)
        items.get(path)?.classList.toggle('viewed', on)
        for (const box of document.querySelectorAll(`input[data-viewed="${CSS.escape(path)}"]`)) box.checked = on
        const s = document.getElementById(anchor(path))
        if (s) s.classList.toggle('collapsed', on)
        progress.textContent = `${viewed.size} of ${files.length} viewed`
    }
    const progress = el('span', 'quiet tabular', `${files.filter(f => viewed.has(f.path)).length} of ${files.length} viewed`)
    for (const f of files) {
        const count = el('span', 'tree-stat tabular')
        stats.set(f.path, count)
        const item = html`<li class=${viewed.has(f.path) ? 'viewed' : null}><a href=${`#${anchor(f.path)}`} title=${f.path}>${statusDot(f.status)}
            <span class="tree-name"><span class="tree-file">${f.path.split('/').pop()}</span><span class="tree-dir">${f.path.includes('/') ? f.path.slice(0, f.path.lastIndexOf('/')) : ''}</span></span>
            ${count}${viewed.has(f.path) ? icon('check') : null}</a></li>`
        items.set(f.path, item)
        tree.append(item)
        const sink = {
            counts(d) {
                if (d?.lines?.length) count.replaceChildren(diffStat(d))
            },
            viewed: () => viewed.has(f.path),
            viewedBox: () => html`<label class="viewed-box"><input type="checkbox" data-viewed=${f.path} ?checked=${viewed.has(f.path)}
                @change=${e => mark(f.path, e.target.checked)}>Viewed</label>`,
        }
        const node = section(f, sink)
        node.id = anchor(f.path)
        if (viewed.has(f.path)) node.classList.add('collapsed')
        sections.push(node)
    }
    return html`<div class="review">
        <aside class="review-side"><div class="review-side-inner">
            <div class="review-side-head"><strong>${plural(files.length, 'file')}</strong>${progress}</div>
            ${tree}
        </div></aside>
        <div class="review-main">${extra}${sections}</div>
    </div>`
}

// A file's diff in a review: its head with status, stat, links and the
// Viewed box, then the diff, loaded when it nears the screen.
export function diffSection(file, sink, {load, links = null, body = (d, draw) => diffView(d)}) {
    const section = html`<section class="file-box">
        <header class="file-head sticky">
            <button type="button" class="icon-button fold-file" aria-label="Fold the file">${icon('chevron-down')}</button>
            ${statusDot(file.status)}<strong class="path">${file.path}</strong><span class="head-stat"></span>
            <span class="toolbar-end">${links}${sink.viewedBox()}</span>
        </header>
        <div class="file-body">${skeleton('text')}</div>
    </section>`
    section.querySelector('.fold-file').addEventListener('click', () => section.classList.toggle('collapsed'))
    const target = section.querySelector('.file-body')
    let started = false
    const start = () => {
        if (started) return
        started = true
        const view = loaded(load, (d, v) => {
            sink.counts(d)
            if (d.lines?.length) section.querySelector('.head-stat').replaceChildren(diffStat(d))
            return body(d, () => v.draw())
        }, {skeleton: 'text'})
        target.replaceChildren(view.node)
        const redraw = () => view.node.isConnected ? view.draw() : removeEventListener('diff-mode', redraw)
        addEventListener('diff-mode', redraw)
    }
    // Loaded before (a draw again after a comment): at once, so the page keeps its height.
    if (load()?.peek?.() || typeof IntersectionObserver !== 'function') {
        start()
    } else {
        const seen = new IntersectionObserver(entries => {
            if (entries.some(e => e.isIntersecting)) {
                seen.disconnect()
                start()
            }
        }, {rootMargin: '600px 0px'})
        seen.observe(section)
    }
    return section
}

export function Change({params}) {
    const revision = params.revision
    const diffs = new Map()
    return projectPage(params.project, 'changes', p => api(`/api/projects/${p.id}/changes/${revision}`), (p, c) => {
        const [title, ...rest] = c.description.split('\n')
        const body = rest.join('\n').trim()
        const from = c.parents[0]
        return html`<div class="page-inner">
            <header class="change-head">
                <h2 class="title">${title || 'No description'}</h2>
                <div class="byline">${person(c.author_name, c.author)}<span class="quiet">wrote this ${ago(c.written)}</span>
                    ${c.coauthors.length ? html`<span class="quiet">with ${c.coauthors.map((a, i) => [i ? ', ' : '', a.name || short(a.key)])}</span>` : null}
                    <a class="pill" href=${`/p/${p.id}/evolution/${c.change}`}>${icon('change')}Revision history</a></div>
                ${body ? markdown(body) : null}
                ${technical([['Change ID', c.change], ['Revision', c.revision], ['Parent', c.parents.join(', ')], ['Created', when(c.created)], ['Written', when(c.written)],
                    ['Attached', c.attachments?.length ? attachedText(c.attachments) : '']])}
            </header>
            ${c.files_complete === false ? html`<div class="notice warn">${icon('alert')}<p>Some files of this change are not on this server yet.</p></div>` : null}
            <div class="section-head"><h2>Files changed <span class="count">${c.files.length}</span></h2>${diffModeSwitch()}</div>
            ${c.files.length === 0 ? empty('No files changed') : filesReview({files: c.files, key: c.revision, section: (f, sink) => diffSection(f, sink, {
                load: () => once(diffs, f.path, () => diffLoad(p, from, c.revision, f.path)),
                links: html`<a class="button small ghost" href=${href(`/p/${p.id}/file`, {rev: c.revision, path: f.path})}>View file</a>`,
                body: d => [d.asset ? assetDetail(d.asset) : null, d.assetState === 'fetching' ? html`<p class="quiet pad">The server is fetching what your team's computers recorded of this change. Reload in a moment.</p>` : null, diffView(d)],
            })})}
        </div>`
    }, {title: (p, c) => c.description.split('\n')[0] || 'Change', crumbs: (p, c) => [{label: 'Changes', href: `/p/${p.id}/changes`}, {label: c.description.split('\n')[0] || short(c.revision)}]})
}

// The line diff of a file, and of a binary one what peers recorded of the
// change of the asset it is.
export async function diffLoad(p, from, to, path) {
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

export function Diff({params, query}) {
    const {from, to, path} = query
    return projectPage(params.project, 'changes', p => diffLoad(p, from, to, path), (p, d, view) => {
        const redraw = () => view.node.isConnected ? view.draw() : removeEventListener('diff-mode', redraw)
        addEventListener('diff-mode', redraw)
        return html`<div class="page-inner">
            <div class="section-head"><p class="quiet range">${from ? hash(from, `/p/${p.id}/change/${from}`) : 'Nothing'} ${icon('arrow-right')} ${hash(to, `/p/${p.id}/change/${to}`)}</p>${diffModeSwitch()}</div>
            <section class="file-box">
                <header class="file-head">${statusDot(d.before ? d.after ? 'modified' : 'removed' : 'added')}<strong class="path">${path}</strong>${d.lines.length ? diffStat(d) : null}
                    <span class="toolbar-end"><a class="button small ghost" href=${href(`/p/${p.id}/file`, {rev: to, path})}>View file</a></span></header>
                ${d.asset ? assetDetail(d.asset) : null}
                ${d.assetState === 'fetching' ? html`<p class="quiet pad">The server is fetching what your team's computers recorded of this change. Reload in a moment.</p>` : null}
                ${diffView(d)}
            </section>
        </div>`
    }, {title: path?.split('/').pop() || 'Diff', crumbs: p => [{label: 'Changes', href: `/p/${p.id}/changes`}, {label: path}]})
}

// --- Revision history ---

function sinceBefore(p, d) {
    if (d.files.length === 0) return html`<p class="quiet small-text">Same content as the previous revision: rebased or reworded.</p>`
    return html`<div class="since"><span class="quiet">Changes since previous revision:</span>
        <ul class="inline-list">${d.files.map(f => html`<li><a href=${href(`/p/${p.id}/diff`, {from: d.from, to: d.to, path: f.path})}>${icon('file')}${f.path}</a></li>`)}</ul></div>`
}

export function Evolution({params}) {
    return projectPage(params.project, 'changes', p => api(`/api/projects/${p.id}/evolution/${params.change}`), (p, e) => html`<div class="page-inner">
        <header class="change-head"><h2 class="title">Revision history</h2>
            <p class="quiet">${plural(e.revisions.length, 'revision')} of one change, oldest first. Each time the change was rewritten, a new revision is recorded.</p></header>
        <ol class="timeline">${e.revisions.map((r, i) => html`<li>
            <span class="timeline-dot tabular">${i + 1}</span>
            <div class="timeline-body">
                <a href=${`/p/${p.id}/change/${r.revision}`} class="change-title">${r.summary || 'No description'}</a>
                <div class="byline">${person(r.author_name, r.author)}<span class="quiet">${ago(r.written)} · ${plural(r.files.length, 'file')}</span>${hash(r.revision)}</div>
                ${e.interdiffs[i - 1] ? sinceBefore(p, e.interdiffs[i - 1]) : null}
            </div>
        </li>`)}</ol>
    </div>`, {title: 'Revision history', crumbs: p => [{label: 'Changes', href: `/p/${p.id}/changes`}, {label: 'Revision history'}]})
}
