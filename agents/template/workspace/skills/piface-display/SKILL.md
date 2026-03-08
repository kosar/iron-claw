---
name: piface-display
description: >
  High-Density Physical Admin Dashboard (16x2 LCD).
  Use this skill to update the physical display on the Pi.
metadata:
  openclaw:
    emoji: "📟"
    requires:
      bins: ["curl", "bash"]
---

# PiFace LCD — Physical Information Surface

The PiFace CAD is a **16x2 character physical display**.

## 📟 Update the Display (Transient)
Use this during tasks. Text will be shown for 60s.

```
exec: bash /home/openclaw/.openclaw/workspace/skills/piface-display/scripts/display.sh "L1:Subject" "L2:Status"
```

## 📊 Update Admin Stats (Persistent)
Use at the end of runs. This updates the permanent dashboard.

```
exec: bash /home/openclaw/.openclaw/workspace/skills/piface-display/scripts/admin.sh "<user>" "<action>" "<balance>"
```

## 🚀 Startup Banner
Use only during startup/heartbeat. Stays for 5 mins.

```
exec: bash /home/openclaw/.openclaw/workspace/skills/piface-display/scripts/startup.sh "Line 1" "Line 2"
```

## Rules
- **Succinctness:** Max 16 chars per line. Use abbreviations (LD, MEM, BAL).
- **No Filler:** No "The", "Is", or polite phrases on the LCD.
