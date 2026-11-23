// Accounts: signing in with a passkey or from a computer, creating an
// account, the three steps of setting up (passkey, computer, organization)
// and the account page with its user ID and devices.
import {el, html, mount} from './dom.js'
import {app} from './api.js'
import {link as linkPasskey, linkDevice, linkOffer, makeOrg, recoveryWait, register, signIn, signInByDevice} from './passkey.js'
import {action, avatar, badge, brandMark, confirmDialog, copyField, icon, navigate, plural, setPage, short, size, toast} from './ui.js'

// The machine being linked, across draws of the page: its offer to compare,
// whether it was linked and whether it set the recovery key yet.
const linking = {offer: null, linked: false, recovering: false, waiting: false}

const startLink = action(async () => {
    Object.assign(linking, {offer: null, linked: false, waiting: true})
    app.set({approval: app.approval})
    try {
        linking.offer = await linkOffer()
    } finally {
        linking.waiting = false
        app.set({approval: app.approval})
    }
})

const confirmLink = action(async () => {
    const offer = linking.offer
    await linkDevice(offer)
    Object.assign(linking, {offer: null, linked: true, recovering: !app.session.recovered})
    app.set({approval: app.approval})
    toast(`${offer.name} is linked to your account`)
    if (!linking.recovering) return
    try {
        await recoveryWait(offer)
    } finally {
        linking.recovering = false
        app.set({approval: app.approval})
    }
})

const rejectLink = () => {
    linking.offer = null
    toast('The computer was not linked', 'info')
    app.set({approval: null})
}

const createOrg = action(async event => {
    const name = event.target.elements.name.value.trim()
    if (!name) throw new Error("give your organization a name: 1 to 64 characters")
    const ok = await confirmDialog({
        title: `Create ${name}`,
        text: 'Your passkey signs two things, one prompt each:',
        steps: ['the new organization, with you as its owner', 'that this server keeps it for your team'],
        confirm: 'Continue',
    })
    if (!ok) return
    const org = await makeOrg(name)
    toast(`${name} is ready: add its first project`)
    navigate(`/org/${org}`)
})

// The steps of setting up an account: each done, current or to come.
function steps(s) {
    const linked = s.recovered || (s.devices ?? []).some(d => !d.revoked)
    const hosts = s.hosting.max > 0
    const org = s.orgs.length > 0
    const project = org && (app.projects ?? []).some(p => s.orgs.some(o => o.org === p.org))
    return [
        {key: 'passkey', title: s.passkey ? 'Passkey created' : 'Signed in from your computer', done: true},
        {key: 'computer', title: 'Link your computer', done: linked},
        {key: 'org', title: hosts ? 'Create your organization and first project' : 'Join an organization', done: org && (project || !hosts)},
    ]
}

// Whether every step of setting up is done.
export function setUp(s) {
    return steps(s).every(x => x.done)
}

// The setting-up card: compact on Home with a link to finish, whole on the
// account page where each step is done.
export function onboarding(s, whole = false) {
    if (!s || setUp(s)) return null
    const list = steps(s)
    const current = list.findIndex(x => !x.done)
    return html`<section class="onboarding">
        <header><div>${icon('rocket')}<div><h2>Get set up</h2><p class="quiet">${plural(list.filter(x => x.done).length, 'step')} of 3 done</p></div></div>
            ${whole ? null : html`<a class="button primary" href="/account">Continue setup${icon('arrow-right')}</a>`}</header>
        <ol class="steps">${list.map((x, i) => html`<li class=${x.done ? 'done' : i === current ? 'current' : 'todo'}>
            <span class="step-mark tabular">${x.done ? icon('check') : String(i + 1)}</span>
            <div class="step-body"><strong>${x.title}</strong>${whole && i === current ? stepBody(s, x.key) : null}</div>
        </li>`)}</ol>
    </section>`
}

function stepBody(s, key) {
    if (key === 'computer') return linkFlow(s)
    if (key === 'org') return orgStep(s)
    return null
}

// Linking a computer: the command to run there, then the code both show.
function linkFlow(s) {
    if (!s.passkey) return html`<p class="quiet">Add a passkey to this browser first (below): linking a computer is signed with it.</p>`
    if (linking.recovering) return html`<div class="notice">${icon('shield')}<p>Linked. Your computer now sets your recovery key and shows it once: write it down and keep it somewhere safe, offline.</p></div>`
    if (linking.offer) return html`<div class="link-compare">
        <p>A computer called <strong>${linking.offer.name}</strong> asks to be linked. Check that it shows exactly this code:</p>
        <div class="code-compare tabular" aria-label="Verification code">${linking.offer.code.split('').map(c => c === '-' ? el('span', 'code-sep', '–') : el('span', 'code-digit', c))}</div>
        <div class="actions"><button type="button" class="primary" @click=${confirmLink}>${icon('check')}The codes match: link it</button>
            <button type="button" class="ghost" @click=${rejectLink}>They differ</button></div>
    </div>`
    const a = app.approval
    if (linking.waiting && a?.kind === 'device') return html`<div class="link-wait">
        <p>On your computer, open a terminal in any folder and run:</p>
        ${copyField(a.command, {label: 'Command to run on your computer'})}
        <p class="waiting-line"><span class="spinner" aria-hidden="true"></span>Waiting for your computer…</p>
    </div>`
    return html`<div class="link-start">
        <p class="quiet">Your computer becomes a device of your account: it works on your projects, approves sign-ins and keeps your recovery key. You need Mirai installed there.</p>
        <button type="button" class="primary" @click=${startLink}>${icon('laptop')}Link a computer</button>
    </div>`
}

