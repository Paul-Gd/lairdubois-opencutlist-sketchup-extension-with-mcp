module Ladb::OpenCutList

  require_relative 'controller'
  require_relative '../mcp/mcp_error'
  require_relative '../mcp/mcp_bridge_server'
  require_relative '../mcp/mcp_part_helper'
  require_relative '../worker/cutlist/cutlist_generate_worker'
  require_relative '../worker/cutlist/cutlist_part_update_worker'
  require_relative '../worker/common/common_drawing_decomposition_worker'
  require_relative '../worker/common/common_solid_boolean_worker'
  require_relative '../worker/common/common_solid_boolean_apply_worker'
  require_relative '../model/drawing/drawing_def'
  require_relative '../model/cutlist/instance_info'
  require_relative '../model/attributes/definition_attributes'
  require_relative '../model/attributes/material_attributes'
  require_relative '../utils/dimension_utils'
  require_relative '../utils/color_utils'

  # Commands exposed to AI tools through the MCP bridge.
  #
  # Reads and most updates reuse OpenCutList's own workers, so the result is
  # exactly what the UI would produce. Only part creation and the direct
  # transformation operations are implemented here.
  class McpController < Controller

    include McpPartHelper

    MATERIAL_TYPES = {
      'unknown' => MaterialAttributes::TYPE_UNKNOWN,
      'unknow' => MaterialAttributes::TYPE_UNKNOWN,
      'solid_wood' => MaterialAttributes::TYPE_SOLID_WOOD,
      'sheet_good' => MaterialAttributes::TYPE_SHEET_GOOD,
      'dimensional' => MaterialAttributes::TYPE_DIMENSIONAL,
      'edge' => MaterialAttributes::TYPE_EDGE,
      'hardware' => MaterialAttributes::TYPE_HARDWARE,
      'veneer' => MaterialAttributes::TYPE_VENEER,
      'machining' => MaterialAttributes::TYPE_MACHINING
    }.freeze

    DEFAULT_PARTS_LIMIT = 200
    MAX_PARTS_LIMIT = 1000
    MAX_PART_COUNT = 1000

    SOLID_OPERATIONS = %w(union subtract intersect trim split outer_shell).freeze

    def initialize
      super('mcp')
      @bridge_server = nil
    end

    def setup_commands

      # Bridge lifecycle
      PLUGIN.register_command('mcp_bridge_start') { |_params| bridge_start_command }
      PLUGIN.register_command('mcp_bridge_stop') { |_params| bridge_stop_command }
      PLUGIN.register_command('mcp_bridge_status') { |_params| bridge_status_command }

      # Diagnostics
      PLUGIN.register_command('mcp_ping') { |_params| ping_command }
      PLUGIN.register_command('mcp_model_info') { |params| model_info_command(params) }

      # Parts
      PLUGIN.register_command('mcp_parts_list') { |params| parts_list_command(params) }
      PLUGIN.register_command('mcp_part_get') { |params| part_get_command(params) }
      PLUGIN.register_command('mcp_part_create') { |params| part_create_command(params) }
      PLUGIN.register_command('mcp_part_update') { |params| part_update_command(params) }
      PLUGIN.register_command('mcp_part_resize') { |params| part_resize_command(params) }
      PLUGIN.register_command('mcp_part_move') { |params| part_move_command(params) }
      PLUGIN.register_command('mcp_part_delete') { |params| part_delete_command(params) }
      PLUGIN.register_command('mcp_parts_select') { |params| parts_select_command(params) }
      PLUGIN.register_command('mcp_parts_visibility') { |params| parts_visibility_command(params) }
      PLUGIN.register_command('mcp_create_group') { |params| group_create_command(params) }
      PLUGIN.register_command('mcp_solid_operation') { |params| solid_operation_command(params) }
      PLUGIN.register_command('mcp_screenshot') { |params| screenshot_command(params) }

      # Materials
      PLUGIN.register_command('mcp_materials_list') { |params| materials_list_command(params) }
      PLUGIN.register_command('mcp_material_create') { |params| material_create_command(params) }
      PLUGIN.register_command('mcp_material_update') { |params| material_update_command(params) }
      PLUGIN.register_command('mcp_material_delete') { |params| material_delete_command(params) }

      # Cutlist
      PLUGIN.register_command('mcp_cutlist_get') { |params| cutlist_get_command(params) }

    end

    # Called by Plugin#stop_mcp_bridge on SketchUp quit.
    def stop_bridge
      @bridge_server.stop unless @bridge_server.nil?
    end

    private

    # ---------------------------------------------------------------------
    # Bridge lifecycle / diagnostics

    def bridge_start_command
      @bridge_server ||= McpBridgeServer.new(lambda { |method, params| PLUGIN.execute_command(method, params) })
      @bridge_server.start
    rescue Exception => e
      PLUGIN.dump_exception(e, false)
      {
        :running => false,
        :error => "#{e.class}: #{e.message}"
      }
    end

    def bridge_stop_command
      @bridge_server.stop unless @bridge_server.nil?
      {
        :running => false,
        :discovery_file => _discovery_file
      }
    end

    def bridge_status_command
      return @bridge_server.status unless @bridge_server.nil?
      {
        :running => false,
        :port => nil,
        :discovery_file => _discovery_file,
        :version => _version,
        :model => _model_name
      }
    end

    def ping_command
      {
        :pong => true,
        :version => _version,
        :model => _model_name
      }
    end

    def model_info_command(params)
      model = _require_model
      cutlist = _cutlist
      parts = cutlist.get_parts

      {
        :model_name => model.name,
        :model_path => model.path,
        :length_unit => DimensionUtils.length_unit,
        :length_unit_name => _length_unit_name(DimensionUtils.length_unit),
        :part_count => parts.length,
        :real_part_count => parts.count { |part| !part.virtual },
        :virtual_part_count => parts.count { |part| part.virtual },
        :selection_count => model.selection.length,
        :active_path => model.active_path.to_a.map { |entity| entity.respond_to?(:name) ? entity.name : entity.to_s },
        :version => _version
      }
    end

    # ---------------------------------------------------------------------
    # Parts

    def parts_list_command(params)
      p = _deep_symbolize(params || {})
      filters = p[:filters].is_a?(Hash) ? p[:filters] : {}
      include_virtual = p[:include_virtual] == true
      limit = _clamp((p[:limit] || DEFAULT_PARTS_LIMIT).to_i, 1, MAX_PARTS_LIMIT)
      offset = [ (p[:offset] || 0).to_i, 0 ].max

      cutlist = _cutlist
      parts = cutlist.get_parts

      unless include_virtual
        parts = parts.reject { |part| part.virtual }
      end

      if (name_contains = filters[:name_contains])
        needle = name_contains.to_s.downcase
        parts = parts.select { |part| part.name.to_s.downcase.include?(needle) }
      end
      if (material = filters[:material])
        material = material.to_s
        parts = parts.select { |part| part.group.material_name.to_s == material }
      end
      if (tag = filters[:tag])
        tag = tag.to_s
        parts = parts.select { |part| Array(part.tags).include?(tag) }
      end
      if (group_id = filters[:group_id])
        group_id = group_id.to_s
        parts = parts.select { |part| part.group.id.to_s == group_id }
      end

      total = parts.length
      page = parts[offset, limit] || []

      {
        :total => total,
        :returned => page.length,
        :offset => offset,
        :limit => limit,
        :parts => page.map { |part| _part_summary(part) }
      }
    end

    def part_get_command(params)
      p = _deep_symbolize(params || {})
      part_id = p[:part_id].to_s
      raise McpError.new('invalid_params', 'part_id is required.') if part_id.empty?

      cutlist = _cutlist
      part = _find_part(cutlist, part_id)
      _part_detail(part)
    end

    def part_create_command(params)
      p = _deep_symbolize(params || {})
      model = _require_model

      name = p[:name].to_s.strip
      raise McpError.new('invalid_params', 'name is required.') if name.empty?

      warnings = []

      shape = (p[:shape] || 'box').to_s.downcase
      unless %w(box cylinder).include?(shape)
        raise McpError.new('invalid_params', "shape must be 'box' or 'cylinder'.")
      end

      length = _positive_mm(p[:length_mm], 'length_mm')

      if shape == 'cylinder'
        diameter = _positive_mm(p[:diameter_mm], 'diameter_mm')
        width = p[:width_mm].nil? ? nil : _positive_mm(p[:width_mm], 'width_mm')
        thickness = p[:thickness_mm].nil? ? nil : _positive_mm(p[:thickness_mm], 'thickness_mm')
        if !p[:width_mm].nil? || !p[:thickness_mm].nil?
          warnings << 'width_mm and thickness_mm are ignored for cylinders.'
        end
      else
        width = _positive_mm(p[:width_mm], 'width_mm')
        thickness = _positive_mm(p[:thickness_mm], 'thickness_mm')
        diameter = nil
        warnings << 'diameter_mm is ignored for boxes.' unless p[:diameter_mm].nil?
      end

      position = p[:position_mm] || [ 0, 0, 0 ]
      unless position.is_a?(Array) && position.length == 3
        raise McpError.new('invalid_params', 'position_mm must be an array of 3 numbers.')
      end

      rotation = p[:rotation_deg] || [ 0, 0, 0 ]
      unless rotation.is_a?(Array) && rotation.length == 3
        raise McpError.new('invalid_params', 'rotation_deg must be an array of 3 numbers.')
      end

      count = (p[:count] || 1).to_i
      raise McpError.new('invalid_params', "count must be between 1 and #{MAX_PART_COUNT}.") if count < 1 || count > MAX_PART_COUNT

      spacing = (p[:spacing_mm] || 0).to_f
      raise McpError.new('invalid_params', 'spacing_mm must be >= 0.') if spacing < 0

      reuse_definition = p[:reuse_definition] != false
      count_axis = (p[:count_axis] || 'x').to_s.downcase
      unless %w(x y z).include?(count_axis)
        raise McpError.new('invalid_params', "count_axis must be 'x', 'y' or 'z'.")
      end
      axis_index = { 'x' => 0, 'y' => 1, 'z' => 2 }[count_axis]

      tags = Array(p[:tags]).map(&:to_s)

      material = nil
      if p[:material].is_a?(String) && !p[:material].strip.empty?
        material_name = p[:material].strip
        requested_type = p[:material_type].nil? ? MaterialAttributes::TYPE_UNKNOWN : _material_type_to_int(p[:material_type])
        existing_material = model.materials[material_name]

        if existing_material.nil? && p[:create_material_if_missing] == false
          raise McpError.new(
            'material_not_found',
            "Material '#{material_name}' does not exist. Create it first or set create_material_if_missing to true."
          )
        end

        color = p[:material_color] || _default_material_color(model)
        material = MaterialAttributes.fetch_or_create_material(model, material_name, requested_type, color)

        if existing_material.nil?
          warnings << "Material '#{material_name}' did not exist and was created with type '#{_material_type_name(requested_type)}' and colour '#{color}'."
        elsif p[:material_type] && MaterialAttributes.new(existing_material).type != requested_type
          warnings << "Material '#{material_name}' already existed with type '#{_material_type_name(MaterialAttributes.new(existing_material).type)}'; the requested type '#{_material_type_name(requested_type)}' was not applied."
        end
      end

      warnings << "count is greater than 1 and spacing_mm is 0: the copies overlap along #{count_axis}." if count > 1 && spacing == 0

      container_entities = _mcp_container_entities(model, p[:container_id])
      created_entities = []
      definition = nil
      reused_definition = false

      model.start_operation('OCL MCP: Create Part', true)
      begin
        definition, reused_definition, definition_warnings = _mcp_prepare_definition(
          model,
          name,
          shape,
          length.mm,
          width.nil? ? nil : width.mm,
          thickness.nil? ? nil : thickness.mm,
          diameter.nil? ? nil : diameter.mm,
          tags,
          reuse_definition
        )
        warnings.concat(definition_warnings)

        count.times do |index|
          copy_position = [ position[0].to_f, position[1].to_f, position[2].to_f ]
          copy_position[axis_index] += index * spacing
          transformation = _mcp_instance_transformation(copy_position, rotation)
          instance = container_entities.add_instance(definition, transformation)
          raise McpError.new('create_failed', 'Failed to add the part instance.') if instance.nil?
          instance.material = material unless material.nil?
          created_entities << instance
        end

        unless model.commit_operation
          raise McpError.new('create_failed', 'Failed to commit the part creation.')
        end
      rescue Exception => e
        begin
          model.abort_operation
        rescue StandardError
          # Nothing to abort.
        end
        raise e
      end

      entity_ids = created_entities.map { |entity| entity.entityID }
      cutlist = _cutlist
      part = _find_part_by_entity_ids(cutlist, entity_ids)

      result = {
        :created_entity_ids => entity_ids,
        :created_instance_count => created_entities.length,
        :definition_id => definition.nil? ? nil : definition.name,
        :reused_definition => reused_definition,
        :shape => shape,
        :diameter_mm => diameter,
        :warnings => warnings
      }
      if part.nil?
        result[:warning] = 'The part was created but OpenCutList does not recognize it yet. Check its dimensions and visibility.'
      else
        result[:part] = _part_detail(part)
      end
      result
    end

    def part_update_command(params)
      p = _deep_symbolize(params || {})
      model = _require_model

      part_id = p[:part_id].to_s
      raise McpError.new('invalid_params', 'part_id is required.') if part_id.empty?

      patch = p[:patch]
      raise McpError.new('invalid_params', 'patch must be a non-empty object.') unless patch.is_a?(Hash) && !patch.empty?
      patch = _deep_symbolize(patch)

      allowed_keys = [
        :name, :description, :url, :tags, :material,
        :cumulable, :mass, :price, :thickness_layer_count,
        :orientation_locked_on_axis, :symmetrical,
        :ignore_grain_direction, :follow_grain_direction,
        :edge_materials, :face_materials, :face_texture_angles
      ]
      unknown_keys = patch.keys - allowed_keys
      raise McpError.new('invalid_params', "Unsupported patch keys: #{unknown_keys.join(', ')}.") unless unknown_keys.empty?

      cutlist = _cutlist
      part = _find_part(cutlist, part_id)

      # Mirror what the UI does: send the part hash through JSON so nested hash
      # keys become strings, exactly as CutlistPartUpdateWorker expects.
      begin
        part_hash = JSON.parse(JSON.generate(part.to_hash))
      rescue JSON::GeneratorError
        part_hash = _stringify_keys(part.to_hash)
      end
      warnings = []

      # Name
      if patch.key?(:name)
        new_name = patch[:name].to_s
        raise McpError.new('invalid_params', 'name cannot be empty.') if new_name.strip.empty?

        if part.name_source == InstanceInfo::NAME_SOURCE_DEFINITION
          part_hash['name'] = new_name
        else
          _rename_part_instances(model, part.entity_ids, new_name)
          warnings << 'This part takes its name from the instance or dynamic attributes, so the instances were renamed directly.'
        end
      end

      # Body material
      if patch.key?(:material)
        _validate_material_exists(model, patch[:material]) unless patch[:material].nil?
        part_hash['material_name'] = patch[:material]
      end

      # Edge banding
      if patch.key?(:edge_materials)
        edge_materials = patch[:edge_materials] || {}
        raise McpError.new('invalid_params', 'edge_materials must be an object.') unless edge_materials.is_a?(Hash)

        names = part_hash['edge_material_names'].is_a?(Hash) ? part_hash['edge_material_names'] : {}
        edge_materials.each do |edge, material_name|
          edge_key = edge.to_s
          unless %w(ymin ymax xmin xmax).include?(edge_key)
            raise McpError.new('invalid_params', "Unknown edge '#{edge}'. Use ymin, ymax, xmin or xmax.")
          end
          _validate_material_type(model, material_name, MaterialAttributes::TYPE_EDGE) unless material_name.nil?
          names[edge_key] = material_name
        end
        part_hash['edge_material_names'] = names

        # Fill in the face entity ids by oriented axis so a brand-new part can
        # receive edge banding even though OpenCutList has not detected edges yet.
        existing_ids = part_hash['edge_entity_ids'].is_a?(Hash) ? part_hash['edge_entity_ids'] : {}
        part_hash['edge_entity_ids'] = existing_ids.merge(_mcp_face_ids_by_role(model, part))
      end

      # Veneers / face materials
      if patch.key?(:face_materials)
        face_materials = patch[:face_materials] || {}
        raise McpError.new('invalid_params', 'face_materials must be an object.') unless face_materials.is_a?(Hash)

        names = part_hash['face_material_names'].is_a?(Hash) ? part_hash['face_material_names'] : {}
        face_materials.each do |face, material_name|
          face_key = face.to_s
          unless %w(zmin zmax).include?(face_key)
            raise McpError.new('invalid_params', "Unknown face '#{face}'. Use zmin or zmax.")
          end
          _validate_material_type(model, material_name, MaterialAttributes::TYPE_VENEER) unless material_name.nil?
          names[face_key] = material_name
        end
        part_hash['face_material_names'] = names

        existing_ids = part_hash['face_entity_ids'].is_a?(Hash) ? part_hash['face_entity_ids'] : {}
        part_hash['face_entity_ids'] = existing_ids.merge(_mcp_face_ids_by_role(model, part))
      end

      if patch.key?(:face_texture_angles)
        angles = patch[:face_texture_angles] || {}
        raise McpError.new('invalid_params', 'face_texture_angles must be an object.') unless angles.is_a?(Hash)

        current = part_hash['face_texture_angles'].is_a?(Hash) ? part_hash['face_texture_angles'] : {}
        angles.each do |face, angle|
          face_key = face.to_s
          unless %w(zmin zmax).include?(face_key)
            raise McpError.new('invalid_params', "Unknown face '#{face}'. Use zmin or zmax.")
          end
          current[face_key] = angle.nil? ? nil : angle.to_f.round
        end
        part_hash['face_texture_angles'] = current
      end

      # Scalar definition attributes
      [ :description, :url, :tags, :cumulable, :mass, :price,
        :thickness_layer_count, :orientation_locked_on_axis, :symmetrical,
        :ignore_grain_direction, :follow_grain_direction ].each do |key|
        part_hash[key.to_s] = patch[key] if patch.key?(key)
      end

      begin
        committed = CutlistPartUpdateWorker.new(
          cutlist,
          parts_data: [ part_hash ],
          transparent_operation: false
        ).run
      rescue Exception => e
        begin
          model.abort_operation
        rescue StandardError
          # Nothing to abort.
        end
        raise e
      end

      raise McpError.new('update_failed', 'OpenCutList failed to commit the part update.') unless committed == true

      updated_cutlist = _cutlist
      updated_part = _find_part_by_entity_ids(updated_cutlist, part.entity_ids)

      {
        :part_id => updated_part.nil? ? nil : updated_part.id,
        :part => updated_part.nil? ? nil : _part_detail(updated_part),
        :warnings => warnings
      }
    end

    def part_resize_command(params)
      p = _deep_symbolize(params || {})
      model = _require_model

      part_id = p[:part_id].to_s
      raise McpError.new('invalid_params', 'part_id is required.') if part_id.empty?

      targets_mm = {}
      targets_mm[:length] = _positive_mm(p[:length_mm], 'length_mm') if p.key?(:length_mm)
      targets_mm[:width] = _positive_mm(p[:width_mm], 'width_mm') if p.key?(:width_mm)
      targets_mm[:thickness] = _positive_mm(p[:thickness_mm], 'thickness_mm') if p.key?(:thickness_mm)
      raise McpError.new('invalid_params', 'Provide at least one of length_mm, width_mm or thickness_mm.') if targets_mm.empty?

      cutlist = _cutlist
      part = _find_part(cutlist, part_id)
      raise McpError.new('unsupported_entity', 'Virtual parts (edge bands/veneers) cannot be resized directly. Edit the real part instead.') if part.virtual

      entities = _resolve_entities(model, part.entity_ids)
      raise McpError.new('part_not_found', 'None of the part instances could be resolved in the model.') if entities.empty?

      model.start_operation('OCL MCP: Resize Part', true)
      begin
        scale_by_axis = _mcp_resize_entities(entities, part.def, targets_mm)
        model.commit_operation
      rescue Exception => e
        begin
          model.abort_operation
        rescue StandardError
          # Nothing to abort.
        end
        raise e
      end

      updated_cutlist = _cutlist
      updated_part = _find_part_by_entity_ids(updated_cutlist, part.entity_ids)

      {
        :part_id => updated_part.nil? ? nil : updated_part.id,
        :scale => scale_by_axis,
        :part => updated_part.nil? ? nil : _part_detail(updated_part)
      }
    end

    def part_move_command(params)
      p = _deep_symbolize(params || {})
      model = _require_model

      part_id = p[:part_id].to_s
      raise McpError.new('invalid_params', 'part_id is required.') if part_id.empty?

      dx = (p[:dx_mm] || 0).to_f
      dy = (p[:dy_mm] || 0).to_f
      dz = (p[:dz_mm] || 0).to_f

      cutlist = _cutlist
      part = _find_part(cutlist, part_id)
      raise McpError.new('unsupported_entity', 'Virtual parts (edge bands/veneers) cannot be moved directly. Move the real part instead.') if part.virtual

      entities = _resolve_entities(model, part.entity_ids)
      raise McpError.new('part_not_found', 'None of the part instances could be resolved in the model.') if entities.empty?

      # A zero offset is allowed: it is a useful "where is this part?" query.
      unless dx == 0 && dy == 0 && dz == 0
        model.start_operation('OCL MCP: Move Part', true)
        begin
          _mcp_translate_entities(entities, dx, dy, dz)
          model.commit_operation
        rescue Exception => e
          begin
            model.abort_operation
          rescue StandardError
            # Nothing to abort.
          end
          raise e
        end
      end

      updated_cutlist = _cutlist
      updated_part = _find_part_by_entity_ids(updated_cutlist, part.entity_ids)

      if updated_part.nil?
        # Fallback if the part vanished from the cutlist for any reason.
        bounds = Geom::BoundingBox.new
        entities.each { |entity| bounds.add(entity.bounds) }
        {
          :part_id => part.id,
          :bounds_mm => _mcp_bounds_mm(bounds),
          :instances => nil
        }
      else
        {
          :part_id => updated_part.id,
          :bounds_mm => _mcp_part_world_bounds_mm(updated_part),
          :instances => updated_part.def.instance_infos.values
                                        .sort_by(&:serialized_path)
                                        .map { |instance_info| _mcp_instance_world_info(instance_info, updated_part.def.size.axes) }
        }
      end
    end

    def part_delete_command(params)
      p = _deep_symbolize(params || {})
      model = _require_model

      part_id = p[:part_id].to_s
      raise McpError.new('invalid_params', 'part_id is required.') if part_id.empty?
      raise McpError.new('confirmation_required', 'Set confirm to true to delete a part.') unless p[:confirm] == true

      cutlist = _cutlist
      part = _find_part(cutlist, part_id)
      raise McpError.new('unsupported_entity', 'Virtual parts (edge bands/veneers) disappear with their real part and cannot be deleted directly.') if part.virtual

      entities = _resolve_entities(model, part.entity_ids)
      raise McpError.new('part_not_found', 'None of the part instances could be resolved in the model.') if entities.empty?

      erased = 0
      model.start_operation('OCL MCP: Delete Part', true)
      begin
        erased = _mcp_erase_entities(entities)
        model.commit_operation
      rescue Exception => e
        begin
          model.abort_operation
        rescue StandardError
          # Nothing to abort.
        end
        raise e
      end

      {
        :part_id => part.id,
        :deleted_entity_count => erased
      }
    end

    def parts_select_command(params)
      p = _deep_symbolize(params || {})
      model = _require_model

      part_ids = Array(p[:part_ids]).map(&:to_s).reject(&:empty?)
      raise McpError.new('invalid_params', 'part_ids must be a non-empty array.') if part_ids.empty?

      mode = (p[:mode] || 'replace').to_s
      unless %w(replace add remove).include?(mode)
        raise McpError.new('invalid_params', "Unknown mode '#{mode}'. Use replace, add or remove.")
      end

      cutlist = _cutlist
      parts = part_ids.map { |part_id| _find_part(cutlist, part_id) }
      entities = parts.inject([]) { |memo, part| memo + _resolve_entities(model, part.entity_ids) }
      raise McpError.new('part_not_found', 'None of the requested parts could be resolved in the model.') if entities.empty?

      warnings = []
      selectable = entities.select { |entity| model.active_entities.include?(entity) }
      if selectable.length < entities.length
        warnings << 'Some parts are nested inside a group and cannot be selected from the current drawing context.'
      end

      case mode
      when 'replace'
        model.selection.clear
        model.selection.add(selectable) unless selectable.empty?
      when 'add'
        model.selection.add(selectable) unless selectable.empty?
      when 'remove'
        model.selection.remove(selectable) unless selectable.empty?
      end

      {
        :mode => mode,
        :selected_count => model.selection.length,
        :requested_entity_count => entities.length,
        :selectable_entity_count => selectable.length,
        :warnings => warnings
      }
    end

    def parts_visibility_command(params)
      p = _deep_symbolize(params || {})
      model = _require_model

      visible = p[:visible]
      raise McpError.new('invalid_params', 'visible must be true or false.') unless visible == true || visible == false

      part_ids = Array(p[:part_ids]).map(&:to_s).reject(&:empty?)
      entity_ids = Array(p[:entity_ids]).map { |entity_id| entity_id.to_i }.reject(&:zero?)
      if part_ids.empty? && entity_ids.empty?
        raise McpError.new('invalid_params', 'Provide part_ids or entity_ids.')
      end

      entities = _resolve_entities(model, entity_ids)

      unless part_ids.empty?
        # Hidden parts are excluded from the cutlist, so a hidden part can only
        # be shown again through entity_ids (returned by the hide call).
        cutlist = _cutlist
        part_ids.each do |part_id|
          begin
            part = _find_part(cutlist, part_id)
          rescue McpError => e
            raise McpError.new(e.code, "#{e.message} If the part is hidden, pass the entity_ids returned by the hide call instead.")
          end
          entities.concat(_resolve_entities(model, part.entity_ids))
        end
      end

      entities = entities.uniq { |entity| entity.entityID }
      raise McpError.new('part_not_found', 'None of the requested entities could be resolved.') if entities.empty?

      model.start_operation(visible ? 'OCL MCP: Show Parts' : 'OCL MCP: Hide Parts', true)
      begin
        changed = _mcp_set_entities_visible(entities, visible)
        model.commit_operation
      rescue Exception => e
        begin
          model.abort_operation
        rescue StandardError
          # Nothing to abort.
        end
        raise e
      end

      {
        :visible => visible,
        :changed_entity_count => changed,
        :part_ids => part_ids,
        :entity_ids => entities.map { |entity| entity.entityID },
        :note => visible ? nil : 'Hidden parts are excluded from OpenCutList cutlists. Use the returned entity_ids to show them again.'
      }
    end

    def group_create_command(params)
      p = _deep_symbolize(params || {})
      model = _require_model

      name = p[:name].to_s.strip
      raise McpError.new('invalid_params', 'name is required.') if name.empty?

      part_ids = Array(p[:part_ids]).map(&:to_s).reject(&:empty?)
      raise McpError.new('invalid_params', 'part_ids must be a non-empty array.') if part_ids.empty?

      cutlist = _cutlist
      parts = part_ids.map { |part_id| _find_part(cutlist, part_id) }
      parts.each do |part|
        raise McpError.new('unsupported_entity', 'Virtual parts cannot be grouped directly. Group the real part instead.') if part.virtual
      end

      entities = parts.inject([]) { |memo, part| memo + _resolve_entities(model, part.entity_ids) }
      entities = entities.uniq { |entity| entity.entityID }
      raise McpError.new('part_not_found', 'None of the requested parts could be resolved.') if entities.empty?

      containers = entities.map(&:parent)
      container_keys = containers.map do |container|
        container.is_a?(Sketchup::Model) ? :model : container.object_id
      end
      if container_keys.uniq.length > 1
        raise McpError.new('different_parents', 'All parts must be in the same container (the model root or the same group) to be grouped.')
      end
      parent_entities = containers.first.entities

      bounds = Geom::BoundingBox.new
      parts.each do |part|
        part_bounds = _mcp_part_bounds(part)
        bounds.add(part_bounds) unless part_bounds.nil? || part_bounds.empty?
      end

      group = nil
      model.start_operation('OCL MCP: Create Group', true)
      begin
        group = _mcp_create_group(parent_entities, entities, name)
        model.commit_operation
      rescue Exception => e
        begin
          model.abort_operation
        rescue StandardError
          # Nothing to abort.
        end
        raise e
      end

      {
        :group_entity_id => group.entityID,
        :group_guid => group.respond_to?(:guid) ? group.guid : nil,
        :group_name => group.name,
        :definition_name => group.definition.name,
        :part_ids => parts.map(&:id),
        :part_count => parts.length,
        :member_entity_ids => entities.map { |entity| entity.entityID },
        :bounds_mm => bounds.empty? ? nil : _mcp_bounds_mm(bounds)
      }
    end

    # Runs a boolean solid operation on OpenCutList parts.
    #
    # Operands are instances, not part definitions: a part with several copies
    # must be addressed through entity_ids. All operands must be in the same
    # container. The first operand is the target; the others are tools. The
    # operation uses OpenCutList's own Meshy-based boolean workers, so locked
    # instances, non-manifold solids and nested containers are handled exactly
    # like the Smart tools do.
    def solid_operation_command(params)
      p = _deep_symbolize(params || {})
      model = _require_model

      operation = p[:operation].to_s.strip.downcase
      unless SOLID_OPERATIONS.include?(operation)
        raise McpError.new('invalid_params', "operation must be one of: #{SOLID_OPERATIONS.join(', ')}.")
      end

      cutlist = _cutlist
      operands = _mcp_solid_operands(model, cutlist, p)
      if operation == 'split' && operands.length != 2
        raise McpError.new('invalid_params', 'split requires exactly two operands: the target and the tool.')
      end

      _mcp_require_same_solid_container(operands)

      drawing_defs = operands.map do |operand|
        drawing_def = _mcp_solid_drawing_def(operand[:instance_info])
        if drawing_def.nil?
          raise McpError.new(
            'solid_operand_not_readable',
            "OpenCutList could not read '#{operand[:part].name}' as a solid. Make sure it is a closed group or component."
          )
        end
        drawing_def
      end

      result = nil
      split_pieces = nil
      rename_jobs = []
      operation_label = operation.split('_').map(&:capitalize).join(' ')

      model.start_operation("OCL MCP: Solid #{operation_label}", true)
      begin
        if operation == 'split'
          split_pieces = _mcp_apply_solid_split(drawing_defs)
          _mcp_copy_split_result_attributes(split_pieces, operands)
          _mcp_erase_entities(operands.map { |operand| operand[:entity] })
          _mcp_remove_unused_solid_definitions(model, operands, [])
          rename_jobs = _mcp_split_rename_jobs(split_pieces, operands, p[:name])
        else
          # Free the target's definition name before the boolean worker clones
          # the container, otherwise SketchUp uniquifies the clone ("Shelf" ->
          # "Shelf#1") while the source definition still holds the name.
          name_context = _mcp_free_solid_result_name(model, operands.first)
          result = _mcp_apply_solid_boolean(drawing_defs, operation)
          rename_jobs = _mcp_prepare_solid_result_identity(result, operands, p[:name], model, name_context)
        end
        _mcp_apply_solid_rename_jobs(rename_jobs)
        model.commit_operation
      rescue Exception => e
        begin
          model.abort_operation
        rescue StandardError
          # Nothing to abort.
        end
        raise e
      end

      cutlist = _cutlist
      if operation == 'split'
        _mcp_split_result_response(operation, split_pieces, operands, cutlist)
      else
        _mcp_boolean_result_response(operation, result, operands, cutlist)
      end
    end

    # ---------------------------------------------------------------------
    # Solid operation helpers

    def _mcp_solid_operands(model, cutlist, p)
      part_ids = Array(p[:part_ids]).map(&:to_s).reject(&:empty?)
      entity_ids = Array(p[:entity_ids]).map { |id| id.to_i }.reject(&:zero?)

      if !part_ids.empty? && !entity_ids.empty?
        raise McpError.new('invalid_params', 'Provide either part_ids or entity_ids, not both.')
      end
      if part_ids.empty? && entity_ids.empty?
        raise McpError.new('invalid_params', 'Provide part_ids or entity_ids with at least two operands.')
      end

      if !part_ids.empty?
        if part_ids.length < 2
          raise McpError.new('invalid_params', 'part_ids must contain at least two parts.')
        end
        part_ids.map do |part_id|
          part = _find_part(cutlist, part_id)
          _mcp_solid_operand_from_part(model, part)
        end
      else
        entity_ids = entity_ids.uniq
        if entity_ids.length < 2
          raise McpError.new('invalid_params', 'entity_ids must contain at least two different entities.')
        end
        entity_ids.map { |entity_id| _mcp_solid_operand_from_entity(model, cutlist, entity_id) }
      end
    end

    def _mcp_solid_operand_from_part(model, part)
      if part.virtual
        raise McpError.new('unsupported_entity', "Part '#{part.name}' is virtual (edge banding or veneer) and cannot take part in a solid operation.")
      end

      entity_ids = Array(part.entity_ids).map(&:to_i).uniq
      if entity_ids.length != 1
        raise McpError.new(
          'ambiguous_part_instances',
          "Part '#{part.name}' has #{entity_ids.length} instances. Use entity_ids to choose which instances take part (see ocl_get_part instances[])."
        )
      end

      _mcp_solid_operand_from_entity(model, nil, entity_ids.first, part)
    end

    def _mcp_solid_operand_from_entity(model, cutlist, entity_id, part = nil)
      entity = model.find_entity_by_id(entity_id)
      if entity.nil?
        raise McpError.new('entity_not_found', "No entity with id #{entity_id}. Call ocl_list_parts to get fresh ids.")
      end
      unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
        raise McpError.new('unsupported_entity', "Entity #{entity_id} is not a group or component instance.")
      end
      if entity.respond_to?(:visible?) && !entity.visible?
        raise McpError.new('entity_hidden', "Entity #{entity_id} is hidden. Show it before a solid operation.")
      end

      if part.nil?
        part = _find_part_by_entity_ids(cutlist, [entity_id])
        if part.nil?
          raise McpError.new('not_a_part', "Entity #{entity_id} is not an OpenCutList part. Solid operations only accept parts listed by ocl_list_parts.")
        end
        if part.virtual
          raise McpError.new('unsupported_entity', "Part '#{part.name}' is virtual (edge banding or veneer) and cannot take part in a solid operation.")
        end
      end

      instance_info = part.def.instance_infos.values.find { |info| !info.entity.nil? && info.entity.entityID == entity_id }
      if instance_info.nil?
        raise McpError.new('part_not_found', "Entity #{entity_id} is not an instance of part '#{part.name}'.")
      end

      {
        :entity => entity,
        :entity_id => entity_id,
        :part => part,
        :instance_info => instance_info,
        :definition => _mcp_definition(entity),
        :material => entity.material,
        :layer => entity.layer
      }
    end

    def _mcp_require_same_solid_container(operands)
      containers = operands.map { |operand| operand[:entity].parent }
      keys = containers.map { |container| container.is_a?(Sketchup::Model) ? :model : container.object_id }
      if keys.uniq.length > 1
        raise McpError.new('different_parents', 'All solid operands must be in the same container (the model root or the same group).')
      end
    end

    def _mcp_apply_solid_boolean(drawing_defs, operation)
      first = drawing_defs.first
      rest = drawing_defs[1..-1] || []

      result = case operation
               when 'union', 'outer_shell'
                 CommonSolidBooleanApplyWorker.new(
                   drawing_defs, [],
                   operation: CommonSolidBooleanWorker::OPERATION_UNION,
                   wrap_operation: false
                 ).run
               when 'subtract'
                 CommonSolidBooleanApplyWorker.new(
                   [first], rest,
                   operation: CommonSolidBooleanWorker::OPERATION_SUBTRACTION,
                   wrap_operation: false
                 ).run
               when 'trim'
                 CommonSolidBooleanApplyWorker.new(
                   [first], rest,
                   operation: CommonSolidBooleanWorker::OPERATION_SUBTRACTION,
                   keep_cuts: true,
                   wrap_operation: false
                 ).run
               when 'intersect'
                 CommonSolidBooleanApplyWorker.new(
                   [first], rest,
                   operation: CommonSolidBooleanWorker::OPERATION_INTERSECTION,
                   wrap_operation: false
                 ).run
               else
                 raise McpError.new('invalid_params', "Unsupported solid operation '#{operation}'.")
               end

      unless result.success?
        raise McpError.new('solid_operation_failed', _mcp_solid_error_message(result))
      end

      result
    end

    # Split is three independent boolean results on the same pair:
    # target - tool, tool - target and target ∩ tool. Compute all three
    # before touching the model, then apply each in keep_srcs mode so the
    # operands survive until every piece has been rebuilt.
    def _mcp_apply_solid_split(drawing_defs)
      target, tool = drawing_defs
      pieces = [
        {
          :role => 'target_minus_tool',
          :source_index => 0,
          :src => [target],
          :cut => [tool],
          :operation => CommonSolidBooleanWorker::OPERATION_SUBTRACTION
        },
        {
          :role => 'tool_minus_target',
          :source_index => 1,
          :src => [tool],
          :cut => [target],
          :operation => CommonSolidBooleanWorker::OPERATION_SUBTRACTION
        },
        {
          :role => 'intersection',
          :source_index => 0,
          :src => [target],
          :cut => [tool],
          :operation => CommonSolidBooleanWorker::OPERATION_INTERSECTION
        }
      ]

      pieces.each do |piece|
        piece[:computed] = CommonSolidBooleanWorker.new(
          piece[:src], piece[:cut],
          operation: piece[:operation]
        ).run
        unless piece[:computed].success?
          raise McpError.new('solid_operation_failed', _mcp_solid_error_message(piece[:computed]))
        end
      end

      pieces.each do |piece|
        next if piece[:computed].fragment_defs.empty?

        piece[:applied] = CommonSolidBooleanApplyWorker.new(
          piece[:src], piece[:cut],
          operation: piece[:operation],
          result_def: piece[:computed],
          keep_srcs: true,
          keep_cuts: true,
          wrap_operation: false
        ).run
        unless piece[:applied].success?
          raise McpError.new('solid_operation_failed', _mcp_solid_error_message(piece[:applied]))
        end
      end

      pieces
    end

    def _mcp_copy_split_result_attributes(pieces, operands)
      pieces.each do |piece|
        applied = piece[:applied]
        next if applied.nil?

        source_operand = operands[piece[:source_index]]
        containers = Array(applied.created_entities).select { |entity| entity.respond_to?(:definition) }
        containers.each do |entity|
          _mcp_copy_definition_attributes(source_operand[:definition], _mcp_definition(entity))
          _mcp_copy_solid_result_appearance(entity, source_operand[:material], source_operand[:layer])
        end
      end
    end

    def _mcp_split_rename_jobs(pieces, operands, name)
      jobs = []
      pieces.each do |piece|
        applied = piece[:applied]
        next if applied.nil?

        source_operand = operands[piece[:source_index]]
        containers = Array(applied.created_entities).select { |entity| entity.respond_to?(:definition) }
        containers.each_with_index do |entity, index|
          base_name = name || source_operand[:part].name
          suffix = piece[:role].tr('_', ' ')
          suffix = "#{suffix} #{index + 1}" if index > 0
          jobs << { :entity => entity, :name => "#{base_name} (#{suffix})" }
        end
      end
      jobs
    end

    # Renames the target definition to a temporary unique name so the boolean
    # worker's clone can take the original name back. SketchUp will not allow
    # two definitions to share a name and suffixes the clone instead.
    def _mcp_free_solid_result_name(model, source_operand)
      definition = source_operand[:definition]
      original_name = source_operand[:part].name.to_s
      context = { :definition => definition, :original_name => original_name, :renamed => false }
      return context if definition.nil? || original_name.empty?

      temp_name = _mcp_unique_definition_name(model, "#{original_name} [MCP solid #{source_operand[:entity_id]}]")
      begin
        definition.name = temp_name
        context[:renamed] = true
      rescue StandardError
        # The result keeps SketchUp's unique suffix if the source name cannot
        # be freed.
      end
      context
    end

    def _mcp_prepare_solid_result_identity(result_def, operands, name, model, name_context)
      source_operand = operands.first
      source_definition = source_operand[:definition]
      containers = Array(result_def.created_entities).select { |entity| entity.respond_to?(:definition) }

      result_definitions = containers.map { |entity| _mcp_definition(entity) }.compact.uniq

      containers.each do |entity|
        definition = _mcp_definition(entity)
        # A made-unique clone keeps a copy of the source definition attributes,
        # including its UUID. Two definitions sharing a UUID are one part to
        # OCL, so a clone gets fresh attributes and a fresh UUID.
        _mcp_copy_definition_attributes(source_definition, definition) if definition != source_definition
      end

      # The source definition may still be displayed by instances outside this
      # operation. Restore its original name before naming the result; in that
      # case the result is a new part and must take a distinguishable name.
      source_in_use = false
      if name_context[:renamed] && !source_definition.nil? && !result_definitions.include?(source_definition)
        begin
          if model.definitions.include?(source_definition) && source_definition.count_used_instances > 0
            source_definition.name = name_context[:original_name]
            source_in_use = true
          end
        rescue StandardError
          # Keep the boolean worker's naming if the source definition is gone.
        end
      end

      _mcp_remove_unused_solid_definitions(model, operands, result_definitions)
      return [] if containers.empty?

      containers.each_with_index.map do |entity, index|
        base_name = name || name_context[:original_name]
        base_name = source_operand[:part].name if base_name.to_s.empty?
        desired_name = source_in_use && name.nil? ? "#{base_name} (solid)" : base_name
        desired_name = "#{desired_name} (#{index + 1})" if name.nil? && containers.length > 1 && index > 0
        _mcp_copy_solid_result_appearance(entity, source_operand[:material], source_operand[:layer])
        { :entity => entity, :name => desired_name }
      end
    end

    def _mcp_apply_solid_rename_jobs(jobs)
      jobs.each { |job| _mcp_rename_entity_and_definition(job[:entity], job[:name]) }
    end

    # Removes source definitions that no longer have any instance after a
    # boolean operation (the target/tool containers are rebuilt or erased).
    # Definitions still displayed by other instances are kept.
    def _mcp_remove_unused_solid_definitions(model, operands, keep_definitions)
      operands.map { |operand| operand[:definition] }.compact.uniq.each do |definition|
        next if keep_definitions.include?(definition)
        next unless definition.respond_to?(:count_used_instances)
        next unless definition.count_used_instances.zero?

        begin
          model.definitions.remove(definition)
        rescue StandardError
          # Leaving an unused definition behind is harmless.
        end
      end
    end

    def _mcp_rename_entity_and_definition(entity, name)
      return if name.nil? || name.to_s.strip.empty?

      definition = _mcp_definition(entity)
      if definition.respond_to?(:name=)
        model = definition.respond_to?(:model) ? definition.model : nil
        unless model.nil?
          existing = model.definitions[name]
          if !existing.nil? && existing != definition && existing.respond_to?(:count_used_instances) && existing.count_used_instances.zero?
            begin
              model.definitions.remove(existing)
            rescue StandardError
              # If it cannot be removed, SketchUp will suffix the result name.
            end
          end
        end

        definition.name = name
      end

      # For groups OCL reads the instance name; for components it reads the
      # definition name. Do not set an instance name on components: it is not
      # what OCL displays and it can interfere with definition uniquification.
      entity.name = name if entity.is_a?(Sketchup::Group) && entity.respond_to?(:name=)
    end

    def _mcp_copy_solid_result_appearance(entity, material, layer)
      begin
        entity.material = material if entity.respond_to?(:material=)
      rescue StandardError
        # Material assignment is best effort.
      end
      begin
        entity.layer = layer if entity.respond_to?(:layer=) && !layer.nil?
      rescue StandardError
        # Keep the layer chosen by the boolean worker.
      end
    end

    def _mcp_solid_error_message(result_def)
      messages = Array(result_def.errors).map do |error|
        if error.is_a?(Array)
          PLUGIN.get_i18n_string(error[0], error[1])
        else
          PLUGIN.get_i18n_string(error.to_s)
        end
      end.uniq

      messages = ['the operands must be manifold solids'] if messages.empty?
      "Solid operation failed: #{messages.join(' ')}"
    end

    def _mcp_parts_for_entity_ids(cutlist, entity_ids)
      ids = Array(entity_ids).map(&:to_i)
      return [] if ids.empty?

      cutlist.get_parts.select { |part| (Array(part.entity_ids).map(&:to_i) & ids).any? }
    end

    def _mcp_boolean_result_response(operation, result_def, operands, cutlist)
      entity_ids = Array(result_def.created_entities).map { |entity| entity.respond_to?(:entityID) ? entity.entityID : nil }.compact
      parts = _mcp_parts_for_entity_ids(cutlist, entity_ids)

      warnings = []
      if Array(result_def.created_entities).empty?
        warnings << 'The operation produced an empty solid; no part was created.'
      elsif parts.empty?
        warnings << 'The solid result was created but OpenCutList does not recognize it as a part. Check that it is a closed solid.'
      end
      if operation == 'outer_shell'
        warnings << 'outer_shell is an alias of union here: the union already removes interior faces, so it returns an outer shell.'
      end

      kept_parts = if operation == 'trim'
                     operands.select { |operand| operand[:entity].valid? }
                             .flat_map { |operand| _mcp_parts_for_entity_ids(cutlist, [operand[:entity_id]]) }
                             .uniq { |part| part.id }
                   else
                     []
                   end

      {
        :operation => operation,
        :result_part_ids => parts.map(&:id),
        :result_entity_ids => entity_ids,
        :results => parts.map { |part| _part_summary(part) },
        :kept_part_ids => kept_parts.map(&:id),
        :operand_entity_ids => operands.map { |operand| operand[:entity_id] },
        :kept_operand_entity_ids => operands.select { |operand| operand[:entity].valid? }.map { |operand| operand[:entity_id] },
        :removed_operand_entity_ids => operands.reject { |operand| operand[:entity].valid? }.map { |operand| operand[:entity_id] },
        :warnings => warnings
      }
    end

    def _mcp_split_result_response(operation, pieces, operands, cutlist)
      entries = pieces.map do |piece|
        applied = piece[:applied]
        entity_ids = applied.nil? ? [] : Array(applied.created_entities).map { |entity| entity.respond_to?(:entityID) ? entity.entityID : nil }.compact
        part = nil
        entity_ids.each { |entity_id| part ||= _find_part_by_entity_ids(cutlist, [entity_id]) }

        {
          :role => piece[:role],
          :empty => applied.nil?,
          :result_part_id => part.nil? ? nil : part.id,
          :result_entity_ids => entity_ids,
          :part => part.nil? ? nil : _part_summary(part)
        }
      end

      warnings = []
      if entries.any? { |entry| entry[:empty] }
        warnings << 'An empty piece produces no part (for example when the intersection is empty).'
      end
      if entries.select { |entry| !entry[:empty] }.any? { |entry| entry[:part].nil? }
        warnings << 'A split piece was created but OpenCutList does not recognize it as a part. Check that it is a closed solid.'
      end

      {
        :operation => operation,
        :results => entries,
        :result_part_ids => entries.map { |entry| entry[:result_part_id] }.compact,
        :result_entity_ids => entries.flat_map { |entry| entry[:result_entity_ids] },
        :operand_entity_ids => operands.map { |operand| operand[:entity_id] },
        :warnings => warnings
      }
    end

    def screenshot_command(params)
      p = _deep_symbolize(params || {})
      model = _require_model
      view = model.active_view
      raise McpError.new('no_view', 'No active SketchUp view is available.') if view.nil?

      width = _clamp((p[:width] || 1200).to_i, 64, 4000)
      height = _clamp((p[:height] || 800).to_i, 64, 4000)
      isolate = p[:isolate] == true
      part_ids = Array(p[:part_ids]).map(&:to_s).reject(&:empty?)

      view_preset = p[:view].to_s.strip.downcase
      view_preset = nil if view_preset.empty?

      camera_params = p[:camera]
      unless camera_params.nil?
        raise McpError.new('invalid_params', 'camera must be an object.') unless camera_params.is_a?(Hash)
        camera_params = _deep_symbolize(camera_params)
      end
      if !view_preset.nil? && !camera_params.nil?
        raise McpError.new('invalid_params', 'Use either view or camera, not both.')
      end
      unless view_preset.nil? || McpPartHelper::VIEW_DIRECTIONS.key?(view_preset)
        raise McpError.new('invalid_params', "Unknown view '#{view_preset}'. Use front, back, left, right, top, bottom or iso.")
      end

      perspective = p[:perspective]
      unless perspective.nil? || perspective == true || perspective == false
        raise McpError.new('invalid_params', 'perspective must be true or false.')
      end

      fov = p[:fov]
      unless fov.nil?
        fov = fov.to_f
        unless fov >= 1.0 && fov <= 120.0
          raise McpError.new('invalid_params', 'fov must be between 1 and 120 degrees.')
        end
      end

      # An explicit camera/view is used as-is; only the old behavior zooms by default.
      zoom_extents = if p.key?(:zoom_extents)
                       p[:zoom_extents] != false
                     else
                       view_preset.nil? && camera_params.nil?
                     end

      parts = []
      paths = []
      target_entities = []
      target_bounds = nil

      unless part_ids.empty?
        cutlist = _cutlist
        part_ids.each do |part_id|
          part = _find_part(cutlist, part_id)
          raise McpError.new('unsupported_entity', 'Virtual parts cannot be isolated in a screenshot.') if part.virtual
          parts << part
          paths.concat(part.def.instance_infos.values.map(&:path))
          target_entities.concat(_resolve_entities(model, part.entity_ids))
        end

        unless parts.empty?
          bounds = Geom::BoundingBox.new
          parts.each do |part|
            part_bounds = _mcp_part_bounds(part)
            bounds.add(part_bounds) unless part_bounds.nil? || part_bounds.empty?
          end
          target_bounds = bounds unless bounds.empty?
        end
      end

      if isolate && paths.empty?
        raise McpError.new('invalid_params', 'isolate requires at least one visible part_id.')
      end

      result = _mcp_capture_screenshot(
        model,
        view,
        paths,
        :width => width,
        :height => height,
        :isolate => isolate,
        :zoom_extents => zoom_extents,
        :target_entities => target_entities,
        :target_bounds => target_bounds,
        :view_preset => view_preset,
        :camera_params => camera_params,
        :perspective => perspective,
        :fov => fov
      )

      result[:part_ids] = parts.map(&:id)
      result[:isolated] = isolate
      result
    end

    # ---------------------------------------------------------------------
    # Materials

    def materials_list_command(params)
      response = PLUGIN.execute_command('materials_list', {})
      materials = Array(response[:materials]).map do |material|
        {
          :id => material[:id],
          :name => material[:name],
          :display_name => material[:display_name],
          :color => material[:color],
          :type => material[:type],
          :type_name => _material_type_name(material[:type]),
          :thickness => material[:thickness],
          :std_sizes => material[:std_sizes],
          :std_thicknesses => material[:std_thicknesses],
          :grained => material[:grained]
        }
      end

      {
        :count => materials.length,
        :materials => materials,
        :errors => response[:errors],
        :warnings => response[:warnings]
      }
    end

    def material_create_command(params)
      p = _deep_symbolize(params || {})
      model = _require_model

      name = p[:name].to_s.strip
      raise McpError.new('invalid_params', 'name is required.') if name.empty?

      display_name = p[:display_name].to_s.strip
      display_name = name if display_name.empty?
      raise McpError.new('material_exists', "A material named '#{display_name}' already exists.") unless model.materials[display_name].nil?

      type = p[:type].nil? ? MaterialAttributes::TYPE_UNKNOWN : _material_type_to_int(p[:type])
      color = p[:color] || _default_material_color(model)

      data = {
        :name => name,
        :display_name => display_name,
        :color => color,
        :type => type,
        :transparent_operation => false
      }
      data[:thickness] = "#{p[:thickness_mm].to_f}mm" unless p[:thickness_mm].nil?

      response = PLUGIN.execute_command('materials_create', data)
      if response.is_a?(Hash) && response[:errors].is_a?(Array) && !response[:errors].empty?
        raise McpError.new('material_create_failed', response[:errors].join(', '))
      end

      {
        :name => display_name,
        :requested_name => name,
        :display_name => display_name,
        :type => type,
        :type_name => _material_type_name(type),
        :result => response
      }
    end

    def material_update_command(params)
      p = _deep_symbolize(params || {})
      model = _require_model

      name = p[:name].to_s.strip
      raise McpError.new('invalid_params', 'name is required.') if name.empty?

      material = model.materials[name]
      raise McpError.new('material_not_found', "Material '#{name}' does not exist.") if material.nil?

      patch = p[:patch]
      raise McpError.new('invalid_params', 'patch must be a non-empty object.') unless patch.is_a?(Hash) && !patch.empty?
      patch = _deep_symbolize(patch)

      allowed_keys = [
        :display_name, :color, :description, :url, :type,
        :thickness, :thickness_mm,
        :length_increase, :length_increase_mm,
        :width_increase, :width_increase_mm,
        :thickness_increase, :thickness_increase_mm,
        :std_sections, :std_lengths, :std_widths, :std_thicknesses, :std_sizes,
        :grained, :edge_decremented, :raw_estimated, :multiplier_coefficient,
        :std_volumic_masses, :std_prices, :std_cut_prices
      ]
      unknown_keys = patch.keys - allowed_keys
      raise McpError.new('invalid_params', "Unsupported patch keys: #{unknown_keys.join(', ')}.") unless unknown_keys.empty?

      # Start from the current full attribute set: MaterialsUpdateWorker writes
      # every field, so a partial hash would silently clear the omitted ones.
      attributes = MaterialAttributes.new(material)
      data = {
        :name => name,
        # Preserve the SketchUp material name unless the patch asks for a
        # rename; display_name is the name the update worker compares against.
        :display_name => material.name,
        :color => ColorUtils.color_to_hex(material.color, '#ffffff'),
        :description => attributes.description.to_s,
        :url => attributes.url.to_s,
        :type => attributes.type,
        :thickness => attributes.thickness.to_s,
        :length_increase => attributes.length_increase.to_s,
        :width_increase => attributes.width_increase.to_s,
        :thickness_increase => attributes.thickness_increase.to_s,
        :std_sections => attributes.std_sections,
        :std_lengths => attributes.std_lengths,
        :std_widths => attributes.std_widths,
        :std_thicknesses => attributes.std_thicknesses,
        :std_sizes => attributes.std_sizes,
        :grained => attributes.grained,
        :edge_decremented => attributes.edge_decremented,
        :raw_estimated => attributes.raw_estimated,
        :multiplier_coefficient => attributes.multiplier_coefficient,
        :std_volumic_masses => attributes.std_volumic_masses,
        :std_prices => attributes.std_prices,
        :std_cut_prices => attributes.std_cut_prices,
        :texture_file => nil,
        :texture_changed => false,
        :texture_rotation => 0,
        :texture_width => nil,
        :texture_height => nil,
        :transparent_operation => false
      }

      patch.each do |key, value|
        case key
        when :display_name
          data[:display_name] = value.to_s
        when :color
          data[:color] = value
        when :description
          data[:description] = value.to_s
        when :url
          data[:url] = value.to_s
        when :type
          data[:type] = _material_type_to_int(value)
        when :thickness
          data[:thickness] = value.to_s
        when :thickness_mm
          data[:thickness] = "#{value.to_f}mm"
        when :length_increase
          data[:length_increase] = value.to_s
        when :length_increase_mm
          data[:length_increase] = "#{value.to_f}mm"
        when :width_increase
          data[:width_increase] = value.to_s
        when :width_increase_mm
          data[:width_increase] = "#{value.to_f}mm"
        when :thickness_increase
          data[:thickness_increase] = value.to_s
        when :thickness_increase_mm
          data[:thickness_increase] = "#{value.to_f}mm"
        when :std_sections, :std_lengths, :std_widths, :std_thicknesses, :std_sizes,
             :grained, :edge_decremented, :raw_estimated, :multiplier_coefficient,
             :std_volumic_masses, :std_prices, :std_cut_prices
          data[key] = value
        end
      end

      response = PLUGIN.execute_command('materials_update', data)
      if response.is_a?(Hash) && response[:errors].is_a?(Array) && !response[:errors].empty?
        raise McpError.new('material_update_failed', response[:errors].join(', '))
      end

      updated_attributes = MaterialAttributes.new(material)
      {
        :name => material.name,
        :requested_name => name,
        :display_name => material.name,
        :material_display_name => material.display_name,
        :renamed => material.name != name,
        :color => ColorUtils.color_to_hex(material.color),
        :type => updated_attributes.type,
        :type_name => _material_type_name(updated_attributes.type),
        :thickness => updated_attributes.thickness,
        :description => updated_attributes.description,
        :url => updated_attributes.url
      }
    end

    def material_delete_command(params)
      p = _deep_symbolize(params || {})
      model = _require_model

      name = p[:name].to_s.strip
      raise McpError.new('invalid_params', 'name is required.') if name.empty?

      material = model.materials[name]
      raise McpError.new('material_not_found', "Material '#{name}' does not exist.") if material.nil?

      cutlist = _cutlist
      using_groups = cutlist.groups.select { |group| group.material_name == name }
      if using_groups.any? && p[:force] != true
        raise McpError.new(
          'material_in_use',
          "Material '#{name}' is used by #{using_groups.length} cutlist group(s). Reassign those parts first, or pass force: true."
        )
      end

      warnings = []
      warnings << "Material '#{name}' is used by #{using_groups.length} cutlist group(s); deletion was forced." if using_groups.any?

      model.start_operation('OCL MCP: Delete Material', true)
      begin
        response = PLUGIN.execute_command('materials_delete', { :name => name })
        if response.is_a?(Hash) && response[:success]
          model.commit_operation
        else
          errors = response.is_a?(Hash) ? Array(response[:errors]) : []
          raise McpError.new(
            'material_delete_failed',
            errors.empty? ? 'OpenCutList failed to delete the material.' : errors.join(', ')
          )
        end
      rescue Exception => e
        begin
          model.abort_operation
        rescue StandardError
          # Nothing to abort.
        end
        raise e
      end

      {
        :deleted => true,
        :name => name,
        :warnings => warnings
      }
    end

    # ---------------------------------------------------------------------
    # Cutlist

    def cutlist_get_command(params)
      p = _deep_symbolize(params || {})
      include_parts = p[:include_parts] != false

      cutlist = _cutlist
      groups = cutlist.groups.map do |group|
        parts = include_parts ? group.get_parts : []
        {
          :id => group.id,
          :material_name => group.material_name,
          :material_display_name => group.material_display_name,
          :material_type => _material_type_name(group.material_type),
          :material_is_virtual => group.material_is_virtual,
          :part_count => group.part_count,
          :total_cutting_length => group.total_cutting_length,
          :total_cutting_area => group.total_cutting_area,
          :total_cutting_volume => group.total_cutting_volume,
          :parts => include_parts ? parts.map { |part| _part_summary(part) } : nil
        }
      end

      {
        :errors => cutlist.errors,
        :warnings => cutlist.warnings,
        :tips => cutlist.tips,
        :groups => groups
      }
    end

    # ---------------------------------------------------------------------
    # Shared helpers

    def _cutlist(options = {})
      preset = PLUGIN.get_model_preset('cutlist_options') || {}
      preset = _deep_symbolize(preset)

      settings = {
        :ignore_selection => true,
        :scope => :model,
        :names_filter => '',
        :tags_filter => [],
        :edge_material_names_filter => [],
        :veneer_material_names_filter => []
      }.merge(preset).merge(options)

      CutlistGenerateWorker.new(**settings).run
    end

    def _require_model
      model = Sketchup.active_model
      raise McpError.new('no_model', 'No SketchUp model is open.') if model.nil?
      model
    end

    def _find_part(cutlist, part_id)
      part = cutlist.get_part(part_id)
      if part.nil?
        raise McpError.new('part_not_found', "No part with id '#{part_id}'. Call ocl_list_parts to get fresh ids.")
      end
      part
    end

    def _find_part_by_entity_ids(cutlist, entity_ids)
      ids = Array(entity_ids).map(&:to_i)
      return nil if ids.empty?
      cutlist.get_parts.find { |part| (Array(part.entity_ids).map(&:to_i) & ids).any? }
    end

    def _resolve_entities(model, entity_ids)
      Array(entity_ids).map { |entity_id| model.find_entity_by_id(entity_id.to_i) }.compact
    end

    def _rename_part_instances(model, entity_ids, name)
      model.start_operation('OCL MCP: Rename Part', true)
      begin
        _resolve_entities(model, entity_ids).each do |entity|
          entity.name = name if entity.respond_to?(:name=)
        end
        model.commit_operation
      rescue Exception => e
        begin
          model.abort_operation
        rescue StandardError
          # Nothing to abort.
        end
        raise e
      end
    end

    def _part_summary(part)
      size = part.def.size
      cutting_size = part.def.cutting_size
      instances = part.def.instance_infos.values.sort_by(&:serialized_path).map { |instance_info| _mcp_instance_world_info(instance_info, size.axes) }

      {
        :part_id => part.id,
        :group_id => part.group.id,
        :number => part.number,
        :name => part.name,
        :virtual => part.virtual,
        :definition_id => part.respond_to?(:definition_id) ? part.definition_id : nil,
        :length_mm => _mcp_mm(size.length),
        :width_mm => _mcp_mm(size.width),
        :thickness_mm => _mcp_mm(size.thickness),
        :cutting_length_mm => _mcp_mm(cutting_size.length),
        :cutting_width_mm => _mcp_mm(cutting_size.width),
        :cutting_thickness_mm => _mcp_mm(cutting_size.thickness),
        :count => part.count,
        :material => part.group.material_name,
        :material_type => _material_type_name(part.group.material_type),
        :tags => part.tags,
        :edge_materials => part.edge_material_names,
        :face_materials => part.face_material_names,
        :entity_ids => part.entity_ids,
        :instance_count => instances.length,
        :bounds_mm => _mcp_part_world_bounds_mm(part),
        :instances => instances
      }
    end

    def _part_detail(part)
      size = part.def.size
      model = Sketchup.active_model
      {
        :summary => _part_summary(part),
        :axes => size.axes.map { |axis| _mcp_axis_name(axis) },
        :edge_material_raw_colors => _raw_material_colors(model, part.edge_material_names),
        :face_material_raw_colors => _raw_material_colors(model, part.face_material_names),
        :hash => part.to_hash
      }
    end

    # Raw material colours, as opposed to OCL's edge_material_colors which are
    # deliberately darkened for display over white panels.
    def _raw_material_colors(model, names)
      return {} unless names.is_a?(Hash) && !model.nil?

      names.each_with_object({}) do |(role, name), result|
        material = name.nil? ? nil : model.materials[name]
        result[role] = material.nil? ? nil : ColorUtils.color_to_hex(material.color)
      end
    end

    def _positive_mm(value, name)
      number = value.to_f
      raise McpError.new('invalid_params', "#{name} is required and must be > 0.") unless number > 0
      raise McpError.new('invalid_params', "#{name} must be <= #{MAX_DIMENSION_MM.to_i} mm.") if number > MAX_DIMENSION_MM
      number
    end

    def _material_type_to_int(value)
      return value if value.is_a?(Integer) && value >= 0 && value <= 7
      type = MATERIAL_TYPES[value.to_s.strip.downcase]
      raise McpError.new('invalid_params', "Unknown material type '#{value}'.") if type.nil?
      type
    end

    # OCL's type_strippedname returns the historical 'unknow' spelling; expose
    # the same value the tool inputs accept ('unknown') at the MCP boundary.
    def _material_type_name(type)
      name = MaterialAttributes.type_strippedname(type)
      name == 'unknow' ? 'unknown' : name
    end

    def _validate_material_exists(model, name)
      return if name.nil?
      raise McpError.new('material_not_found', "Material '#{name}' does not exist. Create it with ocl_create_material.") if model.materials[name].nil?
    end

    def _validate_material_type(model, name, expected_type)
      return if name.nil?
      material = model.materials[name]
      raise McpError.new('material_not_found', "Material '#{name}' does not exist. Create it with ocl_create_material.") if material.nil?

      actual_type = MaterialAttributes.new(material).type
      return if actual_type == expected_type

      raise McpError.new(
        'invalid_material_type',
        "Material '#{name}' has type '#{_material_type_name(actual_type)}', expected '#{_material_type_name(expected_type)}'."
      )
    end

    def _default_material_color(model)
      DEFAULT_MATERIAL_COLORS[model.materials.length % DEFAULT_MATERIAL_COLORS.length]
    end

    def _deep_symbolize(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, child), result| result[key.respond_to?(:to_sym) ? key.to_sym : key] = _deep_symbolize(child) }
      when Array
        value.map { |child| _deep_symbolize(child) }
      else
        value
      end
    end

    def _stringify_keys(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, child), result| result[key.to_s] = _stringify_keys(child) }
      when Array
        value.map { |child| _stringify_keys(child) }
      else
        value
      end
    end

    def _clamp(value, min, max)
      [ [ value, min ].max, max ].min
    end

    def _version
      defined?(EXTENSION_VERSION) ? EXTENSION_VERSION : 'unknown'
    end

    def _model_name
      model = Sketchup.active_model
      model.nil? ? nil : model.name
    end

    def _discovery_file
      File.join(Dir.home, '.ocl-mcp', 'bridge.json')
    end

    def _length_unit_name(unit)
      case unit
      when 0 then 'inches'
      when 1 then 'feet'
      when 2 then 'millimeters'
      when 3 then 'centimeters'
      when 4 then 'meters'
      when 5 then 'yards'
      else 'unknown'
      end
    end

  end

end
