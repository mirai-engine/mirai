// What the views share: the route and the page's title and breadcrumbs,
// formatting, loading without flashes, toasts, dialogs, icons and avatars,
// Markdown, highlighted code and the diff viewer.
import {el, html, nodes} from './dom.js'
import {api, apiRaw, app} from './api.js'
import {parseMarkdown} from './markdown.js'
import {highlighter, languageOf} from './highlight.js'
import {counts, pairs, segments, splitRows, wordDiff} from './diffs.js'

export function navigate(target, replace = false) {
    if (replace) history.replaceState(null, '', target)
    else history.pushState(null, '', target)
    dispatchEvent(new Event('route'))
    if (!replace) scrollTo(0, 0)
}

export function href(path, query = {}) {
    const q = new URLSearchParams()
    for (const [k, v] of Object.entries(query)) if (v !== undefined && v !== null && v !== '') q.set(k, v)
    const text = q.toString()
    return text ? `${path}?${text}` : path
}

// The page's title, breadcrumbs ([{label, href}]) and primary action, shown
// in the top bar; the document's title follows them.
export function setPage({title = '', crumbs = [], action = null} = {}) {
    const parts = [title, ...crumbs.slice(0, -1).reverse().map(c => c.label).slice(0, 1)].filter(Boolean)
    document.title = [...new Set(parts), 'KaiHub'].join(' · ')
    app.set({page: {title, crumbs, action}})
}

export const short = text => (text || '').slice(0, 8)
export const plural = (n, word, many = `${word}s`) => `${n.toLocaleString()} ${n === 1 ? word : many}`

export function when(ns) {
    return ns ? new Date(Number(ns) / 1e6).toLocaleString() : ''
}

const relative = new Intl.RelativeTimeFormat(undefined, {numeric: 'auto'})
const STEPS = [['year', 31536000], ['month', 2592000], ['week', 604800], ['day', 86400], ['hour', 3600], ['minute', 60]]

// A time as "3 days ago", the full date on hover.
export function ago(ns) {
    if (!ns) return null
    const date = new Date(Number(ns) / 1e6)
    if (date.getFullYear() < 2000) return null
    const seconds = (date - Date.now()) / 1000
    const [unit, length] = STEPS.find(([, s]) => Math.abs(seconds) >= s) ?? ['second', 1]
    return html`<time datetime=${date.toISOString()} title=${date.toLocaleString()}>${relative.format(Math.round(seconds / length), unit)}</time>`
}

export function size(n) {
    if (n < 1024) return `${n} B`
    const units = ['KiB', 'MiB', 'GiB', 'TiB']
    let v = n, u = -1
    while (v >= 1024 && u < units.length - 1) {
        v /= 1024
        u++
    }
    return `${v.toFixed(v < 10 ? 1 : 0)} ${units[u]}`
}

// --- Toasts and failures ---

let toastId = 0

// A message in the corner: ok and info ones go by themselves, a bad one
// stays until dismissed.
export function toast(text, tone = 'ok') {
    const id = ++toastId
    app.set({toasts: [...app.toasts, {id, text, tone}].slice(-4)})
    if (tone !== 'bad') setTimeout(() => dismiss(id), 4500)
    return id
}

export function dismiss(id) {
    if (app.toasts.some(t => t.id === id)) app.set({toasts: app.toasts.filter(t => t.id !== id)})
}

// The one place a failed action surfaces: the console keeps its stack, the
// page shows the node's text until it is dismissed.
export function report(error) {
    console.error(error)
    const text = error?.message || String(error)
    toast(text.charAt(0).toUpperCase() + text.slice(1), 'bad')
}

// A listener that runs work with the control that fired it disabled and
// marked busy; a form's submission does not leave the page. A string done
// is shown as a toast when the work ends well.
export function action(work, done) {
    return async event => {
        event.preventDefault?.()
        const control = event.submitter ?? event.currentTarget
        if (control?.disabled) return
        if (control) {
            control.disabled = true
            control.setAttribute('aria-busy', 'true')
        }
        try {
            await work(event)
            if (done) toast(done)
        } catch (error) {
            report(error)
        } finally {
            if (control) {
                control.disabled = false
                control.removeAttribute('aria-busy')
            }
        }
    }
}

