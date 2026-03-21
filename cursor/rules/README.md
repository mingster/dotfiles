# Cursor rules (dotfiles)

This directory is synced from **`riben.life`** (`web/.cursor/rules/`) as the **standard** stack (Next.js, Prisma, Tailwind, Biome, etc.).

- After `install.sh`, **`~/.cursor/rules`** symlinks here for **global** Cursor rules.
- Re-sync from riben when you update project rules:

  ```bash
  rsync -a --delete ~/projects/riben.life/web/.cursor/rules/ ~/dotfiles/cursor/rules/
  ```

- Do not put secrets in `.mdc` files.
