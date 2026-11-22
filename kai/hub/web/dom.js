// What the views are written with: html`...` makes DOM from a template, mount
// draws a render function into an element, and state holds what the page
// shares. A value only ever becomes a text node, an attribute or a property,
// never markup, so what a repository holds cannot become part of the page.

// In a tag, a value fills one whole attribute:
//   name=${v}   the attribute, absent when v is null, undefined or false
//   ?name=${v}  a boolean attribute, present when v is truthy
//   .name=${v}  the property name of the element
//   @name=${f}  f listens to the event name; none when f is null
// Elsewhere a value is text, a node (another html`...`), or a list of them;
// null, undefined and false are nothing.
const ATTRIBUTE = /([.?@]?[\w-]+)=(["']?)$/

// The parsed template of each tagged literal, made the first time it runs.
const templates = new WeakMap()

// The template's markup with a marker in place of every value: a comment
// <!--hN--> where it is content, an attribute data-hN where it fills one.
function parse(strings) {
    let markup = ''
    let quote = ''
    const holes = []
    strings.forEach((part, i) => {
        if (quote) {
            if (!part.startsWith(quote)) throw new SyntaxError(`html: a value in a tag fills the whole attribute: ${part.slice(0, 40)}`)
            part = part.slice(1)
        }
        markup += part
        if (i === strings.length - 1) return
        if (markup.lastIndexOf('<') > markup.lastIndexOf('>')) {
            const found = ATTRIBUTE.exec(markup)
            if (!found) throw new SyntaxError(`html: a value in a tag goes in an attribute, as name=\${value}: ${markup.slice(-40)}`)
            const name = found[1]
            const kind = '.?@'.includes(name[0]) ? name[0] : ''
            holes.push({index: i, kind, name: kind ? name.slice(1) : name})
            markup = markup.slice(0, -found[0].length) + `data-h${i}`
            quote = found[2]
        } else {
            holes.push({index: i, kind: 'content'})
            markup += `<!--h${i}-->`
            quote = ''
        }
    })
    const template = document.createElement('template')
    template.innerHTML = markup
    return {template, holes}
}

export function html(strings, ...values) {
    let parsed = templates.get(strings)
    if (!parsed) templates.set(strings, parsed = parse(strings))
    const fragment = parsed.template.content.cloneNode(true)
    const markers = new Map()
    const walker = document.createTreeWalker(fragment, NodeFilter.SHOW_COMMENT)
    for (let n = walker.nextNode(); n; n = walker.nextNode()) markers.set(n.data, n)
    // Content first, so a property such as a select's .value finds its options.
    for (const hole of parsed.holes) {
        if (hole.kind !== 'content') continue
        const marker = markers.get(`h${hole.index}`)
        if (!marker) throw new SyntaxError('html: a value cannot be the text of a <textarea> or <title>: set .value instead')
        marker.replaceWith(...nodes(values[hole.index]))
    }
    for (const hole of parsed.holes) {
        if (hole.kind === 'content') continue
        const element = fragment.querySelector(`[data-h${hole.index}]`)
        element.removeAttribute(`data-h${hole.index}`)
        set(element, hole, values[hole.index])
    }
    trim(fragment)
    return fragment.childNodes.length === 1 ? fragment.firstChild : fragment
}

function set(element, {kind, name}, value) {
    if (kind === '@') {
        if (value === null || value === undefined) return
        if (typeof value !== 'function') throw new TypeError(`html: @${name} takes a function, not ${typeof value}`)
        element.addEventListener(name, value)
    } else if (kind === '.') {
        element[name] = value
    } else if (kind === '?') {
        element.toggleAttribute(name, Boolean(value))
    } else if (value !== null && value !== undefined && value !== false) {
        element.setAttribute(name, value === true ? '' : String(value))
    }
}

// The whitespace a template starts and ends with is not content.
function trim(fragment) {
    for (const edge of ['firstChild', 'lastChild']) {
        while (fragment[edge]?.nodeType === Node.TEXT_NODE && fragment[edge].data.trim() === '') fragment[edge].remove()
    }
}

// The nodes a value stands for.
export function nodes(value) {
    if (value === null || value === undefined || value === false) return []
    if (Array.isArray(value)) return value.flatMap(nodes)
    if (value instanceof Node) return [value]
    return [document.createTextNode(String(value))]
}

// Draws render() into element in place of what it holds, now and each time
// the function it answers is called. Nothing draws on its own.
export function mount(element, render) {
    const draw = () => element.replaceChildren(...nodes(render()))
    draw()
    return draw
}

// Values the whole page reads, as plain properties. set(changes) assigns them
// and then calls, in order, the functions watching each key it changed.
export function state(values) {
    const watchers = {}
    return Object.assign(values, {
        set(changes) {
            Object.assign(values, changes)
            for (const key of Object.keys(changes)) for (const watcher of watchers[key] ?? []) watcher()
        },
        watch(key, watcher) {
            (watchers[key] ??= []).push(watcher)
        },
    })
}
