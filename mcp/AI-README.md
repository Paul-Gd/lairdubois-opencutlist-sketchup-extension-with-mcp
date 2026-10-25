# AI implementation notes — OpenCutList MCP bridge

Audience: AI agents and developers continuing this work.
Verified on 2026-10-25 with SketchUp Pro 2023 (embedded Ruby 2.7.2), OpenCutList
8.0.0, macOS, Node.js 24.

This document explains **what was built, why it is shaped this way, and which
invariants must not be broken**. Read it before changing the bridge.

## What was built

A loopback MCP bridge that lets AI tools view and edit OpenCutList parts in a
running SketchUp model.

```
Claude Code / any MCP client
   │  MCP over stdio (JSON-RPC)
   ▼
mcp/server.mjs  (Node 20+, @modelcontextprotocol/server 2.x, zod 4)
   │  newline-delimited JSON over 127.0.0.1:<ephemeral port>
   │  token from ~/.ocl-mcp/bridge.json (mode 0600)
   ▼
Ruby bridge inside the OpenCutList extension
   │  timer-pumped non-blocking TCP on SketchUp's main thread
   │  PLUGIN.execute_command / direct OCL workers
   ▼
OpenCutList model + workers → SketchUp model
```

The bridge is **off by default**. The user starts it from
**Extensions → OpenCutList → MCP Bridge → Start MCP Bridge**.

## Why this architecture

- OpenCutList already has a generic command dispatcher
  (`PLUGIN.register_command` / `PLUGIN.execute_command`, `plugin.rb:934-944`).
  Reusing it means MCP operations behave like the UI instead of duplicating
  model logic.
- SketchUp's Ruby API is main-thread only. OCL's own `LocalHttpServer`
  (`ruby/server/local_http_server.rb`) proves that a non-blocking `TCPServer`
  pumped by a self-rescheduling `UI.start_timer` is safe. The bridge follows
  that pattern and uses **no Ruby threads**.
- MCP protocol work is delegated to the official SDK. The Node server is a thin,
  debuggable adapter; the Ruby side only speaks a small newline-JSON protocol.
- A separate stdio MCP server is more robust than implementing MCP Streamable
  HTTP inside SketchUp's Ruby 2.7 runtime.

## Files and responsibilities

| Path | Responsibility |
|---|---|
| `src/ladb_opencutlist/ruby/mcp/mcp_bridge_server.rb` | TCP listener, discovery file, token auth, newline JSON framing, non-blocking pump, start/stop |
| `src/ladb_opencutlist/ruby/mcp/mcp_controller.rb` | Registers `mcp_*` commands; parts/materials/cutlist handlers; undo wrapping |
| `src/ladb_opencutlist/ruby/mcp/mcp_part_helper.rb` | Box/cylinder creation, face-role mapping, resize/move/erase helpers, solid DrawingDef/attribute copying, mm helpers |
| `src/ladb_opencutlist/ruby/mcp/mcp_error.rb` | `McpError(code, message)` for structured bridge errors |
| `src/ladb_opencutlist/ruby/plugin.rb` | Requires/pushes `McpController`; adds the MCP Bridge menu; stops the bridge |
| `src/ladb_opencutlist/ruby/observer/app_observer.rb` | Stops the bridge on SketchUp quit |
| `src/ladb_opencutlist/ruby/worker/cutlist/cutlist_generate_worker.rb` | Added `ignore_selection` and `scope: :model` (UI defaults unchanged) |
| `src/ladb_opencutlist/ruby/worker/cutlist/cutlist_part_update_worker.rb` | Added `transparent_operation` (UI default unchanged; MCP passes false) |
| `src/ladb_opencutlist/ruby/worker/materials/materials_create_worker.rb` | Same `transparent_operation` option |
| `mcp/server.mjs` | MCP tool registration, schemas, descriptions, error results |
| `mcp/bridge-client.mjs` | Discovery-file reader, TCP client, request serialization, timeouts, reconnects |
| `mcp/README.md` | User-facing setup and tool documentation |
| `.mcp.json` | Project-scoped Claude Code configuration |

