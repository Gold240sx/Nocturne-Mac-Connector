<img src="https://utfs.io/f/3394da99-784c-4153-b71d-450d4e3e48b3-1xajxz.jpg" alt="Nocturne-Mac-Connector" width="650">

# Nocturne-Mac-Connector

Why was this created?

I wanted to control my Spotify, Youtube, Apple Music on my Mac from the Spotify Car Thing.

The Spotify Car Thing is a small device that you can connect to your car's audio system. It has a button to play/pause, skip forward, skip backward, and volume up/down.

This repo works with a CarThing Flashed with the Nocturne firmware.

This is a port of the iphone/android only Nocturne connect repo (a vite-react app) who uses a python script to connect to the CarThing.

This repo is built on Swift, & SwiftUI, and in near-fully functional.

I got Album art, timestamp, song duration and progress, back, forward, pause,  Shuffle and Repeat cycles all working and in sync with the Mac Port now. Updates on new songs as you would expect

Things it's missing:

- Lyrics
- Like / Unlike (UI reacts just doesn't sync)
- Volume (I think I'm just rate-limited out but maybe another reason)

Things I'd like to do in the future to improve it:

I was able to  get the now playing from nearly any source on the Mac (Spotify, Youtube, Apple Music) into the app itself, which wasn't easy because Apple depricated the MediaRemote API in macOS 14.4. Thankfully I found a workaround with Ejbills package MediaRemoteAdapter linked below. This however is not in place due to how Nocturne currently works... this feature could be added pretty easily by adding a conditional function call to behave differently if the connector is the Mac Connect, and if so if the player is not Spotify etc, but each button was configured seperately and I didn't want to dive into making any changes to the firmware... yet. But with that, it really shouldn't be all that hard, and then the Now playing feature (show playing info from any source) would match the current state of the iOS-based connector, so for the sake of cohesion, it would be a nice addition.

Nocturne Firmware: [Nocturne Firmware Repo](https://github.com/usenocturne/nocturne)
Nocturne Connect Repo: [Nocturne Connect Repo](https://github.com/usenocturne/nocturne-connector)
Nocturne Website: [Nocturne Website](https://usenocturne.com)
MediaRemoteAdapter: [MediaRemoteAdapter Repo](https://github.com/ejbills/mediaremote-adapter)

If you like this project, please consider donating to the Nocturne project. It wouldn't of been built without all the hard work from the Nocturne team.
