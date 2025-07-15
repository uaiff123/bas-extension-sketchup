require 'sketchup.rb'
require 'json'

module Bowwownow
  module BoxMaker

    def self.create_toolbar
      cmd = UI::Command.new("สร้างกล่องเทพ") {
        self.show_ui
      }
      cmd.tooltip = "เปิดกล่อง UI"
      cmd.status_bar_text = "คลิกเพื่อสร้างกล่องสุดหล่อ"

      toolbar = UI::Toolbar.new("Box Maker")
      toolbar.add_item(cmd)
      toolbar.restore
    end

    def self.show_ui
      html = <<-HTML
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="UTF-8">
          <style>
            body { font-family: sans-serif; padding: 20px; background: #f9fafb; color: #111; }
            label { display: block; margin-top: 10px; }
            input, select { width: 100%; padding: 5px; margin-top: 5px; }
            button {
              margin-top: 15px;
              background: #4f46e5; color: white; padding: 10px;
              border: none; border-radius: 5px; cursor: pointer;
            }
            button:hover { background: #4338ca; }
          </style>
        </head>
        <body>
          <h2>🧱 สร้างกล่องเทพ</h2>
          <label>ความกว้าง (เมตร):</label>
          <input id="width" type="number" value="1" min="0.01" step="0.1">
          <label>ความยาว (เมตร):</label>
          <input id="length" type="number" value="1" min="0.01" step="0.1">
          <label>ความสูง (เมตร):</label>
          <input id="height" type="number" value="1" min="0.01" step="0.1">
          <label>ชื่อชิ้นงาน:</label>
          <input id="name" type="text" value="MyBox">
          <label>ชื่อ Layer (Tag):</label>
          <input id="layer" type="text" value="MyLayer">
          <button onclick="createBox()">สร้างเลย!</button>

          <script>
            function createBox() {
              const data = {
                width: parseFloat(document.getElementById('width').value),
                length: parseFloat(document.getElementById('length').value),
                height: parseFloat(document.getElementById('height').value),
                name: document.getElementById('name').value,
                layer: document.getElementById('layer').value
              };
              window.location = 'skp:create_box@' + JSON.stringify(data);
            }
          </script>
        </body>
        </html>
      HTML

      dialog = UI::HtmlDialog.new(
        dialog_title: "Box Maker",
        scrollable: true,
        resizable: false,
        width: 350,
        height: 450,
        style: UI::HtmlDialog::STYLE_DIALOG
      )
      dialog.set_html(html)

      dialog.add_action_callback("create_box") do |_, json_str|
        params = JSON.parse(json_str)
        self.create_box(params)
      end

      dialog.show
    end

    def self.create_box(params)
      model = Sketchup.active_model
      entities = model.active_entities
      model.start_operation("สร้างกล่อง", true)

      width = params["width"].m
      length = params["length"].m
      height = params["height"].m
      name = params["name"]
      layer_name = params["layer"]

      # สร้างกล่อง
      pts = [
        [0, 0, 0],
        [width, 0, 0],
        [width, length, 0],
        [0, length, 0]
      ]
      face = entities.add_face(pts)
      face.pushpull(height)

      group = entities.add_group(face.all_connected)
      group.name = name

      # กำหนด Tag (Layer)
      tag = model.layers[layer_name] || model.layers.add(layer_name)
      group.layer = tag

      model.commit_operation
    end

    unless file_loaded?(__FILE__)
      self.create_toolbar
      file_loaded(__FILE__)
    end

  end
end
