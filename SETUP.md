# KAGAMI Fleet Toolkit — Setup Guide
### Tin Drum / Magic Leap 2 Fleet Management

This guide walks you through setting up the KAGAMI fleet toolkit on your Mac. Follow these steps once per machine. After setup, refer to **PROVISIONING.md** for daily device flashing instructions.

---

## What you need

- A Mac (MacBook Air or MacBook Pro — both Intel and Apple Silicon work)
- An internet connection
- Access to the private GitHub repo (ask your team lead for access)
- A GitHub account

---

## Step 1 — Install GitHub Desktop

If you don't already have it:

1. Go to [desktop.github.com](https://desktop.github.com)
2. Download and install GitHub Desktop
3. Open it and sign in with your GitHub account

---

## Step 2 — Clone the repo

1. In GitHub Desktop, go to **File → Clone Repository**
2. Search for `ml_toolkit_tools` or paste the repo URL
3. Set the local path to: `/Users/[yourname]/Developer/ml_toolkit`
   - If the `Developer` folder doesn't exist, GitHub Desktop will create it
4. Click **Clone**

---

## Step 3 — Run the installer

1. Open **Terminal** (search for it in Spotlight with Cmd+Space)
2. Type the following and press Enter:

```
cd ~/Developer/ml_toolkit && chmod +x install.sh && ./install.sh
```

3. The installer will:
   - Install Homebrew (Mac package manager) if not already installed
   - Install required tools: `adb`, `fastboot`, `bash`, `git`, `python3`
   - Set up the fleet ADB key so devices trust your laptop
   - Configure all scripts

4. Follow any prompts on screen. If asked for your Mac password, enter it — this is normal for installing system tools.

5. When you see **Installation complete!** you're done.

---

## Step 4 — Download the OS image from ML Hub

The OS image file is too large to store in GitHub — you need to download it separately.

1. Open **Magic Leap Hub** on your Mac
2. Go to **Package Manager**
3. Find **Device OS Versions** → select version **1.4.1**
4. Click **Apply Changes** and wait for the download to complete
5. Click **Open Folder** to find where it downloaded
6. Copy the entire folder (named `1.4.1`) into:
   ```
   ~/Developer/ml_toolkit/os_images/
   ```

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
cd ~/Developer/ml_toolkit
./ml_os_flash.sh --help
```

If you see the help output, everything is installed correctly.

---

## Keeping the toolkit updated

When your team lead pushes updates to the repo:

1. Open GitHub Desktop
2. Click **Fetch origin** then **Pull**
3. Re-run `./install.sh` to apply any configuration changes

Or from Terminal:
```
cd ~/Developer/ml_toolkit && git pull && ./install.sh
```

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
/opt/homebrew/bin/bash ./ml_os_flash.sh 1.4.1
```

---

Once setup is complete, proceed to **PROVISIONING.md** for device flashing instructions.
