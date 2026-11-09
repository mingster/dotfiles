# Pstack attribution

Vendored from [cursor/plugins](https://github.com/cursor/plugins/tree/6b0300214a09fd6029cfb7077043125758cd1fd2), pinned at `6b0300214a09fd6029cfb7077043125758cd1fd2`. `script/sync-pstack-template-skills.sh` copies these trees unchanged every week and records the sha in `script/.pstack-template-upstream`. No plugin install.

| Upstream | Author | In `templates/agent-team/` |
|----------|--------|----------------------------|
| `harness/pstack/claude-code` | Lauren Tan | `skills/*` in `.agents/skills/`, every other file under `.agents/` |
| `cursor-team-kit` | Cursor | `skills/*` in `.agents/skills/`, every other file under `vendor/cursor-team-kit/` |
| `dyl-stack/skills/principle-the-algorithm` | Dylan Gattey | `.agents/skills/principle-the-algorithm/` |

The vendored skill names are the `skills=` line of `script/.pstack-template-upstream`. Local files never sit inside a vendored directory. The Orca adaptation lives in `.agents/skills/orca-adapter/`.

## License

All three are MIT licensed.

Copyright (c) 2026 Lauren Tan
Copyright (c) 2026 Cursor
Copyright (c) 2026 Dylan Gattey

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
