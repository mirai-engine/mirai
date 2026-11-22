// Signing in: with a passkey, as a new user whose first passkey this is, by
// linking a passkey to an existing user, or by a device's approval.
import {h, reactive} from './vue.js'
import {state} from './api.js'
import {link as linkPasskey, linkDevice, linkOffer, register, signIn, signInByDevice} from './passkey.js'
import {button, Copy, errorBox, navigate, useAction} from './ui.js'

export const SignIn = {
    props: ['params', 'query'],
    setup() {
        const form = reactive({name: '', user: '', made: null, linked: false, offer: null, device: false})
        const passkey = useAction(async () => {
            await signIn()
            navigate('/')
        })
        const create = useAction(async () => {
            if (!form.name.trim()) throw new Error('give your name: 1 to 64 bytes')
            form.made = await register(form.name.trim())
        })
        const attach = useAction(async () => {
            await linkPasskey(form.user.trim(), form.name.trim() || 'Kai user')
            form.linked = true
        })
        const device = useAction(async () => {
            await signInByDevice()
            navigate('/')
        })
        const offer = useAction(async () => {
            form.offer = await linkOffer()
        })
        const confirm = useAction(async () => {
            await linkDevice(form.offer)
            form.offer = null
            form.device = true
        })
        return () => {
            if (state.session) {
                return [
                    h('h1', 'Signed in'),
                    h('p', `You are ${state.session.name || state.session.user}.`),
                    state.session.passkey ? h('section', [
                        h('h2', 'Link a device'),
                        h('p', {class: 'quiet'}, 'Makes a machine a device of yours. A user made with a passkey has no recovery key until its first device sets one: run mirai kai identity recovery there.'),
                        form.device ? h('p', 'The device is yours now.') : form.offer ? [
                            h('p', `${form.offer.name} offers itself with the code ${form.offer.code}. Link it only if the machine shows the same.`),
                            h('div', {class: 'row'}, button('Link it', confirm)),
                            errorBox(confirm.error),
                        ] : [h('div', {class: 'row'}, button('Link a device', offer)), errorBox(offer.error)],
                    ]) : null,
                ]
            }
            if (form.made) {
                return [
                    h('h1', 'Your user is made'),
                    h('p', 'Your user id: give it to an admin of an org this node serves. It waits on this node until they add you; then sign in with your passkey and link a device of yours, which sets your recovery key.'),
                    h(Copy, {text: form.made.user}),
                    h('div', {class: 'row'}, button('Sign in', passkey)),
                    errorBox(passkey.error),
                ]
            }
            const work = state.node?.passkeys_work
            return [
                h('h1', 'Sign in'),
                work ? null : h('p', {class: 'quiet'}, 'Passkeys need the node over HTTPS on its domain; this address serves reads. A device of yours can still approve a sign-in.'),
                h('section', [
                    h('h2', 'With a passkey'),
                    h('div', {class: 'row'}, button('Sign in with a passkey', passkey, {disabled: !work})),
                    errorBox(passkey.error),
                ]),
                h('section', [
                    h('h2', 'New here'),
                    h('p', {class: 'quiet'}, 'Makes a user of this passkey alone: it signs your user\'s first entry, the node only keeps it.'),
                    h('form', {class: 'row', onSubmit: e => {
                        e.preventDefault()
                        create.run()
                    }}, [
                        h('input', {placeholder: 'Your name', 'aria-label': 'Your name', maxlength: 64, value: form.name, onInput: e => form.name = e.target.value, class: 'grow'}),
                        h('button', {type: 'submit', disabled: create.busy || !work}, 'Create a passkey'),
                    ]),
                    errorBox(create.error),
                ]),
                h('section', [
                    h('h2', 'Add a passkey to your user'),
                    h('p', {class: 'quiet'}, 'For a user you have on a device already: the device approves the new passkey. The device prints your user id with mirai kai identity.'),
                    form.linked ? h('p', 'The passkey is yours now: sign in with it above.') : h('form', {class: 'row', onSubmit: e => {
                        e.preventDefault()
                        attach.run()
                    }}, [
                        h('input', {placeholder: 'Your user id, 64 hex', 'aria-label': 'User id', value: form.user, onInput: e => form.user = e.target.value, class: 'grow'}),
                        h('button', {type: 'submit', disabled: attach.busy || !work}, 'Create and link'),
                    ]),
                    errorBox(attach.error),
                ]),
                h('section', [
                    h('h2', 'Without a passkey'),
                    h('p', {class: 'quiet'}, 'A device of yours approves this browser\'s sign-in; the writes of such a session are approved the same way.'),
                    h('div', {class: 'row'}, button('Approve from a device', device)),
                    errorBox(device.error),
                ]),
            ]
        }
    },
}

// The approval the page waits for, whatever asked it.
export function approvalPanel() {
    const a = state.approval
    if (!a) return null
    return h('aside', {class: 'approval', role: 'status'}, [
        h('p', h('strong', 'Waiting for a device of yours to approve.')),
        h('p', 'Run this on it:'),
        h(Copy, {text: a.command}),
        h('div', {class: 'row'}, [
            h('span', {class: 'quiet'}, a.state),
            h('button', {type: 'button', class: 'link', onClick: () => state.approval = null}, 'Dismiss'),
        ]),
    ])
}
