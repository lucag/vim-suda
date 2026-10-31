# vim-suda

A Vim and Neovim plugin that reads and writes protected files by escalating privileges through an external privilege-escalation tool (`sudo`).

## Language

**Protected File**:
A file whose permissions prevent the current user from reading or writing it directly without privilege escalation.

**Editor Session**:
A single running instance of Vim or Neovim in which a user opens buffers and executes `:SudaRead` or `:SudaWrite` commands.
_Avoid_: Vim instance, Neovim instance

**Host Shell**:
The interactive shell session that launched the Editor Session and to which the user returns after exiting the editor.
_Avoid_: Parent shell, spawning shell

**Credential Scope**:
The boundary across which a successful privilege-escalation authentication remains valid without re-prompting for a password (for example, across commands within the same Editor Session or back in the Host Shell).
_Avoid_: Privilege escalation scope, sudo session, timestamp scope

**Terminal Client**:
The part of an Editor Session attached to the Host Shell's terminal; privileged commands started from it share the Host Shell's Credential Scope.
_Avoid_: TUI, UI client, outer nvim
