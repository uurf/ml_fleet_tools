Place adbkey.pub files here to pre-authorize additional machines.

Each laptop/workstation used for KAGAMI fleet management should have
its ADB public key in this folder so all devices trust all machines
without ever showing the "Allow USB debugging" dialog.

To get the public key from any machine:
  macOS/Linux:  cat ~/.android/adbkey.pub
  (If it doesn't exist yet, run 'adb devices' once to generate it)

Copy the .pub file here with a descriptive name, e.g.:
  macbook_stage_left.pub
  macbook_stage_right.pub
  macbook_ops_booth.pub

These keys are injected into every device during os_downgrade.sh.
To inject them into already-provisioned devices over WiFi ADB:
  ./ml_deploy.sh shell "cat /data/misc/adb/adb_keys"   # see current keys
  # Then push an updated adb_keys file using ml_deploy.sh push
