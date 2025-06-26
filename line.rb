require 'sketchup.rb'

class InteractivePipeTool
  PIPE_RADIUS = 1.inch
  PIPE_SIDES = 16
  DEFAULT_LAYER_NAME = "3D_Pipes"
  HIGHLIGHT_COLOR = Sketchup::Color.new(255, 200, 0, 200)  # Orange highlight
  AXIS_HIGHLIGHT_COLOR = Sketchup::Color.new(0, 200, 255, 200)  # Cyan for axes
  AXIS_LOCK_ENABLED = true

  def activate
    @model = Sketchup.active_model
    @view = @model.active_view
    @ip = Sketchup::InputPoint.new
    @points = []
    @current_pipe_component = nil
    @length_input = nil
    @override_position = nil
    @bulge_distance = 0
    @active = true
    @axis_lock = nil  # :x, :y, :z, or nil
    @view.tooltip = "Click to start pipe. Enter to finish. Type length for exact distance. 'b' for bulge. Press X/Y/Z to lock axes. Click on pipe to delete."
    @view.invalidate
    
    # Set pencil cursor
    UI.set_cursor(IDC_PENCIL)
    
    # Create or get the pipe layer
    @pipe_layer = @model.layers[DEFAULT_LAYER_NAME] || @model.layers.add(DEFAULT_LAYER_NAME)
    @pipe_layer.visible = true
    
    # Create a deletion mode flag
    @deletion_mode = false
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
      # Handle pipe deletion
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
      # Handle pipe creation
      current_point = @override_position || @ip.position
      
      if @points.empty?
        @model.start_operation('Create 3D Pipe', true)
        @current_pipe_component = create_new_pipe_component
      end
      
      @points << current_point

      if @points.length > 1
        create_pipe_segment(@points[-2], current_point, @bulge_distance)
        @bulge_distance = 0 # Reset bulge after segment creation
      end
      
      # Reset axis lock after each point
      @axis_lock = nil
    end
    
    view.invalidate
  end

  def onMouseMove(flags, x, y, view)
    return unless @active
    
    @ip.pick(view, x, y)
    @mouse_position = @ip.position
    
    # Handle deletion mode highlighting
    if @deletion_mode
      ph = view.pick_helper
      ph.do_pick(x, y)
      entity = ph.best_picked
      
      if entity && entity.respond_to?(:definition) && 
         entity.definition.name == "3D_Pipe_Component"
        view.tooltip = "Click to delete pipe"
        view.invalidate
        return
      else
        view.tooltip = "Move mouse over a pipe to delete it"
      end
    end
    
    # Handle axis lock
    if @axis_lock && !@points.empty?
      base_point = @points.last
      case @axis_lock
      when :x
        @override_position = Geom::Point3d.new(
          @ip.position.x,
          base_point.y,
          base_point.z
        )
      when :y
        @override_position = Geom::Point3d.new(
          base_point.x,
          @ip.position.y,
          base_point.z
        )
      when :z
        @override_position = Geom::Point3d.new(
          base_point.x,
          base_point.y,
          @ip.position.z
        )
      end
    end
    
    # Handle length constraint
    if @length_input && !@points.empty?
      base_point = @points.last
      target_point = @override_position || @ip.position
      vector = target_point - base_point
      if vector.length > 0
        direction = vector.normalize
        @override_position = base_point + direction * @length_input
      else
        @override_position = nil
      end
    end
    
    view.invalidate
  end

  def onUserText(text, view)
    return unless @active
    
    # Handle bulge input (prefix with 'b')
    if text.downcase.start_with?('b')
      begin
        @bulge_distance = text[1..-1].to_l
        view.tooltip = "Bulge: #{@bulge_distance}"
        view.invalidate
        return
      rescue
        # Ignore conversion errors
      end
    end
    
    # Handle length input in meters
    begin
      # Try to parse input as meters
      if text.include?(',')
        # Handle coordinate input (x,y)
        parts = text.split(',')
        if parts.length == 2
          x = parts[0].to_l
          y = parts[1].to_l
          if !@points.empty?
            base_point = @points.last
            # Get current view vectors
            camera = view.camera
            right = camera.xaxis
            up = camera.yaxis
            
            # Create new point relative to base point
            @override_position = base_point + (right * x) + (up * y)
            @length_input = nil
            view.tooltip = "Position: #{x}m, #{y}m"
            view.invalidate
            return
          end
        end
      else
        # Handle single length value
        value = text.to_l
        if value > 0
          @length_input = value
          view.tooltip = "Length: #{@length_input}m"
          
          # Immediately apply length constraint
          if !@points.empty? && @ip.valid?
            base_point = @points.last
            vector = @ip.position - base_point
            if vector.length > 0
              direction = vector.normalize
              @override_position = base_point + direction * @length_input
            end
          end
        else
          @length_input = nil
        end
      end
    rescue
      @length_input = nil
    end
    
    view.invalidate
  end

  def onKeyDown(key, repeat, flags, view)
    return unless @active
    
    case key
    when VK_RETURN
      commit_and_reset
      view.invalidate
      return true
    when VK_ESCAPE
      onCancel(0, view)
      view.invalidate
      return true
    when 88 # 'X' key
      @axis_lock = :x
      view.tooltip = "X-Axis Locked"
      return true
    when 89 # 'Y' key
      @axis_lock = :y
      view.tooltip = "Y-Axis Locked"
      return true
    when 90 # 'Z' key
      @axis_lock = :z
      view.tooltip = "Z-Axis Locked"
      return true
    when 68 # 'D' key - toggle deletion mode
      @deletion_mode = !@deletion_mode
      if @deletion_mode
        view.tooltip = "Deletion Mode: Move mouse over a pipe and click to delete"
      else
        view.tooltip = "Creation Mode: Click to place pipe points"
      end
      return true
    end
    false
  end

  def onReturn(view)
    commit_and_reset
    view.invalidate
  end

  def onCancel(reason, view)
    if @model.active_operation?
      @model.abort_operation
    end
    reset_tool_state
    view.invalidate
  end

  def draw(view)
    return unless @active
    
    # Draw deletion mode highlight
    if @deletion_mode
      # Highlight all existing pipe components
      @model.definitions.each do |definition|
        next unless definition.name == "3D_Pipe_Component"
        
        definition.instances.each do |instance|
          # Draw bounding box around the pipe
          bb = instance.bounds
          view.drawing_color = Sketchup::Color.new(255, 0, 0)  # Red for deletion mode
          view.line_width = 3
          view.draw(GL_LINE_LOOP, bb_corners(bb))
        end
      end
      
      # Skip drawing creation elements in deletion mode
      return
    end
    
    @ip.draw(view)
    
    # Draw axis locks if active
    if @axis_lock && !@points.empty? && @ip.valid?
      base_point = @points.last
      axis_vector = case @axis_lock
                   when :x then X_AXIS
                   when :y then Y_AXIS
                   when :z then Z_AXIS
                   end
      
      # Draw the axis line
      end_point = base_point.offset(axis_vector, 1000)  # Long line
      view.drawing_color = AXIS_HIGHLIGHT_COLOR
      view.line_width = 5
      view.draw(GL_LINES, [base_point, end_point])
      
      # Draw a large plus sign at the base point
      draw_axis_indicator(view, base_point, @axis_lock)
    end
    
    # Draw constraint circle if length is set
    if @length_input && !@points.empty? && @ip.valid?
      base_point = @points.last
      camera = view.camera
      normal = camera.direction
      circle_points = compute_circle(base_point, normal, @length_input, 32)
      view.drawing_color = [128, 128, 128]
      view.line_width = 1
      view.draw(GL_LINE_LOOP, circle_points)
    end
    
    # Draw all placed points
    if @points.size > 0
      view.drawing_color = HIGHLIGHT_COLOR
      view.line_width = 3
      view.draw_points(@points, 10, 1, HIGHLIGHT_COLOR)
      
      # Draw a large plus sign at the last point
      draw_large_plus_at_point(view, @points.last) unless @axis_lock
    end
    
    # Draw existing segments
    if @points.size > 1
      view.drawing_color = HIGHLIGHT_COLOR
      view.line_width = 9  # 3x original width
      view.draw(GL_LINE_STRIP, @points)
    end
    
    # Draw preview from last point to mouse position
    if !@points.empty? && (@ip.valid? || @override_position)
      start_point = @points.last
      end_point = @override_position || @ip.position
      
      if @bulge_distance != 0
        draw_preview_curve(view, start_point, end_point, @bulge_distance)
      else
        draw_preview_line(view, start_point, end_point)
      end
    end
  end

  private

  def create_new_pipe_component
    # Create a component definition
    definition = @model.definitions.add("3D_Pipe_Component")
    definition.description = "3D Pipe created by Interactive Pipe Tool"
    
    # Create an instance of the component
    instance = @model.active_entities.add_instance(definition, IDENTITY)
    instance.layer = @pipe_layer
    instance.name = "3D Pipe #{Time.now.to_i}"
    
    # Return the entities collection for the component
    definition.entities
  end

  def create_pipe_segment(start_point, end_point, bulge)
    return unless @current_pipe_component
    
    if bulge != 0
      # Create curved segment
      curve_points = generate_curve_points(start_point, end_point, bulge)
      path = @current_pipe_component.add_curve(curve_points)
      pipe_path = path.first
      
      # Create pipe profile
      vector = curve_points[1] - curve_points[0]
      circle = create_pipe_profile(@current_pipe_component, start_point, vector)
      face = @current_pipe_component.add_face(circle)
      
      # Create pipe
      face.followme(pipe_path)
      pipe_path.erase!
    else
      # Create straight segment
      vector = end_point - start_point
      return if vector.length == 0

      circle = create_pipe_profile(@current_pipe_component, start_point, vector)
      face = @current_pipe_component.add_face(circle)
      return unless face && face.normal.samedirection?(vector)

      path = @current_pipe_component.add_line(start_point, end_point)
      face.followme(path)
      path.erase!
    end
    
    # Smooth joints between segments
    if @points.length > 2
      smooth_joints(@current_pipe_component)
    end
  end
  
  def create_pipe_profile(entities, point, vector)
    # Find perpendicular axis
    axis = if vector.parallel?(Z_AXIS)
             X_AXIS
           else
             vector * Z_AXIS
           end
    entities.add_circle(point, vector, PIPE_RADIUS, PIPE_SIDES)
  end

  def generate_curve_points(start_point, end_point, bulge)
    mid_point = Geom.linear_combination(0.5, start_point, 0.5, end_point)
    direction = (end_point - start_point).normalize
    perpendicular = direction.axes.z
    curve_point = mid_point + perpendicular * bulge
    
    # Create a smooth curve with 3 points
    [start_point, curve_point, end_point]
  end

  def draw_preview_curve(view, start_point, end_point, bulge)
    curve_points = generate_curve_points(start_point, end_point, bulge)
    view.drawing_color = HIGHLIGHT_COLOR
    view.line_width = 9  # Thicker line
    view.draw(GL_LINE_STRIP, curve_points)
  end

  def draw_preview_line(view, start_point, end_point)
    view.drawing_color = HIGHLIGHT_COLOR
    view.line_width = 9  # Thicker line (3x original)
    view.draw(GL_LINES, [start_point, end_point])
  end

  def compute_circle(center, normal, radius, segments)
    # Find perpendicular vectors
    axis1 = normal.arbitrary_perpendicular.normalize
    axis2 = normal * axis1

    circle_points = []
    segments.times do |i|
      angle = 2 * Math::PI * i / segments
      x = radius * Math.cos(angle)
      y = radius * Math.sin(angle)
      point = center + axis1 * x + axis2 * y
      circle_points << point
    end
    circle_points
  end

  def smooth_joints(entities)
    # Find all edges in the pipe group
    edges = entities.grep(Sketchup::Edge)
    
    # Group edges by their connected faces
    edge_groups = {}
    edges.each do |edge|
      edge.faces.each do |face|
        edge_groups[face] ||= []
        edge_groups[face] << edge
      end
    end
    
    # Smooth edges that are part of the same face
    edge_groups.each do |face, face_edges|
      face_edges.each do |edge|
        edge.soft = true
        edge.smooth = true
      end
    end
  end

  def draw_large_plus_at_point(view, point)
    size = 0.5  # Size of the plus sign in inches
    
    # Horizontal line
    h_start = point.offset(X_AXIS.reverse, size)
    h_end = point.offset(X_AXIS, size)
    
    # Vertical line
    v_start = point.offset(Y_AXIS.reverse, size)
    v_end = point.offset(Y_AXIS, size)
    
    # Draw plus sign
    view.drawing_color = AXIS_HIGHLIGHT_COLOR
    view.line_width = 5
    view.draw(GL_LINES, [h_start, h_end, v_start, v_end])
  end

  def draw_axis_indicator(view, point, axis)
    size = 1.0  # Size of the indicator
    
    case axis
    when :x
      # Draw X-axis indicator
      view.drawing_color = Sketchup::Color.new(255, 0, 0)  # Red
      line1_start = point.offset(X_AXIS.reverse, size).offset(Y_AXIS, size/2)
      line1_end = point.offset(X_AXIS, size).offset(Y_AXIS.reverse, size/2)
      line2_start = point.offset(X_AXIS.reverse, size).offset(Y_AXIS.reverse, size/2)
      line2_end = point.offset(X_AXIS, size).offset(Y_AXIS, size/2)
      view.draw(GL_LINES, [line1_start, line1_end, line2_start, line2_end])
      
    when :y
      # Draw Y-axis indicator
      view.drawing_color = Sketchup::Color.new(0, 255, 0)  # Green
      line1_start = point.offset(Y_AXIS.reverse, size).offset(X_AXIS.reverse, size/2)
      line1_end = point.offset(Y_AXIS, size).offset(X_AXIS, size/2)
      line2_start = point.offset(Y_AXIS.reverse, size).offset(X_AXIS, size/2)
      line2_end = point.offset(Y_AXIS, size).offset(X_AXIS.reverse, size/2)
      view.draw(GL_LINES, [line1_start, line1_end, line2_start, line2_end])
      
    when :z
      # Draw Z-axis indicator
      view.drawing_color = Sketchup::Color.new(0, 0, 255)  # Blue
      top_left = point.offset(X_AXIS.reverse, size/2).offset(Y_AXIS, size/2)
      top_right = point.offset(X_AXIS, size/2).offset(Y_AXIS, size/2)
      bottom_left = point.offset(X_AXIS.reverse, size/2).offset(Y_AXIS.reverse, size/2)
      bottom_right = point.offset(X_AXIS, size/2).offset(Y_AXIS.reverse, size/2)
      
      # Horizontal top
      view.draw(GL_LINES, [top_left, top_right])
      # Diagonal
      view.draw(GL_LINES, [top_right, bottom_left])
      # Horizontal bottom
      view.draw(GL_LINES, [bottom_left, bottom_right])
    end
  end

  def bb_corners(bb)
    [
      bb.corner(0), bb.corner(1), bb.corner(3), bb.corner(2), bb.corner(0),
      bb.corner(4), bb.corner(5), bb.corner(7), bb.corner(6), bb.corner(4),
      bb.corner(0), bb.corner(4), # Front vertical
      bb.corner(1), bb.corner(5), # Front vertical
      bb.corner(2), bb.corner(6), # Back vertical
      bb.corner(3), bb.corner(7)  # Back vertical
    ]
  end

  def commit_and_reset
    if @model.active_operation?
      @model.commit_operation
    end
    reset_tool_state
  end

  def reset_tool_state
    @points = []
    @current_pipe_component = nil
    @length_input = nil
    @override_position = nil
    @bulge_distance = 0
    @axis_lock = nil
    @deletion_mode = false
    @view.tooltip = "Click to start pipe. Enter to finish. Type length for exact distance. 'b' for bulge. Press X/Y/Z to lock axes. Press 'D' to delete pipes."
  end
