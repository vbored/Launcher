
Note:
LaunchBack is currently in beta, so unexpected issues may occur. Please report them if they haven't already been reported.

Why does LaunchBack ask for Screen Recording permission?
LaunchBack shows the app grid over a blurred version of your actual desktop wallpaper — just like classic Launchpad did. For most people, that's a simple image file, and LaunchBack reads it directly with no special permission needed.

If you're using one of macOS's newer animated/dynamic wallpapers (the flowing gradient styles introduced in recent macOS versions), there's no image file behind it at all — it's rendered live by the system. To match those colors accurately instead of falling back to a generic blur, LaunchBack needs to take a quick snapshot of just the wallpaper layer, which macOS gates behind Screen Recording permission.

What this does not do:

It does not record your screen, your other windows, or anything you're working on.
It only ever captures the single, static desktop-background layer — the same layer that sits behind every other window on your Mac — and only at the moment you open LaunchBack.
Nothing is saved, transmitted, or stored anywhere. The snapshot exists in memory only, long enough to blur it for the background.
If you'd rather not grant it: LaunchBack works fine without it — it just falls back to a system blur effect that may not match your exact wallpaper colors as closely.

To enable it:

Open System Settings → Privacy & Security → Screen Recording
Turn on the toggle for LaunchBack
Quit and reopen LaunchBack (macOS requires a relaunch for this permission to take effect)


Without Persion
![alt text](https://github.com/vbored/Launchback/blob/main/screenshot.png)

With permission: 

![alt text](https://github.com/vbored/Launchback/blob/main/Screenshot1.png)

demo video
![](demo.mov)
