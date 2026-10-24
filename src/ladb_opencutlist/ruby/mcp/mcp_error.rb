module Ladb::OpenCutList

  # Error raised by the MCP command handlers. The bridge server turns it into a
  # structured JSON error instead of an internal_error.
  class McpError < StandardError

    attr_reader :code

    def initialize(code, message)
      @code = code
      super(message)
    end

  end

end
