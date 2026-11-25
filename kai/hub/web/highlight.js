// Syntax highlighting as data: the tokens of each line, [{t, s}] where t is
// a class (com, str, num, kw, type, lit, fn, prop, meta, var, punct) or ''
// for plain text and s the text. The state a line ends in (a block comment,
// a string that goes on) carries to the next. No DOM: the tests run it under
// node, and ui.js makes spans of the tokens.

const LINE_MAX = 2000 // characters of a line that are highlighted; the rest is plain

const C_TYPES = 'void bool char short int long float double signed unsigned'
const ODIN = {
    line: '//', block: ['/*', '*/'], nest: true, strings: '"\'`', raw: '`', multi: '`', meta: '#@',
    kw: 'package import proc struct enum union bit_set bit_field map dynamic distinct using defer return if else when for in not_in switch case break continue fallthrough or_return or_else or_break or_continue cast transmute auto_cast foreign where context matrix do',
    type: 'int uint i8 i16 i32 i64 i128 u8 u16 u32 u64 u128 f16 f32 f64 bool b8 b16 b32 b64 string cstring rune rawptr typeid any uintptr byte complex64 complex128 quaternion256',
    lit: 'true false nil',
}
const JS = {
    line: '//', block: ['/*', '*/'], strings: '"\'`', multi: '`', template: true,
    kw: 'import export from as default function return if else for while do switch case break continue new delete typeof instanceof in of class extends super this const let var async await yield try catch finally throw void with static get set interface type enum implements declare namespace readonly keyof',
    type: 'string number boolean object symbol bigint unknown never any Array Promise Map Set Uint8Array Error',
    lit: 'true false null undefined NaN Infinity',
}
const SLANG = {
    line: '//', block: ['/*', '*/'], strings: '"\'', meta: '#',
    kw: 'struct cbuffer uniform in out inout return if else for while do switch case break continue discard static const import module export public private internal interface extension associatedtype typedef layout groupshared register namespace using let var func generic where',
    type: `${C_TYPES} half uint float2 float3 float4 float2x2 float3x3 float4x4 int2 int3 int4 uint2 uint3 uint4 half2 half3 half4 bool2 bool3 bool4 vec2 vec3 vec4 ivec2 ivec3 ivec4 uvec2 uvec3 uvec4 mat2 mat3 mat4 Texture2D Texture3D TextureCube RWTexture2D SamplerState StructuredBuffer RWStructuredBuffer ByteAddressBuffer ConstantBuffer sampler2D`,
    lit: 'true false',
}
const JSON_LANG = {strings: '"', lit: 'true false null', keys: true}
const CSS = {block: ['/*', '*/'], strings: '"\'', css: true}
const SHELL = {line: '#', strings: '"\'', shell: true,
    kw: 'if then else elif fi for while until do done case esac in function return export local readonly unset set shift exit source alias select time',
    lit: 'true false',
}
const PY = {line: '#', strings: '"\'',
    kw: 'def class return if elif else for while in not and or is import from as with try except finally raise pass break continue lambda yield async await global nonlocal del assert',
    lit: 'True False None',
}

const LANGUAGES = {odin: ODIN, js: JS, slang: SLANG, json: JSON_LANG, css: CSS, sh: SHELL, md: {markdown: true}, py: PY}

const EXTENSIONS = {
    odin: 'odin', js: 'js', mjs: 'js', cjs: 'js', jsx: 'js', ts: 'js', tsx: 'js', mts: 'js',
    slang: 'slang', glsl: 'slang', hlsl: 'slang', vert: 'slang', frag: 'slang', comp: 'slang', metal: 'slang',
    c: 'slang', h: 'slang', cpp: 'slang', hpp: 'slang', cc: 'slang', wgsl: 'slang',
    json: 'json', css: 'css', md: 'md', markdown: 'md', sh: 'sh', bash: 'sh', zsh: 'sh', py: 'py', toml: 'sh', yml: 'sh', yaml: 'sh',
}

