![cover](./images/workshop-cover.png)

A minimal Ruby implementation of an agentic chatbot with tool use capabilities.

## Prerequisites

- Ruby 3.0+
- Anthropic API key

## Setup

1. Install dependencies:
```bash
bundle install
```

2. Set your API key:
```bash
export ANTHROPIC_API_KEY='your-key-here'
```

## Running

```bash
ruby agent.rb
```

Type `exit` or press `ctrl-c` to quit.

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

## Architecture

```
```

## Resources

- [Anthropic Ruby SDK](https://github.com/alexrudall/anthropic)
- [Messages API Documentation](https://docs.anthropic.com/en/api/messages)
- [Tool Use Guide](https://docs.anthropic.com/en/docs/build-with-claude/tool-use)

## Solution

A complete implementation is available on the `solution` branch:
```bash
git checkout solution
```
