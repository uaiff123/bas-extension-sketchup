require 'sketchup.rb'

class InteractivePipeTool
  PIPE_RADIUS = 1.inch
  PIPE_SIDES = 16
  DEFAULT_LAYER_PREFIX = "Pipe_"
  HIGHLIGHT_COLOR = Sketchup::Color.new(255, 200, 0, 200)  # Orange highlight

  def activate
    @model = Sketchup.active_model
    @view = @model.active_view
    @ip = Sketchup::InputPoint.new
    @points = []
    @pipe_group = nil
    @length_input = nil
    @override_position = nil
    @bulge_distance = 0
    @active = true
    @view.tooltip = "Click to start pipe. Enter to finish. Type length for exact distance. 'b' for bulge."
    @view.invalidate
    
    # Set pencil cursor
    UI.set_cursor(IDC_PENCIL)
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
    
    current_point = @override_position || @ip.position
    
    if @points.empty?
      @model.start_operation('Create 3D Pipe', true)
      @pipe_group = @model.active_entities.add_group
      
      # Create dedicated layer for each pipe
      layer_name = DEFAULT_LAYER_PREFIX + Time.now.to_i.to_s
      pipe_layer = @model.layers.add(layer_name)
      @pipe_group.layer = pipe_layer
    end
    
    @points << current_point

    if @points.length > 1
      create_pipe_segment(@points[-2], current_point, @bulge_distance)
      @bulge_distance = 0 # Reset bulge after segment creation
    end
    
    view.invalidate
  end

  def onMouseMove(flags, x, y, view)
    return unless @active
    
    @ip.pick(view, x, y)
    @mouse_position = @ip.position
    
    # Handle length constraint
    if @length_input && !@points.empty?
      base_point = @points.last
      vector = @ip.position - base_point
      if vector.length > 0
        direction = vector.normalize
        @override_position = base_point + direction * @length_input
      else
        @override_position = nil
      end
    else
      @override_position = nil
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
    end
    false
  end

  def onReturn(view)
    commit_and_reset
    view.invalidate
  end

  def onCancel(reason, view)
    if @pipe_group && @pipe_group.valid?
      @pipe_group.erase! 
      @model.abort_operation
    end
    reset_tool_state
    view.invalidate
  end

  def draw(view)
    return unless @active
    
    @ip.draw(view)
    
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
    end
    
    # Draw existing segments
    if @points.size > 1
      view.drawing_color = HIGHLIGHT_COLOR
      view.line_width = 3
      view.draw(GL_LINE_STRIP, @points)
    end
    
    # Draw preview from last point to mouse position
    if !@points.empty? && (@ip.valid? || @override_position)
      start_point = @points.last
      end_point = @override_position || @ip.position
      
      if @bulge_distance != 0
        draw_preview_curve(view, start_point, end_point, @bulge_distance)
      else
        # Only draw one preview line (removed the extra cylinder preview)
        draw_preview_line(view, start_point, end_point)
      end
    end
  end

  private

  def create_pipe_segment(start_point, end_point, bulge)
    entities = @pipe_group.entities
    
    if bulge != 0
      # Create curved segment
      curve_points = generate_curve_points(start_point, end_point, bulge)
      path = entities.add_curve(curve_points)
      pipe_path = path.first
      
      # Create pipe profile
      vector = curve_points[1] - curve_points[0]
      circle = create_pipe_profile(entities, start_point, vector)
      face = entities.add_face(circle)
      
      # Create pipe
      face.followme(pipe_path)
      pipe_path.erase!
    else
      # Create straight segment
      vector = end_point - start_point
      return if vector.length == 0

      circle = create_pipe_profile(entities, start_point, vector)
      face = entities.add_face(circle)
      return unless face && face.normal.samedirection?(vector)

      path = entities.add_line(start_point, end_point)
      face.followme(path)
      path.erase!
    end
    
    # Smooth joints between segments
    if @points.length > 2
      smooth_joints(entities)
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

  def commit_and_reset
    if @pipe_group
      if @pipe_group.entities.empty?
        @pipe_group.erase!
        @model.abort_operation
      else
        @model.commit_operation
      end
    end
    reset_tool_state
  end

  def reset_tool_state
    @points = []
    @pipe_group = nil
    @length_input = nil
    @override_position = nil
    @bulge_distance = 0
    @view.tooltip = "Click to start pipe. Enter to finish. Type length for exact distance. 'b' for bulge."
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
  cmd.status_bar_text = "Click to place pipe points. Enter to finish. Type length for exact distance. 'b' for bulge."
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