# frozen_string_literal: true

module MyCustomTools

  # ประกาศค่าคงที่ปุ่มคีย์บอร์ด
  unless defined?(MyCustomTools::VK_LEFT)
    VK_LEFT = 37
    VK_UP = 38
    VK_RIGHT = 39
    VK_DOWN = 40
    VK_ESCAPE = 27
    CONSTRAIN_MODIFIER_KEY = 16 # ปุ่ม Shift
  end

  class CustomLineTool
    X_AXIS = Geom::Vector3d.new(1, 0, 0)
    Y_AXIS = Geom::Vector3d.new(0, 1, 0)
    Z_AXIS = Geom::Vector3d.new(0, 0, 1)
    Z_AXIS_NEGATIVE = Geom::Vector3d.new(0, 0, -1)    

    SNAP_ANGLE_THRESHOLD = 0.1  
    AUTO_SNAP_DISTANCE_THRESHOLD = 50.inch  

    LOCKED_AXIS_LINE_WIDTH = 4  
    PREVIEW_LINE_WIDTH = 2  

    BEZIER_SEGMENTS = 100 # <<< ปรับตรงนี้
    DEFAULT_CURVE_SAGITTA_FACTOR = 0.1 # ความโค้งมนเล็กน้อย (ไม่ได้เปลี่ยนตามคำขอของคุณในครั้งนี้)
    SUPER_CURVE_AMPLIFY_FACTOR = 100.0 # <<< ปรับตรงนี้

    def initialize
      @points = []
      @axis = X_AXIS  
      @force_axis = false  
      @color = Sketchup::Color.new(0, 0, 0)  
      @ip = Sketchup::InputPoint.new  
      @active = true
      @axis_lock = nil  
      @lock_direction = nil  
      @current_drawing_direction = nil  
      @last_mouse_x = 0 
      @last_mouse_y = 0 
      @arc_mode = false # เพิ่มสถานะสำหรับโหมดวาดส่วนโค้ง "สุดเวอร์"
      @bezier_control_point = nil # จุดควบคุมสำหรับ Bezier Curve
    end

    def activate
      @points.clear
      @current_drawing_direction = nil  
      @arc_mode = false
      @bezier_control_point = nil
      Sketchup.vcb_label = "ความยาว"
      Sketchup.status_text = "คลิกเพื่อวางจุด | พิมพ์ระยะ + Enter | ←↑→↓ สลับการล็อกแกน | ESC ยกเลิก | Shift สำหรับโหมดโค้ง (2 จุด)"
      Sketchup.active_model.active_view.invalidate
    end

    def deactivate(view)
      view.invalidate
    end

    # เมธอดสำหรับคำนวณจุดบน Quadratic Bezier Curve
    # P0: จุดเริ่มต้น, P1: จุดควบคุม, P2: จุดสิ้นสุด
    # segments: จำนวนส่วนย่อยของเส้นโค้ง
    def calculate_bezier_points(p0, p1, p2, segments)
      points = []
      (0..segments).each do |i|
        t = i.to_f / segments
        # สูตร Quadratic Bezier Curve: B(t) = (1-t)^2 * P0 + 2(1-t)t * P1 + t^2 * P2
        x = (1 - t)**2 * p0.x + 2 * (1 - t) * t * p1.x + t**2 * p2.x
        y = (1 - t)**2 * p0.y + 2 * (1 - t) * t * p1.y + t**2 * p2.y
        z = (1 - t)**2 * p0.z + 2 * (1 - t) * t * p1.z + t**2 * p2.z
        points << Geom::Point3d.new(x, y, z)
      end
      points
    end

    # เมธอดช่วยในการหา Vector ตั้งฉากที่เชื่อถือได้
    # line_direction: ทิศทางของเส้น (normalized)
    # view_camera_up: เวกเตอร์ Up ของกล้อง (normalized)
    # view_camera_direction: ทิศทางของกล้อง (normalized)
    def find_perpendicular_vector(line_direction, view_camera_up, view_camera_direction)
      # 1. พยายามใช้ vector ตั้งฉากกับทิศทางเส้นและระนาบของกล้อง
      plane_normal = view_camera_direction.cross(view_camera_up).normalize
      
      # 2. Vector ตั้งฉากบนระนาบนี้ (cross product ของทิศทางเส้นและ normal ของระนาบ)
      perp_vector = line_direction.cross(plane_normal).normalize
      
      # Fallback ในกรณีที่ cross product เป็นศูนย์
      if perp_vector.length < 0.0001
        perp_vector = line_direction.cross(view_camera_up).normalize
        if perp_vector.length < 0.0001
          if line_direction.parallel?(Z_AXIS)
            perp_vector = line_direction.cross(X_AXIS).normalize
          else
            perp_vector = line_direction.cross(Z_AXIS).normalize
          end
        end
      end
      
      if perp_vector.length < 0.0001
        perp_vector = Y_AXIS 
      end

      return perp_vector.normalize
    end


    def onMouseMove(flags, x, y, view)
      return unless @active

      @last_mouse_x = x 
      @last_mouse_y = y 

      if @points.empty?
        @ip.pick(view, x, y)
        @current_drawing_direction = nil  
      else
        # ในโหมด arc_mode เราต้องการให้ InputPoint ชี้ไปที่ตำแหน่งเมาส์ปัจจุบันเสมอ
        # เพื่อใช้เป็นจุดปลาย (P2) และคำนวณจุดควบคุม P1 จากมัน
        # นอกโหมด arc_mode ยังคงใช้ inference ได้
        if @arc_mode
            @ip.pick(view, x, y)
        else
            temp_ip_for_inference = Sketchup::InputPoint.new(@points.last)
            @ip.pick(view, x, y, temp_ip_for_inference)
        end
      end

      @mouse_position = @ip.position # ตำแหน่งเมาส์ปัจจุบันบนโมเดล
      @current_mouse_x = x
      @current_mouse_y = y

      # ตรวจสอบว่า Shift ถูกกดหรือไม่ เพื่อเข้าสู่โหมดวาดส่วนโค้ง "สุดเวอร์"
      # @arc_mode จะเป็นจริงเมื่อมีจุดแรกแล้ว และกด Shift
      @arc_mode = (flags & CONSTRAIN_MODIFIER_KEY == CONSTRAIN_MODIFIER_KEY) && (@points.size == 1) 

      if !@points.empty?
        p0 = @points.last # จุดเริ่มต้น (P0)

        if @arc_mode # ถ้าอยู่ในโหมดวาดโค้ง "สุดเวอร์" (Shift กดค้าง)
          @color = Sketchup::Color.new(0, 0, 255) # สีน้ำเงินสำหรับโหมดโค้ง
          @axis_lock = nil
          @lock_direction = nil
          @current_drawing_direction = nil
          @force_axis = false # ไม่มีการ force_axis ในโหมดโค้ง "สุดเวอร์"
          
          # ในโหมด 2 Point Arc, P2 คือจุดที่เมาส์ชี้
          p2 = @mouse_position 
          
          # คำนวณ Midpoint ของคอร์ด P0-P2
          mid_point_chord = Geom::Point3d.linear_combination(0.5, p0, 0.5, p2)
          
          # คำนวณทิศทางของคอร์ด P0-P2
          chord_direction = p2 - p0
          
          if chord_direction.length > 0.001
            chord_direction.normalize!
            
            # หา vector ตั้งฉากกับคอร์ด P0-P2 ในระนาบที่มองเห็น
            # ใช้ view.camera.up และ view.camera.direction เพื่อช่วยหาทิศทางตั้งฉากที่เหมาะสมกับมุมมอง
            orthogonal_vector = find_perpendicular_vector(chord_direction, view.camera.up.normalize, view.camera.direction.normalize)
            
            # คำนวณจุดควบคุม P1 (@bezier_control_point)
            # มันจะอยู่บนเส้นตั้งฉากกับคอร์ด ที่จุดกึ่งกลางของคอร์ด
            # ระยะห่างจากกึ่งกลางคอร์ดถูกขยายด้วย SUPER_CURVE_AMPLIFY_FACTOR
            
            # ระยะห่างจาก mid_point_chord ไปยัง control point (P1)
            # เราใช้ระยะห่างจากเมาส์ไปยัง mid_point_chord เป็น "Bulge factor" เริ่มต้น
            # และขยายด้วย SUPER_CURVE_AMPLIFY_FACTOR
            
            # นี่คือส่วนที่สำคัญที่สุด:
            # ความนูนของ Bezier Curve จะถูกควบคุมโดยระยะห่างของเมาส์
            # จากจุดกึ่งกลางของเส้นคอร์ด P0-P2 ในระนาบหน้าจอ
            
            # สร้างระนาบที่ผ่านจุดเริ่มต้นและจุดสิ้นสุด โดยมี normal เป็นทิศทางมองของกล้อง
            # (เพื่อให้การเคลื่อนที่ของเมาส์ในระนาบหน้าจอมีผลต่อความนูน)
            # ถ้า P0 กับ P2 ใกล้กันมาก อาจเกิดปัญหา cross product เป็น 0
            if (p2 - p0).length > 0.001
              line_from_p0_to_p2 = [p0, p2]
              # โปรเจกต์ตำแหน่งเมาส์ลงบนระนาบหน้าจอที่ผ่านจุดกึ่งกลางของคอร์ด
              # เพื่อให้การเคลื่อนที่ของเมาส์ในหน้าจอควบคุมความนูนได้ดีขึ้น
              
              # ลองใช้จุดเมาส์ปัจจุบันใน space 3D แล้วหา vector จาก mid_point_chord ไปยัง @mouse_position
              # จากนั้นโปรเจกต์ vector นั้นลงบน orthogonal_vector
              vec_from_mid_to_mouse = @mouse_position - mid_point_chord
              
              # ระยะ Bulge ที่มาจากเมาส์ (Bulge Input)
              # ใช้ค่า scalar projection ของ vec_from_mid_to_mouse บน orthogonal_vector
              mouse_bulge_distance = vec_from_mid_to_mouse.dot(orthogonal_vector)
              
              # P1 จะอยู่ที่ mid_point_chord และเลื่อนออกไปในทิศทาง orthogonal_vector
              # โดยมีระยะที่ขยายด้วย SUPER_CURVE_AMPLIFY_FACTOR
              @bezier_control_point = mid_point_chord.offset(orthogonal_vector, mouse_bulge_distance * SUPER_CURVE_AMPLIFY_FACTOR)
            else
              # ถ้า P0 กับ P2 ใกล้กันมาก ให้ P1 เป็น P0 หรือ P2
              @bezier_control_point = p0 
            end

          else # ถ้าจุด P0 กับ P2 ซ้ำกัน
            @bezier_control_point = p0 # จุดควบคุมก็เป็นจุดเริ่มต้น
          end

        else # ถ้าไม่ได้อยู่ใน arc_mode (โหมดวาดเส้นตรงปกติ)
          # *** แก้ไข: เพิ่มการกำหนด mouse_vector ที่นี่ ***
          mouse_vector = @mouse_position - p0 
          # **********************************************

          if @force_axis && @lock_direction  
            # โหมดล็อกแกน (เดิม)
            @current_drawing_direction = @lock_direction
            @color = Sketchup::Color.new(
              case @axis_lock
              when :x then 255
              when :y then 0
              when :z_pos, :z_neg then 0
              else 0
              end,
              case @axis_lock
              when :x then 0
              when :y then 255
              when :z_pos, :z_neg then 0
              else 0
              end,
              case @axis_lock
              when :x then 0
              when :y then 0
              when :z_pos, :z_neg then 255
              else 0
              end
            )
            @bezier_control_point = nil # ออกจากโหมดโค้ง
          elsif mouse_vector.valid? && mouse_vector.length > 0  
            # โหมด inference อัตโนมัติ (เดิม)
            mouse_direction = mouse_vector.normalize

            axes_to_check = [
              { axis: X_AXIS, color: Sketchup::Color.new(255, 0, 0), symbol: :x },
              { axis: Y_AXIS, color: Sketchup::Color.new(0, 255, 0), symbol: :y },
              { axis: Z_AXIS, color: Sketchup::Color.new(0, 0, 255), symbol: :z_pos },
              { axis: Z_AXIS_NEGATIVE, color: Sketchup::Color.new(0, 0, 255), symbol: :z_neg }
            ]

            best_axis = nil
            min_angle = Math::PI  

            axes_to_check.each do |axis_info|
              angle = mouse_direction.angle_between(axis_info[:axis])
              if angle < min_angle
                min_angle = angle
                best_axis = axis_info
              end
            end

            if best_axis && min_angle < SNAP_ANGLE_THRESHOLD
              line_to_project_on = [p0, best_axis[:axis]]
              projected_point = @mouse_position.project_to_line(line_to_project_on)
              distance_to_axis = (@mouse_position - projected_point).length

              if distance_to_axis < AUTO_SNAP_DISTANCE_THRESHOLD
                @lock_direction = best_axis[:axis]
                @axis_lock = best_axis[:symbol]
                @color = best_axis[:color]
                @current_drawing_direction = best_axis[:axis]  
              else
                @axis_lock = nil
                @lock_direction = nil
                @color = Sketchup::Color.new(0, 0, 0)  
                @current_drawing_direction = mouse_direction  
              end
            else
              @axis_lock = nil
              @lock_direction = nil
              @color = Sketchup::Color.new(0, 0, 0)
              @current_drawing_direction = mouse_direction  
            end
            @bezier_control_point = nil # ออกจากโหมดโค้ง
          else  
            # ไม่มี inference หรือเมาส์ยังไม่ขยับ
            @axis_lock = nil
            @lock_direction = nil
            @force_axis = false
            @color = Sketchup::Color.new(0, 0, 0)
            @current_drawing_direction = nil
            @arc_mode = false # ตรวจสอบให้แน่ใจว่าปิดโหมดโค้ง
            @bezier_control_point = nil # ออกจากโหมดโค้ง
          end
        end # End if @arc_mode

      else  
        # ยังไม่มีจุดเริ่มต้น
        @axis_lock = nil
        @lock_direction = nil
        @force_axis = false
        @color = Sketchup::Color.new(0, 0, 0)
        @current_drawing_direction = nil
        @arc_mode = false # ตรวจสอบให้แน่ใจว่าปิดโหมดโค้ง
        @bezier_control_point = nil # ออกจากโหมดโค้ง
      end

      view.invalidate
    end

    def onLButtonDown(flags, x, y, view)
      return unless @ip.valid?

      @last_mouse_x = x 
      @last_mouse_y = y 

      point_clicked = @ip.position # จุดที่คลิก (จะเป็น P2)

      model = Sketchup.active_model
      model.start_operation("Draw Line/Curve", true)

      if @points.empty?
        @points << point_clicked
        @current_drawing_direction = nil  
      else
        p0 = @points.last # จุดเริ่มต้น (P0)
        p2 = point_clicked # จุดที่คลิกครั้งที่สอง (P2)
        
        if @arc_mode && @bezier_control_point # ถ้าอยู่ในโหมดวาดโค้ง "สุดเวอร์" (Shift กดค้าง)
          # คำนวณจุดควบคุม Bezier สำหรับการสร้างจริง
          mid_point_chord = Geom::Point3d.linear_combination(0.5, p0, 0.5, p2)
          chord_direction = p2 - p0
          
          if chord_direction.length > 0.001
            chord_direction.normalize!
            
            orthogonal_vector = find_perpendicular_vector(chord_direction, view.camera.up.normalize, view.camera.direction.normalize)
            
            # คำนวณระยะ Bulge จากตำแหน่งที่คลิกเมาส์เทียบกับ mid_point_chord
            vec_from_mid_to_clicked = point_clicked - mid_point_chord
            mouse_bulge_distance = vec_from_mid_to_clicked.dot(orthogonal_vector)
            
            # ใช้จุดควบคุมที่คำนวณจากระยะ Bulge ที่คลิก
            final_bezier_control_point = mid_point_chord.offset(orthogonal_vector, mouse_bulge_distance * SUPER_CURVE_AMPLIFY_FACTOR)
            
            bezier_points = calculate_bezier_points(p0, final_bezier_control_point, p2, BEZIER_SEGMENTS)
            
            if bezier_points.length > 1
                edges = model.active_entities.add_curve(bezier_points)
                if edges && edges.first.is_a?(Sketchup::Edge)
                    edges.each { |e| e.material = @color }
                end
            else 
                model.active_entities.add_point(p0)
            end
          else # ถ้า P0 กับ P2 ซ้ำกัน (จุดที่คลิกอยู่บนจุดเริ่มต้น)
             model.active_entities.add_point(p0)
          end

        else # ไม่ได้อยู่ในโหมดวาดโค้ง "สุดเวอร์" (โหมดปกติ - วาดเส้นตรง/โค้งมน)
          effective_direction = @current_drawing_direction  
          unless effective_direction && effective_direction.valid? && effective_direction.length > 0
            vector_to_click_point = point_clicked - p0
            if vector_to_click_point.valid? && vector_to_click_point.length > 0
              effective_direction = vector_to_click_point.normalize
            else
              effective_direction = X_AXIS  
            end
          end

          length = (point_clicked - p0).length  
          finish_point = p0.offset(effective_direction, length) # จุดปลายที่อิงจาก inference

          # สร้างจุดควบคุมสำหรับความโค้งมนเล็กน้อย (โค้งเมื่อตัดมุม)
          if length > 0.001
            mid_point_for_default_curve = p0.offset(effective_direction, length / 2.0)
            
            vec_orthogonal_for_default = find_perpendicular_vector(effective_direction, view.camera.up.normalize, view.camera.direction.normalize)
            
            sagitta_for_default_curve = length * DEFAULT_CURVE_SAGITTA_FACTOR # ความโค้งมนเล็กน้อย
            
            control_point_for_default_curve = mid_point_for_default_curve.offset(vec_orthogonal_for_default, sagitta_for_default_curve)
            
            bezier_points_default = calculate_bezier_points(p0, control_point_for_default_curve, finish_point, BEZIER_SEGMENTS)
            
            if bezier_points_default.length > 1
              edges = model.active_entities.add_curve(bezier_points_default)
              if edges && edges.first.is_a?(Sketchup::Edge)
                  edges.each { |e| e.material = @color }
              end
            end
          else # ถ้าความยาวเป็น 0 ก็วาดจุด
            model.active_entities.add_point(p0)
          end
        end 

        model.commit_operation

        # หลังจากวาดแล้ว ให้เริ่มต้นใหม่จากจุดสุดท้ายที่คลิก
        @points.clear  
        @points << point_clicked 

        temp_ip_for_inference = Sketchup::InputPoint.new(@points.last)
        @ip.pick(view, @last_mouse_x, @last_mouse_y, temp_ip_for_inference)
        
        @axis_lock = nil
        @lock_direction = nil
        @force_axis = false
        @color = Sketchup::Color.new(0,0,0)  
        @current_drawing_direction = nil  
        @arc_mode = false # รีเซ็ตโหมดโค้ง "สุดเวอร์"
        @bezier_control_point = nil # รีเซ็ตจุดควบคุม Bezier
      end
      
      view.invalidate
    end

    def onKeyDown(key, repeat, flags, view)
      case key
      when MyCustomTools::CONSTRAIN_MODIFIER_KEY
        # เมื่อกด Shift ค้างไว้
        # เราจะไม่ทำอะไรโดยตรงที่นี่ แต่ onMouseMove จะตรวจจับ flags
        # เพื่อเข้าสู่โหมดโค้ง "สุดเวอร์"
        view.invalidate
        return true

      when MyCustomTools::VK_RIGHT
        # โค้ดเดิมสำหรับการล็อกแกน
        if @axis_lock == :x
          @axis_lock = nil
          @lock_direction = nil
          @force_axis = false
          @color = Sketchup::Color.new(0,0,0)
        else
          @axis_lock = :x
          @lock_direction = X_AXIS
          @force_axis = true
          @color = Sketchup::Color.new(255, 0, 0)
        end
        @current_drawing_direction = @lock_direction  
        @arc_mode = false # ออกจากโหมดโค้ง "สุดเวอร์" เมื่อล็อกแกน
        @bezier_control_point = nil
        view.invalidate
        return true

      when MyCustomTools::VK_LEFT
        if @axis_lock == :y
          @axis_lock = nil
          @lock_direction = nil
          @force_axis = false
          @color = Sketchup::Color.new(0,0,0)
        else
          @axis_lock = :y
          @lock_direction = Y_AXIS
          @force_axis = true
          @color = Sketchup::Color.new(0, 255, 0)
        end
        @current_drawing_direction = @lock_direction  
        @arc_mode = false
        @bezier_control_point = nil
        view.invalidate
        return true

      when MyCustomTools::VK_UP
        if @axis_lock == :z_pos
          @axis_lock = nil
          @lock_direction = nil
          @force_axis = false
          @color = Sketchup::Color.new(0,0,0)
        else
          @axis_lock = :z_pos
          @lock_direction = Z_AXIS
          @force_axis = true
          @color = Sketchup::Color.new(0, 0, 255)
        end
        @current_drawing_direction = @lock_direction  
        @arc_mode = false
        @bezier_control_point = nil
        view.invalidate
        return true

      when MyCustomTools::VK_DOWN
        if @axis_lock == :z_neg
          @axis_lock = nil
          @lock_direction = nil
          @force_axis = false
          @color = Sketchup::Color.new(0,0,0)
        else
          @axis_lock = :z_neg
          @lock_direction = Z_AXIS_NEGATIVE  
          @force_axis = true
          @color = Sketchup::Color.new(0, 0, 255)
        end
        @current_drawing_direction = @lock_direction  
        @arc_mode = false
        @bezier_control_point = nil
        view.invalidate
        return true

      when MyCustomTools::VK_ESCAPE
        @points.clear  
        @force_axis = false
        @axis_lock = nil
        @lock_direction = nil
        @color = Sketchup::Color.new(0,0,0)  
        @current_drawing_direction = nil  
        @arc_mode = false
        @bezier_control_point = nil
        view.invalidate
        return true
      end
      false
    end

    def onUserText(text, view)
      return if @points.empty?  

      begin
        if text.match?(/^\s*\d+(\.\d+)?\s*$/) 
          if text.to_f == 0.0
            text_with_unit = text 
          else
            text_with_unit = "#{text}m" 
          end
        elsif text !~ /[mcm"']/ && text.to_f != 0.0 && text.to_l.to_f != 0.0 
          text_with_unit = "#{text}m"
        else
          text_with_unit = text 
        end

        length = text_with_unit.to_l  
        
        if length <= 0
          UI.messagebox("ใส่ระยะไม่ถูกต้อง ระยะต้องมากกว่า 0")
          return
        end

        p0 = @points.last # จุดเริ่มต้น (P0)
        
        model = Sketchup.active_model
        model.start_operation("Draw Line (Typed Length)", true)
        
        if @arc_mode && @bezier_control_point # หากอยู่ในโหมดโค้ง "สุดเวอร์" เมื่อพิมพ์ความยาว
            # คำนวณจุดสิ้นสุด (P2) จากความยาวที่พิมพ์
            effective_direction_for_p2 = @current_drawing_direction 
            if !effective_direction_for_p2.is_a?(Geom::Vector3d) || !effective_direction_for_p2.valid? || effective_direction_for_p2.length == 0
                # ใช้ทิศทางจาก P0 ไปยังตำแหน่งเมาส์ปัจจุบันเป็นค่าตั้งต้น
                vec_to_mouse = @ip.position - p0
                if vec_to_mouse.valid? && vec_to_mouse.length > 0
                    effective_direction_for_p2 = vec_to_mouse.normalize
                else
                    effective_direction_for_p2 = X_AXIS # Default ถ้าทิศทางยังไม่ชัดเจน
                end
            end
            p2_from_length = p0.offset(effective_direction_for_p2, length)

            # คำนวณจุดควบคุม P1 ใหม่สำหรับ P2 ที่ได้จากความยาว
            mid_point_chord = Geom::Point3d.linear_combination(0.5, p0, 0.5, p2_from_length)
            chord_direction = p2_from_length - p0
            
            if chord_direction.length > 0.001
              chord_direction.normalize!
              orthogonal_vector = find_perpendicular_vector(chord_direction, view.camera.up.normalize, view.camera.direction.normalize)
              
              # ใช้ตำแหน่งของ @bezier_control_point ที่คำนวณไว้ก่อนหน้านี้ (จาก onMouseMove)
              # เพื่อให้ "Bulge" ที่เมาส์กำหนดไว้ก่อนพิมพ์ยังคงอยู่
              vec_from_mid_to_control = @bezier_control_point - mid_point_chord
              current_bulge_distance = vec_from_mid_to_control.dot(orthogonal_vector) # เอา Bulge scalar ของ P1 เดิม
              
              final_bezier_control_point = mid_point_chord.offset(orthogonal_vector, current_bulge_distance)
            else
              final_bezier_control_point = p0 # ถ้า P0 กับ P2 ซ้ำกัน
            end
            
            bezier_points = calculate_bezier_points(p0, final_bezier_control_point, p2_from_length, BEZIER_SEGMENTS)
            
            if bezier_points.length > 1
                edges = model.active_entities.add_curve(bezier_points)
                if edges && edges.first.is_a?(Sketchup::Edge)
                    edges.each { |e| e.material = @color }
                end
            end
            
            @points.clear
            @points << p2_from_length # ให้จุดสุดท้ายเป็นจุดเริ่มต้นใหม่
        else # ไม่ได้อยู่ในโหมดโค้ง "สุดเวอร์" (โหมดปกติ - วาดเส้นตรง/โค้งมน)
          effective_direction = @current_drawing_direction
          if !effective_direction.is_a?(Geom::Vector3d) || !effective_direction.valid? || effective_direction.length == 0
            vector_to_mouse = @ip.position - p0
            if vector_to_mouse.valid? && vector_to_mouse.length > 0
              effective_direction = vector_to_mouse.normalize
            else
              effective_direction = X_AXIS  
            end
          end

          finish_point = p0.offset(effective_direction, length)

          # สร้างจุดควบคุมสำหรับความโค้งมนเล็กน้อย (โค้งเมื่อตัดมุม)
          if length > 0.001
            mid_point_for_default_curve = p0.offset(effective_direction, length / 2.0)
            
            vec_orthogonal_for_default = find_perpendicular_vector(effective_direction, view.camera.up.normalize, view.camera.direction.normalize)
            
            sagitta_for_default_curve = length * DEFAULT_CURVE_SAGITTA_FACTOR
            control_point_for_default_curve = mid_point_for_default_curve.offset(vec_orthogonal_for_default, sagitta_for_default_curve)
            
            bezier_points_default = calculate_bezier_points(p0, control_point_for_default_curve, finish_point, BEZIER_SEGMENTS)
            
            if bezier_points_default.length > 1
                edges = model.active_entities.add_curve(bezier_points_default)
                if edges && edges.first.is_a?(Sketchup::Edge)
                    edges.each { |e| e.material = @color }
                end
            end
          else
            model.active_entities.add_point(p0)
          end
        end

        model.commit_operation

        temp_ip_for_inference = Sketchup::InputPoint.new(@points.last)
        @ip.pick(view, @last_mouse_x, @last_mouse_y, temp_ip_for_inference)
        
      rescue => e  
        UI.messagebox("เกิดข้อผิดพลาดในการป้อนค่า: #{e.message}\nใส่ระยะไม่ถูกต้อง เช่น 2m, 150cm, 100mm", MB_OK)
      ensure
        @axis_lock = nil
        @lock_direction = nil
        @force_axis = false
        @color = Sketchup::Color.new(0,0,0)  
        @current_drawing_direction = nil  
        @arc_mode = false # รีเซ็ตโหมดโค้ง "สุดเวอร์"
        @bezier_control_point = nil # รีเซ็ตจุดควบคุม Bezier
        view.invalidate
      end
    end

    def draw(view)
      return if @points.empty?
      return unless @ip.valid?

      p0 = @points.last # จุดเริ่มต้น (P0)
      preview_p2 = @ip.position  # จุดปลายพรีวิว (P2) - ตำแหน่งเมาส์ปัจจุบัน

      # ถ้าอยู่ในโหมดล็อกแกน (force_axis) ให้วาดเส้นแกนนำ
      if @force_axis && @lock_direction
        line_length = 1000.feet  
        start_axis_line = p0.offset(@lock_direction.reverse, line_length)
        end_axis_line = p0.offset(@lock_direction, line_length)
        
        view.line_width = LOCKED_AXIS_LINE_WIDTH  
        view.drawing_color = @color  
        view.draw(GL_LINES, [start_axis_line, end_axis_line])
      end

      # คำนวณ preview_p2 ใหม่ถ้ามีการล็อกแกนหรือมีการ inference ทิศทาง (เฉพาะในโหมดเส้นตรง)
      if @current_drawing_direction && @current_drawing_direction.valid? && @current_drawing_direction.length > 0 && !@arc_mode 
        vector_from_start = preview_p2 - p0
        if vector_from_start.valid? && vector_from_start.length > 0
          projection_scalar = vector_from_start.dot(@current_drawing_direction)
          preview_p2 = p0.offset(@current_drawing_direction, projection_scalar)
        else
          preview_p2 = p0  
        end
      end
      
      view.line_width = PREVIEW_LINE_WIDTH  
      view.drawing_color = @color  
      
      if @arc_mode && @bezier_control_point # พรีวิวเส้นโค้ง "สุดเวอร์" (โหมด 2 Point Arc)
        # P0: p0 (จุดเริ่มต้น)
        # P1: @bezier_control_point (ถูกคำนวณใน onMouseMove เพื่อกำหนด "Bulge")
        # P2: preview_p2 (ตำแหน่งเมาส์ปัจจุบัน)
        bezier_preview_points = calculate_bezier_points(p0, @bezier_control_point, preview_p2, BEZIER_SEGMENTS)
        
        if bezier_preview_points.length > 1
            view.draw(GL_LINE_STRIP, bezier_preview_points)
        end

        # วาดเส้นคอร์ด (P0-P2) และเส้นประจาก mid_point_chord ไปยัง P1 (แสดง Bulge)
        view.line_stipple = [0xF0F0, 10, 10] # Dash pattern
        view.drawing_color = Sketchup::Color.new(128, 128, 128) # สีเทา
        view.draw(GL_LINES, [p0, preview_p2]) # วาดคอร์ด
        
        mid_point_chord = Geom::Point3d.linear_combination(0.5, p0, 0.5, preview_p2)
        view.draw(GL_LINES, [mid_point_chord, @bezier_control_point]) # วาดเส้น Bulge

        view.line_stipple = [] # Reset stipple
      else # พรีวิวเส้นโค้งมน (โหมดปกติ - ไม่ได้กด Shift)
        length_preview = (preview_p2 - p0).length
        if length_preview > 0.001
            line_direction_preview = (preview_p2 - p0).normalize

            # ใช้ helper method ในการหา vector ตั้งฉาก
            # Normalizing view.camera.up and view.camera.direction for safety
            control_perp_vector = find_perpendicular_vector(line_direction_preview, view.camera.up.normalize, view.camera.direction.normalize)
            
            mid_point_preview = p0.offset(line_direction_preview, length_preview / 2.0)
            
            sagitta_preview = length_preview * DEFAULT_CURVE_SAGITTA_FACTOR # ความโค้งมนเล็กน้อยสำหรับการพรีวิว
            control_point_preview = mid_point_preview.offset(control_perp_vector, sagitta_preview)
            
            bezier_preview_points_default = calculate_bezier_points(p0, control_point_preview, preview_p2, BEZIER_SEGMENTS)
            
            if bezier_preview_points_default.length > 1
                view.draw(GL_LINE_STRIP, bezier_preview_points_default)
            end
        else
            view.draw(GL_LINES, [p0, preview_p2]) # ถ้าความยาวเป็น 0 ก็วาดจุดเดียวหรือเส้นตรงสั้นๆ
        end
      end

      # แสดง VCB Value (ความยาว)
      if @points.size > 0
        length = (preview_p2 - p0).length
        Sketchup.vcb_value = length  
      end
    end
  end # class CustomLineTool

  unless file_loaded?(__FILE__)
    cmd = UI::Command.new("Custom Line Tool") {
      Sketchup.active_model.select_tool(CustomLineTool.new)
    }
    cmd.tooltip = "เครื่องมือวาดเส้นแบบกำหนดเอง"
    cmd.status_bar_text = "คลิกเพื่อวางจุด | พิมพ์ระยะ + Enter | ←↑→↓ สลับการล็อกแกน | ESC ยกเลิก | Shift สำหรับโหมดโค้ง (2 จุด)"
    
    icon_base_name = File.basename(__FILE__, ".rb")
    current_dir = File.dirname(__FILE__)
    
    icon_path_24 = File.join(current_dir, "#{icon_base_name}_24.png")
    icon_path_32 = File.join(current_dir, "#{icon_base_name}_32.png")

    cmd.small_icon = icon_path_24 if File.exist?(icon_path_24)
    cmd.large_icon = icon_path_32 if File.exist?(icon_path_32)

    toolbar = UI::Toolbar.new("Custom Tools")
    toolbar.add_item(cmd)
    toolbar.show

    menu = UI.menu("Extensions").add_submenu("My Custom Tools")
    menu.add_item(cmd)

    file_loaded(__FILE__)
  end

end # module MyCustomTools