// --- Loading ---

// A value loaded once and kept: get() answers it, and a failed load is not
// kept, so the next get() tries again. peek() has it at once once loaded.
export function cell(load) {
    let promise = null, done = false, value
    return {
        get() {
            if (done) return Promise.resolve(value)
            promise ??= Promise.resolve().then(load).then(v => {
                value = v
                done = true
                return v
            }, error => {
                promise = null
                throw error
            })
            return promise
        },
        peek: () => done ? {value} : null,
    }
}

// The cell of key in a map of cells, made by load the first time.
export function once(cells, key, load) {
    if (!cells.has(key)) cells.set(key, cell(load))
    return cells.get(key)
}

// An element that holds render(data) once load() gives data: a skeleton till
// then, the data at once when load gives a loaded cell. reload() loads again
// and draws in place, keeping what shows and where the page is scrolled
// while it loads; draw() draws the data it has again. A first load that
// fails shows its error with a retry; a later one is reported and keeps the data.
export function loaded(load, render, {skeleton: shape = 'rows'} = {}) {
    const node = el('div', 'loaded')
    let data, has = false
    const view = {
        node,
        draw() {
            const y = scrollY
            node.replaceChildren(...nodes(render(data, view)))
            if (scrollY !== y) scrollTo(scrollX, y)
        },
        async reload() {
            let next
            try {
                const source = load()
                const ready = source?.peek?.()
                next = ready ? ready.value : await (source?.get ? source.get() : source)
            } catch (error) {
                if (!has) node.replaceChildren(failed(error, () => {
                    node.replaceChildren(skeleton(shape))
                    view.reload()
                }))
                else report(error)
                return
            }
            data = next
            has = true
            view.draw()
        },
    }
    let source
    try {
        source = load()
    } catch (error) {
        node.replaceChildren(failed(error))
        return view
    }
    const ready = source?.peek?.()
    if (ready) {
        data = ready.value
        has = true
        view.draw()
    } else {
        node.replaceChildren(skeleton(shape))
        Promise.resolve(source?.get ? source.get() : source).then(value => {
            data = value
            has = true
            view.draw()
        }, error => node.replaceChildren(failed(error, () => {
            node.replaceChildren(skeleton(shape))
            view.reload()
        })))
    }
    return view
}

// Grey shapes where content will be: rows of a list, a block of text, or a page.
export function skeleton(shape = 'rows') {
    const bar = cls => el('span', `bone ${cls}`)
    if (shape === 'text') return el('div', 'skeleton', bar('w80'), bar('w60'), bar('w70'), bar('w40'))
    if (shape === 'page') return el('div', 'skeleton page-bones', bar('title'), bar('w60'), el('div', 'bone block'), bar('w80'), bar('w70'))
    if (shape === 'inline') return el('span', 'skeleton inline', bar('w40'))
    return el('div', 'skeleton', ...Array.from({length: 4}, (_, i) => el('div', 'bone-row', bar('dot'), bar(['w60', 'w40', 'w70', 'w50'][i]))))
}

export function failed(error, retry) {
    return html`<div class="notice bad" role="alert">${icon('x-circle')}<div><strong>This could not be shown</strong><p>${error.message}</p>
        ${retry ? html`<button type="button" class="small" @click=${retry}>Try again</button>` : null}</div></div>`
}

// A polished empty state: an icon, a title, a line of text and one action.
export function empty(title, text, cta) {
    return html`<div class="empty">${el('span', 'empty-icon', icon('sparkle'))}<strong>${title}</strong>${text ? html`<p>${text}</p>` : null}${cta ?? null}</div>`
}

export function badge(text, tone = text) {
    return html`<span class=${`badge ${tone}`}>${text}</span>`
}

// An id shortened, the whole of it on hover and a click away from the clipboard.
export function hash(text, target) {
    if (!text) return null
    const code = html`<code class="hash" title=${text}>${short(text)}</code>`
    return target ? html`<a class="hash-link" href=${target}>${code}</a>` : code
}

