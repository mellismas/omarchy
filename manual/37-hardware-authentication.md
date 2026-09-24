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

If your laptop has an infrared camera whose illuminator the kernel can drive, you can unlock the lock screen by looking at it. Today that means an Intel IPU3 laptop with an ov7251 IR sensor on a kernel carrying the ov7251 strobe patch, which the stock Omarchy kernel doesn't have yet; USB (UVC) IR modules aren't supported. Run _Setup > Security > Face > Enroll_ in the Omarchy menu (`Super + Space`): the entry appears only when a supported camera is detected. Setup installs the `omarchy-faceauth` and `omarchy-faceauth-models` packages first, then asks `faceauth doctor` whether it can open the camera and drive the illuminator. If not, it stops there, before it starts the face service, enrolls you or changes any PAM configuration. Otherwise it walks you through enrolling your face in a window that never shows or keeps a picture of you, verifies it, and from then on the lock screen (`Super + Ctrl + L`) opens when you look at the camera.

A color webcam won't do: it can't see in the dark and a photo fools it. The IR camera refuses a paper print by how differently paper and skin reflect its own light, and in testing a phone or screen held up to it has read as glare, not a face. It can't tell a look-alike or a 3D mask from you, so keep a strong password behind it; every failure falls back to the password. The [FaceAuth README](https://github.com/mellismas/omarchy-faceauth) lists what it resists and what it doesn't.

Your enrollment is a set of numbers derived from your face, never images, kept root-only and sealed to the TPM when the machine has one. _Setup > Security > Face_ also holds _Add Look_, _Tune Gestures_ and _Status_ (`faceauth doctor`).

You can remove face authentication under _Remove > Security > Face_ in the Omarchy menu.
