# frozen_string_literal: true
#
# inspired by:
# https://github.com/ghuntley/how-to-build-a-coding-agent
require 'json'
require 'open3'
require 'timeout'
require 'fileutils'
require 'pathname'
require 'optparse'
require 'anthropic'

class Sandbox
  DEFAULT_MAX_BYTES = 1 << 20 # 1MB

  def initialize(root:)
    @root = Pathname.new(File.expand_path(root)).realpath
  end

  def read(path, max_bytes: DEFAULT_MAX_BYTES)
    validate_file(path).read(max_bytes)
  end

  def list(path = ".", max: 512)
    dir = validate_dir(path)
    Dir.glob("**/*", base: dir).first(max).sort
  end

  def write(path, content, create_dirs: true)
    p = safe_path(path)
    FileUtils.mkdir_p(p.dirname) if create_dirs
    File.write(p, content)
    "wrote #{rel(p)} (#{content.bytesize} bytes)"
  end

  def edit(path, old_str:, new_str:, ensure_uniqueness: true)
    p = safe_path(path)
    FileUtils.mkdir_p(p.dirname) unless p.dirname.exist?

    existing = p.exist? ? p.read : ""

    updated = if old_str.to_s.empty?
      return "no-op: new_str already present" if ensure_uniqueness && existing.include?(new_str)
      existing + new_str
    else
      raise "old_str not found" unless existing.include?(old_str)
      existing.gsub(old_str, new_str)
    end

    File.write(p, updated)
    "edited #{rel(p)} (#{existing.bytesize}B -> #{updated.bytesize}B)"
  end

  def bash(command, timeout_sec: 10)
    Timeout.timeout(timeout_sec) do
      stdout, stderr, status = Open3.capture3({"LC_ALL" => "C"}, command, chdir: @root.to_s)
      ["$ #{command}", stdout, stderr, "\n(exit #{status.exitstatus})"].reject(&:empty?).join("\n")
    end
  rescue Timeout::Error
    "timeout after #{timeout_sec}s"
  end

  def code_search(pattern:, path: ".", **opts)
    ensure_ripgrep!

    rg_cmd = build_rg_command(pattern, opts)
    stdout, stderr, status = Open3.capture3(*rg_cmd, chdir: safe_path(path).to_s)

    raise "rg error: #{stderr}" if !status.success? && stdout.empty? && stderr.present?
    stdout.lines.first(opts[:max_results] || 500).join
  end

  private

  def safe_path(path)
    p = @root.join(path).cleanpath
    raise "Path escapes sandbox root" unless p.to_s.start_with?(@root.to_s)
    p
  end

  def validate_file(path)
    p = safe_path(path)
    raise "File not found: #{p}" unless p.file?
    p
  end

  def validate_dir(path)
    p = safe_path(path)
    raise "Not a directory: #{path}" unless p.directory?
    p
  end

  def rel(pathname)
    pathname.to_s.delete_prefix(@root.to_s + "/")
  end

  def ensure_ripgrep!
    _, _, status = Open3.capture3("rg --version")
    raise "ripgrep (rg) not installed" unless status.success?
  end

  def build_rg_command(pattern, opts)
    ["rg", "--no-heading", "--line-number", "--hidden", "--glob", "!.git"].tap do |cmd|
      cmd << "-i" unless opts[:case_sensitive]
      cmd += ["-t", opts[:file_type]] if opts[:file_type]&.present?
      cmd << pattern << "."
    end
  end
end

