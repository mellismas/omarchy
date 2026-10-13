#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const polkit = requireFromRoot('shell/plugins/polkit/PolkitModel.js')

assert(polkit.promptLooksFingerprint('Swipe your finger'), 'polkit detects fingerprint prompts')
assert(polkit.promptLooksFingerprint('fprintd verification'), 'polkit detects fprint prompts')
assert(!polkit.promptLooksFingerprint('Password:'), 'polkit ignores password prompts')

assertEqual(
  polkit.authorizationLabel("Authentication is needed to run `/usr/bin/true' as the super user"),
  "Authorize running '/usr/bin/true'",
  'polkit shortens the standard pkexec message'
)
assertEqual(
  polkit.authorizationLabel('Authentication is required to change system settings'),
  'Authentication is required to change system settings',
  'polkit preserves custom authorization messages'
)

assert(
  polkit.fingerprintConfiguredFromPamConfig(`
# comment
auth sufficient pam_fprintd.so
auth include system-auth
`),
  'polkit detects fingerprint in a PAM config'
)
assert(
  polkit.fingerprintConfiguredFromPamConfig(`
auth [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed
auth sufficient pam_fprintd.so
auth required pam_unix.so
`),
  'polkit detects fingerprint even behind a clamshell gate'
)
// The polkit line is read out of the setup script, so the agent is tested on
// what setup writes: the whole polkit-1 it creates when none exists, and the
// line alone, which it inserts into an existing one.
const setupScript = fs.readFileSync(path.join(process.env.ROOT, 'bin/omarchy-setup-security-face'), 'utf8')
const polkitLine = (setupScript.match(/^polkit_face_line='(.*)'$/m) || [])[1]
assert(polkitLine, 'setup names its polkit line')
const createdStack = (setupScript.match(/^polkit_stack="([\s\S]*?)"$/m) || [])[1]
assert(/pam_stack_write \/etc\/pam\.d\/polkit-1 "\$polkit_stack"/.test(setupScript), 'setup writes that stack as polkit-1 when none exists')
assert(createdStack && createdStack.includes('$polkit_face_line'), 'setup writes a whole polkit-1 around its line when none exists')
assert(
  polkit.faceConsentConfiguredFromPamConfig(createdStack.replace('$polkit_face_line', polkitLine)),
  "the polkit-1 setup creates puts the face window in charge of the request"
)
assert(
  polkit.faceConsentConfiguredFromPamConfig(`${polkitLine}\nauth include system-auth\n`),
  "the line setup inserts into an existing polkit-1 puts the face window in charge of the request"
)
assert(
  !polkit.faceConsentConfiguredFromPamConfig(`${polkitLine.replace(/ consent$/, '')}\nauth include system-auth\n`),
  "the same line without consent leaves the agent dialog as it was"
)
assert(
  !polkit.fingerprintConfiguredFromPamConfig(`
account include system-auth
auth include system-auth
auth required pam_unix.so
`),
  'polkit reports no fingerprint when pam_fprintd is absent'
)

const agent = fs.readFileSync(path.join(process.env.ROOT, 'shell/plugins/polkit/PolkitAgent.qml'), 'utf8')
// The retry makes the new agent on a later turn: made in the same handler, it
// would find the old one still holding Quickshell's one agent slot and never
// register, so only every other retry would count.
const retry = agent.match(/id: registerRetry[\s\S]*?onTriggered: \{([\s\S]*?)\n    \}/)
assert(retry, 'the agent retries its registration')
assert(/agentLoader\.active = false/.test(retry[1]), 'the retry drops the old agent')
assert(!/agentLoader\.active = true/.test(retry[1]), 'the retry does not make the new agent in the same handler')
assert(/Qt\.callLater\(root\.reloadAgent\)/.test(retry[1]), 'the retry makes the new agent on the next turn')
const reload = agent.match(/function reloadAgent\(\) \{([\s\S]*?)\n  \}/)
assert(reload && /^\s*agentLoader\.active = true\s*$/.test(reload[1]), 'reloadAgent makes the new agent and does nothing else')
// A face refusal reaches the agent as a PAM failure; polkit would then ask
// again forever. The agent must cancel the request instead, and only when
// no password was submitted from its own dialog.
const failed =agent.match(/function onAuthenticationFailed\(\) \{([\s\S]*?)\n    \}/)
assert(failed, 'the agent handles authenticationFailed')
assert(/if \(root\.faceConfigured && !root\.submitted\)/.test(failed[1]), 'a failure in face mode with nothing submitted is the face refusal')
assert(/Qt\.callLater\(root\.cancelRequest\)/.test(failed[1]), 'the agent cancels the request, deferred past the flow restart')
assert(/root\.refusing = true/.test(failed[1]), 'the agent marks the refusal before the cancel lands')
assert(/dialogVisible: \(agentActive \|\| closing\) && !faceMode && !refusing/.test(agent), 'the dialog stays hidden while a face refusal is being canceled')
assert(failed[1].indexOf('return') !== -1 && failed[1].indexOf('return') < failed[1].indexOf('root.triggerFailureFeedback()'), 'no failure feedback is shown for a face refusal')
// The daemon labels a request with a context only when it came over a
// connection from the very process systemd says connected polkit's helper:
// the agent itself. A child process (the faceauth CLI) would be a different
// peer, and a description planted by any other process of the user's would
// match just as well.
const tell = agent.match(/function tellFaceauth\(\) \{([\s\S]*?)\n  \}/)
assert(tell, 'the agent tells faceauth about the request')
assert(/contextSocket\.connected = true/.test(tell[1]), 'the context goes over the agent\'s own socket connection')
assert(!/consent-context/.test(tell[1]) && !/contextProc/.test(agent), 'the context is not sent through a child process')
assert(/Socket \{\s*id: contextSocket\s*path: "\/run\/faceauth\/sock"/.test(agent), 'the socket is the daemon\'s')
assert(/context_action: String\(flow\.actionId/.test(tell[1]) && /context_message: String\(flow\.message/.test(tell[1]), 'the context carries the action and the message')
assert(/details\["polkit\.caller-pid"\]/.test(tell[1]) && /details\["polkit\.subject-pid"\]/.test(tell[1]), 'the context carries polkitd\'s caller and subject pids when the flow exposes its details')
assert(/var details = flow\.details \|\| \{\}/.test(tell[1]), 'a Quickshell without request details still sends the context')
assert(/if \(flow\.details === undefined && !root\.detailsWarned\) \{\s*root\.detailsWarned = true\s*console\.warn\(/.test(tell[1]), 'a Quickshell without request details is warned about once per shell')
JS
