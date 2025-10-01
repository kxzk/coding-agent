![cover](./images/workshop-cover.png)

<br>

## Setup

1. Install dependencies:
```bash
bundle install
```

2. Set your API key:
```bash
export ANTHROPIC_API_KEY='your-key-here'
```

<br>

## Running

```bash
ruby agent.rb
```

Type `exit` or press `ctrl-c` to quit.

<br>

## Implementation

The skeleton provides two classes to implement:

### Toolset
Manages tool definitions and execution. Should support:
- `read_file` - read file contents
- `write_file` - write content to file
- `list_files` - list directory contents
- `bash` - execute shell commands

### Agent
Handles conversation loop:
- Accepts user input
- Calls Anthropic Messages API with tool definitions
- Processes tool use requests
- Returns results back to API until completion

<br>

## Architecture

```mermaid
graph TB
    User[User Input] --> Agent

    Agent --> |"1. Send messages + tools"| API[Anthropic API]
    API --> |"2. Response (text/tool_use)"| Agent

    Agent --> |"3. Execute tool"| Toolset
    Toolset --> |"4. Tool result"| Agent
    Agent --> |"5. Send tool_result"| API

    Agent --> UI[UI Module]

    subgraph "Agent Class"
        Agent
        Messages[Message History]
        Agent -.-> Messages
    end

    subgraph "Toolset Class"
        Toolset
        Tools[read_file<br/>write_file<br/>list_files<br/>bash]
        Toolset -.-> Tools
    end

    subgraph "Display"
        UI
        Banner[banner]
        Prompt[prompt]
        AgentOut[agent output]
        ToolCall[tool_call]
        ToolResult[tool_result]
        UI -.-> Banner
        UI -.-> Prompt
        UI -.-> AgentOut
        UI -.-> ToolCall
        UI -.-> ToolResult
    end

    style Agent fill:#e1f5ff
    style Toolset fill:#fff4e1
    style UI fill:#f0e1ff
```

<br>

## Solution

A complete implementation is available on the `solution` branch:
```bash
git checkout solution
```