// --- People ---

function seed(text) {
    let n = 0
    for (const c of String(text)) n = n * 31 + c.charCodeAt(0) >>> 0
    return n
}

export function initials(name) {
    const words = String(name || '?').trim().split(/\s+/).filter(Boolean)
    const first = [...(words[0] ?? '?')][0] ?? '?'
    const second = words.length > 1 ? [...words[words.length - 1]][0] : ''
    return (first + second).toUpperCase()
}

// A round avatar of someone's initials, colored by who they are.
export function avatar(name, key = name, big = false) {
    return el('span', `avatar av-${seed(key || name || '?') % 6}${big ? ' big' : ''}`, initials(name))
}

// Someone by name with their avatar; their id on hover.
export function person(name, key, {plain = false} = {}) {
    const label = name || (key ? `Unknown ${short(key)}` : 'Unknown')
    const node = html`<span class="person" title=${key || null}>${avatar(name || '?', key)}<span class="person-name">${label}</span></span>`
    if (plain) node.classList.add('plain')
    return node
}

// --- Small controls ---

// A thin meter of used against total, with its words beside it.
export function meter(used, total, label) {
    const ratio = total > 0 ? Math.min(1, used / total) : 0
    const tone = ratio >= 0.95 ? 'bad' : ratio >= 0.8 ? 'warn' : 'ok'
    return html`<div class=${`meter ${tone}`}>
        <progress max="1000" value=${String(Math.round(ratio * 1000))} aria-label=${label}></progress>
        <span class="meter-text tabular">${size(used)} of ${size(total)}</span>
    </div>`
}

async function clipboard(text, button) {
    try {
        await navigator.clipboard.writeText(text)
        toast('Copied to the clipboard', 'info')
        if (button) {
            button.classList.add('copied')
            setTimeout(() => button.classList.remove('copied'), 1500)
        }
    } catch {
        report(new Error('the browser did not allow copying: select the text and copy it'))
    }
}

// A command or text to copy, in a box with a Copy button.
export function copyField(text, {label = 'Text to copy', mono = true} = {}) {
    return html`<div class=${mono ? 'copy mono' : 'copy'}>
        <input readonly aria-label=${label} .value=${text} @focus=${e => e.target.select()}>
        <button type="button" class="small" @click=${e => clipboard(text, e.currentTarget)}>${icon('copy')}<span>Copy</span></button>
    </div>`
}

// A small icon button that copies text.
export function copyButton(text, label = 'Copy') {
    return html`<button type="button" class="icon-button" title=${label} aria-label=${label} @click=${e => clipboard(text, e.currentTarget)}>${icon('copy')}</button>`
}

// A collapsed section of ids and keys for those who need them.
export function technical(rows) {
    const list = rows.filter(r => r && r[1])
    if (list.length === 0) return null
    return html`<details class="technical"><summary>${icon('code')}Technical details</summary>
        <dl class="facts">${list.map(([k, v]) => [html`<dt>${k}</dt>`, html`<dd><code class="full">${v}</code>${copyButton(v, `Copy ${k.toLowerCase()}`)}</dd>`])}</dl>
    </details>`
}

// A modal question; answers true when confirmed.
export function confirmDialog({title, text, steps = [], confirm = 'Continue', tone = 'primary'}) {
    return new Promise(done => {
        const dialog = html`<dialog class="dialog" aria-labelledby="dialog-title">
            <form method="dialog">
                <h2 id="dialog-title">${title}</h2>
                ${text ? html`<p>${text}</p>` : null}
                ${steps.length ? html`<ol class="steps-list">${steps.map(s => html`<li>${icon('key')}<span>${s}</span></li>`)}</ol>` : null}
                <div class="actions end">
                    <button type="submit" value="cancel" class="ghost">Cancel</button>
                    <button type="submit" value="ok" class=${tone}>${confirm}</button>
                </div>
            </form>
        </dialog>`
        dialog.addEventListener('close', () => {
            dialog.remove()
            done(dialog.returnValue === 'ok')
        })
        document.body.append(dialog)
        dialog.showModal()
        dialog.querySelector('button[value="ok"]').focus()
    })
}

