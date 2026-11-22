// The node's JSON API (GET /api describes it) and what the page knows of the
// node and of who is signed in.
import {reactive} from './vue.js'

export const state = reactive({
    node: null,    // GET /api/node
    session: null, // GET /api/session, null when signed out
    approval: null, // a device approval the page waits for: {command, state}
})

export class ApiError extends Error {
    constructor(status, message) {
        super(message)
        this.status = status
    }
}

async function failure(response) {
    let text = `${response.status} ${response.statusText}`
    try {
        const body = await response.json()
        if (body && typeof body.error === 'string') text = body.error
    } catch {}
    return new ApiError(response.status, text)
}

// The answer of a route of the API; its error text when it fails.
export async function api(path, body) {
    const init = {credentials: 'same-origin', headers: {}}
    if (body !== undefined) {
        init.method = 'POST'
        init.headers['Content-Type'] = 'application/json'
        init.body = JSON.stringify(body)
    }
    let response
    try {
        response = await fetch(path, init)
    } catch {
        throw new ApiError(0, 'the node does not answer: check that it runs and that this machine reaches it')
    }
    if (!response.ok) throw await failure(response)
    return response.json()
}

// The raw answer of a route that does not answer JSON, as the file route.
export async function apiRaw(path) {
    let response
    try {
        response = await fetch(path, {credentials: 'same-origin'})
    } catch {
        throw new ApiError(0, 'the node does not answer: check that it runs and that this machine reaches it')
    }
    if (!response.ok) throw await failure(response)
    return response
}

export async function refreshSession() {
    try {
        state.session = await api('/api/session')
    } catch (error) {
        if (error.status !== 401) throw error
        state.session = null
    }
}

// The session's role in an org, or '' when it is no member.
export function roleIn(org) {
    return state.session?.orgs.find(o => o.org === org)?.role ?? ''
}