// The tags of fenced code: name=language.
const ALIASES = Object.fromEntries('javascript=js typescript=js ts=js glsl=slang hlsl=slang c=slang cpp=slang shell=sh bash=sh zsh=sh console=sh markdown=md python=py'
    .split(' ').map(pair => pair.split('=')))

// The language of a file by its name, or of a fence's tag; '' when none.
export function languageOf(name) {
    const text = String(name ?? '').toLowerCase()
    if (LANGUAGES[text]) return text
    if (ALIASES[text]) return ALIASES[text]
    const dot = text.lastIndexOf('.')
    return dot >= 0 ? EXTENSIONS[text.slice(dot + 1)] ?? '' : ''
}

const sets = new Map()
function words(lang, key) {
    const id = `${lang}:${key}`
    if (!sets.has(id)) sets.set(id, new Set((LANGUAGES[lang][key] ?? '').split(' ').filter(Boolean)))
    return sets.get(id)
}

// A highlighter of one language: next(line) gives the tokens of each line in turn.
export function highlighter(lang) {
    const L = LANGUAGES[lang]
    const state = {block: 0, string: '', fence: false}
    return {
        next(line) {
            if (!L) return line ? [{t: '', s: line}] : []
            if (line.length > LINE_MAX) return [{t: '', s: line}]
            return L.markdown ? markdownLine(line, state) : scan(line, lang, L, state)
        },
    }
}

// The tokens of every line of a text.
export function tokenize(lines, lang) {
    const h = highlighter(lang)
    return lines.map(line => h.next(line))
}

function push(out, t, s) {
    if (!s) return
    const last = out[out.length - 1]
    if (last && last.t === t) last.s += s
    else out.push({t, s})
}

const IDENT = /[A-Za-z_$À-￿][\w$À-￿]*/y
const NUMBER = /(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|(?:\d[\d_]*)?\.?\d[\d_]*(?:[eE][+-]?\d+)?)[a-zA-Z%]*/y

