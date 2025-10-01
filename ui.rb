module UI
  def self.banner
    puts
    puts "\e[33m  ▘     ▜   \e[0m"
    puts "\e[33m▛▘▌▛▛▌▛▌▐ ▌▌\e[0m"
    puts "\e[33m▄▌▌▌▌▌▙▌▐▖▙▌\e[0m"
    puts "\e[33m      ▌   ▄▌\e[0m"
    puts
    puts "\e[32m● SimplePractice 🦋\e[0m"
    puts "\e[38;5;8m└─ ctrl-c to quit\e[0m\n\n"
  end

  def self.prompt
    print "\e[35m｢You｣ \e[0m"
  end

  def self.agent(text)
    puts "\e[33m｢Simply｣\e[0m #{text}"
  end

  def self.tool_call(name)
    puts "  \e[34m→\e[0m \e[38;5;8mRunning #{name}...\e[0m"
  end

  def self.tool_result(result)
    display = result.length > 200 ? "#{result[0..200]}..." : result
    puts "  \e[35m←\e[0m \e[38;5;8m#{display.strip}\e[0m\n"
  end

  def self.goodbye
    puts "\n\n\e[31mG\e[33mo\e[32mo\e[36md\e[34mb\e[35my\e[31me\e[33m!\e[0m\n"
  end
end