class Toolset
  attr_reader :tools

  def initialize(sandbox)
    @sandbox = sandbox
    @tools = build_tools
  end

  def tools_param
    @tools.map { |t| t.slice(:name, :description, :input_schema) }
  end

  def call(name, input)
    tool = @tools.find { |t| t[:name] == name } or raise "Unknown tool: #{name}"
    tool[:handler].call(input)
  end

  private

  def build_tools
    [
      tool("read_file",
        "Read up to 1MB of a UTF-8 or binary file. Use to inspect code before edits.",
        path: :required) { |i| @sandbox.read(i["path"]) },

      tool("list_files",
        "Recursively list files under a directory (max 512 entries).",
        path: :optional) { |i| @sandbox.list(i["path"] || ".").to_json },

      tool("bash",
        "Execute shell command with 10s timeout. Prefer file tools for code ops.",
        command: :required) { |i| @sandbox.bash(i["command"]) },

      tool("edit_file",
        "Create or modify a file. Empty old_str appends. Replaces all occurrences.",
        path: :required, old_str: :optional, new_str: :required, ensure_uniqueness: :optional) do |i|
        @sandbox.edit(i["path"],
          old_str: i["old_str"].to_s,
          new_str: i["new_str"].to_s,
          ensure_uniqueness: i.fetch("ensure_uniqueness", true))
      end,

      tool("write_file",
        "Write or overwrite a file. Creates parent directories automatically.",
        path: :required, content: :required, create_dirs: :optional) do |i|
        @sandbox.write(i["path"], i["content"], create_dirs: i.fetch("create_dirs", true))
      end,

      tool("code_search",
        "Search with ripgrep. Returns file:line:match. Case-insensitive by default.",
        pattern: :required, path: :optional, file_type: :optional, case_sensitive: :optional) do |i|
        @sandbox.code_search(
          pattern: i["pattern"],
          path: i["path"] || ".",
          file_type: i["file_type"],
          case_sensitive: i["case_sensitive"] == true)
      end
    ]
  end

  def tool(name, description, schema = {}, &handler)
    properties = {}
    required = []

    schema.each do |key, requirement|
      next if key == :handler
      properties[key] = { type: "string", description: infer_description(key) }
      properties[key][:default] = true if key == :ensure_uniqueness || key == :create_dirs
      required << key.to_s if requirement == :required
    end

    {
      name: name,
      description: description,
      input_schema: {
        type: "object",
        properties: properties,
        required: required
      }.compact,
      handler: handler
    }
  end

  def infer_description(key)
    {
      path: "Relative path from workspace root",
      command: "Shell command to run",
      pattern: "Regex or literal search pattern",
      old_str: "Text to replace. If empty, append new_str",
      new_str: "Replacement or appended text",
      content: "Content to write to the file",
      file_type: "rg -t value (e.g., 'rb', 'go', 'js')",
      case_sensitive: "Default false (case-insensitive)",
      ensure_uniqueness: "Prevent duplicate insertion when appending",
      create_dirs: "Create parent directories if needed"
    }[key] || key.to_s.tr('_', ' ').capitalize
  end
end

class Agent
  DEFAULT_MODEL = "claude-sonnet-4-20250514"

  def initialize(verbose: false, root: Dir.pwd, model: DEFAULT_MODEL)
    @verbose = verbose
    @toolset = Toolset.new(Sandbox.new(root: root))
    @anthropic = Anthropic::Client.new(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
    @model = model
    @messages = []
  end

  def run
    puts "Chat with Claude (ctrl-c to quit)"

    loop do
      print "You: "
      input = $stdin.gets&.strip
      break if input.nil?
      next if input.empty?

      @messages << { role: :user, content: input }
      handle_conversation
    end
  end

  private

  def handle_conversation
    loop do
      response = fetch_response

      text_blocks = response.content.select { |b| b.type == :text }
      tool_uses = response.content.select { |b| b.type == :tool_use }

      display_text(text_blocks.map(&:text).join) if text_blocks.any?

      if tool_uses.empty?
        @messages << { role: :assistant, content: text_blocks.map(&:text).join }
        return
      end

      tool_results = execute_tools(tool_uses)

      @messages << build_assistant_message(text_blocks, tool_uses)
      @messages << { role: :user, content: tool_results }
    end
  end

  def fetch_response
    @anthropic.messages.create(
      model: @model,
      max_tokens: 1024,
      messages: @messages,
      tools: @toolset.tools_param
    )
  end

  def display_text(text)
    return if text.empty?
    prefix = @verbose ? "\nassistant(text): " : "Claude: "
    puts "#{prefix}#{text}\n"
  end

  def execute_tools(tool_uses)
    tool_uses.map do |tu|
      input = normalize_input(tu.input)

      log_tool_call(tu.name, input) if @verbose
      result = safe_exec(tu.name, input)
      log_tool_result(result) if @verbose

      { type: :tool_result, tool_use_id: tu.id, content: result }
    end
  end

  def normalize_input(input)
    input = input.is_a?(Hash) ? input : JSON.parse(JSON.dump(input))
    input.transform_keys(&:to_s)
  end

  def safe_exec(name, input)
    @toolset.call(name, input)
  rescue => e
    "error: #{e.class}: #{e.message}"
  end

  def build_assistant_message(text_blocks, tool_uses)
    {
      role: :assistant,
      content: [
        *text_blocks.map { |b| { type: :text, text: b.text } },
        *tool_uses.map { |b| { type: :tool_use, id: b.id, name: b.name, input: b.input } }
      ]
    }
  end

  def log_tool_call(name, input)
    puts "tool: #{name}(#{input.to_json})"
  end

  def log_tool_result(result)
    puts "result: #{result[0, 500]}"
  end
end

class Object
  def present?
    !blank?
  end

  def blank?
    respond_to?(:empty?) ? empty? : !self
  end
end

if __FILE__ == $0
  options = {}

  OptionParser.new do |o|
    o.on("--verbose", "Show tool calls/results") { options[:verbose] = true }
    o.on("--root=PATH", "Workspace root") { |p| options[:root] = p }
  end.parse!(ARGV)

  Agent.new(**options.compact).run
end
