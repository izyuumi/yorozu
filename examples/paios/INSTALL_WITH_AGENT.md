# Install PAIOS with an agent

Copy the prompt below and paste it into your coding agent (Claude Code, Codex, Cursor, OpenClaw or any other that can run shell commands). It installs PAIOS into your Obsidian vault with the [installer](README.md#one-command).

```text
Install PAIOS (an example personal-ops vault of plain Markdown, from github.com/izyuumi/yorozu, folder examples/paios) into my Obsidian vault. Follow these steps in order. If any step fails, stop and report the exact error.

1. Get the inputs.
   - Vault path: ask me for the absolute path of my Obsidian vault folder, or propose one you detected and wait for me to confirm it. Never choose a vault path on your own. The folder must already exist; do not create it. If it doesn't exist, tell me and stop.
   - Time zone: an IANA zone such as Europe/Berlin. You may read it from the system, but show it to me and use the one I confirm.

2. Check for an existing install. If "<vault>/PAIOS" exists as a folder, a file or a symlink (also a broken one), stop and tell me. I may move or rename that path myself, or give you a different vault; then start again from step 1. Never overwrite it, merge into it, write into it, move it or delete it — wait for me to change the path. The installer refuses in this case too, and you must not work around that: --force and -f are not supported (the installer rejects them), and copying files on top is not allowed.

3. Run the installer. Replace <vault> and <tz> with the confirmed values. Quote the vault path so the shell passes it unchanged (spaces, quotes, dollar signs), and use an absolute path, not one starting with ~. Use single quotes if the path contains $, a backtick or a double quote, and write any single quote inside the path as `'\''`.

       curl -fsSL https://raw.githubusercontent.com/izyuumi/yorozu/main/examples/paios/install.sh | bash -s -- "<vault>" --tz <tz>

   If you are already in a checkout of that repository that contains examples/paios/install.sh, run this from the repository root instead:

       bash examples/paios/install.sh --tz <tz> "<vault>"

   The installer's only options are --tz <zone>, --ref <git ref> and -h / --help. Do not pass any other flag. Use --ref only if I ask you to pin a branch, tag or commit; it applies to the curl form only, and the default is main.
   The installer needs bash and Python 3.9 or newer, plus curl and tar for the curl form. If one is missing, tell me and ask before installing anything.

4. Check the result. The output must contain SELFTEST PASS and "Installed PAIOS into", and the exit code must be 0. Otherwise report the exact error and stop: do not retry with other flags, and do not copy files by hand over a failed or partial install.

5. After a successful install:
   - Run: source "<vault>/PAIOS/paios.env" (it exports PAIOS_VAULT and PAIOS_TZ). Do it in every shell where you run PAIOS scripts, and tell me to add that line to my shell profile or my agent's environment.
   - Read "<vault>/PAIOS/AGENTS.md" and follow it from now on when you work in this vault.
   - Walk me through replacing the example files with my own information. They are the files under "<vault>/PAIOS" that contain the line starting "> **Example file.**" (for example Runtime/Now.md, Projects/Example Project.md, Execution/Queue.md). Go one file at a time: ask me what belongs there, then replace or delete it as I say. Never invent facts about me, and never write secrets into the vault.
   - Suggest that I read "<vault>/PAIOS/System/Constitution.md" and change what doesn't fit.

6. Rules for the whole task.
   - Do not install Obsidian plugins or any other tool without asking me first.
   - Change nothing in the vault outside "<vault>/PAIOS".
   - Delete any temporary files you made, such as a downloaded copy of install.sh.

7. Finish with a short report: the vault path, the time zone, the self-test result, and the next steps that are left for me.
```
