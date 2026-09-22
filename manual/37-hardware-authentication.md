# Hardware authentication

### Fingerprint authentication

A lot of laptops come with a fingerprint sensor to do authentication. You can use this with Omarchy by running _Setup > Security > Fingerprint_ in the Omarchy menu (`Super + Space`).

That'll install the fingerprint package, collect your print, verify it, and you'll be set to go using your fingerprint to unlock from the lock screen (which you can trigger with `Super + Ctrl + L`), enter sudo mode, and authorize system prompts.

When your laptop lid is closed, the fingerprint prompt is automatically skipped, so you go straight to the password prompt instead of waiting on a sensor you can't reach. If you otherwise need to work on an external keyboard that doesn't have a sensor, just hit `CTRL + C`, when you're prompted for your fingerprint during `sudo`.

You can remove the fingerprint authentication under _Remove > Security > Fingerprint_ in the Omarchy menu.

### Fido2 authentication

If you're using a Fido2 device, you can set it up for `sudo` authentication using _Setup > Security > Fido2_ in the Omarchy menu (`Super + Space`). It covers `sudo` and system authorization prompts, though, not unlocking your computer.

You can remove the fido2 authentication under _Remove > Security > Fido2_ in the Omarchy menu.

### Face authentication

If your laptop has an infrared camera, the kind Windows Hello uses, you can unlock the lock screen by looking at it. Run _Setup > Security > Face_ in the Omarchy menu (`Super + Space`); the entry only appears when an IR camera is detected. That'll install the face authentication package, fetch its recognition models, enrol your face, verify it, and you'll be set to go: lock the screen (`Super + Ctrl + L`), look at the camera, and it opens.

A colour webcam won't do, on purpose: it can't see in the dark and a photo fools it. The IR camera never even sees a phone as a face, and a paper print is refused by how differently paper and skin reflect the camera's own light. What it can't tell apart is a look-alike or a 3D mask, so keep a strong password behind it; every failure, from a covered camera to a stopped service, falls back to the password.

Once it's set up, `sudo` and system authorization prompts open a small window naming what's asking. Nod twice to allow it, shake your head twice to refuse, or type your password into the window; it waits for you, and if you walk away the screen locks and the request picks up when your face unlocks it. Setup records two nods and two shakes so both gestures are read against the way you move; `sudo faceauth calibrate` records them again any time. With the lid closed the camera can't see you, so the window is skipped and you go straight to the password, the same as fingerprint. An `ssh` login never gets the camera, only the password prompt.

Your enrolment is a set of numbers derived from your face, never images, kept root-only and sealed to the TPM when the machine has one. To enrol another look later, glasses or a beard, use _Setup > Security > Face: Add Look_. `faceauth doctor` reports the state of every part.

You can remove face authentication under _Remove > Security > Face_ in the Omarchy menu.
