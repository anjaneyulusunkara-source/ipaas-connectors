# Names each spec file as it starts, so a run that is killed rather than finished still shows
# where it got to. Progress dots alone leave no trace of that.
class FilePathFormatter
  RSpec::Core::Formatters.register self, :example_started

  def initialize(output)
    @output = output
    @current_file_path = nil
  end

  def example_started(notification)
    return if @current_file_path == notification.example.file_path

    @current_file_path = notification.example.file_path
    @output << "\n#{@current_file_path}\n"
  end
end
