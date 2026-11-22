// Passkeys and signed writes. The server never hands this page a challenge
// to sign for a write: the page checks the draft's bytes against what the
// user asked and signs their BLAKE3. A new user is born of its passkey alone:
// this page makes no key of its own, and the user's first device, linked
// later, sets its recovery key.
import {api, refreshSession, state} from './api.js'
import {blake3} from './blake3.js'
import {
    attestedCredential, b64, deviceLinkCode, draftCheck, entryUnsigned, equal, layoutCheck,
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
    if (!state.node?.passkeys_work) throw new Error('passkeys need the node over HTTPS on its domain: this address serves reads; approve with a device instead')
    if (!window.PublicKeyCredential) throw new Error('this browser has no passkeys: approve with a device instead')
}

function webauthnError(error) {
    if (error?.name === 'NotAllowedError') return new Error('the passkey prompt was dismissed or timed out')
    if (error?.name === 'InvalidStateError') return new Error('this authenticator holds a passkey of this site already')
    return error instanceof Error ? error : new Error(String(error))
}

async function assertion(challenge, credential) {
    const publicKey = {challenge, rpId: state.node.rp_id, userVerification: 'required', timeout: TIMEOUT_MS}
    if (credential) publicKey.allowCredentials = [{type: 'public-key', id: credential}]
    let c
    try {
        c = await navigator.credentials.get({publicKey})
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
    const a = await assertion(unb64(given.challenge))
    await api('/api/session', {challenge: given.challenge, assertion: a})
    storageSet(sessionStorage, CREDENTIAL, a.credential)
    await refreshSession()
}

export async function signOut() {
    await api('/api/session/end', {})
    state.session = null
}

// A new passkey of this site: its credential id and its COSE key.
async function passkeyCreate(name) {
    passkeysWork()
    let c
    try {
        c = await navigator.credentials.create({publicKey: {
            rp: {id: state.node.rp_id, name: 'Kai'},
            user: {id: crypto.getRandomValues(new Uint8Array(16)), name, displayName: name},
            challenge: crypto.getRandomValues(new Uint8Array(32)),
            pubKeyCredParams: [{type: 'public-key', alg: -8}, {type: 'public-key', alg: -7}],
            authenticatorSelection: {residentKey: 'required', userVerification: 'required'},
            attestation: 'none',
            timeout: TIMEOUT_MS,
        }})
    } catch (error) {
        throw webauthnError(error)
    }
    const made = attestedCredential(new Uint8Array(c.response.getAuthenticatorData()))
    if (!equal(made.credential, new Uint8Array(c.rawId))) throw new Error('the authenticator names another credential than the one it made')
    return made
}

// A user whose first passkey is this one, and nothing else: the passkey
// signs the genesis of its log over the BLAKE3 of the bytes this page built.
// Answers the user id, which waits on the node until an admin adds it.
export async function register(name) {
    const {credential, cose} = await passkeyCreate(name)
    const rp = state.node.rp_id
    const unsigned = entryUnsigned({
        type: TYPES.passkey_genesis, author: webKeyId(cose, rp), time: BigInt(Date.now()) * 1000000n,
        body: passkeyGenesisBody(credential, cose, rp, name), sig: SIG_WEBAUTHN,
    })
    const signed = await assertion(blake3(unsigned), credential)
    const made = await api('/api/users', {unsigned: b64(unsigned), assertion: signed})
    remember(credential, cose)
    return {user: made.user}
}

// Waits for a device to answer an approval the page shows.
async function approvalWait(a) {
    state.approval = {command: a.command, state: 'waiting'}
    const shown = state.approval
    try {
        for (;;) {
            await new Promise(done => setTimeout(done, POLL_MS))
            if (state.approval !== shown) throw new Error('the approval was dismissed')
            const r = await api(`/api/approvals/${a.id}/state`, {secret: a.secret})
            shown.state = r.state
            if (r.state === 'approved') return r
            if (r.state !== 'waiting') throw new Error(`the approval was ${r.state}: ask again`)
        }
    } finally {
        if (state.approval === shown) state.approval = null
    }
}

// Links a new passkey to an existing user: a device of the user approves it.
export async function link(user, name) {
    if (!unhex(user, 32)) throw new Error('the user id is 64 hex: `mirai kai identity` prints it on a device of the user')
    const {credential, cose} = await passkeyCreate(name)
    const a = await api('/api/passkeys/link', {user, credential: b64(credential), cose: b64(cose)})
    remember(credential, cose)
    await approvalWait(a)
}

// Links a machine as a device of this session's user: the machine runs the
// command shown and offers itself; answers its offer, with the code it shows.
export async function linkOffer() {
    const a = await api('/api/approvals', {kind: 'device'})
    state.approval = {command: a.command, state: 'waiting'}
    const shown = state.approval
    try {
        for (;;) {
            await new Promise(done => setTimeout(done, POLL_MS))
            if (state.approval !== shown) throw new Error('the link was dismissed')
            const r = await api(`/api/approvals/${a.id}/state`, {secret: a.secret})
            if (r.state !== 'waiting') throw new Error(`the link was ${r.state}: ask again`)
            if (!r.offer) continue
            if (r.offer.code !== deviceLinkCode(unhex(r.offer.device, 32))) throw new Error('the node gives another code than the device\'s key makes: do not link it')
            return r.offer
        }
    } finally {
        if (state.approval === shown) state.approval = null
    }
}

// Signs the Device_Add of an offer the person compared the code of.
export async function linkDevice(offer) {
    return write({type: 'device_add', log: state.session.user, device: offer.device, dh: offer.dh, proof: offer.proof, name: offer.name})
}

// Signs in without a passkey: a device of the user approves the login.
export async function signInByDevice() {
    const a = await api('/api/approvals', {kind: 'login'})
    await approvalWait(a)
    await refreshSession()
}

let layout = ''

// The author this session's passkey signs as: its web key id, from the COSE
// key this browser made when it has it, else as the session names it.
function author() {
    const named = unhex(state.session.passkey, 32)
    const credential = storageGet(sessionStorage, CREDENTIAL)
    const cose = credential && known()[credential]
    if (cose && !equal(webKeyId(unb64(cose), state.node.rp_id), named)) throw new Error('the node names another passkey for this session than the one it signed in with: sign in again')
    return named
}

// Writes an entry: the draft is checked, then its BLAKE3 signed by the
// passkey; a session without one has a device sign it.
export async function write(action) {
    if (!state.session) throw new Error('sign in first')
    if (!state.session.passkey) {
        const a = await api('/api/approvals', {kind: 'entry', draft: action})
        return approvalWait(a)
    }
    if (!layout) {
        layout = layoutCheck(await api('/api/entries')) || 'checked'
    }
    if (layout !== 'checked') throw new Error(layout)
    const expected = author()
    const draft = await api('/api/drafts', action)
    const bytes = unb64(draft.unsigned)
    const why = draftCheck(bytes, action, expected, BigInt(Date.now()) * 1000000n)
    if (why) throw new Error(`the node's draft is not what you asked, so it was not signed: ${why}`)
    const credential = storageGet(sessionStorage, CREDENTIAL)
    const signed = await assertion(blake3(bytes), credential ? unb64(credential) : undefined)
    return api('/api/entries', {unsigned: draft.unsigned, assertion: signed})
}
