// KaiHub: the web view of a Kai server. The app's shell (sidebar, top bar
// with breadcrumbs, quick search, toasts) and one router over the views of
// views.js (public), member.js (members) and account.js.
import {el, html, mount, nodes} from './dom.js'
import {api, app, orgsKnown, refreshSession} from './api.js'
import {Account, approvalPanel, SignUp} from './account.js'
import {NodeStats, Org, Proposal, Proposals, Stacks} from './member.js'
import {signOut} from './passkey.js'
import {action, avatar, brandMark, dismiss, empty, failed, href, icon, navigate, report, setPage, short, skeleton} from './ui.js'
import {Change, Changes, Diff, Evolution, FileView, Home, Overview, Tree} from './views.js'

const ROUTES = [
    ['/', Home],
    ['/signin', Account],
    ['/signup', SignUp],
    ['/account', Account],
    ['/node', NodeStats],
    ['/org/:org', Org],
    ['/proposal/:proposal', Proposal],
    ['/p/:project', Overview],
    ['/p/:project/tree', Tree],
    ['/p/:project/file', FileView],
    ['/p/:project/changes', Changes],
    ['/p/:project/change/:revision', Change],
    ['/p/:project/diff', Diff],
    ['/p/:project/evolution/:change', Evolution],
    ['/p/:project/stacks', Stacks],
    ['/p/:project/proposals', Proposals],
]

// The view of a path and its parameters, or null.
function match(path) {
    const parts = path.replace(/\/+$/, '').split('/').slice(1)
    for (const [pattern, view] of ROUTES) {
        const want = pattern === '/' ? [] : pattern.split('/').slice(1)
        if (want.length !== parts.length) continue
        const params = {}
        const fits = want.every((w, i) => {
            if (!w.startsWith(':')) return w === parts[i]
            try {
                params[w.slice(1)] = decodeURIComponent(parts[i])
            } catch {
                return false
            }
            return parts[i] !== ''
        })
        if (fits) return {view, params}
    }
    return null
}

// The project the page shows, if any: what the sidebar marks and search looks in.
function currentProject() {
    return /^\/p\/([0-9a-f]{64})/.exec(location.pathname)?.[1] ?? ''
}

const signOutClick = action(async () => {
    await signOut()
    navigate('/')
}, 'Signed out')

// --- Sidebar ---

const collapsed = new Set()

function sidebar() {
    const s = app.session
    const here = currentProject()
    const path = location.pathname
    const orgs = orgsKnown()
    const toggle = id => event => {
        if (event.currentTarget.open) collapsed.delete(id)
        else collapsed.add(id)
    }
    return [
        html`<div class="side-top">
            <a class="brand" href="/" aria-label="KaiHub home">${brandMark()}<span>KaiHub</span></a>
            <button type="button" class="icon-button close-drawer" aria-label="Close the menu" @click=${() => app.set({sidebar: false})}>${icon('cross')}</button>
        </div>`,
        html`<button type="button" class="search-button" @click=${openSearch}>${icon('search')}<span>Search</span><kbd>⌘K</kbd></button>`,
        html`<nav class="side-nav" aria-label="Main">
            <a href="/" class=${path === '/' ? 'active' : null} aria-current=${path === '/' ? 'page' : null}>${icon('home')}<span>Home</span></a>
        </nav>`,
        html`<div class="side-section">
            <h2 class="side-heading">Organizations</h2>
            ${app.projects === null ? skeleton('rows') : orgs.length === 0 ? html`<p class="side-empty">No organizations yet.</p>` : html`<ul class="tree">${orgs.map(o => html`<li>
                <details ?open=${!collapsed.has(o.id)} @toggle=${toggle(o.id)}>
                    <summary class=${path === `/org/${o.id}` ? 'active' : null}>${icon('chevron-right')}${avatar(o.name || '?', o.id)}
                        ${o.role ? html`<a href=${`/org/${o.id}`} class="tree-org">${o.name || short(o.id)}</a>` : html`<span class="tree-org">${o.name || short(o.id)}</span>`}</summary>
                    ${o.projects.length === 0 ? html`<p class="side-empty indent">No projects yet</p>` : html`<ul>${o.projects.map(p => html`<li>
                        <a href=${`/p/${p.id}`} class=${p.id === here ? 'active' : null} aria-current=${p.id === here ? 'page' : null}>
                            ${icon(p.public ? 'git' : 'lock')}<span>${p.name || short(p.id)}</span></a></li>`)}</ul>`}
                </details></li>`)}</ul>`}
        </div>`,
        html`<div class="side-bottom">${s
            ? [html`<div class="account-card">
                <a href="/account" class="account-link" title="Your account, devices and user ID">${avatar(s.name || '?', s.user)}
                    <span class="account-text"><strong>${s.name || 'Signed in'}</strong><span>Account and devices</span></span></a>
                <button type="button" class="icon-button" title="Sign out" aria-label="Sign out" @click=${signOutClick}>${icon('sign-out')}</button>
            </div>`, html`<a class="server-link" href="/node">${icon('server')}<span>Server status</span></a>`]
            : html`<a class="button primary wide" href="/signin">${icon('key')}Sign in</a>`}</div>`,
    ]
}

