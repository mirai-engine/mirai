// KaiHub: the web view of a Kai node. The page's frame and one router over
// the views of views.js (public), member.js (members) and account.js.
import {html, mount} from './dom.js'
import {api, app, refreshSession} from './api.js'
import {approvalPanel, SignIn} from './account.js'
import {NodeStats, Org, Proposal, Proposals, Stacks} from './member.js'
import {signOut} from './passkey.js'
import {action, empty, failed, icon, navigate, report, waiting} from './ui.js'
import {Change, Changes, Diff, Evolution, FileView, Home, Overview, Tree} from './views.js'

const ROUTES = [
    ['/', Home],
    ['/signin', SignIn],
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

const signOutClick = action(async () => {
    await signOut()
    navigate('/')
})

function top() {
    const s = app.session
    return html`<div class="top-inner">
        <a class="brand" href="/">${icon('mark')}<span>KaiHub</span></a>
        <nav class="top-nav" aria-label="Account">${s
            ? [html`<a href="/node">Node</a>`, html`<a class="who" href="/signin" title=${s.user}>${s.name || 'Signed in'}</a>`,
                html`<button type="button" class="ghost small" @click=${signOutClick}>Sign out</button>`]
            : html`<a class="button small" href="/signin">Sign in</a>`}</nav>
    </div>`
}

function view() {
    if (!app.node) return waiting()
    const found = match(location.pathname)
    if (!found) return empty('No such page here', 'The address names nothing this node shows.')
    return found.view({params: found.params, query: Object.fromEntries(new URLSearchParams(location.search))})
}

function problem() {
    if (!app.problem) return null
    return html`<div class="toast" role="alert">${icon('alert')}<p>${app.problem}</p>
        <button type="button" class="ghost small" aria-label="Dismiss" @click=${() => app.set({problem: null})}>${icon('cross')}</button></div>`
}

const body = html`<div class="shell">
    <header class="top"></header>
    <main><div class="approval-slot"></div><div class="view"></div></main>
    <div class="toast-slot"></div>
</div>`
document.getElementById('app').replaceChildren(body)

const drawTop = mount(body.querySelector('.top'), top)
const drawView = mount(body.querySelector('.view'), view)
app.watch('approval', mount(body.querySelector('.approval-slot'), approvalPanel))
app.watch('problem', mount(body.querySelector('.toast-slot'), problem))

// A view draws again when the route changes or someone else signs in.
let user // undefined until the session is known
app.watch('session', () => {
    drawTop()
    if ((app.session?.user ?? null) === user) return
    user = app.session?.user ?? null
    drawView()
})
addEventListener('route', drawView)
addEventListener('popstate', drawView)

// A link to a page of this view goes through the router.
document.addEventListener('click', event => {
    const a = event.target.closest('a[href]')
    if (!a || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || a.target || a.hasAttribute('download')) return
    const url = new URL(a.href)
    if (url.origin !== location.origin || url.pathname.startsWith('/api/')) return
    event.preventDefault()
    navigate(url.pathname + url.search)
})

addEventListener('unhandledrejection', event => report(event.reason))

try {
    app.set({node: await api('/api/node')})
    await refreshSession()
} catch (error) {
    body.querySelector('.view').replaceChildren(failed(error))
}
