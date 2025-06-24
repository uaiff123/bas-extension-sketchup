# InteractivePipeTool.rb
require 'sketchup.rb'

class InteractivePipeTool
  PIPE_RADIUS = 1.inch
  PIPE_SIDES = 16

  def activate
    @model = Sketchup.active_model
    @view = @model.active_view
    @ip = Sketchup::InputPoint.new
    @points = []
    @pipe_group = nil
  end

  def deactivate(view)
    commit_and_reset
    view.invalidate
  end

  def onLButtonDown(flags, x, y, view)
    current_point = @ip.position
    if @points.empty?
      @model.start_operation('Create 3D Pipe', true)
      @pipe_group = @model.active_entities.add_group
    end
    @points << current_point

    if @points.length > 1
      create_pipe_segment(@points[-2], current_point)
    end
    view.invalidate
  end

  def onMouseMove(flags, x, y, view)
    @ip.pick(view, x, y)
    @mouse_position = @ip.position
    view.invalidate
  end

  def onReturn(view)
    commit_and_reset
    view.invalidate
  end

  def onCancel(reason, view)
    @pipe_group.erase! if @pipe_group && @pipe_group.valid?
    Sketchup.active_model.abort_operation
    reset_tool_state
    view.invalidate
  end

  def draw(view)
    @ip.draw(view)
    if !@points.empty? && @ip.valid?
      start_point = @points.last
      end_point = @ip.position
      draw_preview_cylinder(view, start_point, end_point, 'sienna')
      draw_preview_line(view, start_point, end_point)
    end
  end

  private

  def create_pipe_segment(start_point, end_point)
    entities = @pipe_group.entities
    vector = end_point - start_point
    return if vector.length == 0

    circle = entities.add_circle(start_point, vector, PIPE_RADIUS, PIPE_SIDES)
    face = entities.add_face(circle)
    return unless face && face.normal.samedirection?(vector)

    path = entities.add_line(start_point, end_point)
    face.followme(path)
    path.erase!
  end

  def draw_preview_cylinder(view, start_point, end_point, color)
    vector = end_point - start_point
    return if vector.length == 0

    axis = if vector.parallel?(Geom::Vector3d.new(0,0,1))
             Geom::Vector3d.new(1,0,0)
           else
             vector * Geom::Vector3d.new(0,0,1)
           end

    tr_start = Geom::Transformation.new(start_point)
    tr_end = Geom::Transformation.new(end_point)

    base_circle_points = (0..PIPE_SIDES).map do |i|
      angle = 2 * Math::PI * i / PIPE_SIDES
      Geom::Point3d.new(PIPE_RADIUS * Math.cos(angle), PIPE_RADIUS * Math.sin(angle), 0)
    end

    xform = Geom::Transformation.rotation(ORIGIN, axis, vector.angle_with(axis))

    start_circle = base_circle_points.map { |pt| pt.transform(xform).transform(tr_start) }
    end_circle = base_circle_points.map { |pt| pt.transform(xform).transform(tr_end) }

    view.drawing_color = color
    view.line_width = 2

    view.draw(GL_LINE_STRIP, start_circle)
    view.draw(GL_LINE_STRIP, end_circle)
    (0...PIPE_SIDES).each { |i| view.draw(GL_LINES, [start_circle[i], end_circle[i]]) }
  end

  def draw_preview_line(view, start_point, end_point)
    view.drawing_color = 'orange'
    view.line_width = 3
    view.draw(GL_LINES, [start_point, end_point])
  end

  def commit_and_reset
    if @pipe_group
      if @pipe_group.entities.empty?
        @pipe_group.erase!
        Sketchup.active_model.abort_operation
      else
        Sketchup.active_model.commit_operation
      end
    end
    reset_tool_state
  end

  def reset_tool_state
    @points = []
    @pipe_group = nil
    @view.tooltip = nil
  end
end

unless defined?($interactive_pipe_tool_loaded)
  cmd = UI::Command.new("3D Pipe Tool") {
    Sketchup.active_model.tools.push_tool(InteractivePipeTool.new)
  }
  cmd.tooltip = "Draws 3D pipes directly"
  cmd.status_bar_text = "Click to place pipe points. Enter to finish."
  toolbar = UI::Toolbar.new "3D Pipe Tool"
  toolbar.add_item cmd
  toolbar.show
  $interactive_pipe_tool_loaded = true
end 