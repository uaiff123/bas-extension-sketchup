# ===================================================================================
#  EXTENSION วาดท่อ 3D โดยตรง (Interactive 3D Pipe Tool)
#  จัดทำโดย: Gemini (ฉบับแก้ไขตามภาพตัวอย่าง)
#  วิธีใช้:
#  1. เปิด SketchUp
#  2. ไปที่เมนู Window > Ruby Console
#  3. คัดลอกโค้ดทั้งหมดข้างล่างนี้ไปวางในหน้าต่าง Ruby Console แล้วกด Enter
#  4. จะมี Toolbar ใหม่ชื่อ "3D Pipe Tool" ปรากฏขึ้นมา
# ===================================================================================

require 'sketchup.rb'

# -------------------------------------------------------------------
# ส่วนที่ 1: คลาสสำหรับเครื่องมือวาดท่อ 3D (The Main Tool Class)
# -------------------------------------------------------------------
class InteractivePipeTool
  # --- การตั้งค่าพื้นฐานของท่อ ---
  PIPE_RADIUS = 1.inch
  PIPE_SIDES = 16
  # --------------------------------

  def activate
    @model = Sketchup.active_model
    @view = @model.active_view
    @ip = Sketchup::InputPoint.new
    @points = []
    @pipe_group = nil # กลุ่มที่จะเก็บท่อทั้งหมดที่วาดในครั้งนี้
  end

  def deactivate(view)
    # จบการทำงานและเคลียร์ทุกอย่างเมื่อเปลี่ยนเครื่องมือ
    commit_and_reset
    view.invalidate
  end

  def onLButtonDown(flags, x, y, view)
    # ถ้าเป็นการคลิกครั้งแรก
    if @points.empty?
      @model.start_operation('Create 3D Pipe', true)
      @pipe_group = @model.active_entities.add_group
    end
    
    current_point = @ip.position
    @points << current_point
    
    # ถ้ามีจุดมากกว่า 1 จุด (สามารถสร้างท่อได้)
    if @points.length > 1
      previous_point = @points[-2]
      # เรียกเมธอดสร้างท่อจริง
      create_pipe_segment(previous_point, current_point)
    end
    
    view.invalidate
  end

  def onMouseMove(flags, x, y, view)
    # หาตำแหน่งของเมาส์ และสั่งให้หน้าจอวาดพรีวิวใหม่
    @ip.pick(view, x, y)
    view.invalidate
  end

  # กด Enter เพื่อจบการทำงาน
  def onReturn(view)
    commit_and_reset
    view.invalidate
  end

  # กด Esc เพื่อยกเลิก
  def onCancel(reason, view)
    # ถ้ามีการวาดไปแล้ว ให้ลบ group ทิ้งทั้งหมด
    if @pipe_group && @pipe_group.valid?
      @pipe_group.erase!
    end
    # ยกเลิก Operation เพื่อไม่ให้มีอะไรเกิดขึ้น
    Sketchup.active_model.abort_operation
    reset_tool_state
    view.invalidate
  end

  # เมธอดสำหรับวาดพรีวิว (ส่วนที่เป็นสีน้ำเงิน)
  def draw(view)
    @ip.draw(view) # แสดงผล inference ของ SketchUp
    
    # วาดพรีวิวเฉพาะเมื่อเริ่มวาดไปแล้ว และเมาส์อยู่ในตำแหน่งที่ถูกต้อง
    if !@points.empty? && @ip.valid?
      start_point = @points.last
      end_point = @ip.position
      
      # เรียกเมธอดวาดพรีวิว
      draw_preview_cylinder(view, start_point, end_point)
    end
  end

  private # เมธอดด้านล่างนี้เป็นเมธอดภายในคลาส ไม่ได้ถูกเรียกโดย SketchUp โดยตรง

  # เมธอดสำหรับสร้างท่อจริงๆ หนึ่งท่อน
  def create_pipe_segment(start_point, end_point)
    # ใช้ entities ของ group ที่เราสร้างไว้ เพื่อให้ท่อทุกชิ้นอยู่ในกลุ่มเดียวกัน
    entities = @pipe_group.entities
    
    vector = end_point - start_point
    length = vector.length
    return if length == 0 # ไม่ต้องสร้างถ้าจุดซ้ำกัน

    # 1. สร้างหน้าตัดวงกลม
    circle = entities.add_circle(start_point, vector, PIPE_RADIUS, PIPE_SIDES)
    face = entities.add_face(circle)
    return unless face.normal.samedirection?(vector)

    # 2. ใช้ FollowMe สร้างท่อ
    # เราจำเป็นต้องสร้างเส้นทาง (path) ชั่วคราวเพื่อให้ FollowMe ทำงานได้
    path = entities.add_line(start_point, end_point)
    face.followme(path)
    path.erase! # ลบเส้นทางทิ้ง เหลือแต่ท่อ
  end
  
  # เมธอดสำหรับวาดพรีวิวทรงกระบอก (เป็นเส้น Wireframe)
  def draw_preview_cylinder(view, start_point, end_point)
    vector = end_point - start_point
    length = vector.length
    return if length == 0

    # หาแกนสำหรับสร้างวงกลม (ต้องตั้งฉากกับ vector)
    if vector.parallel?(Geom::Vector3d.new(0,0,1))
      axis = Geom::Vector3d.new(1,0,0)
    else
      axis = vector.cross(Geom::Vector3d.new(0,0,1))
    end
    
    # สร้าง Transformation สำหรับย้ายวงกลมไปที่จุดเริ่มต้นและจุดสิ้นสุด
    tr_start = Geom::Transformation.new(start_point)
    tr_end = Geom::Transformation.new(end_point)
    
    # สร้างจุดของวงกลมต้นแบบ
    base_circle_points = []
    (0..PIPE_SIDES).each do |i|
      angle = (2 * Math::PI / PIPE_SIDES) * i
      x = PIPE_RADIUS * Math.cos(angle)
      y = PIPE_RADIUS * Math.sin(angle)
      base_circle_points << Geom::Point3d.new(x, y, 0)
    end
    
    # แปลงตำแหน่งจุดของวงกลม
    start_circle = base_circle_points.map { |pt| pt.transform(Geom::Transformation.new(axis, vector).to_a) }
                                     .map { |pt| pt.transform(tr_start) }
    end_circle = base_circle_points.map { |pt| pt.transform(Geom::Transformation.new(axis, vector).to_a) }
                                   .map { |pt| pt.transform(tr_end) }
    
    # ตั้งค่าสีและเริ่มวาด
    view.drawing_color = "blue"
    view.line_width = 2
    
    # วาดวงกลมที่ปลายทั้งสองข้าง
    view.draw(GL_LINE_STRIP, start_circle)
    view.draw(GL_LINE_STRIP, end_circle)
    
    # วาดเส้นเชื่อมระหว่างวงกลม
    (0...PIPE_SIDES).each do |i|
      view.draw(GL_LINES, [start_circle[i], end_circle[i]])
    end
  end
  
  # จบการทำงานและ Commit สิ่งที่วาดไปทั้งหมด
  def commit_and_reset
    if @pipe_group
       # ถ้า group ว่างเปล่า (แค่คลิกเดียว) ให้ลบทิ้ง
      if @pipe_group.entities.empty?
        @pipe_group.erase!
        Sketchup.active_model.abort_operation
      else
        Sketchup.active_model.commit_operation
      end
    end
    reset_tool_state
  end

  # รีเซ็ตค่าเริ่มต้น
  def reset_tool_state
    @points = []
    @pipe_group = nil
    @view.tooltip = nil
  end
end

# -------------------------------------------------------------------
# ส่วนที่ 2: สร้าง Toolbar และ Command
# -------------------------------------------------------------------
unless defined?($interactive_pipe_tool_loaded)
  cmd = UI::Command.new("3D Pipe Tool") {
    Sketchup.active_model.tools.push_tool(InteractivePipeTool.new)
  }
  cmd.tooltip = "Draws 3D pipes directly"
  cmd.status_bar_text = "Click to place points of the pipe. Press Enter to finish."
  
  toolbar = UI::Toolbar.new "3D Pipe Tool"
  toolbar.add_item cmd
  toolbar.show
  
  $interactive_pipe_tool_loaded = true
end