---
paths:
  - ".agents/skills/**"
  - ".claude/skills/**"
---

# Vendored skills

These are upstream files, refreshed weekly by `.github/workflows/update-skills.yaml`
and pinned in `skills-lock.json`. Anything edited here is overwritten on the next
run, silently.

To change a skill's behavior, change it upstream in the source package. To add a
repo-specific skill, create a new directory. Absent from `skills-lock.json`, the
updater leaves it alone.
