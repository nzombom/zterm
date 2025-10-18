# TODO
- handle termios attrs
- implement line wrapping. right now in the main loop, the pty ioctl size is set
  to one less column to prevent line wrapping from causing bugs in programs like
  neovim. fix
