// Passkeys and signed writes. The server never hands this page a challenge
// to sign for a write: the page checks the draft's bytes against what the
// user asked and signs their BLAKE3. A new user is born of its passkey alone:
// this page makes no key of its own, and the user's first device, linked
// later, sets its recovery key.
import {api, app, refreshProjects, refreshSession} from './api.js'
import {blake3} from './blake3.js'
import {
    attestedCredential, b64, deviceLinkCode, draftCheck, entryUnsigned, equal,
    passkeyGenesisBody, SIG_WEBAUTHN, TYPES, unb64, unhex, webKeyId,
} from './entry.js'

const TIMEOUT_MS = 120000
const POLL_MS = 2000
const KNOWN = 'kai-passkeys'   // credential id -> COSE key of the passkeys made in this browser
const CREDENTIAL = 'kai-credential' // the credential id the session signed in with

function storageGet(storage, key) {
    try {
        return storage.getItem(key)
    } catch {
        return null
    }
}

function storageSet(storage, key, value) {
    try {
        storage.setItem(key, value)
    } catch {}
}

function known() {
    try {
        return JSON.parse(storageGet(localStorage, KNOWN) || '{}')
    } catch {
        return {}
    }
}

function remember(credential, cose) {
    const all = known()
    all[b64(credential)] = b64(cose)
    storageSet(localStorage, KNOWN, JSON.stringify(all))
}

function passkeysWork() {
    if (!app.node?.passkeys_work) throw new Error('passkeys need this server over HTTPS on its domain: this address serves reads; approve from your computer instead')
    if (!window.PublicKeyCredential) throw new Error('this browser has no passkeys: approve with a device instead')
}

function webauthnError(error) {
    if (error?.name === 'NotAllowedError') return new Error('the passkey prompt was dismissed or timed out')
    if (error?.name === 'InvalidStateError') return new Error('this authenticator holds a passkey of this site already')
    return error instanceof Error ? error : new Error(String(error))
}

// What the page shows while the browser's passkey prompt is up.
async function prompting(text, work) {
    app.set({signing: text})
    try {
        return await work()
    } finally {
        if (app.signing === text) app.set({signing: null})
    }
}

async function assertion(challenge, credential, text = {text: 'Confirm with your passkey'}) {
    const publicKey = {challenge, rpId: app.node.rp_id, userVerification: 'required', timeout: TIMEOUT_MS}
    if (credential) publicKey.allowCredentials = [{type: 'public-key', id: credential}]
    let c
    try {
        c = await prompting(text, () => navigator.credentials.get({publicKey}))
    } catch (error) {
        throw webauthnError(error)
    }
    const r = c.response
    return {
        credential: b64(new Uint8Array(c.rawId)),
        authenticator_data: b64(new Uint8Array(r.authenticatorData)),
        client_data_json: b64(new Uint8Array(r.clientDataJSON)),
        signature: b64(new Uint8Array(r.signature)),
    }
}

export async function signIn() {
    passkeysWork()
    const given = await api('/api/session/challenge', {})
    const a = await assertion(unb64(given.challenge), undefined, {text: 'Sign in with your passkey'})
    await api('/api/session', {challenge: given.challenge, assertion: a})
    storageSet(sessionStorage, CREDENTIAL, a.credential)
    await refreshSession()
}

export async function signOut() {
    await api('/api/session/end', {})
    app.set({session: null})
}

// A new passkey of this site: its credential id and its COSE key.
async function passkeyCreate(name, prompt = {text: 'Create a passkey for this browser'}) {
    passkeysWork()
    let c
    try {
        c = await prompting(prompt, () => navigator.credentials.create({publicKey: {
            rp: {id: app.node.rp_id, name: 'Kai'},
            user: {id: crypto.getRandomValues(new Uint8Array(16)), name, displayName: name},
            challenge: crypto.getRandomValues(new Uint8Array(32)),
            pubKeyCredParams: [{type: 'public-key', alg: -8}, {type: 'public-key', alg: -7}],
            authenticatorSelection: {residentKey: 'required', userVerification: 'required'},
            attestation: 'none',
            timeout: TIMEOUT_MS,
        }}))
    } catch (error) {
        throw webauthnError(error)
    }
    const made = attestedCredential(new Uint8Array(c.response.getAuthenticatorData()))
    if (!equal(made.credential, new Uint8Array(c.rawId))) throw new Error('the authenticator names another credential than the one it made')
    return made
}

