# authorized_keys/

This folder holds the shared **fleet ADB key**, which is the one and only
mechanism that lets operator laptops connect to fleet devices over ADB.

## The shared fleet key (adbkey_kagami_fleet)

`adbkey_kagami_fleet` is the shared *private* ADB key for the whole fleet. It is
NOT committed to the repo (it is gitignored) and is distributed separately by
the team lead.

Every operator laptop installs this same private key as its own
`~/.android/adbkey`, so all laptops present ONE identity to the devices. That is
the whole trick: a device only ever has to trust that single identity.

To install it:
  1. Obtain `adbkey_kagami_fleet` from your team lead (AirDrop, 1Password, etc.)
  2. Place it in this folder:  authorized_keys/adbkey_kagami_fleet
  3. Run ./install.sh — it copies the key to ~/.android/adbkey, regenerates the
     matching ~/.android/adbkey.pub, and restarts adb. Look for the message
     "Fleet ADB key installed".

## How a device gets authorized

Pre-seeding keys onto the device does NOT work on the production MLOS build
(see the note below), so authorization happens in the headset, once per device:

  - The first operator to USB-connect to a freshly flashed or factory-reset
    device taps "Allow USB debugging" -> "Always allow from this computer" on
    the headset.
  - Because every laptop shares the one fleet identity, that single tap
    authorizes ALL operator laptops for that device. It is one tap PER DEVICE,
    not per laptop. No one else has to tap Allow for that device again.

That is the entire model. There is nothing for operators to commit, generate,
or share — installing the fleet key is the only per-laptop step.

## Note on the *.pub files (inert)

You may see per-machine public keys here (e.g. macbook-neo.pub). These are
leftovers from an earlier approach that tried to pre-inject each laptop's public
key into the device's /data/misc/adb/adb_keys at flash/provision time. That
injection does NOT work on the ML2 1.4.1 user build — the secure OS ignores
pre-seeded adb_keys. The injection code is left in place only because it would
work on a non-secure build. These .pub files are gitignored and have no effect
on the production fleet; do not rely on them and there is no need to add your own.
