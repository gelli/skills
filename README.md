# Claude Plugins

A [Claude Code plugin marketplace](https://code.claude.com/docs/en/plugin-marketplaces). Each plugin lives in its own directory under `plugins/` and is listed in `.claude-plugin/marketplace.json`.

## Install

Add the marketplace once, then install plugins from it:

```
/plugin marketplace add gelli/skills
/plugin install <plugin-name>@gelli-skills
```

Pull updates with `/plugin marketplace update gelli-skills`.

## Layout

```
.claude-plugin/marketplace.json   marketplace manifest
plugins/<name>/                   one directory per plugin
  .claude-plugin/plugin.json      plugin manifest (optional)
  skills/, commands/, agents/     plugin components
```

## Adding a plugin

1. Create `plugins/<name>/` with its components.
2. Append an entry to the `plugins` array in `.claude-plugin/marketplace.json`:

   ```json
   {
     "name": "<name>",
     "source": "./plugins/<name>",
     "description": "What it does"
   }
   ```

3. Validate and test before committing:

   ```
   claude plugin validate . --strict
   claude plugin validate ./plugins/<name> --strict
   sh plugins/<name>/tests/test-hooks.sh   # if the plugin ships hooks
   ```

## Local testing

Load a plugin straight from the working tree without installing it:

```
claude --plugin-dir ./plugins/<name>
```

## License

MIT. See [LICENSE](LICENSE).
