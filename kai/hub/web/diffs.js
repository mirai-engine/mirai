// What the diff viewer computes from the lines the node gives, as data:
// which removed and added lines pair up, the words that differ between a
// pair, the rows of a split view, and the spans a highlighted line with
// marked words is drawn as. No DOM: the tests run it under node.

const WORDS_MAX = 400 // words of a line compared word by word; a longer pair is marked whole

// The words of a line: numbers, runs of letters and digits, runs of
// spaces, and every other character alone.
export function words(text) {
    return text.match(/\d+(?:\.\d+)+|[\p{L}\p{N}_]+|\s+|[^\p{L}\p{N}_\s]/gu) ?? []
}

// The character ranges [start, end) of before and after that a word diff
// marks changed; null when the lines have nothing in common worth showing.
export function wordDiff(before, after) {
    const a = words(before), b = words(after)
    if (a.length > WORDS_MAX || b.length > WORDS_MAX) return null
    const n = a.length, m = b.length
    // The length of the longest common subsequence of a[i:] and b[j:].
    const table = new Uint16Array((n + 1) * (m + 1))
    for (let i = n - 1; i >= 0; i--) {
        for (let j = m - 1; j >= 0; j--) {
            table[i * (m + 1) + j] = a[i] === b[j] ? table[(i + 1) * (m + 1) + j + 1] + 1
                : Math.max(table[(i + 1) * (m + 1) + j], table[i * (m + 1) + j + 1])
        }
    }
    const keepA = new Array(n).fill(false), keepB = new Array(m).fill(false)
    let common = 0
    for (let i = 0, j = 0; i < n && j < m;) {
        if (a[i] === b[j]) {
            keepA[i++] = keepB[j++] = true
            common += a[i - 1].trim() ? a[i - 1].length : 0
        } else if (table[(i + 1) * (m + 1) + j] >= table[i * (m + 1) + j + 1]) i++
        else j++
    }
    if (common === 0) return null
    return {before: ranges(a, keepA), after: ranges(b, keepB)}
}

function ranges(list, keep) {
    const out = []
    let at = 0
    list.forEach((w, i) => {
        if (!keep[i]) {
            const last = out[out.length - 1]
            if (last && last[1] === at) last[1] = at + w.length
            else out.push([at, at + w.length])
        }
        at += w.length
    })
    return out
}

// The removed and added lines that pair up: a run of removed lines followed
// by a run of added ones pairs them in order. A map from each paired line's
// index to its partner's.
export function pairs(lines) {
    const partner = new Map()
    for (let i = 0; i < lines.length;) {
        if (lines[i].op !== 'remove') {
            i++
            continue
        }
        let r = i
        while (r < lines.length && lines[r].op === 'remove') r++
        let a = r
        while (a < lines.length && lines[a].op === 'add') a++
        for (let k = 0; k < Math.min(r - i, a - r); k++) {
            partner.set(i + k, r + k)
            partner.set(r + k, i + k)
        }
        i = a
    }
    return partner
}

// The rows of a split view: [left index | -1, right index | -1] per row,
// an unchanged line on both sides, paired removed and added lines side by side.
export function splitRows(lines) {
    const rows = []
    for (let i = 0; i < lines.length;) {
        if (lines[i].op === 'same') {
            rows.push([i, i])
            i++
            continue
        }
        let r = i
        while (r < lines.length && lines[r].op === 'remove') r++
        let a = r
        while (a < lines.length && lines[a].op === 'add') a++
        if (a === i) {
            rows.push([-1, i])
            i++
            continue
        }
        for (let k = 0; k < Math.max(r - i, a - r); k++) rows.push([i + k < r ? i + k : -1, r + k < a ? r + k : -1])
        i = a
    }
    return rows
}

// The spans of a line: its tokens cut where marked ranges start and end,
// each {t, s, mark}.
export function segments(tokens, marks = []) {
    const out = []
    let at = 0, m = 0
    for (const token of tokens) {
        let start = 0
        const end = token.s.length
        while (start < end) {
            while (m < marks.length && marks[m][1] <= at + start) m++
            const mark = m < marks.length && marks[m][0] <= at + start
            const limit = m >= marks.length ? end : mark ? Math.min(end, marks[m][1] - at) : Math.min(end, marks[m][0] - at)
            const cut = Math.max(limit, start + 1)
            out.push({t: token.t, s: token.s.slice(start, cut), mark})
            start = cut
        }
        at += end
    }
    return out
}

// The added and removed lines of a diff.
export function counts(lines) {
    let added = 0, removed = 0
    for (const l of lines) {
        if (l.op === 'add') added++
        else if (l.op === 'remove') removed++
    }
    return {added, removed}
}