function orgStep(s) {
    if (s.hosting.max === 0) return html`<div><p class="quiet">This server makes no organizations from the web. Ask an admin of your team's organization to add you with your user ID:</p>${copyField(s.user, {label: 'Your user ID'})}</div>`
    if (s.orgs.length) {
        const o = s.orgs[0]
        return html`<p class="quiet">${o.name} is ready. <a href=${`/org/${o.org}`}>Add its first project</a>.</p>`
    }
    if (!s.recovered) return html`<p class="quiet">Link your computer first: an organization needs its owner to have a recovery key, which the computer sets.</p>`
    if (s.hosting.made >= s.hosting.max) return html`<p class="quiet">You made as many organizations here as this server keeps for one person. For more, run a server of your own with mirai kai serve.</p>`
    return html`<form class="inline-form" @submit=${createOrg}>
        <input name="name" class="grow" placeholder="Your organization's name" aria-label="Organization name" maxlength="64" autocomplete="organization">
        <button type="submit" class="primary">${icon('building')}Create organization</button>
    </form>
    <p class="quiet small-text">This server keeps up to ${size(app.node.hosting.quota)} for it. You can also join an existing one: share your user ID with its admin.</p>`
}

export function Account() {
    const root = html`<div class="page narrow"></div>`
    const draw = mount(root, () => {
        const s = app.session
        root.className = s ? 'page narrow' : 'auth-wrap'
        return s ? signedIn(s) : authView('signin')
    })
    const stops = ['session', 'approval', 'projects'].map(key => app.watch(key, () => root.isConnected ? draw() : stops.forEach(stop => stop())))
    return root
}

export function SignUp() {
    const root = html`<div class="auth-wrap"></div>`
    const draw = mount(root, () => {
        const s = app.session
        root.className = s ? 'page narrow' : 'auth-wrap'
        return s ? signedIn(s) : authView('signup')
    })
    const stops = ['session', 'approval', 'projects'].map(key => app.watch(key, () => root.isConnected ? draw() : stops.forEach(stop => stop())))
    return root
}

// --- Signed out ---

const withPasskey = action(async () => {
    await signIn()
    toast(`Welcome back${app.session?.name ? `, ${app.session.name}` : ''}`)
    navigate('/')
})

const byDevice = action(async () => {
    await signInByDevice()
    toast('Signed in from your computer')
    navigate('/')
})

const create = action(async event => {
    const name = event.target.elements.name.value.trim()
    if (!name) throw new Error('give your name: 1 to 64 characters')
    await register(name)
    toast('Your account is ready')
    navigate('/account', true)
})

export function authView(mode = 'signin') {
    const signup = mode === 'signup'
    setPage({title: signup ? 'Create account' : 'Sign in', crumbs: [{label: signup ? 'Create account' : 'Sign in'}]})
    const work = app.node?.passkeys_work
    const hasPublic = (app.projects ?? []).length > 0
    return html`<div class="auth-screen">
        <header class="auth-head">
            ${brandMark(true)}
            <h1>${signup ? 'Create your account' : 'Sign in to KaiHub'}</h1>
            <p class="quiet">${signup
                ? "Your device's passkey secures your account — no password needed."
                : 'No password: sign in with your passkey or from a linked computer.'}</p>
        </header>
        ${work ? null : html`<div class="notice">${icon('lock')}<p>Passkeys work only when this server is opened over HTTPS on its domain. From this address, sign in from your computer instead.</p></div>`}
        ${signup ? html`<section class="auth-card">
            <form class="auth-form" @submit=${create}>
                <label class="field-label" for="signup-name">Your name</label>
                <input id="signup-name" name="name" placeholder="e.g. Tomas" aria-label="Your name" maxlength="64" autocomplete="name" ?disabled=${!work}>
                <button type="submit" class="primary wide lg" ?disabled=${!work}>${icon('key')}Create account</button>
            </form>
            <p class="quiet small-text auth-hint">Your browser asks twice: once to create the passkey, once to confirm it.</p>
        </section>
        <p class="auth-footer">Already have an account? <a href="/signin">Sign in</a></p>`
        : html`<section class="auth-card">
            <button type="button" class="primary wide lg" ?disabled=${!work} @click=${withPasskey}>${icon('key')}Sign in with a passkey</button>
            <div class="auth-divider"><span>or</span></div>
            <div class="auth-alt">
                <button type="button" class="wide lg" @click=${byDevice}>${icon('laptop')}Approve from my computer</button>
                <p class="quiet small-text auth-hint">Use a computer already linked to your account.</p>
            </div>
        </section>
        <p class="auth-footer">New to KaiHub? <a href="/signup">Create an account</a></p>`}
        ${hasPublic && location.pathname !== '/' ? html`<p class="auth-browse"><a href="/">Browse public projects${icon('arrow-right')}</a></p>` : null}
    </div>`
}

