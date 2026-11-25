// The server's JSON API (GET /api describes it) and what the page knows of
// the server and of who is signed in.
import {state} from './dom.js'

function storedMode() {
    try {
        return localStorage.getItem('kai-diff-mode') === 'split' ? 'split' : 'unified'
    } catch {
        return 'unified'
    }
}

export const app = state({
    node: null,      // GET /api/node
    session: null,   // GET /api/session, null when signed out
    projects: null,  // GET /api/projects: what the sidebar and search list
    approval: null,  // a device approval the page waits for: {command, state}
    signing: null,   // a passkey prompt the page waits for: {text, step, of}
    toasts: [],      // [{id, text, tone}]
    page: {title: '', crumbs: [], action: null}, // what the top bar shows
    diffMode: storedMode(), // unified or split
    sidebar: false,  // the drawer is open on a narrow screen
    search: false,   // the quick search is open
})

export class ApiError extends Error {
    constructor(status, message) {
        super(message)
        this.name = 'ApiError'
        this.status = status
    }
}

const UNREACHABLE = 'the server does not answer: check that it runs and that this computer reaches it'

// The response of a route, or an ApiError with the text the server gave.
export async function apiRaw(path, init = {}) {
    let response
    try {
        response = await fetch(path, {credentials: 'same-origin', ...init})
    } catch {
        throw new ApiError(0, UNREACHABLE)
    }
    if (response.ok) return response
    let text = `${response.status} ${response.statusText}`
    try {
        const body = await response.json()
        if (typeof body?.error === 'string') text = body.error
    } catch {}
    throw new ApiError(response.status, text)
}

// The JSON answer of a route; with a body, a POST of it.
export async function api(path, body) {
    const init = body === undefined ? {} : {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(body)}
    return (await apiRaw(path, init)).json()
}

// Who is signed in and the projects they see, set together so no view
// draws one without the other.
export async function refreshSession() {
    let session = null
    const projects = projectsLoad()
    try {
        session = await api('/api/session')
    } catch (error) {
        if (error.status !== 401) throw error
    }
    app.set({projects: await projects, session})
}

async function projectsLoad() {
    try {
        return (await api('/api/projects')).projects
    } catch {
        return app.projects ?? []
    }
}

export async function refreshProjects() {
    app.set({projects: await projectsLoad()})
}

// The session's role in an org, or '' when it is no member.
export function roleIn(org) {
    return app.session?.orgs.find(o => o.org === org)?.role ?? ''
}

// The orgs the page knows, each with its projects: the session's, then those
// of public projects, by name.
export function orgsKnown() {
    const orgs = new Map()
    for (const o of app.session?.orgs ?? []) orgs.set(o.org, {id: o.org, name: o.name, role: o.role, projects: []})
    for (const p of app.projects ?? []) {
        if (!orgs.has(p.org)) orgs.set(p.org, {id: p.org, name: p.org_name, role: '', projects: []})
        orgs.get(p.org).projects.push(p)
    }
    const list = [...orgs.values()]
    for (const o of list) o.projects.sort((a, b) => (a.name || '').localeCompare(b.name || ''))
    return list.sort((a, b) => (b.role !== '') - (a.role !== '') || (a.name || '').localeCompare(b.name || ''))
}

export function orgName(id) {
    return orgsKnown().find(o => o.id === id)?.name || 'Organization'
}
