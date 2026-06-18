# FlashOS — animated README demo. Replays the boot + fsh session via
# scripts/boot_demo_typing.py with two cadences, so it reads like a real
# console: boot `[ OK ]` lines and command OUTPUT paint whole, one line at
# a time, while the username at `login:` and each `$ ` command (whoami / ls
# / cat / echo) are typed out key-by-key at the prompt.
#
# Boot bytes mirror a real Raspberry Pi 4B Mini-UART capture; the
# authenticated fsh session is reconstructed from the programs' own output
# (the login gate blocks capturing it under QEMU). See the script header.
#
# Regenerate with `vhs scripts/boot_demo.tape`.

Output assets/boot_demo.gif

# Theme + font mirror the user's Ghostty config (Atom One Dark palette,
# bg #1c1e26 / fg #abb2bf, JetBrainsMono Nerd Font). The terminal's
# background-opacity/blur and bloom shader can't be reproduced in an opaque
# GIF, so the GIF background is the solid base colour.
Set FontFamily "JetBrainsMono Nerd Font"
Set FontSize 18
Set Width 1200
Set Height 700
Set Theme { "name": "Ghostty AtomOneDark", "background": "#1c1e26", "foreground": "#abb2bf", "selection": "#3e4451", "cursor": "#c0caf5", "black": "#282c34", "brightBlack": "#5c6370", "red": "#e06c75", "brightRed": "#e06c75", "green": "#98c379", "brightGreen": "#98c379", "yellow": "#e5c07b", "brightYellow": "#e5c07b", "blue": "#61afef", "brightBlue": "#61afef", "magenta": "#9a86fd", "brightMagenta": "#9a86fd", "cyan": "#66b2ff", "brightCyan": "#66b2ff", "white": "#abb2bf", "brightWhite": "#ffffff" }
Set Padding 20
Set Framerate 24

# The replay command is hidden (typed instantly); recording starts as the
# boot begins to stream.
Hide
Type@5ms "clear"
Enter
Type@5ms "python3 scripts/boot_demo_typing.py"
Enter
Show

Sleep 29s
