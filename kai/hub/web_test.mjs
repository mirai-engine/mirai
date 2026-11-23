// Runs the frontend's pure modules against the vectors web_test.odin makes:
// node web_test.mjs <vectors.json>. Prints what fails and exits 1, or the
// number of checks. Markdown, highlighting and word diffs are checked
// against cases of their own.
import {readFileSync} from 'node:fs'
import {blake3} from './web/blake3.js'
import * as E from './web/entry.js'
import * as Preview from './web/preview.js'
import {inline, parseMarkdown, plainText, safeHref} from './web/markdown.js'
import {highlighter, languageOf, tokenize} from './web/highlight.js'
import {pairs, segments, splitRows, wordDiff} from './web/diffs.js'

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

for (const [name, value] of Object.entries(v.constants)) {
    if (typeof value === 'number') expect(E[name] === value, `${name} is the node's`)
    else for (const k in E[name]) expect(E[name][k] === value[k], `${name}.${k} is the node's`)
}

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

for (const x of v.previews.summaries) {
    const got = Preview.summaryDecode(x.text)
    expect(got && got.kind === x.kind && JSON.stringify(got.facts.map(f => [f.label, f.value])) === JSON.stringify(x.facts), `the summary ${JSON.stringify(x.text)}`)
}
const detail = Preview.detailDecode(v.previews.detail)
expect(detail && detail.added === 1 && detail.removed === 1 && detail.changed === 1 && detail.cut === 7 && detail.rows.length === 3 &&
    detail.rows[0].name === 'Lamp' && detail.rows[2].name === 'Sun ü' && detail.rows[2].text === '', `the detail ${JSON.stringify(v.previews.detail)}`)
for (const x of v.previews.refused) {
    const decode = x.kind === 'detail' ? Preview.detailDecode : Preview.summaryDecode
    expect(decode(x.text) === null, `the ${x.kind} ${JSON.stringify(x.text)} is refused`)
}

// The two entries of a landing, as the page encodes them from what it read.
const move = v.drafts.find(d => d.action.type === 'bookmark_move')
const landing = v.drafts.find(d => d.action.type === 'proposal_land')
expect(move && landing, 'the vectors hold a landing')
if (move) {
    const e = E.entryParse(E.unb64(move.unsigned))
    const a = move.action
    expect(typeof e !== 'string' && E.hex(e.body.slice(0, 32)) === a.revision && E.hex(e.body.slice(32, 64)) === a.proposal &&
        e.body[64] === a.heads.length && e.body[65] === a.from.length &&
        new TextDecoder().decode(e.body.slice(66 + 32 * (a.heads.length + a.from.length))) === a.bookmark, 'a Bookmark_Move lays out to, proposal, heads, from and the bookmark')
}
if (landing) {
    const e = E.entryParse(E.unb64(landing.unsigned))
    expect(typeof e !== 'string' && e.body.length === 64 && E.hex(e.body.slice(32)) === landing.action.bookmark_move, 'a Land names the move')
}
for (const bad of [{type: 'bookmark_move', revision: 'x'}, {type: 'bookmark_move', revision: '0'.repeat(64), proposal: '0'.repeat(64), heads: [], from: [], bookmark: 'main'},
    {type: 'bookmark_move', revision: '0'.repeat(64), proposal: '0'.repeat(64), heads: ['0'.repeat(64)], from: [], bookmark: ''}, {type: 'proposal_land', revision: '0'.repeat(64)}]) {
    let threw = false
    try {
        E.actionBody(bad)
    } catch {
        threw = true
    }
    expect(threw, `the body of ${JSON.stringify(bad)} is refused`)
}

