# frozen_string_literal: true
#
# compact coding agent in Ruby, inspired by:
# https://github.com/ghuntley/how-to-build-a-coding-agent
#
# capabilities:
#   1) basic chat
#   2) read_file
#   3) list_files
#   4) bash
#   5) edit_file
#   6) code_search (ripgrep)
#
# usage:
#   ruby agent.rb # interactive repl
#   ruby agent.rb --verbose #show tool calls and results
require 'json'
require 'open3'
require 'timeout'
require 'fileutils'
require 'pathname'
require 'optparse'
require 'anthropic'

class Sandbox
  DEFAULT_MAX_BYTES = 1 * 1024 * 1024 # 1 MB read cap

  def initialize(root:)
    @root = Pathname.new(File.expand_path(root)).realpath
  end

  def within(path)
    p = @root.join(path).cleanpath
    raise "Path escapes sandbox root" unless p.to_s.start_with?(@root.to_s)
    p
  end

  def read(path, max_bytes: DEFAULT_MAX_BYTES)
    p = within(path)
    raise "File not found: #{p}" unless p.file?
    File.open(p, "rb") { |f| f.read(max_bytes) }
  end

  def list(path = ".", max: 512)
    p = within(path)
    raise "Not a directory: #{path}" unless p.directory?
    entries = Dir.glob("**/*", base: p).first(max)
    entries.sort
  end

  def write(path, content, create_dirs: true)
    p = within(path)
    FileUtils.mkdir_p(p.dirname) if create_dirs
    File.write(p, content)
    "wrote #{rel(p)} (#{content.bytesize} bytes)"
  end

  def edit(path, old_str:, new_str:, ensure_uniqueness: true)
    p = within(path)
    FileUtils.mkdir_p(p.dirname) unless p.dirname.exist?
    existing = p.exist? ? p.read : ""
    if old_str.nil? || old_str.empty?
      if ensure_uniqueness && existing.include?(new_str)
        return "no-op: new_str already present"
      end
      updated = existing + new_str
    else
      occurrences = existing.scan(Regexp.new(Regexp.escape(old_str))).size
      raise "old_str not found" if occurrences.zero?
      updated = existing.gsub(old_str, new_str)
    end
    File.write(p, updated)
    "edited #{rel(p)} (#{existing.bytesize}B -> #{updated.bytesize}B)"
  end

  def bash(command, timeout_sec: 10)
    Timeout.timeout(timeout_sec) do
      stdout, stderr, status = Open3.capture3({"LC_ALL" => "C"}, command, chdir: @root.to_s)
      out = +"$ #{command}\n"
      out << stdout unless stdout.empty?
      out << stderr unless stderr.empty?
      out << "\n(exit #{status.exitstatus})"
      out
    end
  rescue Timeout::Error
    "timeout after #{timeout_sec}s"
  end

  def code_search(pattern:, path: ".", file_type: nil, case_sensitive: false, max_results: 500)
    rg = ["rg", "--no-heading", "--line-number", "--hidden", "--glob", "!.git"]
    rg << "-i" unless case_sensitive
    rg << "-t" << file_type if file_type && !file_type.empty?
    rg << pattern
    rg << "."
    p = within(path)
    _, _, status = Open3.capture3("rg --version")
    raise "ripgrep (rg) not installed" unless status.success?
    stdout, stderr, st = Open3.capture3(*rg, chdir: p.to_s)
    raise "rg error: #{stderr}" if !st.success? && stdout.empty? && !stderr.empty?
    lines = stdout.lines.first(max_results)
    lines.join
  end

  private

  def rel(pathname) = pathname.to_s.delete_prefix(@root.to_s + "/")
end

Tool = Struct.new(:name, :description, :input_schema, :handler)

