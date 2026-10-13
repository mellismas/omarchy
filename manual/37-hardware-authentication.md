# Hardware authentication

### Fingerprint authentication

A lot of laptops come with a fingerprint sensor to do authentication. You can use this with Omarchy by running _Setup > Security > Fingerprint_ in the Omarchy menu (`Super + Space`).

That'll install the fingerprint package, collect your print, verify it, and you'll be set to go using your fingerprint to unlock from the lock screen (which you can trigger with `Super + Ctrl + L`), enter sudo mode, and authorize system prompts.

Once the lock screen has turned the display off, the sensor rests to save power, so wake the screen with any key or the touchpad before touching it.

When your laptop lid is closed, the fingerprint prompt is automatically skipped, so you go straight to the password prompt instead of waiting on a sensor you can't reach. If you otherwise need to work on an external keyboard that doesn't have a sensor, just hit `CTRL + C`, when you're prompted for your fingerprint during `sudo`.

You can remove the fingerprint authentication under _Remove > Security > Fingerprint_ in the Omarchy menu.

### Fido2 authentication

If you're using a Fido2 device, you can set it up for `sudo` authentication using _Setup > Security > Fido2_ in the Omarchy menu (`Super + Space`). It covers `sudo` and system authorization prompts. With face authentication set up too (below), touching the key also unlocks the lock screen (`Super + Ctrl + L`) alongside your password, through the face service; without it, the lock screen keeps to your password. A key set up to ask for its PIN isn't offered on the lock screen, which has no field for it.

You can remove the fido2 authentication under _Remove > Security > Fido2_ in the Omarchy menu.

### Face authentication

Face authentication needs an Intel IPU3 laptop with an ov7251 infrared sensor, on a kernel with the ov7251 strobe patch, which the stock Omarchy kernel doesn't carry yet. Without that strobe control the camera can't enroll, and USB (UVC) IR modules aren't supported.

Run _Setup > Security > Face > Enroll_ in the Omarchy menu (`Super + Space`). Setup checks the camera and its illuminator before downloading the 260 MB face models, and stops if either fails. Enroll with nobody else in view, since it takes one face at a time. Nothing is saved until it finishes, and then only numbers derived from your face, never images.

The lock screen (`Super + Ctrl + L`) then opens when you look at the camera. `sudo` and system authorization prompts open a window naming what's asking: nod twice to allow it, or shake your head to refuse, which sends `sudo` on to its other prompts (a touch of your Fido2 key, with its PIN if it asks for one, then the password) and cancels a system prompt. With a Fido2 key set up, the window says so, and touching the key allows it too: whichever you do first wins. If your key asks for a PIN, the window gives you a field for it. A fingerprint set up alongside is asked before the window. With face set up, every use of the Fido2 key goes through the face service. If the service isn't running, `sudo` and system prompts take the key the way they do without face, locked screen included, PIN prompts and all (only the six-second touch window below differs), and the lock screen says "Face and key are unavailable because faceauth isn't running. Use your password." While the service is restarting after a crash, they give the password prompt instead. Removing face authentication puts the key back on its own. Setup also makes the infrared camera's capture node usable by the face service alone when it can tell that node carries only infrared, so other apps can no longer open the IR camera; removing face authentication gives it back, and `sudo faceauth doctor` says when setup left it open and why. A `sudo` on a text console with no desktop running takes the key at once; one on a text console or over SSH while your desktop is locked goes straight to the password. If your Fido2 line in `/etc/pam.d/sudo` or `/etc/pam.d/polkit-1` has options the face service can't carry over, face setup stops before changing anything and says which line; edit it, or remove Fido2 and set it up again. While faceauth is running and the screen is locked, a touch of the key can only unlock it, never answer a window waiting behind the lock or a `sudo` waiting in a terminal. The window comes back shortly after the unlock and asks again, and a `sudo` that reached its key prompt while the screen was locked says "The screen is locked. Your security key will be offered after you unlock it." and waits for the unlock, plus half a second. When you're asked to touch the key, you have six seconds; after that the password prompt comes. If two accounts on this computer share one key, a touch while either account's lock screen is asking for it only unlocks that lock screen, and neither account's window or `sudo` takes the key until half a second after that account unlocks. If faceauth can't tell whether the screen is locked, or stops responding, you get the password prompt within about 15 seconds. A Fido2 key registered so that it approves without a touch, or set up with `userpresence=0`, isn't offered on the window, the lock screen or `sudo` while face is set up. For `sudo` the window can also turn on [passwordless sudo](48-security.md#passwordless-sudo) for up to 24 hours, and says so before you nod.

Your password always works, and every face failure falls back to it. A `sudo` typed over SSH never reaches the camera and asks for your password. Any program in your desktop session, even one started from an SSH login, can raise the window or imitate it, so approve only a request you just made. Face matching hasn't been measured against look-alikes, and a close relative may pass.

_Setup > Security > Face_ also holds _Add Look_ (`omarchy setup security face --add`) for glasses or different light, _Tune Gestures_, _Walk-Away Lock_, and _Status_.

Once you pick _Walk-Away Lock > Enable_, the screen locks when nobody has been in front of it for the away time. In default mode anyone looking at the screen keeps it open; in secure mode only your face does, and the first look at anyone else locks. Under _Walk-Away Lock_, _Away Time_ sets each mode's away time and _Obscured Face_ how long a covered or turned-away face keeps it open. Switch modes from its icon in the [top bar](05-the-top-bar.md) or with `Super + Ctrl + Shift + L`; the switch lasts until the face service restarts.

You can remove face authentication under _Remove > Security > Face_ in the Omarchy menu.
