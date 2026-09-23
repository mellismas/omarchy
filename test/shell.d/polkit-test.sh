#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
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
assert(
  polkit.faceConsentConfiguredFromPamConfig(`
auth sufficient pam_faceauth.so socket=/run/faceauth/sock timeout=60 consent
auth include system-auth
`),
  "pam_faceauth with consent means the face window owns the request"
)
assert(
  !polkit.faceConsentConfiguredFromPamConfig(`
auth sufficient pam_faceauth.so socket=/run/faceauth/sock timeout=8 prompt
auth include system-auth
`),
  "pam_faceauth without consent leaves the agent dialog as it was"
)
assert(
  !polkit.fingerprintConfiguredFromPamConfig(`
account include system-auth
auth include system-auth
auth required pam_unix.so
`),
  'polkit reports no fingerprint when pam_fprintd is absent'
)

// A face refusal reaches the agent as a PAM failure; polkit would then ask
// again forever. The agent must cancel the request instead, and only when
// no password was submitted from its own dialog.
const fs = require('fs')
const agent = fs.readFileSync(path.join(process.env.ROOT, 'shell/plugins/polkit/PolkitAgent.qml'), 'utf8')
const failed = agent.match(/function onAuthenticationFailed\(\) \{([\s\S]*?)\n    \}/)
assert(failed, 'the agent handles authenticationFailed')
assert(/if \(root\.faceConfigured && !root\.submitted\)/.test(failed[1]), 'a failure in face mode with nothing submitted is the face refusal')
assert(/Qt\.callLater\(root\.cancelRequest\)/.test(failed[1]), 'the agent cancels the request, deferred past the flow restart')
assert(/root\.refusing = true/.test(failed[1]), 'the agent marks the refusal before the cancel lands')
assert(/dialogVisible: \(agentActive \|\| closing\) && !faceMode && !refusing/.test(agent), 'the dialog stays hidden while a face refusal is being cancelled')
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
JS
