// What the views share: the route, formatting, loading, actions and the
// errors they report, icons, and the diff.
import {html, mount, nodes} from './dom.js'
import {api, apiRaw, app} from './api.js'

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

export const short = text => (text || '').slice(0, 12)
export const plural = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`

export function when(ns) {
    return ns ? new Date(Number(ns) / 1e6).toLocaleString() : ''
}

const relative = new Intl.RelativeTimeFormat(undefined, {numeric: 'auto'})
const STEPS = [['year', 31536000], ['month', 2592000], ['week', 604800], ['day', 86400], ['hour', 3600], ['minute', 60]]

// A time as "3 days ago", the full date on hover.
export function ago(ns) {
    if (!ns) return null
    const date = new Date(Number(ns) / 1e6)
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

// The one place a failed action surfaces: the console keeps its stack, the
// page shows the node's text until it is dismissed.
export function report(error) {
    console.error(error)
    app.set({problem: error?.message || String(error)})
}

// A listener that runs work with the control that fired it disabled and
// marked busy; a form's submission does not leave the page.
export function action(work) {
    return async event => {
        event.preventDefault()
        const control = event.submitter ?? event.currentTarget
        if (control.disabled) return
        control.disabled = true
        control.setAttribute('aria-busy', 'true')
        try {
            await work(event)
        } catch (error) {
            report(error)
        } finally {
            control.disabled = false
            control.removeAttribute('aria-busy')
        }
    }
}

// An element that waits for load(), then holds render(data); reload() loads
// again and draws, draw() draws the data it has again. A first load that
// fails shows its error in place; a later one is reported and keeps the data.
export function loaded(load, render) {
    const node = html`<div class="loaded">${waiting()}</div>`
    let data = null
    const view = {
        node,
        draw: () => mount(node, () => render(data, view)),
        async reload() {
            let next
            try {
                next = await load()
            } catch (error) {
                if (data === null) node.replaceChildren(failed(error))
                else report(error)
                return
            }
            data = next
            view.draw()
        },
    }
    view.reload()
    return view
}

export function waiting(text = 'Loading') {
    return html`<p class="waiting" role="status"><span class="spinner" aria-hidden="true"></span>${text}…</p>`
}

export function failed(error) {
    return html`<div class="notice bad" role="alert">${icon('alert')}<div><strong>This could not be shown</strong><p>${error.message}</p></div></div>`
}

export function empty(title, text) {
    return html`<div class="empty">${icon('dot')}<strong>${title}</strong>${text ? html`<p>${text}</p>` : null}</div>`
}

export function badge(text, tone = text) {
    return html`<span class=${`badge ${tone}`}>${text}</span>`
}

export function hash(text, target) {
    const code = html`<code class="hash" title=${text}>${short(text)}</code>`
    return target ? html`<a class="hash-link" href=${target}>${code}</a>` : code
}

// What the node keeps of an org it hosts, against its quota.
export function usage(o) {
    return html`<div class="usage"><progress max=${String(o.quota)} value=${String(Math.min(o.bytes, o.quota))} aria-label="Storage used"></progress>
        <span class="quiet">${size(o.bytes)} of ${size(o.quota)}${o.full ? ' · full' : ''}</span></div>`
}

// A command or text to copy, in a field that selects itself.
export function copyField(text) {
    const copy = async event => {
        const button = event.currentTarget
        button.previousElementSibling.select()
        try {
            await navigator.clipboard.writeText(text)
            button.textContent = 'Copied'
            setTimeout(() => button.textContent = 'Copy', 1500)
        } catch {}
    }
    return html`<div class="copy"><input readonly aria-label="Text to copy" .value=${text} @focus=${e => e.target.select()}><button type="button" @click=${copy}>Copy</button></div>`
}

const ICONS = {
    folder: 'M1.75 4.25a1 1 0 0 1 1-1h3.5l1.5 1.5h5.5a1 1 0 0 1 1 1v6.5a1 1 0 0 1-1 1H2.75a1 1 0 0 1-1-1z',
    file: 'M3.75 1.75h5.5l3 3v9.5h-8.5z M9.25 1.75v3h3',
    lock: 'M4.25 7.25h7.5v6.5h-7.5z M5.75 7.25V5a2.25 2.25 0 0 1 4.5 0v2.25',
    check: 'M3.25 8.5l3 3 6.5-7',
    cross: 'M4.5 4.5l7 7 M11.5 4.5l-7 7',
    alert: 'M8 1.75l6.5 12H1.5z M8 6.25v3.5 M8 11.75v.5',
    dot: 'M8 5.25a2.75 2.75 0 1 1 0 5.5a2.75 2.75 0 1 1 0-5.5z M1 8h4.25 M10.75 8H15',
    comment: 'M2.25 2.75h11.5v8h-6.5l-3 2.5v-2.5h-2z',
    bookmark: 'M4.25 1.75h7.5v12.5L8 11.5l-3.75 2.75z',
    mark: 'M3.5 12.5L8 3.5l4.5 9 M3.5 12.5h9 M8 3.5v9',
}

export function icon(name) {
    return html`<svg class="icon" viewBox="0 0 16 16" aria-hidden="true"><path d=${ICONS[name]}/></svg>`
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
        if (error.status === 413) return {path, too_large: true, lines: []}
        throw error
    }
    const after = {size: Number(r.headers.get('content-length'))}
    if (!r.headers.get('content-type')?.startsWith('text/plain')) return {path, binary: true, before: null, after, lines: []}
    let text = await r.text()
    if (text.endsWith('\n')) text = text.slice(0, -1)
    const lines = text === '' ? [] : text.split('\n').map((t, i) => ({op: 'add', old: 0, new: i + 1, text: t}))
    return {path, binary: false, too_large: false, before: null, after, added: lines.length, removed: 0, lines}
}

const CONTEXT = 3

// Which lines a unified diff shows: the changed ones with CONTEXT lines
// around them, those whose new number is in keep, and those opened.
function shownLines(lines, keep, open) {
    const shown = lines.map((l, i) => open.has(i) || keep.has(l.new))
    lines.forEach((l, i) => {
        if (l.op !== 'same') for (let k = Math.max(0, i - CONTEXT); k <= Math.min(lines.length - 1, i + CONTEXT); k++) shown[k] = true
    })
    return shown
}

const SIGN = {same: ' ', add: '+', remove: '−'}

// A unified diff. options: pick(newLine, event) makes new line numbers
// clickable; after(newLine) gives what goes under a line; keep, the new line
// numbers always shown; selected, {line, lines} marked; open, the indexes of
// lines unfolded, kept across draws.
export function diffView(d, {pick, after, keep = new Set(), selected, open = new Set()} = {}) {
    if (d.binary) return html`<p class="quiet pad">Binary file: ${d.before ? size(d.before.size) : 'none'} → ${d.after ? size(d.after.size) : 'none'}</p>`
    if (d.too_large) return html`<p class="quiet pad">The file is too large to show its lines here: fetch it with mirai kai.</p>`
    if (d.lines.length === 0) return html`<p class="quiet pad">No lines.</p>`
    const row = i => {
        const l = d.lines[i]
        const picked = selected && l.new >= selected.line && l.new < selected.line + selected.lines
        const number = pick && l.new
            ? html`<td class="num pick" title="Comment on this line; shift-click for a range" @click=${e => pick(l.new, e)}>${l.new}</td>`
            : html`<td class="num">${l.new || ''}</td>`
        const extra = l.new ? after?.(l.new) : null
        return [
            html`<tr class=${picked ? `${l.op} picked` : l.op}><td class="num">${l.old || ''}</td>${number}<td class="sign">${SIGN[l.op]}</td><td class="text">${l.text}</td></tr>`,
            extra ? html`<tr class="extra"><td colspan="4">${extra}</td></tr>` : null,
        ]
    }
    const fold = (first, count) => {
        const unfold = event => {
            for (let i = first; i < first + count; i++) open.add(i)
            event.currentTarget.closest('tr').replaceWith(...nodes(Array.from({length: count}, (_, k) => row(first + k))))
        }
        return html`<tr class="fold"><td colspan="4"><button type="button" class="link" @click=${unfold}>Show ${plural(count, 'unchanged line')}</button></td></tr>`
    }
    const shown = shownLines(d.lines, keep, open)
    const body = []
    for (let i = 0; i < d.lines.length;) {
        if (shown[i]) {
            body.push(row(i++))
            continue
        }
        let j = i
        while (j < d.lines.length && !shown[j]) j++
        body.push(fold(i, j - i))
        i = j
    }
    return html`<div class="scroll">
        ${d.truncated ? html`<p class="quiet pad">Only the first lines are shown: the diff is longer than the node answers.</p>` : null}
        <table class="diff"><tbody>${body}</tbody></table>
    </div>`
}
