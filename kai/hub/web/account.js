// Signing in: with a passkey, as a new user whose first passkey this is, by
// linking a passkey to an existing user, or by a device's approval.
import {html, mount} from './dom.js'
import {app} from './api.js'
import {link as linkPasskey, linkDevice, linkOffer, register, signIn, signInByDevice} from './passkey.js'
import {action, copyField, icon, navigate} from './ui.js'

export function SignIn() {
    // Where the person is: the user just made, a passkey just linked, a
    // device's offer to compare, a device just linked.
    let made = null, linked = false, offer = null, device = false
    const root = html`<div class="page narrow"></div>`

    const withPasskey = action(async () => {
        await signIn()
        navigate('/')
    })
    const byDevice = action(async () => {
        await signInByDevice()
        navigate('/')
    })
    const create = action(async event => {
        const name = event.target.elements.name.value.trim()
        if (!name) throw new Error('give your name: 1 to 64 bytes')
        made = await register(name)
        draw()
    })
    const attach = action(async event => {
        const name = root.querySelector('input[name=name]')?.value.trim()
        await linkPasskey(event.target.elements.user.value.trim(), name || 'Kai user')
        linked = true
        draw()
    })
    const askOffer = action(async () => {
        offer = await linkOffer()
        draw()
    })
    const confirm = action(async () => {
        await linkDevice(offer)
        offer = null
        device = true
        draw()
    })

    const draw = mount(root, () => app.session ? signedIn() : made ? madeView() : choices())

    function signedIn() {
        const s = app.session
        return html`<header class="page-head"><h1>Signed in</h1><p class="quiet">You are ${s.name || s.user}.</p></header>
        ${s.passkey ? html`<section class="panel">
            <h2>Link a device</h2>
            <p class="quiet">Makes a machine a device of yours. A user made with a passkey has no recovery key until its first device sets one: run mirai kai identity recovery there.</p>
            ${device ? html`<div class="notice ok">${icon('check')}<p>The device is yours now.</p></div>`
                : offer ? html`<div>
                    <p>${offer.name} offers itself with the code <code class="code-big">${offer.code}</code>. Link it only if the machine shows the same.</p>
                    <div class="actions"><button type="button" class="primary" @click=${confirm}>Link it</button></div>
                </div>`
                : html`<div class="actions"><button type="button" @click=${askOffer}>Link a device</button></div>`}
        </section>` : null}`
    }

    function madeView() {
        return html`<header class="page-head"><h1>Your user is made</h1></header>
        <section class="panel">
            <p>Your user id: give it to an admin of an org this node serves. It waits on this node until they add you; then sign in with your passkey and link a device of yours, which sets your recovery key.</p>
            ${copyField(made.user)}
            <div class="actions"><button type="button" class="primary" @click=${withPasskey}>Sign in</button></div>
        </section>`
    }

    function choices() {
        const work = app.node?.passkeys_work
        return html`<header class="page-head"><h1>Sign in</h1>
            ${work ? null : html`<div class="notice">${icon('lock')}<p>Passkeys need the node over HTTPS on its domain; this address serves reads. A device of yours can still approve a sign-in.</p></div>`}
        </header>
        <section class="panel">
            <h2>With a passkey</h2>
            <div class="actions"><button type="button" class="primary" ?disabled=${!work} @click=${withPasskey}>Sign in with a passkey</button></div>
        </section>
        <section class="panel">
            <h2>New here</h2>
            <p class="quiet">Makes a user of this passkey alone: it signs your user's first entry, the node only keeps it.</p>
            <form class="inline-form" @submit=${create}>
                <input name="name" class="grow" placeholder="Your name" aria-label="Your name" maxlength="64" autocomplete="name">
                <button type="submit" ?disabled=${!work}>Create a passkey</button>
            </form>
        </section>
        <section class="panel">
            <h2>Add a passkey to your user</h2>
            <p class="quiet">For a user you have on a device already: the device approves the new passkey. The device prints your user id with mirai kai identity.</p>
            ${linked ? html`<div class="notice ok">${icon('check')}<p>The passkey is yours now: sign in with it above.</p></div>` : html`<form class="inline-form" @submit=${attach}>
                <input name="user" class="grow" placeholder="Your user id, 64 hex" aria-label="User id" autocomplete="off" spellcheck="false">
                <button type="submit" ?disabled=${!work}>Create and link</button>
            </form>`}
        </section>
        <section class="panel">
            <h2>Without a passkey</h2>
            <p class="quiet">A device of yours approves this browser's sign-in; the writes of such a session are approved the same way.</p>
            <div class="actions"><button type="button" @click=${byDevice}>Approve from a device</button></div>
        </section>`
    }

    return root
}

// The approval the page waits for, whatever asked it.
export function approvalPanel() {
    const a = app.approval
    if (!a) return null
    return html`<aside class="approval" role="status">
        <div class="approval-head"><span class="spinner" aria-hidden="true"></span><strong>Waiting for a device of yours to approve</strong>
            <span class="badge">${a.state}</span></div>
        <p class="quiet">Run this on it:</p>
        ${copyField(a.command)}
        <div class="actions"><button type="button" class="ghost" @click=${() => app.set({approval: null})}>Dismiss</button></div>
    </aside>`
}
