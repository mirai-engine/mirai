// Passkeys and signed writes. The server never hands this page a challenge
// to sign for a write: the page checks the draft's bytes against what the
// user asked and signs their BLAKE3. A new user's keys are made here with
// WebCrypto; the recovery key leaves only as the text shown once.
import {api, refreshSession, state} from './api.js'
import {blake3} from './blake3.js'
import {
    attestedCredential, b64, concat, deviceMessage, draftCheck, entryUnsigned, equal, hex, layoutCheck,
    recoveryText, SIG_ED25519, TYPES, unb64, unhex, userGenesisBody, webKeyAddBody, webKeyId,
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
    const publicKey = {challenge, rpId: state.node.rp_id, userVerification: 'preferred', timeout: TIMEOUT_MS}
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
            authenticatorSelection: {residentKey: 'required', userVerification: 'preferred'},
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

async function ed25519Sign(key, message) {
    return new Uint8Array(await crypto.subtle.sign({name: 'Ed25519'}, key, message))
}

async function publicRaw(key) {
    return new Uint8Array(await crypto.subtle.exportKey('raw', key))
}

// A user whose first passkey is this one: the recovery key and a device key
// made here sign the genesis of its log and the Web_Key_Add of the passkey.
// Answers the user id and the recovery text, which is shown once.
export async function register(name) {
    const {credential, cose} = await passkeyCreate(name)
    const subtle = crypto.subtle
    let recovery, device, dh
    try {
        recovery = await subtle.generateKey({name: 'Ed25519'}, true, ['sign', 'verify'])
        device = await subtle.generateKey({name: 'Ed25519'}, false, ['sign', 'verify'])
        dh = await subtle.generateKey({name: 'X25519'}, false, ['deriveBits'])
    } catch {
        throw new Error('this browser makes no Ed25519 or X25519 keys: use a current browser, or link the passkey to a user from a device')
    }
    const pkcs8 = new Uint8Array(await subtle.exportKey('pkcs8', recovery.privateKey))
    if (pkcs8.length !== 48) throw new Error('the browser exports the recovery key in an unknown form')
    const seed = pkcs8.slice(16)
    const recoveryKey = await publicRaw(recovery.publicKey)
    const body = userGenesisBody({
        recovery: recoveryKey, device: await publicRaw(device.publicKey), dh: await publicRaw(dh.publicKey),
        proof: await ed25519Sign(device.privateKey, deviceMessage(recoveryKey)), deviceName: 'browser', name,
    })
    const now = BigInt(Date.now()) * 1000000n
    const u1 = entryUnsigned({type: TYPES.user_genesis, author: recoveryKey, time: now, body, sig: SIG_ED25519})
    const genesis = concat(u1, await ed25519Sign(recovery.privateKey, u1))
    const log = blake3(genesis)
    const u2 = entryUnsigned({
        type: TYPES.web_key_add, log, parents: [log], author: recoveryKey, time: now + 1n,
        body: webKeyAddBody(credential, cose, state.node.rp_id), sig: SIG_ED25519,
    })
    const add = concat(u2, await ed25519Sign(recovery.privateKey, u2))
    const made = await api('/api/users', {entries: [b64(genesis), b64(add)]})
    if (made.user !== hex(log)) throw new Error('the node kept another user than the one this page made')
    remember(credential, cose)
    return {user: made.user, recovery: recoveryText(seed)}
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
