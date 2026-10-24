module Ladb::OpenCutList

  require 'fileutils'
  require 'securerandom'

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

    # World-space information for one part instance.
    #
    # InstanceInfo#transformation is the full path transformation (the part may
    # be nested in groups), so its origin and the transformed definition bounds
    # are real world coordinates.
    def _mcp_instance_world_info(instance_info, part_axes = nil)
      entity = instance_info.entity
      transformation = instance_info.transformation

      # Hardware parts store parent/world-space entity.bounds in
      # InstanceInfo#definition_bounds (cutlist_generate_worker.rb:1157),
      # while normal parts store definition-local bounds. definition.bounds is
      # always definition-local, so prefer it and never transform a
      # world-space box twice.
      definition = instance_info.definition
      definition_bounds = definition.nil? ? instance_info.definition_bounds : definition.bounds

      bounds_mm = nil
      unless definition_bounds.nil?
        world_bounds = Geom::BoundingBox.new
        (0..7).each { |index| world_bounds.add(definition_bounds.corner(index).transform(transformation)) }
        bounds_mm = _mcp_bounds_mm(world_bounds)
      end

      layer = instance_info.layer
      roles = _mcp_role_world_info(part_axes, transformation)
      {
        :entity_id => entity.respond_to?(:entityID) ? entity.entityID : nil,
        :path => instance_info.named_path,
        :serialized_path => instance_info.serialized_path,
        :position_mm => transformation.origin.to_a.map { |value| value.to_mm.to_f.round(3) },
        :bounds_mm => bounds_mm,
        :transformation => transformation.to_a,
        :layer => layer.respond_to?(:name) ? layer.name : nil,
        :flipped => instance_info.flipped,
        :visible => entity.respond_to?(:visible?) ? entity.visible? : nil,
        :edge_roles => roles.nil? ? nil : roles.select { |role, _| %w(xmin xmax ymin ymax).include?(role) },
        :face_roles => roles.nil? ? nil : roles.select { |role, _| %w(zmin zmax).include?(role) }
      }
    end

    # World-space direction of each oriented edge/face role for one instance.
    # Labels use SketchUp's world directions: front = -Y, back = +Y,
    # left = -X, right = +X, bottom = -Z, top = +Z.
    def _mcp_role_world_info(part_axes, transformation)
      return nil if part_axes.nil? || part_axes.length < 3

      length_axis, width_axis, thickness_axis = part_axes
      local_axes = {
        'xmin' => [ length_axis.reverse, 'x', '-' ],
        'xmax' => [ length_axis, 'x', '+' ],
        'ymin' => [ width_axis.reverse, 'y', '-' ],
        'ymax' => [ width_axis, 'y', '+' ],
        'zmin' => [ thickness_axis.reverse, 'z', '-' ],
        'zmax' => [ thickness_axis, 'z', '+' ]
      }

      local_axes.each_with_object({}) do |(role, (axis, axis_name, sign)), result|
        world = axis.transform(transformation)
        length = world.length
        world = Geom::Vector3d.new(world.x / length, world.y / length, world.z / length) if length > 0

        result[role] = {
          :local_axis => axis_name,
          :sign => sign,
          :world_normal => [ world.x.round(3), world.y.round(3), world.z.round(3) ],
          :label => _mcp_world_direction_label(world)
        }
      end
    end

    def _mcp_world_direction_label(vector)
      axis, value = { 'x' => vector.x, 'y' => vector.y, 'z' => vector.z }.max_by { |_, component| component.abs }
      case axis
      when 'x'
        value >= 0 ? 'right' : 'left'
      when 'y'
        value >= 0 ? 'back' : 'front'
      else
        value >= 0 ? 'top' : 'bottom'
      end
    end

    # Union of all instance world bounds for a part, in millimetres.
    def _mcp_part_world_bounds_mm(part)
      world_bounds = Geom::BoundingBox.new
      found = false

      part.def.instance_infos.values.each do |instance_info|
        # See _mcp_instance_world_info: definition.bounds is always local,
        # whereas InstanceInfo#definition_bounds is world-space for hardware.
        definition = instance_info.definition
        definition_bounds = definition.nil? ? instance_info.definition_bounds : definition.bounds
        next if definition_bounds.nil?

        transformation = instance_info.transformation
        (0..7).each { |index| world_bounds.add(definition_bounds.corner(index).transform(transformation)) }
        found = true
      end

      found ? _mcp_bounds_mm(world_bounds) : nil
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

    # Sets visibility on resolved entities. Used by the explicit hide/show tool.
    def _mcp_set_entities_visible(entities, visible)
      changed = 0
      entities.each do |entity|
        next unless entity.valid? && entity.respond_to?(:visible=)
        entity.visible = visible
        changed += 1
      end
      changed
    end

    # Captures the current viewport as a PNG.
    #
    # When +isolate+ is true, everything that is not on one of +part_paths+ is
    # temporarily hidden (siblings at every level, so nested parts work), the
    # view is zoomed to the remaining geometry, the image is written, and both
    # visibility and camera are restored. The temporary changes are wrapped in
    # an operation that is aborted, so they never land on the undo stack.
    def _mcp_capture_screenshot(model, view, part_paths, width: 1200, height: 800, isolate: false, zoom_extents: true)
      camera = view.camera
      previous_visibility = []
      operation_started = false

      if isolate
        model.start_operation('OCL MCP: Screenshot', true)
        operation_started = true
        _mcp_hide_others_for_paths(model, part_paths, previous_visibility)
      end

      directory = File.join(PLUGIN.temp_dir, 'mcp_screenshots')
      FileUtils.mkdir_p(directory)
      path = File.join(directory, "ocl-#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(4)}.png")

      view.zoom_extents if zoom_extents
      view.invalidate if view.respond_to?(:invalidate)

      ok = view.write_image({
        :filename => path,
        :width => width,
        :height => height,
        :antialias => true,
        :compression => 0.9,
        :transparent => false
      })
      raise McpError.new('screenshot_failed', 'SketchUp failed to write the screenshot.') unless ok
      unless File.exist?(path) && File.size(path) > 0
        raise McpError.new('screenshot_failed', 'SketchUp produced an empty screenshot.')
      end

      _mcp_cleanup_screenshots(directory)

      {
        :path => path,
        :width => width,
        :height => height,
        :bytes => File.size(path),
        :hidden_entity_count => previous_visibility.length,
        :zoomed => zoom_extents
      }
    ensure
      previous_visibility.reverse_each do |entity, visible|
        begin
          entity.visible = visible if entity.valid?
        rescue StandardError
          # Best effort: a locked/deleted entity may reject the change.
        end
      end

      begin
        view.camera = camera if view
      rescue StandardError
        # Camera restore is best effort.
      end

      if operation_started
        begin
          model.abort_operation
        rescue StandardError
          # Nothing to abort.
        end
      end
    end

    # Hides every entity that is not on one of the target paths, at every
    # parent collection along those paths. Returns nothing; the caller passes a
    # list that receives [entity, previous_visibility] pairs for restoration.
    def _mcp_hide_others_for_paths(model, paths, previous_visibility)
      keep_by_parent = {}

      paths.each do |path|
        path.each_with_index do |entity, index|
          if index == 0
            parent_key = 0
            parent = model.entities
          else
            parent_entity = path[index - 1]
            parent_key = parent_entity.entityID
            parent = _mcp_children_entities(parent_entity)
          end
          next if parent.nil?

          entry = (keep_by_parent[parent_key] ||= { :parent => parent, :keep => {} })
          entry[:keep][entity.entityID] = true
        end
      end

      keep_by_parent.each_value do |entry|
        entry[:parent].to_a.each do |entity|
          next if entry[:keep].key?(entity.entityID)
          next unless entity.respond_to?(:visible?) && entity.respond_to?(:visible=)

          begin
            previous_visibility << [ entity, entity.visible? ]
            entity.visible = false
          rescue StandardError
            # Locked or special entities may reject visibility changes.
          end
        end
      end
    end

    def _mcp_children_entities(entity)
      if entity.is_a?(Sketchup::Group)
        entity.entities
      elsif entity.is_a?(Sketchup::ComponentInstance)
        entity.definition.entities
      else
        nil
      end
    end

    # Keep the screenshot directory bounded.
    def _mcp_cleanup_screenshots(directory)
      files = Dir.glob(File.join(directory, '*.png')).sort_by { |file| File.mtime(file) }
      return if files.length <= 20

      files[0...(files.length - 20)].each do |file|
        begin
          File.delete(file)
        rescue StandardError
          # Ignore files already removed.
        end
      end
    end

  end

end