## Wire protocol

Discovery file: `~/.ocl-mcp/bridge.json`, written with mode `0600` in a `0700`
directory, deleted on stop/quit.

```json
{ "port": 50028, "token": "<64 hex chars>", "pid": 1234,
  "version": "8.0.0", "model": "...", "started_at": "..." }
```

Framing: one UTF-8 JSON object per line (`\n`), max 8 MB per line.

Request:

```json
{ "id": 1, "token": "...", "method": "mcp_parts_list", "params": {} }
```

Response:

```json
{ "id": 1, "ok": true, "result": { } }
{ "id": 1, "ok": false, "error": { "code": "part_not_found", "message": "..." } }
```

`method` must be an exact registered `mcp_*` command. Unknown methods return
`unknown_method`; a wrong token returns `auth_failed` and closes the connection.
The Node client serializes calls (one in flight) because SketchUp's model state
is single-threaded.

## Tool → bridge command map

| MCP tool | Bridge method | Type |
|---|---|---|
| `ocl_get_model_info` | `mcp_model_info` | read |
| `ocl_list_parts` | `mcp_parts_list` | read |
| `ocl_get_part` | `mcp_part_get` | read |
| `ocl_get_cutlist` | `mcp_cutlist_get` | read |
| `ocl_list_materials` | `mcp_materials_list` | read |
| `ocl_create_part` | `mcp_part_create` | write |
| `ocl_update_part` | `mcp_part_update` | write |
| `ocl_resize_part` | `mcp_part_resize` | write |
| `ocl_move_part` | `mcp_part_move` | write |
| `ocl_delete_part` | `mcp_part_delete` | destructive |
| `ocl_select_parts` | `mcp_parts_select` | write (selection) |
| `ocl_create_group` | `mcp_create_group` | write (grouping) |
| `ocl_solid_operation` | `mcp_solid_operation` | write (boolean solid) |
| `ocl_set_parts_visibility` | `mcp_parts_visibility` | write (hide/show) |
| `ocl_screenshot` | `mcp_screenshot` | view capture |
| `ocl_create_material` | `mcp_material_create` | write |
| `ocl_update_material` | `mcp_material_update` | write |
| `ocl_delete_material` | `mcp_material_delete` | destructive |

Bridge lifecycle commands (`mcp_bridge_start`, `mcp_bridge_stop`,
`mcp_bridge_status`) and `mcp_ping` exist but are normally invoked from the
SketchUp menu or a manual smoke test, not from the MCP client.

## Critical invariants

1. **Main thread only.** Never call SketchUp APIs from a Ruby thread. The bridge
   is pumped by `UI.start_timer`; keep it that way.
2. **No transparent operations from MCP.** The UI workers default to
   `transparent_operation: true` so they merge into a UI-triggered operation.
   MCP passes `false`; otherwise an AI call could merge into the user's previous
   undo step (or a transparent operation could chain unpredictably).
   MCP-created geometry uses its own `start_operation` and aborts on failure.
3. **Model-scope cutlists.** `_cutlist` passes `scope: :model`,
   `ignore_selection: true`, empty name/tag/material filters, and the user's
   `cutlist_options` preset. This makes MCP see the whole model, not the current
   selection, while still matching the UI's dimension/grouping settings.
   The UI's defaults are unchanged.
4. **Part IDs are not stable.** `Part#id` is an MD5 of definition UUID, name,
   dimensions, etc. It changes after rename/resize/material/group changes.
   After a mutation, re-find the part by `entity_ids` and return the new ID.
   Tool descriptions tell the model to use the returned ID or re-list.
5. **Feed the update worker a JSON-round-tripped hash.** The UI sends
   `part.to_hash` through JSON, which turns nested symbol keys into strings.
   `CutlistPartUpdateWorker` indexes with string keys (`'ymin'`, `'virtual'`,
   ...). The controller does `JSON.parse(JSON.generate(part.to_hash))` for this
   reason. Do not pass the raw Ruby hash.
