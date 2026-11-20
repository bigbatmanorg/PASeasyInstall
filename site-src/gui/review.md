# 5 Review plan

![Step 5: the plan with servers, installers, dependencies and security deviations](../assets/screenshots/5-review.png)

Everything that will happen, in order, prepared **without contacting any server**.

- **Totals:** components, target servers and planned stages.
- **One row per instance:** server name, address, the installer file that will be used, the number of stages, and
  what it depends on (components depend on the Vault; CPM also on its PVWA).
- **Warnings:** every security deviation of the selected profile (`SECURITY DEVIATION: …`) and recipe notes.
- **Fix these before installing:** blocking issues such as missing media, invalid addresses, two servers with the
  same address but different accounts, or a missing EULA acceptance. Use **Back** or the step list to correct
  them, then **Re-check**.
- **Plan digest:** a fingerprint of exactly this plan, recorded with the run so you can tell later which plan was
  installed.
