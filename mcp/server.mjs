import fs from 'node:fs';

import { McpServer } from '@modelcontextprotocol/server';
import { serveStdio } from '@modelcontextprotocol/server/stdio';
import * as z from 'zod/v4';

import { BridgeClient } from './bridge-client.mjs';

const bridge = new BridgeClient();

const SERVER_NAME = 'opencutlist';
const SERVER_VERSION = '1.0.0';

const MATERIAL_TYPES = [
  'unknown',
  'solid_wood',
  'sheet_good',
  'dimensional',
  'edge',
  'hardware',
  'veneer',
  'machining'
];

const EDGE_KEYS = ['ymin', 'ymax', 'xmin', 'xmax'];
const FACE_KEYS = ['zmin', 'zmax'];

function textResult(value) {
  return {
    content: [
      {
        type: 'text',
        text: JSON.stringify(value, null, 2)
      }
    ]
  };
}

function errorResult(error) {
  return {
    content: [
      {
        type: 'text',
        text: error instanceof Error ? error.message : String(error)
      }
    ],
    isError: true
  };
}

function registerTool(server, name, config, method, { timeoutMs = 30000 } = {}) {
  server.registerTool(name, config, async (args) => {
    try {
      const result = await bridge.call(method, args || {}, { timeoutMs });
      return textResult(result);
    } catch (error) {
      return errorResult(error);
    }
  });
}

const optionalEdgeMaterials = Object.fromEntries(
  EDGE_KEYS.map((key) => [key, z.string().nullable().optional()])
);

const optionalFaceMaterials = Object.fromEntries(
  FACE_KEYS.map((key) => [key, z.string().nullable().optional()])
);

const optionalFaceAngles = Object.fromEntries(
  FACE_KEYS.map((key) => [key, z.number().nullable().optional()])
);

const updatePatchSchema = z.object({
  name: z.string().min(1).optional(),
  description: z.string().optional(),
  url: z.string().optional(),
  tags: z.array(z.string()).optional(),
  material: z.string().nullable().optional().describe('Body material name; null clears it.'),
  cumulable: z.boolean().optional(),
  mass: z.number().nonnegative().optional(),
  price: z.number().nonnegative().optional(),
  thickness_layer_count: z.number().int().min(1).optional(),
  orientation_locked_on_axis: z.boolean().optional(),
  symmetrical: z.boolean().optional(),
  ignore_grain_direction: z.boolean().optional(),
  follow_grain_direction: z.boolean().optional(),
  edge_materials: z.object(optionalEdgeMaterials).optional().describe('Edge-band material by definition-local edge role: ymin, ymax, xmin, xmax. These are NOT world directions; read instances[].edge_roles for the world label/normal of each role. null clears an edge.'),
  face_materials: z.object(optionalFaceMaterials).optional().describe('Veneer material by definition-local face role: zmin, zmax. Read instances[].face_roles for world labels. null clears a face.'),
  face_texture_angles: z.object(optionalFaceAngles).optional().describe('Veneer texture angle in degrees by face: zmin, zmax.')
}).refine((patch) => Object.keys(patch).length > 0, {
  message: 'Provide at least one field to update.'
});

const resizeSchema = z.object({
  part_id: z.string().min(1),
  length_mm: z.number().positive().max(100000).optional(),
  width_mm: z.number().positive().max(100000).optional(),
  thickness_mm: z.number().positive().max(100000).optional()
}).refine((value) => value.length_mm !== undefined || value.width_mm !== undefined || value.thickness_mm !== undefined, {
  message: 'Provide at least one of length_mm, width_mm or thickness_mm.'
});

const moveSchema = z.object({
  part_id: z.string().min(1),
  dx_mm: z.number().optional(),
  dy_mm: z.number().optional(),
  dz_mm: z.number().optional()
});

