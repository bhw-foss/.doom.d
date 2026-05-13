# Doom Emacs Configuration 

## Architecture

1. init.el
   The doom! block, which controls what Doom modules are enabled and in what order they will be loaded. This file is evaluated early when Emacs is starting up; before any other module has loaded. Generally shouldn’t add code to this file unless you’re targeting Doom’s CLI or something that needs to be configured very early in the startup process.

2. config.el
   My private configuration. Anything in here is evaluated after all other modules have loaded, when starting up Emacs.

3. packages.el
   Package management is done from this file; where to declare what packages to install and where from. Package source code is located in `~/.config/emacs/.local/straight/repos/`

## Commands

- Run tests with emacs command M-x "doom/reload".

