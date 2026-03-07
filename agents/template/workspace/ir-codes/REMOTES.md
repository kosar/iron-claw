# Learned IR remotes

Buttons learned here can be replayed by the **ir-blast** skill (remote name + button name).

**To learn buttons** (run on the Pi where the IR dongle is attached):

```bash
cd /path/to/ironclaw
./scripts/ir-learn.py
```

Learned files are stored as `ir-codes/<remote>/<button>.ir`. This catalog is updated automatically.

**Blast from CLI:** `./scripts/ir-blast.sh agents/pibot/workspace/ir-codes/<remote>/<button>.ir`  
**From the agent:** Use the ir-blast skill; emit by remote and button name.

## fanremote2

| Button | File |
|--------|------|
| power | fanremote2/power.ir |
| oscillate | fanremote2/oscillate.ir |
| fanspeedup | fanremote2/fanspeedup.ir |
| fanspeeddown | fanremote2/fanspeeddown.ir |
