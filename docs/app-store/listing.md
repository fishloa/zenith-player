# App Store listing (draft)

Platforms: Apple TV and iPad, universal purchase (one bundle ID for both).

## Name and subtitle

- Name: Zenith Player
- Subtitle: Live TV from an M3U playlist

## Description

Zenith Player plays live TV channels from an M3U playlist. Enter the playlist's address and its channels appear, grouped by country or category.

- Channel grid with logos
- Programme guide from the playlist's XMLTV guide
- On Apple TV, the focused channel plays live behind the grid
- Picks the right frame rate and dynamic range for each channel
- Multiple audio tracks
- Your playlist address syncs across your devices with iCloud

Zenith Player includes no channels or content. You need a playlist of MPEG-TS streams that you are entitled to watch.

Zenith Player is open source.

## Keywords

iptv,m3u,live tv,mpeg-ts,xmltv,epg,tv guide,playlist,dvb,tuner

## Category and rating

- Primary category: Entertainment (secondary: Utilities)
- Age rating: all questions "None". Unrestricted web access: No.
- Content rights: the app contains no third-party content; users supply their own.

## App Privacy

Data Not Collected. Privacy policy URL: the repository's PRIVACY.md (published
on GitHub).

## Export compliance

ITSAppUsesNonExemptEncryption = NO (HTTPS through system frameworks only).

## App Review notes

> PURPOSE AND AUDIENCE
> Zenith Player is a live TV player. The user enters the address of an M3U playlist of MPEG-TS streams, and the app shows its channels and plays them. It is for anyone who has such a playlist and wants to watch it on iPad or Apple TV. Apple devices cannot play raw MPEG-TS streams natively: the app demuxes and decodes them with Apple frameworks and adds a channel grid, programme guide and audio-track selection. It ships no channels or content of its own.
>
> HOW TO REVIEW (no account or login needed)
> 1. Launch the app. The first screen asks for a playlist address.
> 2. Enter: https://fishloa.github.io/zenith-player-demo/playlist.m3u
> 3. The app shows four demo channels: excerpts of the Blender open movies Big Buck Bunny, Sintel and Tears of Steel (CC BY 3.0) and a test pattern.
> iPad: tap a group, then a channel to play it full screen.
> Apple TV: focusing a channel tile plays a live preview; Select opens it full screen; Menu returns to the grid.
> The playlist address can be changed later in Settings.
> A screen recording of this flow is attached.
>
> ACCOUNTS AND CONTENT
> The app has no account registration, no login to any developer service, no user-generated content and no paid content. If a playlist's streams require sign-in, the app shows a sign-in prompt and stores the credential in the device keychain, sending it only to the address it was requested for. The demo playlist needs no sign-in.
>
> EXTERNAL SERVICES
> None operated by the developer. The app connects only to the playlist and stream addresses the user enters. The demo playlist is static files on GitHub Pages. The playlist address syncs between the user's devices with iCloud key-value storage. Bonjour (_zenith._tcp) is used only to suggest a playlist address offered on the local network. No analytics, ads, AI, payment or authentication services.
>
> REGIONAL DIFFERENCES
> None. The app works the same in every region where it is available.
>
> REGULATED INDUSTRY / THIRD-PARTY MATERIAL
> Not applicable. The app contains no third-party content. The demo videos are Blender Foundation open movies licensed CC BY 3.0. Users may only play streams they are entitled to watch, as the App Store description states.
>
> OTHER
> Arbitrary loads are allowed because playlists and streams are commonly served over plain HTTP. The local network permission is used only for the Bonjour suggestion above.

Demo channels: github.com/fishloa/zenith-player-demo (GitHub Pages), built by
scripts/make-demo-channels.sh.

## Screenshots needed

- Apple TV: 1920x1080 or 3840x2160, at least 1 (up to 10)
- iPad: 13-inch (2064x2752 or 2752x2064), at least 1
- Use demo content only: no broadcaster logos or programmes.