6. **Edge/face roles are geometric.** A newly created box has no
   `edge_entity_ids` until OpenCutList detects edge materials. The controller
   computes face entity IDs by comparing each definition face normal against
   the part's oriented axes (`size.axes`): `xmin/xmax` are the length-axis
   faces, `ymin/ymax` the width-axis faces, `zmin/zmax` the thickness-axis
   faces. These IDs are merged into `edge_entity_ids` / `face_entity_ids` so
   the update worker can apply edge/veneer materials in one pass.
7. **Face orientation matters.** `Sketchup::Face#pushpull` always returns `nil`,
   so it cannot be used as a success check. Creation verifies
   `definition.bounds.depth`. The face is reversed unless its normal points up
   (the same guard Smart Draw uses), and a bounds fallback lifts geometry above
   z=0 if SketchUp's orientation heuristic produced a downward solid.
8. **Units.** MCP inputs/outputs are millimetres; SketchUp stores inches
   internally. Use `.mm` to build lengths and `.to_mm.to_f` to read them.
9. **Creation scope.** New parts go to `model.entities` (model root), not the
   active edit context, so they cannot accidentally modify a shared component
   definition. `container_id` is allowed only for `Sketchup::Group`.
10. **Materials.** `MaterialAttributes.fetch_or_create_material` never changes
    an existing material's type. New materials default to unknown unless
    `material_type` is supplied. Edge/face materials must already exist with
    `TYPE_EDGE` / `TYPE_VENEER`; the controller validates this. OCL ignores
    `thickness_mm` for sheet-good/solid-wood materials (their thickness comes
    from app defaults); it is meaningful for edge/veneer materials.
11. **Destructive operations.** Delete requires `confirm: true` and is one
    SketchUp undo step. Virtual edge/veneer parts cannot be deleted, resized or
    moved directly; operate on the real part.
12. **Selection limits.** `model.selection` can only hold entities in the
    current drawing context. `mcp_parts_select` selects root-level parts and
    returns a warning for parts nested in closed groups.
13. **World coordinates.** `_part_summary` includes `bounds_mm` (union of all
    instance world bounds) and `instances[]`. Each instance uses
    `InstanceInfo#transformation`, which is
    `PathUtils.get_transformation(path)` (the full path transformation, not a
    local one), so nested parts report true world coordinates.
    `position_mm` is the instance origin, **not** the bounding-box minimum;
    `bounds_mm` is the world AABB; `transformation` is the 16-number SketchUp
    matrix. A part with several instances has no single position — callers must
    use the `instances` array. `ocl_move_part` returns the same per-instance
    data after the move.
14. **Screenshots are temporary visibility changes.** `mcp_screenshot` calls
    `View#write_image` (returns a Boolean). With `isolate`, it walks each
    target instance path and hides every sibling at every parent collection,
    keeps the ancestors/targets visible, captures, then restores visibility and
    the camera in an `ensure`. The visibility changes are wrapped in a normal
    operation that is **aborted**, so they never enter the undo stack. Target
    parts must already be visible; a hidden target is not unhidden. Locked
    entities may reject visibility changes. The PNG is written under
    `PLUGIN.temp_dir/mcp_screenshots/` (newest 20 kept); the Node server reads
    that file and returns it as an MCP image block.
    Camera control: `_mcp_apply_camera` supports `view` presets
    (`front/back/left/right/top/bottom/iso`, world axes; front = eye on -Y
    looking +Y; top up = +Y; bottom up = -Y; iso = front-right-top) and an
    explicit `camera: { eye_mm, target_mm, up? }`. `perspective` keeps the
    current projection unless supplied; `fov` is 1–120. Presets frame the
    `target_bounds` (union of target part bounds, or `model.bounds`) using a
    bounding-sphere distance; orthographic presets also set `camera.height`.
    Explicit cameras are used as-is. `zoom_extents` defaults to false when
    view/camera is given and true otherwise; when true it frames
    `target_entities` via `view.zoom` if parts were supplied, else
    `view.zoom_extents`. The applied camera is returned as metadata
    (`eye_mm`, `target_mm`, `up`, `perspective`, `fov`/`height_mm`).
