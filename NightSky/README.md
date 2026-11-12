# MyNightSky

MyNightSky is an iPhone app for long-exposure night-sky photos. It takes a series of frames at the longest exposure the camera API allows, aligns them, and saves one stacked image. The Xcode project and scheme stay `NightSky`; the name on the phone is MyNightSky.

This project was written on Linux. The iOS app itself was not compiled here — there is no Xcode, and the Simulator has no camera, so the app will not invent frames. The stacking package was tested on this machine with Swift 6.2.3 (`swift test`, 27 tests).

## Run it on an iPhone

1. Open `NightSky.xcodeproj` in Xcode on a Mac.
2. Select the **NightSky** scheme and a physical iPhone (not the Simulator).
3. If Xcode asks, choose your team so it can sign the app. The project deployment target is iOS 18.
4. Run. Trust the developer on the phone if iOS asks, then allow Camera.
5. At night, somewhere dark with a clear view of the sky, set the frame count (the default is 10) and tap **Start**.
6. Read the instruction, then use the countdown to set the phone down. Lay it **face down** on a flat surface so the rear camera points at the sky and the screen faces the surface. The exposure series does not start until the countdown finishes.
7. Elapsed time, frames left, and an estimate of time left stay on screen while it captures. Pick the phone up when it says **Safe to pick up**.
8. Preview the stack and tap **Save to Photos**. Allow adding to the photo library when asked.

The shutter speed is the active format's maximum exposure duration. It is read from the phone at capture time and is not a hardcoded length. Focus is locked toward infinity. Frames are aligned by translation and combined with a median stack.

## Stacking tests

Alignment, stacking, and the countdown gate are pure Swift in `NightSkyStack`. On a machine with the Swift toolchain:

```bash
cd NightSkyStack
swift test
```
