# Provider artwork provenance

Verified 2026-09-27. These assets identify third-party services; they are not Paul Notch branding and do not imply sponsorship, partnership, or a working integration. All marks remain the property of their respective owners. This project does not claim to relicense them under its source-code license. Review each owner's current brand/distribution terms before a public release.

Only format conversion and proportional resizing were performed. Do not redraw, tint, or substitute a generic system symbol for an official mark. If reliable artwork is unavailable, keep the service name and omit the mark.

### Runtime-only installed Muse artwork (verified 2026-10-03)

`ProviderBrandAssets` loads Muse's declared `/Applications/Muse.app/Contents/Resources/AppIcon.icns` only after checking `com.meta.endo` (or the identity-checked LaunchServices installation). It is cached and rendered untinted; no Muse artwork file is copied into this repository. The 256px image's visible alpha footprint is 25...230 on both axes. Cropping 24/256 of the transparent gutter on each side leaves antialiasing intact and a centered 206px footprint on a 208px display canvas, matching the shared logo slot. This identifies Meta's consumer Muse only and is not evidence of a connected account. Missing installed artwork stays absent.

| File | Source | Processing |
| --- | --- | --- |
| `codex.png` | Installed official ChatGPT app: `/Applications/ChatGPT.app/Contents/Resources/icon-codex-light.png` | Exact file copy; original Codex app artwork |
| `kimi.png` | Installed official Kimi app, its declared `CFBundleIconFile`: `/Applications/Kimi.app/Contents/Resources/Kimi.icns` | ICNS converted to PNG, proportional 128 px |
| `doubao.png` | Installed Doubao Work app, its declared `CFBundleIconFile`: `/Applications/DoubaoWork.app/Contents/Resources/app.icns` | ICNS converted to PNG, proportional 128 px; specifically Doubao Work, not a generic chat icon |
| `grok.png` | [Grok's official App Store listing](https://apps.apple.com/us/app/grok-ai/id6670324846), linked by [xAI's brand page](https://x.ai/legal/brand-guidelines). Apple's lookup record for app ID `6670324846`, bundle `ai.x.GrokApp`, supplies `artworkUrl512`. | Original downloaded artwork retained as `grok.jpg`; format-only PNG conversion |
| `deepseek.png` | [DeepSeek official App Store listing](https://apps.apple.com/us/app/deepseek-ai-assistant/id6737597349), Apple lookup ID `6737597349`, bundle `com.deepseek.chat`, seller `Hangzhou DeepSeek Artificial Intelligence Co., Ltd` | Original retained as `deepseek-appstore.jpg`; format-only PNG conversion, verified 2026-09-28. Replaces the shorter transparent favicon to match the other official app-icon silhouettes; legacy `deepseek.ico` retained |
| `minimax-api.png` | [MiniMax official favicon](https://www.minimax.io/favicon.ico) | Original 32 px artwork retained as `minimax-api.ico`; proportional PNG conversion, no invented detail |
| `minimax-audio.png` | [MiniMax Audio official favicon](https://www.minimax.io/audio/favicon.ico) | Original 32 px artwork retained as `minimax-audio.ico`; proportional PNG conversion, no invented detail |

Grok artwork URL from Apple's response:

`https://is1-ssl.mzstatic.com/image/thumb/Purple221/v4/29/2f/44/292f4441-a728-0ae5-2cf1-69b5bd7e4607/AppIcon-0-0-1x_U007epad-0-0-0-1-0-0-0-85-220.png/512x512bb.jpg`

DeepSeek artwork URL from Apple's response (2026-09-28):

`https://is1-ssl.mzstatic.com/image/thumb/Purple211/v4/44/2f/a3/442fa386-e9bc-da3c-4d0c-7f5ad8186b7e/AppIcon-0-0-1x_U007epad-0-1-0-sRGB-85-220.png/512x512bb.jpg`

## SHA-256 of rendered PNG inputs

```text
de7d43f3386105ab20952958c2c25beb0d903e2aeb6e1aef57c49a648c0d1c07  codex.png
75edd1a581ebc32bf533e1c4911ec3a867c21cba4f14744ddf82522efc3e2578  deepseek.png
cfe428837e302762daf3ad73c4f45e12561a1274ab92e7b3dd7ca113b1aaf776  doubao.png
ad8a77c7a5e9014f85298aa3e9ced37487446152814ff88582d44f53d340352d  grok.png
c9763091c754f3679e270862a23f2fe56e454a17751517a8a88c9229930af0b5  kimi.png
c6b881818029efae5e0339c837ee2bcf7b1d7eea9d8763cba9001deb33ec11ce  minimax-api.png
8afbce130b1f484fa78d0787c9a268585341ffe24d8437d65b39c7760a2d0767  minimax-audio.png
```
