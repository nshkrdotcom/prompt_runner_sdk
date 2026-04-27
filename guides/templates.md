# Templates

Prompt Runner 0.7.0 uses template-based prompt scaffolding.

Templates are markdown files with YAML front matter. They define:

- prompt metadata defaults
- authoring sections in the prompt body
- placeholder markers that `packet doctor` can detect until you replace them

## Where Templates Live

Home-scoped templates:

```text
~/.config/prompt_runner/templates/
  default.prompt.md
  from-adr.prompt.md
```

Packet-local templates:

```text
demo/
  templates/
    from-adr.prompt.md
```

Resolution order when you create a prompt:

1. `prompt new --template ...`
2. packet `prompt_template`
3. home templates
4. built-in default template

Packet-local templates override home templates with the same name.

## Initialize The Template Store

```bash
mix prompt_runner init
mix prompt_runner template list
```

`init` creates editable home templates if they do not already exist.

## Use A Template

Set a packet-wide default:

```bash
mix prompt_runner packet new demo \
  --prompt-template from-adr
```

Or choose a template for one prompt:

```bash
mix prompt_runner prompt new 01 \
  --packet demo \
  --phase 1 \
  --name "Capture runtime boundaries" \
  --targets app \
  --commit "docs: add runtime boundaries summary" \
  --template from-adr
```

You can also point directly at a file:

```bash
mix prompt_runner prompt new 02 \
  --packet demo \
  --phase 1 \
  --name "Review contracts" \
  --template /path/to/custom.prompt.md
```

## Template Format

Example:

```markdown
---
references: []
required_reading: []
context_files: []
depends_on: []
verify:
  files_exist: []
  contains: []
  changed_paths_only: []
---
# {{name}}

## Required Reading

<!-- prompt_runner:placeholder required_reading -->
- Add ADRs and design docs here.

## Mission

<!-- prompt_runner:placeholder mission -->
Describe the exact work to perform.
```

Prompt Runner merges generated prompt attributes such as `id`, `phase`,
`targets`, and `commit` into the template front matter.

Supported body placeholders:

- `{{id}}`
- `{{phase}}`
- `{{name}}`
- `{{commit}}`
- `{{targets_csv}}`
- `{{targets_bullets}}`

## Placeholder Markers

The marker:

```html
<!-- prompt_runner:placeholder ... -->
```

is intentional.

`mix prompt_runner packet doctor` flags prompts that still contain placeholder
markers so incomplete scaffolds are loud before you run the packet.

`mix prompt_runner packet preflight` is the separate runtime readiness check.
Run setup first when a packet creates local repos or workspaces, then run
preflight before provider execution.

## Recommended Practice

- use home templates for personal defaults
- use packet-local templates when a packet needs a shared authoring shape
- keep `verify:` skeletons in the template
- replace placeholder markers before running real work