function scan(line, lang, L, state) {
    const out = []
    let i = 0
    const at = (re, k) => {
        re.lastIndex = k
        const m = re.exec(line)
        return m ? m[0] : ''
    }
    // What the line before left open.
    if (state.block) i = blockRest(line, 0, L, state, out)
    else if (state.string) i = stringRest(line, 0, state.string, L, state, out)
    while (i < line.length) {
        const c = line[i]
        if (L.line && line.startsWith(L.line, i) && (!L.shell || i === 0 || /\s/.test(line[i - 1]))) {
            push(out, 'com', line.slice(i))
            break
        }
        if (L.block && line.startsWith(L.block[0], i)) {
            state.block = 1
            push(out, 'com', L.block[0])
            i = blockRest(line, i + L.block[0].length, L, state, out)
            continue
        }
        if (L.strings?.includes(c)) {
            push(out, 'str', c)
            i = stringRest(line, i + 1, c, L, state, out)
            if (L.keys && !state.string) {
                // A JSON key is the string before a colon.
                let k = i
                while (line[k] === ' ') k++
                if (line[k] === ':') out[out.length - 1].t = 'prop'
            }
            continue
        }
        if (/[0-9]/.test(c) || (c === '.' && /[0-9]/.test(line[i + 1] ?? ''))) {
            const n = at(NUMBER, i)
            if (n && (i === 0 || !/[\w$]/.test(line[i - 1]))) {
                push(out, 'num', n)
                i += n.length
                continue
            }
        }
        if (L.meta?.includes(c) && /[A-Za-z_(]/.test(line[i + 1] ?? '')) {
            const word = c + (line[i + 1] === '(' ? '' : at(IDENT, i + 1))
            push(out, 'meta', word)
            i += word.length
            continue
        }
        if (L.css) {
            const n = cssToken(line, i, out)
            if (n > i) {
                i = n
                continue
            }
        }
        if (L.shell && c === '$') {
            const v = /\$(?:\{[^}]*\}|[A-Za-z_][\w]*|[0-9#?@*$!-])/y
            const word = at(v, i)
            if (word) {
                push(out, 'var', word)
                i += word.length
                continue
            }
        }
        const word = at(IDENT, i)
        if (word) {
            let t = ''
            if (words(lang, 'kw').has(word)) t = 'kw'
            else if (words(lang, 'lit').has(word)) t = 'lit'
            else if (words(lang, 'type').has(word)) t = 'type'
            else {
                let k = i + word.length
                while (line[k] === ' ') k++
                if (line[k] === '(' || (lang === 'odin' && line.startsWith('::', k) && /^\s*proc\b/.test(line.slice(k + 2)))) t = 'fn'
                else if (/^[A-Z][a-z0-9]/.test(word) && lang !== 'sh' && lang !== 'json') t = 'type'
            }
            push(out, t, word)
            i += word.length
            continue
        }
        push(out, /[{}()[\];,.:=<>+\-*/%!&|^~?]/.test(c) ? 'punct' : '', c)
        i++
    }
    return out
}

// The rest of a block comment from k; nested in Odin.
function blockRest(line, k, L, state, out) {
    const [open, close] = L.block
    let i = k
    while (i < line.length) {
        if (L.nest && line.startsWith(open, i)) {
            state.block++
            i += open.length
            continue
        }
        if (line.startsWith(close, i)) {
            i += close.length
            if (--state.block === 0) break
            continue
        }
        i++
    }
    push(out, 'com', line.slice(k, i))
    return i
}

// The rest of a string opened by quote from k: to its close, or the line's
// end, where a string that may go on leaves the state open.
function stringRest(line, k, quote, L, state, out) {
    const raw = L.raw?.includes(quote)
    let i = k
    for (; i < line.length; i++) {
        if (!raw && line[i] === '\\') {
            i++
            continue
        }
        if (line[i] === quote) {
            push(out, 'str', line.slice(k, i + 1))
            state.string = ''
            return i + 1
        }
    }
    push(out, 'str', line.slice(k))
    state.string = L.multi?.includes(quote) ? quote : ''
    return i
}

// A token of CSS at i: an at-rule, a color, a property; i when none.
function cssToken(line, i, out) {
    const rest = line.slice(i)
    let m
    if ((m = /^@[\w-]+/.exec(rest))) {
        push(out, 'kw', m[0])
        return i + m[0].length
    }
    if ((m = /^#[0-9a-fA-F]{3,8}\b/.exec(rest))) {
        push(out, 'num', m[0])
        return i + m[0].length
    }
    if ((m = /^-?-?[a-zA-Z][\w-]*(?=\s*:(?!:))/.exec(rest)) && !/[{,]\s*$/.test(line) ) {
        push(out, 'prop', m[0])
        return i + m[0].length
    }
    if ((m = /^[.:]{1,2}[a-zA-Z][\w-]*/.exec(rest))) {
        push(out, 'fn', m[0])
        return i + m[0].length
    }
    return i
}

function markdownLine(line, state) {
    const out = []
    if (/^ {0,3}(```|~~~)/.test(line)) {
        state.fence = !state.fence
        push(out, 'com', line)
        return out
    }
    if (state.fence) {
        push(out, 'str', line)
        return out
    }
    if (/^ {0,3}#{1,6}(\s|$)/.test(line)) {
        push(out, 'kw', line)
        return out
    }
    let i = 0
    const marker = /^(\s*)([-*+]|\d+[.)]|>)\s/.exec(line)
    if (marker) {
        push(out, '', marker[1])
        push(out, 'punct', marker[2])
        i = marker[1].length + marker[2].length
    }
    const re = /`[^`]+`|\*\*[^*]+\*\*|\[[^\]]*\]\([^)]*\)/g
    re.lastIndex = i
    for (let m = re.exec(line); m; m = re.exec(line)) {
        push(out, '', line.slice(i, m.index))
        push(out, m[0][0] === '`' ? 'str' : m[0][0] === '[' ? 'fn' : 'type', m[0])
        i = m.index + m[0].length
    }
    push(out, '', line.slice(i))
    return out
}
