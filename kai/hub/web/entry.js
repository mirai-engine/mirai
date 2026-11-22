// The bytes of Kai log entries as kai/log.odin lays them out, built and
// checked here rather than taken on the server's word: a draft is signed
// only when every field is what the user asked for. Integers are
// little-endian and structures packed. No DOM: the tests run it under node.
import {blake3} from './blake3.js'

export const MAGIC = 0x3149414b // the bytes K A I 1
export const VERSION = 1
export const HEAD = 120
export const PARENTS_MAX = 8
export const BODY_MAX = 64 << 10
export const NAME_MAX = 64
export const SIG_ED25519 = 0
export const SIG_WEBAUTHN = 1
export const TIME_SKEW_NS = 600n * 1000000000n

export const TYPES = {
    user_genesis: 1, web_key_add: 5,
    member_add: 7, member_remove: 8, role_set: 9,
    proposal_comment: 23, proposal_verdict: 24, proposal_close: 27, proposal_reopen: 28,
}
export const ROLES = {reader: 1, writer: 2, admin: 3}
export const VERDICTS = {approve: 0, changes: 1, withdraw: 2}
export const ANCHORS = {file: 0, lines: 1}

const LABEL_DEVICE = 'kai-1/device'
const LABEL_RECOVERY = 'kai-1/recovery'
const CROCKFORD = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'
const ZERO = new Uint8Array(32)

const encoder = new TextEncoder()

export function utf8(text) {
    return encoder.encode(text)
}

export function concat(...parts) {
    const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0))
    let at = 0
    for (const p of parts) {
        out.set(p, at)
        at += p.length
    }
    return out
}

export function equal(a, b) {
    if (a.length !== b.length) return false
    for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false
    return true
}

export function hex(bytes) {
    let out = ''
    for (const b of bytes) out += b.toString(16).padStart(2, '0')
    return out
}

// The bytes of exactly size bytes of hex; null when it is not that.
export function unhex(text, size) {
    if (typeof text !== 'string' || text.length !== 2 * size || !/^[0-9a-fA-F]*$/.test(text)) return null
    const out = new Uint8Array(size)
    for (let i = 0; i < size; i++) out[i] = parseInt(text.slice(2 * i, 2 * i + 2), 16)
    return out
}

const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'

// Base64url without padding, as the API carries bytes.
export function b64(bytes) {
    let out = ''
    for (let i = 0; i < bytes.length; i += 3) {
        const n = bytes[i] << 16 | (bytes[i + 1] ?? 0) << 8 | (bytes[i + 2] ?? 0)
        const digits = Math.min(4, Math.ceil((bytes.length - i) * 4 / 3))
        for (let k = 0; k < digits; k++) out += B64[n >> 18 - 6 * k & 63]
    }
    return out
}

export function unb64(text) {
    const clean = text.replace(/=+$/, '')
    if (!/^[A-Za-z0-9_-]*$/.test(clean) || clean.length % 4 === 1) throw new Error('not base64url')
    const out = new Uint8Array(Math.floor(clean.length * 3 / 4))
    let acc = 0, bits = 0, at = 0
    for (const c of clean) {
        acc = acc << 6 | B64.indexOf(c)
        bits += 6
        if (bits >= 8) {
            bits -= 8
            out[at++] = acc >> bits & 255
        }
    }
    return out
}

function less(a, b) {
    for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return a[i] < b[i]
    return false
}

// The bytes an entry's signature covers: its head, its parents in ascending
// order, then its body.
export function entryUnsigned({type, log = ZERO, parents = [], author, authorCtx = ZERO, time, body, sig}) {
    const sorted = [...parents].sort((a, b) => less(a, b) ? -1 : less(b, a) ? 1 : 0)
    const out = new Uint8Array(HEAD + 32 * sorted.length + body.length)
    const v = new DataView(out.buffer)
    v.setUint32(0, MAGIC, true)
    v.setUint16(4, VERSION, true)
    out[6] = type
    out[7] = sorted.length
    out.set(log, 8)
    out.set(author, 40)
    out.set(authorCtx, 72)
    v.setBigInt64(104, BigInt(time), true)
    v.setUint32(112, body.length, true)
    out[116] = sig
    sorted.forEach((p, i) => out.set(p, HEAD + 32 * i))
    out.set(body, HEAD + 32 * sorted.length)
    return out
}

