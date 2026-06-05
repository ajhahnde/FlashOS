# FlashOS — animated README demo. Replays the captured Raspberry Pi 4B
# boot (firmware + kernel + in-kernel test harness) at a readable scroll,
# then re-emits the real fsh session at the tail with a typewriter
# cadence — each command (whoami / ls / echo) is keyed out, then its real
# captured output appears, so it reads like a live session.
#
# Every byte is from a real capture (scripts/boot_demo_typing.py); only
# the pacing is added on replay. Live keystroke capture into the guest is
# not possible under QEMU, so the cadence is reproduced here instead.
#
# Regenerate with `vhs scripts/boot_demo.tape` (renders OneDark).

Output assets/boot_demo.gif

Set FontSize 11
Set Width 1200
Set Height 700
Set Theme "OneDark"
Set Padding 16
Set Framerate 24

# The replay command is hidden (typed instantly); recording starts as the
# boot begins to stream.
Hide
Type@5ms "clear"
Enter
Type@5ms "python3 scripts/boot_demo_typing.py"
Enter
Show

Sleep 21s