// --- Icons: 16px, 1.5px strokes ---

const ICONS = {
    folder: 'M2 4.5a1 1 0 0 1 1-1h3.2l1.4 1.5H13a1 1 0 0 1 1 1V12a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1z',
    file: 'M4 1.75h5l3 3v9.5H4z M9 1.75v3h3',
    'file-code': 'M4 1.75h5l3 3v9.5H4z M9 1.75v3h3 M7 8.25l-1.25 1.5L7 11.25 M9 8.25l1.25 1.5L9 11.25',
    lock: 'M4.25 7.25h7.5v6.5h-7.5z M5.75 7.25V5a2.25 2.25 0 0 1 4.5 0v2.25',
    check: 'M3.25 8.5l3 3 6.5-7',
    cross: 'M4.5 4.5l7 7 M11.5 4.5l-7 7',
    alert: 'M8 1.75l6.5 12H1.5z M8 6.25v3.5 M8 11.75v.5',
    dot: 'M8 6a2 2 0 1 1 0 4a2 2 0 1 1 0-4z',
    comment: 'M2.25 2.75h11.5v8h-6.5l-3 2.5v-2.5h-2z',
    bookmark: 'M4.25 1.75h7.5v12.5L8 11.5l-3.75 2.75z',
    search: 'M7 2.5a4.5 4.5 0 1 1 0 9a4.5 4.5 0 1 1 0-9z M10.25 10.25L13.5 13.5',
    'chevron-right': 'M6 3.5L10.5 8 6 12.5',
    'chevron-down': 'M3.5 6L8 10.5 12.5 6',
    branch: 'M5 2.5v7 M5 9.5a1.75 1.75 0 1 0 0 3.5a1.75 1.75 0 1 0 0-3.5z M11 3a1.75 1.75 0 1 0 0 3.5a1.75 1.75 0 1 0 0-3.5z M11 6.5c0 2.5-3 2.25-6 3',
    change: 'M8 5.25a2.75 2.75 0 1 1 0 5.5a2.75 2.75 0 1 1 0-5.5z M1.5 8h3.75 M10.75 8h3.75',
    stack: 'M8 1.75l6 3-6 3-6-3z M2 8l6 3 6-3 M2 11.25l6 3 6-3',
    'check-circle': 'M8 1.75a6.25 6.25 0 1 1 0 12.5a6.25 6.25 0 1 1 0-12.5z M5.25 8.25l2 2 3.5-4',
    'x-circle': 'M8 1.75a6.25 6.25 0 1 1 0 12.5a6.25 6.25 0 1 1 0-12.5z M5.75 5.75l4.5 4.5 M10.25 5.75l-4.5 4.5',
    plus: 'M8 3v10 M3 8h10',
    copy: 'M5.75 5.75h7.5v7.5h-7.5z M3.75 10.25h-1v-7.5h7.5v1',
    key: 'M5.5 7a3 3 0 1 1 0 .01z M8.25 8.5h6 M12 8.5v2.25 M14 8.5v1.5',
    laptop: 'M3.25 3.5h9.5v6.5h-9.5z M1.5 12.5h13',
    building: 'M3 14V2.75h7V14 M10 6.5h3V14 M1.5 14h13 M5.25 5h1.5 M5.25 7.5h1.5 M5.25 10h1.5',
    users: 'M6 3a2.25 2.25 0 1 1 0 4.5A2.25 2.25 0 1 1 6 3z M1.75 13.25c0-2.5 1.9-4 4.25-4s4.25 1.5 4.25 4 M10.5 3.25a2.1 2.1 0 0 1 0 4.1 M11.75 9.5c1.6.4 2.5 1.75 2.5 3.75',
    server: 'M2.25 2.75h11.5v4h-11.5z M2.25 9.25h11.5v4h-11.5z M4.75 4.75h.5 M4.75 11.25h.5',
    shield: 'M8 1.75l5.25 2v4c0 3.25-2.25 5.5-5.25 6.5-3-1-5.25-3.25-5.25-6.5v-4z',
    eye: 'M1.5 8s2.5-4.75 6.5-4.75S14.5 8 14.5 8s-2.5 4.75-6.5 4.75S1.5 8 1.5 8z M8 6.25a1.75 1.75 0 1 1 0 3.5a1.75 1.75 0 1 1 0-3.5z',
    code: 'M5.5 4.5L2 8l3.5 3.5 M10.5 4.5L14 8l-3.5 3.5',
    columns: 'M2.25 2.75h11.5v10.5H2.25z M8 2.75v10.5',
    list: 'M5.5 4h8 M5.5 8h8 M5.5 12h8 M2.5 4h.5 M2.5 8h.5 M2.5 12h.5',
    external: 'M9.5 2.5h4v4 M13.5 2.5L7.5 8.5 M11.5 9.5v4h-9v-9h4',
    'arrow-right': 'M2.5 8h11 M9 3.5L13.5 8 9 12.5',
    download: 'M8 2v8.5 M4.5 7L8 10.5 11.5 7 M2.5 13.5h11',
    sparkle: 'M8 1.75l1.5 4.75 4.75 1.5-4.75 1.5L8 14.25 6.5 9.5 1.75 8l4.75-1.5z',
    rocket: 'M9.5 2.5c2-.75 3.5-.75 4-.25s.5 2-.25 4L9 10.5 5.5 7z M5.5 7L3 6.75 4.5 5.25h2.25 M9 10.5l.25 2.5 1.5-1.5V9.25 M4.75 11.25c-1 .25-2 1.75-2.25 2.25.5-.25 2-1.25 2.25-2.25z',
    menu: 'M2.5 4h11 M2.5 8h11 M2.5 12h11',
    'sign-out': 'M6 2.75H3v10.5h3 M10 5l3 3-3 3 M13 8H6',
    home: 'M2.25 7.25L8 2.5l5.75 4.75 M3.75 6v7.25h8.5V6',
    git: 'M8 1.75l6.25 6.25L8 14.25 1.75 8z M8 5v4.5',
    mark: 'M8 1.5l5.75 3.25v6.5L8 14.5l-5.75-3.25v-6.5z M5.5 5.5v5 M5.5 8.25l3.25-2.75 M6.75 7.25L10.5 10.5',
}

