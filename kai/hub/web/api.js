// The node's JSON API (GET /api describes it) and what the page knows of the
// node and of who is signed in.
import {state} from './dom.js'

export const app = state({
    node: null,     // GET /api/node
    session: null,  // GET /api/session, null when signed out
    approval: null, // a device approval the page waits for: {command, state}
    problem: null,  // the error of the last action that failed, shown until dismissed
})

export class ApiError extends Error {
    constructor(status, message) {
        super(message)
        this.name = 'ApiError'
        this.status = status
    }
}

const UNREACHABLE = 'the node does not answer: check that it runs and that this machine reaches it'

// The response of a route, or an ApiError with the text the node gave.
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

export async function refreshSession() {
    try {
        app.set({session: await api('/api/session')})
    } catch (error) {
        if (error.status !== 401) throw error
        app.set({session: null})
    }
}

// The session's role in an org, or '' when it is no member.
export function roleIn(org) {
    return app.session?.orgs.find(o => o.org === org)?.role ?? ''
}