class Toolset
  attr_reader :definitions

  def initialize(sandbox)
    @sandbox = sandbox
    @definitions = [
      Tool.new(
        "read_file",
        "Read up to 1MB of a UTF-8 or binary file form the workspace root. Use to inspect code or data before proposing edits.",
        {
          type: "object",
          properties: {
            path: { type: "string", description: "Relative path from workspace root." }
          },
          required: ["path"]
        },
        ->(input) { @sandbox.read(input["path"]) }
      ),
      Tool.new(
        "list_files",
        "Recursively list files under a directory (max 512 entries). Use to explore the workspace before file-specific actions.",
        {
          type: "object",
          properties: {
            path: { type: "string", description: "Directory path, default '.'" }
          }
        },
        ->(input) { @sandbox.list(input["path"] || ".").to_json }
      ),
      Tool.new(
        "bash",
        "Execute a shell command inside the workspace root with a 10s timeout. Prefer read_file/edit_file for code ops; use bash for git/linters/builds.",
        {
          type: "object",
          properties: {
            command: { type: "string", description: "Shell command to run." }
          },
          required: ["command"]
        },
        ->(input) { @sandbox.bash(input["command"]) }
      ),
            Tool.new(
        "edit_file",
        "Create or modify a file. If old_str is empty, append new_str. Otherwise replace all occurrences of old_str with new_str. Ensures uniqueness by default.",
        {
          type: "object",
          properties: {
            path: { type: "string", description: "Relative file path." },
            old_str: { type: "string", description: "Text to replace. If empty, append new_str." },
            new_str: { type: "string", description: "Replacement or appended text." },
            ensure_uniqueness: { type: "boolean", description: "Prevent duplicate insertion when appending.", default: true }
          },
          required: ["path", "new_str"]
        },
        ->(input) do
          @sandbox.edit(
            input["path"],
            old_str: input["old_str"].to_s,
            new_str: input["new_str"].to_s,
            ensure_uniqueness: input.fetch("ensure_uniqueness", true)
          )
        end
      ),
      Tool.new(
        "write_file",
        "Write or overwrite a file with new content. Creates parent directories automatically.",
        {
          type: "object",
          properties: {
            path: { type: "string", description: "Relative file path from workspace root." },
            content: { type: "string", description: "Content to write to the file." },
            create_dirs: { type: "boolean", description: "Create parent directories if needed.", default: true }
          },
          required: ["path", "content"]
        },
        ->(input) do
          @sandbox.write(
            input["path"],
            input["content"],
            create_dirs: input.fetch("create_dirs", true)
          )
        end
      ),
      Tool.new(
        "code_search",
        "Search code with ripgrep. Returns file:line:match for the first match per file, case-insensitive by default.",
        {
          type: "object",
          properties: {
            pattern: { type: "string", description: "Regex or literal search pattern." },
            path: { type: "string", description: "Directory to search, default '.'" },
            file_type: { type: "string", description: "rg -t value (e.g., 'rb', 'go', 'js')." },
            case_sensitive: { type: "boolean", description: "Default false (case-insensitive)." }
          },
          required: ["pattern"]
        },
        ->(input) do
          @sandbox.code_search(
            pattern: input["pattern"],
            path: input["path"] || ".",
            file_type: input["file_type"],
            case_sensitive: input["case_sensitive"] == true
          )
        end
      )
    ]
  end

  def tools_param
    @definitions.map do |t|
      { name: t.name, description: t.description, input_schema: t.input_schema }
    end
  end

  def call_tool(name, input)
    tool = @definitions.find { |t| t.name == name } or raise "Unknown tool: #{name}"
    tool.handler.call(input)
  end
end

class Agent
  DEFAULT_MODEL = "claude-sonnet-4-20250514"

  def initialize(verbose: false, root: Dir.pwd, model: DEFAULT_MODEL)
    @verbose = verbose
    @sandbox = Sandbox.new(root: root)
    @toolset = Toolset.new(@sandbox)
    @anthropic = Anthropic::Client.new(api_key: ENV["ANTHROPIC_API_KEY"])
    @model = model
    @messages = []
  end

  def run
    puts "Chat with Claude (ctrl-c to quit)"
    loop do
      print "You: "
      line = $stdin.gets
      break if line.nil?
      user = line.strip
      next if user.empty?
      @messages << { role: :user, content: user }
      respond_until_complete!
    end
  end

  private

  def respond_until_complete!
    loop do
      resp = @anthropic.messages.create(
        model: @model,
        max_tokens: 1024,
        messages: @messages,
        tools: @toolset.tools_param
      )

      text = resp.content.filter { |b| b.type == :text }.map(&:text).join
      tool_uses = resp.content.filter { |b| b.type == :tool_use }

      if @verbose && !text.empty?
        puts "\nassistant(text): #{text}\n\n"
      end

      if tool_uses.empty?
        puts "Claude: #{text}"
        @messages << { role: :assistant, content: text }
        return
      end

      # log and execute all tool calls
      tool_results = []
      tool_uses.each do |tu|
        name = tu.name
        # ensure string keys for compatibility with tool handlers
        input = tu.input.is_a?(Hash) ? tu.input : JSON.parse(JSON.dump(tu.input))
        input = input.transform_keys(&:to_s)
        puts "tool: #{name}(#{input.to_json})" if @verbose
        result_text = safe_exec_tool(name, input)
        puts "result: #{result_text[0, 500]}" if @verbose
        tool_results << { type: :tool_result, tool_use_id: tu.id, content: result_text }
      end

      assistant_blocks = []
      assistant_blocks.concat(resp.content.filter { |b| b.type == :text }.map { |b| { type: :text, text: b.text } })
      assistant_blocks.concat(tool_uses.map { |b| { type: :tool_use, id: b.id, name: b.name, input: b.input } })

      @messages << { role: :assistant, content: assistant_blocks }
      @messages << { role: :user, content: tool_results }
    end
  end

  def safe_exec_tool(name, input)
    @toolset.call_tool(name, input)
  rescue => e
    "error: #{e.class}: #{e.message}"
  end
end

if __FILE__ == $0
  options = { verbose: false }
  OptionParser.new do |o|
    o.on("--verbose", "Verbose logging (show tool calls/results)") { options[:verbose] = true }
    o.on("--root=PATH", "Workspace root (default: Dir.pwd)") { |p| options[:root] = p }
  end.parse!(ARGV)

  Agent.new(verbose: options[:verbose], root: options[:root] || Dir.pwd).run
end
