# MyNightSky

MyNightSky is an iPhone app for long-exposure night-sky photos. It takes a series of frames at the longest exposure the camera API allows, aligns them, and saves one stacked image. The home screen name is MyNightSky.

This project was written on Linux. The iOS app itself was not compiled here — there is no Xcode, and the Simulator has no camera, so the app will not invent frames. The stacking package was tested on this machine with Swift 6.2.3 (`swift test`, 30 tests).

## Run it on an iPhone

1. Open `MyNightSky.xcodeproj` in Xcode on a Mac.
2. Select the **MyNightSky** scheme and a physical iPhone (not the Simulator).
3. If Xcode asks, choose your team so it can sign the app. The project deployment target is iOS 18.
4. Run. Trust the developer on the phone if iOS asks, then allow Camera.
5. At night, somewhere dark with a clear view of the sky, set the frame count (the default is 10) and tap **Start**.
6. The button says **Waiting for camera…** while the rear camera starts. Read the instruction, then use the one countdown to set the phone down. Lay it **face down** on a flat surface so the rear camera points at the sky and the screen faces the surface. The long exposure does not start until that countdown finishes.
7. Elapsed time, frames left, and an estimate of time left stay on screen while it captures. The camera waits 5 seconds between frames and does not wait after the last frame. The estimate includes those pauses. Pick the phone up when it says **Safe to pick up**.
8. Preview the stack and tap **Save to Photos**. Allow adding to the photo library when asked.

The shutter speed is the active format's maximum exposure duration. It is read from the phone at capture time and is not a hardcoded length. The session starts before the countdown, at a normal frame rate. When the countdown hits zero, the app sets that longest exposure and takes a still, then waits 5 seconds, then takes the next still, until the series is done. There is no wait after the last still. When the rear camera can lock a custom lens position, focus is locked at 1.0 (infinity) before the countdown and left locked for the whole series. If the camera cannot lock at 1.0, the series still uses that longest exposure. Each frame is a still from the photo output, with still-image stabilization off, so a later photo is not rejected after the first one. Frames are aligned by translation and combined with a median stack.

## Stacking tests

Alignment, stacking, and the countdown gate are pure Swift in `NightSkyStack`. On a machine with the Swift toolchain:

```bash
cd NightSkyStack
swift test
```