// The fields of unsigned bytes, or a string that says why they are no entry.
export function entryParse(bytes) {
    if (!(bytes instanceof Uint8Array) || bytes.length < HEAD) return 'the bytes are shorter than an entry head'
    const v = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
    const e = {
        magic: v.getUint32(0, true), version: v.getUint16(4, true), type: bytes[6], count: bytes[7],
        log: bytes.slice(8, 40), author: bytes.slice(40, 72), authorCtx: bytes.slice(72, 104),
        time: v.getBigInt64(104, true), bodyLength: v.getUint32(112, true), sig: bytes[116], reserved: bytes.slice(117, 120),
    }
    if (e.magic !== MAGIC || e.version !== VERSION) return 'the bytes are not a Kai entry of this version'
    if (e.count > PARENTS_MAX || e.bodyLength > BODY_MAX) return 'the entry is past its bounds'
    if (bytes.length !== HEAD + 32 * e.count + e.bodyLength) return 'the entry has bytes beyond its head, parents and body'
    if (e.reserved.some(b => b !== 0)) return 'the reserved bytes of the entry are not zero'
    e.parents = []
    for (let i = 0; i < e.count; i++) e.parents.push(bytes.slice(HEAD + 32 * i, HEAD + 32 * (i + 1)))
    e.body = bytes.slice(HEAD + 32 * e.count)
    return e
}

function u16(n) {
    return Uint8Array.of(n & 255, n >> 8 & 255)
}

function u32(n) {
    return Uint8Array.of(n & 255, n >>> 8 & 255, n >>> 16 & 255, n >>> 24 & 255)
}

function need(bytes, what) {
    if (!bytes) throw new Error(what)
    return bytes
}

// The body an action asks for, built as kai/log.odin builds it. The action
// is what the browser posts to /api/drafts.
export function actionBody(a) {
    switch (a.type) {
    case 'proposal_comment': {
        const kind = ANCHORS[a.anchor?.kind || 'file']
        if (kind === undefined) throw new Error("a comment's anchor kind is file or lines")
        const change = a.change ? need(unhex(a.change, 16), 'change is a change id, 32 hex') : new Uint8Array(16)
        const reply = a.reply_to ? need(unhex(a.reply_to, 32), 'reply_to is the address of a comment, 64 hex') : ZERO
        const path = utf8(a.path || '')
        const text = utf8(a.text || '')
        const lines = kind === ANCHORS.lines
        const line = lines ? a.anchor.line : 0, count = lines ? a.anchor.lines : 0
        if (lines && !(line >= 1 && count >= 1)) throw new Error('a comment on lines names the first line and how many')
        if (!a.change !== (path.length === 0)) throw new Error('a comment on a file names its change and its path; one on the proposal neither')
        return concat(reply, Uint8Array.of(kind), u16(path.length), u32(line), u32(count), new Uint8Array(16), change, path, text)
    }
    case 'proposal_verdict': {
        const verdict = VERDICTS[a.verdict]
        if (verdict === undefined) throw new Error('verdict is approve, changes or withdraw')
        return concat(Uint8Array.of(verdict), need(unhex(a.revision, 32), 'revision is 64 hex'))
    }
    case 'proposal_close':
    case 'proposal_reopen':
        return new Uint8Array(0)
    case 'member_add':
    case 'role_set': {
        const role = ROLES[a.role]
        if (role === undefined) throw new Error('role is reader, writer or admin')
        return concat(need(unhex(a.user, 32), 'user is 64 hex'), Uint8Array.of(role))
    }
    case 'member_remove':
        return need(unhex(a.user, 32), 'user is 64 hex')
    }
    throw new Error(`a browser does not write entries of type ${a.type}`)
}

// Why the unsigned bytes of a draft are not the entry the action asks for by
// author, at now (nanoseconds); '' when they are.
export function draftCheck(bytes, action, author, now) {
    const e = entryParse(bytes)
    if (typeof e === 'string') return e
    let body
    try {
        body = actionBody(action)
    } catch (error) {
        return error.message
    }
    if (e.type !== TYPES[action.type]) return 'the entry is of another type than the one asked'
    const log = unhex(action.log, 32)
    if (!log || !equal(e.log, log)) return 'the entry joins another log than the one asked'
    if (!equal(e.author, author)) return "the entry's author is not this passkey"
    if (e.sig !== SIG_WEBAUTHN) return 'the entry is not one a passkey signs'
    if (e.count === 0) return 'the entry names no parent'
    for (let i = 0; i < e.count; i++) {
        if (equal(e.parents[i], ZERO) || (i > 0 && !less(e.parents[i - 1], e.parents[i]))) return 'the parents are not distinct addresses in ascending order'
    }
    if (equal(e.authorCtx, ZERO)) return "the entry names no entry of the author's log"
    const skew = e.time - BigInt(now)
    if (skew > TIME_SKEW_NS || skew < -TIME_SKEW_NS) return "the entry's time is more than ten minutes from this computer's clock"
    if (!equal(e.body, body)) return 'the body is not what was asked'
    return ''
}