function registerTools(server) {
  // ------------------------------------------------------------------
  // Read-only tools

  registerTool(server, 'ocl_get_model_info', {
    description: 'Get the active SketchUp model name, path, units, part counts and current selection size.',
    inputSchema: z.object({}),
    annotations: { readOnlyHint: true, openWorldHint: false }
  }, 'mcp_model_info', { timeoutMs: 120000 });

  registerTool(server, 'ocl_list_parts', {
    description:
      'List OpenCutList parts from the whole model. Returns part_id, name, dimensions in millimetres, material, tags, count and entity ids. ' +
      'Each part also has bounds_mm (world-space axis-aligned box) and instances[] with each instance world position_mm (its origin), bounds_mm, transformation matrix, ' +
      'visible flag, edge_roles and face_roles. Role entries include the definition-local axis/sign, the world normal and a world label (front/back/left/right/top/bottom). ' +
      'part_id is valid for the current model state: call this again after any change to get fresh ids. Virtual edge/veneer parts are hidden unless include_virtual is true.',
    inputSchema: z.object({
      filters: z.object({
        name_contains: z.string().optional(),
        material: z.string().optional(),
        tag: z.string().optional(),
        group_id: z.string().optional()
      }).optional(),
      include_virtual: z.boolean().optional(),
      limit: z.number().int().min(1).max(1000).optional(),
      offset: z.number().int().min(0).optional()
    }),
    annotations: { readOnlyHint: true, openWorldHint: false }
  }, 'mcp_parts_list', { timeoutMs: 120000 });

  registerTool(server, 'ocl_get_part', {
    description:
      'Get the full details of one OpenCutList part by part_id: dimensions in mm, oriented axes, edge/face materials, world bounds, per-instance positions/transformations, ' +
      'edge_roles/face_roles (local axis + world normal + front/back/left/right/top/bottom label), raw material colours and the raw OpenCutList data.',
    inputSchema: z.object({
      part_id: z.string().min(1)
    }),
    annotations: { readOnlyHint: true, openWorldHint: false }
  }, 'mcp_part_get', { timeoutMs: 120000 });

  registerTool(server, 'ocl_get_cutlist', {
    description:
      'Get the OpenCutList cutlist grouped by material, with group totals and optional part summaries. Use this for an overview before listing individual parts.',
    inputSchema: z.object({
      include_parts: z.boolean().optional()
    }),
    annotations: { readOnlyHint: true, openWorldHint: false }
  }, 'mcp_cutlist_get', { timeoutMs: 120000 });

  registerTool(server, 'ocl_list_materials', {
    description: 'List the SketchUp materials known to OpenCutList, including type, thickness and standard sizes.',
    inputSchema: z.object({}),
    annotations: { readOnlyHint: true, openWorldHint: false }
  }, 'mcp_materials_list', { timeoutMs: 60000 });

  // ------------------------------------------------------------------
  // Mutating tools

  registerTool(server, 'ocl_create_part', {
    description:
      'Create one or more rectangular parts in the model and register them with OpenCutList. All dimensions and positions are in millimetres. ' +
      'The part definition is created at the model root unless container_id names a group. position_mm is the transformed local origin, not the bbox minimum. ' +
      'Rotations compose T(position) * Rx * Ry * Rz: with [0,90,0] local length maps to world -Z (the part extends downward), with [0,-90,0] to world +Z, ' +
      'and with [90,0,0] local width maps to world +Z. Use rotation_deg [0,90,0] plus position z=height to stand a panel upright on the floor. ' +
      'Returns the new part with a fresh part_id, world bounds and per-instance world positions in millimetres. ' +
      'If the material does not exist it is created (type unknown unless material_type is given); set create_material_if_missing: false to fail instead.',
    inputSchema: z.object({
      name: z.string().min(1).describe('Definition/part name, e.g. "Shelf".'),
      length_mm: z.number().positive().max(100000),
      width_mm: z.number().positive().max(100000),
      thickness_mm: z.number().positive().max(100000),
      position_mm: z.tuple([z.number(), z.number(), z.number()]).optional().describe('World position in mm; defaults to [0,0,0].'),
      rotation_deg: z.tuple([z.number(), z.number(), z.number()]).optional().describe('Rotation around X, Y, Z in degrees; defaults to [0,0,0].'),
      count: z.number().int().min(1).max(1000).optional(),
      spacing_mm: z.number().min(0).optional().describe('Distance between copies along X, in mm.'),
      material: z.string().optional().describe('Material name; created if it does not exist.'),
      material_type: z.enum(MATERIAL_TYPES).optional(),
      material_color: z.string().regex(/^#[0-9a-fA-F]{6}$/).optional().describe('Colour for a newly created material, e.g. "#C8A165".'),
      create_material_if_missing: z.boolean().optional().describe('When false, fail if the material does not exist instead of creating it. Defaults to true.'),
      tags: z.array(z.string()).optional(),
      container_id: z.number().int().optional().describe('Optional entityID of a group to create the part inside. Components are rejected.')
    }),
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false }
  }, 'mcp_part_create', { timeoutMs: 120000 });

  registerTool(server, 'ocl_update_part', {
    description:
      'Update part metadata, material, tags, edge banding or veneers. Only the supplied fields change. ' +
      'Edge/face materials must already exist with type edge/veneer (create them with ocl_create_material). ' +
      'Renaming a definition renames every instance of that definition; instance-named parts are renamed per instance. ' +
      'The returned part_id may differ from the input id: use the returned one for the next call.',
    inputSchema: z.object({
      part_id: z.string().min(1),
      patch: updatePatchSchema
    }),
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false }
  }, 'mcp_part_update', { timeoutMs: 120000 });

  registerTool(server, 'ocl_resize_part', {
    description:
      'Set absolute dimensions of a part in millimetres. Only the supplied dimensions change. All instances of the part are scaled from their local min corner; ' +
      'the returned part_id may differ, so use it for the next call. Non-box geometry and textures are stretched, like the SketchUp scale tool.',
    inputSchema: resizeSchema,
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false }
  }, 'mcp_part_resize', { timeoutMs: 120000 });

  registerTool(server, 'ocl_move_part', {
    description: 'Translate all instances of a part by a relative offset in millimetres. A zero offset is allowed and returns the current world bounds and instance positions without changing the model.',
    inputSchema: moveSchema,
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false }
  }, 'mcp_part_move', { timeoutMs: 60000 });

  registerTool(server, 'ocl_delete_part', {
    description:
      'Delete all instances of a part. Definitions and materials are kept. This is destructive and requires confirm: true. ' +
      'The user can undo it with a single SketchUp undo step.',
    inputSchema: z.object({
      part_id: z.string().min(1),
      confirm: z.literal(true).describe('Must be true to confirm the deletion.')
    }),
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false }
  }, 'mcp_part_delete', { timeoutMs: 60000 });

  registerTool(server, 'ocl_select_parts', {
    description:
      'Select parts in SketchUp so the user can see what is being changed. Parts nested inside a closed group cannot be selected from the current context and are reported as warnings.',
    inputSchema: z.object({
      part_ids: z.array(z.string().min(1)).min(1),
      mode: z.enum(['replace', 'add', 'remove']).optional()
    }),
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false }
  }, 'mcp_parts_select', { timeoutMs: 60000 });

  registerTool(server, 'ocl_set_parts_visibility', {
    description:
      'Hide or show parts. Hidden parts are excluded from OpenCutList cutlists, so to show a hidden part pass the entity_ids returned by the hide call ' +
      '(part_ids cannot be resolved while the part is hidden). Changes are one undoable SketchUp operation.',
    inputSchema: z.object({
      part_ids: z.array(z.string().min(1)).optional(),
      entity_ids: z.array(z.number().int()).optional(),
      visible: z.boolean()
    }).refine((value) => (value.part_ids?.length ?? 0) > 0 || (value.entity_ids?.length ?? 0) > 0, {
      message: 'Provide part_ids or entity_ids.'
    }),
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false }
  }, 'mcp_parts_visibility', { timeoutMs: 60000 });

  server.registerTool('ocl_screenshot', {
    description:
      'Capture a PNG image of the current SketchUp viewport. With part_ids + isolate: true, temporarily hides everything that is not on those parts, ' +
      'captures the image, then restores visibility and camera; the temporary changes do not stay on the undo stack. ' +
      'Camera control: view is one of front (looks +Y from -Y), back, left, right, top, bottom, iso (front-right-top); ' +
      'or pass camera: { eye_mm, target_mm, up? } for an explicit world-space camera. perspective toggles orthographic/perspective (defaults to the current camera) ' +
      'and fov is 1-120 degrees. With part_ids, the camera targets those parts; otherwise the whole model. ' +
      'zoom_extents defaults to false when view/camera is given and true otherwise. Returns an image block plus metadata including the final camera. ' +
      'Recommended size 1200×800; both dimensions are capped at 4000.',
    inputSchema: z.object({
      part_ids: z.array(z.string().min(1)).optional(),
      isolate: z.boolean().optional(),
      view: z.enum(['front', 'back', 'left', 'right', 'top', 'bottom', 'iso']).optional(),
      camera: z.object({
        eye_mm: z.tuple([z.number(), z.number(), z.number()]),
        target_mm: z.tuple([z.number(), z.number(), z.number()]),
        up: z.tuple([z.number(), z.number(), z.number()]).optional()
      }).optional(),
      perspective: z.boolean().optional(),
      fov: z.number().min(1).max(120).optional(),
      width: z.number().int().min(64).max(4000).optional(),
      height: z.number().int().min(64).max(4000).optional(),
      zoom_extents: z.boolean().optional().describe('Frame the target after applying the view/camera. Defaults to false when view or camera is given, true otherwise.')
    }).refine((value) => !(value.view && value.camera), {
      message: 'Use either view or camera, not both.'
    }).refine((value) => !value.isolate || (Array.isArray(value.part_ids) && value.part_ids.length > 0), {
      message: 'isolate requires part_ids.'
    }),
    annotations: { readOnlyHint: true, openWorldHint: false }
  }, async (args) => {
    try {
      const result = await bridge.call('mcp_screenshot', args || {}, { timeoutMs: 120000 });
      const image = await fs.promises.readFile(result.path);
      return {
        content: [
          { type: 'text', text: JSON.stringify(result, null, 2) },
          { type: 'image', data: image.toString('base64'), mimeType: 'image/png' }
        ]
      };
    } catch (error) {
      return errorResult(error);
    }
  });

  registerTool(server, 'ocl_create_material', {
    description:
      'Create a SketchUp material with OpenCutList metadata. Use type "edge" for edge banding and "veneer" for veneers. ' +
      'Materials are identified by their display name (which defaults to name).',
    inputSchema: z.object({
      name: z.string().min(1),
      display_name: z.string().optional(),
      type: z.enum(MATERIAL_TYPES).optional(),
      color: z.string().regex(/^#[0-9a-fA-F]{6}$/).optional(),
      thickness_mm: z.number().positive().max(100000).optional()
    }),
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false }
  }, 'mcp_material_create', { timeoutMs: 60000 });

  registerTool(server, 'ocl_update_material', {
    description:
      'Update an existing material by name. Only the supplied fields change: colour, type, display name (rename), description, url, thickness and standard sizes/prices. ' +
      'thickness_mm is meaningful for edge/veneer materials; OpenCutList uses app defaults for sheet goods/solid wood. ' +
      'The returned name is the actual material name (SketchUp may uniquify a rename).',
    inputSchema: z.object({
      name: z.string().min(1),
      patch: z.object({
        display_name: z.string().min(1).optional(),
        color: z.string().regex(/^#[0-9a-fA-F]{6}$/).optional(),
        type: z.enum(MATERIAL_TYPES).optional(),
        thickness_mm: z.number().positive().max(100000).optional(),
        thickness: z.string().optional().describe('Formatted thickness with units, e.g. "2mm".'),
        description: z.string().optional(),
        url: z.string().optional(),
        length_increase_mm: z.number().nonnegative().optional(),
        width_increase_mm: z.number().nonnegative().optional(),
        thickness_increase_mm: z.number().nonnegative().optional(),
        length_increase: z.string().optional(),
        width_increase: z.string().optional(),
        thickness_increase: z.string().optional(),
        std_sections: z.string().optional(),
        std_lengths: z.string().optional(),
        std_widths: z.string().optional(),
        std_thicknesses: z.string().optional(),
        std_sizes: z.string().optional(),
        grained: z.boolean().optional(),
        edge_decremented: z.boolean().optional(),
        raw_estimated: z.boolean().optional(),
        multiplier_coefficient: z.number().optional(),
        std_volumic_masses: z.string().optional(),
        std_prices: z.string().optional(),
        std_cut_prices: z.string().optional()
      }).refine((value) => Object.keys(value).length > 0, {
        message: 'Provide at least one field to update.'
      })
    }),
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false }
  }, 'mcp_material_update', { timeoutMs: 60000 });

  registerTool(server, 'ocl_delete_material', {
    description:
      'Delete a material by name. If the material is used by OpenCutList parts the call fails unless force: true is set; ' +
      'a forced deletion may leave material references on entities empty. This is destructive and undoable.',
    inputSchema: z.object({
      name: z.string().min(1),
      force: z.boolean().optional()
    }),
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false }
  }, 'mcp_material_delete', { timeoutMs: 60000 });
}

serveStdio(() => {
  const server = new McpServer({
    name: SERVER_NAME,
    version: SERVER_VERSION
  });
  registerTools(server);
  return server;
});
