# frozen_string_literal: true

module FileHelper
  def invalid_encoded_file?(file)
    file_path = file.dup
    result = !file_path.to_s.force_encoding('US-ASCII').valid_encoding? || !file_path.to_s.valid_encoding?

    Listen.logger.error { "file_path=#{file_path}" } if result
    result
  end
end
