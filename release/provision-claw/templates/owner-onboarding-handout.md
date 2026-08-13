# Getting you connected

Welcome. This gets you working on your firm's claw from your laptop, and from your phone if you want it.

A *claw* is the machine your firm's work lives on. WAGMI runs it; the work on it is yours.

**You can hand this whole file to your own AI assistant** — Claude, ChatGPT, whichever you use — and ask it to walk you through it or run it for you. It was written to be followed either way.

## The one thing worth knowing up front

Nothing in here asks you for a password, a token, or a private key. Nothing in here produces one in a chat window.

You are going to make a pair of keys. One half is private. It stays on your machine, and in your password manager somewhere only you can open. The other half is public, and public keys are safe to paste anywhere — that is the only thing you send back to us.

So if an assistant is helping you: it never sees a secret, because no step in this document creates one where it could look. It cannot leak what it never touches.

## What you need before you start

- Your laptop, and a terminal on it
- A password manager you already use (1Password, Bitwarden, Apple Passwords, whatever it is)
- The connection details we sent you: **the claw address, your username**
- Your phone, if you want to work from it

## Step 1 — pick your desktop app

You need one of these on your laptop. If you already have one, skip ahead.

**Claude Code.** Install it, then sign in with your own Claude account.

```bash
curl -fsSL https://claude.ai/install.sh | bash
claude --version
```

**Codex.** Install it from the ChatGPT desktop app, then sign in with your own ChatGPT account.

Either works. You can have both. You bring your own subscription, and the claw does not hold or pay for it — your conversations are yours.

## Step 2 — make your desktop key

If you already have an SSH key you use, skip to step 3 and send us that public half instead.

```bash
ssh-keygen -t ed25519 -C "your-name-laptop"
```

Press enter to accept the default location. Set a passphrase if you want one.

This makes two files. `~/.ssh/id_ed25519` is private — it stays put. `~/.ssh/id_ed25519.pub` is public, and that is the one you send us.

## Step 3 — make your phone key

Skip this if you do not want phone access. You can add it later.

The mobile app is fussy about key format. It wants an unencrypted PKCS#8 key on a P-256 curve, and it rejects the format `ssh-keygen` normally makes, and it rejects RSA. So this one uses `openssl`. Copying a key you already have will not work here.

**Your password manager's "create SSH key" button will not do it either.** Those generators make the ordinary format, which is the one the mobile app turns down. Use the commands below and store the result afterwards. This is the one key you make by hand.

```bash
umask 077
openssl ecparam -name prime256v1 -genkey -noout -out phone.key
openssl pkcs8 -topk8 -nocrypt -in phone.key -out phone.p8
ssh-keygen -y -f phone.key > phone.pub
```

Three files, and it matters which is which:

| File | What it is | Who sees it |
|---|---|---|
| `phone.p8` | your private key, in the form your phone wants | you only |
| `phone.key` | the same private key, different form | you only |
| `phone.pub` | your public key | us; safe to paste anywhere |

## Step 4 — put the private key in your password manager

Save the contents of `phone.p8` into your password manager as a secure note. Call it something you will recognise later, like `phone SSH key`.

**Put it in a vault only you can read.** Most managers give you a personal vault of your own alongside the shared ones your team uses, and the personal one is where this goes, whatever yours is called. Not a shared vault, not a team vault, not one an app or an automated account can open. This key is how the claw knows an action was yours rather than somebody else's, and a key two people can reach cannot answer that. If you are unsure which of your vaults is which, the test is whether anyone else could open it — if they could, it is the wrong one.

Nobody at your firm, and nobody here, needs a copy for safekeeping. If you ever lose it you make a new one and send us the new public half, which takes a couple of minutes and is a far better trade than a key other people can open.

Save it as a **note**, not as an SSH-key item. A note holds the format your phone needs. It also means this key stays out of your manager's SSH agent, which is correct — the agent is for your laptop, and this key belongs to your phone.

Then open that note on your phone, through your manager's app. That is how the key gets to your phone.

**Move it that way and no other way.** Not chat, not email, not AirDrop, not the clipboard into a messaging app. Anything you delete in those places leaves backups nobody can account for, so a key that has been through one is a key we replace.

If a private key ever ends up somewhere it should not, just tell us. We replace it in a minute and nobody minds. Do not spend time working out how likely it is that anyone saw it.

Once your manager has the key and your phone can reach the claw, delete the local copies:

```bash
shred -u phone.key phone.p8 phone.pub
```

## Step 5 — send us the public halves

Send back:

1. the contents of `~/.ssh/id_ed25519.pub` — one line, starts with `ssh-ed25519`
2. the contents of `phone.pub` — one line, starts with `ecdsa-sha2-nistp256`, only if you did step 3

Both are public. Paste them however is convenient.

**Do not send us anything else.** If you find yourself about to send a file whose name does not end in `.pub`, stop.

Wait for us to confirm they are installed before the next step.

## Step 6 — connect from your laptop

Add this to `~/.ssh/config` on your machine, filling in what we sent you. **Name the entry after the claw**, not something generic — people end up on more than one, and two entries called the same thing is a bad afternoon.

```
Host <the claw name>
  HostName <the claw address>
  User <your username>
  IdentityFile ~/.ssh/id_ed25519
  ServerAliveInterval 60
```

Check it:

```bash
ssh <the claw name> 'hostname; pwd'
```

You should see the claw name and your home directory. If you get a password prompt, something is wrong — the claw does not accept passwords at all, so it means your key is not being offered.

Now open the claw in your app. Codex reads your SSH config and finds the entry by itself. Claude Code takes an SSH connection in the app.

Your work lives in `workspaces` in your home folder, one folder per area of work. When the app asks which folder to open, that is where to look, and it is right there when the picker starts.

Open your work folder. Ask it what the instructions file says. It should answer with your team's actual context, not a guess — that tells you the session is genuinely running on the claw rather than pretending from your laptop.

## Step 7 — connect from your phone

**Claude.** Start a session on the claw that stays running:

```bash
ssh <the claw name>
tmux new -d -s rc
tmux send-keys -t rc 'cd ~/workspaces/<your workspace> && claude' Enter
```

Then connect Remote Control from the Claude phone app. That session keeps running whether or not your laptop is open or even awake.

**Codex.** In the ChatGPT phone app: Remote control, add connection, SSH. Enter the claw address, your username, and the private key out of the note in your own vault. Note that the phone holds its own connection — it will not find one through your laptop.

## You are operational when

Work through these. If all five pass, you are done.

- [ ] `ssh <the claw name> 'hostname'` answers with the claw name
- [ ] Your desktop app opens your work folder under `~/workspaces` on the claw
- [ ] You ask it what the instructions file says, and it answers with your team's real context
- [ ] Your phone connects and answers `hostname` and `pwd` correctly
- [ ] You close your laptop, ask the phone something, and it still answers

That last one is the good part. The work lives on the claw, so it keeps going whether or not you are at your desk.

## If something does not work

**The mobile app rejects your key.** Almost always the format. Redo step 3 exactly — a key from `ssh-keygen` alone will not be accepted.

**Connection refused.** Your public key may not be installed yet, or it arrived with a line break in the middle. Send it again as one line.

**You are asked for a password.** The claw accepts no passwords, so your key is not being offered. Check the path in your SSH config.

**The phone cannot find the claw through your laptop.** It is not supposed to. The phone holds its own connection; see step 7.

Anything else, ask us. Setup problems are ours, not yours.
