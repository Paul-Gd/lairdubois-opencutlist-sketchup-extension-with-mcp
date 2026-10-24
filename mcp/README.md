# OpenCutList MCP server

This folder contains the MCP server that lets AI tools such as Claude Code
view and edit OpenCutList parts in a running SketchUp model.

> AI agents and developers continuing this work: read
> [AI-README.md](AI-README.md) first. It documents the architecture, invariants,
> protocol, and known limitations.

```
Claude Code ──stdio MCP──▶ mcp/server.mjs ──loopback TCP──▶ Ruby bridge in SketchUp
```

The SketchUp side lives inside the OpenCutList extension. The bridge is off by
default and only listens on `127.0.0.1` with a per-run token.

## Requirements

- SketchUp with the OpenCutList RBZ built from this branch (it contains the MCP
  bridge code).
- Node.js 20 or newer (`node --version`).
- No global npm packages and no Python required.

## Setup

1. Build and install the OpenCutList RBZ, then restart SketchUp.
2. In SketchUp: **Extensions → OpenCutList → MCP Bridge → Start MCP Bridge**.
   The status item shows the port and discovery file.
3. Install the MCP server dependencies:

   ```bash
   cd mcp
   npm install
   ```

4. Configure Claude Code. The repository contains a project `.mcp.json`; open
   Claude Code in the repository and approve the `opencutlist` server when
   prompted. Alternatively:

   ```bash
   claude mcp add --transport stdio opencutlist -- node mcp/server.mjs
   ```

5. Check the connection with `/mcp` in Claude Code, then ask:
   “List the OpenCutList parts.”

SketchUp must stay open while Claude Code uses the tools. Stop the bridge from
the same menu when you are done.

## Tools

All lengths are in **millimetres**. `part_id` values are only valid for the
current model state: after any create/update/resize/move/delete, use the
returned id or call `ocl_list_parts` again.

| Tool | Type | Purpose |
|---|---|---|
| `ocl_get_model_info` | read | Model name, path, units, part counts, selection |
| `ocl_list_parts` | read | List parts with dimensions, material, tags, count |
| `ocl_get_part` | read | Full details for one part |
| `ocl_get_cutlist` | read | Cutlist grouped by material |
| `ocl_list_materials` | read | Materials, types, thickness |
| `ocl_create_part` | write | Create rectangular part(s) |
| `ocl_update_part` | write | Rename, tags, material, edge banding, veneers |
| `ocl_resize_part` | write | Set absolute dimensions |
| `ocl_move_part` | write | Translate all instances |
| `ocl_select_parts` | write | Select parts in SketchUp |
| `ocl_delete_part` | destructive | Delete all instances (requires `confirm: true`) |
| `ocl_create_material` | write | Create a material, including edge/veneer types |

### Example prompts

- “List the OpenCutList parts.”
- “Create a 600 × 400 × 18 mm oak shelf at 0,0,0.”
- “Create an edge material called Oak edge, 2 mm, type edge.”
- “Give the shelf a 2 mm edge on ymin and ymax.”
- “Resize the shelf to 800 × 400 × 18.”
- “Move it 100 mm up and select it.”
- “Delete it.” (Claude Code asks for confirmation; the bridge also requires
  `confirm: true`.)

## Discovery and security

When started, the bridge writes:

```
~/.ocl-mcp/bridge.json   (mode 0600)
```

containing the ephemeral port and a random token. The MCP server reads this
file for each new connection, so restarting the bridge needs no config change.
The file is deleted when the bridge stops or SketchUp quits.

Security properties:

- Loopback only (`127.0.0.1`).
- Random per-run token on every request.
- No arbitrary Ruby evaluation; only the curated `mcp_*` commands are exposed.
- Delete requires an explicit `confirm: true`.

## Troubleshooting

**“OpenCutList MCP Bridge is not running”**
Start it from **Extensions → OpenCutList → MCP Bridge → Start MCP Bridge**.
Check that `~/.ocl-mcp/bridge.json` exists.

**“Bridge is not reachable”**
The discovery file is stale or the bridge stopped. Stop and start the bridge.

**“SketchUp did not answer …”**
SketchUp is busy, a modal dialog is open, or the command is long (cutlist
generation). Close the dialog and retry. A mutation may still have committed
after a timeout — call `ocl_list_parts` instead of blindly retrying.

**Claude Code cannot spawn `node`**
Claude Code may not inherit your nvm PATH. Use an absolute path in `.mcp.json`:

```json
"command": "/Users/you/.nvm/versions/node/v24.12.0/bin/node"
```

**Parts are missing from the list**
The bridge scans the whole model (`scope: :model`), independent of the current
SketchUp edit context. If the part is hidden, on a hidden tag, or not a
recognized component/group, OpenCutList will not include it.

## Development

Run the server directly:

```bash
npm start
```

Use the MCP Inspector against the stdio server:

```bash
npm run inspect
```

Plain protocol smoke test (from the repository root), with the bridge running:

```bash
PORT=$(jq -r .port ~/.ocl-mcp/bridge.json)
TOKEN=$(jq -r .token ~/.ocl-mcp/bridge.json)
printf '{"id":1,"token":"%s","method":"mcp_ping"}\n' "$TOKEN" | nc -w 2 127.0.0.1 "$PORT"
printf '{"id":2,"token":"%s","method":"mcp_parts_list","params":{}}\n' "$TOKEN" | nc -w 2 127.0.0.1 "$PORT"
```

The bridge protocol is newline-delimited JSON. Requests must use the exact
registered command name (`mcp_*`).