export function icon(name) {
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg')
    svg.setAttribute('class', `icon icon-${name}`)
    svg.setAttribute('viewBox', '0 0 16 16')
    svg.setAttribute('aria-hidden', 'true')
    const path = document.createElementNS('http://www.w3.org/2000/svg', 'path')
    path.setAttribute('d', ICONS[name] ?? ICONS.dot)
    svg.append(path)
    return svg
}

// The brand mark: a violet tile with Kai's K.
export function brandMark(big = false) {
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg')
    svg.setAttribute('class', big ? 'brand-mark big' : 'brand-mark')
    svg.setAttribute('viewBox', '0 0 24 24')
    svg.setAttribute('aria-hidden', 'true')
    const tile = document.createElementNS('http://www.w3.org/2000/svg', 'rect')
    for (const [k, v] of Object.entries({width: 24, height: 24, rx: 6, class: 'brand-tile'})) tile.setAttribute(k, v)
    const k = document.createElementNS('http://www.w3.org/2000/svg', 'path')
    k.setAttribute('d', 'M8.5 6.5v11 M8.5 12.75l6.5-6.25 M10.75 10.6l4.75 6.9')
    k.setAttribute('class', 'brand-k')
    svg.append(tile, k)
    return svg
}

// --- Markdown ---

// Markdown as DOM, built node by node from markdown.js's tree: headings
// start a level below the page's own, links are http(s) or resolved by
// resolve(href) for relative ones.
export function markdown(text, {resolve} = {}) {
    const inlines = list => list.map(n => {
        switch (n.type) {
        case 'text': return document.createTextNode(n.text)
        case 'strong': return el('strong', null, inlines(n.children))
        case 'em': return el('em', null, inlines(n.children))
        case 'del': return el('del', null, inlines(n.children))
        case 'code': return el('code', null, n.text)
        case 'br': return el('br')
        case 'link': {
            const a = el('a', null, inlines(n.children))
            const external = /^https?:/i.test(n.href)
            a.setAttribute('href', external || !resolve ? n.href : resolve(n.href))
            if (external) {
                a.setAttribute('target', '_blank')
                a.setAttribute('rel', 'noopener noreferrer')
            }
            return a
        }
        }
        return null
    })
    const blocks = list => list.map(b => {
        switch (b.type) {
        case 'heading': return el(`h${Math.min(6, b.level + 1)}`, null, inlines(b.children))
        case 'paragraph': return el('p', null, inlines(b.children))
        case 'hr': return el('hr')
        case 'quote': return el('blockquote', null, blocks(b.children))
        case 'code': return codeBlock(b.text, b.lang)
        case 'list': {
            const node = el(b.ordered ? 'ol' : 'ul', null, b.items.map(item =>
                el('li', null, item.length === 1 && item[0].type === 'paragraph' ? inlines(item[0].children) : blocks(item))))
            if (b.ordered && b.start !== 1) node.setAttribute('start', String(b.start))
            return node
        }
        }
        return null
    })
    return el('div', 'md', blocks(parseMarkdown(text)))
}