// A user whose first passkey is this one, and nothing else: the passkey
// signs the genesis of its log over the BLAKE3 of the bytes this page built,
// and that signature signs the user in. Answers the user id, which waits on
// the server until an admin adds it to an org or it makes one.
export async function register(name) {
    const {credential, cose} = await passkeyCreate(name, {text: 'Create your passkey', step: 1, of: 2})
    const rp = app.node.rp_id
    const unsigned = entryUnsigned({
        type: TYPES.passkey_genesis, author: webKeyId(cose, rp), time: BigInt(Date.now()) * 1000000n,
        body: passkeyGenesisBody(credential, cose, rp, name), sig: SIG_WEBAUTHN,
    })
    const signed = await assertion(blake3(unsigned), credential, {text: 'Confirm your new passkey', step: 2, of: 2})
    const made = await api('/api/users', {unsigned: b64(unsigned), assertion: signed})
    remember(credential, cose)
    storageSet(sessionStorage, CREDENTIAL, b64(credential))
    await refreshSession()
    return {user: made.user}
}

// Waits for a device to answer an approval the page shows.
async function approvalWait(a) {
    const shown = {command: a.command, state: 'waiting'}
    app.set({approval: shown})
    try {
        for (;;) {
            await new Promise(done => setTimeout(done, POLL_MS))
            if (app.approval !== shown) throw new Error('the approval was dismissed')
            const r = await api(`/api/approvals/${a.id}/state`, {secret: a.secret})
            shown.state = r.state
            app.set({approval: shown})
            if (r.state === 'approved') return r
            if (r.state !== 'waiting') throw new Error(`the approval was ${r.state}: ask again`)
        }
    } finally {
        if (app.approval === shown) app.set({approval: null})
    }
}

// Links a new passkey of this browser to the session's user: a device of the user approves it.
export async function link(user, name) {
    const {credential, cose} = await passkeyCreate(name)
    const a = await api('/api/passkeys/link', {user, credential: b64(credential), cose: b64(cose)})
    remember(credential, cose)
    await approvalWait(a)
}

// Links a machine as a device of this session's user: the machine runs the
// command shown and offers itself; answers its offer, with the code it
// shows, and the approval, which says when the machine set the recovery key.
export async function linkOffer() {
    const a = await api('/api/approvals', {kind: 'device'})
    const shown = {command: a.command, state: 'waiting', kind: 'device'}
    app.set({approval: shown})
    try {
        for (;;) {
            await new Promise(done => setTimeout(done, POLL_MS))
            if (app.approval !== shown) return null
            const r = await api(`/api/approvals/${a.id}/state`, {secret: a.secret})
            if (r.state !== 'waiting') throw new Error(`the link was ${r.state}: ask again`)
            if (!r.offer) continue
            if (r.offer.code !== deviceLinkCode(unhex(r.offer.device, 32))) throw new Error('the server gives another code than the computer\'s key makes: do not link it')
            return {...r.offer, approval: a}
        }
    } finally {
        if (app.approval === shown) app.set({approval: null})
    }
}

// Signs the Device_Add of an offer the person compared the code of.
export async function linkDevice(offer) {
    return write({type: 'device_add', log: app.session.user, device: offer.device, dh: offer.dh, kem: offer.kem, proof: offer.proof, name: offer.name},
        {text: `Link ${offer.name} to your account`})
}

// Waits for the machine just linked to set the user's first recovery key,
// which it shows there once: only its entry reaches the node.
export async function recoveryWait(offer) {
    const a = offer.approval
    for (;;) {
        await new Promise(done => setTimeout(done, POLL_MS))
        const r = await api(`/api/approvals/${a.id}/state`, {secret: a.secret})
        if (r.recovered) break
        if (r.state === 'denied' || r.state === 'expired') throw new Error(`the link was ${r.state}: on the machine, mirai kai identity recovery sets the recovery key`)
    }
    await refreshSession()
}

