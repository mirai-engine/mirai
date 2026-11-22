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

for (const x of v.blake3) {
    const input = Uint8Array.from({length: x.size}, (_, i) => i % 251)
    expect(E.hex(blake3(input)) === x.hash, `BLAKE3 of ${x.size} bytes`)
}
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

// A new user's genesis, as the page builds it for its passkey to sign.
const u = v.user
const cose = E.unb64(u.cose)
const unsigned = E.entryUnsigned({
    type: E.TYPES.passkey_genesis, author: E.webKeyId(cose, u.rp), time: BigInt(u.time),
    body: E.passkeyGenesisBody(E.unb64(u.credential), cose, u.rp, u.name), sig: E.SIG_WEBAUTHN,
})
expect(E.hex(unsigned) === u.unsigned, 'the Passkey_Genesis')
for (const d of v.codes) expect(E.deviceLinkCode(bytes(d.device)) === d.code, `the link code of ${d.device}`)

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