end

# Improved toolbar with proper toggle functionality
unless defined?($interactive_pipe_tool_loaded)
  $pipe_tool_active = false

  cmd = UI::Command.new("3D Pipe Tool") {
    model = Sketchup.active_model
    active_tool = model.tools.active_tool
    
    if active_tool.is_a?(InteractivePipeTool)
      model.select_tool(nil)
      $pipe_tool_active = false
    else
      model.select_tool(InteractivePipeTool.new)
      $pipe_tool_active = true
    end
  }
  
  cmd.tooltip = "Draws 3D pipes directly"
  cmd.status_bar_text = "Click to place pipe points. Enter to finish. Type length for exact distance. 'b' for bulge. Press X/Y/Z to lock axes. Press 'D' to delete pipes."
  cmd.small_icon = "pipe_tool_small.png"
  cmd.large_icon = "pipe_tool_large.png"
  
  toolbar = UI::Toolbar.new "3D Pipe Tool"
  toolbar.add_item cmd
  toolbar.show
  
  # Add to Tools menu
  UI.menu("Tools").add_item(cmd)
  
  # Add observer to track tool changes
  class PipeToolObserver < Sketchup::AppObserver
    def onNewModel(model)
      $pipe_tool_active = false
    end
    
    def onActivateModel(model)
      $pipe_tool_active = model.tools.active_tool.is_a?(InteractivePipeTool)
    end
  end
  
  Sketchup.add_observer(PipeToolObserver.new)
  
  $interactive_pipe_tool_loaded = true
end