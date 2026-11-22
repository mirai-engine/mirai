// What the views share: the route, links, loading, errors and the diff.
import {h, reactive, ref, onUnmounted} from './vue.js'
import {api, apiRaw} from './api.js'

export const route = reactive({path: location.pathname, query: Object.fromEntries(new URLSearchParams(location.search))})

export function navigate(target, replace = false) {
    if (replace) history.replaceState(null, '', target)
    else history.pushState(null, '', target)
    const url = new URL(target, location.origin)
    route.path = url.pathname
    route.query = Object.fromEntries(url.searchParams)
    if (!replace) window.scrollTo(0, 0)
}

addEventListener('popstate', () => {
    route.path = location.pathname
    route.query = Object.fromEntries(new URLSearchParams(location.search))
})

export function href(path, query = {}) {
    const q = new URLSearchParams()
    for (const [k, v] of Object.entries(query)) if (v !== undefined && v !== null && v !== '') q.set(k, v)
    const text = q.toString()
    return text ? `${path}?${text}` : path
}

export function link(target, children, props = {}) {
    return h('a', {...props, href: target, onClick: e => {
        if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return
        e.preventDefault()
        navigate(target)
    }}, children)
}

export const short = text => (text || '').slice(0, 12)

export function when(ns) {
    if (!ns) return ''
    return new Date(Number(ns) / 1e6).toLocaleString()
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

// What a loader holds: its data, or the error text the node gave.
export function useLoad(fetcher) {
    const s = reactive({data: null, error: '', loading: true})
    s.reload = async () => {
        s.loading = true
        try {
            s.data = await fetcher()
            s.error = ''
        } catch (error) {
            s.error = error.message
        }
        s.loading = false
    }
    s.reload()
    return s
}

export function errorBox(text) {
    return text ? h('p', {class: 'error', role: 'alert'}, text) : null
}

// The view of a loader: its error, a quiet wait, or what render makes of its data.
export function frame(load, render) {
    if (load.error && !load.data) return errorBox(load.error)
    if (!load.data) return h('p', {class: 'quiet'}, 'Loading…')
    return [errorBox(load.error), render(load.data)]
}

// An action of a button: busy while it runs, its error kept to show.
export function useAction(run) {
    const s = reactive({busy: false, error: ''})
    s.run = async (...args) => {
        if (s.busy) return
        s.busy = true
        s.error = ''
        try {
            await run(...args)
        } catch (error) {
            s.error = error.message
        }
        s.busy = false
    }
    return s
}

export function button(label, action, props = {}) {
    return h('button', {type: 'button', disabled: action.busy || props.disabled, class: props.class, onClick: () => action.run(...(props.args || []))}, label)
}

// A command or text to copy, in a field that selects itself.
export const Copy = {
    props: ['text'],
    setup(props) {
        const copied = ref(false)
        let timer = 0
        onUnmounted(() => clearTimeout(timer))
        const copy = async e => {
            const field = e.target.closest('.copy').querySelector('input')
            field.select()
            try {
                await navigator.clipboard.writeText(props.text)
                copied.value = true
                timer = setTimeout(() => copied.value = false, 1500)
            } catch {}
        }
        return () => h('div', {class: 'copy'}, [
            h('input', {readonly: true, value: props.text, onFocus: e => e.target.select()}),
            h('button', {type: 'button', onClick: copy}, copied.value ? 'Copied' : 'Copy'),
        ])
    },
}

// The lines of one file between two revisions: the diff route's, or every
// line added when there is no old revision.
export async function fileDiff(project, from, to, path) {
    const base = `/api/projects/${project}`
    if (from) return api(href(`${base}/diff`, {from, to, path}))
    try {
        const r = await apiRaw(href(`${base}/file`, {rev: to, path}))
        if (!r.headers.get('content-type')?.startsWith('text/plain')) return {path, binary: true, after: {size: Number(r.headers.get('content-length'))}, before: null, lines: []}
        const after = {size: Number(r.headers.get('content-length'))}
        let text = await r.text()
        if (text.endsWith('\n')) text = text.slice(0, -1)
        const lines = text === '' ? [] : text.split('\n').map((t, i) => ({op: 'add', old: 0, new: i + 1, text: t}))
        return {path, binary: false, too_large: false, before: null, after, added: lines.length, removed: 0, lines}
    } catch (error) {
        if (error.status === 413) return {path, too_large: true, lines: []}
        throw error
    }
}

const CONTEXT = 3

// The rows of a unified diff: changed lines with CONTEXT lines around them,
// lines whose new number is in keep, and folds for the rest.
function rows(lines, keep, open) {
    const shown = new Uint8Array(lines.length)
    lines.forEach((l, i) => {
        if (l.op !== 'same') for (let k = Math.max(0, i - CONTEXT); k <= Math.min(lines.length - 1, i + CONTEXT); k++) shown[k] = 1
        if (keep.has(l.new)) shown[i] = 1
    })
    const out = []
    for (let i = 0; i < lines.length;) {
        if (shown[i] || open.has(i)) {
            out.push({line: i})
            i++
            continue
        }
        let j = i
        while (j < lines.length && !shown[j] && !open.has(j)) j++
        out.push({fold: i, count: j - i})
        i = j
    }
    return out
}

const MARK = {same: ' ', add: '+', remove: '-'}

// A unified diff. pick(newLine, event) makes new line numbers clickable;
// after(newLine) gives what goes under a line.
export const DiffView = {
    props: ['diff', 'pick', 'after', 'keep', 'selected'],
    setup(props) {
        const open = reactive(new Set())
        return () => {
            const d = props.diff
            if (d.binary) return h('p', {class: 'quiet'}, `Binary file: ${d.before ? size(d.before.size) : 'none'} → ${d.after ? size(d.after.size) : 'none'}`)
            if (d.too_large) return h('p', {class: 'quiet'}, 'The file is too large to show its lines here: fetch it with mirai kai.')
            if (d.lines.length === 0) return h('p', {class: 'quiet'}, 'No lines.')
            const keep = props.keep || new Set()
            const sel = props.selected
            const body = []
            for (const r of rows(d.lines, keep, open)) {
                if (r.fold !== undefined) {
                    body.push(h('tr', {class: 'fold'}, h('td', {colspan: 3}, h('button', {type: 'button', class: 'link', onClick: () => {
                        for (let k = r.fold; k < r.fold + r.count; k++) open.add(k)
                    }}, `⋯ ${r.count} unchanged line${r.count === 1 ? '' : 's'}`))))
                    continue
                }
                const l = d.lines[r.line]
                const picked = sel && l.new && l.new >= sel.line && l.new < sel.line + sel.lines
                const number = props.pick && l.new
                    ? h('td', {class: 'num pick', title: 'Comment on this line; shift-click for a range', onClick: e => props.pick(l.new, e)}, l.new)
                    : h('td', {class: 'num'}, l.new || '')
                body.push(h('tr', {class: [l.op, picked ? 'picked' : '']}, [
                    h('td', {class: 'num'}, l.old || ''), number,
                    h('td', {class: 'text'}, MARK[l.op] + l.text),
                ]))
                const extra = l.new && props.after?.(l.new)
                if (extra) body.push(h('tr', {class: 'extra'}, h('td', {colspan: 3}, extra)))
            }
            return h('div', {class: 'scroll'}, [
                d.truncated ? h('p', {class: 'quiet'}, 'Only the first lines are shown: the diff is longer than the node answers.') : null,
                h('table', {class: 'diff'}, h('tbody', body)),
            ])
        }
    },
}