// --- Signed in ---

const addPasskey = action(async () => {
    await linkPasskey(app.session.user, app.session.name || 'Kai user')
    toast('This browser now signs in with its own passkey')
})

function signedIn(s) {
    setPage({title: 'Account', crumbs: [{label: 'Account'}]})
    const devices = (s.devices ?? []).filter(d => !d.revoked)
    return html`<header class="profile">
        ${avatar(s.name || '?', s.user, true)}
        <div><h1>${s.name || 'Your account'}</h1>
            <p class="quiet">${s.passkey ? 'Signed in with a passkey' : 'Signed in from your computer'} · ${plural(s.orgs.length, 'organization')}</p></div>
    </header>
    <section class="card-panel">
        <h2>${icon('users')}Your user ID</h2>
        <p class="quiet">Share it with an admin who adds you to their organization.</p>
        ${copyField(s.user, {label: 'Your user ID'})}
    </section>
    ${onboarding(s, true)}
    <section class="card-panel">
        <div class="panel-head"><h2>${icon('laptop')}Your computers</h2>
            ${s.passkey && setUp(s) && !linking.waiting && !linking.offer ? html`<button type="button" class="small" @click=${startLink}>${icon('plus')}Link another</button>` : null}</div>
        ${devices.length === 0 ? html`<p class="quiet">No computer is linked yet.</p>` : html`<ul class="device-list">${devices.map(d => html`<li>
            ${icon('laptop')}<div><strong>${d.name && d.name !== short(d.key) ? d.name : 'Computer'}</strong><code class="hash" title=${d.key}>${short(d.key)}</code></div></li>`)}</ul>`}
        ${setUp(s) && (linking.waiting || linking.offer || linking.recovering) ? linkFlow(s) : null}
        ${linking.linked && !linking.recovering && !linking.offer ? html`<div class="notice ok">${icon('check-circle')}<p>Linked${s.recovered ? ', and your account has its recovery key' : ''}.</p></div>` : null}
    </section>
    ${s.passkey ? null : html`<section class="card-panel">
        <h2>${icon('key')}Add a passkey to this browser</h2>
        <p class="quiet">Your computer approved this session. With a passkey, this browser signs in and signs your reviews by itself; your computer approves it once.</p>
        <button type="button" class="primary" ?disabled=${!app.node?.passkeys_work} @click=${addPasskey}>Add a passkey</button>
    </section>`}
    ${s.orgs.length ? html`<section class="card-panel">
        <h2>${icon('building')}Organizations</h2>
        <ul class="org-list">${s.orgs.map(o => html`<li><a href=${`/org/${o.org}`}>${avatar(o.name || '?', o.org)}<strong>${o.name || 'Organization'}</strong></a>${badge(o.role, 'neutral')}</li>`)}</ul>
        ${s.hosting.max > s.hosting.made && s.recovered && setUp(s) ? html`<details class="more"><summary>${icon('plus')}Create another organization</summary>${orgForm()}</details>` : null}
    </section>` : null}`
}

function orgForm() {
    return html`<form class="inline-form" @submit=${createOrg}>
        <input name="name" class="grow" placeholder="Organization name" aria-label="Organization name" maxlength="64" autocomplete="organization">
        <button type="submit" class="primary">Create</button>
    </form>`
}

// The approval the page waits for from a computer: a sign-in or a write,
// with the command to run there. Linking a computer shows its own on the account page.
export function approvalPanel() {
    const a = app.approval
    if (!a || a.kind === 'device') return null
    return html`<aside class="approval" role="status">
        <div class="approval-head"><span class="spinner" aria-hidden="true"></span><strong>Approve on your computer</strong>${badge(a.state, 'neutral')}</div>
        <p class="quiet">Run this in a terminal on a computer linked to your account:</p>
        ${copyField(a.command, {label: 'Command to run on your computer'})}
        <div class="actions"><button type="button" class="ghost small" @click=${() => app.set({approval: null})}>Cancel</button></div>
    </aside>`
}