// Makes an org this node hosts: the passkey signs its genesis, then the
// entry that adds this node to it. Answers the org's id.
export async function makeOrg(name) {
    const made = await write({type: 'org_genesis', owner: app.session.user, name}, {text: `Create ${name}`, step: 1, of: 2})
    await addThisNode(made.log, {step: 2, of: 2})
    return made.log
}

// The Node_Add of this node to an org, as GET /api/node describes the node.
export async function addThisNode(org, steps = {}) {
    const n = app.node
    await write({type: 'node_add', log: org, node: n.device, dh: n.dh, modes: ['relay', 'seed'], addresses: n.addresses},
        {text: 'Let this server keep the organization', ...steps})
    await refreshSession()
}

// Makes an empty project of an org: its genesis, then the org's Project_Add.
export async function makeProject(org, name, isPublic) {
    const made = await write({type: 'project_genesis', org, name, public: isPublic}, {text: `Create ${name}`, step: 1, of: 2})
    await write({type: 'project_add', log: org, project: made.log, public: isPublic}, {text: `Add ${name} to the organization`, step: 2, of: 2})
    await refreshProjects()
    return made.log
}

// Lands proposal x of GET /api/proposals on its target, as proposal_land
// signs it: the move of the project's target from the revisions it has
// landed (project, of GET /api/projects) to the final revision, then the
// proposal's Land naming the move. A move made already whose Land was not
// signed (x.landing) is finished.
export async function land(x, project) {
    let move = x.landing
    if (!move) {
        const from = project.bookmarks.filter(b => b.landed && b.name === x.target).map(b => b.revision)
        const made = await write({type: 'bookmark_move', log: x.project, proposal: x.id, bookmark: x.target, revision: x.revision, heads: x.heads, from},
            {text: `Move ${x.target} to the proposal's final revision`, step: 1, of: 2})
        move = made.address
    }
    await write({type: 'proposal_land', log: x.id, revision: x.revision, bookmark_move: move},
        {text: 'Mark the proposal landed', step: x.landing ? 1 : 2, of: x.landing ? 1 : 2})
}

// Signs in without a passkey: a device of the user approves the login.
export async function signInByDevice() {
    const a = await api('/api/approvals', {kind: 'login'})
    await approvalWait(a)
    await refreshSession()
}

// The author this session's passkey signs as: its web key id, from the COSE
// key this browser made when it has it, else as the session names it.
function author() {
    const named = unhex(app.session.passkey, 32)
    const credential = storageGet(sessionStorage, CREDENTIAL)
    const cose = credential && known()[credential]
    if (cose && !equal(webKeyId(unb64(cose), app.node.rp_id), named)) throw new Error('the server names another passkey for this session than the one it signed in with: sign in again')
    return named
}

// Writes an entry: the draft is checked, then its BLAKE3 signed by the
// passkey; a session without one has a device sign it. prompt is what the
// page says while the passkey asks: {text, step, of}.
export async function write(action, prompt = {text: 'Confirm with your passkey'}) {
    if (!app.session) throw new Error('sign in first')
    if (!app.session.passkey) {
        const a = await api('/api/approvals', {kind: 'entry', draft: action})
        return approvalWait(a)
    }
    const expected = author()
    const draft = await api('/api/drafts', action)
    const bytes = unb64(draft.unsigned)
    const why = draftCheck(bytes, action, expected, BigInt(Date.now()) * 1000000n)
    if (why) throw new Error(`the server prepared something other than what you asked, so nothing was signed: ${why}`)
    const credential = storageGet(sessionStorage, CREDENTIAL)
    const signed = await assertion(blake3(bytes), credential ? unb64(credential) : undefined, prompt)
    return api('/api/entries', {unsigned: draft.unsigned, assertion: signed})
}
