# interactive_pipe_tool.rb
require 'sketchup.rb'

# Conditionally define key constants to avoid warnings
unless defined?(VK_RETURN)
  VK_RETURN = 13
  VK_ESCAPE = 27
  VK_D = 68
  IDC_PENCIL = 631

  # Arrow keys
  VK_LEFT   = 37
  VK_UP     = 38
  VK_RIGHT  = 39
  VK_DOWN   = 40
end

class InteractivePipeTool
  PIPE_RADIUS = 1.inch
  PIPE_SIDES = 16
  DEFAULT_LAYER_NAME = "3D_Pipes"
  HIGHLIGHT_COLOR = Sketchup::Color.new(255, 200, 0, 200)
  AXIS_COLORS = {x: "Red", y: "Green", z: "Blue"}
  SNAP_DISTANCE = 10 # pixels for axis snapping

  # Axis vectors
  X_AXIS = Geom::Vector3d.new(1, 0, 0)
  Y_AXIS = Geom::Vector3d.new(0, 1, 0)
  Z_AXIS = Geom::Vector3d.new(0, 0, 1)

  def initialize
    @active_operation = nil
    @current_mouse_x = 0
    @current_mouse_y = 0
  end

  def activate
    @model = Sketchup.active_model
    @view = @model.active_view
    @ip = Sketchup::InputPoint.new
    @points = []
    @current_pipe_component = nil
    @length_input = ""
    @bulge_input = ""
    @active = true
    @axis_lock = nil
    @lock_direction = nil
    @view.invalidate

    @view.tooltip = "Click to start. Enter to finish. Arrow keys to lock axes. 'D' to delete."

    UI.set_cursor(IDC_PENCIL)

    @pipe_layer = @model.layers[DEFAULT_LAYER_NAME] || @model.layers.add(DEFAULT_LAYER_NAME)
    @pipe_layer.visible = true
    @deletion_mode = false
    @input_mode = :length # :length or :bulge
    @last_axis_lock = nil
  end

  def deactivate(view)
    commit_and_reset
    @active = false
    view.invalidate
  end

  def resume(view)
    @active = true
    view.invalidate
    UI.set_cursor(IDC_PENCIL)
  end

  def suspend(view)
    view.invalidate
  end

  def onLButtonDown(flags, x, y, view)
    return unless @active

    if @deletion_mode
      ph = view.pick_helper
      ph.do_pick(x, y)
      entity = ph.best_picked

      if entity && entity.respond_to?(:definition) &&
         entity.definition.name == "3D_Pipe_Component"
        entity.erase!
        view.tooltip = "Pipe deleted"
        view.invalidate
        return
      end
    else
      current_point = @ip.position
      
      # Apply axis lock if active
      if @axis_lock && @lock_direction && !@points.empty?
        vector = current_point - @points.last
        if vector.valid?
          scalar = vector.dot(@lock_direction)
          current_point = @points.last.offset(@lock_direction, scalar)
        end
      end
      
      if @points.empty?
        @active_operation = @model.start_operation('Create 3D Pipe', true)
        @current_pipe_component = create_new_pipe_component
      end
      
      @points << current_point

      # Create segment if we have at least 2 points
      if @points.length > 1
        bulge = @bulge_input.empty? ? 0 : @bulge_input.to_l
        create_pipe_segment(@points[-2], current_point, bulge)
        @bulge_input = ""
      end
      
      # Reset after placing point
      @length_input = ""
      @axis_lock = nil
      @lock_direction = nil
      @last_axis_lock = nil
    end

    view.invalidate
  end

  def onMouseMove(flags, x, y, view)
    return unless @active

    if @points.empty?
      @ip.pick(view, x, y)
    else
      temp_ip = Sketchup::InputPoint.new(@points.last)
      @ip.pick(view, x, y, temp_ip)
    end
    
    @mouse_position = @ip.position
    @current_mouse_x = x
    @current_mouse_y = y

    if @deletion_mode
      return
    end

    # Automatic axis snapping logic
    if !@points.empty? && !@axis_lock
      base_point = @points.last
      mouse_vector = @mouse_position - base_point
      
      if mouse_vector.valid? && mouse_vector.length > 0
        mouse_direction = mouse_vector.normalize
        
        # Calculate which axis is closest
        angle_x = mouse_direction.angle_between(X_AXIS)
        angle_y = mouse_direction.angle_between(Y_AXIS)
        angle_z = mouse_direction.angle_between(Z_AXIS)
        
        min_angle = [angle_x, angle_y, angle_z].min
        
        # Only update if significantly different direction
        if min_angle < 0.1 # ~5.7 degrees
          if min_angle == angle_x
            @lock_direction = X_AXIS
            @axis_lock = :x
          elsif min_angle == angle_y
            @lock_direction = Y_AXIS
            @axis_lock = :y
          else
            @lock_direction = Z_AXIS
            @axis_lock = :z
          end
        else
          @axis_lock = nil
          @lock_direction = nil
        end
      end
    end

    # Apply length input if we have one
    if !@length_input.empty? && !@points.empty?
      base_point = @points.last
      direction = @lock_direction || (base_point.vector_to(@mouse_position).normalize rescue X_AXIS)
      
      begin
        # Convert meter input to model units
        if @length_input.end_with?('m')
          value = @length_input[0..-2].to_f
          length_value = value.meters
        else
          length_value = @length_input.to_l
        end
        @mouse_position = base_point.offset(direction, length_value)
      rescue
        # Ignore invalid input
      end
    end
    
    # Force immediate update if axis lock changed
    if @last_axis_lock != @axis_lock
      view.invalidate
      @last_axis_lock = @axis_lock
    end
    
    update_tooltip(view)
  end

  def onKeyDown(key, repeat, flags, view)
    return unless @active
    
    # Use stored mouse position
    x = @current_mouse_x
    y = @current_mouse_y
    
    case key
    when VK_RETURN
      if @input_mode == :length && !@length_input.empty?
        # Apply length input
        onMouseMove(flags, x, y, view)
        @input_mode = :bulge
        view.tooltip = "Enter bulge distance (e.g., 0.5m) or click to place"
      elsif @input_mode == :bulge
        # Place point with current bulge
        onLButtonDown(flags, x, y, view)
        @input_mode = :length
      else
        # Finish operation
        commit_and_reset
      end
      view.invalidate
      return true
      
    when VK_ESCAPE
      onCancel(0, view)
      view.invalidate
      return true
      
    # Arrow key bindings:
    when VK_RIGHT # Lock to X-axis (Red)
      @axis_lock = @axis_lock == :x ? nil : :x
      @lock_direction = @axis_lock == :x ? X_AXIS : nil
      update_tooltip(view)
      onMouseMove(flags, x, y, view)
      return true

    when VK_LEFT # Lock to Y-axis (Green)
      @axis_lock = @axis_lock == :y ? nil : :y
      @lock_direction = @axis_lock == :y ? Y_AXIS : nil
      update_tooltip(view)
      onMouseMove(flags, x, y, view)
      return true

    when VK_UP # Lock to Z-axis (Blue)
      @axis_lock = @axis_lock == :z ? nil : :z
      @lock_direction = @axis_lock == :z ? Z_AXIS : nil
      update_tooltip(view)
      onMouseMove(flags, x, y, view)
      return true
      
    when VK_D # 'D' for Deletion Mode
      @deletion_mode = !@deletion_mode
      update_tooltip(view)
      return true
      
    when 8 # Backspace
      if @input_mode == :length && !@length_input.empty?
        @length_input.chop!
      elsif @input_mode == :bulge && !@bulge_input.empty?
        @bulge_input.chop!
      end
      update_tooltip(view)
      onMouseMove(flags, x, y, view)
      return true
    end
    
    # Handle numeric input and meter unit
    if key >= 48 && key <= 57 || key == 46 || key == 109 || key == 77
      char = [key].pack('U')
      
      # Convert uppercase M to lowercase
      char = 'm' if char == 'M'
      
      # For meter input, only allow at the end and only once
      if char == 'm'
        if @input_mode == :length
          @length_input << 'm' unless @length_input.include?('m')
        elsif @input_mode == :bulge
          @bulge_input << 'm' unless @bulge_input.include?('m')
        end
      else
        # For digits and decimal, just append
        if @input_mode == :length
          @length_input << char
        elsif @input_mode == :bulge
          @bulge_input << char
        end
      end
      
      update_tooltip(view)
      onMouseMove(flags, x, y, view)
      return true
    end
    
    false
  end

  def onUserText(text, view)
    # Handled in onKeyDown now
  end

  def onReturn(view)
    commit_and_reset
    view.invalidate
  end

  def onCancel(reason, view)
    if @active_operation
      @model.abort_operation
      @active_operation = nil
    end
    reset_tool_state
    view.invalidate
  end

  def draw(view)
    return unless @active
    
    # Use stored mouse position
    x = @current_mouse_x
    y = @current_mouse_y
    
    if @deletion_mode
      ph = view.pick_helper
      ph.do_pick(x, y)
      entity = ph.best_picked
      
      if entity && entity.respond_to?(:definition) &&
         entity.definition.name == "3D_Pipe_Component"
        view.drawing_color = HIGHLIGHT_COLOR
        view.draw_points(entity.bounds.center, 20, 1, HIGHLIGHT_COLOR)
      end
    end
    
    @ip.draw(view)
    
    # Draw axis lock line
    if @axis_lock && !@points.empty?
      base_point = @points.last
      start_pt = base_point.offset(@lock_direction.reverse, 1000.inch)
      end_pt = base_point.offset(@lock_direction, 1000.inch)
      
      view.drawing_color = AXIS_COLORS[@axis_lock]
      view.line_width = 2
      view.draw(GL_LINES, [start_pt, end_pt])
    end
    
    if @points.size > 0
      view.drawing_color = HIGHLIGHT_COLOR
      view.line_width = 3
      view.draw_points(@points, 10, 4, HIGHLIGHT_COLOR)
    end
    
    # Preview line
    if !@points.empty? && @ip.valid?
      start_point = @points.last
      end_point = @mouse_position
      
      bulge = @bulge_input.empty? ? 0 : @bulge_input.to_l
      
      if bulge != 0
        draw_preview_curve(view, start_point, end_point, bulge)
      else
        draw_preview_line(view, start_point, end_point)
      end
      
      # Draw length value
      if !@length_input.empty?
        mid_point = Geom.linear_combination(0.5, start_point, 0.5, end_point)
        view.draw_text(mid_point, @length_input, :size => 20)
      end
    end
  end

  private

  def update_tooltip(view)
    if @deletion_mode
      view.tooltip = "Deletion Mode: Click to delete a pipe"
    elsif @input_mode == :bulge
      view.tooltip = "Bulge: #{@bulge_input.empty? ? '0' : @bulge_input} (Enter to apply)"
    else
      tip = "Length: #{@length_input.empty? ? '0' : @length_input} (Enter to apply)"
      tip += " | Arrow keys: " + 
             (@axis_lock ? "Locked to #{@axis_lock.upcase}" : "Unlocked")
      view.tooltip = tip
    end
  end

  def create_new_pipe_component
    definition = @model.definitions.add("3D_Pipe_Component")
    definition.description = "3D Pipe created by Interactive Pipe Tool"
    instance = @model.active_entities.add_instance(definition, Geom::Transformation.new)
    instance.layer = @pipe_layer
    instance.name = "3D Pipe #{Time.now.to_i}"
    instance # Return the instance, not the entities
  end

  def create_pipe_segment(start_point, end_point, bulge)
    # Check if the component instance is still valid
    return if @current_pipe_component.nil? || @current_pipe_component.deleted?
    
    # Access the entities of the component definition
    definition = @current_pipe_component.definition
    return if definition.deleted?
    
    entities = definition.entities
    
    vector = end_point - start_point
    return if vector.length == 0

    path_entities = []
    
    if bulge != 0
      # Create curve for path
      mid_point = Geom.linear_combination(0.5, start_point, 0.5, end_point)
      normal = vector.cross(Z_AXIS)
      normal = vector.cross(X_AXIS) if normal.length == 0
      offset_vec = normal.normalize * bulge
      curve_points = [start_point, mid_point.offset(offset_vec), end_point]
      path_entities.concat(entities.add_curve(curve_points))
    else
      # Create line for path
      path_entities << entities.add_line(start_point, end_point)
    end
    
    # Create profile and FollowMe
    return if path_entities.empty?
    
    # For curves, use the direction of the first segment
    if path_entities.first.is_a?(Sketchup::Curve)
      edge = path_entities.first.edges.first
      profile_normal = edge.line[1] if edge
    else
      profile_normal = vector.normalize
    end
    
    # Fallback if we couldn't get a normal
    profile_normal ||= vector.normalize
    
    circle_edges = create_pipe_profile(entities, start_point, profile_normal)
    face = entities.add_face(circle_edges)

    # Check if face is created and valid
    if face && face.valid?
      # Reverse face if needed
      face.reverse! unless face.normal.samedirection?(profile_normal)
      
      face.followme(path_entities)
    end
    
    # Clean up
    begin
      entities.erase_entities(path_entities) 
    rescue
      # Ignore errors in case entities were already deleted
    end
  end
  
  def create_pipe_profile(entities, point, vector)
    # Find a perpendicular axis
    axis = vector.parallel?(Z_AXIS) ? X_AXIS : Z_AXIS.cross(vector)
    entities.add_circle(point, vector, PIPE_RADIUS, PIPE_SIDES)
  end

  def draw_preview_line(view, start_point, end_point)
    view.drawing_color = "Black"
    view.line_width = 3
    view.draw(GL_LINES, [start_point, end_point])
    
    # Draw direction indicator
    vec = end_point - start_point
    if vec.length > 0
      dir = vec.normalize
      perp = dir.cross(Z_AXIS)
      perp = dir.cross(X_AXIS) if perp.length == 0
      perp.length = PIPE_RADIUS
      
      arrow_points = [
        end_point,
        end_point.offset(dir.reverse, 1.inch).offset(perp, 0.5.inch),
        end_point.offset(dir.reverse, 1.inch).offset(perp.reverse, 0.5.inch),
        end_point
      ]
      view.draw_polyline(arrow_points)
    end
  end
  
  def draw_preview_curve(view, start_point, end_point, bulge)
    vector = end_point - start_point
    return if vector.length == 0
    
    mid_point = Geom.linear_combination(0.5, start_point, 0.5, end_point)
    normal = vector.cross(Z_AXIS)
    normal = vector.cross(X_AXIS) if normal.length == 0
    offset_vec = normal.normalize * bulge
    curve_points = [start_point, mid_point.offset(offset_vec), end_point]
    
    view.drawing_color = "Black"
    view.line_width = 3
    view.draw_polyline(curve_points)
    
    # Draw bulge value
    view.draw_text(mid_point.offset(offset_vec), "Bulge: #{bulge.to_s}", :size => 20)
  end

  def commit_and_reset
    if @active_operation
      @model.commit_operation
      @active_operation = nil
    end
    reset_tool_state
  end

  def reset_tool_state
    @points = []
    @current_pipe_component = nil
    @length_input = ""
    @bulge_input = ""
    @axis_lock = nil
    @lock_direction = nil
    @deletion_mode = false
    @input_mode = :length
    @last_axis_lock = nil
    @view.tooltip = "Click to start. Enter to finish. Arrow keys to lock axes. 'D' to delete."
  end

end

# Toolbar and menu integration
unless defined?($interactive_pipe_tool_loaded)
  cmd = UI::Command.new("3D Pipe Tool") {
    model = Sketchup.active_model
    if model.tools.active_tool.is_a?(InteractivePipeTool)
      model.select_tool(nil)
    else
      model.select_tool(InteractivePipeTool.new)
    end
  }
  
  cmd.tooltip = "Interactive 3D Pipe Tool"
  cmd.status_bar_text = "Create and edit 3D pipes with precise axis control"
  
  toolbar = UI::Toolbar.new "3D Pipe Tool"
  toolbar.add_item cmd
  toolbar.show if toolbar.get_last_state == TB_VISIBLE
  
  UI.menu("Draw").add_item(cmd)
  
  $interactive_pipe_tool_loaded = true
end