// --- Top bar ---

function shellMode() {
    if (app.session) return 'app'
    const path = location.pathname.replace(/\/+$/, '') || '/'
    if (path === '/signin' || path === '/signup') return 'auth'
    if (path === '/' && app.projects !== null && app.projects.length === 0) return 'auth'
    return 'public'
}

function topbar() {
    const {crumbs, action: primary} = app.page
    const signedOut = !app.session
    return html`<div class="topbar-inner">
        ${signedOut
            ? html`<a class="brand top-brand" href="/" aria-label="KaiHub home">${brandMark()}<span>KaiHub</span></a>`
            : html`<button type="button" class="icon-button menu-button" aria-label="Open the menu" @click=${() => app.set({sidebar: true})}>${icon('menu')}</button>`}
        <nav class="crumbs" aria-label="Breadcrumbs"><ol>${crumbs.map((c, i) => html`<li>
            ${i ? icon('chevron-right') : null}${c.href && i < crumbs.length - 1 ? html`<a href=${c.href}>${c.label}</a>` : html`<span aria-current=${i === crumbs.length - 1 ? 'page' : null}>${c.label}</span>`}
        </li>`)}</ol></nav>
        <div class="topbar-end">${primary ?? null}
            <button type="button" class="icon-button search-icon" aria-label="Search" @click=${openSearch}>${icon('search')}</button>
            ${signedOut ? html`<a class="button primary small" href="/signin">Sign in</a>` : null}</div>
    </div>`
}

// --- Quick search ---

const fileIndex = new Map() // project -> cell of its file paths
const FILES_MAX = 3000
const FOLDERS_MAX = 40

// The files of a project's main bookmark, folder by folder, within bounds.
function projectFiles(project) {
    if (!fileIndex.has(project)) {
        fileIndex.set(project, (async () => {
            const files = []
            const queue = ['']
            let asked = 0
            while (queue.length && asked < FOLDERS_MAX && files.length < FILES_MAX) {
                const path = queue.shift()
                asked++
                let d
                try {
                    d = await api(href(`/api/projects/${project}/tree`, {path}))
                } catch {
                    break
                }
                for (const e of d.entries) {
                    const full = path ? `${path}/${e.name}` : e.name
                    if (e.kind === 'folder') queue.push(full)
                    else files.push(full)
                }
            }
            return files
        })().catch(() => {
            fileIndex.delete(project)
            return []
        }))
    }
    return fileIndex.get(project)
}

function openSearch() {
    app.set({search: true, sidebar: false})
}

