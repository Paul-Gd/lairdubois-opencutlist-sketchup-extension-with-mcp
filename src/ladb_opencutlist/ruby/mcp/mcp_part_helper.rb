module Ladb::OpenCutList

  require_relative '../model/attributes/definition_attributes'
  require_relative '../model/attributes/material_attributes'

  # Geometry helpers used by the MCP controller.
  #
  # Everything here is called on SketchUp's main thread (the bridge server is
  # pumped by UI.start_timer), so plain SketchUp API calls are safe.
  module McpPartHelper

    MAX_DIMENSION_MM = 100_000.0

    DEFAULT_MATERIAL_COLORS = %w(
      #4F78A7 #EF8E2C #DE545A #79B8B2 #5CA34D
      #ECCA48 #AE78A2 #FC9CA8 #9B755F #BAB0AC
    ).freeze

    # Returns a definition name that does not collide with an existing one.
    def _mcp_unique_definition_name(model, name)
      base = name.is_a?(String) ? name.strip : ''
      base = 'Part' if base.empty?
      candidate = base
      index = 2
      while model.definitions[candidate]
        candidate = "#{base} (#{index})"
        index += 1
      end
      candidate
    end

    # Sketchup::Group and Sketchup::ComponentInstance both expose #definition.
    def _mcp_definition(entity)
      entity.respond_to?(:definition) ? entity.definition : nil
    end

    def _mcp_definition_bounds(entity)
      definition = _mcp_definition(entity)
      definition.nil? ? nil : definition.bounds
    end

    # Draws a box in the definition's local XY plane and extrudes it upward.
    # This is the same recipe as the CSV importer, with a positive pushpull so
    # the part sits above z=0.
    def _mcp_create_box_definition(model, name, length, width, thickness, tags)
      definition = model.definitions.add(name)
      entities = definition.entities

      face = entities.add_face([
        Geom::Point3d.new(0, 0, 0),
        Geom::Point3d.new(length, 0, 0),
        Geom::Point3d.new(length, width, 0),
        Geom::Point3d.new(0, width, 0)
      ])
      raise McpError.new('create_failed', 'Failed to create the part base face.') if face.nil?

      # Same orientation guard as OpenCutList's Smart Draw tool: make sure the
      # face points up before extruding, so the part sits above z=0.
      face.reverse! unless face.normal.samedirection?(Z_AXIS)

      # Face#pushpull always returns nil, so verify the extrusion through the
      # definition bounds instead of its return value.
      face.pushpull(thickness)
      if definition.bounds.depth.to_f.abs <= 0.001
        raise McpError.new('create_failed', 'Failed to extrude the part.')
      end

      # Safety net for SketchUp's face-orientation heuristic: if the solid
      # ended up below the XY plane, lift the definition geometry so its
      # bottom face is at z=0.
      if definition.bounds.min.z < -0.001
        entities.transform_entities(
          Geom::Transformation.new(Geom::Vector3d.new(0, 0, -definition.bounds.min.z)),
          entities.to_a
        )
      end

      definition_attributes = DefinitionAttributes.new(definition)
      definition_attributes.orientation_locked_on_axis = true
      definition_attributes.tags = tags unless tags.nil?
      definition_attributes.uuid   # Generate and persist a stable definition UUID
      definition_attributes.write_to_attributes

      definition
    end

    # position_mm: [x, y, z] in millimetres.
    # rotation_deg: [rx, ry, rz] in degrees, applied about the definition origin.
    def _mcp_instance_transformation(position_mm, rotation_deg)
      position = Geom::Point3d.new(position_mm[0].mm, position_mm[1].mm, position_mm[2].mm)
      transformation = Geom::Transformation.new(position)

      if rotation_deg.is_a?(Array) && rotation_deg.length >= 3
        rx, ry, rz = rotation_deg
        rotation = Geom::Transformation.rotation(ORIGIN, X_AXIS, rx.to_f.degrees)
        rotation = rotation * Geom::Transformation.rotation(ORIGIN, Y_AXIS, ry.to_f.degrees)
        rotation = rotation * Geom::Transformation.rotation(ORIGIN, Z_AXIS, rz.to_f.degrees)
        transformation = transformation * rotation
      end

      transformation
    end

    # Scales the given instances/groups in definition-local space so that the
    # local min corner stays fixed. +part_def+ is the OpenCutList PartDef, whose
    # size.axes tell which local axis maps to length/width/thickness.
    def _mcp_resize_entities(entities, part_def, targets_mm)
      size = part_def.size
      current = {
        :length => size.length.to_mm.to_f,
        :width => size.width.to_mm.to_f,
        :thickness => size.thickness.to_mm.to_f
      }

      factors = {}
      [ :length, :width, :thickness ].each do |key|
        value = targets_mm[key]
        if value.nil?
          factors[key] = 1.0
        else
          raise McpError.new('resize_failed', "Current #{key} is zero; cannot resize this part.") if current[key] <= 0
          factors[key] = value.to_f / current[key]
        end
      end

      # Map the length/width/thickness factors onto the definition-local axes.
      scale_by_axis = { :x => 1.0, :y => 1.0, :z => 1.0 }
      axes = size.axes
      [ :length, :width, :thickness ].each_with_index do |key, index|
        axis = axes[index]
        axis_key = axis == X_AXIS ? :x : (axis == Y_AXIS ? :y : :z)
        scale_by_axis[axis_key] = factors[key]
      end

      entities.each do |entity|
        definition = _mcp_definition(entity)
        raise McpError.new('resize_failed', 'A part instance has no definition and cannot be resized.') if definition.nil?

        anchor = definition.bounds.min
        scaling = Geom::Transformation.scaling(anchor, scale_by_axis[:x], scale_by_axis[:y], scale_by_axis[:z])
        entity.transformation = entity.transformation * scaling
      end

      scale_by_axis
    end

    def _mcp_translate_entities(entities, dx_mm, dy_mm, dz_mm)
      translation = Geom::Transformation.new(Geom::Vector3d.new(dx_mm.mm, dy_mm.mm, dz_mm.mm))
      entities.each { |entity| entity.transformation = translation * entity.transformation }
    end

    def _mcp_erase_entities(entities)
      erased = 0
      entities.each do |entity|
        next unless entity.valid?
        entity.parent.entities.erase_entities(entity)
        erased += 1
      end
      erased
    end

    # Returns face entity IDs grouped by the OpenCutList edge/face role
    # (xmin, xmax, ymin, ymax, zmin, zmax), using the part's oriented axes.
    # This lets the MCP bridge apply edge banding/veneers even on a brand-new
    # box for which OpenCutList has not yet detected any edge entities.
    def _mcp_face_ids_by_role(model, part)
      axes = part.def.size.axes
      length_axis, width_axis, thickness_axis = axes

      roles = {
        'xmin' => length_axis.reverse,
        'xmax' => length_axis,
        'ymin' => width_axis.reverse,
        'ymax' => width_axis,
        'zmin' => thickness_axis.reverse,
        'zmax' => thickness_axis
      }

      ids = {}
      definitions = Array(part.entity_ids).map { |entity_id| model.find_entity_by_id(entity_id.to_i) }
                                             .compact
                                             .map { |entity| _mcp_definition(entity) }
                                             .compact
                                             .uniq

      definitions.each do |definition|
        definition.entities.grep(Sketchup::Face).each do |face|
          normal = face.normal
          roles.each do |role, axis|
            (ids[role] ||= []) << face.entityID if normal.dot(axis) > 0.99
          end
        end
      end

      ids
    end

    # Resolves the container for a newly created part. Only groups are accepted:
    # adding geometry to a component definition would affect every instance.
    def _mcp_container_entities(model, container_id)
      return model.entities if container_id.nil? || container_id.to_i == 0

      entity = model.find_entity_by_id(container_id.to_i)
      raise McpError.new('container_not_found', "No entity with id #{container_id}.") if entity.nil?
      unless entity.is_a?(Sketchup::Group)
        raise McpError.new('invalid_container', 'container_id must refer to a group. Components share their definition across instances.')
      end

      entity.entities
    end

    # Converts a SketchUp Length (or nil) to millimetres as a rounded Float.
    def _mcp_mm(length)
      length.nil? ? nil : length.to_mm.to_f.round(3)
    end

    def _mcp_axis_name(axis)
      axis == X_AXIS ? 'x' : (axis == Y_AXIS ? 'y' : 'z')
    end

    def _mcp_bounds_mm(bounds)
      return nil if bounds.nil?
      {
        :min => bounds.min.to_a.map { |value| value.to_mm.to_f.round(3) },
        :max => bounds.max.to_a.map { |value| value.to_mm.to_f.round(3) }
      }
    end

  end

end
