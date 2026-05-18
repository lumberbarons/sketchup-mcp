require 'sketchup'
require 'json'
require 'socket'
require 'fileutils'

puts "MCP Extension loading..."
SKETCHUP_CONSOLE.show rescue nil

module SU_MCP
  class Server
    def initialize
      @port = 9876
      @server = nil
      @running = false
      @timer_id = nil
      
      # Try multiple ways to show console
      begin
        SKETCHUP_CONSOLE.show
      rescue
        begin
          Sketchup.send_action("showRubyPanel:")
        rescue
          UI.start_timer(0) { SKETCHUP_CONSOLE.show }
        end
      end
    end

    def log(msg)
      begin
        SKETCHUP_CONSOLE.write("MCP: #{msg}\n")
      rescue
        puts "MCP: #{msg}"
      end
      STDOUT.flush
    end

    def start
      return if @running
      
      begin
        log "Starting server on localhost:#{@port}..."
        
        @server = TCPServer.new('127.0.0.1', @port)
        log "Server created on port #{@port}"
        
        @running = true
        
        @timer_id = UI.start_timer(0.1, true) {
          begin
            if @running
              # Check for connection
              ready = IO.select([@server], nil, nil, 0)
              if ready
                log "Connection waiting..."
                client = @server.accept_nonblock
                log "Client accepted"
                
                data = client.gets
                log "Raw data: #{data.inspect}"
                
                if data
                  begin
                    # Parse the raw JSON first to check format
                    raw_request = JSON.parse(data)
                    log "Raw parsed request: #{raw_request.inspect}"
                    
                    # Extract the original request ID if it exists in the raw data
                    original_id = nil
                    if data =~ /"id":\s*(\d+)/
                      original_id = $1.to_i
                      log "Found original request ID: #{original_id}"
                    end
                    
                    # Use the raw request directly without transforming it
                    # Just ensure the ID is preserved if it exists
                    request = raw_request
                    if !request["id"] && original_id
                      request["id"] = original_id
                      log "Added missing ID: #{original_id}"
                    end
                    
                    log "Processed request: #{request.inspect}"
                    response = handle_jsonrpc_request(request)
                    response_json = response.to_json + "\n"
                    
                    log "Sending response: #{response_json.strip}"
                    client.write(response_json)
                    client.flush
                    log "Response sent"
                  rescue JSON::ParserError => e
                    log "JSON parse error: #{e.message}"
                    error_response = {
                      jsonrpc: "2.0",
                      error: { code: -32700, message: "Parse error" },
                      id: original_id
                    }.to_json + "\n"
                    client.write(error_response)
                    client.flush
                  rescue StandardError => e
                    log "Request error: #{e.message}"
                    error_response = {
                      jsonrpc: "2.0",
                      error: { code: -32603, message: e.message },
                      id: request ? request["id"] : original_id
                    }.to_json + "\n"
                    client.write(error_response)
                    client.flush
                  end
                end
                
                client.close
                log "Client closed"
              end
            end
          rescue IO::WaitReadable
            # Normal for accept_nonblock
          rescue StandardError => e
            log "Timer error: #{e.message}"
            log e.backtrace.join("\n")
          end
        }
        
        log "Server started and listening"
        
      rescue StandardError => e
        log "Error: #{e.message}"
        log e.backtrace.join("\n")
        stop
      end
    end

    def stop
      log "Stopping server..."
      @running = false
      
      if @timer_id
        UI.stop_timer(@timer_id)
        @timer_id = nil
      end
      
      @server.close if @server
      @server = nil
      log "Server stopped"
    end

    private

    def handle_jsonrpc_request(request)
      log "Handling JSONRPC request: #{request.inspect}"
      
      # Handle direct command format (for backward compatibility)
      if request["command"]
        tool_request = {
          "method" => "tools/call",
          "params" => {
            "name" => request["command"],
            "arguments" => request["parameters"]
          },
          "jsonrpc" => request["jsonrpc"] || "2.0",
          "id" => request["id"]
        }
        log "Converting to tool request: #{tool_request.inspect}"
        return handle_tool_call(tool_request)
      end

      # Handle jsonrpc format
      case request["method"]
      when "tools/call"
        handle_tool_call(request)
      when "resources/list"
        {
          jsonrpc: request["jsonrpc"] || "2.0",
          result: { 
            resources: list_resources,
            success: true
          },
          id: request["id"]
        }
      when "prompts/list"
        {
          jsonrpc: request["jsonrpc"] || "2.0",
          result: { 
            prompts: [],
            success: true
          },
          id: request["id"]
        }
      else
        {
          jsonrpc: request["jsonrpc"] || "2.0",
          error: { 
            code: -32601, 
            message: "Method not found",
            data: { success: false }
          },
          id: request["id"]
        }
      end
    end

    def list_resources
      model = Sketchup.active_model
      return [] unless model
      
      model.entities.map do |entity|
        {
          id: entity.entityID,
          type: entity.typename.downcase
        }
      end
    end

    def handle_tool_call(request)
      log "Handling tool call: #{request.inspect}"

      begin
        params = request["params"] or raise "tools/call request is missing 'params'"
        tool_name = params["name"]
        args = params["arguments"]

        result = case tool_name
        when "create_component"
          create_component(args)
        when "create_extrusion"
          create_extrusion(args)
        when "batch_create"
          batch_create(args)
        when "delete_component"
          delete_component(args)
        when "transform_component"
          transform_component(args)
        when "find_groups"
          find_groups(args)
        when "inspect_geometry"
          inspect_geometry(args)
        when "replace_geometry"
          replace_geometry(args)
        when "get_selection"
          get_selection
        when "export", "export_scene"
          export_scene(args)
        when "set_material"
          set_material(args)
        when "boolean_operation"
          boolean_operation(args)
        when "pattern_linear"
          pattern_linear(args)
        when "mirror_component"
          mirror_component(args)
        when "validate_geometry"
          validate_geometry(args)
        when "intersect_ray"
          intersect_ray(args)
        when "chamfer_edges"
          chamfer_edges(args)
        when "fillet_edges"
          fillet_edges(args)
        when "eval_ruby"
          eval_ruby(args)
        else
          raise "Unknown tool: #{tool_name}"
        end

        log "Tool call result: #{result.inspect}"
        if result[:success]
          # Merge any extra structured fields from the handler (e.g. find_groups'
          # :groups + :truncated, create_*'s :bounds) into the JSON-RPC result so
          # they survive the round trip. Without this, only :result and :id are
          # transmitted and richer payloads collapse to "Success".
          extra = result.reject { |k, _| %i[success result id].include?(k) }
          inner = {
            content: [{ type: "text", text: result[:result] || "Success" }],
            isError: false,
            success: true,
            resourceId: result[:id]
          }.merge(extra)
          response = {
            jsonrpc: request["jsonrpc"] || "2.0",
            result: inner,
            id: request["id"]
          }
          log "Sending success response: #{response.inspect}"
          response
        else
          response = {
            jsonrpc: request["jsonrpc"] || "2.0",
            error: { 
              code: -32603, 
              message: "Operation failed",
              data: { success: false }
            },
            id: request["id"]
          }
          log "Sending error response: #{response.inspect}"
          response
        end
      rescue StandardError => e
        log "Tool call error: #{e.message}"
        response = {
          jsonrpc: request["jsonrpc"] || "2.0",
          error: { 
            code: -32603, 
            message: e.message,
            data: { success: false }
          },
          id: request["id"]
        }
        log "Sending error response: #{response.inspect}"
        response
      end
    end

    # Build the standard create_* response: id + the world bounds the entity
    # actually occupies, in inches. Returning bounds saves the agent a follow-up
    # round trip to verify placement and catches geometry-direction surprises
    # (pushpull going the wrong way, bird's-mouth offsets, etc.) immediately.
    def bounds_result(entity)
      bmin = entity.bounds.min
      bmax = entity.bounds.max
      {
        id: entity.entityID,
        bounds: {
          min: [bmin.x.to_f, bmin.y.to_f, bmin.z.to_f],
          max: [bmax.x.to_f, bmax.y.to_f, bmax.z.to_f]
        },
        success: true
      }
    end

    def create_component(params)
      log "Creating component with params: #{params.inspect}"
      model = Sketchup.active_model
      log "Got active model: #{model.inspect}"
      entities = model.active_entities
      log "Got active entities: #{entities.inspect}"

      pos = params["position"] || [0,0,0]
      dims = params["dimensions"] || [1,1,1]
      name = params["name"]
      type = params["type"] || "cube"

      result = case type
      when "cube"
        log "Creating cube at position #{pos.inspect} with dimensions #{dims.inspect}"

        begin
          group = entities.add_group
          log "Created group: #{group.inspect}"

          face = group.entities.add_face(
            [pos[0], pos[1], pos[2]],
            [pos[0] + dims[0], pos[1], pos[2]],
            [pos[0] + dims[0], pos[1] + dims[1], pos[2]],
            [pos[0], pos[1] + dims[1], pos[2]]
          )
          log "Created face: #{face.inspect}"

          # SketchUp's add_face picks a front side heuristically, which means
          # an isolated horizontal face can end up with its normal pointing -z.
          # pushpull extrudes along the *front normal*, so without this guard
          # tall pieces sometimes build below z=pos[2] instead of above.
          face.reverse! if face.normal.z < 0
          face.pushpull(dims[2])
          log "Pushed/pulled face by #{dims[2]} (normal +z)"

          result = bounds_result(group)
          log "Returning result: #{result.inspect}"
          result
        rescue StandardError => e
          log "Error in create_component: #{e.message}"
          log e.backtrace.join("\n")
          raise
        end
      when "cylinder"
        log "Creating cylinder at position #{pos.inspect} with dimensions #{dims.inspect}"
        
        begin
          # Create a group to contain the cylinder
          group = entities.add_group
          
          # Extract dimensions
          radius = dims[0] / 2.0
          height = dims[2]
          
          # Create a circle at the base
          center = [pos[0] + radius, pos[1] + radius, pos[2]]
          
          # Create points for a circle
          num_segments = 24  # Number of segments for the circle
          circle_points = []
          
          num_segments.times do |i|
            angle = Math::PI * 2 * i / num_segments
            x = center[0] + radius * Math.cos(angle)
            y = center[1] + radius * Math.sin(angle)
            z = center[2]
            circle_points << [x, y, z]
          end
          
          # Create the circular face
          face = group.entities.add_face(circle_points)

          # See cube branch: ensure +z normal so pushpull(height) extrudes up.
          face.reverse! if face.normal.z < 0
          face.pushpull(height)

          result = bounds_result(group)
          log "Created cylinder, returning result: #{result.inspect}"
          result
        rescue StandardError => e
          log "Error creating cylinder: #{e.message}"
          log e.backtrace.join("\n")
          raise
        end
      when "sphere"
        log "Creating sphere at position #{pos.inspect} with dimensions #{dims.inspect}"
        
        begin
          # Create a group to contain the sphere
          group = entities.add_group
          
          # Extract dimensions
          radius = dims[0] / 2.0
          center = [pos[0] + radius, pos[1] + radius, pos[2] + radius]
          
          # Use SketchUp's built-in sphere method if available
          if Sketchup::Tools.respond_to?(:create_sphere)
            Sketchup::Tools.create_sphere(center, radius, 24, group.entities)
          else
            # Fallback implementation using polygons
            # Create a UV sphere with latitude and longitude segments
            segments = 16
            
            # Create points for the sphere
            points = []
            for lat_i in 0..segments
              lat = Math::PI * lat_i / segments
              for lon_i in 0..segments
                lon = 2 * Math::PI * lon_i / segments
                x = center[0] + radius * Math.sin(lat) * Math.cos(lon)
                y = center[1] + radius * Math.sin(lat) * Math.sin(lon)
                z = center[2] + radius * Math.cos(lat)
                points << [x, y, z]
              end
            end
            
            # Create faces for the sphere (simplified approach)
            for lat_i in 0...segments
              for lon_i in 0...segments
                i1 = lat_i * (segments + 1) + lon_i
                i2 = i1 + 1
                i3 = i1 + segments + 1
                i4 = i3 + 1
                
                # Create a quad face
                begin
                  group.entities.add_face(points[i1], points[i2], points[i4], points[i3])
                rescue StandardError => e
                  # Skip faces that can't be created (may happen at poles)
                  log "Skipping face: #{e.message}"
                end
              end
            end
          end
          
          result = bounds_result(group)
          log "Created sphere, returning result: #{result.inspect}"
          result
        rescue StandardError => e
          log "Error creating sphere: #{e.message}"
          log e.backtrace.join("\n")
          raise
        end
      when "cone"
        log "Creating cone at position #{pos.inspect} with dimensions #{dims.inspect}"
        
        begin
          # Create a group to contain the cone
          group = entities.add_group
          
          # Extract dimensions
          radius = dims[0] / 2.0
          height = dims[2]
          
          # Create a circle at the base
          center = [pos[0] + radius, pos[1] + radius, pos[2]]
          apex = [center[0], center[1], center[2] + height]
          
          # Create points for a circle
          num_segments = 24  # Number of segments for the circle
          circle_points = []
          
          num_segments.times do |i|
            angle = Math::PI * 2 * i / num_segments
            x = center[0] + radius * Math.cos(angle)
            y = center[1] + radius * Math.sin(angle)
            z = center[2]
            circle_points << [x, y, z]
          end
          
          # Create the circular face for the base
          base = group.entities.add_face(circle_points)

          # Keep base normal pointing -z so the cone sits below the apex
          # (and sphere/cone bookkeeping stays consistent with cube/cylinder).
          base.reverse! if base.normal.z > 0

          # Create the cone sides
          (0...num_segments).each do |i|
            j = (i + 1) % num_segments
            # Create a triangular face from two adjacent points on the circle to the apex
            group.entities.add_face(circle_points[i], circle_points[j], apex)
          end

          result = bounds_result(group)
          log "Created cone, returning result: #{result.inspect}"
          result
        rescue StandardError => e
          log "Error creating cone: #{e.message}"
          log e.backtrace.join("\n")
          raise
        end
      else
        raise "Unknown component type: #{type}"
      end

      if name && !name.to_s.empty?
        group = model.find_entity_by_id(result[:id])
        group.name = name.to_s if group
        result[:name] = name.to_s
      end
      result
    end

    def create_extrusion(params)
      log "create_extrusion params: #{params.inspect}"

      name = params["name"].to_s
      profile = params["profile"]
      axis = params["extrude_axis"]
      from = params["extrude_from"]
      to = params["extrude_to"]
      plane = params["plane"]
      extrude_depth = params["extrude_depth"]
      holes = params["holes"]

      raise "'name' is required" if name.empty?
      unless profile.is_a?(Array) && profile.length >= 3
        raise "'profile' must be an array of at least 3 [a, b] vertices"
      end

      axis_mode = !axis.nil?
      plane_mode = !plane.nil?
      if axis_mode && plane_mode
        raise "Provide either 'extrude_axis' or 'plane', not both"
      end
      unless axis_mode || plane_mode
        raise "Provide one of 'extrude_axis' or 'plane'"
      end

      if holes
        raise "'holes' must be an array of polygons" unless holes.is_a?(Array)
        holes.each_with_index do |h, i|
          unless h.is_a?(Array) && h.length >= 3
            raise "hole ##{i + 1} must be an array of at least 3 [a, b] vertices"
          end
        end
        validate_holes(profile, holes)
      end

      if axis_mode
        axis_s = axis.to_s
        unless %w[x y z].include?(axis_s)
          raise "'extrude_axis' must be one of 'x', 'y', 'z' (got #{axis.inspect})"
        end
        unless from.is_a?(Numeric) && to.is_a?(Numeric)
          raise "'extrude_from' and 'extrude_to' must be numbers"
        end
        raise "'extrude_from' and 'extrude_to' must differ" if from == to

        outer_tuples = build_profile_points(profile, axis_s, from.to_f)
        hole_tuples = (holes || []).map { |h| build_profile_points(h, axis_s, from.to_f) }
        dx, dy, dz = extrude_direction(axis_s, from.to_f, to.to_f)
        desired = Geom::Vector3d.new(dx, dy, dz)
        depth = (to - from).abs.to_f
      else
        origin = plane["origin"]
        normal = plane["normal"]
        unless origin.is_a?(Array) && origin.length == 3
          raise "'plane.origin' must be a 3-element array"
        end
        unless normal.is_a?(Array) && normal.length == 3
          raise "'plane.normal' must be a 3-element array"
        end
        unless extrude_depth.is_a?(Numeric)
          raise "'extrude_depth' (number) is required when 'plane' is provided"
        end
        raise "'extrude_depth' must not be zero" if extrude_depth.zero?

        u, v, n = build_plane_basis(normal)
        outer_tuples = plane_profile_to_3d(profile, origin, u, v)
        hole_tuples = (holes || []).map { |h| plane_profile_to_3d(h, origin, u, v) }
        sign = extrude_depth.to_f > 0 ? 1.0 : -1.0
        desired = Geom::Vector3d.new(n[0] * sign, n[1] * sign, n[2] * sign)
        depth = extrude_depth.abs.to_f
      end

      points = outer_tuples.map { |x, y, z| Geom::Point3d.new(x, y, z) }
      hole_pts_3d_lists = hole_tuples.map { |h| h.map { |x, y, z| Geom::Point3d.new(x, y, z) } }

      model = Sketchup.active_model
      group = model.active_entities.add_group
      group.name = name

      face = group.entities.add_face(points)
      # Generalization of the cube-branch face.reverse! guard: pushpull
      # extrudes along the face's *front* normal, so flip the face when its
      # normal disagrees with the direction the caller asked for. This is
      # what makes vertex-winding irrelevant from the caller's point of view.
      face.reverse! if face.normal.dot(desired) < 0

      # Cut each hole by adding its face inside the outer, then erasing the
      # face — leaves the inner-loop edges, turning the outer face into a
      # face-with-hole that pushpull carries through as a void.
      hole_pts_3d_lists.each do |hole_pts|
        hole_face = group.entities.add_face(hole_pts)
        hole_face.erase! if hole_face
      end

      # `face` may have been invalidated by the hole-cutting splits; refind
      # the outer (largest-area) face and re-check its normal direction.
      target = face.valid? ? face : group.entities.grep(Sketchup::Face).max_by(&:area)
      target.reverse! if target.normal.dot(desired) < 0
      target.pushpull(depth)

      apply_material(group, params["material"]) if params["material"]

      bounds_result(group)
    end

    # Pure: map a 2D profile + fixed-axis coordinate into [x, y, z] tuples.
    # The axis names the *extrude* direction, so the profile lives in the
    # plane perpendicular to it.
    def build_profile_points(profile, axis, fixed)
      fixed = fixed.to_f
      profile.map do |pair|
        a = pair[0].to_f
        b = pair[1].to_f
        case axis.to_s
        when "x" then [fixed, a, b]
        when "y" then [a, fixed, b]
        when "z" then [a, b, fixed]
        end
      end
    end

    # Pure: unit vector along `axis` pointing from `from` toward `to`. Used
    # to decide whether to flip the face so pushpull extrudes the right way.
    def extrude_direction(axis, from, to)
      sign = (to - from) > 0 ? 1.0 : -1.0
      case axis.to_s
      when "x" then [sign, 0.0, 0.0]
      when "y" then [0.0, sign, 0.0]
      when "z" then [0.0, 0.0, sign]
      end
    end

    # Pure: orthonormal basis [u, v, n] for a plane with the given normal.
    # The 2D profile coordinate (a, b) maps to a*u + b*v on the plane. The
    # reference axis used to seed u is the world axis *least* aligned with
    # the normal — gives the most numerically stable cross product. Each
    # returned vector is a [x, y, z] tuple.
    def build_plane_basis(normal)
      nx = normal[0].to_f
      ny = normal[1].to_f
      nz = normal[2].to_f
      mag = Math.sqrt(nx * nx + ny * ny + nz * nz)
      raise "'plane.normal' must be a non-zero vector" if mag.zero?
      nx /= mag
      ny /= mag
      nz /= mag

      ax = nx.abs
      ay = ny.abs
      az = nz.abs
      ref = if az <= ax && az <= ay
        [0.0, 0.0, 1.0]
      elsif ax <= ay
        [1.0, 0.0, 0.0]
      else
        [0.0, 1.0, 0.0]
      end

      ux = ref[1] * nz - ref[2] * ny
      uy = ref[2] * nx - ref[0] * nz
      uz = ref[0] * ny - ref[1] * nx
      umag = Math.sqrt(ux * ux + uy * uy + uz * uz)
      ux /= umag
      uy /= umag
      uz /= umag

      vx = ny * uz - nz * uy
      vy = nz * ux - nx * uz
      vz = nx * uy - ny * ux

      [[ux, uy, uz], [vx, vy, vz], [nx, ny, nz]]
    end

    # Pure: map a 2D profile onto a plane given origin and (u, v) basis vectors.
    # Each output is an [x, y, z] tuple = origin + a*u + b*v.
    def plane_profile_to_3d(profile, origin, u, v)
      ox = origin[0].to_f
      oy = origin[1].to_f
      oz = origin[2].to_f
      profile.map do |pair|
        a = pair[0].to_f
        b = pair[1].to_f
        [ox + a * u[0] + b * v[0], oy + a * u[1] + b * v[1], oz + a * u[2] + b * v[2]]
      end
    end

    # Pure: 2D AABB of a polygon as [xmin, ymin, xmax, ymax].
    def polygon_aabb_2d(polygon)
      xs = polygon.map { |p| p[0].to_f }
      ys = polygon.map { |p| p[1].to_f }
      [xs.min, ys.min, xs.max, ys.max]
    end

    # Pure: AABB overlap (touching counts).
    def aabbs_overlap_2d?(a, b)
      !(a[2] < b[0] || a[0] > b[2] || a[3] < b[1] || a[1] > b[3])
    end

    # Pure: ray-cast point-in-polygon for 2D points. Returns true if `pt` lies
    # inside `polygon`. Points exactly on the boundary may go either way —
    # don't rely on this for boundary classification.
    def point_in_polygon_2d?(pt, polygon)
      x = pt[0].to_f
      y = pt[1].to_f
      inside = false
      n = polygon.length
      j = n - 1
      (0...n).each do |i|
        xi = polygon[i][0].to_f
        yi = polygon[i][1].to_f
        xj = polygon[j][0].to_f
        yj = polygon[j][1].to_f
        if ((yi > y) != (yj > y)) && (x < (xj - xi) * (y - yi) / (yj - yi) + xi)
          inside = !inside
        end
        j = i
      end
      inside
    end

    # Pure: validate `holes` against an `outer` polygon. Two checks:
    #   1. Every hole vertex lies inside the outer profile.
    #   2. No two holes have overlapping AABBs (catches simple intersect cases).
    # Raises with a clear, 1-indexed identifier on the first failure.
    def validate_holes(outer, holes)
      holes.each_with_index do |hole, i|
        hole.each do |pt|
          unless point_in_polygon_2d?(pt, outer)
            raise "hole ##{i + 1} has vertex #{pt.inspect} outside the outer profile"
          end
        end
      end
      hole_aabbs = holes.map { |h| polygon_aabb_2d(h) }
      (0...holes.length).each do |i|
        ((i + 1)...holes.length).each do |j|
          if aabbs_overlap_2d?(hole_aabbs[i], hole_aabbs[j])
            raise "holes ##{i + 1} and ##{j + 1} overlap"
          end
        end
      end
    end

    # Reuse the existing set_material path so name/hex resolution and color
    # defaults stay in one place. set_material accepts the same `id` format
    # the dispatcher already strips.
    def apply_material(group, material_name)
      set_material({ "id" => group.entityID, "material" => material_name })
    end

    KNOWN_BATCH_OPS = %w[cube cylinder sphere cone extrusion translate move_to delete replace pattern_linear mirror].freeze

    # Run many create / mutate / delete ops as a single SketchUp transaction.
    # The whole batch is one undo step. Any exception during dispatch aborts
    # the transaction (model.abort_operation) and re-raises with the failing
    # op's index, so the caller sees the model unchanged.
    def batch_create(params)
      operations = params["operations"]
      raise "'operations' must be an array" unless operations.is_a?(Array)
      operations.each_with_index { |op, i| validate_batch_op(op, i) }

      transaction_name = (params["transaction_name"] || "MCP batch").to_s
      model = Sketchup.active_model
      results = []
      failed_index = nil
      failed_op = nil

      model.start_operation(transaction_name, true)
      begin
        operations.each_with_index do |op, i|
          failed_index = i
          failed_op = op
          results << execute_batch_op(op)
        end
        failed_index = nil
        model.commit_operation
      rescue StandardError => e
        model.abort_operation
        completed = results.length
        raise "batch_create operation ##{failed_index} (#{failed_op["op"].inspect}) failed: #{e.message}. Aborted; #{completed} prior op(s) rolled back."
      end

      { success: true, count: results.length, results: results }
    end

    def validate_batch_op(op, index)
      raise "operation ##{index} must be a Hash, got #{op.class}" unless op.is_a?(Hash)
      op_name = op["op"].to_s
      unless KNOWN_BATCH_OPS.include?(op_name)
        raise "operation ##{index} has unknown op #{op["op"].inspect} (expected one of: #{KNOWN_BATCH_OPS.join(', ')})"
      end
    end

    def execute_batch_op(op)
      case op["op"].to_s
      when "cube", "cylinder", "sphere", "cone"
        create_named_primitive(op)
      when "extrusion"
        extrusion_params = { "name" => op["name"], "profile" => op["profile"] }
        # Only forward keys the caller actually set so create_extrusion's
        # axis-vs-plane mutual-exclusion check sees the right shape.
        %w[extrude_axis extrude_from extrude_to holes plane extrude_depth material].each do |k|
          extrusion_params[k] = op[k] unless op[k].nil?
        end
        create_extrusion(extrusion_params)
      when "translate"
        # Prefer "position" (matches transform_component's vocabulary); accept
        # "delta" as a backwards-compat alias. Both missing → raise instead of
        # silently no-op'ing (sch-gc5).
        delta = op["position"] || op["delta"]
        raise "translate op requires 'position' [dx,dy,dz]" if delta.nil?
        transform_component(addressing_params(op).merge("position" => delta))
      when "move_to"
        transform_component(addressing_params(op).merge("move_to" => op["target"]))
      when "delete"
        entity = resolve_entity(addressing_params(op))
        id = entity.entityID
        entity.erase!
        { id: id, success: true }
      when "replace"
        replace_params = addressing_params(op).merge("geometry" => op["geometry"])
        replace_params["recursive"] = op["recursive"] if op.key?("recursive")
        replace_geometry(replace_params)
      when "pattern_linear"
        # Same atomicity model as translate/delete: address by name and the
        # source created earlier in this same batch resolves fine because
        # named entities are visible mid-transaction. Pattern's own
        # start_operation nests inside batch_create's outer transaction.
        params = addressing_params(op).merge(
          "vector" => op["vector"],
          "count" => op["count"]
        )
        params["include_source"] = op["include_source"] if op.key?("include_source")
        params["name_template"] = op["name_template"] if op.key?("name_template")
        pattern_linear(params)
      when "mirror"
        params = addressing_params(op)
        params["axis"] = op["axis"] if op.key?("axis")
        params["offset"] = op["offset"] if op.key?("offset")
        params["plane"] = op["plane"] if op.key?("plane")
        params["name_template"] = op["name_template"] if op.key?("name_template")
        params["include_source"] = op["include_source"] if op.key?("include_source")
        mirror_component(params)
      else
        # validate_batch_op already screened this; defensive only.
        raise "Unknown batch op: #{op["op"].inspect}"
      end
    end

    # Build a transform_component / delete_component params hash from a raw
    # `id_or_name` value. Integer → id; String → name. Strict: a numeric
    # string is still treated as a name, so the integer-vs-string distinction
    # is what selects the lookup mode (per the bead's contract).
    def id_or_name_params(raw)
      case raw
      when Integer then { "id" => raw }
      when String then { "name" => raw }
      else
        raise "id_or_name must be an Integer (entityID) or String (group name), got #{raw.class}"
      end
    end

    # Addressing helper for batch_create sub-ops (translate/move_to/delete/
    # replace). Accepts the same "id" or "name" fields used everywhere else
    # in the API; falls back to the legacy unified "id_or_name" field for
    # backwards compatibility (sch-i7a). Raises if none are provided so a
    # missing addressing key surfaces as an explicit error.
    def addressing_params(op)
      if op.key?("id") && !op["id"].nil?
        { "id" => op["id"] }
      elsif op.key?("name") && !op["name"].nil?
        { "name" => op["name"] }
      elsif op.key?("id_or_name") && !op["id_or_name"].nil?
        id_or_name_params(op["id_or_name"])
      else
        raise "operation requires 'id' (entityID) or 'name' (group name)"
      end
    end

    # Compute the dimensions array that create_component's per-shape code
    # expects, from the more natural radius/height batch-op parameterization.
    #
    # Accepts either shape: an explicit "dimensions" array (create_component
    # vocabulary, used by replace_geometry) or "radius"/"height" pair
    # (batch_create vocabulary). Without the dimensions fallback for
    # cylinder/sphere/cone, replace_geometry callers passing dimensions get
    # [0,0,0] from `nil.to_f` and the constructor emits 24 colocated points,
    # raising "Duplicate points in array" (sch-0q8).
    def primitive_dimensions(op)
      case op["op"].to_s
      when "cube"
        op["dimensions"]
      when "cylinder", "cone"
        return op["dimensions"] if op["dimensions"]
        r = op["radius"].to_f
        [r * 2, r * 2, op["height"].to_f]
      when "sphere"
        return op["dimensions"] if op["dimensions"]
        r = op["radius"].to_f
        [r * 2, r * 2, r * 2]
      end
    end

    def create_named_primitive(op)
      result = create_component({
        "type" => op["op"].to_s,
        "position" => op["position"],
        "dimensions" => primitive_dimensions(op)
      })
      # create_component returns the new group's entityID; look it up so we
      # can name it and apply material before reporting bounds.
      group = Sketchup.active_model.find_entity_by_id(result[:id])
      group.name = op["name"].to_s if op["name"]
      apply_material(group, op["material"]) if op["material"]
      out = bounds_result(group)
      out[:name] = group.name
      out
    end

    # Resolve an entity from `params` by either `id` (entity ID) or `name`
    # (exact match against a top-level Group's name). Exactly one must be
    # provided. Name resolution is strict: zero or multiple matches raise.
    # Shared by delete_component, transform_component, and (later) batch_create.
    def resolve_entity(params, model = Sketchup.active_model)
      has_id = params.key?("id") && !params["id"].nil? && params["id"].to_s != ""
      has_name = params.key?("name") && !params["name"].nil? && params["name"].to_s != ""

      raise "Provide exactly one of 'id' or 'name', not both" if has_id && has_name
      raise "Provide exactly one of 'id' or 'name'" unless has_id || has_name

      if has_id
        id_str = params["id"].to_s.gsub('"', '')
        log "Resolving entity by ID: #{id_str}"
        entity = model.find_entity_by_id(id_str.to_i)
        raise "Entity not found: #{id_str}" unless entity
        entity
      else
        name = params["name"].to_s
        log "Resolving entity by name: #{name.inspect}"
        matches = model.entities.grep(Sketchup::Group).select { |g| g.name == name }
        raise "No group found with name #{name.inspect}" if matches.empty?
        if matches.length > 1
          ids = matches.map(&:entityID)
          raise "Multiple groups match name #{name.inspect} (IDs: #{ids.inspect})"
        end
        matches.first
      end
    end

    def delete_component(params)
      entity = resolve_entity(params)
      log "Found entity: #{entity.inspect}"
      entity.erase!
      { success: true }
    end

    def transform_component(params)
      entity = resolve_entity(params)
      log "Found entity: #{entity.inspect}"

      # `move_to` places the entity so its bounds.min lands at the given XYZ.
      # This is the obvious "put this here" semantic — distinct from `position`,
      # which is a relative delta and is preserved for backwards compatibility.
      if params["move_to"]
        target = params["move_to"]
        current_min = entity.bounds.min
        delta = Geom::Vector3d.new(
          target[0] - current_min.x,
          target[1] - current_min.y,
          target[2] - current_min.z
        )
        log "Moving bounds.min from #{[current_min.x.to_f, current_min.y.to_f, current_min.z.to_f].inspect} to #{target.inspect}"
        entity.transform!(Geom::Transformation.translation(delta))
      end

      # `position` is a relative translation applied on top of the entity's
      # current transform. Passing [0,0,0] is a no-op. Use `move_to` for
      # absolute placement.
      if params["position"]
        pos = params["position"]
        log "Translating by #{pos.inspect} (relative)"

        translation = Geom::Transformation.translation(Geom::Point3d.new(pos[0], pos[1], pos[2]))
        entity.transform!(translation)
      end

      # Handle rotation (in degrees)
      if params["rotation"]
        rot = params["rotation"]
        log "Rotating by #{rot.inspect} degrees"

        # Convert to radians
        x_rot = rot[0] * Math::PI / 180
        y_rot = rot[1] * Math::PI / 180
        z_rot = rot[2] * Math::PI / 180

        # Apply rotations
        if rot[0] != 0
          rotation = Geom::Transformation.rotation(entity.bounds.center, Geom::Vector3d.new(1, 0, 0), x_rot)
          entity.transform!(rotation)
        end

        if rot[1] != 0
          rotation = Geom::Transformation.rotation(entity.bounds.center, Geom::Vector3d.new(0, 1, 0), y_rot)
          entity.transform!(rotation)
        end

        if rot[2] != 0
          rotation = Geom::Transformation.rotation(entity.bounds.center, Geom::Vector3d.new(0, 0, 1), z_rot)
          entity.transform!(rotation)
        end
      end

      # Handle scale
      if params["scale"]
        scale = params["scale"]
        log "Scaling by #{scale.inspect}"

        # Create a transformation to scale the entity
        center = entity.bounds.center
        scaling = Geom::Transformation.scaling(center, scale[0], scale[1], scale[2])
        entity.transform!(scaling)
      end

      bounds_result(entity)
    end

    # Replicate a top-level group along a vector. Group#copy returns a new
    # group at the source's position; each copy is then translated by k*vector
    # for k in 1..count so the original is undisturbed. The whole batch runs
    # inside a single operation so it's one undo step.
    def pattern_linear(params)
      vector = params["vector"]
      count = params["count"]
      raise "vector must be a 3-element array [dx,dy,dz]" unless vector.is_a?(Array) && vector.length == 3
      raise "count must be a positive integer" unless count.is_a?(Integer) && count >= 1
      raise "vector must be non-zero; got [0,0,0]" if vector.all? { |c| c.respond_to?(:zero?) && c.zero? }

      template = params["name_template"]
      raise "name_template must be a String" unless template.nil? || template.is_a?(String)

      source = resolve_entity(params)
      include_source = params.key?("include_source") ? params["include_source"] : true

      base, start_n = pattern_linear_naming_seed(source.name.to_s)
      taken = pattern_linear_taken_names(Sketchup.active_model)

      model = Sketchup.active_model
      model.start_operation("pattern_linear", true)
      begin
        copies = []
        next_n = start_n
        (1..count).each do |i|
          copy = source.copy
          delta = Geom::Vector3d.new(vector[0] * i, vector[1] * i, vector[2] * i)
          copy.transform!(Geom::Transformation.translation(delta))
          unless source.name.to_s.empty?
            new_name, next_n = pattern_linear_copy_name(
              template: template,
              src: source.name.to_s,
              base: base,
              i: i,
              start_n: next_n,
              taken: taken
            )
            copy.name = new_name
            taken << new_name
          end
          copies << copy
        end
        source.erase! unless include_source
        model.commit_operation
        {
          success: true,
          ids: copies.map(&:entityID),
          count: copies.length
        }
      rescue StandardError
        model.abort_operation
        raise
      end
    end

    # Pure: derive base name and starting integer for auto-suffix naming.
    # If `name` ends in an integer (with optional whitespace separator), strip
    # it and continue the sequence at int+1. Otherwise the base is the full
    # name and the sequence starts at 2 — that way the source (unsuffixed)
    # plus copies "<name> 2", "<name> 3", … reads naturally.
    def pattern_linear_naming_seed(name)
      if (m = name.match(/\A(.*?)\s*(\d+)\z/)) && !m[1].empty?
        [m[1], m[2].to_i + 1]
      elsif (m = name.match(/\A(\d+)\z/))
        ["", m[1].to_i + 1]
      else
        [name, 2]
      end
    end

    # Snapshot of top-level Group names currently in the model. Used to skip
    # collisions when auto-numbering. Pure given `model`; never mutated except
    # by appending names as copies are created.
    def pattern_linear_taken_names(model)
      return [] if model.nil?
      model.entities.grep(Sketchup::Group).map { |g| g.name.to_s }
    end

    # Reflect a top-level Group across a plane. Mirror is the natural
    # counterpart to pattern_linear: where pattern handles translational
    # repetition, mirror handles bilateral symmetry. Same addressing rules
    # (id or name, exactly one).
    #
    # Plane specification — exactly one of:
    #   axis + offset (axis-aligned shorthand):
    #     axis: "x"|"y"|"z" — the world axis the plane is perpendicular to.
    #     offset: numeric coordinate on that axis (e.g. axis="x", offset=60.5
    #     mirrors across the plane x=60.5).
    #   plane: { "origin" => [x,y,z], "normal" => [x,y,z] } for arbitrary planes.
    #
    # include_source defaults true (the source is preserved and a new mirrored
    # copy is created). Pass false to mirror the source in place — useful for
    # flipping a single piece rather than producing a symmetric pair.
    #
    # Naming: same auto-suffix and name_template contract as pattern_linear.
    # No separate "name" override — "name" is reserved for source addressing
    # (same convention as transform_component / delete_component / pattern_linear)
    # to avoid the dual-role collision where the same key would mean both
    # "find this group" and "rename the copy to this". For a fixed new name,
    # pass name_template with no placeholders (e.g. "Rafter E 1").
    def mirror_component(params)
      raise "name_template must be a String" if params.key?("name_template") && !params["name_template"].nil? && !params["name_template"].is_a?(String)

      origin, normal = resolve_mirror_plane(params)
      source = resolve_entity(params)
      include_source = params.key?("include_source") ? params["include_source"] : true

      matrix = build_mirror_matrix(origin, normal)
      reflection = Geom::Transformation.new(matrix)

      base, start_n = pattern_linear_naming_seed(source.name.to_s)
      taken = pattern_linear_taken_names(Sketchup.active_model)

      model = Sketchup.active_model
      model.start_operation("mirror_component", true)
      begin
        target = include_source ? source.copy : source
        target.transform!(reflection)
        # In-place mirrors (include_source=false) keep the source's name; only
        # named copies get a fresh sequence number, matching pattern_linear's
        # behavior.
        if include_source && !source.name.to_s.empty?
          new_name, = pattern_linear_copy_name(
            template: params["name_template"],
            src: source.name.to_s,
            base: base,
            i: 1,
            start_n: start_n,
            taken: taken
          )
          target.name = new_name
        end
        model.commit_operation
        out = bounds_result(target)
        out[:name] = target.name
        out
      rescue StandardError
        model.abort_operation
        raise
      end
    end

    # Pure: resolve the mirror plane params into [[ox, oy, oz], [nx, ny, nz]],
    # where the normal is unit-length. Raises if both forms are given, neither
    # is given, the axis is unknown, or the normal is zero. The axis-aligned
    # shorthand ({axis, offset}) is the dominant case; {plane: {origin,
    # normal}} is the escape hatch for arbitrary planes.
    def resolve_mirror_plane(params)
      has_axis = params.key?("axis") && !params["axis"].nil?
      has_plane = params.key?("plane") && !params["plane"].nil?

      raise "Provide exactly one of 'axis'+'offset' or 'plane', not both" if has_axis && has_plane
      raise "Provide a mirror plane: 'axis'+'offset' or 'plane' {origin, normal}" unless has_axis || has_plane

      if has_axis
        axis = params["axis"].to_s
        unless params.key?("offset") && !params["offset"].nil?
          raise "'offset' (numeric) is required with 'axis'"
        end
        offset = params["offset"]
        raise "'offset' must be numeric" unless offset.is_a?(Numeric)
        case axis
        when "x" then [[offset.to_f, 0.0, 0.0], [1.0, 0.0, 0.0]]
        when "y" then [[0.0, offset.to_f, 0.0], [0.0, 1.0, 0.0]]
        when "z" then [[0.0, 0.0, offset.to_f], [0.0, 0.0, 1.0]]
        else
          raise "axis must be \"x\", \"y\", or \"z\"; got #{axis.inspect}"
        end
      else
        plane = params["plane"]
        raise "plane must be a Hash with 'origin' and 'normal'" unless plane.is_a?(Hash)
        origin = plane["origin"]
        normal = plane["normal"]
        unless origin.is_a?(Array) && origin.length == 3 && origin.all? { |c| c.is_a?(Numeric) }
          raise "plane.origin must be [x,y,z] numerics"
        end
        unless normal.is_a?(Array) && normal.length == 3 && normal.all? { |c| c.is_a?(Numeric) }
          raise "plane.normal must be [x,y,z] numerics"
        end
        nx, ny, nz = normal.map(&:to_f)
        mag = Math.sqrt(nx * nx + ny * ny + nz * nz)
        raise "plane.normal must be non-zero" if mag.zero?
        [[origin[0].to_f, origin[1].to_f, origin[2].to_f], [nx / mag, ny / mag, nz / mag]]
      end
    end

    # Pure: build a 16-element column-major reflection matrix for a plane
    # through `origin` with unit `normal`. Reflection of point p:
    #   p' = (I - 2 n n^T) p + 2 (O·n) n
    # The 3×3 part is symmetric; column j is e_j - 2 n_j n. Translation is
    # 2 (O·n) n. Output layout matches Geom::Transformation.new's expected
    # column-major order: cols 1-3 carry basis-vector images, col 4 carries
    # the translation with a trailing 1.
    def build_mirror_matrix(origin, normal)
      ox, oy, oz = origin
      nx, ny, nz = normal
      d = 2.0 * (ox * nx + oy * ny + oz * nz)
      [
        1.0 - 2.0 * nx * nx, -2.0 * nx * ny,       -2.0 * nx * nz,       0.0,
        -2.0 * nx * ny,       1.0 - 2.0 * ny * ny, -2.0 * ny * nz,       0.0,
        -2.0 * nx * nz,      -2.0 * ny * nz,        1.0 - 2.0 * nz * nz, 0.0,
        d * nx,               d * ny,               d * nz,              1.0
      ]
    end

    # Pure: compute the name for the next copy. With a template, substitute
    # placeholders and advance the sequence by 1. Without a template, find
    # the next integer that doesn't collide with `taken` and use "<base> <n>"
    # (or just "<n>" when base is empty). Returns [name, next_n_to_try].
    def pattern_linear_copy_name(template:, src:, base:, i:, start_n:, taken:)
      if template
        n = start_n
        name = template.gsub("{src}", src).gsub("{base}", base).gsub("{n}", n.to_s).gsub("{i}", i.to_s)
        [name, n + 1]
      else
        n = start_n
        loop do
          candidate = base.empty? ? n.to_s : "#{base} #{n}"
          unless taken.include?(candidate)
            return [candidate, n + 1]
          end
          n += 1
        end
      end
    end

    def find_groups(params)
      log "find_groups params: #{params.inspect}"

      has_prefix = params.key?("name_prefix") && !params["name_prefix"].nil?
      has_pattern = params.key?("name_pattern") && !params["name_pattern"].nil?
      raise "Provide at most one of 'name_prefix' or 'name_pattern'" if has_prefix && has_pattern

      prefix = has_prefix ? params["name_prefix"].to_s : nil
      pattern = has_pattern ? Regexp.new(params["name_pattern"].to_s) : nil
      in_bounds = params["in_bounds"]
      limit = (params["limit"] || 200).to_i
      include_components = params["include_components"] ? true : false
      recursive = params["recursive"] ? true : false

      model = Sketchup.active_model
      entities = resolve_search_root(model, params["parent_id"])

      matched = []
      truncated = false
      # NOTE: Sketchup::Entities#each requires a block — calling it without
      # one raises 'no block given' rather than returning an Enumerator like
      # Array does. Use .to_a to get an Enumerable that works either way.
      walker = recursive ? walk_entities_recursive(entities) : entities.to_a
      walker.each do |entity|
        next unless entity_matches_kind?(entity, include_components)
        next unless name_matches?(entity.name, prefix, pattern)
        next unless bounds_matches?(entity.bounds, in_bounds)

        if matched.length >= limit
          truncated = true
          break
        end
        matched << describe_match(entity)
      end

      { success: true, groups: matched, truncated: truncated }
    end

    # Yields every entity reachable from `entities`, descending into nested
    # Groups (and ComponentInstance definitions). Order is depth-first so
    # parents are visited before children — matters only for limit truncation.
    def walk_entities_recursive(entities)
      Enumerator.new do |y|
        stack = entities.to_a.reverse
        until stack.empty?
          e = stack.pop
          y << e
          if e.is_a?(Sketchup::Group)
            e.entities.to_a.reverse.each { |child| stack.push(child) }
          elsif e.is_a?(Sketchup::ComponentInstance) && e.respond_to?(:definition)
            e.definition.entities.to_a.reverse.each { |child| stack.push(child) }
          end
        end
      end
    end

    def resolve_search_root(model, parent_id)
      return model.entities if parent_id.nil?

      parent = model.find_entity_by_id(parent_id.to_i)
      raise "Entity not found: #{parent_id}" unless parent
      unless parent.is_a?(Sketchup::Group)
        raise "parent_id #{parent_id} is not a Group (got #{parent.class})"
      end
      parent.entities
    end

    # Pure: does `entity` count as a hit given the kind filter? Groups
    # always do; ComponentInstances only when explicitly opted in.
    def entity_matches_kind?(entity, include_components)
      return true if entity.is_a?(Sketchup::Group)
      return true if include_components && entity.is_a?(Sketchup::ComponentInstance)
      false
    end

    # Pure: name passes if either no filter, prefix matches, or regex matches.
    # prefix and pattern are mutually exclusive at the caller — passing both
    # would be a caller bug, not handled here.
    def name_matches?(name, prefix, pattern)
      return name.to_s.start_with?(prefix) if prefix
      return pattern.match?(name.to_s) if pattern
      true
    end

    # Pure AABB intersection: two boxes intersect iff they overlap on every
    # axis. `in_bounds` is the query box ({"min": [x,y,z], "max": [x,y,z]});
    # `entity_bounds` exposes .min and .max as objects with .x/.y/.z.
    # Touch-only contact (max == min on an axis) counts as intersecting —
    # consistent with SketchUp's own BoundingBox#intersect.
    def bounds_matches?(entity_bounds, in_bounds)
      return true if in_bounds.nil?

      qmin = in_bounds["min"]
      qmax = in_bounds["max"]
      emin = entity_bounds.min
      emax = entity_bounds.max
      return false if emax.x < qmin[0] || emin.x > qmax[0]
      return false if emax.y < qmin[1] || emin.y > qmax[1]
      return false if emax.z < qmin[2] || emin.z > qmax[2]
      true
    end

    # Default contact / alignment / overlap tolerance, matched to the
    # spec — 1/16" is the smallest dimension a framer reliably eyeballs.
    DEFAULT_VALIDATE_TOLERANCE = 0.0625

    def validate_geometry(params)
      log "validate_geometry params: #{params.inspect}"
      assertions = params["assertions"] || []
      raise "'assertions' must be an array" unless assertions.is_a?(Array)

      model = Sketchup.active_model
      results = []
      failed = 0

      assertions.each_with_index do |a, i|
        kind = a["kind"].to_s
        label = (a["name"] && !a["name"].to_s.empty?) ? a["name"].to_s : "##{i} #{kind}"
        outcome =
          begin
            case kind
            when "bounds"     then run_bounds_assertion(a, model)
            when "contact"    then run_contact_assertion(a, model)
            when "aligned"    then run_aligned_assertion(a, model)
            when "no_overlap" then run_no_overlap_assertion(a, model)
            else { passed: false, detail: "unknown kind: #{kind.inspect}" }
            end
          rescue StandardError => e
            { passed: false, detail: e.message }
          end
        failed += 1 unless outcome[:passed]
        results << { name: label, kind: kind, passed: outcome[:passed], detail: outcome[:detail] }
      end

      { success: true, results: results, failed: failed }
    end

    # Resolve a single target by exact group name (string) or entity ID
    # (integer). Mirrors resolve_entity's strict semantics — zero or multiple
    # matches raise. Used only by validate_geometry; resolve_entity is the
    # right helper anywhere that takes id|name params.
    def resolve_validate_target(target, model)
      raise "target is required" if target.nil?
      if target.is_a?(Integer)
        e = model.find_entity_by_id(target)
        raise "Entity not found: id=#{target}" unless e
        return e
      end
      if target.is_a?(String)
        matches = model.entities.grep(Sketchup::Group).select { |g| g.name == target }
        raise "No group found with name #{target.inspect}" if matches.empty?
        if matches.length > 1
          ids = matches.map(&:entityID)
          raise "Multiple groups match name #{target.inspect} (IDs: #{ids.inspect})"
        end
        return matches.first
      end
      raise "target must be a string (name) or integer (id), got #{target.class}"
    end

    def run_bounds_assertion(a, model)
      tol = (a["tolerance"] || DEFAULT_VALIDATE_TOLERANCE).to_f
      entity = resolve_validate_target(a["target"], model)
      errors = []
      errors.concat(bounds_axis_errors(entity.bounds.min, a["min"], "min", tol)) if a["min"]
      errors.concat(bounds_axis_errors(entity.bounds.max, a["max"], "max", tol)) if a["max"]
      if errors.empty?
        { passed: true, detail: "bounds within #{format_tol(tol)}" }
      else
        { passed: false, detail: errors.join("; ") }
      end
    end

    # Pure: per-axis check of an observed Geom::Point3d-like point against
    # an expected [x,y,z]. Returns an array of error strings, empty on pass.
    # `label` is "min" or "max" for use in the error message.
    def bounds_axis_errors(observed_point, expected_xyz, label, tolerance)
      raise "expected_xyz must be [x,y,z]" unless expected_xyz.is_a?(Array) && expected_xyz.length == 3
      errors = []
      [:x, :y, :z].each_with_index do |axis, i|
        obs = observed_point.send(axis).to_f
        exp = expected_xyz[i].to_f
        delta = (obs - exp).abs
        if delta > tolerance
          errors << "#{label}.#{axis}: expected #{format_num(exp)}, got #{format_num(obs)} (Δ #{format_num(delta)})"
        end
      end
      errors
    end

    def run_contact_assertion(a, model)
      tol = (a["tolerance"] || DEFAULT_VALIDATE_TOLERANCE).to_f
      axis = a["axis"].to_s
      direction = a["direction"].to_s
      raise "axis must be x|y|z, got #{axis.inspect}" unless %w[x y z].include?(axis)
      raise "direction must be + or -, got #{direction.inspect}" unless %w[+ -].include?(direction)
      ent_a = resolve_validate_target(a["a"], model)
      ent_b = resolve_validate_target(a["b"], model)
      gap = contact_face_gap(ent_a.bounds.min, ent_a.bounds.max, ent_b.bounds.min, ent_b.bounds.max, axis, direction)
      if gap <= tol
        { passed: true, detail: "contact on #{direction}#{axis} within #{format_tol(tol)} (gap #{format_num(gap)})" }
      else
        { passed: false, detail: "contact gap on #{direction}#{axis}: #{format_num(gap)} (tolerance #{format_tol(tol)})" }
      end
    end

    # Pure: signed gap between group a's face and group b's opposing face.
    # axis+direction selects which face of `a` is being checked; the opposing
    # face of `b` is the one that would meet it (a.max.z touches b.min.z when
    # direction="+", axis="z"). Returns the absolute distance — touching = 0.
    def contact_face_gap(a_min, a_max, b_min, b_max, axis, direction)
      sym = axis.to_sym
      a_face = direction == "+" ? a_max.send(sym).to_f : a_min.send(sym).to_f
      b_face = direction == "+" ? b_min.send(sym).to_f : b_max.send(sym).to_f
      (a_face - b_face).abs
    end

    def run_aligned_assertion(a, model)
      tol = (a["tolerance"] || DEFAULT_VALIDATE_TOLERANCE).to_f
      axis = a["axis"].to_s
      side = a["side"].to_s
      raise "axis must be x|y|z, got #{axis.inspect}" unless %w[x y z].include?(axis)
      raise "side must be min|max|center, got #{side.inspect}" unless %w[min max center].include?(side)
      targets = a["targets"]
      raise "targets must be a non-empty array" unless targets.is_a?(Array) && !targets.empty?
      coords = targets.map do |t|
        e = resolve_validate_target(t, model)
        point = case side
                when "min"    then e.bounds.min
                when "max"    then e.bounds.max
                when "center" then e.bounds.center
                end
        point.send(axis.to_sym).to_f
      end
      spread, mean = alignment_stats(coords)
      if spread > tol
        return { passed: false,
                 detail: "#{side}.#{axis} spread #{format_num(spread)} > tolerance #{format_tol(tol)} " \
                         "(range [#{format_num(coords.min)}, #{format_num(coords.max)}])" }
      end
      if a.key?("value") && !a["value"].nil?
        expected = a["value"].to_f
        delta = (mean - expected).abs
        if delta > tol
          return { passed: false,
                   detail: "#{side}.#{axis} = #{format_num(mean)} ≠ expected #{format_num(expected)} " \
                           "(Δ #{format_num(delta)}, tolerance #{format_tol(tol)})" }
        end
      end
      { passed: true, detail: "#{side}.#{axis} aligned within #{format_tol(tol)}" }
    end

    # Pure: spread (max - min) and mean of the given coords. Returns
    # [0.0, 0.0] for an empty list so callers don't crash; in practice the
    # caller guards against empties.
    def alignment_stats(coords)
      return [0.0, 0.0] if coords.empty?
      cmin = coords.min
      cmax = coords.max
      mean = coords.inject(0.0) { |s, c| s + c } / coords.length
      [cmax - cmin, mean]
    end

    def run_no_overlap_assertion(a, model)
      tol = (a["tolerance"] || DEFAULT_VALIDATE_TOLERANCE).to_f
      targets = a["targets"]
      raise "targets must be a non-empty array" unless targets.is_a?(Array) && !targets.empty?
      entities = targets.map { |t| resolve_validate_target(t, model) }
      offenders = []
      entities.each_with_index do |e1, i|
        b1 = e1.bounds
        (i + 1...entities.length).each do |j|
          e2 = entities[j]
          b2 = e2.bounds
          ox, oy, oz = aabb_overlap_extents(b1.min, b1.max, b2.min, b2.max)
          # Penetration must exceed tolerance on every axis for it to count
          # as a real overlap; allowing one axis ≤ tol catches near-touches
          # (sub-1/16" interpenetration at tight joints) and ignores them.
          if ox > tol && oy > tol && oz > tol
            offenders << "#{describe_for_overlap(e1)} ∩ #{describe_for_overlap(e2)} = " \
                         "#{format_num(ox)}×#{format_num(oy)}×#{format_num(oz)}"
          end
        end
      end
      if offenders.empty?
        { passed: true, detail: "no overlaps among #{entities.length} group(s) (tolerance #{format_tol(tol)})" }
      else
        head = offenders.first(3).join("; ")
        more = offenders.length > 3 ? "; (#{offenders.length - 3} more)" : ""
        { passed: false, detail: head + more }
      end
    end

    # Pure: per-axis penetration depth between two AABBs. A negative or
    # zero value on any axis means the boxes are clear (or just touching) on
    # that axis. All three positive => the interiors overlap.
    def aabb_overlap_extents(a_min, a_max, b_min, b_max)
      [
        [a_max.x.to_f, b_max.x.to_f].min - [a_min.x.to_f, b_min.x.to_f].max,
        [a_max.y.to_f, b_max.y.to_f].min - [a_min.y.to_f, b_min.y.to_f].max,
        [a_max.z.to_f, b_max.z.to_f].min - [a_min.z.to_f, b_min.z.to_f].max,
      ]
    end

    def describe_for_overlap(entity)
      name = entity.respond_to?(:name) ? entity.name.to_s : ""
      name.empty? ? "id=#{entity.entityID}" : name
    end

    # Trim trailing zeros from numeric details so passes read tersely
    # ('within 0.0625"' not '0.0625000000...') and failures don't bury the
    # actual delta in noise.
    def format_num(n)
      "%g" % n.to_f
    end

    def format_tol(t)
      "#{format_num(t)}\""
    end

    # Tiny step past a previous hit so the next raytest doesn't re-hit the
    # same face. 1e-4" is ~2.5 microns — far below any modeling tolerance.
    INTERSECT_RAY_EPS = 1.0e-4

    # Soft cap on hit-skipping iterations when a target is supplied. The loop
    # advances past each face it doesn't want; this bounds runaway in case a
    # caller targets something the ray will never reach.
    INTERSECT_RAY_MAX_STEPS = 256

    def intersect_ray(params)
      log "intersect_ray params: #{params.inspect}"
      origin = params["origin"]
      direction = params["direction"]
      raise "'origin' must be [x,y,z]" unless origin.is_a?(Array) && origin.length == 3
      raise "'direction' must be [x,y,z]" unless direction.is_a?(Array) && direction.length == 3

      origin_xyz = [origin[0].to_f, origin[1].to_f, origin[2].to_f]
      dir_xyz = [direction[0].to_f, direction[1].to_f, direction[2].to_f]
      mag = Math.sqrt(dir_xyz[0]**2 + dir_xyz[1]**2 + dir_xyz[2]**2)
      # Tolerance check, not exact-zero — a tiny but non-zero direction would
      # normalize to a garbage unit vector.
      raise "'direction' must be non-zero" if mag < 1.0e-10
      unit_dir = dir_xyz.map { |c| c / mag }

      target = params["target"]
      max_distance = params["max_distance"] ? params["max_distance"].to_f : nil
      include_back = params.key?("include_back_faces") ? !!params["include_back_faces"] : false

      model = Sketchup.active_model
      raise "no active model" unless model

      raycaster = lambda do |origin_arr|
        pt = Geom::Point3d.new(origin_arr[0], origin_arr[1], origin_arr[2])
        dvec = Geom::Vector3d.new(unit_dir[0], unit_dir[1], unit_dir[2])
        result = model.raytest([pt, dvec], true)
        next nil if result.nil?
        hit_pt, path = result
        face = path.reverse.find { |e| e.is_a?(Sketchup::Face) }
        # Normal computation is lazy: when the loop discards a hit (wrong
        # target, back face, distance over cap), the cumulative-transform
        # math never runs. A step-cap-exhaustion path now does 0 normal
        # computations instead of 256.
        normal_fn = face ? lambda { n = world_normal_for_face(face, path); [n.x.to_f, n.y.to_f, n.z.to_f] } : nil
        [[hit_pt.x.to_f, hit_pt.y.to_f, hit_pt.z.to_f], path, face, normal_fn]
      end

      intersect_ray_loop(origin_xyz, unit_dir, target, max_distance, include_back, raycaster)
    end

    # Pure-but-for-raycaster: drive the skip-and-retry loop with a callable
    # that returns synthetic hits as [hit_point_xyz, path, face, normal_fn]
    # tuples (or nil for a miss). `normal_fn` is a no-arg callable returning
    # the face's world-space normal as [x,y,z]; it's only invoked when the
    # loop reaches a back-face check or accepts the hit. Extracted from
    # intersect_ray so tests can exercise target filtering, back-face
    # culling, max_distance cutoff, and step-cap exhaustion without
    # SketchUp.
    def intersect_ray_loop(origin_xyz, unit_dir, target, max_distance, include_back, raycaster)
      current = origin_xyz
      INTERSECT_RAY_MAX_STEPS.times do
        hit = raycaster.call(current)
        return intersect_ray_miss(:miss) if hit.nil?

        hit_pt, path, face, normal_fn = hit
        distance = euclid_distance(origin_xyz, hit_pt)
        return intersect_ray_miss(:max_distance_exceeded) if max_distance && distance > max_distance

        group_match = if target
                        find_target_group_in_path(path, target)
                      else
                        find_innermost_group_or_instance(path)
                      end

        if target && group_match.nil?
          current = advance_xyz_along(hit_pt, unit_dir)
          next
        end

        # Lazy normal: compute at most once per accepted hit, never for
        # target-skipped ones. Reused for the back-face check and the
        # face_normal field on the response.
        normal_world = nil
        if face && normal_fn && !include_back
          normal_world = normal_fn.call
          if normal_world && vec3_dot(unit_dir, normal_world) > 0
            current = advance_xyz_along(hit_pt, unit_dir)
            next
          end
        end
        normal_world = normal_fn.call if face && normal_fn && normal_world.nil?

        return {
          success: true,
          hit: true,
          point: hit_pt,
          distance: distance,
          face_id: face ? face.entityID : nil,
          group_name: group_match.respond_to?(:name) ? group_match.name : nil,
          group_id: group_match ? group_match.entityID : nil,
          face_normal: normal_world
        }
      end

      intersect_ray_miss(:step_cap_exceeded)
    end

    # Pure: build the miss-response envelope. A clean ray-exits-geometry miss
    # leaves `reason` absent so the common case stays terse; the
    # max_distance / step_cap cases carry a reason so a caller debugging an
    # unexpected miss can tell what fired.
    def intersect_ray_miss(reason)
      out = { success: true, hit: false }
      out[:reason] = reason.to_s unless reason == :miss
      out
    end

    # Pure-ish: walk a raytest path looking for a Group / ComponentInstance
    # whose name (string target) or entityID (integer target) matches. Returns
    # the matching node, or nil. Targets nest, so the *innermost* match wins —
    # if the caller asked for "Wall A" and the ray hits a face inside a
    # nested group inside Wall A, that's still a Wall A hit.
    def find_target_group_in_path(path, target)
      path.reverse.find do |e|
        next false unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
        if target.is_a?(Integer) || (target.is_a?(String) && target =~ /\A-?\d+\z/)
          e.entityID == target.to_i
        else
          e.respond_to?(:name) && e.name == target.to_s
        end
      end
    end

    # Pure: walk a raytest path looking for the innermost Group or
    # ComponentInstance — the natural answer to "what was hit?" when the
    # caller didn't pin a specific target.
    def find_innermost_group_or_instance(path)
      path.reverse.find { |e| e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance) }
    end

    # Compose the world transform for a face by accumulating every
    # Group / ComponentInstance transform above it in the raytest path.
    # The face itself doesn't carry a transform — its normal is in its
    # parent's local space, so we transform by the cumulative parent.
    def cumulative_path_transform(path)
      t = Geom::Transformation.new
      path.each do |node|
        break if node.is_a?(Sketchup::Face)
        t = t * node.transformation if node.respond_to?(:transformation)
      end
      t
    end

    # Face normal in world coordinates. NOTE: vec.transform(t) is correct
    # for rigid transforms (translation, rotation, uniform scale, reflection)
    # but not strictly correct under non-uniform scale, where the proper
    # transform for normals is the inverse-transpose. SketchUp Groups
    # typically carry rigid transforms (mirror_component included), so this
    # is fine in practice; revisit if non-uniform scaling enters the picture.
    def world_normal_for_face(face, path)
      t = cumulative_path_transform(path)
      n = face.normal.transform(t)
      n.normalize!
      n
    end

    # Pure: Euclidean distance between two [x,y,z] arrays.
    def euclid_distance(a, b)
      Math.sqrt((a[0] - b[0])**2 + (a[1] - b[1])**2 + (a[2] - b[2])**2)
    end

    # Pure: dot product of two [x,y,z] arrays.
    def vec3_dot(a, b)
      a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
    end

    # Pure: step a small EPS past `point` along the unit direction so the
    # next raytest doesn't re-hit the same face. Direction must be unit length.
    def advance_xyz_along(point, unit_dir)
      [
        point[0] + unit_dir[0] * INTERSECT_RAY_EPS,
        point[1] + unit_dir[1] * INTERSECT_RAY_EPS,
        point[2] + unit_dir[2] * INTERSECT_RAY_EPS
      ]
    end

    def inspect_geometry(params)
      log "inspect_geometry params: #{params.inspect}"
      entity = resolve_entity(params)
      unless entity.is_a?(Sketchup::Group)
        raise "inspect_geometry only supports top-level Group entities (got #{entity.class})"
      end

      include_vertices = params.key?("include_vertices") ? !!params["include_vertices"] : true

      faces = entity.entities.grep(Sketchup::Face)
      edges = entity.entities.grep(Sketchup::Edge)

      face_dicts = faces.map { |f| describe_face(f, include_vertices) }

      {
        success: true,
        id: entity.entityID,
        name: entity.name,
        face_count: faces.length,
        edge_count: edges.length,
        is_solid: edges_form_solid?(edges),
        faces: face_dicts
      }
    end

    KNOWN_REPLACE_GEOMETRY_OPS = %w[cube cylinder sphere cone extrusion].freeze

    def replace_geometry(params)
      log "replace_geometry params: #{params.inspect}"
      target = resolve_entity(params)
      unless target.is_a?(Sketchup::Group)
        raise "replace_geometry only supports top-level Group entities (got #{target.class})"
      end

      geometry = params["geometry"]
      validate_replace_geometry_dict(geometry)

      # `recursive` (default true) means "preserve recursion" — if any
      # nested groups/components exist they'd be lost in a recreate, so we
      # refuse. Pass recursive: false to acknowledge children-loss and proceed.
      recursive = params.key?("recursive") ? !!params["recursive"] : true
      children = child_entities(target)
      if children.any? && recursive
        n = children.length
        raise "target group has #{n} sub-entit#{n == 1 ? 'y' : 'ies'}; pass recursive: false to replace anyway (children will be lost)"
      end

      captured_name = target.name
      captured_material = target.material
      captured_layer = target.respond_to?(:layer) ? target.layer : nil

      # Wrap erase + rebuild in a single SU operation so a mid-flight failure
      # (e.g. a degenerate primitive that raises during construction) rolls
      # back the target.erase! and leaves the original Group in the model.
      # Without this, callers that hit a construction bug lose the source
      # geometry permanently (sch-9d9).
      model = Sketchup.active_model
      model.start_operation("Replace geometry", true)
      begin
        target.erase!

        new_group = build_replacement_group(geometry, captured_name)

        # Re-apply captured attrs. Material set via assignment works on Groups;
        # apply_material would re-pick a color, which we don't want — preserve
        # exactly what was there.
        new_group.material = captured_material if captured_material
        if captured_layer && captured_layer.respond_to?(:valid?) && captured_layer.valid?
          new_group.layer = captured_layer
        end
        new_group.name = captured_name if new_group.name != captured_name

        out = bounds_result(new_group)
        out[:name] = new_group.name
        model.commit_operation
        out
      rescue StandardError
        model.abort_operation
        raise
      end
    end

    # Pure: validate the geometry dict accepted by replace_geometry and the
    # "replace" batch op. Centralizes both shape and op-name checks so the
    # error message points at the actual problem.
    #
    # Accepts either "op" (batch_create vocabulary) or "type" (standalone
    # create_component vocabulary) as the shape selector; if both are
    # supplied they must agree. Returns the resolved op string.
    def validate_replace_geometry_dict(geometry)
      raise "'geometry' is required" if geometry.nil?
      raise "'geometry' must be a Hash" unless geometry.is_a?(Hash)
      op_val = geometry["op"]
      type_val = geometry["type"]
      if op_val && type_val && op_val.to_s != type_val.to_s
        raise "geometry has both 'op' (#{op_val.inspect}) and 'type' (#{type_val.inspect}); supply one"
      end
      op = (op_val || type_val).to_s
      unless KNOWN_REPLACE_GEOMETRY_OPS.include?(op)
        raise "geometry shape must be one of: #{KNOWN_REPLACE_GEOMETRY_OPS.join(', ')} (got #{(op_val || type_val).inspect})"
      end
      op
    end

    # Adapter: nested Groups + ComponentInstances inside a target. Pulled
    # out so replace_geometry's main flow stays readable.
    def child_entities(group)
      group.entities.grep(Sketchup::Group) + group.entities.grep(Sketchup::ComponentInstance)
    end

    # Adapter: dispatch a geometry dict to the right create_* path and
    # return the newly created Group. The caller provides the preserved
    # name so we can stamp it on creates that take a name directly
    # (extrusion) without an extra .name= pass.
    def build_replacement_group(geometry, preserved_name)
      op = (geometry["op"] || geometry["type"]).to_s
      model = Sketchup.active_model
      if op == "extrusion"
        extrusion_params = geometry.dup
        extrusion_params["name"] = preserved_name
        result = create_extrusion(extrusion_params)
      else
        primitive_op = geometry.dup
        primitive_op["op"] = op
        primitive_op["name"] = preserved_name
        result = create_named_primitive(primitive_op)
      end
      model.find_entity_by_id(result[:id])
    end

    # Pure: a group is solid iff every edge bounds exactly 2 faces. Operates
    # on a counts array so tests can drive it without real edges.
    def is_solid_from_edge_face_counts?(counts)
      return false if counts.empty?
      counts.all? { |c| c == 2 }
    end

    # Adapter: count faces per edge and run the pure check.
    def edges_form_solid?(edges)
      is_solid_from_edge_face_counts?(edges.map { |e| e.faces.length })
    end

    # Pure: round each coord of a 3-element vector to `decimals`. Used for
    # both normals (6 decimals) and vertex coords (6 decimals).
    def round_xyz(xyz, decimals)
      [xyz[0].to_f.round(decimals), xyz[1].to_f.round(decimals), xyz[2].to_f.round(decimals)]
    end

    def describe_face(face, include_vertices)
      n = face.normal
      outer_loop_id = face.outer_loop.entityID
      loops = face.loops.map do |loop|
        role = loop.entityID == outer_loop_id ? "outer" : "hole"
        verts = loop.vertices.map { |v| v.position }
        loop_dict = { role: role, vertex_count: verts.length }
        if include_vertices
          loop_dict[:vertices] = verts.map { |p| round_xyz([p.x.to_f, p.y.to_f, p.z.to_f], 6) }
        end
        loop_dict
      end
      {
        normal: round_xyz([n.x.to_f, n.y.to_f, n.z.to_f], 6),
        area: face.area.to_f.round(2),
        loops: loops
      }
    end

    def describe_match(entity)
      bmin = entity.bounds.min
      bmax = entity.bounds.max
      layer = entity.respond_to?(:layer) && entity.layer ? entity.layer.name : nil
      material = entity.respond_to?(:material) && entity.material ? entity.material.display_name : nil
      {
        id: entity.entityID,
        name: entity.name,
        bounds: {
          min: [bmin.x.to_f, bmin.y.to_f, bmin.z.to_f],
          max: [bmax.x.to_f, bmax.y.to_f, bmax.z.to_f]
        },
        layer: layer,
        material: material
      }
    end

    def get_selection
      model = Sketchup.active_model
      selection = model.selection
      
      log "Getting selection, count: #{selection.length}"
      
      selected_entities = selection.map do |entity|
        {
          id: entity.entityID,
          type: entity.typename.downcase
        }
      end
      
      { success: true, entities: selected_entities }
    end
    
    # Parse and validate the optional `camera` block from export_scene
    # params. Returns nil when no camera is supplied, or a normalized hash
    # {eye:, target:, up:, perspective:, fov:} otherwise. Pure — no
    # SketchUp API calls — so it can be unit-tested without SketchUp.
    # Image formats only; caller is responsible for rejecting camera on
    # non-image formats.
    def self.parse_camera_params(camera)
      return nil if camera.nil?
      raise "camera must be a hash" unless camera.is_a?(Hash)

      eye    = parse_xyz_triple(camera["eye"], "eye")
      target = parse_xyz_triple(camera["target"], "target")
      up     = camera.key?("up") ? parse_xyz_triple(camera["up"], "up") : [0.0, 0.0, 1.0]

      raise "camera.eye and camera.target must differ" if eye == target
      raise "camera.up must be a non-zero vector" if up == [0.0, 0.0, 0.0]

      perspective = camera["perspective"]
      unless perspective.nil? || perspective == true || perspective == false
        raise "camera.perspective must be a boolean"
      end

      fov = camera["fov"]
      unless fov.nil?
        fov = Float(fov)
        raise "camera.fov must be > 0 and < 180" unless fov > 0 && fov < 180
      end

      { eye: eye, target: target, up: up, perspective: perspective, fov: fov }
    end

    def self.parse_xyz_triple(value, name)
      unless value.is_a?(Array) && value.length == 3
        raise "camera.#{name} must be an [x, y, z] array"
      end
      value.map { |v| Float(v) }
    end

    IMAGE_EXPORT_FORMATS = %w[png jpg jpeg].freeze
    IMAGE_MAX_DIMENSION = 8192

    # Validate and coerce optional pixel dimensions for image exports.
    # Returns nil when absent. Pure for unit testing.
    def self.parse_image_dimension(value, name)
      return nil if value.nil?
      coerced = Integer(value)
      unless coerced > 0 && coerced <= IMAGE_MAX_DIMENSION
        raise "#{name} must be between 1 and #{IMAGE_MAX_DIMENSION}"
      end
      coerced
    end

    def export_scene(params)
      log "Exporting scene with params: #{params.inspect}"
      model = Sketchup.active_model

      format = params["format"] || "skp"

      camera_spec = self.class.parse_camera_params(params["camera"])
      if camera_spec && !IMAGE_EXPORT_FORMATS.include?(format.downcase)
        raise "camera is only supported for image formats (png/jpg/jpeg); got #{format}"
      end

      width  = self.class.parse_image_dimension(params["width"], "width")
      height = self.class.parse_image_dimension(params["height"], "height")
      if (width || height) && !IMAGE_EXPORT_FORMATS.include?(format.downcase)
        raise "width/height are only supported for image formats (png/jpg/jpeg); got #{format}"
      end

      begin
        # Create a temporary directory for exports
        temp_dir = File.join(ENV['TEMP'] || ENV['TMP'] || Dir.tmpdir, "sketchup_exports")
        FileUtils.mkdir_p(temp_dir) unless Dir.exist?(temp_dir)
        
        # Generate a unique filename
        timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
        filename = "sketchup_export_#{timestamp}"
        
        case format.downcase
        when "skp"
          # Export as SketchUp file
          export_path = File.join(temp_dir, "#{filename}.skp")
          log "Exporting to SketchUp file: #{export_path}"
          model.save(export_path)
          
        when "obj"
          # Export as OBJ file
          export_path = File.join(temp_dir, "#{filename}.obj")
          log "Exporting to OBJ file: #{export_path}"
          
          # Check if OBJ exporter is available
          if Sketchup.require("sketchup.rb")
            options = {
              :triangulated_faces => true,
              :double_sided_faces => true,
              :edges => false,
              :texture_maps => true
            }
            model.export(export_path, options)
          else
            raise "OBJ exporter not available"
          end
          
        when "dae"
          # Export as COLLADA file
          export_path = File.join(temp_dir, "#{filename}.dae")
          log "Exporting to COLLADA file: #{export_path}"
          
          # Check if COLLADA exporter is available
          if Sketchup.require("sketchup.rb")
            options = { :triangulated_faces => true }
            model.export(export_path, options)
          else
            raise "COLLADA exporter not available"
          end
          
        when "stl"
          # Export as STL file
          export_path = File.join(temp_dir, "#{filename}.stl")
          log "Exporting to STL file: #{export_path}"
          
          # Check if STL exporter is available
          if Sketchup.require("sketchup.rb")
            options = { :units => "model" }
            model.export(export_path, options)
          else
            raise "STL exporter not available"
          end
          
        when "png", "jpg", "jpeg"
          # Export as image
          ext = format.downcase == "jpg" ? "jpeg" : format.downcase
          export_path = File.join(temp_dir, "#{filename}.#{ext}")
          log "Exporting to image file: #{export_path}"

          view = model.active_view

          options = {
            :filename => export_path,
            :width => width || 1920,
            :height => height || 1080,
            :antialias => true,
            :transparent => (ext == "png")
          }

          # Snapshot+restore the user's camera so a composed export does
          # not leave their SketchUp view at a different angle.
          previous_camera = camera_spec ? view.camera : nil
          begin
            if camera_spec
              new_camera = Sketchup::Camera.new(
                Geom::Point3d.new(*camera_spec[:eye]),
                Geom::Point3d.new(*camera_spec[:target]),
                Geom::Vector3d.new(*camera_spec[:up])
              )
              new_camera.perspective = camera_spec[:perspective] unless camera_spec[:perspective].nil?
              new_camera.fov = camera_spec[:fov] if camera_spec[:fov]
              view.camera = new_camera
            end
            view.write_image(options)
          ensure
            view.camera = previous_camera if previous_camera
          end
          
        else
          raise "Unsupported export format: #{format}"
        end
        
        log "Export completed successfully to: #{export_path}"
        
        { 
          success: true, 
          path: export_path,
          format: format
        }
      rescue StandardError => e
        log "Error in export_scene: #{e.message}"
        log e.backtrace.join("\n")
        raise
      end
    end
    
    def set_material(params)
      log "Setting material with params: #{params.inspect}"
      model = Sketchup.active_model
      
      # Handle ID format - strip quotes if present
      id_str = params["id"].to_s.gsub('"', '')
      log "Looking for entity with ID: #{id_str}"
      
      entity = model.find_entity_by_id(id_str.to_i)
      
      if entity
        log "Found entity: #{entity.inspect}"
        
        material_name = params["material"]
        log "Setting material to: #{material_name}"
        
        # Get or create the material
        material = model.materials[material_name]
        if !material
          # Create a new material if it doesn't exist
          material = model.materials.add(material_name)
          
          # Handle color specification
          case material_name.downcase
          when "red"
            material.color = Sketchup::Color.new(255, 0, 0)
          when "green"
            material.color = Sketchup::Color.new(0, 255, 0)
          when "blue"
            material.color = Sketchup::Color.new(0, 0, 255)
          when "yellow"
            material.color = Sketchup::Color.new(255, 255, 0)
          when "cyan", "turquoise"
            material.color = Sketchup::Color.new(0, 255, 255)
          when "magenta", "purple"
            material.color = Sketchup::Color.new(255, 0, 255)
          when "white"
            material.color = Sketchup::Color.new(255, 255, 255)
          when "black"
            material.color = Sketchup::Color.new(0, 0, 0)
          when "brown"
            material.color = Sketchup::Color.new(139, 69, 19)
          when "orange"
            material.color = Sketchup::Color.new(255, 165, 0)
          when "gray", "grey"
            material.color = Sketchup::Color.new(128, 128, 128)
          else
            # If it's a hex color code like "#FF0000"
            if material_name.start_with?("#") && material_name.length == 7
              begin
                r = material_name[1..2].to_i(16)
                g = material_name[3..4].to_i(16)
                b = material_name[5..6].to_i(16)
                material.color = Sketchup::Color.new(r, g, b)
              rescue
                # Default to a wood color if parsing fails
                material.color = Sketchup::Color.new(184, 134, 72)
              end
            else
              # Default to a wood color
              material.color = Sketchup::Color.new(184, 134, 72)
            end
          end
        end
        
        # Apply the material to the entity
        if entity.respond_to?(:material=)
          entity.material = material
        elsif entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
          # For groups and components, we need to apply to all faces
          entities = entity.is_a?(Sketchup::Group) ? entity.entities : entity.definition.entities
          entities.grep(Sketchup::Face).each { |face| face.material = material }
        end
        
        { success: true, id: entity.entityID }
      else
        raise "Entity not found"
      end
    end
    
    # CSG primitive shared by boolean_operation and the joinery handlers.
    # SketchUp Pro's Solid Tools live on Sketchup::Group as instance methods
    # (#union/#subtract/#intersect/#outer_shell); they consume both inputs
    # and return a new manifold Group, or nil if Pro is unavailable / either
    # input is non-manifold. Sketchup::Entities has no .subtract — using
    # the entities collection raises NoMethodError, which is the regression
    # that motivated this helper.
    def solid_csg(target, tool, operation)
      unless target.is_a?(Sketchup::Group) && tool.is_a?(Sketchup::Group)
        raise "solid_csg requires two Sketchup::Group inputs (got #{target.class} and #{tool.class})"
      end
      # Detect deleted references up-front rather than letting #manifold?
      # raise the cryptic 'reference to deleted Group' from inside the
      # manifold check. Solid Tools consumes both operands, so a stale ref
      # passed in by a caller (e.g., a loop that reused the original handle
      # after the first solid_csg call) shows up here with the side named.
      stale = []
      stale << "target" if target.respond_to?(:valid?) && !target.valid?
      stale << "tool" if tool.respond_to?(:valid?) && !tool.valid?
      unless stale.empty?
        raise "Solid Tools #{operation} received deleted operand(s): #{stale.join(', ')} — the caller is holding a stale reference (Solid Tools consumes operands)"
      end
      unless target.respond_to?(operation)
        raise "Solid Tools #{operation} unavailable — requires SketchUp Pro"
      end
      unless target.respond_to?(:manifold?)
        raise "Solid Tools #{operation} requires Sketchup::Group inputs that respond to #manifold?"
      end
      bad = []
      bad << "target" unless target.manifold?
      bad << "tool" unless tool.manifold?
      unless bad.empty?
        raise "Solid Tools #{operation} requires manifold solids — non-manifold operand(s): #{bad.join(', ')}"
      end
      result = target.send(operation, tool)
      raise "Solid Tools #{operation} returned nil — inputs must be manifold solids" if result.nil?
      result
    end

    # CSG via SketchUp Pro's Solid Tools (Sketchup::Group#union/subtract/intersect/
     # outer_shell). The Pro API consumes both inputs and returns a new manifold
     # group on success or nil if either input isn't a solid / Pro is unavailable.
     # `delete_originals` is accepted for back-compat but is implicit — Solid Tools
     # always consume the operands. Set it to false to keep a duplicate by copying
     # the inputs before the operation.
    def boolean_operation(params)
      log "Performing boolean operation with params: #{params.inspect}"
      model = Sketchup.active_model

      operation = params["operation"].to_s
      unless %w[union subtract intersect outer_shell difference intersection].include?(operation)
        raise "Invalid boolean operation: #{operation}. Must be one of: union, subtract, intersect, outer_shell."
      end
      # Tolerate the older verb spellings used by earlier callers.
      operation = "subtract" if operation == "difference"
      operation = "intersect" if operation == "intersection"

      target_id = params["target_id"].to_s.gsub('"', '')
      tool_id = params["tool_id"].to_s.gsub('"', '')

      target_entity = model.find_entity_by_id(target_id.to_i)
      tool_entity = model.find_entity_by_id(tool_id.to_i)

      unless target_entity && tool_entity
        missing = []
        missing << "target" unless target_entity
        missing << "tool" unless tool_entity
        raise "Entity not found: #{missing.join(', ')}"
      end

      # Solid Tools always consumes both operands; `delete_originals=false`
      # would need a copy-the-group dance that Sketchup::Group doesn't
      # expose directly (the legacy implementation tried .copy on each
      # contained Edge — the 'undefined method copy for Sketchup::Edge'
      # regression that produced this bug). Refuse explicitly rather
      # than emitting half-formed geometry.
      if params.key?("delete_originals") && params["delete_originals"] == false
        raise "delete_originals: false is not supported — Solid Tools consumes both operands"
      end

      # Wrap the whole CSG in a single transaction so any failure
      # (non-manifold inputs, Pro unavailable) rolls back cleanly —
      # partial geometry leaks were the second half of sch-mtl.
      model.start_operation("Boolean #{operation}", true)
      begin
        result_group = solid_csg(target_entity, tool_entity, operation.to_sym)
        model.commit_operation

        {
          success: true,
          id: result_group.entityID,
          manifold: result_group.respond_to?(:manifold?) ? result_group.manifold? : nil
        }
      rescue StandardError
        model.abort_operation
        raise
      end
    end
    
    def chamfer_edges(params)
      log "Chamfering edges with params: #{params.inspect}"
      model = Sketchup.active_model
      
      # Get entity ID
      entity_id = params["entity_id"].to_s.gsub('"', '')
      log "Looking for entity with ID: #{entity_id}"
      
      entity = model.find_entity_by_id(entity_id.to_i)
      unless entity
        raise "Entity not found: #{entity_id}"
      end
      
      # Ensure entity is a group or component instance
      unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
        raise "Chamfer operation requires a group or component instance"
      end
      
      # Get the distance parameter
      distance = params["distance"] || 0.5
      
      # Get the entities collection
      entities = entity.is_a?(Sketchup::Group) ? entity.entities : entity.definition.entities
      
      # Find all edges in the entity
      edges = entities.grep(Sketchup::Edge)
      
      # If specific edges are provided, filter the edges
      if params["edge_indices"] && params["edge_indices"].is_a?(Array)
        edge_indices = params["edge_indices"]
        edges = edges.select.with_index { |_, i| edge_indices.include?(i) }
      end
      
      # Create a new group to hold the result
      result_group = model.active_entities.add_group
      
      # Copy all entities from the original to the result
      entities.each do |e|
        e.copy(result_group.entities)
      end
      
      # Get the edges in the result group
      result_edges = result_group.entities.grep(Sketchup::Edge)
      
      # If specific edges were provided, filter the result edges
      if params["edge_indices"] && params["edge_indices"].is_a?(Array)
        edge_indices = params["edge_indices"]
        result_edges = result_edges.select.with_index { |_, i| edge_indices.include?(i) }
      end
      
      # Perform the chamfer operation
      begin
        # Create a transformation for the chamfer
        chamfer_transform = Geom::Transformation.scaling(1.0 - distance)
        
        # For each edge, create a chamfer
        result_edges.each do |edge|
          # Get the faces connected to this edge
          faces = edge.faces
          next if faces.length < 2
          
          # Get the start and end points of the edge
          start_point = edge.start.position
          end_point = edge.end.position
          
          # Calculate the midpoint of the edge
          midpoint = Geom::Point3d.new(
            (start_point.x + end_point.x) / 2.0,
            (start_point.y + end_point.y) / 2.0,
            (start_point.z + end_point.z) / 2.0
          )
          
          # Create a chamfer by creating a new face
          # This is a simplified approach - in a real implementation,
          # you would need to handle various edge cases
          new_points = []
          
          # For each vertex of the edge
          [edge.start, edge.end].each do |vertex|
            # Get all edges connected to this vertex
            connected_edges = vertex.edges - [edge]
            
            # For each connected edge
            connected_edges.each do |connected_edge|
              # Get the other vertex of the connected edge
              other_vertex = (connected_edge.vertices - [vertex])[0]
              
              # Calculate a point along the connected edge
              direction = other_vertex.position - vertex.position
              new_point = vertex.position.offset(direction, distance)
              
              new_points << new_point
            end
          end
          
          # Create a new face using the new points
          if new_points.length >= 3
            result_group.entities.add_face(new_points)
          end
        end
        
        # Clean up the original entity if requested
        if params["delete_original"]
          entity.erase! if entity.valid?
        end
        
        # Return the result
        { 
          success: true, 
          id: result_group.entityID
        }
      rescue StandardError => e
        log "Error in chamfer_edges: #{e.message}"
        log e.backtrace.join("\n")
        
        # Clean up the result group if there was an error
        result_group.erase! if result_group.valid?
        
        raise
      end
    end
    
    def fillet_edges(params)
      log "Filleting edges with params: #{params.inspect}"
      model = Sketchup.active_model
      
      # Get entity ID
      entity_id = params["entity_id"].to_s.gsub('"', '')
      log "Looking for entity with ID: #{entity_id}"
      
      entity = model.find_entity_by_id(entity_id.to_i)
      unless entity
        raise "Entity not found: #{entity_id}"
      end
      
      # Ensure entity is a group or component instance
      unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
        raise "Fillet operation requires a group or component instance"
      end
      
      # Get the radius parameter
      radius = params["radius"] || 0.5
      
      # Get the number of segments for the fillet
      segments = params["segments"] || 8
      
      # Get the entities collection
      entities = entity.is_a?(Sketchup::Group) ? entity.entities : entity.definition.entities
      
      # Find all edges in the entity
      edges = entities.grep(Sketchup::Edge)
      
      # If specific edges are provided, filter the edges
      if params["edge_indices"] && params["edge_indices"].is_a?(Array)
        edge_indices = params["edge_indices"]
        edges = edges.select.with_index { |_, i| edge_indices.include?(i) }
      end
      
      # Create a new group to hold the result
      result_group = model.active_entities.add_group
      
      # Copy all entities from the original to the result
      entities.each do |e|
        e.copy(result_group.entities)
      end
      
      # Get the edges in the result group
      result_edges = result_group.entities.grep(Sketchup::Edge)
      
      # If specific edges were provided, filter the result edges
      if params["edge_indices"] && params["edge_indices"].is_a?(Array)
        edge_indices = params["edge_indices"]
        result_edges = result_edges.select.with_index { |_, i| edge_indices.include?(i) }
      end
      
      # Perform the fillet operation
      begin
        # For each edge, create a fillet
        result_edges.each do |edge|
          # Get the faces connected to this edge
          faces = edge.faces
          next if faces.length < 2
          
          # Get the start and end points of the edge
          start_point = edge.start.position
          end_point = edge.end.position
          
          # Calculate the midpoint of the edge
          midpoint = Geom::Point3d.new(
            (start_point.x + end_point.x) / 2.0,
            (start_point.y + end_point.y) / 2.0,
            (start_point.z + end_point.z) / 2.0
          )
          
          # Calculate the edge vector
          edge_vector = end_point - start_point
          edge_length = edge_vector.length
          
          # Create points for the fillet curve
          fillet_points = []
          
          # Create a series of points along a circular arc
          (0..segments).each do |i|
            angle = Math::PI * i / segments
            
            # Calculate the point on the arc
            x = midpoint.x + radius * Math.cos(angle)
            y = midpoint.y + radius * Math.sin(angle)
            z = midpoint.z
            
            fillet_points << Geom::Point3d.new(x, y, z)
          end
          
          # Create edges connecting the fillet points
          (0...fillet_points.length - 1).each do |i|
            result_group.entities.add_line(fillet_points[i], fillet_points[i+1])
          end
          
          # Create a face from the fillet points
          if fillet_points.length >= 3
            result_group.entities.add_face(fillet_points)
          end
        end
        
        # Clean up the original entity if requested
        if params["delete_original"]
          entity.erase! if entity.valid?
        end
        
        # Return the result
        { 
          success: true, 
          id: result_group.entityID
        }
      rescue StandardError => e
        log "Error in fillet_edges: #{e.message}"
        log e.backtrace.join("\n")
        
        # Clean up the result group if there was an error
        result_group.erase! if result_group.valid?
        
        raise
      end
    end
    
    def eval_ruby(params)
      log "Evaluating Ruby code with length: #{params['code'].length}"
      
      begin
        # Create a safe binding for evaluation
        binding = TOPLEVEL_BINDING.dup
        
        # Evaluate the Ruby code
        log "Starting code evaluation..."
        result = eval(params["code"], binding)
        log "Code evaluation completed with result: #{result.inspect}"
        
        # Return success with the result as a string
        { 
          success: true,
          result: result.to_s
        }
      rescue StandardError => e
        log "Error in eval_ruby: #{e.message}"
        log e.backtrace.join("\n")
        raise "Ruby evaluation error: #{e.message}"
      end
    end
  end

  unless file_loaded?(__FILE__)
    @server = Server.new
    
    menu = UI.menu("Plugins").add_submenu("MCP Server")
    menu.add_item("Start Server") { @server.start }
    menu.add_item("Stop Server") { @server.stop }
    
    file_loaded(__FILE__)
  end
end 