function searchPanel() {
    if (!app.search) return null
    const project = currentProject()
    const known = (app.projects ?? []).find(p => p.id === project)
    let files = [], changes = []
    let selected = 0
    const close = () => app.set({search: false})
    const input = html`<input class="search-input" type="search" placeholder=${known ? `Search projects, or files and changes of ${known.name}` : 'Search organizations and projects'}
        aria-label="Search" autocomplete="off" spellcheck="false">`
    const list = el('div', 'search-results')
    const results = () => {
        const q = input.value.trim().toLowerCase()
        const has = text => (text || '').toLowerCase().includes(q)
        const groups = []
        const orgs = orgsKnown().filter(o => has(o.name)).slice(0, 5)
        if (orgs.length) groups.push(['Organizations', orgs.map(o => ({label: o.name || short(o.id), hint: o.role || 'public projects', target: o.role ? `/org/${o.id}` : `/p/${o.projects[0]?.id}`, icon: 'building'}))])
        const projects = (app.projects ?? []).filter(p => has(p.name) || has(p.org_name)).slice(0, 8)
        if (projects.length) groups.push(['Projects', projects.map(p => ({label: p.name || short(p.id), hint: p.org_name, target: `/p/${p.id}`, icon: p.public ? 'git' : 'lock'}))])
        if (project && q) {
            const found = files.filter(f => f.toLowerCase().includes(q)).slice(0, 8)
            if (found.length) groups.push([`Files in ${known?.name ?? 'this project'}`, found.map(f => ({label: f.split('/').pop(), hint: f, target: href(`/p/${project}/file`, {path: f}), icon: 'file'}))])
        }
        if (project) {
            const recent = changes.filter(c => !q || has(c.summary) || has(c.author_name)).slice(0, q ? 6 : 5)
            if (recent.length) groups.push([q ? 'Changes' : 'Recent changes', recent.map(c => ({label: c.summary || 'No description', hint: c.author_name || '', target: `/p/${project}/change/${c.revision}`, icon: 'change'}))])
        }
        return groups
    }
    const draw = () => {
        const groups = results()
        const flat = groups.flatMap(g => g[1])
        selected = Math.min(selected, Math.max(0, flat.length - 1))
        let k = 0
        list.replaceChildren(...nodes(flat.length === 0
            ? html`<p class="search-empty">Nothing matches “${input.value}”.</p>`
            : groups.map(([title, items]) => html`<section><h3>${title}</h3><ul>${items.map(item => {
                const index = k++
                return html`<li><a href=${item.target} class=${index === selected ? 'active' : null} @click=${close}>${icon(item.icon)}
                    <span class="result-label">${item.label}</span><span class="result-hint">${item.hint}</span></a></li>`
            })}</ul></section>`)))
        list.querySelector('a.active')?.scrollIntoView({block: 'nearest'})
        return flat
    }
    input.addEventListener('input', () => {
        selected = 0
        draw()
    })
    input.addEventListener('keydown', event => {
        const flat = results().flatMap(g => g[1])
        if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
            event.preventDefault()
            selected = (selected + (event.key === 'ArrowDown' ? 1 : -1) + flat.length) % Math.max(1, flat.length)
            draw()
        } else if (event.key === 'Enter' && flat[selected]) {
            event.preventDefault()
            close()
            navigate(flat[selected].target)
        } else if (event.key === 'Escape') {
            close()
        }
    })
    if (project) {
        projectFiles(project).then(f => {
            files = f
            draw()
        })
        api(`/api/projects/${project}/changes`).then(d => {
            changes = d.changes
            draw()
        }, () => {})
    }
    draw()
    const panel = html`<div class="search-overlay" @click=${e => e.target === e.currentTarget && close()}>
        <div class="search-panel" role="dialog" aria-modal="true" aria-label="Quick search">
            <div class="search-field">${icon('search')}${input}<kbd>Esc</kbd></div>
            ${list}
        </div>
    </div>`
    queueMicrotask(() => input.focus())
    return panel
}

// --- What the page waits for, and toasts ---

function signingPanel() {
    const s = app.signing
    if (!s) return null
    return html`<div class="signing" role="status">${el('span', 'pulse', icon('key'))}
        <div><strong>${s.of > 1 ? `Step ${s.step} of ${s.of} · ` : ''}Confirm with your passkey</strong><span>${s.text}</span></div></div>`
}

