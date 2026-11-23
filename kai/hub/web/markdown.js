// Markdown to a tree of plain objects, never markup: ui.js turns the tree
// into DOM nodes, so a README, a proposal or a comment can only ever become
// text, emphasis, lists, code and links to http(s) or relative addresses.
// No DOM: the tests run it under node.
//
// Blocks: {type: heading, level, children} | {type: paragraph, children} |
// {type: code, lang, text} | {type: list, ordered, start, items: [[block]]} |
// {type: quote, children: [block]} | {type: hr}.
// Inlines: {type: text, text} | {type: strong|em|del, children} |
// {type: code, text} | {type: link, href, children} | {type: br}.

const DEPTH_MAX = 8
const FENCE = /^ {0,3}(`{3,}|~{3,})[ \t]*([^`\s]*)/
const HEADING = /^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$/
const RULE = /^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$/
const QUOTE = /^ {0,3}> ?/
const ITEM = /^( {0,3})([-*+]|\d{1,9}[.)])([ \t]+|$)/

// The address a link may go to: http(s), or relative to this site; null for
// any other scheme, a protocol-relative address or one with spaces or controls.
export function safeHref(text) {
    const url = String(text ?? '').trim()
    if (url === '' || /[\s\u0000-\u001f\u007f]/.test(url)) return null
    if (/^https?:\/\/[^/]/i.test(url)) return url
    if (url.startsWith('//')) return null
    const scheme = /^([^/?#]*):/.exec(url)
    return scheme ? null : url
}

function blank(line) {
    return /^[ \t]*$/.test(line)
}

// Whether line starts a block other than a paragraph's continuation.
function interrupts(line) {
    return FENCE.test(line) || HEADING.test(line) || RULE.test(line) || QUOTE.test(line) || ITEM.test(line)
}

export function parseMarkdown(text, depth = 0) {
    const lines = String(text ?? '').replace(/\r\n?/g, '\n').split('\n')
    return blocks(lines, depth)
}

function blocks(lines, depth) {
    const out = []
    let i = 0
    while (i < lines.length) {
        const line = lines[i]
        if (blank(line)) {
            i++
            continue
        }
        let m
        if ((m = FENCE.exec(line))) {
            const mark = m[1]
            const body = []
            i++
            while (i < lines.length && !new RegExp(`^ {0,3}${mark[0] === '`' ? '`' : '~'}{${mark.length},}[ \\t]*$`).test(lines[i])) body.push(lines[i++])
            i++
            out.push({type: 'code', lang: m[2].toLowerCase(), text: body.join('\n')})
            continue
        }
        if ((m = HEADING.exec(line))) {
            out.push({type: 'heading', level: m[1].length, children: inline(m[2] ?? '', depth)})
            i++
            continue
        }
        if (RULE.test(line)) {
            out.push({type: 'hr'})
            i++
            continue
        }
        if (QUOTE.test(line)) {
            const inner = []
            while (i < lines.length && QUOTE.test(lines[i])) inner.push(lines[i++].replace(QUOTE, ''))
            out.push(depth < DEPTH_MAX ? {type: 'quote', children: blocks(inner, depth + 1)} : {type: 'paragraph', children: inline(inner.join('\n'), depth)})
            continue
        }
        if ((m = ITEM.exec(line))) {
            const ordered = /\d/.test(m[2])
            const list = {type: 'list', ordered, start: ordered ? parseInt(m[2], 10) : 1, items: []}
            while (i < lines.length) {
                const item = ITEM.exec(lines[i])
                if (!item || /\d/.test(item[2]) !== ordered) break
                const indent = item[0].length || item[1].length + item[2].length + 1
                const body = [lines[i].slice(item[0].length)]
                i++
                while (i < lines.length) {
                    const next = lines[i]
                    if (blank(next)) {
                        const after = lines.slice(i + 1).find(l => !blank(l))
                        if (after === undefined || leading(after) < indent) break
                        body.push('')
                        i++
                        continue
                    }
                    if (leading(next) >= indent) body.push(next.slice(Math.min(indent, leading(next))))
                    else if (!interrupts(next) && !blank(body[body.length - 1])) body.push(next)
                    else break
                    i++
                }
                list.items.push(depth < DEPTH_MAX ? blocks(body, depth + 1) : [{type: 'paragraph', children: inline(body.join('\n'), depth)}])
            }
            out.push(list)
            continue
        }
        const para = []
        while (i < lines.length && !blank(lines[i]) && (para.length === 0 || !interrupts(lines[i]))) para.push(lines[i++])
        out.push({type: 'paragraph', children: inline(para.map(l => l.replace(/^[ \t]+/, '')).join('\n'), depth)})
    }
    return out
}

function leading(line) {
    let n = 0
    for (const c of line) {
        if (c === ' ') n++
        else if (c === '\t') n += 4 - n % 4
        else break
    }
    return n
}

const ESCAPABLE = '\\`*_{}[]()#+-.!~>|'

// The inlines of a paragraph's text.
export function inline(text, depth = 0) {
    const out = []
    let buffer = ''
    const flush = () => {
        if (buffer) out.push({type: 'text', text: buffer})
        buffer = ''
    }
    const push = node => {
        flush()
        out.push(node)
    }
    const nested = inner => depth < DEPTH_MAX ? inline(inner, depth + 1) : [{type: 'text', text: inner}]
    for (let i = 0; i < text.length;) {
        const c = text[i]
        if (c === '\\' && i + 1 < text.length) {
            if (text[i + 1] === '\n') {
                push({type: 'br'})
                i += 2
                continue
            }
            if (ESCAPABLE.includes(text[i + 1])) {
                buffer += text[i + 1]
                i += 2
                continue
            }
        }
        if (c === '\n') {
            if (buffer.endsWith('  ')) {
                buffer = buffer.replace(/ +$/, '')
                push({type: 'br'})
            } else {
                buffer += '\n'
            }
            i++
            continue
        }
        if (c === '`') {
            let n = 0
            while (text[i + n] === '`') n++
            const run = '`'.repeat(n)
            let end = i + n
            for (;;) {
                end = text.indexOf(run, end)
                if (end < 0 || text[end + n] !== '`') break
                while (text[end] === '`') end++
            }
            if (end > 0) {
                let code = text.slice(i + n, end).replace(/\n/g, ' ')
                if (code.length > 2 && code.startsWith(' ') && code.endsWith(' ')) code = code.slice(1, -1)
                push({type: 'code', text: code})
                i = end + n
            } else {
                buffer += run
                i += n
            }
            continue
        }
        if (c === '!' && text[i + 1] === '[') {
            const link = linkAt(text, i + 1)
            if (link) {
                push(link.href ? {type: 'link', href: link.href, children: [{type: 'text', text: link.label || link.href}]} : {type: 'text', text: link.label})
                i = link.end
                continue
            }
        }
        if (c === '[') {
            const link = linkAt(text, i)
            if (link) {
                push(link.href ? {type: 'link', href: link.href, children: nested(link.label)} : {type: 'text', text: link.label})
                i = link.end
                continue
            }
        }
        if ((c === 'h' || c === 'H') && (i === 0 || /[\s(]/.test(text[i - 1]))) {
            const m = /^https?:\/\/[^\s<>()]+[^\s<>().,;:!?'"]/i.exec(text.slice(i))
            if (m) {
                push({type: 'link', href: m[0], children: [{type: 'text', text: m[0]}]})
                i += m[0].length
                continue
            }
        }
        const pair = text.slice(i, i + 2)
        if (pair === '**' || pair === '__' || pair === '~~') {
            const end = closing(text, i + 2, pair)
            if (end > i + 2) {
                push({type: pair === '~~' ? 'del' : 'strong', children: nested(text.slice(i + 2, end))})
                i = end + 2
                continue
            }
        }
        if ((c === '*' || c === '_') && !/\s/.test(text[i + 1] ?? ' ') && (c === '*' || i === 0 || !/[\p{L}\p{N}]/u.test(text[i - 1]))) {
            const end = closing(text, i + 1, c)
            if (end > i + 1 && (c === '*' || !/[\p{L}\p{N}]/u.test(text[end + 1] ?? ' '))) {
                push({type: 'em', children: nested(text.slice(i + 1, end))})
                i = end + 1
                continue
            }
        }
        buffer += c
        i++
    }
    flush()
    return out
}

// Where mark closes the run opened before from: not after a space, nor
// inside a code span; -1 when it does not.
function closing(text, from, mark) {
    for (let k = from; k < text.length; k++) {
        if (text[k] === '\\') {
            k++
            continue
        }
        if (text[k] === '`') {
            const end = text.indexOf('`', k + 1)
            if (end > 0) k = end
            continue
        }
        if (text.startsWith(mark, k) && !/\s/.test(text[k - 1]) && (mark.length === 2 || text[k + 1] !== mark)) return k
    }
    return -1
}

// A link [label](href "title") at at: its label, safe href or null, and end.
function linkAt(text, at) {
    let depth = 0, k = at
    for (; k < text.length; k++) {
        if (text[k] === '\\') {
            k++
            continue
        }
        if (text[k] === '[') depth++
        else if (text[k] === ']' && --depth === 0) break
    }
    if (k >= text.length || text[k + 1] !== '(') return null
    const close = text.indexOf(')', k + 2)
    if (close < 0) return null
    // A destination, then at most a quoted title.
    const target = /^\s*(<[^>]*>|\S+)(?:\s+("[^"]*"|'[^']*'))?\s*$/.exec(text.slice(k + 2, close))
    if (!target) return null
    return {label: text.slice(at + 1, k), href: safeHref(target[1].replace(/^<(.*)>$/, '$1')), end: close + 1}
}

// The text of inlines, without their marks.
export function plainText(nodes) {
    return nodes.map(n => n.text ?? (n.children ? plainText(n.children) : n.type === 'br' ? '\n' : '')).join('')
}
