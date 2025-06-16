module MyFacePusher
  extend self

  class FacePushTool
    def initialize(dialog)
      @distance = 0.1 # Changed default distance to 0.1 meter
      @direction = 1
      @dialog = dialog
      @active = false
      @move_mode = false
      @moving_entity = nil
      @move_start_point = nil
    end

    def activate
      @active = true
      update_status
      update_ui
      Sketchup.set_status_text("Face Pusher Tool เปิดใช้งานแล้ว", SB_PROMPT)
    end

    def deactivate(view)
      @active = false
      @move_mode = false
      @moving_entity = nil
      update_ui
      Sketchup.set_status_text("Face Pusher Tool ปิดใช้งานแล้ว", SB_PROMPT)
    end

    def onLButtonDown(flags, x, y, view)
      return unless @active
      
      if @move_mode
        start_move(x, y, view)
      else
        start_pushpull(x, y, view)
      end
    end

    def onMouseMove(flags, x, y, view)
      return unless @move_mode && @moving_entity
      
      # การเคลื่อนย้ายแบบมาตรฐานของ SketchUp
      ray = view.pickray(x, y)
      plane = [@move_start_point, view.camera.direction]
      point = Geom.intersect_line_plane(ray, plane)
      
      if point
        vector = point - @move_start_point
        tr = Geom::Transformation.translation(vector)
        @moving_entity.transform!(tr)
        @move_start_point = point
        view.refresh
      end
    end

    def onLButtonUp(flags, x, y, view)
      return unless @move_mode && @moving_entity
      
      begin
        Sketchup.active_model.commit_operation
        @dialog.execute_script("sketchup.showSuccess('เคลื่อนย้ายวัตถุสำเร็จ');")
      ensure
        @moving_entity = nil
        @move_mode = false
        update_status
        update_ui
      end
    end

    private

    def start_pushpull(x, y, view)
      ph = view.pick_helper
      ph.do_pick(x, y)
      picked = ph.best_picked

      unless picked.is_a?(Sketchup::Face)
        @dialog.execute_script("sketchup.showError('กรุณาคลิกที่ Face เท่านั้น');")
        return
      end

      model = Sketchup.active_model
      model.start_operation("Face PushPull", true)
      begin
        push_distance = @distance * @direction
        picked.pushpull(push_distance)
        model.commit_operation
        @dialog.execute_script("sketchup.showSuccess('Push/Pull #{@distance} เมตร สำเร็จ');") # Changed text to meters
      rescue => e
        model.abort_operation
        @dialog.execute_script("sketchup.showError('เกิดข้อผิดพลาด: #{e.message}');")
      end
    end

    def start_move(x, y, view)
      ph = view.pick_helper
      ph.do_pick(x, y)
      picked = ph.best_picked

      unless picked.respond_to?(:transform!)
        @dialog.execute_script("sketchup.showError('กรุณาคลิกที่วัตถุที่ต้องการเคลื่อนย้าย');")
        return
      end

      model = Sketchup.active_model
      model.start_operation("Move Object", true)
      begin
        @moving_entity = picked
        @move_start_point = ph.picked_point
        
        unless @move_start_point
          @move_start_point = @moving_entity.bounds.center
        end
        
        @move_mode = true
        update_ui
        Sketchup.set_status_text("โหมดเคลื่อนย้าย - ลากเพื่อเคลื่อนย้ายวัตถุ", SB_PROMPT)
      rescue => e
        model.abort_operation
        @dialog.execute_script("sketchup.showError('Move ผิดพลาด: #{e.message}');")
        @moving_entity = nil
        @move_mode = false
        update_ui
      end
    end

    def update_ui
      @dialog.execute_script("
        // Update toggle button
        const toggleBtn = document.getElementById('toggle_tool');
        toggleBtn.textContent = '#{@active ? 'เปิดปิดการใช้งาน Tool' : 'เปิดการใช้งาน Tool'}';
        toggleBtn.className = #{@active ? '"active-btn"' : '""'};
        
        // Update move mode button
        const moveBtn = document.getElementById('move_up_btn');
        moveBtn.textContent = '#{@move_mode ? 'ยกเลิกโหมดเคลื่อนย้าย' : 'โหมดเคลื่อนย้ายด้วยเมาส์'}';
        moveBtn.className = #{@move_mode ? '"active-btn"' : '""'};
        
        // Update direction buttons
        document.getElementById('plus').className = #{@direction > 0 ? '"active-btn"' : '""'};
        document.getElementById('minus').className = #{@direction < 0 ? '"active-btn"' : '""'};
        
        // Highlight distance input when active
        document.getElementById('distance').className = #{@active ? '"active-input"' : '""'};
      ")
    end

    public

    def toggle_move_mode
      @move_mode = !@move_mode
      
      if @move_mode
        Sketchup.set_status_text("โหมดเคลื่อนย้าย - คลิกที่วัตถุที่ต้องการเคลื่อนย้าย", SB_PROMPT)
      else
        @moving_entity = nil
        Sketchup.set_status_text("Face Pusher Tool: #{@distance} เมตร, ทิศทาง #{@direction > 0 ? '+' : '-'}", SB_PROMPT) # Changed text to meters
      end
      
      update_ui
    end

    def update_distance(dist)
      @distance = dist.to_f.abs
      update_status
      @dialog.execute_script("
        const distInput = document.getElementById('distance');
        distInput.classList.add('highlight');
        setTimeout(() => distInput.classList.remove('highlight'), 300);
      ")
    end

    def update_direction(dir)
      @direction = dir.to_i
      update_status
      update_ui
    end

    def toggle_tool
      @active = !@active
      
      if @active
        if @distance <= 0
          @dialog.execute_script("sketchup.showError('กรุณาใส่ระยะที่ถูกต้อง (มากกว่า 0)');")
          @active = false
          return
        end
        Sketchup.active_model.select_tool(self)
      else
        Sketchup.active_model.select_tool(nil)
      end
      
      update_status
      update_ui
    end

    def update_status
      return unless @active
      
      dir_str = @direction > 0 ? '+' : '-'
      status = @move_mode ? "โหมดเคลื่อนย้าย - คลิกที่วัตถุที่ต้องการเคลื่อนย้าย" : 
                           "Face Push Tool: #{@distance} เมตร, ทิศทาง #{dir_str}" # Changed text to meters
      Sketchup.set_status_text(status, SB_PROMPT)
    end
  end

  def show_ui
    html = <<~HTML
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="utf-8">
        <title>Face Pusher</title>
        <style>
          body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: #f5f5f5;
            color: #333;
            padding: 20px;
            margin: 0;
          }
          .container {
            max-width: 400px;
            margin: 0 auto;
            background: white;
            border-radius: 10px;
            padding: 20px;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
          }
          h1 {
            text-align: center;
            color: #2c3e50;
            margin-bottom: 25px;
            font-size: 24px;
          }
          label {
            display: block;
            margin-bottom: 8px;
            font-weight: bold;
            color: #34495e;
          }
          input[type="number"] {
            width: 100%;
            padding: 10px;
            font-size: 16px;
            border-radius: 5px;
            border: 1px solid #ddd;
            margin-bottom: 20px;
            box-sizing: border-box;
            transition: all 0.3s;
          }
          input[type="number"]:focus {
            border-color: #3498db;
            outline: none;
          }
          .active-input {
            border-color: #3498db !important;
            box-shadow: 0 0 0 2px rgba(52,152,219,0.2);
          }
          .btn-group {
            display: flex;
            gap: 10px;
            margin-bottom: 20px;
          }
          button {
            padding: 12px;
            font-size: 16px;
            border-radius: 5px;
            border: none;
            cursor: pointer;
            transition: all 0.3s;
            font-weight: bold;
            flex: 1;
          }
          button:hover {
            transform: translateY(-2px);
            box-shadow: 0 4px 8px rgba(0,0,0,0.1);
          }
          button:active {
            transform: translateY(0);
          }
          #plus {
            background: #27ae60;
            color: white;
          }
          #minus {
            background: #e74c3c;
            color: white;
          }
          #toggle_tool, #move_up_btn {
            width: 100%;
            margin-bottom: 15px;
            background: #3498db;
            color: white;
          }
          .active-btn {
            position: relative;
            box-shadow: 0 0 0 2px rgba(255,255,255,0.8), 0 0 0 4px rgba(52,152,219,0.5);
            border: 2px solid white !important;
          }
          .highlight {
            animation: highlight 0.5s;
          }
          @keyframes highlight {
            0% { box-shadow: 0 0 0 0 rgba(52,152,219,0.7); }
            100% { box-shadow: 0 0 0 10px rgba(52,152,219,0); }
          }
          .message {
            padding: 10px;
            border-radius: 5px;
            margin-top: 15px;
            text-align: center;
            display: none;
            font-weight: bold;
          }
          .success {
            background: rgba(46,204,113,0.2);
            color: #27ae60;
            display: block;
          }
          .error {
            background: rgba(231,76,60,0.2);
            color: #e74c3c;
            display: block;
          }
        </style>
      </head>
      <body>
        <div class="container">
          <h1>Face Pusher Tool</h1>
          
          <label for="distance">ระยะดัน/ดึง (เมตร):</label> // Changed text to meters
          <input id="distance" type="number" min="0.01" step="0.01" value="0.1"> // Changed default value and step for meters
          
          <div class="btn-group">
            <button id="plus">+ </button>
            <button id="minus">- </button>
          </div>
          
          <button id="toggle_tool">เปิดปิดการใช้งาน Tool</button>
          <p >สามารถเช็คด่านล่างซ่ายว่า เปิด/ปิด tool แล้ว <br>
            (ตัวอย่าง) ให้กดที่ .เปิดปิดการใช้งาน Tool. หากปิดอยู๋จะขึ้่นว่า <br>
            Click or drag to select objects. <br> Shift = Add/Subtract. <br>Ctrl = Add. Shift + Ctrl = Subtract.
          </p>
          <button id="move_up_btn">โหมดเคลื่อนย้ายด้วยเมาส์</button>
          
          <div id="message" class="message"></div>
        </div>

        <script>
          function showSuccess(text) {
            const msg = document.getElementById('message');
            msg.textContent = text;
            msg.className = 'message success';
            setTimeout(() => msg.className = 'message', 3000);
          }
          
          function showError(text) {
            const msg = document.getElementById('message');
            msg.textContent = text;
            msg.className = 'message error';
            setTimeout(() => msg.className = 'message', 3000);
          }

          // Direction buttons
          document.getElementById('plus').addEventListener('click', function() {
            this.classList.add('highlight');
            setTimeout(() => this.classList.remove('highlight'), 300);
            window.location.href = 'skp:update_direction@1';
          });

          document.getElementById('minus').addEventListener('click', function() {
            this.classList.add('highlight');
            setTimeout(() => this.classList.remove('highlight'), 300);
            window.location.href = 'skp:update_direction@-1';
          });

          // Distance input
          document.getElementById('distance').addEventListener('change', function() {
            const value = parseFloat(this.value);
            if (isNaN(value) || value <= 0) {
              showError('กรุณาใส่ระยะที่ถูกต้อง (มากกว่า 0)');
              this.value = 0.1; // Changed default value to 0.1 for meters
              return;
            }
            this.classList.add('highlight');
            setTimeout(() => this.classList.remove('highlight'), 300);
            window.location.href = 'skp:update_distance@' + value;
          });

          // Tool toggle
          document.getElementById('toggle_tool').addEventListener('click', function() {
            this.classList.add('highlight');
            setTimeout(() => this.classList.remove('highlight'), 300);
            window.location.href = 'skp:toggle_tool';
          });

          // Move mode toggle
          document.getElementById('move_up_btn').addEventListener('click', function() {
            this.classList.add('highlight');
            setTimeout(() => this.classList.remove('highlight'), 300);
            window.location.href = 'skp:toggle_move_mode';
          });

          // Expose to Ruby
          window.sketchup = {
            showSuccess: showSuccess,
            showError: showError
          };
        </script>
      </body>
      </html>
    HTML

    # Create or reuse dialog
    @dialog ||= UI::HtmlDialog.new(
      dialog_title: "Face Pusher Tool",
      width: 420,
      height: 420,
      resizable: false,
      style: UI::HtmlDialog::STYLE_DIALOG
    )

    @dialog.set_html(html)
    @tool = FacePushTool.new(@dialog)

    # Setup callbacks
    @dialog.add_action_callback("update_distance") { |_, val| @tool.update_distance(val) }
    @dialog.add_action_callback("update_direction") { |_, val| @tool.update_direction(val) }
    @dialog.add_action_callback("toggle_tool") { |_, _| @tool.toggle_tool }
    @dialog.add_action_callback("toggle_move_mode") { |_, _| @tool.toggle_move_mode }

    # Create toolbar if not exists
    unless @toolbar
      @toolbar = UI::Toolbar.new "Face Pusher"
      
      cmd = UI::Command.new("Face Pusher") { show_ui }
      cmd.tooltip = "เปิด Face Pusher Tool"
      cmd.small_icon = "icons/icon_small.png"
      cmd.large_icon = "icons/icon_large.png"
      @toolbar.add_item cmd
    end

    @toolbar.show unless @toolbar.visible?
    @dialog.show
  end
end

# Start the tool
MyFacePusher.show_ui