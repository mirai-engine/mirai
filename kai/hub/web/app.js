// KaiHub: the web view of a Kai node. One router over the views of
// views.js (public), member.js (members) and account.js (signing in).
import {createApp, h} from './vue.js'
import {api, refreshSession, state} from './api.js'
import {approvalPanel, SignIn} from './account.js'
import {NodeStats, Org, Proposal, Proposals, Stacks} from './member.js'
import {signOut} from './passkey.js'
import {errorBox, link, navigate, route, useAction} from './ui.js'
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

const App = {
    setup() {
        const out = useAction(async () => {
            await signOut()
            navigate('/')
        })
        const started = useAction(async () => {
            state.node = await api('/api/node')
            await refreshSession()
        })
        started.run()
        return () => {
            const found = match(route.path)
            const s = state.session
            return [
                h('header', {class: 'top'}, [
                    link('/', 'KaiHub', {class: 'brand'}),
                    h('nav', [
                        s ? link('/node', 'Node') : null,
                        s ? h('span', {class: 'who'}, s.name || 'signed in') : null,
                        s ? h('button', {type: 'button', class: 'link', onClick: out.run}, 'Sign out') : link('/signin', 'Sign in'),
                    ]),
                ]),
                h('main', [
                    approvalPanel(),
                    errorBox(started.error || out.error),
                    !state.node && !started.error ? h('p', {class: 'quiet'}, 'Loading…')
                        : found ? h(found.view, {key: `${route.path}?${new URLSearchParams(route.query)}|${s?.user ?? ''}`, params: found.params, query: route.query})
                        : h('p', {class: 'error'}, 'No such page here.'),
                ]),
            ]
        }
    },
}

createApp(App).mount('#app')