// Markdown becomes a tree of plain objects, and links only http(s) or relative ones.
const same = (got, want, what) => expect(JSON.stringify(got) === JSON.stringify(want), `${what}: ${JSON.stringify(got)}`)
same(parseMarkdown('# Title\n\nSome **bold** and *em* and `code`.'), [
    {type: 'heading', level: 1, children: [{type: 'text', text: 'Title'}]},
    {type: 'paragraph', children: [{type: 'text', text: 'Some '}, {type: 'strong', children: [{type: 'text', text: 'bold'}]}, {type: 'text', text: ' and '},
        {type: 'em', children: [{type: 'text', text: 'em'}]}, {type: 'text', text: ' and '}, {type: 'code', text: 'code'}, {type: 'text', text: '.'}]},
], 'a heading and inline marks')
same(parseMarkdown('```odin\nmain :: proc() {}\n```'), [{type: 'code', lang: 'odin', text: 'main :: proc() {}'}], 'a fenced block')
same(parseMarkdown('- one\n- two\n\n1. first\n2. second').map(b => [b.type, b.ordered, b.items.length]), [['list', false, 2], ['list', true, 2]], 'lists')
same(parseMarkdown('> quoted\n> more\n\n---').map(b => b.type), ['quote', 'hr'], 'a quote and a rule')
same(parseMarkdown('~~gone~~')[0].children[0].type, 'del', 'strikethrough')
same(parseMarkdown('- a\n  - nested')[0].items[0].map(b => b.type), ['paragraph', 'list'], 'a nested list')
same(inline('snake_case_name'), [{type: 'text', text: 'snake_case_name'}], 'underscores inside a word are no emphasis')
same(inline('a \\*literal\\* star'), [{type: 'text', text: 'a *literal* star'}], 'escapes')
const links = text => inline(text).filter(n => n.type === 'link').map(n => n.href)
same(links('[site](https://example.com) [doc](docs/a.md) [top](#top) see https://kai.test/x.'), ['https://example.com', 'docs/a.md', '#top', 'https://kai.test/x'], 'links and bare addresses')
for (const hostile of ['javascript' + ':alert(1)', 'JAVASCRIPT' + ':x', 'data:text/html,x', 'vbscript:x', '//evil.test/x', 'java\tscript:x', ' javascript' + ':x', 'file:///etc/passwd']) {
    expect(safeHref(hostile) === null, `the address ${JSON.stringify(hostile)} is no link`)
    expect(links(`[x](${hostile})`).length === 0, `a link to ${JSON.stringify(hostile)} becomes text`)
}
same(plainText(inline('[**a**](https://x.test) <b>tag</b>')), 'a <b>tag</b>', 'markup stays text')
expect(parseMarkdown('>'.repeat(5000) + ' deep').length === 1, 'deep nesting stays bounded')

// Highlighting gives every character back, as tokens of the language.
const tokens = (text, lang) => tokenize(text.split('\n'), lang)
const kinds = (line, lang) => tokens(line, lang)[0].filter(x => x.t).map(x => `${x.t}:${x.s}`)
for (const [lang, text] of [['odin', 'main :: proc() {\n\tx := "a\\"b" // c\n/* d /* e */ f */ y := 0x1F\n}'], ['js', 'const a = `x\n${y}` // z'],
    ['json', '{"a": [1, true, null]}'], ['css', '.a { color: #7050f0; }'], ['sh', 'echo "$HOME" # x'], ['slang', '#include "x"\nfloat4 f(float3 p) {}'], ['md', '# Title\n- `code`']]) {
    const lines = text.split('\n')
    expect(tokenize(lines, lang).map(l => l.map(x => x.s).join('')).join('\n') === text, `the tokens of ${lang} give back the text`)
}
same(kinds('x :: proc(a: int) -> bool { return true }', 'odin'), ['fn:x', 'punct:::', 'kw:proc', 'punct:(', 'punct::', 'type:int', 'punct:)', 'punct:->', 'type:bool', 'punct:{', 'kw:return', 'lit:true', 'punct:}'], 'Odin')
same(tokens('/* open\nstill */ x', 'odin').map(l => l[0].t), ['com', 'com'], 'a block comment goes on to the next line')
same(kinds('{"key": "value", "n": 2}', 'json').filter(k => !k.startsWith('punct')), ['prop:"key"', 'str:"value"', 'prop:"n"', 'num:2'], 'JSON keys')
same(languageOf('a/b/shader.slang') + languageOf('x.mjs') + languageOf('README.md') + languageOf('noext'), 'slangjsmd', 'languages by name')
const long = highlighter('odin').next('x'.repeat(5000))
expect(long.length === 1 && long[0].t === '', 'a very long line stays plain')

// Word diffs mark what changed in a pair of lines, and split rows pair them.
const marked = (text, ranges) => ranges.map(([a, b]) => text.slice(a, b))
const w = wordDiff('let speed = 10.0', 'let speed = 12.5')
expect(w && JSON.stringify(marked('let speed = 10.0', w.before)) === JSON.stringify(['10.0']) && JSON.stringify(marked('let speed = 12.5', w.after)) === JSON.stringify(['12.5']), `a changed number: ${JSON.stringify(w)}`)
expect(wordDiff('alpha', 'omega') === null, 'lines with nothing in common are marked whole')
const lines = [{op: 'same'}, {op: 'remove'}, {op: 'remove'}, {op: 'add'}, {op: 'same'}, {op: 'add'}]
same([...pairs(lines)].sort(), [[1, 3], [3, 1]], 'a removed line pairs with the added one after it')
same(splitRows(lines), [[0, 0], [1, 3], [2, -1], [4, 4], [-1, 5]], 'split rows')
same(segments([{t: 'kw', s: 'let'}, {t: '', s: ' x = 10'}], [[8, 10]]).map(x => [x.t, x.s, x.mark]), [['kw', 'let', false], ['', ' x = ', false], ['', '10', true]], 'marks cut the tokens')

if (fails.length) {
    console.log(fails.join('\n'))
    process.exit(1)
}
console.log(`ok: ${checks} checks`)
