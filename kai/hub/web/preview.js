// The previews peers publish of an asset (kai/preview.odin): the summary of
// what it is and the detail of what a change did to it, decoded with the
// bounds the node checks them with. null for anything else.

const SUMMARY_HEAD = 'kai-summary 1'
const DETAIL_HEAD = 'kai-detail 1'
const LIMITS = {summary: 8 << 10, detail: 128 << 10, kind: 32, facts: 16, label: 48, value: 256, rows: 200, name: 64, text: 512}
const encoder = new TextEncoder()
const bytes = text => encoder.encode(text).length

// The lines of a record: UTF-8 text within max bytes, ending with a line feed,
// with no control character but the tab.
function lines(text, max) {
    if (typeof text !== 'string' || text === '' || bytes(text) > max || !text.endsWith('\n')) return null
    if (/[\u0000-\u0008\u000a-\u001f\u007f]/.test(text.replaceAll('\n', '')) || text.includes('�')) return null
    return text.slice(0, -1).split('\n')
}

// {kind, facts: [{label, value}]} of a summary.
export function summaryDecode(text) {
    const all = lines(text, LIMITS.summary)
    if (!all || all.length < 2 || all[0] !== SUMMARY_HEAD) return null
    const kind = all[1]
    if (kind === '' || bytes(kind) > LIMITS.kind || kind.includes('\t')) return null
    const facts = []
    for (const line of all.slice(2)) {
        const parts = line.split('\t')
        if (parts.length !== 2 || parts[0] === '' || bytes(parts[0]) > LIMITS.label || bytes(parts[1]) > LIMITS.value || facts.length >= LIMITS.facts) return null
        facts.push({label: parts[0], value: parts[1]})
    }
    return {kind, facts}
}

// {added, removed, changed, cut, rows: [{mark, name, text}]} of a detail.
export function detailDecode(text) {
    const all = lines(text, LIMITS.detail)
    if (!all || all.length < 2 || all[0] !== DETAIL_HEAD) return null
    const counts = all[1].split('\t')
    if (counts.length !== 4 || !counts.every(n => /^[0-9]{1,9}$/.test(n))) return null
    const [added, removed, changed, cut] = counts.map(Number)
    const rows = []
    for (const line of all.slice(2)) {
        const parts = line.split('\t')
        if (parts.length !== 3 || !['+', '-', '~'].includes(parts[0]) || bytes(parts[1]) > LIMITS.name || bytes(parts[2]) > LIMITS.text || rows.length >= LIMITS.rows) return null
        rows.push({mark: parts[0], name: parts[1], text: parts[2]})
    }
    return {added, removed, changed, cut, rows}
}
