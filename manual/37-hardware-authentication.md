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

Enrolment is a short walk-through in a full-screen window. It draws a dot for where your head is pointing and a ring to put it in; it never shows or keeps a picture of you. Sit as you normally do and look at the centre (the dot's size tells you if you're too close or too far), turn your head all the way round once, follow the ring as it moves out to the edge and around, then hold the dot in it at the centre, left, right, up and down. Look at the camera to verify. After that it records how you move: nod twice, shake twice, glance right and left, look down at the keyboard, read some text placed around the screen, say a sentence facing the screen, and lean in. Those recordings are what make sure a glance or a nod along to music never counts as a yes.

Once it's set up, `sudo` and system authorization prompts open a small window naming what's asking. Nod twice to allow it, or type your password into the window. Shaking your head twice, or closing the window, is a no: a system prompt is cancelled outright, and `sudo` falls back to its usual password prompt in the terminal. The window waits for you. If the walk-away lock is on and you leave, the screen locks and the request picks up when your face unlocks it. With the lid closed the camera can't see you, so the window is skipped and you go straight to the password, the same as fingerprint. An `ssh` login never gets the camera, only the password prompt.

One thing to know about the window: nothing marks it as the real one. A program already running under your account could draw a look-alike and collect a password typed into it, so a password window you didn't just cause is worth the same as any other unexpected prompt. Type your password into it only for a request you just made, and prefer the nod, which a fake window can't use.

Your enrolment is a set of numbers derived from your face, never images, kept root-only and sealed to the TPM when the machine has one. _Setup > Security > Face_ holds the rest: _Add Look_ for another look later (glasses, a beard), _Tune Gestures_ to record your nod, shake and everyday movements again, _Walk-Away Lock_ to turn the presence lock off or set how long an empty chair waits before it locks, and _Status_ for `faceauth doctor`. `faceauth doctor` reports the state of every part.

The walk-away lock has two modes. In the default mode the screen locks after your face has been gone for the away time, whoever else is sitting there: someone else in your chair, or a photo propped in it, never keeps it open past that. In secure mode it locks as soon as you're not in front of the camera. A tray toggle to switch between them is coming.

You can remove face authentication under _Remove > Security > Face_ in the Omarchy menu.
