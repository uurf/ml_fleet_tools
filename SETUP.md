# KAGAMI Fleet Toolkit — Setup Guide
### Tin Drum / Magic Leap 2 Fleet Management

This guide walks you through setting up the KAGAMI fleet toolkit on your Mac. Follow these steps once per machine. After setup, refer to **PROVISIONING.md** for daily device flashing instructions.

---

## What you need

- A Mac with a free USB-C port while plugged in to power
- An internet connection
- The fleet ADB key file `adbkey_kagami_fleet` — ask your team lead for this. Every machine that connects to fleet devices must use this key.

---

## Step 1 — Open Terminal

Press **Cmd+Space**, type `Terminal`, and press Enter.

---

## Step 2 — Run the installer

Paste this into Terminal and press Enter:

```
curl -fsSL https://raw.githubusercontent.com/uurf/ml_fleet_tools/main/install.sh | bash
```

The installer will:
- Install Homebrew (Mac package manager) if not already installed
- Install required tools: `adb`, `fastboot`, `bash`, `git`, `python3`
- Download the toolkit to `~/Developer/ml_toolkit`
- Configure all scripts

If asked for your Mac password, enter it — this is normal for installing system tools.

When you see **Installation complete!** you're done with this step.

---

## Step 3 — Install the fleet ADB key

Every machine that flashes or connects to fleet devices must use the shared fleet ADB key. This ensures all laptops are recognized by devices using the same key. It's distributed separately for security — do not share it outside the team.

Copy the `adbkey_kagami_fleet` file your team lead gave you to:

```
~/Developer/ml_toolkit/authorized_keys/adbkey_kagami_fleet
```

Then run the installer again to activate it:

```
cd ~/Developer/ml_toolkit && ./install.sh
```

You'll see **Fleet ADB key installed** when it's set up correctly.

---

## Step 4 — Download the OS image from ML Hub

The OS image is too large to distribute with the toolkit — you need to download it separately from ML Hub.

1. Open **Magic Leap Hub** on your Mac
2. Go to **Package Manager**
3. Find **Device OS Versions** → select the target version → **Apply Changes**
4. Wait for the download to complete, then click **Open Folder**
5. Copy the downloaded folder into `~/Developer/ml_toolkit/os_images/` and **rename it to the version number**

Your folder structure should look like:

```
ml_toolkit/
└── os_images/
    └── 1.4.1/
        ├── flashall_amd.sh
        └── *.img files
```

---

## Step 5 — Verify setup

In Terminal, run:

```
cd ~/Developer/ml_toolkit && ./ml_os_flash.sh
```

If the toolkit is set up correctly you'll see the OS selection menu or auto-selection output. If there's no OS image yet you'll see a message saying `os_images/` is empty — that's fine, it means Step 4 isn't done yet.

---

## Keeping the toolkit updated

When your team lead pushes updates, run:

```
cd ~/Developer/ml_toolkit && ./update.sh
```

The script will show you the current version and the new version after updating. If the scripts tell you to update when you run them, this is the command to use.

---

## Troubleshooting

**"Permission denied" when running a script**
```
chmod +x ~/Developer/ml_toolkit/*.sh
```

**"adb: command not found"**
```
brew install android-platform-tools
```

**"No such file or directory: os_images"**
You need to download the OS image — see Step 4 above.

**Script exits immediately with no output**
Make sure you're using Homebrew bash:
```
/opt/homebrew/bin/bash ./ml_os_flash.sh
```

**Toolkit says it's out of date every time**
Run `./update.sh` — if that doesn't fix it, check your internet connection and try again.

---

Once setup is complete, proceed to **PROVISIONING.md** for device flashing instructions.
