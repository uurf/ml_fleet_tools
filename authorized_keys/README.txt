# authorized_keys/

This folder contains ADB public keys for machines authorized to connect
to fleet devices.

## Fleet private key (adbkey)

The fleet private key `adbkey` is NOT stored in this repo for security reasons.
It is distributed separately by the team lead.

To install it:
1. Obtain `adbkey` from your team lead (AirDrop, 1Password, etc.)
2. Place it in this folder: authorized_keys/adbkey
3. Re-run ./install.sh — it will configure your machine automatically

## Public keys (*.pub)

One .pub file per authorized machine. These are committed to the repo.
When a new machine is set up, its public key should be added here and committed.

To get your machine's public key after running install.sh:
  cat ~/.android/adbkey.pub

Add it to this folder with a descriptive name, e.g.:
  authorized_keys/macbook-neo.pub
  authorized_keys/macbook-air-chris.pub

Then commit and push so other machines pick it up on next git pull.
