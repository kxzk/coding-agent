### How to Build A Coding Agent - Code Snippets

---

### Slide 20: Initial Setup

```bash
# Install dependencies
gem install anthropic

# Set your API key
export ANTHROPIC_API_KEY='sk-...'
```

---

### Slide 21: Toolset Class - Initialize and Definitions

```ruby
class Toolset
  def initialize
    @tools = build_tools
  end

  def definitions
    @tools.map { |t| t.slice(:name, :description, :input_schema) }
  end
end
```

---

### Slide 22: Toolset Class - Execute Method

```ruby
class Toolset
  # .. existing code ...

  def execute(name, input)
    tool = @tools.find { |t| t[:name] == name }
    input = JSON.parse(JSON.generate(input))
    tool[:handler].call(input)
  end
end
```

---

### Slide 26: Read File Tool

```ruby
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
    }
  ]
end
```

---

### Slide 27: Write File Tool

```ruby
def build_tools
  [
    # ... read_file ...
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
    }
  ]
end
```

---

### Slide 28: List Files Tool

```ruby
def build_tools
  [
    # ... read_file ...
    # ... write_file ...
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
    }
  ]
end
```

---

### Slide 29: Bash Tool

```ruby
def build_tools
  [
    # ... read_file ...
    # ... write_file ...
    # ... list_files ...
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
```

---

### Slide 31: Agent Class - Initialize

```ruby
class Agent
  def initialize
    @client = Anthropic::Client.new(api_key: ENV.fetch('ANTHROPIC_API_KEY'))
    @toolset = Toolset.new
    @messages = []
  end
end
```

---

### Slide 32: Agent Class - Run Method

```ruby
class Agent
  # ... existing code ...

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
end
```

---

### Slide 34: Handle Conversation - Start

```ruby
class Agent
  # ... existing code ...

  def handle_conversation
    loop do
      response = @client.messages.create(
        model: 'claude-sonnet-4-5',
        max_tokens: 1024,
        messages: @messages,
        tools: @toolset.definitions
      )

      text_blocks = response.content.select { |b| b.type == :text }
      tool_uses = response.content.select { |b| b.type == :tool_use }
    end
  end
end
```

---

### Slide 35: Display Response and Check for Tools

```ruby
class Agent
  # ... existing code ...

  def handle_conversation
    loop do
      # ... existing code ...
      if text_blocks.any?
        text = text_blocks.map(&:text).join
        UI.agent(text)
      end

      if tool_uses.empty?
        @messages << { role: :assistant, content: text_blocks.map(&:text).join }
        break
      end
    end
  end
end
```

---

### Slide 36: Execute Tools

```ruby
class Agent
  # ... existing code ...

  def handle_conversation
    loop do
      # ... existing code ...
      tool_results = tool_uses.map do |tool_use|
        UI.tool_call(tool_use.name)
        result = @toolset.execute(tool_use.name, tool_use.input)
        UI.tool_result(result)

        { type: :tool_result, tool_use_id: tool_use.id, content: result }
      end
    end
  end
end
```

---

### Slide 37: Feed Results Back to Claude

```ruby
class Agent
  # ... existing code ...

  def handle_conversation
    loop do
      # ... existing code ...
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
```

---

### Slide 38: Run the Agent

```bash
$ ruby agent.rb
```