15. **Hiding is a real model change.** `mcp_parts_visibility` commits an
    undoable operation. Hidden parts are excluded from OpenCutList cutlists, so
    a hidden part cannot be found by `part_id`; the hide response returns
    `entity_ids`, which the show call accepts instead. Hiding a part nested in
    a shared component definition affects every instance of that definition.
16. **Hardware bounds are a special case.** For hardware materials,
    `cutlist_generate_worker.rb:1157` stores parent/world-space `entity.bounds`
    in `InstanceInfo#definition_bounds`; normal parts store definition-local
    bounds. Never transform `definition_bounds` directly in MCP code. Prefer
    `instance_info.definition.bounds`, which is always definition-local, and
    fall back to `definition_bounds` only when the definition is nil
    (`_mcp_instance_world_info`, `_mcp_part_world_bounds_mm`).
17. **Materials are patchable.** `MaterialsUpdateWorker` writes every
    attribute, so `material_update_command` first builds the full current
    attribute hash and then overlays the patch. `transparent_operation: false`
    gives the MCP call its own undo step. Deletion is wrapped in an operation in
    the controller and refuses in-use materials unless `force: true`.
18. **MCP type names are normalized.** OCL's `type_strippedname` returns the
    historical `unknow`; the controller maps it to `unknown` in every response
    (`_material_type_name`). Inputs already accept both spellings.
19. **Edge roles are exposed per instance.** `_mcp_role_world_info` transforms
    each oriented definition axis by the instance's full path transformation
    and labels the dominant world direction (`front` = -Y, `back` = +Y,
    `left` = -X, `right` = +X, `top` = +Z, `bottom` = -Z). Use
    `instances[].edge_roles` / `face_roles` instead of assuming `ymin` is the
    front edge; `edge_material_colors` is a display colour, while
    `edge_material_raw_colors` / `face_material_raw_colors` are the real
    material colours.
20. **Zero move is allowed.** `ocl_move_part` with a zero offset performs no
    operation but returns the current world bounds and instance positions; it is
    the cheapest "where is this part?" query.
21. **Definitions are reused by default.** `_mcp_prepare_definition`
    matches an existing definition by name and expected local dimensions
    (tolerance 0.5 mm: box = L×W×T, cylinder = diameter×diameter×length). A
    match reuses it, so `PartDef.generate_part_id` (which includes the
    definition UUID) produces the same OCL part and the instances merge into one
    cutlist line. On reuse, only the OCL UUID is ensured; tags and orientation
    flags are definition-level and intentionally preserved (a differing
    requested tag set is warned). A name match with different dimensions creates
    a uniquely named definition and warns. Material is per instance, so OCL
    still splits by material. `count_axis` offsets copies along world X/Y/Z
    (default X).