// Why the layout GET /api/entries describes is not the one this page builds;
// '' when it is.
export function layoutCheck(d) {
    const differs = 'the node lays entries out otherwise than this page: reload it'
    if (d?.entry?.size !== HEAD || d.constants?.magic !== MAGIC || d.constants?.version !== VERSION) return differs
    if (d.constants.ENTRY_PARENTS_MAX !== PARENTS_MAX || d.constants.ENTRY_BODY_MAX !== BODY_MAX) return differs
    const tables = [[TYPES, d.types], [ROLES, d.enums?.role], [VERDICTS, d.enums?.verdict], [ANCHORS, d.enums?.anchor]]
    for (const [ours, theirs] of tables) {
        for (const name in ours) if (theirs?.[name] !== ours[name]) return differs
    }
    return ''
}

// The web key id of a passkey: what the entries it signs name as their author.
export function webKeyId(cose, rpId) {
    return blake3(concat(u16(cose.length), cose, utf8(rpId)))
}

export function webKeyAddBody(credential, cose, rpId) {
    const rp = utf8(rpId)
    return concat(Uint8Array.of(credential.length), u16(cose.length), Uint8Array.of(rp.length), credential, cose, rp)
}

// What a new user's device signs to prove it holds its key.
export function deviceMessage(recovery) {
    return concat(utf8(LABEL_DEVICE), recovery)
}

export function userGenesisBody({recovery, device, dh, proof, name}) {
    const n = utf8(name)
    if (n.length < 1 || n.length > NAME_MAX) throw new Error(`a name is 1 to ${NAME_MAX} bytes`)
    return concat(recovery, device, dh, proof, n)
}

// The recovery key as the CLI prints it once: Crockford Base32 of the seed and
// three bytes of its checksum, in groups of four digits.
export function recoveryText(seed) {
    const sum = blake3(concat(utf8(LABEL_RECOVERY), seed))
    const bytes = concat(seed, sum.subarray(0, 3))
    let out = '', digits = 0, bits = 0, acc = 0
    for (const b of bytes) {
        acc = acc << 8 | b
        bits += 8
        while (bits >= 5) {
            bits -= 5
            if (digits > 0 && digits % 4 === 0) out += '-'
            out += CROCKFORD[acc >> bits & 31]
            digits++
            acc &= (1 << bits) - 1
        }
    }
    return out
}

// The end of the CBOR item at at, without reading what it means.
function cborEnd(bytes, at, depth = 0) {
    if (at >= bytes.length || depth > 16) throw new Error('the CBOR ends early')
    const major = bytes[at] >> 5, info = bytes[at] & 31
    at++
    let n
    if (info < 24) n = info
    else if (info <= 27) {
        const size = 1 << info - 24
        if (at + size > bytes.length) throw new Error('the CBOR ends early')
        n = 0
        for (let i = 0; i < size; i++) n = n * 256 + bytes[at + i]
        at += size
    } else throw new Error('indefinite CBOR is not a COSE key')
    switch (major) {
    case 0: case 1: case 7: return at
    case 2: case 3:
        if (at + n > bytes.length) throw new Error('the CBOR ends early')
        return at + n
    case 4:
        for (let i = 0; i < n; i++) at = cborEnd(bytes, at, depth + 1)
        return at
    case 5:
        for (let i = 0; i < 2 * n; i++) at = cborEnd(bytes, at, depth + 1)
        return at
    case 6: return cborEnd(bytes, at, depth + 1)
    }
}

// The credential id and COSE key of the authenticator data a new passkey
// gives: rpIdHash, flags, counter, then the attested credential data.
export function attestedCredential(data) {
    const ATTESTED = 0x40
    if (data.length < 55 || !(data[32] & ATTESTED)) throw new Error('the authenticator gave no credential')
    const length = data[53] << 8 | data[54]
    const start = 55 + length
    if (start > data.length) throw new Error('the authenticator data ends early')
    const end = cborEnd(data, start)
    return {credential: data.slice(55, start), cose: data.slice(start, end)}
}
