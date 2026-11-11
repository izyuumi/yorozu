# Install PAIOS with an agent

Copy the prompt below and paste it into your coding agent (Claude Code, Codex, Cursor, OpenClaw, Hermes or any other that can run shell commands). It installs PAIOS into a folder you choose with the [installer](README.md#one-command), then offers to fill it from the history the agent can already read.

```text
Install PAIOS for me. PAIOS is a second-brain memory shared by me and my AI agents: a folder of plain Markdown files, from github.com/izyuumi/yorozu, folder examples/paios. It works in any folder and needs no particular app. Follow these steps in order. If any step fails, stop and report the exact error.

1. Get the inputs.
   - Folder: ask me which existing folder PAIOS should go into; the installer creates "<folder>/PAIOS" there. Any folder works, such as my home folder, a notes folder or a synced folder. You may suggest one, but wait for me to confirm it. Never choose a folder on your own. Use its absolute path. The folder must already exist; do not create it. If it doesn't exist, tell me and stop.
   - Time zone: an IANA zone such as Europe/Berlin. You may read it from the system, but show it to me and use the one I confirm.

2. Check for an existing install. If "<folder>/PAIOS" exists as a folder, a file or a symlink (also a broken one), stop and tell me. I may move or rename that path myself, or give you a different folder; then start again from step 1. Never overwrite it, merge into it, write into it, move it or delete it — wait for me to change the path. The installer refuses in this case too, and you must not work around that: --force and -f are not supported (the installer rejects them), and copying files on top is not allowed.

3. Run the installer. Replace <folder> and <tz> with the confirmed values. Quote the folder path so the shell passes it unchanged (spaces, quotes, dollar signs), and use an absolute path, not one starting with ~. Use single quotes if the path contains $, a backtick or a double quote, and write any single quote inside the path as `'\''`.

       curl -fsSL https://raw.githubusercontent.com/izyuumi/yorozu/main/examples/paios/install.sh | bash -s -- "<folder>" --tz <tz>

   If you are already in a checkout of that repository that contains examples/paios/install.sh, run this from the repository root instead:

       bash examples/paios/install.sh --tz <tz> "<folder>"

   The installer's only options are --tz <zone>, --ref <git ref> and -h / --help. Do not pass any other flag. Use --ref only if I ask you to pin a branch, tag or commit; it applies to the curl form only, and the default is main.
   The installer needs bash and Python 3.9 or newer, plus curl and tar for the curl form. If one is missing, tell me and ask before installing anything.

4. Check the result. The output must contain SELFTEST PASS and "Installed PAIOS into", and the exit code must be 0. Otherwise report the exact error and stop: do not retry with other flags, and do not copy files by hand over a failed or partial install.

5. After a successful install:
   - Run: source "<folder>/PAIOS/paios.env" (it exports PAIOS_ROOT, its older name PAIOS_VAULT, and PAIOS_TZ). Do it in every shell where you run PAIOS scripts, and tell me to add that line to my shell profile or my agent's environment.
   - Read "<folder>/PAIOS/AGENTS.md" and follow it from now on when you work in this PAIOS folder.

6. Offer to start from what you already know. Ask me once: "Scan the agent history I can already read for your lasting preferences and facts now, or skip?" If I skip, tell me I can run the prompt in "<folder>/PAIOS/IMPORT_HISTORY.md" at any time, and go to step 7. If I say yes, open "<folder>/PAIOS/IMPORT_HISTORY.md" and follow that prompt to the end before you continue to step 7, using the confirmed <folder> as <root>. Do not invent a shorter import procedure of your own.

7. Replace the examples. Walk me through replacing the example files with my own information. They are the files under "<folder>/PAIOS" that contain the line starting "> **Example file.**" (for example Runtime/Now.md, Projects/Example Project.md, Execution/Queue.md). Go one file at a time: ask me what belongs there, then replace or delete it as I say. If you replace Runtime/Now.md, keep any links the import added to it. Never invent facts about me, and never write secrets into PAIOS. Suggest that I read "<folder>/PAIOS/System/Constitution.md" and change what doesn't fit.

8. Rules for the whole task.
   - Obsidian is optional: set it up only if I say I want it, following "<folder>/PAIOS/docs/obsidian.md", and never install it, its plugins or any other tool without asking me first.
   - Change nothing outside "<folder>/PAIOS".
   - Delete any temporary files you made, such as a downloaded copy of install.sh.

9. Finish with a short report: the folder path, the time zone, the self-test result, what you imported from history (or that I skipped it), and the next steps that are left for me.
```