function toasts() {
    return app.toasts.map(t => html`<div class=${`toast ${t.tone}`} role=${t.tone === 'bad' ? 'alert' : 'status'}>
        ${icon(t.tone === 'bad' ? 'x-circle' : t.tone === 'info' ? 'dot' : 'check-circle')}<p>${t.text}</p>
        <button type="button" class="icon-button" aria-label="Dismiss" @click=${() => dismiss(t.id)}>${icon('cross')}</button></div>`)
}

// --- The router ---

function view() {
    if (!app.node) return skeleton('page')
    const found = match(location.pathname)
    if (!found) {
        setPage({title: 'Not found', crumbs: [{label: 'Not found'}]})
        return html`<div class="page">${empty('There is nothing here', 'The address names no page of this server.', html`<a class="button primary" href="/">Go home</a>`)}</div>`
    }
    return found.view({params: found.params, query: Object.fromEntries(new URLSearchParams(location.search))})
}

const body = html`<div class="shell">
    <aside class="sidebar" aria-label="Navigation"></aside>
    <div class="backdrop" aria-hidden="true"></div>
    <div class="main-area">
        <header class="topbar"></header>
        <div class="approval-slot"></div>
        <main class="view" id="main"></main>
    </div>
    <div class="signing-slot"></div>
    <div class="toast-slot" aria-live="polite"></div>
    <div class="search-slot"></div>
</div>`
document.getElementById('app').replaceChildren(body)
body.querySelector('.backdrop').addEventListener('click', () => app.set({sidebar: false}))

const syncShell = () => {
    body.dataset.mode = shellMode()
    drawTop()
}

const drawSidebar = mount(body.querySelector('.sidebar'), sidebar)
const drawTop = mount(body.querySelector('.topbar'), topbar)
const drawView = mount(body.querySelector('.view'), view)
app.watch('approval', mount(body.querySelector('.approval-slot'), approvalPanel))
app.watch('signing', mount(body.querySelector('.signing-slot'), signingPanel))
app.watch('toasts', mount(body.querySelector('.toast-slot'), toasts))
app.watch('search', mount(body.querySelector('.search-slot'), searchPanel))
app.watch('page', syncShell)
app.watch('projects', () => {
    syncShell()
    drawSidebar()
})
app.watch('sidebar', () => body.classList.toggle('drawer-open', app.sidebar))
app.watch('diffMode', () => dispatchEvent(new Event('diff-mode')))

// A view draws again when the route changes or someone else signs in.
let user // undefined until the session is known
app.watch('session', () => {
    syncShell()
    drawSidebar()
    if ((app.session?.user ?? null) === user) return
    user = app.session?.user ?? null
    drawView()
})
const routed = () => {
    app.set({sidebar: false})
    syncShell()
    drawSidebar()
    drawView()
}
syncShell()
addEventListener('route', routed)
addEventListener('popstate', routed)

// A link to a page of this view goes through the router.
document.addEventListener('click', event => {
    const a = event.target.closest('a[href]')
    if (!a || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || a.target || a.hasAttribute('download')) return
    const url = new URL(a.href)
    if (url.origin !== location.origin || url.pathname.startsWith('/api/')) return
    event.preventDefault()
    if (url.pathname === location.pathname && url.search === location.search && url.hash) {
        document.getElementById(url.hash.slice(1))?.scrollIntoView({block: 'start'})
        return
    }
    navigate(url.pathname + url.search)
})

// ⌘K, Ctrl+K and / open the quick search; / not while typing.
document.addEventListener('keydown', event => {
    const typing = event.target.closest?.('input, textarea, select, [contenteditable]')
    if ((event.key === 'k' && (event.metaKey || event.ctrlKey)) || (event.key === '/' && !typing)) {
        event.preventDefault()
        openSearch()
    } else if (event.key === 'Escape' && app.sidebar) {
        app.set({sidebar: false})
    }
})

addEventListener('unhandledrejection', event => report(event.reason))

try {
    app.set({node: await api('/api/node')})
    await refreshSession()
} catch (error) {
    body.querySelector('.view').replaceChildren(failed(error, () => location.reload()))
}
