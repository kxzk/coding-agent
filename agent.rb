#!/usr/bin/env ruby
require 'json'
require 'anthropic'
require_relative 'ui'

class Toolset
  def initialize
    # TODO: initialize tools
  end

  def definitions
    # TODO: return tool definitions for API
  end

  def execute(name, input)
    # TODO: execute the requested tool
  end

  private

  def build_tools
    # TODO: define available tools (read_file, write_file, list_files, bash)
  end
end

class Agent
  def initialize
    # TODO: initialize client, toolset, and message history
  end

  def run
    # TODO: main REPL loop
  end

  private

  def handle_conversation
    # TODO: API call loop with tool use handling
  end
end

if __FILE__ == $0
  begin
    Agent.new.run
  rescue Interrupt
    UI.goodbye
  end
end