// A fenced block of code, highlighted.
export function codeBlock(text, lang) {
    const h = highlighter(languageOf(lang))
    const lines = text.split('\n')
    return el('pre', 'code-block', el('code', null, lines.map((line, i) => [...spans(h.next(line)), i < lines.length - 1 ? '\n' : null])))
}

const TOKEN = {com: 'tok-com', str: 'tok-str', num: 'tok-num', kw: 'tok-kw', type: 'tok-type', lit: 'tok-lit', fn: 'tok-fn', prop: 'tok-prop', meta: 'tok-meta', var: 'tok-var', punct: 'tok-punct'}

// The spans of tokens or segments: plain text stays a text node.
function spans(list) {
    return list.map(x => {
        const cls = [TOKEN[x.t], x.mark ? 'wd' : ''].filter(Boolean).join(' ')
        return cls ? el('span', cls, x.s) : document.createTextNode(x.s)
    })
}

// --- Code and diffs ---

export const LINES_STEP = 2000 // lines a file or diff draws at a time

// A text file's lines, numbered and highlighted, LINES_STEP at a time, with
// a bar that draws more or downloads the file.
export function codeView(text, path, raw) {
    const lines = text.endsWith('\n') ? text.slice(0, -1).split('\n') : text.split('\n')
    const h = highlighter(languageOf(path))
    const body = el('tbody')
    const table = el('table', 'code', body)
    const bar = el('div', 'more-bar')
    let shown = 0
    const more = () => {
        const end = Math.min(lines.length, shown + LINES_STEP)
        const rows = []
        for (let i = shown; i < end; i++) {
            const row = el('tr', null, el('td', 'num', String(i + 1)), el('td', 'text', spans(h.next(lines[i]))))
            row.id = `L${i + 1}`
            rows.push(row)
        }
        body.append(...rows)
        shown = end
        const left = lines.length - shown
        bar.replaceChildren(...(left > 0 ? nodes([
            el('span', 'quiet', `Showing ${shown.toLocaleString()} of ${plural(lines.length, 'line')}`),
            html`<button type="button" class="small" @click=${more}>Load ${Math.min(left, LINES_STEP).toLocaleString()} more lines</button>`,
            html`<a class="button small ghost" href=${raw} download>${icon('download')}Download raw file</a>`,
        ]) : []))
        bar.hidden = left <= 0
    }
    more()
    return el('div', 'code-frame', el('div', 'scroll', table), bar)
}

