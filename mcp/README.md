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
| `ocl_create_group` | write | Group parts into a SketchUp group |
| `ocl_solid_operation` | write | Boolean solid union/subtract/intersect/trim/split |
| `ocl_set_parts_visibility` | write | Hide or show parts |
| `ocl_screenshot` | read | PNG of the viewport, optionally isolated to chosen parts |
| `ocl_delete_part` | destructive | Delete all instances (requires `confirm: true`) |
| `ocl_create_material` | write | Create a material, including edge/veneer types |
| `ocl_update_material` | write | Change colour, type, thickness, display name, etc. |
| `ocl_delete_material` | destructive | Delete an unused material (force optional) |

### Coordinates

All coordinates are **world-space millimetres**. Every part summary and detail
includes:

- `bounds_mm`: `{ "min": [x, y, z], "max": [x, y, z] }` — axis-aligned world
  bounds, unioned over all instances of the part.
- `instances[]`: one entry per placed instance, with:
  - `position_mm` — the instance origin in world space (not the bbox min),
  - `bounds_mm` — that instance's world bounds,
  - `transformation` — the 16-number SketchUp transformation matrix,
  - `path`, `serialized_path`, `entity_id`, `layer`, `flipped`, `visible`,
  - `edge_roles` / `face_roles` — for each `xmin/xmax/ymin/ymax/zmin/zmax`, the
    definition-local axis and sign, the normalized world normal and a world
    label (`front` = -Y, `back` = +Y, `left` = -X, `right` = +X, `top` = +Z,
    `bottom` = -Z).

A part with several copies has several entries in `instances`; there is no
single part-level point. `ocl_create_part`'s `position_mm` is interpreted in the
container's coordinate system (model root by default); the returned instances
give the resulting world coordinates.

#### Rotation and position semantics

`position_mm` is the transformed **local origin**, not the min corner of the
world bounding box. Rotations compose as `T(position) * Rx * Ry * Rz`, so the
local axes map to world directions as follows:

| `rotation_deg` | local length (X) | local width (Y) | local thickness (Z) |
|---|---|---|---|
| `[0, 0, 0]` | world +X | world +Y | world +Z |
| `[0, 90, 0]` | world -Z (extends downward) | world +Y | world +X |
| `[90, 0, 0]` | world +X | world +Z | world -Y |
| `[0, -90, 0]` | world +Z (extends upward) | world +Y | world -X |

To stand a 1760 mm panel on the floor with `[0, 90, 0]`, pass
`position_mm: [x, y, 1760]`; with `[0, -90, 0]`, use `z = 0`. Always confirm
with the returned `bounds_mm`.

#### Shared definitions and cutlist merging

`ocl_create_part` defaults to `reuse_definition: true`. When a definition with
the same **name** and the same **local length × width × thickness** (within
0.5 mm) already exists, a new instance is added to that definition instead of
creating another one. OpenCutList then reports a single cutlist line with the
merged `count`. Set `reuse_definition: false` to force a new definition.

- `count` copies are offset by `spacing_mm` along `count_axis`
  (`x`, `y` or `z`, default `x`). Three shelves on Z:
  `count: 3, count_axis: "z", spacing_mm: 300`.
- Reusing a definition also works across separate calls: create the same
  name/dimensions at different `position_mm` values.
- Tags and `orientation_locked_on_axis` are definition-level properties. A
  reused definition keeps its existing values; a differing requested tag set is
  returned as a warning. Use `ocl_update_part` to change them (it affects every
  instance of the definition).
- If the name exists but the local dimensions differ, a new uniquely named
  definition is created and the response warns.
- Material is per instance. OCL groups by material, so identical geometry with
  different instance materials still produces separate cutlist lines.

#### Groups and cylinders

- `ocl_create_group(name, part_ids)` groups sibling parts into a SketchUp
  group. All parts must be in the same container (model root or the same
  group); parts in different containers must be moved first. OpenCutList
  traverses groups as containers, so the cutlist is unchanged and the group
  itself is not counted. The response returns the group entity id/guid, name,
  member entity ids and world bounds. Groups organize the model/outliner; OCL
  cutlists still group by material, not by SketchUp group.
