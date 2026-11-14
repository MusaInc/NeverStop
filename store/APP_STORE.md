# NEVER STOP 1.0: App Store submission pack

Everything here describes features in the 1.0 build (checked against the
code and menus on 12 Nov 2026). Paste into App Store Connect → NEVER STOP →
App Store tab → iOS App 1.0. **Items marked OWNER need your decision.**

## Identity

| Field | Value |
|---|---|
| Name | NEVER STOP |
| Subtitle (≤30) | Outrun the whole city's police |
| Bundle ID | com.musastudios.neverstop |
| Version / build | 1.0.0 / next TestFlight build number |
| SKU | neverstop-ios |
| Primary category | Games → Racing |
| Secondary category | Games → Action |
| Price | **OWNER** (CitySwing is £2.99 paid up front; NEVER STOP has no in-app purchases and no ads either way) |
| Copyright | © 2026 Musa Studios |
| Support URL | https://musastudios.co.uk/support |
| Privacy policy URL | https://musastudios.co.uk/privacy/neverstop *(page in `store/privacy-neverstop.html`; publish before submitting)* |
| Devices | iPhone and iPad (universal), landscape |

## Promotional text (≤170, can change without review)

One car, one city, every police unit on your tail. Drift, ram and jump your
way through the chase, or fight nine rivals on a platform in the sky.

## Description

`store/description.txt` (1,847 characters; every feature it lists is in 1.0).

## Keywords (≤100 chars)

police,chase,cop,pursuit,getaway,car,driving,drift,racing,arcade,crash,escape,wanted,offline

## What's new (1.0)

First release.

## App Review information

Notes for the reviewer: `store/review_notes.txt`. No login or demo account.
Contact: Musa Studios, support@musastudios.co.uk.

## App Privacy (nutrition label)

**Data Not Collected.** The app makes no network requests and has no
analytics, advertising, crash reporting or third-party SDKs. Progress and
settings stay on the device (`user://save.json`, `user://settings.cfg`).

## Export compliance

`ITSAppUsesNonExemptEncryption = NO` is set by the build workflow.

## Age rating questionnaire (suggested; you attest these)

| Question | Suggested answer | Why |
|---|---|---|
| Cartoon or fantasy violence | Infrequent / mild | Arcade cars crash, police cars are rammed and wrecked, mines and caltrops stop police cars. No people are ever hurt: pedestrians step out of the way and can't be hit, no drivers are shown |
| Realistic violence | None | |
| Profanity, crude humour, mature / suggestive, horror | None | |
| Alcohol, tobacco, drugs, gambling, sexual content | None | |
| Contests | None | |
| Unrestricted web access | No | No links out of the app |
| User-generated content / messaging | No | |

Evading the police is the premise (as in many 4+/9+ racing games); expect
**9+**. **OWNER** to confirm.

## Screenshots

Genuine in-game captures of the 1.0 build (HUD and touch controls as
shipped, rendered on the build server), with a headline band added.
`tools/store_shots.sh` reproduces them.

* `store/screenshots/iphone69/`: 2868 × 1320 (6.9″ iPhone, landscape), accepted for all iPhone sizes
* `store/screenshots/ipad13/`: 2752 × 2064 (13″ iPad, landscape), required because the app is universal
* `store/screenshots/raw/`: the same frames without headlines

## App icon

`assets/icon_1024.png`, made from the artwork `assets/brand/icon_source.jpg`
(`convert assets/brand/icon_source.jpg -resize 1024x1024 -alpha off PNG24:assets/icon_1024.png`,
plus a 256 px `assets/icon.png` for the web build). Opaque RGB, no alpha.
The iOS export makes every other size from it.

## Before you press Submit (checklist)

1. Publish `store/privacy-neverstop.html` at the privacy URL above.
2. Upload build 1.0.0 with the TestFlight workflow, then install it fresh on
   a real iPhone **and** iPad: launch, loading screen, a chase, a battle, the
   garage, backgrounding and relaunching. (CitySwing's first rejection was a
   stall on first launch on a review device; NEVER STOP now pre-compiles its
   shaders behind the loading screen and caps the 3-D pixel count, but that
   has only been checked on this server.)
3. Record a short screen recording of that run: Apple asked for one for
   CitySwing (Guideline 2.1, Information Needed).
4. Set price, age rating and categories; upload the screenshots; paste the
   text; choose the build; submit.