// The lines of one file between two revisions: the diff route's, or every
// line added when there is no old revision.
export async function fileDiff(project, from, to, path) {
    const base = `/api/projects/${project}`
    if (from) return api(href(`${base}/diff`, {from, to, path}))
    let r
    try {
        r = await apiRaw(href(`${base}/file`, {rev: to, path}))
    } catch (error) {
        if (error.status === 413) return {path, too_large: true, lines: [], added: 0, removed: 0}
        throw error
    }
    const after = {size: Number(r.headers.get('content-length'))}
    if (!r.headers.get('content-type')?.startsWith('text/plain')) return {path, binary: true, before: null, after, lines: [], added: 0, removed: 0}
    let text = await r.text()
    if (text.endsWith('\n')) text = text.slice(0, -1)
    const lines = text === '' ? [] : text.split('\n').map((t, i) => ({op: 'add', old: 0, new: i + 1, text: t}))
    return {path, binary: false, too_large: false, before: null, after, added: lines.length, removed: 0, lines}
}

export function setDiffMode(mode) {
    try {
        localStorage.setItem('kai-diff-mode', mode)
    } catch {}
    app.set({diffMode: mode})
}

// The Unified / Split switch; it marks the layout chosen itself.
export function diffModeSwitch() {
    const node = html`<div class="segmented small" role="group" aria-label="Diff layout"></div>`
    const option = (value, label, name) => html`<button type="button" class=${app.diffMode === value ? 'active' : null} aria-pressed=${app.diffMode === value ? 'true' : 'false'}
        @click=${() => {
            setDiffMode(value)
            draw()
        }}>${icon(name)}<span>${label}</span></button>`
    const draw = () => node.replaceChildren(option('unified', 'Unified', 'list'), option('split', 'Split', 'columns'))
    draw()
    return node
}

const CONTEXT = 3

// Which lines a diff shows: the changed ones with CONTEXT lines around
// them, those whose new number is in keep, and those opened.
function shownLines(lines, keep, open) {
    const shown = lines.map((l, i) => open.has(i) || keep.has(l.new))
    lines.forEach((l, i) => {
        if (l.op !== 'same') for (let k = Math.max(0, i - CONTEXT); k <= Math.min(lines.length - 1, i + CONTEXT); k++) shown[k] = true
    })
    return shown
}

const SIGN = {same: ' ', add: '+', remove: '−'}

