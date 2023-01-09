# frozen_string_literal: true

# Besides programming error exceptions like ArgumentError,
# all public interface exceptions should be declared here and inherit from Listen::Error.
module Listen
  class Error < RuntimeError
    class NotStarted < Error; end
    class SymlinkLoop < Error; end
    class INotifyMaxWatchesExceeded < Error; end
    class ArgumentError < Error; end
    class InvalidEncodedError < Error
	  attr_reader :file_path
	  def initialize(file_path)
	    @file_path = file_path
	  end
	end
  end
end
