#!/usr/bin/env ruby
require 'json'
require 'anthropic'
require_relative 'ui'

class Toolset
  def initialize
    @tools = build_tools
  end

  def definitions
    @tools.map { |t| t.slice(:name, :description, :input_schema) }
  end

  def execute(name, input)
    tool = @tools.find { |t| t[:name] == name }
    input = JSON.parse(JSON.generate(input))
    tool[:handler].call(input)
  end

  private

  def build_tools
    [
      {
        name: 'read_file',
        description: 'Read contents of a file',
        input_schema: {
          type: 'object',
          properties: { path: { type: 'string', description: 'File path to read' } },
          required: ['path']
        },
        handler: ->(input) { File.read(input['path']) }
      },
      {
        name: 'write_file',
        description: 'Write content to a file',
        input_schema: {
          type: 'object',
          properties: {
            path: { type: 'string', description: 'File path to write' },
            content: { type: 'string', description: 'Content to write' }
          },
          required: ['path', 'content']
        },
        handler: ->(input) do
          File.write(input['path'], input['content'])
          "wrote #{input['path']} (#{input['content'].bytesize} bytes)"
        end
      },
      {
        name: 'list_files',
        description: 'List files in current directory',
        input_schema: {
          type: 'object',
          properties: { path: { type: 'string', description: 'Directory path (optional)' } }
        },
        handler: ->(input) do
          path = input['path'] || '.'
          files = Dir.entries(path).reject { |f| f.start_with?('.') }.sort
          files.join("\n")
        end
      },
      {
        name: 'bash',
        description: 'Execute a shell command',
        input_schema: {
          type: 'object',
          properties: { command: { type: 'string', description: 'Command to run' } },
          required: ['command']
        },
        handler: ->(input) { `#{input['command']} 2>&1` }
      }
    ]
  end
end

class Agent
  def initialize
    @client = Anthropic::Client.new(api_key: ENV.fetch('ANTHROPIC_API_KEY'))
    @toolset = Toolset.new
    @messages = []
  end

  def run
    UI.banner

    loop do
      UI.prompt
      input = gets&.strip
      break if input.nil? || input == 'exit'
      next if input.empty?

      @messages << { role: :user, content: input }
      handle_conversation
    end
  end

  private

  def handle_conversation
    loop do
      response = @client.messages.create(
        model: 'claude-sonnet-4-5',
        # model: 'claude-sonnet-4-20250514',
        max_tokens: 1024,
        messages: @messages,
        tools: @toolset.definitions
      )

      text_blocks = response.content.select { |b| b.type == :text }
      tool_uses = response.content.select { |b| b.type == :tool_use }

      if text_blocks.any?
        text = text_blocks.map(&:text).join
        UI.agent(text)
      end

      if tool_uses.empty?
        @messages << { role: :assistant, content: text_blocks.map(&:text).join }
        break
      end

      tool_results = tool_uses.map do |tool_use|
        UI.tool_call(tool_use.name)
        result = @toolset.execute(tool_use.name, tool_use.input)
        UI.tool_result(result)

        { type: :tool_result, tool_use_id: tool_use.id, content: result }
      end

      @messages << {
        role: :assistant,
        content: [
          *text_blocks.map { |b| { type: :text, text: b.text } },
          *tool_uses.map { |tu| { type: :tool_use, id: tu.id, name: tu.name, input: tu.input } }
        ]
      }

      @messages << { role: :user, content: tool_results }
    end
  end
end

if __FILE__ == $0
  begin
    Agent.new.run
  rescue Interrupt
    UI.goodbye
  end
end