22. **Solid operations reuse OCL's Meshy workers.** `mcp_solid_operation`
    builds one `DrawingDef` per operand with
    `CommonDrawingDecompositionWorker` (`flatten: false`,
    `CONTAINER_VALIDATOR_PART_WITHOUT_MACHININGS`, the same parameters as
    `SmartActionHandlerSolidBooleanHelper`), then calls
    `CommonSolidBooleanApplyWorker` with `wrap_operation: false` inside the
    controller's own undo operation. Never call the raw SketchUp
    `Group#union/#subtract/...` methods here: they lose OCL attributes and do
    not handle shared definitions, nested containers or glued machinings.
    Operands are individual **instances**; `part_ids` is accepted only when a
    part has exactly one instance, otherwise `entity_ids` is required. All
    operands must share a parent container. The first operand is the target.
    `trim` is subtraction with `keep_cuts: true`; `outer_shell` is an alias of
    union (Meshy's union is already a manifold outer shell). `split` computes
    target−tool, tool−target and intersection with
    `CommonSolidBooleanWorker` **before** touching the model, then applies each
    with `keep_srcs: true, keep_cuts: true, result_def: <precomputed>` and
    erases both sources at the end. `created_entities` identifies the result
    containers; parts are re-found from a fresh cutlist. A made-unique definition
    inherits a **copy** of the source OCL definition attributes, including its
    UUID; `_mcp_copy_definition_attributes` therefore copies the
    DefinitionAttributes plus SketchUp's `definition.description` and assigns
    a fresh UUID (two definitions sharing a UUID are one OCL part). Split
    results get attributes from their source piece and are renamed with a role
    suffix. The target's material/layer is restored on the result.
    **Result naming:** OCL takes component part names from the definition
    name. Before a non-split boolean, `_mcp_free_solid_result_name` renames the
    target definition to a temporary unique name (`Shelf [MCP solid 123]`), so
    the worker's clone/rebuild can take the original name without SketchUp
    appending `#1`. After the operation, `_mcp_prepare_solid_result_identity`
    either restores the source name (it still has non-operand instances; the
    result becomes `Shelf (solid)`) or the unused source definition is removed
    (the result takes `Shelf`). Everything happens inside the same undo
    operation. Renaming *after* removing the source but still inside the
    operation is not enough: SketchUp keeps the removed definition's name
    reserved until the operation commits. `trim` also returns
    `kept_part_ids` for the rebuilt target and the kept tools.
23. **Groups are containers; cylinders are X-oriented.** `mcp_create_group`
    uses `Entities#add_group(entities)` on siblings. All member entities must
    share the same parent collection (same model root or same group); OCL
    traverses the resulting `Sketchup::Group` as a container and does not count
    it, so the cutlist is unchanged. Group names are set on both the instance
    and its definition. Cylinders are created with `add_circle` + `add_face` +
    `pushpull` along local X (OCL's default length axis), origin at the
    base-circle centre; `shape: "cylinder"` requires `diameter_mm`, ignores
    width/thickness, and reuses definitions by length/diameter/diameter. Edge
    and veneer banding remains box-oriented and is not meaningful on cylinders.

## What changed in the existing OpenCutList code

- `plugin.rb`: requires and instantiates `McpController`, adds the MCP Bridge
  submenu, adds `stop_mcp_bridge`.
- `app_observer.rb`: stops the bridge in `onQuit`.
- `cutlist_generate_worker.rb`: optional `ignore_selection` / `scope`.
- `cutlist_part_update_worker.rb`, `materials_create_worker.rb`,
  `materials_update_worker.rb`: optional `transparent_operation` (defaults
  preserve UI behavior).
- `dist/` and generated version constants were refreshed by `gulp build`.

No existing UI route or default behavior was changed.

## Build, install, test

```bash
# Ruby/RBZ (existing npm deps in build/ are enough)
cd build && ./node_modules/.bin/gulp build
# install dist/ladb_opencutlist.rbz via SketchUp Extension Manager, restart

# Node MCP server
cd mcp && npm install
node --check server.mjs
```

Manual protocol smoke test with the bridge running:

```bash
PORT=$(jq -r .port ~/.ocl-mcp/bridge.json)
TOKEN=$(jq -r .token ~/.ocl-mcp/bridge.json)
printf '{"id":1,"token":"%s","method":"mcp_ping"}\n' "$TOKEN" | nc -w 2 127.0.0.1 "$PORT"
printf '{"id":2,"token":"%s","method":"mcp_parts_list","params":{}}\n' "$TOKEN" | nc -w 2 127.0.0.1 "$PORT"
```

MCP Inspector:

```bash
cd mcp && npm run inspect
```

Live test sequence used on 2026-10-25 (all passed): create sheet + edge
materials, create a 600×400×18 mm part, rename/tag/reassign material, apply
2 mm edge banding on ymin/ymax (`edge_count: 2`, pattern `1010`), resize to
800×400×18, move +100 mm (world bounds z=100–118), select, delete, list → 0
parts. Part summaries/detail return world `bounds_mm` and per-instance
`position_mm` / `transformation`.

World-coordinate and visual tests (same session):

- Two 600×400×18 parts created at `[0,0,0]` and `[1000,0,0]` reported
  `bounds_mm` 0–600 and 1000–1600, positions `[0,0,0]` and `[1000,0,0]`, and
  correct identity/translation matrices.
- `mcp_screenshot` with `isolate` produced an 800×600 PNG containing only the
  target part (2 sibling entities hidden), then restored visibility/camera.
- `mcp_parts_visibility` hid the second part (cutlist went 2 → 1) and showing it
  again via the returned `entity_ids` restored both parts (1 → 2).

Feedback regression tests (2026-10-25, feedback round 1):

- Hardware rail 756×25×25 at `[18,265,1630]`: `bounds_mm` is
  `[18,265,1630]..[774,290,1655]` at creation and after `ocl_update_part` (no
  double translation). `edge_roles` are correct.
- `ocl_update_material` changed colour/description/type and preserved the name;
  `ocl_delete_material` deleted an unused material, refused an in-use one, and
  succeeded after the part was deleted.
- Auto-created material warning reported type `unknown` and colour; a raw
  bridge call with `create_material_if_missing: false` returned
  `material_not_found` and created nothing.
- Zero-offset `ocl_move_part` returned the current bounds/positions without an
  undo step.
- Rotated part `[0,90,0]`: bounds `z=-600..0`, `xmin` label `top`, `xmax`
  `bottom`, `zmin` `left`, `zmax` `right` — matching the documented table.

Camera tests (same session, 600×400×18 box at the origin):

- `view: front`: camera eye `[300,-797.653,9]`, target `[300,200,9]`, up `+Z`;
  the PNG is a 600×18 strip (front elevation).
- `view: top`: eye `[300,200,1006.653]`, target `[300,200,9]`, up `+Y`; the PNG
  is a 600×400 rectangle.
- `view: iso`: eye `[875.995,-375.995,584.995]`; the PNG shows the box in
  three-quarter view.
- Explicit camera eye `[1200,-1200,900]`, target `[300,200,9]`,
  `perspective: false`: metadata reports the exact eye/target, orthographic
  height `1190.457 mm`, and the expected orthographic image.

Cutlist-merging tests (same session, 360×545×18 shelves):

- One call `count: 3, count_axis: "z", spacing_mm: 300` produced one part with
  `count: 3`, bounds z `0..618`, positions z `0/300/600`.
- Three separate calls at z `0/300/600` reused the definition and raised the
  same part's count `1 → 2 → 3`.
- A same-name call with length 400 (different from 360) created
  `MCP Merge Shelf (2)` and warned about the dimension mismatch.
- `reuse_definition: false` created `MCP No Reuse` and `MCP No Reuse (2)`,
  each with `count: 1`.
- Note: the raw bridge was used for `count_axis`/`reuse_definition` because the
  session's MCP client still had the camera-era tool schema cached; the Node
  server code contains the new fields and a fresh MCP connection picks them up.

Groups/cylinders tests (same session):

- Cylinder rail `length 756, diameter 25` at `[0,0,1000]`, rotation `[0,0,0]`:
  OCL reports length/width/thickness `756/25/25`; bounds x `0..756`,
  y `-12.5..12.5`, z `987.5..1012.5`.
- Second identical rail at `[0,1000,1000]`: definition reused, one cutlist line
  with `count: 2`.
- Grouping two 200×200×18 boxes under "MCP Test Group": group entity id/guid
  returned, cutlist still three lines (rail count 2 + A + B), and the boxes'
  instance paths read `MCP Test Group` (serialized paths include the group id).

Solid-operation tests (2026-10-25, final build):

- Two 500³ boxes offset by 250 → `union`: one 750³ part, bounds
  `0..750` on all axes, name `MCP Name A` (no `#1`), target tags preserved,
  tool erased.
- `subtract`: target bounds unchanged, tool erased. `intersect` of 300³ and
  200³ boxes offset by 150 → 150³ at `[3150,150,150]`.
- `trim`: target rebuilt, tool kept, both remain as parts; response
  `kept_part_ids` includes both.
- `split` of 300³ and 200³ offset by 150 → three parts named
  `<source> (target minus tool)`, `<source> (tool minus target)`,
  `<source> (intersection)` with bounds 300³ / 200³ / 150³; source parts gone.
  Tags, description (`Split description`) and price (`7.5`) copied to the
  target-side pieces.
- Fully contained `subtract` → empty result, both operands erased, warning
  `The operation produced an empty solid`, no leftover definition.
- `part_ids` on a two-instance part → `ambiguous_part_instances`; the same part
  unioned through its two `entity_ids` merged into one 300×200×200 part.
- Operands in different containers → `different_parents`; union of two parts
  inside a group kept the group path and produced one named part.
- Target definition shared with a non-operand instance: the result became
  `MCP Name I (solid)` at the operated instance, while the untouched instance
  kept `MCP Name I` at its original bounds.
- Sheet-good part with 2 mm edge banding on `ymin`/`ymax` (`edge_count: 2`,
  `1010`) kept both edge materials after `subtract`; a part without a
  sheet-good body material does not get OCL edge detection (OCL behavior, not
  the boolean).

## Known limitations / future work

- `ocl_create_part` creates rectangular boxes and X-axis cylinders only. Smart
  Draw supports polygons, arbitrary planes and construction geometry; its
  creation path is coupled to interactive tool state
  (`smart_draw_tool.rb:1544-1673`), so reusing it needs a dedicated worker.
- Solid operations accept only OCL parts that are manifold solids and share
  one container. A part with several instances must be addressed through
  `entity_ids`. There is no `keep_target` option: `trim` is the way to keep
  the tool, and `split` is the way to keep both sides of the difference.
  `outer_shell` is an alias of `union`; Meshy does not expose a separate
  inner-face-preserving union.
- Solid operations do not recreate edge banding/veneer on newly cut faces.
  Materials on surviving faces are preserved by the worker. Apply finishing
  with `ocl_update_part` after the operation.
- No part thumbnails (the viewport screenshot is the visual tool), batch part
  update, group editing/ungrouping, outliner, export or packing tools. Groups
  can be created only from parts that already share a container.
- Cylinders support length/diameter only; edge banding/veneers are not
  meaningful on them. Boxes remain the only shape with oriented edge/face
  roles.
- Screenshot isolation only hides siblings along the target paths; it cannot
  isolate inside a shared component definition without temporarily affecting
  other instances of that definition (restored afterwards). Captures use the
  current style/background and require a visible target part.
- Hidden parts disappear from OpenCutList cutlists until shown again by
  `entity_ids`.
- Resize scales instance transformations; non-box geometry and textures stretch
  like the SketchUp scale tool. Shared definitions scaled differently per
  instance become separate OCL parts.
- Multiple SketchUp instances starting the bridge overwrite the same discovery
  file; the last start wins. The stop logic only deletes its own file (PID
  check).
- The bridge token lives for the bridge session; restarting the bridge rotates
  it and the Node client re-reads the discovery file.
- A timed-out mutation may still commit. Tell the model/client to re-list rather
  than blindly retry.

## Extending safely

1. Add a command method in `McpController` and register it in `setup_commands`.
2. Keep params JSON-friendly; deep-symbolize at the handler edge.
3. Wrap every model mutation in `start_operation` / `commit_operation` /
   `abort_operation`; raise `McpError` for expected failures.
4. Add a tool in `mcp/server.mjs` with a zod schema, description, annotations
   and timeout; map it to the `mcp_*` method.
5. Add it to `mcp/README.md` and this file.
6. Test the protocol standalone (stubbed Ruby server / fake TCP bridge) before
   the live SketchUp test, then run the create → update → resize → move →
   select → delete sequence on an empty model.

## Security boundaries

- Loopback only (`127.0.0.1`), ephemeral port.
- Per-run random token required on every request; discovery file `0600`.
- No arbitrary Ruby evaluation and no generic UI-command dispatch; only the
  curated `mcp_*` commands are callable.
- Delete requires explicit `confirm: true`; MCP annotations mark destructive
  tools.
- The bridge is opt-in via the SketchUp menu and stops on quit.