- `ocl_create_part` accepts `shape: "cylinder"` with `length_mm` along the
  definition-local **X** axis (OCL's default length axis) and `diameter_mm`.
  The cylinder origin is the centre of its base circle, so `position_mm` is
  that point and the cylinder extends along world +X with the default rotation.
  Use `rotation_deg` to orient it (e.g. `[0, -90, 0]` stands it vertically).
  `width_mm`/`thickness_mm` are ignored for cylinders. Edge banding and veneers
  are box-oriented and not meaningful on a cylinder.

#### Solid operations

`ocl_solid_operation` runs the same Meshy-based boolean engine as
OpenCutList's Smart tools. Operands must be **manifold solids in the same
container** (model root or the same group). They are ordered: the first is the
target, the rest are tools.

| `operation` | Result | Tools |
|---|---|---|
| `union` | all operands merged into one solid | consumed |
| `outer_shell` | alias of `union`; the union already removes interior faces | consumed |
| `subtract` | first operand minus every tool | consumed |
| `intersect` | volume common to the first operand and all tools | consumed |
| `trim` | first operand minus every tool | **kept** |
| `split` | exactly two operands → target-minus-tool, tool-minus-target, intersection | replaced |

- Pass `part_ids` only when every part has **one instance**. If a part has
  several copies, pass explicit `entity_ids` from
  `ocl_get_part` → `instances[].entity_id`; otherwise the call fails with
  `ambiguous_part_instances` instead of guessing.
- The result keeps the target's name, material, layer, tags, description,
  price and other OCL definition attributes. `name` overrides the result name.
  Split pieces are named `"<source> (target minus tool)"`,
  `"<source> (tool minus target)"` and `"<source> (intersection)"`.
- If the target definition is still displayed by instances that were not part
  of the operation, those instances keep the original name and the result is
  named `"<name> (solid)"`; SketchUp cannot give two definitions the same name.
  Source definitions left with no instance are removed.
- Materials on surviving faces are preserved, including edge banding on
  sheet-good parts (OCL only detects edge banding when the body material is
  sheet good). Newly created cut faces have no edge banding or veneer; apply it
  afterwards with `ocl_update_part`.
- For `trim`, the response includes `kept_part_ids` with both the rebuilt target
  and the kept tools.
- One call is one SketchUp undo step. The response returns fresh
  `result_part_ids` (one part, several parts if the union has disjoint lumps,
  or up to three for `split`). An empty piece (for example an empty
  intersection) is reported with `empty: true` and creates no part.
- Parts with locked instances, non-manifold geometry (open edges, no volume)
  or unsupported geometry fail with OpenCutList's own validation message and
  leave the model unchanged.
- Union/outer shell of disjoint solids may produce several result parts rather
  than one container; the response lists all of them.

#### Material semantics

- `ocl_create_part` creates a missing material automatically and reports it in
  `warnings`; set `create_material_if_missing: false` to fail instead.
- `ocl_update_material` patches only the supplied fields. `display_name` renames
  the material (SketchUp may uniquify it).
- `ocl_delete_material` refuses materials used by OpenCutList parts unless
  `force: true`.
- `thickness_mm` is only meaningful for `edge` / `veneer` materials; for sheet
  goods and solid wood, OpenCutList uses the type's app-default thickness.
- `type_name` is normalized to `unknown` (OCL's historical spelling is
  `unknow`).

#### Edge banding keys

`edge_materials` keys (`ymin`, `ymax`, `xmin`, `xmax`) index the part's
**definition-local oriented axes**, not world directions. Which physical edge
that is depends on `rotation_deg`; read `instances[].edge_roles` to get the
world label and normal for each key. `edge_material_colors` in the raw
OpenCutList data is a display colour (near-white edge materials are darkened so
they stay visible); `ocl_get_part` also returns
`edge_material_raw_colors` / `face_material_raw_colors`.

`ocl_resize_part` returns a fresh `part_id`, like `ocl_update_part`; use the
returned id for later calls.

### Screenshots and visibility

- `ocl_screenshot` returns a PNG image block of the current viewport. Pass
  `part_ids` with `isolate: true` to show only those parts: everything else is
  temporarily hidden (including siblings inside groups), the image is captured,
  then visibility and camera are restored. The temporary changes are aborted, so
  they do not appear on the undo stack. Without `isolate`, the whole visible
  model is captured. Default size is 1200×800; dimensions are capped at 4000.
- **Camera presets:** `view: front | back | left | right | top | bottom | iso`.
  Directions are in SketchUp world axes: front looks along +Y from the -Y side,
  back from +Y, left from -X, right from +X, top from +Z (up = +Y), bottom from
  -Z (up = -Y), iso from front-right-top. With `part_ids`, the camera targets
  those parts; otherwise the whole model.
- **Explicit camera:** `camera: { eye_mm: [x,y,z], target_mm: [x,y,z], up?: [x,y,z] }`
  (world millimetres, `up` defaults to +Z unless the view direction is vertical).
  Do not combine `camera` with `view`.
- **Projection:** `perspective: true|false` (defaults to the current camera) and
  `fov` (1–120°, perspective cameras). Orthographic presets set their height
  automatically.
- `zoom_extents` defaults to false when `view`/`camera` is supplied (use the
  requested camera as-is) and true otherwise; set it to true to frame the target
  after applying the camera.
- The response metadata includes the final `camera` (eye/target/up in mm,
  perspective, fov or orthographic height), so the caller can verify the view.
- Screenshots use the current SketchUp style/background and are written under
  the OpenCutList temp directory (`mcp_screenshots/`). The newest 20 are kept.
- `ocl_set_parts_visibility` hides or shows parts as a normal undoable change.
  **Hidden parts are excluded from OpenCutList cutlists**, so a hidden part can
  only be shown again with the `entity_ids` returned by the hide call.

### Example prompts

- “List the OpenCutList parts.”
- “Create a 600 × 400 × 18 mm oak shelf at 0,0,0.”
- “Create three identical 360 × 545 × 18 shelves, 300 mm apart in Z.”
- “Create a 756 mm long, 25 mm diameter rail at the top of the wardrobe.”
- “Group the two side panels and the shelf under ‘Carcass’.”
- “Union these two intersecting rails into one part.”
- “Subtract the mortise block from the leg and keep the block.”
- “Trim the shelf against the side panel.”
- “Split the panel where it meets the rail and list the three pieces.”
- “Create an edge material called Oak edge, 2 mm, type edge.”
- “Give the shelf a 2 mm edge on ymin and ymax.”
- “Resize the shelf to 800 × 400 × 18.”
- “Show me the front elevation of the shelf, isolated.”
- “Take a top view of the wardrobe.”
- “Screenshot from eye [2000,-2000,1500] looking at the carcass centre.”
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
