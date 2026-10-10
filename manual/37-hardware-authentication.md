# Hardware authentication

### Fingerprint authentication

A lot of laptops come with a fingerprint sensor to do authentication. You can use this with Omarchy by running _Setup > Security > Fingerprint_ in the Omarchy menu (`Super + Space`).

That'll install the fingerprint package, collect your print, verify it, and you'll be set to go using your fingerprint to unlock from the lock screen (which you can trigger with `Super + Ctrl + L`), enter sudo mode, and authorize system prompts.

Once the lock screen has turned the display off, the sensor rests to save power, so wake the screen with any key or the touchpad before touching it.

When your laptop lid is closed, the fingerprint prompt is automatically skipped, so you go straight to the password prompt instead of waiting on a sensor you can't reach. If you otherwise need to work on an external keyboard that doesn't have a sensor, just hit `CTRL + C`, when you're prompted for your fingerprint during `sudo`.

You can remove the fingerprint authentication under _Remove > Security > Fingerprint_ in the Omarchy menu.

### Fido2 authentication

If you're using a Fido2 device, you can set it up for `sudo` authentication using _Setup > Security > Fido2_ in the Omarchy menu (`Super + Space`). It covers `sudo` and system authorization prompts, though, not unlocking your computer.

You can remove the fido2 authentication under _Remove > Security > Fido2_ in the Omarchy menu.

### Face authentication

Face authentication needs an Intel IPU3 laptop with an ov7251 infrared sensor, on a kernel with the ov7251 strobe patch, which the stock Omarchy kernel doesn't carry yet. Without that strobe control the camera can't enroll, and USB (UVC) IR modules aren't supported.

Run _Setup > Security > Face > Enroll_ in the Omarchy menu (`Super + Space`). Setup checks the camera and its illuminator before downloading the 260 MB face models, and stops if either fails. Enroll with nobody else in view, since it takes one face at a time. Nothing is saved until it finishes, and then only numbers derived from your face, never images.

The lock screen (`Super + Ctrl + L`) then opens when you look at the camera. `sudo` and system authorization prompts open a window naming what's asking: nod twice to allow it, or shake your head to refuse, which sends `sudo` to its terminal prompt and cancels a system prompt. A fingerprint or Fido2 set up alongside is asked first. For `sudo` the window can also turn on [passwordless sudo](48-security.md#passwordless-sudo) for up to 24 hours, and says so before you nod.

Your password always works, and every face failure falls back to it. A `sudo` typed over SSH never reaches the camera and asks for your password. Any program in your desktop session, even one started from an SSH login, can raise the window or imitate it, so approve only a request you just made. Face matching hasn't been measured against look-alikes, and a close relative may pass.

_Setup > Security > Face_ also holds _Add Look_ (`omarchy setup security face --add`) for glasses or different light, _Tune Gestures_, _Walk-Away Lock_, and _Status_.

Once you pick _Walk-Away Lock > Enable_, the screen locks when nobody has been in front of it for the away time. In default mode anyone looking at the screen keeps it open; in secure mode only your face does, and the first look at anyone else locks. Under _Walk-Away Lock_, _Away Time_ sets each mode's away time and _Obscured Face_ how long a covered or turned-away face keeps it open. Switch modes from its icon in the [top bar](05-the-top-bar.md) or with `Super + Ctrl + Shift + L`; the switch lasts until the face service restarts.

You can remove face authentication under _Remove > Security > Face_ in the Omarchy menu.
