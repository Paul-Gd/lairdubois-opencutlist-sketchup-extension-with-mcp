module Ladb::OpenCutList

  require 'socket'
  require 'json'
  require 'securerandom'
  require 'fileutils'
  require_relative 'mcp_error'

  # Loopback-only TCP bridge used by the external MCP server.
  #
  # The server runs entirely on SketchUp's main thread: UI.start_timer pumps a
  # non-blocking accept/read/write loop, exactly like LocalHttpServer. No Ruby
  # thread ever touches the SketchUp API.
  #
  # Wire format: one UTF-8 JSON object per line.
  #   request  {"id":1,"token":"...","method":"mcp_parts_list","params":{}}
  #   response {"id":1,"ok":true,"result":{...}}
  #            {"id":1,"ok":false,"error":{"code":"...","message":"..."}}
  class McpBridgeServer

    POLL_INTERVAL_ACTIVE = 0.02
    POLL_INTERVAL_IDLE = 0.1
    ACTIVE_WINDOW = 1.0
    IDLE_TIMEOUT = 3600
    READ_CHUNK = 65536
    MAX_LINE_BYTES = 8 * 1024 * 1024

    attr_reader :port, :discovery_file

    def initialize(command_executor)
      @command_executor = command_executor
      @server = nil
      @port = nil
      @token = nil
      @discovery_file = File.join(Dir.home, '.ocl-mcp', 'bridge.json')
      @clients = {}
      @poll_timer_id = nil
      @last_activity_at = 0.0
    end

    # Idempotent. Returns the status Hash.
    def start
      return status if running?

      @token = SecureRandom.hex(32)
      @server = TCPServer.new('127.0.0.1', 0)
      @port = @server.addr[1]
      _write_discovery_file
      @last_activity_at = Time.now.to_f
      _schedule_poll
      status
    rescue Exception => e
      _close_server
      _delete_discovery_file
      raise e
    end

    def stop
      _cancel_poll
      @clients.each_key { |client| _close_client(client) }
      @clients.clear
      _close_server
      _delete_discovery_file
      nil
    end

    def running?
      !@server.nil?
    end

    def status
      {
        :running => running?,
        :port => @port,
        :discovery_file => @discovery_file,
        :version => _version,
        :model => _model_name
      }
    end

    # Called by the UI.start_timer tick. Safe and cheap when stopped.
    def pump
      return if @server.nil?
      _accept_new_clients
      _service_clients
      nil
    end

    private

    def _version
      defined?(EXTENSION_VERSION) ? EXTENSION_VERSION : 'unknown'
    end

    def _model_name
      model = Sketchup.active_model
      model.nil? ? nil : model.name
    end

    def _write_discovery_file
      directory = File.dirname(@discovery_file)
      FileUtils.mkdir_p(directory)
      begin
        File.chmod(0700, directory)
      rescue StandardError
        # Not fatal on platforms without POSIX permissions.
      end

      payload = {
        :port => @port,
        :token => @token,
        :pid => Process.pid,
        :version => _version,
        :model => _model_name,
        :started_at => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
      }

      File.open(@discovery_file, File::WRONLY | File::CREAT | File::TRUNC, 0600) do |file|
        file.write(JSON.generate(payload))
      end
      begin
        File.chmod(0600, @discovery_file)
      rescue StandardError
        # Not fatal on platforms without POSIX permissions.
      end
    end

    def _delete_discovery_file
      return unless File.exist?(@discovery_file)

      # Only remove the file if it still belongs to this process. Another
      # SketchUp instance may have overwritten it in the meantime.
      data = JSON.parse(File.read(@discovery_file))
      File.delete(@discovery_file) if data['pid'] == Process.pid
    rescue StandardError
      # Ignore malformed or already-deleted discovery files.
    end

    def _schedule_poll
      return unless @poll_timer_id.nil?

      active = (Time.now.to_f - @last_activity_at.to_f) < ACTIVE_WINDOW
      interval = active ? POLL_INTERVAL_ACTIVE : POLL_INTERVAL_IDLE
      @poll_timer_id = UI.start_timer(interval, false) do
        @poll_timer_id = nil
        begin
          pump
        rescue Exception => e
          PLUGIN.dump_exception(e, false)
        end
        _schedule_poll if running?
      end
    end

    def _cancel_poll
      UI.stop_timer(@poll_timer_id) unless @poll_timer_id.nil?
      @poll_timer_id = nil
    end

    def _accept_new_clients
      return if @server.nil?

      loop do
        begin
          client = @server.accept_nonblock
        rescue IO::WaitReadable, Errno::EAGAIN
          return
        rescue Exception => e
          PLUGIN.dump_exception(e, false)
          return
        end

        @clients[client] = {
          :buffer => ''.dup,
          :output => ''.dup,
          :last_activity => Time.now,
          :close_after_flush => false
        }
        @last_activity_at = Time.now.to_f
      end
    end

    def _service_clients
      now = Time.now

      @clients.keys.each do |client|
        state = @clients[client]
        next if state.nil?

        begin
          data = client.read_nonblock(READ_CHUNK)
          state[:buffer] << data
          state[:last_activity] = now
        rescue IO::WaitReadable, Errno::EAGAIN
          # Nothing to read right now: normal for an idle persistent connection.
        rescue EOFError, Errno::ECONNRESET, Errno::EPIPE
          _close_client(client)
          next
        rescue Exception => e
          PLUGIN.dump_exception(e, false)
          _close_client(client)
          next
        end

        _flush_client(client)
        next if @clients[client].nil?

        loop do
          line = _extract_line(state[:buffer])
          break if line.nil?

          state[:buffer] = line[1]
          @last_activity_at = Time.now.to_f
          _handle_line(client, line[0])
          break if @clients[client].nil?
        end

        next if @clients[client].nil?

        if state[:buffer].bytesize > MAX_LINE_BYTES
          _close_client(client)
        elsif now - state[:last_activity] > IDLE_TIMEOUT
          _close_client(client)
        end
      end
    end

    # Returns [line, rest] or nil when no complete line is buffered.
    def _extract_line(buffer)
      index = buffer.index("\n")
      return nil if index.nil?
      [ buffer[0, index].strip, buffer[(index + 1)..-1] || ''.dup ]
    end

    def _handle_line(client, line)
      return if line.nil? || line.empty?

      if line.bytesize > MAX_LINE_BYTES
        _queue_response(client, _error_response(nil, 'line_too_long', 'Request line exceeds the 8 MB limit.'), true)
        return
      end

      begin
        request = JSON.parse(line)
      rescue JSON::ParserError => e
        _queue_response(client, _error_response(nil, 'invalid_json', e.message))
        return
      end

      unless request.is_a?(Hash)
        _queue_response(client, _error_response(nil, 'invalid_request', 'Request must be a JSON object.'))
        return
      end

      id = request['id']
      token = request['token']

      unless _secure_compare(token, @token)
        _queue_response(client, _error_response(id, 'auth_failed', 'Invalid or missing bridge token.'), true)
        return
      end

      method = request['method']
      unless method.is_a?(String) && method.start_with?('mcp_')
        _queue_response(client, _error_response(id, 'unknown_method', "Unknown method '#{method}'."))
        return
      end

      params = request['params']
      params = {} if params.nil?
      unless params.is_a?(Hash)
        _queue_response(client, _error_response(id, 'invalid_params', 'params must be a JSON object.'))
        return
      end

      begin
        result = @command_executor.call(method, params)
        _queue_response(client, { :id => id, :ok => true, :result => result })
      rescue McpError => e
        _queue_response(client, _error_response(id, e.code, e.message))
      rescue Exception => e
        PLUGIN.dump_exception(e, false)
        code = e.message =~ /Command '.*' not found/ ? 'unknown_method' : 'internal_error'
        _queue_response(client, _error_response(id, code, "#{e.class}: #{e.message}"))
      end
    end

    def _error_response(id, code, message)
      {
        :id => id,
        :ok => false,
        :error => {
          :code => code,
          :message => message
        }
      }
    end

    def _queue_response(client, payload, close_after_flush = false)
      state = @clients[client]
      return if state.nil?

      state[:output] << JSON.generate(payload) << "\n"
      state[:close_after_flush] = true if close_after_flush
      _flush_client(client)
    end

    def _flush_client(client)
      state = @clients[client]
      return if state.nil?

      until state[:output].empty?
        begin
          written = client.write_nonblock(state[:output])
          state[:output] = state[:output].byteslice(written, state[:output].bytesize - written) || ''.dup
        rescue IO::WaitWritable, Errno::EAGAIN
          return
        rescue EOFError, Errno::ECONNRESET, Errno::EPIPE
          _close_client(client)
          return
        rescue Exception => e
          PLUGIN.dump_exception(e, false)
          _close_client(client)
          return
        end
      end

      _close_client(client) if state[:close_after_flush]
    end

    def _close_client(client)
      state = @clients.delete(client)
      return if state.nil?
      begin
        client.close unless client.closed?
      rescue StandardError
        # Ignore sockets already closed by the peer.
      end
    end

    def _close_server
      begin
        @server.close unless @server.nil?
      rescue StandardError
        # Ignore.
      ensure
        @server = nil
        @port = nil
      end
    end

    def _secure_compare(a, b)
      return false unless a.is_a?(String) && b.is_a?(String) && a.bytesize == b.bytesize
      result = 0
      a.bytes.zip(b.bytes) { |x, y| result |= (x ^ y) }
      result == 0
    end

  end

end
