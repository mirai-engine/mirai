// Runs the frontend's pure modules against the vectors web_test.odin makes:
// node web_test.mjs <vectors.json>. Prints what fails and exits 1, or the
// number of checks.
import {readFileSync} from 'node:fs'
import {blake3} from './web/blake3.js'
import * as E from './web/entry.js'

const text = readFileSync(process.argv[2], 'utf8')
let v
try {
    v = JSON.parse(text)
} catch (error) {
    const at = Number(/position (\d+)/.exec(error.message)?.[1] ?? 0)
    console.log(`the vectors do not read: ${error.message} near ${JSON.stringify(text.slice(Math.max(0, at - 80), at + 40))}`)
    process.exit(1)
}
const fails = []
let checks = 0
const expect = (ok, what) => {
    checks++
    if (!ok) fails.push(what)
}
const bytes = text => E.unhex(text, text.length / 2)
const PKCS8_ED25519 = bytes('302e020100300506032b657004220420')
const signer = async seed => crypto.subtle.importKey('pkcs8', E.concat(PKCS8_ED25519, seed), {name: 'Ed25519'}, false, ['sign'])
const sign = async (key, message) => new Uint8Array(await crypto.subtle.sign({name: 'Ed25519'}, key, message))

for (const x of v.blake3) {
    const input = Uint8Array.from({length: x.size}, (_, i) => i % 251)
    expect(E.hex(blake3(input)) === x.hash, `BLAKE3 of ${x.size} bytes`)
}
for (const r of v.recovery) expect(E.recoveryText(bytes(r.seed)) === r.text, `the recovery text of ${r.seed}`)
for (const k of v.web_keys) expect(E.hex(E.webKeyId(E.unb64(k.cose), k.rp)) === k.id, `the web key id of ${k.cose}`)
for (const a of v.attested) {
    let got
    try {
        got = E.attestedCredential(E.unb64(a.data))
    } catch (error) {
        got = {credential: new Uint8Array(0), cose: new Uint8Array(0), error}
    }
    expect(E.b64(got.credential) === a.credential && E.b64(got.cose) === a.cose, `the credential of authenticator data ${a.name} ${got.error ?? ''}`)
}
expect(E.b64(E.unb64('_-8')) === '_-8' && E.b64(Uint8Array.of(251, 255)) === '-_8', 'base64url both ways')

// A new user's first entries, signed with WebCrypto as the page signs them.
const u = v.user
const recovery = await signer(bytes(u.recovery_seed)), device = await signer(bytes(u.device_seed))
const recoveryKey = bytes(u.genesis).slice(E.HEAD, E.HEAD + 32)
const proof = await sign(device, E.deviceMessage(recoveryKey))
expect(E.hex(proof) === u.proof, "the device's proof")
const body = E.userGenesisBody({recovery: recoveryKey, device: bytes(u.genesis).slice(E.HEAD + 32, E.HEAD + 64), dh: bytes(u.dh), proof, deviceName: 'browser', name: u.name})
const u1 = E.entryUnsigned({type: E.TYPES.user_genesis, author: recoveryKey, time: BigInt(u.time), body, sig: E.SIG_ED25519})
const genesis = E.concat(u1, await sign(recovery, u1))
expect(E.hex(genesis) === u.genesis, 'the genesis')
const log = blake3(genesis)
expect(E.hex(log) === u.log, "the new user's id")
const u2 = E.entryUnsigned({
    type: E.TYPES.web_key_add, log, parents: [log], author: recoveryKey, time: BigInt(u.time) + 1n,
    body: E.webKeyAddBody(E.unb64(u.credential), E.unb64(u.cose), u.rp), sig: E.SIG_ED25519,
})
expect(E.hex(u2) === u.web_key_add, 'the Web_Key_Add')

expect(E.layoutCheck(v.layout) === '', 'the layout GET /api/entries describes')
expect(E.layoutCheck({...v.layout, types: {...v.layout.types, proposal_verdict: 99}}) !== '', 'another layout is refused')

const author = E.unhex(v.author, 32)
const now = BigInt(v.now)
for (const d of v.drafts) {
    const why = E.draftCheck(E.unb64(d.unsigned), d.action, author, now)
    expect(why === '', `the draft of ${JSON.stringify(d.action)} holds: ${why}`)
    const other = author.slice()
    other[0] ^= 1
    expect(E.draftCheck(E.unb64(d.unsigned), d.action, other, now) !== '', `the draft of ${d.action.type} is refused for another author`)
}
for (const d of v.refused) expect(E.draftCheck(E.unb64(d.unsigned), d.action, author, now) !== '', `${d.name} is refused`)

if (fails.length) {
    console.log(fails.join('\n'))
    process.exit(1)
}
console.log(`ok: ${checks} checks`)