// A diff of one file, unified or split by app.diffMode, highlighted, with
// the words that changed marked on paired lines. Options: pick(newLine,
// event) puts a + on each new line that opens a comment there; after(newLine)
// gives what goes under a line; keep, the new line numbers always shown;
// selected, {line, lines} marked; open, the indexes of lines unfolded, kept
// across draws. It draws LINES_STEP rows at a time.
export function diffView(d, {pick, after, keep = new Set(), selected, open = new Set(), mode = app.diffMode} = {}) {
    if (d.binary) return html`<p class="quiet pad">Binary file: ${d.before ? size(d.before.size) : 'none'} → ${d.after ? size(d.after.size) : 'none'}</p>`
    if (d.too_large) return html`<p class="quiet pad">This file is too large to show line by line here. Fetch it with Kai on your computer.</p>`
    if (d.lines.length === 0) return html`<p class="quiet pad">No lines.</p>`
    const lines = d.lines
    const lang = languageOf(d.path)
    const oldSide = highlighter(lang), newSide = highlighter(lang)
    const tokens = lines.map(l => {
        if (l.op === 'remove') return oldSide.next(l.text)
        if (l.op === 'same') oldSide.next(l.text)
        return newSide.next(l.text)
    })
    const partner = pairs(lines)
    const marks = new Map()
    for (const [i, k] of partner) {
        if (lines[i].op !== 'remove') continue
        const w = wordDiff(lines[i].text, lines[k].text)
        if (w) {
            marks.set(i, w.before)
            marks.set(k, w.after)
        }
    }
    const split = mode === 'split'
    const columns = 4
    const textCell = (i, side) => {
        if (i < 0) return el('td', 'text blank')
        const l = lines[i]
        return el('td', `text ${side ? `${l.op}` : ''}`.trim(), spans(segments(tokens[i], marks.get(i))))
    }
    const newNumber = l => {
        const cell = el('td', 'num', l.new ? String(l.new) : '')
        if (pick && l.new) {
            cell.classList.add('pickable')
            const button = html`<button type="button" class="add-comment" aria-label=${`Comment on line ${l.new}`} title="Comment on this line; shift-click for a range" @click=${e => pick(l.new, e)}>${icon('plus')}</button>`
            cell.prepend(button)
        }
        return cell
    }
    const picked = l => selected && l.new && l.new >= selected.line && l.new < selected.line + selected.lines
    const extraRow = n => {
        const extra = n ? after?.(n) : null
        return extra ? el('tr', 'extra', Object.assign(el('td', null, extra), {colSpan: columns})) : null
    }
    const rowNodes = row => {
        if (split) {
            const [left, right] = row
            const l = left >= 0 ? lines[left] : null, r = right >= 0 ? lines[right] : null
            const tr = el('tr', l?.op === 'same' ? 'same' : 'change',
                el('td', `num ${l && l.op !== 'same' ? 'remove' : ''}`.trim(), l ? String(l.old || '') : ''),
                textCell(left, true),
                r ? newNumber(r) : el('td', 'num'),
                textCell(right, true))
            if (r?.op === 'add') tr.children[2].classList.add('add')
            if (r && picked(r)) tr.classList.add('picked')
            return [tr, extraRow(r?.new)]
        }
        const l = lines[row[0]]
        const tr = el('tr', l.op, el('td', 'num', l.old ? String(l.old) : ''), newNumber(l), el('td', 'sign', SIGN[l.op]), textCell(row[0], false))
        if (picked(l)) tr.classList.add('picked')
        return [tr, extraRow(l.new)]
    }
    const rows = split ? splitRows(lines) : lines.map((_, i) => [i])
    const shown = shownLines(lines, keep, open)
    const visible = row => row.some(i => i >= 0 && shown[i])
    // The items to draw: a row, or a fold of hidden rows.
    const items = []
    for (let i = 0; i < rows.length;) {
        if (visible(rows[i])) {
            items.push({row: rows[i++]})
            continue
        }
        let j = i
        while (j < rows.length && !visible(rows[j])) j++
        items.push({fold: rows.slice(i, j)})
        i = j
    }
    const foldNode = hidden => {
        const count = hidden.length
        const unfold = event => {
            for (const row of hidden) for (const i of row) if (i >= 0) open.add(i)
            event.currentTarget.closest('tr').replaceWith(...nodes(hidden.map(rowNodes)))
        }
        return el('tr', 'fold', Object.assign(el('td', null, html`<button type="button" class="link" @click=${unfold}>${icon('chevron-down')}Show ${plural(count, 'unchanged line')}</button>`), {colSpan: columns}))
    }
    const body = el('tbody')
    let drawn = 0
    const more = () => {
        const end = Math.min(items.length, drawn + LINES_STEP)
        const out = []
        for (let k = drawn; k < end; k++) out.push(items[k].row ? rowNodes(items[k].row) : foldNode(items[k].fold))
        body.querySelector('tr.more')?.remove()
        body.append(...nodes(out))
        drawn = end
        if (drawn < items.length) {
            body.append(el('tr', 'more', Object.assign(el('td', null, html`<button type="button" class="small" @click=${more}>Show ${Math.min(items.length - drawn, LINES_STEP).toLocaleString()} more rows</button>`), {colSpan: columns})))
        }
    }
    more()
    return el('div', 'scroll diff-scroll',
        d.truncated ? html`<p class="quiet pad">Only the first lines are shown: the diff is longer than the server answers.</p>` : null,
        el('table', split ? 'diff split-view' : 'diff', body))
}

// The +added −removed of a diff.
export function diffStat(d) {
    const {added, removed} = d.lines?.length ? counts(d.lines) : {added: d.added ?? 0, removed: d.removed ?? 0}
    return html`<span class="stat tabular"><span class="added">+${added}</span><span class="removed">−${removed}</span></span>`
}
